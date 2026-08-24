#!/usr/bin/env bash
set -Eeuo pipefail

COMFY="${COMFY:-/workspace/runpod-slim/ComfyUI}"
WF_DIR="$COMFY/user/default/workflows"
DM_DIR="$COMFY/models/diffusion_models"
TE_DIR="$COMFY/models/text_encoders"
VAE_DIR="$COMFY/models/vae"
LORA_DIR="$COMFY/models/loras"

WF="$WF_DIR/Qwen_ImageEdit_2511_HQ_Restore_v2.json"

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
echo " Qwen-Image-Edit 2511 HQ Restore v2"
echo " - Self-contained: no existing Qwen workflow required"
echo " - Official Comfy workflow template (INT8 model)"
echo " - Does NOT replace/update/reinstall ComfyUI"
echo "============================================================"

[[ -d "$COMFY" ]] || { echo "[ERROR] ComfyUI not found: $COMFY"; exit 1; }
mkdir -p "$WF_DIR" "$DM_DIR" "$TE_DIR" "$VAE_DIR" "$LORA_DIR"

download_if_missing () {
  local url="$1"
  local out="$2"
  local label="$3"
  if [[ -s "$out" ]]; then
    echo "[OK] $label already exists"
  else
    echo "[DL] $label"
    curl -fL --retry 5 --retry-delay 3 --continue-at - "$url" -o "$out"
  fi
}

echo "[1/5] Download official Qwen-Image-Edit 2511 workflow template"
curl -fL --retry 5 --retry-delay 3 "$TEMPLATE_URL" -o "$WF"

echo "[2/5] Diffusion model"
download_if_missing "$DM_URL" "$DM_DIR/$DM" "$DM"

echo "[3/5] Text encoder"
download_if_missing "$TE_URL" "$TE_DIR/$TE" "$TE"

echo "[4/5] VAE + optional Lightning LoRA"
download_if_missing "$VAE_URL" "$VAE_DIR/$VAE" "$VAE"
download_if_missing "$LORA_URL" "$LORA_DIR/$LORA" "$LORA"

echo "[5/5] Patch workflow for HQ restoration"
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

# Patch all subgraph text encoders by title/role.
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
        elif "negative" in title or vals[0] == "":
            vals[0] = NEG
            neg_count += 1

# Also patch exposed top-level subgraph input values where frontend stores them.
for node in data.get("nodes", []):
    props = node.get("properties", {})
    proxy = props.get("proxyWidgets")
    vals = node.get("widgets_values")
    if not isinstance(proxy, list) or not isinstance(vals, list):
        continue
    # Current official template's composite node may not materialize all proxy
    # values here; don't disturb model selections if it does not.
    names = []
    for x in proxy:
        if isinstance(x, list) and len(x) >= 2:
            names.append(x[1])
    # Only touch explicit prompt strings if present.
    prompt_positions = [i for i,n in enumerate(names) if n == "prompt"]
    for j, pos in enumerate(prompt_positions[:2]):
        if pos < len(vals) and isinstance(vals[pos], str):
            vals[pos] = POS if j == 0 else NEG

# Prefer quality mode: disable turbo switch where the official template exposes BOOLConstant.
# Lightning LoRA remains installed so the user can turn turbo back on later.
for sg in data.get("definitions", {}).get("subgraphs", []):
    for node in sg.get("nodes", []):
        if node.get("type") == "BOOLConstant":
            vals = node.get("widgets_values")
            if isinstance(vals, list) and vals:
                vals[0] = False

# Use descriptive output prefix.
for node in data.get("nodes", []):
    if node.get("type") in ("SaveImage", "SaveImageAdvanced"):
        vals = node.get("widgets_values")
        if isinstance(vals, list) and vals:
            vals[0] = "Qwen_ImageEdit_2511_HQ_Restore"

if pos_count == 0:
    raise SystemExit("[ERROR] Positive Qwen edit prompt node not found in official template.")

path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"[OK] Patched positive nodes: {pos_count}, negative nodes: {neg_count}")
PY

echo
echo "READY"
echo "Workflow:"
echo "  $WF"
echo
echo "Models:"
echo "  $DM_DIR/$DM"
echo "  $TE_DIR/$TE"
echo "  $VAE_DIR/$VAE"
echo
echo "Quality mode is selected (Turbo OFF)."
echo "Refresh ComfyUI and load:"
echo "  Qwen_ImageEdit_2511_HQ_Restore_v2.json"
echo
echo "No existing Qwen workflow was required."
echo "No ComfyUI update/reinstall was performed."
echo "============================================================"
