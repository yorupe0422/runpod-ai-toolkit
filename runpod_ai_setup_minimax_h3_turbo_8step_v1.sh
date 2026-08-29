#!/usr/bin/env bash
set -Eeuo pipefail

# Standalone MiniMax-H3 Turbo (FL2VA/I2V) environment.
# It does NOT modify or reuse the PinkCherry model.  The only shared assets
# are verified VAE files, linked read-only when they already exist.

ROOT="/workspace/runpod-slim"
COMFY="$ROOT/ComfyUI-MiniMaxH3Turbo"
PORT="${PORT:-8188}"
LOG="$ROOT/comfyui-minimax-h3-turbo.log"
WORKFLOW="MiniMaxH3_Turbo_8step_I2V_768p_v1.json"
WF_URL="https://raw.githubusercontent.com/ModelTC/Minimax-H3-Turbo/main/example_workflows/video_minimax_h3_i2v_lightx2v_turbo.json"

MODEL="minimax_h3_fl2va_pruned_int8_convrot.safetensors"
TEXT="qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"
VIDEO_VAE="minimax_h3_video_vae_fp16.safetensors"
AUDIO_VAE="minimax_h3_audio_vae_fp32.safetensors"
LORA="minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors"

green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[0;33m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
die(){ red "[FAILED] $*"; exit 1; }
on_error(){ local rc=$?; red "SETUP FAILED (exit=$rc, line=${BASH_LINENO[0]:-unknown})"; echo "Log: $LOG"; exit "$rc"; }
trap on_error ERR

hf_download(){
  local repo="$1"; local file="$2"; local target="$3"; local min_bytes="$4"
  local url="https://huggingface.co/${repo}/resolve/main/${file}?download=true"
  local auth=()
  [[ -n "${HF_TOKEN:-}" ]] && auth=(--header="Authorization: Bearer $HF_TOKEN")
  mkdir -p "$(dirname "$target")"
  if [[ -s "$target" && "$(stat -c%s "$target")" -ge "$min_bytes" ]]; then
    echo "  [OK] $(basename "$target")"
    return 0
  fi
  yellow "  [DL] $(basename "$target")"
  aria2c -c -x8 -s8 -k16M --file-allocation=none --auto-file-renaming=false --allow-overwrite=true \
    --max-tries=12 --retry-wait=20 --summary-interval=20 "${auth[@]}" \
    --dir "$(dirname "$target")" --out "$(basename "$target")" "$url"
  [[ -s "$target" && "$(stat -c%s "$target")" -ge "$min_bytes" ]] || die "Incomplete download: $(basename "$target")"
}

reuse_or_download(){
  local rel="$1"; local repo="$2"; local file="$3"; local min_bytes="$4"
  local target="$COMFY/models/$rel"
  mkdir -p "$(dirname "$target")"
  if [[ -s "$target" && "$(stat -c%s "$target")" -ge "$min_bytes" ]]; then return 0; fi
  for src_root in "$ROOT/ComfyUI-PinkCherry-beta06" "$ROOT/ComfyUI" "$ROOT/ComfyUI-Ref2VA"; do
    local src="$src_root/models/$rel"
    if [[ -s "$src" && "$(stat -c%s "$src")" -ge "$min_bytes" ]]; then
      rm -f "$target"
      ln -s "$src" "$target"
      echo "  [LINK] $(basename "$target")"
      return 0
    fi
  done
  hf_download "$repo" "$file" "$target" "$min_bytes"
}

echo "============================================================"
echo " MINIMAX-H3 TURBO — FL2VA/I2V 8-STEP 768p v1"
echo "============================================================"
echo "Environment: $COMFY"

echo "[1/8] System tools and GPU preflight"
command -v nvidia-smi >/dev/null 2>&1 || die "No NVIDIA GPU detected"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v aria2c >/dev/null 2>&1 || ! command -v lsof >/dev/null 2>&1 || ! command -v ffmpeg >/dev/null 2>&1; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl ca-certificates aria2 lsof ffmpeg python3-venv
fi

echo "[2/8] Fresh independent ComfyUI core"
if [[ ! -f "$COMFY/main.py" ]]; then
  if [[ -e "$COMFY" ]]; then
    backup="${COMFY}.incomplete.$(date +%Y%m%d-%H%M%S)"
    mv "$COMFY" "$backup"
    echo "  [BACKUP] $backup"
  fi
  git -c gc.auto=0 clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
fi
grep -Rqs "MiniMaxH3ImageToVideo" "$COMFY/comfy_extras" || die "Installed ComfyUI does not contain MiniMax-H3 nodes"
if command -v python3.12 >/dev/null 2>&1; then PY="$(command -v python3.12)"; else PY="$(command -v python3)"; fi
[[ -x "$COMFY/.venv/bin/python" ]] || "$PY" -m venv --system-site-packages "$COMFY/.venv"
VENV_PY="$COMFY/.venv/bin/python"
if [[ ! -f "$COMFY/.h3turbo_requirements_ok" ]]; then
  "$VENV_PY" -m pip install -q --upgrade pip 'setuptools<82' wheel
  "$VENV_PY" -m pip install -q -r "$COMFY/requirements.txt"
  touch "$COMFY/.h3turbo_requirements_ok"
fi

echo "[3/8] Official MiniMax-H3 FL2VA base model"
hf_download "Comfy-Org/MiniMax-H3" "diffusion_models/$MODEL" "$COMFY/models/diffusion_models/$MODEL" 18000000000

echo "[4/8] Official text encoder and VAEs"
hf_download "Comfy-Org/MiniMax-H3" "text_encoders/$TEXT" "$COMFY/models/text_encoders/$TEXT" 8000000000
reuse_or_download "vae/$VIDEO_VAE" "Comfy-Org/MiniMax-H3" "vae/$VIDEO_VAE" 900000000
reuse_or_download "vae/$AUDIO_VAE" "Comfy-Org/MiniMax-H3" "vae/$AUDIO_VAE" 300000000

echo "[5/8] LightX2V Turbo LoRA (8-step)"
hf_download "lightx2v/Minimax-h3-Turbo" "$LORA" "$COMFY/models/loras/$LORA" 1800000000

echo "[6/8] Official I2V workflow and input placeholder"
mkdir -p "$COMFY/user/default/workflows" "$COMFY/input"
curl -fL --retry 8 --retry-all-errors --retry-delay 10 "$WF_URL?v=$(date +%s)" -o "$COMFY/user/default/workflows/$WORKFLOW"
grep -q "$LORA" "$COMFY/user/default/workflows/$WORKFLOW" || die "Downloaded workflow does not use the expected 8-step Turbo LoRA"
COMFY="$COMFY" "$VENV_PY" - <<'PY'
from pathlib import Path
from PIL import Image, ImageDraw
p=Path(__import__('os').environ['COMFY'])/'input'/'image.jpg'
if not p.exists():
    im=Image.new('RGB',(1344,768),(36,36,36))
    ImageDraw.Draw(im).text((490,375),'REPLACE WITH YOUR START IMAGE',fill=(235,235,235))
    im.save(p,quality=95)
PY

echo "[7/8] Start Turbo ComfyUI on port $PORT"
pids="$(lsof -ti tcp:$PORT 2>/dev/null || true)"
if [[ -n "$pids" ]]; then
  for pid in $pids; do
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    [[ "$cmd" == *"main.py"* && "$cmd" == *"/workspace/runpod-slim/"* ]] || die "Port $PORT is occupied by unrelated PID $pid; it was not stopped."
  done
  echo "  [PORT] Stopping existing RunPod ComfyUI: $pids"
  kill $pids 2>/dev/null || true
  for _ in $(seq 1 20); do [[ -z "$(lsof -ti tcp:$PORT 2>/dev/null || true)" ]] && break; sleep 1; done
fi
[[ -z "$(lsof -ti tcp:$PORT 2>/dev/null || true)" ]] || die "Could not free port $PORT"
cd "$COMFY"
nohup "$VENV_PY" main.py --listen 0.0.0.0 --port "$PORT" --preview-method auto --enable-cors-header --reserve-vram 4 --cache-none > "$LOG" 2>&1 &
PID=$!

echo "[8/8] Runtime and model visibility validation"
ready=0
for _ in $(seq 1 240); do
  if ! kill -0 "$PID" 2>/dev/null; then tail -160 "$LOG" || true; die "ComfyUI exited during startup"; fi
  if curl --max-time 3 -fsS "http://127.0.0.1:$PORT/object_info" > /tmp/minimax_h3_turbo_object_info.json 2>/dev/null; then ready=1; break; fi
  sleep 1
done
[[ "$ready" == 1 ]] || die "Startup timeout"
MODEL="$MODEL" TEXT="$TEXT" VIDEO_VAE="$VIDEO_VAE" AUDIO_VAE="$AUDIO_VAE" LORA="$LORA" "$VENV_PY" - <<'PY'
import json,os
d=json.load(open('/tmp/minimax_h3_turbo_object_info.json'))
need=['MiniMaxH3ImageToVideo','LoraLoaderModelOnly','MiniMaxH3SigmaShift','UNETLoader','VAELoader','SaveVideo']
missing=[x for x in need if x not in d]
if missing: raise SystemExit('Missing nodes: '+', '.join(missing))
allinfo=json.dumps(d)
for key in ['MODEL','TEXT','VIDEO_VAE','AUDIO_VAE','LORA']:
    if os.environ[key] not in allinfo: raise SystemExit(f'{key} is not visible in ComfyUI: {os.environ[key]}')
print('  Turbo nodes and all required models are visible')
PY

trap - ERR
echo "============================================================"
green " MINIMAX-H3 TURBO 8-STEP READY"
echo "============================================================"
echo "Workflow : $COMFY/user/default/workflows/$WORKFLOW"
echo "Input    : $COMFY/input/image.jpg"
echo "Output   : $COMFY/output/video/MiniMax_H3"
echo "Defaults : 8 steps, video shift 12, audio shift 3, 1344x768, ~5 sec"
echo "Port     : $PORT"
