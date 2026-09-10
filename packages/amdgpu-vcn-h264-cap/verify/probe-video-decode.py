#!/usr/bin/env python3
"""Probe the kiosk Chromium's video decode path for silent green-frame failures.

Context: feral-file/ffos-user#302 (fix: the amdgpu-vcn-h264-cap package one directory up). On FF1 (Radeon 680M, VCN 3.1.1) an H.264
clip at 4096x4096 "plays" through VA-API but every decoded frame is an
all-zero NV12 surface, which the BT.709 limited-range conversion paints as a
flat RGB (0, 77, 0) green. No <video> error fires, so the player cannot see it.
This script turns the manual measurement from the issue into something that
can be re-run on any device after a kernel/Mesa/Chromium bump, and that can
bisect the exact resolution where the decoder gives up.

How it works (all on the device, no extra packages):
  1. Serves a directory of test clips over HTTP on 127.0.0.1 with CORS and
     Range support (Chromium needs both: CORS so the canvas readback is not
     tainted, Range because the media stack fetches byte ranges).
  2. Connects to the kiosk Chromium's DevTools socket (--remote-debugging-port
     9222 in start-kiosk.sh) with a minimal hand-rolled WebSocket client and
     picks the player page target.
  3. For each clip, evaluates an in-page probe that loads the clip in a
     DETACHED <video> (never inserted into the DOM, so nothing is drawn on the
     wall), waits for the first presented frame, samples two frames a second
     apart into a 32x32 canvas, and reports average colour + spread.
  4. Prints one row per clip: decoded size, macroblock count, and a verdict:
     `ok` (two distinct frames, decode progressing), `GREEN` (the zero-YUV
     signature), `flat frame`, `STALLED` (no playback or decode progress
     between samples), `unmeasured` (canvas readback failed), `error`, or
     `timeout`. Clips named `h264_*`/`hevc_*` also get Chromium's
     mediaCapabilities `powerEfficient` answer for that codec at that size.

Usage (on the device, as the feralfile user, from this directory):
  python3 probe-video-decode.py --clips /home/feralfile/probe-clips
  python3 probe-video-decode.py --manifest manifests/bytedance-hevc-demo.json
  python3 probe-video-decode.py --clips ./clips --manifest demo.json --json results.json

Remote manifests are played straight from their URLs, so the CDN must send
Access-Control-Allow-Origin (otherwise every row reads "unmeasured").

Generate clips on a machine with ffmpeg via gen-video-decode-probe-clips.sh
and copy them over. The probe competes with the on-screen artwork for the
hardware decoder while a clip is loading; run it on a device that is not
being demoed.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.server
import json
import os
import re
import socket
import struct
import sys
import threading
import urllib.parse
import urllib.request
from pathlib import Path

CLIP_SUFFIXES = {".mp4", ".webm", ".mov", ".mkv"}
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

# Kept as a Python format string so the clip URL/timeout are substituted as
# JSON literals; the function body is otherwise plain browser JS.
PROBE_JS = r"""
(async (url, timeoutMs, codec) => {
  const out = { url };
  const v = document.createElement('video');
  v.muted = true;
  v.playsInline = true;
  v.preload = 'auto';
  v.crossOrigin = 'anonymous';
  v.loop = false;
  const settled = new Promise((resolve) => {
    const timer = setTimeout(() => resolve('timeout'), timeoutMs);
    v.addEventListener('error', () => { clearTimeout(timer); resolve('error'); }, { once: true });
    const onFrame = () => { clearTimeout(timer); resolve('frame'); };
    if (typeof v.requestVideoFrameCallback === 'function') {
      v.requestVideoFrameCallback(onFrame);
    } else {
      v.addEventListener('loadeddata', onFrame, { once: true });
    }
  });
  v.src = url;
  v.load();
  v.play().catch(() => {});
  out.outcome = await settled;
  out.width = v.videoWidth;
  out.height = v.videoHeight;
  out.readyState = v.readyState;
  out.error = v.error ? { code: v.error.code, message: v.error.message } : null;
  const q = typeof v.getVideoPlaybackQuality === 'function' ? v.getVideoPlaybackQuality() : null;
  out.decodedFrames = q ? q.totalVideoFrames : (v.webkitDecodedFrameCount ?? null);
  out.droppedFrames = q ? q.droppedVideoFrames : (v.webkitDroppedFrameCount ?? null);
  if (codec && navigator.mediaCapabilities && out.width && out.height) {
    try {
      const info = await navigator.mediaCapabilities.decodingInfo({
        type: 'file',
        video: {
          contentType: 'video/mp4; codecs="' + codec + '"',
          width: out.width,
          height: out.height,
          bitrate: 20000000,
          framerate: 30,
        },
      });
      out.mediaCapabilities = {
        supported: info.supported,
        smooth: info.smooth,
        powerEfficient: info.powerEfficient,
      };
    } catch (e) {
      out.mediaCapabilities = { error: String(e) };
    }
  }
  if (out.outcome === 'frame') {
    const sample = () => {
      const c = document.createElement('canvas');
      c.width = 32;
      c.height = 32;
      const ctx = c.getContext('2d', { willReadFrequently: true });
      ctx.drawImage(v, 0, 0, 32, 32);
      const d = ctx.getImageData(0, 0, 32, 32).data;
      const sum = [0, 0, 0];
      const min = [255, 255, 255];
      const max = [0, 0, 0];
      for (let i = 0; i < d.length; i += 4) {
        for (let k = 0; k < 3; k++) {
          const x = d[i + k];
          sum[k] += x;
          if (x < min[k]) min[k] = x;
          if (x > max[k]) max[k] = x;
        }
      }
      const n = d.length / 4;
      const quality = typeof v.getVideoPlaybackQuality === 'function' ? v.getVideoPlaybackQuality() : null;
      return {
        t: Number(v.currentTime.toFixed(2)),
        // Decoded-frame progress is the stall signal; pixel identity is not,
        // because static and slow artworks legitimately repeat frames.
        frames: quality ? quality.totalVideoFrames : (v.webkitDecodedFrameCount ?? null),
        avg: sum.map((s) => Math.round(s / n)),
        spread: Math.max(...max.map((m, k) => m - min[k])),
      };
    };
    const samples = [];
    try {
      samples.push(sample());
      // A legitimate clip can open on a flat frame; a second sample a
      // second later separates "flat title card" from "decoder wrote nothing".
      await new Promise((r) => setTimeout(r, 1000));
      samples.push(sample());
    } catch (e) {
      out.sampleError = String(e);
    }
    out.samples = samples;
    out.flat = samples.length > 0 && samples.every((s) => s.spread <= 4);
    // BT.709 limited range, Y=U=V=0 -> RGB (0, 77, 0). Tolerances absorb
    // rounding differences between the GPU and software YUV->RGB paths.
    out.zeroYuvGreen = out.flat && samples.every(
      (s) => s.avg[0] <= 8 && Math.abs(s.avg[1] - 77) <= 12 && s.avg[2] <= 8
    );
  }
  v.pause();
  v.removeAttribute('src');
  v.load();
  return out;
})(%s, %d, %s)
"""


class ClipRequestHandler(http.server.SimpleHTTPRequestHandler):
    """Static file server with CORS and single-range support for media."""

    def log_message(self, format, *args):  # noqa: A002 - stdlib signature
        pass

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def send_head(self):
        # Per-request state. The handler serves one request per connection
        # today (HTTP/1.0), but a stale value would truncate the next full
        # response on a keep-alive connection, so reset it unconditionally.
        self._range_remaining = None
        path = self.translate_path(self.path)
        range_header = self.headers.get("Range")
        if not range_header or not os.path.isfile(path):
            return super().send_head()
        match = re.fullmatch(r"bytes=(\d*)-(\d*)", range_header.strip())
        size = os.path.getsize(path)
        if not match:
            return super().send_head()
        start = int(match.group(1)) if match.group(1) else None
        end = int(match.group(2)) if match.group(2) else None
        if start is None:
            # Suffix range: last N bytes.
            start = max(0, size - (end or 0))
            end = size - 1
        else:
            end = size - 1 if end is None else min(end, size - 1)
        if start >= size or start > end:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.end_headers()
            return None
        fh = open(path, "rb")  # noqa: SIM115 - returned to caller, closed by copyfile path
        fh.seek(start)
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        self._range_remaining = end - start + 1
        return fh

    def copyfile(self, source, outputfile):
        # Chromium's media stack opens a range, reads the moov atom, then drops
        # the connection and re-requests from where the samples start. Those
        # aborted bodies surface here as broken pipes and are not failures.
        try:
            remaining = getattr(self, "_range_remaining", None)
            if remaining is None:
                return super().copyfile(source, outputfile)
            while remaining > 0:
                chunk = source.read(min(64 * 1024, remaining))
                if not chunk:
                    break
                outputfile.write(chunk)
                remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass
        return None


def serve_clips(directory: Path, port: int) -> http.server.ThreadingHTTPServer:
    def handler(*args, **kwargs):
        return ClipRequestHandler(*args, directory=str(directory), **kwargs)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


class CDPSession:
    """Just enough RFC 6455 to drive the DevTools protocol without a dependency."""

    def __init__(self, ws_url: str, timeout: float):
        parsed = urllib.parse.urlparse(ws_url)
        self.sock = socket.create_connection((parsed.hostname, parsed.port), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            f"GET {parsed.path} HTTP/1.1\r\n"
            f"Host: {parsed.hostname}:{parsed.port}\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(request.encode())
        # Bytes that arrive after the handshake terminator already belong to
        # the first WebSocket frame; keep them for the frame parser instead of
        # dropping them. Nothing is sent unsolicited today (no CDP domain is
        # enabled), but enabling one would otherwise desynchronise the stream.
        response, self._pending = self._read_handshake()
        status_line = response.split(b"\r\n", 1)[0]
        if b" 101 " not in status_line:
            raise ConnectionError(f"DevTools handshake failed: {status_line!r}")
        expected = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        if expected.encode() not in response:
            raise ConnectionError("DevTools handshake returned a bad Sec-WebSocket-Accept")
        self.next_id = 0

    def _read_handshake(self) -> tuple[bytes, bytes]:
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("DevTools socket closed during handshake")
            buf += chunk
        head, _, surplus = buf.partition(b"\r\n\r\n")
        return head, surplus

    def _recv_exact(self, n: int) -> bytes:
        buf = self._pending[:n]
        self._pending = self._pending[n:]
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("DevTools socket closed")
            buf += chunk
        return buf

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        header = bytearray([0x80 | opcode])
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", n)
        mask = os.urandom(4)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(header) + masked)

    def _recv_message(self) -> str:
        buf = b""
        while True:
            b1, b2 = self._recv_exact(2)
            opcode = b1 & 0x0F
            fin = b1 & 0x80
            n = b2 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._recv_exact(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._recv_exact(8))[0]
            if b2 & 0x80:
                self._recv_exact(4)  # servers must not mask, tolerate anyway
            payload = self._recv_exact(n)
            if opcode == 0x8:
                raise ConnectionError("DevTools closed the socket")
            if opcode == 0x9:
                self._send_frame(0xA, payload)
                continue
            if opcode == 0xA:
                continue
            buf += payload
            if fin:
                return buf.decode()

    def call(self, method: str, params: dict | None = None) -> dict:
        self.next_id += 1
        message_id = self.next_id
        self._send_frame(0x1, json.dumps({"id": message_id, "method": method, "params": params or {}}).encode())
        while True:
            message = json.loads(self._recv_message())
            if message.get("id") != message_id:
                continue  # unsolicited event
            if "error" in message:
                raise RuntimeError(f"{method}: {message['error']}")
            return message.get("result", {})

    def close(self) -> None:
        try:
            self._send_frame(0x8, b"")
        finally:
            self.sock.close()


def find_player_target(devtools_http: str, page_prefix: str) -> dict:
    with urllib.request.urlopen(f"{devtools_http}/json", timeout=5) as resp:
        targets = json.load(resp)
    pages = [t for t in targets if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
    for target in pages:
        if target.get("url", "").startswith(page_prefix):
            return target
    if pages:
        return pages[0]
    raise SystemExit(f"no page target at {devtools_http}; is chromium-kiosk running with --remote-debugging-port?")


# mediaCapabilities answers for the codec string it is given, not for the clip,
# so the string must follow the clip's codec or an HEVC row would print
# Chromium's opinion of H.264. Levels are chosen to hold the largest clip in
# the default bracket: H.264 Level 5.2 (0x34) is what the kernel table
# advertises; HEVC Level 6 (180) is the first level whose luma budget fits
# 4096x4096. The prefixes are the ones gen-video-decode-probe-clips.sh writes.
CODEC_BY_PREFIX = {
    "h264_": "avc1.640034",
    "hevc_": "hvc1.1.6.L180.B0",
}


def codec_for_clip(name: str, fallback: str) -> str | None:
    for prefix, codec in CODEC_BY_PREFIX.items():
        if name.startswith(prefix):
            return codec
    return fallback or None


def probe_clip(session: CDPSession, url: str, timeout_ms: int, codec: str | None) -> dict:
    expression = PROBE_JS % (json.dumps(url), timeout_ms, json.dumps(codec))
    result = session.call(
        "Runtime.evaluate",
        {"expression": expression, "awaitPromise": True, "returnByValue": True},
    )
    if "exceptionDetails" in result:
        return {"url": url, "outcome": "exception", "exception": result["exceptionDetails"].get("text")}
    return result.get("result", {}).get("value", {"url": url, "outcome": "no-value"})


def verdict(row: dict) -> str:
    outcome = row.get("outcome")
    if outcome == "frame":
        # "ok" must mean "two distinct, non-flat frames were read back". Anything
        # short of that is reported as its own state so a stalled decoder or a
        # tainted canvas can never print as a healthy row; §5 of the plan uses
        # this column as the acceptance signal for a driver patch.
        if row.get("sampleError"):
            return f"unmeasured (canvas readback failed: {row['sampleError']})"
        samples = row.get("samples") or []
        if len(samples) < 2:
            return "unmeasured (fewer than two samples)"
        if row.get("zeroYuvGreen"):
            return "GREEN (zero-YUV surface)"
        if row.get("flat"):
            return "flat frame (not the green signature)"
        first, second = samples[0], samples[1]
        if first["t"] == second["t"]:
            return "STALLED (currentTime did not advance between samples)"
        frames_known = first.get("frames") is not None and second.get("frames") is not None
        if frames_known and second["frames"] <= first["frames"]:
            return "STALLED (no new decoded frames between samples)"
        return "ok"
    if outcome == "error":
        err = row.get("error") or {}
        return f"error code={err.get('code')} {err.get('message', '')}".strip()
    return str(outcome)


def load_manifest(path: Path) -> list[dict]:
    """Remote clips: [{name, url, codec}] under "items". The CDN must send
    Access-Control-Allow-Origin, or the canvas readback is tainted and every
    row prints as unmeasured; bytedance-hevc-demo.json is known to."""
    doc = json.loads(path.read_text())
    items = doc if isinstance(doc, list) else doc.get("items", [])
    entries = []
    for item in items:
        if not item.get("url"):
            continue
        entries.append({
            "label": item.get("name") or item["url"].rsplit("/", 1)[-1],
            "url": item["url"],
            "codec": item.get("codec") or None,
        })
    return entries


def print_row(label: str, row: dict, codec: str | None) -> None:
    size = f"{row.get('width', '?')}x{row.get('height', '?')}"
    mbs = ""
    if row.get("width") and row.get("height"):
        mbs = f" {(-(-row['width'] // 16)) * (-(-row['height'] // 16))} MBs"
    samples = row.get("samples") or []
    avg = f" avg={samples[0]['avg']}" if samples else ""
    mc = row.get("mediaCapabilities")
    mc_text = (
        f" powerEfficient({codec})={mc.get('powerEfficient')}"
        if isinstance(mc, dict) and "powerEfficient" in mc
        else ""
    )
    print(f"{label:40s} {size:>10s}{mbs:>12s}  {verdict(row)}{avg}{mc_text}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--clips", type=Path, help="directory of local test clips (served on --port)")
    parser.add_argument(
        "--manifest",
        type=Path,
        action="append",
        default=[],
        help="JSON manifest of remote clips to play straight from their URLs (repeatable)",
    )
    parser.add_argument("--port", type=int, default=8765, help="local port to serve clips on")
    parser.add_argument("--devtools", default="http://127.0.0.1:9222", help="Chromium DevTools HTTP endpoint")
    parser.add_argument("--page-prefix", default="http://127.0.0.1:8080", help="URL prefix of the player page target")
    parser.add_argument("--timeout", type=float, default=20.0, help="seconds to wait for a first frame per clip")
    parser.add_argument(
        "--codec",
        default="",
        help=(
            "codec string for the navigator.mediaCapabilities query on local clips whose "
            "filename has no h264_/hevc_ prefix (the generator always writes one); "
            "prefixed clips and manifest entries pick their own string"
        ),
    )
    parser.add_argument("--only", default="", help="substring filter on clip labels")
    parser.add_argument("--json", type=Path, help="also write raw results to this file")
    args = parser.parse_args()

    entries: list[dict] = []
    server = None
    if args.clips:
        clips = sorted(p for p in args.clips.iterdir() if p.suffix.lower() in CLIP_SUFFIXES)
        for clip in clips:
            entries.append({
                "label": clip.name,
                "url": f"http://127.0.0.1:{args.port}/{urllib.parse.quote(clip.name)}",
                "codec": codec_for_clip(clip.name, args.codec),
            })
        if clips:
            server = serve_clips(args.clips.resolve(), args.port)
    for manifest in args.manifest:
        entries.extend(load_manifest(manifest))
    if not entries:
        print("nothing to probe: pass --clips <dir> and/or --manifest <json>", file=sys.stderr)
        return 2
    if args.only:
        total = len(entries)
        entries = [e for e in entries if args.only in e["label"]]
        if not entries:
            print(f"--only {args.only!r} matched none of the {total} clips", file=sys.stderr)
            return 2

    target = find_player_target(args.devtools, args.page_prefix)
    print(f"probing {len(entries)} clips via page target {target.get('url')}", flush=True)
    session = CDPSession(target["webSocketDebuggerUrl"], timeout=args.timeout + 10)
    results = []
    try:
        for entry in entries:
            row = probe_clip(session, entry["url"], int(args.timeout * 1000), entry["codec"])
            row["clip"] = entry["label"]
            row["mediaCapabilitiesCodec"] = entry["codec"]
            results.append(row)
            print_row(entry["label"], row, entry["codec"])
    finally:
        session.close()
        if server is not None:
            server.shutdown()

    if args.json:
        args.json.write_text(json.dumps(results, indent=2))
        print(f"raw results written to {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
