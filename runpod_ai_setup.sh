#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# RunPod MiniMax H3 Auto Setup
# - Finds ComfyUI automatically under /workspace
# - Updates ComfyUI + requirements
# - Ensures required custom nodes
# - Downloads MiniMax H3 GGUF / text encoder / VAEs / Turbo LoRA
# - Restarts ComfyUI on port 8188
# ============================================================

PORT="${PORT:-8188}"
WORKSPACE="${WORKSPACE:-/workspace}"
PYTHON_BIN="${PYTHON_BIN:-python3.12}"

H3_MODEL="MiniMax-H3-FL2VA-Q4_K_M.gguf"
H3_TEXT_ENCODER="qwen3vl-32B-MiniMax-H3-Q4_K_M.gguf"
H3_VIDEO_VAE="minimax_h3_video_vae_fp16.safetensors"
H3_AUDIO_VAE="minimax_h3_audio_vae_fp32.safetensors"
H3_TURBO_LORA="minimax_h3_turbo_v4_step600_ema_pruned_comfyui.safetensors"

# URLs confirmed/used in the working setup.
H3_MODEL_URL="https://huggingface.co/realrebelai/MiniMax-H3_GGUFs/resolve/main/${H3_MODEL}"
H3_TEXT_ENCODER_URL="https://huggingface.co/realrebelai/MiniMax-H3_GGUFs/resolve/main/${H3_TEXT_ENCODER}"
H3_VIDEO_VAE_URL="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/${H3_VIDEO_VAE}"
H3_AUDIO_VAE_URL="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/${H3_AUDIO_VAE}"
H3_TURBO_LORA_URL="https://huggingface.co/drbaph/MiniMax-H3-Turbo-Lora-ComfyUI/resolve/main/${H3_TURBO_LORA}"

GGUF_REPO="https://github.com/city96/ComfyUI-GGUF.git"
KJNODES_REPO="https://github.com/kijai/ComfyUI-KJNodes.git"
EASYUSE_REPO="https://github.com/yolain/ComfyUI-Easy-Use.git"
RTX_REPO="https://github.com/Comfy-Org/Nvidia_RTX_Nodes_ComfyUI.git"

LOG_FILE="${WORKSPACE}/runpod-slim/comfyui.log"

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[0;33m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
blue()  { printf '\033[0;34m%s\033[0m\n' "$*"; }

die() {
  red "ERROR: $*"
  exit 1
}

trap 'red "FAILED at line $LINENO: $BASH_COMMAND"' ERR

echo
blue "============================================================"
blue " RunPod MiniMax H3 Auto Setup"
blue "============================================================"
echo

# ------------------------------------------------------------
# 1/10 GPU
# ------------------------------------------------------------
printf "[1/10] GPU確認            "
if command -v nvidia-smi >/dev/null 2>&1; then
  GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1 || true)"
  GPU_MEM="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader | head -n1 || true)"
  green "✓ ${GPU_NAME:-NVIDIA GPU} (${GPU_MEM:-VRAM unknown})"
else
  yellow "⚠ nvidia-smi が見つかりません"
fi

# ------------------------------------------------------------
# 2/10 Find ComfyUI
# ------------------------------------------------------------
printf "[2/10] ComfyUI確認        "
CANDIDATES=(
  "${WORKSPACE}/runpod-slim/ComfyUI"
  "${WORKSPACE}/ComfyUI"
)

COMFY_DIR=""
for d in "${CANDIDATES[@]}"; do
  if [[ -f "$d/main.py" ]]; then
    COMFY_DIR="$d"
    break
  fi
done

if [[ -z "$COMFY_DIR" ]]; then
  COMFY_DIR="$(find "$WORKSPACE" -maxdepth 4 -type f -name main.py -path '*/ComfyUI/main.py' 2>/dev/null | head -n1 | xargs -r dirname || true)"
fi

[[ -n "$COMFY_DIR" && -f "$COMFY_DIR/main.py" ]] || die "ComfyUI が /workspace 配下に見つかりません"
green "✓ $COMFY_DIR"

CUSTOM_DIR="$COMFY_DIR/custom_nodes"
MODELS_DIR="$COMFY_DIR/models"
LOG_FILE="$(dirname "$COMFY_DIR")/comfyui.log"

mkdir -p \
  "$CUSTOM_DIR" \
  "$MODELS_DIR/diffusion_models" \
  "$MODELS_DIR/text_encoders" \
  "$MODELS_DIR/vae" \
  "$MODELS_DIR/loras"

# ------------------------------------------------------------
# 3/10 ComfyUI update
# ------------------------------------------------------------
printf "[3/10] ComfyUI更新        "
cd "$COMFY_DIR"

if [[ -d .git ]]; then
  git fetch origin >/dev/null 2>&1 || true

  CURRENT_BRANCH="$(git symbolic-ref --short -q HEAD || true)"
  if [[ -z "$CURRENT_BRANCH" ]]; then
    yellow ""
    yellow "      Detached HEAD を検出 → master へ復帰します"
    git checkout master
  elif [[ "$CURRENT_BRANCH" != "master" ]]; then
    yellow ""
    yellow "      現在のbranch: $CURRENT_BRANCH"
    yellow "      master に切替えます"
    git checkout master
  fi

  # Do not destroy local modifications.
  if [[ -n "$(git status --porcelain)" ]]; then
    yellow ""
    yellow "      ローカル変更を検出。git pull はスキップします。"
    yellow "      必要なら変更を退避/commitしてから再実行してください。"
  else
    git pull --ff-only origin master
  fi
  green "✓"
else
  yellow "⚠ Git管理ではないため更新をスキップ"
fi

# ------------------------------------------------------------
# 4/10 requirements
# ------------------------------------------------------------
printf "[4/10] requirements       "
"$PYTHON_BIN" -m pip install -r "$COMFY_DIR/requirements.txt" -q
green "✓"

# ------------------------------------------------------------
# Helper: install/update custom node
# ------------------------------------------------------------
ensure_node() {
  local dirname="$1"
  local repo="$2"
  local path="$CUSTOM_DIR/$dirname"

  if [[ -d "$path/.git" ]]; then
    (
      cd "$path"
      if [[ -z "$(git status --porcelain)" ]]; then
        git pull --ff-only -q || true
      else
        yellow "      $dirname: local変更あり → update skip"
      fi
    )
  elif [[ -d "$path" ]]; then
    yellow "      $dirname: 既存folderを使用"
  else
    git clone -q "$repo" "$path"
  fi

  # Install node-specific requirements when present.
  if [[ -f "$path/requirements.txt" ]]; then
    "$PYTHON_BIN" -m pip install -r "$path/requirements.txt" -q || \
      yellow "      $dirname requirements の一部で警告/失敗。起動時ログを確認してください。"
  fi
}

# ------------------------------------------------------------
# 5/10 Custom nodes
# ------------------------------------------------------------
printf "[5/10] Custom Nodes       "
ensure_node "ComfyUI-GGUF" "$GGUF_REPO"
ensure_node "ComfyUI-KJNodes" "$KJNODES_REPO"
ensure_node "ComfyUI-Easy-Use" "$EASYUSE_REPO"
ensure_node "Nvidia_RTX_Nodes_ComfyUI" "$RTX_REPO"
green "✓"

# ------------------------------------------------------------
# Helper: download if missing
# ------------------------------------------------------------
download_if_missing() {
  local url="$1"
  local dest="$2"
  local label="$3"

  if [[ -s "$dest" ]]; then
    local size
    size="$(du -h "$dest" | awk '{print $1}')"
    green "      ✓ $label already exists ($size)"
    return 0
  fi

  yellow "      ↓ $label"
  if command -v wget >/dev/null 2>&1; then
    wget -c --progress=bar:force:noscroll -O "$dest" "$url"
  elif command -v curl >/dev/null 2>&1; then
    curl -fL --retry 5 --retry-delay 3 -C - -o "$dest" "$url"
  else
    die "wget/curl がありません"
  fi

  [[ -s "$dest" ]] || die "$label のダウンロードに失敗しました"
}

# ------------------------------------------------------------
# 6/10 H3 model
# ------------------------------------------------------------
printf "[6/10] H3 model           "
if [[ -s "$MODELS_DIR/diffusion_models/$H3_MODEL" ]]; then
  green "✓"
else
  echo
  download_if_missing \
    "$H3_MODEL_URL" \
    "$MODELS_DIR/diffusion_models/$H3_MODEL" \
    "$H3_MODEL"
fi

# ------------------------------------------------------------
# 7/10 Text encoder
# ------------------------------------------------------------
printf "[7/10] Text encoder       "
if [[ -s "$MODELS_DIR/text_encoders/$H3_TEXT_ENCODER" ]]; then
  green "✓"
else
  echo
  download_if_missing \
    "$H3_TEXT_ENCODER_URL" \
    "$MODELS_DIR/text_encoders/$H3_TEXT_ENCODER" \
    "$H3_TEXT_ENCODER"
fi

# ------------------------------------------------------------
# 8/10 VAEs
# ------------------------------------------------------------
printf "[8/10] VAE                "
if [[ -s "$MODELS_DIR/vae/$H3_VIDEO_VAE" && -s "$MODELS_DIR/vae/$H3_AUDIO_VAE" ]]; then
  green "✓"
else
  echo
  download_if_missing \
    "$H3_VIDEO_VAE_URL" \
    "$MODELS_DIR/vae/$H3_VIDEO_VAE" \
    "$H3_VIDEO_VAE"

  download_if_missing \
    "$H3_AUDIO_VAE_URL" \
    "$MODELS_DIR/vae/$H3_AUDIO_VAE" \
    "$H3_AUDIO_VAE"
fi

# ------------------------------------------------------------
# 9/10 Turbo LoRA
# ------------------------------------------------------------
printf "[9/10] Turbo LoRA         "
if [[ -s "$MODELS_DIR/loras/$H3_TURBO_LORA" ]]; then
  green "✓"
else
  echo
  download_if_missing \
    "$H3_TURBO_LORA_URL" \
    "$MODELS_DIR/loras/$H3_TURBO_LORA" \
    "$H3_TURBO_LORA"
fi

# ------------------------------------------------------------
# 10/10 Restart ComfyUI
# ------------------------------------------------------------
printf "[10/10] ComfyUI起動       "

# Stop ComfyUI processes whose command points to this install.
PIDS="$(pgrep -f "python.*main.py.*--port[ =]${PORT}" || true)"
if [[ -n "$PIDS" ]]; then
  yellow ""
  yellow "      既存ComfyUIを停止: $PIDS"
  kill $PIDS || true
  sleep 3
fi

cd "$COMFY_DIR"
nohup "$PYTHON_BIN" main.py \
  --listen 0.0.0.0 \
  --port "$PORT" \
  --preview-method auto \
  --enable-cors-header \
  > "$LOG_FILE" 2>&1 &

COMFY_PID=$!
echo "$COMFY_PID" > "$(dirname "$COMFY_DIR")/comfyui.pid"

# Wait up to 120 sec for HTTP port.
READY=0
for _ in $(seq 1 120); do
  if ! kill -0 "$COMFY_PID" 2>/dev/null; then
    echo
    red "ComfyUI process exited during startup."
    tail -80 "$LOG_FILE" || true
    exit 1
  fi

  if command -v curl >/dev/null 2>&1; then
    if curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
      READY=1
      break
    fi
  else
    if "$PYTHON_BIN" - <<PY >/dev/null 2>&1
import socket
s=socket.socket()
s.settimeout(1)
s.connect(("127.0.0.1", ${PORT}))
s.close()
PY
    then
      READY=1
      break
    fi
  fi
  sleep 1
done

if [[ "$READY" -eq 1 ]]; then
  green "✓ Port ${PORT} available"
else
  echo
  red "ComfyUIが120秒以内に応答しませんでした。"
  tail -100 "$LOG_FILE" || true
  exit 1
fi

echo
blue "============================================================"
green " MiniMax H3 READY"
blue "============================================================"
echo
echo "ComfyUI : $COMFY_DIR"
echo "Port    : $PORT"
echo "Log     : $LOG_FILE"
echo
echo "Models:"
echo "  ✓ $H3_MODEL"
echo "  ✓ $H3_TEXT_ENCODER"
echo "  ✓ $H3_VIDEO_VAE"
echo "  ✓ $H3_AUDIO_VAE"
echo "  ✓ $H3_TURBO_LORA"
echo
echo "Turbo LoRA recommended starting point:"
echo "  steps     : 8"
echo "  sampler   : Euler"
echo "  scheduler : Beta"
echo
yellow "NOTE:"
echo "  Workflow側では Video VAE / Audio VAE が pixel_space ではなく"
echo "  MiniMax H3用VAEになっていることを確認してください。"
echo
