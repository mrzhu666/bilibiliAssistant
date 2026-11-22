-- https://github.com/itKelis/MPV-Play-BiliBili-Comments

local mp = require 'mp'
local utils = require 'mp.utils'
local options = require 'mp.options'

local o = {
	--是否自动显示弹幕
	autoplay = true,
	--最小弹幕数量
	mincount = 1,
	--弹幕字体。留默认 "sans-serif" 时自动跟随 mpv 的 --sub-font，
	--这样直播弹幕与点播 ASS 弹幕落在同一字体（点播的中文字形就是回退到 sub-font 的）。
	--显式填字体名则两边都用它。
	fontname = "sans-serif",
	--弹幕字体大小
	fontsize = "50",
	--弹幕不透明度(0-1)
	opacity = "0.95",
	--滚动弹幕显示的持续时间 (秒)【旧参数】。speed 生效时本项只做兜底。
	duration_marquee = "10",
	--滚动弹幕速度（单位：屏幕宽度/秒，0 或留空 = 关闭，改用 duration_marquee）。
	--这是把"持续秒数"换成"速度"后的新参数：所有滚动弹幕速度相同，
	--更长的那条自然在屏上待得更久（时长 = (屏宽+文字宽)/速度），不会越长的越快。
	--例：0.1 ≈ 10 秒穿过一屏（按弹幕自身宽度会略长）；0.2 = 两倍速。
	--直播与点播（Danmu2Ass.py -sp）共用此参数。
	speed = "",
	--静止弹幕显示的持续时间 (秒)
	duration_still = "5",
	--滚动弹幕区以下保留的比例 (0.0-1.0)：滚动区 = 顶部 (1 - percent) * 舞台高。
	--0.85 → 滚动弹幕只用上方 15%（与旧行为一致）。注意这里就是「底部留白比例」，
	--不是「弹幕区下边界」；固定弹幕区另由 live_fixed_percent 控制，不受它影响。
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
	--弹幕描边色：black(默认，与点播 Danmu2Ass 一致)
	--default=显式继承 mpv OSD 描边色（旧行为，紫字白边就是这么来的，仅作对比用）
	--white / RRGGBB 也可显式指定
	live_outline_color = "black",
	--彩色弹幕调暗系数(0.3-1.0，1=不调)。黄/蓝等饱和色发亮刺眼时调低即可。
	--只作用于彩色弹幕，默认白字(FFFFFF)与黑字不受影响。
	live_color_dim = "0.75",
	--SC（醒目留言）显示方式：top(默认，顶部固定弹幕) / scroll(旧行为，滚动)
	--B站网页播放器把 SC 钉在顶部固定位置停留，而不是让它飘过去；
	--固定显示也便于读完整条内容（SC 往往很长，滚动会来不及看）。
	live_sc_mode = "top",
	--SC 停留秒数（仅 live_sc_mode=top 生效）。0 或留空 = 用 duration_still * 2。
	live_sc_dur = "",
	--固定弹幕区高度（从舞台顶部算起，占整屏高度的比例 0-1，默认 0.3）。
	--固定弹幕（mode4 底部 / mode5 顶部 / SC / 聚合弹幕）共用这一块：顶部锚定从
	--区顶往下排，底部锚定从区底往上排，固定弹幕之间共用一张占用表，所以互不叠字。
	--注意它与滚动区【重叠】（0 ~ 滚动区下边界 这段两块都有）：固定弹幕和滚动弹幕
	--是两套独立通道，互不避让，和 B站 / Danmu2Ass 的分层行为一致。
	live_fixed_percent = "0.3",
	--重复弹幕聚合（防刷屏）：同一条内容短时间内反复出现时，只保留一个顶部固定
	--弹幕并在后面拼 " ×N"，N 原地增长，不再占新的行。
	--行为对齐 B站服务端 DANMU_AGGREGATION（msg + aggregation_num）的语义。
	live_merge = "yes",
	--聚合统计窗口 / 固定弹幕残留时间（秒）：同一内容间隔超过它就算新的一轮；
	--最后一次出现后也保留这么久，然后消失、计数清零。
	live_merge_hold = "4",
	--累计到第几条才折叠（前面的仍按普通滚动弹幕显示，保证单条观感不变）
	live_merge_min = "2",
	--同屏最多几条聚合弹幕（固定区不够时自动收敛；满了淘汰最久没更新的）
	live_merge_max = "10",
	--显示文本超过该字数不参与聚合（0 = 不限）
	live_merge_maxlen = "30",
	--直播自动重连：掉线 / 卡顿自愈。详见下方「直播自动重连」小节
	live_reconnect = "yes",
	--判定“卡顿”的阈值：paused-for-cache 持续多少秒就重载换线路
	live_stall_sec = "2",
	--time-pos 冻结多少秒判定为卡死。
	--实测断流后 mpv 会有一段“僵死期”：idle-active 仍是 no、playlist-pos 仍是 0、
	--eof-reached 仍是 no，只有 time-pos 完全冻结（本地实测持续 30 秒以上才转
	--idle）。这段期间用户看到的就是画面卡住，所以必须靠它尽早发现并换线。
	--默认 8 秒：兼顾“别把 HLS 分片边界的短暂停滞误判”和“别让用户干等”。
	live_freeze_sec = "8",
	--两次自动重载的最小间隔（秒），防重载风暴
	live_cooldown = "20",
	--熔断窗口（秒）内最多自动重载几次，超过即停止尝试并提示
	live_max_reload = "4",
	--开播 / 重载后多少秒内不自动动作，避开初始缓冲。
	--注意：这个宽限期只影响“卡顿/卡死”判据；已经掉回 idle 的终态恢复不受它限制。
	--默认 8 秒：够等 yt-dlp 解析 + 首帧出图，又不至于让真断流白等太久。
	live_start_delay = "8",
	--断线等待重连时，轮询直播间状态的间隔（秒）
	live_rewait_sec = "30",
}

options.read_options(o, "bilibiliAssistant")

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
--   2) percent 语义与点播 -p 完全相同：底部保留 percent * dh，滚动弹幕只排上方
--      (1 - percent) * dh（默认 0.85 → 顶部 15%），与旧行为一致
--   3) 固定弹幕（mode4/5、SC、聚合弹幕）单独占用「固定区」：同样从舞台顶部算起，
--      高度 live_fixed_percent * dh（默认 30%）。它与滚动区是重叠的（固定弹幕和
--      滚动弹幕是两套独立通道，互不避让，同 Danmu2Ass 的多通道行为）；顶部锚定
--      从区顶往下、底部锚定从区底往上，固定弹幕之间共用一张按舞台绝对行索引的
--      占用表，所以固定弹幕彼此不重叠
--   4) 滚动通道 2 条（0 正向 / 3 逆向），固定弹幕共用一张按舞台绝对行索引的
--      占用表 + 像素行占用 + 追尾判定，等价于 TestFreeRows / MarkCommentRow
--   5) 字号沿用 B站语义（25 为标准）：fsize = fontsize * size / 25
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
local live_chan = {}      -- 滚动通道占用表：live_chan[ch][row] = occ（ch 0/3）
local live_fixed = {}     -- 固定区占用表：live_fixed[舞台绝对行] = occ（两个方向共用）
local live_agg = {}       -- 重复弹幕聚合组：显示文本 -> {count, last_seen, item, ...}
local live_visible = true
local live_room = nil
local live_danmu_open = false -- 直播弹幕是否处于开启状态（供 Add_fps_vf 判断）

-- 从可能保留原始 URL 的属性里识别直播间号。
-- 不依赖 live_enable：自动重连要能在“关掉直播弹幕但保留重连”时独立判断。
-- 注意：这里必须用 read_options 读出来的 o.live_room，不能用 mp.get_opt("live_room")——
-- mp.get_opt 查的是 script-opts 里的原始键名，而实际键名是 "bilibiliAssistant-live_room"，
-- 所以 mp.get_opt 永远返回 nil（手填房间号会静默失效）。
local function live_room_from_url()
	local room = tostring(o.live_room or "")
	if room ~= "" then
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

local function get_live_room()
	if o.live_enable ~= "yes" then return nil end
	return live_room_from_url()
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

-- 字体名转 ASS。
--
-- 与点播对齐的关键：点播 ASS 的 Style Fontname 写的是 o.fontname（默认 sans-serif），
-- 拉丁字形由 libass 解析成 Arial，而**中文字形 libass 里没有**，于是回退到
-- mpv 传给 ass_set_fonts 的 default font —— 也就是 --sub-font（本机
-- "LXGW WenKai Mono Lite" 楷体）。真机日志：
--   [sub/ass] fontselect: (sans-serif, 700, 0) -> Arial-BoldMT
--   [sub/ass] Using default font family: -> LXGWWenKaiMonoLite-Regular
--
-- 直播 overlay 走的是 OSD 字体链，同样的回退目标是 --osd-font（默认 sans-serif
-- → 微软雅黑），于是中文变成了黑体，与点播的楷体观感完全不同：
--   [osd/libass] fontselect: (sans-serif, 700, 0) -> MicrosoftYaHeiUI-Bold
--
-- 所以这里在 o.fontname 保持默认 sans-serif 时改用 --sub-font，让两条链路
-- 落到同一个字体；用户显式配了 fontname 则尊重用户配置。
local function live_font_tag()
	local fn = tostring(o.fontname or "sans-serif"):match("^[^,]*") or "sans-serif"
	if fn == "sans-serif" then
		local sf = mp.get_property("sub-font")
		if type(sf) == "string" and sf ~= "" then fn = sf end
	end
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

-- 画布与点播 ASS 完全等价，但输出坐标改为「屏幕像素」，这样窗口怎么缩放都不跑偏：
--   * 内部坐标（下称 U）沿用 Danmu2Ass 的舞台尺寸：16:9 → 1920x1080，
--     其它比例按 Danmaku_process 的同一条规则推（4:3 → 1440x1080，21:9 → 1920x823）
--   * 渲染时按「视频显示矩形」缩放：1 U = 视频显示高 / 舞台高 个屏幕像素
--   * overlay 的 res_x/res_y 直接取当前 OSD 像素尺寸，所以 1 单位 = 1 屏幕像素
--
-- 旧实现固定用 1920x1080 当 PlayRes，再交给 libass 按窗口高度缩放。窗口宽高比
-- 一变（拖窄/拖宽、上下黑边），画布就会被拉伸或裁掉：弹幕可能从屏幕中间冒出来、
-- 在屏条数变多（看起来"挤"），而且相对窗口的速度也跟着变。改成直接贴合视频显示
-- 矩形后，直播弹幕和点播 ASS 在任意窗口尺寸下都落在同一块区域、用同一条速度。
local function live_layout()
	local ow, oh = 0, 0
	local ml, mt, vw, vh = 0, 0, 0, 0

	-- osd-dimensions 是 mpv 真正用来渲染 OSD/overlay 的像素矩形：
	-- w/h = 整个窗口，ml/mt/mr/mb = 视频四周的留边（黑边）。
	local dim = mp.get_property_native("osd-dimensions")
	if type(dim) == "table" and (dim.w or 0) > 0 and (dim.h or 0) > 0 then
		ow, oh = dim.w, dim.h
		ml, mt = dim.ml or 0, dim.mt or 0
		vw = ow - ml - (dim.mr or 0)
		vh = oh - mt - (dim.mb or 0)
	end

	-- 舞台比例用视频自身宽高比，与 Danmaku_process 传给 Danmu2Ass 的 -s 同源。
	-- 不用显示矩形比例：显示矩形可能因取整带上 1px 黑边，会让 -p 留白边界跳动。
	local vw_src = mp.get_property_number("width", 0) or 0
	local vh_src = mp.get_property_number("height", 0) or 0
	local aspect = (vw_src > 0 and vh_src > 0) and (vw_src / vh_src) or (16 / 9)

	-- 舞台尺寸规则与 Danmaku_process 逐字一致
	local dw, dh = 1920, 1080
	if aspect > 16 / 9 then
		dh = math.floor(1920 / aspect)
	elseif aspect < 16 / 9 then
		dw = math.floor(1080 * aspect)
	end
	if dh < 1 then dh = 1 end
	if dw < 1 then dw = 1 end

	-- 没有 OSD 信息（刚启动 / 无视频）时按 1:1 处理，避免出现 0 尺寸
	if vw <= 0 or vh <= 0 then
		ow, oh, ml, mt, vw, vh = dw, dh, 0, 0, dw, dh
	end

	local fs = tonumber(o.fontsize) or 50
	-- percent = 滚动区以下保留的比例（默认 0.85 → 顶部 15% 给滚动弹幕）。
	-- 语义是「底部留白比例」，不是「弹幕区下边界」；0.85 就是顶部 15%。
	local pct = tonumber(o.percent) or 0.75
	if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
	local scroll_bottom = dh - math.floor(pct * dh) -- 滚动区下边界（U）
	if scroll_bottom < 1 then scroll_bottom = 1 end

	-- 固定区：同样从舞台顶部算起，占整屏高度的 live_fixed_percent（默认 30%）。
	-- 注意它与滚动区是【重叠】的（0 ~ scroll_bottom 这段两块都有），因为固定弹幕
	-- 和滚动弹幕本来就是两套独立通道、互不避让——和 Danmu2Ass 的 4 个 rows 数组、
	-- B站播放器的分层行为一致。固定区只是给固定弹幕一个更高的行数上限。
	local fpct = tonumber(o.live_fixed_percent) or 0.3
	if fpct < 0 then fpct = 0 elseif fpct > 1 then fpct = 1 end
	local fixed_top = 0
	local fixed_bottom = math.floor(fpct * dh)
	if fixed_bottom > dh then fixed_bottom = dh end
	if fixed_bottom < fixed_top then fixed_bottom = fixed_top end

	return {
		ow = ow, oh = oh,          -- overlay 的 res_x/res_y（屏幕像素）
		ml = ml, mt = mt,          -- 视频显示矩形在窗口内的偏移
		vw = vw, vh = vh,          -- 视频显示矩形尺寸（屏幕像素）
		dw = dw, dh = dh,          -- 舞台尺寸（U，等价 ASS PlayRes）
		sx = vw / dw,              -- 1 U 横向 = 多少屏幕像素
		sy = vh / dh,              -- 1 U 纵向 = 多少屏幕像素（字号跟随这个）
		fs = fs,                   -- 基准字号（U）
		scroll_bottom = scroll_bottom, -- 滚动区下边界（U）
		fixed_top = fixed_top,         -- 固定区上边界（U）
		fixed_bottom = fixed_bottom,   -- 固定区下边界（U）
		area_bottom = scroll_bottom,   -- 兼容旧字段名（滚动区下边界）
	}
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

-- 通道占用项：{T=出生毫秒, len=长度(U), fixed=是否固定, dur=自身显示时长}
-- 判空逐条对齐 Danmu2Ass 的 TestFreeRows（两个条件都要满足才可用）：
--   条件1（本条追不上上一条）：dt >= 本条时长 * 本条长/(本条长+W)
--   条件2（上一条尾巴已完全进屏）：dt >= 上一条时长 * 上一条长/(上一条长+W)
-- 这两条其实都是"某条弹幕走完自身长度所需时间"，与速度无关，只与长度成正比。
-- 固定秒数模式（speed=0）：所有滚动弹幕时长相同，等价于原来的实现。
-- 固定速度模式（speed>0）：时长 = (W+长度)/(速度*W)，代进去后两个阈值都化简成
--   长度/(速度*W)，即"按固定速度把这条弹幕整体送进屏幕"所需时间——
--   于是同屏密度只取决于速度和文字长度，与窗口大小、固定秒数彻底解耦。
local function live_occ_free(occ, t, dur_ms, new_len, W, still_ms, speed)
	if not occ then return true end
	if occ.fixed then
		-- 固定弹幕按「自身 dur」释放。旧代码用全局 still_ms：SC 停 10s 时第 6 秒
		-- 它的行就被判成空闲，下一条固定弹幕直接叠上去（叠字）。
		-- 聚合弹幕寿命同样远长于 still_ms，所以这里必须用 occ.dur。
		return (t - occ.T) >= (occ.dur or still_ms)
	end
	local dt = t - occ.T
	local new_dur = dur_ms
	local occ_dur = dur_ms
	if speed > 0 then
		new_dur = (W + new_len) / (speed * W) * 1000
		occ_dur = (W + occ.len) / (speed * W) * 1000
	end
	if dt < new_dur * new_len / (new_len + W) then return false end
	if dt < occ_dur * occ.len / (occ.len + W) then return false end
	return true
end

-- 滚动通道（0 正向 / 3 逆向）：只在滚动区 [0, scroll_bottom) 内排行
local function live_find_row(ch, h, t, dur_ms, new_len, W, scroll_bottom, still_ms, speed)
	if not live_chan[ch] then live_chan[ch] = {} end
	local arr = live_chan[ch]
	local nrow = math.ceil(h)
	local row = 0
	while row + nrow <= scroll_bottom do
		local ok = true
		for r = row, row + nrow - 1 do
			if not live_occ_free(arr[r], t, dur_ms, new_len, W, still_ms, speed) then
				ok = false
				break
			end
		end
		if ok then return row end
		row = row + 1
	end
	return nil
end

-- ============ 固定弹幕区 ============
-- 固定区 [fixed_top, fixed_bottom) 由 mode4 底部、mode5 顶部、SC、聚合弹幕共用。
-- 占用表 live_fixed 按「舞台绝对行」索引，所以两个方向天然互斥：
--   from_top=true  → 从 fixed_top 往下找（顶部弹幕 / SC / 聚合）
--   from_top=false → 从 fixed_bottom 往上找（底部弹幕）
local function live_fixed_free(y, nrow, t, dur_ms, new_len, W, still_ms, speed)
	for r = y, y + nrow - 1 do
		if not live_occ_free(live_fixed[r], t, dur_ms, new_len, W, still_ms, speed) then
			return false
		end
	end
	return true
end

-- 在固定区找位置。from_top=true 从区顶往下（顶部弹幕/SC/聚合），
-- false 从区底往上（底部弹幕）。占用表按舞台绝对行记，所以固定弹幕之间天然互斥。
local function live_find_fixed_row(L, h, t, dur_ms, new_len, W, still_ms, speed,
		from_top)
	local nrow = math.ceil(h)
	if nrow < 1 then nrow = 1 end
	local top = L.fixed_top
	if L.fixed_bottom - top < nrow then return nil end
	if from_top then
		for y = top, L.fixed_bottom - nrow do
			if live_fixed_free(y, nrow, t, dur_ms, new_len, W, still_ms, speed) then
				return y
			end
		end
	else
		for y = L.fixed_bottom - nrow, top, -1 do
			if live_fixed_free(y, nrow, t, dur_ms, new_len, W, still_ms, speed) then
				return y
			end
		end
	end
	return nil
end

local function live_mark_fixed(y, h, occ)
	for i = y, y + math.ceil(h) - 1 do
		live_fixed[i] = occ
	end
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
	for y, occ in pairs(live_fixed) do
		if (t - occ.T) >= occ.dur then live_fixed[y] = nil end
	end
end

-- 提前释放一条弹幕占用的行（live_max 裁剪 / 聚合淘汰 / 聚合过期时用）。
-- 只清「确实属于自己」的占用项，避免误删同一行上别人的占用。
local function live_release(it)
	if not it or not it.occ then return end
	local n = math.ceil(it.fsize or 1)
	if it.fixed then
		for y = it.fixed_y, it.fixed_y + n - 1 do
			if live_fixed[y] == it.occ then live_fixed[y] = nil end
		end
	else
		local arr = live_chan[it.ch]
		if arr then
			for r = it.row, it.row + n - 1 do
				if arr[r] == it.occ then arr[r] = nil end
			end
		end
	end
	it.occ = nil
end

-- ============ 重复弹幕聚合（防刷屏） ============
-- 行为对齐 B站服务端 DANMU_AGGREGATION（msg + aggregation_num）的语义：
--   * 同一条内容在 live_merge_hold 秒内反复出现 → 只保留一个「顶部固定弹幕」，
--     文字后接 " ×N"，N 原地增长，不再占新的行（把行让给其它弹幕）
--   * 超过 hold 没有再次出现 → 固定弹幕消失、计数清零
--   * 第 1 条（累计不到 live_merge_min）仍按普通滚动弹幕显示，不改变单条观感
--   * 只聚合普通滚动弹幕（mode1）；SC / 图片 / 超长文本不参与
local function live_agg_cfg()
	local hold = (tonumber(o.live_merge_hold) or 4) * 1000
	if hold < 500 then hold = 500 end
	local minc = tonumber(o.live_merge_min) or 2
	if minc < 2 then minc = 2 end
	local maxn = tonumber(o.live_merge_max) or 10
	if maxn < 1 then maxn = 1 end
	local maxlen = tonumber(o.live_merge_maxlen) or 30
	return hold, minc, maxn, maxlen
end

local function live_agg_active()
	local n = 0
	for _, g in pairs(live_agg) do
		if g.item then n = n + 1 end
	end
	return n
end

local function live_agg_drop(key)
	local g = live_agg[key]
	if not g then return false end
	if g.item then
		g.item.end_ms = 0 -- 立刻从本帧起不再渲染
		live_release(g.item)
		g.item = nil
	end
	live_agg[key] = nil
	return true
end

-- 淘汰最久没有更新的聚合弹幕。只动聚合，绝不碰 SC / 原生固定弹幕。
local function live_agg_evict_oldest()
	local oldest_key, oldest_seen = nil, nil
	for k, g in pairs(live_agg) do
		if g.item and (oldest_seen == nil or g.last_seen < oldest_seen) then
			oldest_key, oldest_seen = k, g.last_seen
		end
	end
	if not oldest_key then return false end
	return live_agg_drop(oldest_key)
end

-- 在固定区申请一行，创建聚合用的顶部固定弹幕。
-- 从 fixed_top（= 舞台顶部）往下排：固定区与滚动区重叠是刻意设计，聚合弹幕
-- 和滚动弹幕是两套独立通道、互不避让（同 B站顶部弹幕与滚动弹幕的关系）。
local function live_agg_spawn(g, now_ms, L, W, still_ms, hold)
	local _, _, maxn = live_agg_cfg()
	if live_agg_active() >= maxn then live_agg_evict_oldest() end
	local y = live_find_fixed_row(L, g.fsize, now_ms, hold, g.w, W,
		still_ms, 0, true)
	if not y and live_agg_evict_oldest() then
		y = live_find_fixed_row(L, g.fsize, now_ms, hold, g.w, W,
			still_ms, 0, true)
	end
	if not y then return nil end
	local occ = { T = now_ms, len = g.w, fixed = true, dur = hold }
	live_mark_fixed(y, g.fsize, occ)
	local it = {
		text = g.text, color_tag = g.color_tag, fsize = g.fsize,
		an = 8, y = y, w = g.w, fixed = true,
		born_ms = now_ms, dur_ms = hold, end_ms = now_ms + hold,
		fixed_y = y, occ = occ, agg = true, agg_key = g.key,
	}
	live_items[#live_items + 1] = it
	return it
end

-- 更新/创建聚合组。count 是该组的累计条数；force=true 时即使不到 min 也显示
--（服务端 DANMU_AGGREGATION 已经替我们决定要聚合了）。
-- 返回 true 表示这条弹幕已被聚合吸收，调用方不要再排行。
local function live_agg_apply(key, base, color_tag, fsize, count,
		now_ms, L, W, still_ms, force)
	local hold, minc = live_agg_cfg()
	local g = live_agg[key]
	-- 上一轮已经过期：先把它彻底丢掉，避免复用旧 item
	if g and (now_ms - g.last_seen) > hold then
		live_agg_drop(key)
		g = nil
	end
	if not g then
		g = { key = key, base = base, color_tag = color_tag, fsize = fsize,
			count = 0, last_seen = now_ms, item = nil }
		live_agg[key] = g
	end
	g.color_tag = color_tag
	g.fsize = fsize
	g.count = count
	g.last_seen = now_ms
	if g.count < minc and not force then return false end

	g.text = g.base .. " ×" .. tostring(g.count)
	g.w = utf8_len(g.text) * fsize

	if not g.item then
		g.item = live_agg_spawn(g, now_ms, L, W, still_ms, hold)
		if not g.item then
			-- 固定区真的没位置：退回普通显示（调用方会照常排行）
			if g.count > 1 then g.count = g.count - 1 end
			if g.count < 1 then live_agg[key] = nil end
			return false
		end
	end
	-- 原地更新：数字变大、寿命续到 now + hold
	g.item.text = g.text
	g.item.w = g.w
	g.item.dur_ms = hold
	g.item.end_ms = now_ms + hold
	if g.item.occ then
		g.item.occ.T = now_ms
		g.item.occ.dur = hold
	end
	return true
end

-- 过期清理：最后一次出现后超过 hold 就删组、释放行
local function live_agg_sweep(now_ms)
	local hold = live_agg_cfg()
	for k, g in pairs(live_agg) do
		if (now_ms - g.last_seen) >= hold then
			live_agg_drop(k)
		end
	end
end

-- 单条滚动弹幕的当前横坐标（U）。
-- 按「进度」实时重算，而不是把起终点定死在创建时：窗口尺寸/宽高比在飞行途中
-- 变化时轨迹会跟着平滑重映射。速度模式下 duration = (W+文字宽)/速度，
-- 所以各条弹幕速度相同、长弹幕只是在屏时间更长。
local function live_pos_x(it, now_ms, W)
	local p = (now_ms - it.born_ms) / it.dur_ms
	if p < 0 then p = 0 elseif p > 1 then p = 1 end
	if it.reverse then
		return -it.w + p * (W + it.w)
	end
	return W - p * (W + it.w)
end

-- 弹幕文字色 / 描边色 → ASS 颜色标签。
--
-- ⚠ 关键：这里必须「显式输出」\c 与 \3c，不能靠继承。
-- 点播 Danmu2Ass 可以省略它们，因为它的 ASS 样式本身就写了
-- PrimaryColour=&HFFFFFF / OutlineColour=&H000000；而直播 overlay 的样式是
-- mpv 的 OSD 样式（osd-color / osd-outline-color），本机是紫字 #672168 + 近白边
-- #EEEEEE。省略标签会让白字弹幕直接变成紫字、黑边变成白边——这正是
-- 「直播弹幕显示效果差」的根因（真机实测：白字渲染成 RGB(92,30,93)）。
-- 所以两边要的是「最终渲染结果一致」，不是「标签串一致」。
--
-- live_outline_color: black(默认，与点播 Danmu2Ass 一致) / white / RRGGBB
--                     default = 显式选择继承 mpv OSD 描边色（旧行为，可留作对比）
local function live_outline_color_ass()
	local v = tostring(o.live_outline_color or "black"):lower()
	if v == "default" or v == "" then return nil end -- 显式要求继承 OSD
	if v == "white" then return "FFFFFF" end
	if v == "black" then return "000000" end
	-- 允许写 RRGGBB，转成 ASS 的 BGR 序
	local r, g, b = v:match("^(%x%x)(%x%x)(%x%x)$")
	if r then return (b .. g .. r):upper() end
	return nil
end

-- 文字色(ASS BGR) + 描边色 → 颜色标签串。
-- 文字色始终输出（含白色），避免继承 mpv 的 osd-color。
-- 黑字特例：补白边，否则在黑底上看不见（同 Danmu2Ass 的 WriteComment）。
local function live_color_tag(color)
	local out = "\\c&H" .. color .. "&"
	if color == "000000" then
		return out .. "\\3c&HFFFFFF&"
	end
	-- 默认黑边；只有显式设 default 才不输出（继承 mpv OSD）
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

-- 把一条弹幕拼成 ASS 事件。it 里的尺寸都是 U（舞台单位）；这里统一换算到
-- 屏幕像素，所以窗口缩放时字号 / 位移 / 描边一起等比变化。
local function live_emit(parts, it, L, now_ms, font_tag, alpha)
	local fs_px = it.fsize * L.sy
	if fs_px < 1 then fs_px = 1 end
	-- 描边与 Danmu2Ass 同源：舞台内 max(fontsize/25, 1)，再按当前缩放落到屏幕
	local bord = math.max(L.fs / 25, 1) * L.sy
	local style = string.format("%s\\fs%d\\b1\\bord%.2f\\shad0\\q2%s%s",
		font_tag, math.floor(fs_px + 0.5), bord, alpha, it.color_tag)
	local y = L.mt + math.floor(it.y * L.sy + 0.5)
	if it.fixed then
		local x = L.ml + math.floor(L.vw / 2)
		parts[#parts + 1] = string.format("{\\an%d\\pos(%d,%d)%s}%s",
			it.an, x, y, style, it.text)
	else
		local x = L.ml + math.floor(live_pos_x(it, now_ms, L.dw) * L.sx + 0.5)
		local w_px = it.w * L.sx
		if x + w_px >= L.ml then -- 左边界裁剪；右侧出屏部分交给 libass 裁掉
			parts[#parts + 1] = string.format("{\\an7\\pos(%d,%d)%s}%s",
				x, y, style, it.text)
		end
	end
end

local function Live_render()
	if not live_overlay then return end
	local L = live_layout()
	if not live_visible then
		live_overlay.data = ""
		live_overlay.res_x = L.ow
		live_overlay.res_y = L.oh
		live_overlay:update()
		return
	end
	local font_tag = live_font_tag()
	local alpha = live_alpha_tag()
	local now_ms = math.floor(mp.get_time() * 1000 + 0.5)
	local live_max_items = tonumber(o.live_max) or 60
	if live_max_items < 1 then live_max_items = 1 end
	-- 过期清理 + 拼接本帧所有应显示的弹幕
	local fresh, parts = {}, {}
	for _, it in ipairs(live_items) do
		if now_ms < it.end_ms then
			fresh[#fresh + 1] = it
			live_emit(parts, it, L, now_ms, font_tag, alpha)
		end
	end
	-- 同屏上限：只保留最新的 N 条（旧弹幕已显示过，丢的是寿命尾段）。
	-- 必须在此裁剪，否则超高密度房间里每帧拼串量会失控。
	-- 聚合弹幕是常驻的（数量另有 live_merge_max 限制），不参与裁剪：否则在高密度
	-- 房间里它永远是最旧的一条，会被反复丢掉。裁剪时顺手释放占用的行。
	if #fresh > live_max_items then
		local over = #fresh - live_max_items
		local kept = {}
		for _, it in ipairs(fresh) do
			if over > 0 and not it.agg then
				over = over - 1
				it.end_ms = 0
				live_release(it)
			else
				kept[#kept + 1] = it
			end
		end
		fresh = kept
		parts = {}
		for _, it in ipairs(fresh) do
			live_emit(parts, it, L, now_ms, font_tag, alpha)
		end
	end
	live_items = fresh
	live_overlay.data = table.concat(parts, "\n")
	live_overlay.res_x = L.ow
	live_overlay.res_y = L.oh
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
	-- 时间基准与清理必须放在「有没有新数据」之前：聚合弹幕过期、占用行释放都靠
	-- 这里推进，否则房间安静下来后固定弹幕会一直挂着不消失。
	local now_ms = math.floor(mp.get_time() * 1000 + 0.5)
	live_sweep(now_ms)
	live_agg_sweep(now_ms)
	if not chunk or chunk == "" then Live_render() return end
	-- 只消费以换行结尾的完整行：写入方可能正写半行，剩下半行留到下个 tick
	local last_nl = chunk:match(".*()\n")
	if not last_nl then Live_render() return end
	local complete = chunk:sub(1, last_nl)
	live_offset = live_offset + last_nl
	-- 已播弹幕直接删除：把未消费的剩余半行回写，其余截掉，防止 jsonl 无限增长。
	-- 截断后文件内容就是剩余半行本身，所以偏移必须归零，否则下次会从半行
	-- 中间开始读，拼出来的行永远是坏的。
	-- 注意用 o.live_trim（read_options 的结果），mp.get_opt 读不到这个键。
	if tostring(o.live_trim) ~= "no" then
		local rest = chunk:sub(last_nl + 1)
		local wf = io.open(live_file, "w")
		if wf then
			wf:write(rest)
			wf:close()
		end
		live_offset = 0
	end
	local L = live_layout()
	local W = L.dw
	local fs = L.fs
	local scroll_bottom = L.scroll_bottom
	local marquee_ms = (tonumber(o.duration_marquee) or 10) * 1000
	if marquee_ms < 1000 then marquee_ms = 1000 end
	local still_ms = (tonumber(o.duration_still) or 5) * 1000
	if still_ms < 1000 then still_ms = 1000 end
	-- 速度模式：单位「屏宽/秒」，与点播 Danmu2Ass.py 的 -sp 完全同义。
	-- 每条滚动弹幕时长 = (屏宽 + 文字宽) / 速度，于是各条速度相同，
	-- 长弹幕只是在屏更久；0/空 = 关闭，退回 duration_marquee 的固定秒数。
	local speed = tonumber(o.speed) or 0
	if speed < 0 then speed = 0 end
	local MODE2CH = { [1] = 0, [4] = 2, [5] = 1, [6] = 3 }
	local function keep_line(line)
		local ok, d = pcall(utils.parse_json, line)
		if not (ok and d and d.text) then return end
		local is_sc = (d.type == "sc")
		local is_agg = (d.type == "agg")
		-- 服务端聚合弹幕的 text 就是纯内容，不走「用户名：」前缀处理
		local label = is_agg and tostring(d.text) or live_preprocess(d.text, d.user)
		if not label or label == "" then return end
		local ch = MODE2CH[tonumber(d.mode) or 1] or 0
		local ssize = tonumber(d.size) or 25
		local fsize = math.floor(fs * ssize / 25 + 0.5)
		local w = utf8_len(label) * fsize -- 等价 CalculateLength(c) * size
		local dur_ms = marquee_ms
		local row_speed = speed
		if is_sc then
			label = string.format("[SC ¥%s]%s", tostring(d.price or "?"), label)
			-- 文字变了要重算宽度，否则排位判定会按旧长度算
			w = utf8_len(label) * fsize
			if tostring(o.live_sc_mode or "top") == "top" then
				-- SC 默认走顶部固定弹幕（对齐 B站网页播放器：钉住停留，不飘过去）。
				-- 固定弹幕与 mode5/聚合共用固定区，ch=1 表示「顶部锚定」。
				ch = 1
				dur_ms = tonumber(o.live_sc_dur) or 0
				if dur_ms <= 0 then dur_ms = still_ms * 2 else dur_ms = dur_ms * 1000 end
			else
				-- live_sc_mode=scroll：保留旧的滚动行为（时长仍翻倍，醒目）
				dur_ms = still_ms * 2
			end
			row_speed = 0 -- SC 不参与固定速度
		elseif speed > 0 and not (ch == 1 or ch == 2) then
			dur_ms = math.floor((W + w) / (speed * W) * 1000 + 0.5)
		end
		local text = live_ass_escape(label)
		local color = live_convert_color(tonumber(d.color) or 0xffffff, L.dw, L.dh)
		local dim = tonumber(o.live_color_dim) or 1
		if dim > 0 and dim < 1 then color = live_dim_color(color, dim) end
		local color_tag = live_color_tag(color)
		local h = fsize -- 单行弹幕高度

		-- ① 服务端聚合弹幕（DANMU_AGGREGATION）：aggregation_num 是累计值，直接覆盖
		if is_agg then
			local cnt = tonumber(d.count) or 0
			if cnt >= 1 then
				live_agg_apply(label, text, color_tag, fsize, cnt,
					now_ms, L, W, still_ms, true)
			end
			return
		end

		-- ② 客户端聚合：只处理普通滚动弹幕，累计到 live_merge_min 条才折叠。
		-- 第 1 条照常滚动显示（观感不变），第 2 条起被吸收进顶部固定弹幕。
		if ch == 0 and not is_sc and tostring(o.live_merge or "yes") ~= "no" then
			local hold, _, _, maxlen = live_agg_cfg()
			if maxlen <= 0 or utf8_len(label) <= maxlen then
				local g = live_agg[label]
				local cnt = (g and (now_ms - g.last_seen) <= hold)
					and (g.count + 1) or 1
				if live_agg_apply(label, text, color_tag, fsize, cnt,
						now_ms, L, W, still_ms) then
					return
				end
			end
		end

		if ch == 1 or ch == 2 then
			-- 固定区：顶部锚定（mode5 / SC / 聚合）从区顶往下，底部锚定（mode4）从区底往上
			local from_top = (ch == 1)
			local y = live_find_fixed_row(L, h, now_ms, dur_ms, w, W,
				still_ms, 0, from_top)
			-- SC / 原生顶部弹幕优先：没位置时先挤掉最久没更新的聚合弹幕再试一次
			if not y and from_top and live_agg_evict_oldest() then
				y = live_find_fixed_row(L, h, now_ms, dur_ms, w, W,
					still_ms, 0, from_top)
			end
			if not y then return end -- 排不下就丢弃，保证不重叠
			local occ = { T = now_ms, len = w, fixed = true, dur = dur_ms }
			live_mark_fixed(y, h, occ)
			live_items[#live_items + 1] = {
				text = text, color_tag = color_tag, fsize = fsize,
				an = from_top and 8 or 2,
				-- an2 的 \pos 是文字底边，所以底部锚定要落到整块的底边
				y = from_top and y or (y + math.ceil(h)),
				w = w, fixed = true, occ = occ, fixed_y = y,
				born_ms = now_ms, dur_ms = dur_ms, end_ms = now_ms + dur_ms,
			}
		else
			local reverse = (ch == 3)
			local row = live_find_row(ch, h, now_ms, dur_ms, w, W,
				scroll_bottom, still_ms, row_speed)
			if row == nil then return end
			local occ = { T = now_ms, len = w, fixed = false, dur = dur_ms }
			live_mark_row(ch, row, h, occ)
			live_items[#live_items + 1] = {
				text = text, color_tag = color_tag, fsize = fsize,
				reverse = reverse, y = row, w = w,
				ch = ch, row = row, occ = occ,
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
	live_fixed = {}
	live_agg = {}
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
	live_fixed, live_agg = {}, {}
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
-- ============ B站直播自动重连 ============
-- 背景：B站直播的 CDN 直链带签名且会过期（实测 expires 约 1 小时），yt-dlp
-- 只在加载时解析一次、不会续期；单条线路也可能被 B站切走。两者都表现为播放
-- 中途停下：mpv 触发 end-file(reason=error/eof)，播放列表被清到 playlist-pos=-1，
-- 界面退回 uosc 的 idle 转圈，用户只能重开 mpv。
--
-- 本模块用 1 秒一次的轻量看门狗，检测到「卡顿」「流结束」「退回 idle」时重新
-- 加载直播间 URL。加载会重新跑 yt-dlp 解析，拿到一条全新的带签名直链，并且实测
-- 大概率换到另一条 CDN 线路——所以“重载”本身就是“同画质换线路”。
--
-- 重载原语必须分两种情况（实测结论，别想当然）：
--   1) 播放列表还有有效条目（playlist-pos >= 0）：用 playlist-play-index <idx>，
--      复用条目可保留 file-local-options（画质选择等）。
--   2) 断流后 playlist-pos 已变成 -1（“current”不存在了）：playlist-play-index
--      current 完全无效，必须退回 loadfile <房间URL> replace。
--      代价是 file-local-options 丢失、回到 yt-dlp 默认画质——这是断流恢复的
--      必要代价，总比停在 idle 强。
--
-- 流结束时先查直播间状态（live_status.py）再决定：状态“在播”才重载（判定为
-- CDN 掉线 / URL 过期）；状态“未播”说明主播确实下播，转入等待轮询，检测到
-- 重新开播再重载，绝不空转。
--
-- 资源占用：看门狗只是每秒读几个属性，不产生进程、不联网；live_status.py 只在
-- 等待重连阶段按 live_rewait_sec 轮询，是短命进程，正常播放时零额外开销。
local live_reconnect_on = tostring(o.live_reconnect) == "yes"
local live_watch_timer = nil   -- 1s 看门狗
local live_wait_timer = nil    -- 等待重连时的状态轮询定时器
local live_reload_guard = nil  -- 重载收尾超时兜底定时器
local live_watching = false    -- 是否正在监护当前直播间
local live_waiting = false      -- 是否处于“等待主播重新开播”状态
local live_room_reconnect = nil -- 正在监护的直播间号
local live_url = nil            -- 重载用的直播间 URL（loadfile 降级路径需要）
local live_stall_since = nil    -- paused-for-cache 持续为 yes 的起点
local live_freeze_since = nil   -- time-pos 停止推进的起点
local live_last_tp = nil        -- 上一次见到的 time-pos
local live_last_cache = nil     -- 上一次见到的 demuxer-cache-duration（判断缓存是否还在增长）
local live_idle_since = nil     -- 退回 idle（播放列表被清空）的起点
local live_eof_handled = false  -- 本轮是否已处理过流结束
local live_eof_since = nil      -- 流结束信号持续存在的起点
local live_reload_count = 0     -- 熔断窗口内的自动重载次数
local live_reload_since = 0     -- 熔断窗口起点
local live_cooldown_until = 0   -- 冷却截止时刻
local live_grace_until = 0      -- 开播 / 重载后的宽限期截止时刻
-- 重载进行中的标志：分别由 Danmaku_terminate 与本模块的 end-file 各自消费，
-- 与监听器注册顺序无关，避免“跳过弹幕清理”和“保持看门狗”互相打架
local live_skip_danmu_stop = false
local live_keep_watch = false
-- 熔断窗口长度（秒）：窗口内重载次数超限即停止自动尝试
local live_reload_window = 120
-- 流结束信号需要持续多少秒才认定真的结束（直播下 eof-reached 会偶发抖动）
local live_eof_sec = 3
-- 退回 idle 后等多少秒再判定需要重载（给 mpv 内部收尾留出时间）
local live_idle_sec = 2

-- 收尾：停掉所有定时器并清空状态（切台 / 关掉直播 / 重载失败时调用）
local function live_reconnect_stop()
	if live_watch_timer then live_watch_timer:kill() live_watch_timer = nil end
	if live_wait_timer then live_wait_timer:kill() live_wait_timer = nil end
	if live_reload_guard then live_reload_guard:kill() live_reload_guard = nil end
	live_watching = false
	live_waiting = false
	live_room_reconnect = nil
	live_url = nil
	live_stall_since = nil
	live_freeze_since = nil
	live_last_tp = nil
	live_last_cache = nil
	live_idle_since = nil
	live_eof_handled = false
	live_eof_since = nil
	live_reload_count = 0
	live_reload_since = 0
	live_cooldown_until = 0
	live_grace_until = 0
	live_skip_danmu_stop = false
	live_keep_watch = false
end

-- 查直播间状态：true=在播 / false=未播 / nil=无法判定
local function live_query_status(room)
	local py_path = utils.join_path(mp.get_script_directory(), "live_status.py")
	local ok, val = pcall(mp.command_native, {
		name = "subprocess",
		playback_only = false,
		capture_stdout = true,
		args = { o.python_path, py_path, room },
	})
	if not ok or val == nil then return nil end
	-- command_native 对 subprocess 返回的是结果表（stdout 在 val.stdout 里），
	-- 不是裸字符串；两种形态都兼容，避免以后 mpv 版本差异直接判成“未知”
	local out = val
	if type(val) == "table" then out = val.stdout end
	if type(out) ~= "string" then return nil end
	local s = out:gsub("[\r\n]", "")
	if s == "1" then return true end
	if s == "0" then return false end
	return nil
end

-- 重载当前直播流：重新解析 + 大概率换线路。force=true 时跳过熔断（手动触发）
local function live_reload(reason, force)
	if not live_room_reconnect then return false end
	local now = mp.get_time()
	if not force and now < live_cooldown_until then
		return false
	end
	if not force and live_reload_count >= (tonumber(o.live_max_reload) or 4) then
		log("直播自动重连已达上限，停止尝试")
		mp.osd_message("直播重连已达上限，请手动按 Ctrl+Shift+L", 4)
		return false
	end
	-- 标记“本次结束由我们发起”，让 Danmaku_terminate 保留弹幕、
	-- 让本模块的 end-file 不退出监护；两个标志分别被各自的消费者清掉
	live_skip_danmu_stop = true
	live_keep_watch = true
	live_reload_count = live_reload_count + 1
	live_reload_since = now
	live_cooldown_until = now + (tonumber(o.live_cooldown) or 20)
	live_grace_until = now + (tonumber(o.live_start_delay) or 15)
	live_stall_since = nil
	live_freeze_since = nil
	live_eof_handled = false
	live_eof_since = nil
	log("直播重载：" .. reason)
	mp.osd_message(reason, 2.5)
	-- 选重载原语：断流后 playlist-pos 会变成 -1，此时 "current" 不存在，
	-- playlist-play-index current 是空操作（实测无效），必须退回 loadfile。
	local pos = mp.get_property_number("playlist-pos")
	if pos ~= nil and pos >= 0 then
		-- 播放列表条目还在：复用它可以保留画质等 file-local-options
		mp.commandv("playlist-play-index", tostring(pos))
	else
		-- 播放列表已失效：只能按 URL 重新加载，画质会回到 yt-dlp 默认值。
		-- live_url 万一没记录到，用房间号现拼一个兜底。
		local url = live_url
		if not url and live_room_reconnect then
			url = "https://live.bilibili.com/" .. live_room_reconnect
		end
		if not url then
			log("直播重载失败：没有可用的直播间 URL")
			return false
		end
		mp.commandv("loadfile", url, "replace")
	end
	-- 兜底：若重载没换来新的 file-loaded（解析失败 / 网络仍不通），
	-- 不能就此停掉看门狗——那正是“一直转圈”的来源。这里只清标志、
	-- 复位状态，让看门狗继续用 idle 判据重试（受熔断保护）。
	if live_reload_guard then live_reload_guard:kill() end
	live_reload_guard = mp.add_timeout(20.0, function()
		live_reload_guard = nil
		live_skip_danmu_stop, live_keep_watch = false, false
		if live_watching then
			live_eof_handled = false
			live_eof_since = nil
			live_idle_since = nil
			live_stall_since, live_freeze_since, live_last_tp, live_last_cache = nil, nil, nil, nil
			log("直播重载未完成，继续监护")
		end
	end)
	return true
end

-- 进入“等待主播重新开播”：不重载、不空转，按间隔轮询直播间状态
local function live_enter_wait(note)
	live_waiting = true
	if live_wait_timer then live_wait_timer:kill() end
	log("直播等待重连：" .. tostring(note))
	mp.osd_message("直播已断开，等待重连…", 3)
	local interval = tonumber(o.live_rewait_sec) or 30
	if interval < 5 then interval = 5 end
	live_wait_timer = mp.add_periodic_timer(interval, function()
		if not live_waiting then return end
		local live = live_query_status(live_room_reconnect)
		if live then
			-- 等待阶段每次轮询都是一次独立的恢复机会，不受冷却期限制
			-- （否则冷却未过时永远重载不了，会一直卡在等待）
			if live_reload("检测到直播恢复，重新连接", true) then
				live_waiting = false
				if live_wait_timer then live_wait_timer:kill() live_wait_timer = nil end
			end
		elseif live == nil then
			mp.osd_message("直播状态未知，继续等待…", 2.5)
		else
			mp.osd_message("直播已断开，等待重连…", 2.5)
		end
	end)
end

-- eof-reached 已持续为 yes / 已退回 idle：查直播间状态，区分“掉线”和“主播下播”
-- from_idle=true 表示已经掉回 idle（必须恢复的终态），此时重载绕过冷却期
local function live_handle_eof(from_idle)
	live_eof_handled = true
	local live = live_query_status(live_room_reconnect)
	if live then
		if live_reload(from_idle and "直播已断开，重新连接" or "直播流断开，重新连接",
			from_idle and true or false) then
			-- 重载已发起：复位，让后续（若又失败）还能再次尝试
			live_eof_handled = false
		end
	elseif live == nil then
		live_enter_wait("状态未知")
	else
		live_enter_wait("主播未开播")
	end
end

-- 1 秒一次的看门狗
local function live_watchdog_tick()
	if not live_watching or live_waiting then return end
	local now = mp.get_time()
	if now < live_grace_until then return end

	-- 0) 最高优先级：已经退回 idle（界面变默认界面 + 转圈）。
	--    断流时 mpv 会触发 end-file(error) 并把 playlist-pos 置 -1，此时
	--    paused-for-cache / time-pos / eof-reached 全是 nil，下面所有判据都会
	--    失效。必须单独靠 idle-active 抓这种情况，否则永远救不回来。
	--    idle 是“必须恢复”的终态，因此这里**绕过冷却期**：刚重载失败又掉回
	--    idle 时如果还等冷却，用户就会盯着转圈干等一整个冷却期。
	if mp.get_property_native("idle-active") then
		if live_idle_since == nil then live_idle_since = now end
		if now - live_idle_since >= live_idle_sec then
			live_idle_since = nil
			live_handle_eof(true)
		end
		return
	end
	live_idle_since = nil

	-- 其余判据（卡顿 / 卡死 / eof）受冷却期保护，避免重载风暴
	if now < live_cooldown_until then return end
	-- 熔断窗口过期则清零重载次数
	if live_reload_count > 0 and now - live_reload_since > live_reload_window then
		live_reload_count = 0
	end

	-- 过渡期（重载 / 切台）这些属性可能是 nil，清计时不做判断
	local paused_cache = mp.get_property("paused-for-cache")
	if paused_cache == nil then
		live_stall_since = nil
		live_freeze_since = nil
		return
	end
	-- 1) 卡顿：paused-for-cache 持续为 yes
	if paused_cache == "yes" then
		if live_stall_since == nil then live_stall_since = now end
		if now - live_stall_since >= (tonumber(o.live_stall_sec) or 2) then
			live_reload("直播卡顿，自动切换线路")
			return
		end
	else
		live_stall_since = nil
	end
	-- 2) 卡死：用户没暂停，但 time-pos 一直不推进。
	--    这是断流“僵死期”的主要判据（见 live_freeze_sec 注释）。
	--    为了不把正常缓冲误判成卡死，同时要求 demuxer 缓存也不再增长：
	--    真断流时缓存会停在一个值不动，正常缓冲则缓存还在往里填。
	if mp.get_property_native("paused") then return end
	local tp = mp.get_property_native("time-pos")
	if tp == nil then return end
	local cachedur = mp.get_property_number("demuxer-cache-duration")
	if tp ~= live_last_tp then
		live_last_tp = tp
		live_freeze_since = nil
		live_last_cache = cachedur
	else
		if live_freeze_since == nil then
			live_freeze_since = now
			live_last_cache = cachedur
		elseif cachedur ~= nil and live_last_cache ~= nil and cachedur > live_last_cache + 0.05 then
			-- 缓存还在增长：说明只是播放端在等，流本身有数据，不算卡死
			live_freeze_since = now
			live_last_cache = cachedur
		end
		if now - live_freeze_since >= (tonumber(o.live_freeze_sec) or 8) then
			live_reload("直播无进展，自动重新连接")
		end
	end
	-- 3) 流结束：eof-reached 需持续为 yes 才认定（直播下该属性会偶发抖动，
	--    瞬时 yes 不动作，避免误触发重载）
	if mp.get_property_native("eof-reached") then
		if live_eof_since == nil then live_eof_since = now end
		if now - live_eof_since >= live_eof_sec and not live_eof_handled then
			live_handle_eof()
		end
	else
		live_eof_since = nil
	end
end

-- 开始监护：识别到直播间就挂上看门狗
local function live_reconnect_start()
	if not live_reconnect_on then
		live_reconnect_stop()
		return
	end
	local room = live_room_from_url()
	if not room then
		live_reconnect_stop()
		return
	end
	if live_watch_timer then
		-- 同一场直播的重复加载（重载后重连）：只刷新宽限期与标志，不重启定时器
		-- （重启会清掉重载计数，让熔断永远不触发）
		live_room_reconnect = room
		live_grace_until = mp.get_time() + (tonumber(o.live_start_delay) or 15)
		live_eof_handled = false
		live_eof_since = nil
		live_idle_since = nil
		live_stall_since, live_freeze_since, live_last_tp, live_last_cache = nil, nil, nil, nil
		return
	end
	live_room_reconnect = room
	live_watching = true
	live_waiting = false
	live_eof_handled = false
	live_eof_since = nil
	live_idle_since = nil
	live_stall_since = nil
	live_freeze_since = nil
	live_last_tp = nil
	live_last_cache = nil
	live_grace_until = mp.get_time() + (tonumber(o.live_start_delay) or 15)
	live_watch_timer = mp.add_periodic_timer(1.0, live_watchdog_tick)
end

-- 重载收尾 / 状态复位
local function live_reconnect_on_file_loaded()
	live_skip_danmu_stop = false
	live_keep_watch = false
	if live_reload_guard then live_reload_guard:kill() live_reload_guard = nil end
	-- 记录可用于 loadfile 降级的直播间 URL（断流后播放列表会失效）
	local url = live_room_from_url()
	if url then
		live_url = "https://live.bilibili.com/" .. url
	end
	live_reconnect_start()
end

-- 本模块的 end-file。
-- 关键：必须按 reason 区分“用户主动结束”和“流自己断掉”：
--   stop / quit  = 用户意图（按了停止、关窗口），必须停掉看门狗，否则会把
--                  用户主动关掉的直播重新拉起来。
--   error / eof  = 流自己断掉（CDN 掉线、签名过期、分片 404），**绝不能**停
--                  看门狗——此时 mpv 已把播放列表清空、属性全变 nil，只有看门狗
--                  靠 idle-active 才能发现并自愈。这正是“退回默认界面一直转圈”
--                  的成因，早期版本在这里误停了看门狗。
--   redirect     = mpv 内部重定向，忽略。
local function live_reconnect_on_end_file(ev)
	local reason = tostring((ev and ev.reason) or "unknown")
	if live_keep_watch then
		-- 自己发起的重载：保持监护，等 file-loaded 收尾
		live_keep_watch = false
		return
	end
	if reason == "stop" or reason == "quit" then
		-- 用户主动结束：正常收尾，不再自愈
		live_skip_danmu_stop = false
		live_reconnect_stop()
		return
	end
	if reason == "redirect" then return end
	-- error / eof / unknown：保留看门狗与监护状态，让它在下一步靠
	-- idle-active / eof-reached 发现断流并自愈
	live_skip_danmu_stop = false
	live_eof_handled = false
	live_eof_since = nil
	live_idle_since = nil
end

-- 手动重载（Ctrl+Shift+L）：不依赖自动重连开关，强制重载一次
local function live_reconnect_manual()
	local room = live_room_from_url()
	if not room then
		log("当前不是 B站直播间，无需重载")
		mp.osd_message("当前不是 B站直播间", 2)
		return
	end
	if live_reconnect_on then
		live_reconnect_start()
	end
	live_room_reconnect = room
	live_reload("手动重载直播流", true)
end

mp.register_event("file-loaded", live_reconnect_on_file_loaded)
mp.register_event("end-file", live_reconnect_on_end_file)
mp.add_key_binding(nil, 'reload', live_reconnect_manual)
-- ============ 直播自动重连结束 ============
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
		local danmaku_id = nil
		cid, danmaku_id = get_cid()

		if cid == nil then
			-- 没有弹幕轨道 → 不是 B 站（或这条片没抓到弹幕）：直接返回，绝不能碰 sid。
			-- 原实现不看来源就执行下面的 sid=false，会把「非 B 站 URL（如其它站点 m3u8）」的
			-- 正片外挂字幕一并关掉；若改用 URL 里有没有 bilibili.com 来判别，又会漏掉 B 站走
			-- akamaized 等第三方 CDN 的情况。以「有没有弹幕轨道」为准，与 CDN 域名无关。
			return
		end

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
			'-sp', tostring(tonumber(o.speed) or 0),
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
			'-sp', tostring(tonumber(o.speed) or 0),
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
	if live_skip_danmu_stop then
		-- 本次结束由插件自己发起的重载引起：保留弹幕子进程与 jsonl，
		-- 跨重载无缝延续，避免每次自动恢复弹幕都闪断
		live_skip_danmu_stop = false
	else
		Live_stop() -- 直播模式：杀子进程、清 overlay、删 jsonl，无 danmu_file 也要执行
	end
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
