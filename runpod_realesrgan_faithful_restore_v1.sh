#!/usr/bin/env bash
set -Eeuo pipefail
COMFY="/workspace/runpod-slim/ComfyUI"
MODEL_DIR="$COMFY/models/upscale_models"
WF_DIR="$COMFY/user/default/workflows"
MODEL="RealESRGAN_x4plus.pth"
URL="https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth"
WF="$WF_DIR/capture_faithful_realesrgan_x4_v1.json"

echo "=== Real-ESRGAN faithful restore v1 ==="
[[ -d "$COMFY" ]] || { echo "[ERROR] ComfyUI not found: $COMFY"; exit 1; }
mkdir -p "$MODEL_DIR" "$WF_DIR"

echo "[1/2] Model"
[[ -s "$MODEL_DIR/$MODEL" ]] || curl -fL --retry 5 --retry-delay 3 "$URL" -o "$MODEL_DIR/$MODEL"

echo "[2/2] Workflow"
cat > "$WF" <<'JSON'
{
 "last_node_id":4,"last_link_id":3,
 "nodes":[
  {"id":1,"type":"LoadImage","pos":[60,170],"size":[320,320],"flags":{},"order":0,"mode":0,"inputs":[],"outputs":[{"name":"IMAGE","type":"IMAGE","slot_index":0,"links":[2]},{"name":"MASK","type":"MASK","links":null}],"properties":{"Node name for S&R":"LoadImage"},"widgets_values":["example.png","image"]},
  {"id":2,"type":"UpscaleModelLoader","pos":[60,40],"size":[320,60],"flags":{},"order":1,"mode":0,"inputs":[],"outputs":[{"name":"UPSCALE_MODEL","type":"UPSCALE_MODEL","slot_index":0,"links":[1]}],"properties":{"Node name for S&R":"UpscaleModelLoader"},"widgets_values":["RealESRGAN_x4plus.pth"]},
  {"id":3,"type":"ImageUpscaleWithModel","pos":[480,170],"size":[300,80],"flags":{},"order":2,"mode":0,"inputs":[{"name":"upscale_model","type":"UPSCALE_MODEL","link":1},{"name":"image","type":"IMAGE","link":2}],"outputs":[{"name":"IMAGE","type":"IMAGE","slot_index":0,"links":[3]}],"properties":{"Node name for S&R":"ImageUpscaleWithModel"},"widgets_values":[]},
  {"id":4,"type":"SaveImage","pos":[880,170],"size":[420,360],"flags":{},"order":3,"mode":0,"inputs":[{"name":"images","type":"IMAGE","link":3}],"outputs":[],"properties":{"Node name for S&R":"SaveImage"},"widgets_values":["faithful_restore/RealESRGAN_x4"]}
 ],
 "links":[[1,2,0,3,0,"UPSCALE_MODEL"],[2,1,0,3,1,"IMAGE"],[3,3,0,4,0,"IMAGE"]],
 "groups":[],"config":{},"extra":{},"version":0.4
}
JSON

echo
echo "READY"
echo "Model: $MODEL_DIR/$MODEL"
echo "Workflow: $WF"
echo "No custom nodes / no pip / no ComfyUI update or replacement."
echo "Refresh ComfyUI; restart only if the model is not listed."
