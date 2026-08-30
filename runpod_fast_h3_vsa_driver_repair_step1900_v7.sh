#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# FastH3 VSA DRIVER-AWARE REPAIR + STEP1900 v7
# Fixes:
# - CUDA 12.8-capable RunPod driver + cu130 PyTorch incompatibility
# - Keeps existing /workspace/runpod-slim/ComfyUI-FastH3
# - Pins PyTorch 2.11.0 cu128 on drivers < 580
# - Uses cu130 only on drivers >= 580
# - Rechecks comfy-kitchen CUDA extension
# - Probes Kijai repo for converted Synthetic Step1900
# - Restarts FastH3 on port 8188
# ============================================================

ROOT="${FASTH3_ROOT:-/workspace/runpod-slim/ComfyUI-FastH3}"
VENV="$ROOT/.venv"
PORT="${COMFY_PORT:-8188}"
LOG_DIR="$ROOT/setup_logs"

mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/driver_repair_step1900_v7_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

trap 'rc=$?; echo; echo "============================================================"; echo "[FAILED] rc=$rc line=$LINENO"; echo "Log: $LOG"; echo "============================================================"; exit $rc' ERR

echo "============================================================"
echo " FastH3 VSA DRIVER-AWARE REPAIR + STEP1900 v7"
echo " ROOT : $ROOT"
echo " PORT : $PORT"
echo " LOG  : $LOG"
echo "============================================================"

[[ -d "$ROOT/.git" ]] || { echo "[ERROR] Missing FastH3 repo: $ROOT"; exit 1; }
[[ -x "$VENV/bin/python" ]] || { echo "[ERROR] Missing FastH3 venv: $VENV"; exit 1; }

PY="$VENV/bin/python"
PIP="$VENV/bin/pip"

cd "$ROOT"

echo
echo "[1/7] Detect NVIDIA driver"
nvidia-smi

DRIVER_RAW="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 | tr -d ' ')"
DRIVER_MAJOR="${DRIVER_RAW%%.*}"
echo "[Driver] $DRIVER_RAW"

if [[ "$DRIVER_MAJOR" =~ ^[0-9]+$ ]] && (( DRIVER_MAJOR >= 580 )); then
  TORCH_INDEX="https://download.pytorch.org/whl/cu130"
  TORCH_TAG="cu130"
else
  TORCH_INDEX="https://download.pytorch.org/whl/cu128"
  TORCH_TAG="cu128"
fi

echo "[Torch target] $TORCH_TAG"

echo
echo "[2/7] Repair PyTorch for this driver"

# Remove the incompatible CUDA build first.
"$PIP" uninstall -y torch torchvision torchaudio >/dev/null 2>&1 || true

# 2.11.0 has official cu128 and cu130 wheels and supports Blackwell.
"$PIP" install --no-cache-dir \
  torch==2.11.0 \
  torchvision==0.26.0 \
  torchaudio==2.11.0 \
  --index-url "$TORCH_INDEX"

echo
echo "[3/7] Restore ComfyUI requirements without replacing Torch"

# Install the rest while preserving the already-pinned working torch.
# pip normally considers installed torch satisfied; then explicitly re-pin below
# as a final guard in case any dependency changed it.
"$PIP" install -r requirements.txt

"$PIP" install --no-cache-dir \
  torch==2.11.0 \
  torchvision==0.26.0 \
  torchaudio==2.11.0 \
  --index-url "$TORCH_INDEX"

"$PIP" install --only-binary=:all: --upgrade "comfy-kitchen[cublas]==0.2.31"
"$PIP" install -U "huggingface_hub[hf_xet]" hf_transfer

echo
echo "[4/7] CUDA + comfy-kitchen smoke test"

"$PY" - <<'PY'
import importlib, importlib.metadata as md
import torch

print("Torch:", torch.__version__)
print("Torch CUDA:", torch.version.cuda)
print("CUDA available:", torch.cuda.is_available())

if not torch.cuda.is_available():
    raise SystemExit("CUDA is still unavailable after driver-aware Torch repair")

p = torch.cuda.get_device_properties(0)
print("GPU:", p.name)
print("Compute capability:", f"{p.major}.{p.minor}")
print("VRAM GiB:", round(p.total_memory / 1024**3, 2))

print("comfy-kitchen:", md.version("comfy-kitchen"))
m = importlib.import_module("comfy_kitchen.backends.cuda._C")
print("comfy-kitchen CUDA extension:", getattr(m, "__file__", "unknown"))

x = torch.randn((256,256), device="cuda", dtype=torch.float16)
y = x @ x
torch.cuda.synchronize()
print("CUDA matmul: OK", tuple(y.shape))
PY

echo
echo "[5/7] Verify models and probe Step1900"

mkdir -p models/diffusion_models models/text_encoders models/vae user/default/workflows
export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_XET_HIGH_PERFORMANCE=1

HF="$VENV/bin/hf"
[[ -x "$HF" ]] || HF="$(command -v hf || true)"
[[ -n "$HF" ]] || { echo "[ERROR] hf CLI not found"; exit 1; }

# Ensure the already-established core model set exists.
"$HF" download Kijai/MiniMax-H3-experimental \
  minimax_h3_fastvideo_vsa_datafree_1300step_4step_int8_convrot.safetensors \
  --local-dir models/diffusion_models

"$HF" download Comfy-Org/MiniMax-H3 \
  text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors \
  vae/minimax_h3_video_vae_fp16.safetensors \
  vae/minimax_h3_audio_vae_fp32.safetensors \
  --local-dir models

PROBE_ENV="$ROOT/step1900_probe.env"

"$PY" - <<'PY' > "$PROBE_ENV"
from huggingface_hub import list_repo_files

repo = "Kijai/MiniMax-H3-experimental"
files = list_repo_files(repo)

def score(name):
    s = name.lower()
    pts = 0
    if s.endswith(".safetensors"): pts += 100
    if "fastvideo" in s: pts += 50
    if "synthetic" in s: pts += 40
    if "1900" in s: pts += 40
    if "int8_convrot" in s: pts += 30
    if s.startswith("loras/") or "/loras/" in s: pts -= 200
    if s.startswith("controlnet/") or "/controlnet/" in s: pts -= 200
    return pts

cands = sorted(
    [f for f in files if score(f) >= 150],
    key=lambda x: (-score(x), x)
)

if cands:
    print("STEP1900_FOUND=1")
    print("STEP1900_REPO_FILE=" + cands[0])
    print("STEP1900_MODEL_BASENAME=" + cands[0].split("/")[-1])
else:
    print("STEP1900_FOUND=0")
PY

cat "$PROBE_ENV"
source "$PROBE_ENV"

STEP1900_NOTE="$ROOT/user/default/workflows/STEP1900_STATUS.txt"

if [[ "${STEP1900_FOUND:-0}" == "1" ]]; then
  echo "[FOUND] Converted Step1900: $STEP1900_REPO_FILE"
  "$HF" download Kijai/MiniMax-H3-experimental \
    "$STEP1900_REPO_FILE" \
    --local-dir models/diffusion_models

  FOUND_PATH="$(find "$ROOT/models/diffusion_models" -type f -name "$STEP1900_MODEL_BASENAME" | head -n1 || true)"
  [[ -n "$FOUND_PATH" ]] || { echo "[ERROR] Step1900 download completed but file was not found"; exit 1; }

  if [[ "$FOUND_PATH" != "$ROOT/models/diffusion_models/$STEP1900_MODEL_BASENAME" ]]; then
    ln -sf "$FOUND_PATH" "$ROOT/models/diffusion_models/$STEP1900_MODEL_BASENAME"
  fi

  echo "STEP1900_FOUND=1" > "$STEP1900_NOTE"
  echo "MODEL=$STEP1900_MODEL_BASENAME" >> "$STEP1900_NOTE"
else
  echo "[INFO] Kijai has not published a converted Synthetic Step1900 checkpoint yet."
  echo "STEP1900_FOUND=0" > "$STEP1900_NOTE"
fi

echo
echo "[6/7] Stop any ComfyUI currently using port $PORT"

while read -r pid args; do
  [[ -z "${pid:-}" ]] && continue
  if [[ "$args" == *"main.py"* && "$args" == *"--port $PORT"* ]]; then
    cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
    echo "[STOP] PID=$pid CWD=${cwd:-unknown}"
    kill "$pid" 2>/dev/null || true
  fi
done < <(ps -eo pid=,args=)

sleep 3

echo
echo "[7/7] Start FastH3"

export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"
mkdir -p "$ROOT/runtime_logs"
RLOG="$ROOT/runtime_logs/comfy_$(date +%Y%m%d_%H%M%S).log"

nohup "$PY" main.py \
  --listen 0.0.0.0 \
  --port "$PORT" \
  --preview-method auto \
  --enable-cors-header \
  > "$RLOG" 2>&1 &

PID=$!
echo "$PID" > "$ROOT/fast_h3.pid"

for i in $(seq 1 45); do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "[ERROR] FastH3 exited during startup."
    tail -150 "$RLOG" || true
    exit 1
  fi

  if curl -fsS "http://127.0.0.1:$PORT/system_stats" >/dev/null 2>&1; then
    echo "[READY] FastH3 PID=$PID"
    echo "[CWD] $(readlink -f /proc/$PID/cwd 2>/dev/null || true)"
    break
  fi
  sleep 1
done

echo
echo "============================================================"
echo "[SUCCESS] Driver-aware FastH3 repair completed."
echo "Driver       : $DRIVER_RAW"
echo "PyTorch CUDA : $TORCH_TAG"
echo "Port         : $PORT"
echo "Runtime log  : $RLOG"
echo "Step1900     : ${STEP1900_FOUND:-0}"
echo "Status file  : $STEP1900_NOTE"
echo "============================================================"
