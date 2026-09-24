#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# #16 v3 - MiniMax H3 Quality x Speed
# Robust RunPod setup / 2026-09-24
#
# MAIN (required):
#   Ref2VA INT8 ConvRot + Turbo 4-step + Ref2VA-VSA
#
# OPTIONAL:
#   VDN-H3 comparison path (never blocks the main install)
#
# Fixes vs v2:
#   - no interactive GitHub credential prompt
#   - VDN is optional, because VSA is the primary/faster path
#   - correct HF repos / filenames from current upstream README
#   - reuses existing #5 model files when present
#   - removes obsolete external FunControl dependency
#     (current ComfyUI has native H3 FunControl support)
# ============================================================

ROOT="${ROOT:-/workspace/runpod-slim}"
COMFY="${ROOT}/ComfyUI-H3-SpeedLab16"
PORT="${PORT:-8188}"
PYTHON="${PYTHON:-python3.12}"
WF_DIR="${COMFY}/user/default/workflows"
INPUT_DIR="${COMFY}/input"

export HF_HUB_ENABLE_HF_TRANSFER=1
export GIT_TERMINAL_PROMPT=0

log(){ printf '\n\033[1;36m[#16 v3]\033[0m %s\n' "$*"; }
warn(){ printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\n\033[1;31m[FATAL]\033[0m %s\n' "$*" >&2; exit 1; }
trap 'echo "[ERROR] line=$LINENO command=$BASH_COMMAND" >&2' ERR

mkdir -p "$ROOT"
cd "$ROOT"

log "GPU / disk"
nvidia-smi || true
df -h / /workspace || true

# ---------- system ----------
log "Installing system packages"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git git-lfs curl wget aria2 tar unzip python3.12 python3.12-venv python3-pip
git lfs install || true

# ---------- ComfyUI ----------
if [[ ! -d "$COMFY/.git" ]]; then
  log "Installing fresh ComfyUI"
  rm -rf "$COMFY"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
else
  log "Updating existing #16 ComfyUI"
  git -C "$COMFY" pull --ff-only || warn "ComfyUI pull failed; continuing with current checkout"
fi

cd "$COMFY"

if [[ ! -x .venv/bin/python ]]; then
  "$PYTHON" -m venv .venv
fi
source .venv/bin/activate
python -m pip install -U pip setuptools wheel

log "Installing ComfyUI requirements"
pip install -r requirements.txt
pip install -U comfy-kitchen huggingface_hub hf_transfer safetensors

mkdir -p \
  custom_nodes \
  models/diffusion_models \
  models/text_encoders \
  models/vae \
  models/loras \
  models/controlnet \
  models/vdn \
  "$WF_DIR" "$INPUT_DIR"

# ------------------------------------------------------------
# Robust GitHub downloader:
# 1) non-interactive git clone
# 2) codeload tarball main
# 3) codeload tarball master
# ------------------------------------------------------------
install_gh_repo () {
  local owner="$1" repo="$2" dst="$3" required="${4:-yes}"
  local url="https://github.com/${owner}/${repo}.git"
  local tmp="/tmp/${repo}.$$"

  rm -rf "$tmp"
  mkdir -p "$tmp"

  if [[ -d "$dst" ]]; then
    rm -rf "$dst"
  fi

  log "Installing ${owner}/${repo}"

  if timeout 60 git -c credential.helper= clone --depth 1 "$url" "$dst" </dev/null; then
    return 0
  fi

  warn "git clone failed for ${owner}/${repo}; trying codeload"

  for branch in main master; do
    rm -rf "$tmp/src" "$tmp/repo.tar.gz"
    mkdir -p "$tmp/src"
    if curl -fL --retry 3 --connect-timeout 15 \
      "https://codeload.github.com/${owner}/${repo}/tar.gz/refs/heads/${branch}" \
      -o "$tmp/repo.tar.gz"; then
      tar -xzf "$tmp/repo.tar.gz" -C "$tmp/src"
      local top
      top="$(find "$tmp/src" -mindepth 1 -maxdepth 1 -type d | head -1)"
      if [[ -n "$top" ]]; then
        mv "$top" "$dst"
        rm -rf "$tmp"
        return 0
      fi
    fi
  done

  rm -rf "$tmp"
  if [[ "$required" == "yes" ]]; then
    die "Could not install required repo ${owner}/${repo}"
  else
    warn "Optional repo ${owner}/${repo} unavailable; skipping it."
    return 1
  fi
}

# ---------- required node ----------
install_gh_repo "Kablex" "ComfyUI-Ref2VA-VSA" \
  "$COMFY/custom_nodes/ComfyUI-Ref2VA-VSA" yes

if [[ -f custom_nodes/ComfyUI-Ref2VA-VSA/requirements.txt ]]; then
  pip install -r custom_nodes/ComfyUI-Ref2VA-VSA/requirements.txt || \
    warn "VSA requirements had a non-critical install warning"
fi

# ---------- optional VDN ----------
VDN_OK=0
if install_gh_repo "Saganaki22" "ComfyUI-VDN-H3" \
  "$COMFY/custom_nodes/ComfyUI-VDN-H3" no; then
  VDN_OK=1
fi

# ---------- required model helper ----------
# Reuse existing model in /workspace/runpod-slim first.
reuse_or_hf () {
  local filename="$1"
  local destdir="$2"
  local repo="$3"
  local repopath="$4"
  local required="${5:-yes}"

  mkdir -p "$destdir"
  local dest="${destdir}/${filename}"

  if [[ -s "$dest" ]]; then
    echo "[OK existing] $dest"
    return 0
  fi

  # Find a copy in another ComfyUI environment, excluding current destination.
  local found=""
  found="$(find "$ROOT" -type f -name "$filename" \
      ! -path "$COMFY/*" -size +1M 2>/dev/null | head -1 || true)"

  if [[ -n "$found" ]]; then
    log "Reusing existing model: $filename"
    ln -sf "$found" "$dest"
    echo "[LINK] $dest -> $found"
    return 0
  fi

  log "Downloading $filename from HF: $repo"
  if hf download "$repo" "$repopath" --local-dir /tmp/hf16.$$ >/tmp/hf16_path.$$ 2>/tmp/hf16_err.$$; then
    local downloaded="/tmp/hf16.$$/${repopath}"
    if [[ -s "$downloaded" ]]; then
      mv "$downloaded" "$dest"
      rm -rf /tmp/hf16.$$ /tmp/hf16_path.$$ /tmp/hf16_err.$$
      return 0
    fi
  fi

  cat /tmp/hf16_err.$$ 2>/dev/null || true
  rm -rf /tmp/hf16.$$ /tmp/hf16_path.$$ /tmp/hf16_err.$$ || true

  if [[ "$required" == "yes" ]]; then
    die "Required model unavailable: $filename
If Hugging Face says 401, the Comfy-Org H3 repo requires access/token.
If #5 exists, keep it under /workspace/runpod-slim so v3 can auto-reuse the file."
  else
    warn "Optional model unavailable: $filename"
    return 1
  fi
}

# ---------- H3 core assets ----------
# Exact current upstream repo/path names.
reuse_or_hf \
  "minimax_h3_ref2va_pruned_int8_convrot.safetensors" \
  "$COMFY/models/diffusion_models" \
  "Comfy-Org/MiniMax_H3_repackaged" \
  "split_files/diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors" yes

reuse_or_hf \
  "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" \
  "$COMFY/models/text_encoders" \
  "Comfy-Org/MiniMax_H3_repackaged" \
  "split_files/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" yes

reuse_or_hf \
  "minimax_h3_video_vae_fp16.safetensors" \
  "$COMFY/models/vae" \
  "Comfy-Org/MiniMax_H3_repackaged" \
  "split_files/vae/minimax_h3_video_vae_fp16.safetensors" yes

reuse_or_hf \
  "minimax_h3_audio_vae_fp32.safetensors" \
  "$COMFY/models/vae" \
  "Comfy-Org/MiniMax_H3_repackaged" \
  "split_files/vae/minimax_h3_audio_vae_fp32.safetensors" yes

# VSA gate: public upstream-linked repo
reuse_or_hf \
  "fasth3_vsa_gate.safetensors" \
  "$COMFY/models/loras" \
  "barelymining/ComfyUI-MiniMax-H3-FastVideo" \
  "fasth3_vsa_gate.safetensors" yes

# Ref2V 4-step Turbo LoRA: public LightX2V repo
reuse_or_hf \
  "minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors" \
  "$COMFY/models/loras" \
  "lightx2v/Minimax-h3-Turbo" \
  "minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors" yes

# ---------- VDN checkpoint: OPTIONAL ----------
if [[ "$VDN_OK" == "1" ]]; then
  log "Downloading optional official VDN 8-step checkpoint"
  if hf download OpenVDN/vdn-minimax-h3 \
      --include "stage-dmd-step-250/*" \
      --local-dir "$COMFY/models/vdn"; then
    echo "[OK] VDN stage installed"
  else
    warn "VDN weights unavailable; VSA main workflow is unaffected."
    VDN_OK=0
  fi
fi

# ---------- workflow ----------
log "Installing tested VSA workflow"
SRC_WF="$COMFY/custom_nodes/ComfyUI-Ref2VA-VSA/workflows/ref2va_vsa_4step_rtx4090.json"
[[ -s "$SRC_WF" ]] || die "Upstream VSA workflow missing: $SRC_WF"

cp -f "$SRC_WF" "$WF_DIR/16A_H3_REF2VA_VSA_4STEP_SPEED.json"
cp -f "$SRC_WF" "$WF_DIR/UPSTREAM_ref2va_vsa_4step_rtx4090.json"

# copy VDN examples only if available
if [[ "$VDN_OK" == "1" ]]; then
  n=0
  while IFS= read -r -d '' f; do
    n=$((n+1))
    cp -f "$f" "$WF_DIR/16B_VDN_${n}_$(basename "$f")"
  done < <(find "$COMFY/custom_nodes/ComfyUI-VDN-H3" \
    -type f -iname "*.json" \( -path "*/example_workflows/*" -o -path "*/workflows/*" \) -print0 2>/dev/null)
fi

# ---------- example input ----------
if [[ -s "$COMFY/custom_nodes/ComfyUI-Ref2VA-VSA/assets/example_character.jpg" ]]; then
  cp -f "$COMFY/custom_nodes/ComfyUI-Ref2VA-VSA/assets/example_character.jpg" \
    "$INPUT_DIR/example_character.jpg"
elif [[ -s "$COMFY/custom_nodes/ComfyUI-Ref2VA-VSA/example_character.jpg" ]]; then
  cp -f "$COMFY/custom_nodes/ComfyUI-Ref2VA-VSA/example_character.jpg" \
    "$INPUT_DIR/example_character.jpg"
fi

# ---------- launcher ----------
cat > "$ROOT/start_16_h3_speedlab_v3.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
cd /workspace/runpod-slim/ComfyUI-H3-SpeedLab16
source .venv/bin/activate
exec python main.py \
  --listen 0.0.0.0 \
  --port 8188 \
  --reserve-vram 3
EOF
chmod +x "$ROOT/start_16_h3_speedlab_v3.sh"

# ---------- preflight import ----------
log "Preflight checks"
python - <<'PY'
from pathlib import Path
C=Path("/workspace/runpod-slim/ComfyUI-H3-SpeedLab16")
required=[
 C/"models/diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors",
 C/"models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
 C/"models/vae/minimax_h3_video_vae_fp16.safetensors",
 C/"models/vae/minimax_h3_audio_vae_fp32.safetensors",
 C/"models/loras/fasth3_vsa_gate.safetensors",
 C/"models/loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors",
 C/"custom_nodes/ComfyUI-Ref2VA-VSA/nodes.py",
 C/"user/default/workflows/16A_H3_REF2VA_VSA_4STEP_SPEED.json",
]
missing=[]
for p in required:
    ok=p.exists() or p.is_symlink()
    print(("[OK]   " if ok else "[MISS] "), p)
    if not ok: missing.append(str(p))
if missing:
    raise SystemExit("Required #16 files missing:\n"+"\n".join(missing))
PY

# Check comfy-kitchen's sol_attn import without failing the setup solely on API naming.
python - <<'PY'
try:
    import comfy_kitchen
    print("[OK] comfy_kitchen import")
except Exception as e:
    raise SystemExit(f"comfy_kitchen import failed: {e}")
PY

cat <<EOF

============================================================
 #16 v3 READY
============================================================

Main workflow:
  16A_H3_REF2VA_VSA_4STEP_SPEED.json

Main pipeline:
  Ref2VA INT8 ConvRot
  + Ref2V Turbo 4-step
  + VSA gate
  + sparsity 0.75
  + Euler / simple

Start:
  $ROOT/start_16_h3_speedlab_v3.sh

Port:
  8188

VDN optional:
  $( [[ "$VDN_OK" == "1" ]] && echo "installed" || echo "skipped (main VSA path unaffected)" )

#5:
  untouched

============================================================
EOF

log "Starting ComfyUI"
exec "$ROOT/start_16_h3_speedlab_v3.sh"
