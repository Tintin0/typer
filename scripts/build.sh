#!/usr/bin/env bash
# Build the Typer llama helper + Swift menu-bar app, assemble the bundle, sign it
# with the stable self-signed certificate (so macOS keeps the Accessibility grant
# across rebuilds), and restart.
#
# llama.cpp is resolved in this order:
#   1. Homebrew:           brew --prefix llama.cpp   (recommended; `brew install llama.cpp`)
#   2. $TYPER_LLAMA_PREFIX (point at any llama.cpp install: <prefix>/include + <prefix>/lib)
#   3. Local fallback:     vendor/llama.cpp/include + $TYPER_LLAMA_LIB (default ~/.local/share/typer/lib)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="$HOME/.local/share/typer"
APP="$HOME/Applications/Typer.app"
CERT_CN="${TYPER_SIGN_CN:-Typer Self-Signed}"

mkdir -p "$DATA_DIR" "$APP/Contents/MacOS"

# ---- Resolve llama.cpp -------------------------------------------------------
INC=""; LIBDIR=""
BREW_PREFIX="$(brew --prefix llama.cpp 2>/dev/null || true)"
if [ -n "${TYPER_LLAMA_PREFIX:-}" ] && [ -f "$TYPER_LLAMA_PREFIX/include/llama.h" ]; then
  INC="$TYPER_LLAMA_PREFIX/include"; LIBDIR="$TYPER_LLAMA_PREFIX/lib"
elif [ -n "$BREW_PREFIX" ] && [ -f "$BREW_PREFIX/include/llama.h" ]; then
  INC="$BREW_PREFIX/include"; LIBDIR="$BREW_PREFIX/lib"
elif [ -f "$ROOT_DIR/vendor/llama.cpp/include/llama.h" ] && ls "${TYPER_LLAMA_LIB:-$DATA_DIR/lib}"/libllama* >/dev/null 2>&1; then
  INC="$ROOT_DIR/vendor/llama.cpp/include"; LIBDIR="${TYPER_LLAMA_LIB:-$DATA_DIR/lib}"
else
  echo "!! Could not find llama.cpp. Install it with:  brew install llama.cpp" >&2
  echo "   (or set TYPER_LLAMA_PREFIX to a llama.cpp install with include/ and lib/)" >&2
  exit 1
fi
echo "==> Using llama.cpp from: $LIBDIR"

# Link every llama/ggml dylib present (handles both versioned and unversioned names).
# Use an array + globbing (not `ls`) so paths with spaces/metacharacters are safe.
shopt -s nullglob
LIBFILES=( "$LIBDIR"/libllama*.dylib "$LIBDIR"/libggml*.dylib )
shopt -u nullglob
[ "${#LIBFILES[@]}" -gt 0 ] || { echo "!! No libllama/libggml dylibs in $LIBDIR" >&2; exit 1; }

echo "==> Building typer-llama-server"
clang++ -std=c++17 -O3 "$ROOT_DIR/scripts/llama_server.cpp" \
  -I"$INC" "${LIBFILES[@]}" -Wl,-rpath,"$LIBDIR" \
  -o "$DATA_DIR/typer-llama-server"

echo "==> Building Swift menu-bar app"
# The app is split across scripts/typer/*.swift (one TyperApp extension per topic +
# one file per supporting type). swiftc compiles them as a single module.
swiftc -O "$ROOT_DIR"/scripts/typer/*.swift -o "$DATA_DIR/typer-menu-bar"
cp "$DATA_DIR/typer-menu-bar" "$APP/Contents/MacOS/Typer"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Typer</string>
  <key>CFBundleIdentifier</key><string>local.typer.menubar</string>
  <key>CFBundleName</key><string>Typer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# ---- Sign --------------------------------------------------------------------
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_CN"; then
  echo "==> Signing with stable identity '$CERT_CN'"
  codesign --force --sign "$CERT_CN" --identifier local.typer.menubar --timestamp=none "$APP"
else
  echo "!! Stable identity '$CERT_CN' not found — using ad-hoc signing."
  echo "!! Accessibility trust resets on each rebuild. Run scripts/make_signing_cert.sh once to fix."
  codesign --force --sign - "$APP"
fi
echo "==> Designated requirement:"; codesign -d -r- "$APP" 2>&1 | sed -n 's/^# designated => /  /p'

pkill -f "Typer.app/Contents/MacOS/Typer" 2>/dev/null || true
pkill -f typer-llama-server 2>/dev/null || true

echo
echo "Build complete.  Launch:  open \"$APP\""
echo "Logs:  tail -f ~/Library/Logs/Typer.log"
