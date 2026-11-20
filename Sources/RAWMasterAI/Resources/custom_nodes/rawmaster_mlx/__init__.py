"""RAWMaster owned Comfy→MLX adapter. No model download and no lab dependencies."""
import atexit
import asyncio
import hmac
import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import threading
import time
import uuid

import numpy as np
import torch
from PIL import Image
from aiohttp import web
import comfy.model_management
import comfy.utils
from server import PromptServer

RUN = Path(os.environ['RAWMASTER_RUN_ROOT']).resolve()
MODEL = Path(os.environ['RAWMASTER_MODEL_ROOT']).resolve()
TOKEN = os.environ['RAWMASTER_OWNERSHIP_TOKEN']
WORKER_SCRIPT = Path(os.environ['RAWMASTER_WORKER_SCRIPT']).resolve()
# Preserve the virtualenv executable path; resolving its symlink bypasses its site-packages.
MLX_PYTHON = Path(os.environ['RAWMASTER_MLX_PYTHON']).absolute()


class MLXProcess:
    def __init__(self):
        self.process = None
        self.lock = threading.Lock()
        self.guard = threading.Lock()
        self.log = None

    def stop(self):
        # Called only under request lock, or while terminating the owning Comfy process.
        with self.guard:
            process = self.process
            if process is not None:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                process.stdin.close()
                process.stdout.close()
            self.process = None
            if self.log:
                self.log.close()
                self.log = None

    def unload(self):
        with self.lock:
            self.stop()
        return True

    def request(self, request):
        with self.lock:
            try:
                if self.process is None or self.process.poll() is not None:
                    self.stop()
                    RUN.mkdir(parents=True, exist_ok=True)
                    self.log = (RUN/'worker.log').open('a')
                    self.process = subprocess.Popen([str(MLX_PYTHON), str(WORKER_SCRIPT), '--parent-pid', str(os.getpid())],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log, text=True, bufsize=1,
                        cwd=RUN, env=os.environ | {'PYTHONUNBUFFERED': '1', 'RAWMASTER_NODE_SHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()})
                self.process.stdin.write(json.dumps(request)+'\n')
                self.process.stdin.flush()
                progress = comfy.utils.ProgressBar(8)
                deadline = time.monotonic()+1200
                with selectors.DefaultSelector() as selector:
                    selector.register(self.process.stdout, selectors.EVENT_READ)
                    while time.monotonic() < deadline:
                        comfy.model_management.throw_exception_if_processing_interrupted()
                        if selector.select(.1):
                            line = self.process.stdout.readline()
                            if not line:
                                raise RuntimeError('Owned MLX worker exited')
                            event = json.loads(line)
                            if event['event'] == 'result':
                                return event['result']
                            if event['event'] == 'error':
                                raise RuntimeError('MLX inference failed: '+event['error'])
                            progress.update_absolute(event['step'], event['total'])
                        if self.process.poll() is not None:
                            raise RuntimeError('Owned MLX worker exited')
                raise TimeoutError('MLX inference exceeded 1200 seconds')
            except BaseException:
                self.stop()
                raise


WORKER = MLXProcess()
atexit.register(WORKER.stop)


def owner_watch():
    owner = int(os.environ.get('RAWMASTER_OWNER_PID', '0'))
    if owner:
        while True:
            if os.getppid() != owner:
                WORKER.stop()
                os._exit(0)
            time.sleep(.5)


threading.Thread(target=owner_watch, daemon=True).start()


@web.middleware
async def ownership(request, handler):
    if not hmac.compare_digest(request.headers.get('X-RAWMaster-Token', ''), TOKEN):
        return web.json_response({'error': 'owned_runtime_authorization_required'}, status=403)
    if request.path == '/free' and request.method == 'POST':
        await asyncio.to_thread(WORKER.unload)
    return await handler(request)


PromptServer.instance.app.middlewares.append(ownership)


@PromptServer.instance.routes.get('/rawmaster/health')
async def health(request):
    return web.json_response({'protocol': 'rawmaster-comfy-mlx-v1', 'pid': os.getpid(),
        'executable': str(Path(sys.executable).resolve()), 'runRoot': str(RUN), 'modelRoot': str(MODEL),
        'workerPID': WORKER.process.pid if WORKER.process and WORKER.process.poll() is None else None,
        'modelPresent': (MODEL/'qwen21-turbo/model_index.json').is_file()})


@PromptServer.instance.routes.post('/rawmaster/shutdown')
async def shutdown(request):
    PromptServer.instance.prompt_queue.wipe_queue()
    comfy.model_management.interrupt_current_processing()
    await asyncio.to_thread(WORKER.unload)
    asyncio.get_running_loop().call_later(.25, lambda: os._exit(0))
    return web.json_response({'workerJoined': True})


@PromptServer.instance.routes.post('/rawmaster/unload')
async def unload(request):
    PromptServer.instance.prompt_queue.wipe_queue()
    comfy.model_management.interrupt_current_processing()
    await asyncio.to_thread(WORKER.unload)
    return web.json_response({'workerJoined': True})


class RAWMasterMLXEdit:
    @classmethod
    def INPUT_TYPES(cls):
        return {'required': {'image': ('IMAGE',), 'prompt': ('STRING', {'multiline': True}),
            'seed': ('INT', {'default': 20261030, 'min': 0, 'max': 2**32-1}),
            'resolution': ('INT', {'default': 1024, 'min': 512, 'max': 2048, 'step': 32}),
            'decoder': (['stock', 'texture_fix'],), 'run_id': ('STRING',)}}
    RETURN_TYPES = ('IMAGE', 'STRING')
    RETURN_NAMES = ('rgba_image', 'receipt')
    FUNCTION = 'edit'
    CATEGORY = 'RAWMaster/Internal'

    def edit(self, image, prompt, seed, resolution, decoder, run_id):
        if image.shape[0] != 1:
            raise ValueError('Only one reference image is supported')
        if not run_id or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-' for c in run_id):
            raise ValueError('Invalid owned attempt identity')
        directory = RUN/'jobs'/run_id
        directory.mkdir(parents=True)
        source = directory/'input.png'
        pixels = np.clip(image[0].cpu().numpy() * 255, 0, 255).round().astype(np.uint8)
        Image.fromarray(pixels).save(source)
        receipt = WORKER.request({'input': str(source), 'prompt': prompt, 'seed': seed,
            'resolution': resolution, 'decoder': decoder, 'directory': str(directory)})
        with Image.open(receipt['output']) as output:
            array = np.asarray(output.convert('RGBA')).copy().astype(np.float32)/255
        return {'ui': {'text': [json.dumps(receipt)]}, 'result': (torch.from_numpy(array)[None], json.dumps(receipt))}


NODE_CLASS_MAPPINGS = {'RAWMasterMLXEdit': RAWMasterMLXEdit}
