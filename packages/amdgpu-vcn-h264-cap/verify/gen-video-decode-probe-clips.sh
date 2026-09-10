#!/usr/bin/env bash
# Generate the synthetic clips consumed by probe-video-decode.py.
#
# Context: feral-file/ffos-user#302. The FF1's VCN 3.1.1 H.264 decoder returns
# an untouched (all-zero, i.e. green) surface at 4096x4096 while 4096x3072
# decodes fine. The kernel advertises the codec at 4096x4096, so nothing in the
# stack refuses the stream. The resolutions below bracket that cliff in
# macroblock terms so a single probe run answers "where exactly does it break":
#
#   4096x3072 = 49,152 MBs  known good (issue #302)
#   4096x3584 = 57,344 MBs
#   4096x3840 = 61,440 MBs
#   4096x4080 = 65,280 MBs  one macroblock row short of 2^16
#   4080x4096 = 65,280 MBs  same count, other axis (rules out a pure height cap)
#   4096x4096 = 65,536 MBs  known green (issue #302)
#
# If 65,280 decodes and 65,536 does not on both axes, the limit is the frame
# macroblock count, not width or height alone. That is the fact any driver
# patch (kernel amdgpu codec table or Mesa radeonsi cap) has to be built on.
# Measured 2026-09-10 on FF1-8EVTK3RE: exactly that, H.264 only; the HEVC
# twins (--hevc) all decode, 4096x4096 included. See
# the package README and ffos-user#302.
#
# Requires ffmpeg with libx264 (and libx265 for --hevc). Run on a dev machine,
# then copy the output directory to the device, e.g.
#   verify/gen-video-decode-probe-clips.sh /tmp/probe-clips
#   scp -r /tmp/probe-clips feralfile@<device>:/home/feralfile/probe-clips
#
# testsrc2 is used deliberately: its frames are busy enough that a genuine
# decode never reads as "flat" to the probe's spread check.
set -euo pipefail

usage() {
  echo "Usage: $0 [--hevc] [--level LEVEL] [--seconds N] <output-dir> [WxH ...]" >&2
  echo "  Default resolutions bracket the FF1 H.264 cliff; pass explicit WxH to override." >&2
  exit 1
}

hevc=0
level=""
seconds=4
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hevc) hevc=1; shift ;;
    --level) level="$2"; shift 2 ;;
    --seconds) seconds="$2"; shift 2 ;;
    -h|--help) usage ;;
    --*) usage ;;
    *) break ;;
  esac
done
[[ $# -ge 1 ]] || usage
out_dir="$1"
shift

command -v ffmpeg >/dev/null 2>&1 || { echo "$0: ffmpeg not found" >&2; exit 1; }

if [[ $# -gt 0 ]]; then
  resolutions=("$@")
else
  resolutions=(
    2048x2048
    3840x2160
    4096x3072
    4096x3584
    4096x3840
    4096x4080
    4080x4096
    4096x4096
  )
fi

mkdir -p "$out_dir"

encode() {
  local codec_label="$1" encoder="$2" res="$3"
  local -a level_args=()
  if [[ -n "$level" ]]; then
    # x264/x265 warn when the level cannot legally hold the frame size but
    # still write it into the SPS; that is exactly the "L5.1 at 4096x4096"
    # shape the field asset in #302 had, so allow forcing it.
    level_args=(-level "$level")
  fi
  # The "<codec>_" prefix is a contract with probe-video-decode.py, which picks
  # the mediaCapabilities codec string from it; renaming clips breaks that.
  local out="$out_dir/${codec_label}_${res}.mp4"
  echo "encoding $out"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=${res}:rate=30" -t "$seconds" \
    -c:v "$encoder" -preset veryfast -pix_fmt yuv420p \
    -g 30 -an "${level_args[@]}" -movflags +faststart \
    "$out"
}

for res in "${resolutions[@]}"; do
  [[ "$res" =~ ^[0-9]+x[0-9]+$ ]] || { echo "$0: bad resolution '$res' (want WxH)" >&2; exit 1; }
  encode h264 libx264 "$res"
  if [[ "$hevc" -eq 1 ]]; then
    encode hevc libx265 "$res"
  fi
done

echo "clips written to $out_dir"
