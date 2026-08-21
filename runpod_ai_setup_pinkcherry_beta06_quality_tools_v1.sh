#!/usr/bin/env bash
set -Eeuo pipefail

# Add-on for the standalone PinkCherry beta-0.6 environment.
# Installs only input-quality tools; it does not replace the PinkCherry model.

ROOT="/workspace/runpod-slim"
COMFY="$ROOT/ComfyUI-PinkCherry-beta06"
PORT="${PORT:-8188}"
LOG="$ROOT/comfyui-pinkcherry-beta06.log"
NODE="$COMFY/custom_nodes/facerestore_cf"
WORKFLOW="PinkCherry_H3_beta06_FAST_QA_16STEP.json"
WORKFLOW_URL="https://raw.githubusercontent.com/yorupe0422/runpod-ai-toolkit/main/$WORKFLOW"

green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[0;33m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
die(){ red "[FAILED] $*"; exit 1; }
on_error(){ local rc=$?; red "QUALITY ADD-ON FAILED (exit=$rc, line=${BASH_LINENO[0]:-unknown})"; exit "$rc"; }
trap on_error ERR

download(){
  local url="$1"
  local target="$2"
  local min_bytes="$3"
  mkdir -p "$(dirname "$target")"
  if [[ -s "$target" ]] && [[ "$(stat -c%s "$target")" -ge "$min_bytes" ]]; then
    echo "  [OK] $(basename "$target")"
    return 0
  fi
  echo "  [DL] $(basename "$target")"
  curl -fL -C - --retry 12 --retry-all-errors --retry-delay 15 --connect-timeout 30 \
    -o "$target.part" "$url"
  [[ -s "$target.part" ]] && [[ "$(stat -c%s "$target.part")" -ge "$min_bytes" ]] || die "Incomplete download: $target"
  mv -f "$target.part" "$target"
}

echo "============================================================"
echo " PINKCHERRY beta-0.6 — QUALITY TOOLS ADD-ON v1"
echo "============================================================"

[[ -x "$COMFY/.venv/bin/python" ]] || die "Base PinkCherry environment was not found: $COMFY"
VENV_PY="$COMFY/.venv/bin/python"

echo "[1/5] Install CodeFormer face-repair node"
if [[ ! -f "$NODE/__init__.py" ]]; then
  git clone --depth 1 https://github.com/mav-rik/facerestore_cf.git "$NODE"
fi
if [[ "$($VENV_PY -c 'import sys; print(sys.version_info >= (3, 12))')" == "True" ]]; then
  REQ="$NODE/requirements_312.txt"
else
  REQ="$NODE/requirements.txt"
fi
MARKER="$NODE/.pinkbeta_requirements_ok"
if [[ ! -f "$MARKER" ]]; then
  "$VENV_PY" -m pip install -q -r "$REQ"
  touch "$MARKER"
fi

echo "[2/5] Download lightweight input-quality models"
download "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth" \
  "$COMFY/models/upscale_models/RealESRGAN_x2plus.pth" 60000000
download "https://github.com/sczhou/CodeFormer/releases/download/v0.1.0/codeformer.pth" \
  "$COMFY/models/facerestore_models/codeformer.pth" 300000000
download "https://github.com/xinntao/facexlib/releases/download/v0.1.0/detection_Resnet50_Final.pth" \
  "$COMFY/models/facedetection/detection_Resnet50_Final.pth" 90000000
download "https://github.com/sczhou/CodeFormer/releases/download/v0.1.0/parsing_parsenet.pth" \
  "$COMFY/models/facedetection/parsing_parsenet.pth" 10000000

echo "[3/5] Install fast QA workflow"
mkdir -p "$COMFY/user/default/workflows"
curl -fL --retry 8 --retry-all-errors --retry-delay 10 \
  "$WORKFLOW_URL?v=$(date +%s)" -o "$COMFY/user/default/workflows/$WORKFLOW"
grep -q 'FAST_QA_16STEP' "$COMFY/user/default/workflows/$WORKFLOW" || die "GitHub workflow is not the expected fast QA workflow"

echo "[4/5] Restart PinkCherry on port $PORT"
pids="$(lsof -ti tcp:$PORT 2>/dev/null || true)"
[[ -z "$pids" ]] || kill $pids 2>/dev/null || true
sleep 2
still="$(lsof -ti tcp:$PORT 2>/dev/null || true)"
[[ -z "$still" ]] || kill -9 $still 2>/dev/null || true
cd "$COMFY"
nohup "$VENV_PY" main.py --listen 0.0.0.0 --port "$PORT" --preview-method auto \
  --enable-cors-header --reserve-vram 4 --cache-none > "$LOG" 2>&1 &
PID=$!

echo "[5/5] Verify required nodes"
ready=0
for _ in $(seq 1 180); do
  if ! kill -0 "$PID" 2>/dev/null; then tail -120 "$LOG" || true; die "ComfyUI exited during startup"; fi
  if curl --max-time 3 -fsS "http://127.0.0.1:$PORT/object_info" > /tmp/pinkbeta_quality_object_info.json 2>/dev/null; then ready=1; break; fi
  sleep 1
done
[[ "$ready" == 1 ]] || die "Startup timeout"
"$VENV_PY" - <<'PY'
import json
d=json.load(open('/tmp/pinkbeta_quality_object_info.json'))
required=['UpscaleModelLoader','ImageUpscaleWithModel','FaceRestoreModelLoader','FaceRestoreCFWithModel','MiniMaxH3ImageToVideo']
missing=[n for n in required if n not in d]
if missing: raise SystemExit('Missing nodes: '+', '.join(missing))
print('  required quality nodes visible')
PY

trap - ERR
echo "============================================================"
green " PINKCHERRY FAST QA + INPUT REPAIR READY"
echo "============================================================"
echo "Workflow : $WORKFLOW"
echo "Test     : 512x512 / 124 frames (~5 sec) / 16 steps"
echo "Input    : RealESRGAN x2 -> CodeFormer 0.90 -> 512x512"
echo "Port     : $PORT"
echo "Log      : $LOG"
