#!/usr/bin/env bash
set -Eeuo pipefail

# SCAIL-2 Character Replacement / RunPod RTX 5090 / ComfyUI
# Fresh-Pod, isolated, resumable setup.  Generated 2026-08-22.

ROOT="${ROOT:-/workspace/runpod-slim}"
COMFY_DIR="${COMFY_DIR:-$ROOT/ComfyUI-SCAIL2}"
VENV_DIR="$COMFY_DIR/.venv"
HF_CACHE="$ROOT/hf-cache-scail2"
SETUP_LOG="$ROOT/scail2-replacement-setup.log"
RUN_LOG="$ROOT/comfyui-scail2.log"
PORT="${PORT:-8188}"

COMFY_COMMIT="76135e557da1ec7dcb270160f01e597565e3e003"
MANAGER_COMMIT="f39cbd56fecae0b27a446c0cd450cd591f3a8bea"
WORKFLOW_COMMIT="e95e3b20567bea8df16510c8390b7f897b7e6d4b"
WORKFLOW_SHA256="d85a06af10724e66e5f7857e5f7d9fc10cf28fc528abe19b86514b04ee84ccde"

MODEL_NAME="wan2.1_14B_SCAIL_2_nvfp4_mxpf8_mix.safetensors"

mkdir -p "$ROOT"
touch "$SETUP_LOG"
exec > >(tee -a "$SETUP_LOG") 2>&1

CURRENT_STAGE="startup"
on_error() {
  local exit_code=$?
  local line_no="${1:-unknown}"
  echo
  echo "[FAILED] stage=$CURRENT_STAGE exit=$exit_code line=$line_no"
  echo "Setup log: $SETUP_LOG"
  exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

banner() {
  echo
  echo "================================================================="
  echo " SCAIL-2 REPLACEMENT — RTX 5090 / ComfyUI / SETUP v1"
  echo "================================================================="
}

stage() {
  CURRENT_STAGE="$1"
  echo
  echo "===== $1 ====="
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERROR] Required command not found: $1"
    return 1
  }
}

sha_ok() {
  local file="$1"
  local expected="$2"
  [[ -e "$file" ]] || return 1
  printf '%s  %s\n' "$expected" "$file" | sha256sum -c --status
}

backup_bad_file() {
  local file="$1"
  [[ -e "$file" || -L "$file" ]] || return 0
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  mv "$file" "${file}.invalid-${stamp}"
  echo "[WARN] Invalid existing file preserved as ${file}.invalid-${stamp}"
}

hf_download() {
  local repo="$1"
  local remote_file="$2"
  local destination="$3"
  local expected_sha="$4"
  local attempt downloaded_path force_download=0

  mkdir -p "$(dirname "$destination")" "$HF_CACHE"

  if sha_ok "$destination" "$expected_sha"; then
    echo "[OK] Already verified: $(basename "$destination")"
    return 0
  fi

  backup_bad_file "$destination"
  echo "[DOWNLOAD] $repo :: $remote_file"

  for attempt in 1 2 3 4 5 6; do
    if downloaded_path="$(
      "$VENV_DIR/bin/python" - "$repo" "$remote_file" "$HF_CACHE" "$force_download" <<'PY'
import os
import sys
from huggingface_hub import hf_hub_download

repo_id, filename, cache_dir, force_download = sys.argv[1:]
token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN")
path = hf_hub_download(
    repo_id=repo_id,
    filename=filename,
    cache_dir=cache_dir,
    token=token or None,
    force_download=(force_download == "1"),
)
print(path)
PY
    )"; then
      if printf '%s  %s\n' "$expected_sha" "$downloaded_path" | sha256sum -c --status; then
        ln -s "$downloaded_path" "$destination"
        if sha_ok "$destination" "$expected_sha"; then
          echo "[OK] Verified: $(basename "$destination")"
          return 0
        fi
      else
        echo "[WARN] Checksum mismatch after attempt $attempt"
        force_download=1
      fi
    else
      echo "[WARN] Hugging Face download attempt $attempt failed"
    fi

    if (( attempt < 6 )); then
      local wait_seconds=$((15 * attempt))
      echo "[WAIT] Retrying in ${wait_seconds}s"
      sleep "$wait_seconds"
    fi
  done

  echo "[ERROR] Download failed after six attempts: $repo/$remote_file"
  echo "        If Hugging Face returns 429, export HF_TOKEN and rerun this same script."
  return 1
}

banner

stage "[1/9] GPU and disk preflight"
need_command nvidia-smi
GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1 | tr -d '\r')"
GPU_VRAM="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader | head -1 | tr -d '\r')"
echo "GPU  : $GPU_NAME"
echo "VRAM : $GPU_VRAM"

if [[ "$GPU_NAME" != *"RTX 5090"* && "${SCAIL_ALLOW_OTHER_GPU:-0}" != "1" ]]; then
  echo "[ERROR] This build uses the Blackwell NVFP4/MXFP8 model and is validated for RTX 5090."
  echo "        To deliberately continue on another supported Blackwell GPU, set SCAIL_ALLOW_OTHER_GPU=1."
  exit 1
fi

FREE_GIB="$(df -PB1 "$ROOT" | awk 'NR==2 {printf "%d", $4/1024/1024/1024}')"
echo "Disk : ${FREE_GIB} GiB free at $ROOT"
if (( FREE_GIB < 30 )) && [[ ! -e "$COMFY_DIR/models/diffusion_models/$MODEL_NAME" ]]; then
  echo "[ERROR] At least 30 GiB of free disk is required for the first installation."
  exit 1
fi

stage "[2/9] System tools"
if (( EUID != 0 )); then
  echo "[ERROR] Run this setup as root inside the RunPod container."
  exit 1
fi
export DEBIAN_FRONTEND=noninteractive
apt-get -o Acquire::Retries=5 update -y
apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
  ca-certificates curl ffmpeg git jq lsof python3 python3-pip python3-venv ripgrep

stage "[3/9] Isolated ComfyUI core"
if [[ ! -d "$COMFY_DIR/.git" ]]; then
  if [[ -e "$COMFY_DIR" ]]; then
    echo "[ERROR] $COMFY_DIR exists but is not a Git checkout. It was not modified."
    exit 1
  fi
  git clone --filter=blob:none https://github.com/Comfy-Org/ComfyUI.git "$COMFY_DIR"
fi

EXPECTED_ORIGIN="https://github.com/Comfy-Org/ComfyUI.git"
ACTUAL_ORIGIN="$(git -C "$COMFY_DIR" remote get-url origin)"
if [[ "$ACTUAL_ORIGIN" != "$EXPECTED_ORIGIN" && "$ACTUAL_ORIGIN" != "https://github.com/comfyanonymous/ComfyUI.git" ]]; then
  echo "[ERROR] Unexpected ComfyUI origin: $ACTUAL_ORIGIN"
  echo "        Existing environment was not modified."
  exit 1
fi

if [[ -n "$(git -C "$COMFY_DIR" status --porcelain --untracked-files=no)" ]]; then
  echo "[ERROR] Tracked files in $COMFY_DIR contain local changes."
  echo "        Existing work was not overwritten. Back it up or choose another COMFY_DIR."
  exit 1
fi

git -C "$COMFY_DIR" fetch --depth=1 origin "$COMFY_COMMIT"
git -C "$COMFY_DIR" checkout -B scail2-rtx5090-v1 "$COMFY_COMMIT"
echo "[OK] ComfyUI pinned at $(git -C "$COMFY_DIR" rev-parse --short=12 HEAD)"

stage "[4/9] Python environment"
if [[ -d "$VENV_DIR" ]] && ! "$VENV_DIR/bin/python" -c 'import sys' >/dev/null 2>&1; then
  VENV_BACKUP="${VENV_DIR}.invalid-$(date +%Y%m%d-%H%M%S)"
  mv "$VENV_DIR" "$VENV_BACKUP"
  echo "[WARN] Invalid venv preserved as $VENV_BACKUP"
fi

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  python3 -m venv --system-site-packages "$VENV_DIR"
fi

PY="$VENV_DIR/bin/python"
"$PY" -m pip install --upgrade pip wheel 'setuptools<82'
"$PY" -m pip install --upgrade-strategy only-if-needed -r "$COMFY_DIR/requirements.txt"
"$PY" -m pip install --upgrade 'huggingface_hub[hf_xet]>=0.34'

"$PY" - <<'PY'
import torch
print(f"Python : {__import__('sys').version.split()[0]}")
print(f"Torch  : {torch.__version__}")
print(f"CUDA   : {torch.version.cuda}")
if not torch.cuda.is_available():
    raise SystemExit("[ERROR] PyTorch cannot access CUDA")
name = torch.cuda.get_device_name(0)
major, minor = torch.cuda.get_device_capability(0)
print(f"Device : {name} (compute capability {major}.{minor})")
if major < 12:
    raise SystemExit("[ERROR] The selected NVFP4/MXFP8 model requires a Blackwell-class GPU")
PY

stage "[5/9] ComfyUI Manager"
MANAGER_DIR="$COMFY_DIR/custom_nodes/ComfyUI-Manager"
if [[ ! -d "$MANAGER_DIR/.git" ]]; then
  if [[ -e "$MANAGER_DIR" ]]; then
    echo "[ERROR] $MANAGER_DIR exists but is not a Git checkout. It was not modified."
    exit 1
  fi
  git clone --filter=blob:none https://github.com/Comfy-Org/ComfyUI-Manager.git "$MANAGER_DIR"
fi
if [[ -n "$(git -C "$MANAGER_DIR" status --porcelain --untracked-files=no)" ]]; then
  echo "[ERROR] ComfyUI-Manager has tracked local changes; refusing to overwrite them."
  exit 1
fi
git -C "$MANAGER_DIR" fetch --depth=1 origin "$MANAGER_COMMIT"
git -C "$MANAGER_DIR" checkout -B scail2-rtx5090-v1 "$MANAGER_COMMIT"
if [[ -f "$MANAGER_DIR/requirements.txt" ]]; then
  "$PY" -m pip install --upgrade-strategy only-if-needed -r "$MANAGER_DIR/requirements.txt"
fi

stage "[6/9] SCAIL-2 model files"
export HF_HOME="$HF_CACHE"
export HF_HUB_CACHE="$HF_CACHE/hub"
export HF_HUB_DISABLE_TELEMETRY=1
export HF_HUB_ETAG_TIMEOUT=30
export HF_HUB_DOWNLOAD_TIMEOUT=180
export HF_XET_HIGH_PERFORMANCE=1
export TOKENIZERS_PARALLELISM=false

mkdir -p \
  "$COMFY_DIR/models/diffusion_models" \
  "$COMFY_DIR/models/text_encoders" \
  "$COMFY_DIR/models/clip_vision" \
  "$COMFY_DIR/models/vae" \
  "$COMFY_DIR/models/loras" \
  "$COMFY_DIR/models/checkpoints"

hf_download \
  "Comfy-Org/SCAIL-2" \
  "diffusion_models/$MODEL_NAME" \
  "$COMFY_DIR/models/diffusion_models/$MODEL_NAME" \
  "5053562142b46a12ef368360373304609ce6e6e010b3fddd35ef1cd27e180e7d"

hf_download \
  "Comfy-Org/Wan_2.1_ComfyUI_repackaged" \
  "split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" \
  "$COMFY_DIR/models/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" \
  "c3355d30191f1f066b26d93fba017ae9809dce6c627dda5f6a66eaa651204f68"

hf_download \
  "Comfy-Org/Wan_2.1_ComfyUI_repackaged" \
  "split_files/clip_vision/clip_vision_h.safetensors" \
  "$COMFY_DIR/models/clip_vision/clip_vision_h.safetensors" \
  "64a7ef761bfccbadbaa3da77366aac4185a6c58fa5de5f589b42a65bcc21f161"

hf_download \
  "Kijai/WanVideo_comfy" \
  "Wan2_1_VAE_bf16.safetensors" \
  "$COMFY_DIR/models/vae/Wan2_1_VAE_bf16.safetensors" \
  "1ab9a32cc2c740f6e39d80d367ce5dcc28db8c71b79b28670546b8973e9d75f9"

hf_download \
  "Kijai/WanVideo_comfy" \
  "Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors" \
  "$COMFY_DIR/models/loras/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors" \
  "85c4a61c30e0497aa44b91d93a893b624708461a56fe5485183b28fa07e2dfb3"

hf_download \
  "Comfy-Org/SCAIL-2" \
  "loras/wan2.1_SCAIL_2_DPO_lora_bf16.safetensors" \
  "$COMFY_DIR/models/loras/wan2.1_SCAIL_2_DPO_lora_bf16.safetensors" \
  "b106522036f64e50f5f8ae3b808973515ff442cc2fac27b65d875eafb95b89e2"

hf_download \
  "Comfy-Org/sam3.1" \
  "checkpoints/sam3.1_multiplex_fp16.safetensors" \
  "$COMFY_DIR/models/checkpoints/sam3.1_multiplex_fp16.safetensors" \
  "9ba99c92703c2e8b4f47de2d34a539bb8e18923049e238b780d70dbe6368eb03"

stage "[7/9] Official Replacement workflows"
WORKFLOW_URL="https://raw.githubusercontent.com/Comfy-Org/workflow_templates/$WORKFLOW_COMMIT/templates/video_wan21_scail2_character_replacement.json"
TMP_WORKFLOW="$(mktemp /tmp/scail2-workflow.XXXXXX.json)"
curl -fL --retry 5 --retry-all-errors --connect-timeout 20 "$WORKFLOW_URL" -o "$TMP_WORKFLOW"
printf '%s  %s\n' "$WORKFLOW_SHA256" "$TMP_WORKFLOW" | sha256sum -c --status || {
  echo "[ERROR] Official workflow checksum did not match the pinned release."
  exit 1
}

WORKFLOW_DIR="$COMFY_DIR/user/default/workflows/SCAIL2_Replacement"
mkdir -p "$WORKFLOW_DIR"

"$PY" - "$TMP_WORKFLOW" "$WORKFLOW_DIR" "$MODEL_NAME" <<'PY'
import copy
import json
import pathlib
import sys
import uuid

source_path = pathlib.Path(sys.argv[1])
output_dir = pathlib.Path(sys.argv[2])
model_name = sys.argv[3]

with source_path.open("r", encoding="utf-8") as f:
    source = json.load(f)

old_model = "wan2.1_14B_SCAIL_2_fp16.safetensors"
old_url = "https://huggingface.co/Comfy-Org/SCAIL-2/resolve/main/diffusion_models/" + old_model
new_url = "https://huggingface.co/Comfy-Org/SCAIL-2/resolve/main/diffusion_models/" + model_name

generic_prompt = (
    "One fictional adult character with natural anatomy, consistent identity, stable face, hair, "
    "body proportions and clothing across every frame, accurately following the original motion "
    "and expression, seamlessly integrated into the original scene, matching the original lighting, "
    "shadows, color, camera perspective and depth of field. Clean temporal consistency, realistic "
    "skin texture, no identity drift, no extra limbs, no duplicated body parts."
)

def replace_strings(obj):
    if isinstance(obj, str):
        return obj.replace(old_url, new_url).replace(old_model, model_name)
    if isinstance(obj, list):
        return [replace_strings(v) for v in obj]
    if isinstance(obj, dict):
        return {k: replace_strings(v) for k, v in obj.items()}
    return obj

def tune_graph(data, width, height, frames, test_mode):
    data = replace_strings(data)
    data["id"] = str(uuid.uuid5(uuid.NAMESPACE_URL, f"scail2-rtx5090-{width}x{height}-{frames}-{test_mode}"))

    for graph in data.get("definitions", {}).get("subgraphs", []):
        for node in graph.get("nodes", []):
            node_id = node.get("id")
            node_type = node.get("type")
            widgets = node.get("widgets_values", [])

            if node_type == "UNETLoader" and widgets:
                widgets[0] = model_name
            elif node_type == "CLIPTextEncode" and node_id in {3, 258} and widgets:
                widgets[0] = generic_prompt
            elif node_type == "PrimitiveInt" and node_id in {178, 236} and widgets:
                widgets[0] = width
            elif node_type == "PrimitiveInt" and node_id in {179, 237} and widgets:
                widgets[0] = height
            elif node_type == "ImageFromBatch" and node_id in {177, 235} and len(widgets) >= 2:
                widgets[0] = 0
                widgets[1] = frames
            elif node_type == "WanSCAILToVideo" and len(widgets) >= 3:
                widgets[0] = height
                widgets[1] = width
                widgets[2] = frames

    for node in data.get("nodes", []):
        node_id = node.get("id")
        if node_id == 264:
            node["widgets_values"] = [f"ceil(a / ({frames} - 5))"]
        elif node_id == 202:
            node["title"] = "Save Video — TEST output" if test_mode else "Save Video — First segment"
            node["widgets_values"][0] = "video/SCAIL2_TEST" if test_mode else "video/SCAIL2_FIRST"
        elif node_id == 271:
            node["widgets_values"][0] = "video/SCAIL2_QUALITY"
            if test_mode:
                node["mode"] = 2  # NEVER: first-segment smoke test only
        elif node_id == 274 and node.get("widgets_values"):
            mode_note = (
                "\n\n## RTX 5090 TEST preset\nThis copy runs only the Base/first segment. "
                "Use it first to validate your inputs and masks."
                if test_mode else
                "\n\n## RTX 5090 QUALITY preset\nThis copy keeps Base + Extend enabled for two-segment output."
            )
            node["widgets_values"][0] += mode_note

    for group in data.get("groups", []):
        title = group.get("title", "")
        if title.startswith("Estimate Segment Count"):
            group["title"] = f"Estimate Segment Count (frame count: {frames}, previous frame count: 5)"
    return data

presets = [
    ("SCAIL2_Replacement_RTX5090_TEST_768x512_49F.json", 768, 512, 49, True),
    ("SCAIL2_Replacement_RTX5090_QUALITY_896x512_81F.json", 896, 512, 81, False),
]

for filename, width, height, frames, test_mode in presets:
    result = tune_graph(copy.deepcopy(source), width, height, frames, test_mode)
    destination = output_dir / filename
    with destination.open("w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"[OK] Workflow: {destination.name}")
PY

rm -f "$TMP_WORKFLOW"

if rg -q "wan2.1_14B_SCAIL_2_fp16.safetensors" "$WORKFLOW_DIR"; then
  echo "[ERROR] Workflow patch left an FP16 model reference behind."
  exit 1
fi
jq -e . "$WORKFLOW_DIR/SCAIL2_Replacement_RTX5090_TEST_768x512_49F.json" >/dev/null
jq -e . "$WORKFLOW_DIR/SCAIL2_Replacement_RTX5090_QUALITY_896x512_81F.json" >/dev/null

stage "[8/9] Safe launcher"
LAUNCHER="$ROOT/start_scail2_replacement.sh"
cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
COMFY_DIR="$COMFY_DIR"
PORT="\${PORT:-$PORT}"
RUN_LOG="$RUN_LOG"

if command -v lsof >/dev/null 2>&1; then
  mapfile -t port_pids < <(lsof -tiTCP:"\$PORT" -sTCP:LISTEN 2>/dev/null || true)
  if (( \${#port_pids[@]} > 0 )); then
    echo "Stopping existing service on port \$PORT: \${port_pids[*]}"
    kill "\${port_pids[@]}" 2>/dev/null || true
    for _ in {1..20}; do
      lsof -tiTCP:"\$PORT" -sTCP:LISTEN >/dev/null 2>&1 || break
      sleep 0.5
    done
  fi
fi

cd "\$COMFY_DIR"
export HF_HOME="$HF_CACHE"
export HF_HUB_CACHE="$HF_CACHE/hub"
export TOKENIZERS_PARALLELISM=false
export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"

nohup "\$COMFY_DIR/.venv/bin/python" main.py \\
  --listen 0.0.0.0 \\
  --port "\$PORT" \\
  --preview-method auto \\
  --enable-cors-header \\
  --lowvram \\
  --reserve-vram 4 \\
  --cache-none \\
  > "\$RUN_LOG" 2>&1 &

echo \$! > "$ROOT/comfyui-scail2.pid"
echo "ComfyUI-SCAIL2 starting on port \$PORT (PID \$!)"
echo "Log: \$RUN_LOG"
EOF
chmod +x "$LAUNCHER"

"$LAUNCHER"

stage "[9/9] Runtime validation"
READY=0
for _ in {1..120}; do
  if curl -fsS "http://127.0.0.1:$PORT/system_stats" >/dev/null 2>&1; then
    READY=1
    break
  fi
  if [[ -f "$ROOT/comfyui-scail2.pid" ]]; then
    SERVER_PID="$(cat "$ROOT/comfyui-scail2.pid")"
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "[ERROR] ComfyUI exited before becoming ready."
      tail -120 "$RUN_LOG" || true
      exit 1
    fi
  fi
  sleep 1
done

if (( READY == 0 )); then
  echo "[ERROR] ComfyUI did not become ready within 120 seconds."
  tail -120 "$RUN_LOG" || true
  exit 1
fi

OBJECT_INFO="$(mktemp /tmp/scail2-object-info.XXXXXX.json)"
curl -fsS "http://127.0.0.1:$PORT/object_info" -o "$OBJECT_INFO"
"$PY" - "$OBJECT_INFO" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    info = json.load(f)

required = {"WanSCAILToVideo", "SCAIL2ColoredMask", "SAM3_VideoTrack"}
missing = sorted(required.difference(info))
if missing:
    raise SystemExit("[ERROR] Missing required ComfyUI core nodes: " + ", ".join(missing))
print("[OK] Required SCAIL-2 and SAM3 nodes are available")
PY
rm -f "$OBJECT_INFO"

echo
echo "================================================================="
echo " SCAIL-2 REPLACEMENT READY"
echo "================================================================="
echo "ComfyUI : $COMFY_DIR"
echo "Model   : $MODEL_NAME"
echo "Port    : $PORT"
echo "Log     : $RUN_LOG"
echo "Launcher: $LAUNCHER"
echo
echo "First test workflow:"
echo "  SCAIL2_Replacement/SCAIL2_Replacement_RTX5090_TEST_768x512_49F.json"
echo "Then quality workflow:"
echo "  SCAIL2_Replacement/SCAIL2_Replacement_RTX5090_QUALITY_896x512_81F.json"
echo
echo "Use one short driving video with one clearly visible fictional adult,"
echo "plus one clean full-body reference image. Leave replace_mode=true."
echo "================================================================="
