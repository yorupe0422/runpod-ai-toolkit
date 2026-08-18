#!/usr/bin/env bash
set -Eeuo pipefail

# SETUP #10 — standalone SAM2.1 tracked mosaic environment for RunPod/ComfyUI.
# Every external source is pinned and verified; reruns converge on the same state.

SCRIPT_VERSION="10.1.0-audit"
ROOT="${RUNPOD_ROOT:-/workspace/runpod-slim}"
COMFY_DIR="${COMFY_DIR:-$ROOT/ComfyUI}"
PORT="${RUNPOD_PORT:-8188}"
LOG="$ROOT/sam2_mosaic_setup.log"

COMFY_REPO="https://github.com/Comfy-Org/ComfyUI.git"
COMFY_COMMIT="b963f4ad210a42841ab23dfc28a84143a0cce227"
VHS_REPO="https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
VHS_COMMIT="4ee72c065db22c9d96c2427954dc69e7b908444b"
KJ_REPO="https://github.com/kijai/ComfyUI-KJNodes.git"
KJ_COMMIT="3f20054214fec9f9234fd3841ae6f1e4287948f6"
SAM2_REPO="https://github.com/kijai/ComfyUI-segment-anything-2.git"
SAM2_COMMIT="0c35fff5f382803e2310103357b5e985f5437f32"

MODEL_NAME="sam2.1_hiera_small-fp16.safetensors"
MODEL_REVISION="f885607d88bb3f9145efa49c3e3c50a9e5bf13eb"
MODEL_URL="https://huggingface.co/Kijai/sam2-safetensors/resolve/${MODEL_REVISION}/${MODEL_NAME}?download=true"
MODEL_SIZE="92181820"
MODEL_SHA256="b766bb5aea81d3b7a09c8d3f74d1527144bb848d43e5bb1fe4152528a60c683b"

export PYTHONUNBUFFERED=1
export PYTHONNOUSERSITE=1
export MPLCONFIGDIR="$ROOT/.cache/matplotlib"
mkdir -p "$ROOT"
mkdir -p "$MPLCONFIGDIR"
exec > >(tee -a "$LOG") 2>&1

log()  { printf '\n\033[1;36m[MOSAIC]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FATAL]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n===== %s =====\n' "$*"; }

MODEL_TMP=""
OBJECT_INFO=""
cleanup_temps() {
    [[ -z "${MODEL_TMP:-}" ]] || rm -f "$MODEL_TMP" || true
    [[ -z "${OBJECT_INFO:-}" ]] || rm -f "$OBJECT_INFO" || true
}
on_error() {
    local code=$?
    printf '\nSETUP #10 FAILED (exit=%s, line=%s)\n' "$code" "${BASH_LINENO[0]}" >&2
    printf 'Log: %s\n' "$LOG" >&2
    exit "$code"
}
trap on_error ERR
trap cleanup_temps EXIT

step "SETUP #10 — SAM2.1 TRACKED MOSAIC"
printf 'Installer version: %s\n' "$SCRIPT_VERSION"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || \
    die "RUNPOD_PORT must be an integer from 1 to 65535"

step "[1/10] System and GPU preflight"
if ! command -v git >/dev/null || ! command -v curl >/dev/null || \
   ! command -v sha256sum >/dev/null || ! command -v ffmpeg >/dev/null || \
   ! command -v pkill >/dev/null; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        git curl ca-certificates coreutils procps ffmpeg
fi
for cmd in git curl sha256sum stat df awk grep tee mktemp pkill ffmpeg; do
    command -v "$cmd" >/dev/null || die "Required system command not found: $cmd"
done
command -v nvidia-smi >/dev/null || die "NVIDIA driver/GPU not found"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
gpu_mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -dc '0-9')"
[[ -n "$gpu_mib" ]] || die "Could not read GPU VRAM"
(( gpu_mib >= 8000 )) || die "At least 8 GB VRAM is required; detected ${gpu_mib} MiB"

pin_repo() {
    local name="$1" url="$2" commit="$3" dst="$4" branch="$5"
    local remote="codex-v10-upstream" old_sha backup
    if [[ ! -d "$dst/.git" ]]; then
        if [[ -e "$dst" ]]; then
            backup="${dst}.codex-v10-backup.$(date +%Y%m%d%H%M%S)"
            mv "$dst" "$backup"
            warn "$name non-git directory preserved at $backup"
        fi
        git clone --filter=blob:none "$url" "$dst"
    fi
    if [[ -n "$(git -C "$dst" status --porcelain --untracked-files=no)" ]]; then
        die "$name has tracked local changes; refusing to overwrite them"
    fi
    if git -C "$dst" remote get-url "$remote" >/dev/null 2>&1; then
        git -C "$dst" remote set-url "$remote" "$url"
    else
        git -C "$dst" remote add "$remote" "$url"
    fi
    git -C "$dst" fetch --prune --filter=blob:none "$remote" "$branch"
    git -C "$dst" cat-file -e "$commit^{commit}" 2>/dev/null || \
        die "$name pinned commit is unavailable: $commit"
    old_sha="$(git -C "$dst" rev-parse --short=12 HEAD)"
    backup="codex-v10-backup-$old_sha"
    git -C "$dst" show-ref --verify --quiet "refs/heads/$backup" || \
        git -C "$dst" branch "$backup" HEAD
    git -C "$dst" switch -C codex-v10 "$commit"
    [[ "$(git -C "$dst" rev-parse HEAD)" == "$commit" ]] || \
        die "$name commit verification failed"
    ok "$name pinned at $commit"
}

step "[2/10] ComfyUI core (standalone and pinned)"
if [[ -e "$COMFY_DIR" && ! -d "$COMFY_DIR/.git" ]]; then
    die "$COMFY_DIR exists but is not a git checkout; move it aside and rerun"
fi
pin_repo "ComfyUI" "$COMFY_REPO" "$COMFY_COMMIT" "$COMFY_DIR" master
for flag in '--reserve-vram' '--cache-none' '--disable-all-custom-nodes' '--whitelist-custom-nodes'; do
    grep -Fq -- "$flag" "$COMFY_DIR/comfy/cli_args.py" || die "ComfyUI lacks CLI flag: $flag"
done

step "[3/10] Dedicated Python environment"
BASE_PYTHON="$(command -v python3 || true)"
[[ -n "$BASE_PYTHON" && -x "$BASE_PYTHON" ]] || die "python3 not found"
"$BASE_PYTHON" -c 'import sys; assert sys.version_info >= (3, 10)' 2>/dev/null || \
    die "Python 3.10 or newer is required"
VENV="$ROOT/.venv-sam2-mosaic"
PYTHON_BIN="$VENV/bin/python"
if [[ -e "$VENV" ]] && ! "$PYTHON_BIN" -c 'import sys; assert sys.prefix != sys.base_prefix' >/dev/null 2>&1; then
    broken_venv="$VENV.broken.$(date +%Y%m%d%H%M%S)"
    mv "$VENV" "$broken_venv"
    warn "Invalid old venv preserved at $broken_venv"
fi
if [[ ! -x "$PYTHON_BIN" ]]; then
    "$BASE_PYTHON" -m venv --system-site-packages "$VENV" || {
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv
        "$BASE_PYTHON" -m venv --system-site-packages "$VENV"
    }
fi
"$PYTHON_BIN" -c 'import sys; assert sys.prefix != sys.base_prefix; assert sys.version_info >= (3, 10)' || \
    die "Dedicated Python environment validation failed"
"$PYTHON_BIN" -m ensurepip --upgrade >/dev/null 2>&1 || true
"$PYTHON_BIN" -m pip --version >/dev/null 2>&1 || die "pip is unavailable in the dedicated venv"
"$PYTHON_BIN" -m pip install -U pip setuptools wheel
"$PYTHON_BIN" -m pip install -r "$COMFY_DIR/requirements.txt"

step "[4/10] Pinned custom nodes and dependencies"
CUSTOM="$COMFY_DIR/custom_nodes"
mkdir -p "$CUSTOM"
pin_repo "VideoHelperSuite" "$VHS_REPO" "$VHS_COMMIT" "$CUSTOM/ComfyUI-VideoHelperSuite" main
pin_repo "KJNodes" "$KJ_REPO" "$KJ_COMMIT" "$CUSTOM/ComfyUI-KJNodes" main
pin_repo "ComfyUI-segment-anything-2" "$SAM2_REPO" "$SAM2_COMMIT" "$CUSTOM/ComfyUI-segment-anything-2" main

# One OpenCV distribution is installed intentionally. Installing both GUI and
# headless wheels in the same venv is a common source of cv2 breakage.
"$PYTHON_BIN" -m pip install \
    'Pillow>=10.3.0' color-matcher matplotlib mss opencv-python imageio-ffmpeg
"$PYTHON_BIN" - <<'PY'
import importlib
mods = ["torch", "torchvision", "yaml", "numpy", "PIL", "cv2",
        "imageio_ffmpeg", "color_matcher", "matplotlib", "mss"]
missing = []
for name in mods:
    try:
        importlib.import_module(name)
    except Exception as exc:
        missing.append(f"{name}: {exc}")
if missing:
    raise SystemExit("Dependency import failure:\n" + "\n".join(missing))
print("Python dependency imports: OK")
PY
grep -Rqs 'class PointsEditor' "$CUSTOM/ComfyUI-KJNodes" || die "Pinned KJNodes lacks PointsEditor"
for node in DownloadAndLoadSAM2Model Sam2VideoSegmentationAddPoints Sam2VideoSegmentation; do
    grep -Fq "class $node" "$CUSTOM/ComfyUI-segment-anything-2/nodes.py" || \
        die "Pinned SAM2 nodes lack $node"
done
for node in VHS_LoadVideo VHS_VideoCombine; do
    grep -Fq "\"$node\"" "$CUSTOM/ComfyUI-VideoHelperSuite/videohelpersuite/nodes.py" || \
        die "Pinned VideoHelperSuite lacks $node"
done

step "[5/10] SAM2.1 Hiera Small FP16 model"
MODEL_DIR="$COMFY_DIR/models/sam2"
MODEL_PATH="$MODEL_DIR/$MODEL_NAME"
mkdir -p "$MODEL_DIR"
available_bytes="$(df -PB1 "$ROOT" | awk 'NR==2 {print $4}')"
[[ "$available_bytes" =~ ^[0-9]+$ ]] || die "Could not determine free disk space"
(( available_bytes >= 2000000000 )) || die "At least 2 GB free disk space is required"

model_ok=0
if [[ -f "$MODEL_PATH" && "$(stat -c %s "$MODEL_PATH")" == "$MODEL_SIZE" ]]; then
    current_sha="$(sha256sum "$MODEL_PATH" | awk '{print $1}')"
    [[ "$current_sha" == "$MODEL_SHA256" ]] && model_ok=1
fi
if [[ "$model_ok" == "1" ]]; then
    ok "SAM2 model already present and verified"
else
    MODEL_TMP="$MODEL_PATH.part"
    rm -f "$MODEL_TMP"
    curl -fL --retry 8 --retry-all-errors --connect-timeout 20 \
        -o "$MODEL_TMP" "$MODEL_URL"
    [[ "$(stat -c %s "$MODEL_TMP")" == "$MODEL_SIZE" ]] || die "SAM2 model size mismatch"
    downloaded_sha="$(sha256sum "$MODEL_TMP" | awk '{print $1}')"
    [[ "$downloaded_sha" == "$MODEL_SHA256" ]] || die "SAM2 model SHA256 mismatch"
    mv -f "$MODEL_TMP" "$MODEL_PATH"
    MODEL_TMP=""
    ok "SAM2 model downloaded and verified"
fi

step "[6/10] Mosaic Toolkit custom nodes"
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

step "[7/10] Ready-to-open workflow and guide"
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

1) Run SETUP #10. The script starts the verified ComfyUI environment automatically.
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

step "[8/10] Static workflow and artifact validation"

[[ -f "$CUSTOM/ComfyUI-KJNodes/__init__.py" ]] || die "KJNodes is not usable."
[[ -f "$CUSTOM/ComfyUI-segment-anything-2/nodes.py" ]] || die "SAM2 custom nodes are not usable."
[[ -f "$CUSTOM/ComfyUI-VideoHelperSuite/videohelpersuite/load_video_nodes.py" ]] || die "VideoHelperSuite is not usable."
[[ "$(stat -c %s "$MODEL_PATH")" == "$MODEL_SIZE" ]] || die "SAM2 model size validation failed."
[[ "$(sha256sum "$MODEL_PATH" | awk '{print $1}')" == "$MODEL_SHA256" ]] || \
    die "SAM2 model checksum validation failed."
[[ -f "$WF_USER_DIR/SAM2_Tracked_Mosaic.json" ]] || die "Workflow missing."

WF_PATH="$WF_USER_DIR/SAM2_Tracked_Mosaic.json" "$PYTHON_BIN" - <<'PY'
import json, os
p = os.environ["WF_PATH"]
with open(p, encoding="utf-8") as f:
    wf = json.load(f)
nodes = wf.get("nodes", [])
links = wf.get("links", [])
node_ids = [n.get("id") for n in nodes]
if len(node_ids) != len(set(node_ids)):
    raise SystemExit("Workflow has duplicate node IDs")
node_id_set = set(node_ids)
link_ids = set()
for link in links:
    if not isinstance(link, list) or len(link) < 6:
        raise SystemExit(f"Malformed workflow link: {link!r}")
    lid, origin, target = link[0], link[1], link[3]
    if lid in link_ids:
        raise SystemExit(f"Duplicate workflow link ID: {lid}")
    link_ids.add(lid)
    if origin not in node_id_set or target not in node_id_set:
        raise SystemExit(f"Link {lid} references a missing node")
for node in nodes:
    for inp in node.get("inputs", []):
        lid = inp.get("link")
        if lid is not None and lid not in link_ids:
            raise SystemExit(f"Node {node['id']} input references missing link {lid}")
    for out in node.get("outputs", []):
        for lid in out.get("links") or []:
            if lid not in link_ids:
                raise SystemExit(f"Node {node['id']} output references missing link {lid}")
required = {
    "VHS_LoadVideo", "MosaicEditorPrep", "PointsEditor", "MosaicMapCoordinates",
    "DownloadAndLoadSAM2Model", "Sam2VideoSegmentationAddPoints",
    "Sam2VideoSegmentation", "MosaicMaskedVideo", "MosaicVideoInfoFPS",
    "VHS_VideoCombine",
}
types = {n.get("type") for n in nodes}
if required - types:
    raise SystemExit("Workflow missing node types: " + ", ".join(sorted(required - types)))
loader = next(n for n in nodes if n.get("type") == "DownloadAndLoadSAM2Model")
if loader.get("widgets_values") != ["sam2.1_hiera_small.safetensors", "video", "cuda", "fp16"]:
    raise SystemExit("SAM2 loader configuration mismatch")
if wf.get("last_node_id") != 10 or wf.get("last_link_id") != 17 or len(links) != 17:
    raise SystemExit("Workflow graph count mismatch")
print("Workflow graph and SAM2 loader configuration: OK")
PY

step "[9/10] Restart ComfyUI in isolated SAM2 mode"
if command -v fuser >/dev/null 2>&1; then
    fuser -k "${PORT}/tcp" 2>/dev/null || true
else
    pkill -f "[p]ython.*main.py.*--port[ =]$PORT" 2>/dev/null || true
fi
sleep 2
cd "$COMFY_DIR"
nohup "$PYTHON_BIN" main.py \
    --listen 0.0.0.0 \
    --port "$PORT" \
    --preview-method auto \
    --reserve-vram 2 \
    --cache-none \
    --disable-all-custom-nodes \
    --whitelist-custom-nodes \
        ComfyUI-VideoHelperSuite \
        ComfyUI-KJNodes \
        ComfyUI-segment-anything-2 \
        ComfyUI-MosaicToolkit \
    > "$ROOT/comfyui_sam2_mosaic.log" 2>&1 &
printf '%s\n' "$!" > "$ROOT/comfyui_sam2_mosaic.pid"

OBJECT_INFO="$(mktemp)"
ready=0
for _ in $(seq 1 120); do
    if curl -fsS "http://127.0.0.1:$PORT/object_info" -o "$OBJECT_INFO" 2>/dev/null; then
        ready=1
        break
    fi
    if ! kill -0 "$(cat "$ROOT/comfyui_sam2_mosaic.pid")" 2>/dev/null; then
        tail -160 "$ROOT/comfyui_sam2_mosaic.log" || true
        die "ComfyUI exited during SAM2 startup"
    fi
    sleep 2
done
[[ "$ready" == 1 ]] || {
    tail -160 "$ROOT/comfyui_sam2_mosaic.log" || true
    die "ComfyUI did not become ready"
}

step "[10/10] Runtime node validation"
OBJECT_INFO="$OBJECT_INFO" "$PYTHON_BIN" - <<'PY'
import json, os
with open(os.environ["OBJECT_INFO"], encoding="utf-8") as f:
    nodes = json.load(f)
required = [
    "VHS_LoadVideo", "VHS_VideoCombine", "PointsEditor",
    "DownloadAndLoadSAM2Model", "Sam2VideoSegmentationAddPoints",
    "Sam2VideoSegmentation", "MosaicEditorPrep", "MosaicMapCoordinates",
    "MosaicMaskedVideo", "MosaicVideoInfoFPS",
]
missing = [name for name in required if name not in nodes]
if missing:
    raise SystemExit("Missing required runtime nodes: " + ", ".join(missing))
print("All required SAM2 mosaic runtime nodes are loaded")
PY

printf '\n'
printf '\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m SETUP #10 COMPLETE — SAM2 TRACKED MOSAIC READY\033[0m\n'
printf '\033[1;32m============================================================\033[0m\n'
printf 'ComfyUI:  http://127.0.0.1:%s\n' "$PORT"
printf 'Model:    %s\n' "$MODEL_PATH"
printf 'Toolkit:  %s\n' "$TOOLKIT"
printf 'Workflow: %s\n' "$WF_USER_DIR/SAM2_Tracked_Mosaic.json"
printf 'Guide:    %s\n' "$WF_USER_DIR/SAM2_Tracked_Mosaic_GUIDE.txt"
printf '\n'
printf 'Open workflow "SAM2_Tracked_Mosaic"; no manual restart is required.\n'
printf 'Normal controls: target points / block_size / grow_px / feather_px.\n'
printf '\n'
