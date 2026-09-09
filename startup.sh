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
  mkdir -p "$VOL_MODELS/checkpoints" "$VOL_MODELS/controlnet" "$VOL_MODELS/clip_vision" "$VOL_MODELS/ipadapter" "$VOL_MODELS/loras" "$VOL_MODELS/insightface" "$VOL_MODELS/facerestore_models"
  # 심볼릭 링크: ComfyUI 경로 → 볼륨
  for sub in checkpoints controlnet clip_vision ipadapter loras insightface facerestore_models; do
    if [ ! -L "$MODEL_ROOT/$sub" ] && [ -d "$MODEL_ROOT/$sub" ]; then
      rm -rf "$MODEL_ROOT/$sub"
    fi
    mkdir -p "$MODEL_ROOT"
    ln -sfn "$VOL_MODELS/$sub" "$MODEL_ROOT/$sub"
  done
  echo "[startup] 볼륨 모델 경로 사용: $VOL_MODELS"
fi

# ── 모델 다운로드 (볼륨/로컬에 없을 때만) ───────────────────
# 실사 모델 = RealVisXL V5.0 (fp16 6.9GB, 무검열 프롬프트로 처리) — 2026-09-09 V4.0→V5.0 교체
if [ ! -f $MODEL_ROOT/checkpoints/RealVisXL_V5.0_fp16.safetensors ]; then
  echo "[startup] RealVisXL V5.0 다운로드..."
  curl -sL -o $MODEL_ROOT/checkpoints/RealVisXL_V5.0_fp16.safetensors "https://huggingface.co/SG161222/RealVisXL_V5.0/resolve/main/RealVisXL_V5.0_fp16.safetensors" || true
fi

# ── Juggernaut XL v9 (고퀄리티 실사 보조) — 2026-09-09 추가 ──
# 출처: HF RunDiffusion/Juggernaut-XL-v9 (Civitai Juggernaut XL 계열, 실사·시네마틱 강점)
if [ ! -f $MODEL_ROOT/checkpoints/Juggernaut-XL_v9_RunDiffusionPhoto_v2.safetensors ]; then
  echo "[startup] Juggernaut XL v9 다운로드..."
  curl -sL -o $MODEL_ROOT/checkpoints/Juggernaut-XL_v9_RunDiffusionPhoto_v2.safetensors "https://huggingface.co/RunDiffusion/Juggernaut-XL-v9/resolve/main/Juggernaut-XL_v9_RunDiffusionPhoto_v2.safetensors" || true
fi

# ── RealVisXL V4.0 (실사 NSFW 표현용 복귀) — 2026-09-09 추가 ──
# 출처: HF SG161222/RealVisXL_V4.0 (V5.0은 정화 필터로 누드 표현 제한 → V4.0 복귀)
# 기존 스크립트 호환을 위해 파일명 realvisxl_v40.safetensors 유지
if [ ! -f $MODEL_ROOT/checkpoints/realvisxl_v40.safetensors ]; then
  echo "[startup] RealVisXL V4.0 다운로드..."
  curl -sL -o $MODEL_ROOT/checkpoints/realvisxl_v40.safetensors "https://huggingface.co/SG161222/RealVisXL_V4.0/resolve/main/RealVisXL_V4.0.safetensors" || true
fi

# ── CreaLISM (NSFW 전용 SDXL) — 남성기·삽입 표현용 (2026-08-31 추가) ──
# 출처: Civitai model 1836368 (Terra Mirabilis PhotoRealistic NSFW SDXL), v2.0
# Civitai 토큰은 엔드포인트 env(CIVITAI_TOKEN)로 주입됨
# ★ 크기 검증: 정상 파일은 6.7GB. 1GB 미만(이전 잔여 불량 612MB)이면 재다운로드
CREALISM_SIZE=$(stat -c%s $MODEL_ROOT/checkpoints/crealism_v2.safetensors 2>/dev/null || echo 0)
if [ ! -f $MODEL_ROOT/checkpoints/crealism_v2.safetensors ] || [ "$CREALISM_SIZE" -lt 1000000000 ]; then
  if [ -n "$CIVITAI_TOKEN" ]; then
    echo "[startup] CreaLISM 다운로드: 기존 크기=${CREALISM_SIZE} bytes (6.7GB 필요) — Civitai에서 재다운로드..."
    rm -f $MODEL_ROOT/checkpoints/crealism_v2.safetensors
    curl -sL --retry 3 --retry-all-errors -H "Authorization: Bearer $CIVITAI_TOKEN" \
          -o $MODEL_ROOT/checkpoints/crealism_v2.safetensors \
          "https://civitai.com/api/download/models/2237143?fileId=2130410" || true
    echo "[startup] CreaLISM 결과: $(ls -la $MODEL_ROOT/checkpoints/crealism_v2.safetensors 2>/dev/null | awk '{print $5}') bytes"
  else
    echo "[startup] CIVITAI_TOKEN 없음 — CreaLISM 스킵"
  fi
fi

# ── Illustrious-XL (애니메/만화 NSFW 전용 SDXL) — 2026-09-08 추가 ──
# 출처: HF 미러 Liberata/illustrious-xl-v1.0 (Civitai model 795765 v1.0과 동일, 6.9GB)
# 용도: 만화/아니메 이미지 → 화풍 유지 NSFW 변환
# ★ 2026-09-08 저녁: 부팅 시 다운로드는 제거.
#   원인: 부팅 시간 한계(수 분) 내 6.9GB 다운로드가 불가해 throttled 루프 반복,
#         resume(-C -)으로 "크기는 맞지만 내용 손상" 파일이 생김.
#   해결: handler.py가 첫 요청 시 헤더까지 검증해 손상 파일을 temp로 새로 받아 교체.
#         (워커는 항상 빠르게 ready → 부팅 타임아웃 원천 차단)

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
# IPAdapter FaceID lora — ★ loras 폴더에 넣어야 IPAdapter_plus가 찾음 (2026-08-30 확정)
if [ ! -f $MODEL_ROOT/loras/ip-adapter-faceid-plusv2_sdxl_lora.safetensors ]; then
  echo "[startup] IPAdapter FaceID lora 다운로드 (loras 폴더)..."
  curl -sL -o $MODEL_ROOT/loras/ip-adapter-faceid-plusv2_sdxl_lora.safetensors "https://huggingface.co/h94/IP-Adapter-FaceID/resolve/main/ip-adapter-faceid-plusv2_sdxl_lora.safetensors" || true
fi

# ── 성인 체위/삽입 LoRA (2026-08-31 추가 — 삽입 장면 표현용) ──
# 1) 남성/성기 표현 LoRA (pguy v1, Pony/SDXL 호환) 218MB
if [ ! -f $MODEL_ROOT/loras/pguy.safetensors ]; then
  if [ -n "$CIVITAI_TOKEN" ]; then
    echo "[startup] pguy LoRA (남성 표현) 다운로드..."
    curl -sL -H "Authorization: Bearer $CIVITAI_TOKEN" \
      -o $MODEL_ROOT/loras/pguy.safetensors \
      "https://civitai.com/api/download/models/1507868?fileId=1408088" || true
    echo "[startup] pguy LoRA 결과: $(ls -la $MODEL_ROOT/loras/pguy.safetensors 2>/dev/null | awk '{print $5}') bytes"
  fi
fi
# 2) 삽입 제스처 LoRA (segg_gesture v2, Pony/SDXL 호환) 122MB
if [ ! -f $MODEL_ROOT/loras/segg_gesture_v2.safetensors ]; then
  if [ -n "$CIVITAI_TOKEN" ]; then
    echo "[startup] segg_gesture LoRA (삽입 제스처) 다운로드..."
    curl -sL -H "Authorization: Bearer $CIVITAI_TOKEN" \
      -o $MODEL_ROOT/loras/segg_gesture_v2.safetensors \
      "https://civitai.com/api/download/models/485933?fileId=404005" || true
    echo "[startup] segg_gesture 결과: $(ls -la $MODEL_ROOT/loras/segg_gesture_v2.safetensors 2>/dev/null | awk '{print $5}') bytes"
  fi
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
# 디버그: 볼륨 내 모델 전체 출력
echo "=== ipadapter ==="
ls -la $MODEL_ROOT/ipadapter/ 2>/dev/null || echo "(ipadapter 없음)"
echo "=== lora (ipadapter dir) ==="
ls -la $MODEL_ROOT/ipadapter/*.safetensors 2>/dev/null || echo "(lora 없음)"
echo "=== clip_vision ==="
ls -la $MODEL_ROOT/clip_vision/ 2>/dev/null || echo "(clip_vision 없음)"

# ── ReActor 커스텀 노드 의존성 보강 (ComfyUI 시작 전!) ──────
# insightface가 이미 설치되어 있으면 skip, 없으면 설치 시도
python3 -c "import insightface" 2>/dev/null && echo "[startup] insightface 이미 설치됨" || {
  echo "[startup] insightface 설치 시도..."
  pip install --no-cache-dir insightface onnxruntime-gpu 2>&1 | tail -3 || echo "[startup] insightface 설치 실패(무시)"
}
# ReActor install.py 실행 (모델 buffalo_l/inswapper 자동 설치 — folder_paths import가 실패할 수 있어 예외 처리)
cd /ComfyUI/custom_nodes/comfyui-reactor-node && python3 install.py 2>&1 | tail -5 || echo "[startup] ReActor install.py 스킵"

# ── ComfyUI 기동 ────────────────────────────────────────────
echo "[startup] ComfyUI 시작..."
cd /ComfyUI
setsid nohup python3 main.py --port 3000 > /tmp/comfy.log 2>&1 < /dev/null &
COMFY_PID=$!
echo "[startup] ComfyUI PID: $COMFY_PID"
# ComfyUI 로그를 워커 로그 스트림으로 실시간 포워딩 (디버깅용)
setsid nohup tail -f /tmp/comfy.log > /proc/1/fd/1 2>&1 < /dev/null &
echo "[startup] ComfyUI 로그 포워딩 시작"

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