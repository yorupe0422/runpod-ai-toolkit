#!/usr/bin/env bash
set -Eeuo pipefail

###############################################
# RunPod + ComfyUI Z-Image BOOTH Setup v2
#
# Design goals:
# - One-shot install on RunPod
# - Survives browser/terminal disconnects
# - Prints heartbeat every 20s during long steps
# - Resume-safe/idempotent after an interrupted v1/v2 run
# - Official ComfyUI + NVIDIA PyTorch CUDA 13.0 path
# - Z-Image-Turbo BF16 + Qwen3 4B + VAE
# - BEYOND REALITY Z IMAGE v3 BF16
# - Z-Image-Turbo Realism LoRA
###############################################

SCRIPT_NAME="runpod_zimage_booth_setup_v2"
BASE_DIR="${BASE_DIR:-/workspace/runpod-slim}"
COMFY_DIR="${COMFY_DIR:-${BASE_DIR}/ComfyUI-ZImage}"
VENV_DIR="${COMFY_DIR}/.venv"
STATE_DIR="${BASE_DIR}/.zimage_booth_v2"
SETUP_LOG="${STATE_DIR}/setup.log"
PHASE_DIR="${STATE_DIR}/phases"
PID_FILE="${STATE_DIR}/setup.pid"
STATUS_FILE="${STATE_DIR}/status"
HF_HOME_DIR="${BASE_DIR}/.cache/huggingface"
REQUESTED_PORT="${COMFY_PORT:-8188}"
HOST="${COMFY_HOST:-0.0.0.0}"
HEARTBEAT_SECONDS="${HEARTBEAT_SECONDS:-20}"
MIN_FREE_GB="${MIN_FREE_GB:-55}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

mkdir -p "${STATE_DIR}" "${PHASE_DIR}"

usage() {
  cat <<EOF_USAGE
${SCRIPT_NAME}

Usage:
  $0               Launch setup detached, then follow the live log
  $0 --follow      Follow the live setup log
  $0 --status      Show setup status and worker PID
  $0 --worker      Internal mode; do not use directly
  $0 --help        Show this help

Important:
  Do NOT run this script via "curl ... | bash".
  Download it to /workspace first, then execute it. The launcher detaches the
  installer so the setup continues even if the RunPod browser terminal closes.
EOF_USAGE
}

human_elapsed() {
  local total="$1"
  printf '%02d:%02d:%02d' $((total/3600)) $(((total%3600)/60)) $((total%60))
}

is_pid_alive() {
  local pid="${1:-}"
  [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}

show_status() {
  local status="NOT_STARTED"
  [[ -f "${STATUS_FILE}" ]] && status="$(cat "${STATUS_FILE}" 2>/dev/null || true)"
  echo "Status : ${status}"
  if [[ -f "${PID_FILE}" ]]; then
    local pid
    pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if is_pid_alive "${pid}"; then
      echo "Worker : RUNNING (PID ${pid})"
    else
      echo "Worker : not running (last PID ${pid})"
    fi
  else
    echo "Worker : not started"
  fi
  echo "Log    : ${SETUP_LOG}"
}

follow_log() {
  touch "${SETUP_LOG}"
  local pid=""
  [[ -f "${PID_FILE}" ]] && pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if is_pid_alive "${pid}"; then
    echo "Following setup log. If this terminal disconnects, the installer keeps running."
    echo "Reconnect and run: $0 --follow"
    echo
    tail --pid="${pid}" -n 80 -F "${SETUP_LOG}" || true
  else
    tail -n 120 "${SETUP_LOG}" || true
    echo
    show_status
  fi
}

launch_detached() {
  # A real file path is required so nohup can restart the script independently.
  local self
  self="$(readlink -f "${BASH_SOURCE[0]}")"
  if [[ ! -f "${self}" ]]; then
    echo "[FATAL] This script must be downloaded to a file before execution." >&2
    echo "Do not use: curl ... | bash" >&2
    exit 2
  fi

  if [[ -f "${PID_FILE}" ]]; then
    local old_pid
    old_pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if is_pid_alive "${old_pid}"; then
      echo "A setup worker is already running (PID ${old_pid})."
      follow_log
      return 0
    fi
  fi

  : > "${SETUP_LOG}"
  echo "STARTING" > "${STATUS_FILE}"

  nohup "${self}" --worker >> "${SETUP_LOG}" 2>&1 < /dev/null &
  local pid=$!
  echo "${pid}" > "${PID_FILE}"

  echo "Started detached setup worker: PID ${pid}"
  echo "The installation WILL continue even if this RunPod terminal says 'Connection Closed'."
  echo "Live log: ${SETUP_LOG}"
  echo
  sleep 1
  follow_log
}

worker_fail() {
  local rc=$?
  local line="${1:-unknown}"
  echo
  echo "[FAILED] setup stopped at line ${line}; exit code ${rc}"
  echo "FAILED" > "${STATUS_FILE}"
  echo "Inspect: ${SETUP_LOG}"
  exit "${rc}"
}

say() {
  echo
  echo "================================================================"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "================================================================"
}

phase_slug() {
  echo "$1" | tr '[:upper:] ' '[:lower:]_' | tr -cd 'a-z0-9_.-'
}

run_phase() {
  local phase="$1"
  shift
  local slug
  slug="$(phase_slug "${phase}")"
  local phase_log="${PHASE_DIR}/${slug}.log"
  local start now elapsed pid rc

  say "${phase}"
  echo "[INFO] Detailed phase log: ${phase_log}"
  : > "${phase_log}"
  start="$(date +%s)"

  "$@" > "${phase_log}" 2>&1 &
  pid=$!

  while is_pid_alive "${pid}"; do
    sleep "${HEARTBEAT_SECONDS}"
    if is_pid_alive "${pid}"; then
      now="$(date +%s)"
      elapsed=$((now-start))
      echo "[ALIVE] ${phase} | elapsed $(human_elapsed "${elapsed}") | PID ${pid}"
      ps -p "${pid}" -o pid=,etime=,%cpu=,%mem=,stat=,cmd= 2>/dev/null | sed 's/^/[PROC] /' || true
      echo "[SPACE] $(df -h "${BASE_DIR}" | awk 'NR==2 {print "used=" $3 ", free=" $4 ", use%=" $5}')"
      if [[ -d "${HF_HOME_DIR}" ]]; then
        echo "[HF] cache size: $(du -sh "${HF_HOME_DIR}" 2>/dev/null | awk '{print $1}' || echo '?')"
      fi
      if [[ -s "${phase_log}" ]]; then
        echo "[TAIL] newest output:"
        tail -n 4 "${phase_log}" | sed 's/^/       /' || true
      else
        echo "[TAIL] no new command output yet; process is still alive"
      fi
    fi
  done

  if wait "${pid}"; then
    rc=0
  else
    rc=$?
  fi

  now="$(date +%s)"
  elapsed=$((now-start))

  if [[ "${rc}" -ne 0 ]]; then
    echo "[ERROR] ${phase} failed after $(human_elapsed "${elapsed}") (exit ${rc})"
    echo "----- last 120 lines: ${phase_log} -----"
    tail -n 120 "${phase_log}" || true
    return "${rc}"
  fi

  echo "[OK] ${phase} completed in $(human_elapsed "${elapsed}")"
  if [[ -s "${phase_log}" ]]; then
    echo "----- last 12 lines: ${phase_log} -----"
    tail -n 12 "${phase_log}" || true
  fi
}

check_space() {
  local free_kb free_gb
  free_kb="$(df -Pk "${BASE_DIR}" | awk 'NR==2 {print $4}')"
  free_gb=$((free_kb / 1024 / 1024))
  echo "Free space in ${BASE_DIR}: ~${free_gb} GiB"
  if (( free_gb < MIN_FREE_GB )); then
    echo "[FATAL] Need at least ${MIN_FREE_GB} GiB free for models + Python/CUDA packages." >&2
    return 1
  fi
}


stop_legacy_installers() {
  say "Check for an interrupted v1 installer"
  local pids
  pids="$(ps -eo pid=,args= | awk -v py="${VENV_DIR}/bin/python" '$0 ~ py && $0 ~ /-m pip/ {print $1}' | xargs || true)"
  if [[ -z "${pids}" ]]; then
    echo "No legacy pip installer is running."
    return 0
  fi

  echo "Found legacy pip process(es) using this same ComfyUI-ZImage venv: ${pids}"
  echo "Stopping them before v2 repairs/resumes the environment..."
  kill ${pids} 2>/dev/null || true
  sleep 5
  local pid
  for pid in ${pids}; do
    if is_pid_alive "${pid}"; then
      echo "Force-stopping legacy PID ${pid}"
      kill -9 "${pid}" 2>/dev/null || true
    fi
  done
}

install_os_packages() {
  export DEBIAN_FRONTEND=noninteractive
  run_phase "APT package index" apt-get update -y
  run_phase "APT base packages" apt-get install -y --no-install-recommends \
    git curl wget ca-certificates jq unzip aria2 lsof procps \
    python3 python3-venv python3-pip
}

install_or_update_comfyui() {
  if [[ -d "${COMFY_DIR}/.git" ]]; then
    run_phase "Update official ComfyUI" git -C "${COMFY_DIR}" pull --ff-only
  else
    if [[ -e "${COMFY_DIR}" ]]; then
      # Keep models/output from a prior partial attempt, but remove a broken non-git code dir only.
      echo "[WARN] ${COMFY_DIR} exists but is not a git checkout; moving it aside."
      mv "${COMFY_DIR}" "${COMFY_DIR}.broken.$(date +%Y%m%d_%H%M%S)"
    fi
    run_phase "Clone official ComfyUI" git clone --depth 1 https://github.com/Comfy-Org/ComfyUI.git "${COMFY_DIR}"
  fi
  git -C "${COMFY_DIR}" rev-parse HEAD > "${COMFY_DIR}/COMFYUI_COMMIT_USED.txt"
  echo "ComfyUI commit: $(cat "${COMFY_DIR}/COMFYUI_COMMIT_USED.txt")"
}

prepare_python_env() {
  say "Prepare Python environment"
  if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    echo "Creating venv: ${VENV_DIR}"
    "${PYTHON_BIN}" -m venv "${VENV_DIR}"
  else
    echo "Reusing existing venv (safe resume): ${VENV_DIR}"
  fi

  run_phase "Upgrade pip tooling" "${VENV_DIR}/bin/python" -m pip install --upgrade pip setuptools wheel

  # Install GPU stack explicitly first. This is intentionally separated from
  # requirements.txt so a long CUDA/Torch installation always has a heartbeat.
  run_phase "Install NVIDIA PyTorch CUDA 13.0" \
    "${VENV_DIR}/bin/python" -m pip install --upgrade \
    torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cu130

  run_phase "Verify PyTorch CUDA" "${VENV_DIR}/bin/python" -c \
    'import torch; print("torch=", torch.__version__); print("cuda_available=", torch.cuda.is_available()); print("torch_cuda=", torch.version.cuda); assert torch.cuda.is_available(), "PyTorch cannot see the NVIDIA GPU"'

  run_phase "Install ComfyUI requirements" \
    "${VENV_DIR}/bin/python" -m pip install --upgrade -r "${COMFY_DIR}/requirements.txt"

  run_phase "Install Hugging Face helpers" \
    "${VENV_DIR}/bin/python" -m pip install --upgrade huggingface_hub safetensors

  run_phase "Pip dependency check" "${VENV_DIR}/bin/python" -m pip check
}

prepare_dirs() {
  say "Prepare model / workflow / BOOTH directories"
  mkdir -p \
    "${COMFY_DIR}/models/diffusion_models" \
    "${COMFY_DIR}/models/text_encoders" \
    "${COMFY_DIR}/models/vae" \
    "${COMFY_DIR}/models/loras" \
    "${COMFY_DIR}/user/default/workflows" \
    "${COMFY_DIR}/output/booth_test" \
    "${COMFY_DIR}/output/booth_selected" \
    "${COMFY_DIR}/output/booth_product" \
    "${COMFY_DIR}/output/booth_samples" \
    "${HF_HOME_DIR}"
}

write_hf_downloader() {
  cat > "${STATE_DIR}/hf_download_one.py" <<'PY'
import os
import shutil
import sys
from pathlib import Path
from huggingface_hub import hf_hub_download

if len(sys.argv) != 5:
    raise SystemExit("usage: hf_download_one.py REPO FILENAME DEST MIN_BYTES")

repo, filename, dest_s, min_bytes_s = sys.argv[1:]
dest = Path(dest_s)
min_bytes = int(min_bytes_s)
dest.parent.mkdir(parents=True, exist_ok=True)

if dest.exists() and dest.stat().st_size >= min_bytes:
    print(f"SKIP: already complete: {dest} ({dest.stat().st_size} bytes)")
    raise SystemExit(0)

if dest.exists():
    print(f"Removing incomplete destination: {dest} ({dest.stat().st_size} bytes)")
    dest.unlink()

print(f"Downloading: {repo} :: {filename}", flush=True)
path = hf_hub_download(repo_id=repo, filename=filename)
src = Path(path).resolve()
size = src.stat().st_size
print(f"Cache file complete: {src} ({size} bytes)", flush=True)

if size < min_bytes:
    raise RuntimeError(f"Downloaded file is unexpectedly small: {size} < {min_bytes}")

# HF_HOME is placed on /workspace, so hard-linking normally avoids a second
# full copy of multi-GB weights. Fall back to copy if the filesystem differs.
try:
    os.link(src, dest)
    print(f"Hard-linked to: {dest}", flush=True)
except OSError as e:
    print(f"Hard-link unavailable ({e}); copying instead...", flush=True)
    shutil.copy2(src, dest)

if dest.stat().st_size != size:
    raise RuntimeError("Destination size mismatch")
print(f"OK: {dest} ({dest.stat().st_size} bytes)", flush=True)
PY
}

download_models() {
  export HF_HOME="${HF_HOME_DIR}"
  export HF_HUB_CACHE="${HF_HOME_DIR}/hub"
  export HF_HUB_DISABLE_TELEMETRY=1
  export PYTHONUNBUFFERED=1
  write_hf_downloader

  local py="${VENV_DIR}/bin/python"
  local dl="${STATE_DIR}/hf_download_one.py"

  run_phase "Download Z-Image-Turbo BF16" \
    "${py}" "${dl}" \
    "Comfy-Org/z_image_turbo" \
    "split_files/diffusion_models/z_image_turbo_bf16.safetensors" \
    "${COMFY_DIR}/models/diffusion_models/z_image_turbo_bf16.safetensors" \
    "10000000000"

  run_phase "Download Qwen3 4B text encoder" \
    "${py}" "${dl}" \
    "Comfy-Org/z_image_turbo" \
    "split_files/text_encoders/qwen_3_4b.safetensors" \
    "${COMFY_DIR}/models/text_encoders/qwen_3_4b.safetensors" \
    "6000000000"

  run_phase "Download Z-Image VAE" \
    "${py}" "${dl}" \
    "Comfy-Org/z_image_turbo" \
    "split_files/vae/ae.safetensors" \
    "${COMFY_DIR}/models/vae/ae.safetensors" \
    "250000000"

  run_phase "Download BEYOND REALITY Z IMAGE v3 BF16" \
    "${py}" "${dl}" \
    "Nurburgring/BEYOND_REALITY_Z_IMAGE" \
    "BEYOND REALITY SUPER Z IMAGE 3.0 淡妆浓抹 BF16.safetensors" \
    "${COMFY_DIR}/models/diffusion_models/beyond_reality_z_image_v3_bf16.safetensors" \
    "10000000000"

  run_phase "Download Z-Image Realism LoRA" \
    "${py}" "${dl}" \
    "suayptalha/Z-Image-Turbo-Realism-LoRA" \
    "pytorch_lora_weights.safetensors" \
    "${COMFY_DIR}/models/loras/zimage_realism_lora.safetensors" \
    "20000000"
}

download_workflow() {
  local wf_url="https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/image_z_image_turbo.json"
  local wf_dst="${COMFY_DIR}/user/default/workflows/booth_zimage_official_base_v2.json"
  run_phase "Download official Z-Image workflow" \
    curl -fL --retry 8 --retry-delay 3 --connect-timeout 20 "${wf_url}" -o "${wf_dst}"
}

write_helper_files() {
  say "Write helper files"

  cat > "${COMFY_DIR}/MODEL_SOURCES_AND_LICENSES.txt" <<'EOF_LICENSES'
MODEL SOURCES / LICENSE RECORD
Generated by runpod_zimage_booth_setup_v2.sh

Official Z-Image-Turbo ComfyUI split files:
https://huggingface.co/Comfy-Org/z_image_turbo
Upstream:
https://huggingface.co/Tongyi-MAI/Z-Image-Turbo

BEYOND REALITY Z IMAGE:
https://huggingface.co/Nurburgring/BEYOND_REALITY_Z_IMAGE
Installed: BEYOND REALITY SUPER Z IMAGE 3.0 淡妆浓抹 BF16.safetensors

Z-Image-Turbo Realism LoRA:
https://huggingface.co/suayptalha/Z-Image-Turbo-Realism-LoRA
Installed: pytorch_lora_weights.safetensors
Trigger word: Realism

Before every commercial release, re-check the current model cards/licenses and current BOOTH rules.
EOF_LICENSES

  cat > "${COMFY_DIR}/README_BOOTH_ZIMAGE_ENV.md" <<'EOF_MD'
# BOOTH Z-Image Environment v2

## A/B/C test
A. Official Z-Image-Turbo BF16
B. Official Z-Image-Turbo BF16 + Realism LoRA (start around 0.8, trigger `Realism`)
C. BEYOND REALITY Z IMAGE v3 BF16

## Starter settings
- Steps: 10-15
- CFG: 1.0
- Sampler: Euler
- Scheduler: simple
- Portrait: 1024x1536 or 896x1344

## Output folders
- output/booth_test
- output/booth_selected
- output/booth_product
- output/booth_samples
EOF_MD

  cat > "${COMFY_DIR}/start_comfyui_zimage.sh" <<EOF_START
#!/usr/bin/env bash
set -euo pipefail
cd "${COMFY_DIR}"
PORT_TO_USE="\${1:-${REQUESTED_PORT}}"
exec "${VENV_DIR}/bin/python" main.py --listen "${HOST}" --port "\${PORT_TO_USE}" --preview-method auto
EOF_START
  chmod +x "${COMFY_DIR}/start_comfyui_zimage.sh"

  cat > "${COMFY_DIR}/stop_comfyui_zimage.sh" <<'EOF_STOP'
#!/usr/bin/env bash
set -euo pipefail
PID_FILE="/workspace/runpod-slim/ComfyUI-ZImage/comfyui.pid"
if [[ ! -f "${PID_FILE}" ]]; then
  echo "No ComfyUI PID file found."
  exit 0
fi
PID="$(cat "${PID_FILE}")"
if kill -0 "${PID}" 2>/dev/null; then
  kill "${PID}"
  echo "Stopped ComfyUI PID ${PID}"
else
  echo "ComfyUI PID ${PID} is not running."
fi
rm -f "${PID_FILE}"
EOF_STOP
  chmod +x "${COMFY_DIR}/stop_comfyui_zimage.sh"
}

verify_assets() {
  say "Verify installed assets"
  local required=(
    "${COMFY_DIR}/models/diffusion_models/z_image_turbo_bf16.safetensors"
    "${COMFY_DIR}/models/diffusion_models/beyond_reality_z_image_v3_bf16.safetensors"
    "${COMFY_DIR}/models/text_encoders/qwen_3_4b.safetensors"
    "${COMFY_DIR}/models/vae/ae.safetensors"
    "${COMFY_DIR}/models/loras/zimage_realism_lora.safetensors"
  )
  local f
  for f in "${required[@]}"; do
    [[ -s "${f}" ]] || { echo "[FATAL] Missing: ${f}"; return 1; }
    echo "[OK] $(basename "${f}") : $(du -h "${f}" | awk '{print $1}')"
  done

  run_phase "ComfyUI import smoke test" bash -lc \
    "cd '${COMFY_DIR}' && '${VENV_DIR}/bin/python' -c 'import torch; import comfy.model_management; print(\"torch\", torch.__version__, \"cuda\", torch.cuda.is_available())'"
}

find_free_port() {
  local p="$1"
  while lsof -iTCP:"${p}" -sTCP:LISTEN -t >/dev/null 2>&1; do
    p=$((p + 1))
  done
  echo "${p}"
}

start_comfyui() {
  say "Start ComfyUI"
  local port
  port="$(find_free_port "${REQUESTED_PORT}")"
  echo "${port}" > "${STATE_DIR}/comfyui.port"

  if [[ -f "${COMFY_DIR}/comfyui.pid" ]]; then
    local old
    old="$(cat "${COMFY_DIR}/comfyui.pid" 2>/dev/null || true)"
    if is_pid_alive "${old}"; then
      echo "Stopping previous ComfyUI process PID ${old}"
      kill "${old}" || true
      sleep 2
    fi
  fi

  cd "${COMFY_DIR}"
  nohup "${VENV_DIR}/bin/python" main.py \
    --listen "${HOST}" --port "${port}" --preview-method auto \
    > "${COMFY_DIR}/comfyui.log" 2>&1 < /dev/null &
  echo $! > "${COMFY_DIR}/comfyui.pid"
  echo "ComfyUI PID: $(cat "${COMFY_DIR}/comfyui.pid")"
  echo "ComfyUI port: ${port}"
}

wait_for_comfyui() {
  local port pid start now elapsed
  port="$(cat "${STATE_DIR}/comfyui.port")"
  pid="$(cat "${COMFY_DIR}/comfyui.pid")"
  start="$(date +%s)"

  say "Wait for ComfyUI readiness"
  while true; do
    if curl -fsS "http://127.0.0.1:${port}/system_stats" >/dev/null 2>&1; then
      echo "[OK] ComfyUI is ready on port ${port}."
      return 0
    fi
    if ! is_pid_alive "${pid}"; then
      echo "[FATAL] ComfyUI process exited before readiness."
      tail -n 160 "${COMFY_DIR}/comfyui.log" || true
      return 1
    fi
    sleep 10
    now="$(date +%s)"
    elapsed=$((now-start))
    echo "[ALIVE] ComfyUI starting | elapsed $(human_elapsed "${elapsed}") | PID ${pid}"
    tail -n 4 "${COMFY_DIR}/comfyui.log" | sed 's/^/[COMFY] /' || true
    if (( elapsed > 600 )); then
      echo "[FATAL] ComfyUI did not become ready within 10 minutes."
      tail -n 160 "${COMFY_DIR}/comfyui.log" || true
      return 1
    fi
  done
}

print_summary() {
  local port
  port="$(cat "${STATE_DIR}/comfyui.port")"
  say "SETUP COMPLETE"
  cat <<EOF_SUMMARY
READY

ComfyUI:
  ${COMFY_DIR}

Port:
  ${port}

Health check:
  http://127.0.0.1:${port}/system_stats

Installed:
  - z_image_turbo_bf16.safetensors
  - beyond_reality_z_image_v3_bf16.safetensors
  - qwen_3_4b.safetensors
  - ae.safetensors
  - zimage_realism_lora.safetensors

Workflow:
  user/default/workflows/booth_zimage_official_base_v2.json

Logs:
  Setup : ${SETUP_LOG}
  Comfy : ${COMFY_DIR}/comfyui.log

Reconnect after a browser-terminal disconnect:
  ${BASH_SOURCE[0]} --follow

Status:
  ${BASH_SOURCE[0]} --status
EOF_SUMMARY
}

worker_main() {
  trap '' HUP
  trap 'worker_fail ${LINENO}' ERR
  echo "RUNNING" > "${STATUS_FILE}"
  echo "$$" > "${PID_FILE}"

  say "${SCRIPT_NAME} worker started"
  echo "Worker PID: $$"
  echo "Heartbeat interval: ${HEARTBEAT_SECONDS}s"
  echo "This worker is detached from the browser terminal and survives Connection Closed."

  mkdir -p "${BASE_DIR}" "${STATE_DIR}" "${PHASE_DIR}" "${HF_HOME_DIR}"
  check_space

  # GPU check before spending time on installation.
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo "GPU: $(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader | head -n 1)"
  else
    echo "[FATAL] nvidia-smi not found. This v2 setup expects an NVIDIA RunPod GPU." >&2
    return 1
  fi

  stop_legacy_installers
  install_os_packages
  install_or_update_comfyui
  prepare_python_env
  prepare_dirs
  download_models
  download_workflow
  write_helper_files
  verify_assets
  start_comfyui
  wait_for_comfyui
  print_summary

  echo "READY" > "${STATUS_FILE}"
  rm -f "${PID_FILE}"
}

case "${1:-}" in
  --help|-h)
    usage
    ;;
  --status)
    show_status
    ;;
  --follow)
    follow_log
    ;;
  --worker)
    worker_main
    ;;
  "")
    launch_detached
    ;;
  *)
    echo "Unknown option: $1" >&2
    usage >&2
    exit 2
    ;;
esac
