#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# PATCH #2 v1 — MiniMax H3 Fused environment
# Adds:
#   03_H3_REF2VA_PDD_8STEP_4REF.json
#   04_H3_REF2VA_TURBO8_768P_4REF.json
#
# Target:
#   /workspace/runpod-slim/ComfyUI-H3-Fused
#
# Safety:
#   - Existing 01/02 workflows are NOT modified.
#   - Existing fused checkpoint is NOT modified.
#   - Downloads one clean Ref2VA INT8 ConvRot base shared by PDD/Turbo8 tests.
#   - PDD is kept separate from the baked Turbo model, as required.
# =============================================================================

ROOT="${ROOT:-/workspace/runpod-slim}"
COMFY="${COMFY:-$ROOT/ComfyUI-H3-Fused}"
PORT="${PORT:-8188}"
PY="$COMFY/.venv/bin/python"
PIP="$COMFY/.venv/bin/pip"
WF_DIR="$COMFY/user/default/workflows"
LOG_DIR="$COMFY/setup_logs"
PATCH_LOG="$LOG_DIR/patch_pdd_turbo8_$(date +%Y%m%d_%H%M%S).log"

BASE_MODEL="minimax_h3_ref2va_int8_convrot.safetensors"
PDD_FILE="minimax_h3_ref2va_pdd_acc_8step_comfyui.safetensors"
TURBO_FILE="minimax_h3_ref2v_turbo_8step_v1.0_768p_comfyui_bf16.safetensors"

BASE_URL="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/diffusion_models/$BASE_MODEL?download=true"
PDD_URL="https://huggingface.co/aptech0081/MiniMax-H3-Acc-LoRAs-ComfyUI/resolve/main/$PDD_FILE?download=true"
TURBO_URL="https://huggingface.co/lightx2v/Minimax-h3-Turbo/resolve/main/$TURBO_FILE?download=true"

BASE_SHA="9eef934046a0671bc8a5daf87100705e1478419c574cfde70c50fbe6885f76a9"
PDD_SHA="5531fa0da887c24ec0083b0050ea9e4ff03c479cfbe21ef586d1c5c79bdc78a1"
TURBO_SHA="6a56f41ab4229c9dd845b9501bbd475ee57e112d846cf2e819d534a1ae928c5a"

PDD_NODE_REPO="https://github.com/Jalen-Brunson/ComfyUI-MiniMax-H3-PDD-Acc.git"
PDD_EXAMPLE_URL="https://raw.githubusercontent.com/Jalen-Brunson/ComfyUI-MiniMax-H3-PDD-Acc/main/example_workflows/pdd_acc_t2v_basic.json"
R2V_TEMPLATE_URL="https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/video_minimax_h3_r2v.json"

WF_PDD="$WF_DIR/03_H3_REF2VA_PDD_8STEP_4REF.json"
WF_TURBO="$WF_DIR/04_H3_REF2VA_TURBO8_768P_4REF.json"

green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[0;33m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
die(){ red "[FAILED] $*"; exit 1; }

on_error(){
  rc=$?
  red ""
  red "PATCH FAILED (rc=$rc, line=${BASH_LINENO[0]:-unknown})"
  red "Existing #2 files were not intentionally overwritten."
  exit "$rc"
}
trap on_error ERR

echo "================================================================="
echo " #2 PATCH v1 — PDD 8-step + Ref2VA Turbo8 768p"
echo "================================================================="

[[ -d "$COMFY/.git" ]] || die "Target #2 not found: $COMFY"
[[ -x "$PY" ]] || die "Python venv not found: $PY"
mkdir -p "$WF_DIR" "$LOG_DIR" "$COMFY/models/pdd_acc" "$COMFY/models/loras" "$COMFY/models/diffusion_models"
exec > >(tee -a "$PATCH_LOG") 2>&1

echo "[1/8] Verify #2 core"
CORE_TAG="$(git -C "$COMFY" describe --tags --exact-match 2>/dev/null || git -C "$COMFY" rev-parse --short HEAD)"
echo "ComfyUI: $CORE_TAG"
"$PY" - <<'PY'
from pathlib import Path
p=Path("'"$COMFY"'")/"comfy_extras"
text=""
for f in p.rglob("*.py"):
    try:
        s=f.read_text(errors="ignore")
    except Exception:
        continue
    if "MiniMaxH3ReferenceToVideo" in s:
        text=s
        break
if not text:
    raise SystemExit("MiniMaxH3ReferenceToVideo not found in this ComfyUI core")
print("MiniMax H3 Ref2VA core: OK")
PY

# #2 saved setup uses v0.34.0. PDD node requires >= v0.33.0.
"$PY" - <<'PY'
import re, subprocess
root="'"$COMFY"'"
try:
    tag=subprocess.check_output(["git","-C",root,"describe","--tags","--exact-match"], text=True, stderr=subprocess.DEVNULL).strip()
except Exception:
    tag=""
m=re.match(r"v?(\d+)\.(\d+)\.(\d+)", tag)
if m and tuple(map(int,m.groups())) < (0,33,0):
    raise SystemExit(f"PDD node requires ComfyUI >= v0.33.0; found {tag}")
print("Core version gate: OK" if m else "Core tag not exact; continuing because MiniMax-H3 core node is present.")
PY

echo "[2/8] System tools"
for tool in git curl aria2c sha256sum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl aria2 ca-certificates
    break
  fi
done
green "  ✓ tools ready"

verified_download(){
  local label="$1" url="$2" dest="$3" sha="$4" min_bytes="$5"
  mkdir -p "$(dirname "$dest")"
  if [[ -s "$dest" ]]; then
    local size got
    size="$(stat -c%s "$dest")"
    if (( size >= min_bytes )); then
      got="$(sha256sum "$dest" | awk '{print $1}')"
      if [[ "$got" == "$sha" ]]; then
        echo "  [SKIP verified] $label"
        return 0
      fi
    fi
    yellow "  Existing $label is incomplete/mismatched; redownloading."
    rm -f "$dest" "$dest.aria2"
  fi
  echo "  [DOWNLOAD] $label"
  aria2c -c -x16 -s16 -k16M --file-allocation=none \
    --auto-file-renaming=false --allow-overwrite=true \
    --max-tries=12 --retry-wait=10 --summary-interval=15 \
    --dir "$(dirname "$dest")" --out "$(basename "$dest")" "$url"
  [[ -s "$dest" ]] || die "Download failed: $label"
  local size got
  size="$(stat -c%s "$dest")"
  (( size >= min_bytes )) || die "$label too small: $size"
  got="$(sha256sum "$dest" | awk '{print $1}')"
  [[ "$got" == "$sha" ]] || die "$label SHA256 mismatch: $got"
  green "  ✓ $label"
}

echo "[3/8] Install/update PDD custom node"
NODE_DIR="$COMFY/custom_nodes/ComfyUI-MiniMax-H3-PDD-Acc"
if [[ ! -d "$NODE_DIR/.git" ]]; then
  rm -rf "$NODE_DIR"
  git clone --depth 1 "$PDD_NODE_REPO" "$NODE_DIR"
else
  git -C "$NODE_DIR" pull --ff-only
fi
if [[ -f "$NODE_DIR/requirements.txt" ]]; then
  "$PIP" install -q --upgrade-strategy only-if-needed -r "$NODE_DIR/requirements.txt"
fi
green "  ✓ PDD custom node"

echo "[4/8] Download clean Ref2VA INT8 base (~34 GB)"
verified_download \
  "Clean Ref2VA INT8 ConvRot base" \
  "$BASE_URL" \
  "$COMFY/models/diffusion_models/$BASE_MODEL" \
  "$BASE_SHA" \
  33000000000

echo "[5/8] Download acceleration files"
verified_download \
  "PDD Ref2VA 8-step heads+LoRA" \
  "$PDD_URL" \
  "$COMFY/models/pdd_acc/$PDD_FILE" \
  "$PDD_SHA" \
  1600000000

verified_download \
  "LightX2V Ref2VA Turbo8 768p LoRA" \
  "$TURBO_URL" \
  "$COMFY/models/loras/$TURBO_FILE" \
  "$TURBO_SHA" \
  1900000000

echo "[6/8] Build isolated 03/04 workflows"

TMP_PDD="$(mktemp)"
TMP_TURBO="$(mktemp)"
curl -fL --retry 6 --retry-delay 3 "$PDD_EXAMPLE_URL" -o "$TMP_PDD"
curl -fL --retry 6 --retry-delay 3 "$R2V_TEMPLATE_URL" -o "$TMP_TURBO"

"$PY" - "$TMP_PDD" "$TMP_TURBO" "$WF_PDD" "$WF_TURBO" \
  "$BASE_MODEL" "$PDD_FILE" "$TURBO_FILE" <<'PY'
import copy, json, sys
src_pdd, src_turbo, out_pdd, out_turbo, base_model, pdd_file, turbo_file = sys.argv[1:]

TEXT="qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"
VIDEO_VAE="minimax_h3_video_vae_int8_convrot.safetensors"
AUDIO_VAE="minimax_h3_audio_vae_fp32.safetensors"
REF_LABELS=[
    ("REF1_FACE_HAIR.png","REF1 — FACE & HAIR"),
    ("REF2_BODY_PROPORTIONS.png","REF2 — BODY PROPORTIONS"),
    ("REF3_CLOTHING.png","REF3 — CLOTHING"),
    ("REF4_BACKGROUND.png","REF4 — BACKGROUND / ENVIRONMENT"),
]

def node_by_type(d, t):
    return [n for n in d.get("nodes",[]) if n.get("type")==t]

def remove_link(d, lid):
    if lid is None: return
    d["links"]=[x for x in d.get("links",[]) if x[0]!=lid]
    for n in d.get("nodes",[]):
        for o in n.get("outputs",[]) or []:
            if isinstance(o.get("links"), list):
                o["links"]=[x for x in o["links"] if x!=lid]
        for i in n.get("inputs",[]) or []:
            if i.get("link")==lid:
                i["link"]=None

def next_node_id(d):
    m=max([int(n.get("id",0)) for n in d.get("nodes",[])] or [0])+1
    d["last_node_id"]=max(int(d.get("last_node_id",0) or 0), m)
    return m

def next_link_id(d):
    m=max([int(x[0]) for x in d.get("links",[])] or [0])+1
    d["last_link_id"]=max(int(d.get("last_link_id",0) or 0), m)
    return m

def set_loader_names(d):
    unets=node_by_type(d,"UNETLoader")
    if not unets: raise RuntimeError("UNETLoader missing")
    for n in unets:
        if n.get("widgets_values"): n["widgets_values"][0]=base_model
        if "widgets_values_named" in n: n["widgets_values_named"]["unet_name"]=base_model

    for n in node_by_type(d,"CLIPLoader"):
        if n.get("widgets_values"): n["widgets_values"][0]=TEXT
        if "widgets_values_named" in n: n["widgets_values_named"]["clip_name"]=TEXT

    vaes=node_by_type(d,"VAELoader")
    for n in vaes:
        vals=n.get("widgets_values") or []
        old=str(vals[0]).lower() if vals else ""
        new=AUDIO_VAE if "audio" in old else VIDEO_VAE
        if vals: vals[0]=new
        if "widgets_values_named" in n:
            if "vae_name" in n["widgets_values_named"]:
                n["widgets_values_named"]["vae_name"]=new

def add_four_refs(d, ref_node):
    # Remove existing ref-image links/inputs only. Keep ref-video/audio dynamic slots.
    old_ref_inputs=[i for i in ref_node.get("inputs",[]) if str(i.get("name","")).startswith("ref_images.ref_image_")]
    for i in old_ref_inputs:
        remove_link(d, i.get("link"))
    ref_node["inputs"]=[i for i in ref_node.get("inputs",[]) if not str(i.get("name","")).startswith("ref_images.ref_image_")]

    # Insert after audio_vae, before ref-video/audio slots.
    insert_at=0
    for idx,i in enumerate(ref_node["inputs"]):
        if i.get("name")=="audio_vae":
            insert_at=idx+1

    new_inputs=[]
    for idx in range(4):
        new_inputs.append({
            "label": f"ref_image_{idx}",
            "name": f"ref_images.ref_image_{idx}",
            "shape": 7,
            "type": "IMAGE",
            "link": None,
        })
    ref_node["inputs"][insert_at:insert_at]=new_inputs

    base_x=(ref_node.get("pos") or [400,400])[0]-520
    base_y=(ref_node.get("pos") or [400,400])[1]-40
    for idx,(filename,title) in enumerate(REF_LABELS):
        nid=next_node_id(d)
        lid=next_link_id(d)
        target_slot=insert_at+idx
        node={
            "id":nid,
            "type":"LoadImage",
            "pos":[base_x, base_y+idx*260],
            "size":[360,230],
            "flags":{},
            "order":idx,
            "mode":0,
            "inputs":[],
            "outputs":[
                {"name":"IMAGE","type":"IMAGE","links":[lid],"slot_index":0},
                {"name":"MASK","type":"MASK","links":None,"slot_index":1},
            ],
            "properties":{"Node name for S&R":"LoadImage"},
            "widgets_values":[filename,"image"],
            "title":title,
        }
        d["nodes"].append(node)
        ref_node["inputs"][target_slot]["link"]=lid
        d.setdefault("links",[]).append([lid,nid,0,ref_node["id"],target_slot,"IMAGE"])

def patch_prompt_and_size(d):
    refs=node_by_type(d,"MiniMaxH3ReferenceToVideo")
    if not refs: raise RuntimeError("MiniMaxH3ReferenceToVideo missing")
    r=refs[0]
    vals=r.get("widgets_values") or []
    prompt = (
        "[REFERENCE USAGE]\\n"
        "Reference 1 = FACE & HAIR only.\\n"
        "Reference 2 = BODY PROPORTIONS / PHYSIQUE only.\\n"
        "Reference 3 = CLOTHING / ACCESSORIES only.\\n"
        "Reference 4 = BACKGROUND / ENVIRONMENT only.\\n"
        "Keep all four roles strictly separated.\\n\\n"
        "[ACTION]\\n"
        "Replace this block with your current 10-second action prompt."
    )
    # Native node order: prompt,width,height,length,ref_image_size.
    if len(vals)>=5:
        vals[0]=prompt
        vals[1]=1344
        vals[2]=768
        vals[3]=241
        vals[4]="match"
    add_four_refs(d,r)

def patch_pdd(d):
    set_loader_names(d)
    patch_prompt_and_size(d)
    for n in node_by_type(d,"MiniMaxH3SigmaShift"):
        n["widgets_values"]=[12,3]
    applies=node_by_type(d,"MiniMaxH3PDDAccApply")
    if not applies: raise RuntimeError("MiniMaxH3PDDAccApply missing")
    # file, nfe, lora_strength, head_strength, mismatch behavior
    applies[0]["widgets_values"]=[pdd_file,"8",1.0,1.0,"error"]
    for n in node_by_type(d,"KSamplerSelect"):
        n["widgets_values"]=["euler"]
        if "widgets_values_named" in n: n["widgets_values_named"]["sampler_name"]="euler"
    for n in node_by_type(d,"SaveVideo"):
        vals=n.get("widgets_values") or []
        if vals: vals[0]="video/H3_PDD_8STEP"
    # Update note so nobody accidentally stacks Turbo.
    nid=next_node_id(d)
    d["nodes"].append({
        "id":nid,"type":"Note","pos":[700,560],"size":[480,250],"flags":{},
        "order":999,"mode":0,"inputs":[],"outputs":[],
        "properties":{"Node name for S&R":"Note"},
        "widgets_values":[
            "PDD TEST — DO NOT STACK TURBO LoRA\\n"
            "Base: clean Ref2VA INT8 ConvRot\\n"
            "PDD: 8 NFE, SigmaShift 12/3, Euler, CFG-free.\\n"
            "This live-LoRA path is for first quality testing; on RTX 5090, runtime LoRA patching can be slower than a baked PDD trunk."
        ],
        "title":"#2 PATCH — PDD 8-step"
    })

def insert_lora_after_unet(d):
    unets=node_by_type(d,"UNETLoader")
    if not unets: raise RuntimeError("UNETLoader missing")
    u=unets[0]
    old_links=[]
    for l in d.get("links",[]):
        if len(l)>=6 and l[1]==u["id"] and l[2]==0 and l[5]=="MODEL":
            old_links.append(l[0])
            l[1]=None  # temporary
    if not old_links:
        raise RuntimeError("No MODEL link leaves UNETLoader")

    lid=next_link_id(d)
    nid=next_node_id(d)

    # New LoRA node feeds every target that previously received UNET directly.
    for l in d["links"]:
        if l[0] in old_links:
            l[1]=nid
            l[2]=0

    if u.get("outputs"):
        u["outputs"][0]["links"]=[lid]

    lora_node={
        "id":nid,
        "type":"LoraLoaderModelOnly",
        "pos":[(u.get("pos") or [0,0])[0]+450,(u.get("pos") or [0,0])[1]],
        "size":[360,90],
        "flags":{},
        "order":100,
        "mode":0,
        "inputs":[{"name":"model","type":"MODEL","link":lid}],
        "outputs":[{"name":"MODEL","type":"MODEL","links":old_links,"slot_index":0}],
        "properties":{"Node name for S&R":"LoraLoaderModelOnly"},
        "widgets_values":[turbo_file,1.0],
        "title":"LightX2V Ref2VA Turbo8 v1.0 768p",
    }
    d["nodes"].append(lora_node)
    d["links"].append([lid,u["id"],0,nid,0,"MODEL"])

def patch_linked_int(d, input_obj, value):
    lid=input_obj.get("link")
    if lid is None: return False
    rec=next((x for x in d.get("links",[]) if x[0]==lid),None)
    if not rec: return False
    src=next((n for n in d.get("nodes",[]) if n.get("id")==rec[1]),None)
    if not src: return False
    vals=src.get("widgets_values") or []
    for j,v in enumerate(vals):
        if isinstance(v,(int,float)):
            vals[j]=value
            if "widgets_values_named" in src:
                for k in list(src["widgets_values_named"]):
                    if "step" in k.lower() or k.lower() in ("value","int"):
                        src["widgets_values_named"][k]=value
            return True
    return False

def patch_turbo(d):
    set_loader_names(d)
    patch_prompt_and_size(d)
    insert_lora_after_unet(d)

    for n in node_by_type(d,"MiniMaxH3SigmaShift"):
        n["widgets_values"]=[6,3]
        if "widgets_values_named" in n:
            for k in list(n["widgets_values_named"]):
                kl=k.lower()
                if "video" in kl and "shift" in kl: n["widgets_values_named"][k]=6
                if "audio" in kl and "shift" in kl: n["widgets_values_named"][k]=3

    for n in node_by_type(d,"KSamplerSelect"):
        n["widgets_values"]=["euler"]
        if "widgets_values_named" in n: n["widgets_values_named"]["sampler_name"]="euler"

    for n in node_by_type(d,"BasicScheduler"):
        vals=n.get("widgets_values") or []
        if len(vals)>=3:
            vals[0]="simple"; vals[1]=8; vals[2]=1
        if "widgets_values_named" in n:
            n["widgets_values_named"]["scheduler"]="simple"
            n["widgets_values_named"]["steps"]=8
            n["widgets_values_named"]["denoise"]=1
        step_input=next((i for i in n.get("inputs",[]) if i.get("name")=="steps"),None)
        if step_input: patch_linked_int(d,step_input,8)

    for n in node_by_type(d,"SaveVideo"):
        vals=n.get("widgets_values") or []
        if vals: vals[0]="video/H3_TURBO8_768P"

    nid=next_node_id(d)
    d["nodes"].append({
        "id":nid,"type":"Note","pos":[500,4700],"size":[500,230],"flags":{},
        "order":999,"mode":0,"inputs":[],"outputs":[],
        "properties":{"Node name for S&R":"Note"},
        "widgets_values":[
            "TURBO8 TEST\\n"
            "Clean Ref2VA INT8 ConvRot + LightX2V Ref2VA Turbo8 v1.0 768p\\n"
            "Recommended: 8 steps / video shift 6 / audio shift 3 / Euler / Simple / LoRA strength 1.0.\\n"
            "Do NOT swap back to the #2 fused Turbo checkpoint inside this workflow."
        ],
        "title":"#2 PATCH — Turbo8 768p"
    })

for src,out,fn in [
    (src_pdd,out_pdd,patch_pdd),
    (src_turbo,out_turbo,patch_turbo),
]:
    with open(src,"r",encoding="utf-8") as f:
        d=json.load(f)
    fn(d)
    # Keep top-level IDs safely above actual maxima.
    d["last_node_id"]=max([int(n.get("id",0)) for n in d.get("nodes",[])] or [0])
    d["last_link_id"]=max([int(x[0]) for x in d.get("links",[])] or [0])
    with open(out,"w",encoding="utf-8") as f:
        json.dump(d,f,ensure_ascii=False,indent=2)
    print("WROTE",out)
PY

"$PY" -m json.tool "$WF_PDD" >/dev/null
"$PY" -m json.tool "$WF_TURBO" >/dev/null
green "  ✓ 03/04 workflows created"

echo "[7/8] Restart #2 ComfyUI and validate nodes"
if [[ -x "$COMFY/restart_h3_fused.sh" ]]; then
  "$COMFY/restart_h3_fused.sh"
else
  pids="$(lsof -ti tcp:"$PORT" 2>/dev/null || true)"
  [[ -z "$pids" ]] || kill $pids 2>/dev/null || true
  sleep 2
  mkdir -p "$COMFY/runtime_logs"
  nohup "$PY" "$COMFY/main.py" --listen 0.0.0.0 --port "$PORT" \
    --preview-method auto --enable-cors-header --reserve-vram 4 --cache-none \
    > "$COMFY/runtime_logs/comfy_patch_restart.log" 2>&1 &
fi

for i in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:$PORT/object_info" -o /tmp/h3_patch_object_info.json 2>/dev/null; then
    break
  fi
  sleep 2
done
[[ -s /tmp/h3_patch_object_info.json ]] || die "ComfyUI did not become ready on port $PORT"

"$PY" - <<'PY'
import json
d=json.load(open("/tmp/h3_patch_object_info.json"))
required=["MiniMaxH3ReferenceToVideo","MiniMaxH3PDDAccApply","LoraLoaderModelOnly","BasicScheduler","KSamplerSelect"]
missing=[x for x in required if x not in d]
if missing:
    raise SystemExit("Missing nodes: "+", ".join(missing))
print("Required nodes registered:", ", ".join(required))
PY

echo "[8/8] Final checks"
sha256sum \
  "$COMFY/models/diffusion_models/$BASE_MODEL" \
  "$COMFY/models/pdd_acc/$PDD_FILE" \
  "$COMFY/models/loras/$TURBO_FILE" | sed 's/^/  /'

trap - ERR

echo
echo "================================================================="
green " READY — #2 PATCH v1"
echo "================================================================="
echo "Existing workflows preserved:"
echo "  01_FUSED_H3_I2V_FL2V_4STEP_SLA.json"
echo "  02_FUSED_H3_REF2VA_4STEP_SLA.json"
echo
echo "New workflows:"
echo "  03_H3_REF2VA_PDD_8STEP_4REF.json"
echo "  04_H3_REF2VA_TURBO8_768P_4REF.json"
echo
echo "03 PDD:"
echo "  clean Ref2VA INT8 + PDD live LoRA"
echo "  8 NFE / shift 12:3 / Euler / no Turbo stacking"
echo
echo "04 Turbo8:"
echo "  clean Ref2VA INT8 + LightX2V Turbo8 v1.0 768p"
echo "  8 steps / shift 6:3 / Euler / Simple"
echo
echo "4 reference slots:"
echo "  Ref1 FACE & HAIR"
echo "  Ref2 BODY PROPORTIONS"
echo "  Ref3 CLOTHING"
echo "  Ref4 BACKGROUND"
echo
yellow "NOTE: PDD live-LoRA may be slower on RTX 5090 because of low-VRAM patching."
yellow "If PDD quality is clearly better, next step is the baked-PDD trunk variant."
echo
echo "Patch log:"
echo "  $PATCH_LOG"
echo "================================================================="
