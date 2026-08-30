
"""ComfyUI 서버리스 핸들러 — 무검열 이미지 생성/변환
RunPod Serverless Worker: input = {image_b64, prompt, mode, ...} → output = {image_b64, outputs}
"""
import json, base64, os, time, subprocess, urllib.request, uuid, glob

COMFY_URL = os.environ.get("COMFY_URL", "http://127.0.0.1:3000")

def upload(path):
    boundary = "----" + uuid.uuid4().hex
    with open(path, "rb") as f:
        data = f.read()
    body = b""
    body += f"--{boundary}\r\n".encode()
    body += b'Content-Disposition: form-data; name="image"; filename="in.png"\r\n'
    body += b"Content-Type: image/png\r\n\r\n" + data + b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    req = urllib.request.Request(f"{COMFY_URL}/upload/image", data=body,
                                 headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
                                 method="POST")
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read().decode()).get("name")

def submit(wf):
    req = urllib.request.Request(f"{COMFY_URL}/prompt", data=json.dumps({"prompt": wf}).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read().decode()).get("prompt_id")
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        print(f"[handler] ComfyUI prompt HTTP {e.code}: {body[:2000]}", flush=True)
        raise RuntimeError(f"ComfyUI {e.code}: {body[:2000]}")

def wait(pid, timeout=600):
    start = time.time()
    while time.time() - start < timeout:
        try:
            req = urllib.request.Request(f"{COMFY_URL}/history/{pid}")
            with urllib.request.urlopen(req, timeout=30) as r:
                hist = json.loads(r.read().decode())
            if pid in hist and hist[pid].get("outputs"):
                files = []
                for node, out in hist[pid]["outputs"].items():
                    for img in out.get("images", []):
                        files.append(img["filename"])
                return files
        except Exception:
            pass
        time.sleep(3)
    return []

def download(fname):
    req = urllib.request.Request(f"{COMFY_URL}/view?filename={fname}&subfolder=&type=output")
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()

MODEL_REALVISXL = "realvisxl_v40.safetensors"
MODEL_CREALISM = "crealism_v2.safetensors"

def wf_single(prompt_info, input_name, seed, denoise):
    ckpt = prompt_info.get("settings", {}).get("model", MODEL_CREALISM)
    return {
        "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": ckpt}},
        "5c": {"class_type": "LoadImage", "inputs": {"image": input_name}},
        "5d": {"class_type": "VAEEncode", "inputs": {"pixels": ["5c", 0], "vae": ["4", 2]}},
        "7": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt_info["positive"], "clip": ["4", 1]}},
        "8": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt_info["negative"], "clip": ["4", 1]}},
        "10": {"class_type": "KSampler", "inputs": {"seed": seed, "steps": prompt_info["settings"].get("steps", 28), "cfg": prompt_info["settings"].get("cfg", 6.0), "sampler_name": "dpmpp_2m", "scheduler": "normal", "denoise": denoise, "model": ["4", 0], "positive": ["7", 0], "negative": ["8", 0], "latent_image": ["5d", 0]}},
        "11": {"class_type": "VAEDecode", "inputs": {"samples": ["10", 0], "vae": ["4", 2]}},
        "12": {"class_type": "SaveImage", "inputs": {"filename_prefix": "out", "images": ["11", 0]}},
    }

def wf_3stage(prompt_info, input_name, seed):
    pos, neg = prompt_info["positive"], prompt_info["negative"]
    steps = prompt_info["settings"].get("steps", 28)
    return {
        "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": MODEL_REALVISXL}},
        "2": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": MODEL_CREALISM}},
        "3": {"class_type": "IPAdapterUnifiedLoaderFaceID", "inputs": {"model": ["1", 0], "preset": "FACEID PLUS V2", "lora_strength": 1.0, "provider": "CUDA"}},
        "5": {"class_type": "LoadImage", "inputs": {"image": input_name}},
        "6": {"class_type": "CLIPVisionLoader", "inputs": {"clip_name": "CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors"}},
        "7": {"class_type": "CLIPTextEncode", "inputs": {"text": pos, "clip": ["1", 1]}},
        "8": {"class_type": "CLIPTextEncode", "inputs": {"text": neg, "clip": ["1", 1]}},
        "9": {"class_type": "IPAdapterFaceID", "inputs": {"model": ["3", 0], "ipadapter": ["3", 1], "image": ["5", 0], "clip_vision": ["6", 0], "weight": 0.85, "weight_faceidv2": 0.85, "weight_type": "linear", "combine_embeds": "concat", "start_at": 0.0, "end_at": 0.85, "embeds_scaling": "V only"}},
        "5c": {"class_type": "LoadImage", "inputs": {"image": input_name}},
        "5d": {"class_type": "VAEEncode", "inputs": {"pixels": ["5c", 0], "vae": ["1", 2]}},
        "10a": {"class_type": "KSampler", "inputs": {"seed": seed, "steps": 30, "cfg": 6.0, "sampler_name": "dpmpp_2m", "scheduler": "normal", "denoise": 0.6, "model": ["9", 0], "positive": ["7", 0], "negative": ["8", 0], "latent_image": ["5d", 0]}},
        "11a": {"class_type": "VAEDecode", "inputs": {"samples": ["10a", 0], "vae": ["1", 2]}},
        "7b": {"class_type": "CLIPTextEncode", "inputs": {"text": pos, "clip": ["2", 1]}},
        "8b": {"class_type": "CLIPTextEncode", "inputs": {"text": neg, "clip": ["2", 1]}},
        "5e": {"class_type": "VAEEncode", "inputs": {"pixels": ["11a", 0], "vae": ["2", 2]}},
        "10b": {"class_type": "KSampler", "inputs": {"seed": seed + 1, "steps": steps, "cfg": 8.0, "sampler_name": "dpmpp_2m", "scheduler": "normal", "denoise": 0.88, "model": ["2", 0], "positive": ["7b", 0], "negative": ["8b", 0], "latent_image": ["5e", 0]}},
        "11b": {"class_type": "VAEDecode", "inputs": {"samples": ["10b", 0], "vae": ["2", 2]}},
        "13": {"class_type": "ReActorFaceSwap", "inputs": {"enabled": True, "input_image": ["11b", 0], "source_image": ["5", 0], "swap_model": "inswapper_128.onnx", "facedetection": "retinaface_resnet50", "face_restore_model": "GFPGANv1.4.pth", "visibility": 1.0, "console_log_level": 1, "input_faces_index": "0", "source_faces_index": "0", "detect_gender_input": "no", "detect_gender_source": "no", "codeformer_weight": 0.5, "face_restore_visibility": 1.0}},
        "14": {"class_type": "SaveImage", "inputs": {"filename_prefix": "out", "images": ["13", 0]}},
    }

def wf_inpaint(prompt_info, input_name, mask_name, seed):
    ckpt = prompt_info.get("settings", {}).get("model", MODEL_CREALISM)
    return {
        "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": ckpt}},
        "5c": {"class_type": "LoadImage", "inputs": {"image": input_name}},
        "5m": {"class_type": "LoadImage", "inputs": {"image": mask_name}},
        "5d": {"class_type": "VAEEncode", "inputs": {"pixels": ["5c", 0], "vae": ["4", 2]}},
        "5e": {"class_type": "SetLatentNoiseMask", "inputs": {"samples": ["5d", 0], "mask": ["5m", 0]}},
        "7": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt_info["positive"], "clip": ["4", 1]}},
        "8": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt_info["negative"], "clip": ["4", 1]}},
        "10": {"class_type": "KSampler", "inputs": {"seed": seed, "steps": prompt_info["settings"].get("steps", 28), "cfg": prompt_info["settings"].get("cfg", 6.0), "sampler_name": "dpmpp_2m", "scheduler": "normal", "denoise": 1.0, "model": ["4", 0], "positive": ["7", 0], "negative": ["8", 0], "latent_image": ["5e", 0]}},
        "11": {"class_type": "VAEDecode", "inputs": {"samples": ["10", 0], "vae": ["4", 2]}},
        "12": {"class_type": "SaveImage", "inputs": {"filename_prefix": "out", "images": ["11", 0]}},
    }

def wf_openpose(prompt_info, input_name, pose_name, seed):
    pos, neg = prompt_info["positive"], prompt_info["negative"]
    ckpt = prompt_info.get("settings", {}).get("model", MODEL_REALVISXL)
    return {
        "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": ckpt}},
        "3": {"class_type": "IPAdapterUnifiedLoaderFaceID", "inputs": {"model": ["1", 0], "preset": "FACEID PLUS V2", "lora_strength": 1.0, "provider": "CUDA"}},
        "5": {"class_type": "LoadImage", "inputs": {"image": input_name}},
        "6": {"class_type": "CLIPVisionLoader", "inputs": {"clip_name": "CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors"}},
        "7": {"class_type": "CLIPTextEncode", "inputs": {"text": pos, "clip": ["1", 1]}},
        "8": {"class_type": "CLIPTextEncode", "inputs": {"text": neg, "clip": ["1", 1]}},
        "9": {"class_type": "IPAdapterFaceID", "inputs": {"model": ["3", 0], "ipadapter": ["3", 1], "image": ["5", 0], "clip_vision": ["6", 0], "weight": 0.85, "weight_faceidv2": 0.85, "weight_type": "linear", "combine_embeds": "concat", "start_at": 0.0, "end_at": 0.85, "embeds_scaling": "V only"}},
        "5p": {"class_type": "LoadImage", "inputs": {"image": pose_name}},
        "cn": {"class_type": "ControlNetLoader", "inputs": {"control_net_name": "control_v11p_sd15_openpose.pth"}},
        "cnp": {"class_type": "ControlNetApplyAdvanced", "inputs": {"positive": ["7", 0], "negative": ["8", 0], "control_net": ["cn", 0], "image": ["5p", 0], "strength": 0.9, "start_percent": 0.0, "end_percent": 1.0}},
        "5c": {"class_type": "LoadImage", "inputs": {"image": input_name}},
        "5d": {"class_type": "VAEEncode", "inputs": {"pixels": ["5c", 0], "vae": ["1", 2]}},
        "10": {"class_type": "KSampler", "inputs": {"seed": seed, "steps": 30, "cfg": 6.0, "sampler_name": "dpmpp_2m", "scheduler": "normal", "denoise": 0.75, "model": ["9", 0], "positive": ["cnp", 0], "negative": ["cnp", 1], "latent_image": ["5d", 0]}},
        "11": {"class_type": "VAEDecode", "inputs": {"samples": ["10", 0], "vae": ["1", 2]}},
        "12": {"class_type": "SaveImage", "inputs": {"filename_prefix": "out", "images": ["11", 0]}},
    }

def handler(job):
    inp = job.get("input", {})
    image_b64 = inp.get("image_b64", "")
    prompt_info = inp.get("prompt", {})
    mode = inp.get("mode", "img2img")
    if not image_b64:
        return {"error": "image_b64 required"}
    tmp = "/tmp/in.png"
    with open(tmp, "wb") as f:
        f.write(base64.b64decode(image_b64))
    input_name = upload(tmp)
    seed = int(time.time()) % 100000

    if mode == "inpaint" and inp.get("mask_b64"):
        mtmp = "/tmp/mask.png"
        with open(mtmp, "wb") as f:
            f.write(base64.b64decode(inp["mask_b64"]))
        mask_name = upload(mtmp)
        wf = wf_inpaint(prompt_info, input_name, mask_name, seed)
    elif mode == "openpose" and inp.get("pose_b64"):
        ptmp = "/tmp/pose.png"
        with open(ptmp, "wb") as f:
            f.write(base64.b64decode(inp["pose_b64"]))
        pose_name = upload(ptmp)
        wf = wf_openpose(prompt_info, input_name, pose_name, seed)
    elif mode == "faceid":
        wf = wf_3stage(prompt_info, input_name, seed)
    else:
        denoise = inp.get("denoise", 0.88 if prompt_info.get("level", 4) >= 4 else 0.6)
        wf = wf_single(prompt_info, input_name, seed, denoise)

    pid = submit(wf)
    files = wait(pid)
    if not files:
        # ComfyUI 로그 마지막 부분에서 원인 캡처
        reason = ""
        try:
            with open("/tmp/comfy.log", "r", errors="replace") as cf:
                clines = cf.read().split("\n")
            reason = "\n".join([l for l in clines[-30:] if l.strip()])
        except Exception:
            pass
        return {"error": "no output", "prompt_id": pid, "comfy_tail": reason[-2000:]}
    img_bytes = download(files[0])
    return {
        "image_b64": base64.b64encode(img_bytes).decode(),
        "image_bytes": len(img_bytes),
        "filename": files[0],
        "mode": mode,
    }

# ── RunPod Serverless 엔트리포인트 ─────────────────────────
import runpod

# ComfyUI가 뜰 때까지 대기 (startup.sh가 이미 대기하지만 보험)
import time as _t
def _wait_comfy(timeout=300):
    st = _t.time()
    while _t.time() - st < timeout:
        try:
            import urllib.request as _u
            with _u.urlopen(f"{COMFY_URL}/system_stats", timeout=5) as r:
                if r.status == 200:
                    print("[handler] ComfyUI ready", flush=True)
                    return
        except Exception:
            pass
        _t.sleep(5)

_wait_comfy()
runpod.serverless.start({"handler": handler})
