#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# RunPod stock ComfyUI + native SUPIR image restoration
# v2 — no custom nodes, no pip, no ComfyUI replacement/update
# ============================================================

COMFY="${COMFY:-/workspace/runpod-slim/ComfyUI}"
PORT="${PORT:-8188}"
WF_DIR="$COMFY/user/default/workflows"
CKPT_DIR="$COMFY/models/checkpoints"
PATCH_DIR="$COMFY/models/model_patches"
TEXT_DIR="$COMFY/models/text_encoders"
LOG_DIR="/workspace/runpod-slim/logs"
WF_NAME="capture_to_iphone_supir_native_v2.json"
WF_PATH="$WF_DIR/$WF_NAME"

JUG_NAME="juggernautXL_v9Rdphoto2Lightning.safetensors"
SUPIR_NAME="SUPIR-v0Q_fp16.safetensors"
QWEN_NAME="qwen3.5_4b_bf16.safetensors"

JUG_URL="https://huggingface.co/AiWise/Juggernaut-XL-V9-GE-RDPhoto2-Lightning_4S/resolve/main/juggernautXL_v9Rdphoto2Lightning.safetensors"
SUPIR_URL="https://huggingface.co/Kijai/SUPIR_pruned/resolve/main/SUPIR-v0Q_fp16.safetensors"
QWEN_URL="https://huggingface.co/Comfy-Org/Qwen3.5/resolve/main/text_encoders/qwen3.5_4b_bf16.safetensors"
WF_URL="https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/utility_image_upscale_supir.json"

info(){ printf '\n\033[1;36m[INFO]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
fail(){ printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -d "$COMFY" ]] || fail "Stock ComfyUI not found: $COMFY"
mkdir -p "$WF_DIR" "$CKPT_DIR" "$PATCH_DIR" "$TEXT_DIR" "$LOG_DIR"

# Find the already-running stock ComfyUI. We use its exact executable/args only
# if we need to relaunch it at the very end.
OLD_PID="$(pgrep -f "main\.py.*--port[= ]${PORT}" | head -n1 || true)"
if [[ -n "$OLD_PID" ]]; then
  OLD_CWD="$(readlink -f "/proc/$OLD_PID/cwd" 2>/dev/null || true)"
  OLD_EXE="$(readlink -f "/proc/$OLD_PID/exe" 2>/dev/null || true)"
  mapfile -d '' OLD_ARGV < "/proc/$OLD_PID/cmdline" || true
  info "Detected stock ComfyUI PID $OLD_PID"
  echo "  cwd: $OLD_CWD"
  echo "  exe: $OLD_EXE"
else
  warn "No running ComfyUI PID detected on port $PORT. Setup will continue without stopping anything."
fi

# Native SUPIR landed in ComfyUI core. Check the currently running server BEFORE
# downloading multi-GB models. If this fails, this script changes nothing.
info "Checking whether this stock ComfyUI already has native SUPIR support..."
if command -v curl >/dev/null 2>&1 && curl -fsS "http://127.0.0.1:${PORT}/object_info/SUPIRApply" -o /tmp/supir_object_info.json 2>/dev/null; then
  if grep -q 'SUPIRApply' /tmp/supir_object_info.json; then
    ok "Native SUPIRApply node is present. No custom node is needed."
  else
    fail "ComfyUI answered, but native SUPIRApply was not found. This Pod image is too old for this native workflow. Nothing was modified."
  fi
else
  # Fallback filesystem check for a temporarily non-responsive UI.
  if [[ -f "$COMFY/comfy/ldm/supir/supir_patch.py" ]] && grep -q 'SUPIRApply' "$COMFY/comfy_extras/nodes_model_patch.py" 2>/dev/null; then
    ok "Native SUPIR code is present in the stock ComfyUI filesystem."
  else
    fail "Native SUPIR is not available in this stock ComfyUI. Nothing was modified."
  fi
fi

# Reliable downloader. Downloads to *.part and only renames when complete.
download_file() {
  local url="$1" dst="$2" min_bytes="$3" label="$4"
  local tmp="${dst}.part"

  if [[ -f "$dst" ]]; then
    local sz
    sz="$(stat -c%s "$dst" 2>/dev/null || echo 0)"
    if (( sz >= min_bytes )); then
      ok "$label already exists ($(numfmt --to=iec "$sz" 2>/dev/null || echo "$sz bytes"))"
      return 0
    fi
    warn "$label exists but is too small; redownloading."
    rm -f "$dst"
  fi

  info "Downloading $label"
  echo "  -> $dst"
  if command -v wget >/dev/null 2>&1; then
    wget -c --tries=10 --timeout=30 --read-timeout=30 -O "$tmp" "$url"
  elif command -v curl >/dev/null 2>&1; then
    curl -fL --retry 10 --retry-all-errors --retry-delay 5 -o "$tmp" "$url"
  else
    fail "Neither wget nor curl is available."
  fi

  local sz
  sz="$(stat -c%s "$tmp" 2>/dev/null || echo 0)"
  (( sz >= min_bytes )) || fail "$label download looks incomplete ($sz bytes)."
  mv -f "$tmp" "$dst"
  ok "$label downloaded ($(numfmt --to=iec "$sz" 2>/dev/null || echo "$sz bytes"))"
}

# Official ComfyUI SUPIR workflow model set.
download_file "$JUG_URL"   "$CKPT_DIR/$JUG_NAME"   1000000000 "Juggernaut XL v9 RDPhoto2 Lightning"
download_file "$SUPIR_URL" "$PATCH_DIR/$SUPIR_NAME" 2000000000 "SUPIR v0Q fp16 model patch"
download_file "$QWEN_URL"  "$TEXT_DIR/$QWEN_NAME"   1000000000 "Qwen3.5 4B BF16 text encoder"

info "Downloading the official ComfyUI native SUPIR workflow..."
if command -v curl >/dev/null 2>&1; then
  curl -fL --retry 8 --retry-delay 3 "$WF_URL" -o "${WF_PATH}.part"
else
  wget --tries=8 -O "${WF_PATH}.part" "$WF_URL"
fi
[[ "$(stat -c%s "${WF_PATH}.part" 2>/dev/null || echo 0)" -gt 10000 ]] || fail "Workflow download failed."
mv -f "${WF_PATH}.part" "$WF_PATH"
ok "Workflow installed: $WF_PATH"

# Everything is now on disk. Only now do we restart the stock ComfyUI so it
# refreshes its model lists. We do NOT delete/update/replace ComfyUI.
if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
  info "All setup is complete. Restarting stock ComfyUI once to refresh model lists..."
  kill "$OLD_PID" 2>/dev/null || true

  # Give a platform supervisor a chance to restart it automatically.
  RESTARTED_PID=""
  for _ in $(seq 1 15); do
    sleep 1
    RESTARTED_PID="$(pgrep -f "main\.py.*--port[= ]${PORT}" | head -n1 || true)"
    if [[ -n "$RESTARTED_PID" && "$RESTARTED_PID" != "$OLD_PID" ]]; then
      break
    fi
  done

  # If the platform did not relaunch it, use the exact interpreter and argv that
  # the stock process was using. This avoids the .venv/bin/python wrapper issue.
  if [[ -z "$RESTARTED_PID" ]]; then
    [[ -n "${OLD_EXE:-}" && -x "$OLD_EXE" && -n "${OLD_CWD:-}" ]] || fail "Could not recover the stock ComfyUI launch command."
    info "RunPod did not auto-restart ComfyUI; relaunching the same stock process command."
    (
      cd "$OLD_CWD"
      nohup "$OLD_EXE" "${OLD_ARGV[@]:1}" > "$LOG_DIR/comfyui_supir_native_v2.log" 2>&1 &
      echo $! > "$LOG_DIR/comfyui_supir_native_v2.pid"
    )
  else
    ok "RunPod automatically restarted stock ComfyUI (PID $RESTARTED_PID)."
  fi
fi

info "Waiting for ComfyUI API..."
READY=0
for _ in $(seq 1 90); do
  sleep 2
  if curl -fsS "http://127.0.0.1:${PORT}/object_info/SUPIRApply" -o /tmp/supir_final_check.json 2>/dev/null && grep -q 'SUPIRApply' /tmp/supir_final_check.json; then
    READY=1
    break
  fi
done
[[ "$READY" == "1" ]] || fail "ComfyUI did not come back with native SUPIR support. Check the normal RunPod ComfyUI startup log."

printf '\n\033[1;32m============================================================\n'
printf ' SUCCESS — native SUPIR image restoration is ready\n'
printf '============================================================\033[0m\n'
echo "Stock ComfyUI : $COMFY   (not replaced / not updated)"
echo "Port          : $PORT"
echo "Workflow      : $WF_PATH"
echo "Checkpoint    : $CKPT_DIR/$JUG_NAME"
echo "SUPIR patch   : $PATCH_DIR/$SUPIR_NAME"
echo "Text encoder  : $TEXT_DIR/$QWEN_NAME"
echo
echo "Open the usual ComfyUI page, then load:"
echo "  $WF_NAME"
echo
echo "This is the official ComfyUI native SUPIR workflow; no custom-node package is required."
echo "============================================================"
