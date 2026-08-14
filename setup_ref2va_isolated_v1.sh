#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# MiniMax H3 Ref2VA — CLEAN ISOLATED REBUILD v1
#
# Goal:
#   Create a fresh ComfyUI dedicated to Ref2VA without touching
#   the known-good /workspace/runpod-slim/ComfyUI environment.
#
# New environment:
#   /workspace/runpod-slim/ComfyUI-Ref2VA
# Port:
#   8189
#
# Reuses already-downloaded model files via symlinks.
# ============================================================

BASE="/workspace/runpod-slim"
OLD="$BASE/ComfyUI"
NEW="$BASE/ComfyUI-Ref2VA"
PORT="${PORT:-8189}"
PY="${PYTHON_BIN:-python3.12}"
LOG="$BASE/comfyui-ref2va.log"

MODEL_REF="MiniMax-H3-REF2VA-Q4_K_M.gguf"
MODEL_CLIP="qwen3vl-32B-MiniMax-H3-Q4_K_M.gguf"
MODEL_VVAE="minimax_h3_video_vae_fp16.safetensors"
MODEL_AVAE="minimax_h3_audio_vae_fp32.safetensors"

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
die() { red "[FAILED] $*"; exit 1; }

echo "============================================================"
echo " MiniMax H3 Ref2VA CLEAN ISOLATED REBUILD v1"
echo "============================================================"

[[ -d "$OLD" ]] || die "Existing ComfyUI not found: $OLD"

# Verify the expensive files already exist before doing anything.
for f in   "$OLD/models/diffusion_models/$MODEL_REF"   "$OLD/models/text_encoders/$MODEL_CLIP"   "$OLD/models/vae/$MODEL_VVAE"   "$OLD/models/vae/$MODEL_AVAE"
do
  [[ -s "$f" ]] || die "Required model missing: $f"
done
green "[1/9] Existing Ref2VA models verified — NO redownload"

# Build clean tree. Existing isolated tree is replaced; the old known-good tree is untouched.
rm -rf "$NEW"
git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$NEW"
cd "$NEW"

grep -R "class MiniMaxH3ReferenceToVideo" comfy_extras >/dev/null 2>&1   || grep -R "MiniMaxH3ReferenceToVideo" comfy_extras >/dev/null 2>&1   || die "Fresh ComfyUI master still lacks MiniMaxH3ReferenceToVideo"
green "[2/9] Fresh latest ComfyUI contains MiniMaxH3ReferenceToVideo"

# Isolated Python environment while reusing system Torch/CUDA.
"$PY" -m venv --system-site-packages "$NEW/.venv"
"$NEW/.venv/bin/python" -m pip install -q --upgrade pip
"$NEW/.venv/bin/python" -m pip install -q -r "$NEW/requirements.txt"
green "[3/9] Core requirements installed in isolated venv"

# Only required custom node.
git clone --depth 1 https://github.com/city96/ComfyUI-GGUF.git "$NEW/custom_nodes/ComfyUI-GGUF"
if [[ -f "$NEW/custom_nodes/ComfyUI-GGUF/requirements.txt" ]]; then
  "$NEW/.venv/bin/python" -m pip install -q -r "$NEW/custom_nodes/ComfyUI-GGUF/requirements.txt"
fi
green "[4/9] ComfyUI-GGUF installed"

# Reuse big model files — zero copy, zero download.
mkdir -p "$NEW/models/diffusion_models" "$NEW/models/text_encoders" "$NEW/models/vae"
ln -sf "$OLD/models/diffusion_models/$MODEL_REF" "$NEW/models/diffusion_models/$MODEL_REF"
ln -sf "$OLD/models/text_encoders/$MODEL_CLIP" "$NEW/models/text_encoders/$MODEL_CLIP"
ln -sf "$OLD/models/vae/$MODEL_VVAE" "$NEW/models/vae/$MODEL_VVAE"
ln -sf "$OLD/models/vae/$MODEL_AVAE" "$NEW/models/vae/$MODEL_AVAE"
green "[5/9] Models linked from existing environment"

# Write the ABC workflow locally.
mkdir -p "$NEW/user/default/workflows"
cat > "$NEW/user/default/workflows/MiniMax_H3_Ref2VA_ABC_Q4KM_ISOLATED.json" <<'__WF_JSON__'
{"id": "minimax-h3-ref2va-abc-q4km-isolated", "revision": 0, "last_node_id": 19, "last_link_id": 22, "nodes": [{"type": "LoadImage", "pos": [40, 100], "size": [320, 330], "flags": {}, "order": 0, "mode": 0, "inputs": [], "outputs": [{"name": "IMAGE", "type": "IMAGE", "links": [5]}, {"name": "MASK", "type": "MASK", "links": null}], "title": "IMAGE A — PERSON / SUBJECT", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "LoadImage"}, "widgets_values": ["person_A.png", "image"], "id": 1}, {"type": "LoadImage", "pos": [40, 480], "size": [320, 330], "flags": {}, "order": 1, "mode": 0, "inputs": [], "outputs": [{"name": "IMAGE", "type": "IMAGE", "links": [6]}, {"name": "MASK", "type": "MASK", "links": null}], "title": "IMAGE B — BACKGROUND", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "LoadImage"}, "widgets_values": ["background_B.png", "image"], "id": 2}, {"type": "LoadVideo", "pos": [390, 100], "size": [470, 330], "flags": {}, "order": 2, "mode": 0, "inputs": [], "outputs": [{"name": "VIDEO", "type": "VIDEO", "links": [1]}], "title": "VIDEO C — MOTION REFERENCE", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "LoadVideo"}, "widgets_values": ["motion_C.mp4", "image"], "id": 3}, {"type": "GetVideoComponents", "pos": [430, 480], "size": [250, 90], "flags": {}, "order": 3, "mode": 0, "inputs": [{"name": "video", "type": "VIDEO", "link": 1}], "outputs": [{"name": "images", "type": "IMAGE", "links": [7]}, {"name": "audio", "type": "AUDIO", "links": null}, {"name": "fps", "type": "FLOAT", "links": null}, {"name": "bit_depth", "type": "INT", "links": null}], "title": "Extract Video C frames", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "GetVideoComponents"}, "widgets_values": [], "id": 4}, {"type": "UnetLoaderGGUF", "pos": [40, 860], "size": [500, 70], "flags": {}, "order": 4, "mode": 0, "inputs": [], "outputs": [{"name": "MODEL", "type": "MODEL", "links": [8, 10]}], "title": "REF2VA Q4_K_M GGUF", "properties": {"cnr_id": "ComfyUI-GGUF", "Node name for S&R": "UnetLoaderGGUF"}, "widgets_values": ["MiniMax-H3-REF2VA-Q4_K_M.gguf"], "id": 5}, {"type": "CLIPLoaderGGUF", "pos": [40, 960], "size": [500, 90], "flags": {}, "order": 5, "mode": 0, "inputs": [], "outputs": [{"name": "CLIP", "type": "CLIP", "links": [2]}], "title": "Qwen3VL 32B Q4_K_M GGUF", "properties": {"cnr_id": "ComfyUI-GGUF", "Node name for S&R": "CLIPLoaderGGUF"}, "widgets_values": ["qwen3vl-32B-MiniMax-H3-Q4_K_M.gguf", "wan"], "id": 6}, {"type": "VAELoader", "pos": [40, 1080], "size": [500, 65], "flags": {}, "order": 6, "mode": 0, "inputs": [], "outputs": [{"name": "VAE", "type": "VAE", "links": [3, 17]}], "title": "VIDEO VAE", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "VAELoader"}, "widgets_values": ["minimax_h3_video_vae_fp16.safetensors"], "id": 7}, {"type": "VAELoader", "pos": [40, 1170], "size": [500, 65], "flags": {}, "order": 7, "mode": 0, "inputs": [], "outputs": [{"name": "VAE", "type": "VAE", "links": [4, 19]}], "title": "AUDIO VAE", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "VAELoader"}, "widgets_values": ["minimax_h3_audio_vae_fp32.safetensors"], "id": 8}, {"type": "MiniMaxH3ReferenceToVideo", "pos": [900, 100], "size": [540, 790], "flags": {}, "order": 8, "mode": 0, "inputs": [{"name": "clip", "type": "CLIP", "link": 2}, {"name": "vae", "type": "VAE", "link": 3}, {"name": "audio_vae", "type": "VAE", "link": 4}, {"label": "ref_image_0", "name": "ref_images.ref_image_0", "shape": 7, "type": "IMAGE", "link": 5}, {"label": "ref_image_1", "name": "ref_images.ref_image_1", "shape": 7, "type": "IMAGE", "link": 6}, {"label": "ref_image_2", "name": "ref_images.ref_image_2", "shape": 7, "type": "IMAGE", "link": null}, {"label": "ref_image_3", "name": "ref_images.ref_image_3", "shape": 7, "type": "IMAGE", "link": null}, {"label": "ref_image_4", "name": "ref_images.ref_image_4", "shape": 7, "type": "IMAGE", "link": null}, {"label": "ref_video_0", "name": "ref_videos.ref_video_0", "shape": 7, "type": "IMAGE", "link": 7}, {"label": "ref_video_1", "name": "ref_videos.ref_video_1", "shape": 7, "type": "IMAGE", "link": null}, {"label": "ref_video_2", "name": "ref_videos.ref_video_2", "shape": 7, "type": "IMAGE", "link": null}, {"label": "ref_video_audio_0", "name": "ref_video_audios.ref_video_audio_0", "shape": 7, "type": "AUDIO", "link": null}, {"label": "ref_video_audio_1", "name": "ref_video_audios.ref_video_audio_1", "shape": 7, "type": "AUDIO", "link": null}, {"label": "ref_video_audio_2", "name": "ref_video_audios.ref_video_audio_2", "shape": 7, "type": "AUDIO", "link": null}, {"label": "ref_audio_0", "name": "ref_audios.ref_audio_0", "shape": 7, "type": "AUDIO", "link": null}, {"label": "ref_audio_1", "name": "ref_audios.ref_audio_1", "shape": 7, "type": "AUDIO", "link": null}, {"label": "ref_audio_2", "name": "ref_audios.ref_audio_2", "shape": 7, "type": "AUDIO", "link": null}, {"name": "prompt", "type": "STRING", "widget": {"name": "prompt"}, "link": null}, {"name": "width", "type": "INT", "widget": {"name": "width"}, "link": null}, {"name": "height", "type": "INT", "widget": {"name": "height"}, "link": null}, {"name": "length", "type": "INT", "widget": {"name": "length"}, "link": null}], "outputs": [{"name": "positive", "type": "CONDITIONING", "links": [9]}, {"name": "LATENT", "type": "LATENT", "links": [15]}], "title": "MiniMax H3 Ref2VA — A + B + C", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "MiniMaxH3ReferenceToVideo"}, "widgets_values": ["subject_definitions:\n<Subject 1> is the person shown in <Picture 1>.\n<Environment 1> is the location and background shown in <Picture 2>.\n<Video 1> is the motion reference video.\n\nsummary:\nGenerate a new video where <Subject 1> appears naturally inside <Environment 1> and follows the body movement, pose transitions, timing, and motion rhythm of <Video 1> as closely as possible.\n\nretention_analysis:\n<Subject 1>: fully_preserved — preserve identity, face, hair, body proportions, and recognizable visual characteristics from <Picture 1>.\n<Environment 1>: strongly_referenced — preserve the location, background composition, lighting mood, spatial layout, and visual atmosphere from <Picture 2>.\n<Video 1>: motion_reference — reproduce the subject motion, timing, pose progression, gesture rhythm, and camera-motion feel from <Video 1>, while replacing the original person with <Subject 1>.\n\ndetailed_description:\n[Shot 1] A coherent realistic shot. <Subject 1> is integrated naturally into <Environment 1>. The person's movement follows <Video 1> closely from beginning to end. Keep the face and identity consistent with <Picture 1>. Keep the environment visually faithful to <Picture 2>. Avoid unrelated people, locations, clothing changes, or unsupported camera movements.\n\noverall_soundscape:\nNatural ambient sound appropriate for <Environment 1>.\n\nnon_diegetic_music:\nnone.", 512, 512, 124], "id": 9}, {"type": "RandomNoise", "pos": [1510, 100], "size": [300, 85], "flags": {}, "order": 9, "mode": 0, "inputs": [], "outputs": [{"name": "NOISE", "type": "NOISE", "links": [11]}], "title": "Seed", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "RandomNoise"}, "widgets_values": [123456789, "randomize"], "id": 10}, {"type": "BasicGuider", "pos": [1510, 220], "size": [300, 70], "flags": {}, "order": 10, "mode": 0, "inputs": [{"name": "model", "type": "MODEL", "link": 8}, {"name": "conditioning", "type": "CONDITIONING", "link": 9}], "outputs": [{"name": "GUIDER", "type": "GUIDER", "links": [12]}], "title": "Guider", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "BasicGuider"}, "widgets_values": [], "id": 11}, {"type": "KSamplerSelect", "pos": [1510, 330], "size": [300, 70], "flags": {}, "order": 11, "mode": 0, "inputs": [], "outputs": [{"name": "SAMPLER", "type": "SAMPLER", "links": [13]}], "title": "Baseline sampler", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "KSamplerSelect"}, "widgets_values": ["res_multistep"], "id": 12}, {"type": "BasicScheduler", "pos": [1510, 440], "size": [300, 120], "flags": {}, "order": 12, "mode": 0, "inputs": [{"name": "model", "type": "MODEL", "link": 10}], "outputs": [{"name": "SIGMAS", "type": "SIGMAS", "links": [14]}], "title": "25 steps / simple", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "BasicScheduler"}, "widgets_values": ["simple", 25, 1.0], "id": 13}, {"type": "SamplerCustomAdvanced", "pos": [1860, 250], "size": [280, 165], "flags": {}, "order": 13, "mode": 0, "inputs": [{"name": "noise", "type": "NOISE", "link": 11}, {"name": "guider", "type": "GUIDER", "link": 12}, {"name": "sampler", "type": "SAMPLER", "link": 13}, {"name": "sigmas", "type": "SIGMAS", "link": 14}, {"name": "latent_image", "type": "LATENT", "link": 15}], "outputs": [{"name": "output", "type": "LATENT", "links": [16, 18]}, {"name": "denoised_output", "type": "LATENT", "links": null}], "title": "Sample", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "SamplerCustomAdvanced"}, "widgets_values": [], "id": 14}, {"type": "VAEDecode", "pos": [2200, 160], "size": [260, 65], "flags": {}, "order": 14, "mode": 0, "inputs": [{"name": "samples", "type": "LATENT", "link": 16}, {"name": "vae", "type": "VAE", "link": 17}], "outputs": [{"name": "IMAGE", "type": "IMAGE", "links": [20]}], "title": "Decode Video", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "VAEDecode"}, "widgets_values": [], "id": 15}, {"type": "VAEDecodeAudio", "pos": [2200, 270], "size": [260, 65], "flags": {}, "order": 15, "mode": 0, "inputs": [{"name": "samples", "type": "LATENT", "link": 18}, {"name": "vae", "type": "VAE", "link": 19}], "outputs": [{"name": "AUDIO", "type": "AUDIO", "links": [21]}], "title": "Decode Audio", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "VAEDecodeAudio"}, "widgets_values": [], "id": 16}, {"type": "CreateVideo", "pos": [2520, 190], "size": [280, 110], "flags": {}, "order": 16, "mode": 0, "inputs": [{"name": "images", "type": "IMAGE", "link": 20}, {"name": "audio", "shape": 7, "type": "AUDIO", "link": 21}], "outputs": [{"name": "VIDEO", "type": "VIDEO", "links": [22]}], "title": "Create Video 24FPS", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "CreateVideo"}, "widgets_values": [24, 8], "id": 17}, {"type": "SaveVideo", "pos": [2860, 100], "size": [620, 690], "flags": {}, "order": 17, "mode": 0, "inputs": [{"name": "video", "type": "VIDEO", "link": 22}], "outputs": [{"name": "video", "type": "VIDEO", "links": null}], "title": "SAVE — Ref2VA ABC", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "SaveVideo"}, "widgets_values": ["video/MiniMax_H3_Ref2VA_ABC_ISOLATED", "auto", "auto"], "id": 18}, {"type": "MarkdownNote", "pos": [900, 930], "size": [540, 240], "flags": {}, "order": 18, "mode": 0, "inputs": [], "outputs": [], "title": "How to use", "properties": {}, "widgets_values": ["## INPUTS\n- **Image A** = person / identity\n- **Image B** = background / environment\n- **Video C** = motion reference\n\nFirst run uses **512×512, 124 frames (~5s), 25 steps**. Confirm stability before creating a Turbo copy."], "id": 19}], "links": [[1, 3, 0, 4, 0, "VIDEO"], [2, 6, 0, 9, 0, "CLIP"], [3, 7, 0, 9, 1, "VAE"], [4, 8, 0, 9, 2, "VAE"], [5, 1, 0, 9, 3, "IMAGE"], [6, 2, 0, 9, 4, "IMAGE"], [7, 4, 0, 9, 8, "IMAGE"], [8, 5, 0, 11, 0, "MODEL"], [9, 9, 0, 11, 1, "CONDITIONING"], [10, 5, 0, 13, 0, "MODEL"], [11, 10, 0, 14, 0, "NOISE"], [12, 11, 0, 14, 1, "GUIDER"], [13, 12, 0, 14, 2, "SAMPLER"], [14, 13, 0, 14, 3, "SIGMAS"], [15, 9, 1, 14, 4, "LATENT"], [16, 14, 0, 15, 0, "LATENT"], [17, 7, 0, 15, 1, "VAE"], [18, 14, 0, 16, 0, "LATENT"], [19, 8, 0, 16, 1, "VAE"], [20, 15, 0, 17, 0, "IMAGE"], [21, 16, 0, 17, 1, "AUDIO"], [22, 17, 0, 18, 0, "VIDEO"]], "groups": [], "config": {}, "extra": {"ds": {"scale": 0.55, "offset": [100, 80]}}, "version": 0.4}
__WF_JSON__
green "[6/9] ABC Ref2VA workflow installed"

# Do NOT touch port 8188. Kill only an older isolated Ref2VA server on 8189.
pids="$(lsof -ti tcp:$PORT 2>/dev/null || true)"
if [[ -n "$pids" ]]; then
  kill -9 $pids 2>/dev/null || true
  sleep 2
fi

cd "$NEW"
nohup "$NEW/.venv/bin/python" main.py   --listen 0.0.0.0   --port "$PORT"   --preview-method auto   --enable-cors-header   --reserve-vram 3   --cache-none   > "$LOG" 2>&1 &
PID=$!

ready=0
for i in $(seq 1 180); do
  if ! kill -0 "$PID" 2>/dev/null; then
    tail -100 "$LOG" || true
    die "Isolated ComfyUI exited during startup"
  fi
  if curl --max-time 3 -fsS "http://127.0.0.1:$PORT/object_info" > /tmp/ref2va_object_info.json 2>/dev/null; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" == "1" ]] || die "Startup timeout on port $PORT"
green "[7/9] Isolated ComfyUI is responding on port $PORT"

"$NEW/.venv/bin/python" - <<'PY'
import json, sys
d=json.load(open("/tmp/ref2va_object_info.json"))
required = [
    "MiniMaxH3ReferenceToVideo",
    "UnetLoaderGGUF",
    "CLIPLoaderGGUF",
    "LoadVideo",
    "GetVideoComponents",
    "SamplerCustomAdvanced",
    "VAEDecodeAudio",
    "CreateVideo",
    "SaveVideo",
]
missing=[x for x in required if x not in d]
if missing:
    print("Missing node types:", ", ".join(missing))
    sys.exit(1)
print("All required node types found.")
PY
green "[8/9] Required Ref2VA/GGUF/video nodes verified"

# Confirm exact model files are visible through the server.
"$NEW/.venv/bin/python" - <<'PY'
from pathlib import Path
root=Path("/workspace/runpod-slim/ComfyUI-Ref2VA/models")
files=[
 root/"diffusion_models"/"MiniMax-H3-REF2VA-Q4_K_M.gguf",
 root/"text_encoders"/"qwen3vl-32B-MiniMax-H3-Q4_K_M.gguf",
 root/"vae"/"minimax_h3_video_vae_fp16.safetensors",
 root/"vae"/"minimax_h3_audio_vae_fp32.safetensors",
]
bad=[str(p) for p in files if not p.exists()]
if bad:
    raise SystemExit("Missing symlinked models: " + ", ".join(bad))
print("All model links present.")
PY
green "[9/9] Model links verified"

echo
echo "============================================================"
green " REF2VA ISOLATED ENVIRONMENT READY"
echo "============================================================"
echo "Old stable ComfyUI : $OLD       (untouched, port 8188)"
echo "New Ref2VA ComfyUI : $NEW"
echo "Ref2VA port        : $PORT"
echo "Workflow           : MiniMax_H3_Ref2VA_ABC_Q4KM_ISOLATED.json"
echo "Log                : $LOG"
echo
echo "RunPod: expose/open HTTP port $PORT and open the Ref2VA ComfyUI."
echo "Inputs: Image A = person / Image B = background / Video C = motion"
echo "============================================================"
