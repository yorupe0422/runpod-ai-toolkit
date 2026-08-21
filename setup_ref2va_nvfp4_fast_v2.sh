#!/usr/bin/env bash
set -Eeuo pipefail

# SETUP #6 — MiniMax H3 Ref2VA NVFP4 + AfterMidnight (standalone/idempotent)
# Creates its own environment at /workspace/runpod-slim/ComfyUI-Ref2VA.
# SETUP #5 and an older SETUP #6 are not prerequisites. If compatible model
# files already exist in /workspace/runpod-slim/ComfyUI they are reused by
# symlink; otherwise this script downloads them. The old ComfyUI tree is never
# modified or deleted.

BASE="/workspace/runpod-slim"
COMFY="$BASE/ComfyUI-Ref2VA"
PORT="${PORT:-8188}"
MODEL="MiniMax-H3_Ref2VA-NVFP4.safetensors"
URL="https://huggingface.co/DmitryDB/MiniMax-H3-ComfyUI-Quants/resolve/main/Ref2VA/$MODEL?download=true"
DEST="$COMFY/models/diffusion_models/$MODEL"
WF_DIR="$COMFY/user/default/workflows"
LOG="$BASE/comfyui-ref2va.log"

# Pinned AfterMidnight Ref2VA LoRAs.  Use only one flavor at a time.
AFTERMIDNIGHT_REPO="SexGod1979/AfterMidnight-MiniMax-H3-NSFW"
AFTERMIDNIGHT_REVISION="4b325f60229c136b97501f5830bb277aace738b6"
AFTERMIDNIGHT_SOFT="AfterMidnight_ref2va_h3_softer_rank64_v1.safetensors"
AFTERMIDNIGHT_SOFT_SHA256="16934ba9640e787097fdc6284b065035adaeb6313476abe9a96c0555e7564151"
AFTERMIDNIGHT_SEXY="AfterMidnight_ref2va_h3_sexytime_rank64-v1.2.safetensors"
AFTERMIDNIGHT_SEXY_SHA256="82226a7c7f0b4631092f9270fa33d078c985a2d757895fcbe8f3fca8881bef59"
LORA_DIR="$COMFY/models/loras"
TEXT_ENCODER="qwen3vl-32B-MiniMax-H3-Q4_K_M.gguf"
VIDEO_VAE="minimax_h3_video_vae_fp16.safetensors"
AUDIO_VAE="minimax_h3_audio_vae_fp32.safetensors"

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
die() { red "[FAILED] $*"; exit 1; }

on_error() {
  local rc=$?
  red "SETUP #6 FAILED (exit=$rc, line=${BASH_LINENO[0]:-unknown})"
  echo "Log: $LOG"
  exit "$rc"
}
trap on_error ERR

hf_curl() {
  local url="$1" output="$2"
  local auth=()
  [[ -n "${HF_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $HF_TOKEN")
  curl -fL -C - --retry 12 --retry-all-errors --retry-delay 20 \
    --connect-timeout 30 "${auth[@]}" -o "$output" "$url"
}

ensure_support_model() {
  local rel="$1" url="$2" min_bytes="$3"
  local target="$COMFY/models/$rel"
  local source="$BASE/ComfyUI/models/$rel"
  mkdir -p "$(dirname "$target")"

  if [[ -s "$target" ]] && [[ "$(stat -Lc%s "$target")" -ge "$min_bytes" ]]; then
    echo "  [SKIP] $(basename "$target")"
    return 0
  fi
  rm -f "$target"
  if [[ -s "$source" ]] && [[ "$(stat -Lc%s "$source")" -ge "$min_bytes" ]]; then
    ln -s "$source" "$target"
    echo "  [LINK] $(basename "$target") from existing ComfyUI"
    return 0
  fi

  echo "  [DL] $(basename "$target")"
  hf_curl "$url" "$target.part"
  [[ -s "$target.part" ]] && [[ "$(stat -c%s "$target.part")" -ge "$min_bytes" ]] || \
    die "Downloaded file is incomplete: $target.part"
  mv -f "$target.part" "$target"
}

bootstrap_isolated_comfyui() {
  echo "[0/7] Prepare standalone Ref2VA ComfyUI"

  local missing=()
  for cmd in git curl; do command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd"); done
  if ((${#missing[@]})); then
    command -v apt-get >/dev/null 2>&1 || die "Missing tools: ${missing[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl ca-certificates
  fi
  if ! command -v aria2c >/dev/null 2>&1 || ! command -v lsof >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq aria2 lsof
  fi

  if [[ ! -f "$COMFY/main.py" ]]; then
    if [[ -e "$COMFY" ]]; then
      local backup="${COMFY}.incomplete.$(date +%Y%m%d-%H%M%S)"
      mv "$COMFY" "$backup"
      echo "  [BACKUP] Incomplete directory moved to $backup"
    fi
    git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
  else
    echo "  [SKIP] Existing isolated ComfyUI"
  fi

  grep -Rqs "MiniMaxH3ReferenceToVideo" "$COMFY/comfy_extras" || \
    die "This ComfyUI checkout lacks MiniMaxH3ReferenceToVideo"

  local py=""
  if command -v python3.12 >/dev/null 2>&1; then py="$(command -v python3.12)";
  elif command -v python3 >/dev/null 2>&1; then py="$(command -v python3)";
  else die "python3.12/python3 not found"; fi

  if [[ ! -x "$COMFY/.venv/bin/python" ]]; then
    "$py" -m venv --system-site-packages "$COMFY/.venv" || {
      apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv
      "$py" -m venv --system-site-packages "$COMFY/.venv"
    }
  fi

  if [[ ! -f "$COMFY/.setup6_core_ok" ]]; then
    "$COMFY/.venv/bin/python" -m pip install -q --upgrade pip setuptools wheel
    "$COMFY/.venv/bin/python" -m pip install -q -r "$COMFY/requirements.txt"
    touch "$COMFY/.setup6_core_ok"
  fi

  if [[ ! -f "$COMFY/custom_nodes/ComfyUI-GGUF/__init__.py" ]]; then
    rm -rf "$COMFY/custom_nodes/ComfyUI-GGUF"
    git clone --depth 1 https://github.com/city96/ComfyUI-GGUF.git \
      "$COMFY/custom_nodes/ComfyUI-GGUF"
  fi
  if [[ -f "$COMFY/custom_nodes/ComfyUI-GGUF/requirements.txt" ]] && \
     [[ ! -f "$COMFY/custom_nodes/ComfyUI-GGUF/.setup6_requirements_ok" ]]; then
    "$COMFY/.venv/bin/python" -m pip install -q \
      -r "$COMFY/custom_nodes/ComfyUI-GGUF/requirements.txt"
    touch "$COMFY/custom_nodes/ComfyUI-GGUF/.setup6_requirements_ok"
  fi

  ensure_support_model "text_encoders/$TEXT_ENCODER" \
    "https://huggingface.co/realrebelai/MiniMax-H3_GGUFs/resolve/main/$TEXT_ENCODER?download=true" \
    10000000000
  ensure_support_model "vae/$VIDEO_VAE" \
    "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/$VIDEO_VAE?download=true" \
    900000000
  ensure_support_model "vae/$AUDIO_VAE" \
    "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/$AUDIO_VAE?download=true" \
    300000000
  green "[0/7] Standalone environment ready"
}

download_hf_lora() {
  local name="$1" expected_sha="$2" dest="$LORA_DIR/$1"
  local url="https://huggingface.co/$AFTERMIDNIGHT_REPO/resolve/$AFTERMIDNIGHT_REVISION/$name?download=true"
  local auth=()
  if [[ -f "$dest" ]] && [[ "$(sha256sum "$dest" | awk '{print $1}')" == "$expected_sha" ]]; then
    echo "  [SKIP] $name verified"
    return 0
  fi
  rm -f "$dest.part"
  [[ -n "${HF_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $HF_TOKEN")
  echo "  [DL] $name"
  curl -fL --retry 8 --retry-all-errors --retry-delay 20 --connect-timeout 30 \
    "${auth[@]}" -o "$dest.part" "$url"
  [[ "$(sha256sum "$dest.part" | awk '{print $1}')" == "$expected_sha" ]] || \
    die "SHA256 mismatch for $name"
  mv -f "$dest.part" "$dest"
}

if [[ -n "${HF_TOKEN:-}" ]] && [[ "$HF_TOKEN" != hf_* ]]; then
  die "HF_TOKEN does not look like a Hugging Face token"
fi

bootstrap_isolated_comfyui

mkdir -p "$(dirname "$DEST")" "$WF_DIR" "$LORA_DIR"

echo "[1/7] Check RTX / native loader"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1 || true

"$COMFY/.venv/bin/python" - <<'PY'
from pathlib import Path
src = Path("/workspace/runpod-slim/ComfyUI-Ref2VA/comfy_extras/nodes_minimax_h3.py")
if not src.exists():
    raise SystemExit("MiniMax H3 native nodes file missing")
print("MiniMax H3 native nodes present")
PY
green "[1/7] OK"

echo "[2/7] Download Ref2VA NVFP4 model (~10.9 GiB)"
if [[ -s "$DEST" ]] && [[ "$(stat -c%s "$DEST")" -gt 10000000000 ]]; then
  echo "  [SKIP] $MODEL already present"
else
  rm -f "$DEST" "$DEST.aria2"
  model_auth=()
  if [[ -n "${HF_TOKEN:-}" ]]; then
    [[ "$HF_TOKEN" == hf_* ]] || die "HF_TOKEN does not look like a Hugging Face token"
    model_auth=(--header "Authorization: Bearer $HF_TOKEN")
    echo "  [OK] Using authenticated Hugging Face download"
  else
    echo "  [WARN] HF_TOKEN is unset; shared RunPod IPs may receive HTTP 429"
  fi
  if command -v aria2c >/dev/null 2>&1; then
    aria2c -c -x16 -s16 -k16M --file-allocation=none --allow-overwrite=true \
      --auto-file-renaming=false --max-tries=12 --retry-wait=20 \
      "${model_auth[@]}" --dir "$(dirname "$DEST")" --out "$(basename "$DEST")" "$URL"
  else
    curl -fL --retry 12 --retry-all-errors --retry-delay 20 --connect-timeout 30 \
      "${model_auth[@]}" -o "$DEST" "$URL"
  fi
fi
[[ -s "$DEST" ]] || die "NVFP4 model download failed"
[[ "$(stat -c%s "$DEST")" -gt 10000000000 ]] || die "NVFP4 model looks incomplete"
green "[2/7] Model ready: $(du -h "$DEST" | cut -f1)"

echo "[3/7] Download AfterMidnight Ref2VA LoRAs"
if [[ -z "${HF_TOKEN:-}" ]]; then
  echo "  [WARN] HF_TOKEN is unset; shared RunPod IPs may receive HTTP 429 from Hugging Face"
else
  echo "  [OK] Using authenticated Hugging Face download"
fi
download_hf_lora "$AFTERMIDNIGHT_SOFT" "$AFTERMIDNIGHT_SOFT_SHA256"
download_hf_lora "$AFTERMIDNIGHT_SEXY" "$AFTERMIDNIGHT_SEXY_SHA256"
green "[3/7] AfterMidnight LoRAs ready"

echo "[4/7] Install base FAST / QUALITY workflows"
cat > "$WF_DIR/MiniMax_H3_Ref2VA_ABC_NVFP4_16STEP_FAST.json" <<'__FAST_WF__'
{"id": "MiniMax_H3_Ref2VA_ABC_NVFP4_16STEP_FAST", "revision": 0, "last_node_id": 19, "last_link_id": 22, "nodes": [{"type": "LoadImage", "pos": [40, 100], "size": [320, 330], "flags": {}, "order": 0, "mode": 0, "inputs": [], "outputs": [{"name": "IMAGE", "type": "IMAGE", "links": [5]}, {"name": "MASK", "type": "MASK", "links": null}], "title": "IMAGE A — PERSON / SUBJECT", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "LoadImage"}, "widgets_values": ["person_A.png", "image"], "id": 1}, {"type": "LoadImage", "pos": [40, 480], "size": [320, 330], "flags": {}, "order": 1, "mode": 0, "inputs": [], "outputs": [{"name": "IMAGE", "type": "IMAGE", "links": [6]}, {"name": "MASK", "type": "MASK", "links": null}], "title": "IMAGE B — BACKGROUND", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "LoadImage"}, "widgets_values": ["background_B.png", "image"], "id": 2}, {"type": "LoadVideo", "pos": [390, 100], "size": [470, 330], "flags": {}, "order": 2, "mode": 0, "inputs": [], "outputs": [{"name": "VIDEO", "type": "VIDEO", "links": [1]}], "title": "VIDEO C — MOTION REFERENCE", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "LoadVideo"}, "widgets_values": ["motion_C.mp4", "image"], "id": 3}, {"type": "GetVideoComponents", "pos": [430, 480], "size": [250, 90], "flags": {}, "order": 3, "mode": 0, "inputs": [{"name": "video", "type": "VIDEO", "link": 1}], "outputs": [{"name": "images", "type": "IMAGE", "links": [7]}, {"name": "audio", "type": "AUDIO", "links": null}, {"name": "fps", "type": "FLOAT", "links": null}, {"name": "bit_depth", "type": "INT", "links": null}], "title": "Extract Video C frames", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "GetVideoComponents"}, "widgets_values": [], "id": 4}, {"type": "UNETLoader", "pos": [40, 860], "size": [500, 70], "flags": {}, "order": 4, "mode": 0, "inputs": [], "outputs": [{"name": "MODEL", "type": "MODEL", "links": [8, 10]}], "title": "REF2VA NVFP4 — Blackwell FAST", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "UNETLoader"}, "widgets_values": ["MiniMax-H3_Ref2VA-NVFP4.safetensors", "default"], "id": 5}, {"type": "CLIPLoaderGGUF", "pos": [40, 960], "size": [500, 90], "flags": {}, "order": 5, "mode": 0, "inputs": [], "outputs": [{"name": "CLIP", "type": "CLIP", "links": [2]}], "title": "Qwen3VL 32B Q4_K_M GGUF", "properties": {"cnr_id": "ComfyUI-GGUF", "Node name for S&R": "CLIPLoaderGGUF"}, "widgets_values": ["qwen3vl-32B-MiniMax-H3-Q4_K_M.gguf", "wan"], "id": 6}, {"type": "VAELoader", "pos": [40, 1080], "size": [500, 65], "flags": {}, "order": 6, "mode": 0, "inputs": [], "outputs": [{"name": "VAE", "type": "VAE", "links": [3, 17]}], "title": "VIDEO VAE", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "VAELoader"}, "widgets_values": ["minimax_h3_video_vae_fp16.safetensors"], "id": 7}, {"type": "VAELoader", "pos": [40, 1170], "size": [500, 65], "flags": {}, "order": 7, "mode": 0, "inputs": [], "outputs": [{"name": "VAE", "type": "VAE", "links": [4, 19]}], "title": "AUDIO VAE", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "VAELoader"}, "widgets_values": ["minimax_h3_audio_vae_fp32.safetensors"], "id": 8}, {"type": "MiniMaxH3ReferenceToVideo", "pos": [900, 100], "size": [540, 790], "flags": {}, "order": 8, "mode": 0, "inputs": [{"name": "clip", "type": "CLIP", "link": 2}, {"name": "vae", "type": "VAE", "link": 3}, {"name": "audio_vae", "type": "VAE", "link": 4}, {"label": "ref_image_0", "name": "ref_images.ref_image_0", "shape": 7, "type": "IMAGE", "link": 5}, {"label": "ref_image_1", "name": "ref_images.ref_image_1", "shape": 7, "type": "IMAGE", "link": 6}, {"label": "ref_image_2", "name": "ref_images.ref_image_2", "shape": 7, "type": "IMAGE", "link": null}, {"label": "ref_image_3", "name": "ref_images.ref_image_3", "shape": 7, "type": "IMAGE", "link": null}, {"label": "ref_image_4", "name": "ref_images.ref_image_4", "shape": 7, "type": "IMAGE", "link": null}, {"label": "ref_video_0", "name": "ref_videos.ref_video_0", "shape": 7, "type": "IMAGE", "link": 7}, {"label": "ref_video_1", "name": "ref_videos.ref_video_1", "shape": 7, "type": "IMAGE", "link": null}, {"label": "ref_video_2", "name": "ref_videos.ref_video_2", "shape": 7, "type": "IMAGE", "link": null}, {"label": "ref_video_audio_0", "name": "ref_video_audios.ref_video_audio_0", "shape": 7, "type": "AUDIO", "link": null}, {"label": "ref_video_audio_1", "name": "ref_video_audios.ref_video_audio_1", "shape": 7, "type": "AUDIO", "link": null}, {"label": "ref_video_audio_2", "name": "ref_video_audios.ref_video_audio_2", "shape": 7, "type": "AUDIO", "link": null}, {"label": "ref_audio_0", "name": "ref_audios.ref_audio_0", "shape": 7, "type": "AUDIO", "link": null}, {"label": "ref_audio_1", "name": "ref_audios.ref_audio_1", "shape": 7, "type": "AUDIO", "link": null}, {"label": "ref_audio_2", "name": "ref_audios.ref_audio_2", "shape": 7, "type": "AUDIO", "link": null}, {"name": "prompt", "type": "STRING", "widget": {"name": "prompt"}, "link": null}, {"name": "width", "type": "INT", "widget": {"name": "width"}, "link": null}, {"name": "height", "type": "INT", "widget": {"name": "height"}, "link": null}, {"name": "length", "type": "INT", "widget": {"name": "length"}, "link": null}], "outputs": [{"name": "positive", "type": "CONDITIONING", "links": [9]}, {"name": "LATENT", "type": "LATENT", "links": [15]}], "title": "MiniMax H3 Ref2VA — A + B + C", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "MiniMaxH3ReferenceToVideo"}, "widgets_values": ["subject_definitions:\n<Subject 1> is the person shown in <Picture 1>.\n<Environment 1> is the location and background shown in <Picture 2>.\n<Video 1> is the motion reference video.\n\nsummary:\nGenerate a new video where <Subject 1> appears naturally inside <Environment 1> and follows the body movement, pose transitions, timing, and motion rhythm of <Video 1> as closely as possible.\n\nretention_analysis:\n<Subject 1>: fully_preserved — preserve identity, face, hair, body proportions, and recognizable visual characteristics from <Picture 1>.\n<Environment 1>: strongly_referenced — preserve the location, background composition, lighting mood, spatial layout, and visual atmosphere from <Picture 2>.\n<Video 1>: motion_reference — reproduce the subject motion, timing, pose progression, gesture rhythm, and camera-motion feel from <Video 1>, while replacing the original person with <Subject 1>.\n\ndetailed_description:\n[Shot 1] A coherent realistic shot. <Subject 1> is integrated naturally into <Environment 1>. The person's movement follows <Video 1> closely from beginning to end. Keep the face and identity consistent with <Picture 1>. Keep the environment visually faithful to <Picture 2>. Avoid unrelated people, locations, clothing changes, or unsupported camera movements.\n\noverall_soundscape:\nNatural ambient sound appropriate for <Environment 1>.\n\nnon_diegetic_music:\nnone.", 512, 512, 124], "id": 9}, {"type": "RandomNoise", "pos": [1510, 100], "size": [300, 85], "flags": {}, "order": 9, "mode": 0, "inputs": [], "outputs": [{"name": "NOISE", "type": "NOISE", "links": [11]}], "title": "Seed", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "RandomNoise"}, "widgets_values": [123456789, "randomize"], "id": 10}, {"type": "BasicGuider", "pos": [1510, 220], "size": [300, 70], "flags": {}, "order": 10, "mode": 0, "inputs": [{"name": "model", "type": "MODEL", "link": 8}, {"name": "conditioning", "type": "CONDITIONING", "link": 9}], "outputs": [{"name": "GUIDER", "type": "GUIDER", "links": [12]}], "title": "Guider", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "BasicGuider"}, "widgets_values": [], "id": 11}, {"type": "KSamplerSelect", "pos": [1510, 330], "size": [300, 70], "flags": {}, "order": 11, "mode": 0, "inputs": [], "outputs": [{"name": "SAMPLER", "type": "SAMPLER", "links": [13]}], "title": "Baseline sampler", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "KSamplerSelect"}, "widgets_values": ["res_multistep"], "id": 12}, {"type": "BasicScheduler", "pos": [1510, 440], "size": [300, 120], "flags": {}, "order": 12, "mode": 0, "inputs": [{"name": "model", "type": "MODEL", "link": 10}], "outputs": [{"name": "SIGMAS", "type": "SIGMAS", "links": [14]}], "title": "16 steps / simple", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "BasicScheduler"}, "widgets_values": ["simple", 16, 1.0], "id": 13}, {"type": "SamplerCustomAdvanced", "pos": [1860, 250], "size": [280, 165], "flags": {}, "order": 13, "mode": 0, "inputs": [{"name": "noise", "type": "NOISE", "link": 11}, {"name": "guider", "type": "GUIDER", "link": 12}, {"name": "sampler", "type": "SAMPLER", "link": 13}, {"name": "sigmas", "type": "SIGMAS", "link": 14}, {"name": "latent_image", "type": "LATENT", "link": 15}], "outputs": [{"name": "output", "type": "LATENT", "links": [16, 18]}, {"name": "denoised_output", "type": "LATENT", "links": null}], "title": "Sample", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "SamplerCustomAdvanced"}, "widgets_values": [], "id": 14}, {"type": "VAEDecode", "pos": [2200, 160], "size": [260, 65], "flags": {}, "order": 14, "mode": 0, "inputs": [{"name": "samples", "type": "LATENT", "link": 16}, {"name": "vae", "type": "VAE", "link": 17}], "outputs": [{"name": "IMAGE", "type": "IMAGE", "links": [20]}], "title": "Decode Video", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "VAEDecode"}, "widgets_values": [], "id": 15}, {"type": "VAEDecodeAudio", "pos": [2200, 270], "size": [260, 65], "flags": {}, "order": 15, "mode": 0, "inputs": [{"name": "samples", "type": "LATENT", "link": 18}, {"name": "vae", "type": "VAE", "link": 19}], "outputs": [{"name": "AUDIO", "type": "AUDIO", "links": [21]}], "title": "Decode Audio", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "VAEDecodeAudio"}, "widgets_values": [], "id": 16}, {"type": "CreateVideo", "pos": [2520, 190], "size": [280, 110], "flags": {}, "order": 16, "mode": 0, "inputs": [{"name": "images", "type": "IMAGE", "link": 20}, {"name": "audio", "shape": 7, "type": "AUDIO", "link": 21}], "outputs": [{"name": "VIDEO", "type": "VIDEO", "links": [22]}], "title": "Create Video 24FPS", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "CreateVideo"}, "widgets_values": [24, 8], "id": 17}, {"type": "SaveVideo", "pos": [2860, 100], "size": [620, 690], "flags": {}, "order": 17, "mode": 0, "inputs": [{"name": "video", "type": "VIDEO", "link": 22}], "outputs": [{"name": "video", "type": "VIDEO", "links": null}], "title": "SAVE — Ref2VA ABC", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "SaveVideo"}, "widgets_values": ["video/MiniMax_H3_Ref2VA_ABC_NVFP4_16STEP_FAST", "auto", "auto"], "id": 18}, {"type": "MarkdownNote", "pos": [900, 930], "size": [540, 240], "flags": {}, "order": 18, "mode": 0, "inputs": [], "outputs": [], "title": "How to use", "properties": {}, "widgets_values": ["## Ref2VA NVFP4 16-step FAST\n- Image A = person / identity\n- Image B = background / environment\n- Video C = motion reference\n\nUses Blackwell-native NVFP4 diffusion model and 16 sampling steps.\nNo Turbo LoRA: current Turbo LoRA is not officially Ref2VA-compatible."], "id": 19}], "links": [[1, 3, 0, 4, 0, "VIDEO"], [2, 6, 0, 9, 0, "CLIP"], [3, 7, 0, 9, 1, "VAE"], [4, 8, 0, 9, 2, "VAE"], [5, 1, 0, 9, 3, "IMAGE"], [6, 2, 0, 9, 4, "IMAGE"], [7, 4, 0, 9, 8, "IMAGE"], [8, 5, 0, 11, 0, "MODEL"], [9, 9, 0, 11, 1, "CONDITIONING"], [10, 5, 0, 13, 0, "MODEL"], [11, 10, 0, 14, 0, "NOISE"], [12, 11, 0, 14, 1, "GUIDER"], [13, 12, 0, 14, 2, "SAMPLER"], [14, 13, 0, 14, 3, "SIGMAS"], [15, 9, 1, 14, 4, "LATENT"], [16, 14, 0, 15, 0, "LATENT"], [17, 7, 0, 15, 1, "VAE"], [18, 14, 0, 16, 0, "LATENT"], [19, 8, 0, 16, 1, "VAE"], [20, 15, 0, 17, 0, "IMAGE"], [21, 16, 0, 17, 1, "AUDIO"], [22, 17, 0, 18, 0, "VIDEO"]], "groups": [], "config": {}, "extra": {"ds": {"scale": 0.55, "offset": [100, 80]}}, "version": 0.4}
__FAST_WF__
cat > "$WF_DIR/MiniMax_H3_Ref2VA_ABC_NVFP4_20STEP.json" <<'__QUALITY_WF__'
{"id": "MiniMax_H3_Ref2VA_ABC_NVFP4_20STEP", "revision": 0, "last_node_id": 19, "last_link_id": 22, "nodes": [{"type": "LoadImage", "pos": [40, 100], "size": [320, 330], "flags": {}, "order": 0, "mode": 0, "inputs": [], "outputs": [{"name": "IMAGE", "type": "IMAGE", "links": [5]}, {"name": "MASK", "type": "MASK", "links": null}], "title": "IMAGE A — PERSON / SUBJECT", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "LoadImage"}, "widgets_values": ["person_A.png", "image"], "id": 1}, {"type": "LoadImage", "pos": [40, 480], "size": [320, 330], "flags": {}, "order": 1, "mode": 0, "inputs": [], "outputs": [{"name": "IMAGE", "type": "IMAGE", "links": [6]}, {"name": "MASK", "type": "MASK", "links": null}], "title": "IMAGE B — BACKGROUND", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "LoadImage"}, "widgets_values": ["background_B.png", "image"], "id": 2}, {"type": "LoadVideo", "pos": [390, 100], "size": [470, 330], "flags": {}, "order": 2, "mode": 0, "inputs": [], "outputs": [{"name": "VIDEO", "type": "VIDEO", "links": [1]}], "title": "VIDEO C — MOTION REFERENCE", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "LoadVideo"}, "widgets_values": ["motion_C.mp4", "image"], "id": 3}, {"type": "GetVideoComponents", "pos": [430, 480], "size": [250, 90], "flags": {}, "order": 3, "mode": 0, "inputs": [{"name": "video", "type": "VIDEO", "link": 1}], "outputs": [{"name": "images", "type": "IMAGE", "links": [7]}, {"name": "audio", "type": "AUDIO", "links": null}, {"name": "fps", "type": "FLOAT", "links": null}, {"name": "bit_depth", "type": "INT", "links": null}], "title": "Extract Video C frames", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "GetVideoComponents"}, "widgets_values": [], "id": 4}, {"type": "UNETLoader", "pos": [40, 860], "size": [500, 70], "flags": {}, "order": 4, "mode": 0, "inputs": [], "outputs": [{"name": "MODEL", "type": "MODEL", "links": [8, 10]}], "title": "REF2VA NVFP4 — Blackwell QUALITY", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "UNETLoader"}, "widgets_values": ["MiniMax-H3_Ref2VA-NVFP4.safetensors", "default"], "id": 5}, {"type": "CLIPLoaderGGUF", "pos": [40, 960], "size": [500, 90], "flags": {}, "order": 5, "mode": 0, "inputs": [], "outputs": [{"name": "CLIP", "type": "CLIP", "links": [2]}], "title": "Qwen3VL 32B Q4_K_M GGUF", "properties": {"cnr_id": "ComfyUI-GGUF", "Node name for S&R": "CLIPLoaderGGUF"}, "widgets_values": ["qwen3vl-32B-MiniMax-H3-Q4_K_M.gguf", "wan"], "id": 6}, {"type": "VAELoader", "pos": [40, 1080], "size": [500, 65], "flags": {}, "order": 6, "mode": 0, "inputs": [], "outputs": [{"name": "VAE", "type": "VAE", "links": [3, 17]}], "title": "VIDEO VAE", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "VAELoader"}, "widgets_values": ["minimax_h3_video_vae_fp16.safetensors"], "id": 7}, {"type": "VAELoader", "pos": [40, 1170], "size": [500, 65], "flags": {}, "order": 7, "mode": 0, "inputs": [], "outputs": [{"name": "VAE", "type": "VAE", "links": [4, 19]}], "title": "AUDIO VAE", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "VAELoader"}, "widgets_values": ["minimax_h3_audio_vae_fp32.safetensors"], "id": 8}, {"type": "MiniMaxH3ReferenceToVideo", "pos": [900, 100], "size": [540, 790], "flags": {}, "order": 8, "mode": 0, "inputs": [{"name": "clip", "type": "CLIP", "link": 2}, {"name": "vae", "type": "VAE", "link": 3}, {"name": "audio_vae", "type": "VAE", "link": 4}, {"label": "ref_image_0", "name": "ref_images.ref_image_0", "shape": 7, "type": "IMAGE", "link": 5}, {"label": "ref_image_1", "name": "ref_images.ref_image_1", "shape": 7, "type": "IMAGE", "link": 6}, {"label": "ref_image_2", "name": "ref_images.ref_image_2", "shape": 7, "type": "IMAGE", "link": null}, {"label": "ref_image_3", "name": "ref_images.ref_image_3", "shape": 7, "type": "IMAGE", "link": null}, {"label": "ref_image_4", "name": "ref_images.ref_image_4", "shape": 7, "type": "IMAGE", "link": null}, {"label": "ref_video_0", "name": "ref_videos.ref_video_0", "shape": 7, "type": "IMAGE", "link": 7}, {"label": "ref_video_1", "name": "ref_videos.ref_video_1", "shape": 7, "type": "IMAGE", "link": null}, {"label": "ref_video_2", "name": "ref_videos.ref_video_2", "shape": 7, "type": "IMAGE", "link": null}, {"label": "ref_video_audio_0", "name": "ref_video_audios.ref_video_audio_0", "shape": 7, "type": "AUDIO", "link": null}, {"label": "ref_video_audio_1", "name": "ref_video_audios.ref_video_audio_1", "shape": 7, "type": "AUDIO", "link": null}, {"label": "ref_video_audio_2", "name": "ref_video_audios.ref_video_audio_2", "shape": 7, "type": "AUDIO", "link": null}, {"label": "ref_audio_0", "name": "ref_audios.ref_audio_0", "shape": 7, "type": "AUDIO", "link": null}, {"label": "ref_audio_1", "name": "ref_audios.ref_audio_1", "shape": 7, "type": "AUDIO", "link": null}, {"label": "ref_audio_2", "name": "ref_audios.ref_audio_2", "shape": 7, "type": "AUDIO", "link": null}, {"name": "prompt", "type": "STRING", "widget": {"name": "prompt"}, "link": null}, {"name": "width", "type": "INT", "widget": {"name": "width"}, "link": null}, {"name": "height", "type": "INT", "widget": {"name": "height"}, "link": null}, {"name": "length", "type": "INT", "widget": {"name": "length"}, "link": null}], "outputs": [{"name": "positive", "type": "CONDITIONING", "links": [9]}, {"name": "LATENT", "type": "LATENT", "links": [15]}], "title": "MiniMax H3 Ref2VA — A + B + C", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "MiniMaxH3ReferenceToVideo"}, "widgets_values": ["subject_definitions:\n<Subject 1> is the person shown in <Picture 1>.\n<Environment 1> is the location and background shown in <Picture 2>.\n<Video 1> is the motion reference video.\n\nsummary:\nGenerate a new video where <Subject 1> appears naturally inside <Environment 1> and follows the body movement, pose transitions, timing, and motion rhythm of <Video 1> as closely as possible.\n\nretention_analysis:\n<Subject 1>: fully_preserved — preserve identity, face, hair, body proportions, and recognizable visual characteristics from <Picture 1>.\n<Environment 1>: strongly_referenced — preserve the location, background composition, lighting mood, spatial layout, and visual atmosphere from <Picture 2>.\n<Video 1>: motion_reference — reproduce the subject motion, timing, pose progression, gesture rhythm, and camera-motion feel from <Video 1>, while replacing the original person with <Subject 1>.\n\ndetailed_description:\n[Shot 1] A coherent realistic shot. <Subject 1> is integrated naturally into <Environment 1>. The person's movement follows <Video 1> closely from beginning to end. Keep the face and identity consistent with <Picture 1>. Keep the environment visually faithful to <Picture 2>. Avoid unrelated people, locations, clothing changes, or unsupported camera movements.\n\noverall_soundscape:\nNatural ambient sound appropriate for <Environment 1>.\n\nnon_diegetic_music:\nnone.", 512, 512, 124], "id": 9}, {"type": "RandomNoise", "pos": [1510, 100], "size": [300, 85], "flags": {}, "order": 9, "mode": 0, "inputs": [], "outputs": [{"name": "NOISE", "type": "NOISE", "links": [11]}], "title": "Seed", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "RandomNoise"}, "widgets_values": [123456789, "randomize"], "id": 10}, {"type": "BasicGuider", "pos": [1510, 220], "size": [300, 70], "flags": {}, "order": 10, "mode": 0, "inputs": [{"name": "model", "type": "MODEL", "link": 8}, {"name": "conditioning", "type": "CONDITIONING", "link": 9}], "outputs": [{"name": "GUIDER", "type": "GUIDER", "links": [12]}], "title": "Guider", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "BasicGuider"}, "widgets_values": [], "id": 11}, {"type": "KSamplerSelect", "pos": [1510, 330], "size": [300, 70], "flags": {}, "order": 11, "mode": 0, "inputs": [], "outputs": [{"name": "SAMPLER", "type": "SAMPLER", "links": [13]}], "title": "Baseline sampler", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "KSamplerSelect"}, "widgets_values": ["res_multistep"], "id": 12}, {"type": "BasicScheduler", "pos": [1510, 440], "size": [300, 120], "flags": {}, "order": 12, "mode": 0, "inputs": [{"name": "model", "type": "MODEL", "link": 10}], "outputs": [{"name": "SIGMAS", "type": "SIGMAS", "links": [14]}], "title": "20 steps / simple", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "BasicScheduler"}, "widgets_values": ["simple", 20, 1.0], "id": 13}, {"type": "SamplerCustomAdvanced", "pos": [1860, 250], "size": [280, 165], "flags": {}, "order": 13, "mode": 0, "inputs": [{"name": "noise", "type": "NOISE", "link": 11}, {"name": "guider", "type": "GUIDER", "link": 12}, {"name": "sampler", "type": "SAMPLER", "link": 13}, {"name": "sigmas", "type": "SIGMAS", "link": 14}, {"name": "latent_image", "type": "LATENT", "link": 15}], "outputs": [{"name": "output", "type": "LATENT", "links": [16, 18]}, {"name": "denoised_output", "type": "LATENT", "links": null}], "title": "Sample", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "SamplerCustomAdvanced"}, "widgets_values": [], "id": 14}, {"type": "VAEDecode", "pos": [2200, 160], "size": [260, 65], "flags": {}, "order": 14, "mode": 0, "inputs": [{"name": "samples", "type": "LATENT", "link": 16}, {"name": "vae", "type": "VAE", "link": 17}], "outputs": [{"name": "IMAGE", "type": "IMAGE", "links": [20]}], "title": "Decode Video", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "VAEDecode"}, "widgets_values": [], "id": 15}, {"type": "VAEDecodeAudio", "pos": [2200, 270], "size": [260, 65], "flags": {}, "order": 15, "mode": 0, "inputs": [{"name": "samples", "type": "LATENT", "link": 18}, {"name": "vae", "type": "VAE", "link": 19}], "outputs": [{"name": "AUDIO", "type": "AUDIO", "links": [21]}], "title": "Decode Audio", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "VAEDecodeAudio"}, "widgets_values": [], "id": 16}, {"type": "CreateVideo", "pos": [2520, 190], "size": [280, 110], "flags": {}, "order": 16, "mode": 0, "inputs": [{"name": "images", "type": "IMAGE", "link": 20}, {"name": "audio", "shape": 7, "type": "AUDIO", "link": 21}], "outputs": [{"name": "VIDEO", "type": "VIDEO", "links": [22]}], "title": "Create Video 24FPS", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "CreateVideo"}, "widgets_values": [24, 8], "id": 17}, {"type": "SaveVideo", "pos": [2860, 100], "size": [620, 690], "flags": {}, "order": 17, "mode": 0, "inputs": [{"name": "video", "type": "VIDEO", "link": 22}], "outputs": [{"name": "video", "type": "VIDEO", "links": null}], "title": "SAVE — Ref2VA ABC", "properties": {"cnr_id": "comfy-core", "Node name for S&R": "SaveVideo"}, "widgets_values": ["video/MiniMax_H3_Ref2VA_ABC_NVFP4_20STEP", "auto", "auto"], "id": 18}, {"type": "MarkdownNote", "pos": [900, 930], "size": [540, 240], "flags": {}, "order": 18, "mode": 0, "inputs": [], "outputs": [], "title": "How to use", "properties": {}, "widgets_values": ["## Ref2VA NVFP4 20-step QUALITY\n- Image A = person / identity\n- Image B = background / environment\n- Video C = motion reference\n\nUses Blackwell-native NVFP4 diffusion model and 20 sampling steps.\nNo Turbo LoRA: current Turbo LoRA is not officially Ref2VA-compatible."], "id": 19}], "links": [[1, 3, 0, 4, 0, "VIDEO"], [2, 6, 0, 9, 0, "CLIP"], [3, 7, 0, 9, 1, "VAE"], [4, 8, 0, 9, 2, "VAE"], [5, 1, 0, 9, 3, "IMAGE"], [6, 2, 0, 9, 4, "IMAGE"], [7, 4, 0, 9, 8, "IMAGE"], [8, 5, 0, 11, 0, "MODEL"], [9, 9, 0, 11, 1, "CONDITIONING"], [10, 5, 0, 13, 0, "MODEL"], [11, 10, 0, 14, 0, "NOISE"], [12, 11, 0, 14, 1, "GUIDER"], [13, 12, 0, 14, 2, "SAMPLER"], [14, 13, 0, 14, 3, "SIGMAS"], [15, 9, 1, 14, 4, "LATENT"], [16, 14, 0, 15, 0, "LATENT"], [17, 7, 0, 15, 1, "VAE"], [18, 14, 0, 16, 0, "LATENT"], [19, 8, 0, 16, 1, "VAE"], [20, 15, 0, 17, 0, "IMAGE"], [21, 16, 0, 17, 1, "AUDIO"], [22, 17, 0, 18, 0, "VIDEO"]], "groups": [], "config": {}, "extra": {"ds": {"scale": 0.55, "offset": [100, 80]}}, "version": 0.4}
__QUALITY_WF__
green "[4/7] Base workflows installed"

echo "[5/7] Build AfterMidnight Euler + beta workflows"
COMFY_DIR="$COMFY" WF_DIR="$WF_DIR" SOFT_LORA="$AFTERMIDNIGHT_SOFT" SEXY_LORA="$AFTERMIDNIGHT_SEXY" \
  "$COMFY/.venv/bin/python" - <<'PY'
import copy, json, os
from pathlib import Path

wf_dir = Path(os.environ["WF_DIR"])
base_path = wf_dir / "MiniMax_H3_Ref2VA_ABC_NVFP4_20STEP.json"
base = json.loads(base_path.read_text(encoding="utf-8"))

def add_aftermidnight(filename, lora_name, title):
    wf = copy.deepcopy(base)
    nodes = wf["nodes"]
    links = wf["links"]
    by_id = {n["id"]: n for n in nodes}
    model_loader = next(n for n in nodes if n["type"] == "UNETLoader")
    guider = next(n for n in nodes if n["type"] == "BasicGuider")
    scheduler = next(n for n in nodes if n["type"] == "BasicScheduler")
    sampler = next(n for n in nodes if n["type"] == "KSamplerSelect")
    note = next((n for n in nodes if n["type"] == "MarkdownNote"), None)
    new_id = max(n["id"] for n in nodes) + 1
    new_link = max(link[0] for link in links) + 1

    # Existing model links feed BasicGuider and BasicScheduler.  Reroute them
    # through one core LoRA loader, keeping the remainder of the known-good
    # Ref2VA graph intact.
    target_ids = {guider["id"], scheduler["id"]}
    for link in links:
        if link[1] == model_loader["id"] and link[2] == 0 and link[3] in target_ids:
            link[1] = new_id
    model_loader["outputs"][0]["links"] = [new_link]

    lora = {
        "id": new_id,
        "type": "LoraLoaderModelOnly",
        "pos": [610, 860],
        "size": [500, 95],
        "flags": {},
        "order": max(n.get("order", 0) for n in nodes) + 1,
        "mode": 0,
        "inputs": [{"name": "model", "type": "MODEL", "link": new_link}],
        "outputs": [{"name": "MODEL", "type": "MODEL", "links": [8, 10]}],
        "title": title,
        "properties": {"Node name for S&R": "LoraLoaderModelOnly"},
        "widgets_values": [lora_name, 0.75],
    }
    nodes.append(lora)
    links.append([new_link, model_loader["id"], 0, new_id, 0, "MODEL"])
    sampler["widgets_values"] = ["euler"]
    scheduler["widgets_values"] = ["beta", 20, 1.0]
    guider["title"] = "Guider — AfterMidnight"
    sampler["title"] = "Euler (required by AfterMidnight)"
    scheduler["title"] = "20 steps / beta (required by AfterMidnight)"
    if note:
        note["title"] = "AfterMidnight Ref2VA — usage"
        note["widgets_values"] = [
            "## AfterMidnight Ref2VA\n"
            "- Use one flavor only; this workflow loads exactly one.\n"
            "- Sampler: Euler / Scheduler: beta (author requirement).\n"
            "- Start at LoRA strength 0.75; tune within 0.55–0.90.\n"
            "- Image A: subject, Image B: environment, Video C: motion reference.\n"
            "- First test: 512×512, about 5 seconds."
        ]
    wf["id"] = filename.removesuffix(".json")
    for n in nodes:
        if n["type"] == "SaveVideo":
            n["title"] = "SAVE — " + filename.removesuffix(".json")
            n["widgets_values"][0] = "video/" + filename.removesuffix(".json")
    wf["last_node_id"] = new_id
    wf["last_link_id"] = new_link
    (wf_dir / filename).write_text(json.dumps(wf, ensure_ascii=False), encoding="utf-8")

add_aftermidnight("MiniMax_H3_Ref2VA_AfterMidnight_Softer.json", os.environ["SOFT_LORA"], "AfterMidnight — Softer (0.75)")
add_aftermidnight("MiniMax_H3_Ref2VA_AfterMidnight_Sexytime_v1_2.json", os.environ["SEXY_LORA"], "AfterMidnight — Sexytime v1.2 (0.75)")
for path in wf_dir.glob("MiniMax_H3_Ref2VA_AfterMidnight_*.json"):
    json.loads(path.read_text(encoding="utf-8"))
print("AfterMidnight workflow JSON validation OK")
PY
green "[5/7] AfterMidnight workflows installed"

echo "[6/7] Validate workflow JSON"
WF_DIR="$WF_DIR" "$COMFY/.venv/bin/python" - <<'PY'
import json
import os
from pathlib import Path
root=Path(os.environ["WF_DIR"])
for name in ["MiniMax_H3_Ref2VA_ABC_NVFP4_16STEP_FAST.json",
             "MiniMax_H3_Ref2VA_ABC_NVFP4_20STEP.json",
             "MiniMax_H3_Ref2VA_AfterMidnight_Softer.json",
             "MiniMax_H3_Ref2VA_AfterMidnight_Sexytime_v1_2.json"]:
    d=json.loads((root/name).read_text())
    loaders=[n for n in d["nodes"] if n["type"]=="UNETLoader"]
    assert loaders and loaders[0]["widgets_values"][0]=="MiniMax-H3_Ref2VA-NVFP4.safetensors"
    if "AfterMidnight" in name:
        loras=[n for n in d["nodes"] if n["type"]=="LoraLoaderModelOnly"]
        assert len(loras)==1 and loras[0]["widgets_values"][1] == 0.75
print("workflow JSON validation OK")
PY
green "[6/7] OK"

echo "[7/7] Restart isolated Ref2VA environment on port $PORT"
pkill -9 -f "/workspace/runpod-slim/ComfyUI-Ref2VA.*main.py" 2>/dev/null || true
# Free port only if another ComfyUI process owns it. This does not delete either environment.
if command -v lsof >/dev/null 2>&1; then
  pids="$(lsof -ti tcp:$PORT 2>/dev/null || true)"
  [[ -z "$pids" ]] || kill -9 $pids 2>/dev/null || true
fi
sleep 2
cd "$COMFY"
nohup "$COMFY/.venv/bin/python" main.py   --listen 0.0.0.0   --port "$PORT"   --preview-method auto   --enable-cors-header   --reserve-vram 3   --cache-none   > "$LOG" 2>&1 &
PID=$!

ready=0
for i in $(seq 1 180); do
  if ! kill -0 "$PID" 2>/dev/null; then
    tail -100 "$LOG" || true
    die "ComfyUI exited during startup"
  fi
  if curl --max-time 3 -fsS "http://127.0.0.1:$PORT/object_info" >/tmp/ref2va_nvfp4_object_info.json 2>/dev/null; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" == "1" ]] || die "ComfyUI startup timeout"
green "[7/7] ComfyUI ready"

echo "[7/7] Validate required nodes"
"$COMFY/.venv/bin/python" - <<'PY'
import json
d=json.load(open("/tmp/ref2va_nvfp4_object_info.json"))
req=["MiniMaxH3ReferenceToVideo","UNETLoader","CLIPLoaderGGUF","LoadVideo",
     "GetVideoComponents","LoraLoaderModelOnly","SamplerCustomAdvanced","VAEDecodeAudio","CreateVideo","SaveVideo"]
missing=[x for x in req if x not in d]
if missing:
    raise SystemExit("Missing nodes: "+", ".join(missing))
print("all required nodes found")
PY
green "[7/7] Validation passed"

echo
echo "============================================================"
green " SETUP #6 — REF2VA + AFTERMIDNIGHT READY"
echo "============================================================"
echo "Model    : $MODEL"
echo "FAST WF  : MiniMax_H3_Ref2VA_ABC_NVFP4_16STEP_FAST.json"
echo "Quality  : MiniMax_H3_Ref2VA_ABC_NVFP4_20STEP.json"
echo "AfterMidnight Softer : MiniMax_H3_Ref2VA_AfterMidnight_Softer.json"
echo "AfterMidnight v1.2  : MiniMax_H3_Ref2VA_AfterMidnight_Sexytime_v1_2.json"
echo "Port     : $PORT"
echo "Log      : $LOG"
echo
echo "Recommended first test: AfterMidnight Softer / 512x512 / ~5 sec"
echo "============================================================"
