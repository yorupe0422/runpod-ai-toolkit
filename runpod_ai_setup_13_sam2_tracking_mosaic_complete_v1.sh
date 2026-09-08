#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# #13 SAM2 Tracking Mosaic (COMPLETE v1)
# Fresh isolated RunPod / ComfyUI environment
#
# Goal:
#   Simple video-wide tracking mosaic workflow.
#   User-facing controls should be limited to roughly:
#     1) Load Video
#     2) Initial target selection on the first frame
#     3) Mosaic Size
#     4) Mask Expand
#     5) Output MP4 with original audio preserved
#
# Design:
#   - Video load/save: VideoHelperSuite
#   - Tracking / propagation: SAM2 (video segmentor)
#   - Optional point / coordinate assistance: KJNodes
#   - Masked mosaic effect: ComfyUI-Mosaic
#   - Utility / mask helpers: ComfyUI_essentials
#
# Notes:
#   * This v1 focuses on building a clean independent environment.
#   * A minimal operation guide file is created alongside the environment.
#   * Because custom-node ecosystems move fast, treat this as a candidate
#     until it is verified on a fresh Pod.
# ============================================================

ROOT="/workspace/runpod-slim"
COMFY="${ROOT}/ComfyUI-SAM2MosaicSimple"
PORT="${PORT:-8188}"
BACKUP_EXISTING="${BACKUP_EXISTING:-0}"

export HF_HOME="${HF_HOME:-${ROOT}/.cache/huggingface}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-${HF_HOME}/hub}"
export HF_XET_CACHE="${HF_XET_CACHE:-${HF_HOME}/xet}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${ROOT}/.cache}"
export TMPDIR="${TMPDIR:-${ROOT}/.tmp}"

mkdir -p "$ROOT" "$HF_HOME" "$HUGGINGFACE_HUB_CACHE" "$HF_XET_CACHE" "$XDG_CACHE_HOME" "$TMPDIR"

LOGDIR="${ROOT}/setup_logs"
STAMP="$(date +%Y%m%d_%H%M%S)"
LOG="${LOGDIR}/setup_13_sam2_tracking_mosaic_complete_v1_${STAMP}.log"
mkdir -p "$LOGDIR"
exec > >(tee -a "$LOG") 2>&1

echo "============================================================"
echo "[#13 COMPLETE v1] SAM2 Tracking Mosaic"
echo "Time: $(date -Is)"
echo "Root: $ROOT"
echo "ComfyUI: $COMFY"
echo "Port: $PORT"
echo "Log: $LOG"
echo "============================================================"

command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi || true

apt_install_if_missing() {
  local need=0
  for x in git wget curl ffmpeg python3; do
    command -v "$x" >/dev/null 2>&1 || need=1
  done
  if [[ "$need" == "1" ]]; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      git wget curl ffmpeg python3 python3-venv python3-pip
  fi
}

clone_or_update() {
  local url="$1"
  local dst="$2"
  if [[ -d "$dst/.git" ]]; then
    echo "[GIT] update: $(basename "$dst")"
    git -C "$dst" fetch --all --prune
    git -C "$dst" reset --hard origin/HEAD || git -C "$dst" pull --ff-only || true
  else
    echo "[GIT] clone: $url"
    git clone --depth 1 "$url" "$dst"
  fi
}

install_req_if_exists() {
  local d="$1"
  if [[ -f "$d/requirements.txt" ]]; then
    echo "[PIP] requirements: $d"
    "$PY" -m pip install -r "$d/requirements.txt"
  fi
}

wait_http() {
  local url="$1"
  local tries="${2:-150}"
  local sleep_s="${3:-2}"
  for ((i=1;i<=tries;i++)); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      echo "[OK] HTTP ready: $url"
      return 0
    fi
    if (( i % 10 == 0 )); then
      echo "[WAIT] $url ($i/$tries)"
    fi
    sleep "$sleep_s"
  done
  return 1
}

apt_install_if_missing

if [[ -e "$COMFY" ]]; then
  if [[ "$BACKUP_EXISTING" == "1" ]]; then
    BAK="${COMFY}.backup_${STAMP}"
    echo "[INFO] Existing environment -> $BAK"
    mv "$COMFY" "$BAK"
  else
    echo "[INFO] Removing existing #13 environment: $COMFY"
    rm -rf "$COMFY"
  fi
fi

echo "[1/8] Clone ComfyUI"
git clone --depth 1 https://github.com/Comfy-Org/ComfyUI.git "$COMFY"
cd "$COMFY"

echo "[2/8] Create venv on top of RunPod/system Torch"
python3 -m venv --system-site-packages .venv
PY="$COMFY/.venv/bin/python"
"$PY" -m pip install -U pip wheel "setuptools<82"
"$PY" -m pip install -r requirements.txt
"$PY" -m pip install -U huggingface_hub hf_xet requests pillow imageio-ffmpeg opencv-python hydra-core omegaconf loguru

echo "[INFO] Base Torch stack:"
"$PY" - <<'PY'
import torch
print("torch:", torch.__version__)
print("torch file:", torch.__file__)
print("cuda:", torch.version.cuda)
print("cuda available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("gpu:", torch.cuda.get_device_name(0))
PY

mkdir -p custom_nodes input output user/default/workflows models/sam2

echo "[3/8] Install custom nodes"
clone_or_update https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git \
  "$COMFY/custom_nodes/ComfyUI-VideoHelperSuite"
clone_or_update https://github.com/kijai/ComfyUI-segment-anything-2.git \
  "$COMFY/custom_nodes/ComfyUI-segment-anything-2"
clone_or_update https://github.com/1038lab/ComfyUI-Mosaic.git \
  "$COMFY/custom_nodes/ComfyUI-Mosaic"
clone_or_update https://github.com/kijai/ComfyUI-KJNodes.git \
  "$COMFY/custom_nodes/ComfyUI-KJNodes"
clone_or_update https://github.com/cubiq/ComfyUI_essentials.git \
  "$COMFY/custom_nodes/ComfyUI_essentials"

for d in \
  "$COMFY/custom_nodes/ComfyUI-VideoHelperSuite" \
  "$COMFY/custom_nodes/ComfyUI-segment-anything-2" \
  "$COMFY/custom_nodes/ComfyUI-Mosaic" \
  "$COMFY/custom_nodes/ComfyUI-KJNodes" \
  "$COMFY/custom_nodes/ComfyUI_essentials"
do
  install_req_if_exists "$d"
done

echo "[CHECK] Custom-node installation must NOT shadow RunPod Torch"
"$PY" - <<'PY'
import torch
print("torch:", torch.__version__)
print("torch file:", torch.__file__)
if "/.venv/" in torch.__file__:
    raise SystemExit(
        "ERROR: custom-node requirements installed a private Torch inside .venv. "
        "Abort instead of silently changing the known-good RunPod Torch stack."
    )
PY

echo "[4/8] Create operation guide"
cat > "$COMFY/user/default/workflows/13A_SAM2_TRACKING_MOSAIC_SIMPLE_GUIDE.txt" <<'TXT'
#13 SAM2 Tracking Mosaic — simple operation guide

Goal:
- Apply a mosaic to one tracked subject/object across the whole video.
- Preserve original audio when exporting MP4.

Recommended node groups:
1) VHS_LoadVideo
2) (Down)Load SAM2Model
   - model: sam2.1_hiera_tiny.safetensors (fast test) or sam2.1_hiera_small.safetensors
   - segmentor: video
   - device: cuda
   - precision: fp16
3) Select the target on the first frame
   - Use points / box helper nodes from KJNodes, or any coordinate/points helper you prefer.
4) Sam2VideoSegmentationAddPoints
5) Sam2VideoSegmentation
6) Expand/Grow mask (mask expand control)
7) MosaicCreator
   - mosaic_type: pixelation
   - block_size: user control for mosaic size
   - intensity: 1.0
8) VHS_VideoCombine
   - Use the processed frames
   - Reuse the source video's audio if the node exposes audio input/output in your installed VHS version

Suggested user-facing controls:
- source video
- target selection / first-frame points
- mosaic block_size (e.g. 12-40)
- mask expand (e.g. 0-24)
- output fps / save path as needed

Notes:
- If tracking is unstable, place more positive points on the object in frame 1.
- For large/fast-moving subjects, start with sam2.1_hiera_small.
- For quick smoke tests, use short clips first.
TXT

cat > "$COMFY/input/README_FIRST.txt" <<'TXT'
Put the source video in this input folder or upload through the ComfyUI UI.
TXT

echo "[5/8] Create launchers"
cat > "$ROOT/start_sam2_tracking_mosaic.sh" <<EOF2
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$ROOT"
COMFY="$COMFY"
PORT="\${PORT:-$PORT}"

export HF_HOME="\${HF_HOME:-\$ROOT/.cache/huggingface}"
export HUGGINGFACE_HUB_CACHE="\${HUGGINGFACE_HUB_CACHE:-\$HF_HOME/hub}"
export HF_XET_CACHE="\${HF_XET_CACHE:-\$HF_HOME/xet}"
export XDG_CACHE_HOME="\${XDG_CACHE_HOME:-\$ROOT/.cache}"
export TMPDIR="\${TMPDIR:-\$ROOT/.tmp}"
mkdir -p "\$HF_HOME" "\$HUGGINGFACE_HUB_CACHE" "\$HF_XET_CACHE" "\$XDG_CACHE_HOME" "\$TMPDIR"

cd "\$COMFY"
source .venv/bin/activate
exec python main.py --listen 0.0.0.0 --port "\$PORT" --preview-method auto
EOF2
chmod +x "$ROOT/start_sam2_tracking_mosaic.sh"

cat > "$ROOT/restart_sam2_tracking_mosaic.sh" <<EOF2
#!/usr/bin/env bash
set -Eeuo pipefail
PORT="\${PORT:-$PORT}"
pkill -f "python.*main.py.*--port[ =]\${PORT}" 2>/dev/null || true
pkill -f "$COMFY/main.py" 2>/dev/null || true
if command -v fuser >/dev/null 2>&1; then
  fuser -k "\${PORT}/tcp" 2>/dev/null || true
fi
sleep 3
exec "$ROOT/start_sam2_tracking_mosaic.sh"
EOF2
chmod +x "$ROOT/restart_sam2_tracking_mosaic.sh"

echo "[6/8] Static checks"
"$PY" - <<'PY'
from pathlib import Path
import json
root = Path("/workspace/runpod-slim/ComfyUI-SAM2MosaicSimple")
checks = [
    root/"custom_nodes/ComfyUI-VideoHelperSuite",
    root/"custom_nodes/ComfyUI-segment-anything-2",
    root/"custom_nodes/ComfyUI-Mosaic",
    root/"custom_nodes/ComfyUI-KJNodes",
    root/"custom_nodes/ComfyUI_essentials",
    root/"user/default/workflows/13A_SAM2_TRACKING_MOSAIC_SIMPLE_GUIDE.txt",
]
for p in checks:
    if not p.exists():
        raise SystemExit(f"[FAIL] missing: {p}")
    print(f"[OK] {p}")
PY

echo "[7/8] Start ComfyUI"
pkill -f "python.*main.py.*--port[ =]${PORT}" 2>/dev/null || true
pkill -f "$COMFY/main.py" 2>/dev/null || true
if command -v fuser >/dev/null 2>&1; then
  fuser -k "${PORT}/tcp" 2>/dev/null || true
fi
sleep 3

SERVER_LOG="${LOGDIR}/comfy_13_sam2_tracking_mosaic_complete_v1_${STAMP}.log"
cd "$COMFY"
nohup "$PY" main.py --listen 0.0.0.0 --port "$PORT" --preview-method auto \
  > "$SERVER_LOG" 2>&1 &
PID=$!

echo "[INFO] ComfyUI PID: $PID"
echo "[INFO] Server log: $SERVER_LOG"
echo "[INFO] Waiting for /object_info (up to ~5 min)..."

if ! wait_http "http://127.0.0.1:${PORT}/object_info" 150 2; then
  echo "[FAIL] ComfyUI did not become ready."
  tail -160 "$SERVER_LOG" || true
  exit 1
fi

if ! kill -0 "$PID" >/dev/null 2>&1; then
  echo "[FAIL] New #13 ComfyUI process died; another process may own port $PORT."
  tail -160 "$SERVER_LOG" || true
  exit 1
fi

CMDLINE="$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null || true)"
echo "[INFO] PID cmdline: $CMDLINE"
if [[ "$CMDLINE" != *"main.py"* || "$CMDLINE" != *"--port $PORT"* ]]; then
  echo "[FAIL] PID $PID is not the intended #13 launch."
  exit 1
fi
echo "[OK] Verified new #13 ComfyUI PID $PID owns the intended launch command."

echo "[8/8] Verify key nodes through /object_info"
"$PY" - <<'PY'
import json, urllib.request
url = 'http://127.0.0.1:8188/object_info'
with urllib.request.urlopen(url, timeout=30) as r:
    obj = json.load(r)
keys = set(obj.keys())
required = [
    'DownloadAndLoadSAM2Model',
    'Sam2VideoSegmentationAddPoints',
    'Sam2VideoSegmentation',
    'MosaicCreator',
]
missing = [k for k in required if k not in keys]
print('[INFO] Required-node probe:')
for k in required:
    print('  -', k, 'OK' if k in keys else 'MISSING')
if missing:
    print('[WARN] Some required nodes are missing from /object_info:')
    for k in missing:
        print('  -', k)
    print('[WARN] Check server log and node imports. Candidate environment may still need a v2 patch.')
else:
    print('[OK] Core SAM2 + Mosaic nodes are loaded.')

vhs_candidates = [k for k in sorted(keys) if 'VHS' in k or 'Video' in k]
print('[INFO] Example video-related nodes (first 25):')
for k in vhs_candidates[:25]:
    print('  -', k)
PY

echo
echo "============================================================"
echo "[SUCCESS] #13 COMPLETE v1 environment is up."
echo
echo "Open RunPod proxy for port: $PORT"
echo
echo "Environment:"
echo "  $COMFY"
echo
echo "Guide file:"
echo "  $COMFY/user/default/workflows/13A_SAM2_TRACKING_MOSAIC_SIMPLE_GUIDE.txt"
echo
echo "Launch:"
echo "  $ROOT/start_sam2_tracking_mosaic.sh"
echo "Restart:"
echo "  $ROOT/restart_sam2_tracking_mosaic.sh"
echo
echo "Setup log:"
echo "  $LOG"
echo "Server log:"
echo "  $SERVER_LOG"
echo "============================================================"
