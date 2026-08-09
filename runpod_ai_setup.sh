#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# RunPod AI Toolkit
# Profile : MiniMax H3 (GGUF + Turbo LoRA)
# Version : 2.1
# ============================================================

VERSION="2.1"
PROFILE="${PROFILE:-minimax-h3}"
WORKSPACE="${WORKSPACE:-/workspace}"
PORT="${PORT:-8188}"
PYTHON_BIN="${PYTHON_BIN:-python3.12}"
DOWNLOAD_CONNECTIONS="${DOWNLOAD_CONNECTIONS:-16}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-180}"

MODEL_MAIN="MiniMax-H3-FL2VA-Q4_K_M.gguf"
MODEL_TEXT="qwen3vl-32B-MiniMax-H3-Q4_K_M.gguf"
VAE_VIDEO="minimax_h3_video_vae_fp16.safetensors"
VAE_AUDIO="minimax_h3_audio_vae_fp32.safetensors"
LORA_TURBO="minimax_h3_turbo_v4_step600_ema_pruned_comfyui.safetensors"

URL_MAIN="https://huggingface.co/realrebelai/MiniMax-H3_GGUFs/resolve/main/${MODEL_MAIN}"
URL_TEXT="https://huggingface.co/realrebelai/MiniMax-H3_GGUFs/resolve/main/${MODEL_TEXT}"
URL_VAE_VIDEO="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/${VAE_VIDEO}"
URL_VAE_AUDIO="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/${VAE_AUDIO}"
URL_LORA_TURBO="https://huggingface.co/drbaph/MiniMax-H3-Turbo-Lora-ComfyUI/resolve/main/${LORA_TURBO}"

MIN_MAIN=18000000000
MIN_TEXT=13000000000
MIN_VAE_VIDEO=5000000000
MIN_VAE_AUDIO=500000000
MIN_LORA=500000000

NODE_GGUF_NAME="ComfyUI-GGUF"
NODE_GGUF_REPO="https://github.com/city96/ComfyUI-GGUF.git"
NODE_KJ_NAME="ComfyUI-KJNodes"
NODE_KJ_REPO="https://github.com/kijai/ComfyUI-KJNodes.git"
NODE_EASY_NAME="ComfyUI-Easy-Use"
NODE_EASY_REPO="https://github.com/yolain/ComfyUI-Easy-Use.git"

green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[0;33m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
blue(){ printf '\033[0;34m%s\033[0m\n' "$*"; }
die(){ red "[ERROR] $*"; exit 1; }

[[ "$PROFILE" == "minimax-h3" ]] || die "v${VERSION} currently supports PROFILE=minimax-h3 only."

COMFY_DIR=""
for d in "$WORKSPACE/runpod-slim/ComfyUI" "$WORKSPACE/ComfyUI"; do
  if [[ -f "$d/main.py" ]]; then
    COMFY_DIR="$d"
    break
  fi
done

if [[ -z "$COMFY_DIR" ]]; then
  COMFY_DIR="$(find "$WORKSPACE" -maxdepth 4 -type f -path '*/ComfyUI/main.py' 2>/dev/null | head -n1 | xargs -r dirname || true)"
fi

[[ -n "$COMFY_DIR" && -f "$COMFY_DIR/main.py" ]] || die "ComfyUI was not found under $WORKSPACE."

BASE_DIR="$(dirname "$COMFY_DIR")"
TOOLKIT_DIR="$BASE_DIR/runpod-ai-toolkit"
SETUP_LOG="$TOOLKIT_DIR/setup.log"
COMFY_LOG="$BASE_DIR/comfyui.log"
PID_FILE="$TOOLKIT_DIR/comfyui.pid"

mkdir -p "$TOOLKIT_DIR"
exec > >(tee -a "$SETUP_LOG") 2>&1
trap 'code=$?; red "[FAILED] line $LINENO: $BASH_COMMAND"; red "See log: $SETUP_LOG"; exit $code' ERR

echo
blue "============================================================"
blue " RunPod AI Toolkit v${VERSION}"
blue " Profile: ${PROFILE}"
blue "============================================================"
echo
echo "Started : $(date '+%Y-%m-%d %H:%M:%S')"
echo "Log     : $SETUP_LOG"
echo

have(){ command -v "$1" >/dev/null 2>&1; }

file_ok() {
  local path="$1"
  local min_bytes="$2"
  [[ -f "$path" ]] || return 1
  local size
  size="$(stat -c '%s' "$path" 2>/dev/null || echo 0)"
  (( size >= min_bytes ))
}

human_size() {
  du -h "$1" 2>/dev/null | awk '{print $1}'
}

ensure_system_tools() {
  local missing=()
  have git || missing+=("git")
  have curl || missing+=("curl")
  have wget || missing+=("wget")
  if ((${#missing[@]} > 0)); then
    have apt-get || die "Missing tools: ${missing[*]} and apt-get is unavailable."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
  fi
  if ! have aria2c && have apt-get; then
    echo "Installing aria2..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq aria2 >/dev/null
  fi
}

safe_git_update() {
  local dir="$1"
  [[ -d "$dir/.git" ]] || return 0
  (
    cd "$dir"
    if [[ -n "$(git status --porcelain)" ]]; then
      yellow "      Local changes: $(basename "$dir") → update skipped"
      return 0
    fi
    git fetch origin -q || return 0
    local branch
    branch="$(git symbolic-ref --short -q HEAD || true)"
    if [[ -z "$branch" ]]; then
      if git show-ref --verify --quiet refs/heads/master; then
        git checkout master -q
      elif git show-ref --verify --quiet refs/heads/main; then
        git checkout main -q
      fi
    fi
    branch="$(git symbolic-ref --short -q HEAD || true)"
    [[ -n "$branch" ]] && git pull --ff-only -q origin "$branch" || true
  )
}

ensure_node() {
  local name="$1"
  local repo="$2"
  local dir="$CUSTOM_DIR/$name"

  if [[ -d "$dir" ]]; then
    echo "      [OK] $name"
    safe_git_update "$dir"
  else
    echo "      [INSTALL] $name"
    git clone -q "$repo" "$dir"
  fi

  if [[ -f "$dir/requirements.txt" ]]; then
    "$PYTHON_BIN" -m pip install -q -r "$dir/requirements.txt" || \
      yellow "      requirements warning: $name"
  fi
}

download_one() {
  local url="$1"
  local dest="$2"
  local min_bytes="$3"
  local label="$4"

  mkdir -p "$(dirname "$dest")"

  if file_ok "$dest" "$min_bytes"; then
    echo "      [SKIP] $label ($(human_size "$dest"))"
    return 0
  fi

  if [[ -e "$dest" ]]; then
    yellow "      [RETRY] $label: incomplete file detected"
    rm -f "$dest"
  else
    echo "      [DOWNLOAD] $label"
  fi

  if have aria2c; then
    aria2c \
      --continue=true \
      --max-connection-per-server="$DOWNLOAD_CONNECTIONS" \
      --split="$DOWNLOAD_CONNECTIONS" \
      --min-split-size=8M \
      --file-allocation=none \
      --auto-file-renaming=false \
      --allow-overwrite=true \
      --summary-interval=10 \
      --console-log-level=warn \
      --dir="$(dirname "$dest")" \
      --out="$(basename "$dest")" \
      "$url"
  else
    wget -c -O "$dest" "$url"
  fi

  file_ok "$dest" "$min_bytes" || die "$label download appears incomplete."
  echo "      [DONE] $label ($(human_size "$dest"))"
}

wait_job() {
  local pid="$1"
  local name="$2"
  if wait "$pid"; then
    green "      ✓ $name"
  else
    die "$name download failed."
  fi
}

CUSTOM_DIR="$COMFY_DIR/custom_nodes"
MODELS_DIR="$COMFY_DIR/models"

mkdir -p \
  "$CUSTOM_DIR" \
  "$MODELS_DIR/diffusion_models" \
  "$MODELS_DIR/text_encoders" \
  "$MODELS_DIR/vae" \
  "$MODELS_DIR/loras"

printf "[1/10] GPU                 "
if have nvidia-smi; then
  GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1 || true)"
  GPU_MEM="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader | head -n1 || true)"
  green "✓ ${GPU_NAME:-NVIDIA GPU} (${GPU_MEM:-VRAM unknown})"
else
  yellow "⚠ nvidia-smi unavailable"
fi

printf "[2/10] ComfyUI             "
green "✓ $COMFY_DIR"

printf "[3/10] System tools        "
ensure_system_tools
if have aria2c; then
  green "✓ aria2 (${DOWNLOAD_CONNECTIONS} connections/file)"
else
  yellow "⚠ wget fallback"
fi

printf "[4/10] ComfyUI update      "
if [[ -d "$COMFY_DIR/.git" ]]; then
  safe_git_update "$COMFY_DIR"
  green "✓"
else
  yellow "⚠ not a git checkout; skipped"
fi

printf "[5/10] Python requirements "
"$PYTHON_BIN" -m pip install -q -r "$COMFY_DIR/requirements.txt"
green "✓"

echo "[6/10] Custom Nodes"
ensure_node "$NODE_GGUF_NAME" "$NODE_GGUF_REPO"
ensure_node "$NODE_KJ_NAME" "$NODE_KJ_REPO"
ensure_node "$NODE_EASY_NAME" "$NODE_EASY_REPO"
"$PYTHON_BIN" -m pip install -q --upgrade gguf || true
green "      ✓ Custom Nodes ready"

echo "[7/10] H3 core files - parallel download"

download_one "$URL_MAIN" \
  "$MODELS_DIR/diffusion_models/$MODEL_MAIN" \
  "$MIN_MAIN" "$MODEL_MAIN" &
P1=$!

download_one "$URL_TEXT" \
  "$MODELS_DIR/text_encoders/$MODEL_TEXT" \
  "$MIN_TEXT" "$MODEL_TEXT" &
P2=$!

download_one "$URL_VAE_VIDEO" \
  "$MODELS_DIR/vae/$VAE_VIDEO" \
  "$MIN_VAE_VIDEO" "$VAE_VIDEO" &
P3=$!

download_one "$URL_VAE_AUDIO" \
  "$MODELS_DIR/vae/$VAE_AUDIO" \
  "$MIN_VAE_AUDIO" "$VAE_AUDIO" &
P4=$!

wait_job "$P1" "$MODEL_MAIN"
wait_job "$P2" "$MODEL_TEXT"
wait_job "$P3" "$VAE_VIDEO"
wait_job "$P4" "$VAE_AUDIO"

echo "[8/10] Turbo LoRA"
download_one "$URL_LORA_TURBO" \
  "$MODELS_DIR/loras/$LORA_TURBO" \
  "$MIN_LORA" "$LORA_TURBO"
green "      ✓ Turbo LoRA ready"

echo "[9/10] Environment verification"

declare -a VERIFY_ITEMS=(
  "$MODELS_DIR/diffusion_models/$MODEL_MAIN|$MIN_MAIN|Main GGUF"
  "$MODELS_DIR/text_encoders/$MODEL_TEXT|$MIN_TEXT|Text encoder"
  "$MODELS_DIR/vae/$VAE_VIDEO|$MIN_VAE_VIDEO|Video VAE"
  "$MODELS_DIR/vae/$VAE_AUDIO|$MIN_VAE_AUDIO|Audio VAE"
  "$MODELS_DIR/loras/$LORA_TURBO|$MIN_LORA|Turbo LoRA"
)

for item in "${VERIFY_ITEMS[@]}"; do
  IFS='|' read -r path min label <<< "$item"
  if file_ok "$path" "$min"; then
    echo "      ✓ $label: $(basename "$path") ($(human_size "$path"))"
  else
    die "$label verification failed: $path"
  fi
done

for node in "$NODE_GGUF_NAME" "$NODE_KJ_NAME" "$NODE_EASY_NAME"; do
  [[ -d "$CUSTOM_DIR/$node" ]] || die "Custom node missing: $node"
done
green "      ✓ environment verified"

echo "[10/10] Restarting ComfyUI"

if [[ -f "$PID_FILE" ]]; then
  OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ "$OLD_PID" =~ ^[0-9]+$ ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    kill "$OLD_PID" || true
    sleep 2
  fi
fi

PIDS="$(pgrep -f "python.*main.py.*(--port[ =])?${PORT}" || true)"
if [[ -n "$PIDS" ]]; then
  echo "      stopping existing PID(s): $PIDS"
  kill $PIDS || true
  sleep 3
fi

cd "$COMFY_DIR"
nohup "$PYTHON_BIN" main.py \
  --listen 0.0.0.0 \
  --port "$PORT" \
  --preview-method auto \
  --enable-cors-header \
  > "$COMFY_LOG" 2>&1 &

COMFY_PID=$!
echo "$COMFY_PID" > "$PID_FILE"

READY=0
for ((i=1; i<=STARTUP_TIMEOUT; i++)); do
  if ! kill -0 "$COMFY_PID" 2>/dev/null; then
    red "ComfyUI exited during startup."
    tail -100 "$COMFY_LOG" || true
    exit 1
  fi

  if curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 1
done

if (( READY == 0 )); then
  red "ComfyUI did not become ready within ${STARTUP_TIMEOUT}s."
  tail -100 "$COMFY_LOG" || true
  exit 1
fi

green "      ✓ ComfyUI ready on port $PORT"

echo
blue "============================================================"
green " MiniMax H3 READY"
blue " RunPod AI Toolkit v${VERSION}"
blue "============================================================"
echo
echo "GPU       : ${GPU_NAME:-unknown}"
echo "ComfyUI   : $COMFY_DIR"
echo "Port      : $PORT"
echo "Setup log : $SETUP_LOG"
echo "Comfy log : $COMFY_LOG"
echo
echo "Turbo starting settings:"
echo "  LoRA      : $LORA_TURBO"
echo "  Strength  : 1.0"
echo "  Steps     : 8"
echo "  Sampler   : Euler"
echo "  Scheduler : Beta"
echo
echo "Workflow VAE settings:"
echo "  Video VAE : $VAE_VIDEO"
echo "  Audio VAE : $VAE_AUDIO"
echo
echo "Safe to re-run: complete existing model files are skipped."
echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
