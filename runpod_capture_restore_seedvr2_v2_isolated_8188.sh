#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-/workspace/runpod-slim}"
COMFY="$ROOT/ComfyUI-SeedVR2"
VENV="$COMFY/.venv"
CUSTOM="$COMFY/custom_nodes"
WF_DIR="$COMFY/user/default/workflows"
PORT="8188"

echo "============================================================"
echo " Capture Restore SeedVR2 v2 — ISOLATED"
echo " Existing ComfyUI will NOT be modified."
echo " New install: $COMFY"
echo "============================================================"

find_python() {
  local c
  for c in /usr/bin/python3 /usr/local/bin/python3 python3; do
    if command -v "$c" >/dev/null 2>&1 || [[ -x "$c" ]]; then
      if "$c" -c 'import sys; print(sys.version)' >/dev/null 2>&1; then
        echo "$c"
        return 0
      fi
    fi
  done
  return 1
}

PY="$(find_python || true)"
if [[ -z "$PY" ]]; then
  echo "[ERROR] A normal Python 3 interpreter was not found."
  echo "Please paste: which -a python python3; ls -l /usr/bin/python3 /usr/local/bin/python3 2>/dev/null"
  exit 1
fi

echo "[0/7] Python: $PY"
"$PY" -c 'import sys; print("Python", sys.version)'

echo "[1/7] Installing/updating isolated ComfyUI..."
if [[ -d "$COMFY/.git" ]]; then
  git -C "$COMFY" fetch --depth=1 origin
  git -C "$COMFY" reset --hard origin/master
else
  rm -rf "$COMFY"
  git clone --depth=1 https://github.com/Comfy-Org/ComfyUI.git "$COMFY"
fi

echo "[2/7] Creating isolated venv..."
if [[ ! -x "$VENV/bin/python" ]] || ! "$VENV/bin/python" -c 'import sys' >/dev/null 2>&1; then
  rm -rf "$VENV"
  "$PY" -m venv --system-site-packages "$VENV"
fi

VPY="$VENV/bin/python"
"$VPY" -m pip install -U pip setuptools wheel

echo "[3/7] Installing ComfyUI requirements..."
"$VPY" -m pip install -r "$COMFY/requirements.txt"

echo "[4/7] Verifying native SeedVR2 support..."
if [[ ! -d "$COMFY/comfy/ldm/seedvr" ]]; then
  echo "[ERROR] Latest ComfyUI clone does not contain comfy/ldm/seedvr"
  git -C "$COMFY" log -1 --oneline
  exit 1
fi
git -C "$COMFY" log -1 --oneline

echo "[5/7] Installing FL SeedVR2 image nodes..."
mkdir -p "$CUSTOM" "$WF_DIR"
REPO="$CUSTOM/ComfyUI-FL-SeedVR2"
if [[ -d "$REPO/.git" ]]; then
  git -C "$REPO" fetch --depth=1 origin
  git -C "$REPO" reset --hard origin/main
else
  git clone --depth=1 https://github.com/filliptm/ComfyUI-FL-SeedVR2.git "$REPO"
fi

echo "[6/7] Installing official example workflow..."
curl -fL --retry 5 --retry-delay 2   "https://raw.githubusercontent.com/filliptm/ComfyUI-FL-SeedVR2/main/examples/seedvr2_1_4b_upscale.json"   -o "$WF_DIR/capture_to_iphone_seedvr2_v2.json"

"$VPY" - "$WF_DIR/capture_to_iphone_seedvr2_v2.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    d = json.load(f)
for n in d.get("nodes", []):
    if n.get("type") == "FLSeedVR2Upscale":
        vals = n.get("widgets_values", [])
        if vals:
            vals[0] = 2.0
    if n.get("type") == "SaveImage":
        n["widgets_values"] = ["capture_restored/SeedVR2_2x"]
with open(path, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
PY

echo "[7/7] Writing launch/check helpers..."
cat > "$ROOT/start_seedvr2_comfyui.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

if command -v ss >/dev/null 2>&1 && ss -ltn | grep -q ':8188 '; then
  echo "[ERROR] Port 8188 is already in use."
  echo "Stop the existing ComfyUI first, then run this launcher again."
  exit 1
fi

cd "$COMFY"
exec "$VENV/bin/python" main.py --listen 0.0.0.0 --port 8188
EOF
chmod +x "$ROOT/start_seedvr2_comfyui.sh"

cat > "$ROOT/check_seedvr2_comfyui.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
echo "=== ComfyUI commit ==="
git -C "$COMFY" log -1 --oneline
echo "=== Native SeedVR2 ==="
test -d "$COMFY/comfy/ldm/seedvr" && echo "OK: comfy/ldm/seedvr exists" || echo "NG"
echo "=== FL node ==="
test -f "$COMFY/custom_nodes/ComfyUI-FL-SeedVR2/__init__.py" && echo "OK: FL node installed" || echo "NG"
echo "=== Python/Torch ==="
"$VENV/bin/python" -c 'import sys,torch; print(sys.version.split()[0]); print("torch",torch.__version__); print("cuda",torch.cuda.is_available()); print("gpu", torch.cuda.get_device_name(0) if torch.cuda.is_available() else "none")'
EOF
chmod +x "$ROOT/check_seedvr2_comfyui.sh"

echo
echo "============================================================"
echo " READY — isolated SeedVR2 ComfyUI installed"
echo " Existing: $ROOT/ComfyUI               (untouched)"
echo " SeedVR2 : $COMFY"
echo " Port    : 8188 (exclusive)"
echo " Workflow: $WF_DIR/capture_to_iphone_seedvr2_v2.json"
echo
echo " Check:"
echo "   $ROOT/check_seedvr2_comfyui.sh"
echo
echo " Start on port 8188:"
echo "   $ROOT/start_seedvr2_comfyui.sh"
echo
echo " First Queue downloads:"
echo "   ~2.89 GB SeedVR2 1.4B transformer"
echo "   ~0.50 GB SeedVR2 VAE"
echo
echo " First test: scale_multiplier = 2.0"
echo "============================================================"
