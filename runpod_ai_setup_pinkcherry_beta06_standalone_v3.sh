#!/usr/bin/env bash
set -Eeuo pipefail

# PinkCherry beta-0.6 FL2VA — fresh-Pod standalone setup (v3).
# Ref2VA and SETUP #5 are NOT prerequisites. Safe to rerun after interruption.
# Creates /workspace/runpod-slim/ComfyUI-PinkCherry-beta06 and leaves both
# /workspace/runpod-slim/ComfyUI and ComfyUI-Ref2VA untouched on disk.
# The server uses port 8188, so the currently running Ref2VA server is stopped
# only when the new FL2VA server is ready to start.

ROOT="/workspace/runpod-slim"
COMFY="$ROOT/ComfyUI-PinkCherry-beta06"
PORT="${PORT:-8188}"
LOG="$ROOT/comfyui-pinkcherry-beta06.log"

MODEL="PinkCherry_fl2va_MiniMax_H3_pruned_int8_convrot-beta-0.6.safetensors"
MODEL_URL="https://huggingface.co/SexGod1979/PinkCherry_MiniMax-H3/resolve/main/beta-0.6-fl2va/$MODEL?download=true"
MODEL_SHA256="0cb2812f061003d9f345186d58f1bafbf902c6ad2b4c064590b4fc4811634ad1"
MODEL_MIN_BYTES=19000000000

TEXT="qwen3vl-32B-MiniMax-H3-Q4_K_M.gguf"
VIDEO_VAE="minimax_h3_video_vae_fp16.safetensors"
AUDIO_VAE="minimax_h3_audio_vae_fp32.safetensors"
WORKFLOW="PinkCherry_H3_beta06_FL2VA_25STEP.json"
WORKFLOW_URL="https://raw.githubusercontent.com/yorupe0422/runpod-ai-toolkit/main/$WORKFLOW"
WORKFLOW_TMP="$ROOT/.pinkcherry_beta06_workflow.json"

green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[0;33m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
die(){ red "[FAILED] $*"; exit 1; }

on_error(){
  local rc=$?
  local line="${BASH_LINENO[0]:-unknown}"
  red "SETUP FAILED (exit=$rc, line=$line)"
  echo "Log: $LOG"
  exit "$rc"
}
trap on_error ERR

hf_curl(){
  local url="$1"
  local dest="$2"
  local auth=()
  [[ -n "${HF_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $HF_TOKEN")
  curl -fL -C - --retry 12 --retry-all-errors --retry-delay 20 --connect-timeout 30 \
    "${auth[@]}" -o "$dest" "$url"
}

ensure_support(){
  # Keep declarations separate: with `set -u`, Bash expands all assignments on
  # one `local` command before assigning `rel`, which would make `$rel` unset.
  local rel="$1"
  local url="$2"
  local min="$3"
  local target="$COMFY/models/$rel"
  mkdir -p "$(dirname "$target")"
  if [[ -s "$target" ]] && [[ "$(stat -Lc%s "$target")" -ge "$min" ]]; then return 0; fi
  rm -f "$target"
  for source_root in "$ROOT/ComfyUI-Ref2VA" "$ROOT/ComfyUI" "$ROOT/ComfyUI-H3"; do
    local source="$source_root/models/$rel"
    if [[ -s "$source" ]] && [[ "$(stat -Lc%s "$source")" -ge "$min" ]]; then
      ln -s "$source" "$target"
      echo "  [LINK] $(basename "$target")"
      return 0
    fi
  done
  echo "  [DL] $(basename "$target")"
  hf_curl "$url" "$target.part"
  [[ -s "$target.part" ]] && [[ "$(stat -c%s "$target.part")" -ge "$min" ]] || die "Incomplete support model: $target"
  mv -f "$target.part" "$target"
}

echo "============================================================"
echo " PinkCherry beta-0.6 FL2VA — FRESH POD SETUP v3"
echo "============================================================"

mkdir -p "$ROOT"

echo "[1/8] System tools"
if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || \
   ! command -v aria2c >/dev/null 2>&1 || ! command -v lsof >/dev/null 2>&1 || \
   ! command -v ffmpeg >/dev/null 2>&1; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    git curl ca-certificates aria2 lsof ffmpeg python3-venv
fi

echo "[2/8] Verify beta-0.6 workflow source"
curl -fL --retry 8 --retry-all-errors --retry-delay 10 \
  "$WORKFLOW_URL?v=$(date +%s)" -o "$WORKFLOW_TMP"
grep -q "$MODEL" "$WORKFLOW_TMP" || die "GitHub workflow is not the beta-0.6 workflow"

echo "[3/8] Create isolated ComfyUI"
if [[ ! -f "$COMFY/main.py" ]]; then
  if [[ -e "$COMFY" ]]; then
    backup="${COMFY}.incomplete.$(date +%Y%m%d-%H%M%S)"
    mv "$COMFY" "$backup"
    echo "  [BACKUP] $backup"
  fi
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
fi
grep -Rqs "MiniMaxH3ImageToVideo" "$COMFY/comfy_extras" || die "ComfyUI checkout lacks MiniMaxH3ImageToVideo"

if command -v python3.12 >/dev/null 2>&1; then PY="$(command -v python3.12)"; else PY="$(command -v python3)"; fi
if [[ ! -x "$COMFY/.venv/bin/python" ]]; then "$PY" -m venv --system-site-packages "$COMFY/.venv"; fi
VENV_PY="$COMFY/.venv/bin/python"
if [[ ! -f "$COMFY/.pinkbeta_core_ok" ]]; then
  "$VENV_PY" -m pip install -q --upgrade pip 'setuptools<82' wheel
  "$VENV_PY" -m pip install -q -r "$COMFY/requirements.txt"
  touch "$COMFY/.pinkbeta_core_ok"
fi
if [[ ! -f "$COMFY/custom_nodes/ComfyUI-GGUF/__init__.py" ]]; then
  git clone --depth 1 https://github.com/city96/ComfyUI-GGUF.git "$COMFY/custom_nodes/ComfyUI-GGUF"
fi
if [[ -f "$COMFY/custom_nodes/ComfyUI-GGUF/requirements.txt" && ! -f "$COMFY/custom_nodes/ComfyUI-GGUF/.pinkbeta_ok" ]]; then
  "$VENV_PY" -m pip install -q -r "$COMFY/custom_nodes/ComfyUI-GGUF/requirements.txt"
  touch "$COMFY/custom_nodes/ComfyUI-GGUF/.pinkbeta_ok"
fi

echo "[4/8] Reuse/download text encoder and VAEs"
ensure_support "text_encoders/$TEXT" "https://huggingface.co/realrebelai/MiniMax-H3_GGUFs/resolve/main/$TEXT?download=true" 10000000000
ensure_support "vae/$VIDEO_VAE" "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/$VIDEO_VAE?download=true" 900000000
ensure_support "vae/$AUDIO_VAE" "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/$AUDIO_VAE?download=true" 300000000

echo "[5/8] Download PinkCherry beta-0.6 pruned INT8 (~21 GB)"
DEST="$COMFY/models/diffusion_models/$MODEL"
mkdir -p "$(dirname "$DEST")"
if [[ -s "$DEST" ]] && [[ "$(stat -c%s "$DEST")" -ge "$MODEL_MIN_BYTES" ]] && \
   [[ "$(sha256sum "$DEST" | awk '{print $1}')" == "$MODEL_SHA256" ]]; then
  echo "  [SKIP verified] $MODEL"
else
  # aria2 keeps partial bytes in DEST plus DEST.aria2. Preserve both so a
  # disconnected terminal or HTTP 429 can continue instead of restarting 21 GB.
  if [[ -s "$DEST" ]] && [[ ! -e "$DEST.aria2" ]] && \
     [[ "$(stat -c%s "$DEST")" -ge "$MODEL_MIN_BYTES" ]]; then
    bad="$DEST.invalid.$(date +%Y%m%d-%H%M%S)"
    mv "$DEST" "$bad"
    yellow "  Existing full-size file failed verification; preserved as $(basename "$bad")"
  fi
  auth=()
  if [[ -n "${HF_TOKEN:-}" ]]; then auth=(--header="Authorization: Bearer $HF_TOKEN"); else yellow "  HF_TOKEN unset: shared IP can receive HTTP 429"; fi
  aria2c -c -x8 -s8 -k16M --file-allocation=none --auto-file-renaming=false --allow-overwrite=true \
    --max-tries=12 --retry-wait=20 --summary-interval=15 "${auth[@]}" \
    --dir "$(dirname "$DEST")" --out "$(basename "$DEST")" "$MODEL_URL"
  [[ -s "$DEST" ]] && [[ "$(stat -c%s "$DEST")" -ge "$MODEL_MIN_BYTES" ]] || die "Beta-0.6 download incomplete"
  if [[ "$(sha256sum "$DEST" | awk '{print $1}')" != "$MODEL_SHA256" ]]; then
    bad="$DEST.sha256-failed.$(date +%Y%m%d-%H%M%S)"
    mv "$DEST" "$bad"
    rm -f "$DEST.aria2"
    die "Beta-0.6 SHA256 mismatch; preserved as $(basename "$bad")"
  fi
fi

echo "[6/8] Create input placeholder and validate workflow"
mkdir -p "$COMFY/input" "$COMFY/user/default/workflows"
install -m 644 "$WORKFLOW_TMP" "$COMFY/user/default/workflows/$WORKFLOW"
COMFY="$COMFY" "$VENV_PY" - <<'PY'
from pathlib import Path
from PIL import Image, ImageDraw
p=Path(__import__('os').environ['COMFY'])/'input'/'example.png'
if not p.exists():
    im=Image.new('RGB',(512,512),(32,32,32)); ImageDraw.Draw(im).text((120,245),'REPLACE WITH YOUR IMAGE',fill=(230,230,230)); im.save(p)
PY
COMFY="$COMFY" MODEL="$MODEL" WORKFLOW="$WORKFLOW" "$VENV_PY" - <<'PY'
import json, os
from pathlib import Path
c=Path(os.environ['COMFY']); w=c/'user/default/workflows'/os.environ['WORKFLOW']
d=json.loads(w.read_text()); s=json.dumps(d)
assert os.environ['MODEL'] in s
assert 'LoraLoaderModelOnly' not in s
print('  workflow JSON validation OK')
PY

echo "[7/8] Start PinkCherry FL2VA on port $PORT"
pids="$(lsof -ti tcp:$PORT 2>/dev/null || true)"
[[ -z "$pids" ]] || kill $pids 2>/dev/null || true
sleep 2
still="$(lsof -ti tcp:$PORT 2>/dev/null || true)"
[[ -z "$still" ]] || kill -9 $still 2>/dev/null || true
cd "$COMFY"
nohup "$VENV_PY" main.py --listen 0.0.0.0 --port "$PORT" --preview-method auto --enable-cors-header --reserve-vram 4 --cache-none > "$LOG" 2>&1 &
PID=$!

echo "[8/8] Runtime validation"
ready=0
for _ in $(seq 1 240); do
  if ! kill -0 "$PID" 2>/dev/null; then tail -120 "$LOG" || true; die "ComfyUI exited during startup"; fi
  if curl --max-time 3 -fsS "http://127.0.0.1:$PORT/object_info" > /tmp/pinkbeta_object_info.json 2>/dev/null; then ready=1; break; fi
  sleep 1
done
[[ "$ready" == 1 ]] || die "Startup timeout"
MODEL="$MODEL" "$VENV_PY" - <<'PY'
import json, os
d=json.load(open('/tmp/pinkbeta_object_info.json'))
required=['MiniMaxH3ImageToVideo','UNETLoader','CLIPLoaderGGUF','VAELoader','BasicScheduler','SaveVideo']
missing=[x for x in required if x not in d]
if missing: raise SystemExit('Missing nodes: '+', '.join(missing))
if os.environ['MODEL'] not in json.dumps(d['UNETLoader']): raise SystemExit('Beta model is not visible in UNETLoader')
print('  required nodes and model visibility OK')
PY

trap - ERR
echo "============================================================"
green " PINKCHERRY beta-0.6 FL2VA READY"
echo "============================================================"
echo "ComfyUI  : $COMFY"
echo "Workflow : $WORKFLOW"
echo "Port     : $PORT"
echo "Log      : $LOG"
