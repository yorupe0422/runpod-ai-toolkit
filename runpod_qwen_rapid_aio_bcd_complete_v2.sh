#!/usr/bin/env bash
set -euo pipefail

# Standalone fresh-Pod setup for:
# B = Qwen Rapid-AIO NSFW v23
# C = B + Qwen-Edit 2511 penis_v2 LoRA
# D = C + GenatomyFixer LoRA
#
# Creates its own ComfyUI at:
#   /workspace/runpod-slim/ComfyUI-QwenRapidBCD
# Does NOT modify any other ComfyUI installation.

ROOT="${ROOT:-/workspace/runpod-slim}"
BASE="${BASE:-$ROOT/ComfyUI-QwenRapidBCD}"
PORT="${PORT:-8188}"

say(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

mkdir -p "$ROOT"
cd "$ROOT"

say "Preparing standalone ComfyUI"
if [[ ! -f "$BASE/main.py" ]]; then
  if [[ -e "$BASE" ]]; then
    mv "$BASE" "${BASE}.broken.$(date +%Y%m%d_%H%M%S)"
  fi
  git clone --depth 1 https://github.com/Comfy-Org/ComfyUI.git "$BASE"
else
  say "Existing standalone installation found; keeping it"
fi

cd "$BASE"

say "Preparing Python environment"
if [[ ! -x "$BASE/.venv/bin/python" ]]; then
  python3 -m venv --system-site-packages "$BASE/.venv"
fi
PY="$BASE/.venv/bin/python"
PIP="$BASE/.venv/bin/pip"

"$PY" -m pip install -q --upgrade pip setuptools wheel
# Keep the host CUDA/PyTorch stack intact; install ComfyUI's Python deps around it.
"$PIP" install -q -r requirements.txt
"$PIP" install -q --upgrade "huggingface_hub>=0.34" hf_xet

say "Verifying Qwen Image Edit core node exists"
if ! grep -Rqs "TextEncodeQwenImageEditPlus" "$BASE/comfy" "$BASE/nodes.py" 2>/dev/null; then
  say "Core node not found in this checkout; updating ComfyUI once"
  git -C "$BASE" pull --ff-only
  "$PIP" install -q -r requirements.txt
fi
grep -Rqs "TextEncodeQwenImageEditPlus" "$BASE/comfy" "$BASE/nodes.py" 2>/dev/null \
  || die "TextEncodeQwenImageEditPlus is still missing from ComfyUI core."

CHECKPOINT_DIR="$BASE/models/checkpoints"
LORA_DIR="$BASE/models/loras"
WF_DIR="$BASE/user/default/workflows"
LOG_DIR="$BASE/user/setup_logs"
mkdir -p "$CHECKPOINT_DIR" "$LORA_DIR" "$WF_DIR" "$LOG_DIR"

LOG="$LOG_DIR/setup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

hf_download() {
  local repo="$1"
  local remote="$2"
  local target="$3"

  if [[ -s "$target" ]]; then
    say "Already present: $target"
    return
  fi

  say "Downloading $remote"
  REPO="$repo" REMOTE="$remote" TARGET="$target" "$PY" - <<'PYCODE'
import os, shutil
from huggingface_hub import hf_hub_download

repo = os.environ["REPO"]
remote = os.environ["REMOTE"]
target = os.environ["TARGET"]

src = hf_hub_download(repo_id=repo, filename=remote)
os.makedirs(os.path.dirname(target), exist_ok=True)

tmp = target + ".part"
if os.path.exists(tmp):
    os.remove(tmp)

try:
    os.link(src, tmp)
except Exception:
    shutil.copy2(src, tmp)

os.replace(tmp, target)
print("Saved:", target)
PYCODE
}

RAPID="$CHECKPOINT_DIR/Qwen-Rapid-AIO-NSFW-v23.safetensors"
PENIS="$LORA_DIR/Qwen-Edit_2511_penis_v2.safetensors"
GENATOMY="$LORA_DIR/Qwen-Image-GenatomyFixer_epoch-9.safetensors"

say "Downloading B checkpoint (~28 GB)"
hf_download \
  "Phr00t/Qwen-Image-Edit-Rapid-AIO" \
  "v23/Qwen-Rapid-AIO-NSFW-v23.safetensors" \
  "$RAPID"

say "Downloading C LoRA"
hf_download \
  "nnndite/qweneditpenis" \
  "Qwen-Edit 2511_penis_v2.safetensors" \
  "$PENIS"

say "Downloading D fixer LoRA"
hf_download \
  "Zaytron40k/Qwen-Image-GenatomyFixer" \
  "checkpoints/epoch-9.safetensors" \
  "$GENATOMY"

cat > "$WF_DIR/README_RAPID_AIO_BCD.txt" <<'TXT'
Rapid-AIO B/C/D comparison
==========================

B:
  Qwen-Rapid-AIO-NSFW-v23.safetensors only

C:
  B + Qwen-Edit_2511_penis_v2.safetensors

D:
  C + Qwen-Image-GenatomyFixer_epoch-9.safetensors

Rapid-AIO v23 baseline:
  Load Checkpoint
  TextEncodeQwenImageEditPlus
  CFG = 1
  Steps = 4
  FP8 checkpoint

Fair comparison:
  same source image
  same prompt
  same seed
  same resolution
  same sampler/scheduler
  only change the LoRA chain

Initial strength suggestions:
  C: penis_v2 = 0.70
  D: penis_v2 = 0.70 + GenatomyFixer = 0.20

Then test GenatomyFixer:
  0.20 / 0.30 / 0.40
TXT

cat > "$BASE/start_8188.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$BASE"
exec "$PY" main.py --listen 0.0.0.0 --port "$PORT"
EOF
chmod +x "$BASE/start_8188.sh"

say "Model verification"
ls -lh "$RAPID" "$PENIS" "$GENATOMY"

say "ComfyUI import smoke test"
"$PY" - <<'PYCODE'
import sys
sys.path.insert(0, ".")
import torch
print("Python OK")
print("Torch:", torch.__version__)
print("CUDA available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))
PYCODE

cat <<EOF

============================================================
READY — standalone Qwen Rapid-AIO B/C/D environment
============================================================
ComfyUI:
  $BASE

B checkpoint:
  $RAPID

C LoRA:
  $PENIS

D fixer:
  $GENATOMY

Start:
  $BASE/start_8188.sh

Open RunPod port:
  8188

Log:
  $LOG
============================================================
EOF
