# RunPod Serverless — ComfyUI 무검열 이미지 생성 워커
# (팟 kerotr5xru5eki의 구성을 서버리스 이미지로 이전)
# 모델은 부팅 시 startup.sh에서 다운로드 (이미지 용량 최소화, 콜드스타트 시 받음)

FROM runpod/pytorch:1.1.0-cu1281-torch280-ubuntu2404

# 기본 유틸
RUN apt-get update -y && apt-get install -y git curl wget unzip ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Python deps (cryptography 데비안 설치본 충돌 방지 — --ignore-installed)
RUN pip install --no-cache-dir --ignore-installed runpod fastapi uvicorn

# ComfyUI
WORKDIR /
RUN git clone https://github.com/comfyanonymous/ComfyUI.git /ComfyUI

# ComfyUI 핵심 의존성 (requirements.txt) — 그래야 ComfyUI가 부팅됨
RUN pip install --no-cache-dir -r /ComfyUI/requirements.txt

# 커스텀 노드 (IPAdapter_plus — FaceID)
RUN git clone https://github.com/cubiq/ComfyUI_IPAdapter_plus.git /ComfyUI/custom_nodes/ComfyUI_IPAdapter_plus

# ReActor 노드 (얼굴 스왑) — 구 저장소(comfyui-reactor-node)는 GitHub 비활성화 → 신규 주소 사용
RUN git clone https://github.com/Gourieff/comfyui-reactor.git /ComfyUI/custom_nodes/comfyui-reactor-node

# ReActor 의존성 (insightface, onnx 등 — 설치 실패해도 무시하고 계속)
RUN pip install --no-cache-dir insightface onnxruntime opencv-python-headless || true

# 커스텀 노드 모델 디렉토리 생성 (startup이 모델 받는 곳)
RUN mkdir -p /models/checkpoints /models/controlnet /models/clip_vision \
    && mkdir -p /ComfyUI/models/checkpoints /ComfyUI/models/controlnet /ComfyUI/models/clip_vision \
    && mkdir -p /ComfyUI/models/insightface /ComfyUI/models/facerestore_models

# 핸들러 + 부팅 스크립트
COPY handler.py /handler.py
COPY startup.sh /startup.sh
RUN chmod +x /startup.sh

# ComfyUI 실행 포트
EXPOSE 3000

CMD ["bash", "/startup.sh"]