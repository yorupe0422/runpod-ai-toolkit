#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# RunPod AI Toolkit #15
# Wan2.2 Animate-14B MIX (character replacement) for ComfyUI
# Target: CUDA 13.x host / Blackwell-ready PyTorch cu130
# Goal: Source video remains the base; replace the person with
#       the character from a reference image (MIX mode).
# Includes: ComfyUI, Manager, KJNodes, controlnet_aux, VHS,
#           official ComfyUI workflow, required models,
#           DWPose assets, CUDA validation, smoke test,
#           and persistent ComfyUI start on port 8188.
# ============================================================

BASE="/workspace/runpod-slim"
APP="$BASE/ComfyUI-Wan22-Animate-Mix"
COMFY="$APP/ComfyUI"
VENV="$APP/venv"
HF_HOME_DIR="/workspace/hf"
PORT="8188"
WORKFLOW_DIR="$COMFY/user/default/workflows"
WORKFLOW="$WORKFLOW_DIR/15_Wan22_Animate14B_MIX_CharacterReplace.json"
LOG="$APP/comfyui_startup.log"

# Model choice: scaled FP8 for practical 48GB-class GPUs.
DIFFUSION_NAME="Wan2_2-Animate-14B_fp8_e4m3fn_scaled_KJ.safetensors"
TEXT_NAME="umt5_xxl_fp8_e4m3fn_scaled.safetensors"
CLIP_NAME="clip_vision_h.safetensors"
VAE_NAME="wan_2.1_vae.safetensors"
LIGHTX_NAME="lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors"
RELIGHT_NAME="wan2.2_animate_14B_relight_lora_bf16.safetensors"

say(){ printf '\n\033[1;36m[15] %s\033[0m\n' "$*"; }
warn(){ printf '\n\033[1;33m[WARN] %s\033[0m\n' "$*"; }
die(){ printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

trap 'echo; echo "[ERROR] Failed at line $LINENO: $BASH_COMMAND" >&2' ERR

say "Preflight: NVIDIA / CUDA 13.x required"
command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi not found. Launch a GPU Pod first."
nvidia-smi

CUDA_HOST="$(nvidia-smi | sed -n 's/.*CUDA Version: \([0-9][0-9.]*\).*/\1/p' | head -n1)"
[[ -n "$CUDA_HOST" ]] || die "Could not detect host CUDA version from nvidia-smi."
CUDA_MAJOR="${CUDA_HOST%%.*}"
(( CUDA_MAJOR >= 13 )) || die "CUDA 13.x+ host required. Detected CUDA $CUDA_HOST. Please relaunch a CUDA 13 Pod."

GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1 || true)"
GPU_MEM="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n1 || true)"
echo "GPU: ${GPU_NAME:-unknown}"
echo "VRAM MiB: ${GPU_MEM:-unknown}"

say "System packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  git git-lfs curl wget aria2 ffmpeg jq unzip rsync lsof \
  python3 python3-venv python3-pip libgl1 libglib2.0-0
rm -rf /var/lib/apt/lists/*
git lfs install --skip-repo || true

say "Directories"
mkdir -p "$BASE" "$APP" "$HF_HOME_DIR" "$WORKFLOW_DIR"

say "Clone / update ComfyUI"
if [[ ! -d "$COMFY/.git" ]]; then
  rm -rf "$COMFY"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
else
  git -C "$COMFY" fetch --depth 1 origin master || git -C "$COMFY" fetch --depth 1 origin main
  git -C "$COMFY" reset --hard FETCH_HEAD
fi

say "Python venv"
if [[ ! -x "$VENV/bin/python" ]]; then
  rm -rf "$VENV"
  python3 -m venv "$VENV"
fi
source "$VENV/bin/activate"
python -m pip install -U pip setuptools wheel

say "PyTorch cu130 (Blackwell / CUDA 13)"
python -m pip install --upgrade --force-reinstall \
  torch==2.14.0 torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/cu130

say "ComfyUI Python requirements"
python -m pip install -r "$COMFY/requirements.txt"
python -m pip install -U huggingface_hub hf-xet requests

say "Custom nodes"
CUSTOM="$COMFY/custom_nodes"
mkdir -p "$CUSTOM"

clone_or_update(){
  local url="$1" dir="$2"
  if [[ ! -d "$dir/.git" ]]; then
    rm -rf "$dir"
    git clone --depth 1 "$url" "$dir"
  else
    git -C "$dir" pull --ff-only || true
  fi
}

clone_or_update https://github.com/Comfy-Org/ComfyUI-Manager.git "$CUSTOM/ComfyUI-Manager"
clone_or_update https://github.com/kijai/ComfyUI-KJNodes.git "$CUSTOM/ComfyUI-KJNodes"
clone_or_update https://github.com/Fannovel16/comfyui_controlnet_aux.git "$CUSTOM/comfyui_controlnet_aux"
clone_or_update https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git "$CUSTOM/ComfyUI-VideoHelperSuite"

for req in \
  "$CUSTOM/ComfyUI-Manager/requirements.txt" \
  "$CUSTOM/ComfyUI-KJNodes/requirements.txt" \
  "$CUSTOM/comfyui_controlnet_aux/requirements.txt" \
  "$CUSTOM/ComfyUI-VideoHelperSuite/requirements.txt"; do
  [[ -f "$req" ]] && python -m pip install -r "$req"
done

# Re-assert the known-good CUDA 13 torch build after custom-node dependency installs.
say "Re-pin PyTorch cu130 after custom-node installs"
python -m pip install --upgrade --force-reinstall \
  torch==2.14.0 torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/cu130

export HF_HOME="$HF_HOME_DIR"
export HF_HUB_CACHE="$HF_HOME_DIR/hub"
export HF_XET_CACHE="$HF_HOME_DIR/xet"
export HF_XET_HIGH_PERFORMANCE=1
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
mkdir -p "$HF_HUB_CACHE" "$HF_XET_CACHE"

say "Validate CUDA + Blackwell architecture + real CUDA compute"
python - <<'PY'
import torch
print("Torch:", torch.__version__)
print("Torch CUDA build:", torch.version.cuda)
print("CUDA available:", torch.cuda.is_available())
if not torch.cuda.is_available():
    raise SystemExit("CUDA is not available in PyTorch")
name = torch.cuda.get_device_name(0)
cap = torch.cuda.get_device_capability(0)
arch = torch.cuda.get_arch_list()
print("GPU:", name)
print("Compute capability:", cap)
print("Torch arch list:", arch)
if cap[0] >= 12 and "sm_120" not in arch:
    raise SystemExit("Blackwell sm_120 GPU detected but this Torch build lacks sm_120 support")
a = torch.randn((2048, 2048), device="cuda", dtype=torch.float16)
b = torch.randn((2048, 2048), device="cuda", dtype=torch.float16)
c = a @ b
torch.cuda.synchronize()
print("CUDA matmul OK:", tuple(c.shape), c.dtype)
del a,b,c
PY

say "Create model folders"
mkdir -p \
  "$COMFY/models/diffusion_models" \
  "$COMFY/models/loras" \
  "$COMFY/models/text_encoders" \
  "$COMFY/models/clip_vision" \
  "$COMFY/models/vae"

# Robust HF downloader: uses hf_hub_download/Xet, then moves the exact file to ComfyUI.
hf_get(){
  local repo="$1" filename="$2" dest="$3"
  if [[ -s "$dest" ]]; then
    echo "[SKIP] $(basename "$dest") already exists"
    return 0
  fi
  mkdir -p "$(dirname "$dest")" "$APP/.hf_stage"
  REPO="$repo" FILENAME="$filename" DEST="$dest" STAGE="$APP/.hf_stage" python - <<'PY'
import os, shutil
from huggingface_hub import hf_hub_download
repo=os.environ['REPO']; fn=os.environ['FILENAME']; dest=os.environ['DEST']; stage=os.environ['STAGE']
print(f"[HF] {repo} :: {fn}")
p=hf_hub_download(repo_id=repo, filename=fn, local_dir=stage)
os.makedirs(os.path.dirname(dest), exist_ok=True)
if os.path.abspath(p) != os.path.abspath(dest):
    if os.path.exists(dest): os.remove(dest)
    shutil.move(p, dest)
print(f"[OK] {dest} ({os.path.getsize(dest)/1024**3:.2f} GiB)")
PY
  rm -rf "$APP/.hf_stage/.cache" 2>/dev/null || true
}

say "Download Wan2.2 Animate-14B MIX models"
hf_get \
  "Kijai/WanVideo_comfy_fp8_scaled" \
  "Wan22Animate/$DIFFUSION_NAME" \
  "$COMFY/models/diffusion_models/$DIFFUSION_NAME"

hf_get \
  "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" \
  "split_files/text_encoders/$TEXT_NAME" \
  "$COMFY/models/text_encoders/$TEXT_NAME"

hf_get \
  "Comfy-Org/Wan_2.1_ComfyUI_repackaged" \
  "split_files/clip_vision/$CLIP_NAME" \
  "$COMFY/models/clip_vision/$CLIP_NAME"

hf_get \
  "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" \
  "split_files/vae/$VAE_NAME" \
  "$COMFY/models/vae/$VAE_NAME"

hf_get \
  "Kijai/WanVideo_comfy" \
  "Lightx2v/$LIGHTX_NAME" \
  "$COMFY/models/loras/$LIGHTX_NAME"

# Relighting LoRA is used by replacement/MIX pipelines to better match source lighting.
hf_get \
  "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" \
  "split_files/loras/$RELIGHT_NAME" \
  "$COMFY/models/loras/$RELIGHT_NAME"

say "Pre-download DWPose assets used by the official MIX workflow"
AUX="$CUSTOM/comfyui_controlnet_aux"
mkdir -p "$AUX/ckpts/yzd-v/DWPose" "$AUX/ckpts/hr16/DWPose-TorchScript-BatchSize5"
hf_get \
  "yzd-v/DWPose" \
  "yolox_l.onnx" \
  "$AUX/ckpts/yzd-v/DWPose/yolox_l.onnx"
hf_get \
  "hr16/DWPose-TorchScript-BatchSize5" \
  "dw-ll_ucoco_384_bs5.torchscript.pt" \
  "$AUX/ckpts/hr16/DWPose-TorchScript-BatchSize5/dw-ll_ucoco_384_bs5.torchscript.pt"

say "Install official ComfyUI Wan2.2 Animate workflow (default MIX mode)"
mkdir -p "$WORKFLOW_DIR"
curl -fL --retry 5 --retry-delay 3 \
  https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/video_wan2_2_14B_animate.json \
  -o "$WORKFLOW"

# Patch only model filenames, keeping the official topology/links untouched.
WF="$WORKFLOW" DIFF="$DIFFUSION_NAME" TEXT="$TEXT_NAME" CLIP="$CLIP_NAME" VAE="$VAE_NAME" LIGHTX="$LIGHTX_NAME" RELIGHT="$RELIGHT_NAME" python - <<'PY'
import json, os, pathlib
p=pathlib.Path(os.environ['WF'])
s=p.read_text(encoding='utf-8')
repl={
    'wan2.2_animate_14B_bf16.safetensors': os.environ['DIFF'],
    'Wan2_2-Animate-14B_fp8_e4m3fn_scaled_KJ.safetensors': os.environ['DIFF'],
    'umt5_xxl_fp16.safetensors': os.environ['TEXT'],
    'umt5_xxl_fp8_e4m3fn_scaled.safetensors': os.environ['TEXT'],
    'clip_vision_h.safetensors': os.environ['CLIP'],
    'wan_2.1_vae.safetensors': os.environ['VAE'],
    'lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors': os.environ['LIGHTX'],
    'WanAnimate_relight_lora_fp16.safetensors': os.environ['RELIGHT'],
    'wan2.2_animate_14B_relight_lora_bf16.safetensors': os.environ['RELIGHT'],
}
for a,b in repl.items():
    s=s.replace(a,b)
# Validate JSON after patching.
obj=json.loads(s)
p.write_text(json.dumps(obj, ensure_ascii=False, separators=(',',':')), encoding='utf-8')
print('[OK] Workflow JSON valid:', p)
print('[OK] Nodes:', len(obj.get('nodes', [])))
PY

say "Create helper scripts"
cat > "$BASE/start_wan22_animate_mix.sh" <<EOS
#!/usr/bin/env bash
set -Eeuo pipefail
source "$VENV/bin/activate"
export HF_HOME="$HF_HOME_DIR"
export HF_HUB_CACHE="$HF_HOME_DIR/hub"
export HF_XET_CACHE="$HF_HOME_DIR/xet"
export HF_XET_HIGH_PERFORMANCE=1
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
cd "$COMFY"
exec python main.py --listen 0.0.0.0 --port "$PORT"
EOS
chmod +x "$BASE/start_wan22_animate_mix.sh"

cat > "$BASE/restart_wan22_animate_mix.sh" <<EOS
#!/usr/bin/env bash
set -Eeuo pipefail
pkill -f "$COMFY/main.py" 2>/dev/null || true
sleep 2
exec "$BASE/start_wan22_animate_mix.sh"
EOS
chmod +x "$BASE/restart_wan22_animate_mix.sh"

say "Model inventory"
find "$COMFY/models" -maxdepth 2 -type f \( -name '*.safetensors' -o -name '*.onnx' -o -name '*.pt' \) -printf '%p  %k KB\n' | sort

echo
say "Smoke test ComfyUI startup / node imports"
# Free stale 8188 listener if any from this app.
if lsof -tiTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  warn "Port $PORT is already in use; stopping stale listener for smoke test."
  lsof -tiTCP:"$PORT" -sTCP:LISTEN | xargs -r kill || true
  sleep 2
fi

source "$VENV/bin/activate"
cd "$COMFY"
: > "$LOG"
python main.py --listen 127.0.0.1 --port "$PORT" >"$LOG" 2>&1 &
SMOKE_PID=$!
SMOKE_OK=0
for _ in $(seq 1 90); do
  if curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
    SMOKE_OK=1
    break
  fi
  if ! kill -0 "$SMOKE_PID" 2>/dev/null; then
    break
  fi
  sleep 1
done

if [[ "$SMOKE_OK" != "1" ]]; then
  echo "----- ComfyUI startup log -----"
  tail -n 250 "$LOG" || true
  kill "$SMOKE_PID" 2>/dev/null || true
  wait "$SMOKE_PID" 2>/dev/null || true
  die "ComfyUI smoke test failed."
fi

echo "[OK] ComfyUI responded on port $PORT."
kill "$SMOKE_PID" 2>/dev/null || true
wait "$SMOKE_PID" 2>/dev/null || true
sleep 2

say "#15 setup complete"
echo "App:      $APP"
echo "ComfyUI:  $COMFY"
echo "Workflow: $WORKFLOW"
echo "Start:    $BASE/start_wan22_animate_mix.sh"
echo "Restart:  $BASE/restart_wan22_animate_mix.sh"
echo
echo "TEST PATH:"
echo "  1) Open Port 8188"
echo "  2) Workflow -> Open -> 15_Wan22_Animate14B_MIX_CharacterReplace.json"
echo "  3) LoadImage = target/reference character"
echo "  4) LoadVideo = source/driving video whose background/camera/action should remain"
echo "  5) Keep MIX wiring (background_video + character_mask connected)"
echo "  6) First test: 3-5 sec, small resolution, one adult subject, then Run"
echo
echo "Starting ComfyUI persistently now. Keep this terminal open."

exec "$BASE/start_wan22_animate_mix.sh"
