# bilibiliAssistant

mpv B站播放增强插件：点播弹幕自动加载 + 直播间实时弹幕。

改编自 [itKelis/MPV-Play-BiliBili-Comments](https://github.com/itKelis/MPV-Play-BiliBili-Comments)，
核心弹幕转换代码来自 [danmaku2ass](https://github.com/m13253/danmaku2ass)。

## 功能特性

- 点播弹幕：播放 B站视频时自动下载弹幕并转为 ASS 加载，观感与 B站网页播放器一致
- 直播弹幕：播放 `live.bilibili.com` 时自动连接弹幕服务器实时显示，含普通弹幕与 SC，样式与点播弹幕完全对齐；SC 以顶部固定弹幕显示（同 B站网页）
- 直播自动重连：直播掉线或缓冲跟不上时自动重新解析并加载（重解析即同画质换 CDN 线路）；主播确实下播则转入等待，检测到重新开播自动接回
- 低帧率自动提帧（`<45fps` 且 `<1.5` 倍速时自动加 `fps=60` 滤镜，保证滚动弹幕流畅）
- 按 `b` 一键显示 / 隐藏弹幕，按 `Ctrl+Shift+L` 手动重载当前直播流

## 与上游的区别

1. 新增 B站直播间实时弹幕（`live_danmu.py` + `main.lua` 直播分支），点播那套字号 / 透明度 / 排版 / 描边规则原样复用
2. 新增 B站直播自动重连（`live_status.py` + `main.lua` 看门狗）：掉线 / 卡顿自愈，重载即同画质换线路，主播下播则等待重开
3. **滚动弹幕改为固定速度**（`speed` 参数，屏宽/秒）：所有弹幕速度一致，长弹幕只是在屏更久；
   旧版按「固定秒数」滚动，长弹幕会被逼着跑得更快、窗口一缩小相对速度就变慢并越挤越多。
   点播（`Danmu2Ass.py -sp`）与直播（`main.lua`）共用同一个速度语义。
4. **弹幕画布跟随视频显示矩形**：overlay 的 `res_x/res_y` 取当前 `osd-dimensions` 像素尺寸，
   字号 / 位移 / 描边按「视频显示高度 / 舞台高」实时换算，所以拖窄窗口、加黑边都不会
   把弹幕拉歪或从屏幕中间冒出来（旧版固定 PlayRes 1920x1080 交给 libass 拉伸，宽高比一变就漂）。
5. **直播弹幕样式显式对齐点播**：文字色 / 描边色显式输出（不再继承 mpv OSD 的紫字白边），
   字体默认跟随 `--sub-font`，使直播与点播的字体、颜色、描边完全一致
6. 去掉了 `Danmu2Ass.exe`，只保留 `Danmu2Ass.py`（纯标准库，无第三方依赖）
7. 配置命名空间冻结为 `bilibiliAssistant`（`options.read_options(o, "bilibiliAssistant")`）
8. 不推荐 External Player，推荐“网址进 mpv + yt-dlp 解析 + mpv-quality-menu 选画质”流程（见下文）

## 安装

要求：mpv、Python 3.6+（仅标准库即可）、[yt-dlp](https://github.com/yt-dlp/yt-dlp)（播放在线视频需要）。

将本仓库整个目录放入 mpv 的 `scripts` 文件夹，目录名保持 `bilibiliAssistant`：

```
<mpv配置目录>/scripts/bilibiliAssistant/
├── main.lua
├── Danmu2Ass.py
├── live_danmu.py
└── live_status.py
```

如果 `python` 不在系统 PATH，在 `script-opts/bilibiliAssistant.conf` 里指定解释器路径：

```
bilibiliAssistant-python_path=<python.exe 路径>
```

## 使用

### 1. 把视频送进 mpv（推荐）

本项目不推荐 External Player：它的传参方式与
[mpv-quality-menu](https://github.com/christoph-heinrich/mpv-quality-menu)
的画质选择流程不搭。建议用只负责“把网址送进 mpv”的 opener，
解析和画质选择留给 yt-dlp + mpv-quality-menu：

- [woodruffw/ff2mpv](https://github.com/woodruffw/ff2mpv)（Firefox / Chrome 通用）
- [Tatsh/open-in-mpv](https://github.com/Tatsh/open-in-mpv)
- [Baldomo/open-in-mpv](https://github.com/Baldomo/open-in-mpv)
- [Ezer015/bilibili-mpv-opener](https://github.com/Ezer015/bilibili-mpv-opener)（B站专用）
- [yazansayed/play-in-mpv](https://github.com/yazansayed/play-in-mpv)

配合 yt-dlp 也可直接在命令行播放，点播与直播都会自动挂弹幕：

```console
mpv <B站视频网址>
mpv https://live.bilibili.com/<房间号>
```

### 2. 点播弹幕

有弹幕的视频默认自动显示。可设置最小自动显示的弹幕数量或默认隐藏：

```
bilibiliAssistant-autoplay=yes
bilibiliAssistant-mincount=1
```

弹幕数量按 ASS 文件大小估算，转换器会控制高密度区域不重叠，
估值与网页显示的弹幕数可能不一致。

### 3. 直播弹幕

播放 `live.bilibili.com` 时自动启动，无需任何操作。
匿名连接默认带 `buvid`，弹幕量与登录连接一致。按 `b` 切换显示。

### 4. 直播自动重连

直播播放中无需任何操作，看门狗会自动处理三类问题：

- **卡顿 / 断流僵死**：断流后 mpv 常有一段"僵死期"——界面还在、`idle-active` 仍是 `no`，
  只有 `time-pos` 完全冻结、`demuxer-cache-duration` 不再增长。看门狗靠这对信号识别，
  自动重新解析并加载，**重解析会拿到新的带签名 CDN 直链并大概率换线路**，因此"重载"
  本身就是**同画质换线路**。
- **已经掉回 idle**（界面变默认界面、中间一直转圈）：这是必须恢复的终态，看门狗会
  **绕过冷却期**立即处理，不会让用户干等。
- **主播确实下播**：不会空转重载，转入静默等待；轮询到重新开播后自动接回，OSD 提示状态。

重载期间直播弹幕不会中断（抓取子进程跨重载延续，不会闪断）。

按 `Ctrl+Shift+L` 可随时手动重载当前直播流——**改完 cookie 文件后按它即可生效，
不用重开 mpv**。

> 实现说明：播放列表还有有效条目时用 `playlist-play-index`（保留画质选择）；
> 断流后 `playlist-pos` 会变成 `-1`，此时 `current` 已不存在，必须退回
> `loadfile <房间URL>`，画质会回到 yt-dlp 默认值——这是断流恢复的必要代价。

### 5. 手动加载（本地视频配线上弹幕）

先自行获取视频的 cid（devtools 控制台输入 `cid`，或用取 cid 的油猴脚本），然后：

```console
# 在 mpv console（` 键）里执行
script-message load-danmaku <cid>
```

或启动时传入：

```console
mpv --script-opts-append="cid=<cid>" <视频文件>
```

## 配置

写在 `script-opts/bilibiliAssistant.conf`，或用 `--script-opts-append="bilibiliAssistant-xxx=yyy"` 传入。

点播：

| 选项 | 默认值 | 说明 |
|---|---|---|
| `autoplay` | `yes` | 打开即显示 / `no`=默认隐藏 |
| `mincount` | `1` | 小于此估算弹幕数不自动显示 |
| `fontname` | `sans-serif` | 弹幕字体。留默认时自动跟随 mpv 的 `--sub-font`，与点播弹幕同一字体 |
| `fontsize` | `50` | 弹幕字号 |
| `opacity` | `0.95` | 不透明度 0-1 |
| `speed` | （空） | 滚动弹幕速度，单位「屏宽/秒」，`0`/空 = 关闭改用 `duration_marquee` |
| `duration_marquee` | `10` | 滚动弹幕持续秒数（`speed` 生效时仅作兜底） |
| `duration_still` | `5` | 顶部 / 底部固定弹幕持续秒数 |
| `percent` | `0.75` | 底部保留空白比例 0-1（防挡字幕） |
| `filter_file` | （空） | 弹幕屏蔽关键词文件路径 |
| `fps_vf` | `yes` | 低帧率自动加提帧滤镜，卡可设 `no` |
| `use_python` | `yes` | 固定走 `Danmu2Ass.py` |
| `python_path` | `python` | Python 解释器路径 |
| `log_osd` | `no` | 是否在 OSD 显示日志 |

### 滚动速度：`speed` 与 `duration_marquee`

`speed` 是「屏宽/秒」，`duration_marquee` 是「固定秒数」，二者只取其一（`speed` 优先）。

| 参数 | 语义 | 长弹幕 | 窗口变小 |
|---|---|---|---|
| `speed=0.10`（推荐） | 每秒穿过 0.10 个屏宽 | 速度不变，在屏更久 | 速度不变 |
| `duration_marquee=20`（旧） | 每条都在屏 20 秒 | 被逼着跑得更快 | 相对窗口变慢，越挤越多 |

换算：`speed ≈ 1 / 期望穿过一屏的秒数`。`0.10` ≈ 10 秒，`0.2` ≈ 5 秒。
实际在屏时长 = `(屏宽 + 文字宽) / speed / 屏宽`，所以长弹幕会久一点，这是刻意设计。

B站网页播放器就是固定速度语义（长弹幕在屏更久，不会越长越快），这也是本插件现在的默认行为。

### 字体 / 颜色与点播对齐

直播弹幕用 `osd-overlay` 渲染，样式默认来自 mpv 的 OSD 设置，而点播弹幕是 ASS 字幕、
样式来自 `--sub-font` 等字幕设置。两者不是一套，直接沿用会出现：

- 白色弹幕变成 mpv 的 `osd-color`（本机是紫色 `#672168`）
- 描边变成 `osd-outline-color`（近白 `#EEEEEE`），而点播是黑边
- 中文字形回退到 `osd-font`（微软雅黑），而点播回退到 `sub-font`（楷体）

所以直播分支显式输出 `\c` / `\3c`，并在 `fontname` 留默认时改用 `--sub-font`。
真机 libass 日志可以确认两边现在落在同一字体：

```
[osd/libass] fontselect: (LXGW WenKai Mono Lite, 700, 0) -> LXGWWenKaiMonoLite-Regular   ← 直播
[sub/ass]   Using default font family:              -> LXGWWenKaiMonoLite-Regular        ← 点播
```

直播（样式与排版完全套用上方点播配置）：

| 选项 | 默认值 | 说明 |
|---|---|---|
| `live_enable` | `yes` | 是否启用直播弹幕 |
| `live_interval` | `0.01` | 重绘间隔秒（顺滑度，10ms≈每帧） |
| `live_ingest` | `0.2` | 拉取弹幕间隔秒（与流畅度无关） |
| `live_max` | `60` | 同屏弹幕上限（防超高密度房间卡顿） |
| `live_room` | （空） | 手动指定房间号，留空则从播放地址识别 |
| `live_trim` | `yes` | 已播弹幕直接删除不囤积 / `no`=保留 |
| `live_prefix` | `trim` | `trim`=截断到第一个冒号去掉“用户名：”（默认）/ `no`=保留完整 / `trim_keep`=保留用户名 |
| `live_prefix_drop_empty` | `yes` | 截断后为空的弹幕是否丢弃 |
| `live_outline_color` | `black` | 描边色，`black`=与点播一致 / `white` / `RRGGBB` / `default`=继承 mpv OSD（旧行为，紫字白边） |
| `live_color_dim` | `0.75` | 彩色弹幕调暗系数 0.3-1.0，`1`=不调；白字黑字不受影响 |
| `live_sc_mode` | `top` | SC（醒目留言）显示方式，`top`=顶部固定弹幕 / `scroll`=滚动（旧行为） |
| `live_sc_dur` | （空） | SC 停留秒数（仅 `top` 生效），留空 = `duration_still` × 2 |

直播自动重连（与上方直播弹幕的样式配置无关）：

| 选项 | 默认值 | 说明 |
|---|---|---|
| `live_reconnect` | `yes` | 是否启用直播自动重连 |
| `live_stall_sec` | `2` | 卡顿阈值：`paused-for-cache` 持续多少秒就重载换线路 |
| `live_freeze_sec` | `8` | `time-pos` 冻结多少秒判定卡死（断流“僵死期”的主判据） |
| `live_cooldown` | `20` | 两次自动重载的最小间隔（秒），防重载风暴 |
| `live_max_reload` | `4` | 熔断窗口（120s）内最多自动重载几次，超过即停止并提示 |
| `live_start_delay` | `8` | 开播 / 重载后多少秒内不自动动作，避开初始缓冲 |
| `live_rewait_sec` | `30` | 断线等待重连时，轮询直播间状态的间隔（秒） |

## 快捷键

| 键 | 作用 |
|---|---|
| `b` | 显示 / 隐藏弹幕（点播与直播通用） |
| `Ctrl+Shift+L` | 手动重载当前直播流（重新解析并换线路；改完 cookie 后用它生效） |

换键位可在按键配置里改（本仓库为 `input_uosc.conf`）：

```
<key> script-binding bilibiliAssistant/toggle
<key> script-binding bilibiliAssistant/reload
```

## 加载原理

点播：

1. 从 yt-dlp 传递的 `danmaku` track 或 `--script-opts cid=` 拿到视频 cid
2. `Danmu2Ass.py` 下载弹幕 xml 并转为 `.ass` 存到系统临时目录
3. 以次字幕形式加载该 `.ass`

直播：

1. 从播放地址识别房间号（或 `live_room` 手动指定）
2. `live_danmu.py` 子进程直连弹幕服务器写 `jsonl`（短号自动换真实房间号，断线重连）
3. `main.lua` 高频定时器重绘 OSD overlay，通道占用与追尾判定等价于 `Danmu2Ass` 的 `TestFreeRows` / `MarkCommentRow`
4. 自动重连看门狗每秒检查 `idle-active` / `paused-for-cache` / `time-pos` 与
   `demuxer-cache-duration` / `eof-reached`：已掉回 idle 立即恢复（绕过冷却）；卡顿或
   `time-pos` 冻结且缓存不再增长时用 `playlist-play-index`（或 `loadfile`）重载，重解析
   即换线路；流结束时由 `live_status.py` 查直播间状态，在播才重载，未播则按
   `live_rewait_sec` 轮询等待重开

## 路线图

- 广告跳过
- 高能进度条
- 个人屏蔽词拉取

## 相关项目

- [itKelis/MPV-Play-BiliBili-Comments](https://github.com/itKelis/MPV-Play-BiliBili-Comments)（上游）
- [s594569321/MPV-Play-BAHA-Comments](https://github.com/s594569321/MPV-Play-BAHA-Comments)（同系列巴哈弹幕）
- [m13253/danmaku2ass](https://github.com/m13253/danmaku2ass)（弹幕转换核心）
- [christoph-heinrich/mpv-quality-menu](https://github.com/christoph-heinrich/mpv-quality-menu)（画质选择）

## 许可证

GPL-3.0，与上游保持一致。
