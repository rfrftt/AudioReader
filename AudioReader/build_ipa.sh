#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_PATH="$PROJECT_DIR/AudioReader.xcodeproj"
SCHEME="AudioReader"
CONFIGURATION="Release"
ARCHIVE_PATH="$PROJECT_DIR/build/$SCHEME.xcarchive"
EXPORT_PATH="$PROJECT_DIR/build/ipa"
EXPORT_OPTIONS_PLIST="$PROJECT_DIR/ExportOptions.plist"

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
mkdir -p "$PROJECT_DIR/build"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  archive

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

ls -la "$EXPORT_PATH"
