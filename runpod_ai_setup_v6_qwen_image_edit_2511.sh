#!/usr/bin/env bash
set -Eeuo pipefail

# RunPod one-shot installer: Qwen-Image-Edit-2511 for ComfyUI
# Official quality workflow + official LightX2V Lightning 4-step workflow.

ROOT="/workspace/runpod-slim"
COMFY="$ROOT/ComfyUI"
HF_HOME_V6="$ROOT/.cache/huggingface"
LOG="$ROOT/qwen_image_edit_2511_setup.log"
PORT="8188"
COMFY_REPO="https://github.com/Comfy-Org/ComfyUI.git"
WORKFLOW_URL="https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/image_qwen_image_edit_2511.json"

QUALITY_WF="Qwen_Image_Edit_2511_QUALITY_40STEP.json"
FAST_WF="Qwen_Image_Edit_2511_LIGHTNING_4STEP.json"
A2R_WF="Qwen_Image_Edit_2511_ANYTHING2REAL_2601A.json"
ANYPOSE_WF="Qwen_Image_Edit_2511_ANYPOSE_4STEP.json"

MODEL_FILE="qwen_image_edit_2511_fp8mixed.safetensors"
CLIP_FILE="qwen_2.5_vl_7b_fp8_scaled.safetensors"
VAE_FILE="qwen_image_vae.safetensors"
LORA_FILE="Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"
A2R_FILE="anything2real_2601_A_final_patched.safetensors"
ANYPOSE_BASE_FILE="2511-AnyPose-base-000006250.safetensors"
ANYPOSE_HELPER_FILE="2511-AnyPose-helper-00006000.safetensors"

export HF_HOME="$HF_HOME_V6"
export HF_HUB_ENABLE_HF_TRANSFER=0
export PYTHONUNBUFFERED=1

mkdir -p "$ROOT"
exec > >(tee -a "$LOG") 2>&1

die() { echo "[FATAL] $*" >&2; exit 1; }
step() { echo; echo "===== $* ====="; }

on_error() {
  local code=$?
  echo
  echo "SETUP #6 FAILED (exit=$code, line=${BASH_LINENO[0]})"
  echo "Log: $LOG"
  exit "$code"
}
trap on_error ERR

step "SETUP #6 — QWEN IMAGE EDIT 2511"
command -v nvidia-smi >/dev/null || die "NVIDIA driver/GPU not found"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader

step "[1/10] System tools"
if ! command -v git >/dev/null || ! command -v curl >/dev/null; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y git curl ca-certificates
fi

step "[2/10] ComfyUI core"
if [[ ! -d "$COMFY/.git" ]]; then
  [[ ! -e "$COMFY" ]] || die "$COMFY exists but is not a git checkout; move it aside and rerun"
  git clone --filter=blob:none "$COMFY_REPO" "$COMFY"
else
  git -C "$COMFY" fetch --prune origin
  branch="$(git -C "$COMFY" symbolic-ref --short HEAD 2>/dev/null || true)"
  [[ -n "$branch" ]] || die "ComfyUI is on a detached commit; cannot safely update"
  git -C "$COMFY" pull --ff-only origin "$branch" || die "ComfyUI has local/diverged core changes; refusing to overwrite them"
fi

step "[3/10] Python environment"
PYTHON_BIN=""
for candidate in "$COMFY/.venv/bin/python" "$ROOT/.venv/bin/python"; do
  if [[ -x "$candidate" ]]; then PYTHON_BIN="$candidate"; break; fi
done
if [[ -z "$PYTHON_BIN" ]]; then
  command -v python3 >/dev/null || die "python3 not found"
  python3 -m venv --system-site-packages "$COMFY/.venv"
  PYTHON_BIN="$COMFY/.venv/bin/python"
fi
"$PYTHON_BIN" -m pip install -U pip setuptools wheel
"$PYTHON_BIN" -m pip install -r "$COMFY/requirements.txt"
"$PYTHON_BIN" -m pip install -U "huggingface_hub[hf_xet]"

step "[4/10] Model directories"
mkdir -p \
  "$COMFY/models/diffusion_models" \
  "$COMFY/models/text_encoders" \
  "$COMFY/models/vae" \
  "$COMFY/models/loras" \
  "$COMFY/input" \
  "$COMFY/user/default/workflows"

download_hf() {
  local repo="$1" remote="$2" dest="$3" min_bytes="$4"
  if [[ -f "$dest" ]] && (( $(stat -c '%s' "$dest") >= min_bytes )); then
    echo "[SKIP] $(basename "$dest") already complete"
    return 0
  fi
  rm -f "${dest}.part"
  echo "[DOWNLOAD] $repo :: $remote"
  REPO="$repo" REMOTE="$remote" DEST="$dest" MIN_BYTES="$min_bytes" "$PYTHON_BIN" - <<'PY'
import os, shutil
from huggingface_hub import hf_hub_download
repo, remote, dest = os.environ["REPO"], os.environ["REMOTE"], os.environ["DEST"]
minimum = int(os.environ["MIN_BYTES"])
src = hf_hub_download(repo_id=repo, filename=remote, resume_download=True)
real = os.path.realpath(src)
if os.path.getsize(real) < minimum:
    raise RuntimeError(f"download too small: {os.path.getsize(real)} bytes")
part = dest + ".part"
os.makedirs(os.path.dirname(dest), exist_ok=True)
try:
    os.link(real, part)
except OSError:
    shutil.copy2(real, part)
os.replace(part, dest)
print(f"[OK] {os.path.basename(dest)} ({os.path.getsize(dest):,} bytes)")
PY
}

step "[5/10] Qwen-Image-Edit-2511 models"
download_hf "Comfy-Org/Qwen-Image-Edit_ComfyUI" \
  "split_files/diffusion_models/$MODEL_FILE" \
  "$COMFY/models/diffusion_models/$MODEL_FILE" 19000000000
download_hf "Comfy-Org/HunyuanVideo_1.5_repackaged" \
  "split_files/text_encoders/$CLIP_FILE" \
  "$COMFY/models/text_encoders/$CLIP_FILE" 8000000000
download_hf "Comfy-Org/Qwen-Image_ComfyUI" \
  "split_files/vae/$VAE_FILE" \
  "$COMFY/models/vae/$VAE_FILE" 200000000
download_hf "lightx2v/Qwen-Image-Edit-2511-Lightning" \
  "$LORA_FILE" \
  "$COMFY/models/loras/$LORA_FILE" 100000000
download_hf "lrzjason/Anything2Real" \
  "$A2R_FILE" \
  "$COMFY/models/loras/$A2R_FILE" 500000000
download_hf "lilylilith/AnyPose" \
  "$ANYPOSE_BASE_FILE" \
  "$COMFY/models/loras/$ANYPOSE_BASE_FILE" 200000000
download_hf "lilylilith/AnyPose" \
  "$ANYPOSE_HELPER_FILE" \
  "$COMFY/models/loras/$ANYPOSE_HELPER_FILE" 200000000

step "[6/10] Official workflow and sample inputs"
TMP_WF="$(mktemp)"
curl -fL --retry 8 --retry-all-errors --connect-timeout 20 \
  "$WORKFLOW_URL" -o "$TMP_WF"
"$PYTHON_BIN" -m json.tool "$TMP_WF" >/dev/null

curl -fL --retry 8 --retry-all-errors \
  "https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/input/leather_sofa.png" \
  -o "$COMFY/input/leather_sofa.png"
curl -fL --retry 8 --retry-all-errors \
  "https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/input/texture_fur.png" \
  -o "$COMFY/input/texture_fur.png"

TEMPLATE="$TMP_WF" OUT_QUALITY="$COMFY/user/default/workflows/$QUALITY_WF" \
OUT_FAST="$COMFY/user/default/workflows/$FAST_WF" \
OUT_A2R="$COMFY/user/default/workflows/$A2R_WF" \
OUT_ANYPOSE="$COMFY/user/default/workflows/$ANYPOSE_WF" "$PYTHON_BIN" - <<'PY'
import copy, json, os

with open(os.environ["TEMPLATE"], encoding="utf-8") as f:
    base = json.load(f)

LIGHTNING = "Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"
A2R = "anything2real_2601_A_final_patched.safetensors"
POSE_BASE = "2511-AnyPose-base-000006250.safetensors"
POSE_HELPER = "2511-AnyPose-helper-00006000.safetensors"

def find_node(sg, node_id):
    return next(n for n in sg["nodes"] if n.get("id") == node_id)

def add_anypose_chain(sg):
    lightning = find_node(sg, 153)
    switch = find_node(sg, 163)
    link332 = next(x for x in sg["links"] if x["id"] == 332)
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
        {"id": 388, "origin_id": 195, "origin_slot": 0,
         "target_id": 196, "target_slot": 0, "type": "MODEL"},
        {"id": 389, "origin_id": 196, "origin_slot": 0,
         "target_id": 163, "target_slot": 1, "type": "MODEL"},
    ])
    switch["inputs"][1]["link"] = 389
    sg["state"]["lastNodeId"] = max(int(sg["state"].get("lastNodeId", 0)), 196)
    sg["state"]["lastLinkId"] = max(int(sg["state"].get("lastLinkId", 0)), 389)

def configure(data, variant):
    data = copy.deepcopy(data)
    found = {"bool": False, "unet": False, "clip": False, "vae": False, "lora": False}
    for sg in data.get("definitions", {}).get("subgraphs", []):
        for node in sg.get("nodes", []):
            t = node.get("type")
            if t == "PrimitiveBoolean" and node.get("id") == 168:
                node["widgets_values"] = [variant in ("fast", "anypose")]; found["bool"] = True
            elif t == "UNETLoader":
                node["widgets_values"][0] = "qwen_image_edit_2511_fp8mixed.safetensors"; found["unet"] = True
            elif t == "CLIPLoader":
                node["widgets_values"][0] = "qwen_2.5_vl_7b_fp8_scaled.safetensors"; found["clip"] = True
            elif t == "VAELoader":
                node["widgets_values"][0] = "qwen_image_vae.safetensors"; found["vae"] = True
            elif t == "LoraLoaderModelOnly":
                node["widgets_values"][0] = A2R if variant == "a2r" else LIGHTNING
                node["widgets_values"][1] = 0.85 if variant == "a2r" else 1.0
                found["lora"] = True
            if node.get("id") == 151 and t == "TextEncodeQwenImageEditPlus":
                if variant == "a2r":
                    node["widgets_values"] = [
                        "Change image 1 into a realistic photograph while preserving the original composition, pose, identity, clothing, objects and camera angle. Natural light, realistic skin and materials, photographic detail."
                    ]
                elif variant == "anypose":
                    node["widgets_values"] = [
                        "Make the person in image 1 do the exact same pose as the person in image 2. Preserve the identity, clothing, style and background of image 1. Match the arms, hands, head, legs, camera angle, head tilt and eye gaze of image 2. Remove the background of image 2 and keep the background of image 1."
                    ]
        if variant == "a2r":
            # Apply A2R on the non-turbo branch while retaining official 40-step settings.
            lora = find_node(sg, 153)
            source = find_node(sg, 152)
            link331 = next(x for x in sg["links"] if x["id"] == 331)
            link331["origin_id"], link331["origin_slot"] = 153, 0
            lora["outputs"][0]["links"] = sorted(set(lora["outputs"][0].get("links", []) + [331]))
            source["outputs"][0]["links"] = [x for x in source["outputs"][0].get("links", []) if x != 331]
        elif variant == "anypose":
            add_anypose_chain(sg)
    missing = [k for k, v in found.items() if not v]
    if missing:
        raise RuntimeError("Official workflow structure changed; missing: " + ", ".join(missing))
    if variant == "a2r":
        # A2R uses only image 1; disconnect the material-reference sample image.
        data["links"] = [x for x in data.get("links", []) if x[0] != 377]
        for node in data.get("nodes", []):
            if node.get("id") == 170:
                node["inputs"][1]["link"] = None
            elif node.get("id") == 9:
                node["widgets_values"] = ["Qwen_Edit_2511_Anything2Real"]
    elif variant == "anypose":
        for node in data.get("nodes", []):
            if node.get("id") == 9:
                node["widgets_values"] = ["Qwen_Edit_2511_AnyPose"]
    data["id"] = "qwen-image-edit-2511-" + variant
    return data

outputs = (
    (os.environ["OUT_QUALITY"], "quality"),
    (os.environ["OUT_FAST"], "fast"),
    (os.environ["OUT_A2R"], "a2r"),
    (os.environ["OUT_ANYPOSE"], "anypose"),
)
for path, variant in outputs:
    with open(path + ".part", "w", encoding="utf-8") as f:
        json.dump(configure(base, variant), f, ensure_ascii=False, indent=2)
    os.replace(path + ".part", path)
    print("[OK]", os.path.basename(path))
PY
rm -f "$TMP_WF"

step "[7/10] Static validation"
for f in \
  "$COMFY/models/diffusion_models/$MODEL_FILE" \
  "$COMFY/models/text_encoders/$CLIP_FILE" \
  "$COMFY/models/vae/$VAE_FILE" \
  "$COMFY/models/loras/$LORA_FILE" \
  "$COMFY/models/loras/$A2R_FILE" \
  "$COMFY/models/loras/$ANYPOSE_BASE_FILE" \
  "$COMFY/models/loras/$ANYPOSE_HELPER_FILE" \
  "$COMFY/user/default/workflows/$QUALITY_WF" \
  "$COMFY/user/default/workflows/$FAST_WF" \
  "$COMFY/user/default/workflows/$A2R_WF" \
  "$COMFY/user/default/workflows/$ANYPOSE_WF"; do
  [[ -s "$f" ]] || die "Missing or empty: $f"
done

step "[8/10] Stop previous ComfyUI on port $PORT"
if command -v fuser >/dev/null 2>&1; then
  fuser -k "${PORT}/tcp" 2>/dev/null || true
else
  pkill -f "[p]ython.*main.py.*--port[ =]$PORT" 2>/dev/null || true
fi
sleep 2

step "[9/10] Start ComfyUI"
cd "$COMFY"
nohup "$PYTHON_BIN" main.py \
  --listen 0.0.0.0 \
  --port "$PORT" \
  --preview-method auto \
  --reserve-vram 4 \
  --cache-none \
  > "$ROOT/comfyui_qwen2511.log" 2>&1 &
echo $! > "$ROOT/comfyui_qwen2511.pid"

OBJECT_INFO="$(mktemp)"
ready=0
for _ in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:$PORT/object_info" -o "$OBJECT_INFO" 2>/dev/null; then
    ready=1; break
  fi
  if ! kill -0 "$(cat "$ROOT/comfyui_qwen2511.pid")" 2>/dev/null; then
    tail -120 "$ROOT/comfyui_qwen2511.log" || true
    die "ComfyUI exited during startup"
  fi
  sleep 2
done
[[ "$ready" == 1 ]] || { tail -120 "$ROOT/comfyui_qwen2511.log" || true; die "ComfyUI did not become ready"; }

step "[10/10] Runtime node validation"
OBJECT_INFO="$OBJECT_INFO" "$PYTHON_BIN" - <<'PY'
import json, os
with open(os.environ["OBJECT_INFO"], encoding="utf-8") as f:
    nodes = json.load(f)
required = [
    "TextEncodeQwenImageEditPlus", "FluxKontextMultiReferenceLatentMethod",
    "FluxKontextImageScale", "ModelSamplingAuraFlow", "UNETLoader",
    "CLIPLoader", "VAELoader", "LoraLoaderModelOnly", "KSampler",
    "VAEDecode", "VAEEncode", "SaveImage"
]
missing = [x for x in required if x not in nodes]
if missing:
    raise SystemExit("Missing required runtime nodes: " + ", ".join(missing))
print("[OK] All required Qwen-Image-Edit-2511 nodes are loaded")
PY
rm -f "$OBJECT_INFO"

echo
echo "============================================================"
echo "SETUP #6 COMPLETE — GENERATION READY"
echo "ComfyUI: http://127.0.0.1:$PORT"
echo "QUALITY : $QUALITY_WF"
echo "FAST    : $FAST_WF"
echo "A2R     : $A2R_WF"
echo "ANYPOSE : $ANYPOSE_WF"
echo "Replace the sample image(s), enter your edit prompt, and run."
echo "============================================================"
