#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# RunPod Z-Image + Elusarca + selectable NSFW LoRA comparison pack v2
#
# IMPORTANT
#   * THIS SCRIPT DOES NOT GENERATE IMAGES.
#   * It only downloads/validates LoRA files, installs a workflow,
#     restarts ComfyUI, and verifies model visibility.
#   * Existing Z-Image / PyTorch / ComfyUI core files are not upgraded.
#
# Expected environment:
#   /workspace/runpod-slim/ComfyUI-ZImage
#
# Workflow architecture:
#   Z-Image UNET
#      -> LoRA 1: Elusarca Anime Style
#      -> LoRA 2: selectable NSFW/comparison LoRA
#      -> ModelSamplingAuraFlow
#      -> KSampler
#
# Commercial-use note:
#   The installer writes a manifest separating:
#   - license-explicit candidates
#   - comparison-only / license-unconfirmed candidates
#   Do not treat "downloadable" as "cleared for commercial use".
###############################################################################

SCRIPT_NAME="runpod_zimage_elusarca_nsfw_compare_v2"
BASE_DIR="${BASE_DIR:-/workspace/runpod-slim}"
COMFY_DIR="${COMFY_DIR:-${BASE_DIR}/ComfyUI-ZImage}"
VENV_DIR="${VENV_DIR:-${COMFY_DIR}/.venv}"
PORT="${COMFY_PORT:-8188}"
HOST="${COMFY_HOST:-0.0.0.0}"

LORA_DIR="${COMFY_DIR}/models/loras"
COMPARE_DIR="${LORA_DIR}/nsfw_compare"
WORKFLOW_DIR="${COMFY_DIR}/user/default/workflows"
EXPORT_DIR="${BASE_DIR}/booth_workflows"
WORKFLOW_NAME="booth_zimage_elusarca_nsfw_compare_v2.json"
WORKFLOW_B64="ewogICJsYXN0X25vZGVfaWQiOiAxMiwKICAibGFzdF9saW5rX2lkIjogMTMsCiAgIm5vZGVzIjogWwogICAgewogICAgICAiaWQiOiAxLAogICAgICAidHlwZSI6ICJVTkVUTG9hZGVyIiwKICAgICAgInBvcyI6IFsKICAgICAgICAwLAogICAgICAgIDAKICAgICAgXSwKICAgICAgInNpemUiOiBbCiAgICAgICAgMzAwLAogICAgICAgIDExMAogICAgICBdLAogICAgICAiZmxhZ3MiOiB7fSwKICAgICAgIm9yZGVyIjogMCwKICAgICAgIm1vZGUiOiAwLAogICAgICAiaW5wdXRzIjogW10sCiAgICAgICJvdXRwdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIk1PREVMIiwKICAgICAgICAgICJ0eXBlIjogIk1PREVMIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgMQogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMAogICAgICAgIH0KICAgICAgXSwKICAgICAgInByb3BlcnRpZXMiOiB7CiAgICAgICAgIk5vZGUgbmFtZSBmb3IgUyZSIjogIlVORVRMb2FkZXIiCiAgICAgIH0sCiAgICAgICJ3aWRnZXRzX3ZhbHVlcyI6IFsKICAgICAgICAiel9pbWFnZV90dXJib19iZjE2LnNhZmV0ZW5zb3JzIiwKICAgICAgICAiZGVmYXVsdCIKICAgICAgXQogICAgfSwKICAgIHsKICAgICAgImlkIjogMiwKICAgICAgInR5cGUiOiAiQ0xJUExvYWRlciIsCiAgICAgICJwb3MiOiBbCiAgICAgICAgMCwKICAgICAgICAyNDAKICAgICAgXSwKICAgICAgInNpemUiOiBbCiAgICAgICAgMzAwLAogICAgICAgIDE0MAogICAgICBdLAogICAgICAiZmxhZ3MiOiB7fSwKICAgICAgIm9yZGVyIjogMSwKICAgICAgIm1vZGUiOiAwLAogICAgICAiaW5wdXRzIjogW10sCiAgICAgICJvdXRwdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIkNMSVAiLAogICAgICAgICAgInR5cGUiOiAiQ0xJUCIsCiAgICAgICAgICAibGlua3MiOiBbCiAgICAgICAgICAgIDMKICAgICAgICAgIF0sCiAgICAgICAgICAic2xvdF9pbmRleCI6IDAKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJwcm9wZXJ0aWVzIjogewogICAgICAgICJOb2RlIG5hbWUgZm9yIFMmUiI6ICJDTElQTG9hZGVyIgogICAgICB9LAogICAgICAid2lkZ2V0c192YWx1ZXMiOiBbCiAgICAgICAgInF3ZW5fM180Yi5zYWZldGVuc29ycyIsCiAgICAgICAgImx1bWluYTIiLAogICAgICAgICJkZWZhdWx0IgogICAgICBdCiAgICB9LAogICAgewogICAgICAiaWQiOiAzLAogICAgICAidHlwZSI6ICJWQUVMb2FkZXIiLAogICAgICAicG9zIjogWwogICAgICAgIDAsCiAgICAgICAgNDYwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDMwMCwKICAgICAgICAxMTAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDIsCiAgICAgICJtb2RlIjogMCwKICAgICAgImlucHV0cyI6IFtdLAogICAgICAib3V0cHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJWQUUiLAogICAgICAgICAgInR5cGUiOiAiVkFFIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgOQogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMAogICAgICAgIH0KICAgICAgXSwKICAgICAgInByb3BlcnRpZXMiOiB7CiAgICAgICAgIk5vZGUgbmFtZSBmb3IgUyZSIjogIlZBRUxvYWRlciIKICAgICAgfSwKICAgICAgIndpZGdldHNfdmFsdWVzIjogWwogICAgICAgICJhZS5zYWZldGVuc29ycyIKICAgICAgXQogICAgfSwKICAgIHsKICAgICAgImlkIjogNCwKICAgICAgInR5cGUiOiAiQ0xJUFRleHRFbmNvZGUiLAogICAgICAicG9zIjogWwogICAgICAgIDEwODAsCiAgICAgICAgMjQwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDQ3MCwKICAgICAgICAzMDAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDYsCiAgICAgICJtb2RlIjogMCwKICAgICAgImlucHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJjbGlwIiwKICAgICAgICAgICJ0eXBlIjogIkNMSVAiLAogICAgICAgICAgImxpbmsiOiAzCiAgICAgICAgfQogICAgICBdLAogICAgICAib3V0cHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJDT05ESVRJT05JTkciLAogICAgICAgICAgInR5cGUiOiAiQ09ORElUSU9OSU5HIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgNCwKICAgICAgICAgICAgNQogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMAogICAgICAgIH0KICAgICAgXSwKICAgICAgInByb3BlcnRpZXMiOiB7CiAgICAgICAgIk5vZGUgbmFtZSBmb3IgUyZSIjogIkNMSVBUZXh0RW5jb2RlIgogICAgICB9LAogICAgICAid2lkZ2V0c192YWx1ZXMiOiBbCiAgICAgICAgImVsdXNhcmNhIGFuaW1lIHN0eWxlLCBoaWdoLXF1YWxpdHkgYW5pbWUgaWxsdXN0cmF0aW9uLCAyRCwgY2xlYW4gbGluZWFydCwgY2VsLXNoYWRlZCwgdmlicmFudCBjb2xvcnMsIHNvZnQgc2hhZGluZywgcG9saXNoZWQgSmFwYW5lc2UgYW5pbWUgY2hhcmFjdGVyIGlsbHVzdHJhdGlvbiwgYWR1bHQgY2hhcmFjdGVyLCBkZXRhaWxlZCBmYWNlIGFuZCBoYWlyLCBleHByZXNzaXZlIGFuaW1lIGV5ZXMsIG5hdHVyYWwgYm9keSBwcm9wb3J0aW9ucywgY2xlYW4gY29tcG9zaXRpb24sIHNpbXBsZSBiYWNrZ3JvdW5kIgogICAgICBdCiAgICB9LAogICAgewogICAgICAiaWQiOiA1LAogICAgICAidHlwZSI6ICJDb25kaXRpb25pbmdaZXJvT3V0IiwKICAgICAgInBvcyI6IFsKICAgICAgICAxMjkwLAogICAgICAgIDM4MAogICAgICBdLAogICAgICAic2l6ZSI6IFsKICAgICAgICAyNjAsCiAgICAgICAgODAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDcsCiAgICAgICJtb2RlIjogMCwKICAgICAgImlucHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJjb25kaXRpb25pbmciLAogICAgICAgICAgInR5cGUiOiAiQ09ORElUSU9OSU5HIiwKICAgICAgICAgICJsaW5rIjogNQogICAgICAgIH0KICAgICAgXSwKICAgICAgIm91dHB1dHMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAiQ09ORElUSU9OSU5HIiwKICAgICAgICAgICJ0eXBlIjogIkNPTkRJVElPTklORyIsCiAgICAgICAgICAibGlua3MiOiBbCiAgICAgICAgICAgIDcKICAgICAgICAgIF0sCiAgICAgICAgICAic2xvdF9pbmRleCI6IDAKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJwcm9wZXJ0aWVzIjogewogICAgICAgICJOb2RlIG5hbWUgZm9yIFMmUiI6ICJDb25kaXRpb25pbmdaZXJvT3V0IgogICAgICB9LAogICAgICAid2lkZ2V0c192YWx1ZXMiOiBbXQogICAgfSwKICAgIHsKICAgICAgImlkIjogNiwKICAgICAgInR5cGUiOiAiRW1wdHlTRDNMYXRlbnRJbWFnZSIsCiAgICAgICJwb3MiOiBbCiAgICAgICAgNzYwLAogICAgICAgIDU4MAogICAgICBdLAogICAgICAic2l6ZSI6IFsKICAgICAgICAzMDAsCiAgICAgICAgMTcwCiAgICAgIF0sCiAgICAgICJmbGFncyI6IHt9LAogICAgICAib3JkZXIiOiA4LAogICAgICAibW9kZSI6IDAsCiAgICAgICJpbnB1dHMiOiBbXSwKICAgICAgIm91dHB1dHMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAiTEFURU5UIiwKICAgICAgICAgICJ0eXBlIjogIkxBVEVOVCIsCiAgICAgICAgICAibGlua3MiOiBbCiAgICAgICAgICAgIDgKICAgICAgICAgIF0sCiAgICAgICAgICAic2xvdF9pbmRleCI6IDAKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJwcm9wZXJ0aWVzIjogewogICAgICAgICJOb2RlIG5hbWUgZm9yIFMmUiI6ICJFbXB0eVNEM0xhdGVudEltYWdlIgogICAgICB9LAogICAgICAid2lkZ2V0c192YWx1ZXMiOiBbCiAgICAgICAgODMyLAogICAgICAgIDEyMTYsCiAgICAgICAgMQogICAgICBdCiAgICB9LAogICAgewogICAgICAiaWQiOiA3LAogICAgICAidHlwZSI6ICJNb2RlbFNhbXBsaW5nQXVyYUZsb3ciLAogICAgICAicG9zIjogWwogICAgICAgIDEwODAsCiAgICAgICAgMjAKICAgICAgXSwKICAgICAgInNpemUiOiBbCiAgICAgICAgMzAwLAogICAgICAgIDExMAogICAgICBdLAogICAgICAiZmxhZ3MiOiB7fSwKICAgICAgIm9yZGVyIjogNSwKICAgICAgIm1vZGUiOiAwLAogICAgICAiaW5wdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIm1vZGVsIiwKICAgICAgICAgICJ0eXBlIjogIk1PREVMIiwKICAgICAgICAgICJsaW5rIjogMTMKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJvdXRwdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIk1PREVMIiwKICAgICAgICAgICJ0eXBlIjogIk1PREVMIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgNgogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMAogICAgICAgIH0KICAgICAgXSwKICAgICAgInByb3BlcnRpZXMiOiB7CiAgICAgICAgIk5vZGUgbmFtZSBmb3IgUyZSIjogIk1vZGVsU2FtcGxpbmdBdXJhRmxvdyIKICAgICAgfSwKICAgICAgIndpZGdldHNfdmFsdWVzIjogWwogICAgICAgIDMKICAgICAgXQogICAgfSwKICAgIHsKICAgICAgImlkIjogOCwKICAgICAgInR5cGUiOiAiS1NhbXBsZXIiLAogICAgICAicG9zIjogWwogICAgICAgIDE3MDAsCiAgICAgICAgMTEwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDMzMCwKICAgICAgICAzNDAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDksCiAgICAgICJtb2RlIjogMCwKICAgICAgImlucHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJtb2RlbCIsCiAgICAgICAgICAidHlwZSI6ICJNT0RFTCIsCiAgICAgICAgICAibGluayI6IDYKICAgICAgICB9LAogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogInBvc2l0aXZlIiwKICAgICAgICAgICJ0eXBlIjogIkNPTkRJVElPTklORyIsCiAgICAgICAgICAibGluayI6IDQKICAgICAgICB9LAogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIm5lZ2F0aXZlIiwKICAgICAgICAgICJ0eXBlIjogIkNPTkRJVElPTklORyIsCiAgICAgICAgICAibGluayI6IDcKICAgICAgICB9LAogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogImxhdGVudF9pbWFnZSIsCiAgICAgICAgICAidHlwZSI6ICJMQVRFTlQiLAogICAgICAgICAgImxpbmsiOiA4CiAgICAgICAgfQogICAgICBdLAogICAgICAib3V0cHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJMQVRFTlQiLAogICAgICAgICAgInR5cGUiOiAiTEFURU5UIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgMTAKICAgICAgICAgIF0sCiAgICAgICAgICAic2xvdF9pbmRleCI6IDAKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJwcm9wZXJ0aWVzIjogewogICAgICAgICJOb2RlIG5hbWUgZm9yIFMmUiI6ICJLU2FtcGxlciIKICAgICAgfSwKICAgICAgIndpZGdldHNfdmFsdWVzIjogWwogICAgICAgIDAsCiAgICAgICAgInJhbmRvbWl6ZSIsCiAgICAgICAgOCwKICAgICAgICAxLjAsCiAgICAgICAgInJlc19tdWx0aXN0ZXAiLAogICAgICAgICJzaW1wbGUiLAogICAgICAgIDEuMAogICAgICBdCiAgICB9LAogICAgewogICAgICAiaWQiOiA5LAogICAgICAidHlwZSI6ICJWQUVEZWNvZGUiLAogICAgICAicG9zIjogWwogICAgICAgIDIxMDAsCiAgICAgICAgMTEwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDI1MCwKICAgICAgICAxMDAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDEwLAogICAgICAibW9kZSI6IDAsCiAgICAgICJpbnB1dHMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAic2FtcGxlcyIsCiAgICAgICAgICAidHlwZSI6ICJMQVRFTlQiLAogICAgICAgICAgImxpbmsiOiAxMAogICAgICAgIH0sCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAidmFlIiwKICAgICAgICAgICJ0eXBlIjogIlZBRSIsCiAgICAgICAgICAibGluayI6IDkKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJvdXRwdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIklNQUdFIiwKICAgICAgICAgICJ0eXBlIjogIklNQUdFIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgMTEKICAgICAgICAgIF0sCiAgICAgICAgICAic2xvdF9pbmRleCI6IDAKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJwcm9wZXJ0aWVzIjogewogICAgICAgICJOb2RlIG5hbWUgZm9yIFMmUiI6ICJWQUVEZWNvZGUiCiAgICAgIH0sCiAgICAgICJ3aWRnZXRzX3ZhbHVlcyI6IFtdCiAgICB9LAogICAgewogICAgICAiaWQiOiAxMCwKICAgICAgInR5cGUiOiAiU2F2ZUltYWdlIiwKICAgICAgInBvcyI6IFsKICAgICAgICAyNDIwLAogICAgICAgIDcwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDUwMCwKICAgICAgICA1MDAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDExLAogICAgICAibW9kZSI6IDAsCiAgICAgICJpbnB1dHMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAiaW1hZ2VzIiwKICAgICAgICAgICJ0eXBlIjogIklNQUdFIiwKICAgICAgICAgICJsaW5rIjogMTEKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJvdXRwdXRzIjogW10sCiAgICAgICJwcm9wZXJ0aWVzIjogewogICAgICAgICJOb2RlIG5hbWUgZm9yIFMmUiI6ICJTYXZlSW1hZ2UiCiAgICAgIH0sCiAgICAgICJ3aWRnZXRzX3ZhbHVlcyI6IFsKICAgICAgICAiYm9vdGhfdGVzdC96aW1hZ2VfZWx1c2FyY2FfYW5pbWUiCiAgICAgIF0KICAgIH0sCiAgICB7CiAgICAgICJpZCI6IDExLAogICAgICAidHlwZSI6ICJMb3JhTG9hZGVyTW9kZWxPbmx5IiwKICAgICAgInBvcyI6IFsKICAgICAgICAzNjAsCiAgICAgICAgMAogICAgICBdLAogICAgICAic2l6ZSI6IFsKICAgICAgICAzMjAsCiAgICAgICAgMTMwCiAgICAgIF0sCiAgICAgICJmbGFncyI6IHt9LAogICAgICAib3JkZXIiOiAzLAogICAgICAibW9kZSI6IDAsCiAgICAgICJpbnB1dHMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAibW9kZWwiLAogICAgICAgICAgInR5cGUiOiAiTU9ERUwiLAogICAgICAgICAgImxpbmsiOiAxCiAgICAgICAgfQogICAgICBdLAogICAgICAib3V0cHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJNT0RFTCIsCiAgICAgICAgICAidHlwZSI6ICJNT0RFTCIsCiAgICAgICAgICAibGlua3MiOiBbCiAgICAgICAgICAgIDEyCiAgICAgICAgICBdLAogICAgICAgICAgInNsb3RfaW5kZXgiOiAwCiAgICAgICAgfQogICAgICBdLAogICAgICAidGl0bGUiOiAiTG9SQSAxIC0gRWx1c2FyY2EgQW5pbWUgU3R5bGUiLAogICAgICAicHJvcGVydGllcyI6IHsKICAgICAgICAiTm9kZSBuYW1lIGZvciBTJlIiOiAiTG9yYUxvYWRlck1vZGVsT25seSIKICAgICAgfSwKICAgICAgIndpZGdldHNfdmFsdWVzIjogWwogICAgICAgICJlbHVzYXJjYS1hbmltZS1zdHlsZS5zYWZldGVuc29ycyIsCiAgICAgICAgMS4wCiAgICAgIF0KICAgIH0sCiAgICB7CiAgICAgICJpZCI6IDEyLAogICAgICAidHlwZSI6ICJMb3JhTG9hZGVyTW9kZWxPbmx5IiwKICAgICAgInBvcyI6IFsKICAgICAgICA3MjAsCiAgICAgICAgMAogICAgICBdLAogICAgICAic2l6ZSI6IFsKICAgICAgICAzMjAsCiAgICAgICAgMTUwCiAgICAgIF0sCiAgICAgICJmbGFncyI6IHt9LAogICAgICAib3JkZXIiOiA0LAogICAgICAibW9kZSI6IDAsCiAgICAgICJpbnB1dHMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAibW9kZWwiLAogICAgICAgICAgInR5cGUiOiAiTU9ERUwiLAogICAgICAgICAgImxpbmsiOiAxMgogICAgICAgIH0KICAgICAgXSwKICAgICAgIm91dHB1dHMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAiTU9ERUwiLAogICAgICAgICAgInR5cGUiOiAiTU9ERUwiLAogICAgICAgICAgImxpbmtzIjogWwogICAgICAgICAgICAxMwogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMAogICAgICAgIH0KICAgICAgXSwKICAgICAgInRpdGxlIjogIkxvUkEgMiAtIE5TRlcgLyBDb21wYXJpc29uIChzZWxlY3RhYmxlKSIsCiAgICAgICJwcm9wZXJ0aWVzIjogewogICAgICAgICJOb2RlIG5hbWUgZm9yIFMmUiI6ICJMb3JhTG9hZGVyTW9kZWxPbmx5IgogICAgICB9LAogICAgICAid2lkZ2V0c192YWx1ZXMiOiBbCiAgICAgICAgIm5zZndfY29tcGFyZS9TRUxFQ1RfQUZURVJfSU5TVEFMTC5zYWZldGVuc29ycyIsCiAgICAgICAgMC4wCiAgICAgIF0KICAgIH0KICBdLAogICJsaW5rcyI6IFsKICAgIFsKICAgICAgMSwKICAgICAgMSwKICAgICAgMCwKICAgICAgMTEsCiAgICAgIDAsCiAgICAgICJNT0RFTCIKICAgIF0sCiAgICBbCiAgICAgIDMsCiAgICAgIDIsCiAgICAgIDAsCiAgICAgIDQsCiAgICAgIDAsCiAgICAgICJDTElQIgogICAgXSwKICAgIFsKICAgICAgNCwKICAgICAgNCwKICAgICAgMCwKICAgICAgOCwKICAgICAgMSwKICAgICAgIkNPTkRJVElPTklORyIKICAgIF0sCiAgICBbCiAgICAgIDUsCiAgICAgIDQsCiAgICAgIDAsCiAgICAgIDUsCiAgICAgIDAsCiAgICAgICJDT05ESVRJT05JTkciCiAgICBdLAogICAgWwogICAgICA2LAogICAgICA3LAogICAgICAwLAogICAgICA4LAogICAgICAwLAogICAgICAiTU9ERUwiCiAgICBdLAogICAgWwogICAgICA3LAogICAgICA1LAogICAgICAwLAogICAgICA4LAogICAgICAyLAogICAgICAiQ09ORElUSU9OSU5HIgogICAgXSwKICAgIFsKICAgICAgOCwKICAgICAgNiwKICAgICAgMCwKICAgICAgOCwKICAgICAgMywKICAgICAgIkxBVEVOVCIKICAgIF0sCiAgICBbCiAgICAgIDksCiAgICAgIDMsCiAgICAgIDAsCiAgICAgIDksCiAgICAgIDEsCiAgICAgICJWQUUiCiAgICBdLAogICAgWwogICAgICAxMCwKICAgICAgOCwKICAgICAgMCwKICAgICAgOSwKICAgICAgMCwKICAgICAgIkxBVEVOVCIKICAgIF0sCiAgICBbCiAgICAgIDExLAogICAgICA5LAogICAgICAwLAogICAgICAxMCwKICAgICAgMCwKICAgICAgIklNQUdFIgogICAgXSwKICAgIFsKICAgICAgMTIsCiAgICAgIDExLAogICAgICAwLAogICAgICAxMiwKICAgICAgMCwKICAgICAgIk1PREVMIgogICAgXSwKICAgIFsKICAgICAgMTMsCiAgICAgIDEyLAogICAgICAwLAogICAgICA3LAogICAgICAwLAogICAgICAiTU9ERUwiCiAgICBdCiAgXSwKICAiZ3JvdXBzIjogW10sCiAgImNvbmZpZyI6IHt9LAogICJleHRyYSI6IHsKICAgICJkcyI6IHsKICAgICAgInNjYWxlIjogMC42OCwKICAgICAgIm9mZnNldCI6IFsKICAgICAgICA4MCwKICAgICAgICAxMDAKICAgICAgXQogICAgfQogIH0sCiAgInZlcnNpb24iOiAwLjQKfQ=="

ELU_NAME="elusarca-anime-style.safetensors"
ELU_URL="https://huggingface.co/reverentelusarca/elusarca-anime-style-lora-z-image-turbo/resolve/main/elusarca-anime-style.safetensors?download=true"

STATE_DIR="${BASE_DIR}/.zimage_elusarca_nsfw_v2"
LOG_FILE="${STATE_DIR}/setup.log"
STATUS_FILE="${STATE_DIR}/status"
PHASE_FILE="${STATE_DIR}/phase"
PID_FILE="${STATE_DIR}/setup.pid"
LOCK_DIR="${STATE_DIR}/setup.lock.d"
HEARTBEAT_SECONDS="${HEARTBEAT_SECONDS:-15}"

# Comparison-only repos are enabled by default because this pack is explicitly
# for local A/B evaluation. Set INSTALL_UNCLEAR_LICENSE=0 to omit them.
INSTALL_UNCLEAR_LICENSE="${INSTALL_UNCLEAR_LICENSE:-1}"

mkdir -p "$STATE_DIR"

ts(){ date '+%Y-%m-%d %H:%M:%S'; }
say(){ echo; echo "================================================================"; echo "[$(ts)] $*"; echo "================================================================"; }
set_phase(){ echo "$*" > "$PHASE_FILE"; }
alive(){ [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null; }

usage(){
cat <<'EOF'
Usage:
  ./runpod_zimage_elusarca_nsfw_compare_v2.sh
  ./runpod_zimage_elusarca_nsfw_compare_v2.sh --status
  ./runpod_zimage_elusarca_nsfw_compare_v2.sh --follow

Options via environment:
  INSTALL_UNCLEAR_LICENSE=1   default; also download comparison-only candidates
  INSTALL_UNCLEAR_LICENSE=0   only license-explicit candidates

This installer NEVER generates images.
EOF
}

show_status(){
  echo "Status : $(cat "$STATUS_FILE" 2>/dev/null || echo NOT_STARTED)"
  echo "Phase  : $(cat "$PHASE_FILE" 2>/dev/null || echo -)"
  echo "Log    : $LOG_FILE"
  echo "ComfyUI: $COMFY_DIR"
  echo "Port   : $PORT"
}

follow_log(){
  touch "$LOG_FILE"
  echo "Following $LOG_FILE"
  tail -n 100 -F "$LOG_FILE"
}

need_tools(){
  local missing=()
  for c in python3 curl lsof sha256sum; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]})); then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends python3 curl lsof coreutils ca-certificates
  fi
  if ! command -v aria2c >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends aria2
  fi
}

preflight(){
  say "Preflight existing Z-Image V4 environment"
  set_phase "Preflight"
  [[ -f "$COMFY_DIR/main.py" ]] || { echo "[FATAL] Missing $COMFY_DIR/main.py"; exit 10; }
  [[ -x "$VENV_DIR/bin/python" ]] || { echo "[FATAL] Missing venv $VENV_DIR"; exit 11; }
  for f in \
    "$COMFY_DIR/models/diffusion_models/z_image_turbo_bf16.safetensors" \
    "$COMFY_DIR/models/text_encoders/qwen_3_4b.safetensors" \
    "$COMFY_DIR/models/vae/ae.safetensors"
  do
    [[ -s "$f" ]] || { echo "[FATAL] Missing core model: $f"; exit 12; }
  done
  mkdir -p "$LORA_DIR" "$COMPARE_DIR" "$WORKFLOW_DIR" "$EXPORT_DIR"
}

validate_safetensors(){
  local f="$1"
  "$VENV_DIR/bin/python" - "$f" <<'PY'
import json, os, struct, sys
p=sys.argv[1]
if os.path.getsize(p) < 1_000_000:
    raise SystemExit(f"too small to be expected LoRA: {p}")
with open(p,"rb") as fh:
    b=fh.read(8)
    if len(b)!=8: raise SystemExit("bad safetensors header")
    n=struct.unpack("<Q",b)[0]
    if not (2 < n < 100_000_000): raise SystemExit(f"bad safetensors JSON length: {n}")
    obj=json.loads(fh.read(n))
    if not isinstance(obj,dict): raise SystemExit("bad safetensors metadata")
print("VALID", p, os.path.getsize(p))
PY
}

download_url(){
  local label="$1" url="$2" dest="$3"
  mkdir -p "$(dirname "$dest")"
  if [[ -s "$dest" ]]; then
    if validate_safetensors "$dest" >/dev/null 2>&1; then
      echo "[SKIP] $label already valid: $dest"
      return
    fi
    rm -f "$dest" "$dest.aria2" || true
  fi
  echo "[DOWNLOAD] $label"
  aria2c --continue=true --allow-overwrite=true --auto-file-renaming=false \
    --max-connection-per-server=8 --split=8 --min-split-size=8M \
    --retry-wait=5 --max-tries=0 --timeout=30 --connect-timeout=30 \
    --dir="$(dirname "$dest")" --out="$(basename "$dest")" "$url"
  validate_safetensors "$dest"
}

# Query Hugging Face model API and download selected .safetensors.
# mode=all: all safetensors, limited by max_count
# mode=keywords: prioritize filenames containing NSFW-ish keywords, then fallback.
download_repo_candidates(){
  local repo="$1" subdir="$2" max_count="$3" mode="$4"
  local out="$COMPARE_DIR/$subdir"
  mkdir -p "$out"

  "$VENV_DIR/bin/python" - "$repo" "$out" "$max_count" "$mode" <<'PY'
import json, os, pathlib, sys, urllib.parse, urllib.request, subprocess
repo, out, max_count, mode = sys.argv[1], pathlib.Path(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
api="https://huggingface.co/api/models/" + urllib.parse.quote(repo, safe="/")
with urllib.request.urlopen(api, timeout=60) as r:
    data=json.load(r)
siblings=data.get("siblings",[])
names=[x.get("rfilename","") for x in siblings if x.get("rfilename","").lower().endswith(".safetensors")]
if not names:
    raise SystemExit(f"No safetensors found in {repo}")

kw=("nsfw","master","anime","xxx","porn","adult","nude")
if mode=="keywords":
    preferred=[n for n in names if any(k in n.lower() for k in kw)]
    names=preferred or names
names=names[:max_count]

print(f"{repo}: selected {len(names)} file(s)")
for n in names:
    # flatten repo folders into filename, keeping repo-specific output directory
    dest=out / pathlib.Path(n).name
    url="https://huggingface.co/{}/resolve/main/{}?download=true".format(repo, urllib.parse.quote(n, safe="/"))
    print("SELECT", n, "->", dest)
    subprocess.run([
        "aria2c","--continue=true","--allow-overwrite=true","--auto-file-renaming=false",
        "--max-connection-per-server=8","--split=8","--min-split-size=8M",
        "--retry-wait=5","--max-tries=0","--timeout=30","--connect-timeout=30",
        "--dir="+str(dest.parent),"--out="+dest.name,url
    ], check=True)
PY

  local f
  while IFS= read -r -d '' f; do
    validate_safetensors "$f"
  done < <(find "$out" -maxdepth 1 -type f -name '*.safetensors' -print0)
}

download_all(){
  say "Download Elusarca + NSFW comparison candidates"
  set_phase "Download LoRAs"

  # 1) Anime style LoRA (Apache-2.0 on publisher model card)
  download_url "Elusarca Anime Style" "$ELU_URL" "$LORA_DIR/$ELU_NAME"

  # 2) License-explicit candidate: qqnyanddld/nsfw-z-image-lora (Apache-2.0)
  download_repo_candidates \
    "qqnyanddld/nsfw-z-image-lora" \
    "01_qqnyanddld_apache2" 3 all

  # 3) License-explicit candidate: RomixERR Pornmaster v1 (Apache-2.0)
  download_url \
    "RomixERR Pornmaster v1 checkpoint 44700" \
    "https://huggingface.co/RomixERR/Pornmaster_v1-Z-Images-Turbo/resolve/main/Pornmaster_v1_000044700.safetensors?download=true" \
    "$COMPARE_DIR/02_romix_apache2/Pornmaster_v1_000044700.safetensors"

  if [[ "$INSTALL_UNCLEAR_LICENSE" == "1" ]]; then
    # 4) Comparison-only: NSFW Anime v2 from an aggregation repo.
    # Repository-level commercial rights were not established in our review.
    download_url \
      "torestinbar nsfw-anime-v2 (comparison only)" \
      "https://huggingface.co/torestinbar/z-image-turbo/resolve/main/loras/nsfw-anime-v2.safetensors?download=true" \
      "$COMPARE_DIR/80_torestinbar_license_unconfirmed/nsfw-anime-v2.safetensors"

    # 5) Comparison-only: NSFW-MASTER (HF model card license currently unknown)
    download_repo_candidates \
      "thutes-gbr25/NSFW-MASTER-Z-IMAGE-TURBO" \
      "90_nsfw_master_license_unknown" 2 keywords

    # 6) Comparison-only: Z-Image-LoraSet-NSFW.
    # Only download at most 2 likely NSFW/master/anime files to avoid pulling an entire large collection.
    download_repo_candidates \
      "lkzd7/Z-Image-LoraSet-NSFW" \
      "91_loraset_license_unconfirmed" 2 keywords
  fi
}

pick_default_nsfw(){
  # Prefer qqnyanddld; fallback to Romix; fallback to any comparison LoRA.
  local f=""
  f="$(find "$COMPARE_DIR/01_qqnyanddld_apache2" -maxdepth 1 -type f -name '*.safetensors' | sort | head -n1 || true)"
  [[ -n "$f" ]] || f="$(find "$COMPARE_DIR/02_romix_apache2" -maxdepth 1 -type f -name '*.safetensors' | sort | head -n1 || true)"
  [[ -n "$f" ]] || f="$(find "$COMPARE_DIR" -type f -name '*.safetensors' | sort | head -n1 || true)"
  [[ -n "$f" ]] || { echo "[FATAL] No NSFW candidate downloaded"; exit 21; }

  # Return path relative to models/loras, ComfyUI-style.
  python3 - "$LORA_DIR" "$f" <<'PY'
import os,sys
print(os.path.relpath(sys.argv[2], sys.argv[1]).replace(os.sep,"/"))
PY
}

write_workflow(){
  say "Install dual-LoRA workflow"
  set_phase "Write workflow"
  local default_nsfw
  default_nsfw="$(pick_default_nsfw)"
  echo "Default NSFW LoRA in workflow: $default_nsfw"

  "$VENV_DIR/bin/python" - "$WORKFLOW_B64" "$default_nsfw" \
    "$WORKFLOW_DIR/$WORKFLOW_NAME" "$EXPORT_DIR/$WORKFLOW_NAME" <<'PY'
import base64,json,pathlib,sys
obj=json.loads(base64.b64decode(sys.argv[1]).decode())
default=sys.argv[2]
for n in obj["nodes"]:
    if n.get("id")==12 and n.get("type")=="LoraLoaderModelOnly":
        n["widgets_values"]=[default,0.0]  # disabled by default for safety/comparison
for name in sys.argv[3:]:
    p=pathlib.Path(name); p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(json.dumps(obj,ensure_ascii=False,indent=2),encoding="utf-8")
    json.loads(p.read_text(encoding="utf-8"))
    print("WROTE",p)
PY

  cat > "$EXPORT_DIR/ZIMAGE_NSFw_LORA_MANIFEST.txt" <<'EOF'
Z-Image NSFW LoRA comparison pack

LoRA 1:
  elusarca-anime-style.safetensors
  Purpose: 2D/anime illustration style
  Default strength: 1.0

LoRA 2:
  Select one file under models/loras/nsfw_compare/
  Default strength in workflow: 0.0 (OFF)

LICENSE-EXPLICIT CANDIDATES AT TIME OF REVIEW
  01_qqnyanddld_apache2/
    Source: qqnyanddld/nsfw-z-image-lora
    Hugging Face model card: Apache-2.0

  02_romix_apache2/
    Source: RomixERR/Pornmaster_v1-Z-Images-Turbo
    Hugging Face model card: Apache-2.0
    Author recommendation: strength 0.7-0.85
    Trigger: pronmstr
    Author notes it is a work in progress and can be unpredictable.

COMPARISON-ONLY / RIGHTS NOT CLEARED FOR THIS WORKFLOW
  80_torestinbar_license_unconfirmed/
    nsfw-anime-v2.safetensors
    We confirmed the file exists, but did not establish a repository-level license for commercial use.

  90_nsfw_master_license_unknown/
    Source: thutes-gbr25/NSFW-MASTER-Z-IMAGE-TURBO
    Hugging Face model card currently shows license: unknown.
    Author recommendation: weight 0.8.

  91_loraset_license_unconfirmed/
    Source: lkzd7/Z-Image-LoraSet-NSFW
    Sensitive-content repository; no commercial-use clearance established in our review.

IMPORTANT
  A file being downloadable does NOT mean it is commercially cleared.
  Re-check the upstream model card/license before using any candidate in a sold product.
  This installer does not generate images.
EOF

  find "$COMPARE_DIR" -type f -name '*.safetensors' -printf '%P\n' | sort > "$EXPORT_DIR/ZIMAGE_NSFw_LORA_FILES.txt"
}

safe_restart_comfy(){
  say "Restart ComfyUI safely on port $PORT"
  set_phase "Restart ComfyUI"
  local listeners
  listeners="$(lsof -ti TCP:"$PORT" -sTCP:LISTEN 2>/dev/null | sort -u || true)"
  if [[ -n "$listeners" ]]; then
    for pid in $listeners; do
      local cwd cmd
      cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
      cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
      echo "PID=$pid CWD=$cwd CMD=$cmd"
      if [[ "$cwd" == "$COMFY_DIR" || "$cmd" == *"$COMFY_DIR/main.py"* ]]; then
        kill "$pid" 2>/dev/null || true
        for _ in {1..30}; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
      else
        echo "[FATAL] Port $PORT belongs to another environment. Refusing to kill."
        exit 30
      fi
    done
  fi

  cd "$COMFY_DIR"
  source "$VENV_DIR/bin/activate"
  nohup python main.py --listen "$HOST" --port "$PORT" --preview-method auto \
    > comfyui_8188.log 2>&1 < /dev/null &
  local pid=$!
  echo "$pid" > comfyui_8188.pid

  for i in {1..48}; do
    if curl -fsS "http://127.0.0.1:$PORT/system_stats" >/dev/null 2>&1; then
      echo "[OK] ComfyUI ready."
      return
    fi
    kill -0 "$pid" 2>/dev/null || { tail -n 160 comfyui_8188.log || true; exit 31; }
    echo "[ALIVE] startup $((i*5))s"
    sleep 5
  done
  tail -n 160 comfyui_8188.log || true
  exit 32
}

verify_visibility(){
  say "Verify dual LoRA nodes and downloaded LoRAs (NO image generation)"
  set_phase "Verify visibility"
  "$VENV_DIR/bin/python" - "$PORT" "$COMPARE_DIR" "$LORA_DIR" <<'PY'
import json, pathlib, sys, urllib.request, os
port=int(sys.argv[1]); comp=pathlib.Path(sys.argv[2]); lora_root=pathlib.Path(sys.argv[3])
obj=json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/object_info",timeout=60))
if "LoraLoaderModelOnly" not in obj:
    raise SystemExit("LoraLoaderModelOnly missing")
choices=obj["LoraLoaderModelOnly"]["input"]["required"]["lora_name"][0]
files=sorted(comp.rglob("*.safetensors"))
missing=[]
for f in files:
    rel=os.path.relpath(f,lora_root).replace(os.sep,"/")
    if rel not in choices:
        missing.append(rel)
print("Downloaded NSFW candidate files:", len(files))
print("ComfyUI LoRA choices:", len(choices))
if missing:
    raise SystemExit("Downloaded LoRA(s) not visible in ComfyUI: " + ", ".join(missing))
print("[OK] All downloaded comparison LoRAs visible.")
print("No image generation was performed.")
PY
}

summary(){
  echo READY > "$STATUS_FILE"
  set_phase READY
  say "READY"
  cat <<EOF
No image was generated.

Workflow:
  $WORKFLOW_DIR/$WORKFLOW_NAME

Comparison LoRA folder:
  $COMPARE_DIR

Manifest:
  $EXPORT_DIR/ZIMAGE_NSFw_LORA_MANIFEST.txt

LoRA 1 = Elusarca Anime Style, strength 1.0
LoRA 2 = selectable NSFW/comparison LoRA, strength 0.0 by default

In ComfyUI, change LoRA 2 from its dropdown to compare the downloaded files.
EOF
}

worker_main(){
  trap '' HUP
  trap 'echo FAILED > "$STATUS_FILE"; set_phase "FAILED line $LINENO"; echo "[FATAL] line $LINENO"' ERR

  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    local old="$(cat "$PID_FILE" 2>/dev/null || true)"
    if alive "$old"; then echo "[FATAL] Installer already running PID $old"; exit 40; fi
    rm -rf "$LOCK_DIR"; mkdir "$LOCK_DIR"
  fi
  trap 'rm -rf "$LOCK_DIR" 2>/dev/null || true' EXIT
  echo $$ > "$PID_FILE"
  echo RUNNING > "$STATUS_FILE"

  (
    while true; do
      sleep "$HEARTBEAT_SECONDS"
      echo "[HEARTBEAT $(ts)] status=$(cat "$STATUS_FILE" 2>/dev/null || echo ?) phase=$(cat "$PHASE_FILE" 2>/dev/null || echo ?)"
    done
  ) &
  local hb=$!
  trap 'kill "$hb" 2>/dev/null || true; rm -rf "$LOCK_DIR" 2>/dev/null || true' EXIT

  need_tools
  preflight
  download_all
  write_workflow
  safe_restart_comfy
  verify_visibility
  summary
}

launch(){
  local old="$(cat "$PID_FILE" 2>/dev/null || true)"
  if alive "$old"; then
    echo "Installer already running PID $old"
    follow_log
    return
  fi
  : > "$LOG_FILE"
  nohup bash "${BASH_SOURCE[0]}" --worker >> "$LOG_FILE" 2>&1 < /dev/null &
  echo $! > "$PID_FILE"
  echo "Started installer PID $!"
  echo "Survives browser terminal disconnect."
  sleep 1
  follow_log
}

case "${1:-}" in
  --worker) exec > >(tee -a "$LOG_FILE") 2>&1; worker_main ;;
  --status) show_status ;;
  --follow) follow_log ;;
  --help|-h) usage ;;
  "") launch ;;
  *) usage; exit 2 ;;
esac
