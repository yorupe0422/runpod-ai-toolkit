#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# RunPod + ComfyUI BOOTH Anime Character Comparison Pack v1
#
# Purpose:
#   Extend the already-working V4 ComfyUI-ZImage environment WITHOUT replacing
#   its Python/CUDA stack.
#
# Adds:
#   - Animagine XL 4.0 Opt
#   - Illustrious XL v2.0
#   - Ready-to-load ComfyUI workflows for both models
#   - Prompt preset for an ADULT 18-year-old university student character
#   - Model/license/source manifest
#
# Reliability principles:
#   - No pip install / no torch reinstall / no ComfyUI upgrade.
#   - Large downloads resume with aria2c.
#   - Safetensors headers and minimum sizes are validated.
#   - Existing Z-Image model files are untouched.
#   - ComfyUI is restarted only AFTER all downloads and workflow files succeed.
#   - Port 8188 is only stopped automatically if it belongs to this ComfyUI dir.
#   - No image generation is performed by this setup script.
###############################################################################

SCRIPT_NAME="runpod_booth_anime_compare_setup_v1"
BASE_DIR="${BASE_DIR:-/workspace/runpod-slim}"
COMFY_DIR="${COMFY_DIR:-${BASE_DIR}/ComfyUI-ZImage}"
VENV_DIR="${VENV_DIR:-${COMFY_DIR}/.venv}"
PORT="${COMFY_PORT:-8188}"
HOST="${COMFY_HOST:-0.0.0.0}"
STATE_DIR="${BASE_DIR}/.booth_anime_compare_v1"
PHASE_DIR="${STATE_DIR}/phases"
SETUP_LOG="${STATE_DIR}/setup.log"
STATUS_FILE="${STATE_DIR}/status"
PHASE_FILE="${STATE_DIR}/phase"
PID_FILE="${STATE_DIR}/setup.pid"
LOCK_DIR="${STATE_DIR}/setup.lock.d"
WORKFLOW_DIR="${COMFY_DIR}/user/default/workflows"
EXPORT_WF_DIR="${BASE_DIR}/booth_workflows"
CHECKPOINT_DIR="${COMFY_DIR}/models/checkpoints"
HEARTBEAT_SECONDS="${HEARTBEAT_SECONDS:-15}"
MODEL_TIMEOUT_SECONDS="${MODEL_TIMEOUT_SECONDS:-7200}"
STARTUP_TIMEOUT_SECONDS="${STARTUP_TIMEOUT_SECONDS:-180}"
INSTALL_ILLUSTRIOUS="${INSTALL_ILLUSTRIOUS:-1}"

ANIMAGINE_NAME="animagine-xl-4.0-opt.safetensors"
ANIMAGINE_URL="https://huggingface.co/cagliostrolab/animagine-xl-4.0/resolve/main/animagine-xl-4.0-opt.safetensors?download=true"
ILLUSTRIOUS_NAME="Illustrious-XL-v2.0.safetensors"
ILLUSTRIOUS_URL="https://huggingface.co/OnomaAIResearch/Illustrious-XL-v2.0/resolve/main/Illustrious-XL-v2.0.safetensors?download=true"

mkdir -p "${STATE_DIR}" "${PHASE_DIR}"

usage() {
  cat <<EOF_USAGE
${SCRIPT_NAME}

Usage:
  $0                 Start detached installer and follow log
  $0 --follow        Follow current/last installer log
  $0 --status        Show status
  $0 --stop-setup    Stop only this installer worker
  $0 --worker        Internal worker mode
  $0 --help          Show help

Environment overrides:
  COMFY_PORT=8188
  INSTALL_ILLUSTRIOUS=1   1 = install both models, 0 = Animagine only

This is an ADD-ON for the successful V4 environment at:
  /workspace/runpod-slim/ComfyUI-ZImage

It intentionally does NOT install/upgrade PyTorch, Python packages, or ComfyUI.
It does NOT generate an image.
EOF_USAGE
}

now_human() { date '+%Y-%m-%d %H:%M:%S'; }
human_elapsed() { local t="${1:-0}"; printf '%02d:%02d:%02d' $((t/3600)) $(((t%3600)/60)) $((t%60)); }
is_pid_alive() { [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null; }

say() {
  echo
  echo "================================================================"
  echo "[$(now_human)] $*"
  echo "================================================================"
}

set_phase() { echo "$*" > "${PHASE_FILE}"; }

show_status() {
  local status="NOT_STARTED" phase="-" pid=""
  [[ -f "${STATUS_FILE}" ]] && status="$(cat "${STATUS_FILE}" 2>/dev/null || true)"
  [[ -f "${PHASE_FILE}" ]] && phase="$(cat "${PHASE_FILE}" 2>/dev/null || true)"
  [[ -f "${PID_FILE}" ]] && pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  echo "Status : ${status}"
  echo "Phase  : ${phase}"
  if is_pid_alive "${pid}"; then
    echo "Worker : RUNNING (PID ${pid})"
    ps -p "${pid}" -o pid=,etime=,%cpu=,%mem=,stat=,cmd= 2>/dev/null || true
  else
    echo "Worker : not running${pid:+ (last PID ${pid})}"
  fi
  echo "Log    : ${SETUP_LOG}"
  echo "ComfyUI: ${COMFY_DIR}"
  echo "Port   : ${PORT}"
}

follow_log() {
  touch "${SETUP_LOG}"
  echo "Following ${SETUP_LOG}"
  echo "Reconnect command: ${BASH_SOURCE[0]} --follow"
  tail -n 80 -F "${SETUP_LOG}"
}

stop_setup() {
  local pid=""
  [[ -f "${PID_FILE}" ]] && pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if is_pid_alive "${pid}"; then
    kill "${pid}" || true
    echo "Stopped installer PID ${pid}"
  else
    echo "Installer is not running."
  fi
}

worker_error() {
  local line="${1:-?}"
  echo "FAILED" > "${STATUS_FILE}"
  set_phase "FAILED at line ${line}"
  echo
  echo "[FATAL] Setup failed at line ${line}."
  echo "Last setup log lines:"
  tail -n 100 "${SETUP_LOG}" 2>/dev/null || true
}

launch_detached() {
  if [[ -f "${PID_FILE}" ]]; then
    local old="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if is_pid_alive "${old}"; then
      echo "Installer already running: PID ${old}"
      follow_log
      return
    fi
  fi

  mkdir -p "${STATE_DIR}" "${PHASE_DIR}"
  : > "${SETUP_LOG}"
  nohup bash "${BASH_SOURCE[0]}" --worker >> "${SETUP_LOG}" 2>&1 < /dev/null &
  local pid=$!
  echo "${pid}" > "${PID_FILE}"
  echo "Started detached anime comparison setup worker: PID ${pid}"
  echo "Installer survives browser Terminal disconnects."
  echo "Log: ${SETUP_LOG}"
  sleep 1
  follow_log
}

ensure_tools() {
  local missing=()
  local c
  for c in aria2c curl python3 lsof git; do
    command -v "${c}" >/dev/null 2>&1 || missing+=("${c}")
  done
  if ((${#missing[@]})); then
    say "Install missing OS tools: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends aria2 curl python3 lsof git ca-certificates
  else
    echo "All required OS tools already present."
  fi
}

preflight() {
  say "Preflight: verify successful V4 base environment"
  [[ -d "${COMFY_DIR}" ]] || { echo "[FATAL] Missing ComfyUI directory: ${COMFY_DIR}"; exit 10; }
  [[ -f "${COMFY_DIR}/main.py" ]] || { echo "[FATAL] Missing ${COMFY_DIR}/main.py"; exit 11; }
  [[ -x "${VENV_DIR}/bin/python" ]] || { echo "[FATAL] Missing working venv: ${VENV_DIR}"; exit 12; }

  # Verify the official Z-Image core that V4 established. We do not modify it.
  [[ -s "${COMFY_DIR}/models/diffusion_models/z_image_turbo_bf16.safetensors" ]] || {
    echo "[FATAL] V4 Z-Image core is missing. Run the successful V4 setup first."; exit 13;
  }

  mkdir -p "${CHECKPOINT_DIR}" "${WORKFLOW_DIR}" "${EXPORT_WF_DIR}" "${COMFY_DIR}/output/booth_compare"

  echo "Base ComfyUI : ${COMFY_DIR}"
  echo "Python       : $(${VENV_DIR}/bin/python -V 2>&1)"
  echo "Checkpoint dir: ${CHECKPOINT_DIR}"
  echo "Workspace free: $(df -h "${BASE_DIR}" | awk 'NR==2{print $4}')"
  nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null || true
}

validate_safetensors() {
  local path="$1"
  local min_bytes="$2"
  python3 - "${path}" "${min_bytes}" <<'PY'
import json, os, struct, sys
p=sys.argv[1]; minimum=int(sys.argv[2])
if not os.path.isfile(p):
    raise SystemExit(f"MISSING: {p}")
size=os.path.getsize(p)
if size < minimum:
    raise SystemExit(f"TOO SMALL: {p} size={size} minimum={minimum}")
with open(p,'rb') as f:
    raw=f.read(8)
    if len(raw)!=8: raise SystemExit(f"BAD HEADER: {p}")
    n=struct.unpack('<Q',raw)[0]
    if not (2 <= n <= 100_000_000): raise SystemExit(f"BAD HEADER LENGTH: {n}")
    hdr=f.read(n)
try:
    obj=json.loads(hdr)
except Exception as e:
    raise SystemExit(f"INVALID SAFETENSORS JSON HEADER: {e}")
if not isinstance(obj,dict) or len(obj)==0:
    raise SystemExit("EMPTY SAFETENSORS HEADER")
print(f"VALID SAFETENSORS: {p} size={size} header={n}")
PY
}

run_monitored_download() {
  local label="$1" url="$2" dest="$3" min_bytes="$4"
  local dir name log pid start last_size current_size elapsed
  dir="$(dirname "${dest}")"; name="$(basename "${dest}")"
  log="${PHASE_DIR}/$(echo "${label}" | tr ' /' '__').log"
  mkdir -p "${dir}"

  if [[ -f "${dest}" ]]; then
    if validate_safetensors "${dest}" "${min_bytes}" >/dev/null 2>&1; then
      echo "[SKIP] Valid existing ${label}: ${dest}"
      validate_safetensors "${dest}" "${min_bytes}"
      return 0
    fi
    echo "[WARN] Existing file is incomplete/invalid; aria2 will resume or replace it: ${dest}"
  fi

  say "Download ${label}"
  set_phase "Download ${label}"
  : > "${log}"

  aria2c \
    --continue=true \
    --max-connection-per-server=8 \
    --split=8 \
    --min-split-size=16M \
    --file-allocation=none \
    --auto-file-renaming=false \
    --allow-overwrite=true \
    --summary-interval=10 \
    --console-log-level=notice \
    --dir="${dir}" \
    --out="${name}" \
    "${url}" > "${log}" 2>&1 &
  pid=$!
  start=$(date +%s)
  last_size=-1

  while is_pid_alive "${pid}"; do
    sleep "${HEARTBEAT_SECONDS}"
    elapsed=$(( $(date +%s) - start ))
    current_size=$(stat -c%s "${dest}" 2>/dev/null || echo 0)
    printf '[ALIVE] %s | elapsed=%s | downloaded=%s\n' \
      "${label}" "$(human_elapsed "${elapsed}")" "$(numfmt --to=iec-i --suffix=B "${current_size}" 2>/dev/null || echo "${current_size}B")"
    tail -n 8 "${log}" 2>/dev/null || true
    if (( elapsed > MODEL_TIMEOUT_SECONDS )); then
      echo "[FATAL] Download timed out after $(human_elapsed "${elapsed}"): ${label}"
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      return 124
    fi
    last_size="${current_size}"
  done

  wait "${pid}"
  tail -n 20 "${log}" 2>/dev/null || true
  validate_safetensors "${dest}" "${min_bytes}"
}

write_workflows_and_presets() {
  say "Create BOOTH anime-character workflows and prompt presets"
  set_phase "Create workflows"

  COMFY_DIR="${COMFY_DIR}" WORKFLOW_DIR="${WORKFLOW_DIR}" EXPORT_WF_DIR="${EXPORT_WF_DIR}" \
  ANIMAGINE_NAME="${ANIMAGINE_NAME}" ILLUSTRIOUS_NAME="${ILLUSTRIOUS_NAME}" INSTALL_ILLUSTRIOUS="${INSTALL_ILLUSTRIOUS}" \
  python3 <<'PY'
import json, os
from pathlib import Path

workflow_dir=Path(os.environ['WORKFLOW_DIR'])
export_dir=Path(os.environ['EXPORT_WF_DIR'])
animagine=os.environ['ANIMAGINE_NAME']
illustrious=os.environ['ILLUSTRIOUS_NAME']
install_illustrious=os.environ.get('INSTALL_ILLUSTRIOUS','1')=='1'
workflow_dir.mkdir(parents=True, exist_ok=True)
export_dir.mkdir(parents=True, exist_ok=True)

positive=(
"1girl, solo, adult, 18 years old, university student, young adult, full body, standing, looking at viewer, "
"light brown hair, high side ponytail, side bangs, amber eyes, slightly sharp eyes, "
"smug expression, mischievous smile, raised eyebrow, confident expression, cheeky expression, "
"oversized cream hoodie, white t-shirt, black pleated skirt, black knee-high socks, white sneakers, black shoulder bag, "
"one hand on hip, confident standing pose, slight head tilt, cute, fashionable, energetic, mischievous personality, "
"modern Japanese university student, anime game character, visual novel character, TRPG character sprite, "
"clean lineart, beautiful detailed eyes, detailed hair, polished cel shading, professional character illustration, "
"full body, head to toe, both shoes visible, simple white background, safe, masterpiece, high score, great score, absurdres"
)
negative=(
"lowres, bad anatomy, bad hands, malformed hands, text, error, missing finger, extra digits, fewer digits, "
"extra limbs, cropped, out of frame, worst quality, low quality, low score, bad score, average score, "
"signature, watermark, username, blurry, child, loli, elementary school student, middle school student, toddler, "
"photorealistic, photograph, 3d, multiple girls, background objects"
)

def workflow(checkpoint, prefix, title):
    nodes=[
      {"id":1,"type":"CheckpointLoaderSimple","pos":[0,0],"size":[350,100],"flags":{},"order":0,"mode":0,
       "inputs":[],"outputs":[{"name":"MODEL","type":"MODEL","links":[1],"slot_index":0},{"name":"CLIP","type":"CLIP","links":[2,3],"slot_index":1},{"name":"VAE","type":"VAE","links":[8],"slot_index":2}],
       "title":f"{title} - Load Checkpoint","properties":{"Node name for S&R":"CheckpointLoaderSimple"},"widgets_values":[checkpoint]},
      {"id":2,"type":"CLIPTextEncode","pos":[420,-10],"size":[520,300],"flags":{},"order":1,"mode":0,
       "inputs":[{"name":"clip","type":"CLIP","link":2}],"outputs":[{"name":"CONDITIONING","type":"CONDITIONING","links":[4],"slot_index":0}],
       "title":"POSITIVE - adult 18yo university student / cheeky character","properties":{"Node name for S&R":"CLIPTextEncode"},"widgets_values":[positive]},
      {"id":3,"type":"CLIPTextEncode","pos":[420,340],"size":[520,260],"flags":{},"order":2,"mode":0,
       "inputs":[{"name":"clip","type":"CLIP","link":3}],"outputs":[{"name":"CONDITIONING","type":"CONDITIONING","links":[5],"slot_index":0}],
       "title":"NEGATIVE","properties":{"Node name for S&R":"CLIPTextEncode"},"widgets_values":[negative]},
      {"id":4,"type":"EmptyLatentImage","pos":[0,220],"size":[300,120],"flags":{},"order":3,"mode":0,
       "inputs":[],"outputs":[{"name":"LATENT","type":"LATENT","links":[6],"slot_index":0}],
       "properties":{"Node name for S&R":"EmptyLatentImage"},"widgets_values":[832,1216,1]},
      {"id":5,"type":"KSampler","pos":[1030,90],"size":[330,340],"flags":{},"order":4,"mode":0,
       "inputs":[{"name":"model","type":"MODEL","link":1},{"name":"positive","type":"CONDITIONING","link":4},{"name":"negative","type":"CONDITIONING","link":5},{"name":"latent_image","type":"LATENT","link":6}],
       "outputs":[{"name":"LATENT","type":"LATENT","links":[7],"slot_index":0}],
       "properties":{"Node name for S&R":"KSampler"},"widgets_values":[0,"randomize",28,5.0,"euler_ancestral","normal",1.0]},
      {"id":6,"type":"VAEDecode","pos":[1430,100],"size":[250,100],"flags":{},"order":5,"mode":0,
       "inputs":[{"name":"samples","type":"LATENT","link":7},{"name":"vae","type":"VAE","link":8}],
       "outputs":[{"name":"IMAGE","type":"IMAGE","links":[9],"slot_index":0}],
       "properties":{"Node name for S&R":"VAEDecode"},"widgets_values":[]},
      {"id":7,"type":"SaveImage","pos":[1750,40],"size":[480,500],"flags":{},"order":6,"mode":0,
       "inputs":[{"name":"images","type":"IMAGE","link":9}],"outputs":[],
       "properties":{"Node name for S&R":"SaveImage"},"widgets_values":[prefix]},
      {"id":8,"type":"Note","pos":[0,400],"size":[300,270],"flags":{},"order":7,"mode":0,"inputs":[],"outputs":[],
       "title":"BOOTH comparison settings","properties":{"text":""},
       "widgets_values":["Adult character test. Animagine official guidance: 832x1216, CFG 5, 28 steps, Euler Ancestral. Keep the CHARACTER SPEC constant across models. Compare thumbnail appeal, face distinctiveness, anatomy, and expression-difference potential."]}
    ]
    links=[
      [1,1,0,5,0,"MODEL"], [2,1,1,2,0,"CLIP"], [3,1,1,3,0,"CLIP"],
      [4,2,0,5,1,"CONDITIONING"], [5,3,0,5,2,"CONDITIONING"], [6,4,0,5,3,"LATENT"],
      [7,5,0,6,0,"LATENT"], [8,1,2,6,1,"VAE"], [9,6,0,7,0,"IMAGE"]
    ]
    return {"last_node_id":8,"last_link_id":9,"nodes":nodes,"links":links,"groups":[],"config":{},"extra":{"ds":{"scale":0.75,"offset":[250,180]}},"version":0.4}

files={
  'booth_animagine_xl4_character_v1.json': workflow(animagine, 'booth_compare/animagine_xl4', 'Animagine XL 4.0 Opt'),
}
if install_illustrious:
    files['booth_illustrious_xl2_character_v1.json']=workflow(illustrious, 'booth_compare/illustrious_xl2', 'Illustrious XL v2.0')
for name,obj in files.items():
    text=json.dumps(obj, ensure_ascii=False, indent=2)
    json.loads(text)
    (workflow_dir/name).write_text(text, encoding='utf-8')
    (export_dir/name).write_text(text, encoding='utf-8')
    print('WROTE', workflow_dir/name)
    print('WROTE', export_dir/name)

preset=f"""BOOTH Anime Character Comparison Preset v1

Character concept (adult):
- 18-year-old university student / young adult
- cheeky, confident, mischievous personality
- side ponytail, amber eyes
- cream hoodie + white T-shirt + black pleated skirt + knee-high socks + sneakers
- full-body standing game/TRPG sprite

POSITIVE:\n{positive}\n\nNEGATIVE:\n{negative}\n
Animagine XL 4.0 official baseline used in workflow:
- 832 x 1216
- 28 steps
- CFG 5
- Euler Ancestral
- normal scheduler

Comparison rule:
Keep the character specification the same. Judge the models by:
1. thumbnail appeal / clickability
2. face distinctiveness vs generic AI face
3. hand/leg/foot stability
4. character-design adherence
5. potential for expression and outfit variants
"""
(workflow_dir/'booth_anime_prompt_preset_v1.txt').write_text(preset,encoding='utf-8')
(export_dir/'booth_anime_prompt_preset_v1.txt').write_text(preset,encoding='utf-8')
PY

  cat > "${EXPORT_WF_DIR}/MODEL_SOURCES_LICENSES.txt" <<EOF_MANIFEST
BOOTH Anime Model Comparison Pack v1
Generated: $(date -Iseconds)

1) Animagine XL 4.0 Opt
Repository: https://huggingface.co/cagliostrolab/animagine-xl-4.0
File: ${ANIMAGINE_NAME}
Hugging Face license label at setup design time: openrail++ / CreativeML Open RAIL++-M

2) Illustrious XL v2.0
Repository: https://huggingface.co/OnomaAIResearch/Illustrious-XL-v2.0
File: ${ILLUSTRIOUS_NAME}
Hugging Face license label at setup design time: creativeml-openrail-m

Before commercial release, preserve this manifest and re-check the model cards/current license terms.
EOF_MANIFEST
  cp -f "${EXPORT_WF_DIR}/MODEL_SOURCES_LICENSES.txt" "${WORKFLOW_DIR}/MODEL_SOURCES_LICENSES.txt"
}

get_listener_pid() {
  lsof -t -iTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null | head -n1 || true
}

restart_comfyui_safely() {
  say "Restart this ComfyUI on port ${PORT} so new checkpoints are detected"
  set_phase "Restart ComfyUI"
  local pid cwd cmd start newpid
  pid="$(get_listener_pid)"

  if [[ -n "${pid}" ]]; then
    cwd="$(readlink -f "/proc/${pid}/cwd" 2>/dev/null || true)"
    cmd="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
    echo "Existing port ${PORT} listener: PID ${pid}"
    echo "cwd: ${cwd}"
    echo "cmd: ${cmd}"
    if [[ "${cwd}" != "${COMFY_DIR}" ]]; then
      echo "[FATAL] Port ${PORT} belongs to a different process/environment. Refusing to kill it."
      exit 30
    fi
    kill "${pid}" || true
    for _ in {1..30}; do
      is_pid_alive "${pid}" || break
      sleep 1
    done
    if is_pid_alive "${pid}"; then
      echo "[WARN] Graceful stop timed out; sending SIGKILL to PID ${pid}."
      kill -9 "${pid}" || true
      sleep 2
    fi
  fi

  cd "${COMFY_DIR}"
  nohup "${VENV_DIR}/bin/python" main.py \
    --listen "${HOST}" \
    --port "${PORT}" \
    --preview-method auto \
    > "${COMFY_DIR}/comfyui_8188.log" 2>&1 < /dev/null &
  newpid=$!
  echo "${newpid}" > "${COMFY_DIR}/comfyui_8188.pid"
  echo "Started ComfyUI PID ${newpid}"

  start=$(date +%s)
  while true; do
    if curl -fsS "http://127.0.0.1:${PORT}/system_stats" >/dev/null 2>&1; then
      echo "[OK] ComfyUI HTTP ready on ${PORT}."
      break
    fi
    if ! is_pid_alive "${newpid}"; then
      echo "[FATAL] ComfyUI exited during startup."
      tail -n 120 "${COMFY_DIR}/comfyui_8188.log" || true
      exit 31
    fi
    local elapsed=$(( $(date +%s)-start ))
    echo "[ALIVE] ComfyUI startup elapsed=$(human_elapsed "${elapsed}") PID=${newpid}"
    if (( elapsed > STARTUP_TIMEOUT_SECONDS )); then
      echo "[FATAL] ComfyUI startup timed out."
      tail -n 120 "${COMFY_DIR}/comfyui_8188.log" || true
      exit 32
    fi
    sleep 5
  done
}

verify_checkpoint_visibility() {
  say "Verify ComfyUI can see the new checkpoints (no image generation)"
  set_phase "Verify checkpoint visibility"
  python3 - "${PORT}" "${ANIMAGINE_NAME}" "${ILLUSTRIOUS_NAME}" "${INSTALL_ILLUSTRIOUS}" <<'PY'
import json, sys, urllib.request
port=int(sys.argv[1]); anim=sys.argv[2]; ill=sys.argv[3]; install_ill=sys.argv[4]=='1'
url=f'http://127.0.0.1:{port}/object_info'
with urllib.request.urlopen(url, timeout=60) as r:
    obj=json.load(r)
loader=obj.get('CheckpointLoaderSimple')
if not loader:
    raise SystemExit('CheckpointLoaderSimple missing from /object_info')
choices=loader.get('input',{}).get('required',{}).get('ckpt_name',[[]])[0]
print('Checkpoint count:', len(choices))
if anim not in choices:
    raise SystemExit(f'Animagine not visible in ComfyUI checkpoint list: {anim}')
print('[OK] visible:', anim)
if install_ill:
    if ill not in choices:
        raise SystemExit(f'Illustrious not visible in ComfyUI checkpoint list: {ill}')
    print('[OK] visible:', ill)
PY
}

summary() {
  say "ANIME COMPARISON ENVIRONMENT READY"
  cat <<EOF_SUMMARY
READY

No image was generated by this setup.

Added checkpoints:
  ${CHECKPOINT_DIR}/${ANIMAGINE_NAME}
$( [[ "${INSTALL_ILLUSTRIOUS}" == "1" ]] && echo "  ${CHECKPOINT_DIR}/${ILLUSTRIOUS_NAME}" )

ComfyUI:
  ${COMFY_DIR}
  Port ${PORT}

Workflows installed inside ComfyUI:
  ${WORKFLOW_DIR}/booth_animagine_xl4_character_v1.json
$( [[ "${INSTALL_ILLUSTRIOUS}" == "1" ]] && echo "  ${WORKFLOW_DIR}/booth_illustrious_xl2_character_v1.json" )

Easy-to-find workflow copies for FileBrowser/drag-drop:
  ${EXPORT_WF_DIR}/booth_animagine_xl4_character_v1.json
$( [[ "${INSTALL_ILLUSTRIOUS}" == "1" ]] && echo "  ${EXPORT_WF_DIR}/booth_illustrious_xl2_character_v1.json" )
  ${EXPORT_WF_DIR}/booth_anime_prompt_preset_v1.txt
  ${EXPORT_WF_DIR}/MODEL_SOURCES_LICENSES.txt

Recommended first comparison:
  1) Load booth_animagine_xl4_character_v1.json
  2) Generate several random seeds manually in ComfyUI
  3) If needed, load booth_illustrious_xl2_character_v1.json
  4) Compare thumbnail appeal, face distinctiveness, anatomy, and variant potential

Status:
  ${BASH_SOURCE[0]} --status

Follow log:
  ${BASH_SOURCE[0]} --follow
EOF_SUMMARY
}

worker_main() {
  trap '' HUP
  trap 'worker_error ${LINENO}' ERR

  if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    if [[ -f "${PID_FILE}" ]] && is_pid_alive "$(cat "${PID_FILE}" 2>/dev/null || true)"; then
      echo "[FATAL] Another anime comparison worker is already running."
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
  echo "INSTALL_ILLUSTRIOUS=${INSTALL_ILLUSTRIOUS}"
  echo "No image generation will be performed."

  ensure_tools
  preflight

  run_monitored_download "Animagine XL 4.0 Opt" "${ANIMAGINE_URL}" \
    "${CHECKPOINT_DIR}/${ANIMAGINE_NAME}" 6000000000

  if [[ "${INSTALL_ILLUSTRIOUS}" == "1" ]]; then
    run_monitored_download "Illustrious XL v2.0" "${ILLUSTRIOUS_URL}" \
      "${CHECKPOINT_DIR}/${ILLUSTRIOUS_NAME}" 6000000000
  fi

  write_workflows_and_presets
  restart_comfyui_safely
  verify_checkpoint_visibility

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
