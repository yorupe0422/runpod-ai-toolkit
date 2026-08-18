#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="runpod_booth_animagine_character_lock_setup_v1"
BASE_DIR="/workspace/runpod-slim"
COMFY_DIR="${BASE_DIR}/ComfyUI-ZImage"
VENV_DIR="${COMFY_DIR}/.venv"
CUSTOM_DIR="${COMFY_DIR}/custom_nodes"
IPADAPTER_DIR="${CUSTOM_DIR}/comfyui-ipadapter"
MODEL_IPADAPTER_DIR="${COMFY_DIR}/models/ipadapter"
MODEL_CLIPVISION_DIR="${COMFY_DIR}/models/clip_vision"
MODEL_BG_DIR="${COMFY_DIR}/models/background_removal"
WORKFLOW_DIR="${COMFY_DIR}/user/default/workflows"
WORKFLOW_COPY_DIR="${BASE_DIR}/booth_workflows"
INPUT_DIR="${COMFY_DIR}/input"
LOG_DIR="${BASE_DIR}/.${SCRIPT_NAME}"
PHASE_DIR="${LOG_DIR}/phases"
LOG_FILE="${LOG_DIR}/setup.log"
PORT="8188"
HEARTBEAT=15

mkdir -p "${LOG_DIR}" "${PHASE_DIR}"

if [[ "${1:-}" == "--status" ]]; then
  echo "=== ${SCRIPT_NAME} status ==="
  [[ -f "${LOG_DIR}/worker.pid" ]] && echo "worker pid: $(cat "${LOG_DIR}/worker.pid")" || echo "worker pid: none"
  [[ -f "${LOG_FILE}" ]] && tail -n 80 "${LOG_FILE}" || true
  exit 0
fi

if [[ "${1:-}" == "--follow" ]]; then
  touch "${LOG_FILE}"
  tail -n 120 -F "${LOG_FILE}"
  exit 0
fi

if [[ "${1:-}" != "--worker" ]]; then
  mkdir -p "${LOG_DIR}"
  nohup "$0" --worker > "${LOG_FILE}" 2>&1 &
  echo $! > "${LOG_DIR}/worker.pid"
  echo "Started detached setup worker: PID $!"
  echo "Installer continues even if the browser terminal disconnects."
  echo "Log: ${LOG_FILE}"
  echo
  echo "Following setup log. Reconnect with:"
  echo "  ${BASE_DIR}/${SCRIPT_NAME}.sh --follow"
  echo
  tail -n +1 -F "${LOG_FILE}" --pid=$! || true
  exit 0
fi

exec > >(tee -a "${LOG_FILE}") 2>&1
trap 'echo "[FATAL] line ${LINENO}: command failed"' ERR

ts(){ date '+%Y-%m-%d %H:%M:%S'; }
section(){ echo; echo "================================================================"; echo "[$(ts)] $*"; echo "================================================================"; }

fmt_elapsed(){
  local sec="$1"
  printf '%02d:%02d:%02d' $((sec/3600)) $(((sec%3600)/60)) $((sec%60))
}

run_monitored(){
  local label="$1"; shift
  local phase_log="${PHASE_DIR}/$(echo "$label" | tr ' /:' '___').log"
  : > "${phase_log}"
  section "$label"
  echo "[INFO] phase log: ${phase_log}"
  local start now elapsed pid
  start=$(date +%s)
  ( "$@" >"${phase_log}" 2>&1 ) &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$HEARTBEAT"
    now=$(date +%s); elapsed=$((now-start))
    echo "[ALIVE] ${label} | elapsed=$(fmt_elapsed "$elapsed") | pid=${pid}"
    tail -n 8 "${phase_log}" | sed 's/^/[TAIL] /' || true
  done
  wait "$pid"
  now=$(date +%s); elapsed=$((now-start))
  echo "[OK] ${label} completed in $(fmt_elapsed "$elapsed")"
  tail -n 20 "${phase_log}" || true
}

need(){ command -v "$1" >/dev/null 2>&1 || { echo "[FATAL] missing command: $1"; exit 1; }; }

validate_safetensors(){
  local file="$1" min_bytes="$2" expected_sha="$3"
  python3 - "$file" "$min_bytes" "$expected_sha" <<'PY'
import hashlib, json, os, struct, sys
path, min_bytes, expected = sys.argv[1], int(sys.argv[2]), sys.argv[3]
if not os.path.exists(path): raise SystemExit(f"missing file: {path}")
size=os.path.getsize(path)
if size < min_bytes: raise SystemExit(f"file too small: {path} size={size}")
with open(path,'rb') as f:
    raw=f.read(8)
    if len(raw)!=8: raise SystemExit('invalid safetensors header')
    n=struct.unpack('<Q',raw)[0]
    if n <= 2 or n > 100_000_000: raise SystemExit(f'invalid safetensors header length {n}')
    header=f.read(n)
    json.loads(header)
h=hashlib.sha256()
with open(path,'rb') as f:
    for chunk in iter(lambda:f.read(8*1024*1024), b''): h.update(chunk)
sha=h.hexdigest()
if expected and sha.lower()!=expected.lower(): raise SystemExit(f'SHA256 mismatch for {path}: {sha}')
print(f"VALID SAFETENSORS: {path} size={size} sha256={sha}")
PY
}

download_resume(){
  local label="$1" url="$2" dest="$3" min_bytes="$4" sha="$5"
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" ]]; then
    if validate_safetensors "$dest" "$min_bytes" "$sha" >/dev/null 2>&1; then
      echo "[SKIP] Valid existing ${label}: ${dest}"
      return 0
    fi
    echo "[WARN] Existing ${label} is invalid; removing it."
    rm -f "$dest" "${dest}.aria2"
  fi
  run_monitored "Download ${label}" aria2c -x 8 -s 8 -k 1M --file-allocation=none --continue=true --allow-overwrite=true -d "$(dirname "$dest")" -o "$(basename "$dest")" "$url"
  validate_safetensors "$dest" "$min_bytes" "$sha"
}

restart_comfy(){
  section "Restart ComfyUI on port ${PORT}"
  local listener=""
  listener=$(lsof -tiTCP:${PORT} -sTCP:LISTEN 2>/dev/null | head -n1 || true)
  if [[ -n "$listener" ]]; then
    local cwd cmd
    cwd=$(readlink -f "/proc/${listener}/cwd" 2>/dev/null || true)
    cmd=$(tr '\0' ' ' < "/proc/${listener}/cmdline" 2>/dev/null || true)
    echo "Existing listener PID ${listener}"
    echo "cwd: ${cwd}"
    echo "cmd: ${cmd}"
    if [[ "$cwd" != "$COMFY_DIR" ]]; then
      echo "[FATAL] Port ${PORT} is owned by a different environment. Refusing to kill it."
      exit 1
    fi
    kill "$listener" || true
    for _ in {1..30}; do
      kill -0 "$listener" 2>/dev/null || break
      sleep 1
    done
  fi
  cd "$COMFY_DIR"
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  nohup python main.py --listen 0.0.0.0 --port "$PORT" --preview-method auto > comfyui_8188.log 2>&1 &
  local pid=$!
  echo "$pid" > comfyui_8188.pid
  echo "Started ComfyUI PID ${pid}"
  for i in {1..48}; do
    if curl -fsS "http://127.0.0.1:${PORT}/system_stats" >/dev/null 2>&1; then
      echo "[OK] ComfyUI HTTP ready on ${PORT}."
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || { echo "[FATAL] ComfyUI exited during startup"; tail -n 120 comfyui_8188.log; exit 1; }
    echo "[ALIVE] ComfyUI startup elapsed=$((i*5))s PID=${pid}"
    sleep 5
  done
  echo "[FATAL] ComfyUI did not become ready."
  tail -n 120 comfyui_8188.log || true
  exit 1
}

section "${SCRIPT_NAME} worker started"
echo "Purpose: add Animagine character-lock + expression variants + native BiRefNet transparent-PNG workflow."
echo "No image generation is performed by this setup script."

for c in git curl aria2c python3 lsof sha256sum; do need "$c"; done
[[ -d "$COMFY_DIR" ]] || { echo "[FATAL] missing ComfyUI: ${COMFY_DIR}"; exit 1; }
[[ -x "$VENV_DIR/bin/python" ]] || { echo "[FATAL] missing venv: ${VENV_DIR}"; exit 1; }
[[ -f "$COMFY_DIR/models/checkpoints/animagine-xl-4.0-opt.safetensors" ]] || { echo "[FATAL] Animagine XL 4.0 Opt is not installed."; exit 1; }
mkdir -p "$CUSTOM_DIR" "$MODEL_IPADAPTER_DIR" "$MODEL_CLIPVISION_DIR" "$MODEL_BG_DIR" "$WORKFLOW_DIR" "$WORKFLOW_COPY_DIR" "$INPUT_DIR" "$COMFY_DIR/output/booth_product" "$COMFY_DIR/output/booth_selected"

section "Install/update ComfyUI IPAdapter"
if [[ -d "$IPADAPTER_DIR/.git" ]]; then
  git -C "$IPADAPTER_DIR" fetch origin --prune
  git -C "$IPADAPTER_DIR" reset --hard origin/main
else
  rm -rf "$IPADAPTER_DIR"
  git clone https://github.com/comfyorg/comfyui-ipadapter.git "$IPADAPTER_DIR"
fi
echo "IPAdapter commit: $(git -C "$IPADAPTER_DIR" rev-parse HEAD)"

# Official h94/IP-Adapter SDXL Plus + ViT-H encoder.
download_resume "IP-Adapter Plus SDXL ViT-H" \
  "https://huggingface.co/h94/IP-Adapter/resolve/main/sdxl_models/ip-adapter-plus_sdxl_vit-h.safetensors" \
  "$MODEL_IPADAPTER_DIR/ip-adapter-plus_sdxl_vit-h.safetensors" \
  800000000 \
  "3f5062b8400c94b7159665b21ba5c62acdcd7682262743d7f2aefedef00e6581"

download_resume "CLIP ViT-H image encoder" \
  "https://huggingface.co/h94/IP-Adapter/resolve/main/models/image_encoder/model.safetensors" \
  "$MODEL_CLIPVISION_DIR/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors" \
  2400000000 \
  "6ca9667da1ca9e0b0f75e46bb030f7e011f44f86cbfb8d5a36590fcd7507b030"

# Native ComfyUI BiRefNet, MIT-licensed weights.
download_resume "Comfy-Org BiRefNet" \
  "https://huggingface.co/Comfy-Org/BiRefNet/resolve/main/background_removal/birefnet.safetensors" \
  "$MODEL_BG_DIR/birefnet.safetensors" \
  400000000 \
  "9ab37426bf4de0567af6b5d21b16151357149139362e6e8992021b8ce356a154"

section "Create production workflows and expression presets"
python3 - "$WORKFLOW_DIR" "$WORKFLOW_COPY_DIR" <<'PY'
import json, os, sys
wfdir, copydir = sys.argv[1], sys.argv[2]
os.makedirs(wfdir, exist_ok=True); os.makedirs(copydir, exist_ok=True)

base_positive = """1girl, solo, adult, 18 years old, university student, full body, standing, looking at viewer, light ash blonde hair, beige blonde hair, high ponytail, long side bangs, amber eyes, slightly sharp eyes, confident eyebrows, smug expression, mischievous smile, cheeky personality, oversized white hoodie, pink drawstrings, navy pleated mini skirt, black knee-high socks, white sneakers, black shoulder bag, clean anime game character design, visual novel character sprite, TRPG character standing illustration, clean lineart, polished cel shading, detailed eyes, detailed hair, full body, head to toe, both shoes visible, simple light background, masterpiece, high score, great score, absurdres"""
negative = """lowres, bad anatomy, bad hands, malformed hands, extra fingers, missing fingers, extra limbs, text, watermark, signature, cropped, out of frame, worst quality, low quality, low score, bad score, average score, blurry, child, loli, elementary school student, middle school student, toddler, photorealistic, photograph, 3d, multiple girls"""

# UI workflow helper
def N(i,t,pos,size,order,inputs=None,outputs=None,widgets=None,props=None):
    return {"id":i,"type":t,"pos":list(pos),"size":list(size),"flags":{},"order":order,"mode":0,
            "inputs":inputs or [],"outputs":outputs or [],"properties":props or {"Node name for S&R":t},"widgets_values":widgets or []}

def out(name,typ,links,slot=0):
    d={"name":name,"type":typ,"links":links,"slot_index":slot}
    return d

def inp(name,typ,link,slot=None):
    d={"name":name,"type":typ,"link":link}
    if slot is not None: d["slot_index"]=slot
    return d

nodes=[]
# 1 checkpoint
nodes.append(N(1,"CheckpointLoaderSimple",(0,470),(330,100),0,outputs=[out("MODEL","MODEL",[1],0),out("CLIP","CLIP",[2,3],1),out("VAE","VAE",[4,10],2)],widgets=["animagine-xl-4.0-opt.safetensors"]))
# 2 reference image
nodes.append(N(2,"LoadImage",(0,0),(330,390),1,outputs=[out("IMAGE","IMAGE",[5,6],0),out("MASK","MASK",[],1)],widgets=["booth_char01_reference.png","image"]))
# 3 unified loader
nodes.append(N(3,"IPAdapterUnifiedLoader",(410,430),(330,100),3,inputs=[inp("model","MODEL",1),inp("ipadapter","IPADAPTER",None)],outputs=[out("model","MODEL",[7],0),out("ipadapter","IPADAPTER",[8],1)],widgets=["PLUS (high strength)"]))
# 4 IPAdapter simple
nodes.append(N(4,"IPAdapter",(820,350),(330,180),7,inputs=[inp("model","MODEL",7),inp("ipadapter","IPADAPTER",8),inp("image","IMAGE",5,2),inp("attn_mask","MASK",None)],outputs=[out("MODEL","MODEL",[9],0)],widgets=[0.82,0.0,0.85]))
# 5 VAE Encode reference for low-denoise img2img
nodes.append(N(5,"VAEEncode",(410,20),(300,90),4,inputs=[inp("pixels","IMAGE",6),inp("vae","VAE",4)],outputs=[out("LATENT","LATENT",[11],0)]))
# 6 positive
nodes.append(N(6,"CLIPTextEncode",(410,600),(560,250),5,inputs=[inp("clip","CLIP",2)],outputs=[out("CONDITIONING","CONDITIONING",[12],0)],widgets=[base_positive]))
# 7 negative
nodes.append(N(7,"CLIPTextEncode",(410,890),(560,210),6,inputs=[inp("clip","CLIP",3)],outputs=[out("CONDITIONING","CONDITIONING",[13],0)],widgets=[negative]))
# 8 KSampler
nodes.append(N(8,"KSampler",(1040,560),(340,340),8,inputs=[inp("model","MODEL",9),inp("positive","CONDITIONING",12),inp("negative","CONDITIONING",13),inp("latent_image","LATENT",11)],outputs=[out("LATENT","LATENT",[14],0)],widgets=[0,"randomize",28,5.0,"euler_ancestral","normal",0.35]))
# 9 decode
nodes.append(N(9,"VAEDecode",(1450,600),(250,100),9,inputs=[inp("samples","LATENT",14),inp("vae","VAE",10)],outputs=[out("IMAGE","IMAGE",[15,16,17],0)]))
# 10 raw save
nodes.append(N(10,"SaveImage",(1780,760),(420,300),10,inputs=[inp("images","IMAGE",15)],widgets=["booth_selected/char01_raw"]))
# 11 bg model
nodes.append(N(11,"LoadBackgroundRemovalModel",(1760,420),(330,90),11,inputs=[{"name":"bg_removal_name","type":"COMBO","link":None}],outputs=[out("bg_model","BACKGROUND_REMOVAL",[18],0)],widgets=["birefnet.safetensors"],props={"Node name for S&R":"LoadBackgroundRemovalModel","models":[{"name":"birefnet.safetensors","url":"https://huggingface.co/Comfy-Org/BiRefNet/resolve/main/background_removal/birefnet.safetensors","directory":"background_removal"}]}))
# 12 remove bg -> mask
nodes.append(N(12,"RemoveBackground",(2140,420),(330,90),12,inputs=[inp("image","IMAGE",16),inp("bg_removal_model","BACKGROUND_REMOVAL",18)],outputs=[out("mask","MASK",[19],0)]))
# 13 invert mask
nodes.append(N(13,"InvertMask",(2510,420),(260,80),13,inputs=[inp("mask","MASK",19)],outputs=[out("MASK","MASK",[20],0)]))
# 14 alpha join
nodes.append(N(14,"JoinImageWithAlpha",(2820,520),(300,90),14,inputs=[inp("image","IMAGE",17),inp("alpha","MASK",20)],outputs=[out("IMAGE","IMAGE",[21],0)]))
# 15 png save
nodes.append(N(15,"SaveImage",(3180,480),(460,340),15,inputs=[inp("images","IMAGE",21)],widgets=["booth_product/char01_expression_rgba"]))

links=[
[1,1,0,3,0,"MODEL"],[2,1,1,6,0,"CLIP"],[3,1,1,7,0,"CLIP"],[4,1,2,5,1,"VAE"],[5,2,0,4,2,"IMAGE"],[6,2,0,5,0,"IMAGE"],[7,3,0,4,0,"MODEL"],[8,3,1,4,1,"IPADAPTER"],[9,4,0,8,0,"MODEL"],[10,1,2,9,1,"VAE"],[11,5,0,8,3,"LATENT"],[12,6,0,8,1,"CONDITIONING"],[13,7,0,8,2,"CONDITIONING"],[14,8,0,9,0,"LATENT"],[15,9,0,10,0,"IMAGE"],[16,9,0,12,0,"IMAGE"],[17,9,0,14,0,"IMAGE"],[18,11,0,12,1,"BACKGROUND_REMOVAL"],[19,12,0,13,0,"MASK"],[20,13,0,14,1,"MASK"],[21,14,0,15,0,"IMAGE"]]
wf={"last_node_id":15,"last_link_id":21,"nodes":nodes,"links":links,"groups":[],"config":{},"extra":{"ds":{"scale":0.7,"offset":[130,90]}},"version":0.4}

for name in ["booth_animagine_character_lock_expression_v1.json"]:
    for d in [wfdir,copydir]:
        p=os.path.join(d,name); json.dump(wf,open(p,'w',encoding='utf-8'),ensure_ascii=False,indent=2); print('WROTE',p)

# Second workflow: new-pose / outfit variants using EmptyLatentImage instead of VAEEncode.
import copy
pose=copy.deepcopy(wf)
# Replace node 5 with EmptyLatentImage and change link 11 source accordingly.
for idx,n in enumerate(pose['nodes']):
    if n['id']==5:
        pose['nodes'][idx]=N(5,"EmptyLatentImage",(410,20),(300,120),4,outputs=[out("LATENT","LATENT",[11],0)],widgets=[832,1216,1])
        break
pose['links']=[x for x in pose['links'] if x[0] not in (4,6)]
pose['links'].append([11,5,0,8,3,"LATENT"])
# avoid duplicate link 11 from original by reconstructing
seen=[]; new=[]
for x in pose['links']:
    if x[0] in seen: continue
    seen.append(x[0]); new.append(x)
pose['links']=new
# KSampler denoise must be 1.0 for empty latent
for n in pose['nodes']:
    if n['id']==8: n['widgets_values'][-1]=1.0
for d in [wfdir,copydir]:
    p=os.path.join(d,"booth_animagine_character_lock_pose_variant_v1.json"); json.dump(pose,open(p,'w',encoding='utf-8'),ensure_ascii=False,indent=2); print('WROTE',p)

expressions = {
"01_normal":"calm confident expression, slight smile",
"02_smug":"smug expression, mischievous smile, raised eyebrow",
"03_teasing":"teasing grin, cheeky eyes, playful expression",
"04_angry":"angry expression, furrowed brows, irritated eyes",
"05_pout":"pouting expression, annoyed, puffed cheeks",
"06_surprised":"surprised expression, wide eyes, slightly open mouth",
"07_flustered":"flustered expression, embarrassed, tense smile",
"08_blushing":"blushing, shy smile, averted gaze",
"09_crying":"crying expression, teary eyes, sad face",
"10_big_smile":"bright happy smile, cheerful eyes"
}
with open(os.path.join(copydir,'booth_char01_expression_prompts_v1.txt'),'w',encoding='utf-8') as f:
    f.write('BASE CHARACTER\n'+base_positive+'\n\n')
    f.write('NEGATIVE\n'+negative+'\n\n')
    f.write('EXPRESSION REPLACEMENTS\n')
    for k,v in expressions.items(): f.write(f'{k}: {v}\n')
    f.write('\nRecommended expression workflow starting points:\nIPAdapter weight 0.82, end_at 0.85, denoise 0.35.\nIf the face changes too much: denoise 0.25-0.30 or weight 0.9.\nIf expression barely changes: denoise 0.40-0.45 or end_at 0.75.\n')
print('WROTE expression preset')

with open(os.path.join(copydir,'REFERENCE_IMAGE_README.txt'),'w',encoding='utf-8') as f:
    f.write('Upload/copy the selected base character image into ComfyUI/input with this filename:\n')
    f.write('  booth_char01_reference.png\n\n')
    f.write('Then load booth_animagine_character_lock_expression_v1.json.\n')
    f.write('The setup script does NOT generate images and does NOT copy a reference image automatically.\n')
print('WROTE reference README')
PY

cat > "$WORKFLOW_COPY_DIR/MODEL_SOURCES_CHARACTER_LOCK.txt" <<'EOF_SRC'
Character-lock environment sources

1) ComfyUI IPAdapter
   https://github.com/comfyorg/comfyui-ipadapter
   Reference implementation for IPAdapter in ComfyUI.

2) IP-Adapter Plus SDXL ViT-H
   https://huggingface.co/h94/IP-Adapter
   file: sdxl_models/ip-adapter-plus_sdxl_vit-h.safetensors
   license shown on Hugging Face: Apache-2.0

3) CLIP ViT-H image encoder
   https://huggingface.co/h94/IP-Adapter
   source file: models/image_encoder/model.safetensors
   installed as: CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors

4) Comfy-Org BiRefNet
   https://huggingface.co/Comfy-Org/BiRefNet
   installed: models/background_removal/birefnet.safetensors
   license shown on Hugging Face / Comfy docs: MIT

5) Animagine XL 4.0 Opt
   Already installed in the base environment.
   https://huggingface.co/cagliostrolab/animagine-xl-4.0
   license shown on Hugging Face: OpenRAIL++

Note: The self-hosted BRIA RMBG-2.0 weights were intentionally NOT used because their Hugging Face license is non-commercial unless separately licensed. BiRefNet was chosen for the commercial BOOTH workflow instead.
EOF_SRC

restart_comfy

section "Verify required nodes and models (no image generation)"
python3 - "$PORT" <<'PY'
import json, sys, urllib.request
port=sys.argv[1]
obj=json.load(urllib.request.urlopen(f'http://127.0.0.1:{port}/object_info', timeout=30))
required=['CheckpointLoaderSimple','VAEEncode','KSampler','VAEDecode','IPAdapterUnifiedLoader','IPAdapter','LoadBackgroundRemovalModel','RemoveBackground','InvertMask','JoinImageWithAlpha','SaveImage']
missing=[x for x in required if x not in obj]
if missing: raise SystemExit('Missing required nodes: '+', '.join(missing))
print('ALL REQUIRED NODES PRESENT')
# Verify checkpoint visibility
ck=obj['CheckpointLoaderSimple']['input']['required']['ckpt_name'][0]
assert 'animagine-xl-4.0-opt.safetensors' in ck, 'Animagine checkpoint not visible'
print('[OK] Animagine checkpoint visible')
# Verify background removal model visibility
bg=obj['LoadBackgroundRemovalModel']['input']['required']['bg_removal_name'][0]
assert 'birefnet.safetensors' in bg, 'BiRefNet model not visible'
print('[OK] BiRefNet model visible')
PY

section "CHARACTER LOCK ENVIRONMENT READY"
echo "READY"
echo
echo "No image was generated by this setup."
echo
echo "Installed/updated:"
echo "  ${IPADAPTER_DIR}"
echo "  ${MODEL_IPADAPTER_DIR}/ip-adapter-plus_sdxl_vit-h.safetensors"
echo "  ${MODEL_CLIPVISION_DIR}/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors"
echo "  ${MODEL_BG_DIR}/birefnet.safetensors"
echo
echo "Workflows:"
echo "  ${WORKFLOW_COPY_DIR}/booth_animagine_character_lock_expression_v1.json"
echo "  ${WORKFLOW_COPY_DIR}/booth_animagine_character_lock_pose_variant_v1.json"
echo "  ${WORKFLOW_COPY_DIR}/booth_char01_expression_prompts_v1.txt"
echo "  ${WORKFLOW_COPY_DIR}/REFERENCE_IMAGE_README.txt"
echo
echo "Before using the expression workflow, place your chosen base image at:"
echo "  ${INPUT_DIR}/booth_char01_reference.png"
echo
echo "ComfyUI: port ${PORT}"
echo "Status: ${BASE_DIR}/${SCRIPT_NAME}.sh --status"
echo "Follow: ${BASE_DIR}/${SCRIPT_NAME}.sh --follow"
