-- 桩 mp 环境，验证 main.lua 直播分支：启动/轮询/渲染/开关/清理/截断/分行。
-- 用法（任选其一）：
--   lua tests/test_live.lua
--   lua /abs/path/tests/test_live.lua

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
  ["opt:live_trim"] = "yes",
}
local overlay_data, timers, events, spawned, overlay_res = nil, {}, {}, nil, {}
local key_bindings, msg_handlers = {}, {}
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
    -- 扁平对象近似解析（coverage: 单元测试用；真实解析靠 mpv 内置）
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
    abort_async_command = function(h) spawned = false end,
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
    register_script_message = function(n, fn) msg_handlers[n] = fn end,
    observe_property = function() end,
    msg = {info = function() end, warn = function() end, error = function() end},
    osd_message = function() end,
  }
end

-- 假 jsonl：io.open 命中直播文件时返回 FAKE_FILES 内容；写操作回写进去。
local real_open = io.open
io.open = function(path, mode)
  if type(path) == "string" and path:find("bilibili%-live%-5050%.jsonl") then
    if mode == "w" then
      -- "w" 语义：第一次 write 覆盖，后续追加（模拟截断+回写剩余半行）
      local touched = false
      return {
        write = function(_, s)
          if touched then
            FAKE_FILES.jsonl = (FAKE_FILES.jsonl or "") .. s
          else
            FAKE_FILES.jsonl = s
            touched = true
          end
        end,
        close = function() FAKE_FILES.last = true end,
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
-- 假删除
local real_remove = os.remove
os.remove = function(path)
  if type(path) == "string" and path:find("bilibili%-live") then
    FAKE_FILES.deleted = (FAKE_FILES.deleted or 0) + 1
    FAKE_FILES.jsonl = nil
    return true
  end
  return real_remove(path)
end

FAKE_FILES.jsonl = table.concat({
  '{"user":"甲","text":"滚动第一条","color":16777215,"mode":1,"size":25,"type":"danmu"}',
  '{"user":"乙","text":"红色滚动","color":16711680,"mode":1,"size":25,"type":"danmu"}',
  '{"user":"老板","text":"SC来了","color":16711680,"mode":1,"size":25,"type":"sc","price":30}',
  '{"user":"丙","text":"{花括号}和\\\\反斜杠","color":255,"mode":1,"size":25,"type":"danmu"}',
  '{"user":"丁","text":"顶部固定","color":65280,"mode":5,"size":30,"type":"danmu"}',
  '{"user":"戊","text":"逆向滚动","color":65535,"mode":6,"size":25,"type":"danmu"}',
  '{"user":"己","text":"双倍大字","color":16777215,"mode":1,"size":50,"type":"danmu"}',
  "", ""}, "\n")

dofile(MAIN)

-- 触发 file-loaded → 走直播分支
events["file-loaded"]()
assert(spawned and spawned.args, "未启动 live_danmu.py 子进程")
print("启动子进程 args: " .. table.concat(spawned.args, " "))
assert(spawned.args[#spawned.args]:find("bilibili%-live%-5050%.jsonl"),
  "jsonl 路径不对")

local timer = timers[1]
assert(timer and math.abs(timer.iv - 0.1) < 1e-9, "轮询间隔不是 0.1s")

-- 第 1 tick：消费全部弹幕，6 滚动+1 顶部固定应全部渲染
timer.fn()
assert(overlay_data and #overlay_data > 0, "tick1 后 overlay 为空")
local n1 = select(2, overlay_data:gsub("\\pos", ""))
print("tick1 弹幕事件数: " .. n1)
assert(n1 == 7, "期望 7 条，实际 " .. n1)
assert(overlay_res.x == 1920 and overlay_res.y == 1080,
  "res_x/res_y 未按 1080p 虚拟画布设置")

-- 校验内容：彩色、SC 标记、转义、固定弹幕、字号换算、双倍大字渲染
assert(overlay_data:find("0000FF", 1, true), "缺少红色(B 站语义转 ASS BGR)弹幕")
assert(overlay_data:find("SC", 1, true), "缺少 SC 标记")
assert(overlay_data:find("\\{花括号\\}", 1, true), "花括号未转义")
assert(overlay_data:find("\\an8", 1, true), "顶部固定弹幕未用 an8")
assert(overlay_data:find("\\fs60", 1, true), "size=50 未按 Danmu2Ass 换算到 fs60")
assert(overlay_data:find("戊：逆向滚动", 1, true), "逆向滚动弹幕丢失")

-- jsonl 已截断（trim）：已播弹幕直接删除
local after = FAKE_FILES.jsonl
assert(after == "" or after == nil, "live_trim=yes 时 jsonl 应被截断，剩余: " .. tostring(after))
print("OK: jsonl 截断生效")

-- 记录首条 x 坐标，推进时间后应变小（左移）
local function first_x(s) return tonumber(s:match("\\pos%((%d+),")) end
local x_a = first_x(overlay_data)
FAKE_TIME = FAKE_TIME + 0.5
timer.fn()
local x_b = first_x(overlay_data)
print("x: " .. tostring(x_a) .. " -> " .. tostring(x_b))
assert(x_a and x_b and x_b < x_a, "弹幕未左移")

-- 开关：b 键关掉后 overlay 清空
key_bindings["b"]()
assert(overlay_data == "", "关闭后 overlay 未清空")
key_bindings["b"]()
assert(#overlay_data > 0, "再次开启后 overlay 仍为空")

-- 结束播放：应清理 overlay + 杀 timer + 删 jsonl
events["end-file"]()
assert(overlay_data == nil, "end-file 后 overlay 未移除")
assert(timer.killed, "end-file 后 timer 未 kill")
assert(spawned == false, "end-file 后子进程未 abort")
assert((FAKE_FILES.deleted or 0) >= 1, "end-file 后 jsonl 未删除")
print("OK: 直播分支全部断言通过")

-- ---------- 密集爆发：不得堆叠追尾 ----------
FAKE_FILES.jsonl = (function()
  local long = {}
  for i = 1, 30 do
    long[i] = ('{"user":"u%d","text":"burst-%d-%s","color":16777215,' ..
      '"mode":1,"size":25,"type":"danmu"}'):format(i, i, string.rep("字", i))
  end
  return table.concat(long, "\n") .. "\n"
end)()
for _, t in ipairs(timers) do t.killed = false end
timers = {}
events["file-loaded"]()
timers[1].fn()
local rows = {}
for y in overlay_data:gmatch("\\pos%(%-?%d+,(%d+)%)") do rows[y] = true end
local nrows = 0
for _ in pairs(rows) do nrows = nrows + 1 end
local placed = select(2, overlay_data:gsub("\\pos", ""))
print(("密集爆发：放置 %d 条，占用 %d 行"):format(placed, nrows))
assert(nrows > 1, "全部堆在同一行，未做分行")
events["end-file"]()
print("OK: 分行防重叠通过")

-- ---------- 半行容错：写入方正在写时不能丢弹幕 ----------
-- trim 会把未消费的剩余半行回写文件；这里模拟抓取端补齐该半行后，
-- 下一 tick 必须原样消费，不丢不乱
FAKE_FILES.jsonl = '{"user":"甲","text":"完整行","color":16777215,"mode":1,"size":25,"type":"danmu"}\n' ..
  '{"user":"乙","text":"半行'
for _, t in ipairs(timers) do t.killed = false end
timers = {}
events["file-loaded"]()
timers[1].fn()
local cnt_half = select(2, overlay_data:gsub("\\pos", ""))
assert(cnt_half == 1, "半行时应只渲染 1 条，实际 " .. cnt_half)
-- trim 后文件里只剩剩余半行；模拟抓取端把它补齐成整行
assert(FAKE_FILES.jsonl == '{"user":"乙","text":"半行',
  "trim 后剩余半行不对: " .. tostring(FAKE_FILES.jsonl))
FAKE_FILES.jsonl = '{"user":"乙","text":"半行截断","color":16777215,"mode":1,"size":25,"type":"danmu"}\n'
FAKE_TIME = FAKE_TIME + 20 -- 让第一条过期（marquee 默认 10s），避免占行干扰计数
timers[1].fn()
local cnt_full = select(2, overlay_data:gsub("\\pos", ""))
assert(cnt_full == 1, "补齐后应渲染 1 条（第二条），实际 " .. cnt_full)
assert(overlay_data:find("截断", 1, true), "补齐的半行内容丢失")
events["end-file"]()
print("OK: 半行容错通过")
