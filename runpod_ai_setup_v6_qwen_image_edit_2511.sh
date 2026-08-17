#!/usr/bin/env bash
set -Eeuo pipefail

# RunPod one-shot installer: Qwen-Image-Edit-2511 for ComfyUI
# Installs four audited workflows: quality, Lightning, Anything2Real and AnyPose.

SCRIPT_VERSION="6.4.0-audit"

ROOT="${RUNPOD_ROOT:-/workspace/runpod-slim}"
COMFY="${COMFY_DIR:-$ROOT/ComfyUI}"
HF_HOME_V6="$ROOT/.cache/huggingface"
LOG="$ROOT/qwen_image_edit_2511_setup.log"
PORT="${RUNPOD_PORT:-8188}"
COMFY_REPO="https://github.com/Comfy-Org/ComfyUI.git"
COMFY_REMOTE="codex-v6-upstream"
COMFY_COMMIT="b963f4ad210a42841ab23dfc28a84143a0cce227"
WORKFLOW_COMMIT="dd4e7b844f1a7aa0dd4766618ba4d0f1512c8e87"
WORKFLOW_URL="https://raw.githubusercontent.com/Comfy-Org/workflow_templates/$WORKFLOW_COMMIT/templates/image_qwen_image_edit_2511.json"

QUALITY_WF="Qwen_Image_Edit_2511_QUALITY_40STEP.json"
FAST_WF="Qwen_Image_Edit_2511_LIGHTNING_4STEP.json"
A2R_WF="Qwen_Image_Edit_2511_ANYTHING2REAL_2601A.json"
ANYPOSE_WF="Qwen_Image_Edit_2511_ANYPOSE_4STEP.json"

MODEL_FILE="qwen_image_edit_2511_fp8mixed.safetensors"
CLIP_FILE="qwen_2.5_vl_7b_fp8_scaled.safetensors"
VAE_FILE="qwen_image_vae.safetensors"
LORA_FILE="Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"
A2R_FILE="anything2real_2601_A_final_patched.safetensors"
ANYPOSE_BASE_FILE="2511-AnyPose-base-000006250.safetensors"
ANYPOSE_HELPER_FILE="2511-AnyPose-helper-00006000.safetensors"

export HF_HOME="$HF_HOME_V6"
export HF_HUB_ENABLE_HF_TRANSFER=0
export HF_HUB_DOWNLOAD_TIMEOUT=120
export HF_HUB_ETAG_TIMEOUT=30
export PYTHONUNBUFFERED=1

mkdir -p "$ROOT"
exec > >(tee -a "$LOG") 2>&1

die() { echo "[FATAL] $*" >&2; exit 1; }
step() { echo; echo "===== $* ====="; }

TMP_WF=""
OBJECT_INFO=""
cleanup_temps() {
  [[ -z "${TMP_WF:-}" ]] || rm -f "$TMP_WF" "${TMP_WF}.part" || true
  [[ -z "${OBJECT_INFO:-}" ]] || rm -f "$OBJECT_INFO" || true
}

on_error() {
  local code=$?
  echo
  echo "SETUP #6 FAILED (exit=$code, line=${BASH_LINENO[0]})"
  echo "Log: $LOG"
  exit "$code"
}
trap on_error ERR
trap cleanup_temps EXIT

step "SETUP #6 — QWEN IMAGE EDIT 2511"
echo "Installer version: $SCRIPT_VERSION"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || \
  die "RUNPOD_PORT must be an integer from 1 to 65535"
command -v nvidia-smi >/dev/null || die "NVIDIA driver/GPU not found"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
gpu_mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -dc '0-9')"
[[ -n "$gpu_mib" ]] || die "Could not read GPU VRAM"
(( gpu_mib >= 24000 )) || die "At least 24 GB VRAM is required; detected ${gpu_mib} MiB"

step "[1/10] System tools"
if ! command -v git >/dev/null || ! command -v curl >/dev/null || \
   ! command -v sha256sum >/dev/null || ! command -v pkill >/dev/null; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git curl ca-certificates coreutils procps
fi
for cmd in git curl sha256sum stat df awk grep tee mktemp pkill; do
  command -v "$cmd" >/dev/null || die "Required system command not found: $cmd"
done

step "[2/10] ComfyUI core (pinned and reproducible)"
if [[ ! -d "$COMFY/.git" ]]; then
  [[ ! -e "$COMFY" ]] || die "$COMFY exists but is not a git checkout; move it aside and rerun"
  git clone --filter=blob:none "$COMFY_REPO" "$COMFY"
fi
if git -C "$COMFY" remote get-url "$COMFY_REMOTE" >/dev/null 2>&1; then
  git -C "$COMFY" remote set-url "$COMFY_REMOTE" "$COMFY_REPO"
else
  git -C "$COMFY" remote add "$COMFY_REMOTE" "$COMFY_REPO"
fi
git -C "$COMFY" fetch --prune --filter=blob:none "$COMFY_REMOTE" master

# Always converge on the exact audited core commit. Preserve the prior commit
# as a local branch first; never overwrite tracked user edits.
if [[ -n "$(git -C "$COMFY" status --porcelain --untracked-files=no)" ]]; then
  die "ComfyUI has tracked local changes; refusing to overwrite them"
fi
git -C "$COMFY" cat-file -e "$COMFY_COMMIT^{commit}" 2>/dev/null || \
  die "Pinned ComfyUI commit is unavailable after fetching $COMFY_REPO"
old_sha="$(git -C "$COMFY" rev-parse --short=12 HEAD)"
backup_branch="codex-v6-backup-$old_sha"
git -C "$COMFY" show-ref --verify --quiet "refs/heads/$backup_branch" || \
  git -C "$COMFY" branch "$backup_branch" HEAD
git -C "$COMFY" switch -C codex-v6 "$COMFY_COMMIT"
[[ "$(git -C "$COMFY" rev-parse HEAD)" == "$COMFY_COMMIT" ]] || die "ComfyUI commit verification failed"
echo "[OK] ComfyUI pinned at $COMFY_COMMIT (previous: $backup_branch)"

# Fail before Python packages and 32 GB of models are downloaded if the pinned
# core no longer has the exact nodes or CLI flags required by these workflows.
grep -Fq 'TextEncodeQwenImageEditPlus' "$COMFY/comfy_extras/nodes_qwen.py" || \
  die "Pinned ComfyUI core lacks TextEncodeQwenImageEditPlus"
grep -Fq 'FluxKontextMultiReferenceLatentMethod' "$COMFY/comfy_extras/nodes_flux.py" || \
  die "Pinned ComfyUI core lacks FluxKontextMultiReferenceLatentMethod"
grep -Fq 'ComfySwitchNode' "$COMFY/comfy_extras/nodes_logic.py" || \
  die "Pinned ComfyUI core lacks ComfySwitchNode"
for flag in '--reserve-vram' '--cache-none' '--disable-all-custom-nodes'; do
  grep -Fq -- "$flag" "$COMFY/comfy/cli_args.py" || die "Pinned ComfyUI core lacks CLI flag: $flag"
done
echo "[OK] Required core nodes and launch flags verified"

step "[3/10] Dedicated Python environment"
BASE_PYTHON="$(command -v python3 || true)"
[[ -n "$BASE_PYTHON" && -x "$BASE_PYTHON" ]] || die "python3 not found"
"$BASE_PYTHON" -c 'import sys; assert sys.version_info >= (3, 10)' 2>/dev/null || \
  die "Python 3.10 or newer is required"
VENV="$ROOT/.venv-qwen-image-edit-2511"
PYTHON_BIN="$VENV/bin/python"
if [[ -e "$VENV" ]] && ! "$PYTHON_BIN" -c 'import sys; assert sys.prefix != sys.base_prefix' >/dev/null 2>&1; then
  broken_venv="$VENV.broken.$(date +%Y%m%d%H%M%S)"
  mv "$VENV" "$broken_venv"
  echo "[WARN] Invalid old venv preserved at $broken_venv"
fi
if [[ ! -x "$PYTHON_BIN" ]]; then
  "$BASE_PYTHON" -m venv --system-site-packages "$VENV" || {
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv
    "$BASE_PYTHON" -m venv --system-site-packages "$VENV"
  }
fi
"$PYTHON_BIN" -c 'import sys; assert sys.prefix != sys.base_prefix; assert sys.version_info >= (3, 10)' || \
  die "Dedicated Python environment validation failed"
"$PYTHON_BIN" -m ensurepip --upgrade >/dev/null 2>&1 || true
"$PYTHON_BIN" -m pip --version >/dev/null 2>&1 || die "pip is unavailable in the dedicated Python environment"
echo "[OK] Python: $PYTHON_BIN ($("$PYTHON_BIN" -c 'import sys; print(sys.version.split()[0])'))"
"$PYTHON_BIN" -m pip install -U pip setuptools wheel
"$PYTHON_BIN" -m pip install -r "$COMFY/requirements.txt"
"$PYTHON_BIN" -m pip install -U huggingface_hub hf_xet

step "[4/10] Model directories"
mkdir -p \
  "$COMFY/models/diffusion_models" \
  "$COMFY/models/text_encoders" \
  "$COMFY/models/vae" \
  "$COMFY/models/loras" \
  "$COMFY/input" \
  "$COMFY/user/default/workflows"

expected_sizes=(20533762817 9384670680 253806246 849608296 613580128 295146208 295146216)
expected_shas=(
  "c9fdc158e46d3b61ef75f21ae866ca2fe808bf4a53643120d1c1e87c19280a4e"
  "cb5636d852a0ea6a9075ab1bef496c0db7aef13c02350571e388aea959c5c0b4"
  "a70580f0213e67967ee9c95f05bb400e8fb08307e017a924bf3441223e023d1f"
  "22226e8d05d354bb356627d428809f5afd7819399b077238a2b70a82883a904f"
  "d4cbbabf5610a8f0ea3f530dc0bc9e8a254be6563c4738795bea45d247903528"
  "0396314e43b94f7520cf5242e6aa6e8e9095d784f7e87ee45980c2e541ee8c4d"
  "674340c62fff3cf981d0cfc55daf2f0e6f51c56b50159e241d931748200cf1eb"
)
expected_paths=(
  "$COMFY/models/diffusion_models/$MODEL_FILE"
  "$COMFY/models/text_encoders/$CLIP_FILE"
  "$COMFY/models/vae/$VAE_FILE"
  "$COMFY/models/loras/$LORA_FILE"
  "$COMFY/models/loras/$A2R_FILE"
  "$COMFY/models/loras/$ANYPOSE_BASE_FILE"
  "$COMFY/models/loras/$ANYPOSE_HELPER_FILE"
)
needed_bytes=5000000000
for i in "${!expected_paths[@]}"; do
  actual=0
  actual_sha=""
  [[ -f "${expected_paths[$i]}" ]] && actual="$(stat -c '%s' "${expected_paths[$i]}")"
  if [[ "$actual" == "${expected_sizes[$i]}" ]]; then
    actual_sha="$(sha256sum "${expected_paths[$i]}" | awk '{print $1}')"
  fi
  if [[ "$actual" != "${expected_sizes[$i]}" || "$actual_sha" != "${expected_shas[$i]}" ]]; then
    needed_bytes=$((needed_bytes + ${expected_sizes[$i]}))
  fi
done
available_bytes="$(df -PB1 "$ROOT" | awk 'NR==2 {print $4}')"
[[ "$available_bytes" =~ ^[0-9]+$ ]] || die "Could not determine free disk space"
(( available_bytes >= needed_bytes )) || \
  die "Insufficient disk space: need about $((needed_bytes / 1000000000)) GB free, have $((available_bytes / 1000000000)) GB"
echo "[OK] Disk preflight: $((available_bytes / 1000000000)) GB free"

download_hf() {
  local repo="$1" revision="$2" remote="$3" dest="$4" expected_size="$5" expected_sha="$6"
  local actual_size="0" actual_sha=""
  [[ -f "$dest" ]] && actual_size="$(stat -c '%s' "$dest")"
  if [[ "$actual_size" == "$expected_size" ]]; then
    actual_sha="$(sha256sum "$dest" | awk '{print $1}')"
  fi
  if [[ "$actual_size" == "$expected_size" && "$actual_sha" == "$expected_sha" ]]; then
    echo "[SKIP] $(basename "$dest") verified"
    return 0
  fi
  rm -f "${dest}.part"
  echo "[DOWNLOAD] $repo :: $remote"
  REPO="$repo" REVISION="$revision" REMOTE="$remote" DEST="$dest" \
  EXPECTED_SIZE="$expected_size" EXPECTED_SHA="$expected_sha" "$PYTHON_BIN" - <<'PY'
import hashlib, os, shutil
from huggingface_hub import hf_hub_download
repo, remote, dest = os.environ["REPO"], os.environ["REMOTE"], os.environ["DEST"]
revision = os.environ["REVISION"]
expected_size = int(os.environ["EXPECTED_SIZE"])
expected_sha = os.environ["EXPECTED_SHA"]
def verified_download(force=False):
    src = hf_hub_download(repo_id=repo, filename=remote, revision=revision,
                          force_download=force)
    real = os.path.realpath(src)
    actual_size = os.path.getsize(real)
    h = hashlib.sha256()
    with open(real, "rb") as f:
        for block in iter(lambda: f.read(16 * 1024 * 1024), b""):
            h.update(block)
    return real, actual_size, h.hexdigest()

real, actual_size, actual_sha = verified_download(False)
if actual_size != expected_size or actual_sha != expected_sha:
    print("[WARN] Cached file failed verification; forcing a clean re-download")
    real, actual_size, actual_sha = verified_download(True)
if actual_size != expected_size:
    raise RuntimeError(f"size mismatch: expected {expected_size}, got {actual_size}")
if actual_sha != expected_sha:
    raise RuntimeError(f"SHA256 mismatch: expected {expected_sha}, got {actual_sha}")
part = dest + ".part"
os.makedirs(os.path.dirname(dest), exist_ok=True)
try:
    os.link(real, part)
except OSError:
    shutil.copy2(real, part)
os.replace(part, dest)
print(f"[OK] {os.path.basename(dest)} ({os.path.getsize(dest):,} bytes)")
PY
}

step "[5/10] Qwen-Image-Edit-2511 models"
download_hf "Comfy-Org/Qwen-Image-Edit_ComfyUI" \
  "272e47a0dc9a56fd607dbf48a8cbd2af68f27007" \
  "split_files/diffusion_models/$MODEL_FILE" \
  "$COMFY/models/diffusion_models/$MODEL_FILE" 20533762817 \
  "c9fdc158e46d3b61ef75f21ae866ca2fe808bf4a53643120d1c1e87c19280a4e"
download_hf "Comfy-Org/HunyuanVideo_1.5_repackaged" \
  "5d6f0b4fdd4100acda997de86dbda335578c0d0e" \
  "split_files/text_encoders/$CLIP_FILE" \
  "$COMFY/models/text_encoders/$CLIP_FILE" 9384670680 \
  "cb5636d852a0ea6a9075ab1bef496c0db7aef13c02350571e388aea959c5c0b4"
download_hf "Comfy-Org/Qwen-Image_ComfyUI" \
  "7af1e265fb79c25d43669aea93aa5c51d7ad23e8" \
  "split_files/vae/$VAE_FILE" \
  "$COMFY/models/vae/$VAE_FILE" 253806246 \
  "a70580f0213e67967ee9c95f05bb400e8fb08307e017a924bf3441223e023d1f"
download_hf "lightx2v/Qwen-Image-Edit-2511-Lightning" \
  "d74eba145674fd7e31b949324e148e21e7118abd" \
  "$LORA_FILE" \
  "$COMFY/models/loras/$LORA_FILE" 849608296 \
  "22226e8d05d354bb356627d428809f5afd7819399b077238a2b70a82883a904f"
download_hf "lrzjason/Anything2Real" \
  "b547e090d255ac10b190204c7868b03a61faf15e" \
  "$A2R_FILE" \
  "$COMFY/models/loras/$A2R_FILE" 613580128 \
  "d4cbbabf5610a8f0ea3f530dc0bc9e8a254be6563c4738795bea45d247903528"
download_hf "lilylilith/AnyPose" \
  "27c4b1f7688940d39767e652fe8d87faf44a0881" \
  "$ANYPOSE_BASE_FILE" \
  "$COMFY/models/loras/$ANYPOSE_BASE_FILE" 295146208 \
  "0396314e43b94f7520cf5242e6aa6e8e9095d784f7e87ee45980c2e541ee8c4d"
download_hf "lilylilith/AnyPose" \
  "27c4b1f7688940d39767e652fe8d87faf44a0881" \
  "$ANYPOSE_HELPER_FILE" \
  "$COMFY/models/loras/$ANYPOSE_HELPER_FILE" 295146216 \
  "674340c62fff3cf981d0cfc55daf2f0e6f51c56b50159e241d931748200cf1eb"

step "[6/10] Official workflow and sample inputs"
TMP_WF="$(mktemp)"
download_url_atomic() {
  local url="$1" dest="$2" expected_sha="$3" part="${2}.part" actual_sha
  rm -f "$part"
  curl -fL --retry 8 --retry-all-errors --connect-timeout 20 \
    "$url" -o "$part"
  [[ -s "$part" ]] || die "Downloaded file is empty: $url"
  actual_sha="$(sha256sum "$part" | awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]] || \
    die "Checksum mismatch for $(basename "$dest"): expected $expected_sha, got $actual_sha"
  mv -f "$part" "$dest"
}
download_url_atomic "$WORKFLOW_URL" "$TMP_WF" \
  "d561a38c15bd7d08758a5e6773d467142244d5b83fc5d3aecdf6d8df9fe881b6"
"$PYTHON_BIN" -m json.tool "$TMP_WF" >/dev/null

download_url_atomic \
  "https://raw.githubusercontent.com/Comfy-Org/workflow_templates/$WORKFLOW_COMMIT/input/leather_sofa.png" \
  "$COMFY/input/leather_sofa.png" \
  "be4387e734f14c5bad3f1328c1731d4ac6f85b9517566c4ddfb1d448d96d51c4"
download_url_atomic \
  "https://raw.githubusercontent.com/Comfy-Org/workflow_templates/$WORKFLOW_COMMIT/input/texture_fur.png" \
  "$COMFY/input/texture_fur.png" \
  "6e837f6780f1b1e5674eab24f828ac2920e27eb8f9f7ae83583b77d057d7dc78"

TEMPLATE="$TMP_WF" OUT_QUALITY="$COMFY/user/default/workflows/$QUALITY_WF" \
OUT_FAST="$COMFY/user/default/workflows/$FAST_WF" \
OUT_A2R="$COMFY/user/default/workflows/$A2R_WF" \
OUT_ANYPOSE="$COMFY/user/default/workflows/$ANYPOSE_WF" "$PYTHON_BIN" - <<'PY'
import copy, json, os

with open(os.environ["TEMPLATE"], encoding="utf-8") as f:
    base = json.load(f)

LIGHTNING = "Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"
A2R = "anything2real_2601_A_final_patched.safetensors"
POSE_BASE = "2511-AnyPose-base-000006250.safetensors"
POSE_HELPER = "2511-AnyPose-helper-00006000.safetensors"

def find_node(sg, node_id):
    return next(n for n in sg["nodes"] if n.get("id") == node_id)

def add_anypose_chain(sg):
    lightning = find_node(sg, 153)
    switch = find_node(sg, 163)
    link332 = next(x for x in sg["links"] if x["id"] == 332)
    link332["target_id"], link332["target_slot"] = 195, 0

    base = copy.deepcopy(lightning)
    base["id"] = 195
    base["pos"] = [base["pos"][0] + 430, base["pos"][1] - 180]
    base["title"] = "AnyPose base — strength 0.7"
    base["inputs"][0]["link"] = 332
    base["outputs"][0]["links"] = [388]
    base["widgets_values"] = [POSE_BASE, 0.7]

    helper = copy.deepcopy(lightning)
    helper["id"] = 196
    helper["pos"] = [helper["pos"][0] + 850, helper["pos"][1] - 180]
    helper["title"] = "AnyPose helper — strength 0.7"
    helper["inputs"][0]["link"] = 388
    helper["outputs"][0]["links"] = [389]
    helper["widgets_values"] = [POSE_HELPER, 0.7]

    sg["nodes"].extend([base, helper])
    sg["links"].extend([
        {"id": 388, "origin_id": 195, "origin_slot": 0,
         "target_id": 196, "target_slot": 0, "type": "MODEL"},
        {"id": 389, "origin_id": 196, "origin_slot": 0,
         "target_id": 163, "target_slot": 1, "type": "MODEL"},
    ])
    switch["inputs"][1]["link"] = 389
    sg["state"]["lastNodeId"] = max(int(sg["state"].get("lastNodeId", 0)), 196)
    sg["state"]["lastLinkId"] = max(int(sg["state"].get("lastLinkId", 0)), 389)

def configure(data, variant):
    data = copy.deepcopy(data)
    found = {"bool": False, "unet": False, "clip": False, "vae": False, "lora": False}
    for sg in data.get("definitions", {}).get("subgraphs", []):
        for node in sg.get("nodes", []):
            t = node.get("type")
            if t == "PrimitiveBoolean" and node.get("id") == 168:
                node["widgets_values"] = [variant in ("fast", "anypose")]; found["bool"] = True
            elif t == "UNETLoader":
                node["widgets_values"][0] = "qwen_image_edit_2511_fp8mixed.safetensors"; found["unet"] = True
            elif t == "CLIPLoader":
                node["widgets_values"][0] = "qwen_2.5_vl_7b_fp8_scaled.safetensors"; found["clip"] = True
            elif t == "VAELoader":
                node["widgets_values"][0] = "qwen_image_vae.safetensors"; found["vae"] = True
            elif t == "LoraLoaderModelOnly":
                node["widgets_values"][0] = A2R if variant == "a2r" else LIGHTNING
                node["widgets_values"][1] = 0.85 if variant == "a2r" else 1.0
                found["lora"] = True
            if node.get("id") == 151 and t == "TextEncodeQwenImageEditPlus":
                if variant == "a2r":
                    node["widgets_values"] = [
                        "Change image 1 into a realistic photograph while preserving the original composition, pose, identity, clothing, objects and camera angle. Natural light, realistic skin and materials, photographic detail."
                    ]
                elif variant == "anypose":
                    node["widgets_values"] = [
                        "Make the person in image 1 do the exact same pose as the person in image 2. Preserve the identity, clothing, style and background of image 1. Match the arms, hands, head, legs, camera angle, head tilt and eye gaze of image 2. Remove the background of image 2 and keep the background of image 1."
                    ]
        if variant == "a2r":
            # Apply A2R on the non-turbo branch while retaining official 40-step settings.
            lora = find_node(sg, 153)
            source = find_node(sg, 152)
            link331 = next(x for x in sg["links"] if x["id"] == 331)
            link331["origin_id"], link331["origin_slot"] = 153, 0
            lora["outputs"][0]["links"] = sorted(set(lora["outputs"][0].get("links", []) + [331]))
            source["outputs"][0]["links"] = [x for x in source["outputs"][0].get("links", []) if x != 331]
        elif variant == "anypose":
            add_anypose_chain(sg)
    missing = [k for k, v in found.items() if not v]
    if missing:
        raise RuntimeError("Official workflow structure changed; missing: " + ", ".join(missing))
    if variant == "a2r":
        # A2R uses only image 1; disconnect the material-reference sample image.
        data["links"] = [x for x in data.get("links", []) if x[0] != 377]
        for node in data.get("nodes", []):
            if node.get("id") == 170:
                node["inputs"][1]["link"] = None
            elif node.get("id") == 83:
                node["outputs"][0]["links"] = [
                    x for x in (node["outputs"][0].get("links") or []) if x != 377
                ] or None
            elif node.get("id") == 9:
                node["widgets_values"] = ["Qwen_Edit_2511_Anything2Real"]
    elif variant == "anypose":
        for node in data.get("nodes", []):
            if node.get("id") == 9:
                node["widgets_values"] = ["Qwen_Edit_2511_AnyPose"]
    data["id"] = "qwen-image-edit-2511-" + variant
    return data

def validate_graph(nodes, links, allow_virtual=False):
    node_ids = {n["id"] for n in nodes}
    if allow_virtual:
        node_ids.update((-10, -20))
    link_ids = set()
    for link in links:
        if isinstance(link, dict):
            lid, origin, target = link["id"], link["origin_id"], link["target_id"]
        else:
            lid, origin, target = link[0], link[1], link[3]
        if lid in link_ids:
            raise RuntimeError(f"duplicate link id: {lid}")
        link_ids.add(lid)
        if origin not in node_ids or target not in node_ids:
            raise RuntimeError(f"link {lid} references missing node: {origin}->{target}")
    for node in nodes:
        for inp in node.get("inputs", []):
            lid = inp.get("link")
            if lid is not None and lid not in link_ids:
                raise RuntimeError(f"node {node['id']} input references missing link {lid}")
        for out in node.get("outputs", []):
            for lid in out.get("links") or []:
                if lid not in link_ids:
                    raise RuntimeError(f"node {node['id']} output references missing link {lid}")

def validate_workflow(data, variant):
    validate_graph(data.get("nodes", []), data.get("links", []))
    subgraphs = data.get("definitions", {}).get("subgraphs", [])
    if len(subgraphs) != 1:
        raise RuntimeError(f"expected exactly one subgraph, found {len(subgraphs)}")
    sg = subgraphs[0]
    validate_graph(sg.get("nodes", []), sg.get("links", []), allow_virtual=True)
    types = {n.get("type") for n in sg["nodes"]}
    required = {"TextEncodeQwenImageEditPlus", "UNETLoader", "CLIPLoader",
                "VAELoader", "LoraLoaderModelOnly", "KSampler"}
    if required - types:
        raise RuntimeError("workflow missing types: " + ", ".join(sorted(required - types)))
    loras = [n["widgets_values"][0] for n in sg["nodes"] if n.get("type") == "LoraLoaderModelOnly"]
    expected = {
        "quality": [LIGHTNING], "fast": [LIGHTNING], "a2r": [A2R],
        "anypose": [LIGHTNING, POSE_BASE, POSE_HELPER],
    }[variant]
    if loras != expected:
        raise RuntimeError(f"{variant} LoRA chain mismatch: {loras}")
    turbo = find_node(sg, 168)["widgets_values"][0]
    if turbo != (variant in ("fast", "anypose")):
        raise RuntimeError(f"{variant} turbo setting mismatch")

outputs = (
    (os.environ["OUT_QUALITY"], "quality"),
    (os.environ["OUT_FAST"], "fast"),
    (os.environ["OUT_A2R"], "a2r"),
    (os.environ["OUT_ANYPOSE"], "anypose"),
)
for path, variant in outputs:
    configured = configure(base, variant)
    validate_workflow(configured, variant)
    with open(path + ".part", "w", encoding="utf-8") as f:
        json.dump(configured, f, ensure_ascii=False, indent=2)
    os.replace(path + ".part", path)
    print("[OK]", os.path.basename(path))
PY
rm -f "$TMP_WF"

step "[7/10] Static validation"
for f in \
  "$COMFY/models/diffusion_models/$MODEL_FILE" \
  "$COMFY/models/text_encoders/$CLIP_FILE" \
  "$COMFY/models/vae/$VAE_FILE" \
  "$COMFY/models/loras/$LORA_FILE" \
  "$COMFY/models/loras/$A2R_FILE" \
  "$COMFY/models/loras/$ANYPOSE_BASE_FILE" \
  "$COMFY/models/loras/$ANYPOSE_HELPER_FILE" \
  "$COMFY/user/default/workflows/$QUALITY_WF" \
  "$COMFY/user/default/workflows/$FAST_WF" \
  "$COMFY/user/default/workflows/$A2R_WF" \
  "$COMFY/user/default/workflows/$ANYPOSE_WF"; do
  [[ -s "$f" ]] || die "Missing or empty: $f"
done

step "[8/10] Stop previous ComfyUI on port $PORT"
if command -v fuser >/dev/null 2>&1; then
  fuser -k "${PORT}/tcp" 2>/dev/null || true
else
  pkill -f "[p]ython.*main.py.*--port[ =]$PORT" 2>/dev/null || true
fi
sleep 2

step "[9/10] Start ComfyUI"
cd "$COMFY"
nohup "$PYTHON_BIN" main.py \
  --listen 0.0.0.0 \
  --port "$PORT" \
  --preview-method auto \
  --reserve-vram 4 \
  --cache-none \
  --disable-all-custom-nodes \
  > "$ROOT/comfyui_qwen2511.log" 2>&1 &
echo $! > "$ROOT/comfyui_qwen2511.pid"

OBJECT_INFO="$(mktemp)"
ready=0
for _ in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:$PORT/object_info" -o "$OBJECT_INFO" 2>/dev/null; then
    ready=1; break
  fi
  if ! kill -0 "$(cat "$ROOT/comfyui_qwen2511.pid")" 2>/dev/null; then
    tail -120 "$ROOT/comfyui_qwen2511.log" || true
    die "ComfyUI exited during startup"
  fi
  sleep 2
done
[[ "$ready" == 1 ]] || { tail -120 "$ROOT/comfyui_qwen2511.log" || true; die "ComfyUI did not become ready"; }

step "[10/10] Runtime node validation"
OBJECT_INFO="$OBJECT_INFO" "$PYTHON_BIN" - <<'PY'
import json, os
with open(os.environ["OBJECT_INFO"], encoding="utf-8") as f:
    nodes = json.load(f)
required = [
    "TextEncodeQwenImageEditPlus", "FluxKontextMultiReferenceLatentMethod",
    "FluxKontextImageScale", "ModelSamplingAuraFlow", "CFGNorm",
    "ComfySwitchNode", "PrimitiveBoolean", "PrimitiveFloat", "PrimitiveInt",
    "UNETLoader", "CLIPLoader", "VAELoader", "LoraLoaderModelOnly",
    "KSampler", "VAEDecode", "VAEEncode", "SaveImage"
]
missing = [x for x in required if x not in nodes]
if missing:
    raise SystemExit("Missing required runtime nodes: " + ", ".join(missing))
serialized = json.dumps(nodes, ensure_ascii=False)
required_models = [
    "qwen_image_edit_2511_fp8mixed.safetensors",
    "qwen_2.5_vl_7b_fp8_scaled.safetensors",
    "qwen_image_vae.safetensors",
    "Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors",
    "anything2real_2601_A_final_patched.safetensors",
    "2511-AnyPose-base-000006250.safetensors",
    "2511-AnyPose-helper-00006000.safetensors",
]
undetected = [x for x in required_models if x not in serialized]
if undetected:
    raise SystemExit("ComfyUI did not index required models: " + ", ".join(undetected))
print("[OK] All required Qwen-Image-Edit-2511 nodes are loaded")
print("[OK] All required models are indexed by ComfyUI")
PY
rm -f "$OBJECT_INFO"

echo
echo "============================================================"
echo "SETUP #6 COMPLETE — GENERATION READY"
echo "ComfyUI: http://127.0.0.1:$PORT"
echo "QUALITY : $QUALITY_WF"
echo "FAST    : $FAST_WF"
echo "A2R     : $A2R_WF"
echo "ANYPOSE : $ANYPOSE_WF"
echo "Mode    : audited core nodes only (unrelated custom nodes are disabled)"
echo "Replace the sample image(s), enter your edit prompt, and run."
echo "============================================================"
