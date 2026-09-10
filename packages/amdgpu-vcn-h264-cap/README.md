# amdgpu-vcn-h264-cap

A rebuilt `amdgpu.ko` for the image's pinned `linux-lts`, carrying one table
change: the VCN 3.1.1 (Radeon 680M) H.264 decode entry advertises 4096×4080
instead of 4096×4096. Tracks
[feral-file/ffos-user#302](https://github.com/feral-file/ffos-user/issues/302),
where the full analysis is written up; the measurements and the tooling that
produced them are in `verify/` here.

## Why it exists

The VCN firmware on FF1 returns an unwritten, all-zero surface for any H.264
frame of 65,536 macroblocks or more (4096×4096 is exactly 65,536) and reports
no error. The kernel advertises 4096×4096, Mesa forwards that to libva, and
Chromium trusts it, so a 4096×4096 H.264 artwork shows as a solid green frame.
With the cap, Chromium refuses the hardware path for that shape and decodes it
in software (measured: correct output, 0 dropped frames, about 22% of the CPU
at 4096×4096@30). Every frame at or under 4080 rows, and every other codec,
keeps hardware decode.

## How it takes effect

- The module installs to `/usr/lib/modules/<kernel>/updates/amdgpu.ko.zst`.
  Arch's `/usr/lib/depmod.d/search.conf` ranks `updates` above the in-tree
  copy, so `depmod` (run by pacman's `60-depmod` hook) resolves `amdgpu`
  here. The stock module stays on disk; deleting this file and re-running
  `depmod` is the rollback.
- `amdgpu` is not in the FF1 initramfs (no `kms` hook, not in `MODULES`), so
  the initramfs is untouched. The module loads from the root filesystem after
  switch-root.
- The module has no `.BTF` section (module BTF needs `vmlinux`, which an
  `M=` build never produces); the stock module has one. The kernel only
  skips BTF for this module. Nothing on FF1 consumes module BTF.
- The module is unsigned. The kernel has `CONFIG_MODULE_SIG` without
  `_FORCE` and FF1 ships with Secure Boot off, so it loads with the
  out-of-tree and unsigned taint flags (`/proc/sys/kernel/tainted` = 12288).
  Enabling Secure Boot or kernel lockdown would stop this module from loading
  and silently fall back to nothing (no amdgpu at all), so that change must
  retire this package first.

## How it reaches devices, and how it comes back out

FF1 OTA is not a pacman transaction. `feral-system-update.sh` rsyncs the
whole root filesystem of the new image into a fresh btrfs snapshot
(`rsync -aAX --delete` of `/`, `/boot` staged separately), so:

- The `depends=` pin is evaluated once, when the image is built. Devices
  never run pacman for this; they receive the module file and the
  `modules.dep` that the image build's `depmod` already produced. No
  post-OTA `depmod` is needed or run.
- Rollback on a fielded device is the OTA's own snapshot rollback (boot the
  previous known-good snapshot), or shipping an image without this package.
  Deleting the file and re-running `depmod` by hand works on a bench unit,
  but the next OTA puts it straight back.
- `pure-build-image-to-cf.yml` rebuilds the ISO from the branch's existing R2
  repo without building packages. Because `packages.x86_64` now lists this
  package, a pure build on a branch whose repo never carried it fails at
  pacstrap until a full `build-image-to-cf.yml` run has published it.

## Keeping it in step with the kernel

`depends=("linux-lts=<ver>-<rel>")` is an exact pin. When the image's
`pacman_snapshot` moves to a date with a newer `linux-lts`, the image build
fails at dependency resolution with an unmistakable message, which is the
intended behaviour: a module built for another kernel must never ship
silently. To re-base:

1. Set `_kver` / `_krel` in `PKGBUILD` to the new `linux-lts` version.
2. Re-vendor `0001-*.patch`, `0002-*.patch`, `0003-*.patch` and `config` from
   the Arch packaging repo at tag `<ver>-<rel>`
   (`https://gitlab.archlinux.org/archlinux/packaging/packages/linux-lts/-/raw/<ver>-<rel>/<file>`;
   the number and names of the Arch patches can change between releases, so
   read that tag's `PKGBUILD` `source=()` and mirror it).
3. Check `0004-*.patch` still applies to the new `nv.c`; if AMD has corrected
   the table upstream, delete this package instead.
4. Refresh `sha256sums` (`updpkgsums` or `sha256sum`).

`check()` fails the build if the resulting vermagic is not the pinned kernel's,
so a stale config or missing localversion file cannot produce a loadable but
wrong module.

## Build reuse in CI

The module is a pure function of this directory and the pacman snapshot, so
both CI rails cache the built package under a key made of those inputs
(`actions/cache`, key `pkgbuild-amdgpu-vcn-h264-cap-<snapshot>-<hash>`, where
the hash covers every file directly in this directory, `verify/` excluded).
On a hit the R2 rail skips the compile and only signs and uploads; the tag
rail skips the compile and copies the package into its local repo. Any edit
to a file here (this README included), a `pkgrel` bump, or a snapshot change
produces a new key and a fresh build, so a module cannot be reused across
different inputs. A snapshot that moves the kernel under an unchanged key
(only possible with `pacman_snapshot: latest`) is still caught by the
`depends=` pre-check, which runs on every build. Caches are branch-scoped
with fallback to `develop`, and ones unused for seven days are evicted;
either case just rebuilds.

## Building locally

```
cd packages/amdgpu-vcn-h264-cap
makepkg -sf            # ~2 min on 16 threads, ~8 min on a 4-vCPU runner
bsdtar -tf amdgpu-vcn-h264-cap-*.pkg.tar.zst
```

## Verifying on a device

`verify/` holds the tooling and the raw results the fix was measured with:

- `probe-video-decode.py`: runs on the device, drives the kiosk Chromium over
  its DevTools port, plays each clip in a detached `<video>` and reports
  whether the frames are real, the zero-YUV green, or stalled, plus
  Chromium's `powerEfficient` answer (hardware vs software) per clip.
  Dependency-free (python3 only).
- `gen-video-decode-probe-clips.sh`: generates the macroblock bracket clips
  with ffmpeg on a dev machine (`--hevc` for the HEVC twins).
- `measure-video-decode-cost.py`: decoded fps, dropped frames, CPU and GPU
  busy for a timed loop of a clip.
- `manifests/bytedance-hevc-demo.json`: 59 HEVC conformance clips played
  straight from a CORS-enabled CDN.
- `results-2026-09-10/`: the JSON from FF1-8EVTK3RE before the fix
  (`bracket-results.json`), with hardware decode disabled
  (`sw-only-results.json`, `noflag-results.json`), the HEVC set
  (`hevc-demo-results.json`) and after the fix (`patched-module-results.json`).

With the package installed and the device rebooted:

```
cat /sys/module/amdgpu/srcversion      # differs from the stock module's
modinfo -n amdgpu                      # .../updates/amdgpu.ko.zst
python3 verify/probe-video-decode.py --clips /home/feralfile/probe-clips
```

The `h264_4096x4096` row must read `ok` with
`powerEfficient(avc1.640034)=False`, `h264_4080x4096` flips to `False` as
well (height cap), every other H.264 row stays `True`, and all HEVC rows are
unchanged. `VaapiIgnoreDriverChecks` must stay in the kiosk's Chromium
flags: on AMD under Vulkan/ANGLE it is what enables hardware decode at all,
and without it HEVC has no decoder (Chromium ships no software HEVC).
