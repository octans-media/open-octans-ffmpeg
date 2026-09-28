FROM ubuntu:26.04

ARG OCTANS_FFMPEG_IMAGE_VERSION=unknown
ARG OCTANS_FFMPEG_DEB_SHA256=unknown

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/opt/octans-ffmpeg/bin:${PATH}"

LABEL org.opencontainers.image.title="octans-ffmpeg-full" \
      org.opencontainers.image.description="Octans FFmpeg full runtime for Ubuntu 26.04 Resolute" \
      org.opencontainers.image.version="${OCTANS_FFMPEG_IMAGE_VERSION}" \
      org.opencontainers.image.source="https://github.com/octans-media/open-octans-ffmpeg" \
      org.octans.ffmpeg.deb-sha256="${OCTANS_FFMPEG_DEB_SHA256}"

COPY octans-ffmpeg-full.deb /tmp/octans-ffmpeg-full.deb

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/octans-ffmpeg-full.deb; \
    rm -rf /var/lib/apt/lists/* /tmp/octans-ffmpeg-full.deb

CMD ["ffmpeg", "-version"]
