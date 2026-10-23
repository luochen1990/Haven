# Haven dogfood build container — reproduces the CI/F-Droid toolchain on a
# NixOS host without touching a single source file.
#
# Base: Debian trixie. The cross-glibc headers must be >= the generation CI
# builds against (ubuntu-24.04 era): core/local's haven-usb sources rely on
# offsetof resolving from <sys/un.h> transitively (no explicit <stddef.h>),
# which glibc >= 2.38-era headers do and bookworm's (2.36) do not — a source
# change would be required to build on bookworm, so trixie it is.
#
# Carries exactly the apt set CI installs in
# .github/actions/setup-toolchain/action.yml, plus JDK 17/21 (Temurin, same
# distribution CI's setup-java uses; trixie apt has no openjdk-17) and
# Go 1.27.3 (rclone go.mod requires >= 1.27.1).
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        gcc-aarch64-linux-gnu libc6-dev-arm64-cross \
        gcc-x86-64-linux-gnu libc6-dev-amd64-cross \
        gcc-arm-linux-gnueabihf libc6-dev-armhf-cross \
        meson ninja-build pkg-config bison cmake \
        autoconf automake libtool libtool-bin libltdl-dev \
        libexpat1-dev libffi-dev xutils-dev python3-xcbgen \
        nasm yasm gperf \
        git curl xz-utils bzip2 lbzip2 unzip zip file make g++ python3 python3-yaml ca-certificates procps gawk \
    && rm -rf /var/lib/apt/lists/*

COPY go1.27.3.linux-amd64.tar.gz /tmp/go.tgz
COPY temurin17.tar.gz /tmp/jdk17.tgz
COPY temurin21.tar.gz /tmp/jdk21.tgz
RUN tar -C /usr/local -xzf /tmp/go.tgz && rm /tmp/go.tgz \
    && mkdir -p /opt/jdk-17 /opt/jdk-21 \
    && tar -C /opt/jdk-17 --strip-components=1 -xzf /tmp/jdk17.tgz && rm /tmp/jdk17.tgz \
    && tar -C /opt/jdk-21 --strip-components=1 -xzf /tmp/jdk21.tgz && rm /tmp/jdk21.tgz \
    && mkdir -p /home/lc && chown 1000:1000 /home/lc

ENV PATH=/opt/jdk-21/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
