#!/usr/bin/env bash
set -Eeuo pipefail

########################################
# RunPod + ComfyUI Z-Image BOOTH Setup
# v1
#
# Purpose:
# - Dedicated ComfyUI environment for BOOTH photo-like image generation
# - Official Z-Image-Turbo BF16 + Qwen3 4B + VAE
# - BEYOND REALITY Z IMAGE v3 BF16
# - Z-Image-Turbo Realism LoRA
# - Official Z-Image workflow template
# - BOOTH-oriented output folders
# - Start ComfyUI and wait until ready
########################################

SCRIPT_NAME="runpod_zimage_booth_setup_v1"
BASE_DIR="${BASE_DIR:-/workspace/runpod-slim}"
COMFY_DIR="${COMFY_DIR:-${BASE_DIR}/ComfyUI-ZImage}"
LOG_DIR="${BASE_DIR}/logs"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"
HOST="${COMFY_HOST:-0.0.0.0}"
REQUESTED_PORT="${COMFY_PORT:-8188}"
VENV_DIR="${COMFY_DIR}/.venv"
PYTHON_BIN="${PYTHON_BIN:-python3}"

mkdir -p "${LOG_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1
trap 'echo "[ERROR] line ${LINENO}: command failed" >&2' ERR

say() {
  echo
  echo "========== $* =========="
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[FATAL] Required command not found: $1" >&2
    exit 1
  }
}

find_free_port() {
  local p="$1"
  while lsof -iTCP:"${p}" -sTCP:LISTEN -t >/dev/null 2>&1; do
    p=$((p + 1))
  done
  echo "${p}"
}

install_os_packages() {
  say "Installing OS packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    git curl wget ca-certificates jq unzip aria2 lsof \
    python3 python3-venv python3-pip
  update-ca-certificates || true
}

prepare_base_dirs() {
  say "Preparing directories"
  mkdir -p "${BASE_DIR}" "${LOG_DIR}"
}

clone_or_update_comfyui() {
  say "Installing / updating official ComfyUI"

  if [[ -d "${COMFY_DIR}/.git" ]]; then
    git -C "${COMFY_DIR}" fetch origin --prune
    git -C "${COMFY_DIR}" pull --ff-only || {
      echo "[WARN] Fast-forward update was not possible. Keeping current ComfyUI checkout."
    }
  else
    if [[ -e "${COMFY_DIR}" ]]; then
      echo "[WARN] Removing non-git directory: ${COMFY_DIR}"
      rm -rf "${COMFY_DIR}"
    fi
    git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "${COMFY_DIR}"
  fi

  git -C "${COMFY_DIR}" rev-parse HEAD > "${COMFY_DIR}/COMFYUI_COMMIT_USED.txt"
  echo "ComfyUI commit: $(cat "${COMFY_DIR}/COMFYUI_COMMIT_USED.txt")"
}

create_venv_and_install() {
  say "Creating Python venv and installing ComfyUI requirements"
  cd "${COMFY_DIR}"

  if [[ ! -d "${VENV_DIR}" ]]; then
    "${PYTHON_BIN}" -m venv "${VENV_DIR}"
  fi

  # shellcheck disable=SC1091
  source "${VENV_DIR}/bin/activate"
  python -m pip install --upgrade pip setuptools wheel
  python -m pip install -r requirements.txt
  python -m pip install --upgrade huggingface_hub safetensors
}

prepare_model_dirs() {
  say "Preparing model / workflow / BOOTH folders"
  mkdir -p \
    "${COMFY_DIR}/models/diffusion_models" \
    "${COMFY_DIR}/models/text_encoders" \
    "${COMFY_DIR}/models/vae" \
    "${COMFY_DIR}/models/loras" \
    "${COMFY_DIR}/user/default/workflows" \
    "${COMFY_DIR}/output/booth_test" \
    "${COMFY_DIR}/output/booth_selected" \
    "${COMFY_DIR}/output/booth_product" \
    "${COMFY_DIR}/output/booth_samples"
}

download_models() {
  say "Downloading Z-Image assets"
  # shellcheck disable=SC1091
  source "${VENV_DIR}/bin/activate"

  python - <<'PYMODEL'
import shutil
from pathlib import Path
from huggingface_hub import hf_hub_download

base = Path("/workspace/runpod-slim/ComfyUI-ZImage/models")
stage_root = Path("/workspace/runpod-slim/.zimage_hf_stage")
stage_root.mkdir(parents=True, exist_ok=True)

items = [
    {
        "repo": "Comfy-Org/z_image_turbo",
        "filename": "split_files/diffusion_models/z_image_turbo_bf16.safetensors",
        "dest": base / "diffusion_models" / "z_image_turbo_bf16.safetensors",
        "min_bytes": 10_000_000_000,
    },
    {
        "repo": "Comfy-Org/z_image_turbo",
        "filename": "split_files/text_encoders/qwen_3_4b.safetensors",
        "dest": base / "text_encoders" / "qwen_3_4b.safetensors",
        "min_bytes": 6_000_000_000,
    },
    {
        "repo": "Comfy-Org/z_image_turbo",
        "filename": "split_files/vae/ae.safetensors",
        "dest": base / "vae" / "ae.safetensors",
        "min_bytes": 250_000_000,
    },
    {
        "repo": "Nurburgring/BEYOND_REALITY_Z_IMAGE",
        "filename": "BEYOND REALITY SUPER Z IMAGE 3.0 淡妆浓抹 BF16.safetensors",
        "dest": base / "diffusion_models" / "beyond_reality_z_image_v3_bf16.safetensors",
        "min_bytes": 10_000_000_000,
    },
    {
        "repo": "suayptalha/Z-Image-Turbo-Realism-LoRA",
        "filename": "pytorch_lora_weights.safetensors",
        "dest": base / "loras" / "zimage_realism_lora.safetensors",
        "min_bytes": 20_000_000,
    },
]

for i, item in enumerate(items, start=1):
    dest = item["dest"]
    dest.parent.mkdir(parents=True, exist_ok=True)

    if dest.exists() and dest.stat().st_size >= item["min_bytes"]:
        print(f"[SKIP {i}/{len(items)}] {dest}")
        continue

    if dest.exists():
        print(f"[WARN] Removing incomplete file: {dest}")
        dest.unlink()

    stage = stage_root / f"item_{i}"
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True, exist_ok=True)

    print(f"[DL {i}/{len(items)}] {item['repo']} :: {item['filename']}")
    downloaded = Path(hf_hub_download(
        repo_id=item["repo"],
        filename=item["filename"],
        local_dir=str(stage),
    ))

    size = downloaded.stat().st_size
    if size < item["min_bytes"]:
        raise RuntimeError(f"Downloaded file too small: {downloaded} ({size} bytes)")

    shutil.move(str(downloaded), str(dest))
    shutil.rmtree(stage, ignore_errors=True)
    print(f"[OK] {dest} ({dest.stat().st_size / (1024**3):.2f} GiB)")

shutil.rmtree(stage_root, ignore_errors=True)
PYMODEL
}

download_official_workflow() {
  say "Downloading official Z-Image-Turbo workflow"
  local wf_url="https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/image_z_image_turbo.json"
  local wf_dst="${COMFY_DIR}/user/default/workflows/booth_zimage_official_base_v1.json"

  if curl -fL --retry 5 --retry-delay 3 --connect-timeout 20 \
    "${wf_url}" -o "${wf_dst}"; then
    echo "[OK] Workflow saved: ${wf_dst}"
  else
    echo "[WARN] Workflow download failed. Setup will continue; use ComfyUI's built-in Templates > Z-Image-Turbo if needed."
    rm -f "${wf_dst}"
  fi
}

write_helper_files() {
  say "Writing BOOTH helper files"

  cat > "${COMFY_DIR}/MODEL_SOURCES_AND_LICENSES.txt" <<'EOF_LICENSES'
MODEL SOURCES / LICENSE RECORD
Generated by runpod_zimage_booth_setup_v1.sh

1) Official Z-Image-Turbo ComfyUI assets
   https://huggingface.co/Comfy-Org/z_image_turbo
   Upstream model:
   https://huggingface.co/Tongyi-MAI/Z-Image-Turbo

2) BEYOND REALITY Z IMAGE
   https://huggingface.co/Nurburgring/BEYOND_REALITY_Z_IMAGE
   Installed file:
   BEYOND REALITY SUPER Z IMAGE 3.0 淡妆浓抹 BF16.safetensors
   Hugging Face license label when this setup was authored: Apache-2.0

3) Z-Image-Turbo Realism LoRA
   https://huggingface.co/suayptalha/Z-Image-Turbo-Realism-LoRA
   Installed file:
   pytorch_lora_weights.safetensors
   Trigger word: Realism

IMPORTANT:
Before a commercial release, re-check the current model cards/licenses and the current BOOTH rules.
EOF_LICENSES

  cat > "${COMFY_DIR}/README_BOOTH_ZIMAGE_ENV.md" <<'EOF_MD'
# BOOTH Z-Image Environment

Installed by `runpod_zimage_booth_setup_v1.sh`.

## Installed models

### Diffusion models
- `z_image_turbo_bf16.safetensors`
- `beyond_reality_z_image_v3_bf16.safetensors`

### Text encoder
- `qwen_3_4b.safetensors`

### VAE
- `ae.safetensors`

### LoRA
- `zimage_realism_lora.safetensors`
- Trigger: `Realism`

## First A/B/C test

A. Official Z-Image-Turbo
- diffusion model: `z_image_turbo_bf16.safetensors`
- no LoRA

B. Official Z-Image-Turbo + Realism LoRA
- diffusion model: `z_image_turbo_bf16.safetensors`
- LoRA: `zimage_realism_lora.safetensors`
- initial strength: around `0.8`
- prompt includes `Realism`

C. BEYOND REALITY
- diffusion model: `beyond_reality_z_image_v3_bf16.safetensors`
- no Realism LoRA for the first comparison

## Starter settings
- Steps: 10-15
- CFG: 1.0
- Sampler: Euler
- Scheduler: simple
- Portrait resolution: 1024x1536 or 896x1344

Keep prompt and seed conditions aligned when comparing A/B/C.

## BOOTH folders
- `output/booth_test`
- `output/booth_selected`
- `output/booth_product`
- `output/booth_samples`
EOF_MD

  cat > "${COMFY_DIR}/start_comfyui_zimage.sh" <<EOF_START
#!/usr/bin/env bash
set -euo pipefail
cd "${COMFY_DIR}"
source "${VENV_DIR}/bin/activate"
PORT_TO_USE="\${1:-${REQUESTED_PORT}}"
python main.py --listen "${HOST}" --port "\${PORT_TO_USE}"
EOF_START
  chmod +x "${COMFY_DIR}/start_comfyui_zimage.sh"

  cat > "${COMFY_DIR}/stop_comfyui_zimage.sh" <<'EOF_STOP'
#!/usr/bin/env bash
set -euo pipefail
PID_FILE="/workspace/runpod-slim/ComfyUI-ZImage/comfyui.pid"
if [[ ! -f "${PID_FILE}" ]]; then
  echo "No PID file found."
  exit 0
fi
PID="$(cat "${PID_FILE}")"
if kill -0 "${PID}" 2>/dev/null; then
  kill "${PID}"
  echo "Stopped ComfyUI PID ${PID}"
else
  echo "Process ${PID} is not running."
fi
rm -f "${PID_FILE}"
EOF_STOP
  chmod +x "${COMFY_DIR}/stop_comfyui_zimage.sh"
}

verify_installation() {
  say "Verifying installation"

  local required=(
    "${COMFY_DIR}/models/diffusion_models/z_image_turbo_bf16.safetensors"
    "${COMFY_DIR}/models/diffusion_models/beyond_reality_z_image_v3_bf16.safetensors"
    "${COMFY_DIR}/models/text_encoders/qwen_3_4b.safetensors"
    "${COMFY_DIR}/models/vae/ae.safetensors"
    "${COMFY_DIR}/models/loras/zimage_realism_lora.safetensors"
  )

  local f
  for f in "${required[@]}"; do
    if [[ ! -s "${f}" ]]; then
      echo "[FATAL] Missing required file: ${f}" >&2
      exit 1
    fi
    echo "[OK] $(basename "${f}")"
  done

  # shellcheck disable=SC1091
  source "${VENV_DIR}/bin/activate"
  cd "${COMFY_DIR}"
  python -c 'import torch; print("PyTorch:", torch.__version__, "CUDA:", torch.cuda.is_available())'
}

start_comfyui() {
  say "Starting ComfyUI"
  cd "${COMFY_DIR}"

  PORT="$(find_free_port "${REQUESTED_PORT}")"
  echo "Selected port: ${PORT}"

  if [[ -f comfyui.pid ]]; then
    local old_pid
    old_pid="$(cat comfyui.pid || true)"
    if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
      echo "Stopping previous ComfyUI-ZImage process: ${old_pid}"
      kill "${old_pid}" || true
      sleep 2
    fi
  fi

  # shellcheck disable=SC1091
  source "${VENV_DIR}/bin/activate"
  nohup python main.py --listen "${HOST}" --port "${PORT}" > comfyui.log 2>&1 &
  echo $! > comfyui.pid
}

wait_for_comfyui() {
  say "Waiting for ComfyUI readiness"
  local max_attempts=180
  local i

  for ((i=1; i<=max_attempts; i++)); do
    if curl -fsS "http://127.0.0.1:${PORT}/system_stats" >/dev/null 2>&1; then
      echo "[OK] ComfyUI is ready on port ${PORT}."
      return 0
    fi
    sleep 2
  done

  echo "[FATAL] ComfyUI did not become ready within 6 minutes." >&2
  echo "---- comfyui.log (last 150 lines) ----"
  tail -n 150 "${COMFY_DIR}/comfyui.log" || true
  exit 1
}

print_summary() {
  say "Setup complete"
  cat <<EOF_SUMMARY
READY

ComfyUI directory:
  ${COMFY_DIR}

ComfyUI port:
  ${PORT}

Local health URL:
  http://127.0.0.1:${PORT}/system_stats

Installed diffusion models:
  z_image_turbo_bf16.safetensors
  beyond_reality_z_image_v3_bf16.safetensors

Installed text encoder:
  qwen_3_4b.safetensors

Installed VAE:
  ae.safetensors

Installed LoRA:
  zimage_realism_lora.safetensors

Workflow:
  user/default/workflows/booth_zimage_official_base_v1.json
  (If download failed, open ComfyUI Templates and choose the Z-Image-Turbo template.)

BOOTH folders:
  output/booth_test
  output/booth_selected
  output/booth_product
  output/booth_samples

Logs:
  ${LOG_FILE}
  ${COMFY_DIR}/comfyui.log

Restart:
  cd ${COMFY_DIR} && ./start_comfyui_zimage.sh ${PORT}

Stop:
  cd ${COMFY_DIR} && ./stop_comfyui_zimage.sh
EOF_SUMMARY
}

main() {
  say "${SCRIPT_NAME} started"
  need_cmd bash
  install_os_packages
  need_cmd git
  need_cmd curl
  need_cmd lsof
  need_cmd "${PYTHON_BIN}"
  prepare_base_dirs
  clone_or_update_comfyui
  create_venv_and_install
  prepare_model_dirs
  download_models
  download_official_workflow
  write_helper_files
  verify_installation
  start_comfyui
  wait_for_comfyui
  print_summary
}

main "$@"
