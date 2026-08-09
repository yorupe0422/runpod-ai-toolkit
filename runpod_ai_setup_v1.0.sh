#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== RunPod AI Toolkit v1.0 (MiniMax H3) ==="

WORKSPACE="${WORKSPACE:-/workspace}"
PORT="${PORT:-8188}"
PYTHON_BIN="${PYTHON_BIN:-python3.12}"

COMFY_DIR=$(find "$WORKSPACE" -maxdepth 3 -type d -name ComfyUI | head -n1)

if [ -z "${COMFY_DIR}" ]; then
  echo "[ERROR] ComfyUI not found under $WORKSPACE"
  exit 1
fi

echo "[OK] ComfyUI: $COMFY_DIR"
cd "$COMFY_DIR"

echo "== Updating ComfyUI =="
git pull || true

if [ -f requirements.txt ]; then
  $PYTHON_BIN -m pip install -r requirements.txt
fi

mkdir -p \
 models/diffusion_models \
 models/text_encoders \
 models/vae \
 models/loras

download () {
  local url="$1"
  local out="$2"
  if [ -f "$out" ]; then
    echo "[SKIP] $(basename "$out")"
  else
    echo "[DL] $(basename "$out")"
    wget -c -O "$out" "$url"
  fi
}

download \
"https://huggingface.co/realrebelai/MiniMax-H3_GGUFs/resolve/main/MiniMax-H3-FL2VA-Q4_K_M.gguf" \
"models/diffusion_models/MiniMax-H3-FL2VA-Q4_K_M.gguf"

download \
"https://huggingface.co/realrebelai/MiniMax-H3_GGUFs/resolve/main/qwen3vl-32B-MiniMax-H3-Q4_K_M.gguf" \
"models/text_encoders/qwen3vl-32B-MiniMax-H3-Q4_K_M.gguf"

download \
"https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_video_vae_fp16.safetensors" \
"models/vae/minimax_h3_video_vae_fp16.safetensors"

download \
"https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_audio_vae_fp32.safetensors" \
"models/vae/minimax_h3_audio_vae_fp32.safetensors"

echo ""
echo "NOTE:"
echo "Turbo LoRA URL is intentionally left out in v1.0 because upstream filenames have changed repeatedly."
echo "It will be added after URL verification in v1.1."

echo "Restarting ComfyUI..."
pkill -f "python3.12 main.py" || true
nohup $PYTHON_BIN main.py \
  --listen 0.0.0.0 \
  --port "$PORT" \
  --preview-method auto \
  --enable-cors-header \
  > "$WORKSPACE/runpod-slim/comfyui.log" 2>&1 &

sleep 5

echo ""
echo "=== Installed ==="
ls -lh models/diffusion_models/MiniMax-H3-FL2VA-Q4_K_M.gguf
ls -lh models/text_encoders/qwen3vl-32B-MiniMax-H3-Q4_K_M.gguf
ls -lh models/vae/minimax_h3_video_vae_fp16.safetensors
ls -lh models/vae/minimax_h3_audio_vae_fp32.safetensors

echo ""
echo "Done."
