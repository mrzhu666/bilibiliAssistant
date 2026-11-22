-- 桩 mp 环境，验证 main.lua 直播分支。
-- 重点：渲染/排版规则必须与点播 Danmu2Ass 一致（行位、字号、留白、\pos 推进）。
-- 运行: lua tests/test_live.lua   （任意目录，路径按 arg[0] 推导）

local function dirname(p) return p:match("^(.*)[/\\][^/\\]*$") or "." end
local here = dirname(arg and arg[0] or "tests/test_live.lua")
local root = here:gsub("^[/\\]?tests$", ""):gsub("[/\\]tests$", "")
if root == "" then root = "." end
local MAIN = root .. "/main.lua"
local script_dir = root

local FAKE_TIME = 1000.0
local props = {
  ["path"] = "https://live.bilibili.com/5050",
  ["playlist/0/filename"] = "https://live.bilibili.com/5050",
  ["width"] = 1920, ["height"] = 1080,
  -- 与 script-opts.conf 里的实际取值保持一致
  ["opt:live_trim"] = "yes",
  ["opt:live_ingest"] = "0.2",
  ["opt:live_interval"] = "0.01",
  ["opt:live_max"] = "60",
  ["opt:fontsize"] = "50",
  ["opt:percent"] = "0.85",
  ["opt:duration_marquee"] = "10",
  ["opt:duration_still"] = "5",
  ["opt:fontname"] = "sans-serif",
  ["opt:opacity"] = "1",
}
local overlay_data, overlay_res = nil, {}
local timers, events, spawned = {}, {}, nil
local obs, OPT = {}, nil
local key_bindings = {}
local commands = {}
local FAKE_FILES = {}

package.preload["mp.options"] = function()
  -- 抓住脚本配置表引用，便于测试里像 mpv 运行时那样改选项
  return { read_options = function(t) OPT = t end }
end
package.preload["mp.utils"] = function()
  return {
    join_path = function(a, b) return a .. "/" .. b end,
    split_path = function(p) return "", p end,
    file_info = function(p)
      local d = FAKE_FILES[p]
      if d then return {is_file = true, size = #d} end
      return nil
    end,
    parse_json = function(s)
      local t = {}
      for k, v in s:gmatch('"([%w_]+)"%s*:%s*"([^"]*)"') do t[k] = v end
      for k, v in s:gmatch('"([%w_]+)"%s*:%s*(%-?%d+%.?%d*)') do
        t[k] = tonumber(v)
      end
      return t
    end,
  }
end
package.preload["mp"] = function()
  return {
    get_time = function() return FAKE_TIME end,
    get_property = function(k) return props[k] end,
    get_property_number = function(k, d) return props[k] or d end,
    get_property_native = function(k) return props[k] end,
    set_property_native = function(k, v) props[k] = v end,
    get_opt = function(k) return props["opt:" .. k] end,
    get_script_directory = function() return script_dir end,
    commandv = function(...)
      local a = {...}
      if a[1] == "vf" then
        if a[2] == "append" then commands.vf_append = a[3]
        elseif a[2] == "remove" then
          commands.vf_remove = (commands.vf_remove or 0) + 1
        end
      end
    end,
    command = function() end,
    command_native = function() return {} end,
    command_native_async = function(t) spawned = t; return {pid = 1} end,
    abort_async_command = function() spawned = false end,
    create_osd_overlay = function()
      return {
        data = "", res_x = 0, res_y = 720,
        update = function(self)
          overlay_data = self.data
          overlay_res = {x = self.res_x, y = self.res_y}
        end,
        remove = function() overlay_data = nil end,
      }
    end,
    add_periodic_timer = function(iv, fn)
      local t = {iv = iv, fn = fn, killed = false,
        kill = function(self) self.killed = true end}
      timers[#timers + 1] = t; return t
    end,
    add_key_binding = function(k, n, fn) key_bindings[k or n] = fn end,
    register_event = function(n, fn) events[n] = fn end,
    register_script_message = function() end,
    observe_property = function(name, kind, fn)
      obs[name] = fn
      return 1
    end,
    unobserve_property = function(id) obs["__unobs"] = (obs["__unobs"] or 0) + 1 end,
    msg = {info = function() end, warn = function() end, error = function() end},
    osd_message = function() end,
  }
end

-- 假 jsonl
local real_open = io.open
io.open = function(path, mode)
  if type(path) == "string" and path:find("bilibili%-live%-5050%.jsonl") then
    if mode == "w" then
      local touched = false
      return {
        write = function(_, s)
          if touched then
            FAKE_FILES.jsonl = (FAKE_FILES.jsonl or "") .. s
          else
            FAKE_FILES.jsonl = s; touched = true
          end
        end,
        close = function() end,
      }
    end
    local content = FAKE_FILES.jsonl or ""
    local pos = 0
    return {
      seek = function(_, whence, off)
        if whence == "set" then pos = off or 0 end
        return pos
      end,
      read = function(_, fmt)
        if fmt == "*a" then
          local d = content:sub(pos + 1); pos = #content; return d
        end
      end,
      close = function() end,
    }
  end
  return real_open(path, mode)
end
local real_remove = os.remove
os.remove = function(path)
  if type(path) == "string" and path:find("bilibili%-live") then
    FAKE_FILES.deleted = (FAKE_FILES.deleted or 0) + 1
    FAKE_FILES.jsonl = nil
    return true
  end
  return real_remove(path)
end

local function dm(user, text, color, mode, size)
  return ('{"user":"%s","text":"%s","color":%d,"mode":%d,"size":%d,' ..
    '"type":"danmu"}'):format(user, text, color, mode or 1, size or 25)
end
local function scdm(user, text, color, price, mode, size)
  return ('{"user":"%s","text":"%s","color":%d,"mode":%d,"size":%d,' ..
    '"type":"sc","price":%d}'):format(user, text, color, mode or 1, size or 25, price or 30)
end
local function scan(pat)
  local out = {}
  for v in overlay_data:gmatch(pat) do out[#out + 1] = tonumber(v) end
  return out
end
local function count_pos() return select(2, overlay_data:gsub("\\pos", "")) end

dofile(MAIN)
-- 生产配置是 percent=0.85（滚动区只用顶部 15%）。桩里的 props 不参与
-- read_options（它只抓默认表），所以这里显式设成生产值，
-- 后面的行数 / 固定区断言才有意义。
OPT.percent = "0.85"
events["file-loaded"]()
assert(spawned and spawned.args, "未启动 live_danmu.py 子进程")
print("子进程: " .. table.concat(spawned.args, " "))
local timer = timers[1]
assert(timer and math.abs(timer.iv - 0.2) < 1e-9, "收取间隔不是 0.2s")

-- ============ 1. 行排布必须与 Danmu2Ass 逐字对拍 ============
-- 用真 Danmu2Ass(-s 1920x1080 -fs 50 -p 918 -dm 10 -ds 5) 跑同样 4 条（t=0,1,2,3）
-- 得到的结果是 row = 0, 50, 0, 100：
--   AAAA             -> 0
--   AAAAAAAAAAAAAAAA -> 50   （更长会被追上，换行）
--   BB               -> 0    （更慢，可与第 1 条共行）
--   CCCCCCCCCCCC     -> 100
-- 因此这里按 1 秒一条的节奏喂入，复刻点播的时间差。
FAKE_TIME = 2000.0
local seq = {
  dm("u1", "AAAA", 16777215, 3, 25),
  dm("u1", "AAAAAAAAAAAAAAAA", 16777215, 3, 25),
  dm("u1", "BB", 16777215, 3, 25),
  dm("u1", "CCCCCCCCCCCC", 16777215, 3, 25),
}
local rows = {}
for _, line in ipairs(seq) do
  FAKE_FILES.jsonl = line .. "\n"
  timer.fn()
  -- 取本 tick 新出现的那条的 y（最后一条 \pos）
  local last_y
  for y in overlay_data:gmatch("\\pos%(%-?%d+,(%d+)%)") do last_y = tonumber(y) end
  rows[#rows + 1] = last_y
  FAKE_TIME = FAKE_TIME + 1.0
end
print("行位: " .. table.concat(rows, ","))
assert(rows[1] == 0 and rows[2] == 50 and rows[3] == 0 and rows[4] == 100,
  "行位与 Danmu2Ass 不一致: " .. table.concat(rows, ","))
print("OK: 行排布与点播 Danmu2Ass 一致（0,50,0,100）")

-- ============ 2. 留白：percent=0.85 -> 弹幕区只到 162px，且中间无任何 \pos 超过 ============
for _, y in ipairs(rows) do
  assert(y <= 162, "弹幕越过留白线(162): " .. y)
end
assert(overlay_res.x == 1920 and overlay_res.y == 1080, "PlayRes 不是 1920x1080")
print("OK: 底部留白 percent=0.85 生效（弹幕区 0..162）")

-- ============ 3. 字体/样式必须显式声明，且与点播一致 ============
assert(overlay_data:find("\\fn", 1, true), "缺少 \\fn（会被 mpv OSD 字体覆盖）")
assert(overlay_data:find("\\fs50", 1, true), "字号不对（应为 fontsize=50）")
assert(overlay_data:find("\\q2", 1, true), "缺少 \\q2（换行策略）")
print("OK: 字体/字号/样式显式声明")

-- ============ 3b. 字体：默认跟随 --sub-font，与点播弹幕落在同一字体 ============
-- 点播 ASS 写 sans-serif，但 libass 找不到中文字形，回退到 --sub-font（本机楷体）。
-- 直播 overlay 走 OSD 字体链，回退目标是 --osd-font（微软雅黑），于是两边中文不同。
-- 修复：o.fontname 仍是默认 sans-serif 时，改用 --sub-font。
props["sub-font"] = "LXGW WenKai Mono Lite"
FAKE_FILES.jsonl = dm("f", "FONTTEST", 16777215, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(overlay_data:find("\\fnLXGW WenKai Mono Lite", 1, true),
  "默认应跟随 --sub-font（与点播同一字体），实际: "
  .. tostring(overlay_data:match("\\fn[^\\]*")))
-- 用户显式配了 fontname 时尊重用户配置
OPT.fontname = "Microsoft YaHei"
FAKE_FILES.jsonl = dm("f", "FONTTEST2", 16777215, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(overlay_data:find("\\fnMicrosoft YaHei", 1, true),
  "显式 fontname 应被尊重")
OPT.fontname = "sans-serif"
print("OK: 字体默认跟随 --sub-font（与点播一致），显式 fontname 优先")


-- 关键：必须用高频定时器而不是 observe_property("time-pos")。
-- mpv 的属性事件是 coalesced 的，实测会隔帧丢（mpv#4195），重绘会不规律。
assert(timers[2], "缺少重绘定时器")
local rtimer = timers[2]
assert(math.abs(rtimer.iv - 0.01) < 1e-9, "重绘间隔不是 0.01s")
assert(not obs["time-pos"], "不应依赖 time-pos 观察器（属性事件会被合并丢帧）")
local function first_x()
  local v = overlay_data:match("\\pos%((%-?%d+),")
  return tonumber(v)
end
-- 模拟 60fps 播放：定时器每 1/60s 触发一次
local xs = {}
for i = 1, 6 do
  FAKE_TIME = FAKE_TIME + 1 / 60
  rtimer.fn()
  xs[#xs + 1] = first_x()
end
print("x 序列(60fps): " .. table.concat(xs, ","))
local d0 = xs[2] - xs[1]
for i = 2, #xs - 1 do
  local d = xs[i + 1] - xs[i]
  assert(math.abs(d - d0) <= 1,
    "位移不均匀（卡顿）: " .. table.concat(xs, ","))
end
assert(xs[#xs] < xs[1], "弹幕未左移")
print("OK: 高频重绘定时器推进（60fps 位移恒定）")

-- ============ 5. 不提前消失：显示期未到就不该消失 ============
-- marquee=10s，刚过 0.25s，本 tick 出现的弹幕必须仍在
assert(count_pos() > 0, "弹幕提前消失了")

-- ============ 6. 字号换算：size=50 -> fs100（等价 Danmu2Ass 的 size*fs/25） ============
FAKE_FILES.jsonl = dm("big", "BIG", 16777215, 1, 50) .. "\n"
FAKE_TIME = FAKE_TIME + 60  -- 清空上一批
timer.fn()
assert(overlay_data:find("\\fs100", 1, true), "size=50 未换算为 fs100")
print("OK: 字号换算 size*fontsize/25 生效")

-- ============ 7. 颜色矩阵：与 Danmu2Ass ConvertColor 逐字一致 ============
-- 真 Danmu2Ass 对这些 B站 0xRRGGBB 的输出（已实测）：
--   0xFF0000 -> 0200E9   0x00FF00 -> 08FF14   0x0000FF -> F40002
--   0xFFFFFF -> FFFFFF
-- 注意：这里只测转换矩阵本身，所以先关掉彩色调暗（否则会被 dim 影响）
OPT.live_color_dim = "1.0"
FAKE_FILES.jsonl = dm("c", "RED", 0xFF0000, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(overlay_data:find("\\c&H0200E9&", 1, true),
  "红色未按 Danmu2Ass 矩阵转到 0200E9")
FAKE_FILES.jsonl = dm("c", "GREEN", 0x00FF00, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(overlay_data:find("\\c&H08FF14&", 1, true), "绿色未转到 08FF14")
-- 白色也必须显式输出 \c：直播 overlay 的样式是 mpv OSD（osd-color），
-- 省略 \c 会继承 OSD 颜色（本机紫字 #672168），白字弹幕直接变紫。
-- 点播那边能省略是因为 ASS 样式自带 PrimaryColour=&HFFFFFF。
FAKE_FILES.jsonl = dm("c", "WHITE", 0xFFFFFF, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(overlay_data:find("\\c&HFFFFFF&", 1, true),
  "白色必须显式输出 \\c&HFFFFFF&（否则继承 mpv OSD 的紫字）")
OPT.live_color_dim = "0.75" -- 恢复默认
print("OK: 颜色转换与 Danmu2Ass 一致（白色也显式输出 \\c）")

-- ============ 7b. 描边：默认黑边（与点播 Danmu2Ass 一致） ============
-- 回归点：default 继承 mpv OSD 描边会让描边变成近白 #EEEEEE，与点播黑边不一致。
assert((OPT.live_outline_color or "black") == "black",
  "默认描边应为 black（与点播 Danmu2Ass 一致）")
FAKE_FILES.jsonl = dm("d", "BLACKOUT", 0xFF0000, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(overlay_data:find("\\3c&H000000&", 1, true),
  "默认应输出黑色描边 \\3c&H000000&（同点播 Danmu2Ass）")
assert(overlay_data:find("\\c&H", 1, true), "彩色弹幕应输出文字色 \\c")
-- 黑字特例：必须补白边，与描边设置无关（否则黑底看不见）
FAKE_FILES.jsonl = dm("d", "BLACKTEXT", 0x000000, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(overlay_data:find("\\c&H000000&\\3c&HFFFFFF&", 1, true),
  "黑字未补白边")
-- 白色默认弹幕：必须显式输出 \c&HFFFFFF& + 黑边
FAKE_FILES.jsonl = dm("d", "PLAINWHITE", 0xFFFFFF, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(overlay_data:find("\\c&HFFFFFF&\\3c&H000000&", 1, true),
  "白色弹幕应为白字黑边（与点播渲染结果一致）")
print("OK: 默认白字黑边，与点播 Danmu2Ass 渲染结果一致")

-- 显式指定描边色仍可用（可选增强）
OPT.live_outline_color = "white"
FAKE_FILES.jsonl = dm("d", "WOUT", 0xFF0000, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(overlay_data:find("\\3c&HFFFFFF&", 1, true),
  "live_outline_color=white 未生效")
-- default 仍可显式选择继承 mpv OSD（旧行为，留作对比）
OPT.live_outline_color = "default"
FAKE_FILES.jsonl = dm("d", "OSDOUT", 0xFF0000, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(not overlay_data:find("\\3c", 1, true),
  "live_outline_color=default 应继承 mpv OSD（不输出 \\3c）")
OPT.live_outline_color = "black"
print("OK: live_outline_color 可指定（black 默认 / white / RRGGBB / default 继承 OSD）")

-- ============ 7c. 调暗：默认开启，只作用彩色弹幕，白字不受影响 ============
-- 纯红 0xFF0000 -> Danmu2Ass 矩阵 0200E9
-- 0.75: 0x02*0.75=1.5->2, 0xE9*0.75=174.75->175=0xAF  => 0200AF
local dim = tonumber(OPT.live_color_dim or 1)
assert(dim > 0 and dim < 1, "默认应开启彩色调暗，实际 live_color_dim="
  .. tostring(OPT.live_color_dim))
FAKE_FILES.jsonl = dm("d", "DIMRED", 0xFF0000, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
local got = overlay_data:match("\\c&H(%x%x%x%x%x%x)&")
print("  红色调暗后: " .. tostring(got))
assert(got and got < "0200E9", "彩色弹幕未被调暗: " .. tostring(got))
assert(got ~= "0200E9", "调暗系数无效")
-- 白字不受调暗影响（白色仍是纯白 FFFFFF，只是显式输出 \c）
FAKE_FILES.jsonl = dm("d", "DIMWHITE", 0xFFFFFF, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(overlay_data:find("\\c&HFFFFFF&", 1, true),
  "白字应显式输出纯白 \\c&HFFFFFF&（不受调暗影响）")
assert(not overlay_data:find("\\c&H%x%x%x%x%x%x&[^\\]*\\c", 1, false),
  "白字被调暗/染色了")
-- dim=1.0 时完全还原
OPT.live_color_dim = "1.0"
FAKE_FILES.jsonl = dm("d", "NODIM", 0xFF0000, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(overlay_data:find("\\c&H0200E9&", 1, true),
  "live_color_dim=1.0 时未还原为原色")
print("OK: live_color_dim 默认开启、只调彩色、白字不受影响")

-- ============ 8. 固定弹幕 an8/an2 ============
FAKE_FILES.jsonl = dm("t", "TOP", 16777215, 5, 25) .. "\n"
  .. dm("b", "BOTTOM", 16777215, 4, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(overlay_data:find("\\an8", 1, true), "顶部固定弹幕缺少 an8")
assert(overlay_data:find("\\an2", 1, true), "底部固定弹幕缺少 an2")
print("OK: 固定弹幕 an8/an2 正确")

-- ============ 8b. SC 默认走顶部固定弹幕（不再滚动） ============
-- B站网页播放器把 SC 钉在顶部固定位置，不飘过去；SC 往往很长，滚动也来不及看。
assert((OPT.live_sc_mode or "top") == "top", "SC 默认应为 top（顶部固定）")
FAKE_FILES.jsonl = scdm("scuser", "这是一条SC留言", 16711680, 30) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
-- SC 必须是固定弹幕：an8（顶部）+ \pos，且不带 \move
local sc_line
for line in overlay_data:gmatch("[^\n]+") do
  if line:find("这是一条SC留言", 1, true) then sc_line = line break end
end
assert(sc_line, "SC 未渲染")
assert(sc_line:find("\\an8", 1, true), "SC 应为顶部固定弹幕（an8）: " .. sc_line)
assert(not sc_line:find("\\an7", 1, true), "SC 不应再用滚动定位（an7）: " .. sc_line)
assert(sc_line:find("[SC ¥30]", 1, true), "SC 未显示金额前缀: " .. sc_line)
-- 停留时长：默认 duration_still * 2
FAKE_TIME = FAKE_TIME + 6   -- 6s > duration_still(5)，但 < 10
rtimer.fn()
assert(overlay_data:find("这是一条SC留言", 1, true), "SC 停留时间不足（应约 10s）")
FAKE_TIME = FAKE_TIME + 5   -- 累计 11s > 10
rtimer.fn()
assert(not overlay_data:find("这是一条SC留言", 1, true), "SC 超时后未消失")
print("OK: SC 默认顶部固定弹幕（an8 + 金额前缀 + 停留约 10s）")

-- live_sc_mode=scroll 时退回旧的滚动行为
OPT.live_sc_mode = "scroll"
FAKE_FILES.jsonl = scdm("scuser2", "滚动SC", 16711680, 50) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
local sc2
for line in overlay_data:gmatch("[^\n]+") do
  if line:find("滚动SC", 1, true) then sc2 = line break end
end
assert(sc2 and sc2:find("\\an7", 1, true), "live_sc_mode=scroll 时应走滚动: " .. tostring(sc2))
OPT.live_sc_mode = "top"
print("OK: live_sc_mode=scroll 可退回旧行为")

-- ============ 9. 转义：花括号不可注入 ============
FAKE_FILES.jsonl = dm("x", "\\{bad\\}", 16777215, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(overlay_data:find("\\{", 1, true), "花括号未转义")
print("OK: ASS 转义生效")

-- ============ 9b. 提帧：直播也复用 fps_vf（<45fps 自动 fps=60） ============
-- 直播流常见 30fps，画面本身只有 30Hz，不提帧弹幕再顺也会被拖住
FAKE_FILES.jsonl = dm("f", "FPS", 16777215, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
props["container-fps"] = 30
timer.fn()          -- 收到弹幕
-- 提帧评估挂在重绘 tick 上（低频重估），推进足够多次让它触发
for i = 1, 120 do
  FAKE_TIME = FAKE_TIME + 0.01
  rtimer.fn()
end
assert(commands.vf_append and commands.vf_append:find("fps=fps=60", 1, true),
  "低帧率直播未自动提帧到 60fps")
props["container-fps"] = 60
for i = 1, 120 do
  FAKE_TIME = FAKE_TIME + 0.01
  rtimer.fn()
end
assert(commands.vf_remove and commands.vf_remove > 0,
  "高帧率时未撤掉提帧滤镜")
print("OK: 直播同样复用 fps_vf 提帧")

-- ============ 9c. 速度参数：所有滚动弹幕速度相同，与文字长度无关 ============
-- 用户要求把「固定秒数」换成「固定速度」：duration_marquee 只决定"穿过一屏"的
-- 基准时间，长弹幕不再因为固定秒数而被逼着跑得更快（也就不会追尾挤压）。
-- 这里用 0.2 屏宽/秒：1920 宽舞台上应为 384 U/s，与文字长度无关。
local function pos_xs()
  local out = {}
  for v in overlay_data:gmatch("\\pos%((%-?%d+),") do out[#out + 1] = tonumber(v) end
  return out
end
local function measure_speed_u(text)
  FAKE_FILES.jsonl = dm("s", text, 16777215, 1, 25) .. "\n"
  FAKE_TIME = FAKE_TIME + 60      -- 清掉上一批，只留本条
  timer.fn()
  local x0 = pos_xs()[1]
  FAKE_TIME = FAKE_TIME + 1.0
  rtimer.fn()
  local x1 = pos_xs()[1]
  return x0 - x1                  -- 每秒推进的舞台单位
end
OPT.speed = "0.2"
local v_short = measure_speed_u("SHORT")
local v_long = measure_speed_u(string.rep("L", 40))
print(string.format("速度(短/长): %d / %d U/s", v_short, v_long))
assert(math.abs(v_short - v_long) <= 2,
  "长短弹幕速度不一致（应相同）: " .. v_short .. " vs " .. v_long)
assert(math.abs(v_short - 0.2 * 1920) <= 3,
  "速度与 speed 参数不符（应为 0.2*1920=384）: " .. v_short)
print("OK: speed 参数生效（0.2 屏宽/秒，与文字长度无关）")

-- ============ 9d. 窗口尺寸无关：任意窗口下「穿过一屏的时间」相同 ============
-- 旧实现把 PlayRes 固定成 1920x1080 交给 libass 拉伸，窗口一变宽高比就被拉歪：
-- 相对窗口的横向速度会变，弹幕越挤越多。现在 overlay 画布 = 屏幕像素、坐标按
-- 视频显示矩形换算，所以「每秒穿过多少屏宽」恒等于 speed。
local function measure_speed_screens()
  FAKE_FILES.jsonl = dm("w", "WWWWWWWWWW", 16777215, 1, 25) .. "\n"
  FAKE_TIME = FAKE_TIME + 60
  timer.fn()
  local xs = pos_xs()
  local x0 = xs[#xs]
  FAKE_TIME = FAKE_TIME + 1.0
  rtimer.fn()
  xs = pos_xs()
  local x1 = xs[#xs]
  -- 视频显示宽度（屏幕像素）= osd 宽 - 左右黑边
  local dim = props["osd-dimensions"]
  local vw = dim.w - (dim.ml or 0) - (dim.mr or 0)
  return (x0 - x1) / vw
end
-- 16:9 小窗（无黑边）
props["osd-dimensions"] = {w = 1280, h = 720, ml = 0, mt = 0, mr = 0, mb = 0}
local s_169 = measure_speed_screens()
-- 4:3 窗口里放 16:9 视频（上下黑边各 75px）：视频区只有 800x450
props["osd-dimensions"] = {w = 800, h = 600, ml = 0, mt = 75, mr = 0, mb = 75}
local s_43 = measure_speed_screens()
-- 超宽窗口（左右黑边）
props["osd-dimensions"] = {w = 1400, h = 500, ml = 200, mt = 0, mr = 200, mb = 0}
local s_wide = measure_speed_screens()
print(string.format("屏宽/秒: 16:9=%.3f 4:3窗=%.3f 超宽=%.3f", s_169, s_43, s_wide))
assert(math.abs(s_169 - 0.2) < 0.01, "16:9 小窗速度不是 0.2 屏宽/秒: " .. s_169)
assert(math.abs(s_43 - s_169) < 0.01,
  "带黑边窗口速度变了（旧 bug）: " .. s_43 .. " vs " .. s_169)
assert(math.abs(s_wide - s_169) < 0.01,
  "超宽窗口速度变了（旧 bug）: " .. s_wide .. " vs " .. s_169)
-- overlay 画布必须等于当前屏幕像素尺寸，否则 libass 会再次拉伸
assert(overlay_res.x == 1400 and overlay_res.y == 500,
  "overlay res 不是当前屏幕像素尺寸: " .. tostring(overlay_res.x) .. "x" .. tostring(overlay_res.y))
print("OK: 窗口缩放 / 黑边都不改变弹幕速度（恒为 speed 屏宽/秒）")
props["osd-dimensions"] = nil
OPT.speed = ""  -- 恢复默认（空 = 用 duration_marquee 固定秒数）

-- ============ 10b. 预处理：截断到第一个冒号，去掉"用户名：" ============
-- 回归点：全角「：」是 3 字节，若用 [：:] 字符类会被逐字节拆开、从字中间切断
FAKE_FILES.jsonl = dm("小明", "你好啊", 16777215, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(overlay_data:find("你好啊", 1, true), "未保留冒号后的内容")
assert(not overlay_data:find("小明", 1, true), "用户名前缀未被截掉")
assert(not overlay_data:find("：你好", 1, true), "全角冒号未被正确识别")
-- 含多个冒号：只截第一个
FAKE_FILES.jsonl = dm("张三", "含 123：多个冒号", 16777215, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(overlay_data:find("含 123：多个冒号", 1, true), "多个冒号时截错了")
-- URL 的协议头不应被当成分隔符
FAKE_FILES.jsonl = dm("李四", "看 http://a.com", 16777215, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(overlay_data:find("http://a.com", 1, true), "URL 协议头被截坏")
-- 冒号后为空 -> 丢弃该条
FAKE_FILES.jsonl = dm("王五", "", 16777215, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(not overlay_data:find("王五", 1, true), "空内容弹幕未被丢弃")
print("OK: 前缀截断（多字节安全 / URL 保护 / 空内容丢弃）")

-- live_prefix=no 时应保留完整"用户名：内容"
OPT.live_prefix = "no"
FAKE_FILES.jsonl = dm("赵六", "完整保留", 16777215, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(overlay_data:find("赵六：完整保留", 1, true), "live_prefix=no 未保留前缀")
-- live_prefix=trim_keep 时应为"用户名 内容"
OPT.live_prefix = "trim_keep"
FAKE_FILES.jsonl = dm("钱七", "保留名字", 16777215, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(overlay_data:find("钱七 保留名字", 1, true), "live_prefix=trim_keep 不对")
OPT.live_prefix = "trim"
print("OK: live_prefix 三种模式")

-- 取包含某段文字的那一行 ASS 事件（\pos 在文字前面，不能按文字往后找）
local function line_with(s)
  for line in overlay_data:gmatch("[^\n]+") do
    if line:find(s, 1, true) then return line end
  end
  return nil
end

-- ============ 9. 固定弹幕区：从舞台顶部算起，占整屏 50%，与滚动区重叠 ============
-- 1080 舞台：滚动区 0..162（percent=0.85），固定区 0..540（0.5*1080），
-- 0..162 这段两块重叠（两套独立通道，互不避让）
OPT.live_fixed_percent = "0.5"
FAKE_TIME = FAKE_TIME + 60
FAKE_FILES.jsonl = dm("t", "FIXTOP", 16777215, 5, 25) .. "\n"
timer.fn()
local fix_line = line_with("FIXTOP")
assert(fix_line, "顶部固定弹幕未渲染")
local fix_y = tonumber(fix_line:match("\\pos%(%-?%d+,(%d+)%)"))
assert(fix_y == 0, "顶部固定弹幕应落在固定区顶(0)，实际 " .. tostring(fix_y))
FAKE_TIME = FAKE_TIME + 60
FAKE_FILES.jsonl = dm("b", "FIXBOT", 16777215, 4, 25) .. "\n"
timer.fn()
local bot_line = line_with("FIXBOT")
assert(bot_line, "底部固定弹幕未渲染")
local bot_y = tonumber(bot_line:match("\\pos%(%-?%d+,(%d+)%)"))
assert(bot_y == 540, "底部固定弹幕底边应落在固定区底(540)，实际 " .. tostring(bot_y))
assert(bot_line:find("\\an2", 1, true), "底部固定弹幕应为 an2")
print("OK: 固定区 0..540（与滚动区重叠，滚动区仍是顶部 15%）")

-- ============ 10. 聚合：3 条相同 -> 1 条滚动 + 1 条固定 ×3 ============
OPT.live_merge = "yes"
OPT.live_merge_hold = "4"
OPT.live_merge_min = "2"
OPT.live_merge_maxlen = "30"
FAKE_TIME = FAKE_TIME + 60
local function feed(line) FAKE_FILES.jsonl = line .. "\n"; timer.fn() end
feed(dm("u1", "SAME", 16777215, 1, 25))
local first_line = line_with("SAME")
assert(first_line and not first_line:find("×", 1, true),
  "第一条应正常滚动显示（不带计数）")
FAKE_TIME = FAKE_TIME + 0.3
feed(dm("u2", "SAME", 16777215, 1, 25))
FAKE_TIME = FAKE_TIME + 0.3
feed(dm("u3", "SAME", 16777215, 1, 25))
local agg_line = line_with("SAME ×3")
assert(agg_line, "第 3 条应把计数更新为 ×3")
assert(agg_line:find("\\an8", 1, true), "聚合弹幕应为顶部固定（an8）")
assert(tonumber(agg_line:match("\\pos%(%-?%d+,(%d+)%)")) == 0,
  "聚合弹幕应落在固定区顶(0)")
local n_same = select(2, overlay_data:gsub("SAME", ""))
assert(n_same == 2, "同屏应只有 2 处 SAME（1 滚动 + 1 固定），实际 " .. n_same)
print("OK: 聚合 3 条相同 -> 1 滚动 + 1 固定 ×3（数字原地增长）")

-- ============ 11. 超过 hold 后聚合弹幕消失、计数清零 ============
FAKE_TIME = FAKE_TIME + 4.5
feed("")
assert(not line_with("SAME ×3"), "超过 hold 后聚合弹幕应消失")
FAKE_TIME = FAKE_TIME + 0.2
feed(dm("u4", "SAME", 16777215, 1, 25))
assert(not line_with("SAME ×2"), "消失后应重新从 1 开始计数")
print("OK: 超过 hold 后消失，再来重新计数")

-- ============ 12. 固定区三方共存：聚合 + 原生顶部 + SC 各占一行 ============
FAKE_TIME = FAKE_TIME + 60
feed(dm("a", "AGGMIX", 16777215, 1, 25))
FAKE_TIME = FAKE_TIME + 0.2
feed(dm("b", "AGGMIX", 16777215, 1, 25))
FAKE_TIME = FAKE_TIME + 0.2
feed(dm("c", "NATIVETOP", 16777215, 5, 25))
FAKE_TIME = FAKE_TIME + 0.2
feed(scdm("s", "SCMIX", 16711680, 30))
local ys = {}
for line in overlay_data:gmatch("[^\n]+") do
  if line:find("AGGMIX ×2", 1, true) or line:find("NATIVETOP", 1, true)
      or line:find("SCMIX", 1, true) then
    ys[#ys + 1] = tonumber(line:match("\\pos%(%-?%d+,(%d+)%)"))
  end
end
assert(#ys == 3, "应有三条固定弹幕，实际 " .. #ys)
assert(ys[1] ~= ys[2] and ys[2] ~= ys[3] and ys[1] ~= ys[3],
  "三条固定弹幕落在同一行（叠字）: " .. table.concat(ys, ","))
print("OK: 聚合/原生顶部/SC 三方共存，各占一行: " .. table.concat(ys, ","))

-- ============ 13. live_merge=no 时不合并 ============
OPT.live_merge = "no"
FAKE_TIME = FAKE_TIME + 60
feed(dm("x1", "NOMERGE", 16777215, 1, 25))
FAKE_TIME = FAKE_TIME + 0.2
feed(dm("x2", "NOMERGE", 16777215, 1, 25))
FAKE_TIME = FAKE_TIME + 0.2
feed(dm("x3", "NOMERGE", 16777215, 1, 25))
local n_nomerge = select(2, overlay_data:gsub("NOMERGE", ""))
assert(n_nomerge == 3, "live_merge=no 时应各自显示 3 条，实际 " .. n_nomerge)
OPT.live_merge = "yes"
print("OK: live_merge=no 时关闭聚合")

-- ============ 10. jsonl 截断 + 结束清理 ============
assert(FAKE_FILES.jsonl == "" or FAKE_FILES.jsonl == nil, "live_trim 未截断")
key_bindings["b"]()
assert(overlay_data == "", "关闭后未清空")
key_bindings["b"]()
events["end-file"]()
assert(overlay_data == nil, "end-file 未移除 overlay")
assert(timer.killed, "end-file 未 kill timer")
assert(spawned == false, "end-file 未 abort 子进程")
assert((FAKE_FILES.deleted or 0) >= 1, "end-file 未删除 jsonl")
print("OK: 截断/开关/结束清理通过")

-- ============ 11. 半行容错 ============
FAKE_FILES.jsonl = dm("a", "完整行", 16777215, 1, 25) .. "\n"
  .. '{"user":"b","text":"半行'
for _, t in ipairs(timers) do t.killed = false end
timers = {}
FAKE_TIME = FAKE_TIME + 60
events["file-loaded"]()
timers[1].fn()
assert(count_pos() == 1, "半行时应只渲染 1 条，实际 " .. count_pos())
assert(FAKE_FILES.jsonl == '{"user":"b","text":"半行', "trim 后剩余半行不对")
FAKE_FILES.jsonl = dm("b", "半行截断", 16777215, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timers[1].fn()
assert(count_pos() == 1, "补齐后应渲染 1 条")
assert(overlay_data:find("截断", 1, true), "补齐的半行内容丢失")
events["end-file"]()
print("OK: 半行容错通过")

print("\n所有断言通过")
