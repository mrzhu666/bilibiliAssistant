-- https://github.com/itKelis/MPV-Play-BiliBili-Comments

local mp = require 'mp'
local utils = require 'mp.utils'
local options = require 'mp.options'

local o = {
	--是否自动显示弹幕
	autoplay = true,
	--最小弹幕数量
	mincount = 1,
	--弹幕字体
	fontname = "sans-serif",
	--弹幕字体大小
	fontsize = "50",
	--弹幕不透明度(0-1)
	opacity = "0.95",
	--滚动弹幕显示的持续时间 (秒)
	duration_marquee = "10",
	--静止弹幕显示的持续时间 (秒)
	duration_still = "5",
	--保留底部多少高度的空白区域 (取值0.0-1.0)
	percent = "0.75",
	--弹幕屏蔽的关键词文件路径，支持绝对和相对路径
	filter_file = "",
	--是否对低帧率视频自动添加fps滤镜，以保证滚动弹幕流畅
	fps_vf = true,
	--是否在osd显示日志
	log_osd = false,
	--是否使用Danmu2Ass.py，为false时使用Danmu2Ass.exe
	use_python = true,
	-- python可执行文件路径，默认为环境变量的python，若无法运行请指定 python[.exe] 的路径
	python_path = "python",
	--直播弹幕轮询 jsonl 的间隔（秒）
	live_interval = "0.1",
	--直播同屏滚动弹幕上限（超出后仍会按行补位，绝不重叠）
	live_max = "40",
	--手动指定直播间号（留空则从播放地址自动识别 live.bilibili.com/<号>）
	live_room = "",
	--直播弹幕读完后是否截断 jsonl（yes=已播弹幕直接删除，不囤积）
	live_trim = "yes",
}

options.read_options(o)

local danmu_file = nil
local danmu_open = false
local sec_sub_visibility = mp.get_property_native("secondary-sub-visibility")
local sec_sub_ass_override = mp.get_property_native("secondary-sub-ass-override")

-- 前向声明：log 在下方才定义，直播分支也要用
local log

-- ============ B站直播实时弹幕 ============
local live_cmd = nil      -- subprocess 句柄（可 abort）
local live_file = nil     -- jsonl 路径
local live_overlay = nil  -- osd overlay
local live_timer = nil    -- 轮询 timer
local live_offset = 0     -- jsonl 已读字节数
local live_items = {}     -- 在屏弹幕列表 {text, ass_color, birth, dur, spd, w, vw, row, y}
local live_rows = {}      -- row -> 该行最后一条弹幕（用于防重叠/追尾）
local live_visible = true
local live_room = nil

local function get_live_room()
	local room = mp.get_opt("live_room")
	if room and room ~= "" then
		local manual = room:match("(%d+)")
		if manual then return manual end
	end
	-- 依次在几个可能保留原始 URL 的属性里找直播间号
	local candidates = {
		mp.get_property("playlist/0/filename"),
		mp.get_property("path"),
		mp.get_property("stream-open-filename"),
		mp.get_property("metadata/by-key/url"),
		mp.get_property("media-title"),
	}
	for _, p in ipairs(candidates) do
		if p then
			local rid = p:match("live%.bilibili%.com/(%d+)")
			if rid then return rid end
		end
	end
	return nil
end

-- Lua 5.1 无 utf8 库，手动数 UTF-8 字符（估算弹幕宽度用）
local function utf8_len(s)
	local _, n = s:gsub("[^\128-\191]", "")
	return n
end

local function live_color_ass(color)
	color = tonumber(color) or 0xffffff
	local r = math.floor(color / 65536) % 256
	local g = math.floor(color / 256) % 256
	local b = color % 256
	return string.format("%02X%02X%02X", b, g, r) -- ASS 是 BGR 序
end

local function live_ass_escape(s)
	-- ASS 里 { } 是特效块，\ 是转义符；弹幕内换行会破坏 overlay 行结构
	s = s:gsub("[\r\n]", " ")
	return s:gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}")
end

-- 透明度 → ASS \alpha 值（&Hxx&，00=不透明，FF=全透明）
local function live_alpha_tag()
	local op = tonumber(o.opacity) or 1
	if op < 0 then op = 0 elseif op > 1 then op = 1 end
	local a = math.floor((1 - op) * 255 + 0.5)
	if a <= 0 then return "" end
	return string.format("\\alpha&H%02X&", a)
end

-- 虚拟画布：高度固定 1080，宽度按视频宽高比推导（与 Danmu2Ass 一致）。
-- overlay 的 res_x/res_y 会成为 ASS PlayResX/PlayResY，libass 会自动缩放到窗口，
-- 因此这里只需按 1080p 坐标计算，无需关心真实 OSD 像素。
local function live_layout()
	local w = mp.get_property_number("width", 0) or 0
	local h = mp.get_property_number("height", 0) or 0
	local aspect = (w > 0 and h > 0) and (w / h) or (16 / 9)
	local vh = 1080
	local vw = math.max(1, math.floor(vh * aspect))
	-- 直接套用点播弹幕的样式：字号、底部留白比例
	local fs = tonumber(o.fontsize) or 50
	local line_h = math.max(1, math.floor(fs * 1.35))
	local pct = tonumber(o.percent) or 0.85
	if pct <= 0 or pct > 1 then pct = 0.85 end
	local max_rows = math.max(1, math.floor(vh * pct / line_h))
	return vw, vh, fs, line_h, max_rows
end

-- 每条弹幕从右边缘 vw 匀速移到左边缘外 -w，用时 dur。
-- 位置只由 birth/spd 推出，渲染与排版共用同一套坐标，避免漂移。
local function live_x(it, now)
	return it.vw - (now - it.birth) * it.spd
end

local function Live_render()
	if not live_overlay then return end
	if not live_visible then
		live_overlay.data = ""
		live_overlay.res_x = 1920
		live_overlay.res_y = 1080
		live_overlay:update()
		return
	end
	local vw, vh, fs, _line_h, max_rows = live_layout()
	local alpha = live_alpha_tag()
	local now = mp.get_time() -- wall clock：平滑且不受直播重连重置 time-pos 影响
	-- 渲染顺带做过期清理：播出过期的当场剔除，不囤积
	local fresh = {}
	for _, it in ipairs(live_items) do
		if now >= it.birth - 1 and now < it.birth + it.dur then
			fresh[#fresh + 1] = it
		end
	end
	live_items = fresh
	local parts = {}
	for _, it in ipairs(live_items) do
		local fz = it.fsize or fs
		if it.fixed then
			-- 顶部/底部固定弹幕：居中静止显示
			parts[#parts + 1] = string.format(
				"{\\an8\\pos(%d,%d)\\fs%d\\bord2%s\\1c&H%s&}%s",
				math.floor(vw / 2), it.y, fz, alpha, it.ass_color, it.text)
		elseif it.row < max_rows then
			local x, show
			if it.spd < 0 then
				-- 逆向滚动：从左边缘外向右走
				x = it.x0 + (now - it.birth) * (-it.spd)
				show = (x <= vw) -- 右边缘还没完全出屏
			else
				x = live_x(it, now)
				show = true
			end
			-- 只做左边界裁剪：右侧刚出生仍在外面的直接交给 libass 裁掉，
			-- 这样弹幕一进屏就是连续的，不会延迟一个 tick 才出现。
			if show and x + it.w >= 0 then
				parts[#parts + 1] = string.format(
					"{\\an7\\pos(%d,%d)\\fs%d\\bord2%s\\1c&H%s&}%s",
					math.floor(x), it.y, fz, alpha, it.ass_color, it.text)
			end
		end
	end
	live_overlay.data = table.concat(parts, "\n")
	live_overlay.res_x = vw   -- 与虚拟画布一致，libass 再缩放到实际窗口
	live_overlay.res_y = vh
	live_overlay:update()
end

local function Live_poll()
	if not live_file then return end
	local f = io.open(live_file, "r")
	if not f then return end
	f:seek("set", live_offset)
	local chunk = f:read("*a")
	f:close()
	if not chunk or chunk == "" then Live_render() return end
	-- 只消费以换行结尾的完整行：写入方可能正写半行，剩下半行留到下个 tick
	local last_nl = chunk:match(".*()\n")
	if not last_nl then Live_render() return end
	local complete = chunk:sub(1, last_nl)
	live_offset = live_offset + last_nl
	-- 已播弹幕直接删除：把未消费的剩余半行回写，其余截掉，防止 jsonl 无限增长。
	-- 注意截断后文件内容就是剩余半行本身，所以偏移必须归零（不能沿用旧偏移，
	-- 否则下次会从半行中间开始读，拼出来的行永远是坏的）。
	if mp.get_opt("live_trim") ~= "no" then
		local rest = chunk:sub(last_nl + 1)
		local wf = io.open(live_file, "w")
		if wf then
			wf:write(rest)
			wf:close()
		end
		live_offset = 0
	end
	local now = mp.get_time() -- wall clock：稳定递增，不受直播流 time-pos 跳变影响
	local vw, _vh, fs, line_h, max_rows = live_layout()
	-- 直接套用点播弹幕的滚动时长，保证观感一致
	local marquee = tonumber(o.duration_marquee) or 10
	if marquee < 1 then marquee = 1 end
	local max_items = tonumber(o.live_max) or 40
	-- 每个弹幕行只记最后一条（用于判断能否再放）
	local function can_place(last, w, spd)
		if not last then return true end
		local px = live_x(last, now)              -- 上一条左边缘
		if px + last.w > vw then return false end -- 还没完全进屏，让一让
		if spd <= last.spd then return true end   -- 不更快就不会追尾
		-- 更快：算追尾时刻，晚于它离屏就安全
		local t_hit = now + (vw - (px + last.w)) / (spd - last.spd)
		return t_hit > last.birth + last.dur
	end
	local function keep_line(line)
		local ok, d = pcall(utils.parse_json, line)
		if ok and d and d.text then
			local label = d.user .. "：" .. d.text
			local dur = marquee
			if d.type == "sc" then
				label = string.format("[SC ¥%s]%s：%s",
					tostring(d.price or "?"), d.user, d.text)
				-- SC 沿用静止弹幕时长（翻倍以示醒目）
				dur = (tonumber(o.duration_still) or 5) * 2
			end
			local w = math.max(40, math.floor(utf8_len(label) * fs * 0.62))
			-- 字号沿用 B站语义（25 为标准），按 Danmu2Ass 规则换算：
			-- mode 4=底部 5=顶部固定，其余为滚动；1=滚动 6=逆向
			local mmode = tonumber(d.mode) or 1
			local ssize = tonumber(d.size) or 25
			local fontsize = math.floor(fs * ssize / 25 + 0.5)
			if mmode == 4 or mmode == 5 then
				-- 底部/顶部固定：y 打在屏上下固定位置，x 居中
				local y = (mmode == 5) and math.floor(fontsize / 2)
					or (1080 - math.floor(fontsize / 2))
				if #live_items >= max_items then
					table.remove(live_items, 1) -- 维持上限：丢最旧的
				end
				live_items[#live_items + 1] = {
					text = live_ass_escape(label),
					ass_color = live_color_ass(d.color),
					birth = now, dur = dur, spd = 0, w = w, vw = vw,
					row = max_rows, y = y, fixed = true,
					fsize = fontsize,
				}
			else
				local spd = (vw + w) / dur
				-- 选一个能放的行；放不下就丢弃（保证不重叠、不追尾）
				local row = nil
				for r = 0, max_rows - 1 do
					if can_place(live_rows[r], w, spd) then row = r break end
				end
				if row ~= nil then
					if #live_items >= max_items then
						table.remove(live_items, 1) -- 维持上限：丢最旧的
					end
					local it = {
						text = live_ass_escape(label),
						ass_color = live_color_ass(d.color),
						birth = now, dur = dur, spd = spd, w = w, vw = vw,
						row = row, y = row * line_h + line_h / 2,
						fsize = fontsize,
					}
					if mmode == 6 then
						-- 逆向滚动：从左向右走
						it.spd = -spd
						it.x0 = -w
					end
					live_rows[row] = it
					live_items[#live_items + 1] = it
				end
			end
		end
	end
	for line in complete:gmatch("[^\r\n]+") do keep_line(line) end
	Live_render()
end

-- 启动直播弹幕：起 live_danmu.py 子进程 + 定时 tail
local function Live_start(room)
	-- 幂等：同一直播间的 file-loaded 可能因流重连重复触发，别反复重启抓取
	if live_room == room and live_timer then return end
	Live_stop()
	live_room = room
	local tmpdir = os.getenv("TEMP") or os.getenv("TMP") or "/tmp/"
	local directory = mp.get_script_directory()
	local py_path = utils.join_path(directory, "live_danmu.py")
	live_file = utils.join_path(tmpdir, "bilibili-live-" .. room .. ".jsonl")
	live_offset = 0
	live_items = {}
	live_rows = {}
	live_visible = true
	live_overlay = mp.create_osd_overlay("ass-events")
	live_cmd = mp.command_native_async({
		name = "subprocess",
		playback_only = false,
		-- 必须捕获 stdout：mpv 持有管道读端，子进程靠写它来探测 mpv 是否已退出，
		-- 从而避免 mpv 被强杀后抓取进程变成孤儿。日志走 stderr，不受影响。
		capture_stdout = true,
		args = { o.python_path, py_path, room, live_file },
	}, function(res, val, err)
		if err ~= nil and err ~= "killed" then
			log("直播弹幕抓取退出: " .. tostring(err))
		end
	end)
	live_timer = mp.add_periodic_timer(
		tonumber(o.live_interval) or 0.1, Live_poll)
	log("直播间 " .. room .. " 实时弹幕已启动，按 b 切换显示")
end

function Live_stop()
	if live_timer then live_timer:kill() live_timer = nil end
	if live_cmd then
		pcall(mp.abort_async_command, live_cmd)
		live_cmd = nil
	end
	if live_overlay then live_overlay:remove() live_overlay = nil end
	-- 切台/结束时把 jsonl 删掉，不留垃圾
	if live_file then
		pcall(os.remove, live_file)
	end
	live_items, live_rows = {}, {}
	live_offset, live_file, live_room = 0, nil, nil
	live_visible = true
end

local function Live_toggle()
	if not live_overlay then return false end
	live_visible = not live_visible
	log(live_visible and "显示直播弹幕" or "隐藏直播弹幕")
	Live_render()
	return true
end
-- ============ 直播部分结束 ============

local function get_cid()
	local cid, danmaku_id = nil, nil
	local tracks = mp.get_property_native("track-list")
	for _, track in ipairs(tracks) do
		if track["lang"] == "danmaku" then
			cid = track["external-filename"]:match("/(%d-)%.xml$")
			danmaku_id = track["id"]
			break
		end
	end
	return cid, danmaku_id
end

local function get_sub_count()
	local count  = 0
	local tracks = mp.get_property_native("track-list")
	for _, track in ipairs(tracks) do
		if track["type"] == "sub" then
			count = count + 1
		end
	end
	return count
end

local function file_exists(path)
	if path then
		local meta = utils.file_info(path)
		return meta and meta.is_file
	end
	return false
end

-- Log function: log to both terminal and MPV OSD (On-Screen Display)
log = function(string, secs)
	mp.msg.info(string)

	if o.log_osd then
		secs = secs or 2.5
		mp.osd_message(string, secs)
	end
end

-- load function
local function load_danmu(file)
	if not file_exists(file) then return end
	mp.set_property_native("secondary-sub-visibility", false)
	mp.set_property_native("secondary-sub-ass-override", false)
	mp.commandv("sub-add", file, "auto")
	local sub_count = get_sub_count()
	mp.set_property_native("secondary-sid", sub_count)
	local approximatedDanmukuCount = math.floor((utils.file_info(file)["size"] - 850) / 120)
	log(file ..
		' [' .. utils.file_info(file)["size"] ..
		'][' .. approximatedDanmukuCount .. ']')
	if o.autoplay and approximatedDanmukuCount >= o.mincount then
		Danmaku_show()
	end
end

-- check if danmaku exists, load if true
local function Danmaku_check()
	-- 直播分支：live.bilibili.com 走实时弹幕
	local room = get_live_room()
	if room then
		Live_start(room)
		return
	end

	local cid = mp.get_opt('cid')

	if cid == nil then
		local path = mp.get_property("path")
		if path and not path:find('^%a[%w.+-]-://') and not (path:find('bilibili.com') or path:find('bilivideo.com')) then
			return
		end

		local danmaku_id = nil
		cid, danmaku_id = get_cid()

		if danmaku_id ~= nil then
			mp.commandv('sub-remove', danmaku_id)
		end
	end

	mp.set_property_native("sid", false)

	Danmaku_process(cid)
end

-- call Danmu2Ass executable
function Danmaku_process(cid)
	if cid == nil then return end

	-- get danmaku directory
	local danmaku_dir = os.getenv("TEMP") or "/tmp/"
	-- get script directory
	local directory = mp.get_script_directory()
	local py_path = utils.join_path(directory, 'Danmu2Ass.py')
	local exe_path = utils.join_path(directory, 'Danmu2Ass.exe')

	-- no need to convert forwardslashes and backslashes

	local dw = 1920
	local dh = 1080
	local aspect = mp.get_property_number('width', 16) / mp.get_property_number('height', 9)
	if aspect > dw / dh then
		dh = math.floor(dw / aspect)
	elseif aspect < dw / dh then
		dw = math.floor(dh * aspect)
	end
	-- choose to use python or .exe
	local arg = nil
	if o.use_python then
		arg = {
			o.python_path, py_path,
			'-d', danmaku_dir,
			'-s', '' .. dw .. 'x' .. dh,
			'-fn', o.fontname,
			'-fs', o.fontsize,
			'-a', o.opacity,
			'-dm', o.duration_marquee,
			'-ds', o.duration_still,
			'-flf', mp.command_native({ "expand-path", o.filter_file }),
			'-p', tostring(math.floor(o.percent * dh)),
			'-r', cid,
		}
	else
		arg = {
			exe_path,
			'-d', danmaku_dir,
			'-s', '' .. dw .. 'x' .. dh,
			'-fn', o.fontname,
			'-fs', o.fontsize,
			'-a', o.opacity,
			'-dm', o.duration_marquee,
			'-ds', o.duration_still,
			'-flf', mp.command_native({ "expand-path", o.filter_file }),
			'-p', tostring(math.floor(o.percent * dh)),
			'-r', cid,
		}
	end

	-- run python to get comments
	mp.command_native_async({
		name = 'subprocess',
		playback_only = false,
		capture_stdout = true,
		args = arg,
	}, function(res, val, err)
		if err == nil
		then
			danmu_file = utils.join_path(danmaku_dir, 'bilibili.ass')
			load_danmu(danmu_file)
		else
			log("处理错误: " .. err)
		end
	end)
end

-- toggle danmaku visibility
function Danmaku_toggle()
	if Live_toggle() then return end -- 直播模式优先处理
	if not danmu_file then return end

	if danmu_open then
		Danmaku_unshow()
	elseif mp.get_property_native('secondary-sid') then
		Danmaku_show()
	end
end

-- remove danmaku
function Danmaku_terminate()
	Live_stop() -- 直播模式：杀子进程、清 overlay、删 jsonl，无 danmu_file 也要执行
	if not danmu_file then return end
	log('文件结束')
	if file_exists(danmu_file) then
		os.remove(danmu_file)
	end
	danmu_file = nil
	danmu_open = false
	mp.set_property_native("secondary-sub-visibility", sec_sub_visibility)
	mp.set_property_native("secondary-sub-ass-override", sec_sub_ass_override)
	mp.commandv('vf', 'remove', '@Danmaku-FPS')
end

-- hide danmaku
function Danmaku_unshow()
	log('隐藏弹幕')
	danmu_open = false
	mp.set_property_native("secondary-sub-visibility", false)
	mp.commandv('vf', 'remove', '@Danmaku-FPS')
end

-- show danmaku
function Danmaku_show()
	log('显示弹幕')
	danmu_open = true
	mp.set_property_native("secondary-sub-visibility", true)
	Add_fps_vf()
end

function Add_fps_vf()
	if not danmu_open or not o.fps_vf then return end

	local video_fps = mp.get_property_number("container-fps", 30)
	local video_speed = mp.get_property_number("speed", 1)

	if video_fps < 45 and video_speed < 1.5 then
		mp.commandv('vf', 'append', '@Danmaku-FPS:lavfi="fps=fps=60:round=down"')
	else
		mp.commandv('vf', 'remove', '@Danmaku-FPS')
	end
end

mp.register_event("file-loaded", Danmaku_check)
mp.register_event("end-file", Danmaku_terminate)
mp.observe_property("speed", nil, Add_fps_vf)

mp.register_script_message('load-danmaku', Danmaku_process)
mp.add_key_binding('b', 'toggle', Danmaku_toggle)
