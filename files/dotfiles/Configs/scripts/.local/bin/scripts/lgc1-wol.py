#!/usr/bin/env python3
import argparse
import base64
import json
import os
import socket
import struct
import sys
import time

# --- Configuration (edit here or override via env vars) ---
CFG_IP = os.environ.get("TV_IP", "192.168.1.154")
CFG_MAC = os.environ.get("TV_MAC", "70:97:41:9c:71:60")
CFG_PORT = int(os.environ.get("WS_PORT", "3000"))
CFG_INPUT = os.environ.get("TV_INPUT", "hdmi1")
CFG_KEYFILE = os.path.expanduser(os.environ.get("KEY_FILE", "~/.cache/.lg-tv-key.json"))


def wol(mac: str):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    mac_bytes = bytes.fromhex(mac.replace(":", "").replace("-", ""))
    s.sendto(b"\xff" * 6 + mac_bytes * 16, ("255.255.255.255", 9))


def wait_port(ip: str, port: int, timeout: int = 120):
    for _ in range(timeout):
        try:
            s = socket.create_connection((ip, port), timeout=2)
            s.close()
            return True
        except (TimeoutError, OSError):
            time.sleep(2)
    return False


class WebSocket:
    def __init__(self, host: str, port: int, timeout: int = 10):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self._port = port
        self._handshake(host)

    def _handshake(self, host: str):
        key = base64.b64encode(os.urandom(16)).decode()
        req = (
            f"GET / HTTP/1.1\r\n"
            f"Host: {host}:{self._port}\r\n"
            f"Upgrade: websocket\r\n"
            f"Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n"
            f"\r\n"
        )
        self.sock.sendall(req.encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("WebSocket handshake failed")
            resp += chunk
        if b"101" not in resp.split(b"\r\n")[0]:
            raise ConnectionError(
                f"Handshake failed: {resp.decode(errors='replace')[:200]}"
            )

    def send(self, data: str):
        payload = data.encode()
        mask = os.urandom(4)
        frame = bytearray()
        frame.append(0x81)
        n = len(payload)
        if n < 126:
            frame.append(0x80 | n)
        elif n < 65536:
            frame.append(0x80 | 126)
            frame.extend(struct.pack(">H", n))
        else:
            frame.append(0x80 | 127)
            frame.extend(struct.pack(">Q", n))
        frame.extend(mask)
        frame.extend(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(frame))

    def recv(self) -> str:
        head = self._read(2)
        if not head:
            return ""
        opcode = head[0] & 0x0F
        if opcode == 0x8:
            return ""
        mask = head[1] >> 7
        n = head[1] & 0x7F
        if n == 126:
            n = struct.unpack(">H", self._read(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", self._read(8))[0]
        key = self._read(4) if mask else b""
        payload = self._read(n)
        if mask:
            payload = bytes(b ^ key[i % 4] for i, b in enumerate(payload))
        return payload.decode()

    def _read(self, n: int) -> bytes:
        data = b""
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk:
                raise ConnectionError("Connection closed")
            data += chunk
        return data

    def close(self):
        try:
            self.sock.sendall(b"\x88\x00")
        finally:
            self.sock.close()


def _load_key(path: str) -> str:
    try:
        with open(path) as f:
            return json.load(f).get("client-key", "")
    except (FileNotFoundError, json.JSONDecodeError):
        return ""


def _save_key(path: str, key: str):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as f:
        json.dump({"client-key": key}, f)


def _register(ws: WebSocket, client_key: str) -> str:
    reg = {
        "type": "register",
        "id": "register_0",
        "payload": {
            "forcePairing": False,
            "pairingType": "PROMPT",
            "manifest": {
                "manifestVersion": 1,
                "appVersion": "1.0",
                "signed": {
                    "created": "20240501",
                    "appId": "com.lgtv2.app",
                    "vendorId": "com.lgtv2",
                    "localizedAppNames": {"": "LGTV2"},
                    "localizedVendorNames": {"": "LGTV2"},
                    "permissions": ["ALL"],
                    "serial": "12345678",
                    "service": False,
                },
                "permissions": [
                    "CONTROL_INPUT_TEXT",
                    "CONTROL_MOUSE_AND_KEYBOARD",
                    "CONTROL_INPUT_JOYSTICK",
                    "CONTROL_INPUT_MEDIA_PLAYBACK",
                    "CONTROL_INPUT_TV",
                    "CONTROL_POWER",
                    "READ_INSTALLED_APPS",
                    "READ_INPUT_DEVICE_LIST",
                    "READ_RUNNING_APPS",
                    "READ_TV_CHANNEL_LIST",
                    "WRITE_NOTIFICATION_TOAST",
                    "LAUNCH",
                    "LAUNCH_WEBAPP",
                    "APP_TO_APP",
                    "CLOSE",
                    "TEST_OPEN",
                    "TEST_PROTECTED",
                    "CONTROL_AUDIO",
                    "CONTROL_DISPLAY",
                    "CONTROL_USER_CONFIG",
                ],
                "signatures": [{"signatureVersion": 1, "signature": "all"}],
            },
        },
    }
    if client_key:
        reg["payload"]["client-key"] = client_key
    ws.send(json.dumps(reg))
    while True:
        resp = json.loads(ws.recv())
        if resp.get("type") == "registered":
            return resp.get("payload", {}).get("client-key", "")
        if resp.get("type") == "error":
            raise ConnectionError(f"Registration failed: {resp}")


def _ssap_request(ws: WebSocket, uri: str, payload: dict) -> dict:
    req = {"type": "request", "id": "req_1", "uri": uri, "payload": payload}
    ws.send(json.dumps(req))
    return json.loads(ws.recv())


def switch_lg_input(ip: str, port: int, key_file: str, input_id: str):
    client_key = _load_key(key_file)
    ws = WebSocket(ip, port, timeout=15)
    try:
        try:
            new_key = _register(ws, client_key)
        except ConnectionError as e:
            if "401" in str(e) and client_key:
                os.remove(key_file)
                ws.close()
                ws = WebSocket(ip, port, timeout=15)
                new_key = _register(ws, "")
            else:
                raise
        if new_key and new_key != client_key:
            _save_key(key_file, new_key)
        _ssap_request(
            ws, "ssap://system.launcher/launch", {"id": f"com.webos.app.{input_id}"}
        )
    finally:
        ws.close()


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Wake an LG TV and switch input via WebSocket SSAP.",
        epilog=(
            "All options can also be set via environment variables: "
            "TV_IP, TV_MAC, WS_PORT, KEY_FILE, TV_INPUT. "
            "Pass -- <cmd> to exec a command after waking the TV."
        ),
    )
    p.add_argument("--ip", default=CFG_IP, help="TV IP (env: TV_IP)")
    p.add_argument("--mac", default=CFG_MAC, help="TV MAC address (env: TV_MAC)")
    p.add_argument(
        "--port", type=int, default=CFG_PORT, help="WebSocket port (env: WS_PORT)"
    )
    p.add_argument(
        "--key-file",
        default=CFG_KEYFILE,
        help="Client-key cache file (env: KEY_FILE)",
    )
    p.add_argument(
        "--input",
        default=CFG_INPUT,
        help="TV input ID suffix (env: TV_INPUT, default: hdmi1 → com.webos.app.hdmi1)",
    )
    return p.parse_args(argv)


def main():
    cmd = None
    if "--" in sys.argv:
        idx = sys.argv.index("--")
        cmd = sys.argv[idx + 1 :]
        sys.argv = sys.argv[:idx]
    args = parse_args()
    print("Waking TV...")
    wol(args.mac)
    print(f"Waiting for {args.ip}:{args.port} ...")
    if not wait_port(args.ip, args.port):
        print("Timed out waiting for TV", file=sys.stderr)
        sys.exit(1)
    print(f"Switching to {args.input}...")
    switch_lg_input(args.ip, args.port, args.key_file, args.input)
    if cmd:
        os.execvp(cmd[0], cmd)
    print("Done.")


if __name__ == "__main__":
    main()
