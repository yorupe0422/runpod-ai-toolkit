#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# SETUP #14 — MiniMax H3 Singularity Ref2VA v1
#
# Goal:
#   Independent RTX 5090 / RunPod environment for:
#     - WarmBloodAban Minimax-h3_Singularity Ref2VA Pruned v1.3 INT8
#     - Qwen3VL MiniMax-H3 NVFP4-AWQ text encoder
#     - Official MiniMax-H3 video/audio VAE
#     - LightX2V Ref2V Turbo 4-step LoRA
#     - 3-reference-image ready workflows
#
# Important:
#   - Installs independently from #2.
#   - Uses port 8188.
#   - Does NOT run video generation during setup.
#   - Downloads are checksum-verified.
#   - ComfyUI is pinned to v0.31.1 deliberately. H3 full-resolution
#     regressions were reported in later 0.32/0.33-era builds.
# =============================================================================

ROOT="${ROOT:-/workspace/runpod-slim}"
COMFY="${COMFY:-$ROOT/ComfyUI-H3-Singularity}"
PORT="${PORT:-8188}"
COMFY_TAG="${COMFY_TAG:-v0.31.1}"
PYTHON_BIN="${PYTHON_BIN:-python3.12}"

LOG_DIR="$COMFY/setup_logs"
RUNTIME_DIR="$COMFY/runtime_logs"
WF_DIR="$COMFY/user/default/workflows"
STATE_DIR="$ROOT/.h3_singularity_setup_v1"

MODEL="Minimax-h3_Singularity_ref2va_Pruned_v1.3_int8.safetensors"
TEXT="qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"
VIDEO_VAE="minimax_h3_video_vae_fp16.safetensors"
AUDIO_VAE="minimax_h3_audio_vae_fp32.safetensors"
TURBO="minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors"

MODEL_URL="https://huggingface.co/WarmBloodAban/Minimax-h3_Singularity/resolve/main/$MODEL?download=true"
TEXT_URL="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/text_encoders/$TEXT?download=true"
VIDEO_VAE_URL="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/$VIDEO_VAE?download=true"
AUDIO_VAE_URL="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/$AUDIO_VAE?download=true"
TURBO_URL="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/loras/$TURBO?download=true"

# SHA256 values published by the corresponding Hugging Face file pages.
MODEL_SHA="412a7b126595a958964193f3b42513d7cf2df4196ef04223a0f05e3622949cce"
TEXT_SHA="35a88d51044231fe332301d7a62aa81e3f2cba62febeb446e2c1e3e0ef76f2c6"
VIDEO_VAE_SHA="7c1f131492e7eddacaac9069a61b81bdd39de5cc96561e677c5eab1cdce5e522"
AUDIO_VAE_SHA="8e505d95dd1561d47abd43d4238fd40d9bb1ae9e147ed0a4cba778d76ae4db48"
TURBO_SHA="5b9ab5ade15d0775676d01a907268a69a1468dc6033b3b0d3ded5502f3ebb84c"

WF_BASE="14A_H3_Singularity_Ref2VA_3REF_20STEP.json"
WF_TURBO="14B_H3_Singularity_Ref2VA_3REF_TURBO4.json"
WF_SOURCE_URL="https://raw.githubusercontent.com/Hearmeman24/comfyui-minimax/master/workflows/MiniMax%20H3/video_minimax_h3_r2v.json"

green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[0;33m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
die(){ red "[FAILED] $*"; exit 1; }

mkdir -p "$ROOT" "$STATE_DIR"

on_error(){
  rc=$?
  line="${BASH_LINENO[0]:-unknown}"
  red ""
  red "SETUP #14 SINGULARITY FAILED rc=$rc line=$line"
  if [[ -d "${RUNTIME_DIR:-}" ]]; then
    latest="$(ls -t "$RUNTIME_DIR"/comfy_*.log 2>/dev/null | head -1 || true)"
    [[ -n "${latest:-}" ]] && {
      echo "Latest runtime log: $latest"
      tail -160 "$latest" || true
    }
  fi
  exit "$rc"
}
trap on_error ERR

echo "================================================================="
echo " SETUP #14 — MINIMAX H3 SINGULARITY REF2VA v1"
echo "================================================================="
echo "Install dir : $COMFY"
echo "Port        : $PORT"
echo "ComfyUI tag : $COMFY_TAG"
echo

# -----------------------------------------------------------------------------
# 1. Preflight
# -----------------------------------------------------------------------------
echo "[1/12] Preflight"

command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi not found"

GPU="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
DRIVER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | tr -d ' ')"
VRAM_MIB="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -d ' ')"

echo "GPU    : $GPU"
echo "VRAM   : ${VRAM_MIB} MiB"
echo "Driver : $DRIVER"

DRIVER_MAJOR="${DRIVER%%.*}"
if [[ "$DRIVER_MAJOR" =~ ^[0-9]+$ ]] && (( DRIVER_MAJOR < 580 )); then
  die "Driver $DRIVER is below the saved RTX 5090/CUDA 13 path. Select Driver 580+."
fi

if [[ "$GPU" != *"5090"* ]]; then
  yellow "  [WARN] Saved path is validated conceptually for RTX 5090; detected: $GPU"
fi

FREE_KB="$(df -Pk "$ROOT" | awk 'NR==2{print $4}')"
NEEDED_KB=$((65 * 1024 * 1024))
if (( FREE_KB < NEEDED_KB )); then
  die "Need at least ~65 GiB free under $ROOT. Free: $((FREE_KB/1024/1024)) GiB"
fi
echo "Disk free: $((FREE_KB/1024/1024)) GiB"

for tool in git curl aria2c lsof ffmpeg sha256sum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      git curl aria2 lsof ffmpeg ca-certificates coreutils
    break
  fi
done

command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "$PYTHON_BIN not found"
green "  ✓ host preflight"

# -----------------------------------------------------------------------------
# 2. Independent ComfyUI checkout
# -----------------------------------------------------------------------------
echo "[2/12] ComfyUI $COMFY_TAG"

if [[ ! -d "$COMFY/.git" ]]; then
  if [[ -e "$COMFY" ]]; then
    mv "$COMFY" "${COMFY}.incomplete.$(date +%Y%m%d_%H%M%S)"
  fi
  git clone --depth 1 --branch "$COMFY_TAG" https://github.com/Comfy-Org/ComfyUI.git "$COMFY"
else
  git -C "$COMFY" fetch --depth 1 --force origin "refs/tags/$COMFY_TAG:refs/tags/$COMFY_TAG"
  git -C "$COMFY" checkout -f "$COMFY_TAG"
  git -C "$COMFY" reset --hard "$COMFY_TAG"
fi

grep -Rqs "MiniMaxH3ReferenceToVideo" "$COMFY/comfy_extras" || \
  die "$COMFY_TAG does not contain MiniMaxH3ReferenceToVideo"

mkdir -p "$LOG_DIR" "$RUNTIME_DIR" "$WF_DIR" \
  "$COMFY/models/diffusion_models" \
  "$COMFY/models/text_encoders" \
  "$COMFY/models/vae" \
  "$COMFY/models/loras"

SETUP_LOG="$LOG_DIR/setup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$SETUP_LOG") 2>&1

green "  ✓ independent ComfyUI checkout"

# -----------------------------------------------------------------------------
# 3. Python environment, with Torch protected from requirements replacement
# -----------------------------------------------------------------------------
echo "[3/12] Python / CUDA stack"

if [[ ! -x "$COMFY/.venv/bin/python" ]]; then
  "$PYTHON_BIN" -m venv --system-site-packages "$COMFY/.venv"
fi
PY="$COMFY/.venv/bin/python"
PIP="$COMFY/.venv/bin/pip"

"$PY" -m pip install -q -U pip setuptools wheel

REQ_FILTERED="$STATE_DIR/requirements_no_torch.txt"
"$PY" - "$COMFY/requirements.txt" "$REQ_FILTERED" <<'PYCODE'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
pat = re.compile(r'^\s*(torch|torchvision|torchaudio)(?:\s*[<>=!~].*)?\s*(?:#.*)?$', re.I)
out=[]
with open(src, encoding="utf-8") as f:
    for line in f:
        if not pat.match(line.strip()):
            out.append(line)
with open(dst, "w", encoding="utf-8") as f:
    f.writelines(out)
PYCODE

"$PIP" install -q --upgrade-strategy only-if-needed -r "$REQ_FILTERED"

if "$PY" - <<'PYCODE' >/tmp/h3_singularity_torch_probe.txt 2>&1
import torch
ok = torch.cuda.is_available() and str(torch.version.cuda or "").startswith("13.")
print("torch=", torch.__version__)
print("torch_cuda=", torch.version.cuda)
print("cuda=", torch.cuda.is_available())
print("gpu=", torch.cuda.get_device_name(0) if torch.cuda.is_available() else "NONE")
raise SystemExit(0 if ok else 1)
PYCODE
then
  cat /tmp/h3_singularity_torch_probe.txt
  echo "  [SKIP] usable CUDA 13 PyTorch already present"
else
  cat /tmp/h3_singularity_torch_probe.txt || true
  echo "  Installing official PyTorch CUDA 13 wheels..."
  "$PIP" install -q -U torch torchvision torchaudio \
    --extra-index-url https://download.pytorch.org/whl/cu130
fi

# Known-good INT8 ConvRot backend family from the working H3 environment.
"$PIP" install -q -U "comfy-kitchen[cublas]==0.2.31" triton

"$PY" - <<'PYCODE'
import torch
print("torch:", torch.__version__)
print("torch CUDA:", torch.version.cuda)
print("CUDA available:", torch.cuda.is_available())
print("GPU:", torch.cuda.get_device_name(0) if torch.cuda.is_available() else "NONE")
assert torch.cuda.is_available(), "CUDA unavailable"
assert str(torch.version.cuda or "").startswith("13."), "CUDA 13 PyTorch required for saved 5090 path"
x=torch.randn((128,128), device="cuda")
print("CUDA matmul probe:", float((x @ x).mean()))
PYCODE

green "  ✓ Python/CUDA stack"

# -----------------------------------------------------------------------------
# 4. Verified downloader
# -----------------------------------------------------------------------------
echo "[4/12] Downloader"

verified_download(){
  local label="$1" url="$2" dest="$3" sha="$4" min_bytes="$5"
  mkdir -p "$(dirname "$dest")"

  if [[ -s "$dest" ]]; then
    size="$(stat -c%s "$dest")"
    if (( size >= min_bytes )); then
      got="$(sha256sum "$dest" | awk '{print $1}')"
      if [[ "$got" == "$sha" ]]; then
        echo "  [SKIP verified] $label"
        return 0
      fi
    fi
    yellow "  Existing $label is incomplete/checksum-mismatched; redownloading."
    rm -f "$dest" "$dest.aria2"
  fi

  echo "  [DOWNLOAD] $label"
  aria2c -c -x16 -s16 -k16M --file-allocation=none \
    --auto-file-renaming=false --allow-overwrite=true \
    --max-tries=15 --retry-wait=10 --summary-interval=20 \
    --dir "$(dirname "$dest")" --out "$(basename "$dest")" "$url"

  [[ -s "$dest" ]] || die "Download failed: $label"
  size="$(stat -c%s "$dest")"
  (( size >= min_bytes )) || die "$label too small: $size bytes"

  got="$(sha256sum "$dest" | awk '{print $1}')"
  [[ "$got" == "$sha" ]] || die "$label SHA256 mismatch: $got"
  green "  ✓ $label"
}

green "  ✓ verified downloader ready"

# -----------------------------------------------------------------------------
# 5-8. Models
# -----------------------------------------------------------------------------
echo "[5/12] Singularity diffusion model"
verified_download "Singularity Pruned v1.3 INT8" "$MODEL_URL" \
  "$COMFY/models/diffusion_models/$MODEL" "$MODEL_SHA" 20000000000

echo "[6/12] Text encoder"
verified_download "Qwen3VL MiniMax-H3 NVFP4-AWQ" "$TEXT_URL" \
  "$COMFY/models/text_encoders/$TEXT" "$TEXT_SHA" 15000000000

echo "[7/12] Video + audio VAE"
verified_download "MiniMax-H3 video VAE FP16" "$VIDEO_VAE_URL" \
  "$COMFY/models/vae/$VIDEO_VAE" "$VIDEO_VAE_SHA" 5000000000
verified_download "MiniMax-H3 audio VAE FP32" "$AUDIO_VAE_URL" \
  "$COMFY/models/vae/$AUDIO_VAE" "$AUDIO_VAE_SHA" 500000000

echo "[8/12] Ref2V Turbo 4-step LoRA"
verified_download "Ref2V Turbo 4-step LoRA" "$TURBO_URL" \
  "$COMFY/models/loras/$TURBO" "$TURBO_SHA" 1800000000

# -----------------------------------------------------------------------------
# 9. Build workflows from a known native-core Ref2VA workflow
# -----------------------------------------------------------------------------
echo "[9/12] Build 3-REF workflows"

SOURCE_WF="$STATE_DIR/native_ref2va_source.json"
curl -fL --retry 8 --retry-all-errors --retry-delay 5 \
  "$WF_SOURCE_URL" -o "$SOURCE_WF"

"$PY" - "$SOURCE_WF" "$WF_DIR/$WF_BASE" "$WF_DIR/$WF_TURBO" \
  "$MODEL" "$TEXT" "$VIDEO_VAE" "$AUDIO_VAE" "$TURBO" <<'PYCODE'
import copy, json, sys

src, out_base, out_turbo, model, text, vvae, avae, turbo = sys.argv[1:]
with open(src, encoding="utf-8") as f:
    base = json.load(f)

def node_by_type(d, t):
    hits=[n for n in d["nodes"] if n.get("type")==t]
    if not hits:
        raise RuntimeError(f"Required node missing in source workflow: {t}")
    return hits[0]

# Replace model resources in core loader nodes.
unet=node_by_type(base, "UNETLoader")
unet["widgets_values"]=[model, "default"]
unet.setdefault("properties", {})["models"]=[{
    "name": model,
    "url": f"https://huggingface.co/WarmBloodAban/Minimax-h3_Singularity/resolve/main/{model}",
    "directory": "diffusion_models",
}]

clip=node_by_type(base, "CLIPLoader")
clip["widgets_values"]=[text, "minimax", "default"]
clip.setdefault("properties", {})["models"]=[{
    "name": text,
    "url": f"https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/text_encoders/{text}",
    "directory": "text_encoders",
}]

vaes=[n for n in base["nodes"] if n.get("type")=="VAELoader"]
for n in vaes:
    vals=n.get("widgets_values", [])
    old=vals[0] if vals else ""
    new = avae if "audio" in old.lower() else vvae
    n["widgets_values"]=[new]
    n.setdefault("properties", {})["models"]=[{
        "name": new,
        "directory": "vae",
    }]

# Make output prefix explicit for #14.
save=node_by_type(base, "SaveVideo")
if save.get("widgets_values"):
    save["widgets_values"][0]="video/H3_Singularity"

# 5 sec default for first smoke run; user can move to 15 sec after validation.
dur=node_by_type(base, "PrimitiveFloat")
dur["widgets_values"]=[5.0]

# Use a neutral template prompt that explicitly assigns three references.
prompt=node_by_type(base, "PrimitiveStringMultiline")
prompt["widgets_values"]=[(
    "<Picture 1> defines the person's identity and face. "
    "<Picture 2> defines clothing and body appearance. "
    "<Picture 3> defines the location/background. "
    "Create one continuous realistic shot, preserve reference identity, clothing, "
    "environment and natural proportions. No cuts."
)]

# Ensure MiniMax node exposes 3 reference-image slots.
ref=node_by_type(base, "MiniMaxH3ReferenceToVideo")
ref_inputs=ref["inputs"]
while len([i for i in ref_inputs if str(i.get("name","")).startswith("ref_images.")]) < 3:
    idx=len([i for i in ref_inputs if str(i.get("name","")).startswith("ref_images.")])
    # insert after existing image refs
    insert_at=3+idx
    ref_inputs.insert(insert_at, {
        "label": f"ref_image_{idx}",
        "name": f"ref_images.ref_image_{idx}",
        "shape": 7,
        "type": "IMAGE",
        "link": None,
    })

# Connect a third LoadImage to ref_image_2 if it is not already connected.
third = next(i for i in ref_inputs if i.get("name")=="ref_images.ref_image_2")
if third.get("link") is None:
    max_node=max(n["id"] for n in base["nodes"])
    max_link=max(l[0] for l in base["links"])
    nid=max_node+1
    lid=max_link+1
    load3={
        "id": nid,
        "type": "LoadImage",
        "pos": [-170, 5630],
        "size": [290, 330],
        "flags": {},
        "order": max(n.get("order",0) for n in base["nodes"])+1,
        "mode": 0,
        "inputs": [],
        "outputs": [
            {"name":"IMAGE","type":"IMAGE","links":[lid]},
            {"name":"MASK","type":"MASK","links":None},
        ],
        "title":"Reference 3 — Background / Location",
        "properties":{"cnr_id":"comfy-core","Node name for S&R":"LoadImage"},
        "widgets_values":["ref3_background.png","image"],
    }
    base["nodes"].append(load3)
    # Find the actual input index after possible dynamic inputs.
    input_index=ref_inputs.index(third)
    third["link"]=lid
    base["links"].append([lid, nid, 0, ref["id"], input_index, "IMAGE"])
    base["last_node_id"]=max(base.get("last_node_id",0), nid)
    base["last_link_id"]=max(base.get("last_link_id",0), lid)

# Baseline: native 20-step, no Turbo LoRA.
sched=node_by_type(base, "BasicScheduler")
sched["widgets_values"]=["simple", 20, 1]
with open(out_base, "w", encoding="utf-8") as f:
    json.dump(base, f, ensure_ascii=False, indent=2)

# Turbo copy: add LoraLoaderModelOnly between UNET and all MODEL consumers.
tw=copy.deepcopy(base)
unet=node_by_type(tw, "UNETLoader")
sched=node_by_type(tw, "BasicScheduler")
guider=node_by_type(tw, "BasicGuider")

max_node=max(n["id"] for n in tw["nodes"])
max_link=max(l[0] for l in tw["links"])
lora_id=max_node+1
link_unet_lora=max_link+1
link_lora_sched=max_link+2
link_lora_guider=max_link+3

# Remove direct UNET->scheduler / UNET->guider model links.
old_model_links=[]
for l in list(tw["links"]):
    if l[1]==unet["id"] and l[2]==0 and l[3] in (sched["id"], guider["id"]):
        old_model_links.append(l[0])
        tw["links"].remove(l)

# Update target input link IDs.
for inp in sched["inputs"]:
    if inp.get("name")=="model":
        inp["link"]=link_lora_sched
for inp in guider["inputs"]:
    if inp.get("name")=="model":
        inp["link"]=link_lora_guider

# Replace UNET output's links with link to LoRA.
unet["outputs"][0]["links"]=[link_unet_lora]

lora_node={
    "id": lora_id,
    "type": "LoraLoaderModelOnly",
    "pos": [-760, 4850],
    "size": [410, 90],
    "flags": {},
    "order": 9,
    "mode": 0,
    "inputs": [
        {"name":"model","type":"MODEL","link":link_unet_lora}
    ],
    "outputs": [
        {"name":"MODEL","type":"MODEL","links":[link_lora_sched, link_lora_guider]}
    ],
    "title":"Singularity — Ref2V Turbo 4-step",
    "properties":{
        "cnr_id":"comfy-core",
        "Node name for S&R":"LoraLoaderModelOnly",
        "models":[{"name":turbo,"directory":"loras"}],
    },
    "widgets_values":[turbo, 1.0],
}
tw["nodes"].append(lora_node)
tw["links"].extend([
    [link_unet_lora, unet["id"], 0, lora_id, 0, "MODEL"],
    [link_lora_sched, lora_id, 0, sched["id"], 0, "MODEL"],
    [link_lora_guider, lora_id, 0, guider["id"], 0, "MODEL"],
])
sched["widgets_values"]=["simple", 4, 1]
tw["last_node_id"]=max(tw.get("last_node_id",0), lora_id)
tw["last_link_id"]=max(tw.get("last_link_id",0), link_lora_guider)

with open(out_turbo, "w", encoding="utf-8") as f:
    json.dump(tw, f, ensure_ascii=False, indent=2)

# Static graph checks before ComfyUI starts.
for path, expect_lora in [(out_base, False),(out_turbo, True)]:
    d=json.load(open(path, encoding="utf-8"))
    types={n.get("type") for n in d["nodes"]}
    required={"UNETLoader","CLIPLoader","VAELoader","MiniMaxH3ReferenceToVideo",
              "SamplerCustomAdvanced","BasicScheduler","SaveVideo"}
    missing=required-types
    if missing:
        raise RuntimeError(f"{path}: missing nodes: {sorted(missing)}")
    has_lora="LoraLoaderModelOnly" in types
    if has_lora != expect_lora:
        raise RuntimeError(f"{path}: LoRA graph mismatch")
    txt=json.dumps(d, ensure_ascii=False)
    for required_file in (model,text,vvae,avae):
        if required_file not in txt:
            raise RuntimeError(f"{path}: missing resource reference: {required_file}")
    if expect_lora and turbo not in txt:
        raise RuntimeError(f"{path}: missing Turbo LoRA reference")
    # Exactly three image reference inputs should be exposed.
    r=[n for n in d["nodes"] if n.get("type")=="MiniMaxH3ReferenceToVideo"][0]
    refs=[i for i in r["inputs"] if str(i.get("name","")).startswith("ref_images.")]
    if len(refs) < 3:
        raise RuntimeError(f"{path}: fewer than 3 ref image slots")
    print("validated workflow:", path)
PYCODE

green "  ✓ baseline + Turbo workflows created"

# -----------------------------------------------------------------------------
# 10. Safe port handoff
# -----------------------------------------------------------------------------
echo "[10/12] Port $PORT handoff"

pids="$(lsof -ti tcp:"$PORT" 2>/dev/null || true)"
if [[ -n "$pids" ]]; then
  for pid in $pids; do
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
    if [[ "$cmd" == *"main.py"* && "$cwd" == "$ROOT"/ComfyUI* ]]; then
      echo "  stopping existing ComfyUI PID $pid ($cwd)"
      kill "$pid" 2>/dev/null || true
    else
      die "Port $PORT occupied by unrelated PID $pid ($cwd)"
    fi
  done
  for _ in $(seq 1 30); do
    [[ -z "$(lsof -ti tcp:"$PORT" 2>/dev/null || true)" ]] && break
    sleep 1
  done
fi
[[ -z "$(lsof -ti tcp:"$PORT" 2>/dev/null || true)" ]] || die "Could not free port $PORT"

green "  ✓ port ready"

# -----------------------------------------------------------------------------
# 11. Start and validate registered nodes/models
# -----------------------------------------------------------------------------
echo "[11/12] Start ComfyUI + object_info validation"

RUNTIME_LOG="$RUNTIME_DIR/comfy_$(date +%Y%m%d_%H%M%S).log"
cd "$COMFY"
nohup "$PY" main.py \
  --listen 0.0.0.0 \
  --port "$PORT" \
  --preview-method auto \
  --enable-cors-header \
  --reserve-vram 4 \
  --cache-none \
  > "$RUNTIME_LOG" 2>&1 &
PID=$!
echo "$PID" > "$COMFY/h3_singularity.pid"

ready=0
for _ in $(seq 1 180); do
  if ! kill -0 "$PID" 2>/dev/null; then
    tail -180 "$RUNTIME_LOG" || true
    die "ComfyUI exited during startup"
  fi
  if curl -fsS "http://127.0.0.1:$PORT/system_stats" \
      >/tmp/h3_singularity_system_stats.json 2>/dev/null; then
    ready=1
    break
  fi
  sleep 1
done

[[ "$ready" == "1" ]] || {
  tail -180 "$RUNTIME_LOG" || true
  die "ComfyUI did not become ready within 180 seconds"
}

curl -fsS "http://127.0.0.1:$PORT/object_info" \
  -o /tmp/h3_singularity_object_info.json

"$PY" - "$MODEL" "$TEXT" "$VIDEO_VAE" "$AUDIO_VAE" "$TURBO" <<'PYCODE'
import json, sys
model,text,vvae,avae,turbo=sys.argv[1:]
d=json.load(open("/tmp/h3_singularity_object_info.json", encoding="utf-8"))
required=[
    "MiniMaxH3ReferenceToVideo",
    "UNETLoader",
    "CLIPLoader",
    "VAELoader",
    "LoraLoaderModelOnly",
    "SamplerCustomAdvanced",
    "BasicScheduler",
    "VAEDecodeAudio",
    "CreateVideo",
    "SaveVideo",
]
missing=[x for x in required if x not in d]
if missing:
    raise SystemExit("Missing required registered nodes: "+", ".join(missing))

# Verify files are visible in loader dropdown metadata where possible.
checks=[
    ("UNETLoader", model),
    ("CLIPLoader", text),
    ("VAELoader", vvae),
    ("VAELoader", avae),
    ("LoraLoaderModelOnly", turbo),
]
blob=json.dumps(d, ensure_ascii=False)
for node, filename in checks:
    if filename not in blob:
        print(f"[WARN] {filename} not surfaced in object_info metadata; file existence/checksum already verified.")
    else:
        print("loader-visible:", filename)

print("Required MiniMax-H3 / LoRA nodes OK")
PYCODE

green "  ✓ ComfyUI and required H3 nodes registered"

# -----------------------------------------------------------------------------
# 12. Launchers + final summary
# -----------------------------------------------------------------------------
echo "[12/12] Save launchers"

cat > "$COMFY/start_h3_singularity.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$COMFY"
exec "$PY" main.py --listen 0.0.0.0 --port "$PORT" --preview-method auto --enable-cors-header --reserve-vram 4 --cache-none
EOF
chmod +x "$COMFY/start_h3_singularity.sh"

cat > "$COMFY/restart_h3_singularity.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
pids=\$(lsof -ti tcp:"$PORT" 2>/dev/null || true)
[[ -z "\$pids" ]] || kill \$pids 2>/dev/null || true
sleep 2
cd "$COMFY"
nohup "$PY" main.py --listen 0.0.0.0 --port "$PORT" --preview-method auto --enable-cors-header --reserve-vram 4 --cache-none > "$RUNTIME_DIR/comfy_restart.log" 2>&1 &
echo "Started H3 Singularity on port $PORT"
EOF
chmod +x "$COMFY/restart_h3_singularity.sh"

cat > "$COMFY/ENVIRONMENT_INFO.txt" <<EOF
SETUP #14 — MiniMax H3 Singularity Ref2VA v1
Created: $(date -Is)
ComfyUI: $COMFY_TAG
Model: $MODEL
Text encoder: $TEXT
Video VAE: $VIDEO_VAE
Audio VAE: $AUDIO_VAE
Turbo LoRA: $TURBO

Workflow A: $WF_BASE
  Native baseline, 20 steps, 3 reference images.

Workflow B: $WF_TURBO
  Turbo LoRA strength 1.0, 4 steps, 3 reference images.

First test recommendation:
  1) Run 14A at 5 sec first.
  2) Confirm Ref1/Ref2/Ref3 identity/clothing/background behavior.
  3) Run 14B with the same seed/prompt/references.
  4) Only after both pass, increase duration toward 15 sec.

No generation is performed by this setup script.
EOF

trap - ERR

echo
echo "================================================================="
green " READY — SETUP #14 H3 SINGULARITY REF2VA v1"
echo "================================================================="
echo "Environment:"
echo "  $COMFY"
echo
echo "Model:"
echo "  $MODEL"
echo
echo "Workflows:"
echo "  $WF_BASE   <- quality/control baseline (20-step)"
echo "  $WF_TURBO  <- author-recommended Ref2V Turbo 4-step"
echo
echo "First run:"
echo "  Start with 5 sec. Do NOT jump straight to 15 sec."
echo "  Compare the same 3 refs / prompt / seed between A and B."
echo
echo "Setup log:"
echo "  $SETUP_LOG"
echo "Runtime log:"
echo "  $RUNTIME_LOG"
echo
echo "Open RunPod port $PORT."
echo "================================================================="
