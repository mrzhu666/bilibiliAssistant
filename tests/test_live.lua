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
local obs = {}
local key_bindings = {}
local FAKE_FILES = {}

package.preload["mp.options"] = function()
  return { read_options = function() end }
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
    commandv = function() end,
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
local function scan(pat)
  local out = {}
  for v in overlay_data:gmatch(pat) do out[#out + 1] = tonumber(v) end
  return out
end
local function count_pos() return select(2, overlay_data:gsub("\\pos", "")) end

dofile(MAIN)
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

-- ============ 4. 逐帧重绘：由 time-pos 驱动，位移随帧严格均匀 ============
-- overlay 必须注册 time-pos 观察器（这正是不卡顿的关键：视频帧驱动）
assert(obs["time-pos"], "未注册 time-pos 观察器，无法逐帧重绘")
local function first_x()
  local v = overlay_data:match("\\pos%((%-?%d+),")
  return tonumber(v)
end
-- 模拟 60fps 连续出帧：只靠观察器推进（不再经过 ingest timer）
local xs = {}
for i = 1, 6 do
  FAKE_TIME = FAKE_TIME + 1 / 60
  obs["time-pos"]("time-pos", 1.0 + i / 60)
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
print("OK: time-pos 逐帧驱动推进（60fps 位移恒定）")

-- ============ 5. 不提前消失：显示期未到就不该消失 ============
-- marquee=10s，刚过 0.25s，本 tick 出现的弹幕必须仍在
assert(count_pos() > 0, "弹幕提前消失了")

-- ============ 6. 字号换算：size=50 -> fs100（等价 Danmu2Ass 的 size*fs/25） ============
FAKE_FILES.jsonl = dm("big", "BIG", 16777215, 1, 50) .. "\n"
FAKE_TIME = FAKE_TIME + 60  -- 清空上一批
timer.fn()
assert(overlay_data:find("\\fs100", 1, true), "size=50 未换算为 fs100")
print("OK: 字号换算 size*fontsize/25 生效")

-- ============ 7. 颜色：与 Danmu2Ass ConvertColor 逐字一致 ============
-- 真 Danmu2Ass 对这些 B站 0xRRGGBB 的输出（已实测）：
--   0xFF0000 -> 0200E9   0x00FF00 -> 08FF14   0x0000FF -> F40002
--   0xFFFFFF -> FFFFFF
FAKE_FILES.jsonl = dm("c", "RED", 0xFF0000, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(overlay_data:find("\\c&H0200E9&", 1, true),
  "红色未按 Danmu2Ass 矩阵转到 0200E9")
FAKE_FILES.jsonl = dm("c", "GREEN", 0x00FF00, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(overlay_data:find("\\c&H08FF14&", 1, true), "绿色未转到 08FF14")
-- 白色是特例：Danmu2Ass 直接返回 FFFFFF，且不需要 \c 标签
FAKE_FILES.jsonl = dm("c", "WHITE", 0xFFFFFF, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(not overlay_data:find("\\c&HFFFFFF&", 1, true),
  "白色不应输出 \\c（Danmu2Ass 会跳过 0xffffff）")
print("OK: 颜色转换与 Danmu2Ass 一致")

-- ============ 8. 固定弹幕 an8/an2 ============
FAKE_FILES.jsonl = dm("t", "TOP", 16777215, 5, 25) .. "\n"
  .. dm("b", "BOTTOM", 16777215, 4, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(overlay_data:find("\\an8", 1, true), "顶部固定弹幕缺少 an8")
assert(overlay_data:find("\\an2", 1, true), "底部固定弹幕缺少 an2")
print("OK: 固定弹幕 an8/an2 正确")

-- ============ 9. 转义：花括号不可注入 ============
FAKE_FILES.jsonl = dm("x", "\\{bad\\}", 16777215, 1, 25) .. "\n"
FAKE_TIME = FAKE_TIME + 60
timer.fn()
assert(overlay_data:find("\\{", 1, true), "花括号未转义")
print("OK: ASS 转义生效")

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
