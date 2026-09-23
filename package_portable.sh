#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PYTHON="$ROOT/.venv/bin/python"
APP="$ROOT/build/iOS Location Controller.app"
BACKEND_BUILD="$ROOT/build/pyinstaller"
ARCHIVE="$ROOT/dist/iOS-Location-Controller-macOS-arm64.zip"
CHECKSUM="$ARCHIVE.sha256"
export PYINSTALLER_CONFIG_DIR="$BACKEND_BUILD/config"

if ! "$PYTHON" -m PyInstaller --version >/dev/null 2>&1; then
    print -u2 "Install build dependencies: $PYTHON -m pip install pyinstaller"
    exit 2
fi

"$ROOT/build_macos_app.sh"
mkdir -p "$PYINSTALLER_CONFIG_DIR"
"$PYTHON" -m PyInstaller --noconfirm --clean --onedir \
    --name locationctl --target-architecture arm64 \
    --collect-all pymobiledevice3 \
    --distpath "$BACKEND_BUILD/dist" \
    --workpath "$BACKEND_BUILD/work" \
    --specpath "$BACKEND_BUILD/spec" \
    "$ROOT/locationctl.py"

mkdir -p "$APP/Contents/Resources/backend" "$ROOT/dist"
ditto "$BACKEND_BUILD/dist/locationctl" "$APP/Contents/Resources/backend"
"$PYTHON" "$ROOT/generate_third_party_notices.py" \
    --pyinstaller-toc "$BACKEND_BUILD/work/locationctl/PYZ-00.toc" \
    "$APP/Contents/Resources/THIRD_PARTY_NOTICES"
mkdir -p "$APP/Contents/Resources/SOURCE" "$APP/Contents/Resources/THIRD_PARTY_SOURCES"
cp "$ROOT/LocationControllerApp.swift" "$ROOT/locationctl.py" "$ROOT/Info.plist" \
    "$ROOT/pyproject.toml" "$ROOT/build_macos_app.sh" "$ROOT/package_portable.sh" \
    "$ROOT/generate_third_party_notices.py" "$ROOT/run_locationctl.sh" \
    "$ROOT/README.md" "$ROOT/LICENSE" "$ROOT/SOURCE_OFFER.txt" \
    "$APP/Contents/Resources/SOURCE"
ditto "$ROOT/third_party_license_overrides" \
    "$APP/Contents/Resources/SOURCE/third_party_license_overrides"
cp "$ROOT/third_party_sources/"*.tar.gz "$APP/Contents/Resources/THIRD_PARTY_SOURCES"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "$ROOT/SOURCE_OFFER.txt" "$APP/Contents/Resources/SOURCE_OFFER.txt"
codesign --force --deep --sign - "$APP"
ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$APP" "$ARCHIVE"
(
    cd "$ROOT/dist"
    shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$CHECKSUM")"
)
print "$ARCHIVE"
