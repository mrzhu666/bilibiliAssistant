#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""B站直播间状态查询（mpv bilibiliAssistant 直播自动重连后端）.

只用 Python 标准库（urllib），mpv-lazy 自带 Python 无需装任何第三方包即可运行。

用法：
  python live_status.py <房间号>

输出（stdout，单行，供 main.lua 解析）：
  1    直播间正在直播
  0    直播间未开播（或房间不存在 / 已注销）
  -    查询失败，无法判定（网络错误、接口异常等）

为什么要单独一个脚本：Lua 侧不能直接发 HTTP 请求，而状态查询只在
「直播流断开后等待重连」时才需要，属于低频短进程，不占常驻资源。
"""

import json
import sys
import urllib.error
import urllib.request

UA = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36')
ORIGIN = 'https://live.bilibili.com'


class RoomUnavailable(RuntimeError):
    """房间不存在 / 已注销：确定未开播，不是“查询失败”."""


def http_get_json(url, timeout=15):
    """GET 请求并解析 JSON，失败抛异常.

    B站接口出错时可能直接返回非 2xx（且 body 里带 code），这里把能解析的
    body 也返回，交由调用方按 code 判定，避免把“明确拒绝”误当成网络故障。
    """
    req = urllib.request.Request(
        url, headers={'User-Agent': UA, 'Referer': ORIGIN})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
    except urllib.error.HTTPError as e:
        body = e.read()
    try:
        return json.loads(body.decode('utf-8', 'replace'))
    except ValueError:
        raise RuntimeError('bad json from %s' % url)


def resolve_real_room_id(room_id):
    """短号换真实 room_id（room_init 对短号与真实号都返回真实号）.

    Raises:
        RoomUnavailable: 接口明确拒绝（房间不存在 / 已注销）。
    """
    data = http_get_json(
        'https://api.live.bilibili.com/room/v1/Room/room_init?id=%s'
        % room_id)
    if data.get('code') != 0 or not data.get('data'):
        raise RoomUnavailable('room_init failed: %r' % (data,))
    return str(data['data'].get('room_id') or room_id)


def query_live_status(room_id):
    """查询直播间状态，返回 1 / 0。查询失败抛异常."""
    real_id = resolve_real_room_id(room_id)
    data = http_get_json(
        'https://api.live.bilibili.com/room/v1/Room/get_info?id=%s' % real_id)
    if data.get('code') != 0 or not data.get('data'):
        # 房间存在但接口异常：按“未开播”保守处理，下次轮询会再纠正
        return 0
    return 1 if int(data['data'].get('live_status') or 0) == 1 else 0


def main(argv=None):
    """命令行入口，始终返回 0（状态由 stdout 表达，不让 mpv 当成错误）."""
    argv = sys.argv if argv is None else argv
    room_id = argv[1] if len(argv) > 1 else ''
    if not room_id:
        print('-')
        return 0
    try:
        print(query_live_status(room_id))
    except RoomUnavailable:
        # 房间不存在 / 已注销：确定未开播，不算查询失败
        print('0')
    except Exception:  # noqa: BLE001 - 网络抖动/接口变更全部归为“无法判定”
        print('-')
    return 0


if __name__ == '__main__':
    sys.exit(main())
