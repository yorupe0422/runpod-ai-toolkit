#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# RunPod Setup #16 v2
# Qwen-Image-2.1 Uncensored GGUF / ComfyUI / RTX 5090
# Port: 8188
#
# Fix in v2:
# - Correct Hugging Face remote paths for text encoder and VAE
# - Separate remote repo path from local filename
# - Reuse already-downloaded files when re-running
# ============================================================

APP_DIR="/workspace/runpod-slim/ComfyUI-QwenImage21-UC"
COMFY_DIR="${APP_DIR}/ComfyUI"
VENV_DIR="${APP_DIR}/.venv"
LOG_DIR="${APP_DIR}/logs"
DL_DIR="${APP_DIR}/downloads"
WF_DIR="${COMFY_DIR}/user/default/workflows"

MODEL_UNET_DIR="${COMFY_DIR}/models/unet"
MODEL_DIFF_DIR="${COMFY_DIR}/models/diffusion_models"
MODEL_TEXT_DIR="${COMFY_DIR}/models/text_encoders"
MODEL_VAE_DIR="${COMFY_DIR}/models/vae"

PORT="8188"

COMFY_REPO="https://github.com/comfyanonymous/ComfyUI.git"
GGUF_REPO="https://github.com/leejet/ComfyUI-GGUF.git"

GGUF_HF_REPO="abenzerps/Qwen-Image-2.1-Uncensored-GGUF"
GGUF_REMOTE="qwen-image-2.1-UC-Q6_K.gguf"
GGUF_FILE="qwen-image-2.1-UC-Q6_K.gguf"
SHA_REMOTE="SHA256SUMS"
SHA_FILE="SHA256SUMS"

OFFICIAL_HF_REPO="Comfy-Org/Qwen-Image-2.1"

TEXT_ENCODER_REMOTE="text_encoders/qwen3vl_8b_int8_convrot.safetensors"
TEXT_ENCODER_FILE="qwen3vl_8b_int8_convrot.safetensors"

VAE_REMOTE="vae/qwen_image_2.1_vae_bf16.safetensors"
VAE_FILE="qwen_image_2.1_vae_bf16.safetensors"

T2I_WF_URL="https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/image_qwen_image_2_1_t2i.json"
EDIT_WF_URL="https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/image_qwen_image_2_1_image_edit.json"

export HF_HUB_ENABLE_HF_TRANSFER=0
export PYTHONUNBUFFERED=1

trap 'echo; echo "[ERROR] Setup failed at line ${LINENO}."; echo "[ERROR] Re-run this same script after fixing the reported issue; completed downloads will be reused."; echo' ERR

log() {
  echo
  echo "============================================================"
  echo "[INFO] $*"
  echo "============================================================"
}

ensure_basic_tools() {
  log "Checking base tools"

  local need_apt_update=0
  command -v git >/dev/null 2>&1 || need_apt_update=1
  command -v curl >/dev/null 2>&1 || need_apt_update=1
  command -v python3 >/dev/null 2>&1 || need_apt_update=1

  if [[ "${need_apt_update}" -eq 1 ]]; then
    apt-get update
    apt-get install -y git curl python3 python3-pip python3-venv ca-certificates
  else
    apt-get install -y python3-venv ca-certificates >/dev/null 2>&1 || true
  fi

  command -v sha256sum >/dev/null 2>&1 || {
    apt-get update
    apt-get install -y coreutils
  }
}

show_gpu() {
  log "GPU / driver information"
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi || true
  else
    echo "[WARN] nvidia-smi not found."
  fi
}

prepare_dirs() {
  log "Preparing directories"
  mkdir -p \
    "${APP_DIR}" \
    "${LOG_DIR}" \
    "${DL_DIR}" \
    "${WF_DIR}" \
    "${MODEL_UNET_DIR}" \
    "${MODEL_DIFF_DIR}" \
    "${MODEL_TEXT_DIR}" \
    "${MODEL_VAE_DIR}"
}

clone_or_update_repo() {
  local repo="$1"
  local dst="$2"

  if [[ -d "${dst}/.git" ]]; then
    echo "[INFO] Updating ${dst}"
    git -C "${dst}" fetch --all --prune
    git -C "${dst}" reset --hard origin/HEAD || git -C "${dst}" pull --ff-only
  else
    rm -rf "${dst}"
    git clone --depth=1 "${repo}" "${dst}"
  fi
}

setup_comfy() {
  log "Installing / updating ComfyUI"
  clone_or_update_repo "${COMFY_REPO}" "${COMFY_DIR}"
}

setup_venv() {
  log "Creating Python virtual environment"

  if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    rm -rf "${VENV_DIR}"
    python3 -m venv "${VENV_DIR}"
  fi

  # shellcheck disable=SC1091
  source "${VENV_DIR}/bin/activate"

  python -m pip install --upgrade pip setuptools wheel
  python -m pip install -r "${COMFY_DIR}/requirements.txt"
  python -m pip install --upgrade "huggingface_hub[hf_xet]" safetensors gguf
}

install_gguf_node() {
  log "Installing Qwen-Image-2.1-compatible ComfyUI-GGUF fork"

  rm -rf "${COMFY_DIR}/custom_nodes/ComfyUI-GGUF"
  git clone --depth=1 "${GGUF_REPO}" "${COMFY_DIR}/custom_nodes/ComfyUI-GGUF"

  # shellcheck disable=SC1091
  source "${VENV_DIR}/bin/activate"

  if [[ -f "${COMFY_DIR}/custom_nodes/ComfyUI-GGUF/requirements.txt" ]]; then
    python -m pip install -r "${COMFY_DIR}/custom_nodes/ComfyUI-GGUF/requirements.txt"
  fi
  python -m pip install --upgrade gguf
}

hf_download_exact() {
  local repo="$1"
  local remote_path="$2"
  local destination="$3"

  # shellcheck disable=SC1091
  source "${VENV_DIR}/bin/activate"

  HF_REPO="${repo}" \
  HF_REMOTE_PATH="${remote_path}" \
  HF_DEST="${destination}" \
  python - <<'PY'
import os
from pathlib import Path
from huggingface_hub import hf_hub_download

repo = os.environ["HF_REPO"]
remote_path = os.environ["HF_REMOTE_PATH"]
dest = Path(os.environ["HF_DEST"])
dest.parent.mkdir(parents=True, exist_ok=True)

print(f"[HF] repo={repo}")
print(f"[HF] remote={remote_path}")
print(f"[HF] dest={dest}")

cached = hf_hub_download(
    repo_id=repo,
    filename=remote_path,
)

src = Path(cached)

if dest.exists() and dest.stat().st_size == src.stat().st_size:
    print(f"[SKIP] Existing file has expected size: {dest}")
else:
    tmp = dest.with_suffix(dest.suffix + ".part")
    if tmp.exists():
        tmp.unlink()

    with src.open("rb") as r, tmp.open("wb") as w:
        while True:
            chunk = r.read(16 * 1024 * 1024)
            if not chunk:
                break
            w.write(chunk)

    tmp.replace(dest)
    print(f"[OK] Saved: {dest}")
PY
}

download_models() {
  log "Downloading exact model files"

  hf_download_exact \
    "${GGUF_HF_REPO}" \
    "${GGUF_REMOTE}" \
    "${MODEL_UNET_DIR}/${GGUF_FILE}"

  hf_download_exact \
    "${GGUF_HF_REPO}" \
    "${SHA_REMOTE}" \
    "${DL_DIR}/${SHA_FILE}"

  hf_download_exact \
    "${OFFICIAL_HF_REPO}" \
    "${TEXT_ENCODER_REMOTE}" \
    "${MODEL_TEXT_DIR}/${TEXT_ENCODER_FILE}"

  hf_download_exact \
    "${OFFICIAL_HF_REPO}" \
    "${VAE_REMOTE}" \
    "${MODEL_VAE_DIR}/${VAE_FILE}"
}

verify_gguf_checksum() {
  log "Verifying UC GGUF SHA256"

  local checksum_line
  checksum_line="$(grep -E "([[:space:]]|\*)${GGUF_FILE}$" "${DL_DIR}/${SHA_FILE}" | head -n 1 || true)"

  if [[ -z "${checksum_line}" ]]; then
    echo "[ERROR] ${GGUF_FILE} was not found in upstream ${SHA_FILE}."
    exit 1
  fi

  local expected
  expected="$(echo "${checksum_line}" | awk '{print $1}')"

  local actual
  actual="$(sha256sum "${MODEL_UNET_DIR}/${GGUF_FILE}" | awk '{print $1}')"

  echo "[SHA256] expected: ${expected}"
  echo "[SHA256] actual  : ${actual}"

  if [[ "${expected}" != "${actual}" ]]; then
    echo "[ERROR] SHA256 mismatch."
    exit 1
  fi

  echo "[OK] GGUF checksum verified."
}

create_compat_symlink() {
  log "Creating diffusion_models compatibility link"

  rm -f "${MODEL_DIFF_DIR}/${GGUF_FILE}"
  ln -s "../unet/${GGUF_FILE}" "${MODEL_DIFF_DIR}/${GGUF_FILE}"
}

download_workflows() {
  log "Downloading official Comfy-Org workflows"

  curl -fL --retry 5 --retry-delay 2 \
    "${T2I_WF_URL}" \
    -o "${WF_DIR}/Qwen_Image_2_1_T2I_OFFICIAL.json"

  curl -fL --retry 5 --retry-delay 2 \
    "${EDIT_WF_URL}" \
    -o "${WF_DIR}/Qwen_Image_2_1_Image_Edit_OFFICIAL.json"

  test -s "${WF_DIR}/Qwen_Image_2_1_T2I_OFFICIAL.json"
  test -s "${WF_DIR}/Qwen_Image_2_1_Image_Edit_OFFICIAL.json"
}

create_helpers() {
  log "Creating start / stop / log helper scripts"

  cat > "${APP_DIR}/start_comfyui.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="${APP_DIR}"
COMFY_DIR="${COMFY_DIR}"
VENV_DIR="${VENV_DIR}"
LOG_DIR="${LOG_DIR}"
PORT="${PORT}"

mkdir -p "\${LOG_DIR}"

if [[ -f "\${LOG_DIR}/comfyui.pid" ]]; then
  OLD_PID="\$(cat "\${LOG_DIR}/comfyui.pid" 2>/dev/null || true)"
  if [[ -n "\${OLD_PID}" ]] && kill -0 "\${OLD_PID}" 2>/dev/null; then
    echo "[INFO] ComfyUI already running. PID=\${OLD_PID}"
    exit 0
  fi
  rm -f "\${LOG_DIR}/comfyui.pid"
fi

source "\${VENV_DIR}/bin/activate"
cd "\${COMFY_DIR}"

nohup python main.py \
  --listen 0.0.0.0 \
  --port "\${PORT}" \
  --preview-method auto \
  > "\${LOG_DIR}/comfyui.log" 2>&1 &

echo \$! > "\${LOG_DIR}/comfyui.pid"

echo "[OK] ComfyUI started."
echo "[INFO] PID: \$(cat "\${LOG_DIR}/comfyui.pid")"
echo "[INFO] Port: \${PORT}"
echo "[INFO] Log: \${LOG_DIR}/comfyui.log"
EOF
  chmod +x "${APP_DIR}/start_comfyui.sh"

  cat > "${APP_DIR}/stop_comfyui.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

PID_FILE="${LOG_DIR}/comfyui.pid"

if [[ ! -f "\${PID_FILE}" ]]; then
  echo "[INFO] No PID file."
  exit 0
fi

PID="\$(cat "\${PID_FILE}")"

if kill -0 "\${PID}" 2>/dev/null; then
  kill "\${PID}"
  echo "[OK] Stopped ComfyUI. PID=\${PID}"
else
  echo "[INFO] Process is already stopped."
fi

rm -f "\${PID_FILE}"
EOF
  chmod +x "${APP_DIR}/stop_comfyui.sh"

  cat > "${APP_DIR}/logs_comfyui.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
touch "${LOG_DIR}/comfyui.log"
tail -n 200 -f "${LOG_DIR}/comfyui.log"
EOF
  chmod +x "${APP_DIR}/logs_comfyui.sh"

  cat > "${APP_DIR}/README_FIRST_STEPS.txt" <<EOF
Qwen-Image-2.1 UC / ComfyUI

APP:
${APP_DIR}

MODEL:
${MODEL_UNET_DIR}/${GGUF_FILE}

TEXT ENCODER:
${MODEL_TEXT_DIR}/${TEXT_ENCODER_FILE}

VAE:
${MODEL_VAE_DIR}/${VAE_FILE}

WORKFLOWS:
${WF_DIR}/Qwen_Image_2_1_T2I_OFFICIAL.json
${WF_DIR}/Qwen_Image_2_1_Image_Edit_OFFICIAL.json

FIRST RUN:
1. Open RunPod port 8188.
2. Load Qwen_Image_2_1_T2I_OFFICIAL.json.
3. Replace the stock diffusion-model loader with:
   Unet Loader (GGUF)
4. Select:
   ${GGUF_FILE}
5. CLIPLoader:
   ${TEXT_ENCODER_FILE}
   type = qwen_image
6. VAELoader:
   ${VAE_FILE}

HELPERS:
Start:
${APP_DIR}/start_comfyui.sh

Stop:
${APP_DIR}/stop_comfyui.sh

Logs:
${APP_DIR}/logs_comfyui.sh
EOF
}

sanity_check_files() {
  log "Sanity checking installed files"

  test -s "${MODEL_UNET_DIR}/${GGUF_FILE}"
  test -s "${MODEL_TEXT_DIR}/${TEXT_ENCODER_FILE}"
  test -s "${MODEL_VAE_DIR}/${VAE_FILE}"
  test -s "${WF_DIR}/Qwen_Image_2_1_T2I_OFFICIAL.json"
  test -s "${WF_DIR}/Qwen_Image_2_1_Image_Edit_OFFICIAL.json"

  echo "[OK] Required files exist."
}

start_comfyui() {
  log "Starting ComfyUI on port ${PORT}"

  "${APP_DIR}/stop_comfyui.sh" >/dev/null 2>&1 || true
  "${APP_DIR}/start_comfyui.sh"

  sleep 12

  echo
  echo "---------------- STARTUP LOG ----------------"
  tail -n 120 "${LOG_DIR}/comfyui.log" || true
  echo "---------------------------------------------"

  if grep -qiE "Traceback|ImportError|ModuleNotFoundError|Unknown model architecture" "${LOG_DIR}/comfyui.log"; then
    echo
    echo "[WARN] Startup log contains an error keyword."
    echo "[WARN] Please inspect:"
    echo "       ${APP_DIR}/logs_comfyui.sh"
    exit 1
  fi
}

print_summary() {
  echo
  echo "============================================================"
  echo "[DONE] Qwen-Image-2.1 UC environment is ready"
  echo "============================================================"
  echo "ComfyUI : ${COMFY_DIR}"
  echo "Port    : ${PORT}"
  echo "GGUF    : ${GGUF_FILE}"
  echo "Encoder : ${TEXT_ENCODER_FILE}"
  echo "VAE     : ${VAE_FILE}"
  echo
  echo "T2I WF  : ${WF_DIR}/Qwen_Image_2_1_T2I_OFFICIAL.json"
  echo "Edit WF : ${WF_DIR}/Qwen_Image_2_1_Image_Edit_OFFICIAL.json"
  echo
  echo "Start   : ${APP_DIR}/start_comfyui.sh"
  echo "Stop    : ${APP_DIR}/stop_comfyui.sh"
  echo "Logs    : ${APP_DIR}/logs_comfyui.sh"
  echo "============================================================"
}

main() {
  ensure_basic_tools
  show_gpu
  prepare_dirs
  setup_comfy
  setup_venv
  install_gguf_node
  download_models
  verify_gguf_checksum
  create_compat_symlink
  download_workflows
  create_helpers
  sanity_check_files
  start_comfyui
  print_summary
}

main "$@"
