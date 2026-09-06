#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# SETUP #5 — FUSED TURBO / REF2VA CANDIDATE v3
#
# Purpose:
#   Experimental successor candidate for the current SETUP #5.
#   Builds an independent MiniMax-H3 environment using:
#     - MATLOWAI Fused FL2VA+Ref2VA + Turbo8 + Mystic0.7 INT8 ConvRot
#     - Kijai INT8 ConvRot video VAE
#     - MiniMax H3 NVFP4-AWQ text encoder + FP32 audio VAE
#     - SLA sparse attention node
#     - MATLOWAI I2V/FL2V 4-step workflow
#     - MATLOWAI Ref2VA 4-step workflow
#     - Ref2VA 8-step QUALITY workflow derived from the same official graph
#     - MiniMax H3 Fast VAE Decode node (optional benchmark path)
#
# v3 note:
#   Keeps the v2 known-good Fused/Ref2VA/SLA/FastVAE base unchanged.
#   Adds ComfyUI-H3-FaceRefine as a completely separate post-refine path,
#   the required face detector, and a copied RECT example workflow.
#   Also adds a separate 8-step Ref2VA QUALITY workflow while keeping the
#   official 4-step graph untouched as the fast/reference path.
#   Existing generation workflows are not modified by FaceRefine.
#
# Safety:
#   - Does NOT overwrite the current /workspace/runpod-slim/ComfyUI-H3.
#   - Installs to /workspace/runpod-slim/ComfyUI-H3-Fused.
#   - Uses port 8188 only after all files/nodes are prepared.
#
# Recommended RunPod:
#   RTX 5090 + NVIDIA Driver >= 580 + CUDA 13 capable host.
# =============================================================================

ROOT="${ROOT:-/workspace/runpod-slim}"
COMFY="${COMFY:-$ROOT/ComfyUI-H3-Fused}"
PORT="${PORT:-8188}"
COMFY_TAG="${COMFY_TAG:-v0.34.0}"
PYTHON_BIN="${PYTHON_BIN:-python3.12}"
LOG_DIR="$COMFY/setup_logs"
RUNTIME_DIR="$COMFY/runtime_logs"
WF_DIR="$COMFY/user/default/workflows"
STATE_DIR="$ROOT/.h3_fused_setup_v3"

MODEL="minimax_h3_fused_refdelta_r1024_turbo8_mystic07_int8_convrot.safetensors"
TEXT="qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"
VIDEO_VAE="minimax_h3_video_vae_int8_convrot.safetensors"
AUDIO_VAE="minimax_h3_audio_vae_fp32.safetensors"

MODEL_URL="https://huggingface.co/MATLOWAI/minimax-h3-fused-turbo-int8-convrot/resolve/main/diffusion_models/$MODEL?download=true"
TEXT_URL="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/text_encoders/$TEXT?download=true"
VIDEO_VAE_URL="https://huggingface.co/Kijai/MiniMax-H3-experimental/resolve/main/$VIDEO_VAE?download=true"
AUDIO_VAE_URL="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/$AUDIO_VAE?download=true"

MODEL_SHA="4262e4e9963c553fa00016bbe83961407a4fc0a888be95fd836c8d4f2304e48b"
TEXT_SHA="35a88d51044231fe332301d7a62aa81e3f2cba62febeb446e2c1e3e0ef76f2c6"
VIDEO_VAE_SHA="9bb2d96f218c76babd85e0611b85ca8fb330a90546c01a0005e8a58a59593410"
AUDIO_VAE_SHA="8e505d95dd1561d47abd43d4238fd40d9bb1ae9e147ed0a4cba778d76ae4db48"

WF_I2V="01_FUSED_H3_I2V_FL2V_4STEP_SLA.json"
WF_REF="02_FUSED_H3_REF2VA_4STEP_SLA.json"
WF_I2V_URL="https://huggingface.co/MATLOWAI/minimax-h3-fused-turbo-int8-convrot/resolve/main/workflows/04_i2v_fl2v_4step_sla.json?download=true"
WF_REF_URL="https://huggingface.co/MATLOWAI/minimax-h3-fused-turbo-int8-convrot/resolve/main/workflows/05_ref2va_4step_sla.json?download=true"

SLA_REPO="https://github.com/ethanfel/ComfyUI-PlagueKind-Nodes-only-sparse.git"
MAINODES_REPO="https://github.com/matlowai/ComfyUI-MAINodes.git"
FASTVAE_REPO="https://github.com/Mozer/ComfyUI-MiniMax-H3-MotionCache-FastVAE.git"
FACEREFINE_REPO="https://github.com/Carasibana/ComfyUI-H3-FaceRefine.git"
VHS_REPO="https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
IMPACT_REPO="https://github.com/ltdrdata/ComfyUI-Impact-Pack.git"
AUDIOLOCK_REPO="https://github.com/Shrek3OnVH5/MiniMax-H3-NativeAudio-MusicVideo-Workflow.git"
FACE_DETECTOR="face_yolov8m.pt"
FACE_DETECTOR_URL="https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov8m.pt?download=true"
FACE_DETECTOR_SHA="717923c19b3f4bbf5250b728f1fa6b2cb72a33aed1d236ea9caf0e21ad943e5f"

green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[0;33m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
die(){ red "[FAILED] $*"; exit 1; }

mkdir -p "$ROOT" "$STATE_DIR"

on_error(){
  rc=$?
  line="${BASH_LINENO[0]:-unknown}"
  red ""
  red "SETUP #5 FUSED CANDIDATE FAILED rc=$rc line=$line"
  if [[ -d "$RUNTIME_DIR" ]]; then
    latest="$(ls -t "$RUNTIME_DIR"/comfy_*.log 2>/dev/null | head -1 || true)"
    [[ -n "${latest:-}" ]] && { echo "Latest runtime log: $latest"; tail -120 "$latest" || true; }
  fi
  exit "$rc"
}
trap on_error ERR

echo "================================================================="
echo " SETUP #5 — FUSED TURBO / REF2VA CANDIDATE v3"
echo "================================================================="
echo "Install dir: $COMFY"
echo "Port:        $PORT"
echo

# -----------------------------------------------------------------------------
# 1. Preflight
# -----------------------------------------------------------------------------
echo "[1/10] Preflight"

if ! command -v nvidia-smi >/dev/null 2>&1; then
  die "nvidia-smi not found"
fi

DRIVER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | tr -d ' ')"
GPU="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
echo "GPU:    $GPU"
echo "Driver: $DRIVER"

DRIVER_MAJOR="${DRIVER%%.*}"
if [[ "$DRIVER_MAJOR" =~ ^[0-9]+$ ]] && (( DRIVER_MAJOR < 580 )); then
  die "Driver $DRIVER is too old for the recommended CUDA 13 / RTX 5090 path. Select a RunPod host with Driver 580+."
fi

for tool in git curl aria2c lsof ffmpeg; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl aria2 lsof ffmpeg ca-certificates
    break
  fi
done
green "  ✓ system tools"

# -----------------------------------------------------------------------------
# 2. ComfyUI v0.34.0 independent checkout
# -----------------------------------------------------------------------------
echo "[2/10] ComfyUI $COMFY_TAG"

if [[ ! -d "$COMFY/.git" ]]; then
  if [[ -e "$COMFY" ]]; then
    mv "$COMFY" "${COMFY}.incomplete.$(date +%Y%m%d_%H%M%S)"
  fi
  git clone --depth 1 --branch "$COMFY_TAG" https://github.com/Comfy-Org/ComfyUI.git "$COMFY"
else
  git -C "$COMFY" fetch --depth 1 --force origin "refs/tags/$COMFY_TAG:refs/tags/$COMFY_TAG"
  git -C "$COMFY" checkout -f "$COMFY_TAG"
  git -C "$COMFY" reset --hard "$COMFY_TAG"
fi

grep -Rqs "MiniMaxH3ImageToVideo" "$COMFY/comfy_extras" || \
  die "$COMFY_TAG does not contain MiniMax-H3 core nodes"

mkdir -p "$LOG_DIR" "$RUNTIME_DIR" "$WF_DIR" \
  "$COMFY/models/diffusion_models" "$COMFY/models/text_encoders" "$COMFY/models/vae"

SETUP_LOG="$LOG_DIR/setup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$SETUP_LOG") 2>&1

green "  ✓ ComfyUI ready"

# -----------------------------------------------------------------------------
# 3. Python / CUDA stack
# -----------------------------------------------------------------------------
echo "[3/10] Python / CUDA stack"

if [[ ! -x "$COMFY/.venv/bin/python" ]]; then
  "$PYTHON_BIN" -m venv --system-site-packages "$COMFY/.venv"
fi
PY="$COMFY/.venv/bin/python"
PIP="$COMFY/.venv/bin/pip"

"$PY" -m pip install -q -U pip setuptools wheel

# Prevent requirements from silently replacing the GPU torch stack.
REQ_FILTERED="$STATE_DIR/requirements_no_torch.txt"
"$PY" - "$COMFY/requirements.txt" "$REQ_FILTERED" <<'PYCODE'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
pat = re.compile(r'^\s*(torch|torchvision|torchaudio)(?:\s*[<>=!~].*)?\s*(?:#.*)?$', re.I)
out=[]
for line in open(src, encoding='utf-8'):
    if not pat.match(line.strip()):
        out.append(line)
open(dst,'w',encoding='utf-8').writelines(out)
PYCODE

"$PIP" install -q --upgrade-strategy only-if-needed -r "$REQ_FILTERED"

# Reuse a CUDA 13 torch if available. Otherwise install official cu130 wheels.
if "$PY" - <<'PYCODE' >/tmp/h3_fused_torch_probe.txt 2>&1
import torch
ok = torch.cuda.is_available() and str(torch.version.cuda or "").startswith("13.")
print("torch=", torch.__version__)
print("torch_cuda=", torch.version.cuda)
print("cuda=", torch.cuda.is_available())
print("gpu=", torch.cuda.get_device_name(0) if torch.cuda.is_available() else "NONE")
raise SystemExit(0 if ok else 1)
PYCODE
then
  cat /tmp/h3_fused_torch_probe.txt
  echo "  [SKIP] usable CUDA 13 PyTorch already available"
else
  cat /tmp/h3_fused_torch_probe.txt || true
  echo "  Installing official CUDA 13 PyTorch..."
  "$PIP" install -q -U torch torchvision torchaudio \
    --extra-index-url https://download.pytorch.org/whl/cu130
fi

# INT8 ConvRot / Comfy quant backend.
"$PIP" install -q -U "comfy-kitchen[cublas]==0.2.31" triton

"$PY" - <<'PYCODE'
import torch
print("torch:", torch.__version__)
print("torch CUDA:", torch.version.cuda)
print("CUDA available:", torch.cuda.is_available())
print("GPU:", torch.cuda.get_device_name(0) if torch.cuda.is_available() else "NONE")
assert torch.cuda.is_available()
assert str(torch.version.cuda or "").startswith("13."), "CUDA 13 PyTorch required for this saved 5090 path"
x=torch.randn((128,128), device="cuda")
print("CUDA probe:", float((x@x).mean()))
PYCODE
green "  ✓ CUDA 13 stack"

# -----------------------------------------------------------------------------
# 4. Required custom nodes
# -----------------------------------------------------------------------------
echo "[4/10] Custom nodes"

clone_or_update(){
  local repo="$1" dest="$2"
  if [[ ! -d "$dest/.git" ]]; then
    rm -rf "$dest"
    git clone --depth 1 "$repo" "$dest"
  else
    git -C "$dest" pull --ff-only
  fi
  if [[ -f "$dest/requirements.txt" ]]; then
    "$PIP" install -q -r "$dest/requirements.txt"
  fi
}

clone_or_update "$SLA_REPO" "$COMFY/custom_nodes/ComfyUI-PlagueKind-Nodes-only-sparse"
clone_or_update "$MAINODES_REPO" "$COMFY/custom_nodes/ComfyUI-MAINodes"
clone_or_update "$FASTVAE_REPO" "$COMFY/custom_nodes/ComfyUI-MiniMax-H3-MotionCache-FastVAE"
clone_or_update "$FACEREFINE_REPO" "$COMFY/custom_nodes/ComfyUI-H3-FaceRefine"
clone_or_update "$VHS_REPO" "$COMFY/custom_nodes/ComfyUI-VideoHelperSuite"
clone_or_update "$IMPACT_REPO" "$COMFY/custom_nodes/ComfyUI-Impact-Pack"

# FaceRefine's example workflow uses MiniMaxH3NativeAudioLock. The upstream
# repository contains that node as a subdirectory, so stage it separately
# without replacing the rest of this environment.
AUDIOLOCK_STAGE="$STATE_DIR/MiniMax-H3-NativeAudio-MusicVideo-Workflow"
if [[ ! -d "$AUDIOLOCK_STAGE/.git" ]]; then
  rm -rf "$AUDIOLOCK_STAGE"
  git clone --depth 1 "$AUDIOLOCK_REPO" "$AUDIOLOCK_STAGE"
else
  git -C "$AUDIOLOCK_STAGE" pull --ff-only
fi
rm -rf "$COMFY/custom_nodes/ComfyUI-H3-NativeAudioLock"
cp -a "$AUDIOLOCK_STAGE/custom_nodes/ComfyUI-H3-NativeAudioLock" "$COMFY/custom_nodes/ComfyUI-H3-NativeAudioLock"
if [[ -f "$COMFY/custom_nodes/ComfyUI-H3-NativeAudioLock/requirements.txt" ]]; then
  "$PIP" install -q -r "$COMFY/custom_nodes/ComfyUI-H3-NativeAudioLock/requirements.txt"
fi

# Do not install a second onnxruntime variant. FaceRefine upstream warns that
# having CPU and GPU variants together can hide CUDAExecutionProvider.
"$PY" - <<'PYCODE'
try:
    import onnxruntime as ort
    print("onnxruntime providers:", ort.get_available_providers())
except Exception as e:
    print("onnxruntime probe:", repr(e))
PYCODE

green "  ✓ SLA + MAINodes + FastVAE + FaceRefine + VHS + Impact-Pack + NativeAudioLock"

# -----------------------------------------------------------------------------
# 5. Verified downloader
# -----------------------------------------------------------------------------
verified_download(){
  local label="$1" url="$2" dest="$3" sha="$4" min_bytes="$5"
  mkdir -p "$(dirname "$dest")"

  if [[ -s "$dest" ]]; then
    size="$(stat -c%s "$dest")"
    if (( size >= min_bytes )); then
      got="$(sha256sum "$dest" | awk '{print $1}')"
      if [[ "$got" == "$sha" ]]; then
        echo "  [SKIP verified] $label"
        return 0
      fi
    fi
    yellow "  Existing $label is incomplete or checksum-mismatched; redownloading."
    rm -f "$dest" "$dest.aria2"
  fi

  echo "  [DOWNLOAD] $label"
  aria2c -c -x16 -s16 -k16M --file-allocation=none \
    --auto-file-renaming=false --allow-overwrite=true \
    --max-tries=12 --retry-wait=10 --summary-interval=15 \
    --dir "$(dirname "$dest")" --out "$(basename "$dest")" "$url"

  [[ -s "$dest" ]] || die "Download failed: $label"
  size="$(stat -c%s "$dest")"
  (( size >= min_bytes )) || die "$label too small: $size"
  got="$(sha256sum "$dest" | awk '{print $1}')"
  [[ "$got" == "$sha" ]] || die "$label SHA256 mismatch: $got"
  green "  ✓ $label"
}

# -----------------------------------------------------------------------------
# 6. Model files
# -----------------------------------------------------------------------------
echo "[5/10] Fused model"
verified_download "Fused H3 model" "$MODEL_URL" \
  "$COMFY/models/diffusion_models/$MODEL" "$MODEL_SHA" 20900000000

echo "[6/10] Text encoder + VAEs"
verified_download "Qwen3VL text encoder" "$TEXT_URL" \
  "$COMFY/models/text_encoders/$TEXT" "$TEXT_SHA" 14000000000
verified_download "INT8 ConvRot video VAE" "$VIDEO_VAE_URL" \
  "$COMFY/models/vae/$VIDEO_VAE" "$VIDEO_VAE_SHA" 3100000000
verified_download "FP32 audio VAE" "$AUDIO_VAE_URL" \
  "$COMFY/models/vae/$AUDIO_VAE" "$AUDIO_VAE_SHA" 500000000

mkdir -p "$COMFY/models/ultralytics/bbox"
verified_download "FaceRefine YOLO face detector" "$FACE_DETECTOR_URL" \
  "$COMFY/models/ultralytics/bbox/$FACE_DETECTOR" "$FACE_DETECTOR_SHA" 50000000

# -----------------------------------------------------------------------------
# 7. Official MATLOWAI workflows
# -----------------------------------------------------------------------------
echo "[7/10] I2V / Ref2VA workflows"

curl -fL --retry 8 --retry-all-errors --retry-delay 5 \
  "$WF_I2V_URL" -o "$WF_DIR/$WF_I2V"
curl -fL --retry 8 --retry-all-errors --retry-delay 5 \
  "$WF_REF_URL" -o "$WF_DIR/$WF_REF"

"$PY" - "$WF_DIR/$WF_I2V" "$WF_DIR/$WF_REF" "$MODEL" "$TEXT" "$VIDEO_VAE" "$AUDIO_VAE" <<'PYCODE'
import json, sys
for p in sys.argv[1:3]:
    d=json.load(open(p, encoding="utf-8"))
    s=json.dumps(d)
    for required in sys.argv[3:]:
        if required not in s:
            raise SystemExit(f"{p}: required file name not present: {required}")
    print("validated:", p)
PYCODE

# Create a separate 8-step Ref2VA QUALITY workflow. The official 4-step graph
# stays untouched so FAST and QUALITY can be compared with the same seed/prompt.
WF_REF_QUALITY="04_FUSED_H3_REF2VA_8STEP_QUALITY_SLA.json"

"$PY" - "$WF_DIR/$WF_REF" "$WF_DIR/$WF_REF_QUALITY" <<'PYCODE'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src, encoding="utf-8"))
changed = 0
for n in d.get("nodes", []):
    if n.get("type") == "BasicScheduler":
        vals = n.get("widgets_values", [])
        if len(vals) < 3:
            raise SystemExit(f"{src}: BasicScheduler widgets_values shape is unexpected: {vals!r}")
        if vals[0] != "simple":
            raise SystemExit(f"{src}: expected scheduler 'simple', got {vals[0]!r}")
        if vals[1] != 4:
            raise SystemExit(f"{src}: expected official 4-step baseline, got steps={vals[1]!r}")
        vals[1] = 8
        n["widgets_values"] = vals
        n["title"] = "BasicScheduler — QUALITY 8 steps"
        changed += 1
if changed != 1:
    raise SystemExit(f"{src}: expected exactly one BasicScheduler node, found {changed}")
with open(dst, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
print("8-step QUALITY workflow:", dst)
PYCODE

# Create optional FastVAE workflow copies. The original MATLOWAI workflows stay
# untouched so there is always a reference/fallback path.
WF_I2V_FAST="01_FUSED_H3_I2V_FL2V_4STEP_SLA_FASTVAE.json"
WF_REF_FAST="02_FUSED_H3_REF2VA_4STEP_SLA_FASTVAE.json"

"$PY" - "$WF_DIR/$WF_I2V" "$WF_DIR/$WF_I2V_FAST" "$WF_DIR/$WF_REF" "$WF_DIR/$WF_REF_FAST" <<'PYCODE'
import json, sys

def make_fast(src, dst):
    d=json.load(open(src, encoding="utf-8"))
    changed=0
    for n in d.get("nodes", []):
        if n.get("type") == "VAEDecode":
            n["type"] = "MiniMaxH3FastVAEDecode"
            n["title"] = "MiniMax H3 Fast VAE Decode (benchmark)"
            props=n.setdefault("properties", {})
            props["Node name for S&R"] = "MiniMaxH3FastVAEDecode"
            n["widgets_values"] = [4]
            changed += 1
    if changed != 1:
        raise SystemExit(f"{src}: expected exactly one video VAEDecode node, found {changed}")
    with open(dst, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
    print("FastVAE workflow:", dst)

make_fast(sys.argv[1], sys.argv[2])
make_fast(sys.argv[3], sys.argv[4])
PYCODE

# Copy FaceRefine's non-SAM (RECT) example as a separate workflow.
# We intentionally do NOT splice it into Ref2VA: generate first, then refine.
FACEREFINE_WF="03_H3_FACEREFINE_RECT_EXPERIMENTAL.json"
FACEREFINE_SRC="$(find "$COMFY/custom_nodes/ComfyUI-H3-FaceRefine/example_workflows" -maxdepth 1 -type f -name '*.json' 2>/dev/null \
  | grep -Ei 'auto|rect' | grep -vi 'manual' | head -1 || true)"
if [[ -z "$FACEREFINE_SRC" ]]; then
  FACEREFINE_SRC="$(find "$COMFY/custom_nodes/ComfyUI-H3-FaceRefine/example_workflows" -maxdepth 1 -type f -name '*.json' 2>/dev/null \
    | head -1 || true)"
fi
if [[ -z "$FACEREFINE_SRC" ]]; then
  die "FaceRefine RECT example workflow was not found under example_workflows/"
fi
cp -f "$FACEREFINE_SRC" "$WF_DIR/$FACEREFINE_WF"
"$PY" - "$WF_DIR/$FACEREFINE_WF" <<'PYCODE'
import json, sys
p=sys.argv[1]
d=json.load(open(p, encoding="utf-8"))
s=json.dumps(d)
markers=("H3 Face Track", "H3Face", "Face Refine", "FaceRefine")
if not any(m.lower() in s.lower() for m in markers):
    raise SystemExit(f"{p}: does not look like a FaceRefine workflow")
print("FaceRefine workflow:", p)
PYCODE

green "  ✓ workflows installed (4-step standard + 8-step QUALITY + FastVAE + separate FaceRefine RECT)"

# -----------------------------------------------------------------------------
# 8. Safe port handoff
# -----------------------------------------------------------------------------
echo "[8/10] Port $PORT handoff"

pids="$(lsof -ti tcp:"$PORT" 2>/dev/null || true)"
if [[ -n "$pids" ]]; then
  for pid in $pids; do
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
    if [[ "$cmd" == *"main.py"* && "$cwd" == "$ROOT"/ComfyUI* ]]; then
      echo "  stopping existing ComfyUI PID $pid ($cwd)"
      kill "$pid" 2>/dev/null || true
    else
      die "Port $PORT is occupied by unrelated PID $pid ($cwd)"
    fi
  done
  for _ in $(seq 1 30); do
    [[ -z "$(lsof -ti tcp:"$PORT" 2>/dev/null || true)" ]] && break
    sleep 1
  done
fi

[[ -z "$(lsof -ti tcp:"$PORT" 2>/dev/null || true)" ]] || die "Could not free port $PORT"

# -----------------------------------------------------------------------------
# 9. Start and validate
# -----------------------------------------------------------------------------
echo "[9/10] Start ComfyUI"

RUNTIME_LOG="$RUNTIME_DIR/comfy_$(date +%Y%m%d_%H%M%S).log"
cd "$COMFY"
nohup "$PY" main.py \
  --listen 0.0.0.0 \
  --port "$PORT" \
  --preview-method auto \
  --enable-cors-header \
  --reserve-vram 4 \
  --cache-none \
  > "$RUNTIME_LOG" 2>&1 &
PID=$!
echo "$PID" > "$COMFY/h3_fused.pid"

ready=0
for _ in $(seq 1 180); do
  if ! kill -0 "$PID" 2>/dev/null; then
    tail -160 "$RUNTIME_LOG" || true
    die "ComfyUI process exited during startup"
  fi
  if curl -fsS "http://127.0.0.1:$PORT/system_stats" >/tmp/h3_fused_system_stats.json 2>/dev/null; then
    ready=1
    break
  fi
  sleep 1
done

[[ "$ready" == "1" ]] || {
  tail -160 "$RUNTIME_LOG" || true
  die "ComfyUI did not become ready within 180 seconds"
}

# Validate required node names from object_info.
curl -fsS "http://127.0.0.1:$PORT/object_info" -o /tmp/h3_fused_object_info.json
"$PY" - <<'PYCODE'
import json
d=json.load(open("/tmp/h3_fused_object_info.json"))
names=set(d)
required_core=["MiniMaxH3ImageToVideo","MiniMaxH3ReferenceToVideo","UNETLoader"]
missing=[x for x in required_core if x not in names]
if missing:
    raise SystemExit("Missing required core nodes: " + ", ".join(missing))
sla=[x for x in names if "SLA" in x.upper() and "H3" in x.upper()]
print("H3 SLA-like nodes:", sla[:20])
if not sla:
    raise SystemExit("H3 SLA attention node was not registered")
if "MiniMaxH3FastVAEDecode" not in names:
    raise SystemExit("MiniMaxH3FastVAEDecode was not registered")
print("Fast VAE Decode: MiniMaxH3FastVAEDecode")
face_nodes=[x for x in names if ("face" in x.lower() and ("track" in x.lower() or "stitch" in x.lower() or "refine" in x.lower()))]
print("FaceRefine-like nodes:", face_nodes[:20])
if len(face_nodes) < 2:
    raise SystemExit("FaceRefine nodes were not registered")
if "MiniMaxH3NativeAudioLock" not in names:
    raise SystemExit("MiniMaxH3NativeAudioLock was not registered")
print("Required MiniMax H3 + FaceRefine nodes OK")
PYCODE

green "  ✓ ComfyUI + H3 + Ref2VA + SLA + FastVAE + FaceRefine registered"

# -----------------------------------------------------------------------------
# 10. Launchers / summary
# -----------------------------------------------------------------------------
echo "[10/10] Save launchers"

cat > "$COMFY/start_h3_fused.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$COMFY"
exec "$PY" main.py --listen 0.0.0.0 --port "$PORT" --preview-method auto --enable-cors-header --reserve-vram 4 --cache-none
EOF
chmod +x "$COMFY/start_h3_fused.sh"

cat > "$COMFY/restart_h3_fused.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
pids=\$(lsof -ti tcp:"$PORT" 2>/dev/null || true)
[[ -z "\$pids" ]] || kill \$pids 2>/dev/null || true
sleep 2
cd "$COMFY"
nohup "$PY" main.py --listen 0.0.0.0 --port "$PORT" --preview-method auto --enable-cors-header --reserve-vram 4 --cache-none > "$RUNTIME_DIR/comfy_restart.log" 2>&1 &
echo "Started H3 Fused on port $PORT"
EOF
chmod +x "$COMFY/restart_h3_fused.sh"

trap - ERR
trap - EXIT

echo
echo "================================================================="
green " READY — SETUP #5 FUSED TURBO / REF2VA CANDIDATE v3"
echo "================================================================="
echo "Environment:"
echo "  $COMFY"
echo
echo "Model:"
echo "  $MODEL"
echo
echo "Workflows:"
echo "  $WF_I2V   <- I2V / FL2V 4-step SLA"
echo "  $WF_REF   <- Ref2VA 4-step SLA (FAST / reference)"
echo "  $WF_REF_QUALITY <- Ref2VA 8-step SLA (QUALITY; same graph, only steps 4 -> 8)"
echo "  $WF_I2V_FAST   <- I2V / FL2V 4-step SLA + FastVAE benchmark"
echo "  $WF_REF_FAST   <- Ref2VA 4-step SLA + FastVAE benchmark"
echo "  $FACEREFINE_WF <- SEPARATE FaceRefine RECT post-process workflow"
echo
echo "Recommended modes:"
echo "  FAST:    Ref2VA 4 steps"
echo "  QUALITY: Ref2VA 8 steps"
echo "  sampler: res_multistep"
echo "  scheduler: simple"
echo "  video shift: 12"
echo "  audio shift: 3"
echo "  SLA: sparsity 0.90 / block 64 / protect audio ON"
echo "  FastVAE: tile_batch_size 4 (benchmark only; compare against standard VAEDecode)"
echo "  FaceRefine: start with RECT workflow; keep it separate from Ref2VA generation"
echo "  Face detector: $FACE_DETECTOR"
echo
echo "Setup log:"
echo "  $SETUP_LOG"
echo "Runtime log:"
echo "  $RUNTIME_LOG"
echo
echo "Open RunPod port 8188. Use 02_* for FAST or 04_* for QUALITY; then load 03_H3_FACEREFINE_RECT_EXPERIMENTAL.json only when face post-refine is needed."
echo "================================================================="
