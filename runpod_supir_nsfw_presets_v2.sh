#!/usr/bin/env bash
set -Eeuo pipefail

COMFY="${COMFY:-/workspace/runpod-slim/ComfyUI}"
WF_DIR="$COMFY/user/default/workflows"

STRONG_WF="$WF_DIR/Adult_NSFW_Strong_SUPIR_v2.json"
SAFE_WF="$WF_DIR/Adult_NSFW_Detail_Safe_SUPIR_v2.json"

echo "============================================================"
echo " SUPIR NSFW preset workflows v2"
echo " - Fixes native SUPIR subgraph patching"
echo " - Adds 2 preset workflows to the current ComfyUI"
echo " - Does NOT reinstall or replace ComfyUI"
echo "============================================================"

[[ -d "$WF_DIR" ]] || { echo "[ERROR] Workflow dir not found: $WF_DIR"; exit 1; }

SRC_WF="$(find "$WF_DIR" -maxdepth 1 -type f -iname '*supir*.json' \
  ! -iname 'Adult_NSFW_Strong_SUPIR_v*.json' \
  ! -iname 'Adult_NSFW_Detail_Safe_SUPIR_v*.json' \
  | head -n 1 || true)"

if [[ -z "${SRC_WF:-}" ]]; then
  echo "[ERROR] No source SUPIR workflow JSON was found in:"
  echo "  $WF_DIR"
  exit 1
fi

echo "[1/3] Source workflow:"
echo "  $SRC_WF"

cp -f "$SRC_WF" "$STRONG_WF"
cp -f "$SRC_WF" "$SAFE_WF"

echo "[2/3] Patching native SUPIR subgraph presets..."

python3 - "$STRONG_WF" "$SAFE_WF" <<'PY'
import json, sys
from pathlib import Path

strong_path = Path(sys.argv[1])
safe_path = Path(sys.argv[2])

POS_STRONG = (
    "adult realistic intimate photo, high quality detailed modern smartphone photo, "
    "preserve the same adult person, preserve exact pose, preserve body proportions, "
    "preserve anatomy, natural skin texture, clean fine detail, clear focus, realistic lighting, "
    "detailed hair, natural body detail, crisp photographic quality"
)

POS_SAFE = (
    "adult realistic intimate photo, preserve the same adult person, preserve exact pose, "
    "preserve exact anatomy, preserve exact hands and fingers, preserve exact feet and toes, "
    "preserve body proportions, natural skin texture, realistic lighting, clear focus, "
    "clean photographic detail, modern smartphone photo quality"
)

NEG = (
    "child, young-looking, underage, illustration, anime, cartoon, cgi, 3d render, "
    "plastic skin, waxy skin, oversmoothed skin, excessive hdr, oversharpened, "
    "deformed anatomy, malformed hands, malformed feet, extra fingers, missing fingers, "
    "fused fingers, extra toes, missing toes, distorted limbs, blurry, motion blur, "
    "compression artifacts, jpeg artifacts, ringing, halos, watermark, text"
)

def all_nodes(data):
    # Native SUPIR workflow stores the real graph inside definitions.subgraphs.
    defs = data.get("definitions", {})
    for sg in defs.get("subgraphs", []):
        for n in sg.get("nodes", []):
            yield n

def patch(path: Path, mode: str):
    data = json.loads(path.read_text(encoding="utf-8"))
    nodes = list(all_nodes(data))
    if not nodes:
        raise SystemExit(f"No native subgraph nodes found in {path.name}")

    found = {
        "prompt": False,
        "negative": False,
        "caption": False,
        "resize": False,
        "supir": False,
        "scheduler": False,
        "sampler": False,
    }

    for n in nodes:
        nid = n.get("id")
        typ = n.get("type")
        vals = n.get("widgets_values")

        # Official native SUPIR workflow node IDs / types.
        if nid == 71 and typ == "PrimitiveStringMultiline" and isinstance(vals, list):
            vals[0] = POS_STRONG if mode == "strong" else POS_SAFE
            found["prompt"] = True

        elif nid == 73 and typ == "PrimitiveStringMultiline" and isinstance(vals, list):
            vals[0] = NEG
            found["negative"] = True

        elif nid == 90 and typ == "BOOLConstant" and isinstance(vals, list):
            vals[0] = True
            found["caption"] = True

        elif nid == 94 and typ == "ResizeImageMaskNode" and isinstance(vals, list):
            # Native workflow may have only the resize method value locally,
            # with megapixels proxied from the subgraph interface. Leave graph structure intact.
            found["resize"] = True

        elif typ == "SUPIRApply" and isinstance(vals, list) and len(vals) >= 2:
            vals[0] = 1.0
            vals[1] = 0.88 if mode == "strong" else 0.92
            found["supir"] = True

        elif typ == "BasicScheduler" and isinstance(vals, list) and len(vals) >= 3:
            vals[1] = 22 if mode == "strong" else 18
            vals[2] = 0.86 if mode == "strong" else 0.74
            found["scheduler"] = True

        elif typ == "SamplerCustom" and isinstance(vals, list) and len(vals) >= 4:
            vals[1] = 0
            vals[2] = "fixed"
            vals[3] = 1.6 if mode == "strong" else 1.3
            found["sampler"] = True

    # Patch the exposed subgraph widget defaults where they exist.
    # Current native SUPIR proxy order:
    # manual prompt, captioning, negative, megapixels, strength_start,
    # strength_end, steps, cfg, denoise, seed, model names...
    for n in data.get("nodes", []):
        props = n.get("properties", {})
        proxy = props.get("proxyWidgets")
        if not proxy:
            continue
        # The node itself may keep runtime values separately depending on frontend version.
        # Set explicit input defaults to ensure 4 MP appears when supported.
        for inp in n.get("inputs", []):
            label = inp.get("label")
            if label == "final_megapixels":
                inp["value"] = 4.0

    missing = [k for k,v in found.items() if k not in ("resize",) and not v]
    if missing:
        raise SystemExit(
            f"Could not patch expected native SUPIR nodes in {path.name}: {', '.join(missing)}"
        )

    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[OK] {path.name}")
    print("     prompt / negative / captioning / strength / steps / cfg / denoise patched")

patch(strong_path, "strong")
patch(safe_path, "safe")
PY

echo "[3/3] Done."
echo
echo "Created:"
echo "  $STRONG_WF"
echo "  $SAFE_WF"
echo
echo "Preset values:"
echo "  Strong      : strength_end 0.88 / steps 22 / cfg 1.6 / denoise 0.86"
echo "  Detail Safe : strength_end 0.92 / steps 18 / cfg 1.3 / denoise 0.74"
echo
echo "NOTE:"
echo "  final_megapixels is intended to be 4.0."
echo "  If your ComfyUI frontend still displays the source value, set final_megapixels to 4.0 manually once."
echo
echo "Refresh ComfyUI, then load either v2 workflow."
echo "============================================================"
