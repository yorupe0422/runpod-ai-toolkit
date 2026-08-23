#!/usr/bin/env bash
set -Eeuo pipefail

# Z-Image Turbo NSFW v2 add-on for the existing V4 environment.
# Installs one pinned LoRA + one ComfyUI workflow. It does not generate an image.

ROOT="${ROOT:-/workspace/runpod-slim}"
COMFY_DIR="${COMFY_DIR:-$ROOT/ComfyUI-ZImage}"
PORT="${PORT:-8188}"
RESTART=1
[[ "${1:-}" == "--no-restart" ]] && RESTART=0

LORA_REPO="RomixERR/Pornmaster_v1-Z-Images-Turbo"
LORA_REV="2da2579a717ecb4059963421b4f974a719f3cd64"
LORA_FILE="Pornmaster_v1_000044700.safetensors"
LORA_SIZE="340194512"
LORA_SHA256="dff3c72c750721e052ef8952277f9d7fac8b27c2e87e7d5e737261279f66bf90"
WORKFLOW_FILE="booth_zimage_nsfw_adult_pornmaster_v2.json"
LOG="$ROOT/zimage_nsfw_pornmaster_v2_addon.log"
LOCK="$ROOT/.zimage-nsfw-pornmaster-v2-addon.lock"

mkdir -p "$ROOT"
touch "$LOG"
exec > >(tee -a "$LOG") 2>&1
AUTH_CONFIG=""
cleanup_auth() {
  [[ -n "$AUTH_CONFIG" && -f "$AUTH_CONFIG" ]] && rm -f "$AUTH_CONFIG" || true
}
on_error() {
  local rc="$1" line="$2"
  echo "[FAILED] Z-Image NSFW v2 add-on (exit=$rc, line=$line)"
  echo "Log: $LOG"
  exit "$rc"
}
trap 'on_error "$?" "$LINENO"' ERR
trap cleanup_auth EXIT

if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  flock -n 9 || { echo "[FATAL] This add-on is already running"; exit 1; }
fi

printf '\n============================================================\n'
printf ' Z-IMAGE TURBO — ADULT NSFW LoRA v2 ADD-ON\n'
printf '============================================================\n'
printf 'ComfyUI : %s\nPort    : %s\nLoRA    : %s\n\n' "$COMFY_DIR" "$PORT" "$LORA_FILE"

[[ -f "$COMFY_DIR/main.py" ]] || {
  echo "[FATAL] Existing Z-Image V4 environment was not found: $COMFY_DIR"
  echo "Run runpod_zimage_booth_setup_v4.sh first, then rerun this add-on."
  exit 1
}
command -v curl >/dev/null 2>&1 || { echo "[FATAL] curl is required"; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "[FATAL] sha256sum is required"; exit 1; }
command -v base64 >/dev/null 2>&1 || { echo "[FATAL] base64 is required"; exit 1; }

LORA_DIR="$COMFY_DIR/models/loras"
WF_DIR="$COMFY_DIR/user/default/workflows"
mkdir -p "$LORA_DIR" "$WF_DIR"
LORA_PATH="$LORA_DIR/$LORA_FILE"
PART_PATH="$LORA_PATH.part"

valid_file() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  [[ "$(stat -c %s "$path")" == "$LORA_SIZE" ]] || return 1
  [[ "$(sha256sum "$path" | awk '{print $1}')" == "$LORA_SHA256" ]]
}

validate_safetensors() {
  local path="$1"
  python3 - "$path" <<'PY_SAFE'
import json, pathlib, struct, sys
p = pathlib.Path(sys.argv[1])
with p.open('rb') as f:
    raw = f.read(8)
    if len(raw) != 8:
        raise SystemExit('short safetensors file')
    header_len = struct.unpack('<Q', raw)[0]
    if header_len <= 2 or header_len > 100_000_000:
        raise SystemExit(f'invalid safetensors header length: {header_len}')
    header = f.read(header_len)
    obj = json.loads(header)
    if not isinstance(obj, dict) or not obj:
        raise SystemExit('invalid safetensors header')
print(f'[OK] safetensors header validated: {p.name}')
PY_SAFE
}

printf '===== [1/4] LoRA download and verification =====\n'
if valid_file "$LORA_PATH"; then
  echo "[OK] Existing LoRA already matches pinned SHA256"
else
  if [[ -f "$LORA_PATH" ]]; then
    backup="$LORA_PATH.invalid.$(date +%Y%m%d-%H%M%S)"
    mv "$LORA_PATH" "$backup"
    echo "[WARN] Existing mismatched file preserved as: $backup"
  fi

  url="https://huggingface.co/$LORA_REPO/resolve/$LORA_REV/$LORA_FILE?download=true"
  token="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
  if [[ -z "$token" && -f /root/.cache/huggingface/token ]]; then
    token="$(tr -d '\r\n' </root/.cache/huggingface/token)"
  fi
  if [[ -n "$token" ]]; then
    AUTH_CONFIG="$(mktemp)"
    chmod 600 "$AUTH_CONFIG"
    printf 'header = "Authorization: Bearer %s"\n' "$token" >"$AUTH_CONFIG"
    echo "[OK] Hugging Face authentication enabled"
  else
    echo "[WARN] HF_TOKEN is not set; public download will be attempted"
  fi

  curl_args=(
    --fail --location --continue-at -
    --retry 12 --retry-all-errors --retry-delay 10
    --connect-timeout 30 --speed-time 90 --speed-limit 1024
    --output "$PART_PATH"
  )
  [[ -n "$AUTH_CONFIG" ]] && curl_args+=(--config "$AUTH_CONFIG")
  curl "${curl_args[@]}" "$url"
  cleanup_auth
  AUTH_CONFIG=""

  actual_size="$(stat -c %s "$PART_PATH")"
  [[ "$actual_size" == "$LORA_SIZE" ]] || {
    echo "[FATAL] Size mismatch: expected=$LORA_SIZE actual=$actual_size"
    echo "The resumable partial file was kept: $PART_PATH"
    exit 1
  }
  actual_sha="$(sha256sum "$PART_PATH" | awk '{print $1}')"
  [[ "$actual_sha" == "$LORA_SHA256" ]] || {
    echo "[FATAL] SHA256 mismatch: expected=$LORA_SHA256 actual=$actual_sha"
    echo "The mismatched download was kept: $PART_PATH"
    exit 1
  }
  mv "$PART_PATH" "$LORA_PATH"
  echo "[OK] Pinned LoRA installed"
fi
validate_safetensors "$LORA_PATH"

printf '\n===== [2/4] Workflow install =====\n'
WORKFLOW_B64='ewogICJsYXN0X25vZGVfaWQiOiAxMiwKICAibGFzdF9saW5rX2lkIjogMTIsCiAgIm5vZGVzIjogWwogICAgewogICAgICAiaWQiOiAxLAogICAgICAidHlwZSI6ICJVTkVUTG9hZGVyIiwKICAgICAgInBvcyI6IFsKICAgICAgICAwLAogICAgICAgIDAKICAgICAgXSwKICAgICAgInNpemUiOiBbCiAgICAgICAgMzAwLAogICAgICAgIDExMAogICAgICBdLAogICAgICAiZmxhZ3MiOiB7fSwKICAgICAgIm9yZGVyIjogMCwKICAgICAgIm1vZGUiOiAwLAogICAgICAiaW5wdXRzIjogW10sCiAgICAgICJvdXRwdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIk1PREVMIiwKICAgICAgICAgICJ0eXBlIjogIk1PREVMIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgMQogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMAogICAgICAgIH0KICAgICAgXSwKICAgICAgInByb3BlcnRpZXMiOiB7CiAgICAgICAgIk5vZGUgbmFtZSBmb3IgUyZSIjogIlVORVRMb2FkZXIiCiAgICAgIH0sCiAgICAgICJ3aWRnZXRzX3ZhbHVlcyI6IFsKICAgICAgICAiel9pbWFnZV90dXJib19iZjE2LnNhZmV0ZW5zb3JzIiwKICAgICAgICAiZGVmYXVsdCIKICAgICAgXQogICAgfSwKICAgIHsKICAgICAgImlkIjogMiwKICAgICAgInR5cGUiOiAiQ0xJUExvYWRlciIsCiAgICAgICJwb3MiOiBbCiAgICAgICAgMCwKICAgICAgICAyNDAKICAgICAgXSwKICAgICAgInNpemUiOiBbCiAgICAgICAgMzAwLAogICAgICAgIDE0MAogICAgICBdLAogICAgICAiZmxhZ3MiOiB7fSwKICAgICAgIm9yZGVyIjogMSwKICAgICAgIm1vZGUiOiAwLAogICAgICAiaW5wdXRzIjogW10sCiAgICAgICJvdXRwdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIkNMSVAiLAogICAgICAgICAgInR5cGUiOiAiQ0xJUCIsCiAgICAgICAgICAibGlua3MiOiBbCiAgICAgICAgICAgIDMKICAgICAgICAgIF0sCiAgICAgICAgICAic2xvdF9pbmRleCI6IDAKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJwcm9wZXJ0aWVzIjogewogICAgICAgICJOb2RlIG5hbWUgZm9yIFMmUiI6ICJDTElQTG9hZGVyIgogICAgICB9LAogICAgICAid2lkZ2V0c192YWx1ZXMiOiBbCiAgICAgICAgInF3ZW5fM180Yi5zYWZldGVuc29ycyIsCiAgICAgICAgImx1bWluYTIiLAogICAgICAgICJkZWZhdWx0IgogICAgICBdCiAgICB9LAogICAgewogICAgICAiaWQiOiAzLAogICAgICAidHlwZSI6ICJWQUVMb2FkZXIiLAogICAgICAicG9zIjogWwogICAgICAgIDAsCiAgICAgICAgNDYwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDMwMCwKICAgICAgICAxMTAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDIsCiAgICAgICJtb2RlIjogMCwKICAgICAgImlucHV0cyI6IFtdLAogICAgICAib3V0cHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJWQUUiLAogICAgICAgICAgInR5cGUiOiAiVkFFIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgOQogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMAogICAgICAgIH0KICAgICAgXSwKICAgICAgInByb3BlcnRpZXMiOiB7CiAgICAgICAgIk5vZGUgbmFtZSBmb3IgUyZSIjogIlZBRUxvYWRlciIKICAgICAgfSwKICAgICAgIndpZGdldHNfdmFsdWVzIjogWwogICAgICAgICJhZS5zYWZldGVuc29ycyIKICAgICAgXQogICAgfSwKICAgIHsKICAgICAgImlkIjogNCwKICAgICAgInR5cGUiOiAiQ0xJUFRleHRFbmNvZGUiLAogICAgICAicG9zIjogWwogICAgICAgIDEwODAsCiAgICAgICAgMjQwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDQ3MCwKICAgICAgICAzMDAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDYsCiAgICAgICJtb2RlIjogMCwKICAgICAgImlucHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJjbGlwIiwKICAgICAgICAgICJ0eXBlIjogIkNMSVAiLAogICAgICAgICAgImxpbmsiOiAzCiAgICAgICAgfQogICAgICBdLAogICAgICAib3V0cHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJDT05ESVRJT05JTkciLAogICAgICAgICAgInR5cGUiOiAiQ09ORElUSU9OSU5HIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgNCwKICAgICAgICAgICAgNQogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMAogICAgICAgIH0KICAgICAgXSwKICAgICAgInByb3BlcnRpZXMiOiB7CiAgICAgICAgIk5vZGUgbmFtZSBmb3IgUyZSIjogIkNMSVBUZXh0RW5jb2RlIgogICAgICB9LAogICAgICAid2lkZ2V0c192YWx1ZXMiOiBbCiAgICAgICAgInByb25tc3RyLCBwaG90b3JlYWxpc3RpYyBlZGl0b3JpYWwgcG9ydHJhaXQgb2Ygb25lIGNsZWFybHkgYWR1bHQgZmljdGlvbmFsIHdvbWFuLCBhZ2UgMjUsIHRhc3RlZnVsIGFkdWx0IG51ZGUgZ2xhbW91ciBwaG90b2dyYXBoeSwgY29uZmlkZW50IG1hdHVyZSBleHByZXNzaW9uLCBuYXR1cmFsIGFkdWx0IGJvZHkgcHJvcG9ydGlvbnMsIHJlYWxpc3RpYyBza2luIHRleHR1cmUsIGFuYXRvbWljYWxseSBjb2hlcmVudCBoYW5kcywgZGV0YWlsZWQgZmFjZSBhbmQgaGFpciwgc29mdCBjaW5lbWF0aWMgc3R1ZGlvIGxpZ2h0aW5nLCBjbGVhbiBjb21wb3NpdGlvbiwgcHJvZmVzc2lvbmFsIHBob3RvZ3JhcGh5LCBoaWdoIGRldGFpbCwgbm8gdGV4dCwgbm8gd2F0ZXJtYXJrLiIKICAgICAgXQogICAgfSwKICAgIHsKICAgICAgImlkIjogNSwKICAgICAgInR5cGUiOiAiQ29uZGl0aW9uaW5nWmVyb091dCIsCiAgICAgICJwb3MiOiBbCiAgICAgICAgMTI5MCwKICAgICAgICAzODAKICAgICAgXSwKICAgICAgInNpemUiOiBbCiAgICAgICAgMjYwLAogICAgICAgIDgwCiAgICAgIF0sCiAgICAgICJmbGFncyI6IHt9LAogICAgICAib3JkZXIiOiA3LAogICAgICAibW9kZSI6IDAsCiAgICAgICJpbnB1dHMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAiY29uZGl0aW9uaW5nIiwKICAgICAgICAgICJ0eXBlIjogIkNPTkRJVElPTklORyIsCiAgICAgICAgICAibGluayI6IDUKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJvdXRwdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIkNPTkRJVElPTklORyIsCiAgICAgICAgICAidHlwZSI6ICJDT05ESVRJT05JTkciLAogICAgICAgICAgImxpbmtzIjogWwogICAgICAgICAgICA3CiAgICAgICAgICBdLAogICAgICAgICAgInNsb3RfaW5kZXgiOiAwCiAgICAgICAgfQogICAgICBdLAogICAgICAicHJvcGVydGllcyI6IHsKICAgICAgICAiTm9kZSBuYW1lIGZvciBTJlIiOiAiQ29uZGl0aW9uaW5nWmVyb091dCIKICAgICAgfSwKICAgICAgIndpZGdldHNfdmFsdWVzIjogW10KICAgIH0sCiAgICB7CiAgICAgICJpZCI6IDYsCiAgICAgICJ0eXBlIjogIkVtcHR5U0QzTGF0ZW50SW1hZ2UiLAogICAgICAicG9zIjogWwogICAgICAgIDc2MCwKICAgICAgICA1ODAKICAgICAgXSwKICAgICAgInNpemUiOiBbCiAgICAgICAgMzAwLAogICAgICAgIDE3MAogICAgICBdLAogICAgICAiZmxhZ3MiOiB7fSwKICAgICAgIm9yZGVyIjogOCwKICAgICAgIm1vZGUiOiAwLAogICAgICAiaW5wdXRzIjogW10sCiAgICAgICJvdXRwdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIkxBVEVOVCIsCiAgICAgICAgICAidHlwZSI6ICJMQVRFTlQiLAogICAgICAgICAgImxpbmtzIjogWwogICAgICAgICAgICA4CiAgICAgICAgICBdLAogICAgICAgICAgInNsb3RfaW5kZXgiOiAwCiAgICAgICAgfQogICAgICBdLAogICAgICAicHJvcGVydGllcyI6IHsKICAgICAgICAiTm9kZSBuYW1lIGZvciBTJlIiOiAiRW1wdHlTRDNMYXRlbnRJbWFnZSIKICAgICAgfSwKICAgICAgIndpZGdldHNfdmFsdWVzIjogWwogICAgICAgIDgzMiwKICAgICAgICAxMjE2LAogICAgICAgIDEKICAgICAgXQogICAgfSwKICAgIHsKICAgICAgImlkIjogMTIsCiAgICAgICJ0eXBlIjogIkxvcmFMb2FkZXJNb2RlbE9ubHkiLAogICAgICAicG9zIjogWwogICAgICAgIDQ4MCwKICAgICAgICAyMAogICAgICBdLAogICAgICAic2l6ZSI6IFsKICAgICAgICA0MzAsCiAgICAgICAgMTMwCiAgICAgIF0sCiAgICAgICJmbGFncyI6IHt9LAogICAgICAib3JkZXIiOiAzLAogICAgICAibW9kZSI6IDAsCiAgICAgICJpbnB1dHMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAibW9kZWwiLAogICAgICAgICAgInR5cGUiOiAiTU9ERUwiLAogICAgICAgICAgImxpbmsiOiAxCiAgICAgICAgfQogICAgICBdLAogICAgICAib3V0cHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJNT0RFTCIsCiAgICAgICAgICAidHlwZSI6ICJNT0RFTCIsCiAgICAgICAgICAibGlua3MiOiBbCiAgICAgICAgICAgIDEyCiAgICAgICAgICBdLAogICAgICAgICAgInNsb3RfaW5kZXgiOiAwCiAgICAgICAgfQogICAgICBdLAogICAgICAidGl0bGUiOiAiTlNGVyBMb1JBIOKAlCBQb3JubWFzdGVyIHYxICgwLjgwKSIsCiAgICAgICJwcm9wZXJ0aWVzIjogewogICAgICAgICJOb2RlIG5hbWUgZm9yIFMmUiI6ICJMb3JhTG9hZGVyTW9kZWxPbmx5IgogICAgICB9LAogICAgICAid2lkZ2V0c192YWx1ZXMiOiBbCiAgICAgICAgIlBvcm5tYXN0ZXJfdjFfMDAwMDQ0NzAwLnNhZmV0ZW5zb3JzIiwKICAgICAgICAwLjgKICAgICAgXQogICAgfSwKICAgIHsKICAgICAgImlkIjogNywKICAgICAgInR5cGUiOiAiTW9kZWxTYW1wbGluZ0F1cmFGbG93IiwKICAgICAgInBvcyI6IFsKICAgICAgICAxMDgwLAogICAgICAgIDIwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDMwMCwKICAgICAgICAxMTAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDUsCiAgICAgICJtb2RlIjogMCwKICAgICAgImlucHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJtb2RlbCIsCiAgICAgICAgICAidHlwZSI6ICJNT0RFTCIsCiAgICAgICAgICAibGluayI6IDEyCiAgICAgICAgfQogICAgICBdLAogICAgICAib3V0cHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJNT0RFTCIsCiAgICAgICAgICAidHlwZSI6ICJNT0RFTCIsCiAgICAgICAgICAibGlua3MiOiBbCiAgICAgICAgICAgIDYKICAgICAgICAgIF0sCiAgICAgICAgICAic2xvdF9pbmRleCI6IDAKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJwcm9wZXJ0aWVzIjogewogICAgICAgICJOb2RlIG5hbWUgZm9yIFMmUiI6ICJNb2RlbFNhbXBsaW5nQXVyYUZsb3ciCiAgICAgIH0sCiAgICAgICJ3aWRnZXRzX3ZhbHVlcyI6IFsKICAgICAgICAyLjUKICAgICAgXSwKICAgICAgInRpdGxlIjogIlotSW1hZ2Ugc2FtcGxpbmcg4oCUIFNoaWZ0IDIuNSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6IDgsCiAgICAgICJ0eXBlIjogIktTYW1wbGVyIiwKICAgICAgInBvcyI6IFsKICAgICAgICAxNzAwLAogICAgICAgIDExMAogICAgICBdLAogICAgICAic2l6ZSI6IFsKICAgICAgICAzMzAsCiAgICAgICAgMzQwCiAgICAgIF0sCiAgICAgICJmbGFncyI6IHt9LAogICAgICAib3JkZXIiOiA5LAogICAgICAibW9kZSI6IDAsCiAgICAgICJpbnB1dHMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAibW9kZWwiLAogICAgICAgICAgInR5cGUiOiAiTU9ERUwiLAogICAgICAgICAgImxpbmsiOiA2CiAgICAgICAgfSwKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJwb3NpdGl2ZSIsCiAgICAgICAgICAidHlwZSI6ICJDT05ESVRJT05JTkciLAogICAgICAgICAgImxpbmsiOiA0CiAgICAgICAgfSwKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJuZWdhdGl2ZSIsCiAgICAgICAgICAidHlwZSI6ICJDT05ESVRJT05JTkciLAogICAgICAgICAgImxpbmsiOiA3CiAgICAgICAgfSwKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJsYXRlbnRfaW1hZ2UiLAogICAgICAgICAgInR5cGUiOiAiTEFURU5UIiwKICAgICAgICAgICJsaW5rIjogOAogICAgICAgIH0KICAgICAgXSwKICAgICAgIm91dHB1dHMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAiTEFURU5UIiwKICAgICAgICAgICJ0eXBlIjogIkxBVEVOVCIsCiAgICAgICAgICAibGlua3MiOiBbCiAgICAgICAgICAgIDEwCiAgICAgICAgICBdLAogICAgICAgICAgInNsb3RfaW5kZXgiOiAwCiAgICAgICAgfQogICAgICBdLAogICAgICAicHJvcGVydGllcyI6IHsKICAgICAgICAiTm9kZSBuYW1lIGZvciBTJlIiOiAiS1NhbXBsZXIiCiAgICAgIH0sCiAgICAgICJ3aWRnZXRzX3ZhbHVlcyI6IFsKICAgICAgICAwLAogICAgICAgICJyYW5kb21pemUiLAogICAgICAgIDE2LAogICAgICAgIDEuMCwKICAgICAgICAiZXVsZXIiLAogICAgICAgICJiZXRhIiwKICAgICAgICAxLjAKICAgICAgXSwKICAgICAgInRpdGxlIjogIlF1YWxpdHkgYmFzZWxpbmUg4oCUIDE2IHN0ZXBzIC8gRXVsZXIgLyBCZXRhIgogICAgfSwKICAgIHsKICAgICAgImlkIjogOSwKICAgICAgInR5cGUiOiAiVkFFRGVjb2RlIiwKICAgICAgInBvcyI6IFsKICAgICAgICAyMTAwLAogICAgICAgIDExMAogICAgICBdLAogICAgICAic2l6ZSI6IFsKICAgICAgICAyNTAsCiAgICAgICAgMTAwCiAgICAgIF0sCiAgICAgICJmbGFncyI6IHt9LAogICAgICAib3JkZXIiOiAxMCwKICAgICAgIm1vZGUiOiAwLAogICAgICAiaW5wdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogInNhbXBsZXMiLAogICAgICAgICAgInR5cGUiOiAiTEFURU5UIiwKICAgICAgICAgICJsaW5rIjogMTAKICAgICAgICB9LAogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogInZhZSIsCiAgICAgICAgICAidHlwZSI6ICJWQUUiLAogICAgICAgICAgImxpbmsiOiA5CiAgICAgICAgfQogICAgICBdLAogICAgICAib3V0cHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJJTUFHRSIsCiAgICAgICAgICAidHlwZSI6ICJJTUFHRSIsCiAgICAgICAgICAibGlua3MiOiBbCiAgICAgICAgICAgIDExCiAgICAgICAgICBdLAogICAgICAgICAgInNsb3RfaW5kZXgiOiAwCiAgICAgICAgfQogICAgICBdLAogICAgICAicHJvcGVydGllcyI6IHsKICAgICAgICAiTm9kZSBuYW1lIGZvciBTJlIiOiAiVkFFRGVjb2RlIgogICAgICB9LAogICAgICAid2lkZ2V0c192YWx1ZXMiOiBbXQogICAgfSwKICAgIHsKICAgICAgImlkIjogMTAsCiAgICAgICJ0eXBlIjogIlNhdmVJbWFnZSIsCiAgICAgICJwb3MiOiBbCiAgICAgICAgMjQyMCwKICAgICAgICA3MAogICAgICBdLAogICAgICAic2l6ZSI6IFsKICAgICAgICA1MDAsCiAgICAgICAgNTAwCiAgICAgIF0sCiAgICAgICJmbGFncyI6IHt9LAogICAgICAib3JkZXIiOiAxMSwKICAgICAgIm1vZGUiOiAwLAogICAgICAiaW5wdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogImltYWdlcyIsCiAgICAgICAgICAidHlwZSI6ICJJTUFHRSIsCiAgICAgICAgICAibGluayI6IDExCiAgICAgICAgfQogICAgICBdLAogICAgICAib3V0cHV0cyI6IFtdLAogICAgICAicHJvcGVydGllcyI6IHsKICAgICAgICAiTm9kZSBuYW1lIGZvciBTJlIiOiAiU2F2ZUltYWdlIgogICAgICB9LAogICAgICAid2lkZ2V0c192YWx1ZXMiOiBbCiAgICAgICAgImJvb3RoX25zZncvemltYWdlX2FkdWx0X3Bvcm5tYXN0ZXJfdjIiCiAgICAgIF0KICAgIH0sCiAgICB7CiAgICAgICJpZCI6IDExLAogICAgICAidHlwZSI6ICJNYXJrZG93bk5vdGUiLAogICAgICAicG9zIjogWwogICAgICAgIDAsCiAgICAgICAgLTMwMAogICAgICBdLAogICAgICAic2l6ZSI6IFsKICAgICAgICA3NjAsCiAgICAgICAgMjkwCiAgICAgIF0sCiAgICAgICJmbGFncyI6IHt9LAogICAgICAib3JkZXIiOiAwLAogICAgICAibW9kZSI6IDAsCiAgICAgICJpbnB1dHMiOiBbXSwKICAgICAgIm91dHB1dHMiOiBbXSwKICAgICAgInRpdGxlIjogIlJFQUQgTUUg4oCUIEFEVUxUIEZJQ1RJT05BTCBTVUJKRUNUUyBPTkxZIiwKICAgICAgInByb3BlcnRpZXMiOiB7CiAgICAgICAgIk5vZGUgbmFtZSBmb3IgUyZSIjogIk1hcmtkb3duTm90ZSIsCiAgICAgICAgImNucl9pZCI6ICJjb21meS1jb3JlIgogICAgICB9LAogICAgICAid2lkZ2V0c192YWx1ZXMiOiBbCiAgICAgICAgIiMgWi1JbWFnZSBUdXJibyArIFBvcm5tYXN0ZXIgdjEg4oCUIEFkdWx0IE5TRlcgdjJcblxuLSBMb1JBOiBQb3JubWFzdGVyX3YxXzAwMDA0NDcwMC5zYWZldGVuc29yc1xuLSBUcmlnZ2VyOiBgcHJvbm1zdHJgIChrZWVwIGl0IG5lYXIgdGhlIHN0YXJ0IG9mIHRoZSBwcm9tcHQpXG4tIERlZmF1bHQgc3RyZW5ndGg6IDAuODA7IHVzZWZ1bCBhdXRob3IgcmFuZ2U6IDAuNzDigJMwLjg1XG4tIERlZmF1bHQ6IDgzMiB4IDEyMTYgKH4xLjAgTVApLCAxNiBzdGVwcywgQ0ZHIDEuMCwgRXVsZXIgLyBCZXRhLCBTaGlmdCAyLjVcbi0gSWYgYW5hdG9teSBiZWNvbWVzIHVuc3RhYmxlOiBsb3dlciBMb1JBIHN0cmVuZ3RoIHRvIDAuNzDigJMwLjc1LCB0aGVuIHRyeSBhbm90aGVyIHNlZWQuXG4tIFVzZSBvbmx5IGNsZWFybHkgYWR1bHQgZmljdGlvbmFsIHN1YmplY3RzLiBOZXZlciB1c2UgbWlub3JzIG9yIGFnZS1hbWJpZ3VvdXMgc3ViamVjdHMuXG4tIE91dHB1dDogYG91dHB1dC9ib290aF9uc2Z3L2AiCiAgICAgIF0KICAgIH0KICBdLAogICJsaW5rcyI6IFsKICAgIFsKICAgICAgMywKICAgICAgMiwKICAgICAgMCwKICAgICAgNCwKICAgICAgMCwKICAgICAgIkNMSVAiCiAgICBdLAogICAgWwogICAgICA0LAogICAgICA0LAogICAgICAwLAogICAgICA4LAogICAgICAxLAogICAgICAiQ09ORElUSU9OSU5HIgogICAgXSwKICAgIFsKICAgICAgNSwKICAgICAgNCwKICAgICAgMCwKICAgICAgNSwKICAgICAgMCwKICAgICAgIkNPTkRJVElPTklORyIKICAgIF0sCiAgICBbCiAgICAgIDYsCiAgICAgIDcsCiAgICAgIDAsCiAgICAgIDgsCiAgICAgIDAsCiAgICAgICJNT0RFTCIKICAgIF0sCiAgICBbCiAgICAgIDcsCiAgICAgIDUsCiAgICAgIDAsCiAgICAgIDgsCiAgICAgIDIsCiAgICAgICJDT05ESVRJT05JTkciCiAgICBdLAogICAgWwogICAgICA4LAogICAgICA2LAogICAgICAwLAogICAgICA4LAogICAgICAzLAogICAgICAiTEFURU5UIgogICAgXSwKICAgIFsKICAgICAgOSwKICAgICAgMywKICAgICAgMCwKICAgICAgOSwKICAgICAgMSwKICAgICAgIlZBRSIKICAgIF0sCiAgICBbCiAgICAgIDEwLAogICAgICA4LAogICAgICAwLAogICAgICA5LAogICAgICAwLAogICAgICAiTEFURU5UIgogICAgXSwKICAgIFsKICAgICAgMTEsCiAgICAgIDksCiAgICAgIDAsCiAgICAgIDEwLAogICAgICAwLAogICAgICAiSU1BR0UiCiAgICBdLAogICAgWwogICAgICAxLAogICAgICAxLAogICAgICAwLAogICAgICAxMiwKICAgICAgMCwKICAgICAgIk1PREVMIgogICAgXSwKICAgIFsKICAgICAgMTIsCiAgICAgIDEyLAogICAgICAwLAogICAgICA3LAogICAgICAwLAogICAgICAiTU9ERUwiCiAgICBdCiAgXSwKICAiZ3JvdXBzIjogW10sCiAgImNvbmZpZyI6IHt9LAogICJleHRyYSI6IHsKICAgICJkcyI6IHsKICAgICAgInNjYWxlIjogMC42OCwKICAgICAgIm9mZnNldCI6IFsKICAgICAgICA4MCwKICAgICAgICAxMDAKICAgICAgXQogICAgfSwKICAgICJhZHVsdF9vbmx5IjogdHJ1ZSwKICAgICJ3b3JrZmxvd19uYW1lIjogImJvb3RoX3ppbWFnZV9uc2Z3X2FkdWx0X3Bvcm5tYXN0ZXJfdjIiLAogICAgImxvcmFfcmVwbyI6ICJSb21peEVSUi9Qb3JubWFzdGVyX3YxLVotSW1hZ2VzLVR1cmJvIiwKICAgICJsb3JhX3JldmlzaW9uIjogIjJkYTI1NzlhNzE3ZWNiNDA1OTk2MzQyMWI0Zjk3NGE3MTlmM2NkNjQiLAogICAgImxvcmFfc2hhMjU2IjogImRmZjNjNzJjNzUwNzIxZTA1MmVmODk1MjI3N2Y5ZDdmYWM4YjI3YzJlODdlN2Q1ZTczNzI2MTI3OWY2NmJmOTAiCiAgfSwKICAidmVyc2lvbiI6IDAuNAp9Cg=='
WF_TMP="$WF_DIR/$WORKFLOW_FILE.tmp.$$"
printf '%s' "$WORKFLOW_B64" | base64 -d >"$WF_TMP"
python3 -m json.tool "$WF_TMP" >/dev/null
mv "$WF_TMP" "$WF_DIR/$WORKFLOW_FILE"
echo "[OK] Workflow: $WF_DIR/$WORKFLOW_FILE"

printf '\n===== [3/4] Workflow/model cross-check =====\n'
python3 - "$WF_DIR/$WORKFLOW_FILE" "$LORA_FILE" <<'PY_WF'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); expected = sys.argv[2]
d = json.loads(p.read_text())
nodes = d.get('nodes', [])
loras = [n for n in nodes if n.get('type') == 'LoraLoaderModelOnly']
assert len(loras) == 1, f'expected one LoRA loader, found {len(loras)}'
assert loras[0].get('widgets_values', [None])[0] == expected
assert abs(float(loras[0]['widgets_values'][1]) - 0.8) < 1e-9
samplers = [n for n in nodes if n.get('type') == 'KSampler']
assert len(samplers) == 1
assert samplers[0]['widgets_values'][2:7] == [16, 1.0, 'euler', 'beta', 1.0]
assert d.get('extra', {}).get('adult_only') is True
print('[OK] Workflow graph validated')
PY_WF

printf '\n===== [4/4] ComfyUI restart on fixed port %s =====\n' "$PORT"
if [[ "$RESTART" == 0 ]]; then
  echo "[OK] --no-restart selected. Restart ComfyUI before opening the workflow."
else
  PYTHON_BIN=""
  for candidate in "$COMFY_DIR/.venv/bin/python" "$(command -v python3 || true)"; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    if "$candidate" - <<'PY_CUDA' >/dev/null 2>&1
import torch
assert torch.cuda.is_available()
PY_CUDA
    then
      PYTHON_BIN="$candidate"
      break
    fi
  done
  [[ -n "$PYTHON_BIN" ]] || {
    echo "[WARN] No CUDA-capable Python was found. Files are installed, but ComfyUI was not restarted."
    exit 0
  }

  mapfile -t pids < <(
    if command -v lsof >/dev/null 2>&1; then
      lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true
    elif command -v fuser >/dev/null 2>&1; then
      fuser "$PORT/tcp" 2>/dev/null | tr ' ' '\n' | sed '/^$/d' || true
    fi
  )
  foreign=0
  for pid in "${pids[@]}"; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    proc_cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
    proc_cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
    if [[ "$proc_cwd" == "$COMFY_DIR" && "$proc_cmd" == *main.py* ]]; then
      echo "[INFO] Stopping existing Z-Image ComfyUI PID $pid"
      kill "$pid" || true
    else
      echo "[WARN] Port $PORT is occupied by another service (PID $pid): $proc_cmd"
      foreign=1
    fi
  done
  if (( foreign )); then
    echo "[WARN] LoRA and workflow are installed, but restart was skipped to avoid stopping another environment."
    echo "Stop the service on port $PORT, then rerun this script or start $COMFY_DIR manually."
    exit 0
  fi

  for _ in $(seq 1 30); do
    busy=0
    if command -v lsof >/dev/null 2>&1; then
      lsof -tiTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && busy=1 || true
    elif command -v fuser >/dev/null 2>&1; then
      fuser "$PORT/tcp" >/dev/null 2>&1 && busy=1 || true
    fi
    (( busy == 0 )) && break
    sleep 1
  done

  COMFY_LOG="$COMFY_DIR/comfyui.log"
  cd "$COMFY_DIR"
  nohup "$PYTHON_BIN" main.py --listen 0.0.0.0 --port "$PORT" --preview-method auto >>"$COMFY_LOG" 2>&1 &
  new_pid=$!
  echo "$new_pid" >"$COMFY_DIR/comfyui.pid"
  echo "[INFO] Started Z-Image ComfyUI PID $new_pid"

  ready=0
  for _ in $(seq 1 120); do
    if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/system_stats" >/dev/null 2>&1; then
      ready=1
      break
    fi
    kill -0 "$new_pid" 2>/dev/null || break
    sleep 1
  done
  [[ "$ready" == 1 ]] || {
    echo "[FATAL] ComfyUI did not become ready. Check: $COMFY_LOG"
    tail -80 "$COMFY_LOG" || true
    exit 1
  }
  echo "[OK] ComfyUI is ready on port $PORT"
fi

printf '\n============================================================\n'
printf ' Z-IMAGE ADULT NSFW v2 READY\n'
printf '============================================================\n'
printf 'Workflow : %s\n' "$WF_DIR/$WORKFLOW_FILE"
printf 'LoRA     : %s\n' "$LORA_PATH"
printf 'Trigger  : pronmstr\n'
printf 'Strength : 0.80 (recommended adjustment: 0.70–0.85)\n'
printf 'Sampler  : 16 steps / Euler / Beta / CFG 1.0 / Shift 2.5\n'
printf 'Port     : %s\n' "$PORT"
printf 'Log      : %s\n' "$LOG"
printf '\nUse only clearly adult fictional subjects.\n'
