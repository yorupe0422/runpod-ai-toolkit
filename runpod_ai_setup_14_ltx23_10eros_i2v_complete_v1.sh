#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# #14 LTX-2.3 + 10Eros v1.5 I2V / First-Frame HQ (COMPLETE v1)
# Fresh isolated RunPod / ComfyUI environment
#
# Purpose:
#   MiniMax (or another image model) creates the finished MASTER still image
#       -> #14 uses that single image as FIRST FRAME
#       -> LTX-2.3 / 10Eros animates it as I2V
#
# Main stack:
#   - 10Eros v1.5 BF16
#   - TenStrip 10S Nodes
#   - TenStrip Basic DMD V5 I2V workflow as source
#   - LTX2.3_DMD_hybrid_v2 LoRA
#   - LTX-2.3 x2 spatial latent upscaler v1.1
#   - Gemma 3 12B FP4 mixed text encoder
#
# Target:
#   - RTX 5090 class GPU / 32GB VRAM
#   - Port 8188
#   - Quality-first, not speed-first
#
# Environment:
#   /workspace/runpod-slim/ComfyUI-LTX23-10Eros-I2V
#
# Notes:
#   * This is intentionally separate from #12 MSR.
#   * No multi-reference merge here. Feed ONE completed image as First Frame.
#   * Hugging Face/Xet/temp cache stays under /workspace.
#   * Do NOT replace RunPod/system Torch. We keep the known-good base stack.
#   * 10S Nodes are cloned directly from GitHub, not Manager, to avoid stale registry versions.
# ============================================================

ROOT="/workspace/runpod-slim"
COMFY="${ROOT}/ComfyUI-LTX23-10Eros-I2V"
PORT="${PORT:-8188}"
BACKUP_EXISTING="${BACKUP_EXISTING:-0}"
INSTALL_TEMPORAL_UPSCALER="${INSTALL_TEMPORAL_UPSCALER:-0}"

export HF_HOME="${HF_HOME:-${ROOT}/.cache/huggingface}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-${HF_HOME}/hub}"
export HF_XET_CACHE="${HF_XET_CACHE:-${HF_HOME}/xet}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${ROOT}/.cache}"
export TMPDIR="${TMPDIR:-${ROOT}/.tmp}"

mkdir -p "$ROOT" "$HF_HOME" "$HUGGINGFACE_HUB_CACHE" "$HF_XET_CACHE" "$XDG_CACHE_HOME" "$TMPDIR"

LOGDIR="${ROOT}/setup_logs"
STAMP="$(date +%Y%m%d_%H%M%S)"
LOG="${LOGDIR}/setup_14_ltx23_10eros_i2v_complete_v1_${STAMP}.log"
mkdir -p "$LOGDIR"
exec > >(tee -a "$LOG") 2>&1

echo "============================================================"
echo "[#14 COMPLETE v1] LTX-2.3 + 10Eros v1.5 First-Frame I2V"
echo "Time: $(date -Is)"
echo "Root: $ROOT"
echo "ComfyUI: $COMFY"
echo "Port: $PORT"
echo "Log: $LOG"
echo "HF_HOME: $HF_HOME"
echo "TMPDIR: $TMPDIR"
echo "============================================================"

command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi || true

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
apt_install_if_missing() {
  local need=0
  for x in git wget curl ffmpeg python3; do
    command -v "$x" >/dev/null 2>&1 || need=1
  done
  if [[ "$need" == "1" ]]; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      git wget curl ffmpeg python3 python3-venv python3-pip
  fi
}

clone_or_update() {
  local url="$1"
  local dst="$2"
  if [[ -d "$dst/.git" ]]; then
    echo "[GIT] update: $(basename "$dst")"
    git -C "$dst" fetch --all --prune
    git -C "$dst" reset --hard origin/HEAD || git -C "$dst" pull --ff-only || true
  else
    echo "[GIT] clone: $url"
    git clone --depth 1 "$url" "$dst"
  fi
}

install_req_if_exists() {
  local d="$1"
  if [[ -f "$d/requirements.txt" ]]; then
    echo "[PIP] requirements: $d"
    "$PY" -m pip install -r "$d/requirements.txt"
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

# local_dir is deliberately /workspace so 40+ GB files are never reconstructed
# under /root/.cache.
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
  local tries="${2:-150}"
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

apt_install_if_missing

# ------------------------------------------------------------
# Fresh isolated environment
# ------------------------------------------------------------
if [[ -e "$COMFY" ]]; then
  if [[ "$BACKUP_EXISTING" == "1" ]]; then
    BAK="${COMFY}.backup_${STAMP}"
    echo "[INFO] Existing environment -> $BAK"
    mv "$COMFY" "$BAK"
  else
    echo "[INFO] Removing existing #14 environment: $COMFY"
    rm -rf "$COMFY"
  fi
fi

echo "[1/10] Clone ComfyUI"
git clone --depth 1 https://github.com/Comfy-Org/ComfyUI.git "$COMFY"
cd "$COMFY"

echo "[2/10] Create venv on top of RunPod/system Torch"
python3 -m venv --system-site-packages .venv
PY="$COMFY/.venv/bin/python"
"$PY" -m pip install -U pip wheel "setuptools<82"
"$PY" -m pip install -r requirements.txt
"$PY" -m pip install -U huggingface_hub hf_xet requests pillow

echo "[INFO] Base Torch stack:"
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
  models/loras \
  models/text_encoders \
  models/latent_upscale_models \
  input \
  output \
  user/default/workflows

# ------------------------------------------------------------
# Custom nodes
# ------------------------------------------------------------
echo "[3/10] Install LTX / 10Eros workflow custom nodes"

clone_or_update https://github.com/Lightricks/ComfyUI-LTXVideo.git \
  "$COMFY/custom_nodes/ComfyUI-LTXVideo"

# IMPORTANT: direct GitHub clone. TenStrip has warned that Manager/registry may lag.
clone_or_update https://github.com/TenStrip/10S-Comfy-nodes.git \
  "$COMFY/custom_nodes/10S_Nodes"

clone_or_update https://github.com/chrisgoringe/cg-sigmas.git \
  "$COMFY/custom_nodes/cg-sigmas"

clone_or_update https://github.com/kijai/ComfyUI-KJNodes.git \
  "$COMFY/custom_nodes/ComfyUI-KJNodes"

clone_or_update https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git \
  "$COMFY/custom_nodes/ComfyUI-VideoHelperSuite"

clone_or_update https://github.com/cubiq/ComfyUI_essentials.git \
  "$COMFY/custom_nodes/ComfyUI_essentials"

# Small compatibility/helper pack used by several public LTX workflows.
clone_or_update https://github.com/kijai/ComfyUI-PromptRelay.git \
  "$COMFY/custom_nodes/ComfyUI-PromptRelay"

for d in \
  "$COMFY/custom_nodes/ComfyUI-LTXVideo" \
  "$COMFY/custom_nodes/10S_Nodes" \
  "$COMFY/custom_nodes/cg-sigmas" \
  "$COMFY/custom_nodes/ComfyUI-KJNodes" \
  "$COMFY/custom_nodes/ComfyUI-VideoHelperSuite" \
  "$COMFY/custom_nodes/ComfyUI_essentials" \
  "$COMFY/custom_nodes/ComfyUI-PromptRelay"
do
  install_req_if_exists "$d"
done

# Same Kornia compatibility repair that made #12 stable.
echo "[FIX] LTXVideo / Kornia pad compatibility without replacing Torch"
"$PY" - "$COMFY/custom_nodes/ComfyUI-LTXVideo/pyramid_blending.py" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
if not p.exists():
    print("[INFO] pyramid_blending.py not present; patch not needed.")
    raise SystemExit(0)

s = p.read_text(encoding="utf-8")
if "from kornia.geometry.transform.pyramid import" in s:
    s = s.replace("    pad,\n", "").replace("    pad,\r\n", "")
if "import torch.nn.functional as F" not in s:
    if "import torch\n" in s:
        s = s.replace("import torch\n", "import torch\nimport torch.nn.functional as F\n", 1)
    else:
        s = "import torch.nn.functional as F\n" + s
s = re.sub(r"(?<![\w.])pad\(", "F.pad(", s)
p.write_text(s, encoding="utf-8")
print("[OK] patched:", p)
PY

echo "[CHECK] Custom-node installation must NOT shadow RunPod Torch"
"$PY" - <<'PY'
import torch
print("torch:", torch.__version__)
print("torch file:", torch.__file__)
if "/.venv/" in torch.__file__:
    raise SystemExit(
        "ERROR: custom-node requirements installed a private Torch inside .venv. "
        "Abort instead of silently changing the known-good RunPod Torch stack."
    )
PY

# ------------------------------------------------------------
# Workflow + models
# ------------------------------------------------------------
echo "[4/10] Download TenStrip Basic DMD V5 I2V workflow"
hf_get \
  "TenStrip/LTX2.3-10Eros_Workflows" \
  "10Eros_10SNodes_I2V_Basic_DMD_V5.json" \
  "$COMFY/user/default/workflows" \
  "_10Eros_I2V_Basic_DMD_V5_SOURCE.json"

echo "[5/10] Download Gemma text encoder"
hf_get \
  "Comfy-Org/ltx-2" \
  "split_files/text_encoders/gemma_3_12B_it_fp4_mixed.safetensors" \
  "$COMFY/models/text_encoders" \
  "gemma_3_12B_it_fp4_mixed.safetensors"

echo "[6/10] Download 10Eros v1.5 BF16"
echo "[INFO] Workspace disk status before large download:"
df -h "$ROOT" || true

hf_get \
  "TenStrip/LTX2.3-10Eros" \
  "10Eros_v1.5_bf16.safetensors" \
  "$COMFY/models/checkpoints" \
  "10Eros_v1.5_bf16.safetensors"

echo "[7/10] Download DMD hybrid v2 + LTX-2.3 spatial upscaler"
hf_get \
  "TenStrip/LTX2.3_DMD_Lora" \
  "LTX2.3_DMD_hybrid_v2.safetensors" \
  "$COMFY/models/loras" \
  "LTX2.3_DMD_hybrid_v2.safetensors"

hf_get \
  "Lightricks/LTX-2.3" \
  "ltx-2.3-spatial-upscaler-x2-1.1.safetensors" \
  "$COMFY/models/latent_upscale_models" \
  "ltx-2.3-spatial-upscaler-x2-1.1.safetensors"

if [[ "$INSTALL_TEMPORAL_UPSCALER" == "1" ]]; then
  echo "[OPTIONAL] Download x2 temporal upscaler"
  hf_get \
    "Lightricks/LTX-2.3" \
    "ltx-2.3-temporal-upscaler-x2-1.0.safetensors" \
    "$COMFY/models/latent_upscale_models" \
    "ltx-2.3-temporal-upscaler-x2-1.0.safetensors"
else
  echo "[SKIP] Temporal upscaler disabled (INSTALL_TEMPORAL_UPSCALER=0)."
fi

# ------------------------------------------------------------
# Patch published workflow into a stable #14 copy
# ------------------------------------------------------------
echo "[8/10] Create #14 workflow + placeholder First Frame"
"$PY" - "$COMFY" <<'PY'
import json, re, sys
from pathlib import Path
from PIL import Image, ImageDraw

comfy = Path(sys.argv[1])
wfdir = comfy / "user/default/workflows"
src = wfdir / "_10Eros_I2V_Basic_DMD_V5_SOURCE.json"
dst = wfdir / "14A_LTX23_10Eros15_I2V_DMDV5_HQ_5090.json"
inp = comfy / "input"

# Friendly placeholder so the workflow opens without a red missing-image field.
ph = inp / "FIRST_FRAME_REPLACE_ME.png"
im = Image.new("RGB", (1024, 576), "white")
d = ImageDraw.Draw(im)
d.multiline_text(
    (60, 220),
    "FIRST FRAME\nReplace this with the MASTER image\ncreated by MiniMax",
    fill="black",
    spacing=12,
)
im.save(ph)

j = json.loads(src.read_text(encoding="utf-8"))

def patch_string(s: str) -> str:
    low = s.lower()

    # 10Eros checkpoint: point every older 10Eros checkpoint widget to v1.5 BF16.
    if s.endswith(".safetensors") and "10eros" in low:
        return "10Eros_v1.5_bf16.safetensors"

    # TenStrip DMD LoRA: use current hybrid v2.
    if s.endswith(".safetensors") and "dmd" in low:
        return "LTX2.3_DMD_hybrid_v2.safetensors"

    # Current official x2 spatial upscaler hotfix.
    if s.endswith(".safetensors") and "spatial-upscaler" in low:
        return "ltx-2.3-spatial-upscaler-x2-1.1.safetensors"

    # Comfy-repacked Gemma used successfully in #12.
    if s.endswith(".safetensors") and "gemma" in low:
        return "gemma_3_12B_it_fp4_mixed.safetensors"

    return s

def walk(x):
    if isinstance(x, dict):
        return {k: walk(v) for k, v in x.items()}
    if isinstance(x, list):
        return [walk(v) for v in x]
    if isinstance(x, str):
        return patch_string(x)
    return x

j = walk(j)

# Patch the first LoadImage-like node to our placeholder. We intentionally only
# touch the first image loader because #14 is a single First-Frame I2V workflow.
patched_image = False
for n in j.get("nodes", []):
    t = str(n.get("type", "")).lower()
    if not patched_image and ("loadimage" in t or t == "load image"):
        w = n.get("widgets_values")
        if isinstance(w, list) and w:
            w[0] = "FIRST_FRAME_REPLACE_ME.png"
            patched_image = True

# Add an identifying title where safe.
for n in j.get("nodes", []):
    if n.get("type") == "MarkdownNote":
        vals = n.get("widgets_values")
        if isinstance(vals, list) and vals:
            text = str(vals[0])
            if "#14" not in text:
                vals[0] = (
                    "#14 LTX-2.3 / 10Eros v1.5 — First-Frame I2V\n\n"
                    "Recommended chain: MiniMax MASTER still → this workflow.\n"
                    "Main LoRA: LTX2.3_DMD_hybrid_v2.\n\n" + text
                )
            break

dst.write_text(json.dumps(j, ensure_ascii=False, indent=2), encoding="utf-8")
print("[OK] workflow:", dst)
print("[INFO] placeholder LoadImage patched:", patched_image)

# Static diagnostics: print all referenced safetensors strings.
refs = set()
def collect(x):
    if isinstance(x, dict):
        for v in x.values(): collect(v)
    elif isinstance(x, list):
        for v in x: collect(v)
    elif isinstance(x, str) and x.endswith(".safetensors"):
        refs.add(x)
collect(j)

print("[INFO] safetensors referenced by patched workflow:")
for r in sorted(refs):
    print("  -", r)
PY

# ------------------------------------------------------------
# Launchers
# ------------------------------------------------------------
echo "[9/10] Create launch / restart scripts"

cat > "$ROOT/start_ltx23_10eros_i2v.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$ROOT"
COMFY="$COMFY"
PORT="\${PORT:-$PORT}"

export HF_HOME="\${HF_HOME:-\$ROOT/.cache/huggingface}"
export HUGGINGFACE_HUB_CACHE="\${HUGGINGFACE_HUB_CACHE:-\$HF_HOME/hub}"
export HF_XET_CACHE="\${HF_XET_CACHE:-\$HF_HOME/xet}"
export XDG_CACHE_HOME="\${XDG_CACHE_HOME:-\$ROOT/.cache}"
export TMPDIR="\${TMPDIR:-\$ROOT/.tmp}"
mkdir -p "\$HF_HOME" "\$HUGGINGFACE_HUB_CACHE" "\$HF_XET_CACHE" "\$XDG_CACHE_HOME" "\$TMPDIR"

cd "\$COMFY"
source .venv/bin/activate
exec python main.py --listen 0.0.0.0 --port "\$PORT" --preview-method auto
EOF
chmod +x "$ROOT/start_ltx23_10eros_i2v.sh"

cat > "$ROOT/restart_ltx23_10eros_i2v.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
PORT="\${PORT:-$PORT}"
pkill -f "python.*main.py.*--port[ =]\${PORT}" 2>/dev/null || true
pkill -f "$COMFY/main.py" 2>/dev/null || true
if command -v fuser >/dev/null 2>&1; then
  fuser -k "\${PORT}/tcp" 2>/dev/null || true
fi
sleep 3
exec "$ROOT/start_ltx23_10eros_i2v.sh"
EOF
chmod +x "$ROOT/restart_ltx23_10eros_i2v.sh"

# ------------------------------------------------------------
# Static checks + clean server smoke test
# ------------------------------------------------------------
echo "[10/10] Static checks + clean ComfyUI smoke test"

"$PY" - "$COMFY" <<'PY'
from pathlib import Path
import json, sys

root = Path(sys.argv[1])
checks = [
    root/"models/checkpoints/10Eros_v1.5_bf16.safetensors",
    root/"models/loras/LTX2.3_DMD_hybrid_v2.safetensors",
    root/"models/text_encoders/gemma_3_12B_it_fp4_mixed.safetensors",
    root/"models/latent_upscale_models/ltx-2.3-spatial-upscaler-x2-1.1.safetensors",
    root/"user/default/workflows/14A_LTX23_10Eros15_I2V_DMDV5_HQ_5090.json",
]
for p in checks:
    if not p.exists() or p.stat().st_size <= 1024:
        raise SystemExit(f"[FAIL] missing/small: {p}")
    gib = p.stat().st_size/(1024**3)
    print(f"[OK] {p.name}: {gib:.2f} GiB" if gib > 0.01 else f"[OK] {p.name}")

wf = json.loads(checks[-1].read_text(encoding="utf-8"))
blob = json.dumps(wf, ensure_ascii=False)
for needed in [
    "10Eros_v1.5_bf16.safetensors",
    "LTX2.3_DMD_hybrid_v2.safetensors",
]:
    if needed not in blob:
        print(f"[WARN] workflow does not explicitly reference {needed}; inspect loader widgets after first open.")
PY

echo "[PORT] Clearing stale ComfyUI listener on $PORT"
pkill -f "python.*main.py.*--port[ =]${PORT}" 2>/dev/null || true
pkill -f "$COMFY/main.py" 2>/dev/null || true
if command -v fuser >/dev/null 2>&1; then
  fuser -k "${PORT}/tcp" 2>/dev/null || true
fi
sleep 3

SERVER_LOG="${LOGDIR}/comfy_14_ltx23_10eros_i2v_complete_v1_${STAMP}.log"
cd "$COMFY"
nohup "$PY" main.py \
  --listen 0.0.0.0 \
  --port "$PORT" \
  --preview-method auto \
  > "$SERVER_LOG" 2>&1 &
PID=$!

echo "[INFO] ComfyUI PID: $PID"
echo "[INFO] Server log: $SERVER_LOG"
echo "[INFO] Waiting for /object_info (up to ~5 min)..."

if ! wait_http "http://127.0.0.1:${PORT}/object_info" 150 2; then
  echo "[FAIL] ComfyUI did not become ready."
  tail -160 "$SERVER_LOG" || true
  exit 1
fi

if ! kill -0 "$PID" >/dev/null 2>&1; then
  echo "[FAIL] New #14 ComfyUI process died; another process may own port $PORT."
  tail -160 "$SERVER_LOG" || true
  exit 1
fi

CMDLINE="$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null || true)"
echo "[INFO] PID cmdline: $CMDLINE"
if [[ "$CMDLINE" != *"main.py"* || "$CMDLINE" != *"--port $PORT"* ]]; then
  echo "[FAIL] PID $PID is not the intended #14 launch."
  exit 1
fi
echo "[OK] Verified new #14 ComfyUI PID $PID owns the intended launch command."

echo "[CHECK] 10S Nodes import"
if grep -qiE "10S[_ -]?Nodes|10S-Comfy|10S_Nodes" "$SERVER_LOG"; then
  echo "[OK] 10S Nodes import appears in server log."
else
  echo "[WARN] Could not confirm 10S import by text; checking /object_info next."
fi

"$PY" - "$PORT" "$COMFY/user/default/workflows/14A_LTX23_10Eros15_I2V_DMDV5_HQ_5090.json" <<'PY'
import json, sys, urllib.request
from pathlib import Path

port = sys.argv[1]
wfpath = Path(sys.argv[2])
with urllib.request.urlopen(f"http://127.0.0.1:{port}/object_info", timeout=30) as r:
    obj = json.load(r)
keys = set(obj.keys())

wf = json.loads(wfpath.read_text(encoding="utf-8"))
types = {str(n.get("type")) for n in wf.get("nodes", []) if n.get("type")}

# UI-only / virtual node types that need not appear in /object_info.
ignore = {
    "MarkdownNote", "Note", "Reroute", "PrimitiveNode", "Primitive",
    "Load3D", "SetNode", "GetNode",
}
missing = sorted(t for t in types if t not in keys and t not in ignore)

ten_s = sorted(k for k in keys if any(x in k.lower() for x in ("tiled", "anchor", "reference", "reinforcer")))
print("[INFO] Relevant loaded node candidates:", ten_s[:40])

if missing:
    print("[WARN] Workflow node types not found in /object_info:")
    for x in missing:
        print("  -", x)
    print("[WARN] Workflow may still contain frontend/group/virtual nodes. Open it once and check red nodes.")
else:
    print("[OK] All non-UI workflow node types found in /object_info.")
PY

echo
echo "============================================================"
echo "[SUCCESS] #14 COMPLETE v1 environment is up."
echo
echo "Open RunPod proxy for port: $PORT"
echo
echo "MAIN workflow:"
echo "  14A_LTX23_10Eros15_I2V_DMDV5_HQ_5090.json"
echo
echo "Use:"
echo "  1) Make the finished MASTER still in MiniMax."
echo "  2) Load that ONE image into the First Frame / Load Image node."
echo "  3) Describe motion, camera behavior, dialogue/audio."
echo "  4) Keep DMD hybrid v2 as the main quality/motion LoRA baseline."
echo "  5) Use the second/upscale pass for final clarity."
echo
echo "Environment:"
echo "  $COMFY"
echo
echo "Launch:"
echo "  $ROOT/start_ltx23_10eros_i2v.sh"
echo "Restart:"
echo "  $ROOT/restart_ltx23_10eros_i2v.sh"
echo
echo "Setup log:"
echo "  $LOG"
echo "Server log:"
echo "  $SERVER_LOG"
echo "============================================================"
