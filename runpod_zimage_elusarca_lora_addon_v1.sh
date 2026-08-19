#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# RunPod + ComfyUI Z-Image-Turbo + Elusarca Anime Style LoRA Add-on v1
#
# PURPOSE
#   Add Elusarca Anime Style LoRA to the already-working Z-Image V4 setup,
#   install a ready-to-load ComfyUI workflow, and verify ComfyUI sees the LoRA.
#
# IMPORTANT
#   - This script DOES NOT generate any image.
#   - It DOES NOT reinstall PyTorch.
#   - It DOES NOT upgrade ComfyUI.
#   - It DOES NOT modify the existing Z-Image core model files.
#
# Expected existing environment:
#   /workspace/runpod-slim/ComfyUI-ZImage
#
# LoRA:
#   reverentelusarca/elusarca-anime-style-lora-z-image-turbo
#   file: elusarca-anime-style.safetensors
#   SHA256: 4e2edb94c3cf7573af9734e7ce171c1c3176119febfa81470acc326d671774a8
#
# Workflow:
#   booth_zimage_elusarca_anime_v1.json
#   Default strength: 1.0
#   Trigger: elusarca anime style
###############################################################################

SCRIPT_NAME="runpod_zimage_elusarca_lora_addon_v1"
BASE_DIR="${BASE_DIR:-/workspace/runpod-slim}"
COMFY_DIR="${COMFY_DIR:-${BASE_DIR}/ComfyUI-ZImage}"
VENV_DIR="${VENV_DIR:-${COMFY_DIR}/.venv}"
PORT="${COMFY_PORT:-8188}"
HOST="${COMFY_HOST:-0.0.0.0}"

LORA_DIR="${COMFY_DIR}/models/loras"
LORA_NAME="elusarca-anime-style.safetensors"
LORA_URL="https://huggingface.co/reverentelusarca/elusarca-anime-style-lora-z-image-turbo/resolve/main/elusarca-anime-style.safetensors?download=true"
LORA_SHA256="4e2edb94c3cf7573af9734e7ce171c1c3176119febfa81470acc326d671774a8"
LORA_MIN_BYTES=160000000

WORKFLOW_NAME="booth_zimage_elusarca_anime_v1.json"
WORKFLOW_DIR="${COMFY_DIR}/user/default/workflows"
EXPORT_WF_DIR="${BASE_DIR}/booth_workflows"
WORKFLOW_B64="ewogICJsYXN0X25vZGVfaWQiOiAxMSwKICAibGFzdF9saW5rX2lkIjogMTEsCiAgIm5vZGVzIjogWwogICAgewogICAgICAiaWQiOiAxLAogICAgICAidHlwZSI6ICJVTkVUTG9hZGVyIiwKICAgICAgInBvcyI6IFsKICAgICAgICAwLAogICAgICAgIDAKICAgICAgXSwKICAgICAgInNpemUiOiBbCiAgICAgICAgMzAwLAogICAgICAgIDExMAogICAgICBdLAogICAgICAiZmxhZ3MiOiB7fSwKICAgICAgIm9yZGVyIjogMCwKICAgICAgIm1vZGUiOiAwLAogICAgICAiaW5wdXRzIjogW10sCiAgICAgICJvdXRwdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIk1PREVMIiwKICAgICAgICAgICJ0eXBlIjogIk1PREVMIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgMQogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMAogICAgICAgIH0KICAgICAgXSwKICAgICAgInByb3BlcnRpZXMiOiB7CiAgICAgICAgIk5vZGUgbmFtZSBmb3IgUyZSIjogIlVORVRMb2FkZXIiCiAgICAgIH0sCiAgICAgICJ3aWRnZXRzX3ZhbHVlcyI6IFsKICAgICAgICAiel9pbWFnZV90dXJib19iZjE2LnNhZmV0ZW5zb3JzIiwKICAgICAgICAiZGVmYXVsdCIKICAgICAgXQogICAgfSwKICAgIHsKICAgICAgImlkIjogMiwKICAgICAgInR5cGUiOiAiQ0xJUExvYWRlciIsCiAgICAgICJwb3MiOiBbCiAgICAgICAgMCwKICAgICAgICAyNDAKICAgICAgXSwKICAgICAgInNpemUiOiBbCiAgICAgICAgMzAwLAogICAgICAgIDE0MAogICAgICBdLAogICAgICAiZmxhZ3MiOiB7fSwKICAgICAgIm9yZGVyIjogMSwKICAgICAgIm1vZGUiOiAwLAogICAgICAiaW5wdXRzIjogW10sCiAgICAgICJvdXRwdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIkNMSVAiLAogICAgICAgICAgInR5cGUiOiAiQ0xJUCIsCiAgICAgICAgICAibGlua3MiOiBbCiAgICAgICAgICAgIDMKICAgICAgICAgIF0sCiAgICAgICAgICAic2xvdF9pbmRleCI6IDAKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJwcm9wZXJ0aWVzIjogewogICAgICAgICJOb2RlIG5hbWUgZm9yIFMmUiI6ICJDTElQTG9hZGVyIgogICAgICB9LAogICAgICAid2lkZ2V0c192YWx1ZXMiOiBbCiAgICAgICAgInF3ZW5fM180Yi5zYWZldGVuc29ycyIsCiAgICAgICAgImx1bWluYTIiLAogICAgICAgICJkZWZhdWx0IgogICAgICBdCiAgICB9LAogICAgewogICAgICAiaWQiOiAzLAogICAgICAidHlwZSI6ICJWQUVMb2FkZXIiLAogICAgICAicG9zIjogWwogICAgICAgIDAsCiAgICAgICAgNDYwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDMwMCwKICAgICAgICAxMTAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDIsCiAgICAgICJtb2RlIjogMCwKICAgICAgImlucHV0cyI6IFtdLAogICAgICAib3V0cHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJWQUUiLAogICAgICAgICAgInR5cGUiOiAiVkFFIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgOQogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMAogICAgICAgIH0KICAgICAgXSwKICAgICAgInByb3BlcnRpZXMiOiB7CiAgICAgICAgIk5vZGUgbmFtZSBmb3IgUyZSIjogIlZBRUxvYWRlciIKICAgICAgfSwKICAgICAgIndpZGdldHNfdmFsdWVzIjogWwogICAgICAgICJhZS5zYWZldGVuc29ycyIKICAgICAgXQogICAgfSwKICAgIHsKICAgICAgImlkIjogNCwKICAgICAgInR5cGUiOiAiQ0xJUFRleHRFbmNvZGUiLAogICAgICAicG9zIjogWwogICAgICAgIDc2MCwKICAgICAgICAyMjAKICAgICAgXSwKICAgICAgInNpemUiOiBbCiAgICAgICAgNDcwLAogICAgICAgIDMwMAogICAgICBdLAogICAgICAiZmxhZ3MiOiB7fSwKICAgICAgIm9yZGVyIjogNCwKICAgICAgIm1vZGUiOiAwLAogICAgICAiaW5wdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogImNsaXAiLAogICAgICAgICAgInR5cGUiOiAiQ0xJUCIsCiAgICAgICAgICAibGluayI6IDMKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJvdXRwdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIkNPTkRJVElPTklORyIsCiAgICAgICAgICAidHlwZSI6ICJDT05ESVRJT05JTkciLAogICAgICAgICAgImxpbmtzIjogWwogICAgICAgICAgICA0LAogICAgICAgICAgICA1CiAgICAgICAgICBdLAogICAgICAgICAgInNsb3RfaW5kZXgiOiAwCiAgICAgICAgfQogICAgICBdLAogICAgICAicHJvcGVydGllcyI6IHsKICAgICAgICAiTm9kZSBuYW1lIGZvciBTJlIiOiAiQ0xJUFRleHRFbmNvZGUiCiAgICAgIH0sCiAgICAgICJ3aWRnZXRzX3ZhbHVlcyI6IFsKICAgICAgICAiZWx1c2FyY2EgYW5pbWUgc3R5bGUsIGhpZ2gtcXVhbGl0eSBhbmltZSBpbGx1c3RyYXRpb24sIDJELCBjbGVhbiBsaW5lYXJ0LCBjZWwtc2hhZGVkLCB2aWJyYW50IGNvbG9ycywgc29mdCBzaGFkaW5nLCBwb2xpc2hlZCBKYXBhbmVzZSBhbmltZSBjaGFyYWN0ZXIgaWxsdXN0cmF0aW9uLCBhZHVsdCB3b21hbiBpbiBoZXIgdHdlbnRpZXMsIGRldGFpbGVkIGZhY2UgYW5kIGhhaXIsIGV4cHJlc3NpdmUgYW5pbWUgZXllcywgbmF0dXJhbCBib2R5IHByb3BvcnRpb25zLCBjbGVhbiBjb21wb3NpdGlvbiwgc2ltcGxlIGJhY2tncm91bmQiCiAgICAgIF0KICAgIH0sCiAgICB7CiAgICAgICJpZCI6IDUsCiAgICAgICJ0eXBlIjogIkNvbmRpdGlvbmluZ1plcm9PdXQiLAogICAgICAicG9zIjogWwogICAgICAgIDEyOTAsCiAgICAgICAgMzgwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDI2MCwKICAgICAgICA4MAogICAgICBdLAogICAgICAiZmxhZ3MiOiB7fSwKICAgICAgIm9yZGVyIjogNywKICAgICAgIm1vZGUiOiAwLAogICAgICAiaW5wdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogImNvbmRpdGlvbmluZyIsCiAgICAgICAgICAidHlwZSI6ICJDT05ESVRJT05JTkciLAogICAgICAgICAgImxpbmsiOiA1CiAgICAgICAgfQogICAgICBdLAogICAgICAib3V0cHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJDT05ESVRJT05JTkciLAogICAgICAgICAgInR5cGUiOiAiQ09ORElUSU9OSU5HIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgNwogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMAogICAgICAgIH0KICAgICAgXSwKICAgICAgInByb3BlcnRpZXMiOiB7CiAgICAgICAgIk5vZGUgbmFtZSBmb3IgUyZSIjogIkNvbmRpdGlvbmluZ1plcm9PdXQiCiAgICAgIH0sCiAgICAgICJ3aWRnZXRzX3ZhbHVlcyI6IFtdCiAgICB9LAogICAgewogICAgICAiaWQiOiA2LAogICAgICAidHlwZSI6ICJFbXB0eVNEM0xhdGVudEltYWdlIiwKICAgICAgInBvcyI6IFsKICAgICAgICA3NjAsCiAgICAgICAgNTgwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDMwMCwKICAgICAgICAxNzAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDUsCiAgICAgICJtb2RlIjogMCwKICAgICAgImlucHV0cyI6IFtdLAogICAgICAib3V0cHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJMQVRFTlQiLAogICAgICAgICAgInR5cGUiOiAiTEFURU5UIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgOAogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMAogICAgICAgIH0KICAgICAgXSwKICAgICAgInByb3BlcnRpZXMiOiB7CiAgICAgICAgIk5vZGUgbmFtZSBmb3IgUyZSIjogIkVtcHR5U0QzTGF0ZW50SW1hZ2UiCiAgICAgIH0sCiAgICAgICJ3aWRnZXRzX3ZhbHVlcyI6IFsKICAgICAgICA4MzIsCiAgICAgICAgMTIxNiwKICAgICAgICAxCiAgICAgIF0KICAgIH0sCiAgICB7CiAgICAgICJpZCI6IDcsCiAgICAgICJ0eXBlIjogIk1vZGVsU2FtcGxpbmdBdXJhRmxvdyIsCiAgICAgICJwb3MiOiBbCiAgICAgICAgNzYwLAogICAgICAgIDIwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDMwMCwKICAgICAgICAxMTAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDYsCiAgICAgICJtb2RlIjogMCwKICAgICAgImlucHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJtb2RlbCIsCiAgICAgICAgICAidHlwZSI6ICJNT0RFTCIsCiAgICAgICAgICAibGluayI6IDIKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJvdXRwdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIk1PREVMIiwKICAgICAgICAgICJ0eXBlIjogIk1PREVMIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgNgogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMAogICAgICAgIH0KICAgICAgXSwKICAgICAgInByb3BlcnRpZXMiOiB7CiAgICAgICAgIk5vZGUgbmFtZSBmb3IgUyZSIjogIk1vZGVsU2FtcGxpbmdBdXJhRmxvdyIKICAgICAgfSwKICAgICAgIndpZGdldHNfdmFsdWVzIjogWwogICAgICAgIDMKICAgICAgXQogICAgfSwKICAgIHsKICAgICAgImlkIjogOCwKICAgICAgInR5cGUiOiAiS1NhbXBsZXIiLAogICAgICAicG9zIjogWwogICAgICAgIDE2MDAsCiAgICAgICAgMTEwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDMzMCwKICAgICAgICAzNDAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDgsCiAgICAgICJtb2RlIjogMCwKICAgICAgImlucHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJtb2RlbCIsCiAgICAgICAgICAidHlwZSI6ICJNT0RFTCIsCiAgICAgICAgICAibGluayI6IDYKICAgICAgICB9LAogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogInBvc2l0aXZlIiwKICAgICAgICAgICJ0eXBlIjogIkNPTkRJVElPTklORyIsCiAgICAgICAgICAibGluayI6IDQKICAgICAgICB9LAogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIm5lZ2F0aXZlIiwKICAgICAgICAgICJ0eXBlIjogIkNPTkRJVElPTklORyIsCiAgICAgICAgICAibGluayI6IDcKICAgICAgICB9LAogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogImxhdGVudF9pbWFnZSIsCiAgICAgICAgICAidHlwZSI6ICJMQVRFTlQiLAogICAgICAgICAgImxpbmsiOiA4CiAgICAgICAgfQogICAgICBdLAogICAgICAib3V0cHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJMQVRFTlQiLAogICAgICAgICAgInR5cGUiOiAiTEFURU5UIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgMTAKICAgICAgICAgIF0sCiAgICAgICAgICAic2xvdF9pbmRleCI6IDAKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJwcm9wZXJ0aWVzIjogewogICAgICAgICJOb2RlIG5hbWUgZm9yIFMmUiI6ICJLU2FtcGxlciIKICAgICAgfSwKICAgICAgIndpZGdldHNfdmFsdWVzIjogWwogICAgICAgIDAsCiAgICAgICAgInJhbmRvbWl6ZSIsCiAgICAgICAgOCwKICAgICAgICAxLjAsCiAgICAgICAgInJlc19tdWx0aXN0ZXAiLAogICAgICAgICJzaW1wbGUiLAogICAgICAgIDEuMAogICAgICBdCiAgICB9LAogICAgewogICAgICAiaWQiOiA5LAogICAgICAidHlwZSI6ICJWQUVEZWNvZGUiLAogICAgICAicG9zIjogWwogICAgICAgIDIwMDAsCiAgICAgICAgMTEwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDI1MCwKICAgICAgICAxMDAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDksCiAgICAgICJtb2RlIjogMCwKICAgICAgImlucHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJzYW1wbGVzIiwKICAgICAgICAgICJ0eXBlIjogIkxBVEVOVCIsCiAgICAgICAgICAibGluayI6IDEwCiAgICAgICAgfSwKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJ2YWUiLAogICAgICAgICAgInR5cGUiOiAiVkFFIiwKICAgICAgICAgICJsaW5rIjogOQogICAgICAgIH0KICAgICAgXSwKICAgICAgIm91dHB1dHMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAiSU1BR0UiLAogICAgICAgICAgInR5cGUiOiAiSU1BR0UiLAogICAgICAgICAgImxpbmtzIjogWwogICAgICAgICAgICAxMQogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMAogICAgICAgIH0KICAgICAgXSwKICAgICAgInByb3BlcnRpZXMiOiB7CiAgICAgICAgIk5vZGUgbmFtZSBmb3IgUyZSIjogIlZBRURlY29kZSIKICAgICAgfSwKICAgICAgIndpZGdldHNfdmFsdWVzIjogW10KICAgIH0sCiAgICB7CiAgICAgICJpZCI6IDEwLAogICAgICAidHlwZSI6ICJTYXZlSW1hZ2UiLAogICAgICAicG9zIjogWwogICAgICAgIDIzMjAsCiAgICAgICAgNzAKICAgICAgXSwKICAgICAgInNpemUiOiBbCiAgICAgICAgNTAwLAogICAgICAgIDUwMAogICAgICBdLAogICAgICAiZmxhZ3MiOiB7fSwKICAgICAgIm9yZGVyIjogMTAsCiAgICAgICJtb2RlIjogMCwKICAgICAgImlucHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJpbWFnZXMiLAogICAgICAgICAgInR5cGUiOiAiSU1BR0UiLAogICAgICAgICAgImxpbmsiOiAxMQogICAgICAgIH0KICAgICAgXSwKICAgICAgIm91dHB1dHMiOiBbXSwKICAgICAgInByb3BlcnRpZXMiOiB7CiAgICAgICAgIk5vZGUgbmFtZSBmb3IgUyZSIjogIlNhdmVJbWFnZSIKICAgICAgfSwKICAgICAgIndpZGdldHNfdmFsdWVzIjogWwogICAgICAgICJib290aF90ZXN0L3ppbWFnZV9lbHVzYXJjYV9hbmltZSIKICAgICAgXQogICAgfSwKICAgIHsKICAgICAgImlkIjogMTEsCiAgICAgICJ0eXBlIjogIkxvcmFMb2FkZXJNb2RlbE9ubHkiLAogICAgICAicG9zIjogWwogICAgICAgIDM4MCwKICAgICAgICAwCiAgICAgIF0sCiAgICAgICJzaXplIjogWwogICAgICAgIDMyMCwKICAgICAgICAxMzAKICAgICAgXSwKICAgICAgImZsYWdzIjoge30sCiAgICAgICJvcmRlciI6IDMsCiAgICAgICJtb2RlIjogMCwKICAgICAgImlucHV0cyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJtb2RlbCIsCiAgICAgICAgICAidHlwZSI6ICJNT0RFTCIsCiAgICAgICAgICAibGluayI6IDEKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJvdXRwdXRzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIk1PREVMIiwKICAgICAgICAgICJ0eXBlIjogIk1PREVMIiwKICAgICAgICAgICJsaW5rcyI6IFsKICAgICAgICAgICAgMgogICAgICAgICAgXSwKICAgICAgICAgICJzbG90X2luZGV4IjogMAogICAgICAgIH0KICAgICAgXSwKICAgICAgInRpdGxlIjogIkVsdXNhcmNhIEFuaW1lIFN0eWxlIExvUkEiLAogICAgICAicHJvcGVydGllcyI6IHsKICAgICAgICAiTm9kZSBuYW1lIGZvciBTJlIiOiAiTG9yYUxvYWRlck1vZGVsT25seSIKICAgICAgfSwKICAgICAgIndpZGdldHNfdmFsdWVzIjogWwogICAgICAgICJlbHVzYXJjYS1hbmltZS1zdHlsZS5zYWZldGVuc29ycyIsCiAgICAgICAgMS4wCiAgICAgIF0KICAgIH0KICBdLAogICJsaW5rcyI6IFsKICAgIFsKICAgICAgMSwKICAgICAgMSwKICAgICAgMCwKICAgICAgMTEsCiAgICAgIDAsCiAgICAgICJNT0RFTCIKICAgIF0sCiAgICBbCiAgICAgIDIsCiAgICAgIDExLAogICAgICAwLAogICAgICA3LAogICAgICAwLAogICAgICAiTU9ERUwiCiAgICBdLAogICAgWwogICAgICAzLAogICAgICAyLAogICAgICAwLAogICAgICA0LAogICAgICAwLAogICAgICAiQ0xJUCIKICAgIF0sCiAgICBbCiAgICAgIDQsCiAgICAgIDQsCiAgICAgIDAsCiAgICAgIDgsCiAgICAgIDEsCiAgICAgICJDT05ESVRJT05JTkciCiAgICBdLAogICAgWwogICAgICA1LAogICAgICA0LAogICAgICAwLAogICAgICA1LAogICAgICAwLAogICAgICAiQ09ORElUSU9OSU5HIgogICAgXSwKICAgIFsKICAgICAgNiwKICAgICAgNywKICAgICAgMCwKICAgICAgOCwKICAgICAgMCwKICAgICAgIk1PREVMIgogICAgXSwKICAgIFsKICAgICAgNywKICAgICAgNSwKICAgICAgMCwKICAgICAgOCwKICAgICAgMiwKICAgICAgIkNPTkRJVElPTklORyIKICAgIF0sCiAgICBbCiAgICAgIDgsCiAgICAgIDYsCiAgICAgIDAsCiAgICAgIDgsCiAgICAgIDMsCiAgICAgICJMQVRFTlQiCiAgICBdLAogICAgWwogICAgICA5LAogICAgICAzLAogICAgICAwLAogICAgICA5LAogICAgICAxLAogICAgICAiVkFFIgogICAgXSwKICAgIFsKICAgICAgMTAsCiAgICAgIDgsCiAgICAgIDAsCiAgICAgIDksCiAgICAgIDAsCiAgICAgICJMQVRFTlQiCiAgICBdLAogICAgWwogICAgICAxMSwKICAgICAgOSwKICAgICAgMCwKICAgICAgMTAsCiAgICAgIDAsCiAgICAgICJJTUFHRSIKICAgIF0KICBdLAogICJncm91cHMiOiBbXSwKICAiY29uZmlnIjoge30sCiAgImV4dHJhIjogewogICAgImRzIjogewogICAgICAic2NhbGUiOiAwLjcyLAogICAgICAib2Zmc2V0IjogWwogICAgICAgIDEyMCwKICAgICAgICAxMjAKICAgICAgXQogICAgfQogIH0sCiAgInZlcnNpb24iOiAwLjQKfQ=="

STATE_DIR="${BASE_DIR}/.zimage_elusarca_lora_v1"
LOG_FILE="${STATE_DIR}/setup.log"
STATUS_FILE="${STATE_DIR}/status"
PHASE_FILE="${STATE_DIR}/phase"
PID_FILE="${STATE_DIR}/setup.pid"
LOCK_DIR="${STATE_DIR}/setup.lock.d"
HEARTBEAT_SECONDS="${HEARTBEAT_SECONDS:-15}"

mkdir -p "${STATE_DIR}"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
say() {
  echo
  echo "================================================================"
  echo "[$(ts)] $*"
  echo "================================================================"
}
set_phase() { echo "$*" > "${PHASE_FILE}"; }
is_pid_alive() { [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null; }

usage() {
  cat <<'EOF'
Usage:
  ./runpod_zimage_elusarca_lora_addon_v1.sh
  ./runpod_zimage_elusarca_lora_addon_v1.sh --status
  ./runpod_zimage_elusarca_lora_addon_v1.sh --follow

Environment overrides:
  BASE_DIR=/workspace/runpod-slim
  COMFY_PORT=8188

This add-on NEVER generates an image.
EOF
}

show_status() {
  echo "=== ${SCRIPT_NAME} status ==="
  echo "Status : $(cat "${STATUS_FILE}" 2>/dev/null || echo NOT_STARTED)"
  echo "Phase  : $(cat "${PHASE_FILE}" 2>/dev/null || echo -)"
  local pid=""
  pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if is_pid_alive "$pid"; then
    echo "Worker : RUNNING (PID $pid)"
    ps -p "$pid" -o pid=,etime=,%cpu=,%mem=,stat=,cmd= 2>/dev/null || true
  else
    echo "Worker : not running${pid:+ (last PID $pid)}"
  fi
  echo "Log    : ${LOG_FILE}"
  echo "ComfyUI: ${COMFY_DIR}"
  echo "Port   : ${PORT}"
}

follow_log() {
  touch "${LOG_FILE}"
  echo "Following ${LOG_FILE}"
  echo "Reconnect with:"
  echo "  ${BASE_DIR}/${SCRIPT_NAME}.sh --follow"
  tail -n 100 -F "${LOG_FILE}"
}

worker_error() {
  local line="${1:-?}"
  echo "FAILED" > "${STATUS_FILE}"
  set_phase "FAILED at line ${line}"
  echo
  echo "[FATAL] Setup failed at line ${line}"
  tail -n 120 "${LOG_FILE}" 2>/dev/null || true
}

need_tools() {
  local missing=()
  for c in python3 curl lsof sha256sum; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done

  if ((${#missing[@]})); then
    say "Install missing OS tools: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends python3 curl lsof coreutils ca-certificates
  fi

  if ! command -v aria2c >/dev/null 2>&1; then
    say "Install aria2 for resumable model download"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends aria2
  fi
}

preflight() {
  say "Preflight: verify existing Z-Image V4 environment"
  set_phase "Preflight"

  [[ -f "${COMFY_DIR}/main.py" ]] || {
    echo "[FATAL] Missing ${COMFY_DIR}/main.py"
    echo "Run the known-working Z-Image V4 setup first."
    exit 10
  }

  [[ -x "${VENV_DIR}/bin/python" ]] || {
    echo "[FATAL] Missing ComfyUI venv: ${VENV_DIR}"
    exit 11
  }

  local required=(
    "${COMFY_DIR}/models/diffusion_models/z_image_turbo_bf16.safetensors"
    "${COMFY_DIR}/models/text_encoders/qwen_3_4b.safetensors"
    "${COMFY_DIR}/models/vae/ae.safetensors"
  )
  for f in "${required[@]}"; do
    [[ -s "$f" ]] || {
      echo "[FATAL] Missing Z-Image core file: $f"
      exit 12
    }
  done

  mkdir -p "${LORA_DIR}" "${WORKFLOW_DIR}" "${EXPORT_WF_DIR}"
  echo "[OK] Existing Z-Image environment found."
}

validate_safetensors() {
  local file="$1"
  local min_bytes="$2"

  "${VENV_DIR}/bin/python" - "$file" "$min_bytes" <<'PY'
import json, os, struct, sys
p=sys.argv[1]
min_b=int(sys.argv[2])
size=os.path.getsize(p)
if size < min_b:
    raise SystemExit(f"file too small: {size} < {min_b}: {p}")
with open(p, "rb") as f:
    raw=f.read(8)
    if len(raw) != 8:
        raise SystemExit("missing safetensors header length")
    hlen=struct.unpack("<Q", raw)[0]
    if hlen <= 2 or hlen > 100_000_000:
        raise SystemExit(f"invalid safetensors header length: {hlen}")
    header=f.read(hlen)
    obj=json.loads(header)
    if not isinstance(obj, dict):
        raise SystemExit("invalid safetensors JSON header")
print(f"VALID SAFETENSORS: {p} size={size} header={hlen}")
PY
}

download_lora() {
  say "Download / verify Elusarca Anime Style LoRA"
  set_phase "Download LoRA"

  local dest="${LORA_DIR}/${LORA_NAME}"

  if [[ -s "$dest" ]]; then
    local current_sha
    current_sha="$(sha256sum "$dest" | awk '{print $1}')"
    if [[ "$current_sha" == "${LORA_SHA256}" ]]; then
      validate_safetensors "$dest" "${LORA_MIN_BYTES}"
      echo "[SKIP] LoRA already installed and SHA256 verified."
      return 0
    fi
    echo "[WARN] Existing file hash differs; downloading a clean copy."
    rm -f "$dest" "$dest.aria2" || true
  fi

  aria2c \
    --continue=true \
    --allow-overwrite=true \
    --auto-file-renaming=false \
    --max-connection-per-server=8 \
    --split=8 \
    --min-split-size=10M \
    --retry-wait=5 \
    --max-tries=0 \
    --timeout=30 \
    --connect-timeout=30 \
    --console-log-level=notice \
    --dir="$(dirname "$dest")" \
    --out="$(basename "$dest")" \
    "${LORA_URL}"

  validate_safetensors "$dest" "${LORA_MIN_BYTES}"

  local got_sha
  got_sha="$(sha256sum "$dest" | awk '{print $1}')"
  if [[ "$got_sha" != "${LORA_SHA256}" ]]; then
    echo "[FATAL] SHA256 mismatch."
    echo "Expected: ${LORA_SHA256}"
    echo "Actual  : $got_sha"
    exit 20
  fi

  echo "[OK] LoRA SHA256 verified: $got_sha"
}

write_workflow() {
  say "Install LoRA-enabled ComfyUI workflow"
  set_phase "Write workflow"

  "${VENV_DIR}/bin/python" - "${WORKFLOW_B64}" "${WORKFLOW_DIR}/${WORKFLOW_NAME}" "${EXPORT_WF_DIR}/${WORKFLOW_NAME}" <<'PY'
import base64, json, pathlib, sys
raw=base64.b64decode(sys.argv[1]).decode("utf-8")
obj=json.loads(raw)
for name in sys.argv[2:]:
    p=pathlib.Path(name)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(obj, ensure_ascii=False, indent=2), encoding="utf-8")
    json.loads(p.read_text(encoding="utf-8"))
    print("WROTE", p)
PY

  cat > "${EXPORT_WF_DIR}/ZIMAGE_ELUSARCA_ANIME_README.txt" <<'EOF'
Z-Image-Turbo + Elusarca Anime Style LoRA

Workflow:
  booth_zimage_elusarca_anime_v1.json

LoRA:
  elusarca-anime-style.safetensors

Default LoRA strength:
  1.0

Recommended range from model card:
  0.8 - 1.3

Trigger:
  elusarca anime style

Recommended prompt prefix:
  high-quality anime illustration, 2D, clean lineart,
  cel-shaded, vibrant colors, soft shading

Suggested comparison:
  0.0 = off
  0.8 = lighter anime effect
  1.0 = baseline
  1.2 = stronger illustration effect

This installer does NOT generate images.
EOF
}

safe_restart_comfy() {
  say "Restart ComfyUI safely on port ${PORT}"
  set_phase "Restart ComfyUI"

  local listeners
  listeners="$(lsof -ti TCP:"${PORT}" -sTCP:LISTEN 2>/dev/null | sort -u || true)"

  if [[ -n "$listeners" ]]; then
    for pid in $listeners; do
      local cwd cmd
      cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
      cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
      echo "Port ${PORT} listener: PID=$pid CWD=$cwd CMD=$cmd"

      if [[ "$cwd" == "$COMFY_DIR" || "$cmd" == *"$COMFY_DIR/main.py"* ]]; then
        echo "Stopping existing ComfyUI belonging to this environment."
        kill "$pid" 2>/dev/null || true
        for _ in {1..30}; do
          kill -0 "$pid" 2>/dev/null || break
          sleep 1
        done
      else
        echo "[FATAL] Port ${PORT} is used by a process outside ${COMFY_DIR}."
        echo "Refusing to kill it automatically."
        exit 30
      fi
    done
  fi

  cd "${COMFY_DIR}"
  # shellcheck disable=SC1091
  source "${VENV_DIR}/bin/activate"

  nohup python main.py \
    --listen "${HOST}" \
    --port "${PORT}" \
    --preview-method auto \
    > comfyui_8188.log 2>&1 < /dev/null &

  local pid=$!
  echo "$pid" > comfyui_8188.pid
  echo "Started ComfyUI PID $pid"

  for i in {1..48}; do
    if curl -fsS "http://127.0.0.1:${PORT}/system_stats" >/dev/null 2>&1; then
      echo "[OK] ComfyUI HTTP ready on port ${PORT}."
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "[FATAL] ComfyUI exited during startup."
      tail -n 160 comfyui_8188.log || true
      exit 31
    fi
    echo "[ALIVE] ComfyUI startup elapsed=$((i*5))s PID=$pid"
    sleep 5
  done

  echo "[FATAL] ComfyUI did not become ready in time."
  tail -n 160 comfyui_8188.log || true
  exit 32
}

verify_comfy_visibility() {
  say "Verify LoRA node and LoRA visibility (NO image generation)"
  set_phase "Verify ComfyUI visibility"

  "${VENV_DIR}/bin/python" - "${PORT}" "${LORA_NAME}" <<'PY'
import json, sys, urllib.request
port=int(sys.argv[1])
lora_name=sys.argv[2]
with urllib.request.urlopen(f"http://127.0.0.1:{port}/object_info", timeout=60) as r:
    obj=json.load(r)

required = [
    "UNETLoader",
    "CLIPLoader",
    "VAELoader",
    "CLIPTextEncode",
    "ConditioningZeroOut",
    "EmptySD3LatentImage",
    "ModelSamplingAuraFlow",
    "KSampler",
    "VAEDecode",
    "SaveImage",
    "LoraLoaderModelOnly",
]
missing=[n for n in required if n not in obj]
if missing:
    raise SystemExit("Missing required nodes: " + ", ".join(missing))

loader=obj["LoraLoaderModelOnly"]
choices=loader.get("input",{}).get("required",{}).get("lora_name",[[]])[0]
if lora_name not in choices:
    raise SystemExit(
        f"LoRA is not visible in LoraLoaderModelOnly: {lora_name}\n"
        f"Visible LoRAs sample: {choices[:20]}"
    )

print("ALL REQUIRED NODES PRESENT")
print("[OK] LoRA visible:", lora_name)
print("No image generation was performed.")
PY
}

summary() {
  echo "READY" > "${STATUS_FILE}"
  set_phase "READY"

  say "Z-IMAGE + ELUSARCA ANIME LORA READY"
  cat <<EOF
READY

No image was generated.

LoRA:
  ${LORA_DIR}/${LORA_NAME}

Workflow inside ComfyUI:
  ${WORKFLOW_DIR}/${WORKFLOW_NAME}

Easy-to-find workflow copy:
  ${EXPORT_WF_DIR}/${WORKFLOW_NAME}

Notes:
  ${EXPORT_WF_DIR}/ZIMAGE_ELUSARCA_ANIME_README.txt

ComfyUI:
  ${COMFY_DIR}
  Port ${PORT}

Workflow defaults:
  LoRA strength = 1.0
  Trigger       = elusarca anime style
  Size          = 832 x 1216
  Steps         = 8
  CFG           = 1.0
  Sampler       = res_multistep
  Scheduler     = simple

To disable LoRA:
  Set LoraLoaderModelOnly strength_model to 0.0.

Suggested strength comparison:
  0.8 -> 1.0 -> 1.2

Status:
  ${BASE_DIR}/${SCRIPT_NAME}.sh --status

Follow log:
  ${BASE_DIR}/${SCRIPT_NAME}.sh --follow
EOF
}

worker_main() {
  trap '' HUP
  trap 'worker_error $LINENO' ERR

  if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    local old=""
    old="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if is_pid_alive "$old"; then
      echo "[FATAL] Another installer worker is already running: PID $old"
      exit 40
    fi
    rm -rf "${LOCK_DIR}" || true
    mkdir "${LOCK_DIR}"
  fi

  trap 'rm -rf "${LOCK_DIR}" 2>/dev/null || true' EXIT

  echo "$$" > "${PID_FILE}"
  echo "RUNNING" > "${STATUS_FILE}"
  set_phase "Starting"

  (
    while true; do
      sleep "${HEARTBEAT_SECONDS}"
      echo "[HEARTBEAT $(ts)] status=$(cat "${STATUS_FILE}" 2>/dev/null || echo ?) phase=$(cat "${PHASE_FILE}" 2>/dev/null || echo ?)"
    done
  ) &
  local heartbeat_pid=$!
  trap 'kill "${heartbeat_pid}" 2>/dev/null || true; rm -rf "${LOCK_DIR}" 2>/dev/null || true' EXIT

  need_tools
  preflight
  download_lora
  write_workflow
  safe_restart_comfy
  verify_comfy_visibility
  summary
}

launch_detached() {
  local old=""
  old="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if is_pid_alive "$old"; then
    echo "Installer already running: PID $old"
    follow_log
    return
  fi

  : > "${LOG_FILE}"
  nohup bash "${BASH_SOURCE[0]}" --worker >> "${LOG_FILE}" 2>&1 < /dev/null &
  local pid=$!
  echo "$pid" > "${PID_FILE}"

  echo "Started detached installer worker: PID $pid"
  echo "Installer continues even if the browser Terminal disconnects."
  echo "Log: ${LOG_FILE}"
  sleep 1
  follow_log
}

case "${1:-}" in
  --worker)
    exec > >(tee -a "${LOG_FILE}") 2>&1
    worker_main
    ;;
  --status)
    show_status
    ;;
  --follow)
    follow_log
    ;;
  --help|-h)
    usage
    ;;
  "")
    launch_detached
    ;;
  *)
    usage
    exit 2
    ;;
esac
