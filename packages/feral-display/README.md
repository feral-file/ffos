# feral-display package

`feral-display` hosts CEF and libmpv. The kiosk starts `/usr/lib/feral-display/feral-display`. The previous native package (`ff-player-native`) and the production web package (`feral-player`) move to this layout with a full-image update. Existing native installations keep their playback state and skip the Chromium import. The ffos-user Linux workflow builds the runtime archive. The full-image workflow packages that archive together with its matching controld, watchdog and user session.

```sh
python3 packages/feral-display/prepare.py \
  --artifact feral-display-linux.tar.gz --sha256 "$tested_sha256" \
  --version "$pkgver" --epoch "$commit_epoch" --output /tmp/ff1-cef-package
```

Run `makepkg` in that directory. Pacman replaces either legacy package name. The image supplies the matching Cage session and service configuration.
