#!/usr/bin/env bash
set -Eeuo pipefail

# PinkCherry beta-0.6 video post-processing add-on.
# Adds a UI workflow only; it does not modify the MiniMax/PinkCherry models.
# The workflow decodes an MP4, upscales every frame with RealESRGAN x2,
# and writes an H.264 MP4 while retaining the source audio track.

ROOT="/workspace/runpod-slim"
COMFY="$ROOT/ComfyUI-PinkCherry-beta06"
PORT="${PORT:-8188}"
LOG="$ROOT/comfyui-pinkcherry-beta06.log"
NODE="$COMFY/custom_nodes/ComfyUI-VideoHelperSuite"
MODEL="$COMFY/models/upscale_models/RealESRGAN_x2plus.pth"
WORKFLOW="PinkCherry_Video_Upscale_RealESRGANx2_V1.json"
WORKFLOW_PATH="$COMFY/user/default/workflows/$WORKFLOW"

green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
die(){ red "[FAILED] $*"; exit 1; }
on_error(){ local rc=$?; red "VIDEO UPSCALE ADD-ON FAILED (exit=$rc, line=${BASH_LINENO[0]:-unknown})"; echo "Log: $LOG"; exit "$rc"; }
trap on_error ERR

echo "============================================================"
echo " PINKCHERRY — VIDEO UPSCALE ADD-ON v1 (RealESRGAN x2)"
echo "============================================================"

[[ -f "$COMFY/main.py" && -x "$COMFY/.venv/bin/python" ]] || \
  die "PinkCherry beta-0.6 environment was not found: $COMFY"
VENV_PY="$COMFY/.venv/bin/python"

echo "[1/6] Verify required system tools"
if ! command -v git >/dev/null 2>&1 || ! command -v ffmpeg >/dev/null 2>&1 || ! command -v lsof >/dev/null 2>&1; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git ffmpeg lsof
fi

echo "[2/6] Install VideoHelperSuite"
if [[ ! -f "$NODE/__init__.py" ]]; then
  git clone --depth 1 https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git "$NODE"
fi
if [[ -f "$NODE/requirements.txt" && ! -f "$NODE/.pinkcherry_vhs_requirements_ok" ]]; then
  "$VENV_PY" -m pip install -q -r "$NODE/requirements.txt"
  touch "$NODE/.pinkcherry_vhs_requirements_ok"
fi

echo "[3/6] Download RealESRGAN x2 model"
mkdir -p "$(dirname "$MODEL")"
if [[ ! -s "$MODEL" || "$(stat -c%s "$MODEL")" -lt 60000000 ]]; then
  rm -f "$MODEL"
  curl -fL -C - --retry 12 --retry-all-errors --retry-delay 15 --connect-timeout 30 \
    -o "$MODEL.part" "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth"
  [[ -s "$MODEL.part" && "$(stat -c%s "$MODEL.part")" -ge 60000000 ]] || die "RealESRGAN x2 download was incomplete"
  mv -f "$MODEL.part" "$MODEL"
else
  echo "  [SKIP] RealESRGAN_x2plus.pth already present"
fi

echo "[4/6] Create video-upscale workflow"
mkdir -p "$(dirname "$WORKFLOW_PATH")" "$COMFY/output/upscaled"
WORKFLOW_PATH="$WORKFLOW_PATH" "$VENV_PY" - <<'PY'
import json, os
from pathlib import Path

# Standard ComfyUI workflow format, including the Video Info Loaded node.
# It feeds the actual loaded FPS to Video Combine, preventing audio desync.
def node(i, typ, pos, size, title, inputs, outputs, widgets, order):
    return {"id": i, "type": typ, "pos": pos, "size": size, "flags": {},
            "order": order, "mode": 0, "inputs": inputs, "outputs": outputs,
            "title": title, "properties": {"Node name for S&R": typ},
            "widgets_values": widgets}
o = lambda name, typ, links=None: {"name":name, "type":typ, "links":links}
i = lambda name, typ, link=None: {"name":name, "type":typ, "link":link}
w = {"id":"PinkCherry_Video_Upscale_RealESRGANx2_V1", "revision":0,
     "last_node_id":5, "last_link_id":6, "nodes":[
 node(1,"VHS_LoadVideo",[40,170],[390,360],"1. Select generated MP4",[],
      [o("IMAGE","IMAGE",[1]),o("frame_count","INT"),o("audio","AUDIO",[4]),o("video_info","VHS_VIDEOINFO",[3])],
      ["PUT_YOUR_VIDEO_IN_INPUT_FOLDER.mp4",0,0,0,0,0,1],0),
 node(2,"UpscaleModelLoader",[500,70],[330,70],"2. RealESRGAN x2",[],[o("UPSCALE_MODEL","UPSCALE_MODEL",[2])],["RealESRGAN_x2plus.pth"],1),
 node(3,"ImageUpscaleWithModel",[880,140],[300,90],"3. Upscale every frame",[i("upscale_model","UPSCALE_MODEL",2),i("image","IMAGE",1)],[o("IMAGE","IMAGE",[5])],[],2),
 node(4,"VHS_VideoInfoLoaded",[500,310],[300,100],"Use source FPS",[i("video_info","VHS_VIDEOINFO",3)],
      [o("loaded_fps🟦","FLOAT",[6]),o("loaded_frame_count🟦","INT"),o("loaded_duration🟦","FLOAT"),o("loaded_width🟦","INT"),o("loaded_height🟦","INT")],[],3),
 node(5,"VHS_VideoCombine",[1240,160],[420,240],"4. Save MP4 (audio retained)",
      [i("images","IMAGE",5),i("frame_rate","FLOAT",6),i("loop_count","INT"),i("filename_prefix","STRING"),i("format","STRING"),i("pingpong","BOOLEAN"),i("save_output","BOOLEAN"),i("audio","AUDIO",4)],
      [o("Filenames","VHS_FILENAMES")],[24,0,"upscaled/PinkCherry_x2","video/h264-mp4",False,True],4)],
 "links":[[1,1,0,3,1,"IMAGE"],[2,2,0,3,0,"UPSCALE_MODEL"],[3,1,3,4,0,"VHS_VIDEOINFO"],[4,1,2,5,7,"AUDIO"],[5,3,0,5,0,"IMAGE"],[6,4,0,5,1,"FLOAT"]],
 "groups":[], "config":{}, "extra":{"ds":{"scale":0.7,"offset":[80,80]}}, "version":0.4}
Path(os.environ["WORKFLOW_PATH"]).write_text(json.dumps(w, indent=2), encoding="utf-8")
PY
"$VENV_PY" - <<PY
import json
w=json.load(open("$WORKFLOW_PATH"))
assert {x['type'] for x in w['nodes']} == {'VHS_LoadVideo','UpscaleModelLoader','ImageUpscaleWithModel','VHS_VideoInfoLoaded','VHS_VideoCombine'}
assert len(w['links']) == 6
print('  workflow JSON validation OK')
PY

echo "[5/6] Restart PinkCherry on port $PORT"
pids="$(lsof -ti tcp:"$PORT" 2>/dev/null || true)"
if [[ -n "$pids" ]]; then
  for pid in $pids; do
    cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
    [[ "$cwd" == "$COMFY" ]] || die "Port $PORT is occupied by an unrelated process (PID $pid); it was not stopped."
  done
  kill $pids 2>/dev/null || true
  for _ in $(seq 1 15); do [[ -z "$(lsof -ti tcp:"$PORT" 2>/dev/null || true)" ]] && break; sleep 1; done
fi
[[ -z "$(lsof -ti tcp:"$PORT" 2>/dev/null || true)" ]] || die "Could not free port $PORT"
cd "$COMFY"
nohup "$VENV_PY" main.py --listen 0.0.0.0 --port "$PORT" --preview-method auto \
  --enable-cors-header --reserve-vram 4 --cache-none > "$LOG" 2>&1 &
PID=$!

echo "[6/6] Verify video and upscale nodes"
ready=0
for _ in $(seq 1 180); do
  if ! kill -0 "$PID" 2>/dev/null; then tail -120 "$LOG" || true; die "ComfyUI exited during startup"; fi
  if curl --max-time 3 -fsS "http://127.0.0.1:$PORT/object_info" > /tmp/pinkcherry_upscale_object_info.json 2>/dev/null; then ready=1; break; fi
  sleep 1
done
[[ "$ready" == 1 ]] || die "Startup timeout"
"$VENV_PY" - <<'PY'
import json
d=json.load(open('/tmp/pinkcherry_upscale_object_info.json'))
need=['VHS_LoadVideo','VHS_VideoInfoLoaded','VHS_VideoCombine','UpscaleModelLoader','ImageUpscaleWithModel']
missing=[x for x in need if x not in d]
if missing: raise SystemExit('Missing nodes: '+', '.join(missing))
if 'RealESRGAN_x2plus.pth' not in json.dumps(d['UpscaleModelLoader']):
    raise SystemExit('RealESRGAN x2 model is not visible in UpscaleModelLoader')
print('  required video-upscale nodes and x2 model are visible')
PY

trap - ERR
echo "============================================================"
green " PINKCHERRY VIDEO UPSCALE READY"
echo "============================================================"
echo "Workflow : $WORKFLOW_PATH"
echo "Input    : $COMFY/input"
echo "Output   : $COMFY/output/upscaled"
echo "Mode     : Every frame, RealESRGAN x2, source audio/FPS retained"
echo "Port     : $PORT"
