#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# #16 v5 - MiniMax H3 Ref2VA VSA 4-step
# Robust RunPod setup / fixed against current public HF layout
# ============================================================

ROOT="${ROOT:-/workspace/runpod-slim}"
COMFY="${ROOT}/ComfyUI-H3-SpeedLab16"
PORT="${PORT:-8188}"
WF_DIR="${COMFY}/user/default/workflows"

export GIT_TERMINAL_PROMPT=0
export HF_XET_HIGH_PERFORMANCE=1

log(){ printf '\n\033[1;36m[#16 v5]\033[0m %s\n' "$*"; }
warn(){ printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\n\033[1;31m[FATAL]\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$ROOT"
cd "$ROOT"

log "GPU / disk check"
nvidia-smi || true
df -h / /workspace || true

# ---------- system deps ----------
log "System dependencies"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git git-lfs curl wget aria2 python3.12 python3.12-venv python3-pip
git lfs install || true

# ---------- ComfyUI ----------
if [[ ! -d "$COMFY/.git" ]]; then
  log "Clone ComfyUI"
  rm -rf "$COMFY"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
else
  log "Reuse/update existing #16 ComfyUI"
  git -C "$COMFY" pull --ff-only || warn "ComfyUI update failed; continuing with current checkout"
fi

cd "$COMFY"

if [[ ! -x .venv/bin/python ]]; then
  python3.12 -m venv .venv
fi

source .venv/bin/activate
python -m pip install -U pip setuptools wheel
pip install -r requirements.txt
pip install -U comfy-kitchen huggingface_hub hf_xet safetensors

mkdir -p \
  custom_nodes \
  models/diffusion_models \
  models/text_encoders \
  models/vae \
  models/loras \
  input \
  "$WF_DIR"

# ---------- VSA custom node ----------
if [[ ! -f custom_nodes/ComfyUI-Ref2VA-VSA/nodes.py ]]; then
  log "Install ComfyUI-Ref2VA-VSA"
  rm -rf custom_nodes/ComfyUI-Ref2VA-VSA
  if ! git -c credential.helper= clone --depth 1 \
      https://github.com/Kablex/ComfyUI-Ref2VA-VSA.git \
      custom_nodes/ComfyUI-Ref2VA-VSA </dev/null; then
    die "Could not clone public Kablex/ComfyUI-Ref2VA-VSA"
  fi
else
  log "VSA node already present"
fi

if [[ -f custom_nodes/ComfyUI-Ref2VA-VSA/requirements.txt ]]; then
  pip install -r custom_nodes/ComfyUI-Ref2VA-VSA/requirements.txt
fi

# ---------- model helper ----------
# Reuse any existing copy under /workspace/runpod-slim first.
get_model () {
  local repo="$1"
  local hfpath="$2"
  local dest="$3"
  local filename
  filename="$(basename "$dest")"

  mkdir -p "$(dirname "$dest")"

  if [[ -s "$dest" ]]; then
    echo "[OK existing] $dest"
    return 0
  fi

  local found=""
  found="$(find "$ROOT" -type f -name "$filename" ! -path "$COMFY/*" -size +1M 2>/dev/null | head -1 || true)"
  if [[ -n "$found" ]]; then
    log "Reuse existing $filename"
    ln -sf "$found" "$dest"
    echo "[LINK] $dest -> $found"
    return 0
  fi

  log "Download $repo / $hfpath"
  local tmp="/tmp/hf16v4_${RANDOM}_${RANDOM}"
  rm -rf "$tmp"
  mkdir -p "$tmp"

  if ! hf download "$repo" "$hfpath" --local-dir "$tmp"; then
    rm -rf "$tmp"
    die "Download failed: $repo/$hfpath"
  fi

  if [[ ! -s "$tmp/$hfpath" ]]; then
    rm -rf "$tmp"
    die "Downloaded file missing: $tmp/$hfpath"
  fi

  mv "$tmp/$hfpath" "$dest"
  rm -rf "$tmp"
  echo "[OK] $dest"
}

# ---------- VERIFIED CURRENT PUBLIC MODEL LOCATIONS ----------
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

# Official current Comfy-Org R2V template points to this LoRA as well.
get_model "$HF_MAIN" \
  "loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors" \
  "$COMFY/models/loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors"

# VSA gate remains in barelymining's public repo, as linked by VSA upstream.
get_model "barelymining/ComfyUI-MiniMax-H3-FastVideo" \
  "fasth3_vsa_gate.safetensors" \
  "$COMFY/models/loras/fasth3_vsa_gate.safetensors"

# ---------- workflows ----------
log "Install workflow"

UPSTREAM_WF="$COMFY/custom_nodes/ComfyUI-Ref2VA-VSA/workflows/ref2va_vsa_4step_rtx4090.json"
[[ -s "$UPSTREAM_WF" ]] || die "VSA upstream workflow not found: $UPSTREAM_WF"

cp -f "$UPSTREAM_WF" \
  "$WF_DIR/16A_H3_REF2VA_VSA_4STEP_SPEED.json"

# Keep official native R2V as fallback / A-B reference.
curl -fsSL \
  https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/video_minimax_h3_r2v.json \
  -o "$WF_DIR/16B_H3_NATIVE_R2V_OFFICIAL.json" || \
  warn "Could not fetch official R2V template; main VSA workflow is unaffected."

# Example input for upstream workflow.
if [[ -s "$COMFY/custom_nodes/ComfyUI-Ref2VA-VSA/example_character.jpg" ]]; then
  cp -f "$COMFY/custom_nodes/ComfyUI-Ref2VA-VSA/example_character.jpg" \
    "$COMFY/input/example_character.jpg"
elif [[ -s "$COMFY/custom_nodes/ComfyUI-Ref2VA-VSA/assets/example_character.jpg" ]]; then
  cp -f "$COMFY/custom_nodes/ComfyUI-Ref2VA-VSA/assets/example_character.jpg" \
    "$COMFY/input/example_character.jpg"
fi

# ---------- sanity ----------
log "Sanity check"
python - <<'PY'
from pathlib import Path
C=Path("/workspace/runpod-slim/ComfyUI-H3-SpeedLab16")
req=[
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
    ok=p.exists() or p.is_symlink()
    size=p.stat().st_size if ok and p.exists() else 0
    print(("[OK]   " if ok else "[MISS] "), p, f"{size/1024**2:.1f} MB" if ok else "")
    if not ok:
        missing.append(str(p))
if missing:
    raise SystemExit("Missing required files:\n"+"\n".join(missing))
PY

# ---------- launcher ----------
cat > "$ROOT/start_16_h3_speedlab_v5.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
cd /workspace/runpod-slim/ComfyUI-H3-SpeedLab16
source .venv/bin/activate
exec python main.py \
  --listen 0.0.0.0 \
  --port 8188 \
  --reserve-vram 3
EOF
chmod +x "$ROOT/start_16_h3_speedlab_v5.sh"

cat <<'EOF'

============================================================
 #16 v5 READY
============================================================

Main workflow:
  16A_H3_REF2VA_VSA_4STEP_SPEED.json

Fallback / reference:
  16B_H3_NATIVE_R2V_OFFICIAL.json

Pipeline:
  Ref2VA INT8 ConvRot
  + Ref2V Turbo 4-step
  + VSA Gate
  + 75% sparse attention
  + Euler / simple

Start:
  /workspace/runpod-slim/start_16_h3_speedlab_v5.sh

Port:
  8188

NOTE:
  VDN has intentionally been removed from v4.
  First priority is a clean, reproducible VSA setup.
============================================================
EOF

log "Start ComfyUI"
exec "$ROOT/start_16_h3_speedlab_v5.sh"
