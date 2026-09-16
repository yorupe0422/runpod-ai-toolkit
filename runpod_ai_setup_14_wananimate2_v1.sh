#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# RunPod / ComfyUI Setup #14 - Wan-Animate-2
# - Port 8188 fixed
# - Fresh isolated environment
# - Default preset: fast validation on RTX 5090
# ============================================================

BASE_DIR="/workspace/runpod-slim"
APP_DIR="$BASE_DIR/ComfyUI-WanAnimate2"
COMFY_DIR="$APP_DIR/ComfyUI"
VENV_DIR="$APP_DIR/venv"
PORT="8188"
PYTHON_BIN="${PYTHON_BIN:-python3}"
WAN_PRESET="${WAN_PRESET:-distill-int8}"   # distill-int8 | distill-bf16 | quality-int8 | quality-bf16
INSTALL_MANAGER="${INSTALL_MANAGER:-1}"
INSTALL_VHS="${INSTALL_VHS:-1}"
HF_HOME="${HF_HOME:-/workspace/hf}"
HF_HUB_ENABLE_HF_TRANSFER="1"
HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-$HF_HOME/hub}"
COMFYUI_REPO="https://github.com/comfyanonymous/ComfyUI.git"

log()  { echo -e "\n[INFO] $*\n"; }
warn() { echo -e "\n[WARN] $*\n"; }
die()  { echo -e "\n[ERR ] $*\n"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

kill_port_8188() {
  if command -v lsof >/dev/null 2>&1; then
    local pids
    pids="$(lsof -ti tcp:$PORT || true)"
    if [[ -n "$pids" ]]; then
      warn "Killing processes on port $PORT: $pids"
      kill -9 $pids || true
    fi
  fi
}

clone_or_update() {
  local repo_url="$1"
  local dst="$2"
  if [[ -d "$dst/.git" ]]; then
    git -C "$dst" fetch --all --tags
    git -C "$dst" pull --ff-only || true
  else
    git clone "$repo_url" "$dst"
  fi
}

pip_install() {
  "$VENV_DIR/bin/python" -m pip install --upgrade "$@"
}

hf_get() {
  local src="$1"
  local dst_dir="$2"
  mkdir -p "$dst_dir"
  "$VENV_DIR/bin/hf" download Comfy-Org/Wan-Animate-2 "$src" --local-dir "$dst_dir" --local-dir-use-symlinks False
}

symlink_if_exists() {
  local src="$1"
  local dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [[ -f "$src" ]]; then
    ln -sfn "$src" "$dst"
  else
    die "Expected file not found: $src"
  fi
}

log "APT packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y git git-lfs wget curl aria2 ffmpeg jq rsync unzip libgl1 libglib2.0-0 python3-venv python3-pip lsof

git lfs install || true
mkdir -p "$BASE_DIR" "$APP_DIR" "$HF_HOME" "$HUGGINGFACE_HUB_CACHE"
kill_port_8188

log "Clone / update ComfyUI"
clone_or_update "$COMFYUI_REPO" "$COMFY_DIR"

log "Create venv"
$PYTHON_BIN -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --upgrade pip setuptools wheel

log "Install PyTorch"
# Prefer CUDA 12.8 wheels for modern RunPod GPUs; fallback to default index if needed.
pip install --upgrade torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128 || \
  pip install --upgrade torch torchvision torchaudio

log "Install ComfyUI requirements"
pip install --upgrade -r "$COMFY_DIR/requirements.txt"
pip install --upgrade huggingface_hub[cli] hf_transfer safetensors sentencepiece protobuf ninja psutil imageio-ffmpeg

if [[ "$INSTALL_MANAGER" == "1" ]]; then
  log "Install ComfyUI-Manager"
  clone_or_update "https://github.com/ltdrdata/ComfyUI-Manager.git" "$COMFY_DIR/custom_nodes/ComfyUI-Manager"
  if [[ -f "$COMFY_DIR/custom_nodes/ComfyUI-Manager/requirements.txt" ]]; then
    pip install --upgrade -r "$COMFY_DIR/custom_nodes/ComfyUI-Manager/requirements.txt" || true
  fi
fi

if [[ "$INSTALL_VHS" == "1" ]]; then
  log "Install VideoHelperSuite"
  clone_or_update "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git" "$COMFY_DIR/custom_nodes/ComfyUI-VideoHelperSuite"
  if [[ -f "$COMFY_DIR/custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt" ]]; then
    pip install --upgrade -r "$COMFY_DIR/custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt" || true
  fi
fi

log "Create model folders"
mkdir -p \
  "$COMFY_DIR/models/checkpoints" \
  "$COMFY_DIR/models/clip_vision" \
  "$COMFY_DIR/models/diffusion_models" \
  "$COMFY_DIR/models/loras" \
  "$COMFY_DIR/models/text_encoders" \
  "$COMFY_DIR/models/vae" \
  "$COMFY_DIR/input" \
  "$COMFY_DIR/output" \
  "$APP_DIR/models-cache/Wan-Animate-2"

log "Select Wan-Animate-2 preset: $WAN_PRESET"
DIFF_MODEL=""
TEXT_ENCODER="umt5_xxl_fp8_e4m3fn_scaled.safetensors"
CLIP_VISION="clip_vision_h.safetensors"
VAE_MODEL="Wan2_1_VAE_bf16.safetensors"
DISTILL_LORA="lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors"
USE_DISTILL_LORA="0"

case "$WAN_PRESET" in
  distill-int8)
    DIFF_MODEL="wan_animate_2_distill_int8_convrot.safetensors"
    USE_DISTILL_LORA="1"
    ;;
  distill-bf16)
    DIFF_MODEL="wan_animate_2_distill_bf16.safetensors"
    TEXT_ENCODER="umt5_xxl_fp16.safetensors"
    USE_DISTILL_LORA="1"
    ;;
  quality-int8)
    DIFF_MODEL="wan_animate_2_int8_convrot.safetensors"
    ;;
  quality-bf16)
    DIFF_MODEL="wan_animate_2_bf16.safetensors"
    TEXT_ENCODER="umt5_xxl_fp16.safetensors"
    ;;
  *)
    die "Unknown WAN_PRESET: $WAN_PRESET"
    ;;
esac

log "Download required model files from Comfy-Org/Wan-Animate-2"
export HF_HOME HUGGINGFACE_HUB_CACHE HF_HUB_ENABLE_HF_TRANSFER
hf_get "diffusion_models/$DIFF_MODEL" "$APP_DIR/models-cache/Wan-Animate-2"
hf_get "text_encoders/$TEXT_ENCODER" "$APP_DIR/models-cache/Wan-Animate-2"
hf_get "clip_vision/$CLIP_VISION" "$APP_DIR/models-cache/Wan-Animate-2"
hf_get "vae/$VAE_MODEL" "$APP_DIR/models-cache/Wan-Animate-2"
if [[ "$USE_DISTILL_LORA" == "1" ]]; then
  hf_get "loras/$DISTILL_LORA" "$APP_DIR/models-cache/Wan-Animate-2"
fi

log "Symlink models into ComfyUI"
symlink_if_exists "$APP_DIR/models-cache/Wan-Animate-2/diffusion_models/$DIFF_MODEL" "$COMFY_DIR/models/diffusion_models/$DIFF_MODEL"
symlink_if_exists "$APP_DIR/models-cache/Wan-Animate-2/text_encoders/$TEXT_ENCODER" "$COMFY_DIR/models/text_encoders/$TEXT_ENCODER"
symlink_if_exists "$APP_DIR/models-cache/Wan-Animate-2/clip_vision/$CLIP_VISION" "$COMFY_DIR/models/clip_vision/$CLIP_VISION"
symlink_if_exists "$APP_DIR/models-cache/Wan-Animate-2/vae/$VAE_MODEL" "$COMFY_DIR/models/vae/$VAE_MODEL"
if [[ "$USE_DISTILL_LORA" == "1" ]]; then
  symlink_if_exists "$APP_DIR/models-cache/Wan-Animate-2/loras/$DISTILL_LORA" "$COMFY_DIR/models/loras/$DISTILL_LORA"
fi

log "Write helper scripts"
cat > "$BASE_DIR/start_wananimate2.sh" <<EOS
#!/usr/bin/env bash
set -Eeuo pipefail
APP_DIR="$APP_DIR"
COMFY_DIR="$COMFY_DIR"
VENV_DIR="$VENV_DIR"
PORT="$PORT"
export HF_HOME="$HF_HOME"
export HUGGINGFACE_HUB_CACHE="$HUGGINGFACE_HUB_CACHE"
export HF_HUB_ENABLE_HF_TRANSFER=1
export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"
export CUDA_DEVICE_MAX_CONNECTIONS=1
export TOKENIZERS_PARALLELISM=false
if command -v lsof >/dev/null 2>&1; then
  PIDS=\$(lsof -ti tcp:\$PORT || true)
  if [[ -n "\$PIDS" ]]; then kill -9 \$PIDS || true; fi
fi
cd "\$COMFY_DIR"
source "\$VENV_DIR/bin/activate"
python main.py --listen 0.0.0.0 --port "\$PORT"
EOS
chmod +x "$BASE_DIR/start_wananimate2.sh"

cat > "$BASE_DIR/restart_wananimate2.sh" <<EOS
#!/usr/bin/env bash
set -Eeuo pipefail
pkill -f "python main.py --listen 0.0.0.0 --port $PORT" || true
exec "$BASE_DIR/start_wananimate2.sh"
EOS
chmod +x "$BASE_DIR/restart_wananimate2.sh"

cat > "$APP_DIR/README_FIRST_RUN.txt" <<'EOS'
Wan-Animate-2 first-run notes
==============================
1) Start ComfyUI:
   /workspace/runpod-slim/start_wananimate2.sh

2) Open:
   http://<RUNPOD_PUBLIC_IP>:8188

3) For the first validation test, keep it simple:
   - one 5s source video
   - one character reference image
   - replacement mode / character replacement
   - keep original background

4) Default setup is optimized for speed validation:
   WAN_PRESET=distill-int8
   diffusion model: wan_animate_2_distill_int8_convrot.safetensors
   text encoder:    umt5_xxl_fp8_e4m3fn_scaled.safetensors
   clip vision:     clip_vision_h.safetensors
   vae:             Wan2_1_VAE_bf16.safetensors
   distill lora:    lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors

5) To rebuild with a different preset, rerun the setup script with e.g.:
   WAN_PRESET=quality-bf16 bash runpod_ai_setup_14_wananimate2_v1.sh
EOS

log "Done"
echo "=============================================================="
echo "Setup complete."
echo "Environment dir : $APP_DIR"
echo "ComfyUI dir     : $COMFY_DIR"
echo "Start command   : $BASE_DIR/start_wananimate2.sh"
echo "Restart command : $BASE_DIR/restart_wananimate2.sh"
echo "Port            : $PORT"
echo "Preset          : $WAN_PRESET"
echo "=============================================================="
