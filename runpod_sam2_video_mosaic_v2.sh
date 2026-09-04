#!/usr/bin/env bash
set -Eeuo pipefail

APP_ROOT="/workspace/runpod-slim/ComfyUI-SAM2MosaicV2"
APP_DIR="${APP_ROOT}/ComfyUI"
VENV_DIR="${APP_DIR}/.venv"
PORT="8188"

LOG_DIR="/workspace/runpod-slim/setup_logs"
STAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/sam2_video_mosaic_v2_${STAMP}.log"
SMOKE_LOG="${LOG_DIR}/sam2_video_mosaic_v2_smoke_${STAMP}.log"

mkdir -p "${LOG_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "============================================================"
echo "[INFO] runpod_sam2_video_mosaic_v2.sh"
echo "[INFO] START: $(date)"
echo "[INFO] LOG:   ${LOG_FILE}"
echo "============================================================"

export DEBIAN_FRONTEND=noninteractive

echo
echo "[STEP 1/10] apt packages"
apt-get update
apt-get install -y \
  git \
  curl \
  wget \
  ffmpeg \
  python3 \
  python3-venv \
  python3-pip \
  libgl1 \
  libglib2.0-0 \
  libsm6 \
  libxrender1 \
  libxext6 \
  ca-certificates

echo
echo "[STEP 2/10] clone ComfyUI"
mkdir -p "${APP_ROOT}"
cd "${APP_ROOT}"

if [ ! -d "${APP_DIR}" ]; then
  git clone https://github.com/comfyanonymous/ComfyUI.git "${APP_DIR}"
else
  echo "[INFO] ComfyUI already exists: ${APP_DIR}"
fi

cd "${APP_DIR}"

echo
echo "[STEP 3/10] python venv"
if [ ! -d "${VENV_DIR}" ]; then
  python3 -m venv "${VENV_DIR}"
fi

source "${VENV_DIR}/bin/activate"

python -m pip install --upgrade pip setuptools wheel

echo
echo "[STEP 4/10] torch + base requirements"
python -m pip install --upgrade torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128
python -m pip install -r requirements.txt
python -m pip install --upgrade pillow numpy opencv-python imageio imageio-ffmpeg huggingface_hub safetensors

echo
echo "[STEP 5/10] custom nodes"
mkdir -p custom_nodes

install_node () {
  local repo_url="$1"
  local dir_name="$2"

  echo "[INFO] Installing node: ${dir_name}"
  if [ ! -d "custom_nodes/${dir_name}" ]; then
    git clone --depth 1 "${repo_url}" "custom_nodes/${dir_name}"
  else
    echo "[INFO] Already exists: custom_nodes/${dir_name}"
    (
      cd "custom_nodes/${dir_name}"
      git pull --ff-only || true
    )
  fi

  if [ -f "custom_nodes/${dir_name}/requirements.txt" ]; then
    python -m pip install -r "custom_nodes/${dir_name}/requirements.txt" || true
  fi

  if [ -f "custom_nodes/${dir_name}/requirements.pip" ]; then
    python -m pip install -r "custom_nodes/${dir_name}/requirements.pip" || true
  fi

  if [ -f "custom_nodes/${dir_name}/install.py" ]; then
    (
      cd "custom_nodes/${dir_name}"
      python install.py || true
    )
  fi
}

install_node "https://github.com/ltdrdata/ComfyUI-Manager.git" "ComfyUI-Manager"
install_node "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git" "ComfyUI-VideoHelperSuite"
install_node "https://github.com/kijai/ComfyUI-segment-anything-2.git" "ComfyUI-segment-anything-2"

echo
echo "[STEP 6/10] install self-contained SimpleMaskedMosaic node"
mkdir -p custom_nodes/ComfyUI-SimpleMaskedMosaic

cat > custom_nodes/ComfyUI-SimpleMaskedMosaic/__init__.py <<'PY'
from .simple_masked_mosaic import NODE_CLASS_MAPPINGS, NODE_DISPLAY_NAME_MAPPINGS
__all__ = ["NODE_CLASS_MAPPINGS", "NODE_DISPLAY_NAME_MAPPINGS"]
PY

cat > custom_nodes/ComfyUI-SimpleMaskedMosaic/simple_masked_mosaic.py <<'PY'
import numpy as np
import torch
from PIL import Image, ImageFilter

def _ensure_odd(n: int) -> int:
    n = int(max(1, n))
    return n if n % 2 == 1 else n + 1

class SimpleMaskedMosaic:
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "images": ("IMAGE",),
                "masks": ("MASK",),
                "block_size": ("INT", {"default": 18, "min": 2, "max": 128, "step": 1}),
                "grow_px": ("INT", {"default": 12, "min": 0, "max": 128, "step": 1}),
                "feather_px": ("INT", {"default": 4, "min": 0, "max": 64, "step": 1}),
                "strength": ("FLOAT", {"default": 1.0, "min": 0.0, "max": 1.0, "step": 0.05}),
            }
        }

    RETURN_TYPES = ("IMAGE",)
    RETURN_NAMES = ("images",)
    FUNCTION = "apply_mosaic"
    CATEGORY = "image/postprocessing"

    def _prep_mask(self, mask_np, grow_px, feather_px, strength):
        mask_img = Image.fromarray((np.clip(mask_np, 0.0, 1.0) * 255).astype(np.uint8), mode="L")

        if grow_px > 0:
            k = _ensure_odd(grow_px * 2 + 1)
            mask_img = mask_img.filter(ImageFilter.MaxFilter(k))

        if feather_px > 0:
            mask_img = mask_img.filter(ImageFilter.GaussianBlur(radius=feather_px))

        mask_arr = np.array(mask_img).astype(np.float32) / 255.0
        return np.clip(mask_arr * float(strength), 0.0, 1.0)

    def _pixelate(self, img_np, block_size):
        h, w, _ = img_np.shape
        pil = Image.fromarray(img_np, mode="RGB")
        small_w = max(1, w // max(1, block_size))
        small_h = max(1, h // max(1, block_size))
        small = pil.resize((small_w, small_h), resample=Image.BILINEAR)
        mosaic = small.resize((w, h), resample=Image.NEAREST)
        return np.array(mosaic)

    def apply_mosaic(self, images, masks, block_size, grow_px, feather_px, strength):
        if masks.ndim == 2:
            masks = masks.unsqueeze(0)

        if images.shape[0] != masks.shape[0]:
            if masks.shape[0] == 1:
                masks = masks.repeat(images.shape[0], 1, 1)
            else:
                masks = masks[:images.shape[0]]

        outputs = []

        for i in range(images.shape[0]):
            img = np.clip(images[i].cpu().numpy(), 0.0, 1.0)
            img_u8 = (img * 255.0).astype(np.uint8)

            if img_u8.shape[-1] == 4:
                img_u8 = img_u8[..., :3]

            mask = masks[i].cpu().numpy()
            mask_arr = self._prep_mask(mask, grow_px, feather_px, strength)[..., None]
            mosaic_u8 = self._pixelate(img_u8, block_size)

            blended = (img_u8.astype(np.float32) * (1.0 - mask_arr)) + (mosaic_u8.astype(np.float32) * mask_arr)
            blended = np.clip(blended, 0.0, 255.0).astype(np.uint8).astype(np.float32) / 255.0
            outputs.append(torch.from_numpy(blended))

        return (torch.stack(outputs, dim=0),)

NODE_CLASS_MAPPINGS = {
    "SimpleMaskedMosaic": SimpleMaskedMosaic
}

NODE_DISPLAY_NAME_MAPPINGS = {
    "SimpleMaskedMosaic": "Simple Masked Mosaic"
}
PY

echo
echo "[STEP 7/10] try SAM2 model download"
mkdir -p models/sam2

python - <<'PY'
from pathlib import Path
from huggingface_hub import hf_hub_download

dst = Path("models/sam2")
dst.mkdir(parents=True, exist_ok=True)

candidates = [
    ("Kijai/segment-anything-2", "sam2.1_hiera_small.safetensors"),
    ("Kijai/segment-anything-2", "sam2_hiera_small.safetensors"),
    ("Kijai/segment-anything-2", "sam2.1_hiera_small.pt"),
    ("Kijai/segment-anything-2", "sam2_hiera_small.pt"),
]

ok = False
for repo_id, filename in candidates:
    try:
        path = hf_hub_download(
            repo_id=repo_id,
            filename=filename,
            local_dir=str(dst),
            local_dir_use_symlinks=False
        )
        print(f"[OK] Downloaded: {path}")
        ok = True
        break
    except Exception as e:
        print(f"[WARN] failed: {repo_id} / {filename} / {e}")

if not ok:
    print("[WARN] SAM2 model auto-download failed.")
    print("[WARN] Put a SAM2 small model manually into: models/sam2/")
PY

echo
echo "[STEP 8/10] helper files"
mkdir -p "${APP_ROOT}/docs"

cat > "${APP_ROOT}/start_comfyui.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd "${APP_DIR}"
source "${VENV_DIR}/bin/activate"
python main.py --listen 0.0.0.0 --port ${PORT}
EOF
chmod +x "${APP_ROOT}/start_comfyui.sh"

cat > "${APP_ROOT}/docs/HOWTO_SAM2_VIDEO_MOSAIC.txt" <<'EOF'
SAM2 VIDEO MOSAIC V2

1) VHS_LoadVideo
2) SAM2 video tracking
3) Simple Masked Mosaic
4) VHS_VideoCombine

Recommended:
  block_size = 18
  grow_px    = 12
  feather_px = 4
  strength   = 1.0
EOF

echo
echo "[STEP 9/10] smoke test"
pkill -f "python main.py --listen 0.0.0.0 --port ${PORT}" || true
sleep 2

nohup bash -lc "cd '${APP_DIR}' && source '${VENV_DIR}/bin/activate' && python main.py --listen 0.0.0.0 --port ${PORT}" > "${SMOKE_LOG}" 2>&1 &
SMOKE_PID=$!

READY=0
for _ in $(seq 1 60); do
  sleep 2
  if curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
    READY=1
    break
  fi
  if ! kill -0 "${SMOKE_PID}" >/dev/null 2>&1; then
    break
  fi
done

IMPORT_FAILED=0
if grep -q "IMPORT FAILED" "${SMOKE_LOG}"; then
  IMPORT_FAILED=1
fi

kill "${SMOKE_PID}" >/dev/null 2>&1 || true
sleep 2
pkill -f "python main.py --listen 0.0.0.0 --port ${PORT}" || true

echo
echo "[STEP 10/10] summary"

[ -d "${APP_DIR}" ] && echo "[OK] ComfyUI base installed" || echo "[NG] ComfyUI base missing"
[ -d "${APP_DIR}/custom_nodes/ComfyUI-VideoHelperSuite" ] && echo "[OK] VHS nodes detected" || echo "[NG] VHS nodes missing"
[ -d "${APP_DIR}/custom_nodes/ComfyUI-segment-anything-2" ] && echo "[OK] SAM2 nodes detected" || echo "[NG] SAM2 nodes missing"
ls "${APP_DIR}/models/sam2"/* >/dev/null 2>&1 && echo "[OK] SAM2 model detected" || echo "[WARN] SAM2 model not detected"
[ -d "${APP_DIR}/custom_nodes/ComfyUI-SimpleMaskedMosaic" ] && echo "[OK] Simple Mosaic node installed" || echo "[NG] Simple Mosaic node missing"

if [ "${READY}" -eq 1 ]; then
  echo "[OK] ComfyUI startup smoke test passed"
else
  echo "[WARN] ComfyUI smoke test did not confirm HTTP ready"
fi

if [ "${IMPORT_FAILED}" -eq 0 ]; then
  echo "[OK] No IMPORT FAILED detected in smoke log"
else
  echo "[WARN] IMPORT FAILED detected in smoke log"
fi

echo
echo "============================================================"
echo "[INFO] APP ROOT : ${APP_ROOT}"
echo "[INFO] START CMD: bash ${APP_ROOT}/start_comfyui.sh"
echo "[INFO] DOC      : ${APP_ROOT}/docs/HOWTO_SAM2_VIDEO_MOSAIC.txt"
echo "[INFO] SMOKELOG : ${SMOKE_LOG}"
echo "[INFO] SETUPLOG : ${LOG_FILE}"
echo "============================================================"

if [ "${READY}" -eq 1 ]; then
  echo "[READY] Open port ${PORT}"
else
  echo "[WARN] Start once manually and inspect the log if needed"
fi
