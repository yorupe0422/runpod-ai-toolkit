#!/usr/bin/env bash
set -Eeuo pipefail

COMFY="${COMFY:-/workspace/runpod-slim/ComfyUI}"
WF_DIR="$COMFY/user/default/workflows"
DM_DIR="$COMFY/models/diffusion_models"
TE_DIR="$COMFY/models/text_encoders"
VAE_DIR="$COMFY/models/vae"
LORA_DIR="$COMFY/models/loras"

WF="$WF_DIR/Qwen_ImageEdit_2511_HQ_Restore_v3.json"

TEMPLATE_URL="https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/image_qwen_image_edit_2511_int8.json"

DM="qwen_image_edit_2511_int8_convrot.safetensors"
DM_URL="https://huggingface.co/Comfy-Org/Qwen-Image-Edit_ComfyUI/resolve/main/split_files/diffusion_models/qwen_image_edit_2511_int8_convrot.safetensors"

TE="qwen_2.5_vl_7b_fp8_scaled.safetensors"
TE_URL="https://huggingface.co/Comfy-Org/HunyuanVideo_1.5_repackaged/resolve/main/split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors"

VAE="qwen_image_vae.safetensors"
VAE_URL="https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors"

LORA="Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"
LORA_URL="https://huggingface.co/lightx2v/Qwen-Image-Edit-2511-Lightning/resolve/main/Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"

echo "============================================================"
echo " Qwen-Image-Edit 2511 HQ Restore v3 FAST DOWNLOAD"
echo " - aria2 multi-connection downloads"
echo " - resumes partial downloads"
echo " - parallel model downloads"
echo " - does NOT replace/update ComfyUI"
echo "============================================================"

[[ -d "$COMFY" ]] || { echo "[ERROR] ComfyUI not found: $COMFY"; exit 1; }
mkdir -p "$WF_DIR" "$DM_DIR" "$TE_DIR" "$VAE_DIR" "$LORA_DIR"

echo "[0/5] Preparing aria2..."
if ! command -v aria2c >/dev/null 2>&1; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq aria2 >/dev/null
fi

FASTDL() {
  local url="$1"
  local out="$2"
  local label="$3"

  if [[ -s "$out" ]]; then
    echo "[OK] $label already exists"
    return 0
  fi

  echo "[DL] $label"
  aria2c \
    --continue=true \
    --max-connection-per-server=16 \
    --split=16 \
    --min-split-size=1M \
    --file-allocation=none \
    --auto-file-renaming=false \
    --allow-overwrite=true \
    --retry-wait=2 \
    --max-tries=0 \
    --timeout=60 \
    --connect-timeout=20 \
    --summary-interval=5 \
    --console-log-level=warn \
    --dir="$(dirname "$out")" \
    --out="$(basename "$out")" \
    "$url"
}

echo "[1/5] Workflow template"
curl -fL --retry 5 --retry-delay 2 "$TEMPLATE_URL" -o "$WF"

echo "[2/5] Starting model downloads in parallel..."

FASTDL "$DM_URL" "$DM_DIR/$DM" "$DM" &
P1=$!
FASTDL "$TE_URL" "$TE_DIR/$TE" "$TE" &
P2=$!
FASTDL "$VAE_URL" "$VAE_DIR/$VAE" "$VAE" &
P3=$!
FASTDL "$LORA_URL" "$LORA_DIR/$LORA" "$LORA" &
P4=$!

wait "$P1"
wait "$P2"
wait "$P3"
wait "$P4"

echo "[3/5] All downloads complete"

echo "[4/5] Patch workflow for HQ restoration"
python3 - "$WF" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))

POS = (
    "Recreate this exact reference image as a high-quality modern smartphone photograph. "
    "Preserve the same adult person, exact facial identity, expression, hairstyle, pose, "
    "body proportions, anatomy, clothing, camera angle, framing, background and composition. "
    "Strongly improve only image quality: recover natural fine detail, realistic skin texture, "
    "clear eyes, detailed hair, clean edges, realistic lighting and photographic sharpness. "
    "Natural premium modern iPhone photo quality, photorealistic, no beauty-filter look. "
    "Do not redesign the person or scene and do not change anatomy."
)

NEG = (
    "different person, changed face, changed identity, changed pose, changed body proportions, "
    "changed clothing, changed background, deformed anatomy, malformed hands, malformed feet, "
    "extra fingers, missing fingers, fused fingers, extra toes, missing toes, plastic skin, waxy skin, "
    "oversmoothed skin, excessive HDR, oversharpened halos, illustration, anime, cartoon, CGI, "
    "blurry, motion blur, jpeg artifacts, compression artifacts, watermark, text"
)

pos_count = neg_count = 0
for sg in data.get("definitions", {}).get("subgraphs", []):
    for node in sg.get("nodes", []):
        if node.get("type") != "TextEncodeQwenImageEditPlus":
            continue
        vals = node.get("widgets_values")
        if not isinstance(vals, list) or not vals:
            continue
        title = (node.get("title") or "").lower()
        if "positive" in title:
            vals[0] = POS
            pos_count += 1
        elif "negative" in title:
            vals[0] = NEG
            neg_count += 1

for sg in data.get("definitions", {}).get("subgraphs", []):
    for node in sg.get("nodes", []):
        if node.get("type") == "BOOLConstant":
            vals = node.get("widgets_values")
            if isinstance(vals, list) and vals:
                vals[0] = False

if pos_count == 0:
    raise SystemExit("[ERROR] Positive Qwen edit prompt node not found.")

path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"[OK] patched: positive={pos_count}, negative={neg_count}")
PY

echo "[5/5] READY"
echo
echo "Workflow:"
echo "  $WF"
echo
echo "Refresh ComfyUI and load:"
echo "  Qwen_ImageEdit_2511_HQ_Restore_v3.json"
echo
echo "Fast downloader settings:"
echo "  16 connections per file x up to 4 files in parallel"
echo "  partial downloads are resumed automatically"
echo "============================================================"
