#!/usr/bin/env bash
set -Eeuo pipefail
COMFY="/workspace/runpod-slim/ComfyUI"
LOG="/workspace/runpod-slim/comfyui.log"
PORT="${PORT:-8188}"
[[ -f "$COMFY/main.py" ]] || { echo "[FAILED] ComfyUI not found: $COMFY"; exit 1; }
echo "===== SETUP #5 RECOVERY ====="
pkill -9 -f "python.*main.py" 2>/dev/null || true
sleep 3
nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader || true
cd "$COMFY"
nohup python3.12 main.py   --listen 0.0.0.0   --port "$PORT"   --preview-method auto   --enable-cors-header   --reserve-vram 4   --cache-none   > "$LOG" 2>&1 &
PID=$!
for i in $(seq 1 180); do
  kill -0 "$PID" 2>/dev/null || { tail -100 "$LOG"; exit 1; }
  if curl --max-time 3 -fsS "http://127.0.0.1:$PORT/system_stats" >/tmp/setup5_stats.json 2>/dev/null; then
    echo "SETUP #5 RECOVERY READY"
    echo "Dynamic VRAM ON / reserve 4 GB / cache-none"
    exit 0
  fi
  sleep 1
done
tail -100 "$LOG"
exit 1
