#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# RunPod COMPLETE setup:
#   ComfyUI + Qwen-Image-Edit-2511 BF16
#   + Qwen 2.5 VL 7B text encoder BF16
#   + Qwen Image VAE
#   + Zaytron40k/Qwen-Image-GenatomyFixer epoch-7 LoRA
#
# Target:
#   /workspace/runpod-slim/ComfyUI
#   port 8188
#
# Designed for a fresh RunPod.
# ============================================================

ROOT="${ROOT:-/workspace/runpod-slim}"
COMFY="$ROOT/ComfyUI"
VENV="$COMFY/.venv"
PORT="${PORT:-8188}"

DIFF="$COMFY/models/diffusion_models"
TEXT="$COMFY/models/text_encoders"
VAE="$COMFY/models/vae"
LORAS="$COMFY/models/loras"
LOGDIR="$ROOT/logs"

QWEN_MODEL="qwen_image_edit_2511_bf16.safetensors"
QWEN_TEXT="qwen_2.5_vl_7b.safetensors"
QWEN_VAE="qwen_image_vae.safetensors"
GENFIX="Qwen-Image-GenatomyFixer_epoch-7.safetensors"

QWEN_MODEL_URL="https://huggingface.co/Comfy-Org/Qwen-Image-Edit_ComfyUI/resolve/main/split_files/diffusion_models/${QWEN_MODEL}?download=true"
QWEN_TEXT_URL="https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/text_encoders/${QWEN_TEXT}?download=true"
QWEN_VAE_URL="https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/${QWEN_VAE}?download=true"
GENFIX_URL="https://huggingface.co/Zaytron40k/Qwen-Image-GenatomyFixer/resolve/main/checkpoints/epoch-7.safetensors?download=true"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

download() {
  local url="$1"
  local out="$2"
  local min_bytes="${3:-1048576}"

  if [[ -f "$out" ]]; then
    local sz
    sz="$(stat -c%s "$out" 2>/dev/null || echo 0)"
    if (( sz >= min_bytes )); then
      ok "Already present: $(basename "$out") ($(du -h "$out" | awk '{print $1}'))"
      return
    fi
    warn "Existing file looks incomplete; re-downloading: $out"
    rm -f "$out"
  fi

  mkdir -p "$(dirname "$out")"
  say "Downloading $(basename "$out")"

  if command -v aria2c >/dev/null 2>&1; then
    aria2c \
      --console-log-level=notice \
      --summary-interval=5 \
      --file-allocation=none \
      --continue=true \
      --allow-overwrite=true \
      --auto-file-renaming=false \
      -x 16 -s 16 -k 4M \
      -d "$(dirname "$out")" \
      -o "$(basename "$out")" \
      "$url"
  else
    curl -fL \
      --retry 10 --retry-delay 3 --connect-timeout 30 \
      -C - \
      -o "$out" \
      "$url"
  fi

  [[ -f "$out" ]] || die "Download failed: $out"
  local sz
  sz="$(stat -c%s "$out" 2>/dev/null || echo 0)"
  (( sz >= min_bytes )) || die "Downloaded file is unexpectedly small: $out"
  ok "Downloaded: $(basename "$out") ($(du -h "$out" | awk '{print $1}'))"
}

say "Fresh RunPod Qwen-Image-Edit-2511 COMPLETE setup"
echo "Root     : $ROOT"
echo "ComfyUI  : $COMFY"
echo "Port     : $PORT"
echo
echo "Models:"
echo "  - $QWEN_MODEL"
echo "  - $QWEN_TEXT"
echo "  - $QWEN_VAE"
echo "  - $GENFIX"

mkdir -p "$ROOT" "$LOGDIR"

say "Checking disk space"
FREE_GB="$(df -BG "$ROOT" | awk 'NR==2 {gsub("G","",$4); print $4}')"
echo "Free space: ${FREE_GB:-unknown} GB"
if [[ "${FREE_GB:-0}" =~ ^[0-9]+$ ]] && (( FREE_GB < 75 )); then
  warn "Less than 75 GB free. BF16 full setup may run out of disk space."
fi

say "Installing base packages"
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git git-lfs curl aria2 python3 python3-venv python3-pip \
    build-essential libgl1 libglib2.0-0
fi

git lfs install --skip-repo >/dev/null 2>&1 || true

say "Installing / updating ComfyUI"
if [[ ! -d "$COMFY/.git" ]]; then
  rm -rf "$COMFY"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
else
  git -C "$COMFY" fetch --depth 1 origin
  git -C "$COMFY" reset --hard origin/master
fi

say "Creating Python environment"
if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv --system-site-packages "$VENV"
fi

"$VENV/bin/python" -m pip install -U pip setuptools wheel
"$VENV/bin/python" -m pip install -r "$COMFY/requirements.txt"

# Useful download / metadata packages. Safe even if already installed.
"$VENV/bin/python" -m pip install -U huggingface_hub safetensors

mkdir -p "$DIFF" "$TEXT" "$VAE" "$LORAS"

say "Downloading Qwen-Image-Edit-2511 BF16"
download "$QWEN_MODEL_URL" "$DIFF/$QWEN_MODEL" 30000000000

say "Downloading Qwen 2.5 VL 7B BF16 text encoder"
download "$QWEN_TEXT_URL" "$TEXT/$QWEN_TEXT" 12000000000

say "Downloading Qwen Image VAE"
download "$QWEN_VAE_URL" "$VAE/$QWEN_VAE" 200000000

say "Downloading GenatomyFixer epoch-7 LoRA"
download "$GENFIX_URL" "$LORAS/$GENFIX" 100000000

say "Writing launcher"
cat > "$ROOT/start_qwen2511.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
COMFY="/workspace/runpod-slim/ComfyUI"
PORT="${PORT:-8188}"
mkdir -p /workspace/runpod-slim/logs

# Kill only an older ComfyUI process bound to this setup, if present.
pkill -f "/workspace/runpod-slim/ComfyUI/main.py.*--port ${PORT}" 2>/dev/null || true
sleep 2

cd "$COMFY"
nohup "$COMFY/.venv/bin/python" main.py \
  --listen 0.0.0.0 \
  --port "$PORT" \
  > "/workspace/runpod-slim/logs/qwen2511_comfyui.log" 2>&1 &

echo $! > "/workspace/runpod-slim/qwen2511_comfyui.pid"
echo "ComfyUI starting on port $PORT"
echo "PID: $(cat /workspace/runpod-slim/qwen2511_comfyui.pid)"
echo "Log: /workspace/runpod-slim/logs/qwen2511_comfyui.log"
EOF
chmod +x "$ROOT/start_qwen2511.sh"

say "Writing environment summary"
cat > "$ROOT/QWEN2511_GENATOMY_READY.txt" <<EOF
Qwen-Image-Edit-2511 environment

ComfyUI:
  $COMFY

Port:
  $PORT

Diffusion model:
  models/diffusion_models/$QWEN_MODEL

Text encoder:
  models/text_encoders/$QWEN_TEXT

VAE:
  models/vae/$QWEN_VAE

LoRA:
  models/loras/$GENFIX

GenatomyFixer author-recommended low-strength sweep:
  0.20 / 0.30 / 0.40 / 0.50

Recommended starting strength:
  0.30

Restart:
  bash $ROOT/start_qwen2511.sh

Log:
  $LOGDIR/qwen2511_comfyui.log
EOF

say "Starting ComfyUI"
bash "$ROOT/start_qwen2511.sh"

say "Waiting for port $PORT"
READY=0
for i in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${PORT}/system_stats" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done

echo
if (( READY == 1 )); then
  ok "ComfyUI is ALIVE on port $PORT"
else
  warn "ComfyUI did not answer yet. Showing last 80 log lines:"
  tail -n 80 "$LOGDIR/qwen2511_comfyui.log" || true
fi

echo
echo "============================================================"
echo " COMPLETE"
echo "============================================================"
echo "ComfyUI : $COMFY"
echo "Port    : $PORT"
echo "Model   : $DIFF/$QWEN_MODEL"
echo "Text    : $TEXT/$QWEN_TEXT"
echo "VAE     : $VAE/$QWEN_VAE"
echo "LoRA    : $LORAS/$GENFIX"
echo "Launcher: $ROOT/start_qwen2511.sh"
echo "Log     : $LOGDIR/qwen2511_comfyui.log"
echo
echo "GenatomyFixer starting strength: 0.30"
