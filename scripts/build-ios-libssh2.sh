#!/usr/bin/env bash
# Cross-compile static mbedtls + libssh2 for iphoneos arm64.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/third_party"
PREFIX="$VENDOR/ios-arm64"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MIN=14.0
CC="$(xcrun -f clang)"
HOST=aarch64-apple-darwin
COMMON_FLAGS="-isysroot $SDK -arch arm64 -miphoneos-version-min=$MIN -fembed-bitcode-marker"

mkdir -p "$VENDOR/src" "$PREFIX"

MBEDTLS_VER=3.6.3
LIBSSH2_VER=1.11.1
MBEDTLS_TGZ="$VENDOR/src/mbedtls-$MBEDTLS_VER.tar.gz"
LIBSSH2_TGZ="$VENDOR/src/libssh2-$LIBSSH2_VER.tar.gz"

if [ ! -f "$MBEDTLS_TGZ" ]; then
  curl -L --fail -o "$MBEDTLS_TGZ" \
    "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$MBEDTLS_VER/mbedtls-$MBEDTLS_VER.tar.bz2"
fi
if [ ! -f "$LIBSSH2_TGZ" ]; then
  curl -L --fail -o "$LIBSSH2_TGZ" \
    "https://www.libssh2.org/download/libssh2-$LIBSSH2_VER.tar.gz"
fi

if [ ! -d "$VENDOR/src/mbedtls-$MBEDTLS_VER" ]; then
  tar -xjf "$MBEDTLS_TGZ" -C "$VENDOR/src"
fi
if [ ! -d "$VENDOR/src/libssh2-$LIBSSH2_VER" ]; then
  tar -xzf "$LIBSSH2_TGZ" -C "$VENDOR/src"
fi

if [ ! -f "$PREFIX/lib/libmbedtls.a" ]; then
  rm -rf "$VENDOR/src/mbedtls-build"
  cmake -S "$VENDOR/src/mbedtls-$MBEDTLS_VER" -B "$VENDOR/src/mbedtls-build" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT="$SDK" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN" \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DENABLE_PROGRAMS=OFF \
    -DENABLE_TESTING=OFF \
    -DMBEDTLS_FATAL_WARNINGS=OFF \
    -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
    -DCMAKE_BUILD_TYPE=Release
  cmake --build "$VENDOR/src/mbedtls-build" --config Release -j"$(sysctl -n hw.ncpu)"
  cmake --install "$VENDOR/src/mbedtls-build"
fi

if [ ! -f "$PREFIX/lib/libssh2.a" ]; then
  rm -rf "$VENDOR/src/libssh2-build"
  cmake -S "$VENDOR/src/libssh2-$LIBSSH2_VER" -B "$VENDOR/src/libssh2-build" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT="$SDK" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN" \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTING=OFF \
    -DENABLE_ZLIB_COMPRESSION=OFF \
    -DCRYPTO_BACKEND=mbedTLS \
    -DMBEDTLS_INCLUDE_DIR="$PREFIX/include" \
    -DMBEDTLS_LIBRARY="$PREFIX/lib/libmbedtls.a" \
    -DMBEDX509_LIBRARY="$PREFIX/lib/libmbedx509.a" \
    -DMBEDCRYPTO_LIBRARY="$PREFIX/lib/libmbedcrypto.a" \
    -DCMAKE_BUILD_TYPE=Release
  cmake --build "$VENDOR/src/libssh2-build" --config Release -j"$(sysctl -n hw.ncpu)"
  cmake --install "$VENDOR/src/libssh2-build"
fi

ls -lh "$PREFIX/lib"/libmbed*.a "$PREFIX/lib/libssh2.a"
echo "OK ios-arm64 libssh2+mbedtls at $PREFIX"
