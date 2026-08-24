#!/usr/bin/env bash
set -Eeuo pipefail

COMFY="${COMFY:-/workspace/runpod-slim/ComfyUI}"
WF_DIR="$COMFY/user/default/workflows"
DM_DIR="$COMFY/models/diffusion_models"
TE_DIR="$COMFY/models/text_encoders"
VAE_DIR="$COMFY/models/vae"
LORA_DIR="$COMFY/models/loras"

WF="$WF_DIR/Qwen_ImageEdit_2511_HQ_Restore_v4.json"

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
echo " Qwen-Image-Edit 2511 HQ Restore v4 REPAIR + FASTDL"
echo " - Detects/removes truncated safetensors"
echo " - Downloads to .part then atomically renames"
echo " - aria2 multi-connection + parallel downloads"
echo " - Does NOT replace/update/reinstall ComfyUI"
echo "============================================================"

[[ -d "$COMFY" ]] || { echo "[ERROR] ComfyUI not found: $COMFY"; exit 1; }
mkdir -p "$WF_DIR" "$DM_DIR" "$TE_DIR" "$VAE_DIR" "$LORA_DIR"

if ! command -v aria2c >/dev/null 2>&1; then
  echo "[0/6] Installing aria2..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq aria2 >/dev/null
fi

validate_safetensors () {
  local f="$1"
  [[ -s "$f" ]] || return 1
  python3 - "$f" <<'PY'
import json, os, struct, sys
p=sys.argv[1]
try:
    size=os.path.getsize(p)
    with open(p,"rb") as f:
        b=f.read(8)
        if len(b)!=8:
            raise ValueError("missing header length")
        hlen=struct.unpack("<Q", b)[0]
        if hlen <= 2 or hlen > size-8:
            raise ValueError(f"bad header length {hlen} for file size {size}")
        hdr=f.read(hlen)
        meta=json.loads(hdr)
    max_end=0
    tensors=0
    for k,v in meta.items():
        if k=="__metadata__" or not isinstance(v,dict):
            continue
        off=v.get("data_offsets")
        if not (isinstance(off,list) and len(off)==2):
            continue
        a,b=map(int,off)
        if a<0 or b<a:
            raise ValueError(f"bad offsets for {k}: {off}")
        max_end=max(max_end,b)
        tensors+=1
    if tensors==0:
        raise ValueError("no tensors")
    required=8+hlen+max_end
    if size < required:
        raise ValueError(f"TRUNCATED size={size}, required>={required}")
    print(f"VALID {os.path.basename(p)} size={size} tensors={tensors}")
except Exception as e:
    print(f"INVALID {p}: {e}", file=sys.stderr)
    sys.exit(1)
PY
}

fast_download () {
  local url="$1"
  local out="$2"
  local label="$3"

  if validate_safetensors "$out" >/dev/null 2>&1; then
    echo "[OK] $label validated"
    return 0
  fi

  if [[ -e "$out" ]]; then
    echo "[FIX] Removing incomplete/corrupt file: $out"
    rm -f "$out"
  fi

  local part="${out}.part"
  rm -f "${part}.aria2"

  echo "[DL] $label"
  aria2c \
    --continue=true \
    --max-connection-per-server=16 \
    --split=16 \
    --min-split-size=4M \
    --file-allocation=none \
    --auto-file-renaming=false \
    --allow-overwrite=true \
    --retry-wait=2 \
    --max-tries=0 \
    --timeout=60 \
    --connect-timeout=20 \
    --summary-interval=5 \
    --console-log-level=warn \
    --dir="$(dirname "$part")" \
    --out="$(basename "$part")" \
    "$url"

  echo "[CHK] $label"
  validate_safetensors "$part"

  mv -f "$part" "$out"
  rm -f "${part}.aria2"
  echo "[OK] $label complete"
}

echo "[1/6] Official workflow template"
curl -fL --retry 5 --retry-delay 2 "$TEMPLATE_URL" -o "$WF"

echo "[2/6] Validating existing files..."
for f in "$DM_DIR/$DM" "$TE_DIR/$TE" "$VAE_DIR/$VAE" "$LORA_DIR/$LORA"; do
  if [[ -e "$f" ]]; then
    if validate_safetensors "$f" >/dev/null 2>&1; then
      echo "[OK] $(basename "$f")"
    else
      echo "[BAD] $(basename "$f") is incomplete/corrupt and will be replaced"
    fi
  fi
done

echo "[3/6] Fast parallel download/repair..."
fast_download "$DM_URL" "$DM_DIR/$DM" "$DM" &
P1=$!
fast_download "$TE_URL" "$TE_DIR/$TE" "$TE" &
P2=$!
fast_download "$VAE_URL" "$VAE_DIR/$VAE" "$VAE" &
P3=$!
fast_download "$LORA_URL" "$LORA_DIR/$LORA" "$LORA" &
P4=$!

wait "$P1"
wait "$P2"
wait "$P3"
wait "$P4"

echo "[4/6] Final validation..."
validate_safetensors "$DM_DIR/$DM"
validate_safetensors "$TE_DIR/$TE"
validate_safetensors "$VAE_DIR/$VAE"
validate_safetensors "$LORA_DIR/$LORA"

echo "[5/6] Patch workflow prompt..."
python3 - "$WF" <<'PY'
import json, sys
from pathlib import Path

path=Path(sys.argv[1])
data=json.loads(path.read_text(encoding="utf-8"))

POS=(
    "Recreate this exact reference image as a high-quality modern smartphone photograph. "
    "Preserve the same adult person, exact facial identity, expression, hairstyle, pose, "
    "body proportions, anatomy, clothing, camera angle, framing, background and composition. "
    "Strongly improve only image quality: recover natural fine detail, realistic skin texture, "
    "clear eyes, detailed hair, clean edges, realistic lighting and photographic sharpness. "
    "Natural premium modern iPhone photo quality, photorealistic, no beauty-filter look. "
    "Do not redesign the person or scene and do not change anatomy."
)

NEG=(
    "different person, changed face, changed identity, changed pose, changed body proportions, "
    "changed clothing, changed background, deformed anatomy, malformed hands, malformed feet, "
    "extra fingers, missing fingers, fused fingers, extra toes, missing toes, plastic skin, waxy skin, "
    "oversmoothed skin, excessive HDR, oversharpened halos, illustration, anime, cartoon, CGI, "
    "blurry, motion blur, jpeg artifacts, compression artifacts, watermark, text"
)

pos=neg=0
for sg in data.get("definitions",{}).get("subgraphs",[]):
    for node in sg.get("nodes",[]):
        if node.get("type")!="TextEncodeQwenImageEditPlus":
            continue
        vals=node.get("widgets_values")
        if not isinstance(vals,list) or not vals:
            continue
        title=(node.get("title") or "").lower()
        if "positive" in title:
            vals[0]=POS; pos+=1
        elif "negative" in title:
            vals[0]=NEG; neg+=1

if pos==0:
    raise SystemExit("[ERROR] Positive Qwen prompt node not found")

path.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding="utf-8")
print(f"[OK] workflow patched positive={pos}, negative={neg}")
PY

echo "[6/6] READY"
echo
echo "Workflow:"
echo "  $WF"
echo
echo "Refresh ComfyUI and load:"
echo "  Qwen_ImageEdit_2511_HQ_Restore_v4.json"
echo
echo "IMPORTANT:"
echo "  v4 never trusts a merely non-empty file."
echo "  It validates safetensors before reusing it."
echo "============================================================"
