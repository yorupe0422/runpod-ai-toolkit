#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# SETUP #5 COMPLETE v3
# MiniMax H3 / PinkCherry — clean, reproducible, generation-ready environment
#
# Goal:
#   Run this ONE script on a RunPod, then open port 8188, choose one of the
#   installed workflows, replace the placeholder image with your own image,
#   enter/edit the prompt, and Queue.
#
# Design:
#   - Builds an isolated clean ComfyUI-H3 environment.
#   - Pins ComfyUI to official stable v0.33.1.
#   - Uses only native ComfyUI nodes in the workflows.
#   - Downloads and verifies all required model files.
#   - Installs 4 workflows:
#       1) Official MiniMax H3 I2V 20-step baseline
#       2) Official MiniMax H3 I2V Turbo 8-step
#       3) PinkCherry I2V 20-step baseline
#       4) PinkCherry I2V Turbo 8-step
#   - Dynamic VRAM remains ON.
#   - Starts with --reserve-vram 4 --cache-none.
#   - Does not print READY until required nodes/models/workflows are verified.
# =============================================================================

BASE="/workspace/runpod-slim"
COMFY="$BASE/ComfyUI-H3"
PORT="${PORT:-8188}"
LOG="$BASE/comfyui-h3.log"
PYTHON_BIN="${PYTHON_BIN:-python3.12}"
COMFY_TAG="v0.33.1"

# High-speed/resumable download tuning. Override only when the host/network
# benefits from a smaller value (for example: DL_CONNECTIONS=8).
DL_CONNECTIONS="${DL_CONNECTIONS:-16}"
DL_SPLIT="${DL_SPLIT:-16}"
DL_MIN_SPLIT_SIZE="${DL_MIN_SPLIT_SIZE:-16M}"
DL_RETRIES="${DL_RETRIES:-6}"

WF_DIR="$COMFY/user/default/workflows"
INPUT_DIR="$COMFY/input"

# ----- Official MiniMax H3 model files -----
BASE_MODEL="minimax_h3_fl2va_pruned_int8_convrot.safetensors"
TEXT_MODEL="qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"
VIDEO_VAE="minimax_h3_video_vae_fp16.safetensors"
AUDIO_VAE="minimax_h3_audio_vae_fp32.safetensors"

URL_BASE_MODEL="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/diffusion_models/$BASE_MODEL"
URL_TEXT_MODEL="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/text_encoders/$TEXT_MODEL"
URL_VIDEO_VAE="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/$VIDEO_VAE"
URL_AUDIO_VAE="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/$AUDIO_VAE"

SHA_BASE_MODEL="e889202c41dafb67b10d67b97f0d8541508036a6090af23425a5c2615d03c47a"
SHA_TEXT_MODEL="35a88d51044231fe332301d7a62aa81e3f2cba62febeb446e2c1e3e0ef76f2c6"
SHA_VIDEO_VAE="7c1f131492e7eddacaac9069a61b81bdd39de5cc96561e677c5eab1cdce5e522"
SHA_AUDIO_VAE="8e505d95dd1561d47abd43d4238fd40d9bb1ae9e147ed0a4cba778d76ae4db48"

# ----- PinkCherry -----
PINK_MODEL="PinkCherry_h3_fl2va_pruned_int8_v0.5-alpha.safetensors"
# The repository renamed alpha-0.5-testing to alpha-0.5-fl2va. Pin the rename
# commit so a later repository reorganization cannot break SETUP #5 again.
PINK_REV="02f46262748c1e0a6b0e563c4a9c6f6323d951b3"
URL_PINK_MODEL="https://huggingface.co/SexGod1979/PinkCherry_MiniMax-H3/resolve/$PINK_REV/alpha-0.5-fl2va/$PINK_MODEL"
SHA_PINK_MODEL="81360b34506599ff23c8b693f7de77fbe553190fd028608a205eeb9e0f06f9fe"

# ----- Current recommended pruned Turbo LoRA -----
TURBO_LORA="minimax_h3_turbo_v4_step600_ema_pruned_comfyui.safetensors"
TURBO_REV="683477ca53f88d85427c54260328972de28e77ca"
URL_TURBO_LORA="https://huggingface.co/drbaph/MiniMax-H3-Turbo-Lora-ComfyUI/resolve/$TURBO_REV/$TURBO_LORA"
SHA_TURBO_LORA="7098acf3ee75028fd9fcd948f50fcc8d995057fabb76f86bd3ca2c0ffc58e409"

# ----- Official workflow source -----
OFFICIAL_I2V_URL="https://raw.githubusercontent.com/Comfy-Org/workflow_templates/refs/heads/main/templates/video_minimax_h3_i2v.json"
OFFICIAL_I2V_RAW="$BASE/video_minimax_h3_i2v.official.json"

# ----- Installed workflow names -----
WF_BASE="01_MiniMax_H3_I2V_OFFICIAL_20STEP.json"
WF_BASE_TURBO="02_MiniMax_H3_I2V_TURBO_8STEP.json"
WF_PINK="03_PinkCherry_H3_I2V_20STEP.json"
WF_PINK_TURBO="04_PinkCherry_H3_I2V_TURBO_8STEP.json"

green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[0;33m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
die(){ red "[FAILED] $*"; exit 1; }

cleanup_on_error() {
  rc=$?
  if [[ $rc -ne 0 ]]; then
    red ""
    red "SETUP #5 COMPLETE v3 FAILED"
    red "Last ComfyUI log:"
    tail -120 "$LOG" 2>/dev/null || true
  fi
  exit $rc
}
trap cleanup_on_error EXIT

echo
echo "================================================================="
echo " SETUP #5 COMPLETE v3 — MiniMax H3 / PinkCherry"
echo "================================================================="

# -----------------------------------------------------------------------------
# 1) System tools
# -----------------------------------------------------------------------------
echo "[1/10] System tools"
missing_packages=()
command -v git >/dev/null 2>&1 || missing_packages+=(git)
command -v curl >/dev/null 2>&1 || missing_packages+=(curl ca-certificates)
command -v aria2c >/dev/null 2>&1 || missing_packages+=(aria2)
command -v fuser >/dev/null 2>&1 || missing_packages+=(psmisc)
command -v flock >/dev/null 2>&1 || missing_packages+=(util-linux)
if (( ${#missing_packages[@]} > 0 )); then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing_packages[@]}"
fi
green "  ✓ git / curl / aria2 / process tools"

# Refuse only a second copy of this installer. Generation in another ComfyUI
# environment is not mistaken for an installer process.
LOCK_FILE="$BASE/.setup5-complete-v3.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || die "Another SETUP #5 v3 installer is already running"

# -----------------------------------------------------------------------------
# 2) Fresh/pinned ComfyUI-H3
# -----------------------------------------------------------------------------
echo "[2/10] Build clean ComfyUI-H3 ($COMFY_TAG)"
fuser -k "${PORT}/tcp" 2>/dev/null || true
sleep 2

if [[ ! -d "$COMFY/.git" ]]; then
  rm -rf "$COMFY"
  git clone -q https://github.com/Comfy-Org/ComfyUI.git "$COMFY"
fi

cd "$COMFY"
git fetch -q --tags origin
git reset --hard -q
git clean -fd -q -e models -e input -e output -e user
git checkout -q "$COMFY_TAG"

# Critical source-level check. Do NOT continue on a ComfyUI build without H3.
grep -Rqs "class MiniMaxH3ImageToVideo" "$COMFY/comfy_extras" \
  || grep -Rqs "MiniMaxH3ImageToVideo" "$COMFY/comfy_extras" \
  || die "$COMFY_TAG does not contain MiniMaxH3ImageToVideo"

green "  ✓ clean ComfyUI $COMFY_TAG with MiniMaxH3ImageToVideo"

# -----------------------------------------------------------------------------
# 3) Isolated Python env
# -----------------------------------------------------------------------------
echo "[3/10] Python environment"
if [[ ! -x "$COMFY/.venv/bin/python" ]]; then
  "$PYTHON_BIN" -m venv --system-site-packages "$COMFY/.venv"
fi

VENV_PY="$COMFY/.venv/bin/python"
"$VENV_PY" -m pip install -q --upgrade pip
"$VENV_PY" -m pip install -q -r "$COMFY/requirements.txt"

green "  ✓ requirements synced"

# -----------------------------------------------------------------------------
# Download + SHA verification helper
# -----------------------------------------------------------------------------
verified_download() {
  local url="$1"
  local dest="$2"
  local sha="$3"
  local min_bytes="${4:-1}"
  local marker="${dest}.sha256-ok"
  local size got attempt wait_seconds rc job

  mkdir -p "$(dirname "$dest")"

  if [[ -f "$dest" && -f "$marker" ]] && grep -qx "$sha" "$marker"; then
    size="$(stat -c '%s' "$dest")"
    if (( size >= min_bytes )); then
      echo "  [SKIP verified] $(basename "$dest")"
      return 0
    fi
    yellow "  Verified marker exists but file size is invalid; repairing."
    rm -f "$dest" "$dest.aria2" "$marker"
  fi

  # Preserve aria2 partial files so an interrupted multi-GB download resumes.
  # Hash only a completed-looking file that has no aria2 control file.
  if [[ -f "$dest" && ! -f "$dest.aria2" ]]; then
    echo "  [VERIFY existing] $(basename "$dest")"
    got="$(sha256sum "$dest" | awk '{print $1}')"
    size="$(stat -c '%s' "$dest")"
    if [[ "$got" == "$sha" && "$size" -ge "$min_bytes" ]]; then
      printf '%s\n' "$sha" > "$marker"
      echo "  [OK] $(basename "$dest")"
      return 0
    fi
    yellow "  Existing file checksum mismatch; redownloading."
    rm -f "$dest" "$dest.aria2" "$marker"
  fi

  if [[ -f "$dest.aria2" ]]; then
    echo "  [RESUME x${DL_CONNECTIONS}] $(basename "$dest")"
  else
    echo "  [DOWNLOAD x${DL_CONNECTIONS}] $(basename "$dest")"
  fi

  rc=1
  for attempt in $(seq 1 "$DL_RETRIES"); do
    # Keep HF_TOKEN out of the process list by putting the Authorization header
    # in a mode-600 temporary aria2 input file, removed after every attempt.
    job="$(mktemp /tmp/setup5-aria2.XXXXXX)"
    chmod 600 "$job"
    printf '%s\n' "$url" > "$job"
    # With --input-file, dir/out must be URI-local options. Supplying them only
    # on aria2c's command line can let Hugging Face Content-Disposition replace
    # the requested filename with an internal Xet/CAS hash.
    printf '  dir=%s\n' "$(dirname "$dest")" >> "$job"
    printf '  out=%s\n' "$(basename "$dest")" >> "$job"
    if [[ -n "${HF_TOKEN:-}" ]]; then
      printf '  header=Authorization: Bearer %s\n' "$HF_TOKEN" >> "$job"
    fi

    if (
      trap 'rm -f "$job"' EXIT
      aria2c \
        --input-file="$job" \
        --continue=true \
        --max-connection-per-server="$DL_CONNECTIONS" \
        --split="$DL_SPLIT" \
        --min-split-size="$DL_MIN_SPLIT_SIZE" \
        --file-allocation=none \
        --auto-file-renaming=false \
        --allow-overwrite=true \
        --max-tries=8 \
        --retry-wait=5 \
        --timeout=30 \
        --connect-timeout=20 \
        --lowest-speed-limit=64K \
        --summary-interval=10 \
        --console-log-level=warn
    ); then
      rc=0
      break
    else
      rc=$?
    fi

    wait_seconds=$(( attempt * 10 ))
    yellow "  Download attempt ${attempt}/${DL_RETRIES} failed; resuming in ${wait_seconds}s."
    sleep "$wait_seconds"
  done
  [[ "$rc" == "0" ]] || die "Download failed after $DL_RETRIES attempts: $dest"

  [[ -s "$dest" ]] || die "Download failed: $dest"
  size="$(stat -c '%s' "$dest")"
  (( size >= min_bytes )) || die "Downloaded file is unexpectedly small: $(basename "$dest") ($size bytes)"

  echo "  [SHA256] $(basename "$dest")"
  got="$(sha256sum "$dest" | awk '{print $1}')"
  [[ "$got" == "$sha" ]] || die "Checksum mismatch: $(basename "$dest")"
  printf '%s\n' "$sha" > "$marker"
  echo "  [OK] $(basename "$dest")"
}

# -----------------------------------------------------------------------------
# 4) Core model files
# -----------------------------------------------------------------------------
echo "[4/10] Official MiniMax H3 models"
verified_download "$URL_BASE_MODEL" "$COMFY/models/diffusion_models/$BASE_MODEL" "$SHA_BASE_MODEL" 10000000000
verified_download "$URL_TEXT_MODEL" "$COMFY/models/text_encoders/$TEXT_MODEL" "$SHA_TEXT_MODEL" 5000000000
verified_download "$URL_VIDEO_VAE" "$COMFY/models/vae/$VIDEO_VAE" "$SHA_VIDEO_VAE" 400000000
verified_download "$URL_AUDIO_VAE" "$COMFY/models/vae/$AUDIO_VAE" "$SHA_AUDIO_VAE" 500000000
green "  ✓ official H3 model set complete"

# -----------------------------------------------------------------------------
# 5) PinkCherry + Turbo LoRA
# -----------------------------------------------------------------------------
echo "[5/10] PinkCherry + Turbo LoRA"
verified_download "$URL_PINK_MODEL" "$COMFY/models/diffusion_models/$PINK_MODEL" "$SHA_PINK_MODEL" 20000000000
verified_download "$URL_TURBO_LORA" "$COMFY/models/loras/$TURBO_LORA" "$SHA_TURBO_LORA" 500000000
green "  ✓ PinkCherry + Turbo ready"

# -----------------------------------------------------------------------------
# 6) Fetch the official I2V workflow and generate our 4 workflows
# -----------------------------------------------------------------------------
echo "[6/10] Build verified workflows"
mkdir -p "$WF_DIR" "$INPUT_DIR"

curl -fsSL --retry 5 "$OFFICIAL_I2V_URL" -o "$OFFICIAL_I2V_RAW"
"$VENV_PY" - <<'PY'
import copy
import json
from pathlib import Path

BASE = Path("/workspace/runpod-slim")
COMFY = BASE / "ComfyUI-H3"
WF_DIR = COMFY / "user/default/workflows"
RAW = BASE / "video_minimax_h3_i2v.official.json"

BASE_MODEL = "minimax_h3_fl2va_pruned_int8_convrot.safetensors"
PINK_MODEL = "PinkCherry_h3_fl2va_pruned_int8_v0.5-alpha.safetensors"
TEXT_MODEL = "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"
VIDEO_VAE = "minimax_h3_video_vae_fp16.safetensors"
AUDIO_VAE = "minimax_h3_audio_vae_fp32.safetensors"
TURBO = "minimax_h3_turbo_v4_step600_ema_pruned_comfyui.safetensors"

BASE_URL = f"https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/diffusion_models/{BASE_MODEL}"
PINK_REV = "02f46262748c1e0a6b0e563c4a9c6f6323d951b3"
PINK_URL = f"https://huggingface.co/SexGod1979/PinkCherry_MiniMax-H3/resolve/{PINK_REV}/alpha-0.5-fl2va/{PINK_MODEL}"

wf = json.loads(RAW.read_text(encoding="utf-8"))

if not wf.get("definitions", {}).get("subgraphs"):
    raise SystemExit("Official I2V workflow does not contain expected subgraph definition")

sg = wf["definitions"]["subgraphs"][0]
nodes = sg["nodes"]
links = sg["links"]

def find_node(type_name):
    for n in nodes:
        if n.get("type") == type_name:
            return n
    raise RuntimeError(f"Missing node in official workflow: {type_name}")

# Sanity-check that this official template is structurally what we expect.
for t in [
    "MiniMaxH3ImageToVideo", "UNETLoader", "CLIPLoader", "VAELoader",
    "KSamplerSelect", "BasicScheduler", "SamplerCustomAdvanced",
    "BasicGuider", "VAEDecode", "VAEDecodeAudio", "CreateVideo"
]:
    find_node(t)

def replace_all(obj, old, new):
    if isinstance(obj, dict):
        return {k: replace_all(v, old, new) for k, v in obj.items()}
    if isinstance(obj, list):
        return [replace_all(v, old, new) for v in obj]
    if isinstance(obj, str):
        return obj.replace(old, new)
    return obj

def make_model_variant(src, model_name, model_url, output_name):
    out = copy.deepcopy(src)
    out = replace_all(out, BASE_MODEL, model_name)
    out = replace_all(out, BASE_URL, model_url)

    # Set a neutral placeholder image that exists.
    for n in out.get("nodes", []):
        if n.get("type") == "LoadImage":
            n["widgets_values"] = ["setup5_placeholder.png", "image"]
        if n.get("type") == "SaveVideo":
            vals = list(n.get("widgets_values", []))
            if vals:
                vals[0] = f"video/{output_name}"
                n["widgets_values"] = vals

    # Outer subgraph widget also carries the selected model.
    for n in out.get("nodes", []):
        if n.get("type") in {s["id"] for s in out["definitions"]["subgraphs"]}:
            vals = list(n.get("widgets_values", []))
            # Official I2V template: index 4=UNET, 5=CLIP, 6=video VAE, 7=audio VAE
            if len(vals) >= 8:
                vals[4] = model_name
                vals[5] = TEXT_MODEL
                vals[6] = VIDEO_VAE
                vals[7] = AUDIO_VAE
                n["widgets_values"] = vals
    return out

def add_turbo(src):
    out = copy.deepcopy(src)
    sg2 = out["definitions"]["subgraphs"][0]
    ns = sg2["nodes"]
    ls = sg2["links"]

    def fn(t):
        for n in ns:
            if n.get("type") == t:
                return n
        raise RuntimeError(t)

    unet = fn("UNETLoader")
    guider = fn("BasicGuider")
    sched = fn("BasicScheduler")
    sampler = fn("KSamplerSelect")

    # Recommended current Turbo settings.
    sampler["widgets_values"] = ["euler"]
    sched["widgets_values"] = ["beta", 8, 1]

    # Remove only the direct UNET -> guider/scheduler MODEL links.
    direct = [
        l for l in ls
        if l.get("origin_id") == unet["id"]
        and l.get("target_id") in {guider["id"], sched["id"]}
        and l.get("type") == "MODEL"
    ]
    remove_ids = {l["id"] for l in direct}
    sg2["links"] = [l for l in ls if l["id"] not in remove_ids]

    # Clear stale references.
    if unet.get("outputs"):
        old = unet["outputs"][0].get("links") or []
        unet["outputs"][0]["links"] = [x for x in old if x not in remove_ids]
    for target in (guider, sched):
        for inp in target.get("inputs", []):
            if inp.get("name") == "model":
                inp["link"] = None

    new_nid = max(n["id"] for n in ns if isinstance(n.get("id"), int)) + 1
    max_lid = max(l["id"] for l in sg2["links"]) if sg2["links"] else 0
    l1, l2, l3 = max_lid + 1, max_lid + 2, max_lid + 3

    lora = {
        "id": new_nid,
        "type": "LoraLoaderModelOnly",
        "pos": [-1370, 4550],
        "size": [500, 90],
        "flags": {},
        "order": max(n.get("order", 0) for n in ns) + 1,
        "mode": 0,
        "inputs": [{"name": "model", "type": "MODEL", "link": l1}],
        "outputs": [{"name": "MODEL", "type": "MODEL", "links": [l2, l3]}],
        "title": "MiniMax H3 Turbo v4 step600 EMA",
        "properties": {"Node name for S&R": "LoraLoaderModelOnly"},
        "widgets_values": [TURBO, 1.0],
    }
    ns.append(lora)

    # Add links.
    sg2["links"].extend([
        {"id": l1, "origin_id": unet["id"], "origin_slot": 0,
         "target_id": new_nid, "target_slot": 0, "type": "MODEL"},
        {"id": l2, "origin_id": new_nid, "origin_slot": 0,
         "target_id": guider["id"], "target_slot": 0, "type": "MODEL"},
        {"id": l3, "origin_id": new_nid, "origin_slot": 0,
         "target_id": sched["id"], "target_slot": 0, "type": "MODEL"},
    ])

    unet["outputs"][0].setdefault("links", [])
    unet["outputs"][0]["links"].append(l1)

    for target, link_id in ((guider, l2), (sched, l3)):
        for inp in target["inputs"]:
            if inp.get("name") == "model":
                inp["link"] = link_id

    # Keep subgraph state counters consistent if present.
    state = sg2.get("state", {})
    state["lastNodeId"] = max(state.get("lastNodeId", 0), new_nid)
    state["lastLinkId"] = max(state.get("lastLinkId", 0), l3)

    return out

# Baselines from official workflow.
base20 = make_model_variant(wf, BASE_MODEL, BASE_URL, "MiniMax_H3_I2V_OFFICIAL_20STEP")
pink20 = make_model_variant(wf, PINK_MODEL, PINK_URL, "PinkCherry_H3_I2V_20STEP")

# Turbo versions are generated from the same official native workflow, not from
# an old custom-node workflow.
base8 = add_turbo(make_model_variant(wf, BASE_MODEL, BASE_URL, "MiniMax_H3_I2V_TURBO_8STEP"))
pink8 = add_turbo(make_model_variant(wf, PINK_MODEL, PINK_URL, "PinkCherry_H3_I2V_TURBO_8STEP"))

files = {
    "01_MiniMax_H3_I2V_OFFICIAL_20STEP.json": base20,
    "02_MiniMax_H3_I2V_TURBO_8STEP.json": base8,
    "03_PinkCherry_H3_I2V_20STEP.json": pink20,
    "04_PinkCherry_H3_I2V_TURBO_8STEP.json": pink8,
}

for name, obj in files.items():
    (WF_DIR / name).write_text(json.dumps(obj, ensure_ascii=False, indent=2), encoding="utf-8")
    # Round-trip JSON validation.
    json.loads((WF_DIR / name).read_text(encoding="utf-8"))

print("Installed workflows:")
for name in files:
    print(" -", name)
PY

# Placeholder image means the workflows are not born with a missing-image error.
"$VENV_PY" - <<'PY'
from PIL import Image, ImageDraw
from pathlib import Path

p = Path("/workspace/runpod-slim/ComfyUI-H3/input/setup5_placeholder.png")
img = Image.new("RGB", (512, 512), (32, 32, 32))
d = ImageDraw.Draw(img)
d.text((80, 245), "REPLACE WITH YOUR IMAGE", fill=(230,230,230))
img.save(p)
print("placeholder:", p)
PY

green "  ✓ 4 workflows built from official native I2V template"

# -----------------------------------------------------------------------------
# 7) Static workflow integrity checks
# -----------------------------------------------------------------------------
echo "[7/10] Static workflow integrity"
"$VENV_PY" - <<'PY'
import json
from pathlib import Path

root = Path("/workspace/runpod-slim/ComfyUI-H3")
wf_dir = root / "user/default/workflows"
required_models = {
    "minimax_h3_fl2va_pruned_int8_convrot.safetensors":
        root/"models/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors",
    "PinkCherry_h3_fl2va_pruned_int8_v0.5-alpha.safetensors":
        root/"models/diffusion_models/PinkCherry_h3_fl2va_pruned_int8_v0.5-alpha.safetensors",
    "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors":
        root/"models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
    "minimax_h3_video_vae_fp16.safetensors":
        root/"models/vae/minimax_h3_video_vae_fp16.safetensors",
    "minimax_h3_audio_vae_fp32.safetensors":
        root/"models/vae/minimax_h3_audio_vae_fp32.safetensors",
    "minimax_h3_turbo_v4_step600_ema_pruned_comfyui.safetensors":
        root/"models/loras/minimax_h3_turbo_v4_step600_ema_pruned_comfyui.safetensors",
}
for name, path in required_models.items():
    if not path.is_file() or path.stat().st_size == 0:
        raise SystemExit(f"Missing model: {name}")

for f in sorted(wf_dir.glob("0*_*.json")):
    w = json.loads(f.read_text(encoding="utf-8"))
    s = json.dumps(w)
    if "MiniMaxH3ImageToVideo" not in s:
        raise SystemExit(f"{f.name}: missing MiniMaxH3ImageToVideo")
    if "setup5_placeholder.png" not in s:
        raise SystemExit(f"{f.name}: placeholder input not installed")
    if "TURBO" in f.name and "LoraLoaderModelOnly" not in s:
        raise SystemExit(f"{f.name}: Turbo LoRA loader missing")
print("Static workflow integrity OK")
PY
green "  ✓ workflows reference installed assets"

# -----------------------------------------------------------------------------
# 8) Start ComfyUI-H3 on the RunPod-exposed port
# -----------------------------------------------------------------------------
echo "[8/10] Start ComfyUI-H3 on port $PORT"
fuser -k "${PORT}/tcp" 2>/dev/null || true
sleep 3

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

READY=0
for i in $(seq 1 240); do
  if ! kill -0 "$PID" 2>/dev/null; then
    tail -150 "$LOG" || true
    die "ComfyUI-H3 exited during startup"
  fi
  if curl --max-time 3 -fsS "http://127.0.0.1:$PORT/object_info" \
       > /tmp/setup5_object_info.json 2>/dev/null; then
    READY=1
    break
  fi
  sleep 1
done
[[ "$READY" == "1" ]] || die "ComfyUI-H3 startup timeout"

green "  ✓ server responding"

# -----------------------------------------------------------------------------
# 9) Runtime node validation
# -----------------------------------------------------------------------------
echo "[9/10] Runtime node validation"
"$VENV_PY" - <<'PY'
import json
d = json.load(open("/tmp/setup5_object_info.json"))
required = [
    "MiniMaxH3ImageToVideo",
    "UNETLoader",
    "CLIPLoader",
    "VAELoader",
    "LoraLoaderModelOnly",
    "KSamplerSelect",
    "BasicScheduler",
    "SamplerCustomAdvanced",
    "BasicGuider",
    "VAEDecode",
    "VAEDecodeAudio",
    "CreateVideo",
    "SaveVideo",
    "LoadImage",
]
missing = [x for x in required if x not in d]
if missing:
    raise SystemExit("Missing runtime node types: " + ", ".join(missing))
print("All critical node types are available.")
PY
green "  ✓ no critical missing nodes"

# -----------------------------------------------------------------------------
# 10) Runtime/model/profile final validation
# -----------------------------------------------------------------------------
echo "[10/10] Final validation"
RUNNING_CMD="$(ps -p "$PID" -o args= 2>/dev/null || true)"
echo "$RUNNING_CMD" | grep -q -- "--reserve-vram 4" || die "Missing --reserve-vram 4"
echo "$RUNNING_CMD" | grep -q -- "--cache-none" || die "Missing --cache-none"
if echo "$RUNNING_CMD" | grep -q -- "--disable-dynamic-vram"; then
  die "Unexpected --disable-dynamic-vram"
fi

# Check the exact H3 core source and running process one last time.
grep -Rqs "MiniMaxH3ImageToVideo" "$COMFY/comfy_extras" \
  || die "H3 source disappeared unexpectedly"

nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader || true

trap - EXIT
echo
echo "================================================================="
green " SETUP #5 COMPLETE v3 — GENERATION READY"
echo "================================================================="
echo "ComfyUI       : $COMFY"
echo "ComfyUI tag   : $COMFY_TAG"
echo "Port          : $PORT"
echo "VRAM profile  : Dynamic VRAM ON / reserve 4 GB / cache-none"
echo "Downloader    : aria2 x${DL_CONNECTIONS} / resume / SHA256 / retry"
echo
echo "Installed workflows:"
echo "  1. $WF_BASE"
echo "     Official MiniMax H3 baseline / 20 steps"
echo "  2. $WF_BASE_TURBO"
echo "     Official MiniMax H3 + Turbo / 8 steps"
echo "  3. $WF_PINK"
echo "     PinkCherry baseline / 20 steps"
echo "  4. $WF_PINK_TURBO"
echo "     PinkCherry + Turbo / 8 steps"
echo
echo "NEXT:"
echo "  Open RunPod Port 8188 -> Workflow -> choose one of the 4 workflows."
echo "  Replace setup5_placeholder.png with your own image, edit the prompt, Queue."
echo
echo "Log: $LOG"
echo "================================================================="
