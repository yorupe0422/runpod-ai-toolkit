#!/usr/bin/env bash
set -Eeuo pipefail

COMFY="${COMFY:-/workspace/runpod-slim/ComfyUI}"
WF_DIR="$COMFY/user/default/workflows"
DM_DIR="$COMFY/models/diffusion_models"
TE_DIR="$COMFY/models/text_encoders"
VAE_DIR="$COMFY/models/vae"

WF="$WF_DIR/Qwen_ImageEdit_2511_HQ_Restore_v5_BF16.json"

# Official ComfyUI Qwen 2511 blueprint (BF16 model)
TEMPLATE_URL="https://raw.githubusercontent.com/Comfy-Org/ComfyUI/master/blueprints/Image%20Edit%20(Qwen%202511).json"

DM="qwen_image_edit_2511_bf16.safetensors"
DM_URL="https://huggingface.co/Comfy-Org/Qwen-Image-Edit_ComfyUI/resolve/main/split_files/diffusion_models/qwen_image_edit_2511_bf16.safetensors"

TE="qwen_2.5_vl_7b_fp8_scaled.safetensors"
TE_URL="https://huggingface.co/Comfy-Org/Qwen-Image-Edit_ComfyUI/resolve/main/split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors"

VAE="qwen_image_vae.safetensors"
VAE_URL="https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors"

echo "============================================================"
echo " Qwen-Image-Edit 2511 HQ Restore v5 BF16 + FASTDL"
echo " - FIX: avoids unsupported int8_tensorwise model"
echo " - Uses official BF16 Qwen 2511 model"
echo " - A100 80GB friendly"
echo " - Does NOT replace/update/reinstall ComfyUI"
echo "============================================================"

[[ -d "$COMFY" ]] || { echo "[ERROR] ComfyUI not found: $COMFY"; exit 1; }
mkdir -p "$WF_DIR" "$DM_DIR" "$TE_DIR" "$VAE_DIR"

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
        raw=f.read(8)
        if len(raw)!=8:
            raise ValueError("missing header length")
        hlen=struct.unpack("<Q", raw)[0]
        if hlen <= 2 or hlen > size-8:
            raise ValueError(f"bad header length {hlen} for file size {size}")
        meta=json.loads(f.read(hlen))
    max_end=0
    tensors=0
    for k,v in meta.items():
        if k=="__metadata__" or not isinstance(v,dict):
            continue
        off=v.get("data_offsets")
        if isinstance(off,list) and len(off)==2:
            a,b=map(int,off)
            if a<0 or b<a:
                raise ValueError(f"bad offsets for {k}: {off}")
            max_end=max(max_end,b)
            tensors+=1
    if tensors == 0:
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
    echo "[OK] $label already valid"
    return 0
  fi

  [[ -e "$out" ]] && rm -f "$out"

  local part="${out}.part"
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

echo "[1/6] Official BF16 workflow blueprint"
curl -fL --retry 5 --retry-delay 2 "$TEMPLATE_URL" -o "$WF"

echo "[2/6] Starting required model downloads in parallel..."
fast_download "$DM_URL" "$DM_DIR/$DM" "$DM" &
P1=$!
fast_download "$TE_URL" "$TE_DIR/$TE" "$TE" &
P2=$!
fast_download "$VAE_URL" "$VAE_DIR/$VAE" "$VAE" &
P3=$!

wait "$P1"
wait "$P2"
wait "$P3"

echo "[3/6] Final validation"
validate_safetensors "$DM_DIR/$DM"
validate_safetensors "$TE_DIR/$TE"
validate_safetensors "$VAE_DIR/$VAE"

echo "[4/6] Ensuring workflow selects BF16 model"
python3 - "$WF" <<'PY'
import json, sys
from pathlib import Path

path=Path(sys.argv[1])
data=json.loads(path.read_text(encoding="utf-8"))

DM="qwen_image_edit_2511_bf16.safetensors"
TE="qwen_2.5_vl_7b_fp8_scaled.safetensors"
VAE="qwen_image_vae.safetensors"

POS=(
    "Recreate this exact reference image as a high-quality modern smartphone photograph. "
    "Preserve the same adult person, exact facial identity, expression, hairstyle, pose, "
    "body proportions, anatomy, clothing, camera angle, framing, background and composition. "
    "Strongly improve only image quality: recover realistic fine detail, natural skin texture, "
    "clear eyes, detailed hair, clean edges, realistic lighting and photographic sharpness. "
    "Natural premium modern iPhone photo quality, photorealistic, no beauty-filter look. "
    "Do not redesign the person or scene."
)

# Top-level composite workflow model selections
for node in data.get("nodes", []):
    vals=node.get("widgets_values")
    props=node.get("properties",{})
    proxy=props.get("proxyWidgets")
    if isinstance(vals,list) and isinstance(proxy,list):
        names=[]
        for x in proxy:
            if isinstance(x,list) and len(x)>=2:
                names.append(x[1])
        for i,name in enumerate(names):
            if i >= len(vals):
                continue
            if name=="unet_name":
                vals[i]=DM
            elif name=="clip_name":
                vals[i]=TE
            elif name=="vae_name":
                vals[i]=VAE
            elif name=="prompt" and isinstance(vals[i],str):
                vals[i]=POS

# Internal nodes
for sg in data.get("definitions",{}).get("subgraphs",[]):
    for node in sg.get("nodes",[]):
        typ=node.get("type")
        vals=node.get("widgets_values")
        if typ=="UNETLoader" and isinstance(vals,list) and vals:
            vals[0]=DM
            if len(vals)>1:
                vals[1]="default"
        elif typ=="CLIPLoader" and isinstance(vals,list) and vals:
            vals[0]=TE
        elif typ=="VAELoader" and isinstance(vals,list) and vals:
            vals[0]=VAE
        elif typ=="TextEncodeQwenImageEditPlus" and isinstance(vals,list) and vals:
            title=(node.get("title") or "").lower()
            if "positive" in title:
                vals[0]=POS
        elif typ=="KSampler" and isinstance(vals,list) and len(vals)>=7:
            # Official quality guidance: 40 steps / CFG 4.
            vals[2]=40
            vals[3]=4.0

path.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding="utf-8")
print("[OK] BF16 model + HQ prompt + 40 steps / CFG 4.0")
PY

echo "[5/6] Cleaning only stale INT8 workflow confusion"
echo "  The old INT8 model is left on disk, but this workflow will NOT use it."

echo "[6/6] READY"
echo
echo "Workflow:"
echo "  $WF"
echo
echo "Model:"
echo "  $DM_DIR/$DM"
echo
echo "Refresh ComfyUI and load:"
echo "  Qwen_ImageEdit_2511_HQ_Restore_v5_BF16.json"
echo
echo "IMPORTANT:"
echo "  Do NOT use the old INT8 workflow on ComfyUI 0.24.0."
echo "============================================================"
