# RunPod Serverless — ComfyUI 무검열 이미지 생성 워커
# (팟 kerotr5xru5eki의 구성을 서버리스 이미지로 이전)
# 모델은 부팅 시 startup.sh에서 다운로드 (이미지 용량 최소화, 콜드스타트 시 받음)

FROM runpod/pytorch:1.1.0-cu1281-torch280-ubuntu2404

# 기본 유틸
RUN apt-get update -y && apt-get install -y git curl wget unzip ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Python deps
RUN pip install --no-cache-dir runpod fastapi uvicorn

# ComfyUI
WORKDIR /
RUN git clone https://github.com/comfyanonymous/ComfyUI.git /ComfyUI

# 커스텀 노드 (IPAdapter_plus — FaceID)
RUN git clone https://github.com/cubiq/ComfyUI_IPAdapter_plus.git /ComfyUI/custom_nodes/ComfyUI_IPAdapter_plus

# ReActor 노드 (얼굴 스왑)
RUN git clone https://github.com/Gourieff/comfyui-reactor-node.git /ComfyUI/custom_nodes/comfyui-reactor-node

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