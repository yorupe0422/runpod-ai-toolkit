#!/usr/bin/env bash
set -Eeuo pipefail

BASE_SCRIPT_URL="https://raw.githubusercontent.com/yorupe0422/runpod-ai-toolkit/main/runpod_ai_setup_v5_complete_v2.sh"
TMP="/tmp/runpod_ai_setup_v5_complete_v2_pinkfix.sh"

echo "================================================================="
echo " SETUP #5 RECOVERY — PinkCherry URL fix"
echo "================================================================="
echo "This resumes the existing COMPLETE v2 setup."
echo "Already SHA-verified H3 models will be skipped."
echo

echo "[1/3] Fetching current SETUP #5 COMPLETE v2..."
curl -fsSL --retry 5 "$BASE_SCRIPT_URL" -o "$TMP"

echo "[2/3] Patching moved PinkCherry repository path..."
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
old = "alpha-0.5-testing"
new = "alpha-0.5-fl2va"

if old not in s:
    raise SystemExit(
        "Expected old PinkCherry path was not found in COMPLETE v2; "
        "the upstream script may already have changed."
    )

s = s.replace(old, new)
p.write_text(s, encoding="utf-8")

# Confirm both the download URL and embedded workflow URL were patched.
count = s.count(new)
if count < 2:
    raise SystemExit(f"PinkCherry path patch incomplete: found {count} new references")

print(f"Patched {count} PinkCherry URL reference(s): {old} -> {new}")
PY

chmod +x "$TMP"

echo "[3/3] Resuming full setup + verification..."
echo "Previously verified large models should show [SKIP verified]."
echo

exec bash "$TMP"
