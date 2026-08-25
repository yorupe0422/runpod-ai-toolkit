#!/usr/bin/env bash
set -Eeuo pipefail

COMFY="${COMFY:-/workspace/runpod-slim/ComfyUI}"
WF_DIR="$COMFY/user/default/workflows"

SRC="$WF_DIR/Qwen_ImageEdit_2511_HQ_Restore_v5_BF16.json"
OUT="$WF_DIR/Qwen_ImageEdit_2511_HQ_Restore_v6_BF16_OutputFix.json"

echo "============================================================"
echo " Qwen-Image-Edit 2511 HQ v6 OUTPUT FIX"
echo " - Fixes: Prompt has no outputs"
echo " - Adds SaveImage to the top-level workflow"
echo " - Does NOT touch models or ComfyUI install"
echo "============================================================"

[[ -f "$SRC" ]] || { echo "[ERROR] Source workflow not found: $SRC"; exit 1; }

cp -f "$SRC" "$OUT"

python3 - "$OUT" <<'PY'
import json, sys
from pathlib import Path

path=Path(sys.argv[1])
data=json.loads(path.read_text(encoding="utf-8"))

nodes=data.setdefault("nodes", [])
links=data.setdefault("links", [])

# If an output node already exists, don't duplicate it.
output_types={"SaveImage","PreviewImage"}
if any(n.get("type") in output_types for n in nodes):
    print("[OK] Output node already exists.")
    path.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding="utf-8")
    raise SystemExit(0)

# Find a top-level node that exposes an IMAGE output.
source=None
slot_index=None
for n in nodes:
    outs=n.get("outputs") or []
    for i,o in enumerate(outs):
        if o.get("type")=="IMAGE":
            source=n
            slot_index=o.get("slot_index", i)
            break
    if source:
        break

if not source:
    raise SystemExit("[ERROR] No top-level IMAGE output was found in the workflow.")

# IDs in workflow JSON may be ints or strings. SaveImage requires an int id.
int_ids=[n.get("id") for n in nodes if isinstance(n.get("id"), int)]
new_node_id=max(int_ids+[0])+1

int_link_ids=[]
for l in links:
    if isinstance(l,list) and l and isinstance(l[0],int):
        int_link_ids.append(l[0])
new_link_id=max(int_link_ids+[0])+1

# Put SaveImage to the right of the composite node.
pos=source.get("pos",[0,0])
try:
    x=float(pos[0])+520
    y=float(pos[1])+120
except Exception:
    x,y=1200,200

save={
    "id": new_node_id,
    "type": "SaveImage",
    "pos": [x,y],
    "size": [420,360],
    "flags": {},
    "order": max([n.get("order",0) for n in nodes if isinstance(n.get("order",0),int)] + [0]) + 1,
    "mode": 0,
    "inputs": [
        {"name":"images","type":"IMAGE","link":new_link_id}
    ],
    "outputs": [],
    "properties": {"Node name for S&R":"SaveImage"},
    "widgets_values": ["Qwen_ImageEdit_2511_HQ_Restore"]
}
nodes.append(save)

# Attach link to source output.
outs=source.get("outputs") or []
src_out=None
for i,o in enumerate(outs):
    if o.get("type")=="IMAGE":
        src_out=o
        slot_index=o.get("slot_index",i)
        break
if src_out is None:
    raise SystemExit("[ERROR] IMAGE output disappeared unexpectedly.")

src_out.setdefault("links", [])
if src_out["links"] is None:
    src_out["links"]=[]
src_out["links"].append(new_link_id)

links.append([new_link_id, source["id"], slot_index, new_node_id, 0, "IMAGE"])

data["last_node_id"]=max(data.get("last_node_id",0) if isinstance(data.get("last_node_id",0),int) else 0, new_node_id)
data["last_link_id"]=max(data.get("last_link_id",0) if isinstance(data.get("last_link_id",0),int) else 0, new_link_id)

path.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding="utf-8")
print(f"[OK] Added SaveImage node {new_node_id}")
print(f"[OK] Connected source node {source['id']} IMAGE -> SaveImage")
PY

echo
echo "READY"
echo "Load:"
echo "  Qwen_ImageEdit_2511_HQ_Restore_v6_BF16_OutputFix.json"
echo
echo "This specifically fixes: Prompt has no outputs"
echo "============================================================"
