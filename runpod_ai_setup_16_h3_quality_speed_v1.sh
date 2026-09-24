#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# RunPod #16 - MiniMax H3 Quality x Speed Lab
# 2026-09-24
#
# Target:
#   - RTX 5090 / consumer Blackwell
#   - ComfyUI native MiniMax-H3
#   - Ref2VA VSA 4-step (main)
#   - VDN-H3 INT8 ConvRot 8-step (A/B)
#   - H3 Turbo 4-step Q8_CR (FL2VA/I2V/T2V)
#   - H3 Fun ControlNet (Pose/Depth/Canny etc.)
#   - Port 8188
#
# Philosophy:
#   Keep current #5 untouched. This is a separate experimental env.
# ============================================================

ROOT="${ROOT:-/workspace/runpod-slim}"
COMFY="${ROOT}/ComfyUI-H3-SpeedLab16"
PORT="${PORT:-8188}"
PYTHON="${PYTHON:-python3.12}"
WF_DIR="${COMFY}/user/default/workflows"
INPUT_DIR="${COMFY}/input"

log(){ printf '\n\033[1;36m[#16]\033[0m %s\n' "$*"; }
die(){ echo "[FATAL] $*" >&2; exit 1; }
trap 'echo "[ERROR] line=$LINENO command=$BASH_COMMAND" >&2' ERR

mkdir -p "$ROOT"
cd "$ROOT"

log "GPU / disk check"
nvidia-smi || true
df -h / /workspace || true

# ---------- system packages ----------
log "System packages"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git git-lfs curl wget aria2 ffmpeg python3.12 python3.12-venv python3-pip
git lfs install

# ---------- ComfyUI ----------
if [[ ! -d "$COMFY/.git" ]]; then
  log "Clone latest ComfyUI"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
else
  log "Update ComfyUI"
  git -C "$COMFY" pull --ff-only
fi

cd "$COMFY"
"$PYTHON" -m venv .venv
source .venv/bin/activate
python -m pip install -U pip wheel setuptools

log "Install ComfyUI requirements"
pip install -r requirements.txt

# comfy-kitchen / sol_attn is important for VSA.
pip install -U comfy-kitchen huggingface_hub safetensors || true

# ---------- custom nodes ----------
mkdir -p custom_nodes "$WF_DIR" "$INPUT_DIR"
clone_or_update () {
  local url="$1" dst="$2"
  if [[ -d "$dst/.git" ]]; then
    git -C "$dst" pull --ff-only
  else
    git clone --depth 1 "$url" "$dst"
  fi
}

log "Install Ref2VA-VSA"
clone_or_update \
  https://github.com/Kablex/ComfyUI-Ref2VA-VSA.git \
  custom_nodes/ComfyUI-Ref2VA-VSA

log "Install VDN-H3 native ComfyUI port"
clone_or_update \
  https://github.com/Saganaki22/ComfyUI-VDN-H3.git \
  custom_nodes/ComfyUI-VDN-H3

log "Install GGUF loader"
clone_or_update \
  https://github.com/city96/ComfyUI-GGUF.git \
  custom_nodes/ComfyUI-GGUF
if [[ -f custom_nodes/ComfyUI-GGUF/requirements.txt ]]; then
  pip install -r custom_nodes/ComfyUI-GGUF/requirements.txt
fi

# Optional glue node for H3 FunControl; current ComfyUI also has native H3 ControlNet support.
log "Install H3 FunControl helper"
clone_or_update \
  https://github.com/wyzborrero/ComfyUI-H3-FunControl.git \
  custom_nodes/ComfyUI-H3-FunControl

# ---------- model directories ----------
mkdir -p \
  models/diffusion_models \
  models/text_encoders \
  models/vae \
  models/loras \
  models/controlnet \
  models/vdn

HF="https://huggingface.co"
dl () {
  local url="$1" out="$2"
  if [[ -s "$out" ]]; then
    echo "[SKIP] $(basename "$out")"
    return 0
  fi
  log "Download $(basename "$out")"
  aria2c -x 8 -s 8 -k 1M --file-allocation=none -o "$(basename "$out")" -d "$(dirname "$out")" "$url"
}

# ---------- Ref2VA VSA main path ----------
# Native/pruned INT8 ConvRot Ref2VA base
dl "${HF}/Comfy-Org/MiniMax-H3_ComfyUI/resolve/main/split_files/diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors?download=true" \
   "models/diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors"

# H3 text encoder + VAEs
dl "${HF}/Comfy-Org/MiniMax-H3_ComfyUI/resolve/main/split_files/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors?download=true" \
   "models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"

dl "${HF}/Comfy-Org/MiniMax-H3_ComfyUI/resolve/main/split_files/vae/minimax_h3_video_vae_fp16.safetensors?download=true" \
   "models/vae/minimax_h3_video_vae_fp16.safetensors"

dl "${HF}/Comfy-Org/MiniMax-H3_ComfyUI/resolve/main/split_files/vae/minimax_h3_audio_vae_fp32.safetensors?download=true" \
   "models/vae/minimax_h3_audio_vae_fp32.safetensors"

# Resolve current VSA gate / Ref2VA Turbo filenames through HF CLI.
log "Download VSA gate + Ref2VA 4-step Turbo via Hugging Face"
hf download Kablex/ComfyUI-Ref2VA-VSA \
  --include "*.safetensors" \
  --local-dir /tmp/ref2va_vsa_hf 2>/dev/null || true

# The node repo README is authoritative; if assets are hosted elsewhere,
# discover URLs from README and use hf_hub_download where possible.
python - <<'PY'
import os, re, shutil, urllib.request
from pathlib import Path

comfy=Path(os.environ.get("COMFY_PATH","/workspace/runpod-slim/ComfyUI-H3-SpeedLab16"))
readme=comfy/"custom_nodes/ComfyUI-Ref2VA-VSA/README.md"
text=readme.read_text(errors="ignore") if readme.exists() else ""

wanted = {
 "fasth3_vsa_gate.safetensors": comfy/"models/loras/fasth3_vsa_gate.safetensors",
 "minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors":
     comfy/"models/loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors",
}
for name,out in wanted.items():
    if out.exists() and out.stat().st_size > 1024*1024:
        continue
    # Find direct HF resolve URL containing filename in current upstream README.
    urls=re.findall(r'https://huggingface\.co/[^\s\)\]"\']+', text)
    hit=next((u for u in urls if name in u), None)
    if hit:
        out.parent.mkdir(parents=True,exist_ok=True)
        print("[DOWNLOAD]", name)
        urllib.request.urlretrieve(hit.replace("&amp;","&"), out)
    else:
        print("[WARN] Upstream README did not expose a direct URL for", name)
PY

# ---------- Turbo 4-step Q8_CR comparison ----------
dl "${HF}/molbal/MiniMax-H3-Turbo-GGUF/resolve/main/minimax_h3_fl2v_turbo_4step_v1.0_768p_Q8_CR.gguf?download=true" \
   "models/diffusion_models/minimax_h3_fl2v_turbo_4step_v1.0_768p_Q8_CR.gguf"

# ---------- VDN-H3 INT8 ConvRot comparison ----------
log "Download VDN-H3 INT8 ConvRot stage"
if [[ ! -d models/vdn/vdn-minimax-h3-int8-convrot-comfyui ]]; then
  hf download drbaph/vdn-minimax-h3-int8-convrot-comfyui \
    --local-dir models/vdn/vdn-minimax-h3-int8-convrot-comfyui
else
  echo "[SKIP] VDN INT8 checkpoint already present"
fi

# ---------- Fun ControlNet ----------
# Prefer Kijai curve-form/pruned checkpoint compatible with pruned H3.
log "Try downloading pruned H3 FunControl checkpoint"
python - <<'PY'
from huggingface_hub import hf_hub_download
from pathlib import Path
import shutil

dst=Path("/workspace/runpod-slim/ComfyUI-H3-SpeedLab16/models/controlnet")
name="minimax_h3_fun_controlnet_union_pruned_bf16.safetensors"
if (dst/name).exists():
    print("[SKIP]",name)
    raise SystemExit
candidates=[
    ("Kijai/MiniMax-H3-comfy", name),
    ("Kijai/MiniMax-H3", name),
]
for repo,fn in candidates:
    try:
        p=hf_hub_download(repo_id=repo, filename=fn)
        shutil.copy2(p,dst/name)
        print("[OK]",repo,fn)
        break
    except Exception as e:
        print("[MISS]",repo, type(e).__name__)
else:
    print("[WARN] FunControl pruned checkpoint location changed; workflow will still be installed.")
PY

# ---------- workflows ----------
log "Install ready-to-use workflows"

# 1) VSA upstream tested workflow
cp -f custom_nodes/ComfyUI-Ref2VA-VSA/workflows/ref2va_vsa_4step_rtx4090.json \
  "$WF_DIR/16A_H3_REF2VA_VSA_4STEP_SPEED.json"

# 2) VDN upstream workflow(s), if supplied
find custom_nodes/ComfyUI-VDN-H3 -type f -iname "*.json" -path "*/workflow*" -print0 2>/dev/null |
while IFS= read -r -d '' f; do
  cp -f "$f" "$WF_DIR/16B_VDN_$(basename "$f")"
done

# 3) Official ComfyUI Fun ControlNet template
curl -fL \
  https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/video_minimax_h3_fun_controlnet_union.json \
  -o "$WF_DIR/16C_H3_FUN_CONTROLNET_UNION.json" || true

# 4) Keep an untouched copy of the upstream VSA workflow for troubleshooting.
cp -f custom_nodes/ComfyUI-Ref2VA-VSA/workflows/ref2va_vsa_4step_rtx4090.json \
  "$WF_DIR/UPSTREAM_ref2va_vsa_4step_rtx4090.json"

# ---------- launcher ----------
cat > "$ROOT/start_16_h3_speedlab.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
cd /workspace/runpod-slim/ComfyUI-H3-SpeedLab16
source .venv/bin/activate
exec python main.py \
  --listen 0.0.0.0 \
  --port 8188 \
  --reserve-vram 4 \
  --cache-none
EOF
chmod +x "$ROOT/start_16_h3_speedlab.sh"

# ---------- verification ----------
log "Verification"
python - <<'PY'
from pathlib import Path
C=Path("/workspace/runpod-slim/ComfyUI-H3-SpeedLab16")
checks=[
 C/"models/diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors",
 C/"models/diffusion_models/minimax_h3_fl2v_turbo_4step_v1.0_768p_Q8_CR.gguf",
 C/"models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
 C/"models/vae/minimax_h3_video_vae_fp16.safetensors",
 C/"models/vae/minimax_h3_audio_vae_fp32.safetensors",
 C/"user/default/workflows/16A_H3_REF2VA_VSA_4STEP_SPEED.json",
]
for p in checks:
    print(("[OK]  " if p.exists() else "[MISS]"), p)
PY

cat <<'EOF'

============================================================
 #16 MiniMax H3 Quality x Speed Lab installed
============================================================

Main environment:
  /workspace/runpod-slim/ComfyUI-H3-SpeedLab16

Start:
  /workspace/runpod-slim/start_16_h3_speedlab.sh

Port:
  8188

Start with:
  16A_H3_REF2VA_VSA_4STEP_SPEED.json
    - Ref2VA INT8 ConvRot
    - 4-step Turbo
    - VSA sparsity 0.75
    - Euler / simple
    - quality-speed main candidate

A/B:
  16B_VDN_*.json
    - VDN-H3 INT8 ConvRot
    - 8-step path

Structural control:
  16C_H3_FUN_CONTROLNET_UNION.json
    - Pose / Depth / Canny / HED / MLSD

Turbo Q8_CR model:
  minimax_h3_fl2v_turbo_4step_v1.0_768p_Q8_CR.gguf

NOTE:
  #5 is not touched.
  First launch may compile kernels and be slower.
============================================================
EOF

log "Starting ComfyUI"
exec "$ROOT/start_16_h3_speedlab.sh"
