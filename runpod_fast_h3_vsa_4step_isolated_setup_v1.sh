#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# RunPod MiniMax H3 FastVideo VSA 4-Step - isolated installer
# Target: RTX 5090 / Blackwell, port 8188
# Root:   /workspace/runpod-slim/ComfyUI-FastH3
#
# Upstream state expected at creation time (2026-08-30):
# - ComfyUI FastH3/VSA support: kijai/ComfyUI branch "vsa"
# - comfy-kitchen VSA/Sol-Attn support: merged to Comfy-Org/comfy-kitchen main
# - FastH3 model:
#   Kijai/MiniMax-H3-experimental
#   minimax_h3_fastvideo_vsa_datafree_1300step_4step_int8_convrot.safetensors
#
# Safe behavior:
# - Does NOT touch other ComfyUI directories.
# - Re-running resumes/repairs this isolated environment.
# - It never rm -rf's the environment unless RESET_FASTH3=1 is explicitly set.
#
# Optional:
#   RESET_FASTH3=1 bash this_script.sh
#   VERIFY_FASTH3_SHA256=1 bash this_script.sh
# ============================================================

ROOT="${FASTH3_ROOT:-/workspace/runpod-slim/ComfyUI-FastH3}"
VENV="$ROOT/.venv"
LOG_DIR="$ROOT/setup_logs"
MODEL_DIR="$ROOT/models"
PORT="${COMFY_PORT:-8188}"
COMFY_REPO="https://github.com/kijai/ComfyUI.git"
COMFY_BRANCH="vsa"
KITCHEN_REPO="https://github.com/Comfy-Org/comfy-kitchen.git"

FASTH3_REPO="Kijai/MiniMax-H3-experimental"
FASTH3_FILE="minimax_h3_fastvideo_vsa_datafree_1300step_4step_int8_convrot.safetensors"
FASTH3_SHA256="7221ae65d78780354d51e5048d29728d9f1f8fb9baf50b1dd3df85f5101413d3"

TEXT_REPO="Comfy-Org/MiniMax-H3"
TEXT_FILE="text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"
VIDEO_VAE_FILE="vae/minimax_h3_video_vae_fp16.safetensors"
AUDIO_VAE_FILE="vae/minimax_h3_audio_vae_fp32.safetensors"

mkdir -p "$(dirname "$ROOT")"

if [[ "${RESET_FASTH3:-0}" == "1" && -e "$ROOT" ]]; then
  echo "[RESET] Removing ONLY: $ROOT"
  rm -rf "$ROOT"
fi

mkdir -p "$ROOT" "$LOG_DIR"
LOG="$LOG_DIR/setup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

trap 'rc=$?; echo; echo "============================================================"; echo "[FAILED] rc=$rc line=$LINENO"; echo "Log: $LOG"; echo "============================================================"; exit $rc' ERR

echo "============================================================"
echo " MiniMax H3 FastVideo VSA 4-Step / isolated RunPod setup"
echo " ROOT : $ROOT"
echo " PORT : $PORT"
echo " LOG  : $LOG"
echo "============================================================"

# ---------- basic host checks ----------
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "[ERROR] nvidia-smi not found. Start this on a GPU RunPod."
  exit 1
fi

echo
echo "[GPU]"
nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv,noheader || nvidia-smi

# 5090 is recommended, but don't hard fail for other supported GPUs.
GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1 || true)"
if [[ "$GPU_NAME" != *"5090"* ]]; then
  echo "[WARN] This script is tuned for RTX 5090/Blackwell. Detected: ${GPU_NAME:-unknown}"
fi

# ---------- system deps ----------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  git git-lfs curl wget ca-certificates ffmpeg \
  build-essential ninja-build cmake pkg-config \
  libgl1 libglib2.0-0 python3.12 python3.12-venv python3.12-dev
git lfs install --system || true

# ---------- uv ----------
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
fi
command -v uv
uv --version

# ---------- clone/update isolated ComfyUI VSA branch ----------
if [[ ! -d "$ROOT/.git" ]]; then
  echo
  echo "[1/7] Cloning kijai/ComfyUI branch: $COMFY_BRANCH"
  git clone --branch "$COMFY_BRANCH" --single-branch "$COMFY_REPO" "$ROOT"
else
  echo
  echo "[1/7] Existing isolated repo found; updating branch: $COMFY_BRANCH"
  cd "$ROOT"
  git remote get-url origin || true
  git fetch origin "$COMFY_BRANCH"
  git checkout "$COMFY_BRANCH"
  git pull --ff-only origin "$COMFY_BRANCH" || {
    echo "[WARN] Fast-forward pull failed; keeping current checkout rather than destroying local changes."
  }
fi

cd "$ROOT"
echo "[ComfyUI commit] $(git rev-parse HEAD)"
git status --short || true

# ---------- venv + torch ----------
echo
echo "[2/7] Creating isolated Python 3.12 environment"
if [[ ! -x "$VENV/bin/python" ]]; then
  uv venv --python python3.12 "$VENV"
fi

PY="$VENV/bin/python"
PIP="$VENV/bin/pip"

"$PY" -m ensurepip --upgrade >/dev/null 2>&1 || true
uv pip install --python "$PY" -U pip setuptools wheel packaging

echo
echo "[3/7] Installing CUDA 13 Torch stack (preferred for RTX 5090)"
# uv's torch backend resolver avoids accidentally pulling a CPU wheel.
if ! uv pip install --python "$PY" --torch-backend=cu130 -U torch torchvision torchaudio; then
  echo "[WARN] cu130 backend resolution failed. Falling back to cu128."
  uv pip install --python "$PY" --torch-backend=cu128 -U torch torchvision torchaudio
fi

# Install ComfyUI requirements without intentionally replacing an already valid torch.
uv pip install --python "$PY" -r "$ROOT/requirements.txt"
uv pip install --python "$PY" -U "huggingface_hub[hf_xet]" hf_transfer

# ---------- force latest comfy-kitchen main with merged Sol-Attn/VSA ----------
echo
echo "[4/7] Installing current comfy-kitchen main with CUDA support"
KITCHEN_SRC="$ROOT/_src/comfy-kitchen"
mkdir -p "$ROOT/_src"

if [[ ! -d "$KITCHEN_SRC/.git" ]]; then
  git clone --depth 1 "$KITCHEN_REPO" "$KITCHEN_SRC"
else
  git -C "$KITCHEN_SRC" fetch origin main
  git -C "$KITCHEN_SRC" checkout main
  git -C "$KITCHEN_SRC" pull --ff-only origin main
fi

# Build requirements and source build.
uv pip install --python "$PY" -U "cmake>=3.26" ninja "nanobind>=2.0.0"
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$(nproc)}"
export MAX_JOBS="${MAX_JOBS:-$(nproc)}"

# CUDA toolkit is required for source CUDA extension.
if command -v nvcc >/dev/null 2>&1; then
  echo "[nvcc] $(nvcc --version | tail -n1)"
else
  echo "[ERROR] nvcc is not available."
  echo "FastH3 VSA's CUDA path needs a CUDA toolkit >= 12.8."
  echo "Use a RunPod CUDA-devel image (not runtime-only) and rerun this script."
  exit 1
fi

uv pip uninstall --python "$PY" comfy-kitchen >/dev/null 2>&1 || true
uv pip install --python "$PY" --no-build-isolation "$KITCHEN_SRC"

# ---------- folders ----------
mkdir -p \
  "$MODEL_DIR/diffusion_models" \
  "$MODEL_DIR/text_encoders" \
  "$MODEL_DIR/vae" \
  "$MODEL_DIR/loras" \
  "$ROOT/input" "$ROOT/output" "$ROOT/user/default/workflows"

# ---------- model downloads ----------
echo
echo "[5/7] Downloading FastH3 + text encoder + VAEs"
export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_XET_HIGH_PERFORMANCE=1

HF="$VENV/bin/hf"
if [[ ! -x "$HF" ]]; then
  HF="$(command -v hf || true)"
fi
if [[ -z "$HF" ]]; then
  echo "[ERROR] Hugging Face 'hf' CLI not found."
  exit 1
fi

# FastH3 diffusion checkpoint.
"$HF" download "$FASTH3_REPO" "$FASTH3_FILE" \
  --local-dir "$MODEL_DIR/diffusion_models"

# RTX 5090: NVFP4/AWQ encoder is the compact Blackwell-friendly choice.
"$HF" download "$TEXT_REPO" \
  "$TEXT_FILE" \
  "$VIDEO_VAE_FILE" \
  "$AUDIO_VAE_FILE" \
  --local-dir "$MODEL_DIR"

FASTH3_PATH="$MODEL_DIR/diffusion_models/$FASTH3_FILE"

if [[ ! -s "$FASTH3_PATH" ]]; then
  echo "[ERROR] FastH3 checkpoint missing: $FASTH3_PATH"
  exit 1
fi

if [[ "${VERIFY_FASTH3_SHA256:-0}" == "1" ]]; then
  echo "[SHA256] Verifying 22.9 GB FastH3 checkpoint..."
  echo "$FASTH3_SHA256  $FASTH3_PATH" | sha256sum -c -
fi

# ---------- launcher ----------
cat > "$ROOT/start_fast_h3.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$ROOT"
source "$VENV/bin/activate"
export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_XET_HIGH_PERFORMANCE=1
export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"
exec python main.py --listen 0.0.0.0 --port "$PORT"
EOF
chmod +x "$ROOT/start_fast_h3.sh"

cat > "$ROOT/stop_fast_h3.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
pkill -f 'ComfyUI-FastH3.*main.py' 2>/dev/null || true
EOF
chmod +x "$ROOT/stop_fast_h3.sh"

# Convenience resume/update script: pulls only this experimental branch,
# reinstalls comfy-kitchen main, does NOT redownload existing HF blobs.
cat > "$ROOT/update_fast_h3.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$ROOT"
git fetch origin "$COMFY_BRANCH"
git checkout "$COMFY_BRANCH"
git pull --ff-only origin "$COMFY_BRANCH"
git -C "$KITCHEN_SRC" fetch origin main
git -C "$KITCHEN_SRC" checkout main
git -C "$KITCHEN_SRC" pull --ff-only origin main
"$VENV/bin/uv" pip install --python "$VENV/bin/python" --no-build-isolation "$KITCHEN_SRC" 2>/dev/null || \
  uv pip install --python "$VENV/bin/python" --no-build-isolation "$KITCHEN_SRC"
echo "Updated. Restart with: $ROOT/start_fast_h3.sh"
EOF
chmod +x "$ROOT/update_fast_h3.sh"

# ---------- smoke tests ----------
echo
echo "[6/7] Smoke testing Python / Torch / comfy-kitchen / model files"
"$PY" - <<'PY'
import os, sys, torch

print("Python:", sys.version.replace("\n", " "))
print("Torch:", torch.__version__)
print("Torch CUDA:", torch.version.cuda)
print("CUDA available:", torch.cuda.is_available())

if not torch.cuda.is_available():
    raise SystemExit("CUDA is not available in PyTorch")

p = torch.cuda.get_device_properties(0)
print("GPU:", p.name)
print("Compute capability:", f"{p.major}.{p.minor}")
print("VRAM GiB:", round(p.total_memory / 1024**3, 2))

import comfy_kitchen
print("comfy_kitchen import: OK")
print("comfy_kitchen:", getattr(comfy_kitchen, "__file__", "unknown"))

# Check that sol_attn exists somewhere in the installed module tree.
found = False
for name in dir(comfy_kitchen):
    if "sol" in name.lower() and "attn" in name.lower():
        found = True
        print("Sol-Attn symbol:", name)
if not found:
    # Import may expose backend functions below the top level; this is not
    # automatically a failure, because ComfyUI imports the backend modules.
    try:
        from comfy_kitchen import attention
        print("comfy_kitchen.attention import: OK")
        print("attention symbols:", [x for x in dir(attention) if "sol" in x.lower()][:20])
    except Exception as e:
        print("Top-level Sol-Attn symbol not exposed; backend import check:", repr(e))

# Minimal CUDA op proves the installed torch wheel can execute on the GPU.
x = torch.randn((512, 512), device="cuda", dtype=torch.float16)
y = x @ x
torch.cuda.synchronize()
print("CUDA matmul smoke test:", tuple(y.shape), "OK")
PY

for f in \
  "$MODEL_DIR/diffusion_models/$FASTH3_FILE" \
  "$MODEL_DIR/$TEXT_FILE" \
  "$MODEL_DIR/$VIDEO_VAE_FILE" \
  "$MODEL_DIR/$AUDIO_VAE_FILE"
do
  if [[ ! -s "$f" ]]; then
    echo "[ERROR] Required model missing: $f"
    exit 1
  fi
  ls -lh "$f"
done

# Fast syntax/import probe for ComfyUI itself.
cd "$ROOT"
"$PY" - <<'PY'
import sys
sys.path.insert(0, ".")
import comfy.model_management
print("ComfyUI core import: OK")
PY

echo
echo "[7/7] Writing environment report"
REPORT="$LOG_DIR/environment_latest.txt"
{
  echo "DATE=$(date -Is)"
  echo "ROOT=$ROOT"
  echo "PORT=$PORT"
  echo "COMFY_BRANCH=$COMFY_BRANCH"
  echo "COMFY_COMMIT=$(git -C "$ROOT" rev-parse HEAD)"
  echo "KITCHEN_COMMIT=$(git -C "$KITCHEN_SRC" rev-parse HEAD)"
  echo "GPU=$GPU_NAME"
  "$PY" - <<'PY'
import torch
print("PYTORCH=" + torch.__version__)
print("TORCH_CUDA=" + str(torch.version.cuda))
if torch.cuda.is_available():
    p = torch.cuda.get_device_properties(0)
    print("COMPUTE_CAPABILITY=%d.%d" % (p.major, p.minor))
PY
  echo "FASTH3_MODEL=$FASTH3_PATH"
} | tee "$REPORT"

touch "$ROOT/FASTH3_SETUP_OK"

echo
echo "============================================================"
echo "[SUCCESS] FastH3 isolated environment is ready."
echo
echo "Start:"
echo "  cd $ROOT && ./start_fast_h3.sh"
echo
echo "ComfyUI:"
echo "  http://127.0.0.1:$PORT"
echo "  (On RunPod use the HTTP service/proxy for port $PORT.)"
echo
echo "FastH3 checkpoint:"
echo "  models/diffusion_models/$FASTH3_FILE"
echo
echo "Text encoder:"
echo "  $TEXT_FILE"
echo
echo "VAEs:"
echo "  $VIDEO_VAE_FILE"
echo "  $AUDIO_VAE_FILE"
echo
echo "Log:"
echo "  $LOG"
echo "============================================================"
