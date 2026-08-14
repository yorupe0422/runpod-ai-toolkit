#!/usr/bin/env bash
set -Eeuo pipefail

PORT="${PORT:-8188}"
WORKSPACE="${WORKSPACE:-/workspace}"
PYTHON_BIN="${PYTHON_BIN:-python3.12}"
RUNPOD_ROOT="${RUNPOD_ROOT:-/workspace/runpod-slim}"

COMFYUI_DIR="${COMFYUI_DIR:-$(find "$WORKSPACE" -maxdepth 3 -type d -name 'ComfyUI' | head -n 1)}"
[[ -n "${COMFYUI_DIR}" && -d "${COMFYUI_DIR}" ]] || { echo "[ERROR] ComfyUI not found"; exit 1; }

WF_DIR="${COMFYUI_DIR}/user/default/workflows"
META_DIR="${RUNPOD_ROOT}/runpod-ai-toolkit/ref2va_abc"
mkdir -p "$WF_DIR" "$META_DIR" \
  "${COMFYUI_DIR}/models/diffusion_models" \
  "${COMFYUI_DIR}/models/text_encoders" \
  "${COMFYUI_DIR}/models/vae"

download_file() {
  local url="$1" dest="$2"
  if [[ -s "$dest" ]]; then echo "[SKIP] $(basename "$dest")"; return; fi
  echo "[DL] $(basename "$dest")"
  if command -v aria2c >/dev/null 2>&1; then
    aria2c -c -x16 -s16 -k10M --allow-overwrite=true --auto-file-renaming=false \
      --dir "$(dirname "$dest")" --out "$(basename "$dest")" "$url"
  else
    curl -L --fail --retry 5 -o "$dest" "$url"
  fi
}

REF2VA_MODEL="MiniMax-H3-REF2VA-Q4_K_M.gguf"
TEXT_ENCODER="qwen3vl-32B-MiniMax-H3-Q4_K_M.gguf"
VIDEO_VAE="minimax_h3_video_vae_fp16.safetensors"
AUDIO_VAE="minimax_h3_audio_vae_fp32.safetensors"

download_file \
 "https://huggingface.co/realrebelai/MiniMax-H3_GGUFs/resolve/main/${REF2VA_MODEL}" \
 "${COMFYUI_DIR}/models/diffusion_models/${REF2VA_MODEL}"

download_file \
 "https://huggingface.co/realrebelai/MiniMax-H3_GGUFs/resolve/main/${TEXT_ENCODER}" \
 "${COMFYUI_DIR}/models/text_encoders/${TEXT_ENCODER}"

download_file \
 "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/${VIDEO_VAE}" \
 "${COMFYUI_DIR}/models/vae/${VIDEO_VAE}"

download_file \
 "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/${AUDIO_VAE}" \
 "${COMFYUI_DIR}/models/vae/${AUDIO_VAE}"

download_file \
 "https://huggingface.co/vantagewithai/MiniMax-H3-comfyUI-GGUF/resolve/main/workflows/Vantage-Minimax-H3_4_steps-Ref2VA.json?download=true" \
 "${WF_DIR}/minimax_h3_ref2va_base_public.json"

cat > "${META_DIR}/README.txt" <<'EOF'
MiniMax H3 Ref2VA A/B/C

Image 1 = Image A (subject/person)
Image 2 = Image B (background/environment)
Video 1 = Video C (motion reference)

Workflow:
minimax_h3_ref2va_base_public.json

First test:
5 sec / 8 steps / Euler / Beta / 460x460 or 512x512

This setup is additive: it does not replace the existing FL2VA workflow.
EOF

echo
echo "============================================================"
echo " MiniMax H3 Ref2VA A/B/C setup complete"
echo "============================================================"
echo "Workflow: ${WF_DIR}/minimax_h3_ref2va_base_public.json"
echo "Image 1 : A / subject"
echo "Image 2 : B / background"
echo "Video 1 : C / motion"
echo "============================================================"
