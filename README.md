# Octans FFmpeg

Octans FFmpeg is a GPLv3 server-side FFmpeg full runtime. The current tree is FFmpeg 8.1.2 plus the Jellyfin patch series used for playback, transcoding, subtitles, and hardware acceleration.

This build is configured with `--enable-gpl`, `--enable-version3`, `--enable-libx264`, and `--enable-libx265`. The resulting binaries are GPLv3. Corresponding source is this repository.

Source: <https://github.com/octans-media/open-octans-ffmpeg>

## Build

The supported host is Ubuntu 26.04 amd64, with Docker.

```bash
scripts/build-octans-full-linux.sh
scripts/verify-full-linux.sh .build/stage/current/opt/octans-ffmpeg
scripts/package-deb.sh
scripts/verify-deb-install.sh
scripts/build-runtime-image.sh --no-registry-tags
scripts/verify-runtime-image.sh
```

`scripts/build-octans-full-linux.sh` applies `debian/patches/series` with `dpkg-source --before-build`, then configures and installs into `.build/` unless `OCTANS_FFMPEG_BUILD_ROOT` is set.

The runtime image install paths are:

```text
/opt/octans-ffmpeg/bin/ffmpeg
/opt/octans-ffmpeg/bin/ffprobe
/opt/octans-ffmpeg/bin/octans-ffmpeg-capabilities
```

## Publish

Publish scripts do not embed a registry address. Set these environment variables before uploading a package or image:

- `OCTANS_GITEA_URL`
- `OCTANS_GITEA_HOST`
- `OCTANS_FFMPEG_HARBOR_REPOSITORY`

Gitea Actions reads the same addresses from repository variables, and reads registry credentials from repository secrets:

- `OCTANS_FFMPEG_RUNNER`
- `OCTANS_FFMPEG_CI_CACHE_ROOT`
- `OCTANS_GITEA_URL`
- `OCTANS_GITEA_HOST`
- `OCTANS_FFMPEG_HARBOR_REGISTRY`
- `OCTANS_FFMPEG_HARBOR_REPOSITORY`
- `OCTANS_GITEA_REGISTRY_USERNAME`
- `OCTANS_GITEA_REGISTRY_TOKEN`
- `OCTANS_HARBOR_REGISTRY_USERNAME`
- `OCTANS_HARBOR_REGISTRY_TOKEN`

## License

FFmpeg's own license terms are in `LICENSE.md` and the `COPYING.*` files. Enabling GPL components and linking libx264/libx265 makes this build GPLv3. The source required to rebuild the distributed binaries is this repository, including `debian/patches` and `scripts/build-octans-full-linux.sh`.
