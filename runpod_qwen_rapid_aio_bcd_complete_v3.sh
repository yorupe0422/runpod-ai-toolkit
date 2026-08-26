#!/usr/bin/env bash
set -euo pipefail

# v3 repair/complete installer for a fresh RunPod.
# Repairs the v2 installation in place if it already exists.
#
# B = Rapid-AIO NSFW v23
# C = B + Qwen-Edit 2511 penis_v2
# D = C + GenatomyFixer
#
# Dedicated environment:
# /workspace/runpod-slim/ComfyUI-QwenRapidBCD

ROOT="${ROOT:-/workspace/runpod-slim}"
BASE="${BASE:-$ROOT/ComfyUI-QwenRapidBCD}"
PORT="${PORT:-8188}"

say(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

mkdir -p "$ROOT"
cd "$ROOT"

say "Checking dedicated ComfyUI"
if [[ ! -f "$BASE/main.py" ]]; then
  say "ComfyUI not found; cloning"
  rm -rf "$BASE"
  git clone --depth 1 https://github.com/Comfy-Org/ComfyUI.git "$BASE"
else
  say "Existing v2 ComfyUI found; repairing it in place"
fi

cd "$BASE"

say "Preparing Python environment without upgrading setuptools past Torch compatibility"
if [[ ! -x "$BASE/.venv/bin/python" ]]; then
  python3 -m venv --system-site-packages "$BASE/.venv"
fi
PY="$BASE/.venv/bin/python"
PIP="$BASE/.venv/bin/pip"

"$PY" -m pip install -q --upgrade pip
# torch 2.11 in this RunPod image requires setuptools < 82.
"$PIP" install -q "setuptools<82" wheel
"$PIP" install -q -r requirements.txt

# The host image contains ms-swift, which requires transformers < 4.53.
# Install a compatible local copy in the venv so it shadows the system dev build.
"$PIP" install -q --upgrade "transformers>=4.51,<4.53" "huggingface_hub>=0.34" hf_xet

say "Installing Rapid-AIO author's fixed TextEncodeQwenImageEditPlus node"
EXTRAS="$BASE/comfy_extras"
TARGET_NODE="$EXTRAS/nodes_qwen_rapid_aio.py"
mkdir -p "$EXTRAS"

# Keep ComfyUI's own nodes_qwen.py untouched. Add the author's node as a separate
# comfy_extras module so it is picked up by ComfyUI's extras loader.
curl -fL --retry 5 --retry-delay 2 \
  "https://huggingface.co/Phr00t/Qwen-Image-Edit-Rapid-AIO/resolve/main/fixed-textencode-node/nodes_qwen.v2.py?download=true" \
  -o "$TARGET_NODE"

grep -q 'node_id="TextEncodeQwenImageEditPlus"' "$TARGET_NODE" \
  || die "Downloaded Rapid-AIO Qwen node does not contain TextEncodeQwenImageEditPlus."

say "Checking that ComfyUI loads the extra Qwen node file"
"$PY" -m py_compile "$TARGET_NODE"

CHECKPOINT_DIR="$BASE/models/checkpoints"
LORA_DIR="$BASE/models/loras"
WF_DIR="$BASE/user/default/workflows"
LOG_DIR="$BASE/user/setup_logs"
mkdir -p "$CHECKPOINT_DIR" "$LORA_DIR" "$WF_DIR" "$LOG_DIR"

LOG="$LOG_DIR/setup_v3_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

hf_download() {
  local repo="$1"
  local remote="$2"
  local target="$3"

  if [[ -s "$target" ]]; then
    say "Already present: $(basename "$target")"
    return
  fi

  say "Downloading: $remote"
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

say "Downloading B checkpoint if necessary"
hf_download \
  "Phr00t/Qwen-Image-Edit-Rapid-AIO" \
  "v23/Qwen-Rapid-AIO-NSFW-v23.safetensors" \
  "$RAPID"

say "Downloading C LoRA if necessary"
hf_download \
  "nnndite/qweneditpenis" \
  "Qwen-Edit 2511_penis_v2.safetensors" \
  "$PENIS"

say "Downloading D fixer if necessary"
hf_download \
  "Zaytron40k/Qwen-Image-GenatomyFixer" \
  "checkpoints/epoch-9.safetensors" \
  "$GENATOMY"

say "Downloading official Rapid-AIO reference workflow"
curl -fL --retry 5 --retry-delay 2 \
  "https://huggingface.co/Phr00t/Qwen-Image-Edit-Rapid-AIO/resolve/main/Qwen-Rapid-AIO.json?download=true" \
  -o "$WF_DIR/Qwen-Rapid-AIO-reference.json"

cat > "$WF_DIR/README_BCD.txt" <<'TXT'
B/C/D comparison
================
B = Qwen-Rapid-AIO-NSFW-v23 only
C = B + Qwen-Edit_2511_penis_v2
D = C + Qwen-Image-GenatomyFixer_epoch-9

Rapid-AIO author's baseline:
- Load Checkpoint
- TextEncodeQwenImageEditPlus
- CFG 1
- 4 steps
- FP8

Start strengths:
C: penis_v2 = 0.70
D: penis_v2 = 0.70, GenatomyFixer = 0.20
Then compare GenatomyFixer 0.20 / 0.30 / 0.40.

Use identical source image, prompt, seed, resolution, sampler and scheduler.
TXT

cat > "$BASE/start_8188.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$BASE"
exec "$PY" main.py --listen 0.0.0.0 --port "$PORT"
EOF
chmod +x "$BASE/start_8188.sh"

say "Dependency versions"
"$PY" - <<'PYCODE'
import torch, transformers, setuptools
print("torch       :", torch.__version__)
print("transformers:", transformers.__version__)
print("setuptools  :", setuptools.__version__)
print("CUDA        :", torch.cuda.is_available())
if torch.cuda.is_available():
    print("GPU         :", torch.cuda.get_device_name(0))
PYCODE

say "Model files"
ls -lh "$RAPID" "$PENIS" "$GENATOMY"

say "Startup smoke test (20 seconds max)"
cd "$BASE"
set +e
timeout 20s "$PY" main.py --listen 127.0.0.1 --port 8197 > "$LOG_DIR/smoke_v3.log" 2>&1
RC=$?
set -e
# timeout=124 is expected if ComfyUI started normally and stayed running.
if [[ "$RC" != "0" && "$RC" != "124" ]]; then
  echo "---- smoke test log ----"
  tail -n 120 "$LOG_DIR/smoke_v3.log"
  die "ComfyUI startup smoke test failed (exit $RC)."
fi
if grep -qiE 'Traceback|IMPORT FAILED|cannot import|ModuleNotFoundError' "$LOG_DIR/smoke_v3.log"; then
  echo "---- smoke test warnings ----"
  grep -iE 'Traceback|IMPORT FAILED|cannot import|ModuleNotFoundError' "$LOG_DIR/smoke_v3.log" | tail -n 80
  die "ComfyUI reported an import failure during smoke test."
fi

cat <<EOF

============================================================
READY — Qwen Rapid-AIO B/C/D v3
============================================================
ComfyUI:
  $BASE

Reference workflow:
  $WF_DIR/Qwen-Rapid-AIO-reference.json

Start:
  $BASE/start_8188.sh

Port:
  $PORT

Setup log:
  $LOG

Smoke log:
  $LOG_DIR/smoke_v3.log
============================================================
EOF
