#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# #6 UPDATED CANDIDATE
# Qwen Rapid-AIO Multi-Reference HQ B/C/D COMPLETE v2
#
# Fresh-Pod one-shot installer for RunPod / RTX 5090 class
#
# Environment:
#   /workspace/runpod-slim/ComfyUI-QwenRapidBCD
# Port:
#   8188
#
# B = Qwen-Rapid-AIO-NSFW-v23 only
# C = B + Qwen-Edit_2511_penis_v2
# D = C + Qwen-Image-GenatomyFixer_epoch-9
#
# NEW in v2:
# - 4-image Multi-Reference I2I workflows for B/C/D
# - explicit role separation:
#     Picture 1 = identity / appearance
#     Picture 2 = composition / pose
#     Picture 3 = background / lighting
#     Picture 4 = optional detail / clothing / object
# - native output + optional RealESRGAN_x4plus post-upscale branch
# - original single-image B/C/D workflows retained
# - fresh isolated rebuild
# =============================================================================

ROOT="${ROOT:-/workspace/runpod-slim}"
BASE="${BASE:-$ROOT/ComfyUI-QwenRapidBCD}"
PORT="${PORT:-8188}"
BACKUP_EXISTING="${BACKUP_EXISTING:-1}"

say(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
ok(){ printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$ROOT"
cd "$ROOT"

# -----------------------------------------------------------------------------
# 1. Fresh dedicated ComfyUI
# -----------------------------------------------------------------------------
say "Creating fresh #6 Qwen Rapid-AIO environment"

if [[ -e "$BASE" ]]; then
  if [[ "$BACKUP_EXISTING" == "1" ]]; then
    OLD="${BASE}.backup.$(date +%Y%m%d_%H%M%S)"
    warn "Existing environment found; moving to: $OLD"
    mv "$BASE" "$OLD"
  else
    warn "Removing existing environment: $BASE"
    rm -rf "$BASE"
  fi
fi

git clone --depth 1 https://github.com/Comfy-Org/ComfyUI.git "$BASE"
cd "$BASE"

# -----------------------------------------------------------------------------
# 2. Python environment
# -----------------------------------------------------------------------------
say "Preparing Python environment"

python3 -m venv --system-site-packages "$BASE/.venv"
PY="$BASE/.venv/bin/python"
PIP="$BASE/.venv/bin/pip"

"$PY" -m pip install -q --upgrade pip
"$PIP" install -q "setuptools<82" wheel
"$PIP" install -q -r requirements.txt

# Keep the known-good Rapid-AIO dependency pins.
"$PIP" install -q --upgrade \
  "setuptools<82" \
  "transformers>=4.51,<4.53" \
  "huggingface_hub>=0.34" \
  hf_xet

# -----------------------------------------------------------------------------
# 3. Rapid-AIO fixed Qwen multi-image encoder node
# -----------------------------------------------------------------------------
say "Installing Rapid-AIO TextEncodeQwenImageEditPlus"

EXTRAS="$BASE/comfy_extras"
QWEN_NODE="$EXTRAS/nodes_qwen.py"
QWEN_BAK="$EXTRAS/nodes_qwen.py.comfy-original.bak"
mkdir -p "$EXTRAS"

if [[ -f "$QWEN_NODE" ]]; then
  cp "$QWEN_NODE" "$QWEN_BAK"
fi

curl -fL --retry 8 --retry-delay 2 \
  "https://huggingface.co/Phr00t/Qwen-Image-Edit-Rapid-AIO/resolve/main/fixed-textencode-node/nodes_qwen.v2.py?download=true" \
  -o "$QWEN_NODE"

grep -q 'TextEncodeQwenImageEditPlus' "$QWEN_NODE" \
  || die "TextEncodeQwenImageEditPlus not found in downloaded Qwen node."

"$PY" -m py_compile "$QWEN_NODE"

# -----------------------------------------------------------------------------
# 4. Directories / logging
# -----------------------------------------------------------------------------
CHECKPOINT_DIR="$BASE/models/checkpoints"
LORA_DIR="$BASE/models/loras"
UPSCALE_DIR="$BASE/models/upscale_models"
WF_DIR="$BASE/user/default/workflows"
LOG_DIR="$BASE/user/setup_logs"

mkdir -p "$CHECKPOINT_DIR" "$LORA_DIR" "$UPSCALE_DIR" "$WF_DIR" "$LOG_DIR"

LOG="$LOG_DIR/setup_multiref_hq_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

# -----------------------------------------------------------------------------
# 5. Hugging Face downloader
# -----------------------------------------------------------------------------
hf_download() {
  local repo="$1"
  local remote="$2"
  local target="$3"

  if [[ -s "$target" ]]; then
    ok "Already present: $(basename "$target")"
    return 0
  fi

  say "Downloading: $repo :: $remote"

  REPO="$repo" REMOTE="$remote" TARGET="$target" "$PY" - <<'PYCODE'
import os, shutil
from huggingface_hub import hf_hub_download

repo = os.environ["REPO"]
remote = os.environ["REMOTE"]
target = os.environ["TARGET"]

src = hf_hub_download(repo_id=repo, filename=remote)
os.makedirs(os.path.dirname(target), exist_ok=True)
tmp = target + ".part"
if os.path.exists(tmp):
    os.remove(tmp)
try:
    os.link(src, tmp)
except Exception:
    shutil.copy2(src, tmp)
os.replace(tmp, target)
print("Saved:", target)
PYCODE
}

RAPID="$CHECKPOINT_DIR/Qwen-Rapid-AIO-NSFW-v23.safetensors"
PENIS="$LORA_DIR/Qwen-Edit_2511_penis_v2.safetensors"
GENATOMY="$LORA_DIR/Qwen-Image-GenatomyFixer_epoch-9.safetensors"
REALESRGAN="$UPSCALE_DIR/RealESRGAN_x4plus.pth"

say "Downloading Rapid-AIO NSFW v23"
hf_download \
  "Phr00t/Qwen-Image-Edit-Rapid-AIO" \
  "v23/Qwen-Rapid-AIO-NSFW-v23.safetensors" \
  "$RAPID"

say "Downloading C LoRA"
hf_download \
  "nnndite/qweneditpenis" \
  "Qwen-Edit 2511_penis_v2.safetensors" \
  "$PENIS"

say "Downloading D fixer LoRA"
hf_download \
  "Zaytron40k/Qwen-Image-GenatomyFixer" \
  "checkpoints/epoch-9.safetensors" \
  "$GENATOMY"

say "Downloading RealESRGAN x4plus"
hf_download \
  "amd/realesrgan-x4plus" \
  "RealESRGAN_x4plus.pth" \
  "$REALESRGAN"

# -----------------------------------------------------------------------------
# 6. Generate original + Multi-Reference HQ B/C/D workflows
# -----------------------------------------------------------------------------
say "Generating #6 workflows"

WF_DIR="$WF_DIR" "$PY" - <<'PYCODE'
import json, os, uuid
from pathlib import Path

OUT = Path(os.environ["WF_DIR"])
OUT.mkdir(parents=True, exist_ok=True)

CKPT = "Qwen-Rapid-AIO-NSFW-v23.safetensors"
LORA1 = "Qwen-Edit_2511_penis_v2.safetensors"
LORA2 = "Qwen-Image-GenatomyFixer_epoch-9.safetensors"
UPSCALER = "RealESRGAN_x4plus.pth"

def node(nid, typ, pos, size, inputs, outputs, widgets=None, title=None, order=0):
    d = {
        "id": nid, "type": typ, "pos": list(pos), "size": list(size),
        "flags": {}, "order": order, "mode": 0,
        "inputs": inputs, "outputs": outputs,
        "properties": {"Node name for S&R": typ},
        "widgets_values": widgets or []
    }
    if title: d["title"] = title
    return d

def make_multiref(mode="B"):
    links=[]; lid=1
    def link(src,ss,dst,ds,typ):
        nonlocal lid
        links.append([lid,src,ss,dst,ds,typ]); x=lid; lid+=1; return x

    C=1; L1=2; L2=3
    I1=10; I2=11; I3=12; I4=13
    LAT=20; POS=21; NEG=22; KS=23; DEC=24
    SAVE_NATIVE=25; UPLOAD=26; UPSCALE=27; SAVE_UP=28

    model_src=(C,0) if mode=="B" else ((L1,0) if mode=="C" else (L2,0))

    clip_pos=link(C,1,POS,0,"CLIP")
    clip_neg=link(C,1,NEG,0,"CLIP")
    vae_pos=link(C,2,POS,1,"VAE")
    vae_neg=link(C,2,NEG,1,"VAE")
    vae_dec=link(C,2,DEC,1,"VAE")

    i1=link(I1,0,POS,2,"IMAGE")
    i2=link(I2,0,POS,3,"IMAGE")
    i3=link(I3,0,POS,4,"IMAGE")
    i4=link(I4,0,POS,5,"IMAGE")

    lat_pos=link(LAT,0,POS,6,"LATENT")
    lat_ks=link(LAT,0,KS,3,"LATENT")
    pos_ks=link(POS,0,KS,1,"CONDITIONING")
    neg_ks=link(NEG,0,KS,2,"CONDITIONING")
    model_ks=link(model_src[0],model_src[1],KS,0,"MODEL")
    samp_dec=link(KS,0,DEC,0,"LATENT")
    dec_native=link(DEC,0,SAVE_NATIVE,0,"IMAGE")
    up_model=link(UPLOAD,0,UPSCALE,0,"UPSCALE_MODEL")
    dec_up=link(DEC,0,UPSCALE,1,"IMAGE")
    up_save=link(UPSCALE,0,SAVE_UP,0,"IMAGE")

    ck_l1=l1_l2=None
    if mode in ("C","D"): ck_l1=link(C,0,L1,0,"MODEL")
    if mode=="D": l1_l2=link(L1,0,L2,0,"MODEL")

    nodes=[]
    nodes.append(node(C,"CheckpointLoaderSimple",(-980,-120),(360,100),[],
        [{"name":"MODEL","type":"MODEL","links":[model_ks] if mode=="B" else [ck_l1]},
         {"name":"CLIP","type":"CLIP","links":[clip_pos,clip_neg]},
         {"name":"VAE","type":"VAE","links":[vae_pos,vae_neg,vae_dec]}],
        [CKPT],"B BASE — Rapid-AIO NSFW v23",0))

    if mode in ("C","D"):
        nodes.append(node(L1,"LoraLoaderModelOnly",(-570,-120),(360,82),
            [{"name":"model","type":"MODEL","link":ck_l1}],
            [{"name":"MODEL","type":"MODEL","links":[model_ks] if mode=="C" else [l1_l2]}],
            [LORA1,0.70],"C — optional anatomy LoRA (0.70)",1))
    if mode=="D":
        nodes.append(node(L2,"LoraLoaderModelOnly",(-160,-120),(360,82),
            [{"name":"model","type":"MODEL","link":l1_l2}],
            [{"name":"MODEL","type":"MODEL","links":[model_ks]}],
            [LORA2,0.20],"D — optional GenatomyFixer (0.20)",2))

    refspec=[
        (I1,-980,220,"ref_identity.png","PICTURE 1 — IDENTITY / APPEARANCE",i1),
        (I2,-620,220,"ref_pose.png","PICTURE 2 — COMPOSITION / POSE",i2),
        (I3,-260,220,"ref_background.png","PICTURE 3 — BACKGROUND / LIGHTING",i3),
        (I4,100,220,"ref_detail.png","PICTURE 4 — OPTIONAL DETAIL",i4),
    ]
    for nid,x,y,name,title,outlink in refspec:
        nodes.append(node(nid,"LoadImage",(x,y),(320,330),[],
            [{"name":"IMAGE","type":"IMAGE","links":[outlink]},
             {"name":"MASK","type":"MASK","links":None}],
            [name,"image"],title,3))

    nodes.append(node(LAT,"EmptyLatentImage",(-980,610),(320,115),[],
        [{"name":"LATENT","type":"LATENT","links":[lat_pos,lat_ks]}],
        [1280,1280,1],"OUTPUT SIZE — HQ default 1280×1280; match desired aspect",4))

    prompt = (
        "Picture 1 is the ONLY identity and appearance reference. Preserve the adult subject's "
        "identity, face, hairstyle, body proportions and overall appearance from Picture 1. "
        "Picture 2 is ONLY the composition and pose reference. Reproduce its camera angle, framing, "
        "body pose, limb placement and perspective without copying that person's identity. "
        "Picture 3 is ONLY the background and lighting reference. Reproduce its environment, scene "
        "layout, perspective and lighting. Picture 4 is OPTIONAL and should be used only for requested "
        "clothing, object or fine-detail guidance. Do not blend identities between references. "
        "Create one coherent, highly realistic photograph with natural skin texture, fine detail, "
        "clean anatomy, realistic lens behavior and consistent lighting. Preserve the requested reference "
        "roles strictly."
    )

    nodes.append(node(POS,"TextEncodeQwenImageEditPlus",(480,170),(560,390),
        [{"name":"clip","type":"CLIP","link":clip_pos},
         {"name":"vae","type":"VAE","link":vae_pos},
         {"name":"image1","shape":7,"type":"IMAGE","link":i1},
         {"name":"image2","shape":7,"type":"IMAGE","link":i2},
         {"name":"image3","shape":7,"type":"IMAGE","link":i3},
         {"name":"image4","shape":7,"type":"IMAGE","link":i4},
         {"name":"target_latent","shape":7,"type":"LATENT","link":lat_pos}],
        [{"name":"CONDITIONING","type":"CONDITIONING","links":[pos_ks]}],
        [prompt],"MULTI-REF PROMPT — edit this",5))

    nodes.append(node(NEG,"TextEncodeQwenImageEditPlus",(480,600),(560,220),
        [{"name":"clip","type":"CLIP","link":clip_neg},
         {"name":"vae","type":"VAE","link":vae_neg},
         {"name":"image1","shape":7,"type":"IMAGE","link":None},
         {"name":"image2","shape":7,"type":"IMAGE","link":None},
         {"name":"image3","shape":7,"type":"IMAGE","link":None},
         {"name":"image4","shape":7,"type":"IMAGE","link":None},
         {"name":"target_latent","shape":7,"type":"LATENT","link":None}],
        [{"name":"CONDITIONING","type":"CONDITIONING","links":[neg_ks]}],
        [""],"NEGATIVE — Rapid-AIO: leave blank first",5))

    nodes.append(node(KS,"KSampler",(1110,260),(320,280),
        [{"name":"model","type":"MODEL","link":model_ks},
         {"name":"positive","type":"CONDITIONING","link":pos_ks},
         {"name":"negative","type":"CONDITIONING","link":neg_ks},
         {"name":"latent_image","type":"LATENT","link":lat_ks}],
        [{"name":"LATENT","type":"LATENT","links":[samp_dec]}],
        [65454653,"fixed",4,1.0,"sa_solver","beta",1.0],
        f"{mode} MULTI-REF — Rapid baseline 4 steps / CFG 1",6))

    nodes.append(node(DEC,"VAEDecode",(1490,270),(210,80),
        [{"name":"samples","type":"LATENT","link":samp_dec},
         {"name":"vae","type":"VAE","link":vae_dec}],
        [{"name":"IMAGE","type":"IMAGE","links":[dec_native,dec_up]}],
        [],"DECODE — native HQ",7))

    nodes.append(node(SAVE_NATIVE,"SaveImage",(1760,90),(320,340),
        [{"name":"images","type":"IMAGE","link":dec_native}],[],
        [f"RapidAIO_{mode}_MultiRef_NATIVE"],"SAVE NATIVE",8))

    nodes.append(node(UPLOAD,"UpscaleModelLoader",(1490,500),(320,80),[],
        [{"name":"UPSCALE_MODEL","type":"UPSCALE_MODEL","links":[up_model]}],
        [UPSCALER],"UPSCALE MODEL — RealESRGAN x4plus",7))

    nodes.append(node(UPSCALE,"ImageUpscaleWithModel",(1860,500),(300,100),
        [{"name":"upscale_model","type":"UPSCALE_MODEL","link":up_model},
         {"name":"image","type":"IMAGE","link":dec_up}],
        [{"name":"IMAGE","type":"IMAGE","links":[up_save]}],
        [],"OPTIONAL POST UPSCALE ×4",8))

    nodes.append(node(SAVE_UP,"SaveImage",(2220,460),(330,350),
        [{"name":"images","type":"IMAGE","link":up_save}],[],
        [f"RapidAIO_{mode}_MultiRef_x4"],"SAVE UPSCALED ×4",9))

    return {
        "id":str(uuid.uuid4()),"revision":0,
        "last_node_id":SAVE_UP,"last_link_id":lid-1,
        "nodes":nodes,"links":links,"groups":[],
        "config":{},
        "extra":{"ds":{"scale":0.62,"offset":[900,120]},"frontendVersion":"1.49.6"},
        "version":0.4
    }

def make_single(mode="B"):
    # Compact retained single-reference workflow, same known-good Rapid-AIO baseline.
    links=[]; lid=1
    def link(s,ss,d,ds,t):
        nonlocal lid
        links.append([lid,s,ss,d,ds,t]); x=lid; lid+=1; return x
    C=1; L1=2; L2=3; IMG=4; LAT=5; POS=6; NEG=7; KS=8; DEC=9; SAVE=10
    msrc=(C,0) if mode=="B" else ((L1,0) if mode=="C" else (L2,0))
    cp=link(C,1,POS,0,"CLIP"); cn=link(C,1,NEG,0,"CLIP")
    vp=link(C,2,POS,1,"VAE"); vn=link(C,2,NEG,1,"VAE"); vd=link(C,2,DEC,1,"VAE")
    ip=link(IMG,0,POS,2,"IMAGE"); lp=link(LAT,0,POS,6,"LATENT"); lk=link(LAT,0,KS,3,"LATENT")
    pk=link(POS,0,KS,1,"CONDITIONING"); nk=link(NEG,0,KS,2,"CONDITIONING")
    mk=link(msrc[0],msrc[1],KS,0,"MODEL"); sd=link(KS,0,DEC,0,"LATENT"); ds=link(DEC,0,SAVE,0,"IMAGE")
    c1=c2=None
    if mode in ("C","D"): c1=link(C,0,L1,0,"MODEL")
    if mode=="D": c2=link(L1,0,L2,0,"MODEL")
    nodes=[node(C,"CheckpointLoaderSimple",(-620,-60),(360,100),[],
        [{"name":"MODEL","type":"MODEL","links":[mk] if mode=="B" else [c1]},
         {"name":"CLIP","type":"CLIP","links":[cp,cn]},
         {"name":"VAE","type":"VAE","links":[vp,vn,vd]}],[CKPT],"Rapid-AIO NSFW v23",0)]
    if mode in ("C","D"):
        nodes.append(node(L1,"LoraLoaderModelOnly",(-210,-60),(360,82),
            [{"name":"model","type":"MODEL","link":c1}],
            [{"name":"MODEL","type":"MODEL","links":[mk] if mode=="C" else [c2]}],
            [LORA1,0.70],"C LoRA",1))
    if mode=="D":
        nodes.append(node(L2,"LoraLoaderModelOnly",(190,-60),(360,82),
            [{"name":"model","type":"MODEL","link":c2}],
            [{"name":"MODEL","type":"MODEL","links":[mk]}],
            [LORA2,0.20],"D GenatomyFixer",2))
    nodes += [
        node(IMG,"LoadImage",(-620,430),(320,330),[],
             [{"name":"IMAGE","type":"IMAGE","links":[ip]},{"name":"MASK","type":"MASK","links":None}],
             ["example.png","image"],"INPUT IMAGE",1),
        node(LAT,"EmptyLatentImage",(-620,790),(300,110),[],
             [{"name":"LATENT","type":"LATENT","links":[lp,lk]}],[1024,1024,1],"OUTPUT SIZE",2),
        node(POS,"TextEncodeQwenImageEditPlus",(-230,340),(470,300),
             [{"name":"clip","type":"CLIP","link":cp},{"name":"vae","type":"VAE","link":vp},
              {"name":"image1","shape":7,"type":"IMAGE","link":ip},
              {"name":"image2","shape":7,"type":"IMAGE","link":None},
              {"name":"image3","shape":7,"type":"IMAGE","link":None},
              {"name":"image4","shape":7,"type":"IMAGE","link":None},
              {"name":"target_latent","shape":7,"type":"LATENT","link":lp}],
             [{"name":"CONDITIONING","type":"CONDITIONING","links":[pk]}],
             ["Edit the input image while preserving identity, pose, camera, lighting and photorealism unless explicitly requested otherwise."],
             "EDIT PROMPT",4),
        node(NEG,"TextEncodeQwenImageEditPlus",(-230,690),(470,220),
             [{"name":"clip","type":"CLIP","link":cn},{"name":"vae","type":"VAE","link":vn},
              {"name":"image1","shape":7,"type":"IMAGE","link":None},{"name":"image2","shape":7,"type":"IMAGE","link":None},
              {"name":"image3","shape":7,"type":"IMAGE","link":None},{"name":"image4","shape":7,"type":"IMAGE","link":None},
              {"name":"target_latent","shape":7,"type":"LATENT","link":None}],
             [{"name":"CONDITIONING","type":"CONDITIONING","links":[nk]}],[""],"NEGATIVE",3),
        node(KS,"KSampler",(620,260),(300,270),
             [{"name":"model","type":"MODEL","link":mk},{"name":"positive","type":"CONDITIONING","link":pk},
              {"name":"negative","type":"CONDITIONING","link":nk},{"name":"latent_image","type":"LATENT","link":lk}],
             [{"name":"LATENT","type":"LATENT","links":[sd]}],
             [65454653,"fixed",4,1.0,"sa_solver","beta",1.0],f"{mode} — CFG 1 / 4 steps",6),
        node(DEC,"VAEDecode",(970,290),(180,70),
             [{"name":"samples","type":"LATENT","link":sd},{"name":"vae","type":"VAE","link":vd}],
             [{"name":"IMAGE","type":"IMAGE","links":[ds]}],[],"DECODE",7),
        node(SAVE,"SaveImage",(1210,240),(330,350),
             [{"name":"images","type":"IMAGE","link":ds}],[],[f"RapidAIO_{mode}"],f"SAVE {mode}",8)
    ]
    return {"id":str(uuid.uuid4()),"revision":0,"last_node_id":10,"last_link_id":lid-1,
            "nodes":nodes,"links":links,"groups":[],"config":{},
            "extra":{"ds":{"scale":0.82,"offset":[760,160]},"frontendVersion":"1.49.6"},"version":0.4}

for mode in ("B","C","D"):
    p=OUT/f"RapidAIO_{mode}_Qwen2511.json"
    p.write_text(json.dumps(make_single(mode),indent=2,ensure_ascii=False),encoding="utf-8")
    print("Generated:",p)

    p=OUT/f"RapidAIO_{mode}_MultiRef_HQ_x4.json"
    p.write_text(json.dumps(make_multiref(mode),indent=2,ensure_ascii=False),encoding="utf-8")
    print("Generated:",p)
PYCODE

# -----------------------------------------------------------------------------
# 7. README
# -----------------------------------------------------------------------------
cat > "$WF_DIR/README_RAPID_AIO_MULTIREF_HQ.txt" <<'TXT'
#6 Qwen Rapid-AIO Multi-Reference HQ v2
======================================

Recommended first workflow:
  RapidAIO_B_MultiRef_HQ_x4.json

Reference roles:
  Picture 1 = identity / appearance
  Picture 2 = composition / pose
  Picture 3 = background / lighting
  Picture 4 = optional detail / clothing / object

Important:
  Each image is still a generative reference, not a deterministic ControlNet.
  State the role of each Picture explicitly in the prompt.
  Do not ask Picture 2/3/4 to contribute identity unless you actually want blending.

B:
  Qwen-Rapid-AIO-NSFW-v23 only
  Best starting point for general multi-reference editing.

C:
  B + Qwen-Edit_2511_penis_v2
  Initial strength 0.70.
  Use only when that LoRA is actually needed.

D:
  C + Qwen-Image-GenatomyFixer_epoch-9
  Initial strength 0.20.
  Use only when anatomy correction is actually needed.

Generation baseline:
  sampler   = sa_solver
  scheduler = beta
  steps     = 4
  CFG       = 1.0
  denoise   = 1.0

HQ:
  Default native latent = 1280 x 1280
  Change width/height to the intended aspect ratio.
  SaveImage produces the native generation.
  RealESRGAN_x4plus provides a separate optional x4 output.
  For reference-fidelity comparison, judge the NATIVE result first.
  Upscaling improves presentation/detail but cannot repair bad reference adherence.

Suggested test order:
  1. B MultiRef with Pictures 1-3.
  2. Keep Picture 4 simple or replace with a neutral/duplicated reference if unused.
  3. Same seed and prompt while comparing B/C/D.
TXT

# -----------------------------------------------------------------------------
# 8. Launchers
# -----------------------------------------------------------------------------
cat > "$BASE/start_8188.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$BASE"
exec "$PY" main.py --listen 0.0.0.0 --port "$PORT"
EOF
chmod +x "$BASE/start_8188.sh"

cat > "$BASE/restart_8188.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
pkill -f "main.py.*--port $PORT" 2>/dev/null || true
sleep 2
cd "$BASE"
nohup "$PY" main.py --listen 0.0.0.0 --port "$PORT" > "$BASE/comfyui_8188.log" 2>&1 &
echo "Started ComfyUI on port $PORT"
echo "Log: $BASE/comfyui_8188.log"
EOF
chmod +x "$BASE/restart_8188.sh"

# -----------------------------------------------------------------------------
# 9. Static validation
# -----------------------------------------------------------------------------
say "Validating models and workflows"

for f in "$RAPID" "$PENIS" "$GENATOMY" "$REALESRGAN"; do
  [[ -s "$f" ]] || die "Missing: $f"
done

for f in "$WF_DIR"/RapidAIO_[BCD]_Qwen2511.json "$WF_DIR"/RapidAIO_[BCD]_MultiRef_HQ_x4.json; do
  "$PY" -m json.tool "$f" >/dev/null
done

# Verify the multi-ref and upscale node tokens are present in generated workflows.
grep -q '"image4"' "$WF_DIR/RapidAIO_B_MultiRef_HQ_x4.json" || die "image4 input missing"
grep -q '"UpscaleModelLoader"' "$WF_DIR/RapidAIO_B_MultiRef_HQ_x4.json" || die "UpscaleModelLoader missing"
grep -q '"ImageUpscaleWithModel"' "$WF_DIR/RapidAIO_B_MultiRef_HQ_x4.json" || die "ImageUpscaleWithModel missing"

# -----------------------------------------------------------------------------
# 10. Environment report
# -----------------------------------------------------------------------------
say "Environment report"
"$PY" - <<'PYCODE'
import torch, transformers, setuptools
print("torch       :", torch.__version__)
print("transformers:", transformers.__version__)
print("setuptools  :", setuptools.__version__)
print("CUDA        :", torch.cuda.is_available())
if torch.cuda.is_available():
    print("GPU         :", torch.cuda.get_device_name(0))
PYCODE

# -----------------------------------------------------------------------------
# 11. Startup smoke test
# -----------------------------------------------------------------------------
say "Startup smoke test"
SMOKE="$LOG_DIR/smoke_multiref_hq.log"
set +e
timeout 45s "$PY" main.py --listen 127.0.0.1 --port 8197 > "$SMOKE" 2>&1
RC=$?
set -e

if [[ "$RC" != "0" && "$RC" != "124" ]]; then
  tail -n 180 "$SMOKE"
  die "ComfyUI smoke test failed (exit $RC)."
fi
if grep -qiE 'Traceback|IMPORT FAILED|ModuleNotFoundError|SyntaxError' "$SMOKE"; then
  tail -n 180 "$SMOKE"
  die "ComfyUI reported startup/import failure."
fi

# -----------------------------------------------------------------------------
# 12. Start actual server + wait
# -----------------------------------------------------------------------------
say "Starting ComfyUI on port $PORT"
pkill -f "main.py.*--port $PORT" 2>/dev/null || true
sleep 2
nohup "$PY" main.py --listen 0.0.0.0 --port "$PORT" > "$BASE/comfyui_8188.log" 2>&1 &

READY=0
for i in $(seq 1 90); do
  if curl -fsS "http://127.0.0.1:$PORT/object_info" -o "$LOG_DIR/object_info.json"; then
    READY=1
    break
  fi
  sleep 2
done
[[ "$READY" == "1" ]] || { tail -n 180 "$BASE/comfyui_8188.log"; die "8188 server not ready"; }

"$PY" - "$LOG_DIR/object_info.json" <<'PYCODE'
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
need=["CheckpointLoaderSimple","TextEncodeQwenImageEditPlus","KSampler","UpscaleModelLoader","ImageUpscaleWithModel"]
missing=[x for x in need if x not in d]
if missing:
    raise SystemExit("Missing nodes: "+", ".join(missing))
print("object_info OK:", ", ".join(need))
PYCODE

cat <<EOF

============================================================
READY — #6 Qwen Rapid-AIO Multi-Reference HQ COMPLETE v2
============================================================

Environment:
  $BASE

Recommended first workflow:
  $WF_DIR/RapidAIO_B_MultiRef_HQ_x4.json

Other Multi-Ref workflows:
  $WF_DIR/RapidAIO_C_MultiRef_HQ_x4.json
  $WF_DIR/RapidAIO_D_MultiRef_HQ_x4.json

Original single-reference workflows are also retained.

Reference roles:
  Picture 1 = identity / appearance
  Picture 2 = composition / pose
  Picture 3 = background / lighting
  Picture 4 = optional detail

Baseline:
  1280x1280
  4 steps
  CFG 1.0
  sa_solver / beta
  optional RealESRGAN x4 output

ComfyUI:
  port $PORT

Log:
  $BASE/comfyui_8188.log
============================================================
EOF
