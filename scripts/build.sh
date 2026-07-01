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

# ---- Resolve include paths ---------------------------------------------------
# llama.h does `#include "ggml.h"` (plus ggml-*.h). Some llama.cpp packagings —
# notably certain Homebrew bottles — install llama.h into include/ but leave the
# ggml headers out, so the quoted include fails with: 'ggml.h' file not found.
# Make sure every directory that actually holds those headers is on the include
# path: keep $INC, and if ggml.h isn't sitting next to llama.h, hunt for it in
# the install, then fall back to the headers vendored in this repo.
INCLUDES=( "$INC" )
if [ ! -f "$INC/ggml.h" ]; then
  echo "==> ggml.h not next to llama.h — locating it"
  GGML_H=""
  for root in "$INC" "$LIBDIR/.." "$BREW_PREFIX" "${TYPER_LLAMA_PREFIX:-}"; do
    [ -n "$root" ] && [ -d "$root" ] || continue
    GGML_H="$(find -L "$root" -name ggml.h -type f 2>/dev/null | head -n1)"
    [ -n "$GGML_H" ] && break
  done
  if [ -n "$GGML_H" ]; then
    GGML_INC="$(cd "$(dirname "$GGML_H")" && pwd)"
    echo "==> Found ggml headers in: $GGML_INC"
    INCLUDES+=( "$GGML_INC" )
  elif [ -f "$ROOT_DIR/vendor/llama.cpp/include/ggml.h" ]; then
    echo "!! ggml.h is missing from the llama.cpp install; using this repo's vendored headers."
    echo "!! If you later hit link/ABI errors, run:  brew reinstall llama.cpp"
    INCLUDES+=( "$ROOT_DIR/vendor/llama.cpp/include" )
  else
    echo "!! Could not find ggml.h (needed by llama.h). Try:  brew reinstall llama.cpp" >&2
    exit 1
  fi
fi
INCLUDE_FLAGS=(); for d in "${INCLUDES[@]}"; do INCLUDE_FLAGS+=( -I"$d" ); done

echo "==> Building typer-llama-server"
clang++ -std=c++17 -O3 "$ROOT_DIR/scripts/llama_server.cpp" \
  "${INCLUDE_FLAGS[@]}" "${LIBFILES[@]}" -Wl,-rpath,"$LIBDIR" \
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

# Stamp the source checkout path + built commit into the bundle so the app's "Check for
# updates" button can locate this repo and compare against upstream. Must run BEFORE codesign,
# which seals the bundle (editing Info.plist afterwards would break the signature). Info.plist
# is rewritten from scratch each build, so these keys never pre-exist — a plain Add is enough.
GIT_SHA="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
/usr/libexec/PlistBuddy -c "Add :TyperRepoPath string $ROOT_DIR" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :TyperGitCommit string $GIT_SHA" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true

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
