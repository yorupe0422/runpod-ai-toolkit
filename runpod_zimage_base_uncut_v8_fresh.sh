#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# RunPod Z-Image Base + Haruka041/uncut — V8 fresh installer
#
# Design:
#   - A completely independent ComfyUI checkout: ComfyUI-ZImage-V8
#   - No update/repair/checkout operations against earlier ComfyUI directories
#   - Fixed port 8188; an existing ComfyUI listener is stopped before downloads
#   - A non-ComfyUI listener on 8188 causes an immediate preflight failure
#   - Clean shallow clone of pinned ComfyUI v0.33.4 with git auto-gc disabled
#   - Local /tmp venv reusing RunPod's working CUDA PyTorch
#   - Resumable aria2 downloads with 16 -> 4 -> 1 connection fallback
#   - Exact SHA-256 and safetensors header verification
#   - Optional hard-link reuse of previously SHA-verified immutable model files
#   - Native-node workflows only; no custom-node dependency
#   - Detached worker survives RunPod browser-terminal disconnects
###############################################################################

SCRIPT_NAME="runpod_zimage_base_uncut_v8_fresh"
INSTALLER_VERSION="8.0.0-zimage-base-uncut-fresh"
BASE_DIR="${BASE_DIR:-/workspace/runpod-slim}"
COMFY_DIR="${COMFY_DIR:-${BASE_DIR}/ComfyUI-ZImage-V8}"
COMFY_REF="${COMFY_REF:-v0.33.4}"
COMFY_COMMIT="${COMFY_COMMIT:-7a131a3afadc8200120f67f9236311a2c48b7445}"
COMFY_PORT="${COMFY_PORT:-8188}"
COMFY_HOST="${COMFY_HOST:-0.0.0.0}"
LOCAL_VENV_DIR="${LOCAL_VENV_DIR:-/tmp/comfyui-zimage-v8-venv}"
VENV_LINK="${COMFY_DIR}/.venv"
PIP_CACHE_DIR="${PIP_CACHE_DIR:-/tmp/pip-cache-zimage-v8}"
STATE_DIR="${BASE_DIR}/.zimage_base_uncut_v8"
SETUP_LOG="${STATE_DIR}/setup.log"
STATUS_FILE="${STATE_DIR}/status"
PHASE_FILE="${STATE_DIR}/phase"
PID_FILE="${STATE_DIR}/setup.pid"
LOCK_DIR="${STATE_DIR}/setup.lock.d"
COMFY_PID_FILE="${STATE_DIR}/comfyui.pid"
COMFY_LOG="${COMFY_DIR}/comfyui.log"
PYTHON_RECORD="${STATE_DIR}/python_source.txt"
CORE_MARKER="${COMFY_DIR}/.zimage-v8-core-ok"
HEARTBEAT_SECONDS="${HEARTBEAT_SECONDS:-20}"
NORMAL_TIMEOUT_SECONDS="${NORMAL_TIMEOUT_SECONDS:-2400}"
CLONE_TIMEOUT_SECONDS="${CLONE_TIMEOUT_SECONDS:-900}"
MODEL_TIMEOUT_SECONDS="${MODEL_TIMEOUT_SECONDS:-10800}"
START_TIMEOUT_SECONDS="${START_TIMEOUT_SECONDS:-420}"
RESERVE_VRAM_GB="${RESERVE_VRAM_GB:-4}"
REUSE_VERIFIED_MODELS="${REUSE_VERIFIED_MODELS:-1}"

Z_MODEL_NAME="z_image_bf16.safetensors"
Z_CLIP_NAME="qwen_3_4b.safetensors"
Z_VAE_NAME="ae.safetensors"
UNCUT_NAME="uncutpenis_ZIT_v3.1_000004500.safetensors"

Z_MODEL_URL="https://huggingface.co/Comfy-Org/z_image/resolve/main/split_files/diffusion_models/${Z_MODEL_NAME}"
Z_CLIP_URL="https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/${Z_CLIP_NAME}"
Z_VAE_URL="https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/${Z_VAE_NAME}"
UNCUT_REV="e08f941b393446946b59be3951febdd5fb19f490"
UNCUT_URL="https://huggingface.co/Haruka041/uncut/resolve/${UNCUT_REV}/${UNCUT_NAME}"

Z_MODEL_SHA="996a67d3ff666946b1c25cbc16d1b1918b6cc0ac166309e23fe3b3d830263dee"
Z_CLIP_SHA="6c671498573ac2f7a5501502ccce8d2b08ea6ca2f661c458e708f36b36edfc5a"
Z_VAE_SHA="afc8e28272cd15db3919bacdb6918ce9c1ed22e96cb12c4d5ed0fba823529e38"
UNCUT_SHA="f1b56ab6554827472ba4b886c9e7d47ec47af797060cb942bdcb5eebc96d3415"

mkdir -p "${STATE_DIR}"

usage() {
  cat <<EOF
${SCRIPT_NAME} ${INSTALLER_VERSION}

Usage:
  $0                 Start detached installer and follow its log
  $0 --follow        Follow current/last installer log
  $0 --status        Show installer and ComfyUI status
  $0 --stop-setup    Stop only the V8 installer worker
  $0 --worker        Internal mode

Optional environment variables:
  HF_TOKEN=hf_...            Hugging Face token (recommended on shared RunPod IPs)
  REUSE_VERIFIED_MODELS=1    Hard-link previously SHA-verified files (default 1)
  RESERVE_VRAM_GB=4          Leave this amount free for ComfyUI

V8 installs independently at:
  ${COMFY_DIR}

Port 8188 is mandatory. V8 never changes to 8189.
EOF
}

now_human() { date '+%Y-%m-%d %H:%M:%S'; }
is_pid_alive() { [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null; }
say() { echo; echo "================================================================"; echo "[$(now_human)] $*"; echo "================================================================"; }
set_phase() { echo "$*" > "${PHASE_FILE}"; }

show_status() {
  local status="NOT_STARTED" phase="-" pid="" comfy_pid=""
  [[ -f "${STATUS_FILE}" ]] && status="$(cat "${STATUS_FILE}" 2>/dev/null || true)"
  [[ -f "${PHASE_FILE}" ]] && phase="$(cat "${PHASE_FILE}" 2>/dev/null || true)"
  [[ -f "${PID_FILE}" ]] && pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  [[ -f "${COMFY_PID_FILE}" ]] && comfy_pid="$(cat "${COMFY_PID_FILE}" 2>/dev/null || true)"
  echo "Version : ${INSTALLER_VERSION}"
  echo "Status  : ${status}"
  echo "Phase   : ${phase}"
  is_pid_alive "${pid}" && echo "Worker  : RUNNING (PID ${pid})" || echo "Worker  : not running"
  is_pid_alive "${comfy_pid}" && echo "ComfyUI : RUNNING (PID ${comfy_pid})" || echo "ComfyUI : not running"
  echo "Port    : ${COMFY_PORT}"
  echo "Install : ${COMFY_DIR}"
  echo "Log     : ${SETUP_LOG}"
  [[ -f "${PYTHON_RECORD}" ]] && echo "Python  : $(tr '\n' ' ' < "${PYTHON_RECORD}")"
}

follow_log() {
  touch "${SETUP_LOG}"
  local pid=""
  [[ -f "${PID_FILE}" ]] && pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if is_pid_alive "${pid}"; then
    echo "Following V8 setup. Ctrl+C stops only this log view, not the worker."
    echo "Reconnect: $0 --follow"
    echo "Stop worker: $0 --stop-setup"
    tail --pid="${pid}" -n 120 -F "${SETUP_LOG}" || true
  else
    tail -n 200 "${SETUP_LOG}" || true
    echo
    show_status
  fi
}

stop_tree() {
  local pid="$1" child
  for child in $(pgrep -P "${pid}" 2>/dev/null || true); do stop_tree "${child}"; done
  kill "${pid}" 2>/dev/null || true
}

stop_setup() {
  local pid=""
  [[ -f "${PID_FILE}" ]] && pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if is_pid_alive "${pid}"; then
    stop_tree "${pid}"
    sleep 2
    is_pid_alive "${pid}" && kill -9 "${pid}" 2>/dev/null || true
    echo "Stopped V8 installer PID ${pid}. Completed and partial model files remain resumable."
  else
    echo "V8 installer is not running."
  fi
}

launch_detached() {
  local self old="" pid
  self="$(readlink -f "${BASH_SOURCE[0]}")"
  [[ -f "${self}" ]] || { echo "[FATAL] Save the script as a file before running it."; exit 2; }
  [[ -f "${PID_FILE}" ]] && old="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if is_pid_alive "${old}"; then
    echo "V8 installer is already running (PID ${old})."
    follow_log
    return
  fi
  : > "${SETUP_LOG}"
  echo STARTING > "${STATUS_FILE}"
  echo launcher > "${PHASE_FILE}"
  if command -v setsid >/dev/null 2>&1; then
    nohup setsid "${self}" --worker >> "${SETUP_LOG}" 2>&1 < /dev/null &
  else
    nohup "${self}" --worker >> "${SETUP_LOG}" 2>&1 < /dev/null &
  fi
  pid=$!
  echo "${pid}" > "${PID_FILE}"
  echo "Started detached V8 worker PID ${pid}."
  echo "Log: ${SETUP_LOG}"
  sleep 1
  follow_log
}

worker_error() {
  local rc=$? line="${1:-?}"
  trap - ERR
  echo
  echo "[FAILED] V8 setup failed (exit=${rc}, line=${line})"
  echo FAILED > "${STATUS_FILE}"
  echo "FAILED at line ${line}" > "${PHASE_FILE}"
  echo "Last ComfyUI log:"
  [[ -f "${COMFY_LOG}" ]] && tail -100 "${COMFY_LOG}" || true
  echo "Setup log: ${SETUP_LOG}"
  rm -rf "${LOCK_DIR}" 2>/dev/null || true
  exit "${rc}"
}

run_phase() {
  local label="$1" timeout_s="$2"; shift 2
  set_phase "${label}"
  say "${label}"
  "$@" &
  local child=$! started=$SECONDS last=$SECONDS
  while is_pid_alive "${child}"; do
    if (( SECONDS - started > timeout_s )); then
      stop_tree "${child}"
      sleep 2
      is_pid_alive "${child}" && kill -9 "${child}" 2>/dev/null || true
      echo "[FATAL] Phase timed out after ${timeout_s}s: ${label}"
      return 124
    fi
    if (( SECONDS - last >= HEARTBEAT_SECONDS )); then
      local free="-"
      free="$(df -h "${BASE_DIR}" 2>/dev/null | awk 'NR==2{print $4}' || true)"
      echo "[ALIVE] ${label}; elapsed=$((SECONDS-started))s; workspace_free=${free:-unknown}"
      last=$SECONDS
    fi
    sleep 2
  done
  wait "${child}"
}

stop_prior_installers() {
  local state pid cmd
  for state in \
    "${BASE_DIR}/.zimage_booth_v4" \
    "${BASE_DIR}/.zimage_base_uncut_v5" \
    "${BASE_DIR}/.zimage_base_uncut_v6" \
    "${BASE_DIR}/.zimage_base_uncut_v7"; do
    [[ -f "${state}/setup.pid" ]] || continue
    pid="$(cat "${state}/setup.pid" 2>/dev/null || true)"
    is_pid_alive "${pid}" || continue
    cmd="$(ps -p "${pid}" -o args= 2>/dev/null || true)"
    if [[ "${cmd}" == *zimage* || "${cmd}" == *ZImage* ]]; then
      echo "Stopping earlier Z-Image installer PID ${pid}."
      stop_tree "${pid}"
      sleep 2
      is_pid_alive "${pid}" && kill -9 "${pid}" 2>/dev/null || true
    else
      echo "[WARN] PID ${pid} from ${state} is not a Z-Image installer; ignoring stale PID file."
    fi
  done
}

ensure_tools_and_gpu() {
  local need_apt=0 cmd mem
  for cmd in curl git aria2c python3 jq lsof; do command -v "${cmd}" >/dev/null 2>&1 || need_apt=1; done
  python3 -m venv --help >/dev/null 2>&1 || need_apt=1
  if (( need_apt )); then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
      ca-certificates curl git aria2 python3 python3-venv jq lsof psmisc
  else
    echo "[FAST-SKIP] Required system tools are already installed."
  fi
  command -v nvidia-smi >/dev/null || { echo "[FATAL] nvidia-smi is unavailable"; return 1; }
  nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
  mem="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -d ' ')"
  [[ "${mem}" =~ ^[0-9]+$ ]] || { echo "[FATAL] Could not read GPU VRAM"; return 1; }
  (( mem >= 24000 )) || { echo "[FATAL] V8 requires at least 24 GB VRAM; detected ${mem} MiB"; return 1; }
  [[ -n "${HF_TOKEN:-}" ]] \
    && echo "[OK] HF_TOKEN is set (the value will not be printed)." \
    || echo "[WARN] HF_TOKEN is unset. Shared-IP Hugging Face rate limits are more likely."
}

is_comfyui_listener() {
  local pid="$1" cmd cwd
  cmd="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
  cwd="$(readlink -f "/proc/${pid}/cwd" 2>/dev/null || true)"
  if [[ "${cmd}" == *main.py* && "${cmd}" == *--port*"${COMFY_PORT}"* ]]; then return 0; fi
  if [[ "${cmd}" == *main.py* && "${cwd}" == *ComfyUI* ]]; then return 0; fi
  return 1
}

free_port_8188() {
  local round pid cmd cwd waited
  [[ "${COMFY_PORT}" == "8188" ]] || { echo "[FATAL] V8 supports port 8188 only."; return 1; }
  for round in 1 2 3; do
    mapfile -t listeners < <(lsof -tiTCP:"${COMFY_PORT}" -sTCP:LISTEN 2>/dev/null | sort -u || true)
    ((${#listeners[@]})) || { echo "[OK] Port 8188 is free."; return 0; }
    for pid in "${listeners[@]}"; do
      [[ "${pid}" =~ ^[0-9]+$ ]] || continue
      (( pid > 2 )) || { echo "[FATAL] Refusing to stop protected PID ${pid} on port 8188."; return 1; }
      cmd="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
      cwd="$(readlink -f "/proc/${pid}/cwd" 2>/dev/null || true)"
      if is_comfyui_listener "${pid}"; then
        echo "[PORT] Stopping existing ComfyUI PID ${pid} on 8188."
        echo "       cwd=${cwd:-unknown}"
        echo "       cmd=${cmd:-unknown}"
        kill -TERM "${pid}" 2>/dev/null || true
        waited=0
        while lsof -a -p "${pid}" -iTCP:"${COMFY_PORT}" -sTCP:LISTEN >/dev/null 2>&1 \
          && (( waited < 4 )); do
          sleep 1
          waited=$((waited+1))
        done
        if lsof -a -p "${pid}" -iTCP:"${COMFY_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
          if is_comfyui_listener "${pid}"; then
            echo "[PORT] ComfyUI PID ${pid} did not stop gracefully; sending SIGKILL."
            kill -9 "${pid}" 2>/dev/null || true
            sleep 1
          else
            echo "[FATAL] PID ${pid} changed identity while releasing port 8188; refusing SIGKILL."
            return 1
          fi
        fi
      else
        echo "[FATAL] Port 8188 is occupied by a non-ComfyUI process; refusing to kill it."
        echo "PID=${pid} cwd=${cwd:-unknown} cmd=${cmd:-unknown}"
        return 1
      fi
    done
    sleep 2
  done
  if lsof -tiTCP:"${COMFY_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "[FATAL] Port 8188 remained occupied after stopping ComfyUI."
    lsof -nP -iTCP:"${COMFY_PORT}" -sTCP:LISTEN || true
    return 1
  fi
  echo "[OK] Port 8188 is free."
}

fresh_comfyui_core() {
  local stage_root stage_comfy backup
  mkdir -p "${BASE_DIR}"
  if [[ -f "${CORE_MARKER}" && -f "${COMFY_DIR}/main.py" && -d "${COMFY_DIR}/.git" ]] \
    && [[ "$(cat "${CORE_MARKER}" 2>/dev/null || true)" == "${INSTALLER_VERSION}:${COMFY_REF}:${COMFY_COMMIT}" ]] \
    && git -C "${COMFY_DIR}" diff --quiet \
    && git -C "${COMFY_DIR}" diff --cached --quiet; then
    echo "[FAST-SKIP] Clean V8 ComfyUI core already verified."
    return 0
  fi

  stage_root="$(mktemp -d "${BASE_DIR}/.zimage-v8-clone.XXXXXX")"
  stage_comfy="${stage_root}/ComfyUI"
  export GIT_TERMINAL_PROMPT=0
  echo "[FRESH] Shallow-cloning ComfyUI ${COMFY_REF} into a new directory."
  if ! git -c gc.auto=0 -c advice.detachedHead=false clone --depth=1 --single-branch --branch "${COMFY_REF}" --progress \
    https://github.com/Comfy-Org/ComfyUI.git "${stage_comfy}"; then
    echo "[FATAL] Fresh clone failed; no existing ComfyUI directory was modified."
    rm -rf "${stage_root}"
    return 1
  fi
  [[ -f "${stage_comfy}/main.py" && -f "${stage_comfy}/requirements.txt" ]] || {
    echo "[FATAL] Fresh clone is missing required ComfyUI files."
    rm -rf "${stage_root}"
    return 1
  }
  [[ -z "$(git -C "${stage_comfy}" status --porcelain --untracked-files=no)" ]] || {
    echo "[FATAL] Fresh clone unexpectedly has tracked changes."
    rm -rf "${stage_root}"
    return 1
  }
  [[ "$(git -C "${stage_comfy}" rev-parse HEAD)" == "${COMFY_COMMIT}" ]] || {
    echo "[FATAL] ComfyUI tag resolved to an unexpected commit; refusing an unpinned install."
    echo "expected=${COMFY_COMMIT}"
    echo "actual=$(git -C "${stage_comfy}" rev-parse HEAD)"
    rm -rf "${stage_root}"
    return 1
  }

  if [[ -e "${COMFY_DIR}" || -L "${COMFY_DIR}" ]]; then
    backup="${BASE_DIR}/ComfyUI-ZImage-V8.incomplete.$(date '+%Y%m%d-%H%M%S').${BASHPID}"
    echo "[BACKUP] Moving incomplete V8 directory to ${backup}"
    mv "${COMFY_DIR}" "${backup}"
  fi
  mv "${stage_comfy}" "${COMFY_DIR}"
  rmdir "${stage_root}" 2>/dev/null || true
  printf '%s:%s:%s\n' "${INSTALLER_VERSION}" "${COMFY_REF}" "${COMFY_COMMIT}" > "${CORE_MARKER}"
  echo "[OK] Fresh ComfyUI $(git -C "${COMFY_DIR}" describe --tags --always) at $(git -C "${COMFY_DIR}" rev-parse --short=12 HEAD)"
}

find_cuda_python() {
  local p
  for p in /usr/local/bin/python3 python3 /usr/bin/python3; do
    command -v "${p}" >/dev/null 2>&1 || continue
    if "${p}" - <<'PY' >/dev/null 2>&1
import torch
assert torch.cuda.is_available()
PY
    then command -v "${p}"; return 0; fi
  done
  return 1
}

write_filtered_requirements() {
  awk '
    BEGIN{IGNORECASE=1}
    /^[[:space:]]*(torch|torchvision|torchaudio)([[:space:]]|[<>=!~;\[]|$)/ {next}
    {print}
  ' "${COMFY_DIR}/requirements.txt" > "${STATE_DIR}/requirements.no-torch.txt"
}

prepare_python() {
  local base_python use_system=0 py req_hash marker
  mkdir -p "${PIP_CACHE_DIR}"
  export PIP_CACHE_DIR PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_INPUT=1 PIP_DEFAULT_TIMEOUT=120
  if base_python="$(find_cuda_python)"; then
    use_system=1
    echo "[FAST] Reusing working CUDA PyTorch from ${base_python}."
  else
    base_python="$(command -v python3)"
    echo "[WARN] No reusable CUDA PyTorch was found; CUDA wheels will be installed."
  fi
  write_filtered_requirements
  if [[ ! -x "${LOCAL_VENV_DIR}/bin/python" ]]; then
    rm -rf "${LOCAL_VENV_DIR}"
    if (( use_system )); then
      "${base_python}" -m venv --system-site-packages "${LOCAL_VENV_DIR}"
    else
      "${base_python}" -m venv "${LOCAL_VENV_DIR}"
    fi
  fi
  ln -sfn "${LOCAL_VENV_DIR}" "${VENV_LINK}"
  py="${VENV_LINK}/bin/python"
  if ! "${py}" - <<'PY' >/dev/null 2>&1
import torch
assert torch.cuda.is_available()
PY
  then
    "${py}" -m pip install --no-compile --prefer-binary \
      torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128
  fi
  req_hash="$(sha256sum "${STATE_DIR}/requirements.no-torch.txt" | awk '{print $1}')-$(git -C "${COMFY_DIR}" rev-parse --short=12 HEAD)"
  marker="${LOCAL_VENV_DIR}/.requirements-ok"
  if [[ -f "${marker}" && "$(cat "${marker}" 2>/dev/null || true)" == "${req_hash}" ]]; then
    echo "[FAST-SKIP] V8 Python requirements are already installed."
  else
    "${py}" -m pip install --no-compile --prefer-binary -r "${STATE_DIR}/requirements.no-torch.txt"
    printf '%s\n' "${req_hash}" > "${marker}"
  fi
  if ! "${py}" -m pip check; then
    echo "[WARN] pip check found a base-image conflict; dedicated imports are checked separately."
  fi
  "${py}" - <<'PY'
import aiohttp, safetensors, torch, yaml
assert torch.cuda.is_available()
print(f"[OK] PyTorch {torch.__version__}; CUDA {torch.version.cuda}; GPU {torch.cuda.get_device_name(0)}")
PY
  {
    echo "venv=${LOCAL_VENV_DIR}"
    echo "base_python=${base_python}"
    echo "system_cuda_reused=${use_system}"
  } > "${PYTHON_RECORD}"
}

prepare_model_dirs() {
  mkdir -p "${COMFY_DIR}/models/diffusion_models" "${COMFY_DIR}/models/text_encoders" \
    "${COMFY_DIR}/models/vae" "${COMFY_DIR}/models/loras" \
    "${COMFY_DIR}/user/default/workflows" "${COMFY_DIR}/input" "${COMFY_DIR}/output"
  local free
  free="$(df -PB1 "${BASE_DIR}" | awk 'NR==2{print $4}')"
  (( free >= 26000000000 )) || {
    echo "[FATAL] At least 26 GB free workspace is required; available $((free/1000000000)) GB."; return 1;
  }
  echo "[OK] Workspace free space: $((free/1000000000)) GB"
}

validate_safetensors() {
  local file="$1"
  python3 - "${file}" <<'PY'
import json, os, struct, sys
p=sys.argv[1]; size=os.path.getsize(p)
if size < 16: raise SystemExit(f'too small: {p}')
with open(p,'rb') as f:
    n=struct.unpack('<Q',f.read(8))[0]
    if n <= 2 or n > min(size-8,256*1024*1024): raise SystemExit(f'bad safetensors header length: {p}')
    if not isinstance(json.loads(f.read(n)),dict): raise SystemExit(f'bad safetensors JSON: {p}')
print(f'[OK] safetensors: {os.path.basename(p)} ({size/1e9:.2f} GB)')
PY
}

marker_is_valid() {
  local file="$1" expected_sha="$2" marker="${file}.sha256-ok" mark_sha="" mark_size="" actual_size
  [[ -f "${file}" && -f "${marker}" ]] || return 1
  read -r mark_sha mark_size < "${marker}" || return 1
  actual_size="$(stat -c %s "${file}")"
  [[ "${mark_sha}" == "${expected_sha}" && "${mark_size}" == "${actual_size}" ]]
}

reuse_verified_model() {
  local relative="$1" dst="$2" expected_sha="$3" root src
  [[ "${REUSE_VERIFIED_MODELS}" == "1" ]] || return 1
  for root in "${BASE_DIR}/ComfyUI-ZImage" "${BASE_DIR}/ComfyUI-ZImage-V7"; do
    src="${root}/${relative}"
    [[ "${src}" != "${dst}" ]] || continue
    if marker_is_valid "${src}" "${expected_sha}"; then
      validate_safetensors "${src}"
      mkdir -p "$(dirname "${dst}")"
      if ln "${src}" "${dst}" 2>/dev/null; then
        printf '%s %s\n' "${expected_sha}" "$(stat -c %s "${dst}")" > "${dst}.sha256-ok"
        echo "[FAST-REUSE] Hard-linked verified model from ${src}"
        return 0
      fi
      echo "[WARN] Verified source found but hard-link is unavailable; downloading normally."
    fi
  done
  return 1
}

aria_attempt() {
  local url="$1" dst="$2" connections="$3" input_file
  input_file="${STATE_DIR}/aria2.$$.${connections}.txt"
  umask 077
  {
    printf '%s\n' "${url}"
    printf '  dir=%s\n' "$(dirname "${dst}")"
    printf '  out=%s\n' "$(basename "${dst}")"
    [[ -n "${HF_TOKEN:-}" ]] && printf '  header=Authorization: Bearer %s\n' "${HF_TOKEN}"
  } > "${input_file}"
  if aria2c --input-file="${input_file}" --continue=true \
    --max-connection-per-server="${connections}" --split="${connections}" \
    --min-split-size=16M --file-allocation=none --auto-file-renaming=false \
    --allow-overwrite=true --retry-wait=8 --max-tries=8 --timeout=60 \
    --connect-timeout=30 --summary-interval=10 --console-log-level=notice; then
    rm -f "${input_file}"
    return 0
  fi
  rm -f "${input_file}"
  return 1
}

download_verified() {
  local url="$1" relative="$2" expected_sha="$3" dst="${COMFY_DIR}/${relative}" actual connections
  mkdir -p "$(dirname "${dst}")"
  if marker_is_valid "${dst}" "${expected_sha}"; then
    validate_safetensors "${dst}"
    echo "[FAST-SKIP] Verified file already installed: $(basename "${dst}")"
    return 0
  fi
  if [[ ! -e "${dst}" ]] && reuse_verified_model "${relative}" "${dst}" "${expected_sha}"; then return 0; fi
  if [[ -f "${dst}" && ! -f "${dst}.aria2" ]]; then
    echo "[VERIFY] Existing unmarked file: $(basename "${dst}")"
    actual="$(sha256sum "${dst}" | awk '{print $1}')"
    if [[ "${actual}" == "${expected_sha}" ]]; then
      validate_safetensors "${dst}"
      printf '%s %s\n' "${expected_sha}" "$(stat -c %s "${dst}")" > "${dst}.sha256-ok"
      echo "[OK] Existing file verified; download skipped."
      return 0
    fi
    mv "${dst}" "${dst}.invalid.$(date +%s)"
  fi
  for connections in 16 4 1; do
    echo "[DOWNLOAD] $(basename "${dst}") with ${connections} connection(s)"
    if aria_attempt "${url}" "${dst}" "${connections}"; then break; fi
    echo "[WARN] Download attempt failed; retrying with fewer connections."
  done
  [[ -f "${dst}" && ! -f "${dst}.aria2" ]] || { echo "[FATAL] Download did not complete: ${dst}"; return 1; }
  actual="$(sha256sum "${dst}" | awk '{print $1}')"
  [[ "${actual}" == "${expected_sha}" ]] || {
    echo "[FATAL] SHA-256 mismatch: ${dst}"; echo "expected=${expected_sha}"; echo "actual=${actual}"; return 1;
  }
  validate_safetensors "${dst}"
  printf '%s %s\n' "${expected_sha}" "$(stat -c %s "${dst}")" > "${dst}.sha256-ok"
}

install_models() {
  download_verified "${Z_MODEL_URL}" "models/diffusion_models/${Z_MODEL_NAME}" "${Z_MODEL_SHA}"
  download_verified "${Z_CLIP_URL}" "models/text_encoders/${Z_CLIP_NAME}" "${Z_CLIP_SHA}"
  download_verified "${Z_VAE_URL}" "models/vae/${Z_VAE_NAME}" "${Z_VAE_SHA}"
  download_verified "${UNCUT_URL}" "models/loras/${UNCUT_NAME}" "${UNCUT_SHA}"
}

write_native_workflows() {
  local wf_dir="${COMFY_DIR}/user/default/workflows"
  python3 - "${wf_dir}/ZImage_Base_Uncut_Haruka041_V8.json" "${wf_dir}/ZImage_Base_Clean_V8.json" <<'PY'
import copy,json,sys
uncut_out,clean_out=sys.argv[1:3]
def props(name): return {'Node name for S&R':name,'cnr_id':'comfy-core'}
def node(i,t,x,y,w,h,order,widgets,inputs=None,outputs=None,title=None):
    n={'id':i,'type':t,'pos':[x,y],'size':[w,h],'flags':{},'order':order,'mode':0,
       'inputs':inputs or [],'outputs':outputs or [],'properties':props(t),'widgets_values':widgets}
    if title: n['title']=title
    return n
nodes=[
 node(1,'UNETLoader',20,20,330,110,0,['z_image_bf16.safetensors','default'],outputs=[{'name':'MODEL','type':'MODEL','links':[1]}]),
 node(2,'LoraLoaderModelOnly',400,20,410,130,1,['uncutpenis_ZIT_v3.1_000004500.safetensors',1.0],inputs=[{'name':'model','type':'MODEL','link':1}],outputs=[{'name':'MODEL','type':'MODEL','links':[2]}]),
 node(3,'CLIPLoader',20,190,330,130,2,['qwen_3_4b.safetensors','lumina2','default'],outputs=[{'name':'CLIP','type':'CLIP','links':[3,4]}]),
 node(4,'VAELoader',20,370,330,90,3,['ae.safetensors'],outputs=[{'name':'VAE','type':'VAE','links':[10]}]),
 node(5,'CLIPTextEncode',400,200,440,250,4,['A high quality photograph of a fictional adult person, natural anatomy, detailed skin, balanced composition, professional lighting'],inputs=[{'name':'clip','type':'CLIP','link':3}],outputs=[{'name':'CONDITIONING','type':'CONDITIONING','links':[5]}],title='Positive prompt — fictional ADULT subjects only'),
 node(6,'CLIPTextEncode',400,500,440,190,5,['low quality, blurry, distorted anatomy, extra limbs, malformed hands, watermark, text'],inputs=[{'name':'clip','type':'CLIP','link':4}],outputs=[{'name':'CONDITIONING','type':'CONDITIONING','links':[6]}],title='Negative prompt'),
 node(7,'EmptySD3LatentImage',20,520,330,140,6,[1024,1024,1],outputs=[{'name':'LATENT','type':'LATENT','links':[7]}]),
 node(8,'ModelSamplingAuraFlow',880,20,340,100,7,[3],inputs=[{'name':'model','type':'MODEL','link':2}],outputs=[{'name':'MODEL','type':'MODEL','links':[8]}]),
 node(9,'KSampler',880,180,340,500,8,[83472169432,'randomize',30,4.0,'res_multistep','simple',1.0],inputs=[{'name':'model','type':'MODEL','link':8},{'name':'positive','type':'CONDITIONING','link':5},{'name':'negative','type':'CONDITIONING','link':6},{'name':'latent_image','type':'LATENT','link':7}],outputs=[{'name':'LATENT','type':'LATENT','links':[9]}]),
 node(10,'VAEDecode',1270,180,250,100,9,[],inputs=[{'name':'samples','type':'LATENT','link':9},{'name':'vae','type':'VAE','link':10}],outputs=[{'name':'IMAGE','type':'IMAGE','links':[11]}]),
 node(11,'SaveImage',1570,180,360,420,10,['ZImageBase_Uncut_V8'],inputs=[{'name':'images','type':'IMAGE','link':11}],outputs=[])
]
links=[[1,1,0,2,0,'MODEL'],[2,2,0,8,0,'MODEL'],[3,3,0,5,0,'CLIP'],[4,3,0,6,0,'CLIP'],[5,5,0,9,1,'CONDITIONING'],[6,6,0,9,2,'CONDITIONING'],[7,7,0,9,3,'LATENT'],[8,8,0,9,0,'MODEL'],[9,9,0,10,0,'LATENT'],[10,4,0,10,1,'VAE'],[11,10,0,11,0,'IMAGE']]
wf={'last_node_id':11,'last_link_id':11,'nodes':nodes,'links':links,'groups':[],'config':{},'extra':{'ds':{'scale':0.72,'offset':[130,80]}},'version':0.4}
with open(uncut_out,'w',encoding='utf-8') as f: json.dump(wf,f,ensure_ascii=False,indent=2)

clean=copy.deepcopy(wf)
clean['nodes']=[n for n in clean['nodes'] if n['id']!=2]
clean['links']=[x for x in clean['links'] if x[0] not in (1,2)]
unet=next(n for n in clean['nodes'] if n['id']==1); unet['outputs'][0]['links']=[2]
sampling=next(n for n in clean['nodes'] if n['id']==8); sampling['inputs'][0]['link']=2
clean['links'].insert(0,[2,1,0,8,0,'MODEL'])
save=next(n for n in clean['nodes'] if n['id']==11); save['widgets_values']=['ZImageBase_Clean_V8']
with open(clean_out,'w',encoding='utf-8') as f: json.dump(clean,f,ensure_ascii=False,indent=2)
for p in (uncut_out,clean_out):
    o=json.load(open(p,encoding='utf-8'))
    assert o['version']==0.4 and o['nodes'] and o['links']
    print('[OK] Workflow JSON:',p)
PY
}

start_comfyui() {
  local py="${VENV_LINK}/bin/python" pid help_text
  free_port_8188
  cd "${COMFY_DIR}"
  : > "${COMFY_LOG}"
  help_text="$(${py} main.py --help 2>&1 || true)"
  local -a args=(main.py --listen "${COMFY_HOST}" --port "${COMFY_PORT}" --preview-method auto --enable-cors-header)
  [[ "${help_text}" == *--reserve-vram* ]] && args+=(--reserve-vram "${RESERVE_VRAM_GB}")
  [[ "${help_text}" == *--cache-none* ]] && args+=(--cache-none)
  [[ "${help_text}" == *--disable-auto-launch* ]] && args+=(--disable-auto-launch)
  echo "Launch: ${py} ${args[*]}"
  if command -v setsid >/dev/null 2>&1; then
    nohup setsid "${py}" "${args[@]}" >> "${COMFY_LOG}" 2>&1 < /dev/null &
  else
    nohup "${py}" "${args[@]}" >> "${COMFY_LOG}" 2>&1 < /dev/null &
  fi
  pid=$!
  echo "${pid}" > "${COMFY_PID_FILE}"
  echo "Started V8 ComfyUI PID ${pid} on port 8188."
}

verify_runtime() {
  local started=$SECONDS pid objects="${STATE_DIR}/object_info.json"
  pid="$(cat "${COMFY_PID_FILE}")"
  until curl -fsS "http://127.0.0.1:${COMFY_PORT}/system_stats" >/dev/null 2>&1; do
    is_pid_alive "${pid}" || { echo "[FATAL] ComfyUI exited during startup"; tail -150 "${COMFY_LOG}"; return 1; }
    (( SECONDS - started <= START_TIMEOUT_SECONDS )) || { echo "[FATAL] ComfyUI readiness timeout"; tail -150 "${COMFY_LOG}"; return 1; }
    sleep 3
  done
  curl -fsS "http://127.0.0.1:${COMFY_PORT}/object_info" -o "${objects}"
  python3 - "${objects}" "${COMFY_DIR}" <<'PY'
import json,os,sys
objects=json.load(open(sys.argv[1])); root=sys.argv[2]
required={'UNETLoader','LoraLoaderModelOnly','CLIPLoader','VAELoader','CLIPTextEncode','EmptySD3LatentImage','ModelSamplingAuraFlow','KSampler','VAEDecode','SaveImage'}
missing=sorted(required-set(objects))
if missing: raise SystemExit('Missing native nodes: '+', '.join(missing))
files=[
 ('models/diffusion_models/z_image_bf16.safetensors','UNETLoader','unet_name'),
 ('models/text_encoders/qwen_3_4b.safetensors','CLIPLoader','clip_name'),
 ('models/vae/ae.safetensors','VAELoader','vae_name'),
 ('models/loras/uncutpenis_ZIT_v3.1_000004500.safetensors','LoraLoaderModelOnly','lora_name')]
for rel,node,key in files:
    if not os.path.isfile(os.path.join(root,rel)): raise SystemExit('Missing model file: '+rel)
    choices=objects[node]['input']['required'][key][0]
    name=os.path.basename(rel)
    if name not in choices: raise SystemExit(f'{name} is not visible to {node}')
for wf in ('ZImage_Base_Uncut_Haruka041_V8.json','ZImage_Base_Clean_V8.json'):
    p=os.path.join(root,'user/default/workflows',wf)
    data=json.load(open(p,encoding='utf-8'))
    wf_missing=sorted({n['type'] for n in data['nodes']}-set(objects))
    if wf_missing: raise SystemExit(f'{wf} has unavailable nodes: {wf_missing}')
print('[OK] HTTP readiness, native nodes, model visibility and both workflows verified')
PY
  echo "[OK] ComfyUI is ready at port ${COMFY_PORT}."
}

summary() {
  say "V8 SETUP COMPLETE"
  cat <<EOF
READY

Environment : ${COMFY_DIR}
Port        : ${COMFY_PORT}
Comfy log   : ${COMFY_LOG}

Primary workflow:
  ${COMFY_DIR}/user/default/workflows/ZImage_Base_Uncut_Haruka041_V8.json

Clean Base workflow:
  ${COMFY_DIR}/user/default/workflows/ZImage_Base_Clean_V8.json

Installed and verified:
  ComfyUI ${COMFY_REF}
  Z-Image Base BF16
  Qwen3 4B text encoder
  Z-Image VAE
  Haruka041/uncut v3.1 LoRA
  Port 8188 HTTP readiness
  Required native nodes and model visibility

Suggested starting values:
  1024x1024 / 30 steps / CFG 4
  res_multistep / simple / LoRA strength 1.0

Status: $0 --status
Log   : $0 --follow
EOF
}

worker_main() {
  trap 'worker_error ${LINENO}' ERR
  if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    echo "[FATAL] Another V8 installer is already running."
    return 1
  fi
  trap 'rm -rf "${LOCK_DIR}" 2>/dev/null || true' EXIT
  echo RUNNING > "${STATUS_FILE}"
  echo "${BASHPID}" > "${PID_FILE}"
  say "Z-IMAGE BASE + HARUKA041 UNCUT — ${INSTALLER_VERSION}"
  echo "Fresh environment: ${COMFY_DIR}"
  echo "Fixed port: 8188"

  run_phase "[1/10] Stop earlier Z-Image installers" 120 stop_prior_installers
  run_phase "[2/10] System tools and GPU preflight" "${NORMAL_TIMEOUT_SECONDS}" ensure_tools_and_gpu
  run_phase "[3/10] Port 8188 preflight" 120 free_port_8188
  run_phase "[4/10] Fresh ComfyUI core (${COMFY_REF})" "${CLONE_TIMEOUT_SECONDS}" fresh_comfyui_core
  run_phase "[5/10] Dedicated fast Python environment" "${NORMAL_TIMEOUT_SECONDS}" prepare_python
  run_phase "[6/10] Model directories and disk preflight" 300 prepare_model_dirs
  run_phase "[7/10] Verified Base models and Uncut LoRA" "${MODEL_TIMEOUT_SECONDS}" install_models
  run_phase "[8/10] Native V8 workflows" 300 write_native_workflows
  run_phase "[9/10] Start ComfyUI on port 8188" 180 start_comfyui
  run_phase "[10/10] Runtime, model and workflow verification" "${START_TIMEOUT_SECONDS}" verify_runtime

  echo READY > "${STATUS_FILE}"
  set_phase READY
  summary
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

case "${1:-}" in
  --worker) worker_main ;;
  --follow) follow_log ;;
  --status) show_status ;;
  --stop-setup) stop_setup ;;
  --help|-h) usage ;;
  "") launch_detached ;;
  *) usage; exit 2 ;;
esac
