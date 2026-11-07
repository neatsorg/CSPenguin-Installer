#!/usr/bin/env bash
# winex11.so をパッチ付きで再ビルドする(再現可能なビルド用スクリプト)
#
# 使い方: patches/build-winex11.sh [WINE_VERSION]
#   podman(なければ docker)で AlmaLinux 8 (glibc 2.28) コンテナを起動し、
#   公式 Wine ソースに patches/winex11-*.patch を当てて winex11.so だけをビルドする。
#   成果物は patches/x86_64-unix-wine<VERSION>/winex11.so に置かれる。
#
# 古い glibc でビルドするのは、Kron4ek の Wine ビルド同様に
# 幅広いディストリビューションで動かすため。
set -euo pipefail

WINE_VERSION="${1:-11.4}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/x86_64-unix-wine${WINE_VERSION}"
IMAGE="docker.io/library/almalinux:8"

if command -v podman >/dev/null 2>&1; then
    CTR=podman
elif command -v docker >/dev/null 2>&1; then
    CTR=docker
else
    echo "error: podman or docker is required" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

"$CTR" run --rm -i \
    -v "$SCRIPT_DIR:/patches:ro,z" \
    -v "$OUT_DIR:/out:z" \
    -e WINE_VERSION="$WINE_VERSION" \
    "$IMAGE" bash -euo pipefail -s << 'BUILD'
dnf -y -q install dnf-plugins-core >/dev/null
dnf config-manager --set-enabled powertools
dnf -y -q install gcc make flex bison patch xz curl \
    libX11-devel libXext-devel libXi-devel libXrandr-devel libXinerama-devel \
    libXcursor-devel libXcomposite-devel libXfixes-devel libXrender-devel \
    libXxf86vm-devel mesa-libGL-devel mesa-libEGL-devel vulkan-loader-devel >/dev/null

major="${WINE_VERSION%%.*}"
cd /tmp
curl -fsSL "https://dl.winehq.org/wine/source/${major}.x/wine-${WINE_VERSION}.tar.xz" | tar -xJ
cd "wine-${WINE_VERSION}"
for p in /patches/winex11-*.patch; do
    echo "applying $(basename "$p")"
    patch -p1 < "$p"
done

mkdir build && cd build
../configure --enable-win64 --without-mingw --disable-tests \
    --without-wayland --without-gstreamer --without-oss --without-pcsclite \
    --without-sane --without-gphoto --without-cups --without-capi \
    --without-krb5 --without-netapi --without-freetype > configure.log 2>&1 \
    || { tail -40 configure.log; exit 1; }

# 筆圧(XInput2)など、winex11 に必要な X 拡張がそろっているか確認
for f in HAVE_X11_EXTENSIONS_XINPUT2_H HAVE_X11_EXTENSIONS_XRANDR_H HAVE_LIBXSHAPE \
         HAVE_X11_EXTENSIONS_XSHM_H SONAME_LIBXCOMPOSITE SONAME_LIBGL SONAME_LIBVULKAN; do
    grep -q "#define $f" include/config.h || { echo "missing: $f" >&2; exit 1; }
done

make -j"$(nproc)" dlls/winex11.drv/winex11.so > make.log 2>&1 || { tail -40 make.log; exit 1; }
strip --strip-unneeded dlls/winex11.drv/winex11.so
install -m 644 dlls/winex11.drv/winex11.so /out/winex11.so
echo "built: winex11.so (wine-${WINE_VERSION})"
BUILD

ls -la "$OUT_DIR/winex11.so"
