#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Setup #5 COMPLETE — MiniMax H3 / PinkCherry
# New-Pod full setup:
#   - verifies/downloads core models
#   - installs ComfyUI-GGUF if missing
#   - downloads Turbo LoRA
#   - optionally downloads PinkCherry
#   - installs a public FL2V workflow
#   - launches ComfyUI with OOM-safe profile
#
# Canonical runtime:
#   Dynamic VRAM ON / reserve-vram 4 / cache-none
# ============================================================

COMFY="/workspace/runpod-slim/ComfyUI"
PORT="${PORT:-8188}"
PY="${PYTHON_BIN:-python3.12}"
LOG="/workspace/runpod-slim/comfyui.log"
INSTALL_PINKCHERRY="${INSTALL_PINKCHERRY:-1}"

FL2VA="MiniMax-H3-FL2VA-Q4_K_M.gguf"
TEXT="qwen3vl-32B-MiniMax-H3-Q4_K_M.gguf"
VVAE="minimax_h3_video_vae_fp16.safetensors"
AVAE="minimax_h3_audio_vae_fp32.safetensors"
TURBO="minimax_h3_turbo_v4_step600_ema_pruned_comfyui.safetensors"
PINK="PinkCherry_h3_fl2va_pruned_int8_v0.5-alpha.safetensors"

URL_FL2VA="https://huggingface.co/realrebelai/MiniMax-H3_GGUFs/resolve/main/$FL2VA"
URL_TEXT="https://huggingface.co/realrebelai/MiniMax-H3_GGUFs/resolve/main/$TEXT"
URL_VVAE="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/$VVAE"
URL_AVAE="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/$AVAE"
URL_TURBO="https://huggingface.co/drbaph/MiniMax-H3-Turbo-Lora-ComfyUI/resolve/main/$TURBO"
URL_PINK="https://huggingface.co/SexGod1979/PinkCherry_MiniMax-H3/resolve/main/alpha-0.5-testing/$PINK"
URL_WF="https://huggingface.co/realrebelai/MiniMax-H3_GGUFs/resolve/main/FL2V_%28WORKFLOW%29.json"

die(){ echo "[FAILED] $*" >&2; exit 1; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }

download(){
  local url="$1" dest="$2" min="$3"
  mkdir -p "$(dirname "$dest")"

  if [[ -f "$dest" ]]; then
    size="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
    if (( size >= min )); then
      echo "[SKIP] $(basename "$dest")"
      return
    fi
  fi

  echo "[DL] $(basename "$dest")"
  rm -f "$dest.aria2"
  if command -v aria2c >/dev/null 2>&1; then
    aria2c -c -x16 -s16 -k16M --file-allocation=none \
      --allow-overwrite=true --auto-file-renaming=false \
      --dir "$(dirname "$dest")" --out "$(basename "$dest")" "$url"
  else
    curl -L --fail --retry 5 -o "$dest" "$url"
  fi

  size="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
  (( size >= min )) || die "Incomplete download: $dest"
}

echo "============================================================"
echo " Setup #5 COMPLETE — MiniMax H3 / PinkCherry"
echo "============================================================"

[[ -d "$COMFY" ]] || die "ComfyUI not found: $COMFY"
[[ -f "$COMFY/main.py" ]] || die "ComfyUI main.py missing"

echo "[1/7] Stop running ComfyUI"
pkill -9 -f "python.*main.py" 2>/dev/null || true
sleep 3

echo "[2/7] Ensure ComfyUI-GGUF"
if [[ ! -d "$COMFY/custom_nodes/ComfyUI-GGUF" ]]; then
  git clone --depth 1 https://github.com/city96/ComfyUI-GGUF.git "$COMFY/custom_nodes/ComfyUI-GGUF"
  [[ ! -f "$COMFY/custom_nodes/ComfyUI-GGUF/requirements.txt" ]] || \
    "$PY" -m pip install -q -r "$COMFY/custom_nodes/ComfyUI-GGUF/requirements.txt"
fi
green "  ✓ ComfyUI-GGUF ready"

echo "[3/7] Download MiniMax H3 core files"
download "$URL_FL2VA" "$COMFY/models/diffusion_models/$FL2VA" 19000000000
download "$URL_TEXT"  "$COMFY/models/text_encoders/$TEXT" 14000000000
download "$URL_VVAE"  "$COMFY/models/vae/$VVAE" 4900000000
download "$URL_AVAE"  "$COMFY/models/vae/$AVAE" 550000000
green "  ✓ core models ready"

echo "[4/7] Download Turbo LoRA"
download "$URL_TURBO" "$COMFY/models/loras/$TURBO" 600000000
green "  ✓ Turbo LoRA ready"

echo "[5/7] PinkCherry"
if [[ "$INSTALL_PINKCHERRY" == "1" ]]; then
  download "$URL_PINK" "$COMFY/models/diffusion_models/$PINK" 20000000000
  green "  ✓ PinkCherry ready"
else
  echo "  PinkCherry skipped"
fi

echo "[6/7] Install baseline workflow"
mkdir -p "$COMFY/user/default/workflows"
download "$URL_WF" "$COMFY/user/default/workflows/MiniMax_H3_FL2V_PUBLIC_BASE.json" 50000
green "  ✓ workflow ready"

echo "[7/7] Launch OOM-safe"
cd "$COMFY"
nohup "$PY" main.py \
  --listen 0.0.0.0 \
  --port "$PORT" \
  --preview-method auto \
  --enable-cors-header \
  --reserve-vram 4 \
  --cache-none \
  > "$LOG" 2>&1 &
PID=$!

for i in $(seq 1 180); do
  kill -0 "$PID" 2>/dev/null || { tail -120 "$LOG"; exit 1; }
  if curl --max-time 3 -fsS "http://127.0.0.1:$PORT/system_stats" >/tmp/setup5_stats.json 2>/dev/null; then
    break
  fi
  sleep 1
done

echo
green "SETUP #5 COMPLETE READY"
echo "Port : $PORT"
echo "VRAM : Dynamic VRAM ON / reserve 4 GB / cache-none"
echo "FL2V : $FL2VA"
echo "Qwen : $TEXT"
echo "VAE  : $VVAE / $AVAE"
echo "LoRA : $TURBO"
if [[ "$INSTALL_PINKCHERRY" == "1" ]]; then echo "Pink : $PINK"; fi
echo "WF   : MiniMax_H3_FL2V_PUBLIC_BASE.json"
