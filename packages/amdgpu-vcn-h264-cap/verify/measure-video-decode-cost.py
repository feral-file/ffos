#!/usr/bin/env python3
"""Measure what a clip costs the device to decode.

Companion to probe-video-decode.py (same directory; imported for its clip
server and DevTools client). Plays each named clip for N seconds in a
detached <video> inside the kiosk page and reports decoded frame rate,
dropped frames, whole-system CPU busy (from /proc/stat, averaged over the
window) and amdgpu busy percent sampled once before and once after. Written for #302 to price the software-decode
path that a corrected driver cap would send 4096x4096 H.264 down:

  python3 measure-video-decode-cost.py /home/feralfile/probe-clips \
      h264_3840x2160.mp4,h264_4096x4096.mp4 10

CPU is system-wide, so run it on an otherwise idle wall; the on-screen
artwork's own decode is included in the number.
"""
import importlib.util
import json
import pathlib
import sys
import urllib.parse

spec = importlib.util.spec_from_file_location(
    "probe", pathlib.Path(__file__).with_name("probe-video-decode.py")
)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

def cpu_snapshot():
    with open("/proc/stat") as fh:
        f = fh.readline().split()
    vals = list(map(int, f[1:]))
    idle = vals[3] + vals[4]
    return sum(vals), idle

def gpu_busy():
    for p in pathlib.Path("/sys/class/drm").glob("card*/device/gpu_busy_percent"):
        try: return int(p.read_text().strip())
        except Exception: pass
    return None

PLAY_JS = """
(async (url, seconds) => {
  const v = document.createElement('video');
  v.muted = true; v.playsInline = true; v.preload = 'auto'; v.crossOrigin = 'anonymous'; v.loop = true;
  v.src = url; v.load(); await v.play().catch(() => {});
  const t0 = performance.now();
  await new Promise(r => setTimeout(r, seconds * 1000));
  const q = v.getVideoPlaybackQuality();
  const out = { width: v.videoWidth, height: v.videoHeight, currentTime: v.currentTime,
    total: q.totalVideoFrames, dropped: q.droppedVideoFrames, wall: (performance.now() - t0) / 1000,
    error: v.error ? { code: v.error.code, message: v.error.message } : null };
  v.pause(); v.removeAttribute('src'); v.load();
  return out;
})(%s, %d)
"""

if len(sys.argv) != 4:
    print("usage: measure-video-decode-cost.py <clips-dir> <name,name,...> <seconds>", file=sys.stderr)
    sys.exit(2)
clips_dir = pathlib.Path(sys.argv[1])
names = sys.argv[2].split(",")
seconds = int(sys.argv[3])
port = 8766
server = probe.serve_clips(clips_dir.resolve(), port)
target = probe.find_player_target("http://127.0.0.1:9222", "http://127.0.0.1:8080")
session = probe.CDPSession(target["webSocketDebuggerUrl"], timeout=seconds + 30)
try:
    for name in names:
        url = f"http://127.0.0.1:{port}/{urllib.parse.quote(name)}"
        t_a, i_a = cpu_snapshot(); g_a = gpu_busy()
        res = session.call("Runtime.evaluate", {"expression": PLAY_JS % (json.dumps(url), seconds), "awaitPromise": True, "returnByValue": True})
        t_b, i_b = cpu_snapshot(); g_b = gpu_busy()
        v = res.get("result", {}).get("value", {})
        busy = 100.0 * (1 - (i_b - i_a) / max(1, (t_b - t_a)))
        # A clip that never decoded must not print as a cheap one: the CPU
        # number below would be the idle wall, not the codec's cost.
        if v.get("error") or not v.get("total"):
            err = v.get("error") or {}
            print(f"{name:28s} FAILED to decode: error={err.get('code')} {err.get('message', '')} "
                  f"frames={v.get('total', 0)} (cost not measured)", flush=True)
            continue
        fps = v["total"] / max(0.001, v.get("wall", 1))
        print(f"{name:28s} {v.get('width')}x{v.get('height')}  frames={v['total']} dropped={v.get('dropped')} "
              f"decoded_fps={fps:.1f}  system_cpu={busy:.1f}% of {probe.os.cpu_count()} threads  gpu_busy={g_a}->{g_b}%", flush=True)
finally:
    session.close(); server.shutdown()
