#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# RunPod + ComfyUI + Z-Image BOOTH Setup v4
#
# Reliability-first redesign.
#
# Core principles:
#   1) Pin ComfyUI to a known stable release (default: v0.33.1).
#   2) Prefer RunPod's already-working CUDA PyTorch instead of reinstalling
#      multi-GB CUDA wheels into /workspace.
#   3) Use a clean local venv with --system-site-packages when possible.
#   4) Install ComfyUI requirements WITHOUT torch/torchvision/torchaudio so pip
#      cannot silently replace a known-good GPU stack.
#   5) Download only the OFFICIAL Z-Image-Turbo core first.
#   6) Resume large model downloads with aria2c and verify safetensors headers.
#   7) Start ComfyUI, verify required nodes, then perform a REAL API generation
#      smoke test. READY is printed only after an image is successfully saved.
#   8) Optional community extras are intentionally separated from core setup.
#   9) Detached worker + heartbeat/status survive browser Terminal disconnects.
###############################################################################

SCRIPT_NAME="runpod_zimage_booth_setup_v4"
BASE_DIR="${BASE_DIR:-/workspace/runpod-slim}"
COMFY_DIR="${COMFY_DIR:-${BASE_DIR}/ComfyUI-ZImage}"
COMFY_REF="${COMFY_REF:-v0.33.1}"
LOCAL_VENV_DIR="${LOCAL_VENV_DIR:-/opt/comfyui-zimage-v4-venv}"
VENV_LINK="${COMFY_DIR}/.venv"
STATE_DIR="${BASE_DIR}/.zimage_booth_v4"
PHASE_DIR="${STATE_DIR}/phases"
SETUP_LOG="${STATE_DIR}/setup.log"
STATUS_FILE="${STATE_DIR}/status"
PHASE_FILE="${STATE_DIR}/phase"
PID_FILE="${STATE_DIR}/setup.pid"
LOCK_DIR="${STATE_DIR}/setup.lock.d"
PORT_FILE="${STATE_DIR}/comfyui.port"
PYTHON_RECORD="${STATE_DIR}/python_source.txt"
REQUESTED_PORT="${COMFY_PORT:-8188}"
HOST="${COMFY_HOST:-0.0.0.0}"
HEARTBEAT_SECONDS="${HEARTBEAT_SECONDS:-15}"
PHASE_TIMEOUT_SECONDS="${PHASE_TIMEOUT_SECONDS:-2400}"
MODEL_TIMEOUT_SECONDS="${MODEL_TIMEOUT_SECONDS:-7200}"
SMOKE_TIMEOUT_SECONDS="${SMOKE_TIMEOUT_SECONDS:-900}"
MIN_WORKSPACE_FREE_GB="${MIN_WORKSPACE_FREE_GB:-30}"
MIN_ROOT_FREE_GB="${MIN_ROOT_FREE_GB:-4}"
WITH_EXTRAS="${WITH_EXTRAS:-0}"

# Official Z-Image files used by ComfyUI's current official template.
Z_UNET_URL="https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors"
Z_CLIP_URL="https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors"
Z_VAE_URL="https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors"
OFFICIAL_WF_URL="https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/image_z_image_turbo.json"

# Optional community extras. They are deliberately NOT required for READY.
BEYOND_URL="https://huggingface.co/Nurburgring/BEYOND_REALITY_Z_IMAGE/resolve/main/BEYOND%20REALITY%20SUPER%20Z%20IMAGE%203.0%20%E6%B7%A1%E5%A6%86%E6%B5%93%E6%8A%B9%20BF16.safetensors"
REALISM_LORA_URL="https://huggingface.co/suayptalha/Z-Image-Turbo-Realism-LoRA/resolve/main/pytorch_lora_weights.safetensors"

mkdir -p "${STATE_DIR}" "${PHASE_DIR}"

usage() {
  cat <<EOF_USAGE
${SCRIPT_NAME}

Usage:
  $0                 Start detached installer and follow its log
  $0 --follow        Follow current/last installer log
  $0 --status        Show current state, phase, PID, ComfyUI port
  $0 --stop-setup    Stop only the v4 installer worker
  $0 --worker        Internal worker mode
  $0 --help          Show this help

Environment overrides:
  COMFY_REF=v0.33.1         Pinned ComfyUI release/tag
  COMFY_PORT=8188           Preferred ComfyUI port
  WITH_EXTRAS=1             Also download Beyond Reality v3 BF16 + Realism LoRA

Do not use curl | bash. Download this script to /workspace, chmod +x, execute it.
EOF_USAGE
}

now_human() { date '+%Y-%m-%d %H:%M:%S'; }

human_elapsed() {
  local total="${1:-0}"
  printf '%02d:%02d:%02d' $((total/3600)) $(((total%3600)/60)) $((total%60))
}

is_pid_alive() {
  local pid="${1:-}"
  [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}

say() {
  echo
  echo "================================================================"
  echo "[$(now_human)] $*"
  echo "================================================================"
}

set_phase() {
  echo "$*" > "${PHASE_FILE}"
}

show_status() {
  local status="NOT_STARTED" phase="-" pid="" port="-"
  [[ -f "${STATUS_FILE}" ]] && status="$(cat "${STATUS_FILE}" 2>/dev/null || true)"
  [[ -f "${PHASE_FILE}" ]] && phase="$(cat "${PHASE_FILE}" 2>/dev/null || true)"
  [[ -f "${PID_FILE}" ]] && pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  [[ -f "${PORT_FILE}" ]] && port="$(cat "${PORT_FILE}" 2>/dev/null || true)"
  echo "Status : ${status}"
  echo "Phase  : ${phase}"
  if is_pid_alive "${pid}"; then
    echo "Worker : RUNNING (PID ${pid})"
    ps -p "${pid}" -o pid=,etime=,%cpu=,%mem=,stat=,cmd= 2>/dev/null || true
  else
    echo "Worker : not running${pid:+ (last PID ${pid})}"
  fi
  echo "Port   : ${port}"
  echo "Log    : ${SETUP_LOG}"
  if [[ -f "${PYTHON_RECORD}" ]]; then
    echo "Python : $(tr '\n' ' ' < "${PYTHON_RECORD}" 2>/dev/null || true)"
  fi
}

follow_log() {
  touch "${SETUP_LOG}"
  local pid=""
  [[ -f "${PID_FILE}" ]] && pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if is_pid_alive "${pid}"; then
    echo "Following v4 setup log. Browser Terminal can disconnect safely."
    echo "Reconnect command: $0 --follow"
    echo
    tail --pid="${pid}" -n 100 -F "${SETUP_LOG}" || true
  else
    tail -n 160 "${SETUP_LOG}" || true
    echo
    show_status
  fi
}

stop_setup() {
  if [[ ! -f "${PID_FILE}" ]]; then
    echo "No v4 installer PID file."
    return 0
  fi
  local pid
  pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if is_pid_alive "${pid}"; then
    echo "Stopping v4 installer PID ${pid}"
    kill "${pid}" 2>/dev/null || true
    sleep 2
    kill -9 "${pid}" 2>/dev/null || true
  else
    echo "Installer is not running."
  fi
}

launch_detached() {
  local self
  self="$(readlink -f "${BASH_SOURCE[0]}")"
  [[ -f "${self}" ]] || { echo "[FATAL] Script must exist as a file." >&2; exit 2; }

  if [[ -f "${PID_FILE}" ]]; then
    local old
    old="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if is_pid_alive "${old}"; then
      echo "v4 installer is already running (PID ${old})."
      follow_log
      return 0
    fi
  fi

  : > "${SETUP_LOG}"
  echo "STARTING" > "${STATUS_FILE}"
  echo "launcher" > "${PHASE_FILE}"

  # setsid + nohup breaks dependency on the browser Terminal session.
  if command -v setsid >/dev/null 2>&1; then
    nohup setsid "${self}" --worker >> "${SETUP_LOG}" 2>&1 < /dev/null &
  else
    nohup "${self}" --worker >> "${SETUP_LOG}" 2>&1 < /dev/null &
  fi
  local pid=$!
  echo "${pid}" > "${PID_FILE}"
  echo "Started detached v4 worker: PID ${pid}"
  echo "Installer survives browser Terminal disconnects."
  echo "Log: ${SETUP_LOG}"
  sleep 1
  follow_log
}

stop_tree() {
  local pid="$1" child
  for child in $(pgrep -P "${pid}" 2>/dev/null || true); do
    stop_tree "${child}"
  done
  kill "${pid}" 2>/dev/null || true
}

stop_old_installers() {
  say "Stop only prior Z-Image setup workers"
  local ver f pid
  for ver in v1 v2 v3; do
    f="${BASE_DIR}/.zimage_booth_${ver}/setup.pid"
    [[ -f "${f}" ]] || continue
    pid="$(cat "${f}" 2>/dev/null || true)"
    if is_pid_alive "${pid}"; then
      echo "Stopping ${ver} worker tree PID ${pid}"
      stop_tree "${pid}"
      sleep 2
    fi
  done
  echo "Prior installer cleanup complete."
}

worker_error() {
  local rc=$? line="${1:-?}"
  echo
  echo "[FAILED] v4 setup failed at line ${line}, exit=${rc}"
  echo "FAILED" > "${STATUS_FILE}"
  echo "failed line ${line}" > "${PHASE_FILE}"
  echo "Last setup lines:"
  tail -n 100 "${SETUP_LOG}" 2>/dev/null || true
  exit "${rc}"
}

phase_slug() {
  echo "$1" | tr '[:upper:] ' '[:lower:]_' | tr -cd 'a-z0-9_.-'
}

run_phase_timeout() {
  local timeout_s="$1" phase="$2"
  shift 2
  local slug log start pid rc=0
  slug="$(phase_slug "${phase}")"
  log="${PHASE_DIR}/${slug}.log"
  : > "${log}"
  set_phase "${phase}"
  say "${phase}"
  echo "[INFO] phase log: ${log}"
  start="$(date +%s)"

  "$@" > "${log}" 2>&1 &
  pid=$!

  local last_log=-1 quiet=0
  while is_pid_alive "${pid}"; do
    sleep "${HEARTBEAT_SECONDS}"
    is_pid_alive "${pid}" || break

    local now elapsed size cpu stat wchan read_b write_b
    now="$(date +%s)"
    elapsed=$((now-start))
    size="$(stat -c %s "${log}" 2>/dev/null || echo 0)"
    cpu="$(ps -p "${pid}" -o %cpu= 2>/dev/null | xargs || echo '?')"
    stat="$(ps -p "${pid}" -o stat= 2>/dev/null | xargs || echo '?')"
    wchan="$(cat "/proc/${pid}/wchan" 2>/dev/null || echo '?')"
    read_b="$(awk '/^read_bytes:/ {print $2}' "/proc/${pid}/io" 2>/dev/null || echo 0)"
    write_b="$(awk '/^write_bytes:/ {print $2}' "/proc/${pid}/io" 2>/dev/null || echo 0)"

    if [[ "${size}" == "${last_log}" ]]; then quiet=$((quiet+HEARTBEAT_SECONDS)); else quiet=0; fi
    last_log="${size}"

    echo "[ALIVE] ${phase} | elapsed=$(human_elapsed "${elapsed}") | pid=${pid} | stat=${stat} | cpu=${cpu}% | quiet=$(human_elapsed "${quiet}")"
    echo "[IO] wait=${wchan} read=${read_b} write=${write_b}"
    echo "[SPACE] workspace=$(df -h "${BASE_DIR}" | awk 'NR==2 {print $4 " free (" $5 " used)"}') | root=$(df -h / | awk 'NR==2 {print $4 " free (" $5 " used)"}')"
    if [[ -s "${log}" ]]; then
      echo "[TAIL]"
      tail -n 5 "${log}" | sed 's/^/       /'
    else
      echo "[TAIL] no output yet"
    fi

    if (( quiet >= 180 )); then
      echo "[NOTICE] No new command log for $(human_elapsed "${quiet}"). Process is still alive; I/O/wait state is shown above."
    fi
    if (( elapsed >= timeout_s )); then
      echo "[TIMEOUT] ${phase} exceeded $(human_elapsed "${timeout_s}")."
      stop_tree "${pid}"
      sleep 2
      kill -9 "${pid}" 2>/dev/null || true
      rc=124
      break
    fi
  done

  if [[ "${rc}" -eq 0 ]]; then
    if wait "${pid}"; then rc=0; else rc=$?; fi
  fi

  local end elapsed
  end="$(date +%s)"; elapsed=$((end-start))
  if [[ "${rc}" -ne 0 ]]; then
    echo "[ERROR] ${phase} failed after $(human_elapsed "${elapsed}") exit=${rc}"
    tail -n 120 "${log}" || true
    return "${rc}"
  fi
  echo "[OK] ${phase} completed in $(human_elapsed "${elapsed}")"
  tail -n 12 "${log}" 2>/dev/null || true
}

run_phase() {
  run_phase_timeout "${PHASE_TIMEOUT_SECONDS}" "$@"
}

ensure_space() {
  say "Preflight storage check"
  local wk root wk_gb root_gb
  wk="$(df -Pk "${BASE_DIR}" | awk 'NR==2 {print $4}')"
  root="$(df -Pk / | awk 'NR==2 {print $4}')"
  wk_gb=$((wk/1024/1024)); root_gb=$((root/1024/1024))
  echo "workspace free: ~${wk_gb} GiB"
  echo "root free     : ~${root_gb} GiB"
  if (( wk_gb < MIN_WORKSPACE_FREE_GB )); then
    echo "[FATAL] Need at least ${MIN_WORKSPACE_FREE_GB} GiB free in ${BASE_DIR}." >&2
    return 1
  fi
  if (( root_gb < MIN_ROOT_FREE_GB )); then
    echo "[FATAL] Need at least ${MIN_ROOT_FREE_GB} GiB free on local root for the venv." >&2
    return 1
  fi
}

ensure_os_tools() {
  local required=(git curl aria2c jq lsof python3)
  local missing=() x
  for x in "${required[@]}"; do command -v "${x}" >/dev/null 2>&1 || missing+=("${x}"); done
  if [[ "${#missing[@]}" -eq 0 ]] && python3 -m venv --help >/dev/null 2>&1; then
    echo "All required OS tools already present; skipping apt."
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  run_phase "APT package index" apt-get update -y
  run_phase "APT required packages" apt-get install -y --no-install-recommends \
    git curl ca-certificates aria2 jq lsof procps util-linux \
    python3 python3-venv python3-pip
}

check_gpu() {
  say "GPU preflight"
  command -v nvidia-smi >/dev/null 2>&1 || { echo "[FATAL] nvidia-smi not found."; return 1; }
  nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader | head -n 1
}

# Prints the first Python executable that already has a working CUDA torch.
find_working_cuda_python() {
  local candidates=(python3 python /usr/local/bin/python3 /usr/bin/python3 /opt/venv/bin/python /venv/bin/python)
  local seen="" c path
  for c in "${candidates[@]}"; do
    if [[ "${c}" == */* ]]; then
      [[ -x "${c}" ]] || continue
      path="${c}"
    else
      path="$(command -v "${c}" 2>/dev/null || true)"
      [[ -n "${path}" ]] || continue
    fi
    case " ${seen} " in *" ${path} "*) continue;; esac
    seen+=" ${path}"

    if "${path}" - <<'PY' >/tmp/zimage_v4_torch_probe.txt 2>&1
import re, sys
try:
    import torch
except Exception as e:
    raise SystemExit(f"torch import failed: {e}")
nums = tuple(int(x) for x in re.findall(r"\d+", torch.__version__.split('+')[0])[:2])
if nums < (2, 7):
    raise SystemExit(f"torch too old: {torch.__version__}")
if not torch.cuda.is_available():
    raise SystemExit("CUDA unavailable")
x = torch.tensor([1.0, 2.0], device="cuda")
y = (x * 3).sum().item()
if y != 9.0:
    raise SystemExit("CUDA math probe failed")
print(sys.executable)
print(torch.__version__)
print(torch.version.cuda)
print(torch.cuda.get_device_name(0))
print(torch.cuda.get_device_capability(0))
PY
    then
      echo "${path}"
      return 0
    fi
  done
  return 1
}

prepare_comfyui_checkout() {
  say "Prepare clean pinned ComfyUI checkout"
  if [[ ! -d "${COMFY_DIR}/.git" ]]; then
    if [[ -e "${COMFY_DIR}" ]]; then
      local backup="${COMFY_DIR}.pre_v4.$(date +%Y%m%d_%H%M%S)"
      echo "Existing non-git directory moved aside: ${backup}"
      mv "${COMFY_DIR}" "${backup}"
    fi
    run_phase "Clone ComfyUI ${COMFY_REF}" git clone --depth 1 --branch "${COMFY_REF}" https://github.com/Comfy-Org/ComfyUI.git "${COMFY_DIR}"
  else
    # Preserve models/output but force code to an exact known release.
    run_phase "Fetch ComfyUI ${COMFY_REF}" git -C "${COMFY_DIR}" fetch --depth 1 --force origin "refs/tags/${COMFY_REF}:refs/tags/${COMFY_REF}"
    run_phase "Checkout ComfyUI ${COMFY_REF}" git -C "${COMFY_DIR}" checkout -f "${COMFY_REF}"
    run_phase "Reset ComfyUI ${COMFY_REF}" git -C "${COMFY_DIR}" reset --hard "${COMFY_REF}"
  fi
  git -C "${COMFY_DIR}" rev-parse HEAD | tee "${STATE_DIR}/comfyui_commit.txt"
}

make_filtered_requirements() {
  "${BOOTSTRAP_PY}" - "${COMFY_DIR}/requirements.txt" "${STATE_DIR}/requirements_no_torch.txt" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
pat = re.compile(r'^\s*(torch|torchvision|torchaudio)(?:\s*[<>=!~].*)?\s*(?:#.*)?$', re.I)
out=[]
for line in open(src, encoding='utf-8'):
    if pat.match(line.strip()):
        print('FILTERED:', line.rstrip())
        continue
    out.append(line)
open(dst,'w',encoding='utf-8').writelines(out)
PY
}

prepare_python_env() {
  say "Prepare Python environment without replacing working CUDA torch"

  local system_py=""
  if system_py="$(find_working_cuda_python)"; then
    BOOTSTRAP_PY="${system_py}"
    echo "Using preinstalled CUDA PyTorch from: ${BOOTSTRAP_PY}"
    cat /tmp/zimage_v4_torch_probe.txt || true

    rm -rf "${LOCAL_VENV_DIR}"
    rm -rf "${VENV_LINK}" 2>/dev/null || true
    run_phase "Create system-site-packages venv" "${BOOTSTRAP_PY}" -m venv --system-site-packages "${LOCAL_VENV_DIR}"
    ln -s "${LOCAL_VENV_DIR}" "${VENV_LINK}"

    echo "mode=system_cuda_torch" > "${PYTHON_RECORD}"
    echo "bootstrap=${BOOTSTRAP_PY}" >> "${PYTHON_RECORD}"
  else
    # Clean fallback: only used when the RunPod image does not ship a usable GPU torch.
    BOOTSTRAP_PY="$(command -v python3)"
    echo "No usable preinstalled CUDA PyTorch found. Using official ComfyUI/PyTorch CUDA 13 fallback."
    [[ -f /tmp/zimage_v4_torch_probe.txt ]] && cat /tmp/zimage_v4_torch_probe.txt || true

    rm -rf "${LOCAL_VENV_DIR}"
    rm -rf "${VENV_LINK}" 2>/dev/null || true
    run_phase "Create clean fallback venv" "${BOOTSTRAP_PY}" -m venv "${LOCAL_VENV_DIR}"
    ln -s "${LOCAL_VENV_DIR}" "${VENV_LINK}"

    run_phase "Upgrade fallback pip" "${VENV_LINK}/bin/python" -m pip install --disable-pip-version-check --no-input -U pip setuptools wheel
    run_phase_timeout "${MODEL_TIMEOUT_SECONDS}" "Install official NVIDIA PyTorch CUDA 13" \
      "${VENV_LINK}/bin/python" -m pip install --disable-pip-version-check --no-input --prefer-binary \
      torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cu130

    echo "mode=installed_cuda_torch" > "${PYTHON_RECORD}"
    echo "bootstrap=${BOOTSTRAP_PY}" >> "${PYTHON_RECORD}"
  fi

  VENV_PY="${VENV_LINK}/bin/python"

  run_phase "Upgrade venv pip tooling" "${VENV_PY}" -m pip install --disable-pip-version-check --no-input -U pip setuptools wheel
  make_filtered_requirements

  # Important: torch lines are filtered so requirements installation cannot replace
  # the already-probed GPU stack.
  run_phase_timeout "${MODEL_TIMEOUT_SECONDS}" "Install ComfyUI non-torch requirements" \
    "${VENV_PY}" -m pip install --disable-pip-version-check --no-input --prefer-binary \
    --upgrade-strategy only-if-needed -r "${STATE_DIR}/requirements_no_torch.txt"

  run_phase "Verify venv CUDA torch" "${VENV_PY}" - <<'PY'
import re, torch
nums = tuple(int(x) for x in re.findall(r"\d+", torch.__version__.split('+')[0])[:2])
print('torch=', torch.__version__)
print('torch_cuda=', torch.version.cuda)
print('cuda_available=', torch.cuda.is_available())
print('gpu=', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'NONE')
print('capability=', torch.cuda.get_device_capability(0) if torch.cuda.is_available() else None)
assert nums >= (2,7), f'PyTorch >=2.7 required; found {torch.__version__}'
assert torch.cuda.is_available(), 'CUDA unavailable inside v4 venv'
x=torch.randn((128,128),device='cuda'); y=x@x
print('cuda_probe_mean=', float(y.mean()))
PY
}

prepare_dirs() {
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

validate_safetensors() {
  local file="$1" min_bytes="$2"
  "${VENV_LINK}/bin/python" - "${file}" "${min_bytes}" <<'PY'
import json, os, struct, sys
p=sys.argv[1]; min_b=int(sys.argv[2])
size=os.path.getsize(p)
if size < min_b:
    raise SystemExit(f'file too small: {size} < {min_b}: {p}')
with open(p,'rb') as f:
    b=f.read(8)
    if len(b)!=8: raise SystemExit('missing safetensors header length')
    hlen=struct.unpack('<Q',b)[0]
    if hlen <= 2 or hlen > 100_000_000: raise SystemExit(f'invalid safetensors header length: {hlen}')
    header=f.read(hlen)
    obj=json.loads(header)
    if not isinstance(obj,dict): raise SystemExit('invalid safetensors JSON header')
print(f'VALID SAFETENSORS: {p} size={size} header={hlen}')
PY
}

download_file() {
  local label="$1" url="$2" dest="$3" min_bytes="$4"
  if [[ -s "${dest}" ]] && validate_safetensors "${dest}" "${min_bytes}" >/dev/null 2>&1; then
    echo "[SKIP] Valid existing ${label}: ${dest}"
    return 0
  fi
  mkdir -p "$(dirname "${dest}")"
  if [[ -f "${dest}" && -f "${dest}.aria2" ]]; then
    echo "[RESUME] Keeping aria2 partial download for ${label}: ${dest}"
  else
    rm -f "${dest}" "${dest}.aria2" 2>/dev/null || true
  fi

  run_phase_timeout "${MODEL_TIMEOUT_SECONDS}" "Download ${label}" \
    aria2c \
      --allow-overwrite=true --auto-file-renaming=false --continue=true \
      --max-connection-per-server=8 --split=8 --min-split-size=16M \
      --connect-timeout=30 --timeout=60 --max-tries=0 --retry-wait=3 \
      --summary-interval=10 --console-log-level=notice --download-result=full \
      --dir="$(dirname "${dest}")" --out="$(basename "${dest}")" "${url}"

  validate_safetensors "${dest}" "${min_bytes}"
}

download_official_core() {
  say "Download and validate OFFICIAL Z-Image-Turbo core"
  download_file "Z-Image-Turbo BF16" "${Z_UNET_URL}" \
    "${COMFY_DIR}/models/diffusion_models/z_image_turbo_bf16.safetensors" 10000000000
  download_file "Qwen3 4B text encoder" "${Z_CLIP_URL}" \
    "${COMFY_DIR}/models/text_encoders/qwen_3_4b.safetensors" 6000000000
  download_file "Z-Image VAE" "${Z_VAE_URL}" \
    "${COMFY_DIR}/models/vae/ae.safetensors" 250000000
}

download_official_workflow() {
  local dst="${COMFY_DIR}/user/default/workflows/booth_zimage_official_v4.json"
  run_phase "Download official Z-Image-Turbo workflow" \
    curl -fL --retry 12 --retry-all-errors --retry-delay 3 --connect-timeout 20 \
    "${OFFICIAL_WF_URL}" -o "${dst}"
  jq -e '.definitions.subgraphs[0].nodes | length > 0' "${dst}" >/dev/null
  echo "[OK] official workflow JSON validated: ${dst}"
}

write_helpers() {
  say "Write start/stop/status helpers"
  cat > "${COMFY_DIR}/start_comfyui_zimage.sh" <<EOF_START
#!/usr/bin/env bash
set -Eeuo pipefail
cd "${COMFY_DIR}"
PORT_TO_USE="\${1:-${REQUESTED_PORT}}"
exec "${VENV_LINK}/bin/python" main.py --listen "${HOST}" --port "\${PORT_TO_USE}" --preview-method auto
EOF_START
  chmod +x "${COMFY_DIR}/start_comfyui_zimage.sh"

  cat > "${COMFY_DIR}/stop_comfyui_zimage.sh" <<EOF_STOP
#!/usr/bin/env bash
set -Eeuo pipefail
PID_FILE="${COMFY_DIR}/comfyui.pid"
if [[ ! -f "\${PID_FILE}" ]]; then echo "No ComfyUI PID file."; exit 0; fi
PID="\$(cat "\${PID_FILE}")"
if kill -0 "\${PID}" 2>/dev/null; then
  kill "\${PID}" || true
  for _ in {1..20}; do kill -0 "\${PID}" 2>/dev/null || break; sleep 0.5; done
  kill -9 "\${PID}" 2>/dev/null || true
  echo "Stopped ComfyUI PID \${PID}"
fi
rm -f "\${PID_FILE}"
EOF_STOP
  chmod +x "${COMFY_DIR}/stop_comfyui_zimage.sh"

  cat > "${COMFY_DIR}/README_BOOTH_ZIMAGE_V4.txt" <<EOF_README
Riko Atelier / BOOTH Z-Image v4

Core model set:
- z_image_turbo_bf16.safetensors
- qwen_3_4b.safetensors
- ae.safetensors

ComfyUI release pinned by installer:
- ${COMFY_REF}

Official workflow:
- user/default/workflows/booth_zimage_official_v4.json

Output folders:
- output/booth_test
- output/booth_selected
- output/booth_product
- output/booth_samples

Core setup is considered READY only after a real 512x512 Z-Image API smoke generation succeeds.
EOF_README
}

find_free_port() {
  local p="$1"
  while lsof -iTCP:"${p}" -sTCP:LISTEN -t >/dev/null 2>&1; do p=$((p+1)); done
  echo "${p}"
}

start_comfyui() {
  say "Start pinned ComfyUI"
  local port old=""
  port="$(find_free_port "${REQUESTED_PORT}")"
  echo "${port}" > "${PORT_FILE}"

  if [[ -f "${COMFY_DIR}/comfyui.pid" ]]; then
    old="$(cat "${COMFY_DIR}/comfyui.pid" 2>/dev/null || true)"
    if is_pid_alive "${old}"; then kill "${old}" 2>/dev/null || true; sleep 2; fi
  fi

  cd "${COMFY_DIR}"
  : > "${COMFY_DIR}/comfyui.log"
  nohup "${VENV_LINK}/bin/python" main.py --listen "${HOST}" --port "${port}" --preview-method auto \
    > "${COMFY_DIR}/comfyui.log" 2>&1 < /dev/null &
  echo $! > "${COMFY_DIR}/comfyui.pid"
  echo "ComfyUI PID=$(cat "${COMFY_DIR}/comfyui.pid") port=${port}"
}

wait_comfy_ready() {
  set_phase "Wait for ComfyUI readiness"
  say "Wait for ComfyUI HTTP readiness"
  local port pid start now elapsed
  port="$(cat "${PORT_FILE}")"; pid="$(cat "${COMFY_DIR}/comfyui.pid")"; start="$(date +%s)"
  while true; do
    if curl -fsS "http://127.0.0.1:${port}/system_stats" >/dev/null 2>&1; then
      echo "[OK] ComfyUI HTTP ready on port ${port}"
      return 0
    fi
    if ! is_pid_alive "${pid}"; then
      echo "[FATAL] ComfyUI exited before readiness"
      tail -n 200 "${COMFY_DIR}/comfyui.log" || true
      return 1
    fi
    sleep 10
    now="$(date +%s)"; elapsed=$((now-start))
    echo "[ALIVE] ComfyUI startup elapsed=$(human_elapsed "${elapsed}") PID=${pid}"
    tail -n 5 "${COMFY_DIR}/comfyui.log" | sed 's/^/[COMFY] /' || true
    (( elapsed < 600 )) || { echo "[FATAL] ComfyUI readiness timeout"; return 1; }
  done
}

verify_required_nodes() {
  set_phase "Verify required Z-Image nodes"
  say "Verify required nodes via /object_info"
  local port
  port="$(cat "${PORT_FILE}")"
  curl -fsS "http://127.0.0.1:${port}/object_info" -o "${STATE_DIR}/object_info.json"
  "${VENV_LINK}/bin/python" - "${STATE_DIR}/object_info.json" <<'PY'
import json,sys
p=sys.argv[1]
d=json.load(open(p,encoding='utf-8'))
required=['UNETLoader','CLIPLoader','VAELoader','CLIPTextEncode','ConditioningZeroOut','EmptySD3LatentImage','ModelSamplingAuraFlow','KSampler','VAEDecode','SaveImage']
missing=[x for x in required if x not in d]
print('Required nodes:', ', '.join(required))
if missing: raise SystemExit('Missing required nodes: '+', '.join(missing))
print('ALL REQUIRED NODES PRESENT')
PY
}

write_smoke_client() {
  cat > "${STATE_DIR}/zimage_smoke_test.py" <<'PY'
import glob, json, os, sys, time, urllib.request
from pathlib import Path

if len(sys.argv)!=4:
    raise SystemExit('usage: smoke.py PORT OUTPUT_DIR TIMEOUT_SECONDS')
port=int(sys.argv[1]); out=Path(sys.argv[2]); timeout=int(sys.argv[3])
base=f'http://127.0.0.1:{port}'
prefix='booth_test/zimage_v4_smoke'

for p in out.glob('booth_test/zimage_v4_smoke*.png'):
    try: p.unlink()
    except OSError: pass

prompt={
 '1': {'class_type':'UNETLoader','inputs':{'unet_name':'z_image_turbo_bf16.safetensors','weight_dtype':'default'}},
 '2': {'class_type':'CLIPLoader','inputs':{'clip_name':'qwen_3_4b.safetensors','type':'lumina2','device':'default'}},
 '3': {'class_type':'VAELoader','inputs':{'vae_name':'ae.safetensors'}},
 '4': {'class_type':'CLIPTextEncode','inputs':{'text':'A simple studio photograph of a red ceramic mug on a wooden table, soft daylight, realistic photography.','clip':['2',0]}},
 '5': {'class_type':'ConditioningZeroOut','inputs':{'conditioning':['4',0]}},
 '6': {'class_type':'EmptySD3LatentImage','inputs':{'width':512,'height':512,'batch_size':1}},
 '7': {'class_type':'ModelSamplingAuraFlow','inputs':{'model':['1',0],'shift':3.0}},
 '8': {'class_type':'KSampler','inputs':{'model':['7',0],'positive':['4',0],'negative':['5',0],'latent_image':['6',0],'seed':123456789,'steps':8,'cfg':1.0,'sampler_name':'res_multistep','scheduler':'simple','denoise':1.0}},
 '9': {'class_type':'VAEDecode','inputs':{'samples':['8',0],'vae':['3',0]}},
 '10': {'class_type':'SaveImage','inputs':{'images':['9',0],'filename_prefix':prefix}},
}
body=json.dumps({'prompt':prompt}).encode()
req=urllib.request.Request(base+'/prompt', data=body, headers={'Content-Type':'application/json'}, method='POST')
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        resp=json.load(r)
except Exception as e:
    raise SystemExit(f'Prompt submit failed: {e}')
print('prompt response=',resp,flush=True)
prompt_id=resp.get('prompt_id')
if not prompt_id: raise SystemExit('No prompt_id returned')

start=time.time(); last=-1
while time.time()-start < timeout:
    files=sorted(out.glob('booth_test/zimage_v4_smoke*.png'), key=lambda p:p.stat().st_mtime)
    if files:
        p=files[-1]
        if p.stat().st_size > 10000:
            try:
                from PIL import Image, ImageStat
                im=Image.open(p).convert('RGB')
                st=ImageStat.Stat(im)
                extrema=im.getextrema()
                if im.size != (512,512): raise SystemExit(f'Unexpected smoke image size: {im.size}')
                if all(lo==hi for lo,hi in extrema): raise SystemExit('Smoke image is uniform/blank')
                if sum(st.var) < 1.0: raise SystemExit('Smoke image variance too low')
                print(f'SMOKE IMAGE OK: {p} size={p.stat().st_size} mean={st.mean} var={st.var}',flush=True)
                raise SystemExit(0)
            except ImportError:
                print(f'SMOKE IMAGE EXISTS: {p} size={p.stat().st_size}',flush=True)
                raise SystemExit(0)
    elapsed=int(time.time()-start)
    if elapsed//15 != last:
        last=elapsed//15
        print(f'[SMOKE ALIVE] elapsed={elapsed}s prompt_id={prompt_id}',flush=True)
    time.sleep(3)

try:
    with urllib.request.urlopen(base+'/history/'+prompt_id, timeout=20) as r:
        hist=json.load(r)
    print('history=',json.dumps(hist)[-8000:],flush=True)
except Exception as e:
    print('history fetch failed:',e,flush=True)
raise SystemExit(f'Smoke generation timed out after {timeout}s')
PY
}

run_smoke_test() {
  write_smoke_client
  local port
  port="$(cat "${PORT_FILE}")"
  run_phase_timeout "${SMOKE_TIMEOUT_SECONDS}" "End-to-end Z-Image generation smoke test" \
    "${VENV_LINK}/bin/python" "${STATE_DIR}/zimage_smoke_test.py" "${port}" "${COMFY_DIR}/output" "$((SMOKE_TIMEOUT_SECONDS-30))"
}

download_optional_extras() {
  [[ "${WITH_EXTRAS}" == "1" ]] || { echo "Optional extras skipped (WITH_EXTRAS=${WITH_EXTRAS})."; return 0; }
  say "Download optional community extras AFTER core smoke test"
  download_file "Beyond Reality Z-Image v3 BF16" "${BEYOND_URL}" \
    "${COMFY_DIR}/models/diffusion_models/beyond_reality_z_image_v3_bf16.safetensors" 10000000000
  download_file "Z-Image Realism LoRA" "${REALISM_LORA_URL}" \
    "${COMFY_DIR}/models/loras/zimage_realism_lora.safetensors" 20000000
}

summary() {
  local port mode
  port="$(cat "${PORT_FILE}")"
  mode="$(grep '^mode=' "${PYTHON_RECORD}" 2>/dev/null | cut -d= -f2- || true)"
  say "V4 SETUP COMPLETE"
  cat <<EOF_SUMMARY
READY

Reliability checks passed:
  [OK] pinned ComfyUI ${COMFY_REF}
  [OK] CUDA PyTorch probe
  [OK] official Z-Image model files + safetensors validation
  [OK] ComfyUI HTTP readiness
  [OK] required Z-Image nodes present
  [OK] real 512x512 Z-Image generation saved and validated

Python mode:
  ${mode}

ComfyUI:
  ${COMFY_DIR}

Port:
  ${port}

Open via your RunPod HTTP service/proxy for port ${port}.

Official workflow:
  ${COMFY_DIR}/user/default/workflows/booth_zimage_official_v4.json

Smoke output:
  ${COMFY_DIR}/output/booth_test/zimage_v4_smoke*.png

Logs:
  ${SETUP_LOG}
  ${COMFY_DIR}/comfyui.log

Status:
  ${BASH_SOURCE[0]} --status

Follow setup log:
  ${BASH_SOURCE[0]} --follow
EOF_SUMMARY
}

worker_main() {
  trap '' HUP
  trap 'worker_error ${LINENO}' ERR

  # Atomic directory lock prevents concurrent v4 workers without depending on flock.
  if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    if [[ -f "${PID_FILE}" ]] && is_pid_alive "$(cat "${PID_FILE}" 2>/dev/null || true)"; then
      echo "[FATAL] Another v4 worker is already running."
      exit 3
    fi
    rm -rf "${LOCK_DIR}" 2>/dev/null || true
    mkdir "${LOCK_DIR}"
  fi
  trap 'rm -rf "${LOCK_DIR}" 2>/dev/null || true' EXIT

  echo "$$" > "${PID_FILE}"
  echo "RUNNING" > "${STATUS_FILE}"
  set_phase "preflight"

  say "${SCRIPT_NAME} worker started"
  echo "Worker PID: $$"
  echo "ComfyUI pinned ref: ${COMFY_REF}"
  echo "Heartbeat: ${HEARTBEAT_SECONDS}s"
  echo "WITH_EXTRAS=${WITH_EXTRAS}"

  mkdir -p "${BASE_DIR}" "${STATE_DIR}" "${PHASE_DIR}"
  stop_old_installers
  ensure_os_tools
  ensure_space
  check_gpu
  prepare_comfyui_checkout
  prepare_dirs
  prepare_python_env
  download_official_core
  download_official_workflow
  write_helpers
  start_comfyui
  wait_comfy_ready
  verify_required_nodes
  run_smoke_test

  # Optional community models happen only after the official core is proven.
  download_optional_extras

  echo "READY" > "${STATUS_FILE}"
  set_phase "READY"
  rm -f "${PID_FILE}"
  summary
}

case "${1:-}" in
  --help|-h) usage ;;
  --status) show_status ;;
  --follow) follow_log ;;
  --stop-setup) stop_setup ;;
  --worker) worker_main ;;
  "") launch_detached ;;
  *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
esac
