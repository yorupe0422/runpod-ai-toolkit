#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# #16 v6-nochmod - MiniMax H3 Ref2VA VSA 4-step
# For RunPod /workspace filesystems where chmod/git clone fails
# ============================================================

ROOT="${ROOT:-/workspace/runpod-slim}"
COMFY="${ROOT}/ComfyUI-H3-SpeedLab16"
PORT="${PORT:-8188}"
WF_DIR="${COMFY}/user/default/workflows"

export GIT_TERMINAL_PROMPT=0
export HF_XET_HIGH_PERFORMANCE=1

log(){ printf '\n\033[1;36m[#16 v6]\033[0m %s\n' "$*"; }
warn(){ printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\n\033[1;31m[FATAL]\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$ROOT"
cd "$ROOT"

log "GPU / disk check"
nvidia-smi || true
df -h / /workspace || true

log "System dependencies"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl wget aria2 tar python3.12 python3.12-venv python3-pip

# ------------------------------------------------------------
# Tarball installer: avoids chmod-sensitive git metadata entirely
# ------------------------------------------------------------
install_tar_repo () {
  local owner="$1"
  local repo="$2"
  local dst="$3"
  local tmp="/tmp/${repo}_$$"

  rm -rf "$tmp" "$dst"
  mkdir -p "$tmp"

  for branch in master main; do
    log "Fetch ${owner}/${repo} (${branch})"
    if curl -fL --retry 3 --connect-timeout 15 \
      "https://codeload.github.com/${owner}/${repo}/tar.gz/refs/heads/${branch}" \
      -o "$tmp/repo.tar.gz"; then

      mkdir -p "$tmp/unpack"
      tar -xzf "$tmp/repo.tar.gz" -C "$tmp/unpack"

      top="$(find "$tmp/unpack" -mindepth 1 -maxdepth 1 -type d | head -1)"
      if [[ -n "$top" ]]; then
        mv "$top" "$dst"
        rm -rf "$tmp"
        return 0
      fi
    fi
  done

  rm -rf "$tmp"
  return 1
}

# ---------- ComfyUI ----------
if [[ ! -f "$COMFY/main.py" ]]; then
  log "Install ComfyUI via codeload tarball (no git/chmod)"
  install_tar_repo "comfyanonymous" "ComfyUI" "$COMFY" || \
    die "Could not download ComfyUI tarball"
else
  log "Reuse existing ComfyUI directory"
fi

cd "$COMFY"

# venv itself may create executable bits internally; on this mount python still
# works because invoking the interpreter path directly does not require chmod changes.
if [[ ! -f .venv/bin/python ]]; then
  log "Create Python venv"
  python3.12 -m venv .venv
fi

PY="$COMFY/.venv/bin/python"
PIP="$PY -m pip"

$PIP install -U pip setuptools wheel
$PIP install -r requirements.txt
$PIP install -U comfy-kitchen huggingface_hub hf_xet safetensors

mkdir -p \
  custom_nodes \
  models/diffusion_models \
  models/text_encoders \
  models/vae \
  models/loras \
  input \
  "$WF_DIR"

# ---------- Ref2VA-VSA ----------
if [[ ! -f custom_nodes/ComfyUI-Ref2VA-VSA/nodes.py ]]; then
  log "Install Ref2VA-VSA via tarball"
  install_tar_repo "Kablex" "ComfyUI-Ref2VA-VSA" \
    "$COMFY/custom_nodes/ComfyUI-Ref2VA-VSA" || \
    die "Could not download Kablex/ComfyUI-Ref2VA-VSA"
else
  log "VSA node already present"
fi

if [[ -f custom_nodes/ComfyUI-Ref2VA-VSA/requirements.txt ]]; then
  $PIP install -r custom_nodes/ComfyUI-Ref2VA-VSA/requirements.txt
fi

# ---------- model helper ----------
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
    # Copy instead of symlink to avoid filesystem quirks.
    cp -f "$found" "$dest"
    echo "[COPY] $dest <- $found"
    return 0
  fi

  log "Download $repo / $hfpath"
  local tmp="/tmp/hf16v6_${RANDOM}_${RANDOM}"
  rm -rf "$tmp"
  mkdir -p "$tmp"

  if ! "$COMFY/.venv/bin/hf" download "$repo" "$hfpath" --local-dir "$tmp"; then
    rm -rf "$tmp"
    die "Download failed: $repo/$hfpath"
  fi

  if [[ ! -s "$tmp/$hfpath" ]]; then
    rm -rf "$tmp"
    die "Downloaded file missing: $tmp/$hfpath"
  fi

  cp -f "$tmp/$hfpath" "$dest"
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
  warn "Official fallback workflow download failed; VSA workflow is intact."

# ---------- sanity ----------
log "Sanity check"
"$PY" - <<'PY'
from pathlib import Path
C=Path("/workspace/runpod-slim/ComfyUI-H3-SpeedLab16")
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
    print(("[OK]   " if ok else "[MISS] "), p)
    if not ok:
        missing.append(str(p))
if missing:
    raise SystemExit("Missing required files:\n"+"\n".join(missing))
PY

# launcher is a plain text shell file; invoke with "bash", no chmod required.
cat > "$ROOT/start_16_h3_speedlab_v6.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
cd /workspace/runpod-slim/ComfyUI-H3-SpeedLab16
exec .venv/bin/python main.py \
  --listen 0.0.0.0 \
  --port 8188 \
  --reserve-vram 3
EOF

cat <<'EOF'

============================================================
 #16 v6 READY
============================================================

Main workflow:
  16A_H3_REF2VA_VSA_4STEP_SPEED.json

Start:
  bash /workspace/runpod-slim/start_16_h3_speedlab_v6.sh

Port:
  8188

This build intentionally avoids:
  - chmod
  - git clone
  - symlink-based model reuse

to support this RunPod /workspace filesystem.
============================================================
EOF

log "Start ComfyUI"
exec "$PY" main.py \
  --listen 0.0.0.0 \
  --port "$PORT" \
  --reserve-vram 3
