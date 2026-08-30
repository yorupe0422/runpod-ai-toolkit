#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${FASTH3_ROOT:-/workspace/runpod-slim/ComfyUI-FastH3}"
VENV="$ROOT/.venv"
PORT="${COMFY_PORT:-8188}"
LOG_DIR="$ROOT/setup_logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/update_step1900_probe_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

trap 'rc=$?; echo; echo "============================================================"; echo "[FAILED] rc=$rc line=$LINENO"; echo "Log: $LOG"; echo "============================================================"; exit $rc' ERR

echo "============================================================"
echo " FastH3 VSA UPDATE / STEP1900 PROBE v5"
echo " ROOT : $ROOT"
echo " PORT : $PORT"
echo " LOG  : $LOG"
echo "============================================================"

[[ -d "$ROOT/.git" ]] || { echo "[ERROR] Missing FastH3 repo at $ROOT"; exit 1; }
[[ -x "$VENV/bin/python" ]] || { echo "[ERROR] Missing venv at $VENV"; exit 1; }

PY="$VENV/bin/python"
PIP="$VENV/bin/pip"

cd "$ROOT"

echo
echo "[1/7] Update ComfyUI vsa branch"
git fetch origin vsa
git checkout vsa
git pull --ff-only origin vsa || echo "[WARN] Pull failed; keeping existing branch state."
echo "[ComfyUI commit] $(git rev-parse HEAD)"

echo
echo "[2/7] Refresh packages"
"$PIP" install -U pip setuptools wheel packaging
"$PIP" install --only-binary=:all: --upgrade "comfy-kitchen[cublas]==0.2.31"
"$PIP" install -U "huggingface_hub[hf_xet]" hf_transfer
"$PIP" install -r requirements.txt

echo
echo "[3/7] Ensure current core model files"
mkdir -p models/diffusion_models models/text_encoders models/vae user/default/workflows
export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_XET_HIGH_PERFORMANCE=1
HF="$VENV/bin/hf"
[[ -x "$HF" ]] || HF="$(command -v hf || true)"
[[ -n "$HF" ]] || { echo "[ERROR] hf CLI not found"; exit 1; }

"$HF" download Kijai/MiniMax-H3-experimental \
  minimax_h3_fastvideo_vsa_datafree_1300step_4step_int8_convrot.safetensors \
  --local-dir models/diffusion_models
"$HF" download Comfy-Org/MiniMax-H3 \
  text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors \
  vae/minimax_h3_video_vae_fp16.safetensors \
  vae/minimax_h3_audio_vae_fp32.safetensors \
  --local-dir models

echo
echo "[4/7] Probe Kijai repo for ComfyUI-converted Synthetic Step1900"
PROBE_ENV="$ROOT/step1900_probe.env"
"$PY" - <<'PY' > "$PROBE_ENV"
from huggingface_hub import list_repo_files
repo = "Kijai/MiniMax-H3-experimental"
files = list_repo_files(repo)

def score(name):
    s = name.lower()
    pts = 0
    if s.endswith(".safetensors"): pts += 100
    if "fastvideo" in s: pts += 50
    if "synthetic" in s: pts += 40
    if "1900" in s: pts += 40
    if "int8_convrot" in s: pts += 30
    if s.startswith("loras/") or "/loras/" in s: pts -= 200
    if s.startswith("controlnet/") or "/controlnet/" in s: pts -= 200
    if "vae" in s or "text_encoder" in s or "qwen" in s: pts -= 200
    return pts

cands = sorted([f for f in files if score(f) >= 150], key=lambda x: (-score(x), x))
if cands:
    print("STEP1900_FOUND=1")
    print("STEP1900_REPO_FILE=" + cands[0])
    print("STEP1900_MODEL_BASENAME=" + cands[0].split("/")[-1])
else:
    print("STEP1900_FOUND=0")
PY

cat "$PROBE_ENV"
source "$PROBE_ENV"

STEP1900_WF="$ROOT/user/default/workflows/FastH3_VSA_10step_Synthetic1900_ALT_5090.json"
STEP1900_NOTE="$ROOT/user/default/workflows/STEP1900_STATUS.txt"

if [[ "${STEP1900_FOUND:-0}" == "1" ]]; then
  echo "[FOUND] $STEP1900_REPO_FILE"
  "$HF" download Kijai/MiniMax-H3-experimental "$STEP1900_REPO_FILE" --local-dir models/diffusion_models
  DOWNLOADED_PATH="$(find "$ROOT/models/diffusion_models" -type f -name "$STEP1900_MODEL_BASENAME" | head -n1 || true)"
  [[ -n "$DOWNLOADED_PATH" ]] || { echo "[ERROR] Step1900 file not found after download"; exit 1; }
  if [[ "$DOWNLOADED_PATH" != "$ROOT/models/diffusion_models/$STEP1900_MODEL_BASENAME" ]]; then
    ln -sf "$DOWNLOADED_PATH" "$ROOT/models/diffusion_models/$STEP1900_MODEL_BASENAME"
  fi
  echo "Step1900 model installed: $ROOT/models/diffusion_models/$STEP1900_MODEL_BASENAME" > "$STEP1900_NOTE"
else
  echo "[SKIP] No converted Synthetic Step1900 checkpoint found in Kijai repo."
  echo "No converted Synthetic Step1900 checkpoint found in Kijai/MiniMax-H3-experimental at update time." > "$STEP1900_NOTE"
  rm -f "$STEP1900_WF"
fi

echo
echo "[5/7] Write workflows"
cat > "$ROOT/user/default/workflows/FastH3_VSA_10step_MAIN_DataFree1300_5090.json" <<'JSON_MAIN'
{
  "id": "eba0cea1-abb8-417e-90e1-166a9615257e",
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
      },
      "widgets_values": [
        "simple",
        10,
        1.0
      ],
      "title": "MAIN: DataFree1300 / 10 steps / simple / denoise 1.0"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
      },
      "widgets_values": [
        "video/FastH3_VSA_10step_DataFree1300",
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

cat > "$ROOT/user/default/workflows/FastH3_VSA_5step_REFERENCE_DataFree1300_5090.json" <<'JSON_REF'
{
  "id": "39194fa6-f51c-4876-bc1d-d6ccf1240aa4",
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
      },
      "widgets_values": [
        "simple",
        5,
        1.0
      ],
      "title": "REFERENCE: DataFree1300 / 5 scheduler points / simple / denoise 1.0"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
      },
      "widgets_values": [
        "video/FastH3_VSA_5step_DataFree1300_reference",
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

if [[ "${STEP1900_FOUND:-0}" == "1" ]]; then
  cat > "$STEP1900_WF" <<'JSON_1900'
{
  "id": "f1f6bad9-d2c6-46cd-9f26-1efad6ee8645",
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
        "cnr_id": "comfy-core"
      },
      "widgets_values": [
        "__STEP1900_MODEL__",
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
      },
      "widgets_values": [
        "simple",
        10,
        1.0
      ],
      "title": "ALT: Synthetic1900 / 10 steps / simple / denoise 1.0"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
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
        "cnr_id": "comfy-core"
      },
      "widgets_values": [
        "video/FastH3_VSA_10step_Synthetic1900",
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
JSON_1900
  sed -i "s/__STEP1900_MODEL__/$STEP1900_MODEL_BASENAME/g" "$STEP1900_WF"
fi

"$PY" - <<'PY'
import json, os
paths = [
  "user/default/workflows/FastH3_VSA_10step_MAIN_DataFree1300_5090.json",
  "user/default/workflows/FastH3_VSA_5step_REFERENCE_DataFree1300_5090.json",
]
alt = "user/default/workflows/FastH3_VSA_10step_Synthetic1900_ALT_5090.json"
if os.path.exists(alt):
    paths.append(alt)
for p in paths:
    with open(p, "r", encoding="utf-8") as f:
        data = json.load(f)
    print("Workflow OK:", p, "nodes=", len(data.get("nodes", [])))
PY

echo
echo "[6/7] Smoke tests"
"$PY" - <<'PY'
import importlib, importlib.metadata as md, torch, sys
print("Python:", sys.version.split()[0])
print("Torch:", torch.__version__)
print("Torch CUDA:", torch.version.cuda)
if not torch.cuda.is_available():
    raise SystemExit("CUDA unavailable")
p = torch.cuda.get_device_properties(0)
print("GPU:", p.name)
print("Compute capability:", f"{p.major}.{p.minor}")
print("VRAM GiB:", round(p.total_memory/1024**3, 2))
print("comfy-kitchen:", md.version("comfy-kitchen"))
importlib.import_module("comfy_kitchen.backends.cuda._C")
x = torch.randn((256,256), device="cuda", dtype=torch.float16)
_ = x @ x
torch.cuda.synchronize()
print("CUDA smoke test: OK")
PY

echo
echo "[7/7] Restart FastH3 on port $PORT"
if [[ -x "$ROOT/stop_fast_h3.sh" ]]; then
  "$ROOT/stop_fast_h3.sh" || true
fi
while read -r pid args; do
  [[ -z "${pid:-}" ]] && continue
  if [[ "$args" == *"main.py"* && "$args" == *"--port $PORT"* ]]; then
    cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
    echo "[STOP] PID=$pid CWD=${cwd:-unknown}"
    kill "$pid" 2>/dev/null || true
  fi
done < <(ps -eo pid=,args=)
sleep 3

export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_XET_HIGH_PERFORMANCE=1
export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"
mkdir -p "$ROOT/runtime_logs"
RLOG="$ROOT/runtime_logs/comfy_$(date +%Y%m%d_%H%M%S).log"
nohup "$PY" main.py --listen 0.0.0.0 --port "$PORT" --preview-method auto --enable-cors-header > "$RLOG" 2>&1 &
NEWPID=$!
echo "$NEWPID" > "$ROOT/fast_h3.pid"
echo "[START] FastH3 PID=$NEWPID"
echo "[LOG] $RLOG"

for i in $(seq 1 40); do
  if ! kill -0 "$NEWPID" 2>/dev/null; then
    echo "[ERROR] FastH3 exited during startup."
    tail -120 "$RLOG" || true
    exit 1
  fi
  if curl -fsS "http://127.0.0.1:$PORT/system_stats" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo
echo "============================================================"
echo "[SUCCESS] FastH3 update finished."
echo
echo "Main workflow:"
echo "  $ROOT/user/default/workflows/FastH3_VSA_10step_MAIN_DataFree1300_5090.json"
echo "Reference workflow:"
echo "  $ROOT/user/default/workflows/FastH3_VSA_5step_REFERENCE_DataFree1300_5090.json"
if [[ "${STEP1900_FOUND:-0}" == "1" ]]; then
  echo "Synthetic Step1900 ALT workflow:"
  echo "  $STEP1900_WF"
  echo "Step1900 model:"
  echo "  $ROOT/models/diffusion_models/$STEP1900_MODEL_BASENAME"
else
  echo "Synthetic Step1900 ALT workflow: NOT INSTALLED"
fi
echo "FastH3 is running on port $PORT."
echo "Log: $LOG"
echo "============================================================"
