#!/usr/bin/env bash
set -Eeuo pipefail

APP="/workspace/runpod-slim/ComfyUI-SAM2MosaicV2/ComfyUI"
VENV="$APP/.venv"
WF_DIR="$APP/user/default/workflows"

cd "$APP"
source "$VENV/bin/activate"

echo "[1/4] Updating local mosaic helper node..."
cat > "$APP/custom_nodes/ComfyUI-SimpleMaskedMosaic/__init__.py" <<'PY'
from .simple_masked_mosaic import NODE_CLASS_MAPPINGS, NODE_DISPLAY_NAME_MAPPINGS
__all__ = ["NODE_CLASS_MAPPINGS", "NODE_DISPLAY_NAME_MAPPINGS"]
PY

cat > "$APP/custom_nodes/ComfyUI-SimpleMaskedMosaic/simple_masked_mosaic.py" <<'PY'
import json
import numpy as np
import torch
from PIL import Image, ImageFilter

def _ensure_odd(n):
    n = int(max(1, n))
    return n if n % 2 else n + 1

class ManualSAM2Point:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {
            "x": ("INT", {"default": 512, "min": 0, "max": 8192, "step": 1}),
            "y": ("INT", {"default": 512, "min": 0, "max": 8192, "step": 1}),
            "negative_x": ("INT", {"default": -1, "min": -1, "max": 8192, "step": 1}),
            "negative_y": ("INT", {"default": -1, "min": -1, "max": 8192, "step": 1}),
        }}
    RETURN_TYPES = ("STRING","STRING")
    RETURN_NAMES = ("coordinates_positive","coordinates_negative")
    FUNCTION = "make"
    CATEGORY = "SAM2 Mosaic"

    def make(self, x, y, negative_x, negative_y):
        pos = json.dumps([{"x": int(x), "y": int(y)}])
        neg = ""
        if negative_x >= 0 and negative_y >= 0:
            neg = json.dumps([{"x": int(negative_x), "y": int(negative_y)}])
        return (pos, neg)

class SimpleMaskedMosaic:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {
            "images": ("IMAGE",),
            "masks": ("MASK",),
            "block_size": ("INT", {"default":18,"min":2,"max":128,"step":1}),
            "grow_px": ("INT", {"default":12,"min":0,"max":128,"step":1}),
            "feather_px": ("INT", {"default":4,"min":0,"max":64,"step":1}),
            "strength": ("FLOAT", {"default":1.0,"min":0.0,"max":1.0,"step":0.05}),
        }}

    RETURN_TYPES=("IMAGE",)
    RETURN_NAMES=("images",)
    FUNCTION="apply_mosaic"
    CATEGORY="SAM2 Mosaic"

    def _prep_mask(self, mask_np, grow_px, feather_px, strength):
        m = Image.fromarray((np.clip(mask_np,0,1)*255).astype(np.uint8), mode="L")
        if grow_px > 0:
            m = m.filter(ImageFilter.MaxFilter(_ensure_odd(grow_px*2+1)))
        if feather_px > 0:
            m = m.filter(ImageFilter.GaussianBlur(radius=feather_px))
        a=np.array(m).astype(np.float32)/255.0
        return np.clip(a*float(strength),0,1)

    def _pixelate(self, img, block):
        h,w,_=img.shape
        p=Image.fromarray(img,mode="RGB")
        sw=max(1,w//max(1,block)); sh=max(1,h//max(1,block))
        p=p.resize((sw,sh),Image.BILINEAR).resize((w,h),Image.NEAREST)
        return np.array(p)

    def apply_mosaic(self, images, masks, block_size, grow_px, feather_px, strength):
        if masks.ndim == 2:
            masks=masks.unsqueeze(0)
        if images.shape[0] != masks.shape[0]:
            if masks.shape[0] == 1:
                masks=masks.repeat(images.shape[0],1,1)
            else:
                masks=masks[:images.shape[0]]

        out=[]
        for i in range(images.shape[0]):
            im=np.clip(images[i].cpu().numpy(),0,1)
            im8=(im*255).astype(np.uint8)
            if im8.shape[-1] == 4:
                im8=im8[...,:3]
            ma=self._prep_mask(masks[i].cpu().numpy(),grow_px,feather_px,strength)[...,None]
            mo=self._pixelate(im8,block_size)
            result=im8.astype(np.float32)*(1-ma)+mo.astype(np.float32)*ma
            out.append(torch.from_numpy(np.clip(result,0,255).astype(np.uint8).astype(np.float32)/255.0))
        return (torch.stack(out,0),)

NODE_CLASS_MAPPINGS={
    "ManualSAM2Point": ManualSAM2Point,
    "SimpleMaskedMosaic": SimpleMaskedMosaic,
}
NODE_DISPLAY_NAME_MAPPINGS={
    "ManualSAM2Point": "SAM2 Manual Point",
    "SimpleMaskedMosaic": "Simple Masked Mosaic",
}
PY

echo "[2/4] Installing workflow..."
mkdir -p "$WF_DIR"
cat > "$WF_DIR/SAM2_Video_Mosaic_V2.json" <<'JSON'
{
  "last_node_id": 6,
  "last_link_id": 7,
  "nodes": [
    {
      "id": 1,
      "type": "VHS_LoadVideo",
      "pos": [
        20,
        120
      ],
      "size": [
        320,
        470
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "meta_batch",
          "type": "VHS_BatchManager",
          "link": null
        },
        {
          "name": "vae",
          "type": "VAE",
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "IMAGE",
          "type": "IMAGE",
          "links": [
            1,
            5
          ],
          "slot_index": 0,
          "shape": 3
        },
        {
          "name": "frame_count",
          "type": "INT",
          "links": null,
          "shape": 3
        },
        {
          "name": "audio",
          "type": "AUDIO",
          "links": [
            7
          ],
          "slot_index": 2,
          "shape": 3
        },
        {
          "name": "video_info",
          "type": "VHS_VIDEOINFO",
          "links": null,
          "shape": 3
        }
      ],
      "properties": {
        "Node name for S&R": "VHS_LoadVideo"
      },
      "widgets_values": {
        "video": "example.mp4",
        "force_rate": 0,
        "force_size": "Disabled",
        "custom_width": 0,
        "custom_height": 0,
        "frame_load_cap": 0,
        "skip_first_frames": 0,
        "select_every_nth": 1,
        "choose video to upload": "image"
      }
    },
    {
      "id": 2,
      "type": "DownloadAndLoadSAM2Model",
      "pos": [
        30,
        -120
      ],
      "size": [
        350,
        130
      ],
      "flags": {},
      "order": 1,
      "mode": 0,
      "outputs": [
        {
          "name": "sam2_model",
          "type": "SAM2MODEL",
          "links": [
            2
          ],
          "slot_index": 0,
          "shape": 3
        }
      ],
      "properties": {
        "Node name for S&R": "DownloadAndLoadSAM2Model"
      },
      "widgets_values": [
        "sam2.1_hiera_small.safetensors",
        "video",
        "cuda",
        "fp16"
      ]
    },
    {
      "id": 3,
      "type": "ManualSAM2Point",
      "pos": [
        405,
        50
      ],
      "size": [
        260,
        150
      ],
      "flags": {},
      "order": 2,
      "mode": 0,
      "outputs": [
        {
          "name": "coordinates_positive",
          "type": "STRING",
          "links": [
            3
          ],
          "slot_index": 0,
          "shape": 3
        },
        {
          "name": "coordinates_negative",
          "type": "STRING",
          "links": null,
          "slot_index": 1,
          "shape": 3
        }
      ],
      "properties": {
        "Node name for S&R": "ManualSAM2Point"
      },
      "widgets_values": [
        512,
        512,
        -1,
        -1
      ]
    },
    {
      "id": 4,
      "type": "Sam2Segmentation",
      "pos": [
        700,
        80
      ],
      "size": [
        340,
        220
      ],
      "flags": {},
      "order": 3,
      "mode": 0,
      "inputs": [
        {
          "name": "sam2_model",
          "type": "SAM2MODEL",
          "link": 2
        },
        {
          "name": "image",
          "type": "IMAGE",
          "link": 1
        },
        {
          "name": "coordinates_positive",
          "type": "STRING",
          "link": 3
        }
      ],
      "outputs": [
        {
          "name": "mask",
          "type": "MASK",
          "links": [
            4
          ],
          "slot_index": 0,
          "shape": 3
        }
      ],
      "properties": {
        "Node name for S&R": "Sam2Segmentation"
      },
      "widgets_values": [
        false,
        false
      ]
    },
    {
      "id": 5,
      "type": "SimpleMaskedMosaic",
      "pos": [
        1090,
        90
      ],
      "size": [
        300,
        220
      ],
      "flags": {},
      "order": 4,
      "mode": 0,
      "inputs": [
        {
          "name": "images",
          "type": "IMAGE",
          "link": 5
        },
        {
          "name": "masks",
          "type": "MASK",
          "link": 4
        }
      ],
      "outputs": [
        {
          "name": "images",
          "type": "IMAGE",
          "links": [
            6
          ],
          "slot_index": 0,
          "shape": 3
        }
      ],
      "properties": {
        "Node name for S&R": "SimpleMaskedMosaic"
      },
      "widgets_values": [
        18,
        12,
        4,
        1.0
      ]
    },
    {
      "id": 6,
      "type": "VHS_VideoCombine",
      "pos": [
        1460,
        90
      ],
      "size": [
        330,
        520
      ],
      "flags": {},
      "order": 5,
      "mode": 0,
      "inputs": [
        {
          "name": "images",
          "type": "IMAGE",
          "link": 6
        },
        {
          "name": "audio",
          "type": "AUDIO",
          "link": 7
        },
        {
          "name": "meta_batch",
          "type": "VHS_BatchManager",
          "link": null
        },
        {
          "name": "vae",
          "type": "VAE",
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "Filenames",
          "type": "VHS_FILENAMES",
          "links": null,
          "shape": 3
        }
      ],
      "properties": {
        "Node name for S&R": "VHS_VideoCombine"
      },
      "widgets_values": {
        "frame_rate": 30,
        "loop_count": 0,
        "filename_prefix": "mosaic/SAM2_Mosaic",
        "format": "video/h264-mp4",
        "pix_fmt": "yuv420p",
        "crf": 19,
        "save_metadata": true,
        "pingpong": false,
        "save_output": true
      }
    }
  ],
  "links": [
    [
      1,
      1,
      0,
      4,
      1,
      "IMAGE"
    ],
    [
      2,
      2,
      0,
      4,
      0,
      "SAM2MODEL"
    ],
    [
      3,
      3,
      0,
      4,
      2,
      "STRING"
    ],
    [
      4,
      4,
      0,
      5,
      1,
      "MASK"
    ],
    [
      5,
      1,
      0,
      5,
      0,
      "IMAGE"
    ],
    [
      6,
      5,
      0,
      6,
      0,
      "IMAGE"
    ],
    [
      7,
      1,
      2,
      6,
      1,
      "AUDIO"
    ]
  ],
  "groups": [],
  "config": {},
  "extra": {
    "ds": {
      "scale": 0.85,
      "offset": [
        30,
        220
      ]
    }
  },
  "version": 0.4
}
JSON

echo "[3/4] Checking SAM2 model..."
mkdir -p "$APP/models/sam2"
python - <<'PY'
from huggingface_hub import hf_hub_download
from pathlib import Path
dst=Path("models/sam2")
target=dst/"sam2.1_hiera_small-fp16.safetensors"
if target.exists():
    print("[OK] SAM2 model already exists:", target)
else:
    p=hf_hub_download(
        repo_id="Kijai/sam2-safetensors",
        filename="sam2.1_hiera_small-fp16.safetensors",
        local_dir=str(dst)
    )
    print("[OK] SAM2 model:",p)
PY

echo "[4/4] Done"
echo
echo "[OK] Workflow installed:"
echo "     $WF_DIR/SAM2_Video_Mosaic_V2.json"
echo
echo "Restart ComfyUI:"
echo "pkill -f 'python main.py' || true"
echo "bash /workspace/runpod-slim/ComfyUI-SAM2MosaicV2/start_comfyui.sh"
echo
echo "Then open Workflows -> SAM2_Video_Mosaic_V2"
