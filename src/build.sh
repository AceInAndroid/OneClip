#!/bin/bash

set -euo pipefail

log_info() {
    echo "[INFO] $1"
}

log_success() {
    echo "[SUCCESS] $1"
}

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PATH="$PROJECT_DIR/OneClip.xcodeproj"
OUTPUT_DIR="$PROJECT_DIR/dist"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pastelight-release.XXXXXX")"

cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$OUTPUT_DIR"

log_info "构建 PasteLight 双架构 Release 安装包"
log_info "输出目录: $OUTPUT_DIR"

for ARCH in arm64 x86_64; do
    DERIVED_DATA="$TEMP_ROOT/DerivedData-$ARCH"
    APP_PATH="$DERIVED_DATA/Build/Products/Release/PasteLight.app"

    log_info "构建 $ARCH..."
    xcodebuild \
        -quiet \
        -project "$PROJECT_PATH" \
        -scheme OneClip \
        -configuration Release \
        -destination "generic/platform=macOS" \
        -derivedDataPath "$DERIVED_DATA" \
        ARCHS="$ARCH" \
        ONLY_ACTIVE_ARCH=NO \
        clean build

    if [ ! -d "$APP_PATH" ]; then
        echo "[ERROR] 未找到构建产物: $APP_PATH" >&2
        exit 1
    fi

    INFO_PLIST="$APP_PATH/Contents/Info.plist"
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
    BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
    EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
    ACTUAL_ARCH="$(lipo -archs "$APP_PATH/Contents/MacOS/$EXECUTABLE")"

    if [ "$ACTUAL_ARCH" != "$ARCH" ]; then
        echo "[ERROR] 架构校验失败，期望 $ARCH，实际 $ACTUAL_ARCH" >&2
        exit 1
    fi

    codesign --verify --deep --strict "$APP_PATH"

    STAGING_DIR="$TEMP_ROOT/dmg-$ARCH"
    mkdir -p "$STAGING_DIR"
    ditto "$APP_PATH" "$STAGING_DIR/PasteLight.app"
    ln -s /Applications "$STAGING_DIR/Applications"

    DMG_PATH="$OUTPUT_DIR/PasteLight-$VERSION-$ARCH.dmg"
    log_info "制作 $(basename "$DMG_PATH")..."
    hdiutil create \
        -volname "PasteLight $VERSION" \
        -srcfolder "$STAGING_DIR" \
        -format UDZO \
        -ov \
        "$DMG_PATH" >/dev/null

    hdiutil verify "$DMG_PATH" >/dev/null
    log_success "$(basename "$DMG_PATH") — $ARCH, $VERSION (Build $BUILD)"
done

log_info "SHA-256"
shasum -a 256 \
    "$OUTPUT_DIR/PasteLight-$VERSION-arm64.dmg" \
    "$OUTPUT_DIR/PasteLight-$VERSION-x86_64.dmg"

log_success "PasteLight 双架构 Release DMG 构建完成"
