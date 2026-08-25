#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# RunPod / ComfyUI / Z-Image Base + Haruka041 Uncut setup v6-fast
#
# - True Z-Image Base (not Z-Image Turbo)
# - Haruka041/uncut v3.1 LoRA
# - Port 8188 only
# - Detached installer survives browser-terminal disconnects
# - Resumable 16-way aria2 downloads with SHA-256 verification
# - Reuses RunPod's CUDA PyTorch and a small local venv
# - Idempotent: verified downloads and unchanged Python dependencies are skipped
# - Does not alter other ComfyUI directories
###############################################################################

SCRIPT_NAME="runpod_zimage_base_uncut_v6_fast"
INSTALLER_VERSION="6.0.0-base-uncut-fast"
BASE_DIR="${BASE_DIR:-/workspace/runpod-slim}"
COMFY_DIR="${COMFY_DIR:-${BASE_DIR}/ComfyUI-ZImage}"
COMFY_REF="${COMFY_REF:-v0.33.4}"
COMFY_PORT="${COMFY_PORT:-8188}"
COMFY_HOST="${COMFY_HOST:-0.0.0.0}"
LOCAL_VENV_DIR="${LOCAL_VENV_DIR:-/tmp/comfyui-zimage-base-v6-venv}"
VENV_LINK="${COMFY_DIR}/.venv"
PIP_CACHE_DIR="${PIP_CACHE_DIR:-/tmp/pip-cache-zimage-base-v6}"
STATE_DIR="${BASE_DIR}/.zimage_base_uncut_v6"
PHASE_DIR="${STATE_DIR}/phases"
SETUP_LOG="${STATE_DIR}/setup.log"
STATUS_FILE="${STATE_DIR}/status"
PHASE_FILE="${STATE_DIR}/phase"
PID_FILE="${STATE_DIR}/setup.pid"
LOCK_DIR="${STATE_DIR}/setup.lock.d"
COMFY_PID_FILE="${STATE_DIR}/comfyui.pid"
COMFY_LOG="${COMFY_DIR}/comfyui.log"
PYTHON_RECORD="${STATE_DIR}/python_source.txt"
HEARTBEAT_SECONDS="${HEARTBEAT_SECONDS:-20}"
PHASE_TIMEOUT_SECONDS="${PHASE_TIMEOUT_SECONDS:-2400}"
MODEL_TIMEOUT_SECONDS="${MODEL_TIMEOUT_SECONDS:-10800}"
RUN_SMOKE="${RUN_SMOKE:-0}"
SMOKE_TIMEOUT_SECONDS="${SMOKE_TIMEOUT_SECONDS:-900}"
RESERVE_VRAM_GB="${RESERVE_VRAM_GB:-4}"

Z_MODEL_NAME="z_image_bf16.safetensors"
Z_CLIP_NAME="qwen_3_4b.safetensors"
Z_VAE_NAME="ae.safetensors"
UNCUT_NAME="uncutpenis_ZIT_v3.1_000004500.safetensors"

Z_MODEL_URL="https://huggingface.co/Comfy-Org/z_image/resolve/main/split_files/diffusion_models/${Z_MODEL_NAME}"
Z_CLIP_URL="https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/${Z_CLIP_NAME}"
Z_VAE_URL="https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/${Z_VAE_NAME}"
UNCUT_REV="e08f941b393446946b59be3951febdd5fb19f490"
UNCUT_URL="https://huggingface.co/Haruka041/uncut/resolve/${UNCUT_REV}/${UNCUT_NAME}"
OFFICIAL_WF_URL="https://raw.githubusercontent.com/Comfy-Org/workflow_templates/refs/heads/main/templates/image_z_image.json"

Z_MODEL_SHA="996a67d3ff666946b1c25cbc16d1b1918b6cc0ac166309e23fe3b3d830263dee"
Z_CLIP_SHA="6c671498573ac2f7a5501502ccce8d2b08ea6ca2f661c458e708f36b36edfc5a"
Z_VAE_SHA="afc8e28272cd15db3919bacdb6918ce9c1ed22e96cb12c4d5ed0fba823529e38"
UNCUT_SHA="f1b56ab6554827472ba4b886c9e7d47ec47af797060cb942bdcb5eebc96d3415"

mkdir -p "${STATE_DIR}" "${PHASE_DIR}"

usage() {
  cat <<EOF
${SCRIPT_NAME} ${INSTALLER_VERSION}

Usage:
  $0                 Start in background and follow the log
  $0 --follow        Follow current/last setup log
  $0 --status        Show installer and ComfyUI status
  $0 --stop-setup    Stop only this installer
  $0 --worker        Internal mode

Useful overrides:
  HF_TOKEN=hf_...            Avoid Hugging Face shared-IP rate limits
  RUN_SMOKE=1                Run a real 512x512 four-step load test (default 0)
  RESERVE_VRAM_GB=4          ComfyUI VRAM reserve

This installer uses port 8188 only. It never falls through to port 8189.
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
  echo "Status : ${status}"
  echo "Phase  : ${phase}"
  is_pid_alive "${pid}" && echo "Worker : RUNNING (PID ${pid})" || echo "Worker : not running"
  is_pid_alive "${comfy_pid}" && echo "ComfyUI: RUNNING (PID ${comfy_pid})" || echo "ComfyUI: not running"
  echo "Port   : ${COMFY_PORT}"
  echo "Log    : ${SETUP_LOG}"
  [[ -f "${PYTHON_RECORD}" ]] && echo "Python : $(tr '\n' ' ' < "${PYTHON_RECORD}")"
}

follow_log() {
  touch "${SETUP_LOG}"
  local pid=""
  [[ -f "${PID_FILE}" ]] && pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if is_pid_alive "${pid}"; then
    echo "Following setup log. Terminal disconnects are safe."
    echo "Reconnect: $0 --follow"
    tail --pid="${pid}" -n 100 -F "${SETUP_LOG}" || true
  else
    tail -n 180 "${SETUP_LOG}" || true
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
    kill -9 "${pid}" 2>/dev/null || true
    echo "Stopped installer PID ${pid}. Completed downloads remain reusable."
  else
    echo "Installer is not running."
  fi
}

launch_detached() {
  local self pid old=""
  self="$(readlink -f "${BASH_SOURCE[0]}")"
  [[ -f "${self}" ]] || { echo "[FATAL] Save this script as a file before executing." >&2; exit 2; }
  [[ -f "${PID_FILE}" ]] && old="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if is_pid_alive "${old}"; then
    echo "Installer is already running (PID ${old})."
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
  echo "Started detached installer PID ${pid}."
  echo "Log: ${SETUP_LOG}"
  sleep 1
  follow_log
}

worker_error() {
  local rc=$? line="${1:-?}"
  trap - ERR
  echo
  echo "[FAILED] Setup failed (exit=${rc}, line=${line})"
  echo FAILED > "${STATUS_FILE}"
  echo "FAILED at line ${line}" > "${PHASE_FILE}"
  echo "Log: ${SETUP_LOG}"
  rm -rf "${LOCK_DIR}" 2>/dev/null || true
  exit "${rc}"
}

run_phase() {
  local label="$1" timeout_s="$2"; shift 2
  set_phase "${label}"
  say "${label}"
  "$@" &
  local child=$! start=$SECONDS last=$SECONDS
  while is_pid_alive "${child}"; do
    if (( SECONDS - start > timeout_s )); then
      stop_tree "${child}"
      sleep 2
      kill -9 "${child}" 2>/dev/null || true
      echo "[FATAL] Phase timeout after ${timeout_s}s: ${label}" >&2
      return 124
    fi
    if (( SECONDS - last >= HEARTBEAT_SECONDS )); then
      local size="-" free="-"
      size="$(du -sh "${COMFY_DIR}" 2>/dev/null | awk '{print $1}' || true)"
      free="$(df -h "${BASE_DIR}" 2>/dev/null | awk 'NR==2{print $4}' || true)"
      echo "[HEARTBEAT] ${label}; elapsed=$((SECONDS-start))s; install=${size:-}; free=${free:-}"
      last=$SECONDS
    fi
    sleep 2
  done
  wait "${child}"
}

ensure_os_tools() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    ca-certificates curl git aria2 python3 python3-venv jq lsof psmisc
  command -v nvidia-smi >/dev/null || { echo "[FATAL] nvidia-smi is unavailable"; return 1; }
  nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
  if [[ -z "${HF_TOKEN:-}" ]]; then
    echo "[WARN] HF_TOKEN is unset. Public downloads work, but RunPod shared-IP 429 limits are more likely."
  else
    echo "[OK] HF_TOKEN is set (value is never printed)."
  fi
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

prepare_checkout() {
  local tracked_status=""
  mkdir -p "${BASE_DIR}"
  if [[ ! -d "${COMFY_DIR}/.git" ]]; then
    [[ ! -e "${COMFY_DIR}" || -z "$(ls -A "${COMFY_DIR}" 2>/dev/null)" ]] || {
      echo "[FATAL] ${COMFY_DIR} exists but is not a git checkout; refusing to overwrite it"; return 1;
    }
    git clone --filter=blob:none --no-checkout https://github.com/Comfy-Org/ComfyUI.git "${COMFY_DIR}"
  fi
  cd "${COMFY_DIR}"
  tracked_status="$(git status --porcelain --untracked-files=no 2>/dev/null || true)"
  if [[ -n "${tracked_status}" ]]; then
    # A terminated/no-checkout installation can leave every tracked path marked
    # only as deleted. There is no edited content to lose in that exact state,
    # so restore the missing code files. Any modification/addition still stops.
    if printf '%s\n' "${tracked_status}" | awk '
      substr($0,1,2)!="D " && substr($0,1,2)!=" D" { bad=1 }
      END { exit bad }
    '; then
      echo "[RECOVER] Incomplete checkout detected (tracked deletions only)."
      echo "          Restoring missing ComfyUI code; models, inputs, outputs and workflows are untouched."
      git restore --source=HEAD --staged --worktree -- .
    else
      echo "[FATAL] Genuine tracked local changes exist in ${COMFY_DIR}; refusing to overwrite them"
      printf '%s\n' "${tracked_status}" | head -80
      [[ "$(printf '%s\n' "${tracked_status}" | wc -l)" -le 80 ]] || echo "... additional status lines omitted"
      return 1
    fi
  fi
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "[FATAL] Tracked local changes exist in ${COMFY_DIR}; refusing to overwrite them"
    git status --short --untracked-files=no | head -80
    return 1
  fi
  git fetch --depth=1 origin "refs/tags/${COMFY_REF}:refs/tags/${COMFY_REF}"
  git checkout --detach -q "${COMFY_REF}"
  echo "[OK] ComfyUI $(git describe --tags --always) at $(git rev-parse --short=12 HEAD)"
}

make_filtered_requirements() {
  awk '
    BEGIN{IGNORECASE=1}
    /^[[:space:]]*(torch|torchvision|torchaudio)([[:space:]]|[<>=!~;\[]|$)/ {next}
    {print}
  ' "${COMFY_DIR}/requirements.txt" > "${STATE_DIR}/requirements.no-torch.txt"
}

prepare_python_env() {
  local base_python="" use_system=0
  mkdir -p "${PIP_CACHE_DIR}"
  export PIP_CACHE_DIR PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_INPUT=1
  if base_python="$(find_cuda_python)"; then use_system=1; else base_python="$(command -v python3)"; fi
  make_filtered_requirements

  if [[ ! -x "${LOCAL_VENV_DIR}/bin/python" ]]; then
    rm -rf "${LOCAL_VENV_DIR}"
    if (( use_system )); then
      "${base_python}" -m venv --system-site-packages "${LOCAL_VENV_DIR}"
    else
      "${base_python}" -m venv "${LOCAL_VENV_DIR}"
    fi
  fi
  ln -sfn "${LOCAL_VENV_DIR}" "${VENV_LINK}"

  local py="${VENV_LINK}/bin/python" req_hash marker
  req_hash="$(sha256sum "${STATE_DIR}/requirements.no-torch.txt" | awk '{print $1}')-$(git -C "${COMFY_DIR}" rev-parse --short=12 HEAD)"
  marker="${LOCAL_VENV_DIR}/.comfy_requirements_hash"

  if ! "${py}" - <<'PY' >/dev/null 2>&1
import torch
assert torch.cuda.is_available()
PY
  then
    echo "[WARN] No reusable CUDA PyTorch found; installing CUDA 12.8 PyTorch (slow fallback)."
    "${py}" -m pip install --no-compile --prefer-binary \
      torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128
  fi

  if [[ ! -f "${marker}" || "$(cat "${marker}" 2>/dev/null || true)" != "${req_hash}" ]]; then
    "${py}" -m pip install --no-compile --prefer-binary -r "${STATE_DIR}/requirements.no-torch.txt"
    echo "${req_hash}" > "${marker}"
  else
    echo "[FAST-SKIP] Python requirements unchanged; reusing ${LOCAL_VENV_DIR}"
  fi
  if ! "${py}" -m pip check; then
    echo "[WARN] pip check reported a conflict inherited from the RunPod base image."
    echo "       This is not fatal here; the dedicated ComfyUI imports and CUDA probe are checked next."
  fi
  "${py}" - <<'PY'
import aiohttp, safetensors, torch, yaml
assert torch.cuda.is_available()
print('[OK] Required Python imports passed')
PY
  "${py}" - <<'PY'
import torch
print(f"[OK] PyTorch {torch.__version__}; CUDA {torch.version.cuda}; GPU {torch.cuda.get_device_name(0)}; capability {torch.cuda.get_device_capability(0)}")
PY
  {
    echo "venv=${LOCAL_VENV_DIR}"
    echo "base_python=${base_python}"
    echo "system_cuda_reused=${use_system}"
  } > "${PYTHON_RECORD}"
}

prepare_dirs_and_space() {
  mkdir -p "${COMFY_DIR}/models/diffusion_models" "${COMFY_DIR}/models/text_encoders" \
    "${COMFY_DIR}/models/vae" "${COMFY_DIR}/models/loras" \
    "${COMFY_DIR}/user/default/workflows" "${COMFY_DIR}/input" "${COMFY_DIR}/output"
  local free_bytes missing=0 path need
  free_bytes="$(df -PB1 "${BASE_DIR}" | awk 'NR==2{print $4}')"
  for path in \
    "${COMFY_DIR}/models/diffusion_models/${Z_MODEL_NAME}:12300000000" \
    "${COMFY_DIR}/models/text_encoders/${Z_CLIP_NAME}:8040000000" \
    "${COMFY_DIR}/models/vae/${Z_VAE_NAME}:335000000" \
    "${COMFY_DIR}/models/loras/${UNCUT_NAME}:341000000"; do
    need="${path##*:}"; path="${path%:*}"
    [[ -f "${path}" ]] || missing=$((missing + need))
  done
  if (( free_bytes < missing + 4000000000 )); then
    echo "[FATAL] Insufficient /workspace free space. Need about $(((missing+4000000000)/1000000000)) GB; available $((free_bytes/1000000000)) GB."
    return 1
  fi
  echo "[OK] Disk preflight: $((free_bytes/1000000000)) GB free; estimated missing payload $((missing/1000000000)) GB"
}

validate_safetensors() {
  local file="$1"
  python3 - "${file}" <<'PY'
import json, os, struct, sys
p=sys.argv[1]
size=os.path.getsize(p)
if size < 16: raise SystemExit(f"too small: {p}")
with open(p,'rb') as f:
    n=struct.unpack('<Q',f.read(8))[0]
    if n <= 2 or n > min(size-8, 256*1024*1024): raise SystemExit(f"bad safetensors header length: {p}")
    obj=json.loads(f.read(n))
    if not isinstance(obj,dict): raise SystemExit(f"bad safetensors header JSON: {p}")
print(f"[OK] safetensors header: {os.path.basename(p)} ({size/1e9:.2f} GB)")
PY
}

download_verified() {
  local url="$1" dst="$2" expected_sha="$3"
  local marker="${dst}.sha256-ok" current_size marker_sha marker_size tmp_input actual
  mkdir -p "$(dirname "${dst}")"
  if [[ -f "${dst}" && -f "${marker}" ]]; then
    read -r marker_sha marker_size < "${marker}" || true
    current_size="$(stat -c %s "${dst}")"
    if [[ "${marker_sha:-}" == "${expected_sha}" && "${marker_size:-}" == "${current_size}" ]]; then
      validate_safetensors "${dst}"
      echo "[FAST-SKIP] Verified model already present: $(basename "${dst}")"
      return 0
    fi
  fi
  if [[ -f "${dst}" ]]; then
    echo "[VERIFY] Existing file has no current marker; calculating SHA-256: $(basename "${dst}")"
    actual="$(sha256sum "${dst}" | awk '{print $1}')"
    if [[ "${actual}" == "${expected_sha}" ]]; then
      validate_safetensors "${dst}"
      printf '%s %s\n' "${expected_sha}" "$(stat -c %s "${dst}")" > "${marker}"
      echo "[OK] Existing file verified; download skipped."
      return 0
    fi
    echo "[WARN] Existing file hash mismatch; moving it aside before resume."
    mv "${dst}" "${dst}.invalid.$(date +%s)"
  fi

  tmp_input="${STATE_DIR}/aria2.$$.txt"
  umask 077
  {
    printf '%s\n' "${url}"
    printf '  dir=%s\n' "$(dirname "${dst}")"
    printf '  out=%s\n' "$(basename "${dst}")"
    [[ -n "${HF_TOKEN:-}" ]] && printf '  header=Authorization: Bearer %s\n' "${HF_TOKEN}"
  } > "${tmp_input}"
  if ! aria2c --input-file="${tmp_input}" --continue=true --max-connection-per-server=16 \
    --split=16 --min-split-size=16M --file-allocation=none --auto-file-renaming=false \
    --allow-overwrite=true --retry-wait=5 --max-tries=0 --timeout=60 \
    --connect-timeout=30 --summary-interval=10 --console-log-level=notice; then
    rm -f "${tmp_input}"
    return 1
  fi
  rm -f "${tmp_input}"
  actual="$(sha256sum "${dst}" | awk '{print $1}')"
  [[ "${actual}" == "${expected_sha}" ]] || {
    echo "[FATAL] SHA-256 mismatch for ${dst}"; echo "expected=${expected_sha}"; echo "actual=${actual}"; return 1;
  }
  validate_safetensors "${dst}"
  printf '%s %s\n' "${expected_sha}" "$(stat -c %s "${dst}")" > "${marker}"
}

download_models() {
  download_verified "${Z_MODEL_URL}" "${COMFY_DIR}/models/diffusion_models/${Z_MODEL_NAME}" "${Z_MODEL_SHA}"
  download_verified "${Z_CLIP_URL}" "${COMFY_DIR}/models/text_encoders/${Z_CLIP_NAME}" "${Z_CLIP_SHA}"
  download_verified "${Z_VAE_URL}" "${COMFY_DIR}/models/vae/${Z_VAE_NAME}" "${Z_VAE_SHA}"
  download_verified "${UNCUT_URL}" "${COMFY_DIR}/models/loras/${UNCUT_NAME}" "${UNCUT_SHA}"
}

write_workflows() {
  local wf_dir="${COMFY_DIR}/user/default/workflows"
  curl -fL --retry 8 --retry-all-errors --connect-timeout 20 \
    "${OFFICIAL_WF_URL}" -o "${wf_dir}/ZImage_Base_Official_v6.json"
  python3 - "${wf_dir}/ZImage_Base_Uncut_Haruka041_v6.json" <<'PY'
import json, sys
out=sys.argv[1]
def props(name):
    return {"Node name for S&R":name,"cnr_id":"comfy-core","ver":"0.3.73"}
nodes=[
 {"id":1,"type":"UNETLoader","pos":[20,20],"size":[320,110],"flags":{},"order":0,"mode":0,
  "inputs":[],"outputs":[{"name":"MODEL","type":"MODEL","links":[1]}],"properties":props("UNETLoader"),"widgets_values":["z_image_bf16.safetensors","default"]},
 {"id":2,"type":"LoraLoaderModelOnly","pos":[390,20],"size":[390,130],"flags":{},"order":1,"mode":0,
  "inputs":[{"name":"model","type":"MODEL","link":1}],"outputs":[{"name":"MODEL","type":"MODEL","links":[2]}],"properties":props("LoraLoaderModelOnly"),"widgets_values":["uncutpenis_ZIT_v3.1_000004500.safetensors",1.0]},
 {"id":3,"type":"CLIPLoader","pos":[20,190],"size":[320,130],"flags":{},"order":2,"mode":0,
  "inputs":[],"outputs":[{"name":"CLIP","type":"CLIP","links":[3,4]}],"properties":props("CLIPLoader"),"widgets_values":["qwen_3_4b.safetensors","lumina2","default"]},
 {"id":4,"type":"VAELoader","pos":[20,370],"size":[320,90],"flags":{},"order":3,"mode":0,
  "inputs":[],"outputs":[{"name":"VAE","type":"VAE","links":[10]}],"properties":props("VAELoader"),"widgets_values":["ae.safetensors"]},
 {"id":5,"type":"CLIPTextEncode","pos":[390,200],"size":[430,250],"flags":{},"order":4,"mode":0,
  "inputs":[{"name":"clip","type":"CLIP","link":3}],"outputs":[{"name":"CONDITIONING","type":"CONDITIONING","links":[5]}],"title":"Positive prompt — describe fictional ADULT subjects explicitly","properties":props("CLIPTextEncode"),"widgets_values":["A high quality photograph of a fictional adult person, natural anatomy, detailed skin, balanced composition, professional lighting"]},
 {"id":6,"type":"CLIPTextEncode","pos":[390,500],"size":[430,190],"flags":{},"order":5,"mode":0,
  "inputs":[{"name":"clip","type":"CLIP","link":4}],"outputs":[{"name":"CONDITIONING","type":"CONDITIONING","links":[6]}],"title":"Negative prompt","properties":props("CLIPTextEncode"),"widgets_values":["low quality, blurry, distorted anatomy, extra limbs, malformed hands, watermark, text"]},
 {"id":7,"type":"EmptySD3LatentImage","pos":[20,520],"size":[320,140],"flags":{},"order":6,"mode":0,
  "inputs":[],"outputs":[{"name":"LATENT","type":"LATENT","links":[7]}],"properties":props("EmptySD3LatentImage"),"widgets_values":[1024,1024,1]},
 {"id":8,"type":"ModelSamplingAuraFlow","pos":[860,20],"size":[330,100],"flags":{},"order":7,"mode":0,
  "inputs":[{"name":"model","type":"MODEL","link":2}],"outputs":[{"name":"MODEL","type":"MODEL","links":[8]}],"properties":props("ModelSamplingAuraFlow"),"widgets_values":[3]},
 {"id":9,"type":"KSampler","pos":[860,180],"size":[330,500],"flags":{},"order":8,"mode":0,
  "inputs":[{"name":"model","type":"MODEL","link":8},{"name":"positive","type":"CONDITIONING","link":5},{"name":"negative","type":"CONDITIONING","link":6},{"name":"latent_image","type":"LATENT","link":7}],
  "outputs":[{"name":"LATENT","type":"LATENT","links":[9]}],"properties":props("KSampler"),"widgets_values":[83472169432,"randomize",30,4.0,"res_multistep","simple",1.0]},
 {"id":10,"type":"VAEDecode","pos":[1250,180],"size":[250,100],"flags":{},"order":9,"mode":0,
  "inputs":[{"name":"samples","type":"LATENT","link":9},{"name":"vae","type":"VAE","link":10}],"outputs":[{"name":"IMAGE","type":"IMAGE","links":[11]}],"properties":props("VAEDecode"),"widgets_values":[]},
 {"id":11,"type":"SaveImage","pos":[1550,180],"size":[360,420],"flags":{},"order":10,"mode":0,
  "inputs":[{"name":"images","type":"IMAGE","link":11}],"outputs":[],"properties":props("SaveImage"),"widgets_values":["ZImageBase_Uncut"]},
 {"id":12,"type":"MarkdownNote","pos":[860,730],"size":[620,210],"flags":{},"order":11,"mode":0,"inputs":[],"outputs":[],"title":"Z-Image Base + Haruka041/uncut v3.1","properties":{},
  "widgets_values":["This workflow uses true Z-Image Base, not Turbo. Start with LoRA strength 1.0; try 0.65–1.0 if the effect is too strong. Official Base guidance: 30–50 steps, CFG 3–5. Use fictional adults only. The model card documents no trigger token, so describe the intended result in ordinary language."]}
]
links=[[1,1,0,2,0,"MODEL"],[2,2,0,8,0,"MODEL"],[3,3,0,5,0,"CLIP"],[4,3,0,6,0,"CLIP"],[5,5,0,9,1,"CONDITIONING"],[6,6,0,9,2,"CONDITIONING"],[7,7,0,9,3,"LATENT"],[8,8,0,9,0,"MODEL"],[9,9,0,10,0,"LATENT"],[10,4,0,10,1,"VAE"],[11,10,0,11,0,"IMAGE"]]
wf={"last_node_id":12,"last_link_id":11,"nodes":nodes,"links":links,"groups":[],"config":{},"extra":{"ds":{"scale":0.72,"offset":[130,80]}},"version":0.4}
with open(out,'w',encoding='utf-8') as f: json.dump(wf,f,ensure_ascii=False,indent=2)
json.load(open(out,encoding='utf-8'))
print(f"[OK] Ready-to-use Uncut workflow: {out}")
PY
}

port_owner_is_ours() {
  local pid="$1" cwd=""
  cwd="$(readlink -f "/proc/${pid}/cwd" 2>/dev/null || true)"
  [[ "${cwd}" == "$(readlink -f "${COMFY_DIR}")" ]]
}

start_comfyui() {
  local pid old
  mapfile -t owners < <(lsof -tiTCP:"${COMFY_PORT}" -sTCP:LISTEN 2>/dev/null | sort -u || true)
  for old in "${owners[@]:-}"; do
    [[ -n "${old}" ]] || continue
    if port_owner_is_ours "${old}"; then
      echo "Stopping prior ComfyUI-ZImage PID ${old} on ${COMFY_PORT}."
      kill "${old}" 2>/dev/null || true
      sleep 3
    else
      echo "[FATAL] Port ${COMFY_PORT} is occupied by unrelated PID ${old}; refusing to kill it or switch to 8189."
      ps -p "${old}" -o pid=,cmd= || true
      return 1
    fi
  done
  cd "${COMFY_DIR}"
  : > "${COMFY_LOG}"
  nohup "${VENV_LINK}/bin/python" main.py --listen "${COMFY_HOST}" --port "${COMFY_PORT}" \
    --preview-method auto --enable-cors-header --reserve-vram "${RESERVE_VRAM_GB}" --cache-none \
    >> "${COMFY_LOG}" 2>&1 < /dev/null &
  pid=$!
  echo "${pid}" > "${COMFY_PID_FILE}"
  echo "Started ComfyUI PID ${pid} on fixed port ${COMFY_PORT}."
}

wait_and_verify() {
  local start=$SECONDS
  until curl -fsS "http://127.0.0.1:${COMFY_PORT}/system_stats" >/dev/null 2>&1; do
    if (( SECONDS - start > 300 )); then
      echo "[FATAL] ComfyUI did not become ready"; tail -120 "${COMFY_LOG}" || true; return 1
    fi
    is_pid_alive "$(cat "${COMFY_PID_FILE}")" || { echo "[FATAL] ComfyUI exited"; tail -120 "${COMFY_LOG}" || true; return 1; }
    sleep 3
  done
  local objects="${STATE_DIR}/object_info.json"
  curl -fsS "http://127.0.0.1:${COMFY_PORT}/object_info" -o "${objects}"
  python3 - "${objects}" <<'PY'
import json,sys
o=json.load(open(sys.argv[1]))
need={'UNETLoader','CLIPLoader','VAELoader','LoraLoaderModelOnly','ModelSamplingAuraFlow','KSampler','SaveImage'}
missing=sorted(need-set(o))
if missing: raise SystemExit('missing required nodes: '+', '.join(missing))
print('[OK] Required native Z-Image and LoRA nodes are available')
PY
}

smoke_test() {
  [[ "${RUN_SMOKE}" == "1" ]] || { echo "[FAST-SKIP] Real generation smoke test disabled (set RUN_SMOKE=1 to enable)."; return 0; }
  local client="${STATE_DIR}/smoke.py"
  cat > "${client}" <<'PY'
import json, os, sys, time, urllib.request
port=sys.argv[1]; outdir=sys.argv[2]
p={
"1":{"class_type":"UNETLoader","inputs":{"unet_name":"z_image_bf16.safetensors","weight_dtype":"default"}},
"2":{"class_type":"LoraLoaderModelOnly","inputs":{"model":["1",0],"lora_name":"uncutpenis_ZIT_v3.1_000004500.safetensors","strength_model":0.7}},
"3":{"class_type":"CLIPLoader","inputs":{"clip_name":"qwen_3_4b.safetensors","type":"lumina2","device":"default"}},
"4":{"class_type":"VAELoader","inputs":{"vae_name":"ae.safetensors"}},
"5":{"class_type":"CLIPTextEncode","inputs":{"clip":["3",0],"text":"A ceramic mug on a wooden table, studio photograph"}},
"6":{"class_type":"CLIPTextEncode","inputs":{"clip":["3",0],"text":"blurry, distorted, text, watermark"}},
"7":{"class_type":"EmptySD3LatentImage","inputs":{"width":512,"height":512,"batch_size":1}},
"8":{"class_type":"ModelSamplingAuraFlow","inputs":{"model":["2",0],"shift":3}},
"9":{"class_type":"KSampler","inputs":{"model":["8",0],"positive":["5",0],"negative":["6",0],"latent_image":["7",0],"seed":12345,"steps":4,"cfg":4.0,"sampler_name":"res_multistep","scheduler":"simple","denoise":1.0}},
"10":{"class_type":"VAEDecode","inputs":{"samples":["9",0],"vae":["4",0]}},
"11":{"class_type":"SaveImage","inputs":{"images":["10",0],"filename_prefix":"zimage_base_uncut_smoke"}}}
data=json.dumps({'prompt':p}).encode(); req=urllib.request.Request(f'http://127.0.0.1:{port}/prompt',data=data,headers={'Content-Type':'application/json'})
with urllib.request.urlopen(req,timeout=30) as r: pid=json.load(r)['prompt_id']
deadline=time.time()+int(os.environ.get('SMOKE_TIMEOUT_SECONDS','900'))
while time.time()<deadline:
    with urllib.request.urlopen(f'http://127.0.0.1:{port}/history/{pid}',timeout=30) as r: h=json.load(r)
    if pid in h:
        status=h[pid].get('status',{})
        if status.get('status_str')=='error': raise SystemExit('smoke generation failed: '+json.dumps(status))
        imgs=h[pid].get('outputs',{}).get('11',{}).get('images',[])
        if imgs:
            path=os.path.join(outdir,imgs[0].get('subfolder',''),imgs[0]['filename'])
            if os.path.getsize(path)>1024: print('[OK] Real LoRA load smoke output:',path); sys.exit(0)
    time.sleep(3)
raise SystemExit('smoke generation timed out')
PY
  SMOKE_TIMEOUT_SECONDS="${SMOKE_TIMEOUT_SECONDS}" "${VENV_LINK}/bin/python" "${client}" "${COMFY_PORT}" "${COMFY_DIR}/output"
}

verify_and_smoke() {
  wait_and_verify
  smoke_test
}

summary() {
  say "SETUP COMPLETE — Z-IMAGE BASE + HARUKA041 UNCUT"
  cat <<EOF
READY

Environment : ${COMFY_DIR}
Port        : ${COMFY_PORT}
Comfy log   : ${COMFY_LOG}

Workflows:
  ${COMFY_DIR}/user/default/workflows/ZImage_Base_Uncut_Haruka041_v6.json
  ${COMFY_DIR}/user/default/workflows/ZImage_Base_Official_v6.json

Installed:
  Z-Image Base BF16
  Qwen3 4B text encoder
  Z-Image VAE
  Haruka041/uncut v3.1 LoRA (pinned revision ${UNCUT_REV:0:12})

Recommended first settings:
  1024x1024, 30 steps, CFG 4, res_multistep/simple
  LoRA strength 1.0; reduce toward 0.65 if the effect is too strong

Status: $0 --status
Log   : $0 --follow
EOF
}

worker_main() {
  trap 'worker_error ${LINENO}' ERR
  if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    echo "[FATAL] Another v6 Z-Image Base setup worker is active."
    return 1
  fi
  trap 'rm -rf "${LOCK_DIR}" 2>/dev/null || true' EXIT
  echo RUNNING > "${STATUS_FILE}"
  echo "${BASHPID}" > "${PID_FILE}"
  say "Z-IMAGE BASE + HARUKA041 UNCUT — FAST SETUP ${INSTALLER_VERSION}"
  echo "Install directory: ${COMFY_DIR}"
  echo "Port: ${COMFY_PORT} (fixed)"
  run_phase "[1/8] System and GPU preflight" "${PHASE_TIMEOUT_SECONDS}" ensure_os_tools
  run_phase "[2/8] Independent ComfyUI core (${COMFY_REF})" "${PHASE_TIMEOUT_SECONDS}" prepare_checkout
  run_phase "[3/8] Fast reusable Python environment" "${PHASE_TIMEOUT_SECONDS}" prepare_python_env
  run_phase "[4/8] Directories and disk preflight" "${PHASE_TIMEOUT_SECONDS}" prepare_dirs_and_space
  run_phase "[5/8] Verified resumable Base models + Uncut LoRA" "${MODEL_TIMEOUT_SECONDS}" download_models
  run_phase "[6/8] Official and ready-to-use workflows" "${PHASE_TIMEOUT_SECONDS}" write_workflows
  run_phase "[7/8] Start and verify ComfyUI on 8188" "${PHASE_TIMEOUT_SECONDS}" start_comfyui
  run_phase "[8/8] HTTP/node verification and optional smoke" "$((SMOKE_TIMEOUT_SECONDS + 360))" verify_and_smoke
  echo READY > "${STATUS_FILE}"
  set_phase READY
  summary
}

case "${1:-}" in
  --worker) worker_main ;;
  --follow) follow_log ;;
  --status) show_status ;;
  --stop-setup) stop_setup ;;
  --help|-h) usage ;;
  "") launch_detached ;;
  *) usage; exit 2 ;;
esac
