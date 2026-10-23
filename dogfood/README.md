# Haven dogfood build tooling

在 NixOS 宿主上以**源码零改动**复现 CI 同源的完整 release APK (`:app:assembleArm64FullRelease`,
2014 任务, 无 -x 排除无 -Pskip 跳过)。三条 glibc 交叉工具链 / meson 硬编码
/usr/bin/pkg-config / wayland 全家 / CI 同代 glibc 头 (≥2.38) 四类 FHS 依赖
全部由 `debian:trixie` 容器化解 (与 CI apt 清单同源)。

## 用法

```bash
source dogfood/build-env.sh
dogfood-image-build        # 下载 go/JDK tarball (sha256 钉死) + 构建 trixie 镜像
dogfood-container-init     # 缓存快照 + 常驻容器 + 容器侧 cargo-ndk/gomobile
dogfood-gradle :app:assembleArm64FullRelease -PtargetAbi=arm64
# 产物: app/build/outputs/apk/arm64Full/release/haven-<version>-arm64-release.apk
dogfood-destroy            # 用后清理
```

前提: worktree 检出于 /tmp/opencode/haven/dogfood-build (基点 = PR tip),
子模块递归 init, Android SDK (NDK 29.0.14206865) 在 /home/lc/Android/Sdk。

## 狗粮签名

分支的 release 构建硬性要求 keystore (`validateSigningArm64FullRelease`)。
狗粮版用独立密钥 (非上游维护者密钥), appId 加 `.dogfood` 后缀与官方版共存 ——
该后缀提交**只存在于狗粮构建本地, 永不推送**; 本分支 (dogfood-tooling) 仅承载
环境工具链, 挂载点固定为 dogfood-build worktree, 不携带后缀提交。

## 分发

APK 经 lc-studio/nixos 的 `cobbles.fdroid` 声明式清单分发 (fetchurl 锚定本 fork
的 release tag), 见 nixos 仓 pkgs/haven-dogfood-apk/package.nix。
