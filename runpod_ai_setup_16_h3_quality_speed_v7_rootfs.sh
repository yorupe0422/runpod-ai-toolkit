#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# #16 v7 - MiniMax H3 Ref2VA VSA 4-step
# RunPod rootfs build: avoids /workspace permission restrictions
# ============================================================

BASE="${BASE:-/root/runpod16}"
COMFY="${BASE}/ComfyUI-H3-SpeedLab16"
PORT="${PORT:-8188}"
WF_DIR="${COMFY}/user/default/workflows"

export GIT_TERMINAL_PROMPT=0
export HF_XET_HIGH_PERFORMANCE=1
export HF_HOME="${BASE}/hf_cache"
export XDG_CACHE_HOME="${BASE}/cache"
export PIP_CACHE_DIR="${BASE}/pip_cache"

log(){ printf '\n\033[1;36m[#16 v7]\033[0m %s\n' "$*"; }
warn(){ printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\n\033[1;31m[FATAL]\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$BASE"
cd "$BASE"

log "Filesystem check"
/bin/df -h / /workspace 2>/dev/null || true

ROOT_AVAIL_GB="$(df -Pk / | awk 'NR==2 {printf "%d", $4/1024/1024}')"
if [[ "${ROOT_AVAIL_GB:-0}" -lt 70 ]]; then
  die "Root filesystem has only ${ROOT_AVAIL_GB:-unknown} GB free. #16 needs ~70 GB+ free during setup."
fi

log "GPU check"
nvidia-smi || true

log "Install system packages"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git git-lfs curl wget aria2 ffmpeg \
  python3.12 python3.12-venv python3-pip
git lfs install || true

# ---------- ComfyUI ----------
if [[ ! -d "$COMFY/.git" ]]; then
  log "Clone ComfyUI into rootfs"
  rm -rf "$COMFY"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
else
  log "Update ComfyUI"
  git -C "$COMFY" pull --ff-only || warn "ComfyUI update failed; using current checkout"
fi

cd "$COMFY"

if [[ ! -x .venv/bin/python ]]; then
  log "Create Python venv on rootfs"
  python3.12 -m venv .venv
fi

PY="$COMFY/.venv/bin/python"
HF="$COMFY/.venv/bin/hf"

"$PY" -m pip install -U pip setuptools wheel
"$PY" -m pip install -r requirements.txt
"$PY" -m pip install -U comfy-kitchen huggingface_hub hf_xet safetensors

mkdir -p \
  custom_nodes \
  models/diffusion_models \
  models/text_encoders \
  models/vae \
  models/loras \
  input \
  "$WF_DIR"

# ---------- VSA custom node ----------
if [[ ! -d custom_nodes/ComfyUI-Ref2VA-VSA/.git ]]; then
  log "Clone Ref2VA-VSA"
  rm -rf custom_nodes/ComfyUI-Ref2VA-VSA
  git clone --depth 1 \
    https://github.com/Kablex/ComfyUI-Ref2VA-VSA.git \
    custom_nodes/ComfyUI-Ref2VA-VSA
else
  git -C custom_nodes/ComfyUI-Ref2VA-VSA pull --ff-only || true
fi

if [[ -f custom_nodes/ComfyUI-Ref2VA-VSA/requirements.txt ]]; then
  "$PY" -m pip install -r custom_nodes/ComfyUI-Ref2VA-VSA/requirements.txt
fi

# ---------- model download helper ----------
get_model () {
  local repo="$1"
  local hfpath="$2"
  local dest="$3"

  mkdir -p "$(dirname "$dest")"

  if [[ -s "$dest" ]]; then
    echo "[OK existing] $dest"
    return 0
  fi

  log "Download ${repo}/${hfpath}"
  local tmp="${BASE}/hf_stage_$RANDOM$RANDOM"
  rm -rf "$tmp"
  mkdir -p "$tmp"

  "$HF" download "$repo" "$hfpath" --local-dir "$tmp"

  if [[ ! -s "$tmp/$hfpath" ]]; then
    rm -rf "$tmp"
    die "Downloaded file missing: $repo/$hfpath"
  fi

  mv "$tmp/$hfpath" "$dest"
  rm -rf "$tmp"
  echo "[OK] $dest"
}

HF_MAIN="Comfy-Org/MiniMax-H3"

get_model "$HF_MAIN" \
  "diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors" \
  "$COMFY/models/diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors"

get_model "$HF_MAIN" \
  "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" \
  "$COMFY/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"

get_model "$HF_MAIN" \
  "vae/minimax_h3_video_vae_fp16.safetensors" \
  "$COMFY/models/vae/minimax_h3_video_vae_fp16.safetensors"

get_model "$HF_MAIN" \
  "vae/minimax_h3_audio_vae_fp32.safetensors" \
  "$COMFY/models/vae/minimax_h3_audio_vae_fp32.safetensors"

get_model "$HF_MAIN" \
  "loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors" \
  "$COMFY/models/loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors"

get_model "barelymining/ComfyUI-MiniMax-H3-FastVideo" \
  "fasth3_vsa_gate.safetensors" \
  "$COMFY/models/loras/fasth3_vsa_gate.safetensors"

# ---------- workflows ----------
log "Install workflows"
UPSTREAM_WF="$COMFY/custom_nodes/ComfyUI-Ref2VA-VSA/workflows/ref2va_vsa_4step_rtx4090.json"
[[ -s "$UPSTREAM_WF" ]] || die "VSA upstream workflow missing: $UPSTREAM_WF"

cp -f "$UPSTREAM_WF" \
  "$WF_DIR/16A_H3_REF2VA_VSA_4STEP_SPEED.json"

curl -fsSL \
  https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/video_minimax_h3_r2v.json \
  -o "$WF_DIR/16B_H3_NATIVE_R2V_OFFICIAL.json" || \
  warn "Official fallback workflow download failed; main VSA workflow is unaffected."

# ---------- sanity ----------
log "Sanity check"
"$PY" - <<'PY'
from pathlib import Path
C=Path("/root/runpod16/ComfyUI-H3-SpeedLab16")
req=[
 C/"main.py",
 C/"custom_nodes/ComfyUI-Ref2VA-VSA/nodes.py",
 C/"models/diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors",
 C/"models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
 C/"models/vae/minimax_h3_video_vae_fp16.safetensors",
 C/"models/vae/minimax_h3_audio_vae_fp32.safetensors",
 C/"models/loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors",
 C/"models/loras/fasth3_vsa_gate.safetensors",
 C/"user/default/workflows/16A_H3_REF2VA_VSA_4STEP_SPEED.json",
]
missing=[]
for p in req:
    ok=p.exists()
    size=(p.stat().st_size/1024**3) if ok and p.is_file() else 0
    print(("[OK]   " if ok else "[MISS] "), p, f"{size:.2f} GiB" if ok and p.is_file() else "")
    if not ok:
        missing.append(str(p))
if missing:
    raise SystemExit("Missing required files:\n"+"\n".join(missing))
PY

# ---------- launcher ----------
cat > "$BASE/start_16_h3_speedlab_v7.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
cd /root/runpod16/ComfyUI-H3-SpeedLab16
exec .venv/bin/python main.py \
  --listen 0.0.0.0 \
  --port 8188 \
  --reserve-vram 3
EOF
chmod +x "$BASE/start_16_h3_speedlab_v7.sh"

cat <<'EOF'

============================================================
 #16 v7 READY
============================================================

Runtime location:
  /root/runpod16/ComfyUI-H3-SpeedLab16

Main workflow:
  16A_H3_REF2VA_VSA_4STEP_SPEED.json

Fallback:
  16B_H3_NATIVE_R2V_OFFICIAL.json

Start:
  /root/runpod16/start_16_h3_speedlab_v7.sh

Port:
  8188

IMPORTANT:
  /workspace is intentionally NOT used for runtime files.
============================================================
EOF

log "Start ComfyUI"
exec "$PY" main.py \
  --listen 0.0.0.0 \
  --port "$PORT" \
  --reserve-vram 3
