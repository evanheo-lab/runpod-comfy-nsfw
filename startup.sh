#!/usr/bin/env bash
# RunPod Serverless ComfyUI 워커 부팅 스크립트
# - 모델은 네트워크 볼륨(/runpod-volume/models)에 저장 → 워커 재시작에도 재사용
# - 없을 때만 다운로드, ComfyUI는 볼륨 모델을 심볼릭링크로 참조
# - ComfyUI 기동 → 핸들러 실행

set -e

echo "[startup] 모델 준비 시작 $(date)"

# ── 모델 저장소 (볼륨 우선, 없으면 컨테이너 로컬) ───────────
MODEL_ROOT="/ComfyUI/models"
if [ -d /runpod-volume ]; then
  VOL_MODELS="/runpod-volume/models"
  mkdir -p "$VOL_MODELS/checkpoints" "$VOL_MODELS/controlnet" "$VOL_MODELS/clip_vision" "$VOL_MODELS/ipadapter" "$VOL_MODELS/insightface" "$VOL_MODELS/facerestore_models"
  # 심볼릭 링크: ComfyUI 경로 → 볼륨
  for sub in checkpoints controlnet clip_vision ipadapter insightface facerestore_models; do
    if [ ! -L "$MODEL_ROOT/$sub" ] && [ -d "$MODEL_ROOT/$sub" ]; then
      rm -rf "$MODEL_ROOT/$sub"
    fi
    mkdir -p "$MODEL_ROOT"
    ln -sfn "$VOL_MODELS/$sub" "$MODEL_ROOT/$sub"
  done
  echo "[startup] 볼륨 모델 경로 사용: $VOL_MODELS"
fi

# ── 모델 다운로드 (볼륨/로컬에 없을 때만) ───────────────────
# CreaLISM 대체: samsmith47/photorealistic_nsfw_v2 (무검열 실사 NSFW SDXL, 단일 checkpoint)
#   (원래 CreaLISM은 CivitAI 로그인 필요 → VPS에서 다운로드 불가, 2026-08-30 판정)
if [ ! -f $MODEL_ROOT/checkpoints/crealism_v2.safetensors ]; then
  echo "[startup] 무검열 NSFW 모델 다운로드 (photorealistic_nsfw_v2)..."
  curl -sL -o $MODEL_ROOT/checkpoints/crealism_v2.safetensors "https://huggingface.co/samsmith47/photorealistic_nsfw_v2/resolve/main/photorealistic_nude.safetensors" || true
  echo "[startup] 다운로드 결과: $(ls -la $MODEL_ROOT/checkpoints/crealism_v2.safetensors 2>/dev/null | awk '{print $5}') bytes"
fi

# RealVisXL V4.0
if [ ! -f $MODEL_ROOT/checkpoints/realvisxl_v40.safetensors ]; then
  echo "[startup] RealVisXL 다운로드..."
  curl -sL -o $MODEL_ROOT/checkpoints/realvisxl_v40.safetensors "https://huggingface.co/SG161222/RealVisXL_V4.0/resolve/main/RealVisXL_V4.0.safetensors" || true
fi

# ControlNet OpenPose (SD15)
if [ ! -f $MODEL_ROOT/controlnet/control_v11p_sd15_openpose.pth ]; then
  echo "[startup] ControlNet OpenPose 다운로드..."
  curl -sL -o $MODEL_ROOT/controlnet/control_v11p_sd15_openpose.pth "https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_openpose.pth" || true
fi

# CLIP Vision (FaceID용)
if [ ! -f $MODEL_ROOT/clip_vision/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors ]; then
  echo "[startup] CLIP Vision 다운로드..."
  curl -sL -o $MODEL_ROOT/clip_vision/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors "https://huggingface.co/h94/IP-Adapter/resolve/main/models/image_encoder/model.safetensors" || true
fi

# ── 얼굴 유지(FaceID) + ReActor 모델 (재시작에도 볼륨에 보존) ──
# IPAdapter FaceID 디렉토리
mkdir -p $MODEL_ROOT/ipadapter
# IPAdapter FaceID Plus v2 (SDXL)
if [ ! -f $MODEL_ROOT/ipadapter/ip-adapter-faceid-plusv2_sdxl.bin ]; then
  echo "[startup] IPAdapter FaceID 다운로드..."
  curl -sL -o $MODEL_ROOT/ipadapter/ip-adapter-faceid-plusv2_sdxl.bin "https://huggingface.co/h94/IP-Adapter-FaceID/resolve/main/ip-adapter-faceid-plusv2_sdxl.bin" || true
fi
# IPAdapter FaceID lora
if [ ! -f $MODEL_ROOT/ipadapter/ip-adapter-faceid-plusv2_sdxl_lora.safetensors ]; then
  echo "[startup] IPAdapter FaceID lora 다운로드..."
  curl -sL -o $MODEL_ROOT/ipadapter/ip-adapter-faceid-plusv2_sdxl_lora.safetensors "https://huggingface.co/h94/IP-Adapter-FaceID/resolve/main/ip-adapter-faceid-plusv2_sdxl_lora.safetensors" || true
fi
# ReActor — inswapper + GFPGAN (facerestore)
mkdir -p $MODEL_ROOT/insightface $MODEL_ROOT/facerestore_models
if [ ! -f $MODEL_ROOT/insightface/inswapper_128.onnx ]; then
  echo "[startup] ReActor inswapper 다운로드..."
  curl -sL -o $MODEL_ROOT/insightface/inswapper_128.onnx "https://huggingface.co/datasets/Gourieff/ReActor/resolve/main/models/inswapper_128.onnx" || true
fi
if [ ! -f $MODEL_ROOT/facerestore_models/GFPGANv1.4.pth ]; then
  echo "[startup] GFPGAN 다운로드..."
  curl -sL -o $MODEL_ROOT/facerestore_models/GFPGANv1.4.pth "https://github.com/TencentARC/GFPGAN/releases/download/v1.3.0/GFPGANv1.4.pth" || true
fi

echo "[startup] 모델 준비 완료"
ls -la $MODEL_ROOT/checkpoints/ 2>/dev/null | head -20 || true

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