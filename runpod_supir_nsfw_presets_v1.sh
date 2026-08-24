#!/usr/bin/env bash
set -Eeuo pipefail

COMFY="${COMFY:-/workspace/runpod-slim/ComfyUI}"
WF_DIR="$COMFY/user/default/workflows"

STRONG_WF="$WF_DIR/Adult_NSFW_Strong_SUPIR_v1.json"
SAFE_WF="$WF_DIR/Adult_NSFW_Detail_Safe_SUPIR_v1.json"

echo "============================================================"
echo " SUPIR NSFW preset workflows v1"
echo " - Adds 2 preset workflows to the current ComfyUI"
echo " - Does NOT reinstall or replace ComfyUI"
echo " - Uses your existing working SUPIR workflow as the source"
echo "============================================================"

[[ -d "$WF_DIR" ]] || { echo "[ERROR] Workflow dir not found: $WF_DIR"; exit 1; }

# Pick a source SUPIR workflow that already works in this environment.
SRC_WF="$(find "$WF_DIR" -maxdepth 1 -type f -iname '*supir*.json' \
  ! -iname 'Adult_NSFW_Strong_SUPIR_v1.json' \
  ! -iname 'Adult_NSFW_Detail_Safe_SUPIR_v1.json' \
  | head -n 1 || true)"

if [[ -z "${SRC_WF:-}" ]]; then
  echo "[ERROR] No source SUPIR workflow JSON was found in:"
  echo "  $WF_DIR"
  echo
  echo "Please save your currently working SUPIR workflow into that folder first,"
  echo "then run this script again."
  exit 1
fi

echo "[1/3] Source workflow:"
echo "  $SRC_WF"

cp -f "$SRC_WF" "$STRONG_WF"
cp -f "$SRC_WF" "$SAFE_WF"

echo "[2/3] Patching Strong / Detail-Safe presets..."
python3 - "$STRONG_WF" "$SAFE_WF" <<'PY'
import json, sys
from pathlib import Path

strong_path = Path(sys.argv[1])
safe_path = Path(sys.argv[2])

POS_STRONG = (
    "adult realistic photo, high quality detailed smartphone photo, "
    "preserve the same person, preserve exact pose, preserve body proportions, "
    "preserve adult anatomy, natural skin texture, clean fine detail, clear focus, "
    "realistic lighting, detailed hair, natural photographic look"
)

NEG_COMMON = (
    "child, young-looking, underage, illustration, anime, cartoon, cgi, plastic skin, "
    "waxy skin, oversmoothed skin, oversharpened, deformed anatomy, malformed hands, "
    "malformed feet, extra fingers, missing fingers, fused fingers, extra toes, missing toes, "
    "distorted limbs, blurry, motion blur, compression artifacts, jpeg artifacts, watermark, text"
)

POS_SAFE = (
    "adult realistic photo, preserve the same person, preserve exact pose, preserve exact anatomy, "
    "preserve exact hands and fingers, preserve exact feet and toes, preserve body proportions, "
    "natural skin texture, clear focus, realistic lighting, clean detail, natural photographic look"
)

def visit(obj):
    if isinstance(obj, dict):
        yield obj
        for v in obj.values():
            yield from visit(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from visit(v)

def patch(path: Path, kind: str):
    data = json.loads(path.read_text(encoding="utf-8"))
    patched = 0

    for node in visit(data):
        if not isinstance(node, dict):
            continue
        if node.get("type") != "SUPIRApply":
            continue
        vals = node.get("widgets_values")
        if not isinstance(vals, list) or len(vals) < 10:
            continue

        if kind == "strong":
            vals[0] = POS_STRONG
            vals[1] = NEG_COMMON
            vals[2] = True          # enhance_image_captioning
            vals[3] = 4.0           # final_megapixels
            vals[4] = 1.0           # strength_start
            vals[5] = 0.88          # strength_end
            vals[6] = 22            # steps
            vals[7] = 1.6           # cfg
            vals[8] = 0.86          # denoise
            vals[9] = 0             # seed
        else:
            vals[0] = POS_SAFE
            vals[1] = NEG_COMMON
            vals[2] = True
            vals[3] = 4.0
            vals[4] = 1.0
            vals[5] = 0.92
            vals[6] = 18
            vals[7] = 1.3
            vals[8] = 0.74
            vals[9] = 0

        patched += 1

    if patched == 0:
        raise SystemExit(f"Could not find a SUPIRApply node in: {path}")

    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Patched {patched} SUPIRApply node(s) in {path.name}")

patch(strong_path, "strong")
patch(safe_path, "safe")
PY

echo "[3/3] Done."
echo
echo "Created:"
echo "  $STRONG_WF"
echo "  $SAFE_WF"
echo
echo "Use:"
echo "  1) Refresh ComfyUI"
echo "  2) Load Adult_NSFW_Strong_SUPIR_v1.json"
echo "     - stronger beauty / restoration"
echo "  3) Load Adult_NSFW_Detail_Safe_SUPIR_v1.json"
echo "     - safer for hands / feet / local detail"
echo
echo "If these do not appear in the workflow list, drag the JSON files in manually."
echo "============================================================"
