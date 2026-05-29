#!/usr/bin/env bash
# Typer installer (macOS). Sets up the on-device autocomplete app:
#   - installs llama.cpp via Homebrew
#   - downloads a GGUF model from Hugging Face
#   - writes a default config
#   - builds + installs ~/Applications/Typer.app
#
# Re-run any time; it is idempotent. After it finishes, grant Accessibility (and
# optionally Screen Recording) to Typer.app, then launch it.
set -euo pipefail

# --- tunables (override via env) ---------------------------------------------
MODEL_REPO="${TYPER_MODEL_REPO:-unsloth/gemma-4-E2B-it-GGUF}"
MODEL_FILE="${TYPER_MODEL_FILE:-gemma-4-E2B-it-Q4_K_M.gguf}"
MODEL_URL="${TYPER_MODEL_URL:-https://huggingface.co/$MODEL_REPO/resolve/main/$MODEL_FILE?download=true}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$HOME/.local/share/typer"
CONFIG_DIR="$HOME/Library/Application Support/typer"
MODEL_DIR="$CONFIG_DIR/Models"

[ "$(uname -s)" = "Darwin" ] || { echo "Typer is macOS-only." >&2; exit 1; }

echo "==> Checking toolchain"
xcode-select -p >/dev/null 2>&1 || { echo "Xcode Command Line Tools required:  xcode-select --install" >&2; exit 1; }
command -v swiftc >/dev/null || { echo "swiftc not found (install Xcode Command Line Tools)" >&2; exit 1; }

echo "==> Ensuring llama.cpp (Homebrew)"
if ! command -v brew >/dev/null; then
  echo "Homebrew is required: https://brew.sh" >&2; exit 1
fi
if [ ! -f "$(brew --prefix llama.cpp 2>/dev/null)/include/llama.h" ]; then
  brew install llama.cpp
fi

mkdir -p "$DATA_DIR" "$MODEL_DIR" "$HOME/Applications"

# --- model -------------------------------------------------------------------
if ls "$MODEL_DIR"/*.gguf >/dev/null 2>&1; then
  echo "==> Model already present in $MODEL_DIR"
else
  echo "==> Downloading model: $MODEL_REPO / $MODEL_FILE"
  echo "    (override with TYPER_MODEL_REPO / TYPER_MODEL_FILE / TYPER_MODEL_URL)"
  tmp="$MODEL_DIR/.download.gguf"
  if ! curl -fL --progress-bar "$MODEL_URL" -o "$tmp"; then
    echo "!! Download failed. Find the exact GGUF on Hugging Face and re-run with e.g.:" >&2
    echo "   TYPER_MODEL_URL='https://huggingface.co/<repo>/resolve/main/<file>.gguf' ./install.sh" >&2
    rm -f "$tmp"; exit 1
  fi
  # Sanity: a real GGUF is many hundreds of MB and starts with the 'GGUF' magic.
  if [ "$(stat -f%z "$tmp" 2>/dev/null || echo 0)" -lt 100000000 ] || [ "$(head -c 4 "$tmp")" != "GGUF" ]; then
    echo "!! Downloaded file is not a valid GGUF (wrong URL?). See README > Model." >&2
    rm -f "$tmp"; exit 1
  fi
  mv "$tmp" "$MODEL_DIR/$MODEL_FILE"
fi

# --- default config ----------------------------------------------------------
if [ ! -f "$CONFIG_DIR/config.toml" ]; then
  echo "==> Writing default config: $CONFIG_DIR/config.toml"
  cp "$ROOT_DIR/config.example.toml" "$CONFIG_DIR/config.toml"
fi

# --- build + install ---------------------------------------------------------
bash "$ROOT_DIR/scripts/build.sh"

cat <<EOF

============================================================
Typer installed.

1) (Recommended) Stable code signing so Accessibility survives rebuilds:
     ./scripts/make_signing_cert.sh
     ./scripts/build.sh

2) Grant permissions in System Settings > Privacy & Security:
     - Accessibility      -> enable "Typer"   (required)
     - Screen Recording   -> enable "Typer"   (optional: caret placement + screen context in Electron/terminals)

3) Launch:
     open ~/Applications/Typer.app

Type in any text field; a grey suggestion appears at your cursor.
  Tab = accept one word   \` = accept all   Esc = dismiss
Logs: tail -f ~/Library/Logs/Typer.log
============================================================
EOF
