#!/usr/bin/env bash
set -Eeuo pipefail

# #11 Candidate — MiniMax H3 Director RV2V COMPLETE v1
# Fresh Pod -> dedicated Ref2VA RV2V environment
# Install: /workspace/runpod-slim/ComfyUI-H3-Director-RV2V
# Port: 8188

ROOT="${ROOT:-/workspace/runpod-slim}"
COMFY="${COMFY:-$ROOT/ComfyUI-H3-Director-RV2V}"
PORT="${PORT:-8188}"
COMFY_TAG="${COMFY_TAG:-v0.34.0}"
PY="$COMFY/.venv/bin/python"
PIP="$COMFY/.venv/bin/pip"
WF_DIR="$COMFY/user/default/workflows"
LOG_DIR="$COMFY/user/setup_logs"
STATE_DIR="$ROOT/.h3_director_rv2v_v1"

COMFY_REPO="https://github.com/comfyanonymous/ComfyUI.git"
DIRECTOR_REPO="https://github.com/AIMixer/ComfyUI_MiniMaxH3_Director.git"
HF_BASE="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main"

MODEL="minimax_h3_ref2va_pruned_int8_convrot.safetensors"
TEXT="qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"
VIDEO_VAE="minimax_h3_video_vae_fp16.safetensors"
AUDIO_VAE="minimax_h3_audio_vae_fp32.safetensors"

WF_RV2V="11_MINIMAX_H3_DIRECTOR_RV2V_25STEP.json"
WF_V2V="11_MINIMAX_H3_DIRECTOR_V2V_25STEP.json"
WF_R2V="11_MINIMAX_H3_DIRECTOR_R2V_25STEP.json"
RAW_DIRECTOR="https://raw.githubusercontent.com/AIMixer/ComfyUI_MiniMaxH3_Director/main/example_workflows"

mkdir -p "$ROOT" "$STATE_DIR"
LOG="$STATE_DIR/setup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
green(){ printf '\033[1;32m%s\033[0m\n' "$*"; }
red(){ printf '\033[1;31m%s\033[0m\n' "$*"; }
trap 'red "[FAILED] line=$LINENO command=$BASH_COMMAND"; exit 1' ERR

echo "=== #11 MiniMax H3 Director RV2V COMPLETE v1 ==="

echo "[1/10] System"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y git git-lfs curl aria2 ffmpeg python3 python3-venv python3-pip build-essential libgl1 libglib2.0-0
git lfs install

echo "[2/10] Isolated ComfyUI"
if [[ -d "$COMFY/.git" ]]; then
  cd "$COMFY"; git fetch --tags --force; git reset --hard; git clean -fd; git checkout -f "$COMFY_TAG"
else
  rm -rf "$COMFY"
  git clone --branch "$COMFY_TAG" --depth 1 "$COMFY_REPO" "$COMFY"
fi
python3 -m venv "$COMFY/.venv"
"$PIP" install -U pip setuptools wheel
"$PIP" install -r "$COMFY/requirements.txt"
"$PIP" install -U "comfy-kitchen[cublas]" || "$PIP" install -U comfy-kitchen

echo "[3/10] Director"
mkdir -p "$COMFY/custom_nodes"
rm -rf "$COMFY/custom_nodes/ComfyUI_MiniMaxH3_Director"
git clone --depth 1 "$DIRECTOR_REPO" "$COMFY/custom_nodes/ComfyUI_MiniMaxH3_Director"
[[ ! -f "$COMFY/custom_nodes/ComfyUI_MiniMaxH3_Director/requirements.txt" ]] || "$PIP" install -r "$COMFY/custom_nodes/ComfyUI_MiniMaxH3_Director/requirements.txt"

echo "[4/10] Directories"
mkdir -p "$COMFY/models/diffusion_models" "$COMFY/models/text_encoders" "$COMFY/models/vae" "$WF_DIR" "$LOG_DIR"

download_hf(){
  local rel="$1" out="$2" minbytes="$3"
  if [[ -f "$out" ]] && [[ "$(stat -c%s "$out")" -ge "$minbytes" ]]; then echo "exists: $(basename "$out")"; return; fi
  rm -f "$out" "$out.aria2"
  aria2c -x16 -s16 -k1M --file-allocation=none --retry-wait=5 --max-tries=20 --timeout=60 -d "$(dirname "$out")" -o "$(basename "$out")" "$HF_BASE/$rel?download=true"
  [[ "$(stat -c%s "$out")" -ge "$minbytes" ]]
}

echo "[5/10] Dedicated Ref2VA model"
download_hf "diffusion_models/$MODEL" "$COMFY/models/diffusion_models/$MODEL" 19000000000
download_hf "text_encoders/$TEXT" "$COMFY/models/text_encoders/$TEXT" 10000000000
download_hf "vae/$VIDEO_VAE" "$COMFY/models/vae/$VIDEO_VAE" 100000000
download_hf "vae/$AUDIO_VAE" "$COMFY/models/vae/$AUDIO_VAE" 100000000

echo "[6/10] Director workflows"
curl -fL --retry 8 --retry-all-errors "$RAW_DIRECTOR/minimax_h3_director_rv2v.json" -o "$WF_DIR/$WF_RV2V"
curl -fL --retry 8 --retry-all-errors "$RAW_DIRECTOR/minimax_h3_director_v2v.json" -o "$WF_DIR/$WF_V2V"
curl -fL --retry 8 --retry-all-errors "$RAW_DIRECTOR/minimax_h3_director_r2v.json" -o "$WF_DIR/$WF_R2V"
"$PY" - "$WF_DIR/$WF_RV2V" "$WF_DIR/$WF_V2V" "$WF_DIR/$WF_R2V" <<'PYCODE'
import json,sys
for p in sys.argv[1:]:
    d=json.load(open(p,encoding="utf-8"))
    if "MiniMaxH3Director" not in json.dumps(d):
        raise SystemExit("Director node missing: "+p)
    print("validated:",p)
PYCODE

echo "[7/10] Launchers"
cat > "$COMFY/start_h3_director_rv2v.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
COMFY="${COMFY:-/workspace/runpod-slim/ComfyUI-H3-Director-RV2V}"
PORT="${PORT:-8188}"
cd "$COMFY"
exec "$COMFY/.venv/bin/python" main.py --listen 0.0.0.0 --port "$PORT" --preview-method auto
EOF
chmod +x "$COMFY/start_h3_director_rv2v.sh"

cat > "$COMFY/restart_h3_director_rv2v.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
COMFY="${COMFY:-/workspace/runpod-slim/ComfyUI-H3-Director-RV2V}"
PORT="${PORT:-8188}"
pkill -f "python.*main.py.*--port ${PORT}" 2>/dev/null || true
sleep 2
nohup "$COMFY/start_h3_director_rv2v.sh" > "$COMFY/user/setup_logs/comfyui.log" 2>&1 &
echo $! > "$COMFY/user/setup_logs/h3_director_rv2v.pid"
EOF
chmod +x "$COMFY/restart_h3_director_rv2v.sh"

echo "[8/10] Start"
pkill -f "python.*main.py.*--port ${PORT}" 2>/dev/null || true
sleep 2
"$COMFY/restart_h3_director_rv2v.sh"

echo "[9/10] Smoke test"
READY=0
for i in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${PORT}/object_info" -o "$STATE_DIR/object_info.json"; then READY=1; break; fi
  sleep 2
done
[[ "$READY" == 1 ]]
"$PY" - "$STATE_DIR/object_info.json" <<'PYCODE'
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
for x in ["UNETLoader","CLIPLoader","VAELoader"]:
    assert x in d, f"missing {x}"
assert any("MiniMaxH3Director" in x for x in d), "MiniMaxH3Director not registered"
print("object_info OK")
PYCODE

echo "[10/10] Done"
green "READY — #11 H3 Director RV2V COMPLETE v1"
echo "Path: $COMFY"
echo "Workflow: $WF_RV2V"
echo "Baseline: RV2V / 864x480 / ~5 sec / 124 frames / 24fps"
echo "Sampling: 25 steps / res_multistep / simple / CFG 1.0"
echo "Audio mode first test: source"
echo "ComfyUI port: $PORT"
