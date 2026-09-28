# Octans FFmpeg

This repository builds the Octans server FFmpeg full runtime. The build is GPLv3 because `scripts/build-octans-full-linux.sh` passes `--enable-gpl`, `--enable-version3`, `--enable-libx264`, and `--enable-libx265`.

## Layout

- `scripts/build-octans-full-linux.sh` configures and builds the Linux runtime.
- `scripts/verify-full-linux.sh` checks the staged binaries.
- `scripts/package-deb.sh` packs the Debian package.
- `scripts/build-runtime-image.sh` builds the runtime image.
- `debian/patches/series` is applied by `dpkg-source --before-build`.
- `docker/octans-full-linux.Dockerfile` is the compile environment.
- `docker/octans-runtime-linux.Dockerfile` is the runtime image.
- `.gitea/workflows/` publishes from repository variables and secrets. Do not write registry hosts or credentials into the workflow files.

## Build

```bash
scripts/build-octans-full-linux.sh
scripts/verify-full-linux.sh .build/stage/current/opt/octans-ffmpeg
```

Build output stays under `.build/` unless `OCTANS_FFMPEG_BUILD_ROOT` is set. Do not commit `.build/`, packages, or container images.

Publish scripts require `OCTANS_GITEA_URL`, `OCTANS_GITEA_HOST`, and `OCTANS_FFMPEG_HARBOR_REPOSITORY`. They have no default registry address.
