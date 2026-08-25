#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Qwen-Image-GenatomyFixer LoRA installer for ComfyUI
# Target: Qwen-Image-Edit-2511
# Existing ComfyUI is NOT replaced or updated.
# ============================================================

COMFY_DIR="${COMFY_DIR:-/workspace/runpod-slim/ComfyUI}"
LORA_DIR="$COMFY_DIR/models/loras"
REPO="Zaytron40k/Qwen-Image-GenatomyFixer"
REMOTE_FILE="checkpoints/epoch-7.safetensors"
OUT_FILE="$LORA_DIR/Qwen-Image-GenatomyFixer_epoch-7.safetensors"

echo "============================================================"
echo " Qwen-Image-GenatomyFixer LoRA installer"
echo "============================================================"
echo "[INFO] ComfyUI: $COMFY_DIR"
echo "[INFO] Output : $OUT_FILE"

if [[ ! -d "$COMFY_DIR" ]]; then
  echo "[ERROR] ComfyUI directory not found: $COMFY_DIR"
  echo "If your ComfyUI is elsewhere, run:"
  echo "  COMFY_DIR=/path/to/ComfyUI bash $0"
  exit 1
fi

mkdir -p "$LORA_DIR"

if [[ -s "$OUT_FILE" ]]; then
  echo "[OK] LoRA already exists:"
  ls -lh "$OUT_FILE"
else
  echo "[INFO] Downloading epoch-7 checkpoint from Hugging Face..."

  URL="https://huggingface.co/${REPO}/resolve/main/${REMOTE_FILE}?download=true"

  if command -v aria2c >/dev/null 2>&1; then
    aria2c \
      --console-log-level=notice \
      --summary-interval=5 \
      -x 16 -s 16 -k 1M \
      --allow-overwrite=true \
      --auto-file-renaming=false \
      -d "$LORA_DIR" \
      -o "$(basename "$OUT_FILE")" \
      "$URL"
  else
    curl -fL --retry 5 --retry-delay 2 \
      --connect-timeout 30 \
      -o "${OUT_FILE}.part" \
      "$URL"
    mv "${OUT_FILE}.part" "$OUT_FILE"
  fi
fi

if [[ ! -s "$OUT_FILE" ]]; then
  echo "[ERROR] Download failed or file is empty."
  exit 1
fi

echo
echo "[OK] Installed:"
ls -lh "$OUT_FILE"

echo
echo "============================================================"
echo " ComfyUI usage"
echo "============================================================"
echo "LoRA file:"
echo "  Qwen-Image-GenatomyFixer_epoch-7.safetensors"
echo
echo "Recommended starting strength:"
echo "  0.30"
echo
echo "Author-recommended sweep:"
echo "  0.20 / 0.30 / 0.40 / 0.50"
echo
echo "In a Qwen-Image-Edit-2511 workflow:"
echo "  diffusion model"
echo "       |"
echo "  LoRA Loader (MODEL/model-only)"
echo "       |"
echo "  sampler"
echo
echo "If the LoRA does not appear in the dropdown, refresh the browser."
echo "If still absent, restart ComfyUI."
echo
echo "[DONE] Existing models/workflows were not modified."
