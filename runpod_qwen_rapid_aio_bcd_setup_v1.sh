#!/usr/bin/env bash
set -euo pipefail

# Qwen Rapid-AIO B/C/D setup
# B: Rapid-AIO NSFW v23
# C: B + Qwen-Edit 2511 penis_v2 LoRA
# D: C + Qwen-Image GenatomyFixer LoRA
# Existing ComfyUI-Qwen2511 is preserved; this script only adds model assets/helpers.

BASE="${BASE:-/workspace/runpod-slim/ComfyUI-Qwen2511}"
PORT="${PORT:-8188}"
CHECKPOINT_DIR="$BASE/models/checkpoints"
LORA_DIR="$BASE/models/loras"
WF_DIR="$BASE/user/default/workflows"
LOG_DIR="$BASE/user/setup_logs"
mkdir -p "$CHECKPOINT_DIR" "$LORA_DIR" "$WF_DIR" "$LOG_DIR"
LOG="$LOG_DIR/rapid_aio_bcd_setup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

say(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail(){ echo "ERROR: $*" >&2; exit 1; }

say "Checking existing Qwen2511 ComfyUI"
[[ -f "$BASE/main.py" ]] || fail "$BASE/main.py not found. This installer intentionally does not replace your existing ComfyUI-Qwen2511 environment."

# Pick the existing Python environment if present.
if [[ -x "$BASE/.venv/bin/python" ]]; then
  PY="$BASE/.venv/bin/python"
elif [[ -x "$BASE/venv/bin/python" ]]; then
  PY="$BASE/venv/bin/python"
else
  PY="$(command -v python3 || true)"
fi
[[ -n "${PY:-}" ]] || fail "python3 not found"

say "Installing/updating Hugging Face downloader only (no ComfyUI package upgrades)"
"$PY" -m pip install -q --upgrade "huggingface_hub>=0.34" hf_xet || true

# Download through huggingface_hub for Xet/LFS reliability and resume support.
hf_download(){
  local repo="$1" remote="$2" target="$3"
  if [[ -s "$target" ]]; then
    say "Already present: $target"
    return 0
  fi
  say "Downloading: $repo :: $remote"
  REPO="$repo" REMOTE="$remote" TARGET="$target" "$PY" - <<'PY'
import os, shutil
from huggingface_hub import hf_hub_download
repo=os.environ['REPO']; remote=os.environ['REMOTE']; target=os.environ['TARGET']
path=hf_hub_download(repo_id=repo, filename=remote, resume_download=True)
os.makedirs(os.path.dirname(target), exist_ok=True)
if os.path.abspath(path) != os.path.abspath(target):
    tmp=target+'.part'
    if os.path.exists(tmp): os.remove(tmp)
    try:
        os.link(path, tmp)
    except Exception:
        shutil.copy2(path, tmp)
    os.replace(tmp, target)
print(target)
PY
}

RAPID="$CHECKPOINT_DIR/Qwen-Rapid-AIO-NSFW-v23.safetensors"
PENIS="$LORA_DIR/Qwen-Edit_2511_penis_v2.safetensors"
GENATOMY="$LORA_DIR/Qwen-Image-GenatomyFixer_epoch-9.safetensors"

hf_download \
  "Phr00t/Qwen-Image-Edit-Rapid-AIO" \
  "v23/Qwen-Rapid-AIO-NSFW-v23.safetensors" \
  "$RAPID"

hf_download \
  "nnndite/qweneditpenis" \
  "Qwen-Edit 2511_penis_v2.safetensors" \
  "$PENIS"

hf_download \
  "Zaytron40k/Qwen-Image-GenatomyFixer" \
  "checkpoints/epoch-9.safetensors" \
  "$GENATOMY"

say "Writing comparison notes"
cat > "$WF_DIR/README_RAPID_AIO_BCD.txt" <<'TXT'
Rapid-AIO NSFW v23 comparison set
=================================

B = Qwen-Rapid-AIO-NSFW-v23.safetensors only
C = B + Qwen-Edit_2511_penis_v2.safetensors
D = C + Qwen-Image-GenatomyFixer_epoch-9.safetensors

Rapid-AIO author baseline:
- Load Checkpoint
- TextEncodeQwenImageEditPlus for image/prompt conditioning
- CFG 1
- 4 steps
- FP8 checkpoint

For a fair B/C/D comparison:
- use the exact same input image
- use the exact same prompt
- use the exact same seed
- use the exact same output size / sampler / scheduler
- only change the LoRA chain

Suggested first comparison strengths (starting points, not guarantees):
B: no external LoRA
C: penis_v2 = 0.70
D: penis_v2 = 0.70, GenatomyFixer = 0.20
Then test GenatomyFixer 0.20 / 0.30 / 0.40 while keeping everything else fixed.

If LoRA stacking reduces overall realism, lower penis_v2 first and keep GenatomyFixer low.
TXT

say "Writing non-destructive launcher"
cat > "$BASE/start_rapid_aio_8188.sh" <<EOF2
#!/usr/bin/env bash
set -e
cd "$BASE"
if [[ -x "$BASE/.venv/bin/python" ]]; then PY="$BASE/.venv/bin/python";
elif [[ -x "$BASE/venv/bin/python" ]]; then PY="$BASE/venv/bin/python";
else PY=python3; fi
exec "\$PY" main.py --listen 0.0.0.0 --port "$PORT"
EOF2
chmod +x "$BASE/start_rapid_aio_8188.sh"

say "Asset verification"
ls -lh "$RAPID" "$PENIS" "$GENATOMY"

cat <<EOF3

============================================================
READY: B/C/D assets installed without replacing ComfyUI-Qwen2511
============================================================
B checkpoint : $RAPID
C LoRA       : $PENIS
D fixer LoRA : $GENATOMY
Notes        : $WF_DIR/README_RAPID_AIO_BCD.txt
Launcher     : $BASE/start_rapid_aio_8188.sh
Log          : $LOG

Start ComfyUI:
  $BASE/start_rapid_aio_8188.sh

Rapid-AIO baseline: CFG=1, steps=4.
============================================================
EOF3
