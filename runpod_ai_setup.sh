#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# RunPod AI Toolkit v5.0 — KNOWN GOOD MiniMax H3 baseline
#
# Frozen from the setup that actually worked on RTX 5090:
#   ComfyUI commit: 2a68ce33
#   MiniMax H3 Q4 GGUF
#   Qwen3VL 32B H3 Q4 GGUF
#   MiniMax H3 Video / Audio VAE
#   Turbo LoRA
#   PinkCherry H3 v0.5 alpha pruned INT8
#   --disable-dynamic-vram (AIMDO HostBuffer workaround)
#
# Safe design:
#   - Does NOT update every custom node
#   - Does NOT install unrelated custom-node dependencies
#   - Does NOT overwrite working model files
#   - Does NOT use old broken subgraph workflows
# ============================================================

VERSION="5.0"
WORKSPACE="${WORKSPACE:-/workspace}"
PORT="${PORT:-8188}"
PYTHON_BIN="${PYTHON_BIN:-python3.12}"
CONNECTIONS="${CONNECTIONS:-8}"
INSTALL_PINKCHERRY="${INSTALL_PINKCHERRY:-1}"
INSTALL_WORKFLOWS="${INSTALL_WORKFLOWS:-1}"

# GitHub repo where this script/workflows live.
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/yorupe0422/runpod-ai-toolkit/main}"

# Known-good ComfyUI commit from 2026-08-09/10 session.
COMFY_COMMIT="2a68ce33"

# ----- Models -----
H3_MODEL="MiniMax-H3-FL2VA-Q4_K_M.gguf"
H3_TEXT="qwen3vl-32B-MiniMax-H3-Q4_K_M.gguf"
H3_VIDEO_VAE="minimax_h3_video_vae_fp16.safetensors"
H3_AUDIO_VAE="minimax_h3_audio_vae_fp32.safetensors"
H3_TURBO="minimax_h3_turbo_v4_step600_ema_pruned_comfyui.safetensors"
PINKCHERRY="PinkCherry_h3_fl2va_pruned_int8_v0.5-alpha.safetensors"

URL_H3_MODEL="https://huggingface.co/realrebelai/MiniMax-H3_GGUFs/resolve/main/${H3_MODEL}"
URL_H3_TEXT="https://huggingface.co/realrebelai/MiniMax-H3_GGUFs/resolve/main/${H3_TEXT}"
URL_H3_VIDEO_VAE="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/${H3_VIDEO_VAE}"
URL_H3_AUDIO_VAE="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/${H3_AUDIO_VAE}"
URL_H3_TURBO="https://huggingface.co/drbaph/MiniMax-H3-Turbo-Lora-ComfyUI/resolve/main/${H3_TURBO}"
URL_PINKCHERRY="https://huggingface.co/SexGod1979/PinkCherry_MiniMax-H3/resolve/main/alpha-0.5-testing/${PINKCHERRY}"

# Minimum sizes — enough to reject HTML/partial downloads without re-downloading good files.
MIN_H3_MODEL=19000000000
MIN_H3_TEXT=14000000000
MIN_VIDEO_VAE=5000000000
MIN_AUDIO_VAE=550000000
MIN_TURBO=550000000
MIN_PINKCHERRY=20500000000

# PinkCherry remote SHA256 is published by Hugging Face.
SHA_PINKCHERRY="81360b34506599ff23c8b693f7de77fbe553190fd028608a205eeb9e0f06f9fe"

green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[0;33m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
blue(){ printf '\033[0;34m%s\033[0m\n' "$*"; }
die(){ red "[ERROR] $*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

echo
blue "============================================================"
blue " RunPod AI Toolkit v${VERSION} — MiniMax H3 Known-Good Setup"
blue "============================================================"

# 1) Locate ComfyUI
COMFY_DIR=""
for d in "$WORKSPACE/runpod-slim/ComfyUI" "$WORKSPACE/ComfyUI"; do
  if [[ -f "$d/main.py" ]]; then COMFY_DIR="$d"; break; fi
done
if [[ -z "$COMFY_DIR" ]]; then
  COMFY_DIR="$(find "$WORKSPACE" -maxdepth 4 -type f -path '*/ComfyUI/main.py' 2>/dev/null | head -1 | xargs -r dirname || true)"
fi
[[ -n "$COMFY_DIR" ]] || die "ComfyUI not found under $WORKSPACE"

BASE_DIR="$(dirname "$COMFY_DIR")"
LOG_DIR="$BASE_DIR/runpod-ai-toolkit"
SETUP_LOG="$LOG_DIR/setup-v5.log"
COMFY_LOG="$BASE_DIR/comfyui.log"
CUSTOM_DIR="$COMFY_DIR/custom_nodes"
MODELS_DIR="$COMFY_DIR/models"
WORKFLOW_DIR="$COMFY_DIR/user/default/workflows"

mkdir -p "$LOG_DIR" "$CUSTOM_DIR" "$WORKFLOW_DIR" \
  "$MODELS_DIR/diffusion_models" \
  "$MODELS_DIR/text_encoders" \
  "$MODELS_DIR/vae" \
  "$MODELS_DIR/loras"

exec > >(tee -a "$SETUP_LOG") 2>&1
trap 'rc=$?; red "[FAILED] line $LINENO: $BASH_COMMAND"; red "Log: $SETUP_LOG"; exit $rc' ERR

echo "[1/11] GPU / disk"
if have nvidia-smi; then
  nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1
fi
df -h "$WORKSPACE" | tail -1

echo "[2/11] System tools"
if ! have aria2c; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq aria2 >/dev/null
fi
have curl || { apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl >/dev/null; }
have wget || { apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wget >/dev/null; }
have git  || { apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git >/dev/null; }
green "  ✓ aria2 / curl / wget / git"

echo "[3/11] Freeze ComfyUI to known-good commit"
cd "$COMFY_DIR"
[[ -d .git ]] || die "$COMFY_DIR is not a git checkout"
git fetch origin -q
git checkout master -q 2>/dev/null || true
git reset --hard "$COMFY_COMMIT"
green "  ✓ ComfyUI $COMFY_COMMIT"

echo "[4/11] ComfyUI requirements"
"$PYTHON_BIN" -m pip install -q -r "$COMFY_DIR/requirements.txt"
green "  ✓ core requirements"

echo "[5/11] ComfyUI-GGUF only"
GGUF_DIR="$CUSTOM_DIR/ComfyUI-GGUF"
if [[ ! -d "$GGUF_DIR/.git" ]]; then
  rm -rf "$GGUF_DIR"
  git clone -q https://github.com/city96/ComfyUI-GGUF.git "$GGUF_DIR"
else
  echo "  ✓ existing ComfyUI-GGUF kept (not force-updated)"
fi
if [[ -f "$GGUF_DIR/requirements.txt" ]]; then
  "$PYTHON_BIN" -m pip install -q -r "$GGUF_DIR/requirements.txt"
fi
"$PYTHON_BIN" -m pip install -q --upgrade gguf
green "  ✓ GGUF loader ready"

file_ok(){
  local file="$1" min="$2"
  [[ -f "$file" ]] || return 1
  local size
  size="$(stat -c%s "$file" 2>/dev/null || echo 0)"
  (( size >= min ))
}

download(){
  local url="$1" out="$2" min="$3" label="$4"

  if file_ok "$out" "$min"; then
    echo "  [SKIP] $label"
    return 0
  fi

  rm -f "${out}.aria2"
  echo "  [DOWNLOAD] $label"

  set +e
  aria2c \
    --continue=true \
    --max-connection-per-server="$CONNECTIONS" \
    --split="$CONNECTIONS" \
    --min-split-size=16M \
    --file-allocation=none \
    --auto-file-renaming=false \
    --allow-overwrite=true \
    --max-tries=3 \
    --retry-wait=2 \
    --summary-interval=10 \
    --console-log-level=warn \
    --dir="$(dirname "$out")" \
    --out="$(basename "$out")" \
    "$url"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]] || ! file_ok "$out" "$min"; then
    yellow "  aria2 incomplete → wget resume fallback: $label"
    rm -f "${out}.aria2"
    wget -c -O "$out" "$url"
  fi

  file_ok "$out" "$min" || die "$label is missing/incomplete"
  green "  ✓ $label"
}

echo "[6/11] MiniMax H3 core models — parallel"
download "$URL_H3_MODEL" "$MODELS_DIR/diffusion_models/$H3_MODEL" "$MIN_H3_MODEL" "$H3_MODEL" & P1=$!
download "$URL_H3_TEXT" "$MODELS_DIR/text_encoders/$H3_TEXT" "$MIN_H3_TEXT" "$H3_TEXT" & P2=$!
download "$URL_H3_VIDEO_VAE" "$MODELS_DIR/vae/$H3_VIDEO_VAE" "$MIN_VIDEO_VAE" "$H3_VIDEO_VAE" & P3=$!
download "$URL_H3_AUDIO_VAE" "$MODELS_DIR/vae/$H3_AUDIO_VAE" "$MIN_AUDIO_VAE" "$H3_AUDIO_VAE" & P4=$!
wait "$P1"; wait "$P2"; wait "$P3"; wait "$P4"
green "  ✓ core H3 files ready"

echo "[7/11] Turbo LoRA"
download "$URL_H3_TURBO" "$MODELS_DIR/loras/$H3_TURBO" "$MIN_TURBO" "$H3_TURBO"

echo "[8/11] PinkCherry v0.5 alpha"
if [[ "$INSTALL_PINKCHERRY" == "1" ]]; then
  download "$URL_PINKCHERRY" "$MODELS_DIR/diffusion_models/$PINKCHERRY" "$MIN_PINKCHERRY" "$PINKCHERRY"
  if have sha256sum; then
    got="$(sha256sum "$MODELS_DIR/diffusion_models/$PINKCHERRY" | awk '{print $1}')"
    [[ "$got" == "$SHA_PINKCHERRY" ]] || die "PinkCherry SHA256 mismatch"
    green "  ✓ PinkCherry SHA256 verified"
  fi
else
  yellow "  PinkCherry skipped (INSTALL_PINKCHERRY=0)"
fi

# Remove the abandoned partial 8B encoder from the failed detour if it is incomplete.
ABANDONED="$MODELS_DIR/text_encoders/qwen3vl_8b_nvfp4.safetensors"
if [[ -f "$ABANDONED" ]]; then
  s="$(stat -c%s "$ABANDONED" 2>/dev/null || echo 0)"
  if (( s < 6000000000 )); then
    rm -f "$ABANDONED"
    echo "  ✓ removed abandoned partial qwen3vl_8b_nvfp4.safetensors"
  fi
fi

echo "[9/11] Install known-good workflows"
if [[ "$INSTALL_WORKFLOWS" == "1" ]]; then
  for wf in \
    MiniMax_H3_GGUF_RECOVERY_FLAT.json \
    MiniMax_H3_GGUF_RECOVERY_TURBO_8STEP.json \
    PinkCherry_H3_v0.5_RECOVERY_FLAT_25STEP.json \
    PinkCherry_H3_v0.5_TURBO_8STEP_TEST.json
  do
    tmp="$WORKFLOW_DIR/${wf}.tmp"
    if curl -fsSL "$RAW_BASE/workflows/$wf" -o "$tmp"; then
      mv "$tmp" "$WORKFLOW_DIR/$wf"
      echo "  ✓ $wf"
    else
      rm -f "$tmp"
      yellow "  not found on GitHub yet: $wf"
    fi
  done
fi

echo "[10/11] Restart ComfyUI — Dynamic VRAM OFF"
pkill -f "python.*main.py.*--port[ =]${PORT}" 2>/dev/null || true
sleep 3
cd "$COMFY_DIR"

nohup "$PYTHON_BIN" main.py \
  --listen 0.0.0.0 \
  --port "$PORT" \
  --preview-method auto \
  --enable-cors-header \
  --disable-dynamic-vram \
  > "$COMFY_LOG" 2>&1 &
PID=$!

ready=0
for _ in $(seq 1 180); do
  if ! kill -0 "$PID" 2>/dev/null; then
    tail -100 "$COMFY_LOG" || true
    die "ComfyUI exited during startup"
  fi
  if curl -fsS "http://127.0.0.1:$PORT/object_info" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" == "1" ]] || die "ComfyUI startup timeout"

echo "[11/11] Known-good node self-check"
"$PYTHON_BIN" - <<PY
import json, urllib.request, sys
url="http://127.0.0.1:${PORT}/object_info"
data=json.load(urllib.request.urlopen(url, timeout=10))
required=[
    "MiniMaxH3ImageToVideo",
    "UnetLoaderGGUF",
    "CLIPLoaderGGUF",
    "LoraLoaderModelOnly",
    "SamplerCustomAdvanced",
]
missing=[x for x in required if x not in data]
if missing:
    print("MISSING:", ", ".join(missing))
    sys.exit(1)
print("  ✓ required H3/GGUF/Turbo nodes available")
PY

echo
blue "============================================================"
green " RunPod AI Toolkit v5.0 READY"
blue "============================================================"
echo "ComfyUI commit : $COMFY_COMMIT"
echo "Launch flag    : --disable-dynamic-vram"
echo "ComfyUI log    : $COMFY_LOG"
echo "Setup log      : $SETUP_LOG"
echo
echo "Known-good workflows:"
echo "  1) MiniMax_H3_GGUF_RECOVERY_FLAT.json"
echo "  2) MiniMax_H3_GGUF_RECOVERY_TURBO_8STEP.json"
echo "  3) PinkCherry_H3_v0.5_RECOVERY_FLAT_25STEP.json"
echo "  4) PinkCherry_H3_v0.5_TURBO_8STEP_TEST.json"
echo
echo "Baseline recommendation:"
echo "  H3 normal : 25-step recovery workflow"
echo "  H3 fast   : Turbo 8-step workflow"
echo "  PinkCherry stable : 25-step recovery workflow"
echo "  PinkCherry Turbo  : TEST workflow; keep stable fallback"
echo
