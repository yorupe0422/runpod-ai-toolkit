#!/usr/bin/env bash
set -Eeuo pipefail

# RunPod / ComfyUI AutoMosaic add-on v3
# NO IMAGE GENERATION.
# Adds comfyui-auto-mosaic, downloads sensitive_detect_v07.pt,
# installs a workflow, restarts ComfyUI, and verifies node/model visibility.

BASE_DIR="${BASE_DIR:-/workspace/runpod-slim}"
COMFY_DIR="${COMFY_DIR:-$BASE_DIR/ComfyUI-ZImage}"
VENV="$COMFY_DIR/.venv"
PORT="${COMFY_PORT:-8188}"
CUSTOM="$COMFY_DIR/custom_nodes/comfyui-auto-mosaic"
MODEL_DIR="$COMFY_DIR/models/ultralytics"
MODEL="$MODEL_DIR/sensitive_detect_v07.pt"
MODEL_URL="https://huggingface.co/sugarknight/sensitive-detect/resolve/main/sensitive_detect_v07.pt?download=true"
WF_NAME="booth_zimage_elusarca_nsfw_automosaic_v3.json"
WF_DIR="$COMFY_DIR/user/default/workflows"
EXPORT_DIR="$BASE_DIR/booth_workflows"
STATE="$BASE_DIR/.automosaic_v3"
LOG="$STATE/setup.log"
STATUS="$STATE/status"
PHASE="$STATE/phase"
PIDFILE="$STATE/pid"
HB="${HEARTBEAT_SECONDS:-15}"
WF_B64="ewogICJsYXN0X25vZGVfaWQiOiAxMywKICAibGFzdF9saW5rX2lkIjogMTUsCiAgIm5vZGVzIjogWwogICAgewogICAgICAiaWQiOiAxLAogICAgICAidHlwZSI6ICJVTkVUTG9hZGVyIiwKICAgICAgInBvcyI6IFsKICAgICAgICAwLAogICAgICAgIDAKICAgICAgXSwKICAgICAgInNpemUiOiBbCiAgICAgICAgMzAwLAogICAgICAgIDExMAogICAgICBdLAogICAgICAiZmxhZ3MiOiB7fSwKICAgICAgIm9yZGVyIjogMCwKICAgICAgIm1vZGUiOiAwLAogICAgICAiaW5wdXRzIjogW10sCiAgICAgICJvdXRwdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIk1PREVMIiwKICAgICAgICAgICJ0eXBlIjogIk1PREVMIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgMQogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMAogICAgICAgIH0KICAgICAgXSwKICAgICAgInByb3BlcnRpZXMiOiB7CiAgICAgICAgIk5vZGUgbmFtZSBmb3IgUyZSIjogIlVORVRMb2FkZXIiCiAgICAgIH0sCiAgICAgICJ3aWRnZXRzX3ZhbHVlcyI6IFsKICAgICAgICAiel9pbWFnZV90dXJib19iZjE2LnNhZmV0ZW5zb3JzIiwKICAgICAgICAiZGVmYXVsdCIKICAgICAgXQogICAgfSwKICAgIHsKICAgICAgImlkIjogMiwKICAgICAgInR5cGUiOiAiQ0xJUExvYWRlciIsCiAgICAgICJwb3MiOiBbCiAgICAgICAgMCwKICAgICAgICAyNDAKICAgICAgXSwKICAgICAgInNpemUiOiBbCiAgICAgICAgMzAwLAogICAgICAgIDE0MAogICAgICBdLAogICAgICAiZmxhZ3MiOiB7fSwKICAgICAgIm9yZGVyIjogMSwKICAgICAgIm1vZGUiOiAwLAogICAgICAiaW5wdXRzIjogW10sCiAgICAgICJvdXRwdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIkNMSVAiLAogICAgICAgICAgInR5cGUiOiAiQ0xJUCIsCiAgICAgICAgICAibGlua3MiOiBbCiAgICAgICAgICAgIDMKICAgICAgICAgIF0sCiAgICAgICAgICAic2xvdF9pbmRleCI6IDAKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJwcm9wZXJ0aWVzIjogewogICAgICAgICJOb2RlIG5hbWUgZm9yIFMmUiI6ICJDTElQTG9hZGVyIgogICAgICB9LAogICAgICAid2lkZ2V0c192YWx1ZXMiOiBbCiAgICAgICAgInF3ZW5fM180Yi5zYWZldGVuc29ycyIsCiAgICAgICAgImx1bWluYTIiLAogICAgICAgICJkZWZhdWx0IgogICAgICBdCiAgICB9LAogICAgewogICAgICAiaWQiOiAzLAogICAgICAidHlwZSI6ICJWQUVMb2FkZXIiLAogICAgICAicG9zIjogWwogICAgICAgIDAsCiAgICAgICAgNDYwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDMwMCwKICAgICAgICAxMTAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDIsCiAgICAgICJtb2RlIjogMCwKICAgICAgImlucHV0cyI6IFtdLAogICAgICAib3V0cHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJWQUUiLAogICAgICAgICAgInR5cGUiOiAiVkFFIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgOQogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMAogICAgICAgIH0KICAgICAgXSwKICAgICAgInByb3BlcnRpZXMiOiB7CiAgICAgICAgIk5vZGUgbmFtZSBmb3IgUyZSIjogIlZBRUxvYWRlciIKICAgICAgfSwKICAgICAgIndpZGdldHNfdmFsdWVzIjogWwogICAgICAgICJhZS5zYWZldGVuc29ycyIKICAgICAgXQogICAgfSwKICAgIHsKICAgICAgImlkIjogNCwKICAgICAgInR5cGUiOiAiQ0xJUFRleHRFbmNvZGUiLAogICAgICAicG9zIjogWwogICAgICAgIDEwODAsCiAgICAgICAgMjQwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDQ3MCwKICAgICAgICAzMDAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDYsCiAgICAgICJtb2RlIjogMCwKICAgICAgImlucHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJjbGlwIiwKICAgICAgICAgICJ0eXBlIjogIkNMSVAiLAogICAgICAgICAgImxpbmsiOiAzCiAgICAgICAgfQogICAgICBdLAogICAgICAib3V0cHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJDT05ESVRJT05JTkciLAogICAgICAgICAgInR5cGUiOiAiQ09ORElUSU9OSU5HIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgNCwKICAgICAgICAgICAgNQogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMAogICAgICAgIH0KICAgICAgXSwKICAgICAgInByb3BlcnRpZXMiOiB7CiAgICAgICAgIk5vZGUgbmFtZSBmb3IgUyZSIjogIkNMSVBUZXh0RW5jb2RlIgogICAgICB9LAogICAgICAid2lkZ2V0c192YWx1ZXMiOiBbCiAgICAgICAgImVsdXNhcmNhIGFuaW1lIHN0eWxlLCBoaWdoLXF1YWxpdHkgYW5pbWUgaWxsdXN0cmF0aW9uLCAyRCwgY2xlYW4gbGluZWFydCwgY2VsLXNoYWRlZCwgdmlicmFudCBjb2xvcnMsIHNvZnQgc2hhZGluZywgcG9saXNoZWQgSmFwYW5lc2UgYW5pbWUgY2hhcmFjdGVyIGlsbHVzdHJhdGlvbiwgYWR1bHQgY2hhcmFjdGVyLCBkZXRhaWxlZCBmYWNlIGFuZCBoYWlyLCBleHByZXNzaXZlIGFuaW1lIGV5ZXMsIG5hdHVyYWwgYm9keSBwcm9wb3J0aW9ucywgY2xlYW4gY29tcG9zaXRpb24sIHNpbXBsZSBiYWNrZ3JvdW5kIgogICAgICBdCiAgICB9LAogICAgewogICAgICAiaWQiOiA1LAogICAgICAidHlwZSI6ICJDb25kaXRpb25pbmdaZXJvT3V0IiwKICAgICAgInBvcyI6IFsKICAgICAgICAxMjkwLAogICAgICAgIDM4MAogICAgICBdLAogICAgICAic2l6ZSI6IFsKICAgICAgICAyNjAsCiAgICAgICAgODAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDcsCiAgICAgICJtb2RlIjogMCwKICAgICAgImlucHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJjb25kaXRpb25pbmciLAogICAgICAgICAgInR5cGUiOiAiQ09ORElUSU9OSU5HIiwKICAgICAgICAgICJsaW5rIjogNQogICAgICAgIH0KICAgICAgXSwKICAgICAgIm91dHB1dHMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAiQ09ORElUSU9OSU5HIiwKICAgICAgICAgICJ0eXBlIjogIkNPTkRJVElPTklORyIsCiAgICAgICAgICAibGlua3MiOiBbCiAgICAgICAgICAgIDcKICAgICAgICAgIF0sCiAgICAgICAgICAic2xvdF9pbmRleCI6IDAKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJwcm9wZXJ0aWVzIjogewogICAgICAgICJOb2RlIG5hbWUgZm9yIFMmUiI6ICJDb25kaXRpb25pbmdaZXJvT3V0IgogICAgICB9LAogICAgICAid2lkZ2V0c192YWx1ZXMiOiBbXQogICAgfSwKICAgIHsKICAgICAgImlkIjogNiwKICAgICAgInR5cGUiOiAiRW1wdHlTRDNMYXRlbnRJbWFnZSIsCiAgICAgICJwb3MiOiBbCiAgICAgICAgNzYwLAogICAgICAgIDU4MAogICAgICBdLAogICAgICAic2l6ZSI6IFsKICAgICAgICAzMDAsCiAgICAgICAgMTcwCiAgICAgIF0sCiAgICAgICJmbGFncyI6IHt9LAogICAgICAib3JkZXIiOiA4LAogICAgICAibW9kZSI6IDAsCiAgICAgICJpbnB1dHMiOiBbXSwKICAgICAgIm91dHB1dHMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAiTEFURU5UIiwKICAgICAgICAgICJ0eXBlIjogIkxBVEVOVCIsCiAgICAgICAgICAibGlua3MiOiBbCiAgICAgICAgICAgIDgKICAgICAgICAgIF0sCiAgICAgICAgICAic2xvdF9pbmRleCI6IDAKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJwcm9wZXJ0aWVzIjogewogICAgICAgICJOb2RlIG5hbWUgZm9yIFMmUiI6ICJFbXB0eVNEM0xhdGVudEltYWdlIgogICAgICB9LAogICAgICAid2lkZ2V0c192YWx1ZXMiOiBbCiAgICAgICAgODMyLAogICAgICAgIDEyMTYsCiAgICAgICAgMQogICAgICBdCiAgICB9LAogICAgewogICAgICAiaWQiOiA3LAogICAgICAidHlwZSI6ICJNb2RlbFNhbXBsaW5nQXVyYUZsb3ciLAogICAgICAicG9zIjogWwogICAgICAgIDEwODAsCiAgICAgICAgMjAKICAgICAgXSwKICAgICAgInNpemUiOiBbCiAgICAgICAgMzAwLAogICAgICAgIDExMAogICAgICBdLAogICAgICAiZmxhZ3MiOiB7fSwKICAgICAgIm9yZGVyIjogNSwKICAgICAgIm1vZGUiOiAwLAogICAgICAiaW5wdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIm1vZGVsIiwKICAgICAgICAgICJ0eXBlIjogIk1PREVMIiwKICAgICAgICAgICJsaW5rIjogMTMKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJvdXRwdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIk1PREVMIiwKICAgICAgICAgICJ0eXBlIjogIk1PREVMIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgNgogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMAogICAgICAgIH0KICAgICAgXSwKICAgICAgInByb3BlcnRpZXMiOiB7CiAgICAgICAgIk5vZGUgbmFtZSBmb3IgUyZSIjogIk1vZGVsU2FtcGxpbmdBdXJhRmxvdyIKICAgICAgfSwKICAgICAgIndpZGdldHNfdmFsdWVzIjogWwogICAgICAgIDMKICAgICAgXQogICAgfSwKICAgIHsKICAgICAgImlkIjogOCwKICAgICAgInR5cGUiOiAiS1NhbXBsZXIiLAogICAgICAicG9zIjogWwogICAgICAgIDE3MDAsCiAgICAgICAgMTEwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDMzMCwKICAgICAgICAzNDAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDksCiAgICAgICJtb2RlIjogMCwKICAgICAgImlucHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJtb2RlbCIsCiAgICAgICAgICAidHlwZSI6ICJNT0RFTCIsCiAgICAgICAgICAibGluayI6IDYKICAgICAgICB9LAogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogInBvc2l0aXZlIiwKICAgICAgICAgICJ0eXBlIjogIkNPTkRJVElPTklORyIsCiAgICAgICAgICAibGluayI6IDQKICAgICAgICB9LAogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIm5lZ2F0aXZlIiwKICAgICAgICAgICJ0eXBlIjogIkNPTkRJVElPTklORyIsCiAgICAgICAgICAibGluayI6IDcKICAgICAgICB9LAogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogImxhdGVudF9pbWFnZSIsCiAgICAgICAgICAidHlwZSI6ICJMQVRFTlQiLAogICAgICAgICAgImxpbmsiOiA4CiAgICAgICAgfQogICAgICBdLAogICAgICAib3V0cHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJMQVRFTlQiLAogICAgICAgICAgInR5cGUiOiAiTEFURU5UIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgMTAKICAgICAgICAgIF0sCiAgICAgICAgICAic2xvdF9pbmRleCI6IDAKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJwcm9wZXJ0aWVzIjogewogICAgICAgICJOb2RlIG5hbWUgZm9yIFMmUiI6ICJLU2FtcGxlciIKICAgICAgfSwKICAgICAgIndpZGdldHNfdmFsdWVzIjogWwogICAgICAgIDAsCiAgICAgICAgInJhbmRvbWl6ZSIsCiAgICAgICAgOCwKICAgICAgICAxLjAsCiAgICAgICAgInJlc19tdWx0aXN0ZXAiLAogICAgICAgICJzaW1wbGUiLAogICAgICAgIDEuMAogICAgICBdCiAgICB9LAogICAgewogICAgICAiaWQiOiA5LAogICAgICAidHlwZSI6ICJWQUVEZWNvZGUiLAogICAgICAicG9zIjogWwogICAgICAgIDIxMDAsCiAgICAgICAgMTEwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDI1MCwKICAgICAgICAxMDAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDEwLAogICAgICAibW9kZSI6IDAsCiAgICAgICJpbnB1dHMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAic2FtcGxlcyIsCiAgICAgICAgICAidHlwZSI6ICJMQVRFTlQiLAogICAgICAgICAgImxpbmsiOiAxMAogICAgICAgIH0sCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAidmFlIiwKICAgICAgICAgICJ0eXBlIjogIlZBRSIsCiAgICAgICAgICAibGluayI6IDkKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJvdXRwdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIklNQUdFIiwKICAgICAgICAgICJ0eXBlIjogIklNQUdFIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgMTQKICAgICAgICAgIF0sCiAgICAgICAgICAic2xvdF9pbmRleCI6IDAKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJwcm9wZXJ0aWVzIjogewogICAgICAgICJOb2RlIG5hbWUgZm9yIFMmUiI6ICJWQUVEZWNvZGUiCiAgICAgIH0sCiAgICAgICJ3aWRnZXRzX3ZhbHVlcyI6IFtdCiAgICB9LAogICAgewogICAgICAiaWQiOiAxMCwKICAgICAgInR5cGUiOiAiU2F2ZUltYWdlIiwKICAgICAgInBvcyI6IFsKICAgICAgICAyNDUwLAogICAgICAgIDkwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDUwMCwKICAgICAgICA1MDAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDExLAogICAgICAibW9kZSI6IDAsCiAgICAgICJpbnB1dHMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAiaW1hZ2VzIiwKICAgICAgICAgICJ0eXBlIjogIklNQUdFIiwKICAgICAgICAgICJsaW5rIjogMTUKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJvdXRwdXRzIjogW10sCiAgICAgICJwcm9wZXJ0aWVzIjogewogICAgICAgICJOb2RlIG5hbWUgZm9yIFMmUiI6ICJTYXZlSW1hZ2UiCiAgICAgIH0sCiAgICAgICJ3aWRnZXRzX3ZhbHVlcyI6IFsKICAgICAgICAiYm9vdGhfdGVzdC96aW1hZ2VfZWx1c2FyY2FfYW5pbWUiCiAgICAgIF0KICAgIH0sCiAgICB7CiAgICAgICJpZCI6IDExLAogICAgICAidHlwZSI6ICJMb3JhTG9hZGVyTW9kZWxPbmx5IiwKICAgICAgInBvcyI6IFsKICAgICAgICAzNjAsCiAgICAgICAgMAogICAgICBdLAogICAgICAic2l6ZSI6IFsKICAgICAgICAzMjAsCiAgICAgICAgMTMwCiAgICAgIF0sCiAgICAgICJmbGFncyI6IHt9LAogICAgICAib3JkZXIiOiAzLAogICAgICAibW9kZSI6IDAsCiAgICAgICJpbnB1dHMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAibW9kZWwiLAogICAgICAgICAgInR5cGUiOiAiTU9ERUwiLAogICAgICAgICAgImxpbmsiOiAxCiAgICAgICAgfQogICAgICBdLAogICAgICAib3V0cHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJNT0RFTCIsCiAgICAgICAgICAidHlwZSI6ICJNT0RFTCIsCiAgICAgICAgICAibGlua3MiOiBbCiAgICAgICAgICAgIDEyCiAgICAgICAgICBdLAogICAgICAgICAgInNsb3RfaW5kZXgiOiAwCiAgICAgICAgfQogICAgICBdLAogICAgICAidGl0bGUiOiAiTG9SQSAxIC0gRWx1c2FyY2EgQW5pbWUgU3R5bGUiLAogICAgICAicHJvcGVydGllcyI6IHsKICAgICAgICAiTm9kZSBuYW1lIGZvciBTJlIiOiAiTG9yYUxvYWRlck1vZGVsT25seSIKICAgICAgfSwKICAgICAgIndpZGdldHNfdmFsdWVzIjogWwogICAgICAgICJlbHVzYXJjYS1hbmltZS1zdHlsZS5zYWZldGVuc29ycyIsCiAgICAgICAgMS4wCiAgICAgIF0KICAgIH0sCiAgICB7CiAgICAgICJpZCI6IDEyLAogICAgICAidHlwZSI6ICJMb3JhTG9hZGVyTW9kZWxPbmx5IiwKICAgICAgInBvcyI6IFsKICAgICAgICA3MjAsCiAgICAgICAgMAogICAgICBdLAogICAgICAic2l6ZSI6IFsKICAgICAgICAzMjAsCiAgICAgICAgMTUwCiAgICAgIF0sCiAgICAgICJmbGFncyI6IHt9LAogICAgICAib3JkZXIiOiA0LAogICAgICAibW9kZSI6IDAsCiAgICAgICJpbnB1dHMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAibW9kZWwiLAogICAgICAgICAgInR5cGUiOiAiTU9ERUwiLAogICAgICAgICAgImxpbmsiOiAxMgogICAgICAgIH0KICAgICAgXSwKICAgICAgIm91dHB1dHMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAiTU9ERUwiLAogICAgICAgICAgInR5cGUiOiAiTU9ERUwiLAogICAgICAgICAgImxpbmtzIjogWwogICAgICAgICAgICAxMwogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMAogICAgICAgIH0KICAgICAgXSwKICAgICAgInRpdGxlIjogIkxvUkEgMiAtIE5TRlcgLyBDb21wYXJpc29uIChzZWxlY3RhYmxlKSIsCiAgICAgICJwcm9wZXJ0aWVzIjogewogICAgICAgICJOb2RlIG5hbWUgZm9yIFMmUiI6ICJMb3JhTG9hZGVyTW9kZWxPbmx5IgogICAgICB9LAogICAgICAid2lkZ2V0c192YWx1ZXMiOiBbCiAgICAgICAgIm5zZndfY29tcGFyZS9TRUxFQ1RfQUZURVJfSU5TVEFMTC5zYWZldGVuc29ycyIsCiAgICAgICAgMC4wCiAgICAgIF0KICAgIH0sCiAgICB7CiAgICAgICJpZCI6IDEzLAogICAgICAidHlwZSI6ICJBdXRvTW9zYWljIiwKICAgICAgInBvcyI6IFsKICAgICAgICAyMDAwLAogICAgICAgIDkwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDM3MCwKICAgICAgICAzMzAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDEyLAogICAgICAibW9kZSI6IDAsCiAgICAgICJpbnB1dHMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAiaW1hZ2UiLAogICAgICAgICAgInR5cGUiOiAiSU1BR0UiLAogICAgICAgICAgImxpbmsiOiAxNAogICAgICAgIH0KICAgICAgXSwKICAgICAgIm91dHB1dHMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAiSU1BR0UiLAogICAgICAgICAgInR5cGUiOiAiSU1BR0UiLAogICAgICAgICAgImxpbmtzIjogWwogICAgICAgICAgICAxNQogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMAogICAgICAgIH0sCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAiTUFTSyIsCiAgICAgICAgICAidHlwZSI6ICJNQVNLIiwKICAgICAgICAgICJsaW5rcyI6IG51bGwsCiAgICAgICAgICAic2xvdF9pbmRleCI6IDEKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJ0aXRsZSI6ICJBdXRvIE1vc2FpYyAtIGZpbmFsIGNlbnNvcmluZyIsCiAgICAgICJwcm9wZXJ0aWVzIjogewogICAgICAgICJOb2RlIG5hbWUgZm9yIFMmUiI6ICJBdXRvTW9zYWljIgogICAgICB9LAogICAgICAid2lkZ2V0c192YWx1ZXMiOiBbCiAgICAgICAgZmFsc2UsCiAgICAgICAgImJvb3RoX21vc2FpYyIsCiAgICAgICAgMC4yNSwKICAgICAgICAibW9zYWljIiwKICAgICAgICAxMDAsCiAgICAgICAgInB1c3N5LHBlbmlzIiwKICAgICAgICAic2Vuc2l0aXZlX2RldGVjdF92MDcucHQiLAogICAgICAgIDEuMCwKICAgICAgICBmYWxzZSwKICAgICAgICAxMCwKICAgICAgICAic2ltcGxlIiwKICAgICAgICAiTm9uZSIKICAgICAgXQogICAgfQogIF0sCiAgImxpbmtzIjogWwogICAgWwogICAgICAxLAogICAgICAxLAogICAgICAwLAogICAgICAxMSwKICAgICAgMCwKICAgICAgIk1PREVMIgogICAgXSwKICAgIFsKICAgICAgMywKICAgICAgMiwKICAgICAgMCwKICAgICAgNCwKICAgICAgMCwKICAgICAgIkNMSVAiCiAgICBdLAogICAgWwogICAgICA0LAogICAgICA0LAogICAgICAwLAogICAgICA4LAogICAgICAxLAogICAgICAiQ09ORElUSU9OSU5HIgogICAgXSwKICAgIFsKICAgICAgNSwKICAgICAgNCwKICAgICAgMCwKICAgICAgNSwKICAgICAgMCwKICAgICAgIkNPTkRJVElPTklORyIKICAgIF0sCiAgICBbCiAgICAgIDYsCiAgICAgIDcsCiAgICAgIDAsCiAgICAgIDgsCiAgICAgIDAsCiAgICAgICJNT0RFTCIKICAgIF0sCiAgICBbCiAgICAgIDcsCiAgICAgIDUsCiAgICAgIDAsCiAgICAgIDgsCiAgICAgIDIsCiAgICAgICJDT05ESVRJT05JTkciCiAgICBdLAogICAgWwogICAgICA4LAogICAgICA2LAogICAgICAwLAogICAgICA4LAogICAgICAzLAogICAgICAiTEFURU5UIgogICAgXSwKICAgIFsKICAgICAgOSwKICAgICAgMywKICAgICAgMCwKICAgICAgOSwKICAgICAgMSwKICAgICAgIlZBRSIKICAgIF0sCiAgICBbCiAgICAgIDEwLAogICAgICA4LAogICAgICAwLAogICAgICA5LAogICAgICAwLAogICAgICAiTEFURU5UIgogICAgXSwKICAgIFsKICAgICAgMTIsCiAgICAgIDExLAogICAgICAwLAogICAgICAxMiwKICAgICAgMCwKICAgICAgIk1PREVMIgogICAgXSwKICAgIFsKICAgICAgMTMsCiAgICAgIDEyLAogICAgICAwLAogICAgICA3LAogICAgICAwLAogICAgICAiTU9ERUwiCiAgICBdLAogICAgWwogICAgICAxNCwKICAgICAgOSwKICAgICAgMCwKICAgICAgMTMsCiAgICAgIDAsCiAgICAgICJJTUFHRSIKICAgIF0sCiAgICBbCiAgICAgIDE1LAogICAgICAxMywKICAgICAgMCwKICAgICAgMTAsCiAgICAgIDAsCiAgICAgICJJTUFHRSIKICAgIF0KICBdLAogICJncm91cHMiOiBbXSwKICAiY29uZmlnIjoge30sCiAgImV4dHJhIjogewogICAgImRzIjogewogICAgICAic2NhbGUiOiAwLjY4LAogICAgICAib2Zmc2V0IjogWwogICAgICAgIDgwLAogICAgICAgIDEwMAogICAgICBdCiAgICB9CiAgfSwKICAidmVyc2lvbiI6IDAuNAp9"

mkdir -p "$STATE"
ts(){ date '+%Y-%m-%d %H:%M:%S'; }
say(){ echo; echo "================================================================"; echo "[$(ts)] $*"; echo "================================================================"; }
phase(){ echo "$*" > "$PHASE"; }
alive(){ [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null; }

status(){
  echo "Status : $(cat "$STATUS" 2>/dev/null || echo NOT_STARTED)"
  echo "Phase  : $(cat "$PHASE" 2>/dev/null || echo -)"
  echo "Log    : $LOG"
  echo "Node   : $CUSTOM"
  echo "Model  : $MODEL"
  echo "WF     : $WF_DIR/$WF_NAME"
}
follow(){ touch "$LOG"; tail -n 100 -F "$LOG"; }

preflight(){
  say "Preflight"
  phase "Preflight"
  [[ -f "$COMFY_DIR/main.py" ]] || { echo "[FATAL] Missing $COMFY_DIR/main.py"; exit 10; }
  [[ -x "$VENV/bin/python" ]] || { echo "[FATAL] Missing $VENV/bin/python"; exit 11; }
  command -v git >/dev/null || { apt-get update -y && apt-get install -y git; }
  command -v curl >/dev/null || { apt-get update -y && apt-get install -y curl; }
  command -v lsof >/dev/null || { apt-get update -y && apt-get install -y lsof; }
  mkdir -p "$MODEL_DIR" "$WF_DIR" "$EXPORT_DIR"
  "$VENV/bin/python" - <<'PY'
import torch
print("Python/Torch OK:", torch.__version__)
print("CUDA available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))
PY
}

install_node(){
  say "Install/update ComfyUI AutoMosaic"
  phase "Install custom node"
  if [[ -d "$CUSTOM/.git" ]]; then
    git -C "$CUSTOM" fetch --all --prune
    git -C "$CUSTOM" reset --hard origin/master
  else
    rm -rf "$CUSTOM"
    git clone --depth 1 https://github.com/sugarkwork/comfyui-auto-mosaic.git "$CUSTOM"
  fi
  echo "AutoMosaic commit: $(git -C "$CUSTOM" rev-parse HEAD)"

  # Preserve the working Z-Image torch stack: do NOT reinstall torch/torchvision.
  "$VENV/bin/python" -m pip install --upgrade-strategy only-if-needed ultralytics opencv-python-headless

  "$VENV/bin/python" - <<'PY'
import torch, cv2, ultralytics
print("torch:", torch.__version__)
print("opencv:", cv2.__version__)
print("ultralytics:", ultralytics.__version__)
assert torch.cuda.is_available(), "CUDA unavailable after dependency install"
PY
}

download_model(){
  say "Download/verify sensitive_detect_v07.pt"
  phase "Download detection model"
  if [[ ! -s "$MODEL" || $(stat -c%s "$MODEL" 2>/dev/null || echo 0) -lt 50000000 ]]; then
    rm -f "$MODEL"
    curl -fL --retry 8 --retry-delay 3 --continue-at - -o "$MODEL" "$MODEL_URL"
  fi
  local bytes
  bytes="$(stat -c%s "$MODEL")"
  [[ "$bytes" -gt 50000000 ]] || { echo "[FATAL] Model file too small: $bytes"; exit 20; }
  echo "[OK] model bytes=$bytes sha256=$(sha256sum "$MODEL" | awk '{print $1}')"
}

write_wf(){
  say "Install AutoMosaic workflow"
  phase "Write workflow"
  "$VENV/bin/python" - "$WF_B64" "$WF_DIR/$WF_NAME" "$EXPORT_DIR/$WF_NAME" <<'PY'
import base64,json,pathlib,sys
obj=json.loads(base64.b64decode(sys.argv[1]).decode())
for p in map(pathlib.Path, sys.argv[2:]):
    p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(json.dumps(obj,ensure_ascii=False,indent=2),encoding="utf-8")
    print("WROTE",p)
PY
}

restart(){
  say "Restart ComfyUI safely"
  phase "Restart ComfyUI"
  local listeners
  listeners="$(lsof -ti TCP:"$PORT" -sTCP:LISTEN 2>/dev/null | sort -u || true)"
  for pid in $listeners; do
    local cwd cmd
    cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    if [[ "$cwd" == "$COMFY_DIR" || "$cmd" == *"$COMFY_DIR/main.py"* ]]; then
      kill "$pid" 2>/dev/null || true
      for _ in {1..30}; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    else
      echo "[FATAL] Port $PORT belongs to another environment; refusing to kill PID $pid"
      exit 30
    fi
  done

  cd "$COMFY_DIR"
  nohup "$VENV/bin/python" main.py --listen 0.0.0.0 --port "$PORT" --preview-method auto \
    > comfyui_8188.log 2>&1 < /dev/null &
  local cp=$!
  echo "$cp" > comfyui_8188.pid
  for i in {1..60}; do
    if curl -fsS "http://127.0.0.1:$PORT/system_stats" >/dev/null 2>&1; then
      echo "[OK] ComfyUI ready"
      return
    fi
    kill -0 "$cp" 2>/dev/null || { tail -n 160 comfyui_8188.log; exit 31; }
    echo "[ALIVE] ComfyUI startup elapsed=$((i*5))s PID=$cp"
    sleep 5
  done
  tail -n 160 comfyui_8188.log
  exit 32
}

verify(){
  say "Verify AutoMosaic node (NO image generation)"
  phase "Verify"
  "$VENV/bin/python" - "$PORT" <<'PY'
import json,sys,urllib.request
p=int(sys.argv[1])
with urllib.request.urlopen(f"http://127.0.0.1:{p}/object_info",timeout=60) as r:
    o=json.load(r)
assert "AutoMosaic" in o, "AutoMosaic node not loaded"
req=o["AutoMosaic"]["input"]["required"]
print("[OK] AutoMosaic loaded")
print("process_method:", req["process_method"][0])
print("model choices:", req["model_name"][0])
assert "sensitive_detect_v07.pt" in req["model_name"][0]
print("[OK] sensitive_detect_v07.pt visible")
print("NO IMAGE GENERATION PERFORMED")
PY
}

worker(){
  trap '' HUP
  echo $$ > "$PIDFILE"
  echo RUNNING > "$STATUS"
  local hb_pid=""
  cleanup(){ [[ -n "${hb_pid:-}" ]] && kill "$hb_pid" 2>/dev/null || true; }
  trap cleanup EXIT
  (
    while true; do
      sleep "$HB"
      echo "[HEARTBEAT $(ts)] status=$(cat "$STATUS" 2>/dev/null || echo ?) phase=$(cat "$PHASE" 2>/dev/null || echo ?)"
    done
  ) &
  hb_pid=$!

  preflight
  install_node
  download_model
  write_wf
  restart
  verify
  echo READY > "$STATUS"
  phase READY
  say "READY"
  echo "Workflow: $WF_DIR/$WF_NAME"
  echo "AutoMosaic: confidence=0.25 method=mosaic factor=100 mask_expand=1.0%"
  echo "No image was generated."
}

launch(){
  local p="$(cat "$PIDFILE" 2>/dev/null || true)"
  if alive "$p"; then echo "Already running PID=$p"; follow; return; fi
  : > "$LOG"
  nohup bash "${BASH_SOURCE[0]}" --worker >> "$LOG" 2>&1 < /dev/null &
  echo $! > "$PIDFILE"
  echo "Started detached installer PID=$!"
  echo "It continues if the browser terminal disconnects."
  sleep 1
  follow
}

case "${1:-}" in
  --worker) exec > >(tee -a "$LOG") 2>&1; worker ;;
  --status) status ;;
  --follow) follow ;;
  "") launch ;;
  *) echo "Usage: $0 [--status|--follow]"; exit 2 ;;
esac
