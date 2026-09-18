-- 真实集成：用真 io.open 读 live_danmu.py 产出的 jsonl，走 main.lua 的直播渲染路径
-- 依赖环境变量 LIVE_ROOM（默认 5050），jsonl 由外部抓取脚本产出到 TEMP
-- 用法：
--   python3 live_danmu.py 5050 /tmp/bilibili-live-5050.jsonl & sleep 25; kill %1
--   LIVE_ROOM=5050 lua tests/test_integration.lua

local function dirname(p) return p:match("^(.*)[/\\][^/\\]*$") or "." end
local here = dirname(arg and arg[0] or "tests/test_integration.lua")
local root = here:gsub("^[/\\]?tests$", ""):gsub("[/\\]tests$", "")
if root == "" then root = "." end
local MAIN = root .. "/main.lua"
local script_dir = root

local room = os.getenv("LIVE_ROOM") or "5050"
local props = {
  ["path"] = "https://live.bilibili.com/" .. room,
  ["playlist/0/filename"] = "https://live.bilibili.com/" .. room,
  ["width"] = 1920, ["height"] = 1080,
  ["opt:live_trim"] = "yes",
}
local FAKE_TIME = 1000.0
local overlay_data, timers, events, spawned, overlay_res = nil, {}, {}, nil, {}
local obs = {}

package.preload["mp.options"] = function()
  return { read_options = function() end }
end
package.preload["mp.utils"] = function()
  return {
    join_path = function(a, b) return a .. "/" .. b end,
    file_info = function() return nil end,
    -- 真实用例就走 mpv 内置 parse_json；这里扁平近似即可
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
    command_native_async = function(t) spawned = t; return {} end,
    abort_async_command = function() spawned = false end,
    create_osd_overlay = function()
      return {data = "", res_x = 0, res_y = 720,
        update = function(self)
          overlay_data = self.data
          overlay_res = {x = self.res_x, y = self.res_y}
        end,
        remove = function() overlay_data = nil end}
    end,
    add_periodic_timer = function(iv, fn)
      local t = {iv = iv, fn = fn, killed = false,
        kill = function(self) self.killed = true end}
      timers[#timers + 1] = t; return t
    end,
    add_key_binding = function() end,
    register_event = function(n, fn) events[n] = fn end,
    register_script_message = function() end,
    observe_property = function(name, kind, fn)
      obs[name] = fn
      return 1
    end,
    unobserve_property = function() end,
    msg = {info = function() end, warn = function() end, error = function() end},
    osd_message = function() end,
  }
end

dofile(MAIN)
events["file-loaded"]()
assert(spawned, "未进入直播分支")

-- 反复 tick：timers[1]=收取(0.2s)，timers[2]=重绘(0.01s)
assert(timers[1] and timers[2], "缺少收取/重绘定时器")
local peak = 0
for _ = 1, 600 do
  FAKE_TIME = FAKE_TIME + 1 / 60
  timers[1].fn()   -- 收弹幕
  timers[2].fn()   -- 高频重绘（顺滑度来源）
  if overlay_data then
    local n = select(2, overlay_data:gsub("\\pos", ""))
    if n > peak then peak = n end
  end
end
print("真实 jsonl 渲染出的同屏弹幕峰值: " .. peak)
assert(peak > 0, "未从真实 jsonl 渲染出任何弹幕")
if overlay_data and #overlay_data > 0 then
  print("样例 overlay 片段: " .. overlay_data:sub(1, 160))
end
-- jsonl 必须被截断（不囤积）
local tmp = os.getenv("TEMP") or os.getenv("TMP") or "/tmp/"
local jf = io.open(tmp .. "/bilibili-live-" .. room .. ".jsonl", "r")
if jf then
  local body = jf:read("*a"); jf:close()
  assert(body == "" or body == nil,
    "真实 jsonl 未被截断，体积仍在增长: " .. tostring(#(body or "")))
  print("OK: 真实 jsonl 已截断，不囤积")
end
events["end-file"]()
-- 结束时 jsonl 文件必须删除
local gone = io.open(tmp .. "/bilibili-live-" .. room .. ".jsonl", "r")
assert(gone == nil, "end-file 后 jsonl 文件仍存在")
if gone then gone:close() end
print("OK: 真实数据集成通过")
