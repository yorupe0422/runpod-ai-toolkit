#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# RunPod + ComfyUI + SeedVR2 7B INT8
# CLEAN image-restoration setup
#
# Purpose:
#   Restore low-quality video captures / screenshots into a
#   cleaner, modern-phone-photo-like image while preserving
#   the original structure as much as possible.
#
# IMPORTANT:
#   This script intentionally rebuilds ComfyUI from scratch.
#   Use it on a fresh/throwaway RunPod as requested.
# ============================================================

ROOT="/workspace/runpod-slim"
COMFY="$ROOT/ComfyUI"
VENV="$COMFY/.venv"
PORT="8188"
LOG="$ROOT/comfyui_seedvr2.log"
WF_NAME="seedvr2_7b_int8_iphone_restore_2x.json"
WF_DIR="$COMFY/user/default/workflows"
WF_PATH="$WF_DIR/$WF_NAME"

MODEL_REPO="Comfy-Org/SeedVR2"
MODEL_FILE="diffusion_models/seedvr2_7b_int8_convrot.safetensors"
VAE_FILE="vae/seedvr2_ema_vae_fp16.safetensors"
OFFICIAL_WF_URL="https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/utility_seedvr2_7b_int8_upscale_image.json"

export PIP_DISABLE_PIP_VERSION_CHECK=1
export HF_HUB_ENABLE_HF_TRANSFER=0

say() { printf '\n\033[1;36m[%s]\033[0m %s\n' "$1" "$2"; }
die() { printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

find_real_python() {
  local p
  for p in /usr/bin/python3 /usr/local/bin/python3; do
    if [[ -x "$p" ]] && "$p" -c 'import sys; print(sys.version)' >/dev/null 2>&1; then
      echo "$p"
      return 0
    fi
  done
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys' >/dev/null 2>&1; then
    command -v python3
    return 0
  fi
  return 1
}

download_small() {
  local url="$1" dst="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 5 --retry-delay 3 "$url" -o "$dst"
  elif command -v wget >/dev/null 2>&1; then
    wget --tries=5 -O "$dst" "$url"
  else
    die "curl/wget がありません。"
  fi
}

say "0/9" "Stopping any old ComfyUI process on this fresh Pod"
pkill -f 'main.py.*--port 8188' 2>/dev/null || true
sleep 2

mkdir -p "$ROOT"

PY="$(find_real_python || true)"
[[ -n "${PY:-}" ]] || die "通常の Python 3 が見つかりません。"

say "1/9" "Using Python: $PY"
"$PY" -c 'import sys; print("Python:", sys.version)'

say "2/9" "Rebuilding latest ComfyUI from scratch"
rm -rf "$COMFY"
git clone --depth=1 https://github.com/Comfy-Org/ComfyUI.git "$COMFY"

say "3/9" "Creating isolated Python environment"
if ! "$PY" -m venv --system-site-packages "$VENV" 2>/dev/null; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv
    "$PY" -m venv --system-site-packages "$VENV"
  else
    die "venv を作成できませんでした。"
  fi
fi

VPY="$VENV/bin/python"
"$VPY" -m pip install -U pip setuptools wheel
"$VPY" -m pip install -r "$COMFY/requirements.txt"
"$VPY" -m pip install -U "huggingface_hub[hf_xet]"

say "4/9" "Checking CUDA / GPU"
"$VPY" - <<'PY'
import sys
try:
    import torch
except Exception as e:
    raise SystemExit(f"PyTorch import failed: {e}")
print("torch:", torch.__version__)
print("cuda available:", torch.cuda.is_available())
if not torch.cuda.is_available():
    raise SystemExit("CUDA GPU is not visible to PyTorch.")
print("GPU:", torch.cuda.get_device_name(0))
PY

say "5/9" "Checking native SeedVR2 support in ComfyUI"
[[ -d "$COMFY/comfy/ldm/seedvr2" ]] || die "最新ComfyUIに native SeedVR2 実装が見つかりません。"
git -C "$COMFY" log -1 --oneline

say "6/9" "Downloading official SeedVR2 7B INT8 model + VAE (~8.8 GB total)"
mkdir -p "$COMFY/models/diffusion_models" "$COMFY/models/vae"
"$VPY" - "$COMFY/models" "$MODEL_REPO" "$MODEL_FILE" "$VAE_FILE" <<'PY'
import os, sys
from huggingface_hub import hf_hub_download

models_dir, repo, model_file, vae_file = sys.argv[1:]
for filename in (model_file, vae_file):
    print(f"Downloading/checking: {filename}", flush=True)
    path = hf_hub_download(
        repo_id=repo,
        filename=filename,
        local_dir=models_dir,
    )
    size = os.path.getsize(path)
    print(f"OK: {path} ({size/1024**3:.2f} GiB)", flush=True)
PY

MODEL_PATH="$COMFY/models/$MODEL_FILE"
VAE_PATH="$COMFY/models/$VAE_FILE"
[[ -s "$MODEL_PATH" ]] || die "SeedVR2 model download failed."
[[ -s "$VAE_PATH" ]] || die "SeedVR2 VAE download failed."

say "7/9" "Installing the official ComfyUI SeedVR2 7B image workflow"
mkdir -p "$WF_DIR"
download_small "$OFFICIAL_WF_URL" "$WF_PATH"

# Keep the official workflow intact except:
# - default scale 4x -> 2x (safer/less hallucination for video screenshots)
# - output prefix renamed for this use case
"$VPY" - "$WF_PATH" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    d = json.load(f)

def walk_nodes(container):
    if isinstance(container, dict):
        if isinstance(container.get("nodes"), list):
            for n in container["nodes"]:
                yield n
        for v in container.values():
            yield from walk_nodes(v)
    elif isinstance(container, list):
        for v in container:
            yield from walk_nodes(v)

for n in walk_nodes(d):
    t = n.get("type")
    vals = n.get("widgets_values")
    if t == "ResizeImageMaskNode" and isinstance(vals, list) and len(vals) >= 3:
        if vals[0] == "scale by multiplier":
            vals[1] = 2
    if t == "SaveImage" and isinstance(vals, list) and vals:
        vals[0] = "iphone_restore/seedvr2_7b_2x"

with open(path, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
PY

cp -f "$WF_PATH" "$ROOT/$WF_NAME"

say "8/9" "Starting ComfyUI on port 8188"
cd "$COMFY"
nohup "$VPY" main.py \
  --listen 0.0.0.0 \
  --port "$PORT" \
  --preview-method auto \
  --enable-cors-header \
  >"$LOG" 2>&1 &
PID=$!
echo "$PID" > "$ROOT/comfyui_seedvr2.pid"

echo "PID: $PID"
echo "Log: $LOG"

ok=0
for i in $(seq 1 90); do
  if ! kill -0 "$PID" 2>/dev/null; then
    tail -n 120 "$LOG" || true
    die "ComfyUI exited during startup."
  fi
  if command -v curl >/dev/null 2>&1 && curl -fsS "http://127.0.0.1:${PORT}/object_info" -o "$ROOT/object_info.json" 2>/dev/null; then
    ok=1
    break
  fi
  sleep 2
done
[[ "$ok" -eq 1 ]] || {
  tail -n 120 "$LOG" || true
  die "ComfyUI API did not become ready on port 8188."
}

say "9/9" "Verifying SeedVR2 nodes through the live ComfyUI API"
"$VPY" - "$ROOT/object_info.json" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    d = json.load(f)
required = [
    "SeedVR2Preprocess",
    "SeedVR2PostProcessing",
    "SeedVR2Conditioning",
]
missing = [x for x in required if x not in d]
if missing:
    raise SystemExit("Missing native SeedVR2 nodes: " + ", ".join(missing))
print("Native SeedVR2 nodes: OK")
PY

printf '\n\033[1;32m============================================================\n'
printf ' SUCCESS — SeedVR2 image restoration is ready\n'
printf '============================================================\033[0m\n'
echo "ComfyUI URL/Proxy port : 8188"
echo "ComfyUI path           : $COMFY"
echo "Workflow               : $WF_PATH"
echo "Import copy            : $ROOT/$WF_NAME"
echo "Model                  : seedvr2_7b_int8_convrot.safetensors"
echo "VAE                    : seedvr2_ema_vae_fp16.safetensors"
echo "Default upscale        : 2x"
echo "Output folder          : $COMFY/output/iphone_restore/"
echo
echo "FIRST TEST:"
echo "  1) Open ComfyUI on port 8188"
echo "  2) Load '$WF_NAME'"
echo "  3) Select a low-quality screenshot in Load Image"
echo "  4) Keep scale_multiplier=2 and denoise=1 for the first run"
echo "  5) Queue"
echo
echo "If the UI does not list the workflow, drag this JSON into ComfyUI:"
echo "  $ROOT/$WF_NAME"
echo
echo "Startup log:"
echo "  tail -f $LOG"
echo "============================================================"
