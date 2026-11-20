# FF1 native player package

The Cage runtime uses glycin for raster artwork, libmpv for video and CEF Views for browser artwork. The FF1 CEF workflow in `ffos-user` builds and tests the binaries on GitHub. Package the same archive that passed the on-device playlist checks.

```sh
python3 packages/ff-player-native/prepare.py \
  --artifact ff-player-cef-linux.tar.gz --sha256 "$tested_sha256" \
  --version "$pkgver" --epoch "$commit_epoch" --output /tmp/ff1-cef-package
```

Run `makepkg` there in the Arch packaging environment. This step preserves the CI binaries and the hard link to the CEF executable. The FFOS image owns Cage activation.

## Public Chromium comparison build

This package builds the C++ runtime and private media worker from an immutable
source bundle. It installs no session/systemd units and triggers no service
restart, upload, signing, or release workflow. Coordinated activation belongs to
the full-image rail, after the matching controld/session migration is verified.

From a clean native checkout, fetch its hash-pinned dependencies first. Then:

```sh
python3 packages/ff-player-native/prepare.py \
  --source ../ffos-user/components/player --output /tmp/ff-native-package \
  --version 0.1.0.dev20261117 --epoch 1794873600
```

Use the source revision's fixed epoch for release candidates. The output records
every source file hash, the package source hash, and SOURCE_DATE_EPOCH. The same
inputs produce the same archive bytes. The archive contains the public Chromium archive, compositor SDKs, media source
archives, model-viewer and the JSON header; build phases verify their hashes
without downloading. Transfer the generated directory to an FFOS/Arch x86-64
build machine with the pinned toolchain and the matching FFOS snapshot, then run:

```sh
SOURCE_DATE_EPOCH=1794873600 makepkg --cleanbuild --force
```

Run under a bounded build cgroup (three CPUs, 6 GiB memory) on an FF1. This is
a build on the existing device, not proof of clean-room reproducibility. The
PKGBUILD pins the tested compiler/build-tool package versions. Complete base
image/transitive dependency locking and a second clean rebuild comparison remain
required. Do not update the device's system packages merely to satisfy makepkg.

The package carries the public Chromium setuid sandbox (root:root 4755), private shared media
libraries, renderer resources, protocol schema, migration tools and available
upstream license notices. makepkg splits host/worker debug symbols; the selected
public browser archive does not supply Chromium symbols. Complete browser symbol
retrieval, bundled third-party license audit and the new host's license
declaration remain release work. `license=custom` is deliberate until that audit
is complete; it is not a statement that the bundled open-source code has been
relicensed.

Installing this package alone does not replace `feral-player` or Chromium.
The two may coexist for rollback, but the final full-image session must activate
one playback owner. Do not ship a package-only activation or leave both ordinary
control paths running after cutover. Production/staging promotion remains human
operated under the repository guardrails.

The current runtime is built with `FF_WITH_PUBLIC=ON`; `FF_WITH_CEF` is an explicit
rollback/diagnostic target. `build-presentation.sh` builds the pinned private
headless wlroots library. The engine archive and executable hashes are recorded
in dependencies.json; core, native UI, private decoder and broker checks are part
of the component build. The source bundle excludes the unused CEF archive.
