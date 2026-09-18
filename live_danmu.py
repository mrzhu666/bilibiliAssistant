#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""B站直播弹幕抓取器（mpv bilibiliAssert 插件的直播后端）.

只用 Python 标准库（socket/ssl/struct/json/zlib/urllib/logging），
mpv-lazy 自带 Python 无需装任何第三方包即可运行。

原理：
  1. 调 room_init 把短号换成真实 room_id；
  2. 调 room/v1/Danmu/getConf 拿弹幕服务器 host + token（无需登录）；
  3. 裸 socket + ssl 直连 wss://host:443/sub，发鉴权包（protover=2）；
  4. 收到的 DANMU_MSG / SUPER_CHAT_MESSAGE 逐条追加写入 jsonl 文件，
     由 main.lua 定时读取并渲染成滚动弹幕。

每行 jsonl 格式（mode/size 沿用 B站语义，lua 侧按 Danmu2Ass 规则换算）：
  {"user": "昵称", "text": "弹幕", "color": 16777215, "mode": 1,
   "size": 25, "type": "danmu"}
  {"user": "昵称", "text": "SC留言", "color": 16777215, "mode": 1,
   "size": 25, "type": "sc", "price": 30}

用法：
  python live_danmu.py <room_id> <out.jsonl>

收到 SIGTERM / KeyboardInterrupt 或被 mpv 杀掉时直接退出；
网络断开会自动重连（lua 端 abort 进程即彻底停止）。
"""

import argparse
import base64
import json
import logging
import os
import socket
import ssl
import struct
import sys
import time
import urllib.request
import zlib
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Tuple

UA = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36')
ORIGIN = 'https://live.bilibili.com'

LOG = logging.getLogger('live_danmu')


@dataclass
class LiveConf:
    """一次抓取任务的运行配置."""
    room_id: str
    out_path: str
    hb_interval: int = 30
    no_data_timeout: int = 120
    buvid: str = ''
    hosts: List[str] = field(default_factory=list)
    token: str = ''
    real_id: int = 0


def get_buvid(timeout: int = 15) -> str:
    """免费取一个 buvid3（finger/spi 接口，无需登录）.

    有 buvid 的匿名连接拿到的弹幕量和登录连接一样多；
    没有 buvid 只会得到限流后的稀疏流。

    Args:
        timeout: 超时秒数。

    Returns:
        buvid3，失败返回空串（降级为稀疏流但不断连）。
    """
    try:
        data = http_get_json('https://api.bilibili.com/x/frontend/finger/spi',
                             timeout=timeout)
        buvid = str((data.get('data') or {}).get('b_3', ''))
        return buvid if len(buvid) >= 8 else ''
    except Exception:  # noqa: BLE001 - 拿不到就降级
        return ''


def http_get_json(url: str, timeout: int = 15) -> dict:
    """GET 请求并解析 JSON，失败抛异常.

    Args:
        url: 请求地址。
        timeout: 超时秒数。

    Returns:
        解析后的 JSON dict。
    """
    req = urllib.request.Request(
        url, headers={'User-Agent': UA, 'Referer': ORIGIN})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode('utf-8', 'replace'))


def get_real_room_id(room_id: str, timeout: int = 15) -> int:
    """短号转真实 room_id（本身就是真实号则原样返回）.

    Args:
        room_id: 直播间号（支持短号）。
        timeout: 超时秒数。

    Returns:
        真实 room_id。
    """
    data = http_get_json(
        'https://api.live.bilibili.com/room/v1/Room/room_init?id=%s'
        % room_id, timeout=timeout)
    if data.get('code') == 0 and data.get('data'):
        return int(data['data'].get('room_id', room_id))
    return int(room_id)


def get_conf(room_id: int, timeout: int = 15,
             host_index: int = 0) -> Tuple[List[str], str]:
    """拿弹幕服务器列表和 token（旧 getConf 接口，无需登录）.

    Args:
        room_id: 真实 room_id。
        timeout: 超时秒数。
        host_index: 轮换起点，避免总打同一台。

    Returns:
        (host 列表去重保序, token)。
    """
    data = http_get_json(
        'https://api.live.bilibili.com/room/v1/Danmu/getConf'
        '?room_id=%s&platform=pc&player=web' % room_id, timeout=timeout)
    if data.get('code') != 0:
        raise RuntimeError('getConf failed: %r' % (data,))
    info = data['data']
    hosts = [h['host'] for h in info.get('host_server_list', [])
             if h.get('host')]
    if not hosts:
        hosts = [info.get('host', 'broadcastlv.chat.bilibili.com')]
    seen, uniq = set(), []
    for h in hosts:
        if h not in seen:
            seen.add(h)
            uniq.append(h)
    hosts = uniq
    start = host_index % len(hosts)
    return hosts[start:] + hosts[:start], info['token']


def bili_pack(payload: bytes, op: int, ver: int = 1, seq: int = 1) -> bytes:
    """B站弹幕协议封包：16 字节头 + body."""
    if isinstance(payload, str):
        payload = payload.encode('utf-8')
    return (struct.pack('>IHHII', 16 + len(payload), 16, ver, op, seq)
            + payload)


def ws_send(sock: socket.socket, data: bytes) -> None:
    """发一个 masked binary WS 帧（client 发包必须 mask）."""
    mask = os.urandom(4)
    n = len(data)
    if n < 126:
        sock.sendall(bytes([0x82, 0x80 | n]) + mask)
    elif n < 65536:
        sock.sendall(struct.pack('>BBH', 0x82, 0x80 | 126, n) + mask)
    else:
        sock.sendall(struct.pack('>BBQ', 0x82, 0x80 | 127, n) + mask)
    sock.sendall(bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def ws_connect(host: str) -> socket.socket:
    """裸 socket + ssl 做 WS 握手，返回已连接的 socket."""
    raw = socket.create_connection((host, 443), timeout=15)
    sock = ssl.create_default_context().wrap_socket(
        raw, server_hostname=host)
    key = base64.b64encode(os.urandom(16)).decode('ascii')
    sock.sendall('\r\n'.join([
        'GET /sub HTTP/1.1',
        'Host: %s:443' % host,
        'Upgrade: websocket',
        'Connection: Upgrade',
        'Sec-WebSocket-Key: %s' % key,
        'Sec-WebSocket-Version: 13',
        'Origin: %s' % ORIGIN,
        'User-Agent: %s' % UA,
        '', '']).encode('ascii'))
    resp = b''
    while b'\r\n\r\n' not in resp:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError('handshake: connection closed')
        resp += chunk
    if b' 101 ' not in resp.split(b'\r\n', 1)[0]:
        raise RuntimeError('handshake failed: %r' % resp[:120])
    return sock


def ws_recv_frames(sock: socket.socket,
                   buf: bytes) -> Tuple[List[Tuple[int, bytes]], bytes]:
    """从缓冲里抠完整的 WS 帧.

    Args:
        sock: 仅用于类型标注，实际只操作 buf。
        buf: 上次剩余的字节。

    Returns:
        (frames, rest_buf)，frames 为 [(opcode, payload), ...]。
        数据不够时返回已攒的，要求调用方继续 recv。
    """
    del sock  # 仅解析缓冲，不读 socket
    frames = []
    while len(buf) >= 2:
        b1, b2 = buf[0], buf[1]
        ln, masked = b2 & 0x7f, bool(b2 & 0x80)
        off = 2
        if ln == 126:
            if len(buf) < 4:
                break
            ln = struct.unpack('>H', buf[2:4])[0]
            off = 4
        elif ln == 127:
            if len(buf) < 10:
                break
            ln = struct.unpack('>Q', buf[2:10])[0]
            off = 10
        if masked:
            off += 4
        if len(buf) < off + ln:
            break
        payload = buf[off:off + ln]
        if masked:
            mask = buf[off - 4:off]
            payload = bytes(
                b ^ mask[i % 4] for i, b in enumerate(payload))
        frames.append((b1 & 0x0f, bytes(payload)))
        buf = buf[off + ln:]
    return frames, buf


def parse_bili_packet(data: bytes,
                      on_msg: Callable[[dict], None]) -> None:
    """解析 B站协议包（支持 ver=2 zlib 嵌套），弹幕回调 on_msg(dict)."""
    off = 0
    while off + 16 <= len(data):
        plen, _, ver, op, _ = struct.unpack('>IHHII', data[off:off + 16])
        if plen < 16 or off + plen > len(data):
            break
        body = data[off + 16:off + plen]
        if ver == 2:
            try:
                parse_bili_packet(zlib.decompress(body), on_msg)
            except zlib.error:
                pass
        elif op == 5:
            handled = False
            if b'\x00' in body:
                for seg in body.split(b'\x00'):
                    seg = seg.strip()
                    if seg.startswith(b'{'):
                        try:
                            on_msg(json.loads(seg.decode('utf-8', 'replace')))
                            handled = True
                        except ValueError:
                            pass
            if not handled:
                try:
                    on_msg(json.loads(body.decode('utf-8', 'replace')))
                except ValueError:
                    pass
        # op == 3 心跳回复（人气值），op == 8 鉴权回复，均忽略
        off += plen


def extract_danmu(msg: dict) -> Optional[Dict]:
    """从 B站推送 json 提取弹幕，返回 dict 或 None.

    mode/size 沿用 B站语义：mode 1=滚动 4=底部 5=顶部 6=逆向，
    size 25 为标准字号；lua 侧按 Danmu2Ass 规则换算。
    """
    try:
        cmd = msg.get('cmd', '')
        if cmd == 'DANMU_MSG':
            info = msg['info']
            text = str(info[1]).strip()
            if not text:
                return None
            user = str(info[2][1])
            try:
                color = int(info[0][3])
            except (IndexError, TypeError, ValueError):
                color = 16777215
            try:
                mode = int(info[0][1])
            except (IndexError, TypeError, ValueError):
                mode = 1
            try:
                size = int(info[0][2])
            except (IndexError, TypeError, ValueError):
                size = 25
            return {'user': user, 'text': text, 'color': color,
                    'mode': mode, 'size': size, 'type': 'danmu'}
        if cmd == 'SUPER_CHAT_MESSAGE':
            data = msg['data']
            text = str(data.get('message', '')).strip() or '（空）'
            user = str(data.get('user_info', {}).get('uname', 'SC'))
            bg = str(data.get('background_bottom_color', '#FFED4F00'))
            try:
                color = int(bg.lstrip('#')[-6:], 16)
            except ValueError:
                color = 16711680
            return {'user': user, 'text': text, 'color': color,
                    'mode': 1, 'size': 25, 'type': 'sc',
                    'price': data.get('price', 0)}
    except (KeyError, IndexError, TypeError, AttributeError):
        pass
    return None


def keepalive() -> None:
    """向 stdout 写一个心跳：mpv 一直在读该管道，mpv 退出后写会报错.

    这是防止 mpv 被强杀后本进程变成孤儿的关键：一旦 stdio 断开即退出。
    用 os._exit 直接退，避免解释器退出时再次 flush 这个坏管道而报错。
    """
    try:
        sys.stdout.write('\n')
        sys.stdout.flush()
    except (BrokenPipeError, OSError, ValueError):
        os._exit(0)


def init_conf(conf: LiveConf) -> None:
    """取真实 room_id 与服务器配置，失败则退避重试（不直接崩）."""
    delay = 2
    while not conf.hosts:
        try:
            conf.real_id = get_real_room_id(conf.room_id)
            conf.hosts, conf.token = get_conf(conf.real_id)
            if not conf.buvid:
                conf.buvid = get_buvid()
        except Exception as e:  # noqa: BLE001 - 网络抖动全部重试
            LOG.warning('init failed (%s), retry in %ss', e, delay)
            keepalive()
            time.sleep(delay)
            delay = min(delay * 2, 30)
    LOG.info('room=%s real=%s hosts=%s',
             conf.room_id, conf.real_id, conf.hosts)


def serve_once(conf: LiveConf, host: str, fout) -> None:
    """单次连接：握手鉴权后收弹幕写文件，断线抛异常由上层重连."""
    sock = ws_connect(host)
    try:
        auth = {'uid': 0, 'roomid': conf.real_id, 'protover': 2,
                'platform': 'web', 'type': 2, 'key': conf.token}
        if conf.buvid:
            auth['buvid'] = conf.buvid
        ws_send(sock, bili_pack(json.dumps(auth).encode('utf-8'), 7))
        sock.settimeout(1.0)  # 短超时：便于每秒探测 mpv 是否还活着
        buf, last_hb, last_data = b'', time.time(), time.time()

        def _cb(m, _f=fout):
            danmu = extract_danmu(m)
            if danmu:
                _f.write(json.dumps(danmu, ensure_ascii=False) + '\n')
                _f.flush()

        while True:
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                chunk = b''
            if chunk:
                last_data = time.time()
                buf += chunk
                frames, buf = ws_recv_frames(sock, buf)
                for opcode, payload in frames:
                    if opcode == 0x8:  # close
                        raise RuntimeError('server closed ws')
                    if opcode == 0x9:  # ping → pong
                        sock.sendall(b'\x8a\x80' + os.urandom(4))
                    elif opcode in (0x2, 0x1):
                        parse_bili_packet(payload, _cb)
            now = time.time()
            # 每秒探测：mpv 退出后管道断裂，这里会抛错并退出进程
            keepalive()
            if now - last_hb >= conf.hb_interval:
                ws_send(sock, bili_pack(b'', 2))
                last_hb = now
            if now - last_data > conf.no_data_timeout:
                raise RuntimeError('no data for %ss, reconnect'
                                   % conf.no_data_timeout)
    finally:
        try:
            sock.close()
        except Exception:  # noqa: BLE001 - 关闭尽力而为
            pass


def run(room_id: str, out_path: str, hb_interval: int = 30,
        no_data_timeout: int = 120) -> None:
    """主循环：连接 → 收弹幕 → 写 jsonl，断线自动重连.

    Args:
        room_id: 直播间号（支持短号）。
        out_path: 输出 jsonl 路径。
        hb_interval: 心跳间隔秒。
        no_data_timeout: 无数据则重连的秒数。
    """
    conf = LiveConf(room_id=room_id, out_path=out_path,
                    hb_interval=hb_interval,
                    no_data_timeout=no_data_timeout)
    with open(conf.out_path, 'w', encoding='utf-8'):
        pass  # 启动即清空旧文件，防止上次残留弹幕涌入
    init_conf(conf)
    delay, host_idx = 2, 0
    while True:
        host = conf.hosts[host_idx % len(conf.hosts)]
        try:
            with open(conf.out_path, 'a', encoding='utf-8') as fout:
                serve_once(conf, host, fout)
            delay = 2  # 连上后重置退避（正常不会走到：serve_once 不返回）
        except (OSError, RuntimeError, ssl.SSLError) as e:
            LOG.warning('disconnect (%s), retry in %ss', e, delay)
            time.sleep(delay)
            delay = min(delay * 2, 30)
            host_idx += 1
            try:
                conf.hosts, conf.token = get_conf(conf.real_id)
            except Exception:  # noqa: BLE001 - 刷新失败就用旧的继续
                pass


def main(argv=None) -> int:
    """命令行入口.

    Args:
        argv: 参数列表（None 则取 sys.argv）。

    Returns:
        退出码。
    """
    logging.basicConfig(level=logging.WARNING,
                        format='live_danmu: %(message)s', stream=sys.stderr)
    parser = argparse.ArgumentParser(description='B站直播弹幕抓取 → jsonl')
    parser.add_argument('room_id', help='直播间号（支持短号）')
    parser.add_argument('outfile', help='输出 jsonl 文件路径')
    parser.add_argument('--hb', type=int, default=30, help='心跳间隔秒')
    args = parser.parse_args(argv)
    try:
        run(args.room_id, args.outfile, hb_interval=args.hb)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == '__main__':
    sys.exit(main())
