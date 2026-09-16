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
HF_XET_HIGH_PERFORMANCE="1"
HF_HUB_CACHE="${HF_HUB_CACHE:-$HF_HOME/hub}"
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
  "$VENV_DIR/bin/hf" download Comfy-Org/Wan-Animate-2 "$src" --local-dir "$dst_dir"
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

log "Preflight: require CUDA 13.x-capable RunPod host"
need_cmd nvidia-smi

NVIDIA_SMI_OUT="$(nvidia-smi)"
echo "$NVIDIA_SMI_OUT"

HOST_CUDA_VERSION="$(printf '%s\n' "$NVIDIA_SMI_OUT" | sed -n 's/.*CUDA Version: \([0-9][0-9.]*\).*/\1/p' | head -n1)"
[[ -n "$HOST_CUDA_VERSION" ]] || die "Could not detect CUDA Version from nvidia-smi."

HOST_CUDA_MAJOR="${HOST_CUDA_VERSION%%.*}"
if (( HOST_CUDA_MAJOR < 13 )); then
  die "This #14 v4 setup requires a RunPod host reporting CUDA 13.x or newer. Detected: $HOST_CUDA_VERSION. Recreate the Pod with a CUDA 13.x-capable image/host before continuing."
fi

log "Preflight OK: host reports CUDA $HOST_CUDA_VERSION"

log "APT packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y git git-lfs wget curl aria2 ffmpeg jq rsync unzip libgl1 libglib2.0-0 python3-venv python3-pip lsof

git lfs install || true
mkdir -p "$BASE_DIR" "$APP_DIR" "$HF_HOME" "$HF_HUB_CACHE"
kill_port_8188

log "Clone / update ComfyUI"
clone_or_update "$COMFYUI_REPO" "$COMFY_DIR"

log "Create venv"
$PYTHON_BIN -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --upgrade pip setuptools wheel

log "Install PyTorch 2.14.0 + CUDA 13.0"
pip uninstall -y torch torchvision torchaudio >/dev/null 2>&1 || true
pip install --no-cache-dir \
  torch==2.14.0 torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/cu130

log "Install ComfyUI requirements"
pip install --upgrade -r "$COMFY_DIR/requirements.txt"
pip install --upgrade huggingface_hub[cli] hf-xet safetensors sentencepiece protobuf ninja psutil imageio-ffmpeg

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
export HF_HOME HF_HUB_CACHE HF_XET_HIGH_PERFORMANCE
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
export HF_HUB_CACHE="$HF_HUB_CACHE"
export HF_XET_HIGH_PERFORMANCE=1
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
   WAN_PRESET=quality-bf16 bash runpod_ai_setup_14_wananimate2_v4.sh
EOS

log "Validate RTX 5090 / CUDA 13 / PyTorch kernels with real GPU compute"
nvidia-smi

"$VENV_DIR/bin/python" - <<'PY'
import sys
import torch

print("PyTorch          :", torch.__version__)
print("Torch CUDA build :", torch.version.cuda)
print("CUDA available   :", torch.cuda.is_available())

if not torch.cuda.is_available():
    raise SystemExit("[ERROR] PyTorch cannot initialize CUDA.")

gpu = torch.cuda.get_device_name(0)
cc = torch.cuda.get_device_capability(0)
arches = torch.cuda.get_arch_list()

print("GPU              :", gpu)
print("Compute capability:", f"{cc[0]}.{cc[1]}")
print("Torch arch list  :", " ".join(arches))
print("VRAM GiB         :", round(torch.cuda.get_device_properties(0).total_memory / 1024**3, 2))

if "RTX 5090" in gpu and cc != (12, 0):
    raise SystemExit(f"[ERROR] Unexpected RTX 5090 compute capability: {cc}")

if cc == (12, 0) and "sm_120" not in arches:
    raise SystemExit("[ERROR] Installed PyTorch does not contain sm_120 kernels for RTX 5090.")

# Real CUDA kernel execution. cuda.is_available() alone is not enough.
a = torch.randn((2048, 2048), device="cuda", dtype=torch.float16)
b = torch.randn((2048, 2048), device="cuda", dtype=torch.float16)
c = a @ b
torch.cuda.synchronize()

if not torch.isfinite(c).all().item():
    raise SystemExit("[ERROR] CUDA matmul returned non-finite output.")

print("[OK] Real CUDA matmul passed.")
PY

log "Smoke-test ComfyUI startup on port $PORT"
kill_port_8188
SMOKE_LOG="$APP_DIR/comfyui_smoke_test.log"

(
  cd "$COMFY_DIR"
  source "$VENV_DIR/bin/activate"
  export HF_HOME="$HF_HOME"
  export HF_HUB_CACHE="$HF_HUB_CACHE"
  export HF_XET_HIGH_PERFORMANCE=1
  export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"
  python main.py --listen 127.0.0.1 --port "$PORT"
) >"$SMOKE_LOG" 2>&1 &
SMOKE_PID=$!

SMOKE_OK=0
for _ in $(seq 1 60); do
  if ! kill -0 "$SMOKE_PID" 2>/dev/null; then
    break
  fi
  if curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
    SMOKE_OK=1
    break
  fi
  sleep 1
done

if [[ "$SMOKE_OK" != "1" ]]; then
  echo "---------------- ComfyUI smoke-test log ----------------"
  tail -n 120 "$SMOKE_LOG" || true
  echo "---------------------------------------------------------"
  kill "$SMOKE_PID" >/dev/null 2>&1 || true
  wait "$SMOKE_PID" >/dev/null 2>&1 || true
  die "ComfyUI failed to become reachable on port $PORT during smoke test."
fi

echo "[OK] ComfyUI responded on port $PORT."
kill "$SMOKE_PID" >/dev/null 2>&1 || true
wait "$SMOKE_PID" >/dev/null 2>&1 || true
kill_port_8188

log "Done"

echo ""
echo "=============================================================="
echo "Setup complete."
echo "Environment dir : $APP_DIR"
echo "ComfyUI dir     : $COMFY_DIR"
echo "Start command   : $BASE_DIR/start_wananimate2.sh"
echo "Restart command : $BASE_DIR/restart_wananimate2.sh"
echo "Port            : $PORT"
echo "Preset          : $WAN_PRESET"
echo "=============================================================="
