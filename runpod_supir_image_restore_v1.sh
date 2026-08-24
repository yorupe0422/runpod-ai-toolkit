#!/usr/bin/env bash
set -Eeuo pipefail

COMFY_DIR="${COMFY_DIR:-/workspace/runpod-slim/ComfyUI}"
PORT="${PORT:-8188}"
LISTEN="${LISTEN:-0.0.0.0}"
LOG_DIR="${LOG_DIR:-/workspace/runpod-slim/logs}"
LOG_FILE="$LOG_DIR/comfyui_supir.log"
WF_DIR="$COMFY_DIR/user/default/workflows"
CUSTOM_NODES_DIR="$COMFY_DIR/custom_nodes"
CHECKPOINT_DIR="$COMFY_DIR/models/checkpoints"
HF_HOME="${HF_HOME:-/workspace/hf-cache}"
SUPIR_REPO_DIR="$CUSTOM_NODES_DIR/ComfyUI-SUPIR"
SUPIR_COMMIT="53fc4f82f139e0875e1f4f3716fbeafa073e4242"
SUPIR_WF="$WF_DIR/capture_to_iphone_supir_v1.json"

msg() { echo -e "\n[INFO] $*"; }
warn() { echo -e "\n[WARN] $*"; }
fail() { echo -e "\n[ERROR] $*" >&2; exit 1; }

[[ -d "$COMFY_DIR" ]] || fail "ComfyUI directory not found: $COMFY_DIR"
mkdir -p "$LOG_DIR" "$WF_DIR" "$CUSTOM_NODES_DIR" "$CHECKPOINT_DIR" "$HF_HOME"
export HF_HOME
export PIP_DISABLE_PIP_VERSION_CHECK=1

if [[ -x "$COMFY_DIR/.venv/bin/python" ]]; then
  PY="$COMFY_DIR/.venv/bin/python"
else
  PY="python3"
fi

msg "Using Python: $PY"
cd "$COMFY_DIR"

msg "Installing helper Python packages..."
"$PY" -m pip install -q -U huggingface_hub requests safetensors >/dev/null

msg "Installing / updating ComfyUI-SUPIR custom node..."
if [[ -d "$SUPIR_REPO_DIR/.git" ]]; then
  git -C "$SUPIR_REPO_DIR" fetch --depth 1 origin
else
  git clone https://github.com/kijai/ComfyUI-SUPIR "$SUPIR_REPO_DIR"
fi
git -C "$SUPIR_REPO_DIR" checkout "$SUPIR_COMMIT"
"$PY" -m pip install -q -r "$SUPIR_REPO_DIR/requirements.txt" >/dev/null

msg "Downloading required models..."
"$PY" <<'PY'
from huggingface_hub import hf_hub_download
from pathlib import Path
import os

checkpoint_dir = Path(os.environ.get("CHECKPOINT_DIR", "/workspace/runpod-slim/ComfyUI/models/checkpoints"))
checkpoint_dir.mkdir(parents=True, exist_ok=True)

def dl(repo_id, filename, out_dir, local_name=None):
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    target = out_dir / (local_name or Path(filename).name)
    if target.exists() and target.stat().st_size > 1_000_000:
        print(f"[SKIP] {target.name}")
        return
    print(f"[DL] {repo_id} :: {filename} -> {target.name}")
    hf_hub_download(
        repo_id=repo_id,
        filename=filename,
        local_dir=str(out_dir),
        local_dir_use_symlinks=False,
        resume_download=True,
    )
    # rename if the upstream filename differs from the desired local display name
    upstream = out_dir / Path(filename).name
    if local_name and upstream.exists() and upstream.name != local_name:
        upstream.rename(target)

# Base photoreal SDXL checkpoint (quality-first, not lightning)
dl(
    repo_id="RunDiffusion/Juggernaut-XL-v9",
    filename="JuggernautXL_v9_RunDiffusionPhoto_v2.safetensors",
    out_dir=checkpoint_dir,
)

# SUPIR models: v0Q is the default/high-quality choice, v0F is included as an alternate.
for supir_file in ["SUPIR-v0Q_fp16.safetensors", "SUPIR-v0F_fp16.safetensors"]:
    dl(
        repo_id="Kijai/SUPIR_pruned",
        filename=supir_file,
        out_dir=checkpoint_dir,
    )
PY

msg "Writing SUPIR workflow..."
cat > "$SUPIR_WF" <<'JSON'
{
  "id": "c76c4640-fb69-4f0f-b930-d1f4de66e001",
  "revision": 0,
  "last_node_id": 9,
  "last_link_id": 16,
  "nodes": [
    {
      "id": 1,
      "type": "LoadImage",
      "pos": [-760, 80],
      "size": [350, 400],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {"name": "IMAGE", "type": "IMAGE", "slot_index": 0, "links": [1]},
        {"name": "MASK", "type": "MASK", "links": null}
      ],
      "properties": {"cnr_id": "comfy-core", "Node name for S&R": "LoadImage"},
      "widgets_values": ["example_input.png", "image"]
    },
    {
      "id": 2,
      "type": "CheckpointLoaderSimple",
      "pos": [-760, -170],
      "size": [430, 98],
      "flags": {},
      "order": 1,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {"name": "MODEL", "type": "MODEL", "slot_index": 0, "links": [2]},
        {"name": "CLIP", "type": "CLIP", "slot_index": 1, "links": [3]},
        {"name": "VAE", "type": "VAE", "slot_index": 2, "links": [4]}
      ],
      "properties": {"cnr_id": "comfy-core", "Node name for S&R": "CheckpointLoaderSimple"},
      "widgets_values": ["JuggernautXL_v9_RunDiffusionPhoto_v2.safetensors"]
    },
    {
      "id": 3,
      "type": "SUPIR_model_loader_v2",
      "pos": [-280, -170],
      "size": [420, 170],
      "flags": {},
      "order": 2,
      "mode": 0,
      "inputs": [
        {"name": "model", "type": "MODEL", "link": 2},
        {"name": "clip", "type": "CLIP", "link": 3},
        {"name": "vae", "type": "VAE", "link": 4}
      ],
      "outputs": [
        {"name": "SUPIR_model", "type": "SUPIRMODEL", "slot_index": 0, "links": [8, 10]},
        {"name": "SUPIR_VAE", "type": "SUPIRVAE", "slot_index": 1, "links": [5, 14]}
      ],
      "properties": {"cnr_id": "comfyui-supir", "Node name for S&R": "SUPIR_model_loader_v2"},
      "widgets_values": ["SUPIR-v0Q_fp16.safetensors", false, "auto", false]
    },
    {
      "id": 4,
      "type": "SUPIR_first_stage",
      "pos": [170, 30],
      "size": [300, 170],
      "flags": {},
      "order": 3,
      "mode": 0,
      "inputs": [
        {"name": "SUPIR_VAE", "type": "SUPIRVAE", "link": 5},
        {"name": "image", "type": "IMAGE", "link": 1}
      ],
      "outputs": [
        {"name": "SUPIR_VAE", "type": "SUPIRVAE", "slot_index": 0, "links": [6]},
        {"name": "denoised_image", "type": "IMAGE", "slot_index": 1, "links": [7]},
        {"name": "denoised_latents", "type": "LATENT", "slot_index": 2, "links": [9]}
      ],
      "properties": {"cnr_id": "comfyui-supir", "Node name for S&R": "SUPIR_first_stage"},
      "widgets_values": [true, 512, 512, "auto"]
    },
    {
      "id": 5,
      "type": "SUPIR_encode",
      "pos": [500, 30],
      "size": [220, 126],
      "flags": {},
      "order": 4,
      "mode": 0,
      "inputs": [
        {"name": "SUPIR_VAE", "type": "SUPIRVAE", "link": 6},
        {"name": "image", "type": "IMAGE", "link": 7}
      ],
      "outputs": [
        {"name": "latent", "type": "LATENT", "slot_index": 0, "links": [11]}
      ],
      "properties": {"cnr_id": "comfyui-supir", "Node name for S&R": "SUPIR_encode"},
      "widgets_values": [true, 512, "auto"]
    },
    {
      "id": 6,
      "type": "SUPIR_conditioner",
      "pos": [500, 190],
      "size": [430, 210],
      "flags": {},
      "order": 5,
      "mode": 0,
      "inputs": [
        {"name": "SUPIR_model", "type": "SUPIRMODEL", "link": 8},
        {"name": "latents", "type": "LATENT", "link": 9},
        {"name": "captions", "shape": 7, "type": "STRING", "link": null}
      ],
      "outputs": [
        {"name": "positive", "type": "SUPIR_cond_pos", "slot_index": 0, "links": [12]},
        {"name": "negative", "type": "SUPIR_cond_neg", "slot_index": 1, "links": [13]}
      ],
      "properties": {"cnr_id": "comfyui-supir", "Node name for S&R": "SUPIR_conditioner"},
      "widgets_values": [
        "high quality, realistic, crisp smartphone photo, natural detail, clean sharp focus, preserve subject, preserve composition, natural colors",
        "blurry, noisy, compression artifacts, overprocessed, oversharpened, waxy skin, deformed, text, watermark"
      ]
    },
    {
      "id": 7,
      "type": "SUPIR_sample",
      "pos": [980, 20],
      "size": [330, 460],
      "flags": {},
      "order": 6,
      "mode": 0,
      "inputs": [
        {"name": "SUPIR_model", "type": "SUPIRMODEL", "link": 10},
        {"name": "latents", "type": "LATENT", "link": 11},
        {"name": "positive", "type": "SUPIR_cond_pos", "link": 12},
        {"name": "negative", "type": "SUPIR_cond_neg", "link": 13}
      ],
      "outputs": [
        {"name": "latent", "type": "LATENT", "slot_index": 0, "links": [15]}
      ],
      "properties": {"cnr_id": "comfyui-supir", "Node name for S&R": "SUPIR_sample"},
      "widgets_values": [
        174277455657960,
        "fixed",
        10,
        2,
        1.5,
        5,
        1.003,
        1,
        1,
        0.9,
        1,
        false,
        "RestoreDPMPP2MSampler",
        1024,
        512
      ]
    },
    {
      "id": 8,
      "type": "SUPIR_decode",
      "pos": [1360, 90],
      "size": [260, 102],
      "flags": {},
      "order": 7,
      "mode": 0,
      "inputs": [
        {"name": "SUPIR_VAE", "type": "SUPIRVAE", "link": 14},
        {"name": "latents", "type": "LATENT", "link": 15}
      ],
      "outputs": [
        {"name": "image", "type": "IMAGE", "slot_index": 0, "links": [16]}
      ],
      "properties": {"cnr_id": "comfyui-supir", "Node name for S&R": "SUPIR_decode"},
      "widgets_values": [true, 512]
    },
    {
      "id": 9,
      "type": "PreviewImage",
      "pos": [1660, 35],
      "size": [800, 900],
      "flags": {},
      "order": 8,
      "mode": 0,
      "inputs": [
        {"name": "images", "type": "IMAGE", "link": 16}
      ],
      "outputs": [],
      "properties": {"cnr_id": "comfy-core", "Node name for S&R": "PreviewImage"},
      "widgets_values": []
    }
  ],
  "links": [
    [1, 1, 0, 4, 1, "IMAGE"],
    [2, 2, 0, 3, 0, "MODEL"],
    [3, 2, 1, 3, 1, "CLIP"],
    [4, 2, 2, 3, 2, "VAE"],
    [5, 3, 1, 4, 0, "SUPIRVAE"],
    [6, 4, 0, 5, 0, "SUPIRVAE"],
    [7, 4, 1, 5, 1, "IMAGE"],
    [8, 3, 0, 6, 0, "SUPIRMODEL"],
    [9, 4, 2, 6, 1, "LATENT"],
    [10, 3, 0, 7, 0, "SUPIRMODEL"],
    [11, 5, 0, 7, 1, "LATENT"],
    [12, 6, 0, 7, 2, "SUPIR_cond_pos"],
    [13, 6, 1, 7, 3, "SUPIR_cond_neg"],
    [14, 3, 1, 8, 0, "SUPIRVAE"],
    [15, 7, 0, 8, 1, "LATENT"],
    [16, 8, 0, 9, 0, "IMAGE"]
  ],
  "groups": [],
  "config": {},
  "extra": {},
  "version": 0.4
}
JSON

msg "Restarting ComfyUI on port $PORT so the new nodes are loaded..."
PIDS="$(pgrep -f "python.*main\.py.*--port[= ]$PORT" || true)"
if [[ -n "$PIDS" ]]; then
  kill $PIDS || true
  sleep 5
fi

nohup "$PY" main.py --listen "$LISTEN" --port "$PORT" --preview-method auto --enable-cors-header > "$LOG_FILE" 2>&1 &
NEW_PID=$!
echo "$NEW_PID" > "$LOG_DIR/comfyui_supir.pid"

msg "Waiting for API startup..."
SUCCESS=0
for _ in $(seq 1 90); do
  sleep 2
  if curl -sf "http://127.0.0.1:$PORT/object_info" > /tmp/comfyui_object_info.json; then
    if "$PY" - <<'PY'
import json, sys
required = {
    "SUPIR_model_loader_v2",
    "SUPIR_first_stage",
    "SUPIR_encode",
    "SUPIR_conditioner",
    "SUPIR_sample",
    "SUPIR_decode",
}
with open('/tmp/comfyui_object_info.json', 'r', encoding='utf-8') as f:
    data = json.load(f)
missing = sorted(required.difference(data.keys()))
if missing:
    print("Missing nodes:", ", ".join(missing))
    sys.exit(1)
print("All required SUPIR nodes detected.")
PY
    then
      SUCCESS=1
      break
    fi
  fi
done

if [[ "$SUCCESS" != "1" ]]; then
  warn "ComfyUI did not pass the SUPIR node check in time. Last log lines:"
  tail -n 120 "$LOG_FILE" || true
  exit 1
fi

cat <<EOF

============================================================
SUPIR image-restore environment is ready.

Workflow:
  $SUPIR_WF

Models downloaded:
  $CHECKPOINT_DIR/JuggernautXL_v9_RunDiffusionPhoto_v2.safetensors
  $CHECKPOINT_DIR/SUPIR-v0Q_fp16.safetensors
  $CHECKPOINT_DIR/SUPIR-v0F_fp16.safetensors

How to use:
  1) Open ComfyUI on port $PORT
  2) Load workflow: capture_to_iphone_supir_v1.json
  3) In LoadImage, choose your screenshot/capture image
  4) Queue Prompt

Notes:
  - Default model is SUPIR-v0Q (quality-first).
  - If the result becomes slightly too "processed", switch the SUPIR model node
    from SUPIR-v0Q_fp16.safetensors to SUPIR-v0F_fp16.safetensors.
  - This workflow is tuned for still images only. We'll do video in phase 2.
============================================================
EOF
