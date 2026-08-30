#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# RunPod FastH3 VSA - SAVED COMPLETE v4
# Target: RTX 5090 / Blackwell
# Port:   8188
# Root:   /workspace/runpod-slim/ComfyUI-FastH3
#
# Includes:
# - isolated kijai/ComfyUI "vsa" branch
# - Python 3.12 isolated venv
# - CUDA 13 Torch preferred
# - official comfy-kitchen 0.2.31 binary wheel [cublas]
# - FastH3 INT8 ConvRot checkpoint
# - Qwen3VL MiniMax H3 text encoder
# - video/audio VAE
# - MAIN 10-step workflow
# - 5-step reference workflow
# - safe port-8188 takeover from another ComfyUI
# - startup/smoke tests/logging
#
# This script is re-runnable and does not touch/delete other ComfyUI folders.
# ============================================================

ROOT="${FASTH3_ROOT:-/workspace/runpod-slim/ComfyUI-FastH3}"
PARENT="$(dirname "$ROOT")"
VENV="$ROOT/.venv"
MODEL_DIR="$ROOT/models"
LOG_DIR="$ROOT/setup_logs"
PORT="${COMFY_PORT:-8188}"

COMFY_REPO="https://github.com/kijai/ComfyUI.git"
COMFY_BRANCH="vsa"

FASTH3_REPO="Kijai/MiniMax-H3-experimental"
FASTH3_FILE="minimax_h3_fastvideo_vsa_datafree_1300step_4step_int8_convrot.safetensors"
FASTH3_SHA256="7221ae65d78780354d51e5048d29728d9f1f8fb9baf50b1dd3df85f5101413d3"

BASE_REPO="Comfy-Org/MiniMax-H3"
TEXT_FILE="text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"
VIDEO_VAE_FILE="vae/minimax_h3_video_vae_fp16.safetensors"
AUDIO_VAE_FILE="vae/minimax_h3_audio_vae_fp32.safetensors"

WF_MAIN="$ROOT/user/default/workflows/FastH3_VSA_10step_MAIN_5090.json"
WF_REF="$ROOT/user/default/workflows/FastH3_VSA_5step_REFERENCE_5090.json"

mkdir -p "$PARENT"
BOOT_LOG_DIR="$PARENT/FastH3-bootstrap-logs"
mkdir -p "$BOOT_LOG_DIR"
LOG="$BOOT_LOG_DIR/setup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

trap 'rc=$?; echo; echo "============================================================"; echo "[FAILED] rc=$rc line=$LINENO"; echo "Log: $LOG"; echo "============================================================"; exit $rc' ERR

echo "============================================================"
echo " FastH3 VSA SAVED COMPLETE v4"
echo " ROOT : $ROOT"
echo " PORT : $PORT"
echo " LOG  : $LOG"
echo "============================================================"

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "[ERROR] nvidia-smi not found."
  exit 1
fi

echo
echo "[GPU]"
nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv,noheader || nvidia-smi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  git git-lfs curl wget ca-certificates ffmpeg \
  build-essential ninja-build cmake pkg-config \
  libgl1 libglib2.0-0 python3.12 python3.12-venv python3.12-dev
git lfs install --system || true

if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
fi
UV="$(command -v uv)"
echo "[uv] $($UV --version)"

# ------------------------------------------------------------
# 1. ComfyUI VSA branch
# ------------------------------------------------------------
echo
echo "[1/8] ComfyUI VSA branch"

if [[ -d "$ROOT" && ! -d "$ROOT/.git" ]]; then
  shopt -s nullglob dotglob
  entries=("$ROOT"/*)
  shopt -u nullglob dotglob
  if [[ ${#entries[@]} -eq 0 ]]; then
    rmdir "$ROOT"
  elif [[ ${#entries[@]} -eq 1 && "${entries[0]}" == "$ROOT/setup_logs" ]]; then
    echo "[RECOVERY] Removing v1 partial directory containing setup_logs only."
    rm -rf "$ROOT"
  else
    echo "[ERROR] $ROOT exists but is not a git repository."
    echo "Refusing to delete it automatically."
    echo "Inspect with: ls -la '$ROOT'"
    exit 1
  fi
fi

if [[ ! -d "$ROOT/.git" ]]; then
  git clone --branch "$COMFY_BRANCH" --single-branch "$COMFY_REPO" "$ROOT"
else
  git -C "$ROOT" fetch origin "$COMFY_BRANCH"
  git -C "$ROOT" checkout "$COMFY_BRANCH"
  git -C "$ROOT" pull --ff-only origin "$COMFY_BRANCH" || \
    echo "[WARN] Fast-forward pull failed; keeping existing working checkout."
fi

mkdir -p "$LOG_DIR"
FINAL_LOG="$LOG_DIR/$(basename "$LOG")"
cp -f "$LOG" "$FINAL_LOG" 2>/dev/null || true
LOG="$FINAL_LOG"

cd "$ROOT"
echo "[ComfyUI commit] $(git rev-parse HEAD)"

# ------------------------------------------------------------
# 2. Isolated venv
# ------------------------------------------------------------
echo
echo "[2/8] Python environment"
if [[ ! -x "$VENV/bin/python" ]]; then
  "$UV" venv --python python3.12 "$VENV"
fi
PY="$VENV/bin/python"

"$PY" -m ensurepip --upgrade >/dev/null 2>&1 || true
"$PY" -m pip install -U pip setuptools wheel packaging

# ------------------------------------------------------------
# 3. Torch + Comfy requirements
# ------------------------------------------------------------
echo
echo "[3/8] Torch / ComfyUI requirements"

NEED_TORCH=1
if "$PY" - <<'PY' >/dev/null 2>&1
import torch
assert torch.cuda.is_available()
p=torch.cuda.get_device_properties(0)
assert p.major >= 12
PY
then
  NEED_TORCH=0
fi

if [[ "$NEED_TORCH" == "1" ]]; then
  echo "[Torch] Installing CUDA 13 build for Blackwell..."
  if ! "$UV" pip install --python "$PY" --torch-backend=cu130 -U torch torchvision torchaudio; then
    echo "[WARN] cu130 resolver failed; falling back to cu128."
    "$UV" pip install --python "$PY" --torch-backend=cu128 -U torch torchvision torchaudio
  fi
else
  echo "[Torch] Existing CUDA-capable Blackwell Torch is valid; keeping it."
fi

"$UV" pip install --python "$PY" -r "$ROOT/requirements.txt"
"$UV" pip install --python "$PY" -U "huggingface_hub[hf_xet]" hf_transfer

# ------------------------------------------------------------
# 4. comfy-kitchen binary wheel - NO source build
# ------------------------------------------------------------
echo
echo "[4/8] comfy-kitchen 0.2.31 official binary wheel"

"$PY" -m pip uninstall -y comfy-kitchen >/dev/null 2>&1 || true
"$PY" -m pip install \
  --only-binary=:all: \
  --upgrade \
  "comfy-kitchen[cublas]==0.2.31"

"$PY" - <<'PY'
import importlib, importlib.metadata as md, pathlib, comfy_kitchen
print("comfy-kitchen:", md.version("comfy-kitchen"))
pkg = pathlib.Path(comfy_kitchen.__file__).resolve().parent
native = list(pkg.rglob("*.so"))
print("native .so files:", len(native))
if not native:
    raise SystemExit("comfy-kitchen native wheel missing")
m = importlib.import_module("comfy_kitchen.backends.cuda._C")
print("CUDA extension:", m.__file__)
PY

# ------------------------------------------------------------
# 5. Models
# ------------------------------------------------------------
echo
echo "[5/8] FastH3 models"

mkdir -p \
  "$MODEL_DIR/diffusion_models" \
  "$MODEL_DIR/text_encoders" \
  "$MODEL_DIR/vae" \
  "$MODEL_DIR/loras" \
  "$ROOT/input" "$ROOT/output" \
  "$ROOT/user/default/workflows"

export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_XET_HIGH_PERFORMANCE=1

HF="$VENV/bin/hf"
if [[ ! -x "$HF" ]]; then
  HF="$(command -v hf || true)"
fi
if [[ -z "$HF" ]]; then
  echo "[ERROR] Hugging Face CLI 'hf' not found."
  exit 1
fi

"$HF" download "$FASTH3_REPO" "$FASTH3_FILE" \
  --local-dir "$MODEL_DIR/diffusion_models"

"$HF" download "$BASE_REPO" \
  "$TEXT_FILE" \
  "$VIDEO_VAE_FILE" \
  "$AUDIO_VAE_FILE" \
  --local-dir "$MODEL_DIR"

FASTH3_PATH="$MODEL_DIR/diffusion_models/$FASTH3_FILE"
TEXT_PATH="$MODEL_DIR/$TEXT_FILE"
VIDEO_VAE_PATH="$MODEL_DIR/$VIDEO_VAE_FILE"
AUDIO_VAE_PATH="$MODEL_DIR/$AUDIO_VAE_FILE"

check_size () {
  local f="$1"
  local min_bytes="$2"
  if [[ ! -f "$f" ]]; then
    echo "[ERROR] Missing: $f"
    exit 1
  fi
  local sz
  sz="$(stat -c%s "$f")"
  if (( sz < min_bytes )); then
    echo "[ERROR] File is suspiciously small: $f ($sz bytes)"
    exit 1
  fi
  ls -lh "$f"
}

check_size "$FASTH3_PATH" 22000000000
check_size "$TEXT_PATH" 14000000000
check_size "$VIDEO_VAE_PATH" 4500000000
check_size "$AUDIO_VAE_PATH" 500000000

if [[ "${VERIFY_FASTH3_SHA256:-0}" == "1" ]]; then
  echo "$FASTH3_SHA256  $FASTH3_PATH" | sha256sum -c -
fi

# ------------------------------------------------------------
# 6. Workflows
# ------------------------------------------------------------
echo
echo "[6/8] Installing workflows"

cat > "$WF_MAIN" <<'JSON_MAIN'
{
  "id": "9ebf883f-810e-4a59-92b0-841384089020",
  "revision": 0,
  "last_node_id": 15,
  "last_link_id": 18,
  "nodes": [
    {
      "id": 1,
      "type": "UNETLoader",
      "pos": [
        0,
        0
      ],
      "size": [
        440,
        110
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "unet_name",
          "type": "COMBO",
          "widget": {
            "name": "unet_name"
          },
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "MODEL",
          "type": "MODEL",
          "links": [
            1
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "UNETLoader"
      },
      "widgets_values": [
        "minimax_h3_fastvideo_vsa_datafree_1300step_4step_int8_convrot.safetensors",
        "default"
      ]
    },
    {
      "id": 2,
      "type": "ModelAttentionBackend",
      "pos": [
        500,
        0
      ],
      "size": [
        350,
        110
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": 1
        }
      ],
      "outputs": [
        {
          "name": "MODEL",
          "type": "MODEL",
          "links": [
            2,
            3
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "ModelAttentionBackend"
      },
      "widgets_values": [
        "comfy kitchen attention"
      ],
      "title": "FastH3 VSA / Comfy Kitchen Attention"
    },
    {
      "id": 3,
      "type": "CLIPLoader",
      "pos": [
        0,
        170
      ],
      "size": [
        440,
        140
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "clip_name",
          "type": "COMBO",
          "widget": {
            "name": "clip_name"
          },
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "CLIP",
          "type": "CLIP",
          "links": [
            4
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "CLIPLoader"
      },
      "widgets_values": [
        "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
        "minimax",
        "default"
      ]
    },
    {
      "id": 4,
      "type": "VAELoader",
      "pos": [
        0,
        360
      ],
      "size": [
        440,
        100
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "vae_name",
          "type": "COMBO",
          "widget": {
            "name": "vae_name"
          },
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "VAE",
          "type": "VAE",
          "links": [
            5,
            11
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "VAELoader"
      },
      "widgets_values": [
        "minimax_h3_video_vae_fp16.safetensors"
      ]
    },
    {
      "id": 5,
      "type": "VAELoader",
      "pos": [
        0,
        510
      ],
      "size": [
        440,
        100
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "vae_name",
          "type": "COMBO",
          "widget": {
            "name": "vae_name"
          },
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "VAE",
          "type": "VAE",
          "links": [
            12
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "VAELoader"
      },
      "widgets_values": [
        "minimax_h3_audio_vae_fp32.safetensors"
      ]
    },
    {
      "id": 6,
      "type": "MiniMaxH3ImageToVideo",
      "pos": [
        520,
        180
      ],
      "size": [
        480,
        500
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "clip",
          "type": "CLIP",
          "link": 4
        },
        {
          "name": "vae",
          "type": "VAE",
          "link": 5
        },
        {
          "name": "first_frame",
          "type": "IMAGE",
          "shape": 7,
          "link": null
        },
        {
          "name": "last_frame",
          "type": "IMAGE",
          "shape": 7,
          "link": null
        },
        {
          "name": "prompt",
          "type": "STRING",
          "widget": {
            "name": "prompt"
          },
          "link": null
        },
        {
          "name": "width",
          "type": "INT",
          "widget": {
            "name": "width"
          },
          "link": null
        },
        {
          "name": "height",
          "type": "INT",
          "widget": {
            "name": "height"
          },
          "link": null
        },
        {
          "name": "length",
          "type": "INT",
          "widget": {
            "name": "length"
          },
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "positive",
          "type": "CONDITIONING",
          "links": [
            6
          ]
        },
        {
          "name": "LATENT",
          "type": "LATENT",
          "links": [
            10
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "MiniMaxH3ImageToVideo"
      },
      "widgets_values": [
        "A realistic cinematic video, natural motion, coherent anatomy and stable identity, realistic lighting and textures, subtle camera movement, detailed environment. Audio: natural synchronized ambience appropriate to the scene. No text, no subtitles, no logos, no watermark.",
        768,
        432,
        141
      ],
      "title": "FastH3 T2VA — 768x432 / 141f (~5.9s)"
    },
    {
      "id": 7,
      "type": "RandomNoise",
      "pos": [
        1050,
        0
      ],
      "size": [
        300,
        90
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "noise_seed",
          "type": "INT",
          "widget": {
            "name": "noise_seed"
          },
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "NOISE",
          "type": "NOISE",
          "links": [
            7
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "RandomNoise"
      },
      "widgets_values": [
        123456789,
        "randomize"
      ]
    },
    {
      "id": 8,
      "type": "BasicGuider",
      "pos": [
        1050,
        140
      ],
      "size": [
        320,
        100
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": 2
        },
        {
          "name": "conditioning",
          "type": "CONDITIONING",
          "link": 6
        }
      ],
      "outputs": [
        {
          "name": "GUIDER",
          "type": "GUIDER",
          "links": [
            8
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "BasicGuider"
      },
      "widgets_values": []
    },
    {
      "id": 9,
      "type": "KSamplerSelect",
      "pos": [
        1050,
        290
      ],
      "size": [
        320,
        90
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "SAMPLER",
          "type": "SAMPLER",
          "links": [
            9
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "KSamplerSelect"
      },
      "widgets_values": [
        "res_multistep"
      ]
    },
    {
      "id": 10,
      "type": "BasicScheduler",
      "pos": [
        1050,
        430
      ],
      "size": [
        320,
        140
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": 3
        },
        {
          "name": "steps",
          "type": "INT",
          "widget": {
            "name": "steps"
          },
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "SIGMAS",
          "type": "SIGMAS",
          "links": [
            13
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "BasicScheduler"
      },
      "widgets_values": [
        "simple",
        10,
        1.0
      ],
      "title": "MAIN: 10 steps / simple / denoise 1.0"
    },
    {
      "id": 11,
      "type": "SamplerCustomAdvanced",
      "pos": [
        1430,
        150
      ],
      "size": [
        280,
        410
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "noise",
          "type": "NOISE",
          "link": 7
        },
        {
          "name": "guider",
          "type": "GUIDER",
          "link": 8
        },
        {
          "name": "sampler",
          "type": "SAMPLER",
          "link": 9
        },
        {
          "name": "sigmas",
          "type": "SIGMAS",
          "link": 13
        },
        {
          "name": "latent_image",
          "type": "LATENT",
          "link": 10
        }
      ],
      "outputs": [
        {
          "name": "output",
          "type": "LATENT",
          "links": [
            14,
            15
          ]
        },
        {
          "name": "denoised_output",
          "type": "LATENT",
          "links": null
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "SamplerCustomAdvanced"
      },
      "widgets_values": []
    },
    {
      "id": 12,
      "type": "VAEDecode",
      "pos": [
        1770,
        100
      ],
      "size": [
        280,
        100
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "samples",
          "type": "LATENT",
          "link": 14
        },
        {
          "name": "vae",
          "type": "VAE",
          "link": 11
        }
      ],
      "outputs": [
        {
          "name": "IMAGE",
          "type": "IMAGE",
          "links": [
            16
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "VAEDecode"
      },
      "widgets_values": []
    },
    {
      "id": 13,
      "type": "VAEDecodeAudio",
      "pos": [
        1770,
        260
      ],
      "size": [
        280,
        100
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "samples",
          "type": "LATENT",
          "link": 15
        },
        {
          "name": "vae",
          "type": "VAE",
          "link": 12
        }
      ],
      "outputs": [
        {
          "name": "AUDIO",
          "type": "AUDIO",
          "links": [
            17
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "VAEDecodeAudio"
      },
      "widgets_values": []
    },
    {
      "id": 14,
      "type": "CreateVideo",
      "pos": [
        2110,
        150
      ],
      "size": [
        300,
        160
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "images",
          "type": "IMAGE",
          "link": 16
        },
        {
          "name": "audio",
          "type": "AUDIO",
          "shape": 7,
          "link": 17
        }
      ],
      "outputs": [
        {
          "name": "VIDEO",
          "type": "VIDEO",
          "links": [
            18
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "CreateVideo"
      },
      "widgets_values": [
        24,
        8
      ]
    },
    {
      "id": 15,
      "type": "SaveVideo",
      "pos": [
        2470,
        150
      ],
      "size": [
        420,
        220
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "video",
          "type": "VIDEO",
          "link": 18
        }
      ],
      "outputs": [
        {
          "name": "video",
          "type": "VIDEO",
          "links": null
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "SaveVideo"
      },
      "widgets_values": [
        "video/FastH3_VSA_10step",
        "auto",
        "auto"
      ]
    }
  ],
  "links": [
    [
      1,
      1,
      0,
      2,
      0,
      "MODEL"
    ],
    [
      4,
      3,
      0,
      6,
      0,
      "CLIP"
    ],
    [
      5,
      4,
      0,
      6,
      1,
      "VAE"
    ],
    [
      2,
      2,
      0,
      8,
      0,
      "MODEL"
    ],
    [
      6,
      6,
      0,
      8,
      1,
      "CONDITIONING"
    ],
    [
      3,
      2,
      0,
      10,
      0,
      "MODEL"
    ],
    [
      7,
      7,
      0,
      11,
      0,
      "NOISE"
    ],
    [
      8,
      8,
      0,
      11,
      1,
      "GUIDER"
    ],
    [
      9,
      9,
      0,
      11,
      2,
      "SAMPLER"
    ],
    [
      13,
      10,
      0,
      11,
      3,
      "SIGMAS"
    ],
    [
      10,
      6,
      1,
      11,
      4,
      "LATENT"
    ],
    [
      14,
      11,
      0,
      12,
      0,
      "LATENT"
    ],
    [
      11,
      4,
      0,
      12,
      1,
      "VAE"
    ],
    [
      15,
      11,
      0,
      13,
      0,
      "LATENT"
    ],
    [
      12,
      5,
      0,
      13,
      1,
      "VAE"
    ],
    [
      16,
      12,
      0,
      14,
      0,
      "IMAGE"
    ],
    [
      17,
      13,
      0,
      14,
      1,
      "AUDIO"
    ],
    [
      18,
      14,
      0,
      15,
      0,
      "VIDEO"
    ]
  ],
  "groups": [],
  "config": {},
  "extra": {
    "ds": {
      "scale": 0.72,
      "offset": [
        120,
        80
      ]
    }
  },
  "version": 0.4
}
JSON_MAIN

cat > "$WF_REF" <<'JSON_REF'
{
  "id": "5a180dc2-ae9d-4dbc-b5b4-18e29174e952",
  "revision": 0,
  "last_node_id": 15,
  "last_link_id": 18,
  "nodes": [
    {
      "id": 1,
      "type": "UNETLoader",
      "pos": [
        0,
        0
      ],
      "size": [
        440,
        110
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "unet_name",
          "type": "COMBO",
          "widget": {
            "name": "unet_name"
          },
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "MODEL",
          "type": "MODEL",
          "links": [
            1
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "UNETLoader"
      },
      "widgets_values": [
        "minimax_h3_fastvideo_vsa_datafree_1300step_4step_int8_convrot.safetensors",
        "default"
      ]
    },
    {
      "id": 2,
      "type": "ModelAttentionBackend",
      "pos": [
        500,
        0
      ],
      "size": [
        350,
        110
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": 1
        }
      ],
      "outputs": [
        {
          "name": "MODEL",
          "type": "MODEL",
          "links": [
            2,
            3
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "ModelAttentionBackend"
      },
      "widgets_values": [
        "comfy kitchen attention"
      ],
      "title": "FastH3 VSA / Comfy Kitchen Attention"
    },
    {
      "id": 3,
      "type": "CLIPLoader",
      "pos": [
        0,
        170
      ],
      "size": [
        440,
        140
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "clip_name",
          "type": "COMBO",
          "widget": {
            "name": "clip_name"
          },
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "CLIP",
          "type": "CLIP",
          "links": [
            4
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "CLIPLoader"
      },
      "widgets_values": [
        "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
        "minimax",
        "default"
      ]
    },
    {
      "id": 4,
      "type": "VAELoader",
      "pos": [
        0,
        360
      ],
      "size": [
        440,
        100
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "vae_name",
          "type": "COMBO",
          "widget": {
            "name": "vae_name"
          },
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "VAE",
          "type": "VAE",
          "links": [
            5,
            11
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "VAELoader"
      },
      "widgets_values": [
        "minimax_h3_video_vae_fp16.safetensors"
      ]
    },
    {
      "id": 5,
      "type": "VAELoader",
      "pos": [
        0,
        510
      ],
      "size": [
        440,
        100
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "vae_name",
          "type": "COMBO",
          "widget": {
            "name": "vae_name"
          },
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "VAE",
          "type": "VAE",
          "links": [
            12
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "VAELoader"
      },
      "widgets_values": [
        "minimax_h3_audio_vae_fp32.safetensors"
      ]
    },
    {
      "id": 6,
      "type": "MiniMaxH3ImageToVideo",
      "pos": [
        520,
        180
      ],
      "size": [
        480,
        500
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "clip",
          "type": "CLIP",
          "link": 4
        },
        {
          "name": "vae",
          "type": "VAE",
          "link": 5
        },
        {
          "name": "first_frame",
          "type": "IMAGE",
          "shape": 7,
          "link": null
        },
        {
          "name": "last_frame",
          "type": "IMAGE",
          "shape": 7,
          "link": null
        },
        {
          "name": "prompt",
          "type": "STRING",
          "widget": {
            "name": "prompt"
          },
          "link": null
        },
        {
          "name": "width",
          "type": "INT",
          "widget": {
            "name": "width"
          },
          "link": null
        },
        {
          "name": "height",
          "type": "INT",
          "widget": {
            "name": "height"
          },
          "link": null
        },
        {
          "name": "length",
          "type": "INT",
          "widget": {
            "name": "length"
          },
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "positive",
          "type": "CONDITIONING",
          "links": [
            6
          ]
        },
        {
          "name": "LATENT",
          "type": "LATENT",
          "links": [
            10
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "MiniMaxH3ImageToVideo"
      },
      "widgets_values": [
        "A realistic cinematic video, natural motion, coherent anatomy and stable identity, realistic lighting and textures, subtle camera movement, detailed environment. Audio: natural synchronized ambience appropriate to the scene. No text, no subtitles, no logos, no watermark.",
        768,
        432,
        141
      ],
      "title": "FastH3 T2VA — 768x432 / 141f (~5.9s)"
    },
    {
      "id": 7,
      "type": "RandomNoise",
      "pos": [
        1050,
        0
      ],
      "size": [
        300,
        90
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "noise_seed",
          "type": "INT",
          "widget": {
            "name": "noise_seed"
          },
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "NOISE",
          "type": "NOISE",
          "links": [
            7
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "RandomNoise"
      },
      "widgets_values": [
        123456789,
        "randomize"
      ]
    },
    {
      "id": 8,
      "type": "BasicGuider",
      "pos": [
        1050,
        140
      ],
      "size": [
        320,
        100
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": 2
        },
        {
          "name": "conditioning",
          "type": "CONDITIONING",
          "link": 6
        }
      ],
      "outputs": [
        {
          "name": "GUIDER",
          "type": "GUIDER",
          "links": [
            8
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "BasicGuider"
      },
      "widgets_values": []
    },
    {
      "id": 9,
      "type": "KSamplerSelect",
      "pos": [
        1050,
        290
      ],
      "size": [
        320,
        90
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {
          "name": "SAMPLER",
          "type": "SAMPLER",
          "links": [
            9
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "KSamplerSelect"
      },
      "widgets_values": [
        "res_multistep"
      ]
    },
    {
      "id": 10,
      "type": "BasicScheduler",
      "pos": [
        1050,
        430
      ],
      "size": [
        320,
        140
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "model",
          "type": "MODEL",
          "link": 3
        },
        {
          "name": "steps",
          "type": "INT",
          "widget": {
            "name": "steps"
          },
          "link": null
        }
      ],
      "outputs": [
        {
          "name": "SIGMAS",
          "type": "SIGMAS",
          "links": [
            13
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "BasicScheduler"
      },
      "widgets_values": [
        "simple",
        5,
        1.0
      ],
      "title": "REFERENCE: 5 scheduler points / simple / denoise 1.0"
    },
    {
      "id": 11,
      "type": "SamplerCustomAdvanced",
      "pos": [
        1430,
        150
      ],
      "size": [
        280,
        410
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "noise",
          "type": "NOISE",
          "link": 7
        },
        {
          "name": "guider",
          "type": "GUIDER",
          "link": 8
        },
        {
          "name": "sampler",
          "type": "SAMPLER",
          "link": 9
        },
        {
          "name": "sigmas",
          "type": "SIGMAS",
          "link": 13
        },
        {
          "name": "latent_image",
          "type": "LATENT",
          "link": 10
        }
      ],
      "outputs": [
        {
          "name": "output",
          "type": "LATENT",
          "links": [
            14,
            15
          ]
        },
        {
          "name": "denoised_output",
          "type": "LATENT",
          "links": null
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "SamplerCustomAdvanced"
      },
      "widgets_values": []
    },
    {
      "id": 12,
      "type": "VAEDecode",
      "pos": [
        1770,
        100
      ],
      "size": [
        280,
        100
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "samples",
          "type": "LATENT",
          "link": 14
        },
        {
          "name": "vae",
          "type": "VAE",
          "link": 11
        }
      ],
      "outputs": [
        {
          "name": "IMAGE",
          "type": "IMAGE",
          "links": [
            16
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "VAEDecode"
      },
      "widgets_values": []
    },
    {
      "id": 13,
      "type": "VAEDecodeAudio",
      "pos": [
        1770,
        260
      ],
      "size": [
        280,
        100
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "samples",
          "type": "LATENT",
          "link": 15
        },
        {
          "name": "vae",
          "type": "VAE",
          "link": 12
        }
      ],
      "outputs": [
        {
          "name": "AUDIO",
          "type": "AUDIO",
          "links": [
            17
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "VAEDecodeAudio"
      },
      "widgets_values": []
    },
    {
      "id": 14,
      "type": "CreateVideo",
      "pos": [
        2110,
        150
      ],
      "size": [
        300,
        160
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "images",
          "type": "IMAGE",
          "link": 16
        },
        {
          "name": "audio",
          "type": "AUDIO",
          "shape": 7,
          "link": 17
        }
      ],
      "outputs": [
        {
          "name": "VIDEO",
          "type": "VIDEO",
          "links": [
            18
          ]
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "CreateVideo"
      },
      "widgets_values": [
        24,
        8
      ]
    },
    {
      "id": 15,
      "type": "SaveVideo",
      "pos": [
        2470,
        150
      ],
      "size": [
        420,
        220
      ],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [
        {
          "name": "video",
          "type": "VIDEO",
          "link": 18
        }
      ],
      "outputs": [
        {
          "name": "video",
          "type": "VIDEO",
          "links": null
        }
      ],
      "properties": {
        "cnr_id": "comfy-core",
        "Node name for S&R": "SaveVideo"
      },
      "widgets_values": [
        "video/FastH3_VSA_5step_reference",
        "auto",
        "auto"
      ]
    }
  ],
  "links": [
    [
      1,
      1,
      0,
      2,
      0,
      "MODEL"
    ],
    [
      4,
      3,
      0,
      6,
      0,
      "CLIP"
    ],
    [
      5,
      4,
      0,
      6,
      1,
      "VAE"
    ],
    [
      2,
      2,
      0,
      8,
      0,
      "MODEL"
    ],
    [
      6,
      6,
      0,
      8,
      1,
      "CONDITIONING"
    ],
    [
      3,
      2,
      0,
      10,
      0,
      "MODEL"
    ],
    [
      7,
      7,
      0,
      11,
      0,
      "NOISE"
    ],
    [
      8,
      8,
      0,
      11,
      1,
      "GUIDER"
    ],
    [
      9,
      9,
      0,
      11,
      2,
      "SAMPLER"
    ],
    [
      13,
      10,
      0,
      11,
      3,
      "SIGMAS"
    ],
    [
      10,
      6,
      1,
      11,
      4,
      "LATENT"
    ],
    [
      14,
      11,
      0,
      12,
      0,
      "LATENT"
    ],
    [
      11,
      4,
      0,
      12,
      1,
      "VAE"
    ],
    [
      15,
      11,
      0,
      13,
      0,
      "LATENT"
    ],
    [
      12,
      5,
      0,
      13,
      1,
      "VAE"
    ],
    [
      16,
      12,
      0,
      14,
      0,
      "IMAGE"
    ],
    [
      17,
      13,
      0,
      14,
      1,
      "AUDIO"
    ],
    [
      18,
      14,
      0,
      15,
      0,
      "VIDEO"
    ]
  ],
  "groups": [],
  "config": {},
  "extra": {
    "ds": {
      "scale": 0.72,
      "offset": [
        120,
        80
      ]
    }
  },
  "version": 0.4
}
JSON_REF

"$PY" - "$WF_MAIN" "$WF_REF" <<'PY'
import json, sys
for p in sys.argv[1:]:
    with open(p, "r", encoding="utf-8") as f:
        w=json.load(f)
    print("Workflow OK:", p, "nodes=", len(w.get("nodes", [])))
PY

# ------------------------------------------------------------
# 7. Launchers / safe port takeover
# ------------------------------------------------------------
echo
echo "[7/8] Writing launchers"

cat > "$ROOT/stop_port_8188_comfy.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
PORT="$PORT"
found=0
while read -r pid args; do
  [[ -z "\${pid:-}" ]] && continue
  if [[ "\$args" == *"main.py"* && "\$args" == *"--port \$PORT"* ]]; then
    cwd="\$(readlink -f "/proc/\$pid/cwd" 2>/dev/null || true)"
    echo "[STOP] PID=\$pid CWD=\${cwd:-unknown}"
    kill "\$pid" 2>/dev/null || true
    found=1
  fi
done < <(ps -eo pid=,args=)
if [[ "\$found" == "1" ]]; then sleep 3; fi
EOF
chmod +x "$ROOT/stop_port_8188_comfy.sh"

cat > "$ROOT/start_fast_h3.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$ROOT"
PORT="$PORT"
cd "\$ROOT"
"\$ROOT/stop_port_8188_comfy.sh"
source "\$ROOT/.venv/bin/activate"
export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_XET_HIGH_PERFORMANCE=1
export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"
mkdir -p "\$ROOT/runtime_logs"
LOG="\$ROOT/runtime_logs/comfy_\$(date +%Y%m%d_%H%M%S).log"
nohup python main.py \
  --listen 0.0.0.0 \
  --port "\$PORT" \
  --preview-method auto \
  --enable-cors-header \
  > "\$LOG" 2>&1 &
PID=\$!
echo "\$PID" > "\$ROOT/fast_h3.pid"
echo "[START] FastH3 PID=\$PID"
echo "[LOG] \$LOG"

for i in {1..30}; do
  if ! kill -0 "\$PID" 2>/dev/null; then
    echo "[ERROR] FastH3 exited during startup."
    tail -120 "\$LOG" || true
    exit 1
  fi
  if curl -fsS "http://127.0.0.1:\$PORT/system_stats" >/dev/null 2>&1; then
    cwd="\$(readlink -f "/proc/\$PID/cwd" 2>/dev/null || true)"
    echo "[READY] http://127.0.0.1:\$PORT"
    echo "[CWD] \$cwd"
    exit 0
  fi
  sleep 1
done

echo "[ERROR] FastH3 did not become ready in 30 seconds."
tail -120 "\$LOG" || true
exit 1
EOF
chmod +x "$ROOT/start_fast_h3.sh"

cat > "$ROOT/stop_fast_h3.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$ROOT"
if [[ -f "\$ROOT/fast_h3.pid" ]]; then
  pid="\$(cat "\$ROOT/fast_h3.pid" 2>/dev/null || true)"
  if [[ -n "\$pid" ]]; then
    cwd="\$(readlink -f "/proc/\$pid/cwd" 2>/dev/null || true)"
    if [[ "\$cwd" == "\$ROOT" ]]; then
      echo "[STOP] FastH3 PID=\$pid"
      kill "\$pid" 2>/dev/null || true
    fi
  fi
fi
EOF
chmod +x "$ROOT/stop_fast_h3.sh"

cat > "$ROOT/update_fast_h3.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$ROOT"
cd "\$ROOT"
git fetch origin "$COMFY_BRANCH"
git checkout "$COMFY_BRANCH"
git pull --ff-only origin "$COMFY_BRANCH"
"\$ROOT/.venv/bin/python" -m pip install --only-binary=:all: --upgrade "comfy-kitchen[cublas]==0.2.31"
echo "[OK] Updated. Restart with: \$ROOT/start_fast_h3.sh"
EOF
chmod +x "$ROOT/update_fast_h3.sh"

# ------------------------------------------------------------
# 8. Smoke test + switch port 8188 to FastH3
# ------------------------------------------------------------
echo
echo "[8/8] Smoke tests"

"$PY" - <<'PY'
import importlib, importlib.metadata as md, torch, sys
print("Python:", sys.version.split()[0])
print("Torch:", torch.__version__)
print("Torch CUDA:", torch.version.cuda)
if not torch.cuda.is_available():
    raise SystemExit("CUDA unavailable")
p=torch.cuda.get_device_properties(0)
print("GPU:", p.name)
print("Compute capability:", f"{p.major}.{p.minor}")
print("VRAM GiB:", round(p.total_memory/1024**3, 2))
print("comfy-kitchen:", md.version("comfy-kitchen"))
importlib.import_module("comfy_kitchen.backends.cuda._C")
x=torch.randn((256,256), device="cuda", dtype=torch.float16)
_ = x @ x
torch.cuda.synchronize()
print("CUDA smoke test: OK")
PY

cd "$ROOT"
"$PY" - <<'PY'
import sys
sys.path.insert(0, ".")
import comfy.model_management
print("ComfyUI core import: OK")
PY

cat > "$ROOT/FASTH3_SAVED_CONFIG.txt" <<EOF
FastH3 VSA SAVED COMPLETE v4
ComfyUI root: $ROOT
ComfyUI branch: $COMFY_BRANCH
Port: $PORT
Main workflow: $WF_MAIN
Reference workflow: $WF_REF
Main user setting: 10 scheduler steps
Sampler: res_multistep
Scheduler: simple
Denoise: 1.0
Resolution: 768x432
Frames: 141 (~5.9 sec @ 24fps)
FastH3 checkpoint: $FASTH3_FILE
Text encoder: $TEXT_FILE
Video VAE: $VIDEO_VAE_FILE
Audio VAE: $AUDIO_VAE_FILE
EOF

touch "$ROOT/FASTH3_SETUP_OK"

echo
echo "[SWITCH] Port $PORT -> FastH3"
"$ROOT/start_fast_h3.sh"

echo
echo "============================================================"
echo "[SUCCESS] FastH3 SAVED COMPLETE v4 is ready."
echo
echo "Main workflow:"
echo "  $WF_MAIN"
echo
echo "Reference workflow:"
echo "  $WF_REF"
echo
echo "FastH3 is now running on port $PORT."
echo "Open/reload the RunPod HTTP service for port $PORT."
echo
echo "Future startup:"
echo "  $ROOT/start_fast_h3.sh"
echo
echo "Setup log:"
echo "  $LOG"
echo "============================================================"
