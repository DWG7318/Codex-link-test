#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$ROOT_DIR/tools"
PIPER_DIR="$TOOLS_DIR/piper"
WHISPER_DIR="$TOOLS_DIR/whisper.cpp"
MODEL_DIR="$ROOT_DIR/models"
VOICE_DIR="$MODEL_DIR/piper"
WHISPER_MODEL_DIR="$MODEL_DIR/whisper"

mkdir -p "$PIPER_DIR" "$WHISPER_DIR" "$VOICE_DIR" "$WHISPER_MODEL_DIR"

log() { echo "[install] $*"; }

log "Installing system dependencies (ffmpeg/python3/curl/git/build-essential)..."
sudo apt-get update
sudo apt-get install -y ffmpeg python3 python3-venv python3-pip curl git wget ca-certificates build-essential cmake

log "Downloading piper binary..."
PIPER_URL="https://github.com/rhasspy/piper/releases/download/v1.2.0/piper_amd64.tar.gz"
if [[ ! -f "$PIPER_DIR/piper" ]]; then
  curl -L "$PIPER_URL" -o "$PIPER_DIR/piper.tar.gz"
  tar -xzf "$PIPER_DIR/piper.tar.gz" -C "$PIPER_DIR"
  chmod +x "$PIPER_DIR/piper"
fi

log "Downloading Piper voice models (CN female + CN male fallback EN)..."
# Preferred Chinese voices.
CN_F_JSON="$VOICE_DIR/zh_CN-huayan-medium.onnx.json"
CN_F_ONNX="$VOICE_DIR/zh_CN-huayan-medium.onnx"
CN_M_JSON="$VOICE_DIR/zh_CN-huayan-high.onnx.json"
CN_M_ONNX="$VOICE_DIR/zh_CN-huayan-high.onnx"

# Fallback English voices.
EN_F_JSON="$VOICE_DIR/en_US-amy-medium.onnx.json"
EN_F_ONNX="$VOICE_DIR/en_US-amy-medium.onnx"
EN_M_JSON="$VOICE_DIR/en_US-ryan-medium.onnx.json"
EN_M_ONNX="$VOICE_DIR/en_US-ryan-medium.onnx"

fetch_if_missing() {
  local url="$1"
  local out="$2"
  if [[ ! -f "$out" ]]; then
    curl -fL "$url" -o "$out" || return 1
  fi
}

# Try Chinese first.
fetch_if_missing "https://huggingface.co/rhasspy/piper-voices/resolve/main/zh/zh_CN/huayan/medium/zh_CN-huayan-medium.onnx" "$CN_F_ONNX" || true
fetch_if_missing "https://huggingface.co/rhasspy/piper-voices/resolve/main/zh/zh_CN/huayan/medium/zh_CN-huayan-medium.onnx.json" "$CN_F_JSON" || true
fetch_if_missing "https://huggingface.co/rhasspy/piper-voices/resolve/main/zh/zh_CN/huayan/high/zh_CN-huayan-high.onnx" "$CN_M_ONNX" || true
fetch_if_missing "https://huggingface.co/rhasspy/piper-voices/resolve/main/zh/zh_CN/huayan/high/zh_CN-huayan-high.onnx.json" "$CN_M_JSON" || true

# English fallback.
if [[ ! -f "$CN_F_ONNX" || ! -f "$CN_M_ONNX" ]]; then
  log "Chinese voices not fully available; downloading English fallback voices..."
  fetch_if_missing "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx" "$EN_F_ONNX"
  fetch_if_missing "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx.json" "$EN_F_JSON"
  fetch_if_missing "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/medium/en_US-ryan-medium.onnx" "$EN_M_ONNX"
  fetch_if_missing "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/medium/en_US-ryan-medium.onnx.json" "$EN_M_JSON"
fi

log "Preparing whisper.cpp..."
if [[ ! -d "$WHISPER_DIR/.git" ]]; then
  git clone https://github.com/ggerganov/whisper.cpp.git "$WHISPER_DIR"
fi
pushd "$WHISPER_DIR" >/dev/null
cmake -B build
cmake --build build -j
popd >/dev/null

log "Downloading whisper model ggml-base.bin (fallback tiny if base fails)..."
if [[ ! -f "$WHISPER_MODEL_DIR/ggml-base.bin" ]]; then
  curl -fL "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin" -o "$WHISPER_MODEL_DIR/ggml-base.bin" || true
fi
if [[ ! -f "$WHISPER_MODEL_DIR/ggml-base.bin" && ! -f "$WHISPER_MODEL_DIR/ggml-tiny.bin" ]]; then
  curl -fL "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin" -o "$WHISPER_MODEL_DIR/ggml-tiny.bin"
fi

log "Done. Next: ./run.sh --topic-file input/topic.txt --outline input/outline.md"
