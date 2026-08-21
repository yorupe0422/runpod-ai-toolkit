#!/usr/bin/env bash
set -Eeuo pipefail

# SETUP #5 UPDATE — PinkCherry MiniMax H3 FL2VA beta-0.6
#
# Additive update for an existing SETUP #5 environment.
# - Keeps PinkCherry v0.5-alpha and all existing models/workflows.
# - Installs the 21 GB pruned INT8 ConvRot beta-0.6 checkpoint.
# - Creates a non-Turbo 25-step beta-0.6 workflow from the existing
#   known-good PinkCherry v0.5 workflow.
# - Stops the current server on port 8188 (including Ref2VA if active) and
#   starts the selected SETUP #5 FL2VA environment on port 8188.
# - Safe to run again; completed assets are checksum-verified and skipped.

ROOT="/workspace/runpod-slim"
PORT="${PORT:-8188}"

MODEL="PinkCherry_fl2va_MiniMax_H3_pruned_int8_convrot-beta-0.6.safetensors"
MODEL_REPO="SexGod1979/PinkCherry_MiniMax-H3"
MODEL_REVISION="main"
MODEL_SUBPATH="beta-0.6-fl2va/$MODEL"
MODEL_URL="https://huggingface.co/$MODEL_REPO/resolve/$MODEL_REVISION/$MODEL_SUBPATH?download=true"
MODEL_SHA256="0cb2812f061003d9f345186d58f1bafbf902c6ad2b4c064590b4fc4811634ad1"
MODEL_MIN_BYTES=19000000000

OLD_MODEL="PinkCherry_h3_fl2va_pruned_int8_v0.5-alpha.safetensors"
WORKFLOW_NAME="05_PinkCherry_H3_beta06_FL2VA_25STEP.json"

green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
die()    { red "[FAILED] $*"; exit 1; }

COMFY=""
VENV_PY=""
LOG=""
WF_DIR=""
DEST=""

on_error() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    red "SETUP #5 UPDATE FAILED (exit=$rc, line=${BASH_LINENO[0]:-unknown})"
    [[ -n "$LOG" ]] && echo "Log: $LOG"
  fi
  exit "$rc"
}
trap on_error EXIT

echo
echo "================================================================="
echo " SETUP #5 UPDATE — PinkCherry FL2VA beta-0.6"
echo "================================================================="

echo "[1/8] Locate existing SETUP #5 environment"
for candidate in "$ROOT/ComfyUI" "$ROOT/ComfyUI-H3"; do
  if [[ -f "$candidate/main.py" ]] && \
     [[ -s "$candidate/models/diffusion_models/$OLD_MODEL" ]]; then
    COMFY="$candidate"
    break
  fi
done

if [[ -z "$COMFY" ]]; then
  for candidate in "$ROOT/ComfyUI" "$ROOT/ComfyUI-H3"; do
    if [[ -f "$candidate/main.py" ]] && \
       grep -Rqs "MiniMaxH3ImageToVideo" "$candidate/comfy_extras"; then
      COMFY="$candidate"
      break
    fi
  done
fi

[[ -n "$COMFY" ]] || die "SETUP #5 ComfyUI was not found under $ROOT"
[[ -s "$COMFY/models/diffusion_models/$OLD_MODEL" ]] || \
  die "PinkCherry v0.5-alpha is missing; run the complete SETUP #5 first"

if [[ -x "$COMFY/.venv/bin/python" ]]; then
  VENV_PY="$COMFY/.venv/bin/python"
elif command -v python3.12 >/dev/null 2>&1; then
  VENV_PY="$(command -v python3.12)"
elif command -v python3 >/dev/null 2>&1; then
  VENV_PY="$(command -v python3)"
else
  die "Python 3 was not found"
fi

WF_DIR="$COMFY/user/default/workflows"
DEST="$COMFY/models/diffusion_models/$MODEL"
LOG="$ROOT/comfyui-pinkcherry-beta06.log"
mkdir -p "$WF_DIR" "$(dirname "$DEST")"
green "  [OK] $COMFY"

echo "[2/8] System and disk preflight"
if ! command -v curl >/dev/null 2>&1 || \
   ! command -v aria2c >/dev/null 2>&1 || \
   ! command -v lsof >/dev/null 2>&1; then
  command -v apt-get >/dev/null 2>&1 || die "curl/aria2c/lsof are required"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates aria2 lsof
fi

available_kb="$(df -Pk "$(dirname "$DEST")" | awk 'NR==2 {print $4}')"
if [[ ! -s "$DEST" ]] && (( available_kb < 24000000 )); then
  die "At least 24 GB free disk space is required"
fi
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1 || true
green "  [OK] tools and disk"

echo "[3/8] Download PinkCherry beta-0.6 pruned INT8 (~21 GB)"
download_required=1
if [[ -s "$DEST" ]] && [[ "$(stat -c%s "$DEST")" -ge "$MODEL_MIN_BYTES" ]]; then
  echo "  [VERIFY existing] $MODEL"
  existing_sha="$(sha256sum "$DEST" | awk '{print $1}')"
  if [[ "$existing_sha" == "$MODEL_SHA256" ]]; then
    download_required=0
    echo "  [SKIP verified] $MODEL"
  else
    yellow "  Existing file checksum mismatch; keeping it as ${MODEL}.bad"
    mv -f "$DEST" "${DEST}.bad"
    rm -f "$DEST.aria2"
  fi
fi

if (( download_required )); then
  aria_auth=()
  if [[ -n "${HF_TOKEN:-}" ]]; then
    [[ "$HF_TOKEN" == hf_* ]] || die "HF_TOKEN does not look valid"
    aria_auth=(--header="Authorization: Bearer $HF_TOKEN")
    echo "  [OK] Authenticated Hugging Face download"
  else
    yellow "  HF_TOKEN is unset; a shared RunPod IP may receive HTTP 429"
  fi

  aria2c \
    --continue=true \
    --max-connection-per-server=8 \
    --split=8 \
    --min-split-size=16M \
    --file-allocation=none \
    --auto-file-renaming=false \
    --allow-overwrite=true \
    --max-tries=12 \
    --retry-wait=20 \
    --summary-interval=15 \
    --console-log-level=warn \
    "${aria_auth[@]}" \
    --dir="$(dirname "$DEST")" \
    --out="$(basename "$DEST")" \
    "$MODEL_URL"
fi

[[ -s "$DEST" ]] || die "Model download failed"
[[ "$(stat -c%s "$DEST")" -ge "$MODEL_MIN_BYTES" ]] || die "Model file is incomplete"
echo "  [SHA256] $MODEL (this can take several minutes)"
got_sha="$(sha256sum "$DEST" | awk '{print $1}')"
[[ "$got_sha" == "$MODEL_SHA256" ]] || die "SHA256 mismatch for $MODEL"
printf '%s\n' "$MODEL_SHA256" > "${DEST}.sha256-ok"
green "  [OK] $MODEL"

echo "[4/8] Create beta-0.6 non-Turbo 25-step workflow"
COMFY="$COMFY" OLD_MODEL="$OLD_MODEL" NEW_MODEL="$MODEL" \
WORKFLOW_NAME="$WORKFLOW_NAME" "$VENV_PY" - <<'PY'
import copy
import json
import os
from pathlib import Path

comfy = Path(os.environ["COMFY"])
wf_dir = comfy / "user" / "default" / "workflows"
old_model = os.environ["OLD_MODEL"]
new_model = os.environ["NEW_MODEL"]
output = wf_dir / os.environ["WORKFLOW_NAME"]

preferred = [
    wf_dir / "PinkCherry_H3_v0.5_RECOVERY_FLAT_25STEP.json",
    wf_dir / "03_PinkCherry_H3_I2V_20STEP.json",
    wf_dir / "PinkCherry_H3_v0.5_25STEP.json",
]

candidates = []
for path in preferred + sorted(wf_dir.glob("*.json")):
    if path in candidates or not path.is_file() or path == output:
        continue
    try:
        text = path.read_text(encoding="utf-8")
        obj = json.loads(text)
    except Exception:
        continue
    if old_model not in text:
        continue
    if "LoraLoaderModelOnly" in text:
        continue
    candidates.append(path)

if not candidates:
    raise SystemExit(
        "No non-Turbo PinkCherry v0.5 workflow was found. "
        "Run/restore the complete SETUP #5 first."
    )

source = candidates[0]
wf = json.loads(source.read_text(encoding="utf-8"))

old_urls = [
    f"https://huggingface.co/SexGod1979/PinkCherry_MiniMax-H3/resolve/main/alpha-0.5-testing/{old_model}",
    f"https://huggingface.co/SexGod1979/PinkCherry_MiniMax-H3/resolve/main/alpha-0.5-fl2va/{old_model}",
]
new_url = (
    "https://huggingface.co/SexGod1979/PinkCherry_MiniMax-H3/resolve/main/"
    f"beta-0.6-fl2va/{new_model}"
)

def transform(value):
    if isinstance(value, dict):
        out = {k: transform(v) for k, v in value.items()}
        node_type = out.get("type")
        widgets = out.get("widgets_values")
        if node_type == "BasicScheduler" and isinstance(widgets, list):
            if len(widgets) >= 2 and isinstance(widgets[1], int):
                widgets[1] = 25
        if node_type == "SaveVideo" and isinstance(widgets, list) and widgets:
            widgets[0] = "video/PinkCherry_H3_beta06_FL2VA_25STEP"
        return out
    if isinstance(value, list):
        return [transform(v) for v in value]
    if isinstance(value, str):
        value = value.replace(old_model, new_model)
        for old_url in old_urls:
            value = value.replace(old_url, new_url)
        return value
    return value

wf = transform(copy.deepcopy(wf))
wf["id"] = "PinkCherry_H3_beta06_FL2VA_25STEP"

rendered = json.dumps(wf, ensure_ascii=False, indent=2)
if new_model not in rendered:
    raise SystemExit("New model was not written into workflow")
if old_model in rendered:
    raise SystemExit("Old model still remains in generated workflow")
if "LoraLoaderModelOnly" in rendered:
    raise SystemExit("Turbo LoRA unexpectedly remains in baseline workflow")

output.write_text(rendered, encoding="utf-8")
json.loads(output.read_text(encoding="utf-8"))
print(f"  source: {source.name}")
print(f"  output: {output.name}")
PY
green "  [OK] $WORKFLOW_NAME"

echo "[5/8] Static validation"
COMFY="$COMFY" MODEL="$MODEL" WORKFLOW_NAME="$WORKFLOW_NAME" \
"$VENV_PY" - <<'PY'
import json
import os
from pathlib import Path

comfy = Path(os.environ["COMFY"])
model = comfy / "models" / "diffusion_models" / os.environ["MODEL"]
workflow = comfy / "user" / "default" / "workflows" / os.environ["WORKFLOW_NAME"]

if not model.is_file() or model.stat().st_size < 19_000_000_000:
    raise SystemExit("beta-0.6 model is missing or incomplete")
data = json.loads(workflow.read_text(encoding="utf-8"))
text = json.dumps(data)
if os.environ["MODEL"] not in text:
    raise SystemExit("workflow does not reference beta-0.6")
if "LoraLoaderModelOnly" in text:
    raise SystemExit("baseline workflow unexpectedly contains a Turbo LoRA")
print("  beta-0.6 model/workflow validation OK")
PY
green "  [OK] static validation"

echo "[6/8] Switch port $PORT back to SETUP #5 FL2VA"
port_pids="$(lsof -ti tcp:"$PORT" 2>/dev/null || true)"
if [[ -n "$port_pids" ]]; then
  kill $port_pids 2>/dev/null || true
  for _ in $(seq 1 20); do
    sleep 1
    still="$(lsof -ti tcp:"$PORT" 2>/dev/null || true)"
    [[ -z "$still" ]] && break
  done
  still="$(lsof -ti tcp:"$PORT" 2>/dev/null || true)"
  [[ -z "$still" ]] || kill -9 $still 2>/dev/null || true
fi

cd "$COMFY"
nohup "$VENV_PY" main.py \
  --listen 0.0.0.0 \
  --port "$PORT" \
  --preview-method auto \
  --enable-cors-header \
  --reserve-vram 4 \
  --cache-none \
  > "$LOG" 2>&1 &
PID=$!

echo "[7/8] Wait for ComfyUI"
ready=0
for _ in $(seq 1 240); do
  if ! kill -0 "$PID" 2>/dev/null; then
    tail -150 "$LOG" || true
    die "SETUP #5 ComfyUI exited during startup"
  fi
  if curl --max-time 3 -fsS "http://127.0.0.1:$PORT/object_info" \
      > /tmp/setup5_beta06_object_info.json 2>/dev/null; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" == "1" ]] || die "ComfyUI startup timed out on port $PORT"
green "  [OK] server responding"

echo "[8/8] Runtime validation"
MODEL="$MODEL" "$VENV_PY" - <<'PY'
import json
import os

data = json.load(open("/tmp/setup5_beta06_object_info.json", encoding="utf-8"))
required = [
    "MiniMaxH3ImageToVideo", "UNETLoader", "CLIPLoader", "VAELoader",
    "KSamplerSelect", "BasicScheduler", "SamplerCustomAdvanced",
    "VAEDecode", "VAEDecodeAudio", "CreateVideo", "SaveVideo", "LoadImage",
]
missing = [name for name in required if name not in data]
if missing:
    raise SystemExit("Missing runtime nodes: " + ", ".join(missing))

serialized = json.dumps(data.get("UNETLoader", {}))
if os.environ["MODEL"] not in serialized:
    raise SystemExit("UNETLoader does not list the beta-0.6 model")
print("  required nodes and beta-0.6 model are visible")
PY

running_cmd="$(ps -p "$PID" -o args= 2>/dev/null || true)"
echo "$running_cmd" | grep -q -- "--reserve-vram 4" || die "reserve-vram flag missing"
echo "$running_cmd" | grep -q -- "--cache-none" || die "cache-none flag missing"

trap - EXIT
echo
echo "================================================================="
green " SETUP #5 UPDATE — PINKCHERRY beta-0.6 READY"
echo "================================================================="
echo "ComfyUI  : $COMFY"
echo "Model    : $MODEL"
echo "Workflow : $WORKFLOW_NAME"
echo "Port     : $PORT"
echo "Profile  : Dynamic VRAM ON / reserve 4 GB / cache-none"
echo "Previous : $OLD_MODEL (preserved)"
echo "Turbo    : disabled in the beta-0.6 baseline workflow"
echo "Log      : $LOG"
echo "================================================================="
