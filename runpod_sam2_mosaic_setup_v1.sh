#!/usr/bin/env bash
set -Eeuo pipefail

# RunPod / ComfyUI SAM2 Tracked Mosaic setup
# Version: 1.0
# Designed for /workspace/runpod-slim/ComfyUI, but COMFY_DIR can override it.
#
# Installs/ensures:
#   - ComfyUI-VideoHelperSuite
#   - ComfyUI-KJNodes (Points Editor)
#   - kijai/ComfyUI-segment-anything-2
#   - SAM2.1 Hiera Small safetensors
#   - lightweight Mosaic Toolkit custom nodes
#   - ready-to-open SAM2_Tracked_Mosaic workflow
#
# Safe defaults:
#   - existing repos are NOT updated unless MOSAIC_UPDATE_NODES=1
#   - existing model files are not redownloaded

COMFY_DIR="${COMFY_DIR:-/workspace/runpod-slim/ComfyUI}"
MOSAIC_UPDATE_NODES="${MOSAIC_UPDATE_NODES:-0}"
MODEL_NAME="sam2.1_hiera_small-fp16.safetensors"
MODEL_URL="https://huggingface.co/Kijai/sam2-safetensors/resolve/main/${MODEL_NAME}?download=true"
MODEL_SHA256="b766bb5aea81d3b7a09c8d3f74d1527144bb848d43e5bb1fe4152528a60c683b"

log()  { printf '\n\033[1;36m[MOSAIC]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

trap 'printf "\n\033[1;31m[ERROR]\033[0m setup stopped at line %s\n" "$LINENO" >&2' ERR

[[ -d "$COMFY_DIR" ]] || die "ComfyUI directory not found: $COMFY_DIR"
[[ -d "$COMFY_DIR/custom_nodes" ]] || die "custom_nodes not found under $COMFY_DIR"

command -v git >/dev/null 2>&1 || die "git is required."
command -v curl >/dev/null 2>&1 || die "curl is required."
command -v ffmpeg >/dev/null 2>&1 || warn "ffmpeg not found in PATH. VideoHelperSuite MP4 output may fail."

detect_python() {
    local p pid exe
    pid="$(pgrep -f "$COMFY_DIR/main.py" 2>/dev/null | head -n1 || true)"
    if [[ -n "$pid" && -e "/proc/$pid/exe" ]]; then
        exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
        if [[ -n "$exe" ]] && "$exe" -c 'import sys; print(sys.version_info[:2])' >/dev/null 2>&1; then
            printf '%s' "$exe"
            return 0
        fi
    fi

    for p in "$COMFY_DIR/.venv/bin/python" /usr/bin/python3.12 /usr/bin/python3 python3; do
        if command -v "$p" >/dev/null 2>&1 || [[ -x "$p" ]]; then
            if "$p" -c 'import sys; print(sys.version_info[:2])' >/dev/null 2>&1; then
                printf '%s' "$p"
                return 0
            fi
        fi
    done
    return 1
}

PYTHON_BIN="$(detect_python || true)"
[[ -n "$PYTHON_BIN" ]] || die "Could not find the Python interpreter used by ComfyUI."
log "ComfyUI: $COMFY_DIR"
log "Python: $PYTHON_BIN"
"$PYTHON_BIN" --version

ensure_repo() {
    local name="$1"
    local url="$2"
    local dst="$3"
    LAST_CLONED=0

    if [[ -d "$dst/.git" ]]; then
        if [[ "$MOSAIC_UPDATE_NODES" == "1" ]]; then
            log "Updating $name"
            if ! git -C "$dst" pull --ff-only; then
                warn "$name has local changes or cannot fast-forward; keeping current checkout."
            fi
        else
            ok "$name already installed (kept as-is)"
        fi
        return 0
    fi

    if [[ -d "$dst" ]]; then
        warn "$name directory exists but is not a git checkout: $dst"
        warn "Keeping it untouched."
        return 0
    fi

    log "Installing $name"
    git clone --depth 1 "$url" "$dst"
    LAST_CLONED=1
}

install_requirements_if_new() {
    local dst="$1"
    local was_cloned="$2"
    if [[ "$was_cloned" == "1" && -f "$dst/requirements.txt" ]]; then
        log "Installing requirements for $(basename "$dst")"
        "$PYTHON_BIN" -m pip install --disable-pip-version-check -r "$dst/requirements.txt"
    fi
}

CUSTOM="$COMFY_DIR/custom_nodes"

ensure_repo "VideoHelperSuite" \
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git" \
    "$CUSTOM/ComfyUI-VideoHelperSuite"
vhs_cloned="$LAST_CLONED"
install_requirements_if_new "$CUSTOM/ComfyUI-VideoHelperSuite" "$vhs_cloned"

ensure_repo "KJNodes" \
    "https://github.com/kijai/ComfyUI-KJNodes.git" \
    "$CUSTOM/ComfyUI-KJNodes"
kj_cloned="$LAST_CLONED"
install_requirements_if_new "$CUSTOM/ComfyUI-KJNodes" "$kj_cloned"

# PointsEditor is required for click-based target selection. Only update KJNodes
# automatically when the installed checkout is too old to contain it.
if ! grep -Rqs "class PointsEditor" "$CUSTOM/ComfyUI-KJNodes" 2>/dev/null; then
    warn "Installed KJNodes does not contain PointsEditor; attempting a safe fast-forward update."
    if [[ -d "$CUSTOM/ComfyUI-KJNodes/.git" ]] && git -C "$CUSTOM/ComfyUI-KJNodes" pull --ff-only; then
        ok "KJNodes updated for PointsEditor support."
    else
        die "PointsEditor is missing and KJNodes could not be safely updated."
    fi
fi

grep -Rqs "class PointsEditor" "$CUSTOM/ComfyUI-KJNodes" 2>/dev/null \
    || die "PointsEditor is still unavailable in KJNodes."

ensure_repo "ComfyUI-segment-anything-2" \
    "https://github.com/kijai/ComfyUI-segment-anything-2.git" \
    "$CUSTOM/ComfyUI-segment-anything-2"

# Kijai SAM2 repo currently declares no external project dependencies.
# Still verify imports we rely on.
log "Checking base Python dependencies"
"$PYTHON_BIN" - <<'PY'
import importlib
mods = ["torch", "yaml", "numpy", "PIL"]
missing = []
for m in mods:
    try:
        importlib.import_module(m)
    except Exception:
        missing.append(m)
if missing:
    raise SystemExit("Missing Python modules: " + ", ".join(missing))
print("Core Python modules: OK")
PY

MODEL_DIR="$COMFY_DIR/models/sam2"
MODEL_PATH="$MODEL_DIR/$MODEL_NAME"
mkdir -p "$MODEL_DIR"

model_ok=0
if [[ -s "$MODEL_PATH" ]] && [[ "$(stat -c %s "$MODEL_PATH" 2>/dev/null || echo 0)" -gt 70000000 ]]; then
    if command -v sha256sum >/dev/null 2>&1; then
        current_sha="$(sha256sum "$MODEL_PATH" | awk '{print $1}')"
        if [[ "$current_sha" == "$MODEL_SHA256" ]]; then
            model_ok=1
        else
            warn "Existing SAM2 model checksum mismatch; redownloading."
        fi
    else
        model_ok=1
    fi
fi

if [[ "$model_ok" == "1" ]]; then
    ok "SAM2.1 Small FP16 model already present: $MODEL_PATH"
else
    log "Downloading SAM2.1 Small FP16 (~92 MB)"
    tmp="$MODEL_PATH.part"
    rm -f "$tmp"
    curl -fL --retry 5 --retry-delay 2 --connect-timeout 20 \
        -o "$tmp" "$MODEL_URL"
    size="$(stat -c %s "$tmp" 2>/dev/null || echo 0)"
    [[ "$size" -gt 70000000 ]] || die "SAM2 model download looks incomplete ($size bytes)."
    if command -v sha256sum >/dev/null 2>&1; then
        downloaded_sha="$(sha256sum "$tmp" | awk '{print $1}')"
        [[ "$downloaded_sha" == "$MODEL_SHA256" ]] || die "SAM2 model SHA256 mismatch."
    fi
    mv -f "$tmp" "$MODEL_PATH"
    ok "Downloaded and verified: $MODEL_PATH"
fi

TOOLKIT="$CUSTOM/ComfyUI-MosaicToolkit"
mkdir -p "$TOOLKIT"

cat > "$TOOLKIT/__init__.py" <<'PY'
import json
import torch
import torch.nn.functional as F

class MosaicEditorPrep:
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "images": ("IMAGE",),
                "canvas_size": ("INT", {"default": 768, "min": 256, "max": 1536, "step": 64}),
            }
        }

    RETURN_TYPES = ("IMAGE", "STRING")
    RETURN_NAMES = ("editor_image", "mapping")
    FUNCTION = "prepare"
    CATEGORY = "Mosaic Toolkit"

    def prepare(self, images, canvas_size):
        if images is None or images.shape[0] == 0:
            raise ValueError("MosaicEditorPrep: no input frames.")

        frame = images[0:1]
        _, h, w, c = frame.shape
        scale = min(canvas_size / float(w), canvas_size / float(h))
        new_w = max(1, int(round(w * scale)))
        new_h = max(1, int(round(h * scale)))
        off_x = (canvas_size - new_w) // 2
        off_y = (canvas_size - new_h) // 2

        x = frame.permute(0, 3, 1, 2)
        resized = F.interpolate(x, size=(new_h, new_w), mode="bilinear", align_corners=False)
        canvas = torch.zeros((1, c, canvas_size, canvas_size), dtype=resized.dtype, device=resized.device)
        canvas[:, :, off_y:off_y + new_h, off_x:off_x + new_w] = resized
        editor_image = canvas.permute(0, 2, 3, 1).cpu()

        mapping = json.dumps({
            "orig_w": int(w),
            "orig_h": int(h),
            "canvas": int(canvas_size),
            "scale": float(scale),
            "offset_x": int(off_x),
            "offset_y": int(off_y),
            "scaled_w": int(new_w),
            "scaled_h": int(new_h),
        })
        return (editor_image, mapping)


class MosaicMapCoordinates:
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "positive_coords": ("STRING", {"forceInput": True}),
                "negative_coords": ("STRING", {"forceInput": True}),
                "mapping": ("STRING", {"forceInput": True}),
            }
        }

    RETURN_TYPES = ("STRING", "STRING")
    RETURN_NAMES = ("positive_pixels", "negative_pixels")
    FUNCTION = "map_coords"
    CATEGORY = "Mosaic Toolkit"

    @staticmethod
    def _parse_points(value):
        if value is None or value == "":
            return []
        if isinstance(value, list):
            return value
        try:
            return json.loads(value.replace("'", '"'))
        except Exception as exc:
            raise ValueError(f"Invalid point JSON: {value}") from exc

    def map_coords(self, positive_coords, negative_coords, mapping):
        pos = self._parse_points(positive_coords)
        neg = self._parse_points(negative_coords)
        if not pos:
            raise ValueError("No positive point selected. Add at least one green point in Points Editor.")

        m = json.loads(mapping)
        scale = float(m["scale"])
        ox = float(m["offset_x"])
        oy = float(m["offset_y"])
        ow = int(m["orig_w"])
        oh = int(m["orig_h"])

        def convert(points):
            out = []
            for p in points:
                x = (float(p["x"]) - ox) / scale
                y = (float(p["y"]) - oy) / scale
                x = max(0.0, min(float(ow - 1), x))
                y = max(0.0, min(float(oh - 1), y))
                out.append({"x": int(round(x)), "y": int(round(y))})
            return out

        return (json.dumps(convert(pos)), json.dumps(convert(neg)))


class MosaicMaskedVideo:
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "images": ("IMAGE",),
                "masks": ("MASK",),
                "block_size": ("INT", {"default": 24, "min": 2, "max": 256, "step": 1,
                                      "tooltip": "Larger = stronger/coarser mosaic."}),
                "grow_px": ("INT", {"default": 12, "min": 0, "max": 256, "step": 1,
                                   "tooltip": "Expand tracked mask outward by this many pixels."}),
                "feather_px": ("INT", {"default": 2, "min": 0, "max": 64, "step": 1,
                                      "tooltip": "Soften the edge of the mosaic mask."}),
                "strength": ("FLOAT", {"default": 1.0, "min": 0.0, "max": 1.0, "step": 0.05}),
            }
        }

    RETURN_TYPES = ("IMAGE", "MASK")
    RETURN_NAMES = ("mosaic_video", "effective_mask")
    FUNCTION = "apply"
    CATEGORY = "Mosaic Toolkit"

    def apply(self, images, masks, block_size, grow_px, feather_px, strength):
        if images is None or images.shape[0] == 0:
            raise ValueError("MosaicMaskedVideo: no images.")
        if masks is None or masks.numel() == 0:
            raise ValueError("MosaicMaskedVideo: no masks.")

        b, h, w, c = images.shape
        device = images.device
        dtype = images.dtype

        mask = masks
        if mask.ndim == 4:
            mask = mask[:, 0, :, :]
        if mask.ndim != 3:
            raise ValueError(f"Expected MASK [B,H,W], got {tuple(mask.shape)}")

        if mask.shape[0] == 1 and b > 1:
            mask = mask.repeat(b, 1, 1)
        elif mask.shape[0] != b:
            raise ValueError(
                f"Frame/mask count mismatch: video={b}, masks={mask.shape[0]}. "
                "Use one tracked object per workflow or combine masks to one mask per frame."
            )

        mask = mask.to(device=device, dtype=torch.float32).unsqueeze(1)
        if mask.shape[-2:] != (h, w):
            mask = F.interpolate(mask, size=(h, w), mode="bilinear", align_corners=False)

        mask = mask.clamp(0, 1)

        if grow_px > 0:
            k = int(grow_px) * 2 + 1
            mask = F.max_pool2d(mask, kernel_size=k, stride=1, padding=grow_px)

        if feather_px > 0:
            k = int(feather_px) * 2 + 1
            mask = F.avg_pool2d(mask, kernel_size=k, stride=1, padding=feather_px)

        block = max(2, int(block_size))
        small_h = max(1, (h + block - 1) // block)
        small_w = max(1, (w + block - 1) // block)

        x = images.permute(0, 3, 1, 2)
        low = F.interpolate(x, size=(small_h, small_w), mode="area")
        pixelated = F.interpolate(low, size=(h, w), mode="nearest")

        alpha = (mask * float(strength)).clamp(0, 1).to(dtype=dtype)
        out = x * (1.0 - alpha) + pixelated * alpha
        out = out.permute(0, 2, 3, 1).clamp(0, 1).cpu()
        return (out, mask.squeeze(1).cpu())


class MosaicVideoInfoFPS:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"video_info": ("VHS_VIDEOINFO",)}}

    RETURN_TYPES = ("FLOAT",)
    RETURN_NAMES = ("fps",)
    FUNCTION = "get_fps"
    CATEGORY = "Mosaic Toolkit"

    def get_fps(self, video_info):
        if not isinstance(video_info, dict):
            raise ValueError("Expected VHS_VIDEOINFO dictionary.")
        fps = video_info.get("loaded_fps", video_info.get("source_fps", 24.0))
        return (float(fps),)


NODE_CLASS_MAPPINGS = {
    "MosaicEditorPrep": MosaicEditorPrep,
    "MosaicMapCoordinates": MosaicMapCoordinates,
    "MosaicMaskedVideo": MosaicMaskedVideo,
    "MosaicVideoInfoFPS": MosaicVideoInfoFPS,
}

NODE_DISPLAY_NAME_MAPPINGS = {
    "MosaicEditorPrep": "Mosaic - Prepare Point Editor",
    "MosaicMapCoordinates": "Mosaic - Map Editor Points",
    "MosaicMaskedVideo": "Mosaic - Apply Tracked Mosaic",
    "MosaicVideoInfoFPS": "Mosaic - Original FPS",
}

PY

"$PYTHON_BIN" -m py_compile "$TOOLKIT/__init__.py"
ok "Mosaic Toolkit custom node syntax: OK"

# Workflow locations: current ComfyUI user workflow path + a simple backup copy.
WF_USER_DIR="$COMFY_DIR/user/default/workflows"
WF_BACKUP_DIR="$COMFY_DIR/workflows"
mkdir -p "$WF_USER_DIR" "$WF_BACKUP_DIR"

cat > "$WF_USER_DIR/SAM2_Tracked_Mosaic.json" <<'JSON'
{
  "last_node_id": 10,
  "last_link_id": 17,
  "nodes": [
    {
      "id": 1,
      "type": "VHS_LoadVideo",
      "pos": [
        20,
        20
      ],
      "size": [
        360,
        330
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "IMAGE",
          "type": "IMAGE",
          "links": [
            1,
            8,
            12
          ],
          "slot_index": 0
        },
        {
          "name": "frame_count",
          "type": "INT",
          "links": null,
          "slot_index": 1
        },
        {
          "name": "audio",
          "type": "AUDIO",
          "links": [
            17
          ],
          "slot_index": 2
        },
        {
          "name": "video_info",
          "type": "VHS_VIDEOINFO",
          "links": [
            14
          ],
          "slot_index": 3
        }
      ],
      "properties": {
        "Node name for S&R": "VHS_LoadVideo"
      },
      "widgets_values": [
        "",
        0,
        0,
        0,
        0,
        0,
        1,
        "None"
      ],
      "title": "1. Load Video"
    },
    {
      "id": 2,
      "type": "MosaicEditorPrep",
      "pos": [
        430,
        20
      ],
      "size": [
        330,
        150
      ],
      "flags": {},
      "order": 1,
      "mode": 0,
      "inputs": [
        {
          "name": "images",
          "type": "IMAGE",
          "link": 1
        }
      ],
      "outputs": [
        {
          "name": "editor_image",
          "type": "IMAGE",
          "links": [
            2
          ],
          "slot_index": 0
        },
        {
          "name": "mapping",
          "type": "STRING",
          "links": [
            5
          ],
          "slot_index": 1
        }
      ],
      "properties": {
        "Node name for S&R": "MosaicEditorPrep"
      },
      "widgets_values": [
        768
      ],
      "title": "2. Preserve Aspect Ratio for Point Editor"
    },
    {
      "id": 3,
      "type": "PointsEditor",
      "pos": [
        810,
        20
      ],
      "size": [
        520,
        560
      ],
      "flags": {},
      "order": 2,
      "mode": 0,
      "inputs": [
        {
          "name": "bg_image",
          "type": "IMAGE",
          "link": 2
        }
      ],
      "outputs": [
        {
          "name": "positive_coords",
          "type": "STRING",
          "links": [
            3
          ],
          "slot_index": 0
        },
        {
          "name": "negative_coords",
          "type": "STRING",
          "links": [
            4
          ],
          "slot_index": 1
        },
        {
          "name": "bbox",
          "type": "BBOX",
          "links": null,
          "slot_index": 2
        },
        {
          "name": "bbox_mask",
          "type": "MASK",
          "links": null,
          "slot_index": 3
        },
        {
          "name": "cropped_image",
          "type": "IMAGE",
          "links": null,
          "slot_index": 4
        }
      ],
      "properties": {
        "Node name for S&R": "PointsEditor"
      },
      "widgets_values": [
        "{\"positive\":[{\"x\":384,\"y\":384}],\"negative\":[]}",
        "[{\"x\":384,\"y\":384}]",
        "[]",
        "[{}]",
        "[{}]",
        "xyxy",
        768,
        768,
        false,
        null,
        null,
        null
      ],
      "title": "3. Select Target (green = include, red = exclude)"
    },
    {
      "id": 4,
      "type": "MosaicMapCoordinates",
      "pos": [
        1380,
        80
      ],
      "size": [
        330,
        180
      ],
      "flags": {},
      "order": 3,
      "mode": 0,
      "inputs": [
        {
          "name": "positive_coords",
          "type": "STRING",
          "link": 3
        },
        {
          "name": "negative_coords",
          "type": "STRING",
          "link": 4
        },
        {
          "name": "mapping",
          "type": "STRING",
          "link": 5
        }
      ],
      "outputs": [
        {
          "name": "positive_pixels",
          "type": "STRING",
          "links": [
            7
          ],
          "slot_index": 0
        },
        {
          "name": "negative_pixels",
          "type": "STRING",
          "links": [
            9
          ],
          "slot_index": 1
        }
      ],
      "properties": {
        "Node name for S&R": "MosaicMapCoordinates"
      },
      "widgets_values": [],
      "title": "4. Map Editor Point to Original Video"
    },
    {
      "id": 5,
      "type": "DownloadAndLoadSAM2Model",
      "pos": [
        430,
        250
      ],
      "size": [
        330,
        200
      ],
      "flags": {},
      "order": 4,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "sam2_model",
          "type": "SAM2MODEL",
          "links": [
            6
          ],
          "slot_index": 0
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
      ],
      "title": "5. SAM2.1 Small"
    },
    {
      "id": 6,
      "type": "Sam2VideoSegmentationAddPoints",
      "pos": [
        1760,
        80
      ],
      "size": [
        390,
        280
      ],
      "flags": {},
      "order": 5,
      "mode": 0,
      "inputs": [
        {
          "name": "sam2_model",
          "type": "SAM2MODEL",
          "link": 6
        },
        {
          "name": "coordinates_positive",
          "type": "STRING",
          "link": 7
        },
        {
          "name": "image",
          "type": "IMAGE",
          "link": 8
        },
        {
          "name": "coordinates_negative",
          "type": "STRING",
          "link": 9
        }
      ],
      "outputs": [
        {
          "name": "sam2_model",
          "type": "SAM2MODEL",
          "links": [
            10
          ],
          "slot_index": 0
        },
        {
          "name": "inference_state",
          "type": "SAM2INFERENCESTATE",
          "links": [
            11
          ],
          "slot_index": 1
        }
      ],
      "properties": {
        "Node name for S&R": "Sam2VideoSegmentationAddPoints"
      },
      "widgets_values": [
        0,
        0
      ],
      "title": "6. Initialize SAM2 Tracking"
    },
    {
      "id": 7,
      "type": "Sam2VideoSegmentation",
      "pos": [
        2210,
        100
      ],
      "size": [
        330,
        150
      ],
      "flags": {},
      "order": 6,
      "mode": 0,
      "inputs": [
        {
          "name": "sam2_model",
          "type": "SAM2MODEL",
          "link": 10
        },
        {
          "name": "inference_state",
          "type": "SAM2INFERENCESTATE",
          "link": 11
        }
      ],
      "outputs": [
        {
          "name": "mask",
          "type": "MASK",
          "links": [
            13
          ],
          "slot_index": 0
        }
      ],
      "properties": {
        "Node name for S&R": "Sam2VideoSegmentation"
      },
      "widgets_values": [
        false
      ],
      "title": "7. Track Through Video"
    },
    {
      "id": 8,
      "type": "MosaicMaskedVideo",
      "pos": [
        2590,
        60
      ],
      "size": [
        370,
        260
      ],
      "flags": {},
      "order": 7,
      "mode": 0,
      "inputs": [
        {
          "name": "images",
          "type": "IMAGE",
          "link": 12
        },
        {
          "name": "masks",
          "type": "MASK",
          "link": 13
        }
      ],
      "outputs": [
        {
          "name": "mosaic_video",
          "type": "IMAGE",
          "links": [
            15
          ],
          "slot_index": 0
        },
        {
          "name": "effective_mask",
          "type": "MASK",
          "links": null,
          "slot_index": 1
        }
      ],
      "properties": {
        "Node name for S&R": "MosaicMaskedVideo"
      },
      "widgets_values": [
        24,
        12,
        2,
        1.0
      ],
      "title": "8. Mosaic Strength / Range"
    },
    {
      "id": 9,
      "type": "MosaicVideoInfoFPS",
      "pos": [
        2210,
        330
      ],
      "size": [
        300,
        100
      ],
      "flags": {},
      "order": 8,
      "mode": 0,
      "inputs": [
        {
          "name": "video_info",
          "type": "VHS_VIDEOINFO",
          "link": 14
        }
      ],
      "outputs": [
        {
          "name": "fps",
          "type": "FLOAT",
          "links": [
            16
          ],
          "slot_index": 0
        }
      ],
      "properties": {
        "Node name for S&R": "MosaicVideoInfoFPS"
      },
      "widgets_values": [],
      "title": "Original FPS"
    },
    {
      "id": 10,
      "type": "VHS_VideoCombine",
      "pos": [
        3060,
        80
      ],
      "size": [
        420,
        320
      ],
      "flags": {},
      "order": 9,
      "mode": 0,
      "inputs": [
        {
          "name": "images",
          "type": "IMAGE",
          "link": 15
        },
        {
          "name": "frame_rate",
          "type": "FLOAT",
          "link": 16,
          "widget": {
            "name": "frame_rate"
          }
        },
        {
          "name": "audio",
          "type": "AUDIO",
          "link": 17
        }
      ],
      "outputs": [
        {
          "name": "Filenames",
          "type": "VHS_FILENAMES",
          "links": null,
          "slot_index": 0
        }
      ],
      "properties": {
        "Node name for S&R": "VHS_VideoCombine"
      },
      "widgets_values": [
        0,
        "mosaic/mosaic",
        "video/h264-mp4",
        false,
        true,
        "yuv420p",
        19,
        true,
        false
      ],
      "title": "9. Save MP4 + Original Audio"
    }
  ],
  "links": [
    [
      1,
      1,
      0,
      2,
      0,
      "IMAGE"
    ],
    [
      2,
      2,
      0,
      3,
      0,
      "IMAGE"
    ],
    [
      3,
      3,
      0,
      4,
      0,
      "STRING"
    ],
    [
      4,
      3,
      1,
      4,
      1,
      "STRING"
    ],
    [
      5,
      2,
      1,
      4,
      2,
      "STRING"
    ],
    [
      6,
      5,
      0,
      6,
      0,
      "SAM2MODEL"
    ],
    [
      7,
      4,
      0,
      6,
      1,
      "STRING"
    ],
    [
      8,
      1,
      0,
      6,
      2,
      "IMAGE"
    ],
    [
      9,
      4,
      1,
      6,
      3,
      "STRING"
    ],
    [
      10,
      6,
      0,
      7,
      0,
      "SAM2MODEL"
    ],
    [
      11,
      6,
      1,
      7,
      1,
      "SAM2INFERENCESTATE"
    ],
    [
      12,
      1,
      0,
      8,
      0,
      "IMAGE"
    ],
    [
      13,
      7,
      0,
      8,
      1,
      "MASK"
    ],
    [
      14,
      1,
      3,
      9,
      0,
      "VHS_VIDEOINFO"
    ],
    [
      15,
      8,
      0,
      10,
      0,
      "IMAGE"
    ],
    [
      16,
      9,
      0,
      10,
      1,
      "FLOAT"
    ],
    [
      17,
      1,
      2,
      10,
      2,
      "AUDIO"
    ]
  ],
  "groups": [
    {
      "title": "① 動画を選ぶ",
      "bounding": [
        0,
        -20,
        400,
        390
      ],
      "color": "#3f789e",
      "font_size": 24,
      "flags": {}
    },
    {
      "title": "② 対象を指定",
      "bounding": [
        400,
        -20,
        1330,
        620
      ],
      "color": "#8a6d3b",
      "font_size": 24,
      "flags": {}
    },
    {
      "title": "③ 追跡 → モザイク → 出力",
      "bounding": [
        1720,
        20,
        1800,
        470
      ],
      "color": "#3f8f5f",
      "font_size": 24,
      "flags": {}
    }
  ],
  "config": {},
  "extra": {},
  "version": 0.4
}
JSON
cp -f "$WF_USER_DIR/SAM2_Tracked_Mosaic.json" "$WF_BACKUP_DIR/SAM2_Tracked_Mosaic.json"

cat > "$WF_USER_DIR/SAM2_Tracked_Mosaic_GUIDE.txt" <<'TXT'
SAM2 Tracked Mosaic - Quick Guide

1) Run the setup script, then RESTART ComfyUI once.
2) Open workflow: SAM2_Tracked_Mosaic
3) In "1. Load Video", choose/upload your source video.
4) Queue once. The Points Editor gets a letterboxed preview image.
   A temporary green point is placed at the center so the first queue can initialize.
5) In Points Editor:
   - Shift + click       = add green/positive point (target)
   - Shift + right click = add red/negative point (exclude nearby area)
   - Right click point   = delete point
   Put the green point(s) INSIDE the object/area you want tracked.
6) Adjust "8. Mosaic Strength / Range":
   - block_size : mosaic coarseness. 16-40 is a useful range.
   - grow_px    : expands the hidden region. 8-30 is a useful range.
   - feather_px : softens only the mosaic boundary. 0-4 is typical.
   - strength   : 1.0 = full mosaic.
7) Queue again. The result is written under ComfyUI/output/mosaic/.

Notes:
- This workflow uses SAM2.1 Small for a good speed/accuracy balance.
- Original video FPS is passed to Video Combine automatically.
- Original audio is passed through when VideoHelperSuite can read it.
- One tracked object is the intended default. Multiple green points can refine the same target.
- If tracking drifts, add a red/negative point on the nearby distractor.

TXT
cp -f "$WF_USER_DIR/SAM2_Tracked_Mosaic_GUIDE.txt" "$WF_BACKUP_DIR/SAM2_Tracked_Mosaic_GUIDE.txt"

# Final static checks
log "Final checks"

[[ -f "$CUSTOM/ComfyUI-KJNodes/__init__.py" ]] || die "KJNodes is not usable."
[[ -f "$CUSTOM/ComfyUI-segment-anything-2/nodes.py" ]] || die "SAM2 custom nodes are not usable."
[[ -f "$CUSTOM/ComfyUI-VideoHelperSuite/videohelpersuite/load_video_nodes.py" ]] || die "VideoHelperSuite is not usable."
[[ -f "$MODEL_PATH" ]] || die "SAM2 model missing."
[[ -f "$WF_USER_DIR/SAM2_Tracked_Mosaic.json" ]] || die "Workflow missing."

"$PYTHON_BIN" - <<PY
import json
p = r"$WF_USER_DIR/SAM2_Tracked_Mosaic.json"
with open(p, "r", encoding="utf-8") as f:
    wf = json.load(f)
assert wf.get("last_node_id") == 10
print("Workflow JSON: OK")
PY

printf '\n'
printf '\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m SAM2 TRACKED MOSAIC SETUP COMPLETE\033[0m\n'
printf '\033[1;32m============================================================\033[0m\n'
printf 'Model:    %s\n' "$MODEL_PATH"
printf 'Toolkit:  %s\n' "$TOOLKIT"
printf 'Workflow: %s\n' "$WF_USER_DIR/SAM2_Tracked_Mosaic.json"
printf 'Guide:    %s\n' "$WF_USER_DIR/SAM2_Tracked_Mosaic_GUIDE.txt"
printf '\n'
printf 'IMPORTANT: Restart ComfyUI once, then open workflow "SAM2_Tracked_Mosaic".\n'
printf 'Normal controls: target points / block_size / grow_px / feather_px.\n'
printf '\n'
