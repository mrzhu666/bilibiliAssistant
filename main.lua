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
	--直播弹幕【重绘】间隔（秒）。决定顺滑度，与收取无关。
	--为什么不用 observe_property("time-pos")：mpv 的属性变更事件是 coalesced 的
	--（见手册 "Property changes are coalesced"），实测会隔帧丢事件（mpv#4195
	-- 有日志：every second frame / 3-5 帧的空洞），重绘反而不规律。
	--定时器由事件循环按截止时间触发，播放时循环被视频帧唤醒，10ms 约等于
	--"每帧一次"，这也是 uosc_danmaku 等实现采用的方式。
	live_interval = "0.01",
	--直播弹幕【收取】间隔（秒），只负责读 jsonl，与流畅度无关
	live_ingest = "0.2",
	--直播同屏弹幕上限（防超高密度房间让每帧拼串开销失控）
	live_max = "60",
	--是否启用直播弹幕（播放 live.bilibili.com 时生效）
	live_enable = "yes",
	--手动指定直播间号（留空则从播放地址自动识别 live.bilibili.com/<号>）
	live_room = "",
	--直播弹幕读完后是否截断 jsonl（yes=已播弹幕直接删除，不囤积）
	live_trim = "yes",
	--弹幕前缀处理：截断到第一个冒号，即去掉"用户名："前缀。
	--no=完全不处理（保留完整"用户名：内容"）
	--trim=截断到第一个冒号（默认）
	--trim_keep=截断但保留用户名（显示为"用户名 内容"）
	live_prefix = "trim",
	--前缀截断后又空了的弹幕是否丢弃（yes=丢弃该条 / no=保留原文）
	live_prefix_drop_empty = "yes",
	--弹幕描边色：default(默认，不覆盖，继承 mpv 的 osd-outline-color 白边)
	--black / white / RRGGBB 可显式指定；想让彩色弹幕更清爽可设 black
	live_outline_color = "default",
	--彩色弹幕调暗系数(0.3-1.0，1=不调)。黄/蓝等饱和色发亮刺眼时调低即可。
	--只作用于彩色弹幕，默认白字(FFFFFF)与黑字不受影响。
	live_color_dim = "0.75",
}

options.read_options(o)

local danmu_file = nil
local danmu_open = false
local sec_sub_visibility = mp.get_property_native("secondary-sub-visibility")
local sec_sub_ass_override = mp.get_property_native("secondary-sub-ass-override")

-- 前向声明：log 在下方才定义，直播分支也要用
local log
-- 前向声明：提帧函数定义在下方（点播部分），直播分支也要复用
local Add_fps_vf

-- ============ B站直播实时弹幕 ============
-- 显示规则严格对齐点播 Danmu2Ass，保证与点播弹幕长得一样、动得一样：
--   1) PlayRes 按视频宽高比推导（与 main.lua 传给 -s 的 dw x dh 同一算法）
--   2) percent 语义完全相同：bottomReserved = percent * dh，弹幕只排上方 dh 以内
--   3) 4 条通道（0 滚动 / 1 顶部固定 / 2 底部固定 / 3 逆向滚动）+ 像素行占用 +
--      追尾判定，等价于 TestFreeRows / MarkCommentRow
--   4) 字号沿用 B站语义（25 为标准）：fsize = fontsize * size / 25
-- 为什么不能用 \move：osd-overlay 的 event 时间被 mpv 写死
-- （sub/osd_libass.c: event->Start=0; event->Duration=100; 且渲染恒为
-- ass_render_frame(..., ts=0, ...)），所以 Start/End / \move 都不生效，
-- 位置只能在 Lua 侧算好再用 \pos 出来。
--
-- 为什么逐帧重绘不额外费性能：mpv 本来就是每显示一帧就对 OSD overlay
-- 重新跑一遍 libass（osd_object_get_bitmaps → append_ass），我们更新 data
-- 不增加 libass 渲染次数，只多一点拼字符串。因此这里挂 time-pos 让视频帧
-- 驱动重绘：视频出帧才重画，既不空转，又是帧级精确（等同点播 \move 的手感）。
local live_cmd = nil      -- subprocess 句柄（可 abort）
local live_file = nil     -- jsonl 路径
local live_overlay = nil  -- osd overlay
local live_timer = nil    -- 收取 jsonl 的定时器（与流畅度无关）
local live_rtimer = nil   -- 重绘定时器（决定顺滑度）
local live_offset = 0     -- jsonl 已读字节数
local live_items = {}     -- 在屏弹幕
local live_chan = {}      -- 通道占用表：live_chan[ch][pixel_row] = occ
local live_visible = true
local live_room = nil
local live_danmu_open = false -- 直播弹幕是否处于开启状态（供 Add_fps_vf 判断）

local function get_live_room()
	if o.live_enable ~= "yes" then return nil end
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

-- Lua 5.1 无 utf8 库，手动数 UTF-8 字符（等价 Danmu2Ass 的 CalculateLength）
local function utf8_len(s)
	local _, n = s:gsub("[^\128-\191]", "")
	return n
end

-- 与 Danmu2Ass ConvertColor 逐字一致。
-- 注意：返回值本身就是 ASS 的 &HBBGGRR& 顺序（即 BT.601→BT.709 矩阵输出的
-- 三行依次填入 BB/GG/RR），不要再自行换序，否则颜色会整体错位。
-- 小画布(width<1280 且 height<576)时段点播走的是不做矩阵的直通分支，
-- 这里同样保留，保证与点播一致。
local function live_convert_color(rgb, width, height)
	local r = math.floor(rgb / 65536) % 256
	local g = math.floor(rgb / 256) % 256
	local b = rgb % 256
	if width < 1280 and height < 576 then
		return string.format("%02X%02X%02X", b, g, r)
	end
	local function clip(x)
		if x > 255 then return 255 elseif x < 0 then return 0 end
		return math.floor(x + 0.5)
	end
	return string.format("%02X%02X%02X",
		clip(r * 0.00956384088080656 + g * 0.03217254540203729
			+ b * 0.95826361371715607),
		clip(r * -0.10493933142075390 + g * 1.17231478191855154
			+ b * -0.06737545049779757),
		clip(r * 0.91348912373987645 + g * 0.07858536372532510
			+ b * 0.00792551253479842))
end

local function live_ass_escape(s)
	-- 换行会破坏 overlay 的“一行一条”结构，先压平
	s = s:gsub("[\r\n]", " ")
	return s:gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}")
end

-- 字体名转 ASS（与点播一样用 fontname；逗号前截断防注入）
local function live_font_tag()
	local fn = tostring(o.fontname or "sans-serif"):match("^[^,]*") or "sans-serif"
	fn = fn:gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}")
	return "\\fn" .. fn
end

-- 透明度 → ASS \alpha（&Hxx&，00=不透明，FF=全透明）
local function live_alpha_tag()
	local op = tonumber(o.opacity) or 1
	if op < 0 then op = 0 elseif op > 1 then op = 1 end
	local a = math.floor((1 - op) * 255 + 0.5)
	if a <= 0 then return "" end
	return string.format("\\alpha&H%02X&", a)
end

-- 画布与点播一致：PlayRes 按视频宽高比推导；bottomReserved = percent * dh。
-- overlay 的 res_x/res_y 即 PlayResX/PlayResY，libass 负责缩放到实际窗口。
local function live_layout()
	local w = mp.get_property_number("width", 0) or 0
	local h = mp.get_property_number("height", 0) or 0
	local dw, dh = 1920, 1080
	if w > 0 and h > 0 then
		local aspect = w / h
		if aspect > dw / dh then
			dh = math.floor(dw / aspect)
		elseif aspect < dw / dh then
			dw = math.floor(dh * aspect)
		end
	end
	local fs = tonumber(o.fontsize) or 50
	local pct = tonumber(o.percent) or 0.75
	if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
	local bottom_reserved = math.floor(pct * dh)
	local area_bottom = dh - bottom_reserved -- 弹幕可用区域下边界（像素）
	return dw, dh, fs, bottom_reserved, area_bottom
end

-- 弹幕文本预处理：默认截断到第一个冒号，即去掉 "用户名：" 这类前缀。
-- live_prefix 取值：
--   no         完全不处理（保留完整"用户名：内容"）
--   trim       截断到第一个冒号（默认）
--   trim_keep  截断但保留用户名，显示为"用户名 内容"
-- 返回处理后的文本；若截断后为空则按 live_prefix_drop_empty 决定丢弃或保留原文。
-- 注意：不能用 [：:] 字符类——Lua 的字符类是逐字节的，全角「：」占 3 字节，
-- 会被拆成三个单字节分别匹配，从而从字符中间切断。必须用 plain 查找。
-- 半角 ":" 与全角 "：" 都算；URL 协议头（http://）的冒号不当分隔符。
local function live_preprocess(text, user)
	local mode = tostring(o.live_prefix or "trim")
	if mode == "no" then return user .. "：" .. text end
	local label = user .. "：" .. text
	local hs = label:find(":", 1, true)  -- 半角
	local fs = label:find("：", 1, true) -- 全角（plain：按整串精确匹配）
	local pos, clen
	if hs and fs then
		if hs < fs then pos, clen = hs, 1 else pos, clen = fs, #"：" end
	elseif hs then
		pos, clen = hs, 1
	elseif fs then
		pos, clen = fs, #"："
	else
		return label -- 没有冒号，原样
	end
	local head = label:sub(1, pos - 1)
	local after = label:sub(pos + clen)
	-- 形如 http:// / https:// 的协议头，保留原样
	if head:match("^%a[%w+.-]*$") and after:sub(1, 2) == "//" then
		return label
	end
	local rest = after:gsub("^%s+", "")
	if rest == "" then
		if tostring(o.live_prefix_drop_empty) == "no" then
			return head -- 保留原文（至少还有用户名）
		end
		return nil -- 丢弃该条
	end
	if mode == "trim_keep" then
		return head .. " " .. rest
	end
	return rest
end

-- 通道占用项：{T=出生毫秒, len=像素长度, fixed=是否固定, dur=自身显示时长}
-- 判空完全按 TestFreeRows：
--   固定：上一条显示结束本行才空（t - T >= duration_still）
--   滚动：t - T >= duration_marquee * L / (L + W)，L = max(本条, 上一条) 长度，
--         一条式子同时覆盖“上一条已完全进屏”和“这条追不上上一条”
local function live_occ_free(occ, t, dur_ms, new_len, W, still_ms)
	if not occ then return true end
	if occ.fixed then return (t - occ.T) >= still_ms end
	local L = new_len > occ.len and new_len or occ.len
	return (t - occ.T) >= dur_ms * L / (L + W)
end

local function live_find_row(ch, h, t, dur_ms, new_len, W, area_bottom, still_ms, fixed)
	if not live_chan[ch] then live_chan[ch] = {} end
	local arr = live_chan[ch]
	local nrow = math.ceil(h)
	local row = 0
	while row + nrow <= area_bottom do
		local ok = true
		for r = row, row + nrow - 1 do
			if not live_occ_free(arr[r], t, dur_ms, new_len, W, still_ms) then
				ok = false
				break
			end
		end
		if ok then return row end
		row = row + 1
	end
	return nil
end

local function live_mark_row(ch, row, h, occ)
	if not live_chan[ch] then live_chan[ch] = {} end
	local arr = live_chan[ch]
	for i = row, row + math.ceil(h) - 1 do
		arr[i] = occ
	end
end

-- 清掉“整条早就放完”的占用项，避免占用表无限增长
local function live_sweep(t)
	for ch = 0, 3 do
		local arr = live_chan[ch]
		if arr then
			for r, occ in pairs(arr) do
				if (t - occ.T) >= occ.dur then arr[r] = nil end
			end
		end
	end
end

-- 单条弹幕的当前横坐标（毫秒整数推进，避免浮点漂移）
local function live_pos_x(it, now_ms)
	return it.x1 + (it.x2 - it.x1) * (now_ms - it.born_ms) / it.dur_ms
end

-- 弹幕文字色 / 描边色 → ASS 颜色标签。
-- 描边默认 "default"：不输出 \3c，直接继承 mpv 的 OSD 样式
-- （即 mpv.conf 的 osd-outline-color，本机为近白 #EEEEEE），保持原生观感。
-- 若想让彩色弹幕更清爽，可设 live_outline_color=black（点播 Danmu2Ass 即黑边）。
-- live_outline_color: default / black / white / RRGGBB
local function live_outline_color_ass()
	local v = tostring(o.live_outline_color or "default"):lower()
	if v == "default" or v == "" then return nil end
	if v == "white" then return "FFFFFF" end
	if v == "black" then return "000000" end
	-- 允许写 RRGGBB，转成 ASS 的 BGR 序
	local r, g, b = v:match("^(%x%x)(%x%x)(%x%x)$")
	if r then return (b .. g .. r):upper() end
	return nil
end

-- 文字色(ASS BGR) + 描边色 → 颜色标签串。
-- 白色是"默认色"，Danmu2Ass 会跳过它不输出 \c；这里保持一致。
-- 黑字特例：补白边，否则在黑底上看不见（同 WriteComment）。
local function live_color_tag(color)
	local out = ""
	if color ~= "FFFFFF" then
		out = "\\c&H" .. color .. "&"
	end
	if color == "000000" then
		return out .. "\\3c&HFFFFFF&"
	end
	local oc = live_outline_color_ass()
	if oc then
		out = out .. "\\3c&H" .. oc .. "&"
	end
	return out
end

-- 弹幕颜色调暗：只作用于彩色弹幕，默认白字(FFFFFF)保持不变。
-- 用于黄/蓝等饱和色在亮背景上过于刺眼时。factor 为 RGB 等比缩放系数。
local function live_dim_color(color, factor)
	if factor >= 1 then return color end
	if color == "FFFFFF" then return color end -- 默认色不动
	-- color 是 ASS 的 BGR 序
	local b = tonumber(color:sub(1, 2), 16) or 255
	local g = tonumber(color:sub(3, 4), 16) or 255
	local r = tonumber(color:sub(5, 6), 16) or 255
	local function sc(v) return math.floor(v * factor + 0.5) end
	return string.format("%02X%02X%02X", sc(b), sc(g), sc(r))
end

local function live_emit(parts, it, W, now_ms, font_tag, alpha, outline)
	local style = string.format("%s\\fs%d\\b1\\bord%.0f\\shad0\\q2%s%s",
		font_tag, it.fsize, outline, alpha, it.color_tag)
	if it.fixed then
		parts[#parts + 1] = string.format("{\\an%d\\pos(%d,%d)%s}%s",
			it.an, math.floor(W / 2), it.y, style, it.text)
	else
		local x = math.floor(live_pos_x(it, now_ms))
		if x + it.w >= 0 then -- 左边界裁剪；右侧出屏部分交给 libass 裁掉
			parts[#parts + 1] = string.format("{\\an7\\pos(%d,%d)%s}%s",
				x, it.y, style, it.text)
		end
	end
end

local function Live_render()
	if not live_overlay then return end
	local dw, dh, fs = live_layout()
	if not live_visible then
		live_overlay.data = ""
		live_overlay.res_x = dw
		live_overlay.res_y = dh
		live_overlay:update()
		return
	end
	local font_tag = live_font_tag()
	local alpha = live_alpha_tag()
	local outline = math.max(fs / 25, 1) -- 同 WriteASSHead 的 outline
	local now_ms = math.floor(mp.get_time() * 1000 + 0.5)
	local live_max_items = tonumber(o.live_max) or 60
	if live_max_items < 1 then live_max_items = 1 end
	-- 过期清理 + 拼接本帧所有应显示的弹幕
	local fresh, parts = {}, {}
	for _, it in ipairs(live_items) do
		if now_ms < it.end_ms then
			fresh[#fresh + 1] = it
			live_emit(parts, it, dw, now_ms, font_tag, alpha, outline)
		end
	end
	-- 同屏上限：只保留最新的 N 条（旧弹幕已显示过，丢的是寿命尾段）。
	-- 必须在此裁剪，否则超高密度房间里每帧拼串量会失控。
	if #fresh > live_max_items then
		local drop = #fresh - live_max_items
		for i = 1, drop do table.remove(fresh, 1) end
		parts = {}
		for _, it in ipairs(fresh) do
			live_emit(parts, it, dw, now_ms, font_tag, alpha, outline)
		end
	end
	live_items = fresh
	live_overlay.data = table.concat(parts, "\n")
	live_overlay.res_x = dw
	live_overlay.res_y = dh
	live_overlay:update()
end

-- 重绘定时器回调：高频（默认 10ms）推进坐标。
-- 没有在屏弹幕时直接跳过，空闲不花任何 CPU 也不刷屏。
local live_fps_tick = 0
local function live_render_tick()
	if not live_overlay or not live_visible then return end
	if #live_items == 0 then return end
	-- 顺带低频重估提帧（直播流帧率可能中途变化；10ms 一次评估太浪费）
	live_fps_tick = live_fps_tick + 1
	if live_fps_tick >= 100 then
		live_fps_tick = 0
		Add_fps_vf()
	end
	Live_render()
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
	-- 截断后文件内容就是剩余半行本身，所以偏移必须归零，否则下次会从半行
	-- 中间开始读，拼出来的行永远是坏的。
	if mp.get_opt("live_trim") ~= "no" then
		local rest = chunk:sub(last_nl + 1)
		local wf = io.open(live_file, "w")
		if wf then
			wf:write(rest)
			wf:close()
		end
		live_offset = 0
	end
	local dw, dh, fs, _br, area_bottom = live_layout()
	local W = dw
	local marquee_ms = (tonumber(o.duration_marquee) or 10) * 1000
	if marquee_ms < 1000 then marquee_ms = 1000 end
	local still_ms = (tonumber(o.duration_still) or 5) * 1000
	if still_ms < 1000 then still_ms = 1000 end
	local now_ms = math.floor(mp.get_time() * 1000 + 0.5)
	live_sweep(now_ms)
	local MODE2CH = { [1] = 0, [4] = 2, [5] = 1, [6] = 3 }
	local function keep_line(line)
		local ok, d = pcall(utils.parse_json, line)
		if not (ok and d and d.text) then return end
		-- 预处理：默认截断到第一个冒号，去掉"用户名："前缀
		local label = live_preprocess(d.text, d.user)
		if not label then return end
		local dur_ms = marquee_ms
		if d.type == "sc" then
			-- SC 借用静止时长翻倍，醒目
			label = string.format("[SC ¥%s]%s", tostring(d.price or "?"), label)
			dur_ms = still_ms * 2
		end
		local ch = MODE2CH[tonumber(d.mode) or 1] or 0
		local ssize = tonumber(d.size) or 25
		local fsize = math.floor(fs * ssize / 25 + 0.5)
		local w = utf8_len(label) * fsize -- 等价 CalculateLength(c) * size
		local text = live_ass_escape(label)
		local color = live_convert_color(tonumber(d.color) or 0xffffff, dw, dh)
		local dim = tonumber(o.live_color_dim) or 1
		if dim > 0 and dim < 1 then color = live_dim_color(color, dim) end
		local color_tag = live_color_tag(color)
		local h = fsize -- 单行弹幕高度
		if ch == 1 or ch == 2 then
			local row = live_find_row(ch, h, now_ms, marquee_ms, w, W,
				area_bottom, still_ms, true)
			if row == nil then return end -- 排不下就丢弃，保证不重叠
			local y = (ch == 1) and row or (area_bottom - row) -- an8 顶 / an2 底
			live_mark_row(ch, row, h,
				{ T = now_ms, len = w, fixed = true, dur = dur_ms })
			live_items[#live_items + 1] = {
				text = text, color_tag = color_tag, fsize = fsize,
				an = (ch == 1) and 8 or 2, y = y, w = w, fixed = true,
				born_ms = now_ms, dur_ms = dur_ms, end_ms = now_ms + dur_ms,
			}
		else
			local reverse = (ch == 3)
			-- 正向 W→-w，逆向 -w→W（对应 WriteComment 的 \move 起点终点）
			local x1 = reverse and -w or W
			local x2 = reverse and W or -w
			local row = live_find_row(ch, h, now_ms, marquee_ms, w, W,
				area_bottom, still_ms, false)
			if row == nil then return end
			live_mark_row(ch, row, h,
				{ T = now_ms, len = w, fixed = false, dur = dur_ms })
			live_items[#live_items + 1] = {
				text = text, color_tag = color_tag, fsize = fsize,
				x1 = x1, x2 = x2, y = row, w = w,
				born_ms = now_ms, dur_ms = dur_ms, end_ms = now_ms + dur_ms,
			}
		end
	end
	for line in complete:gmatch("[^\r\n]+") do keep_line(line) end
	-- 这里补一次渲染，保证视频暂停时新弹幕也能立刻出现（重绘定时器照跑）
	if #live_items > 0 then Live_render() end
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
	live_chan = {}
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
		tonumber(o.live_ingest) or 0.2, Live_poll)
	-- 重绘定时器：顺滑度就靠它（10ms 约等于每帧一次）
	live_rtimer = mp.add_periodic_timer(
		tonumber(o.live_interval) or 0.01, live_render_tick)
	-- 提帧：直播流常见 30fps，画面本身只有 30Hz，“弹幕再顺”也会被画面拖住。
	-- 复用点播那套 fps_vf（<45fps 自动 fps=60），这是插件本来就有的一致性做法。
	live_danmu_open = true
	Add_fps_vf()
	log("直播间 " .. room .. " 实时弹幕已启动，按 b 切换显示")
end

function Live_stop()
	if live_timer then live_timer:kill() live_timer = nil end
	if live_rtimer then live_rtimer:kill() live_rtimer = nil end
	if live_cmd then
		pcall(mp.abort_async_command, live_cmd)
		live_cmd = nil
	end
	if live_overlay then live_overlay:remove() live_overlay = nil end
	-- 切台/结束时把 jsonl 删掉，不留垃圾
	if live_file then
		pcall(os.remove, live_file)
	end
	live_items, live_chan = {}, {}
	live_offset, live_file, live_room = 0, nil, nil
	live_visible = true
	live_danmu_open = false
	Add_fps_vf() -- 直播结束，撤掉可能加上的提帧滤镜
end

local function Live_toggle()
	if not live_overlay then return false end
	live_visible = not live_visible
	-- 隐藏时不必白刷 overlay，也让提帧滤镜能跟着撤掉
	live_danmu_open = live_visible
	if live_visible then Add_fps_vf() end
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

Add_fps_vf = function()
	-- 点播与直播任一在显示，都需要提帧保证弹幕顺滑
	if not (danmu_open or live_danmu_open) or not o.fps_vf then return end

	-- 直播流有时拿不到 container-fps，用 estimated-vf-fps 兜底
	local video_fps = mp.get_property_number("container-fps", 0) or 0
	if video_fps <= 0 then
		video_fps = mp.get_property_number("estimated-vf-fps", 0) or 0
	end
	local video_speed = mp.get_property_number("speed", 1)

	-- 拿不到帧率时不加滤镜（宁可不加，也不要误判成低帧率）
	if video_fps > 0 and video_fps < 45 and video_speed < 1.5 then
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
