#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Qwen Rapid-AIO B/C/D COMPLETE SAVED VERSION
# Fresh-Pod + repair-safe installer for RunPod / RTX 5090 class
#
# Dedicated environment:
#   /workspace/runpod-slim/ComfyUI-QwenRapidBCD
#
# B = Qwen-Rapid-AIO-NSFW-v23
# C = B + Qwen-Edit_2511_penis_v2
# D = C + Qwen-Image-GenatomyFixer
#
# This installer fixes the issues encountered in v1-v4:
# - no dependency on a pre-existing ComfyUI-Qwen2511 folder
# - setuptools pinned below Torch 2.11 incompatibility threshold
# - transformers pinned below ms-swift 3.4 incompatibility threshold
# - Rapid-AIO author's nodes_qwen.v2.py REPLACES comfy_extras/nodes_qwen.py
# - B/C/D workflows are generated locally by this script
# - downloads are resume/re-run safe
# - startup smoke test + 8188 launcher included
# ============================================================

ROOT="${ROOT:-/workspace/runpod-slim}"
BASE="${BASE:-$ROOT/ComfyUI-QwenRapidBCD}"
PORT="${PORT:-8188}"

say(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

mkdir -p "$ROOT"
cd "$ROOT"

# ------------------------------------------------------------
# 1. Dedicated ComfyUI
# ------------------------------------------------------------
say "Checking dedicated ComfyUI"

if [[ ! -f "$BASE/main.py" ]]; then
  if [[ -e "$BASE" ]]; then
    BROKEN="${BASE}.broken.$(date +%Y%m%d_%H%M%S)"
    say "Incomplete folder exists; moving it to $BROKEN"
    mv "$BASE" "$BROKEN"
  fi
  git clone --depth 1 https://github.com/Comfy-Org/ComfyUI.git "$BASE"
else
  say "Existing ComfyUI found; preserving and repairing it in place"
fi

cd "$BASE"

# ------------------------------------------------------------
# 2. Python environment
# ------------------------------------------------------------
say "Preparing Python environment"

if [[ ! -x "$BASE/.venv/bin/python" ]]; then
  python3 -m venv --system-site-packages "$BASE/.venv"
fi

PY="$BASE/.venv/bin/python"
PIP="$BASE/.venv/bin/pip"

"$PY" -m pip install -q --upgrade pip

# Avoid the RunPod conflict seen during setup:
# torch 2.11.0+cu128 requires setuptools < 82.
"$PIP" install -q "setuptools<82" wheel

# Install ComfyUI dependencies first.
"$PIP" install -q -r requirements.txt

# Then deliberately shadow incompatible host packages inside this venv.
# ms-swift 3.4.0 requires transformers < 4.53.
"$PIP" install -q --upgrade \
  "setuptools<82" \
  "transformers>=4.51,<4.53" \
  "huggingface_hub>=0.34" \
  hf_xet

# ------------------------------------------------------------
# 3. Rapid-AIO author's fixed Qwen node
# ------------------------------------------------------------
say "Installing Rapid-AIO fixed TextEncodeQwenImageEditPlus node"

EXTRAS="$BASE/comfy_extras"
QWEN_NODE="$EXTRAS/nodes_qwen.py"
QWEN_BAK="$EXTRAS/nodes_qwen.py.comfy-original.bak"
mkdir -p "$EXTRAS"

if [[ -f "$QWEN_NODE" && ! -f "$QWEN_BAK" ]]; then
  cp "$QWEN_NODE" "$QWEN_BAK"
  say "Saved original ComfyUI node backup: $QWEN_BAK"
fi

curl -fL --retry 5 --retry-delay 2 \
  "https://huggingface.co/Phr00t/Qwen-Image-Edit-Rapid-AIO/resolve/main/fixed-textencode-node/nodes_qwen.v2.py?download=true" \
  -o "$QWEN_NODE"

grep -q 'TextEncodeQwenImageEditPlus' "$QWEN_NODE" \
  || die "Rapid-AIO nodes_qwen.v2.py downloaded, but TextEncodeQwenImageEditPlus was not found."

"$PY" -m py_compile "$QWEN_NODE"

# ------------------------------------------------------------
# 4. Directories / logging
# ------------------------------------------------------------
CHECKPOINT_DIR="$BASE/models/checkpoints"
LORA_DIR="$BASE/models/loras"
WF_DIR="$BASE/user/default/workflows"
LOG_DIR="$BASE/user/setup_logs"

mkdir -p "$CHECKPOINT_DIR" "$LORA_DIR" "$WF_DIR" "$LOG_DIR"

LOG="$LOG_DIR/setup_saved_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

# ------------------------------------------------------------
# 5. HF downloader
# ------------------------------------------------------------
hf_download() {
  local repo="$1"
  local remote="$2"
  local target="$3"

  if [[ -s "$target" ]]; then
    say "Already present: $(basename "$target")"
    return 0
  fi

  say "Downloading: $remote"

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

say "Ensuring B checkpoint"
hf_download \
  "Phr00t/Qwen-Image-Edit-Rapid-AIO" \
  "v23/Qwen-Rapid-AIO-NSFW-v23.safetensors" \
  "$RAPID"

say "Ensuring C LoRA"
hf_download \
  "nnndite/qweneditpenis" \
  "Qwen-Edit 2511_penis_v2.safetensors" \
  "$PENIS"

say "Ensuring D fixer LoRA"
hf_download \
  "Zaytron40k/Qwen-Image-GenatomyFixer" \
  "checkpoints/epoch-9.safetensors" \
  "$GENATOMY"

# ------------------------------------------------------------
# 6. Generate B/C/D workflows locally
# ------------------------------------------------------------
say "Generating B/C/D workflows"

WF_DIR="$WF_DIR" "$PY" - <<'PYCODE'
import json, os, uuid
from pathlib import Path

OUT = Path(os.environ["WF_DIR"])
OUT.mkdir(parents=True, exist_ok=True)

ckpt = "Qwen-Rapid-AIO-NSFW-v23.safetensors"
lora1 = "Qwen-Edit_2511_penis_v2.safetensors"
lora2 = "Qwen-Image-GenatomyFixer_epoch-9.safetensors"

def node(nid, typ, pos, size, inputs, outputs, widgets=None, title=None, order=0):
    d = {
        "id": nid,
        "type": typ,
        "pos": list(pos),
        "size": list(size),
        "flags": {},
        "order": order,
        "mode": 0,
        "inputs": inputs,
        "outputs": outputs,
        "properties": {"Node name for S&R": typ},
        "widgets_values": widgets or []
    }
    if title:
        d["title"] = title
    return d

def make_workflow(mode):
    links = []
    lid = 1

    def add_link(src, src_slot, dst, dst_slot, typ):
        nonlocal lid
        links.append([lid, src, src_slot, dst, dst_slot, typ])
        x = lid
        lid += 1
        return x

    C=1; L1=2; L2=3; IMG=4; LAT=5; POS=6; NEG=7; KS=8; DEC=9; SAVE=10

    model_src = (C,0) if mode=="B" else ((L1,0) if mode=="C" else (L2,0))

    clip_pos = add_link(C,1,POS,0,"CLIP")
    clip_neg = add_link(C,1,NEG,0,"CLIP")
    vae_pos  = add_link(C,2,POS,1,"VAE")
    vae_neg  = add_link(C,2,NEG,1,"VAE")
    vae_dec  = add_link(C,2,DEC,1,"VAE")
    img_pos  = add_link(IMG,0,POS,2,"IMAGE")
    lat_pos  = add_link(LAT,0,POS,6,"LATENT")
    lat_ks   = add_link(LAT,0,KS,3,"LATENT")
    pos_ks   = add_link(POS,0,KS,1,"CONDITIONING")
    neg_ks   = add_link(NEG,0,KS,2,"CONDITIONING")
    model_ks = add_link(model_src[0],model_src[1],KS,0,"MODEL")
    samp_dec = add_link(KS,0,DEC,0,"LATENT")
    dec_save = add_link(DEC,0,SAVE,0,"IMAGE")

    ck_l1 = None
    l1_l2 = None
    if mode in ("C","D"):
        ck_l1 = add_link(C,0,L1,0,"MODEL")
    if mode == "D":
        l1_l2 = add_link(L1,0,L2,0,"MODEL")

    nodes=[]

    ck_model_links = [model_ks] if mode=="B" else [ck_l1]
    nodes.append(node(
        C,"CheckpointLoaderSimple",(-620,-60),(360,100),[],
        [
            {"name":"MODEL","type":"MODEL","links":ck_model_links},
            {"name":"CLIP","type":"CLIP","links":[clip_pos,clip_neg]},
            {"name":"VAE","type":"VAE","links":[vae_pos,vae_neg,vae_dec]},
        ],
        [ckpt],"B BASE — Rapid-AIO NSFW v23",0
    ))

    if mode in ("C","D"):
        out_links = [model_ks] if mode=="C" else [l1_l2]
        nodes.append(node(
            L1,"LoraLoaderModelOnly",(-210,-60),(360,82),
            [{"name":"model","type":"MODEL","link":ck_l1}],
            [{"name":"MODEL","type":"MODEL","links":out_links}],
            [lora1,0.70],"C — penis_v2 (0.70)",1
        ))

    if mode=="D":
        nodes.append(node(
            L2,"LoraLoaderModelOnly",(190,-60),(360,82),
            [{"name":"model","type":"MODEL","link":l1_l2}],
            [{"name":"MODEL","type":"MODEL","links":[model_ks]}],
            [lora2,0.20],"D — GenatomyFixer (0.20)",2
        ))

    nodes.append(node(
        IMG,"LoadImage",(-620,430),(320,330),[],
        [
            {"name":"IMAGE","type":"IMAGE","links":[img_pos]},
            {"name":"MASK","type":"MASK","links":None}
        ],
        ["example.png","image"],"INPUT IMAGE",1
    ))

    nodes.append(node(
        LAT,"EmptyLatentImage",(-620,790),(300,110),[],
        [{"name":"LATENT","type":"LATENT","links":[lat_pos,lat_ks]}],
        [1024,1024,1],"OUTPUT SIZE — match source aspect ratio",2
    ))

    nodes.append(node(
        POS,"TextEncodeQwenImageEditPlus",(-230,340),(470,300),
        [
            {"name":"clip","type":"CLIP","link":clip_pos},
            {"name":"vae","type":"VAE","link":vae_pos},
            {"name":"image1","shape":7,"type":"IMAGE","link":img_pos},
            {"name":"image2","shape":7,"type":"IMAGE","link":None},
            {"name":"image3","shape":7,"type":"IMAGE","link":None},
            {"name":"image4","shape":7,"type":"IMAGE","link":None},
            {"name":"target_latent","shape":7,"type":"LATENT","link":lat_pos},
        ],
        [{"name":"CONDITIONING","type":"CONDITIONING","links":[pos_ks]}],
        ["Edit the adult subject in the input image according to the requested anatomical change while preserving identity, pose, lighting, skin texture, camera angle, background, and overall photorealism."],
        "EDIT PROMPT",4
    ))

    nodes.append(node(
        NEG,"TextEncodeQwenImageEditPlus",(-230,690),(470,220),
        [
            {"name":"clip","type":"CLIP","link":clip_neg},
            {"name":"vae","type":"VAE","link":vae_neg},
            {"name":"image1","shape":7,"type":"IMAGE","link":None},
            {"name":"image2","shape":7,"type":"IMAGE","link":None},
            {"name":"image3","shape":7,"type":"IMAGE","link":None},
            {"name":"image4","shape":7,"type":"IMAGE","link":None},
            {"name":"target_latent","shape":7,"type":"LATENT","link":None},
        ],
        [{"name":"CONDITIONING","type":"CONDITIONING","links":[neg_ks]}],
        [""],"NEGATIVE — leave blank",3
    ))

    nodes.append(node(
        KS,"KSampler",(620,260),(300,270),
        [
            {"name":"model","type":"MODEL","link":model_ks},
            {"name":"positive","type":"CONDITIONING","link":pos_ks},
            {"name":"negative","type":"CONDITIONING","link":neg_ks},
            {"name":"latent_image","type":"LATENT","link":lat_ks},
        ],
        [{"name":"LATENT","type":"LATENT","links":[samp_dec]}],
        [65454653,"fixed",4,1.0,"sa_solver","beta",1.0],
        f"{mode} — CFG 1 / 4 steps",6
    ))

    nodes.append(node(
        DEC,"VAEDecode",(970,290),(180,70),
        [
            {"name":"samples","type":"LATENT","link":samp_dec},
            {"name":"vae","type":"VAE","link":vae_dec}
        ],
        [{"name":"IMAGE","type":"IMAGE","links":[dec_save]}],
        [],"DECODE",7
    ))

    nodes.append(node(
        SAVE,"SaveImage",(1210,240),(330,350),
        [{"name":"images","type":"IMAGE","link":dec_save}],
        [],
        [f"RapidAIO_{mode}"],f"SAVE — RapidAIO {mode}",8
    ))

    return {
        "id": str(uuid.uuid4()),
        "revision": 0,
        "last_node_id": 10,
        "last_link_id": lid-1,
        "nodes": nodes,
        "links": links,
        "groups": [],
        "config": {},
        "extra": {
            "ds":{"scale":0.82,"offset":[760,160]},
            "frontendVersion":"1.26.13"
        },
        "version": 0.4
    }

for mode in ("B","C","D"):
    path = OUT / f"RapidAIO_{mode}_Qwen2511.json"
    path.write_text(json.dumps(make_workflow(mode), indent=2, ensure_ascii=False))
    print("Generated:", path)
PYCODE

# ------------------------------------------------------------
# 7. README / launchers
# ------------------------------------------------------------
cat > "$WF_DIR/README_BCD.txt" <<'TXT'
Qwen Rapid-AIO B/C/D saved setup
=================================

B:
  Qwen-Rapid-AIO-NSFW-v23.safetensors only

C:
  B + Qwen-Edit_2511_penis_v2.safetensors
  Initial strength: 0.70

D:
  C + Qwen-Image-GenatomyFixer_epoch-9.safetensors
  Initial strength: 0.20

Rapid-AIO baseline:
  CFG: 1
  Steps: 4
  Text encoder: TextEncodeQwenImageEditPlus

Fair comparison:
  same input image
  same prompt
  same seed
  same output dimensions
  same sampler / scheduler
TXT

cat > "$BASE/start_8188.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$BASE"
exec "$PY" main.py --listen 0.0.0.0 --port "$PORT"
EOF
chmod +x "$BASE/start_8188.sh"

cat > "$BASE/restart_8188.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
pkill -f "main.py.*--port $PORT" 2>/dev/null || true
sleep 2
cd "$BASE"
nohup "$PY" main.py --listen 0.0.0.0 --port "$PORT" > "$BASE/comfyui_8188.log" 2>&1 &
echo "Started ComfyUI on port $PORT"
echo "Log: $BASE/comfyui_8188.log"
EOF
chmod +x "$BASE/restart_8188.sh"

# ------------------------------------------------------------
# 8. Verify files
# ------------------------------------------------------------
say "Verifying models and workflows"

for f in "$RAPID" "$PENIS" "$GENATOMY"; do
  [[ -s "$f" ]] || die "Missing model: $f"
done

for f in \
  "$WF_DIR/RapidAIO_B_Qwen2511.json" \
  "$WF_DIR/RapidAIO_C_Qwen2511.json" \
  "$WF_DIR/RapidAIO_D_Qwen2511.json"
do
  "$PY" -m json.tool "$f" >/dev/null
done

ls -lh "$RAPID" "$PENIS" "$GENATOMY"
ls -lh "$WF_DIR"/RapidAIO_[BCD]_Qwen2511.json

# ------------------------------------------------------------
# 9. Dependency / GPU report
# ------------------------------------------------------------
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

# ------------------------------------------------------------
# 10. Smoke test on alternate port
# ------------------------------------------------------------
say "Startup smoke test"

SMOKE="$LOG_DIR/smoke_saved.log"
set +e
timeout 25s "$PY" main.py --listen 127.0.0.1 --port 8197 > "$SMOKE" 2>&1
RC=$?
set -e

if [[ "$RC" != "0" && "$RC" != "124" ]]; then
  echo "---- smoke test log ----"
  tail -n 150 "$SMOKE"
  die "ComfyUI startup smoke test failed (exit $RC)."
fi

if grep -qiE 'Traceback|IMPORT FAILED|ModuleNotFoundError|SyntaxError' "$SMOKE"; then
  echo "---- smoke test log ----"
  tail -n 150 "$SMOKE"
  die "ComfyUI reported an import/startup failure."
fi

# ------------------------------------------------------------
# 11. Start the actual 8188 server
# ------------------------------------------------------------
say "Starting ComfyUI on port $PORT"

pkill -f "main.py.*--port $PORT" 2>/dev/null || true
sleep 2

nohup "$PY" main.py \
  --listen 0.0.0.0 \
  --port "$PORT" \
  > "$BASE/comfyui_8188.log" 2>&1 &

sleep 12

if ! pgrep -af "main.py.*--port $PORT" >/dev/null; then
  echo "---- 8188 startup log ----"
  tail -n 150 "$BASE/comfyui_8188.log"
  die "ComfyUI did not remain running on port $PORT."
fi

cat <<EOF

============================================================
READY — Qwen Rapid-AIO B/C/D SAVED VERSION
============================================================

ComfyUI:
  $BASE

Workflows:
  $WF_DIR/RapidAIO_B_Qwen2511.json
  $WF_DIR/RapidAIO_C_Qwen2511.json
  $WF_DIR/RapidAIO_D_Qwen2511.json

Models:
  $RAPID
  $PENIS
  $GENATOMY

Start:
  $BASE/start_8188.sh

Restart:
  $BASE/restart_8188.sh

Port:
  $PORT

Setup log:
  $LOG

Runtime log:
  $BASE/comfyui_8188.log

If the browser was already open:
  Ctrl+Shift+R

============================================================
EOF
