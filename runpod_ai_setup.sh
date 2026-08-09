#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# RunPod AI Toolkit v4.0
# MiniMax H3 + Turbo + PinkCherry v0.5 alpha
# ============================================================

VERSION="4.0"
WORKSPACE="${WORKSPACE:-/workspace}"
PORT="${PORT:-8188}"
PYTHON_BIN="${PYTHON_BIN:-python3.12}"
DOWNLOAD_CONNECTIONS="${DOWNLOAD_CONNECTIONS:-8}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-180}"
INSTALL_PINKCHERRY="${INSTALL_PINKCHERRY:-1}"
INSTALL_WORKFLOWS="${INSTALL_WORKFLOWS:-1}"

TOOLKIT_REPO_RAW="${TOOLKIT_REPO_RAW:-https://raw.githubusercontent.com/yorupe0422/runpod-ai-toolkit/main}"

MODEL_MAIN="MiniMax-H3-FL2VA-Q4_K_M.gguf"
MODEL_TEXT="qwen3vl-32B-MiniMax-H3-Q4_K_M.gguf"
VAE_VIDEO="minimax_h3_video_vae_fp16.safetensors"
VAE_AUDIO="minimax_h3_audio_vae_fp32.safetensors"
LORA_TURBO="minimax_h3_turbo_v4_step600_ema_pruned_comfyui.safetensors"
PINKCHERRY="PinkCherry_h3_fl2va_pruned_int8_v0.5-alpha.safetensors"

URL_MAIN="https://huggingface.co/realrebelai/MiniMax-H3_GGUFs/resolve/main/${MODEL_MAIN}"
URL_TEXT="https://huggingface.co/realrebelai/MiniMax-H3_GGUFs/resolve/main/${MODEL_TEXT}"
URL_VAE_VIDEO="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/${VAE_VIDEO}"
URL_VAE_AUDIO="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/${VAE_AUDIO}"
URL_LORA_TURBO="https://huggingface.co/drbaph/MiniMax-H3-Turbo-Lora-ComfyUI/resolve/main/${LORA_TURBO}"
URL_PINKCHERRY="https://huggingface.co/SexGod1979/PinkCherry_MiniMax-H3/resolve/main/alpha-0.5-testing/${PINKCHERRY}"

MIN_MAIN=18000000000
MIN_TEXT=13000000000
MIN_VAE_VIDEO=5000000000
MIN_VAE_AUDIO=500000000
MIN_LORA=500000000
MIN_PINKCHERRY=20000000000

green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[0;33m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
blue(){ printf '\033[0;34m%s\033[0m\n' "$*"; }
die(){ red "[ERROR] $*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

# Detect ComfyUI
COMFY_DIR=""
for d in "$WORKSPACE/runpod-slim/ComfyUI" "$WORKSPACE/ComfyUI"; do
  [[ -f "$d/main.py" ]] && COMFY_DIR="$d" && break
done
if [[ -z "$COMFY_DIR" ]]; then
  COMFY_DIR="$(find "$WORKSPACE" -maxdepth 4 -type f -path '*/ComfyUI/main.py' 2>/dev/null | head -n1 | xargs -r dirname || true)"
fi
[[ -n "$COMFY_DIR" ]] || die "ComfyUI not found under $WORKSPACE"

BASE_DIR="$(dirname "$COMFY_DIR")"
TOOLKIT_DIR="$BASE_DIR/runpod-ai-toolkit"
CACHE_DIR="$WORKSPACE/model-cache/minimax-h3"
SETUP_LOG="$TOOLKIT_DIR/setup-v4.log"
COMFY_LOG="$BASE_DIR/comfyui.log"
PID_FILE="$TOOLKIT_DIR/comfyui.pid"
CUSTOM_DIR="$COMFY_DIR/custom_nodes"
MODELS_DIR="$COMFY_DIR/models"
WORKFLOW_DIR="$COMFY_DIR/user/default/workflows"

mkdir -p "$TOOLKIT_DIR" "$CACHE_DIR" "$WORKFLOW_DIR" \
  "$MODELS_DIR/diffusion_models" "$MODELS_DIR/text_encoders" \
  "$MODELS_DIR/vae" "$MODELS_DIR/loras"

exec > >(tee -a "$SETUP_LOG") 2>&1
trap 'c=$?; red "[FAILED] line $LINENO: $BASH_COMMAND"; red "Log: $SETUP_LOG"; exit $c' ERR

echo
blue "============================================================"
blue " RunPod AI Toolkit v${VERSION}"
blue " MiniMax H3 + Turbo + PinkCherry"
blue "============================================================"
echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"
echo

file_ok() {
  local f="$1" min="$2"
  [[ -f "$f" ]] || return 1
  local s
  s="$(stat -c%s "$f" 2>/dev/null || echo 0)"
  (( s >= min ))
}

ensure_tools() {
  local pkgs=()
  have git || pkgs+=(git)
  have curl || pkgs+=(curl)
  have wget || pkgs+=(wget)
  have aria2c || pkgs+=(aria2)
  if ((${#pkgs[@]})); then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" >/dev/null
  fi
}

safe_git_update() {
  local dir="$1"
  [[ -d "$dir/.git" ]] || return 0
  (
    cd "$dir"
    [[ -n "$(git status --porcelain)" ]] && return 0
    git fetch origin -q || return 0
    local b
    b="$(git symbolic-ref --short -q HEAD || true)"
    [[ -n "$b" ]] && git pull --ff-only -q origin "$b" || true
  )
}

ensure_node() {
  local name="$1" repo="$2" dir="$CUSTOM_DIR/$1"
  if [[ -d "$dir" ]]; then
    echo "  [OK] $name"
    safe_git_update "$dir"
  else
    echo "  [INSTALL] $name"
    git clone -q "$repo" "$dir"
  fi
  [[ -f "$dir/requirements.txt" ]] && "$PYTHON_BIN" -m pip install -q -r "$dir/requirements.txt" || true
}

# Downloader with cache + aria2->wget fallback.
fetch() {
  local url="$1" dest="$2" min="$3" label="$4"
  local cache="$CACHE_DIR/$(basename "$dest")"

  if file_ok "$dest" "$min"; then
    echo "  [SKIP] $label"
    return 0
  fi

  if file_ok "$cache" "$min"; then
    echo "  [CACHE] $label"
    ln -f "$cache" "$dest" 2>/dev/null || cp -f "$cache" "$dest"
    return 0
  fi

  rm -f "$dest" "$dest.aria2"
  echo "  [DOWNLOAD] $label"

  local ok=0
  if have aria2c; then
    set +e
    aria2c \
      --continue=true \
      --max-connection-per-server="$DOWNLOAD_CONNECTIONS" \
      --split="$DOWNLOAD_CONNECTIONS" \
      --min-split-size=16M \
      --file-allocation=none \
      --auto-file-renaming=false \
      --allow-overwrite=true \
      --max-tries=3 \
      --retry-wait=2 \
      --summary-interval=10 \
      --console-log-level=warn \
      --dir="$(dirname "$dest")" \
      --out="$(basename "$dest")" "$url"
    rc=$?
    set -e
    [[ $rc -eq 0 ]] && file_ok "$dest" "$min" && ok=1
  fi

  if [[ $ok -ne 1 ]]; then
    yellow "  aria2 incomplete/failed → wget fallback: $label"
    rm -f "$dest.aria2"
    wget -c -O "$dest" "$url"
  fi

  file_ok "$dest" "$min" || die "$label download incomplete"
  cp -f "$dest" "$cache" 2>/dev/null || true
  echo "  [DONE] $label"
}

echo "[1/12] Hardware"
if have nvidia-smi; then
  GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
  GPU_MEM="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader | head -1)"
  green "  ✓ $GPU_NAME ($GPU_MEM)"
else
  yellow "  nvidia-smi unavailable"
fi
echo "  Disk:"
df -h "$WORKSPACE" | tail -1

echo "[2/12] System tools"
ensure_tools
green "  ✓ aria2/curl/wget/git ready"

echo "[3/12] ComfyUI update"
safe_git_update "$COMFY_DIR"
green "  ✓ $COMFY_DIR"

echo "[4/12] Python requirements"
"$PYTHON_BIN" -m pip install -q -r "$COMFY_DIR/requirements.txt"
green "  ✓"

echo "[5/12] Custom Nodes"
ensure_node "ComfyUI-GGUF" "https://github.com/city96/ComfyUI-GGUF.git"
ensure_node "ComfyUI-KJNodes" "https://github.com/kijai/ComfyUI-KJNodes.git"
ensure_node "ComfyUI-Easy-Use" "https://github.com/yolain/ComfyUI-Easy-Use.git"
"$PYTHON_BIN" -m pip install -q --upgrade gguf || true
green "  ✓"

echo "[6/12] Core MiniMax H3 files (parallel)"
fetch "$URL_MAIN" "$MODELS_DIR/diffusion_models/$MODEL_MAIN" "$MIN_MAIN" "$MODEL_MAIN" & P1=$!
fetch "$URL_TEXT" "$MODELS_DIR/text_encoders/$MODEL_TEXT" "$MIN_TEXT" "$MODEL_TEXT" & P2=$!
fetch "$URL_VAE_VIDEO" "$MODELS_DIR/vae/$VAE_VIDEO" "$MIN_VAE_VIDEO" "$VAE_VIDEO" & P3=$!
fetch "$URL_VAE_AUDIO" "$MODELS_DIR/vae/$VAE_AUDIO" "$MIN_VAE_AUDIO" "$VAE_AUDIO" & P4=$!
wait "$P1"; wait "$P2"; wait "$P3"; wait "$P4"
green "  ✓ core files ready"

echo "[7/12] Turbo LoRA"
fetch "$URL_LORA_TURBO" "$MODELS_DIR/loras/$LORA_TURBO" "$MIN_LORA" "$LORA_TURBO"
green "  ✓"

echo "[8/12] PinkCherry"
if [[ "$INSTALL_PINKCHERRY" == "1" ]]; then
  # Native safetensors diffusion model belongs in diffusion_models.
  fetch "$URL_PINKCHERRY" "$MODELS_DIR/diffusion_models/$PINKCHERRY" "$MIN_PINKCHERRY" "$PINKCHERRY"
  green "  ✓ PinkCherry v0.5 alpha pruned INT8"
else
  yellow "  skipped (INSTALL_PINKCHERRY=0)"
fi

echo "[9/12] Workflows"
if [[ "$INSTALL_WORKFLOWS" == "1" ]]; then
  for f in \
    MiniMax_H3_Turbo_8step_workflow.json \
    MiniMax_H3_Turbo_5shot_CONTINUOUS_30s_workflow.json \
    PinkCherry_H3_v0.5_CONTINUOUS_5shot_30s_workflow.json
  do
    url="$TOOLKIT_REPO_RAW/workflows/$f"
    if curl -fsSL "$url" -o "$WORKFLOW_DIR/$f.tmp"; then
      mv "$WORKFLOW_DIR/$f.tmp" "$WORKFLOW_DIR/$f"
      echo "  ✓ $f"
    else
      rm -f "$WORKFLOW_DIR/$f.tmp"
      yellow "  workflow not yet present in GitHub: $f"
    fi
  done
fi

echo "[10/12] Self diagnosis"
"$PYTHON_BIN" - <<PY
import torch
print("  Python/Torch:", torch.__version__)
print("  CUDA available:", torch.cuda.is_available())
print("  Torch CUDA:", torch.version.cuda)
if torch.cuda.is_available():
    print("  GPU:", torch.cuda.get_device_name(0))
PY

for spec in \
"$MODELS_DIR/diffusion_models/$MODEL_MAIN:$MIN_MAIN:Main GGUF" \
"$MODELS_DIR/text_encoders/$MODEL_TEXT:$MIN_TEXT:Text encoder" \
"$MODELS_DIR/vae/$VAE_VIDEO:$MIN_VAE_VIDEO:Video VAE" \
"$MODELS_DIR/vae/$VAE_AUDIO:$MIN_VAE_AUDIO:Audio VAE" \
"$MODELS_DIR/loras/$LORA_TURBO:$MIN_LORA:Turbo LoRA"
do
  IFS=: read -r f m label <<<"$spec"
  file_ok "$f" "$m" || die "$label missing/broken"
  echo "  ✓ $label"
done
if [[ "$INSTALL_PINKCHERRY" == "1" ]]; then
  file_ok "$MODELS_DIR/diffusion_models/$PINKCHERRY" "$MIN_PINKCHERRY" || die "PinkCherry missing/broken"
  echo "  ✓ PinkCherry"
fi

echo "[11/12] Restart ComfyUI"
if [[ -f "$PID_FILE" ]]; then
  op="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ "$op" =~ ^[0-9]+$ ]] && kill -0 "$op" 2>/dev/null && kill "$op" || true
fi
pkill -f "python.*main.py.*--port[ =]${PORT}" 2>/dev/null || true
sleep 3
cd "$COMFY_DIR"
nohup "$PYTHON_BIN" main.py \
 --listen 0.0.0.0 --port "$PORT" --preview-method auto --enable-cors-header \
 >"$COMFY_LOG" 2>&1 &
PID=$!
echo "$PID" > "$PID_FILE"

ready=0
for ((i=1;i<=STARTUP_TIMEOUT;i++)); do
  kill -0 "$PID" 2>/dev/null || { tail -100 "$COMFY_LOG"; die "ComfyUI exited"; }
  if curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
[[ $ready -eq 1 ]] || { tail -100 "$COMFY_LOG"; die "ComfyUI startup timeout"; }
green "  ✓ ComfyUI ready"

echo "[12/12] Final status"
echo
blue "============================================================"
green " RunPod AI Toolkit v4.0 READY"
blue "============================================================"
echo "ComfyUI : $COMFY_DIR"
echo "Port    : $PORT"
echo "Log     : $SETUP_LOG"
echo "Cache   : $CACHE_DIR"
echo
echo "Installed:"
echo "  ✓ MiniMax H3 Q4 GGUF"
echo "  ✓ Qwen3VL H3 Q4"
echo "  ✓ Video + Audio VAE"
echo "  ✓ Turbo LoRA"
[[ "$INSTALL_PINKCHERRY" == "1" ]] && echo "  ✓ PinkCherry H3 v0.5 alpha pruned INT8"
echo
echo "Turbo defaults: 8 steps / Euler / Beta / LoRA 1.0"
echo "PinkCherry defaults: standard H3 sampling; Turbo stacking intentionally disabled until verified."
echo
echo "Safe to re-run. Existing complete files are skipped; cache is reused."
echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
