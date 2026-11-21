# FF1 native player package

The FF1 player hosts CEF and libmpv. The ffos-user Linux workflow builds the runtime archive. The full-image workflow packages that archive together with its matching controld, watchdog and user session.

```sh
python3 packages/ff-player-native/prepare.py \
  --artifact ff-player-cef-linux.tar.gz --sha256 "$tested_sha256" \
  --version "$pkgver" --epoch "$commit_epoch" --output /tmp/ff1-cef-package
```

Run `makepkg` in that directory. Pacman replaces either legacy package name. The image supplies the matching Cage session and service configuration.
