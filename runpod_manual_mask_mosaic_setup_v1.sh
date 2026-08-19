#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# RunPod + ComfyUI Manual Mask Mosaic Setup v1
#
# PURPOSE
#   Install a simple manual-mosaic workflow:
#     Load Image -> Mask Editor -> MosaicCreator -> Save Image
#
# IMPORTANT
#   - NO image generation.
#   - NO NSFW detector.
#   - NO YOLO model.
#   - NO AutoMosaic.
#   - User manually paints the exact mosaic region in ComfyUI Mask Editor.
#   - Existing Z-Image / Animagine / PyTorch / CUDA setup is preserved.
###############################################################################

SCRIPT_NAME="runpod_manual_mask_mosaic_setup_v1"
BASE_DIR="${BASE_DIR:-/workspace/runpod-slim}"
COMFY_DIR="${COMFY_DIR:-$BASE_DIR/ComfyUI-ZImage}"
VENV="$COMFY_DIR/.venv"
PORT="${COMFY_PORT:-8188}"
CUSTOM_DIR="$COMFY_DIR/custom_nodes/ComfyUI-Mosaic"
WF_DIR="$COMFY_DIR/user/default/workflows"
EXPORT_DIR="$BASE_DIR/booth_workflows"
WF_NAME="booth_manual_mask_mosaic_v1.json"
WF_B64="ewogICJsYXN0X25vZGVfaWQiOiA0LAogICJsYXN0X2xpbmtfaWQiOiA0LAogICJub2RlcyI6IFsKICAgIHsKICAgICAgImlkIjogMSwKICAgICAgInR5cGUiOiAiTG9hZEltYWdlIiwKICAgICAgInBvcyI6IFsKICAgICAgICA2MCwKICAgICAgICAxMjAKICAgICAgXSwKICAgICAgInNpemUiOiBbCiAgICAgICAgMzYwLAogICAgICAgIDMyMAogICAgICBdLAogICAgICAiZmxhZ3MiOiB7fSwKICAgICAgIm9yZGVyIjogMCwKICAgICAgIm1vZGUiOiAwLAogICAgICAiaW5wdXRzIjogW10sCiAgICAgICJvdXRwdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIklNQUdFIiwKICAgICAgICAgICJ0eXBlIjogIklNQUdFIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgMQogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMAogICAgICAgIH0sCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAiTUFTSyIsCiAgICAgICAgICAidHlwZSI6ICJNQVNLIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgMgogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMQogICAgICAgIH0KICAgICAgXSwKICAgICAgInRpdGxlIjogIjEpIExvYWQgSW1hZ2Ug4oaSIFJpZ2h0LWNsaWNrIOKGkiBPcGVuIGluIE1hc2sgRWRpdG9yIiwKICAgICAgInByb3BlcnRpZXMiOiB7CiAgICAgICAgIk5vZGUgbmFtZSBmb3IgUyZSIjogIkxvYWRJbWFnZSIKICAgICAgfSwKICAgICAgIndpZGdldHNfdmFsdWVzIjogWwogICAgICAgICIiCiAgICAgIF0KICAgIH0sCiAgICB7CiAgICAgICJpZCI6IDIsCiAgICAgICJ0eXBlIjogIk1vc2FpY0NyZWF0b3IiLAogICAgICAicG9zIjogWwogICAgICAgIDUyMCwKICAgICAgICAxMjAKICAgICAgXSwKICAgICAgInNpemUiOiBbCiAgICAgICAgNDEwLAogICAgICAgIDI1MAogICAgICBdLAogICAgICAiZmxhZ3MiOiB7fSwKICAgICAgIm9yZGVyIjogMSwKICAgICAgIm1vZGUiOiAwLAogICAgICAiaW5wdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogImltYWdlIiwKICAgICAgICAgICJ0eXBlIjogIklNQUdFIiwKICAgICAgICAgICJsaW5rIjogMQogICAgICAgIH0sCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAibWFzayIsCiAgICAgICAgICAidHlwZSI6ICJNQVNLIiwKICAgICAgICAgICJsaW5rIjogMgogICAgICAgIH0KICAgICAgXSwKICAgICAgIm91dHB1dHMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAiaW1hZ2UiLAogICAgICAgICAgInR5cGUiOiAiSU1BR0UiLAogICAgICAgICAgImxpbmtzIjogWwogICAgICAgICAgICAzCiAgICAgICAgICBdLAogICAgICAgICAgInNsb3RfaW5kZXgiOiAwCiAgICAgICAgfSwKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJwcm9jZXNzaW5nX21hc2siLAogICAgICAgICAgInR5cGUiOiAiTUFTSyIsCiAgICAgICAgICAibGlua3MiOiBudWxsLAogICAgICAgICAgInNsb3RfaW5kZXgiOiAxCiAgICAgICAgfQogICAgICBdLAogICAgICAidGl0bGUiOiAiMikgTWFudWFsIE1hc2sg4oaSIE1vc2FpYyIsCiAgICAgICJwcm9wZXJ0aWVzIjogewogICAgICAgICJOb2RlIG5hbWUgZm9yIFMmUiI6ICJNb3NhaWNDcmVhdG9yIgogICAgICB9LAogICAgICAid2lkZ2V0c192YWx1ZXMiOiBbCiAgICAgICAgInBpeGVsYXRpb24iLAogICAgICAgIDI0LAogICAgICAgIDEuMCwKICAgICAgICBmYWxzZQogICAgICBdCiAgICB9LAogICAgewogICAgICAiaWQiOiAzLAogICAgICAidHlwZSI6ICJTYXZlSW1hZ2UiLAogICAgICAicG9zIjogWwogICAgICAgIDEwNDAsCiAgICAgICAgMTIwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDQyMCwKICAgICAgICAzNTAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDIsCiAgICAgICJtb2RlIjogMCwKICAgICAgImlucHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJpbWFnZXMiLAogICAgICAgICAgInR5cGUiOiAiSU1BR0UiLAogICAgICAgICAgImxpbmsiOiAzCiAgICAgICAgfQogICAgICBdLAogICAgICAib3V0cHV0cyI6IFtdLAogICAgICAidGl0bGUiOiAiMykgU2F2ZSBNb3NhaWMgSW1hZ2UiLAogICAgICAicHJvcGVydGllcyI6IHsKICAgICAgICAiTm9kZSBuYW1lIGZvciBTJlIiOiAiU2F2ZUltYWdlIgogICAgICB9LAogICAgICAid2lkZ2V0c192YWx1ZXMiOiBbCiAgICAgICAgImJvb3RoX21hbnVhbF9tb3NhaWMvbWFudWFsX21vc2FpYyIKICAgICAgXQogICAgfSwKICAgIHsKICAgICAgImlkIjogNCwKICAgICAgInR5cGUiOiAiTm90ZSIsCiAgICAgICJwb3MiOiBbCiAgICAgICAgNTAsCiAgICAgICAgNTAwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDkwMCwKICAgICAgICAzMzAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDMsCiAgICAgICJtb2RlIjogMCwKICAgICAgImlucHV0cyI6IFtdLAogICAgICAib3V0cHV0cyI6IFtdLAogICAgICAidGl0bGUiOiAiSE9XIFRPIFVTRSIsCiAgICAgICJwcm9wZXJ0aWVzIjogewogICAgICAgICJ0ZXh0IjogIiIKICAgICAgfSwKICAgICAgIndpZGdldHNfdmFsdWVzIjogWwogICAgICAgICJNQU5VQUwgTU9TQUlDIFdPUktGTE9XXG5cbjEuIExvYWQgSW1hZ2XjgafliqDlt6XjgZfjgZ/jgYTnlLvlg4/jgpLpgbjjgbbjgIJcbjIuIExvYWQgSW1hZ2Xjg47jg7zjg4njgpLlj7Pjgq/jg6rjg4Pjgq8g4oaSIE9wZW4gaW4gTWFzayBFZGl0b3LjgIJcbjMuIOODouOCtuOCpOOCr+OCkuaOm+OBkeOBn+OBhOmDqOWIhuOBoOOBkU1hc2sgUGVu44Gn5aGX44KLIOKGkiBTYXZl44CCXG40LiBNb3NhaWMgQ3JlYXRvcuOBpyBtb3NhaWNfdHlwZT0gcGl4ZWxhdGlvbuOAgWJsb2NrX3NpemXjgpLoqr/mlbTjgIJcbjUuIFF1ZXVl44Gn5a6f6KGM44GZ44KL44Go44CB5aGX44Gj44Gf56+E5Zuy44Gg44GR44Oi44K244Kk44Kv5YyW44GX44Gm5L+d5a2Y44CCXG5cbuebruWuiTogYmxvY2tfc2l6ZSAxNuOAnDMy44CC5aSn44GN44GE44G744Gp57KX44GE44Oi44K244Kk44Kv44CCXG5pbnRlbnNpdHk9MS4w5o6o5aWo44CCXG7oh6rli5XmpJzlh7rjg6Ljg4fjg6vjg7tOU0ZX5qSc5Ye644Oi44OH44Or44Gv5LiA5YiH5L2/55So44GX44G+44Gb44KT44CCIgogICAgICBdCiAgICB9CiAgXSwKICAibGlua3MiOiBbCiAgICBbCiAgICAgIDEsCiAgICAgIDEsCiAgICAgIDAsCiAgICAgIDIsCiAgICAgIDAsCiAgICAgICJJTUFHRSIKICAgIF0sCiAgICBbCiAgICAgIDIsCiAgICAgIDEsCiAgICAgIDEsCiAgICAgIDIsCiAgICAgIDEsCiAgICAgICJNQVNLIgogICAgXSwKICAgIFsKICAgICAgMywKICAgICAgMiwKICAgICAgMCwKICAgICAgMywKICAgICAgMCwKICAgICAgIklNQUdFIgogICAgXQogIF0sCiAgImdyb3VwcyI6IFtdLAogICJjb25maWciOiB7fSwKICAiZXh0cmEiOiB7CiAgICAiZHMiOiB7CiAgICAgICJzY2FsZSI6IDAuODUsCiAgICAgICJvZmZzZXQiOiBbCiAgICAgICAgODAsCiAgICAgICAgODAKICAgICAgXQogICAgfQogIH0sCiAgInZlcnNpb24iOiAwLjQKfQ=="

STATE="$BASE_DIR/.manual_mask_mosaic_v1"
LOG="$STATE/setup.log"
STATUS="$STATE/status"
PHASE="$STATE/phase"
PIDFILE="$STATE/pid"
HB="${HEARTBEAT_SECONDS:-15}"

mkdir -p "$STATE"

ts(){ date '+%Y-%m-%d %H:%M:%S'; }
say(){ echo; echo "================================================================"; echo "[$(ts)] $*"; echo "================================================================"; }
phase(){ echo "$*" > "$PHASE"; }
alive(){ [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null; }

status(){
  echo "Status : $(cat "$STATUS" 2>/dev/null || echo NOT_STARTED)"
  echo "Phase  : $(cat "$PHASE" 2>/dev/null || echo -)"
  echo "Log    : $LOG"
  echo "Node   : $CUSTOM_DIR"
  echo "WF     : $WF_DIR/$WF_NAME"
  echo "ComfyUI: $COMFY_DIR"
  echo "Port   : $PORT"
}

follow(){ touch "$LOG"; tail -n 120 -F "$LOG"; }

preflight(){
  say "Preflight"
  phase "Preflight"

  [[ -f "$COMFY_DIR/main.py" ]] || {
    echo "[FATAL] Missing ComfyUI at $COMFY_DIR"
    exit 10
  }

  [[ -x "$VENV/bin/python" ]] || {
    echo "[FATAL] Missing ComfyUI venv: $VENV"
    exit 11
  }

  for c in git curl lsof; do
    if ! command -v "$c" >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y --no-install-recommends git curl lsof ca-certificates
      break
    fi
  done

  mkdir -p "$COMFY_DIR/custom_nodes" "$WF_DIR" "$EXPORT_DIR" "$COMFY_DIR/output/booth_manual_mosaic"

  "$VENV/bin/python" - <<'PY'
import torch
print("torch:", torch.__version__)
print("cuda_available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("gpu:", torch.cuda.get_device_name(0))
PY
}

install_mosaic_node(){
  say "Install/update 1038lab/ComfyUI-Mosaic"
  phase "Install MosaicCreator"

  if [[ -d "$CUSTOM_DIR/.git" ]]; then
    git -C "$CUSTOM_DIR" fetch origin --prune
    git -C "$CUSTOM_DIR" reset --hard origin/main
  else
    rm -rf "$CUSTOM_DIR"
    git clone --depth 1 https://github.com/1038lab/ComfyUI-Mosaic.git "$CUSTOM_DIR"
  fi

  echo "ComfyUI-Mosaic commit: $(git -C "$CUSTOM_DIR" rev-parse HEAD)"

  # Do NOT install the upstream requirements.txt wholesale because it includes
  # torch/torchvision. Preserve the known-working RunPod CUDA PyTorch stack.
  "$VENV/bin/python" -m pip install --upgrade-strategy only-if-needed \
    "opencv-python-headless>=4.5.0" \
    "pillow>=8.0.0" \
    "numpy>=1.21.0"

  "$VENV/bin/python" - <<'PY'
import torch, cv2, PIL, numpy
print("torch:", torch.__version__)
print("opencv:", cv2.__version__)
print("Pillow:", PIL.__version__)
print("numpy:", numpy.__version__)
assert torch.cuda.is_available(), "CUDA unavailable after dependency install"
PY
}

write_workflow(){
  say "Install manual-mask mosaic workflow"
  phase "Write workflow"

  "$VENV/bin/python" - "$WF_B64" "$WF_DIR/$WF_NAME" "$EXPORT_DIR/$WF_NAME" <<'PY'
import base64, json, pathlib, sys
obj=json.loads(base64.b64decode(sys.argv[1]).decode())
for x in sys.argv[2:]:
    p=pathlib.Path(x)
    p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(json.dumps(obj,ensure_ascii=False,indent=2),encoding="utf-8")
    json.loads(p.read_text(encoding="utf-8"))
    print("WROTE",p)
PY

  cat > "$EXPORT_DIR/MANUAL_MASK_MOSAIC_README.txt" <<'EOF'
Manual Mask Mosaic v1

Workflow:
  booth_manual_mask_mosaic_v1.json

How to use:
  1) Load the image in the Load Image node.
  2) Right-click Load Image -> Open in Mask Editor.
  3) Paint ONLY the area you want to mosaic with Mask Pen.
  4) Save the mask and close Mask Editor.
  5) In Mosaic Creator:
       mosaic_type = pixelation
       block_size  = 24 (try 16-32)
       intensity   = 1.0
  6) Queue the workflow.
  7) Result is saved under output/booth_manual_mosaic/.

No detector / no YOLO / no automatic region selection is used.
The user decides the exact region manually.

This installer does NOT generate images.
EOF
}

restart_comfy(){
  say "Restart ComfyUI safely on port $PORT"
  phase "Restart ComfyUI"

  local listeners
  listeners="$(lsof -ti TCP:"$PORT" -sTCP:LISTEN 2>/dev/null | sort -u || true)"

  for pid in $listeners; do
    local cwd cmd
    cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"

    echo "Port $PORT listener: PID=$pid CWD=$cwd CMD=$cmd"

    if [[ "$cwd" == "$COMFY_DIR" || "$cmd" == *"$COMFY_DIR/main.py"* ]]; then
      kill "$pid" 2>/dev/null || true
      for _ in {1..30}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
      done
    else
      echo "[FATAL] Port $PORT belongs to another environment."
      echo "Refusing to kill PID $pid."
      exit 30
    fi
  done

  cd "$COMFY_DIR"
  nohup "$VENV/bin/python" main.py \
    --listen 0.0.0.0 \
    --port "$PORT" \
    --preview-method auto \
    > comfyui_8188.log 2>&1 < /dev/null &

  local cp=$!
  echo "$cp" > comfyui_8188.pid

  for i in {1..60}; do
    if curl -fsS "http://127.0.0.1:$PORT/system_stats" >/dev/null 2>&1; then
      echo "[OK] ComfyUI ready."
      return
    fi
    if ! kill -0 "$cp" 2>/dev/null; then
      echo "[FATAL] ComfyUI exited during startup."
      tail -n 180 comfyui_8188.log || true
      exit 31
    fi
    echo "[ALIVE] startup=$((i*5))s PID=$cp"
    sleep 5
  done

  tail -n 180 comfyui_8188.log || true
  exit 32
}

verify(){
  say "Verify MosaicCreator node (NO image generation)"
  phase "Verify"

  "$VENV/bin/python" - "$PORT" <<'PY'
import json, sys, urllib.request
port=int(sys.argv[1])
with urllib.request.urlopen(f"http://127.0.0.1:{port}/object_info", timeout=60) as r:
    obj=json.load(r)

for n in ["LoadImage","MosaicCreator","SaveImage"]:
    if n not in obj:
        raise SystemExit(f"Missing required node: {n}")

req=obj["MosaicCreator"]["input"]["required"]
opt=obj["MosaicCreator"]["input"].get("optional",{})

print("[OK] MosaicCreator loaded")
print("mosaic types:", req["mosaic_type"][0])
print("block_size:", req["block_size"][1])
print("intensity:", req["intensity"][1])
print("mask optional input:", "mask" in opt)
assert "mask" in opt, "MosaicCreator mask input missing"
print("[OK] manual-mask input supported")
print("NO IMAGE GENERATION PERFORMED")
PY
}

worker(){
  trap '' HUP
  echo $$ > "$PIDFILE"
  echo RUNNING > "$STATUS"

  local hb_pid=""
  cleanup(){
    [[ -n "${hb_pid:-}" ]] && kill "$hb_pid" 2>/dev/null || true
  }
  trap cleanup EXIT

  (
    while true; do
      sleep "$HB"
      echo "[HEARTBEAT $(ts)] status=$(cat "$STATUS" 2>/dev/null || echo ?) phase=$(cat "$PHASE" 2>/dev/null || echo ?)"
    done
  ) &
  hb_pid=$!

  preflight
  install_mosaic_node
  write_workflow
  restart_comfy
  verify

  echo READY > "$STATUS"
  phase READY

  say "MANUAL MASK MOSAIC READY"
  cat <<EOF
READY

No image was generated.

Workflow:
  $WF_DIR/$WF_NAME

Easy-to-find copy:
  $EXPORT_DIR/$WF_NAME

Usage:
  Load Image
    -> right-click
    -> Open in Mask Editor
    -> paint exact mosaic area
    -> Save mask
    -> Queue

Mosaic defaults:
  type       = pixelation
  block_size = 24
  intensity  = 1.0

Output:
  $COMFY_DIR/output/booth_manual_mosaic/
EOF
}

launch(){
  local p
  p="$(cat "$PIDFILE" 2>/dev/null || true)"

  if alive "$p"; then
    echo "Installer already running PID=$p"
    follow
    return
  fi

  : > "$LOG"
  nohup bash "${BASH_SOURCE[0]}" --worker >> "$LOG" 2>&1 < /dev/null &
  echo $! > "$PIDFILE"

  echo "Started detached installer PID=$!"
  echo "Installer continues if browser terminal disconnects."
  sleep 1
  follow
}

case "${1:-}" in
  --worker)
    exec > >(tee -a "$LOG") 2>&1
    worker
    ;;
  --status) status ;;
  --follow) follow ;;
  --help|-h)
    echo "Usage: $0 [--status|--follow]"
    ;;
  "") launch ;;
  *)
    echo "Usage: $0 [--status|--follow]"
    exit 2
    ;;
esac
