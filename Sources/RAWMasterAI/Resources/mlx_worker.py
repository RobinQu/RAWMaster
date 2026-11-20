"""Offline serial MLX worker; model paths are explicit and outputs confined to the owned run root."""
import argparse
import contextlib
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import sys
import threading
import time
import traceback

PROTOCOL = sys.stdout
ROOT = Path(os.environ['RAWMASTER_MODEL_ROOT']).resolve()
RUN = Path(os.environ['RAWMASTER_RUN_ROOT']).resolve()
os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1', HF_HOME=str(RUN/'hf-cache'))

import mlx.core as mx
from PIL import Image, ImageOps
from mflux.models.common.config import ModelConfig
from mflux.models.qwen21.variants.edit.qwen_image_21_edit import QwenImage21Edit
from mflux.models.qwen21.latent_creator.qwen_image21_latent_creator import QwenImage21LatentCreator
from mflux.models.qwen21.model.qwen21_vae.vae import QwenImage21VAE
from mflux.models.qwen21.weights.qwen_image21_weight_definition import QwenImage21WeightDefinition
from mflux.utils.image_util import ImageUtil


def emit(value):
    print(json.dumps(value), file=PROTOCOL, flush=True)


class Capture:
    def call_in_loop(self, t, **kwargs):
        emit({'event': 'progress', 'step': t+1, 'total': 8})

    def call_after_loop(self, latents, config, **kwargs):
        self.latent = QwenImage21LatentCreator.unpack_latents(latents, config.height, config.width).astype(mx.float32)
        self.sigmas = config.scheduler.sigmas.tolist()


class Worker:
    def __init__(self):
        self.model = None
        self.fixed = None
        self.capture = Capture()
        self.identity = None
        mx.set_cache_limit(2 * 1024**3)

    def load(self):
        if self.model is None:
            identity_path = Path(__file__).resolve().with_name('model-identity.json')
            self.identity = json.loads(identity_path.read_text())
            for item in self.identity['files']:
                path = (ROOT/item['path']).resolve()
                if not path.is_relative_to(ROOT) or not path.is_file() or path.stat().st_size != item['size']:
                    raise ValueError('Pinned model file missing or wrong size')
                with path.open('rb') as handle:
                    digest = hashlib.file_digest(handle, 'sha256').hexdigest()
                if digest != item['sha256']:
                    raise ValueError('Pinned model hash mismatch')
            self.identity_hash = hashlib.sha256(identity_path.read_bytes()).hexdigest()
            self.model = QwenImage21Edit(quantize=4, model_path=str(ROOT/'qwen21-turbo'), model_config=ModelConfig.qwen_image_21_turbo())
            self.model.callbacks.register(self.capture)
            mx.eval(self.model.parameters())

    def run(self, request):
        directory = Path(request['directory']).resolve()
        source_path = Path(request['input']).resolve()
        if not directory.is_relative_to(RUN/'jobs') or not source_path.is_relative_to(directory):
            raise ValueError('Input/output escapes owned job directory')
        if request['decoder'] not in ('stock', 'texture_fix'):
            raise ValueError('Unsupported decoder')
        started = time.monotonic()
        self.load()
        with Image.open(source_path) as opened:
            source = opened.convert('RGBA')
        resolution = int(request['resolution'])
        if not 512 <= resolution <= 2048 or resolution % 32:
            raise ValueError('Unsupported resolution')
        width, height = QwenImage21LatentCreator.dimensions(resolution, source.width/source.height)
        normalized = directory/'normalized.png'
        ImageOps.fit(source, (width, height), method=Image.Resampling.LANCZOS).save(normalized)
        generated = self.model.generate_image(seed=int(request['seed']), prompt=request['prompt'], num_inference_steps=8,
            width=width, height=height, image_paths=[str(normalized)], output_resolution=resolution, guidance=1.0, use_kv_cache=True)
        output = directory/'native.png'
        if request['decoder'] == 'texture_fix':
            if self.fixed is None:
                item = self.identity['textureFix']
                path = (ROOT/item['path']).resolve()
                if not path.is_relative_to(ROOT) or not path.is_file() or path.stat().st_size != item['size']:
                    raise ValueError('Texture-fix weights missing')
                with path.open('rb') as handle:
                    if hashlib.file_digest(handle, 'sha256').hexdigest() != item['sha256']:
                        raise ValueError('Texture-fix hash mismatch')
                config = json.loads((ROOT/'qwen21-turbo/vae/config.json').read_text())
                self.fixed = QwenImage21VAE(config)
                weights = mx.load(str(ROOT/'qwen21-texture-fix/diffusion_pytorch_model.safetensors'))
                self.fixed.load_weights([(k, QwenImage21WeightDefinition.vae_weight(k, v).astype(mx.float32)) for k,v in weights.items()])
                mx.eval(self.fixed.parameters())
            ImageUtil.to_pil(self.fixed.decode(self.capture.latent)).save(output)
        else:
            generated.save(str(output))
        mx.synchronize()
        with Image.open(output) as image:
            image.load()
            size, mode = image.size, image.mode
        return {'output': str(output), 'size': size, 'mode': mode, 'model': 'Qwen-Image-2.1-Turbo', 'quantization': 4,
            'steps': 8, 'guidance': 1, 'kvCache': True, 'decoder': request['decoder'],
            'inputSize': source.size, 'normalizedSize': [width, height], 'resampling': 'ImageOps.fit-Lanczos',
            'outputSHA256': hashlib.sha256(output.read_bytes()).hexdigest(), 'elapsedSeconds': time.monotonic()-started,
            'workerPID': os.getpid(), 'referenceInputSHA256': hashlib.sha256(source_path.read_bytes()).hexdigest(),
            'normalizedInputSHA256': hashlib.sha256(normalized.read_bytes()).hexdigest(), 'sigmaSchedule': self.capture.sigmas,
            'textEncoderSHA256': next(i['sha256'] for i in self.identity['files'] if i['path'].endswith('text_encoder/model.safetensors')),
            'transformerWeightSHA256': {i['path']: i['sha256'] for i in self.identity['files'] if '/transformer/' in i['path'] and i['path'].endswith('.safetensors')},
            'runtimeID': os.environ.get('RAWMASTER_RUNTIME_ID', 'unknown'), 'mfluxVersion': importlib.metadata.version('mflux'),
            'workerSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'nodeSHA256': os.environ.get('RAWMASTER_NODE_SHA256', 'unknown'),
            'modelRevision': self.identity['revision'], 'modelIdentitySHA256': self.identity_hash,
            'decoderWeightsSHA256': self.identity['textureFix']['sha256'] if request['decoder'] == 'texture_fix' else next(i['sha256'] for i in self.identity['files'] if i['path'].endswith('vae/diffusion_pytorch_model.safetensors'))}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--parent-pid', type=int, required=True)
    args = parser.parse_args()
    def parent_watch():
        while True:
            if os.getppid() != args.parent_pid:
                os._exit(0)
            time.sleep(.5)
    threading.Thread(target=parent_watch, daemon=True).start()
    worker = Worker()
    for line in sys.stdin:
        try:
            with contextlib.redirect_stdout(sys.stderr):
                result = worker.run(json.loads(line))
                receipt = Path(result['output']).with_name('worker-result.json')
                receipt.write_text(json.dumps(result, indent=2))
            emit({'event': 'result', 'result': result})
        except Exception as error:
            traceback.print_exc(file=sys.stderr)
            emit({'event': 'error', 'error': type(error).__name__})


if __name__ == '__main__':
    main()
