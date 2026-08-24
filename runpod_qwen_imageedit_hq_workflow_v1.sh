#!/usr/bin/env bash
set -Eeuo pipefail

COMFY="${COMFY:-/workspace/runpod-slim/ComfyUI}"
WF_DIR="$COMFY/user/default/workflows"

OUT_MAIN="$WF_DIR/Qwen_ImageEdit_HQ_Restore_v1.json"
OUT_STRONG="$WF_DIR/Qwen_ImageEdit_HQ_Stronger_v1.json"

echo "============================================================"
echo " Qwen-Image-Edit HQ workflow presets v1"
echo " - Adds 2 Qwen image-edit high-quality workflows"
echo " - Does NOT reinstall or replace ComfyUI"
echo " - Uses your existing working Qwen workflow as the source"
echo "============================================================"

[[ -d "$WF_DIR" ]] || { echo "[ERROR] Workflow dir not found: $WF_DIR"; exit 1; }

SRC_WF="$(find "$WF_DIR" -maxdepth 1 -type f \( -iname '*qwen*2511*.json' -o -iname '*qwen*edit*.json' -o -iname '*qwen*.json' \) \
  ! -iname 'Qwen_ImageEdit_HQ_Restore_v1.json' \
  ! -iname 'Qwen_ImageEdit_HQ_Stronger_v1.json' \
  | head -n 1 || true)"

if [[ -z "${SRC_WF:-}" ]]; then
  echo "[ERROR] No source Qwen workflow JSON was found in:"
  echo "  $WF_DIR"
  echo
  echo "Please save your currently working Qwen workflow into that folder first,"
  echo "then run this script again."
  exit 1
fi

echo "[1/3] Source workflow:"
echo "  $SRC_WF"

cp -f "$SRC_WF" "$OUT_MAIN"
cp -f "$SRC_WF" "$OUT_STRONG"

echo "[2/3] Patching Qwen HQ presets..."

python3 - "$OUT_MAIN" "$OUT_STRONG" <<'PY'
import json, sys
from pathlib import Path

main_path = Path(sys.argv[1])
strong_path = Path(sys.argv[2])

PROMPT_MAIN = (
    "Recreate this exact image as a high-quality modern smartphone photograph. "
    "Preserve the same person, exact facial identity, expression, hairstyle, pose, "
    "body proportions, anatomy, clothing, camera angle, framing, background and composition. "
    "Improve only image quality, natural skin texture, fine detail, sharpness and lighting. "
    "Photorealistic, natural modern iPhone-quality photo. Do not redesign or change the scene."
)

PROMPT_STRONG = (
    "Recreate this exact image as a very high-quality modern smartphone photograph. "
    "Preserve the same person, exact facial identity, expression, hairstyle, pose, "
    "body proportions, anatomy, clothing, camera angle, framing, background and composition. "
    "Improve image quality strongly with crisp fine detail, realistic skin texture, clean detail, "
    "clear eyes, detailed hair and natural lighting. Photorealistic, premium modern iPhone-quality photo. "
    "Do not change the person or scene."
)

def patch(path: Path, prompt: str, steps: int, cfg: float, denoise: float, cfgnorm: float):
    data = json.loads(path.read_text(encoding="utf-8"))

    # Patch top-level proxy widget values when present.
    top_patched = False
    for node in data.get("nodes", []):
        props = node.get("properties", {})
        proxy = props.get("proxyWidgets")
        vals = node.get("widgets_values")
        if not proxy or not isinstance(vals, list):
            continue
        names = [p[1] for p in proxy if isinstance(p, list) and len(p) >= 2]
        if "prompt" in names:
            # Expected order in official blueprint:
            # prompt, seed, control_after_generate, unet_name, clip_name, vae_name
            while len(vals) < 6:
                vals.append(None)
            vals[0] = prompt
            vals[1] = 0
            vals[2] = "fixed"
            top_patched = True

    sg_nodes = []
    for sg in data.get("definitions", {}).get("subgraphs", []):
        sg_nodes.extend(sg.get("nodes", []))

    if not sg_nodes:
        raise SystemExit(f"No Qwen subgraph nodes found in {path.name}")

    sampler_patched = False
    cfgnorm_patched = False
    pos_patched = False

    for node in sg_nodes:
        typ = node.get("type")
        vals = node.get("widgets_values")

        if typ == "KSampler" and isinstance(vals, list):
            while len(vals) < 7:
                vals.append(None)
            vals[0] = 0               # seed
            vals[1] = "fixed"         # control_after_generate
            vals[2] = steps
            vals[3] = cfg
            # keep sampler_name / scheduler if they already exist
            if vals[4] in (None, ""):
                vals[4] = "euler"
            if vals[5] in (None, ""):
                vals[5] = "simple"
            vals[6] = denoise
            sampler_patched = True

        elif typ == "CFGNorm" and isinstance(vals, list) and len(vals) >= 1:
            vals[0] = cfgnorm
            cfgnorm_patched = True

        elif typ == "TextEncodeQwenImageEditPlus":
            title = (node.get("title") or "").lower()
            if "positive" in title and isinstance(vals, list) and len(vals) >= 1:
                vals[0] = prompt
                pos_patched = True

    if not top_patched and not pos_patched:
        raise SystemExit(f"Could not find prompt-bearing Qwen nodes in {path.name}")
    if not sampler_patched:
        raise SystemExit(f"Could not find KSampler in {path.name}")
    if not cfgnorm_patched:
        raise SystemExit(f"Could not find CFGNorm in {path.name}")

    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[OK] {path.name}")

patch(main_path, PROMPT_MAIN, 40, 4.0, 0.70, 1.0)
patch(strong_path, PROMPT_STRONG, 40, 4.0, 0.82, 1.0)
PY

echo "[3/3] Done."
echo
echo "Created:"
echo "  $OUT_MAIN"
echo "  $OUT_STRONG"
echo
echo "Main preset:"
echo "  Qwen_ImageEdit_HQ_Restore_v1.json"
echo "  steps=40 / cfg=4.0 / denoise=0.70"
echo
echo "Stronger preset:"
echo "  Qwen_ImageEdit_HQ_Stronger_v1.json"
echo "  steps=40 / cfg=4.0 / denoise=0.82"
echo
echo "Refresh ComfyUI, then load either workflow."
echo "If not shown in the list, drag the JSON files in manually."
echo "============================================================"
