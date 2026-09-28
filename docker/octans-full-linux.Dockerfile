FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get dist-upgrade -y \
 && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    rsync \
    xz-utils \
    zstd \
    file \
    patchelf \
    git \
    make \
    autoconf \
    automake \
    libtool \
    gcc \
    g++ \
    clang \
    nasm \
    pkg-config \
    dpkg-dev \
    quilt \
    python3 \
    cmake \
    meson \
    ninja-build \
    build-essential \
    libudev-dev \
    libpciaccess-dev \
    libx11-dev \
    libgnutls28-dev \
    libgmp-dev \
    libass-dev \
    libfontconfig-dev \
    libfreetype-dev \
    libfribidi-dev \
    libharfbuzz-dev \
    libdav1d-dev \
    libsvtav1enc-dev \
    libaom-dev \
    librav1e-dev \
    libvpx-dev \
    libopus-dev \
    libvorbis-dev \
    libwebp-dev \
    libmp3lame-dev \
    libtheora-dev \
    libopenmpt-dev \
    libbluray-dev \
    libxml2-dev \
    libchromaprint-dev \
    libx264-dev \
    libx265-dev \
    libzimg-dev \
    ocl-icd-opencl-dev \
    libplacebo-dev \
    libvulkan-dev \
    libshaderc-dev \
    libdrm-dev \
    libva-dev \
 && rm -rf /var/lib/apt/lists/*
