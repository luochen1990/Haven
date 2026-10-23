#!/usr/bin/env bash
# ============================================================================
# dogfood-build-env.sh — Haven 狗粮构建环境 (source 或直接执行皆可)
#
# 目标: 在 NixOS 宿主机上, 以「零源码改动」跑通
#   ./gradlew :app:assembleArm64FullRelease -PtargetAbi=arm64
# 并产出与 CI(.github/workflows/release.yml + actions/setup-toolchain) 同源的完整
# release APK。注: 分支的 release 构建硬性要求 keystore (validateSigning), 无证
# 书时 AGP 直接报错, "unsigned" 在此分支不可达 —— 故用一次性 dogfood 密钥签名
# (见 dogfood-keystore.env); APK 内容 = PR 二进制, 签名除外。
#
# 为什么用 Docker (debian:trixie):
#   1. 三套 glibc 交叉工具链 (gcc-aarch64-linux-gnu / gcc-x86-64-linux-gnu /
#      gcc-arm-linux-gnueabihf + libc6-dev-*-cross) 是 Debian apt 包,
#      F-Droid buildserver 与 CI 均用 apt 安装 —— 容器里 apt 装就是唯一忠实复现。
#      基座选 trixie 而非 bookworm: 跨界 glibc 头必须是 CI 那一代 (ubuntu-24.04+),
#      haven-usb 源码依赖 <sys/un.h> 传递解析 offsetof (未显式 include <stddef.h>),
#      glibc>=2.38 一代头可以, bookworm 的 2.36 不行 —— 换 bookworm 就得改源码, 禁止。
#   2. wayland-android/build-android.sh 生成的 meson cross-file 硬编码
#      /usr/bin/pkg-config; wayland-scanner 原生构建假设宿主有 FHS 式
#      libexpat-dev —— 这两条在无 root 的 NixOS 上无解, 在 Debian 里天然成立。
#   3. CI 的 wayland/ffmpeg 构建链 (meson ninja autotools xcbgen gperf ...) 全是
#      apt 包名, 逐个 nix 化维护成本高且偏离 CI。
#
# 与源码的关系: 容器只挂载 worktree + 缓存, 不修改任何 tracked 文件;
#   构建产物全部落在 .gitignore 已覆盖的路径 (build/, jniLibs/, assets/...)。
#
# 用法:
#   source /tmp/opencode/haven-planning/dogfood-build-env.sh
#   dogfood-image-build         # 构建 docker 镜像 (一次)
#   dogfood-container-init      # 准备容器侧缓存 + 启动常驻容器 + 装容器侧工具
#   dogfood-exec <cmd...>       # 在容器内执行任意命令 (已带全环境)
#   dogfood-gradle <args...>    # 在容器内 worktree 执行 ./gradlew (规范参数)
#   dogfood-destroy             # 停止并删除容器
# ============================================================================

set -euo pipefail

DOGPLAN=/tmp/opencode/haven-planning
DOGWT=/tmp/opencode/haven/dogfood-build          # worktree (基点 c9ec01ab = PR #754 tip)
DOGIMG=haven/dogfood-builder:trixie
DOGCTR=haven-dogfood

# ---- 容器内环境 (dogfood-exec 注入) ----------------------------------------
# GRADLE_USER_HOME 隔离到 /tmp: 宿主 ~/.gradle 有其他会话的活跃 daemon,
# 共用会撞 daemon registry; 拷贝缓存既复用又不干扰。
# CARGO_HOME 同理隔离: 宿主 ~/.cargo/bin/cargo-ndk 是 nix-glibc 链接的,
# 容器内跑不动; 在容器侧重装 FHS 版, 不覆盖宿主文件。
# RUSTUP_HOME 指向容器侧自建的 /tmp/opencode/container-rustup: 符号链接复用
# 宿主 toolchain (rustup.rs 官方 FHS 二进制), settings.toml 的 default 指向
# 1.94.1 —— 因为宿主的 "stable" toolchain 是 nix-glibc 链接的空壳, 容器内
# 跑不动; 各 crate 的 rust-toolchain.toml 钉 (rdp 1.94.1 / spice 1.89.0 /
# prns stable->default 1.94.1) 在此之下全部正常解析, 且零宿主污染。
_dog_env() {
    cat <<'ENVV'
export ANDROID_HOME=/home/lc/Android/Sdk
export ANDROID_SDK_ROOT=/home/lc/Android/Sdk
export GRADLE_USER_HOME=/tmp/opencode/container-gradle
export CARGO_HOME=/tmp/opencode/container-cargo
export RUSTUP_HOME=/tmp/opencode/container-rustup
export GOPATH=/tmp/opencode/container-gopath
export GOBIN=/tmp/opencode/container-gopath/bin
export GOCACHE=/tmp/opencode/container-gocache
export GOMODCACHE=/tmp/opencode/container-gopath/pkg/mod
export PATH=/opt/jdk-21/bin:/tmp/opencode/container-gopath/bin:/tmp/opencode/container-cargo/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENVV
    # 一次性狗粮签名密钥 (见 dogfood-keystore.env 头注释); 不存在则跳过
    [ -f "$DOGPLAN/dogfood-keystore.env" ] && cat "$DOGPLAN/dogfood-keystore.env"
}

# ---- 镜像构建 ----------------------------------------------------------------
# 镜像需要三个 tarball (go + temurin 17/21); 缺失时自动下载并按 sha256 校验。
# go 取固定版本; temurin 用 version 固定 API (与手装版本一致), 不漂移。
dogfood-image-build() {
    cd "$DOGPLAN"
    local need=0
    if [ ! -s go1.27.3.linux-amd64.tar.gz ]; then
        curl -fsSL -o go1.27.3.linux-amd64.tar.gz \
            https://dl.google.com/go/go1.27.3.linux-amd64.tar.gz
        need=1
    fi
    if [ ! -s temurin17.tar.gz ]; then
        curl -fsSL -o temurin17.tar.gz \
            https://api.adoptium.net/v3/binary/version/jdk-17.0.21%2B9/ga/linux/x64/jdk/hotspot/normal/eclipse
        need=1
    fi
    if [ ! -s temurin21.tar.gz ]; then
        curl -fsSL -o temurin21.tar.gz \
            https://api.adoptium.net/v3/binary/version/jdk-21.0.13%2B9/ga/linux/x64/jdk/hotspot/normal/eclipse
        need=1
    fi
    sha256sum -c - <<'SHAS'
65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40  go1.27.3.linux-amd64.tar.gz
8b9b611d917e3dfd8419d3566b5949226f69b052fed7e109c1368add1dfe8711  temurin17.tar.gz
d7f5d5cf865a2902b70ff549b97586a7d3f234e016f041ab447ea740c7d66d1c  temurin21.tar.gz
SHAS
    docker build -f dogfood-Dockerfile -t "$DOGIMG" .
}

# ---- 容器初始化 ---------------------------------------------------------------
dogfood-container-init() {
    # 1) 宿主侧: 快照 gradle 依赖/构建缓存与 wrapper (一次性, 幂等跳过)
    if [ ! -e /tmp/opencode/container-gradle/.dogfood-snapshot ]; then
        echo "[dogfood] snapshotting ~/.gradle caches -> /tmp/opencode/container-gradle"
        mkdir -p /tmp/opencode/container-gradle
        cp -a /home/lc/.gradle/wrapper /tmp/opencode/container-gradle/
        cp -a /home/lc/.gradle/caches  /tmp/opencode/container-gradle/
        rm -rf /tmp/opencode/container-gradle/caches/daemon || true
        touch /tmp/opencode/container-gradle/.dogfood-snapshot
    fi
    # 2) 宿主侧: cargo 隔离副本 (rustup shim + registry 缓存)
    if [ ! -e /tmp/opencode/container-cargo/.dogfood-snapshot ]; then
        echo "[dogfood] snapshotting ~/.cargo -> /tmp/opencode/container-cargo"
        mkdir -p /tmp/opencode/container-cargo
        cp -a /home/lc/.cargo/bin /tmp/opencode/container-cargo/
        [ -f /home/lc/.cargo/config.toml ] && cp -a /home/lc/.cargo/config.toml /tmp/opencode/container-cargo/
        [ -d /home/lc/.cargo/registry ] && cp -a /home/lc/.cargo/registry /tmp/opencode/container-cargo/
        touch /tmp/opencode/container-cargo/.dogfood-snapshot
    fi
    # 2b) 容器侧 rustup home: 链接宿主 toolchain + default 指向 1.94.1
    #     (宿主 "stable" toolchain 是 nix 链接的, 容器内不可执行)
    mkdir -p /tmp/opencode/container-rustup/toolchains /tmp/opencode/container-rustup/downloads /tmp/opencode/container-rustup/tmp
    for tc in 1.89.0-x86_64-unknown-linux-gnu 1.94.1-x86_64-unknown-linux-gnu; do
        ln -sfn "/home/lc/.rustup/toolchains/$tc" "/tmp/opencode/container-rustup/toolchains/$tc"
    done
    cat > /tmp/opencode/container-rustup/settings.toml <<'RSET'
version = "12"
default_toolchain = "1.94.1-x86_64-unknown-linux-gnu"
profile = "default"
RSET
    # 3) 启动常驻容器 (worktree/SDK/缓存全部挂载, 路径与宿主一致以复用绝对路径缓存)
    docker rm -f "$DOGCTR" >/dev/null 2>&1 || true
    docker run -d --name "$DOGCTR" \
        -v /tmp/opencode:/tmp/opencode \
        -v /home/lc/Android:/home/lc/Android \
        -v /home/lc/.rustup:/home/lc/.rustup \
        -v /home/lc/.cache/oss-cache:/home/lc/.cache/oss-cache:ro \
        -v /var/cache/oss-cache:/var/cache/oss-cache:ro \
        --user 1000:1000 -e HOME=/home/lc \
        --ulimit nofile=65536:65536 \
        "$DOGIMG" sleep infinity >/dev/null
    # 3b) 一次性狗粮签名密钥: 分支的 release 构建硬性要求 keystore (validateSigning),
    #     维护者密钥不在此机 —— 生成 throwaway jks (worktree 根, 未跟踪) + env 注入。
    dogfood-exec bash -c '
        [ -f haven-release.jks ] || keytool -genkeypair -keystore haven-release.jks \
          -storepass dogfood2026 -keypass dogfood2026 -alias dogfood \
          -keyalg RSA -keysize 4096 -validity 10950 \
          -dname "CN=Haven Dogfood Build, O=GlassHaven" >/dev/null 2>&1
        echo "[dogfood] keystore: $(ls -la haven-release.jks 2>/dev/null | wc -l) ok"
    '
    # 4) 容器侧: 重装 FHS 版 cargo-ndk + gomobile/gobind (宿主副本是 nix 链接, 跑不动)
    dogfood-exec bash -c '
        set -e
        cargo-ndk --version >/dev/null 2>&1 || cargo install cargo-ndk --locked --force --version 3.5.4
        gomobile version >/dev/null 2>&1 || true
        [ -x "$GOBIN/gomobile" ] || go install golang.org/x/mobile/cmd/gomobile@v0.0.0-20251021151156-188f512ec823
        [ -x "$GOBIN/gobind" ]   || go install golang.org/x/mobile/cmd/gobind@v0.0.0-20251021151156-188f512ec823
        echo "[dogfood] container tools ready"
    '
    dogfood-exec bash -c 'aarch64-linux-gnu-gcc --version | head -1; /usr/bin/pkg-config --version; java -version 2>&1 | head -1; /opt/jdk-17/bin/java -version 2>&1 | head -1; go version; rustc --version; cargo-ndk --version; gomobile version'
}

# ---- 容器内执行 ---------------------------------------------------------------
dogfood-exec() {
    docker exec -w "$DOGWT" -e HOME=/home/lc "$DOGCTR" \
        bash -c "$( _dog_env ); cd $DOGWT && \"\$@\"" _ "$@"
}

# ---- gradle 规范调用 ----------------------------------------------------------
# targetAbi=arm64 与 release.yml 的 matrix 调用一致 (ABI 选择, 非 skip);
# JDK 17/21 (Temurin) 供 jvmToolchain 精确解析。
dogfood-gradle() {
    dogfood-exec ./gradlew \
        -Dorg.gradle.java.installations.paths=/opt/jdk-17,/opt/jdk-21 \
        "$@"
}

dogfood-destroy() {
    docker rm -f "$DOGCTR" >/dev/null 2>&1 && echo "[dogfood] container removed" || true
}

echo "[dogfood] env ready: dogfood-image-build / dogfood-container-init / dogfood-exec / dogfood-gradle / dogfood-destroy"
