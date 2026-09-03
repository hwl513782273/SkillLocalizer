#!/bin/bash
# SkillLocalizer 一键构建脚本（macOS 12+ Universal）
# 用法：bash build.sh
set -e

APP_NAME=SkillLocalizer
VERSION=1.1.9
MIN_MACOS=12.0
ARCH=universal
DMG_NAME="${MIN_MACOS}-${APP_NAME}-${VERSION}-${ARCH}.dmg"
TARGET=arm64-apple-macosx${MIN_MACOS}

mkdir -p "${APP_NAME}.app/Contents/MacOS" "${APP_NAME}.app/Contents/Resources"

echo "==> 编译 (${TARGET}, Universal)"
swiftc -O -parse-as-library -target "${TARGET}" \
  -framework SwiftUI -framework AppKit -framework Foundation \
  -framework Security -framework CryptoKit -framework UniformTypeIdentifiers \
  main.swift -o "${APP_NAME}.app/Contents/MacOS/${APP_NAME}"

echo "==> 签名"
codesign --force --deep --sign - "${APP_NAME}.app"

echo "==> 打包 DMG: ${DMG_NAME}"
rm -f "${DMG_NAME}"
hdiutil create -format UDZO -volname "${APP_NAME}" \
  -srcfolder "${APP_NAME}.app" "${DMG_NAME}"

echo "==> 完成: $(ls -lh "${DMG_NAME}" | awk '{print $5"  "$9}')"
