#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# FastH3 VSA COMPLETE + STEP1900 UPDATE v6
#
# Works on BOTH:
#   A) brand-new RunPod (no ComfyUI-FastH3 yet)
#   B) existing FastH3 environment
#
# Behavior:
# - If FastH3 env is missing:
#     downloads/runs saved complete v4 first
# - Then:
#     downloads/runs Step1900 probe/update v5
#
# Root:
#   /workspace/runpod-slim/ComfyUI-FastH3
#
# Requires these files to exist in the user's GitHub main branch:
#   runpod_fast_h3_vsa_saved_complete_v4.sh
#   runpod_fast_h3_vsa_update_step1900_probe_v5.sh
# ============================================================

BASE="/workspace/runpod-slim"
ROOT="$BASE/ComfyUI-FastH3"
GITHUB_RAW="https://raw.githubusercontent.com/yorupe0422/runpod-ai-toolkit/main"

V4="runpod_fast_h3_vsa_saved_complete_v4.sh"
V5="runpod_fast_h3_vsa_update_step1900_probe_v5.sh"

mkdir -p "$BASE"
cd "$BASE"

echo "============================================================"
echo " FastH3 VSA COMPLETE + STEP1900 UPDATE v6"
echo " ROOT: $ROOT"
echo "============================================================"

download_script () {
  local name="$1"
  echo "[DOWNLOAD] $name"
  wget -q --show-progress -O "$name" "$GITHUB_RAW/$name"
  chmod +x "$name"
}

# ------------------------------------------------------------
# 1. Bootstrap the FastH3 environment when this is a fresh Pod
# ------------------------------------------------------------
if [[ ! -d "$ROOT/.git" || ! -x "$ROOT/.venv/bin/python" ]]; then
  echo
  echo "[BOOTSTRAP] FastH3 environment is not installed on this Pod."
  echo "[BOOTSTRAP] Running saved-complete v4 first."

  download_script "$V4"

  "./$V4"

  if [[ ! -d "$ROOT/.git" || ! -x "$ROOT/.venv/bin/python" ]]; then
    echo "[ERROR] v4 finished but the FastH3 environment is still incomplete."
    echo "Expected:"
    echo "  $ROOT/.git"
    echo "  $ROOT/.venv/bin/python"
    exit 1
  fi

  echo
  echo "[BOOTSTRAP] FastH3 base environment is ready."
else
  echo
  echo "[FOUND] Existing FastH3 environment detected."
  echo "[FOUND] Skipping v4 bootstrap."
fi

# ------------------------------------------------------------
# 2. Apply current Step1900 probe/update
# ------------------------------------------------------------
echo
echo "[UPDATE] Applying Step1900 probe/update v5."

download_script "$V5"
"./$V5"

echo
echo "============================================================"
echo "[SUCCESS] FastH3 complete/update v6 finished."
echo
echo "Environment:"
echo "  $ROOT"
echo
echo "Main workflow:"
echo "  $ROOT/user/default/workflows/FastH3_VSA_10step_MAIN_DataFree1300_5090.json"
echo
echo "Step1900 status:"
echo "  $ROOT/user/default/workflows/STEP1900_STATUS.txt"
echo
echo "If a converted Step1900 model was found:"
echo "  $ROOT/user/default/workflows/FastH3_VSA_10step_Synthetic1900_ALT_5090.json"
echo "============================================================"
