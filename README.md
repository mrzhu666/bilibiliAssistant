# bilibiliAssistant

mpv B站播放增强插件：点播弹幕自动加载 + 直播间实时弹幕。

改编自 [itKelis/MPV-Play-BiliBili-Comments](https://github.com/itKelis/MPV-Play-BiliBili-Comments)，
核心弹幕转换代码来自 [danmaku2ass](https://github.com/m13253/danmaku2ass)。

## 功能特性

- 点播弹幕：播放 B站视频时自动下载弹幕并转为 ASS 加载，观感与 B站网页播放器一致
- 直播弹幕：播放 `live.bilibili.com` 时自动连接弹幕服务器实时显示，含普通弹幕与 SC，样式与点播弹幕完全对齐
- 低帧率自动提帧（`<45fps` 且 `<1.5` 倍速时自动加 `fps=60` 滤镜，保证滚动弹幕流畅）
- 按 `b` 一键显示 / 隐藏弹幕

## 与上游的区别

1. 新增 B站直播间实时弹幕（`live_danmu.py` + `main.lua` 直播分支），点播那套字号 / 透明度 / 排版 / 描边规则原样复用
2. 去掉了 `Danmu2Ass.exe`，只保留 `Danmu2Ass.py`（纯标准库，无第三方依赖）
3. 配置命名空间冻结为 `bilibiliAssistant`（`options.read_options(o, "bilibiliAssistant")`）
4. 不推荐 External Player，推荐“网址进 mpv + yt-dlp 解析 + mpv-quality-menu 选画质”流程（见下文）

## 安装

要求：mpv、Python 3.6+（仅标准库即可）、[yt-dlp](https://github.com/yt-dlp/yt-dlp)（播放在线视频需要）。

将本仓库整个目录放入 mpv 的 `scripts` 文件夹，目录名保持 `bilibiliAssistant`：

```
<mpv配置目录>/scripts/bilibiliAssistant/
├── main.lua
├── Danmu2Ass.py
└── live_danmu.py
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

### 4. 手动加载（本地视频配线上弹幕）

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
| `fontname` | `sans-serif` | 弹幕字体 |
| `fontsize` | `50` | 弹幕字号 |
| `opacity` | `0.95` | 不透明度 0-1 |
| `duration_marquee` | `10` | 滚动弹幕持续秒数 |
| `duration_still` | `5` | 顶部 / 底部固定弹幕持续秒数 |
| `percent` | `0.75` | 底部保留空白比例 0-1（防挡字幕） |
| `filter_file` | （空） | 弹幕屏蔽关键词文件路径 |
| `fps_vf` | `yes` | 低帧率自动加提帧滤镜，卡可设 `no` |
| `use_python` | `yes` | 固定走 `Danmu2Ass.py` |
| `python_path` | `python` | Python 解释器路径 |
| `log_osd` | `no` | 是否在 OSD 显示日志 |

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
| `live_outline_color` | `default` | 描边色，`default`=继承 mpv OSD / `black` / `white` / `RRGGBB` |
| `live_color_dim` | `0.75` | 彩色弹幕调暗系数 0.3-1.0，`1`=不调；白字黑字不受影响 |

## 快捷键

`b` 显示 / 隐藏弹幕（点播与直播通用）。换键位可在 `input.conf` 里改：

```
<key> script-binding bilibiliAssistant/toggle
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

## 路线图

- 广告跳过
- 高能进度条
- SC 滞留显示
- 弹幕速度一致（直播与点播对齐）
- 个人屏蔽词拉取

## 相关项目

- [itKelis/MPV-Play-BiliBili-Comments](https://github.com/itKelis/MPV-Play-BiliBili-Comments)（上游）
- [s594569321/MPV-Play-BAHA-Comments](https://github.com/s594569321/MPV-Play-BAHA-Comments)（同系列巴哈弹幕）
- [m13253/danmaku2ass](https://github.com/m13253/danmaku2ass)（弹幕转换核心）
- [christoph-heinrich/mpv-quality-menu](https://github.com/christoph-heinrich/mpv-quality-menu)（画质选择）

## 许可证

GPL-3.0，与上游保持一致。
