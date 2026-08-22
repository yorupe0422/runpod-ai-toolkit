#!/usr/bin/env bash
set -Eeuo pipefail

# RunPod one-shot installer: independent Qwen-Image-Edit-2511 Studio for ComfyUI.
# Target: NVIDIA RTX 5090 / 32 GB. No existing ComfyUI environment is required.

SCRIPT_VERSION="7.0.0"

ROOT="${RUNPOD_ROOT:-/workspace/runpod-slim}"
COMFY="${QWEN_COMFY_DIR:-$ROOT/ComfyUI-QwenImageEdit}"
VENV="$COMFY/.venv"
PYTHON_BIN="$VENV/bin/python"
PORT="${RUNPOD_PORT:-8188}"
LOG="$ROOT/qwen_image_edit_studio_setup.log"
RUN_LOG="$ROOT/comfyui-qwen-image-edit.log"
PID_FILE="$ROOT/comfyui-qwen-image-edit.pid"
LOCK_FILE="$ROOT/.qwen-image-edit-studio-setup.lock"
MARKER="$COMFY/.qwen-image-edit-studio-managed"
STARTER="$ROOT/start_qwen_image_edit.sh"
STOPPER="$ROOT/stop_qwen_image_edit.sh"

COMFY_REPO="https://github.com/Comfy-Org/ComfyUI.git"
COMFY_COMMIT="72865f4f27eaf5396f8f36370e0a2be3a9a090ee" # v0.33.1
WORKFLOW_COMMIT="810241e1e329f924a29143dc9cbd432bc3638a4a" # workflow templates v0.11.44
WORKFLOW_URL="https://raw.githubusercontent.com/Comfy-Org/workflow_templates/$WORKFLOW_COMMIT/templates/image_qwen_image_edit_2511.json"
WORKFLOW_SHA="d561a38c15bd7d08758a5e6773d467142244d5b83fc5d3aecdf6d8df9fe881b6"

MODEL_FILE="qwen_image_edit_2511_fp8mixed.safetensors"
CLIP_FILE="qwen_2.5_vl_7b_fp8_scaled.safetensors"
VAE_FILE="qwen_image_vae.safetensors"
LIGHTNING_FILE="Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"
A2R_FILE="anything2real_2601_A_final_patched.safetensors"
ANYPOSE_BASE_FILE="2511-AnyPose-base-000006250.safetensors"
ANYPOSE_HELPER_FILE="2511-AnyPose-helper-00006000.safetensors"

WF_GENERAL_QUALITY="01_QWEN_GENERAL_EDIT_QUALITY_40STEP.json"
WF_GENERAL_FAST="02_QWEN_GENERAL_EDIT_FAST_4STEP.json"
WF_PERSON_QUALITY="03_QWEN_PERSON_REPLACE_QUALITY_40STEP.json"
WF_PERSON_FAST="04_QWEN_PERSON_REPLACE_FAST_4STEP.json"
WF_A2R="05_QWEN_ANYTHING2REAL_2601A.json"
WF_ANYPOSE="06_QWEN_ANYPOSE_4STEP.json"
WF_CLOTHES="07_QWEN_CLOTHING_TRANSFER_QUALITY.json"
WF_MULTI="08_QWEN_THREE_IMAGE_REFERENCE_QUALITY.json"

export PYTHONUNBUFFERED=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
export HF_HUB_DOWNLOAD_TIMEOUT=600
export HF_HUB_ETAG_TIMEOUT=60
export HF_HOME="$ROOT/.cache/huggingface-qwen-image-edit"

mkdir -p "$ROOT"
touch "$LOG"
exec > >(tee -a "$LOG") 2>&1

die() { echo "[FATAL] $*" >&2; exit 1; }
step() { echo; echo "===== $* ====="; }
ok() { echo "[OK] $*"; }
warn() { echo "[WARN] $*"; }

TMP_WORKFLOW=""
CURL_AUTH_CONFIG=""
OBJECT_INFO=""

cleanup() {
  [[ -z "${TMP_WORKFLOW:-}" ]] || rm -f "$TMP_WORKFLOW" || true
  [[ -z "${CURL_AUTH_CONFIG:-}" ]] || rm -f "$CURL_AUTH_CONFIG" || true
  [[ -z "${OBJECT_INFO:-}" ]] || rm -f "$OBJECT_INFO" || true
}

on_error() {
  local code=$?
  echo
  echo "QWEN IMAGE EDIT STUDIO SETUP FAILED (exit=$code, line=${BASH_LINENO[0]})"
  echo "Log: $LOG"
  echo "The installer is rerun-safe. Fix the reported cause, then run the same SH again."
  exit "$code"
}

trap on_error ERR
trap cleanup EXIT

step "QWEN IMAGE EDIT 2511 STUDIO — INDEPENDENT SETUP"
echo "Installer version : $SCRIPT_VERSION"
echo "Install directory : $COMFY"
echo "Port              : $PORT"

[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || \
  die "RUNPOD_PORT must be an integer from 1 to 65535"

step "[1/11] System and GPU preflight"
missing_tools=0
for cmd in git curl sha256sum stat df awk grep tee mktemp flock fuser; do
  command -v "$cmd" >/dev/null 2>&1 || missing_tools=1
done
if (( missing_tools )); then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git curl ca-certificates coreutils procps util-linux psmisc python3-venv
fi
for cmd in git curl sha256sum stat df awk grep tee mktemp flock fuser; do
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done
exec 9>"$LOCK_FILE"
flock -n 9 || die "Another Qwen Image Edit setup is already running"
command -v nvidia-smi >/dev/null 2>&1 || die "NVIDIA driver/GPU not found"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
gpu_mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -dc '0-9')"
[[ -n "$gpu_mib" ]] || die "Could not read GPU VRAM"
(( gpu_mib >= 24000 )) || die "At least 24 GB VRAM is required; detected ${gpu_mib} MiB"
ok "GPU preflight passed (${gpu_mib} MiB)"

if [[ -n "${HF_TOKEN:-}" ]]; then
  ok "HF_TOKEN detected (the value will not be printed)"
else
  warn "HF_TOKEN is not set. Public downloads can work, but shared-IP rate limits are more likely."
  echo "      You may stop now, set HF_TOKEN, and rerun without losing completed downloads."
fi

step "[2/11] Independent ComfyUI core (pinned v0.33.1)"
if [[ -e "$COMFY" && ! -d "$COMFY/.git" ]]; then
  preserved="$COMFY.incomplete.$(date +%Y%m%d%H%M%S)"
  mv "$COMFY" "$preserved"
  warn "Non-git or interrupted directory preserved at $preserved"
fi
if [[ ! -d "$COMFY/.git" ]]; then
  git clone --filter=blob:none --no-checkout "$COMFY_REPO" "$COMFY"
fi
git -C "$COMFY" remote set-url origin "$COMFY_REPO"
git -C "$COMFY" fetch --prune --filter=blob:none origin "$COMFY_COMMIT"
git -C "$COMFY" cat-file -e "$COMFY_COMMIT^{commit}" 2>/dev/null || \
  die "Pinned ComfyUI commit is unavailable: $COMFY_COMMIT"
if [[ -n "$(git -C "$COMFY" status --porcelain --untracked-files=no)" ]]; then
  die "Tracked local changes exist in $COMFY; refusing to overwrite them"
fi
git -C "$COMFY" switch -C qwen-image-edit-studio "$COMFY_COMMIT"
[[ "$(git -C "$COMFY" rev-parse HEAD)" == "$COMFY_COMMIT" ]] || \
  die "ComfyUI commit verification failed"
printf '%s\n' "version=$SCRIPT_VERSION" "comfy_commit=$COMFY_COMMIT" > "$MARKER"

grep -Fq 'TextEncodeQwenImageEditPlus' "$COMFY/comfy_extras/nodes_qwen.py" || \
  die "Pinned ComfyUI lacks TextEncodeQwenImageEditPlus"
grep -Fq 'FluxKontextMultiReferenceLatentMethod' "$COMFY/comfy_extras/nodes_flux.py" || \
  die "Pinned ComfyUI lacks multi-reference Qwen support"
for flag in '--reserve-vram' '--cache-none' '--disable-all-custom-nodes'; do
  grep -Fq -- "$flag" "$COMFY/comfy/cli_args.py" || die "Missing ComfyUI flag: $flag"
done
ok "ComfyUI pinned at $COMFY_COMMIT on a normal local branch"

step "[3/11] Fully isolated Python environment"
BASE_PYTHON="$(command -v python3 || true)"
[[ -n "$BASE_PYTHON" && -x "$BASE_PYTHON" ]] || die "python3 not found"
"$BASE_PYTHON" -c 'import sys; assert (3,10) <= sys.version_info[:2] <= (3,14)' 2>/dev/null || \
  die "Python 3.10 through 3.14 is required"

if [[ -e "$VENV" ]] && ! "$PYTHON_BIN" -c 'import sys; assert sys.prefix != sys.base_prefix' >/dev/null 2>&1; then
  preserved_venv="$VENV.invalid.$(date +%Y%m%d%H%M%S)"
  mv "$VENV" "$preserved_venv"
  warn "Invalid venv preserved at $preserved_venv"
fi
if [[ ! -x "$PYTHON_BIN" ]]; then
  "$BASE_PYTHON" -m venv "$VENV" || {
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv
    "$BASE_PYTHON" -m venv "$VENV"
  }
fi
"$PYTHON_BIN" -m pip install --upgrade "pip<27" "setuptools>=75,<82" wheel

# CUDA 12.8 is Blackwell/RTX 5090 compatible. Pin torch itself; let pip select
# its matching torchvision and torchaudio builds from the same official index.
"$PYTHON_BIN" -m pip install --upgrade \
  --index-url https://download.pytorch.org/whl/cu128 \
  "torch==2.11.0" "torchvision==0.26.0" "torchaudio==2.11.0"

CONSTRAINTS="$(mktemp)"
printf '%s\n' \
  'torch==2.11.0' \
  'torchvision==0.26.0' \
  'torchaudio==2.11.0' \
  'setuptools>=75,<82' \
  'transformers>=4.50.3,<6' > "$CONSTRAINTS"
"$PYTHON_BIN" -m pip install --upgrade-strategy only-if-needed \
  -c "$CONSTRAINTS" -r "$COMFY/requirements.txt"
"$PYTHON_BIN" -m pip install --upgrade-strategy only-if-needed \
  -c "$CONSTRAINTS" huggingface_hub hf_xet
rm -f "$CONSTRAINTS"
"$PYTHON_BIN" -m pip install "setuptools>=75,<82"
"$PYTHON_BIN" -m pip check

"$PYTHON_BIN" - <<'PY'
import torch
if not torch.cuda.is_available():
    raise SystemExit("CUDA is not available inside the dedicated venv")
name = torch.cuda.get_device_name(0)
cap = torch.cuda.get_device_capability(0)
print(f"[OK] PyTorch {torch.__version__}; CUDA {torch.version.cuda}; GPU {name}; capability {cap[0]}.{cap[1]}")
PY
ok "Dedicated Python: $PYTHON_BIN"

step "[4/11] Model directories and disk preflight"
mkdir -p \
  "$COMFY/models/diffusion_models" \
  "$COMFY/models/text_encoders" \
  "$COMFY/models/vae" \
  "$COMFY/models/loras" \
  "$COMFY/input" \
  "$COMFY/output" \
  "$COMFY/user/default/workflows" \
  "$HF_HOME"

file_ok() {
  local path="$1" expected_size="$2" expected_sha="$3" actual_size actual_sha
  [[ -f "$path" ]] || return 1
  actual_size="$(stat -c '%s' "$path" 2>/dev/null || printf 0)"
  [[ "$actual_size" == "$expected_size" ]] || return 1
  actual_sha="$(sha256sum "$path" | awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]]
}

preserve_invalid() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  local bad="$path.invalid.$(date +%Y%m%d%H%M%S)"
  mv "$path" "$bad"
  warn "Invalid file preserved at $bad"
}

reuse_local_verified() {
  local dest="$1" expected_size="$2" expected_sha="$3" base candidate part
  file_ok "$dest" "$expected_size" "$expected_sha" && return 0
  [[ -e "$dest" ]] && preserve_invalid "$dest"
  base="$(basename "$dest")"
  while IFS= read -r -d '' candidate; do
    [[ "$candidate" == "$dest" ]] && continue
    if file_ok "$candidate" "$expected_size" "$expected_sha"; then
      part="$dest.reuse.part"
      rm -f "$part"
      if ln "$candidate" "$part" 2>/dev/null; then
        :
      else
        cp --reflink=auto "$candidate" "$part"
      fi
      mv -f "$part" "$dest"
      ok "Reused verified local model: $base"
      return 0
    fi
  done < <(find "$ROOT" -type f -name "$base" -print0 2>/dev/null)
  return 1
}

declare -a MODEL_PATHS=(
  "$COMFY/models/diffusion_models/$MODEL_FILE"
  "$COMFY/models/text_encoders/$CLIP_FILE"
  "$COMFY/models/vae/$VAE_FILE"
  "$COMFY/models/loras/$LIGHTNING_FILE"
  "$COMFY/models/loras/$A2R_FILE"
  "$COMFY/models/loras/$ANYPOSE_BASE_FILE"
  "$COMFY/models/loras/$ANYPOSE_HELPER_FILE"
)
declare -a MODEL_SIZES=(
  20533762817 9384670680 253806246 849608296 613580128 295146208 295146216
)
declare -a MODEL_SHAS=(
  c9fdc158e46d3b61ef75f21ae866ca2fe808bf4a53643120d1c1e87c19280a4e
  cb5636d852a0ea6a9075ab1bef496c0db7aef13c02350571e388aea959c5c0b4
  a70580f0213e67967ee9c95f05bb400e8fb08307e017a924bf3441223e023d1f
  22226e8d05d354bb356627d428809f5afd7819399b077238a2b70a82883a904f
  d4cbbabf5610a8f0ea3f530dc0bc9e8a254be6563c4738795bea45d247903528
  0396314e43b94f7520cf5242e6aa6e8e9095d784f7e87ee45980c2e541ee8c4d
  674340c62fff3cf981d0cfc55daf2f0e6f51c56b50159e241d931748200cf1eb
)

for i in "${!MODEL_PATHS[@]}"; do
  reuse_local_verified "${MODEL_PATHS[$i]}" "${MODEL_SIZES[$i]}" "${MODEL_SHAS[$i]}" || true
done

# Reserve 12 GB for the venv, downloads in progress, logs and workflow data.
needed_bytes=12000000000
for i in "${!MODEL_PATHS[@]}"; do
  if ! file_ok "${MODEL_PATHS[$i]}" "${MODEL_SIZES[$i]}" "${MODEL_SHAS[$i]}"; then
    needed_bytes=$((needed_bytes + MODEL_SIZES[$i]))
  fi
done
available_bytes="$(df -PB1 "$ROOT" | awk 'NR==2 {print $4}')"
[[ "$available_bytes" =~ ^[0-9]+$ ]] || die "Could not determine free disk space"
(( available_bytes >= needed_bytes )) || \
  die "Insufficient disk: need about $((needed_bytes / 1000000000)) GB free; have $((available_bytes / 1000000000)) GB"
ok "Disk preflight: $((available_bytes / 1000000000)) GB free"

step "[5/11] Verified resumable model downloads"
CURL_AUTH_CONFIG="$(mktemp)"
chmod 600 "$CURL_AUTH_CONFIG"
if [[ -n "${HF_TOKEN:-}" ]]; then
  printf 'header = "Authorization: Bearer %s"\n' "$HF_TOKEN" > "$CURL_AUTH_CONFIG"
fi

download_hf() {
  local repo="$1" revision="$2" remote="$3" dest="$4" expected_size="$5" expected_sha="$6"
  local url part attempt=1 delay=60 curl_code=0 actual_size
  if file_ok "$dest" "$expected_size" "$expected_sha"; then
    echo "[SKIP] $(basename "$dest") verified"
    return 0
  fi
  reuse_local_verified "$dest" "$expected_size" "$expected_sha" && return 0
  url="https://huggingface.co/$repo/resolve/$revision/$remote?download=true"
  part="$dest.part"
  echo "[DOWNLOAD] $repo :: $remote"
  echo "[INFO] Interrupted downloads resume from $part"
  while (( attempt <= 7 )); do
    curl_code=0
    if [[ -s "$part" ]]; then
      echo "[RESUME] $(basename "$dest") at $(stat -c '%s' "$part") bytes (outer attempt $attempt/7)"
      curl --config "$CURL_AUTH_CONFIG" -fL -C - \
        --connect-timeout 30 --retry 12 --retry-all-errors --retry-delay 20 \
        --speed-limit 1024 --speed-time 300 \
        "$url" -o "$part" || curl_code=$?
      if (( curl_code == 33 || curl_code == 36 )); then
        preserve_invalid "$part"
        curl_code=0
        curl --config "$CURL_AUTH_CONFIG" -fL \
          --connect-timeout 30 --retry 12 --retry-all-errors --retry-delay 20 \
          --speed-limit 1024 --speed-time 300 \
          "$url" -o "$part" || curl_code=$?
      fi
    else
      curl --config "$CURL_AUTH_CONFIG" -fL \
        --connect-timeout 30 --retry 12 --retry-all-errors --retry-delay 20 \
        --speed-limit 1024 --speed-time 300 \
        "$url" -o "$part" || curl_code=$?
    fi

    if (( curl_code == 0 )) && file_ok "$part" "$expected_size" "$expected_sha"; then
      mv -f "$part" "$dest"
      ok "$(basename "$dest") verified ($expected_size bytes)"
      return 0
    fi

    actual_size="$(stat -c '%s' "$part" 2>/dev/null || printf 0)"
    if (( actual_size >= expected_size )); then
      preserve_invalid "$part"
    fi
    if (( attempt == 7 )); then
      die "Download failed after 7 outer attempts: $(basename "$dest")"
    fi
    warn "Download interrupted or rate-limited (curl=$curl_code). Partial data is preserved."
    echo "[WAIT] Retry in ${delay}s; rerunning this SH later is also safe."
    sleep "$delay"
    (( delay < 600 )) && delay=$((delay * 2))
    (( delay > 600 )) && delay=600
    ((attempt++))
  done
}

download_hf "Comfy-Org/Qwen-Image-Edit_ComfyUI" \
  "272e47a0dc9a56fd607dbf48a8cbd2af68f27007" \
  "split_files/diffusion_models/$MODEL_FILE" \
  "$COMFY/models/diffusion_models/$MODEL_FILE" \
  20533762817 c9fdc158e46d3b61ef75f21ae866ca2fe808bf4a53643120d1c1e87c19280a4e

download_hf "Comfy-Org/HunyuanVideo_1.5_repackaged" \
  "5d6f0b4fdd4100acda997de86dbda335578c0d0e" \
  "split_files/text_encoders/$CLIP_FILE" \
  "$COMFY/models/text_encoders/$CLIP_FILE" \
  9384670680 cb5636d852a0ea6a9075ab1bef496c0db7aef13c02350571e388aea959c5c0b4

download_hf "Comfy-Org/Qwen-Image_ComfyUI" \
  "7af1e265fb79c25d43669aea93aa5c51d7ad23e8" \
  "split_files/vae/$VAE_FILE" \
  "$COMFY/models/vae/$VAE_FILE" \
  253806246 a70580f0213e67967ee9c95f05bb400e8fb08307e017a924bf3441223e023d1f

download_hf "lightx2v/Qwen-Image-Edit-2511-Lightning" \
  "d74eba145674fd7e31b949324e148e21e7118abd" \
  "$LIGHTNING_FILE" \
  "$COMFY/models/loras/$LIGHTNING_FILE" \
  849608296 22226e8d05d354bb356627d428809f5afd7819399b077238a2b70a82883a904f

download_hf "lrzjason/Anything2Real" \
  "d6c07ea51e486f26b7e420b6fc3e19a88534c406" \
  "$A2R_FILE" \
  "$COMFY/models/loras/$A2R_FILE" \
  613580128 d4cbbabf5610a8f0ea3f530dc0bc9e8a254be6563c4738795bea45d247903528

download_hf "lilylilith/AnyPose" \
  "592f9165075ce443ab31fd22e6fd03e796b60b92" \
  "$ANYPOSE_BASE_FILE" \
  "$COMFY/models/loras/$ANYPOSE_BASE_FILE" \
  295146208 0396314e43b94f7520cf5242e6aa6e8e9095d784f7e87ee45980c2e541ee8c4d

download_hf "lilylilith/AnyPose" \
  "592f9165075ce443ab31fd22e6fd03e796b60b92" \
  "$ANYPOSE_HELPER_FILE" \
  "$COMFY/models/loras/$ANYPOSE_HELPER_FILE" \
  295146216 674340c62fff3cf981d0cfc55daf2f0e6f51c56b50159e241d931748200cf1eb

step "[6/11] Official workflow template and sample inputs"
download_url_atomic() {
  local url="$1" dest="$2" expected_sha="$3" part="$2.part" actual_sha
  if [[ -f "$dest" ]] && [[ "$(sha256sum "$dest" | awk '{print $1}')" == "$expected_sha" ]]; then
    echo "[SKIP] $(basename "$dest") verified"
    return 0
  fi
  curl -fL --retry 8 --retry-all-errors --connect-timeout 30 "$url" -o "$part"
  [[ -s "$part" ]] || die "Downloaded file is empty: $url"
  actual_sha="$(sha256sum "$part" | awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]] || \
    die "Checksum mismatch for $(basename "$dest"): expected $expected_sha, got $actual_sha"
  mv -f "$part" "$dest"
}

TMP_WORKFLOW="$(mktemp)"
download_url_atomic "$WORKFLOW_URL" "$TMP_WORKFLOW" "$WORKFLOW_SHA"
"$PYTHON_BIN" -m json.tool "$TMP_WORKFLOW" >/dev/null

download_url_atomic \
  "https://raw.githubusercontent.com/Comfy-Org/workflow_templates/$WORKFLOW_COMMIT/input/leather_sofa.png" \
  "$COMFY/input/qwen_sample_image_1.png" \
  be4387e734f14c5bad3f1328c1731d4ac6f85b9517566c4ddfb1d448d96d51c4
download_url_atomic \
  "https://raw.githubusercontent.com/Comfy-Org/workflow_templates/$WORKFLOW_COMMIT/input/texture_fur.png" \
  "$COMFY/input/qwen_sample_image_2.png" \
  6e837f6780f1b1e5674eab24f828ac2920e27eb8f9f7ae83583b77d057d7dc78

step "[7/11] Build eight ready-to-use workflows"
TEMPLATE="$TMP_WORKFLOW" WORKFLOW_DIR="$COMFY/user/default/workflows" \
WF_GENERAL_QUALITY="$WF_GENERAL_QUALITY" WF_GENERAL_FAST="$WF_GENERAL_FAST" \
WF_PERSON_QUALITY="$WF_PERSON_QUALITY" WF_PERSON_FAST="$WF_PERSON_FAST" \
WF_A2R="$WF_A2R" WF_ANYPOSE="$WF_ANYPOSE" WF_CLOTHES="$WF_CLOTHES" \
WF_MULTI="$WF_MULTI" "$PYTHON_BIN" - <<'PY'
import copy, json, os

with open(os.environ["TEMPLATE"], encoding="utf-8") as f:
    template = json.load(f)

LIGHTNING = "Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"
A2R = "anything2real_2601_A_final_patched.safetensors"
POSE_BASE = "2511-AnyPose-base-000006250.safetensors"
POSE_HELPER = "2511-AnyPose-helper-00006000.safetensors"
MODEL = "qwen_image_edit_2511_fp8mixed.safetensors"
CLIP = "qwen_2.5_vl_7b_fp8_scaled.safetensors"
VAE = "qwen_image_vae.safetensors"

PROMPTS = {
    "general_quality": "Describe only the change you want. Preserve every unmentioned subject, object, facial feature, body proportion, pose, camera angle, composition, background, lighting and text from image 1.",
    "general_fast": "Describe only the change you want. Preserve every unmentioned subject, object, facial feature, body proportion, pose, camera angle, composition, background, lighting and text from image 1.",
    "person_quality": "Replace the person in image 1 with the fictional adult person from image 2. Preserve the pose, body position, framing, camera angle, background, lighting and every non-person element of image 1. Transfer the adult person's facial identity, hairstyle, body appearance and clothing from image 2. Integrate the replacement naturally. Do not copy the background or pose from image 2.",
    "person_fast": "Replace the person in image 1 with the fictional adult person from image 2. Preserve the pose, body position, framing, camera angle, background, lighting and every non-person element of image 1. Transfer the adult person's facial identity, hairstyle, body appearance and clothing from image 2. Integrate the replacement naturally. Do not copy the background or pose from image 2.",
    "a2r": "Change image 1 into a realistic photograph while preserving the original composition, pose, identity, clothing, objects and camera angle. Natural light, realistic skin and materials, photographic detail.",
    "anypose": "Make the person in image 1 do the exact same pose as the person in image 2. Preserve the identity, clothing, style and background of image 1. Match the arms, hands, head, legs, camera angle, head tilt and eye gaze of image 2. Do not copy the background or identity from image 2.",
    "clothes": "Change only the clothing of the fictional adult person in image 1 to match the clothing shown in image 2. Preserve the identity, face, hair, body proportions, pose, hands, camera angle, composition, background and lighting of image 1. Do not copy the person, pose or background from image 2.",
    "multi": "Use image 1 as the base scene and composition. Use image 2 as the fictional adult character identity and appearance reference. Use image 3 as the clothing or style reference. Preserve the pose, camera angle, lighting and background of image 1. Integrate the references naturally without copying their backgrounds.",
}

NOTES = {
    "general_quality": "# Qwen General Edit — QUALITY\nInput 1: base image. One-image workflow.\nEdit the prompt, then run. 40-step quality mode.",
    "general_fast": "# Qwen General Edit — FAST\nInput 1: base image. One-image workflow.\nEdit the prompt, then run. 4-step Lightning test mode.",
    "person_quality": "# Person Replacement — QUALITY\nInput 1: target scene/body/pose/background.\nInput 2: clearly adult fictional reference person.\n40-step quality mode.",
    "person_fast": "# Person Replacement — FAST\nInput 1: target scene/body/pose/background.\nInput 2: clearly adult fictional reference person.\n4-step Lightning test mode.",
    "a2r": "# Anything2Real 2601A\nInput 1: illustration/anime/artwork to convert.\nOne-image workflow. LoRA strength starts at 0.85.",
    "anypose": "# AnyPose\nInput 1: identity/style/base image.\nInput 2: pose reference.\nBoth AnyPose LoRAs are set to 0.7; Lightning 4-step mode.",
    "clothes": "# Clothing Transfer — QUALITY\nInput 1: target adult person and scene.\nInput 2: clothing reference.\n40-step quality mode.",
    "multi": "# Three-Image Reference — QUALITY\nInput 1: base scene. Input 2: adult identity reference.\nInput 3: clothing/style reference. 40-step quality mode.",
}

OUTPUT_PREFIX = {
    "general_quality": "Qwen_General_Quality",
    "general_fast": "Qwen_General_Fast",
    "person_quality": "Qwen_Person_Replace_Quality",
    "person_fast": "Qwen_Person_Replace_Fast",
    "a2r": "Qwen_Anything2Real",
    "anypose": "Qwen_AnyPose",
    "clothes": "Qwen_Clothing_Transfer",
    "multi": "Qwen_Three_Reference",
}

def node_by_id(nodes, node_id):
    return next(n for n in nodes if n.get("id") == node_id)

def set_load(node, title, filename):
    node["title"] = title
    node["widgets_values"] = [filename, "image"]

def disconnect_second_image(data):
    data["links"] = [link for link in data.get("links", []) if link[0] != 377]
    data["nodes"] = [node for node in data.get("nodes", []) if node.get("id") != 83]
    subgraph_node = node_by_id(data["nodes"], 170)
    subgraph_node["inputs"][1]["link"] = None

def add_third_image(data):
    second = node_by_id(data["nodes"], 83)
    third = copy.deepcopy(second)
    third["id"] = 171
    third["pos"] = [second["pos"][0], second["pos"][1] + 500]
    third["order"] = max(n.get("order", 0) for n in data["nodes"]) + 1
    third["outputs"][0]["links"] = [378]
    set_load(third, "INPUT 3 — CLOTHING / STYLE REFERENCE", "qwen_sample_image_1.png")
    data["nodes"].append(third)
    data["links"].append([378, 171, 0, 170, 2, "IMAGE"])
    node_by_id(data["nodes"], 170)["inputs"][2]["link"] = 378
    data["last_node_id"] = max(int(data.get("last_node_id", 0)), 171)
    data["last_link_id"] = max(int(data.get("last_link_id", 0)), 378)

def add_anypose_chain(sg):
    lightning = node_by_id(sg["nodes"], 153)
    switch = node_by_id(sg["nodes"], 163)
    link332 = next(link for link in sg["links"] if link["id"] == 332)
    link332["target_id"], link332["target_slot"] = 195, 0

    base = copy.deepcopy(lightning)
    base["id"] = 195
    base["pos"] = [base["pos"][0] + 430, base["pos"][1] - 180]
    base["title"] = "AnyPose base — strength 0.7"
    base["inputs"][0]["link"] = 332
    base["outputs"][0]["links"] = [388]
    base["widgets_values"] = [POSE_BASE, 0.7]

    helper = copy.deepcopy(lightning)
    helper["id"] = 196
    helper["pos"] = [helper["pos"][0] + 850, helper["pos"][1] - 180]
    helper["title"] = "AnyPose helper — strength 0.7"
    helper["inputs"][0]["link"] = 388
    helper["outputs"][0]["links"] = [389]
    helper["widgets_values"] = [POSE_HELPER, 0.7]

    sg["nodes"].extend([base, helper])
    sg["links"].extend([
        {"id": 388, "origin_id": 195, "origin_slot": 0, "target_id": 196, "target_slot": 0, "type": "MODEL"},
        {"id": 389, "origin_id": 196, "origin_slot": 0, "target_id": 163, "target_slot": 1, "type": "MODEL"},
    ])
    switch["inputs"][1]["link"] = 389
    sg["state"]["lastNodeId"] = max(int(sg["state"].get("lastNodeId", 0)), 196)
    sg["state"]["lastLinkId"] = max(int(sg["state"].get("lastLinkId", 0)), 389)

def configure(variant):
    data = copy.deepcopy(template)
    fast = variant in {"general_fast", "person_fast", "anypose"}
    subgraphs = data.get("definitions", {}).get("subgraphs", [])
    if len(subgraphs) != 1:
        raise RuntimeError(f"Expected one subgraph, found {len(subgraphs)}")
    sg = subgraphs[0]

    for node in sg["nodes"]:
        node_type = node.get("type")
        if node_type == "PrimitiveBoolean" and node.get("id") == 168:
            node["widgets_values"] = [fast]
        elif node_type == "UNETLoader":
            node["widgets_values"][0] = MODEL
        elif node_type == "CLIPLoader":
            node["widgets_values"][0] = CLIP
        elif node_type == "VAELoader":
            node["widgets_values"][0] = VAE
        elif node_type == "LoraLoaderModelOnly":
            node["widgets_values"][0] = A2R if variant == "a2r" else LIGHTNING
            node["widgets_values"][1] = 0.85 if variant == "a2r" else 1.0
        elif node_type == "TextEncodeQwenImageEditPlus" and node.get("id") == 151:
            node["widgets_values"] = [PROMPTS[variant]]

    if variant == "a2r":
        lora = node_by_id(sg["nodes"], 153)
        source = node_by_id(sg["nodes"], 152)
        link331 = next(link for link in sg["links"] if link["id"] == 331)
        link331["origin_id"], link331["origin_slot"] = 153, 0
        lora["outputs"][0]["links"] = sorted(set((lora["outputs"][0].get("links") or []) + [331]))
        source["outputs"][0]["links"] = [x for x in (source["outputs"][0].get("links") or []) if x != 331]
    elif variant == "anypose":
        add_anypose_chain(sg)

    note = node_by_id(data["nodes"], 82)
    note["title"] = "READ ME — INPUT ROLES"
    note["widgets_values"] = [NOTES[variant] + "\n\nModels are pinned and checksum-verified by setup v7."]
    save = node_by_id(data["nodes"], 9)
    save["widgets_values"] = [OUTPUT_PREFIX[variant]]

    first = node_by_id(data["nodes"], 41)
    set_load(first, "INPUT 1 — BASE / TARGET IMAGE", "qwen_sample_image_1.png")
    if variant in {"general_quality", "general_fast", "a2r"}:
        disconnect_second_image(data)
    else:
        second = node_by_id(data["nodes"], 83)
        second_title = {
            "person_quality": "INPUT 2 — ADULT PERSON REFERENCE",
            "person_fast": "INPUT 2 — ADULT PERSON REFERENCE",
            "anypose": "INPUT 2 — POSE REFERENCE",
            "clothes": "INPUT 2 — CLOTHING REFERENCE",
            "multi": "INPUT 2 — ADULT IDENTITY REFERENCE",
        }[variant]
        set_load(second, second_title, "qwen_sample_image_2.png")
    if variant == "multi":
        add_third_image(data)

    data["id"] = "qwen-image-edit-2511-studio-" + variant
    return data

def validate_graph(nodes, links, allow_virtual=False):
    node_ids = {node["id"] for node in nodes}
    if allow_virtual:
        node_ids.update((-10, -20))
    link_ids = set()
    for link in links:
        if isinstance(link, dict):
            lid, origin, target = link["id"], link["origin_id"], link["target_id"]
        else:
            lid, origin, target = link[0], link[1], link[3]
        if lid in link_ids:
            raise RuntimeError(f"Duplicate link id: {lid}")
        link_ids.add(lid)
        if origin not in node_ids or target not in node_ids:
            raise RuntimeError(f"Link {lid} references missing node: {origin}->{target}")
    for node in nodes:
        for inp in node.get("inputs", []):
            lid = inp.get("link")
            if lid is not None and lid not in link_ids:
                raise RuntimeError(f"Node {node['id']} input references missing link {lid}")
        for out in node.get("outputs", []):
            for lid in out.get("links") or []:
                if lid not in link_ids:
                    raise RuntimeError(f"Node {node['id']} output references missing link {lid}")

def validate_workflow(data, variant):
    validate_graph(data.get("nodes", []), data.get("links", []))
    sg = data["definitions"]["subgraphs"][0]
    validate_graph(sg.get("nodes", []), sg.get("links", []), allow_virtual=True)
    types = {node.get("type") for node in sg["nodes"]}
    required = {"TextEncodeQwenImageEditPlus", "UNETLoader", "CLIPLoader", "VAELoader", "LoraLoaderModelOnly", "KSampler"}
    missing = required - types
    if missing:
        raise RuntimeError("Missing workflow node types: " + ", ".join(sorted(missing)))
    loras = [node["widgets_values"][0] for node in sg["nodes"] if node.get("type") == "LoraLoaderModelOnly"]
    expected = [A2R] if variant == "a2r" else ([LIGHTNING, POSE_BASE, POSE_HELPER] if variant == "anypose" else [LIGHTNING])
    if loras != expected:
        raise RuntimeError(f"{variant} LoRA chain mismatch: {loras}")
    turbo = node_by_id(sg["nodes"], 168)["widgets_values"][0]
    if turbo != (variant in {"general_fast", "person_fast", "anypose"}):
        raise RuntimeError(f"{variant} turbo mode mismatch")

outputs = [
    (os.environ["WF_GENERAL_QUALITY"], "general_quality"),
    (os.environ["WF_GENERAL_FAST"], "general_fast"),
    (os.environ["WF_PERSON_QUALITY"], "person_quality"),
    (os.environ["WF_PERSON_FAST"], "person_fast"),
    (os.environ["WF_A2R"], "a2r"),
    (os.environ["WF_ANYPOSE"], "anypose"),
    (os.environ["WF_CLOTHES"], "clothes"),
    (os.environ["WF_MULTI"], "multi"),
]
out_dir = os.environ["WORKFLOW_DIR"]
os.makedirs(out_dir, exist_ok=True)
for filename, variant in outputs:
    data = configure(variant)
    validate_workflow(data, variant)
    path = os.path.join(out_dir, filename)
    with open(path + ".part", "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(path + ".part", path)
    print("[OK]", filename)
PY
rm -f "$TMP_WORKFLOW"
TMP_WORKFLOW=""

step "[8/11] Static integrity validation"
for i in "${!MODEL_PATHS[@]}"; do
  file_ok "${MODEL_PATHS[$i]}" "${MODEL_SIZES[$i]}" "${MODEL_SHAS[$i]}" || \
    die "Model verification failed: ${MODEL_PATHS[$i]}"
done
for workflow in \
  "$WF_GENERAL_QUALITY" "$WF_GENERAL_FAST" "$WF_PERSON_QUALITY" "$WF_PERSON_FAST" \
  "$WF_A2R" "$WF_ANYPOSE" "$WF_CLOTHES" "$WF_MULTI"; do
  path="$COMFY/user/default/workflows/$workflow"
  [[ -s "$path" ]] || die "Missing workflow: $path"
  "$PYTHON_BIN" -m json.tool "$path" >/dev/null
done
ok "All models and workflows passed static validation"

step "[9/11] Create dedicated start/stop launchers"
install -m 755 /dev/stdin "$STARTER" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
COMFY="$COMFY"
PYTHON_BIN="$PYTHON_BIN"
PORT="\${RUNPOD_PORT:-$PORT}"
RUN_LOG="$RUN_LOG"
PID_FILE="$PID_FILE"
[[ -x "\$PYTHON_BIN" && -f "\$COMFY/main.py" ]] || { echo "Qwen environment not found"; exit 1; }
if command -v fuser >/dev/null 2>&1 && fuser "\${PORT}/tcp" >/dev/null 2>&1; then
  echo "Stopping the service currently using port \$PORT..."
  fuser -k "\${PORT}/tcp" 2>/dev/null || true
  sleep 2
fi
cd "\$COMFY"
nohup "\$PYTHON_BIN" main.py \
  --listen 0.0.0.0 \
  --port "\$PORT" \
  --preview-method auto \
  --reserve-vram 4 \
  --cache-none \
  --disable-all-custom-nodes \
  > "\$RUN_LOG" 2>&1 &
echo \$! > "\$PID_FILE"
echo "Starting Qwen Image Edit ComfyUI (PID \$(cat "\$PID_FILE"), port \$PORT)..."
for _ in \$(seq 1 120); do
  if curl -fsS "http://127.0.0.1:\$PORT/object_info" >/dev/null 2>&1; then
    echo "Qwen Image Edit READY on port \$PORT"
    exit 0
  fi
  if ! kill -0 "\$(cat "\$PID_FILE")" 2>/dev/null; then
    tail -120 "\$RUN_LOG" || true
    echo "ComfyUI exited during startup"
    exit 1
  fi
  sleep 2
done
tail -120 "\$RUN_LOG" || true
echo "Timed out waiting for ComfyUI"
exit 1
EOF

install -m 755 /dev/stdin "$STOPPER" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
PID_FILE="$PID_FILE"
if [[ -s "\$PID_FILE" ]] && kill -0 "\$(cat "\$PID_FILE")" 2>/dev/null; then
  kill "\$(cat "\$PID_FILE")"
  echo "Stopped Qwen Image Edit ComfyUI"
else
  echo "Qwen Image Edit ComfyUI is not running from its recorded PID"
fi
EOF
ok "Created $STARTER and $STOPPER"

step "[10/11] Start isolated Qwen Image Edit service"
if [[ "${QWEN_NO_START:-0}" == "1" ]]; then
  warn "QWEN_NO_START=1; installation completed without starting ComfyUI"
else
  "$STARTER"
fi

step "[11/11] Runtime node and model validation"
if [[ "${QWEN_NO_START:-0}" != "1" ]]; then
  OBJECT_INFO="$(mktemp)"
  curl -fsS "http://127.0.0.1:$PORT/object_info" -o "$OBJECT_INFO"
  OBJECT_INFO="$OBJECT_INFO" "$PYTHON_BIN" - <<'PY'
import json, os
with open(os.environ["OBJECT_INFO"], encoding="utf-8") as f:
    nodes = json.load(f)
required_nodes = [
    "TextEncodeQwenImageEditPlus", "FluxKontextMultiReferenceLatentMethod",
    "FluxKontextImageScale", "ModelSamplingAuraFlow", "CFGNorm",
    "ComfySwitchNode", "PrimitiveBoolean", "PrimitiveFloat", "PrimitiveInt",
    "UNETLoader", "CLIPLoader", "VAELoader", "LoraLoaderModelOnly",
    "KSampler", "VAEDecode", "VAEEncode", "LoadImage", "SaveImage",
]
missing = [name for name in required_nodes if name not in nodes]
if missing:
    raise SystemExit("Missing runtime nodes: " + ", ".join(missing))
serialized = json.dumps(nodes, ensure_ascii=False)
required_models = [
    "qwen_image_edit_2511_fp8mixed.safetensors",
    "qwen_2.5_vl_7b_fp8_scaled.safetensors",
    "qwen_image_vae.safetensors",
    "Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors",
    "anything2real_2601_A_final_patched.safetensors",
    "2511-AnyPose-base-000006250.safetensors",
    "2511-AnyPose-helper-00006000.safetensors",
]
undetected = [name for name in required_models if name not in serialized]
if undetected:
    raise SystemExit("Models not indexed by ComfyUI: " + ", ".join(undetected))
print("[OK] Required runtime nodes loaded")
print("[OK] Seven model files indexed")
PY
fi

"$PYTHON_BIN" -m pip freeze > "$ROOT/qwen-image-edit-studio-requirements.freeze.txt"
printf '%s\n' \
  "setup_version=$SCRIPT_VERSION" \
  "completed_at=$(date --iso-8601=seconds)" \
  "comfy_commit=$COMFY_COMMIT" \
  "workflow_commit=$WORKFLOW_COMMIT" \
  "python=$($PYTHON_BIN -c 'import sys; print(sys.version.split()[0])')" \
  "torch=$($PYTHON_BIN -c 'import torch; print(torch.__version__)')" \
  > "$ROOT/qwen-image-edit-studio-installation.txt"

echo
echo "================================================================="
echo " QWEN IMAGE EDIT 2511 STUDIO READY"
echo "================================================================="
echo "Environment : $COMFY"
echo "Python      : $PYTHON_BIN"
echo "Port        : $PORT"
echo "Run log     : $RUN_LOG"
echo "Start       : $STARTER"
echo "Stop        : $STOPPER"
echo
echo "Workflows:"
echo "  1. $WF_GENERAL_QUALITY"
echo "  2. $WF_GENERAL_FAST"
echo "  3. $WF_PERSON_QUALITY"
echo "  4. $WF_PERSON_FAST"
echo "  5. $WF_A2R"
echo "  6. $WF_ANYPOSE"
echo "  7. $WF_CLOTHES"
echo "  8. $WF_MULTI"
echo
echo "Recommended first run: 04_QWEN_PERSON_REPLACE_FAST_4STEP.json"
echo "Then use          : 03_QWEN_PERSON_REPLACE_QUALITY_40STEP.json"
echo "================================================================="
