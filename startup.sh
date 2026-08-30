#!/usr/bin/env bash
# RunPod Serverless ComfyUI 워커 부팅 스크립트
# - 모델 다운로드 (없을 때만)
# - ComfyUI 기동
# - 핸들러 실행

set -e

echo "[startup] 모델 준비 시작 $(date)"

# ── 모델 다운로드 (HuggingFace) ─────────────────────────────
# CreaLISM 대체: samsmith47/photorealistic_nsfw_v2 (무검열 실사 NSFW SDXL, 단일 checkpoint)
#   (원래 CreaLISM은 CivitAI 로그인 필요 → VPS에서 다운로드 불가, 2026-08-30 판정)
if [ ! -f /ComfyUI/models/checkpoints/crealism_v2.safetensors ]; then
  echo "[startup] 무검열 NSFW 모델 다운로드 (photorealistic_nsfw_v2)..."
  cd /ComfyUI/models/checkpoints
  curl -sL -o creatism_v2.safetensors "https://huggingface.co/samsmith47/photorealistic_nsfw_v2/resolve/main/photorealistic_nude.safetensors" || true
  echo "[startup] 다운로드 결과: $(ls -la creatism_v2.safetensors 2>/dev/null | awk '{print $5}') bytes"
fi

# RealVisXL V4.0
if [ ! -f /ComfyUI/models/checkpoints/realvisxl_v40.safetensors ]; then
  echo "[startup] RealVisXL 다운로드..."
  cd /ComfyUI/models/checkpoints
  curl -sL -o realvisxl_v40.safetensors "https://huggingface.co/SG161222/RealVisXL_V4.0/resolve/main/RealVisXL_V4.0.safetensors" || true
fi

# ControlNet OpenPose (SD15)
if [ ! -f /ComfyUI/models/controlnet/control_v11p_sd15_openpose.pth ]; then
  echo "[startup] ControlNet OpenPose 다운로드..."
  cd /ComfyUI/models/controlnet
  curl -sL -o control_v11p_sd15_openpose.pth "https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_openpose.pth" || true
fi

# CLIP Vision (FaceID용)
if [ ! -f /ComfyUI/models/clip_vision/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors ]; then
  echo "[startup] CLIP Vision 다운로드..."
  cd /ComfyUI/models/clip_vision
  curl -sL -o CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors "https://huggingface.co/h94/IP-Adapter/resolve/main/models/image_encoder/model.safetensors" || true
fi

echo "[startup] 모델 준비 완료"
ls -la /ComfyUI/models/checkpoints/ 2>/dev/null | head -20 || true

# ── ComfyUI 기동 ────────────────────────────────────────────
echo "[startup] ComfyUI 시작..."
cd /ComfyUI
setsid nohup python3 main.py --port 3000 > /tmp/comfy.log 2>&1 < /dev/null &
COMFY_PID=$!
echo "[startup] ComfyUI PID: $COMFY_PID"

# ComfyUI ready 대기 (최대 300초)
for i in $(seq 1 60); do
  if curl -s http://127.0.0.1:3000/system_stats >/dev/null 2>&1; then
    echo "[startup] ComfyUI 준비 완료 (${i}x4초)"
    break
  fi
  sleep 4
done

# ── 핸들러 실행 (RunPod SDK가 이 프로세스를 worker로 인식) ──
echo "[startup] 핸들러 실행"
python3 -u /handler.py