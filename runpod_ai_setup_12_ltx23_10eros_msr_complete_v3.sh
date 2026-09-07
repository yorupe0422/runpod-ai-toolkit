#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# #12 LTX-2.3 + 10Eros v1.5 + Licon MSR V2 (COMPLETE v3)
# Fresh isolated RunPod / ComfyUI environment
#
# Target:
#   - RTX 5090 class GPU
#   - Port 8188
#   - Multi-reference: Ref1..Ref4 + Background
#   - 10Eros v1.5 main candidate
#   - Optional official LTX-2.3 FP8 fallback (disabled by default)
#
# Environment:
#   /workspace/runpod-slim/ComfyUI-LTX23-10Eros-MSR
#
# Notes:
#   * Rebuilt from scratch to incorporate all failures seen on 2026-09-07.
#   * Licon MSR V2 is the multi-reference component.
#   * 10Eros + MSR is experimental. FP8 fallback is optional to save ~29 GB.
# ============================================================

ROOT="/workspace/runpod-slim"
COMFY="${ROOT}/ComfyUI-LTX23-10Eros-MSR"
PORT="${PORT:-8188}"
BACKUP_EXISTING="${BACKUP_EXISTING:-0}"
INSTALL_FP8_FALLBACK="${INSTALL_FP8_FALLBACK:-0}"

# v2: keep all large Hugging Face/Xet/temp files on the persistent /workspace disk.
export HF_HOME="${HF_HOME:-${ROOT}/.cache/huggingface}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-${HF_HOME}/hub}"
export HF_XET_CACHE="${HF_XET_CACHE:-${HF_HOME}/xet}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${ROOT}/.cache}"
export TMPDIR="${TMPDIR:-${ROOT}/.tmp}"
mkdir -p "$HF_HOME" "$HUGGINGFACE_HUB_CACHE" "$HF_XET_CACHE" "$XDG_CACHE_HOME" "$TMPDIR"
LOGDIR="${ROOT}/setup_logs"
STAMP="$(date +%Y%m%d_%H%M%S)"
LOG="${LOGDIR}/setup_12_ltx23_10eros_msr_complete_v3_${STAMP}.log"

mkdir -p "$ROOT" "$LOGDIR"
exec > >(tee -a "$LOG") 2>&1

echo "============================================================"
echo "[#12 COMPLETE v3] LTX-2.3 + 10Eros v1.5 + Licon MSR V2"
echo "Time: $(date -Is)"
echo "Root: $ROOT"
echo "ComfyUI: $COMFY"
echo "Port: $PORT"
echo "Log: $LOG"
echo "HF_HOME: $HF_HOME"
echo "HF Hub cache: $HUGGINGFACE_HUB_CACHE"
echo "HF Xet cache: $HF_XET_CACHE"
echo "TMPDIR: $TMPDIR"
echo "============================================================"

if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi || true
fi

# ---------- helpers ----------
apt_install_if_missing() {
  local missing=()
  for x in "$@"; do
    command -v "$x" >/dev/null 2>&1 || missing+=("$x")
  done
  if ((${#missing[@]})); then
    echo "[INFO] Installing system packages..."
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y git wget curl ffmpeg python3-venv python3-pip
  fi
}

clone_or_update() {
  local url="$1"
  local dst="$2"
  if [[ -d "$dst/.git" ]]; then
    echo "[GIT] Updating $(basename "$dst")"
    git -C "$dst" fetch --all --prune
    git -C "$dst" pull --ff-only || true
  else
    echo "[GIT] Cloning $url"
    git clone --depth 1 "$url" "$dst"
  fi
}

install_req_if_exists() {
  local dir="$1"
  if [[ -f "$dir/requirements.txt" ]]; then
    echo "[PIP] requirements: $dir"
    "$PY" -m pip install -r "$dir/requirements.txt"
  fi
}

hf_get() {
  local repo="$1"
  local file="$2"
  local destdir="$3"
  local destname="${4:-$(basename "$file")}"
  mkdir -p "$destdir"

  if [[ -s "$destdir/$destname" ]]; then
    echo "[HF] exists: $destdir/$destname"
    return 0
  fi

  echo "[HF] $repo :: $file"
  "$PY" - "$repo" "$file" "$destdir" "$destname" <<'PY'
import os, sys, shutil
from pathlib import Path
from huggingface_hub import hf_hub_download

repo, filename, destdir, destname = sys.argv[1:5]
token = os.environ.get("HF_TOKEN") or None

destdir = Path(destdir)
destdir.mkdir(parents=True, exist_ok=True)

# v2: download onto the target /workspace filesystem directly.
# This avoids first reconstructing a 40+ GB model under /root/.cache.
downloaded = Path(hf_hub_download(
    repo_id=repo,
    filename=filename,
    token=token,
    local_dir=str(destdir),
))

target = destdir / destname
if downloaded.resolve() != target.resolve():
    if target.exists():
        target.unlink()
    try:
        downloaded.replace(target)
    except OSError:
        shutil.move(str(downloaded), str(target))

if not target.exists() or target.stat().st_size <= 1024:
    raise RuntimeError(f"Download failed or file too small: {target}")

print(target)
PY
}

wait_http() {
  local url="$1"
  local tries="${2:-120}"
  local sleep_s="${3:-2}"
  for ((i=1;i<=tries;i++)); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      echo "[OK] HTTP ready: $url"
      return 0
    fi
    if (( i % 10 == 0 )); then
      echo "[WAIT] $url ($i/$tries)"
    fi
    sleep "$sleep_s"
  done
  return 1
}

apt_install_if_missing git wget curl ffmpeg python3

# ---------- fresh isolated environment ----------
if [[ -e "$COMFY" ]]; then
  if [[ "$BACKUP_EXISTING" == "1" ]]; then
    BAK="${COMFY}.backup_${STAMP}"
    echo "[INFO] Existing environment -> $BAK"
    mv "$COMFY" "$BAK"
  else
    echo "[INFO] Removing existing environment: $COMFY"
    rm -rf "$COMFY"
  fi
fi

echo "[1/9] Clone ComfyUI"
git clone --depth 1 https://github.com/Comfy-Org/ComfyUI.git "$COMFY"
cd "$COMFY"

echo "[2/9] Create venv"
python3 -m venv --system-site-packages .venv
PY="$COMFY/.venv/bin/python"
PIP="$COMFY/.venv/bin/pip"

"$PY" -m pip install -U pip wheel "setuptools<82"
"$PY" -m pip install -r requirements.txt
"$PY" -m pip install -U huggingface_hub hf_xet requests pillow

echo "[INFO] Base torch stack (must stay on RunPod/system stack):"
"$PY" - <<'PY'
import torch
print("torch:", torch.__version__)
print("torch file:", torch.__file__)
print("cuda:", torch.version.cuda)
print("cuda available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("gpu:", torch.cuda.get_device_name(0))
PY

mkdir -p \
  custom_nodes \
  models/checkpoints \
  models/loras/LTX-2.3 \
  models/text_encoders \
  models/vae \
  input \
  user/default/workflows

echo "[3/9] Install LTX/MSR custom nodes"
clone_or_update https://github.com/Lightricks/ComfyUI-LTXVideo.git \
  "$COMFY/custom_nodes/ComfyUI-LTXVideo"

clone_or_update https://github.com/liconstudio/ComfyUI-Licon-MSR.git \
  "$COMFY/custom_nodes/ComfyUI-Licon-MSR"

clone_or_update https://github.com/kijai/ComfyUI-KJNodes.git \
  "$COMFY/custom_nodes/ComfyUI-KJNodes"

clone_or_update https://github.com/kijai/ComfyUI-PromptRelay.git \
  "$COMFY/custom_nodes/ComfyUI-PromptRelay"

# Official sample workflow currently contains a Comfyroll helper node.
clone_or_update https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes.git \
  "$COMFY/custom_nodes/ComfyUI_Comfyroll_CustomNodes"

for d in \
  "$COMFY/custom_nodes/ComfyUI-LTXVideo" \
  "$COMFY/custom_nodes/ComfyUI-Licon-MSR" \
  "$COMFY/custom_nodes/ComfyUI-KJNodes" \
  "$COMFY/custom_nodes/ComfyUI-PromptRelay" \
  "$COMFY/custom_nodes/ComfyUI_Comfyroll_CustomNodes"
do
  install_req_if_exists "$d"
done

echo "[FIX] Apply LTXVideo/Kornia 0.8.3 compatibility patch without touching Torch"
"$PY" - "$COMFY/custom_nodes/ComfyUI-LTXVideo/pyramid_blending.py" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

# Latest Kornia no longer exports pad from kornia.geometry.transform.pyramid.
# Upstream LTXVideo PR #551 switches these calls to torch.nn.functional.pad.
if "from kornia.geometry.transform.pyramid import" in s and "pad," in s:
    s = s.replace("    pad,\n", "")
    s = s.replace("    pad,\r\n", "")

# Ensure F alias exists.
if "import torch.nn.functional as F" not in s:
    if "import torch" in s:
        s = s.replace("import torch\n", "import torch\nimport torch.nn.functional as F\n", 1)
    else:
        s = "import torch.nn.functional as F\n" + s

# Replace function calls conservatively.
s = re_sub = s
# Avoid changing identifiers containing 'pad'; only plain calls.
import re
s = re.sub(r"(?<![\w.])pad\(", "F.pad(", s)

p.write_text(s, encoding="utf-8")
print("[OK] patched:", p)
PY

echo "[CHECK] Ensure installing custom-node requirements did not shadow the system Torch"
"$PY" - <<'PY'
import os, sys, torch
print("torch:", torch.__version__)
print("torch file:", torch.__file__)
if "/.venv/" in torch.__file__:
    raise SystemExit(
        "A private Torch was installed inside the venv. "
        "This setup intentionally relies on the RunPod/system Torch stack."
    )
PY

echo "[4/9] Download MSR V2 LoRA + official sample workflow"
hf_get \
  "LiconStudio/LTX-2.3-Multiple-Subject-Reference" \
  "LTX-2.3-Licon-MSR-V2.safetensors" \
  "$COMFY/models/loras/LTX-2.3" \
  "LTX-2.3-Licon-MSR-V2.safetensors"

hf_get \
  "LiconStudio/LTX-2.3-Multiple-Subject-Reference" \
  "LTX-2.3_MSR_sample_workflow_V2.json" \
  "$COMFY/user/default/workflows" \
  "_Licon_MSR_V2_SOURCE.json"

echo "[5/9] Download text encoder"
# Official ComfyUI-repackaged Gemma 3 12B FP4 text encoder used by LTX-2.3.
hf_get \
  "Comfy-Org/ltx-2" \
  "split_files/text_encoders/gemma_3_12B_it_fp4_mixed.safetensors" \
  "$COMFY/models/text_encoders" \
  "gemma_3_12B_it_fp4_mixed.safetensors"

echo "[6/9] Download primary 10Eros v1.5"
echo "[INFO] Workspace disk status before large download:"
df -h "$ROOT" || true

hf_get \
  "TenStrip/LTX2.3-10Eros" \
  "10Eros_v1.5_bf16.safetensors" \
  "$COMFY/models/checkpoints" \
  "10Eros_v1.5_bf16.safetensors"

if [[ "$INSTALL_FP8_FALLBACK" == "1" ]]; then
  echo "[OPTIONAL] Download official LTX-2.3 FP8 fallback (~29 GB)"
  hf_get \
    "Lightricks/LTX-2.3-fp8" \
    "ltx-2.3-22b-dev-fp8.safetensors" \
    "$COMFY/models/checkpoints" \
    "ltx-2.3-22b-dev-fp8.safetensors"
else
  echo "[SKIP] FP8 fallback disabled (INSTALL_FP8_FALLBACK=0)."
fi

echo "[7/9] Create placeholder reference images + patched workflows"
"$PY" - "$COMFY" <<'PY'
import json, os, sys
from pathlib import Path
from PIL import Image, ImageDraw

comfy = Path(sys.argv[1])
wfdir = comfy / "user/default/workflows"
src = wfdir / "_Licon_MSR_V2_SOURCE.json"
inp = comfy / "input"

# Placeholder files prevent missing-file warnings on first workflow load.
labels = [
    ("ref1_identity.png", "REF 1\nIDENTITY"),
    ("ref2_pose.png", "REF 2\nPOSE / ANGLE"),
    ("ref3_detail.png", "REF 3\nDETAIL"),
    ("ref4_object.png", "REF 4\nOBJECT"),
    ("background.png", "BACKGROUND"),
]
for fn, txt in labels:
    p = inp / fn
    im = Image.new("RGB", (768, 768), "white")
    d = ImageDraw.Draw(im)
    d.multiline_text((60, 330), txt, fill="black", spacing=12)
    im.save(p)

base = json.loads(src.read_text(encoding="utf-8"))

def patch_workflow(checkpoint_name, outname):
    j = json.loads(json.dumps(base))
    load_images = []

    for n in j.get("nodes", []):
        t = n.get("type", "")
        w = n.get("widgets_values", [])

        if t == "LowVRAMCheckpointLoader" and w:
            w[0] = checkpoint_name

        elif t == "LTXVAudioVAELoader" and w:
            w[0] = checkpoint_name

        elif t == "LTXAVTextEncoderLoader" and len(w) >= 2:
            w[0] = "gemma_3_12B_it_fp4_mixed.safetensors"
            w[1] = checkpoint_name

        elif t == "LTXICLoRALoaderModelOnly" and w:
            w[0] = "LTX-2.3/LTX-2.3-Licon-MSR-V2.safetensors"
            if len(w) > 1:
                w[1] = 1.0

        elif t == "LoadImage":
            load_images.append(n)
            # Enable all refs in the 4-ref candidate workflow.
            n["mode"] = 0

        # Practical 5090 starting point if these helper nodes are present.
        title = str(n.get("title", "")).lower()
        if t == "INTConstant" and w:
            if title == "length":
                w[0] = 121
        if t == "FloatConstant" and w and title == "fps":
            w[0] = 24

        # Reduce the source sample's very tall default latent if present.
        if t == "EmptyLTXVLatentVideo" and len(w) >= 3:
            w[0] = 768
            w[1] = 1152
            w[2] = 121

        # Give output a recognizable prefix.
        if t == "SaveVideo" and w:
            w[0] = outname.replace(".json", "")

    # Assign deterministic placeholders by visual order from top to bottom.
    load_images.sort(key=lambda n: (n.get("pos", [0, 0])[1], n.get("pos", [0, 0])[0]))
    names = ["ref1_identity.png", "ref2_pose.png", "ref3_detail.png",
             "ref4_object.png", "background.png"]
    for n, fn in zip(load_images[:5], names):
        w = n.setdefault("widgets_values", [])
        if not w:
            w[:] = [fn, "image"]
        else:
            w[0] = fn

    (wfdir / outname).write_text(
        json.dumps(j, ensure_ascii=False, indent=2),
        encoding="utf-8"
    )

patch_workflow(
    "10Eros_v1.5_bf16.safetensors",
    "12A_LTX23_10Eros15_MSR_V2_4REF_5090.json"
)

if (comfy / "models/checkpoints/ltx-2.3-22b-dev-fp8.safetensors").exists():
    patch_workflow(
        "ltx-2.3-22b-dev-fp8.safetensors",
        "12B_LTX23_OFFICIAL_FP8_MSR_V2_TEST.json"
    )

readme = """#12 COMPLETE v3 LTX-2.3 + 10Eros v1.5 + Licon MSR V2

Recommended first test:
  12A_LTX23_10Eros15_MSR_V2_4REF_5090.json

Optional fallback:
  12B_LTX23_OFFICIAL_FP8_MSR_V2_TEST.json
This is created only when INSTALL_FP8_FALLBACK=1.

Reference role suggestion:
  Ref1 = identity / main subject
  Ref2 = another angle / body / pose cues
  Ref3 = clothing / detail / secondary subject
  Ref4 = object reference (e.g. card)
  Background = environment / scene

Before Queue:
  Replace ALL placeholder images with your actual images.
  Start with 2 refs + background if adherence is unstable.
  Add Ref3/Ref4 only when needed.

Important:
  Licon MSR V2 is a real multi-reference workflow.
  10Eros + MSR remains a candidate combination until
  a successful Queue/output test confirms compatibility and quality.

Starting video settings patched by this installer:
  768 x 1152
  121 frames
  24 fps
The sampler/sigma structure is otherwise kept close to the published MSR V2 workflow.
"""
(wfdir / "README_12_LTX23_10EROS_MSR.txt").write_text(readme, encoding="utf-8")

print("[OK] Workflows created:")
for p in sorted(wfdir.glob("12*.json")):
    print(" -", p.name)
PY

echo "[8/9] Create launchers"
cat > "$ROOT/start_ltx23_10eros_msr.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$COMFY"
source .venv/bin/activate
exec python main.py --listen 0.0.0.0 --port "$PORT" --preview-method auto
EOF
chmod +x "$ROOT/start_ltx23_10eros_msr.sh"

cat > "$ROOT/restart_ltx23_10eros_msr.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
pkill -f "$COMFY/main.py" || true
pkill -f "python main.py --listen 0.0.0.0 --port $PORT" || true
sleep 2
exec "$ROOT/start_ltx23_10eros_msr.sh"
EOF
chmod +x "$ROOT/restart_ltx23_10eros_msr.sh"

echo "[9/9] Static checks + start ComfyUI"
"$PY" - <<PY
import json
from pathlib import Path

root = Path("$COMFY")
wfdir = root / "user/default/workflows"

files = ["12A_LTX23_10Eros15_MSR_V2_4REF_5090.json"]
fallback = wfdir / "12B_LTX23_OFFICIAL_FP8_MSR_V2_TEST.json"
if fallback.exists():
    files.append(fallback.name)

for fn in files:
    p = wfdir / fn
    j = json.loads(p.read_text(encoding="utf-8"))
    types = {n.get("type") for n in j.get("nodes", [])}
    assert "LTXICLoRALoaderModelOnly" in types, (fn, "missing MSR LoRA loader")
    assert "LowVRAMCheckpointLoader" in types, (fn, "missing checkpoint loader")
    assert len([n for n in j["nodes"] if n.get("type") == "LoadImage"]) >= 5
    print("[WF OK]", fn)

required = [
    root/"models/checkpoints/10Eros_v1.5_bf16.safetensors",
    root/"models/loras/LTX-2.3/LTX-2.3-Licon-MSR-V2.safetensors",
    root/"models/text_encoders/gemma_3_12B_it_fp4_mixed.safetensors",
]
for p in required:
    assert p.exists() and p.stat().st_size > 1024, p
    print("[MODEL OK]", p.name, f"{p.stat().st_size/1024**3:.2f} GiB")
PY

# Stop anything already on the port that belongs to this fresh run.
pkill -f "$COMFY/main.py" 2>/dev/null || true
sleep 1

SERVER_LOG="${LOGDIR}/comfy_12_ltx23_10eros_msr_complete_v3_${STAMP}.log"
nohup "$ROOT/start_ltx23_10eros_msr.sh" >"$SERVER_LOG" 2>&1 &
PID=$!
echo "$PID" > "$COMFY/comfy.pid"

echo "[INFO] ComfyUI PID: $PID"
echo "[INFO] Server log: $SERVER_LOG"
echo "[INFO] Waiting for /object_info (up to ~5 min)..."

if ! wait_http "http://127.0.0.1:${PORT}/object_info" 150 2; then
  echo
  echo "[ERROR] ComfyUI did not become ready in time."
  echo "------ tail server log ------"
  tail -n 160 "$SERVER_LOG" || true
  exit 1
fi

echo "[INFO] Verify required nodes through /object_info"
"$PY" - "$PORT" <<'PY'
import json, sys, urllib.request

port = sys.argv[1]
with urllib.request.urlopen(f"http://127.0.0.1:{port}/object_info", timeout=30) as r:
    obj = json.load(r)

required = [
    "LowVRAMCheckpointLoader",
    "LTXAVTextEncoderLoader",
    "LTXICLoRALoaderModelOnly",
    "LTXVCropGuides",
    "PromptRelayEncode",
]
missing = [x for x in required if x not in obj]

# Licon node names have changed between revisions; accept either common spelling,
# but print all matching node names for diagnosis.
licon = [k for k in obj if "licon" in k.lower() or "msr" in k.lower()]
print("[INFO] Licon/MSR node candidates:", licon)

if missing:
    raise SystemExit("Missing required nodes: " + ", ".join(missing))
if not licon:
    raise SystemExit("No Licon/MSR custom node found in /object_info")

print("[OK] Required LTX/MSR nodes are loaded.")
PY

echo
echo "============================================================"
echo "[SUCCESS] #12 COMPLETE v3 environment is up."
echo "[INFO] HF/Xet/temp paths are under /workspace; FP8 fallback is optional; Kornia fix is source-patched without replacing Torch."
echo
echo "Open RunPod proxy for port: $PORT"
echo
echo "MAIN workflow:"
echo "  12A_LTX23_10Eros15_MSR_V2_4REF_5090.json"
echo
if [[ "$INSTALL_FP8_FALLBACK" == "1" ]]; then
  echo "Optional fallback workflow:"
  echo "  12B_LTX23_OFFICIAL_FP8_MSR_V2_TEST.json"
  echo
fi
echo
echo "Reference roles:"
echo "  Ref1 = identity"
echo "  Ref2 = pose / another angle"
echo "  Ref3 = detail / clothing / secondary subject"
echo "  Ref4 = object (card etc.)"
echo "  Background = scene"
echo
echo "Launch:"
echo "  $ROOT/start_ltx23_10eros_msr.sh"
echo "Restart:"
echo "  $ROOT/restart_ltx23_10eros_msr.sh"
echo
echo "Setup log:"
echo "  $LOG"
echo "Server log:"
echo "  $SERVER_LOG"
echo "============================================================"
