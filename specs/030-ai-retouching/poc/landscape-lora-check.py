"""Run a paired SDXL img2img test from local weights. Output is research material."""
import argparse
import hashlib
import json
from pathlib import Path
import time

import numpy as np
from PIL import Image
import torch
from diffusers import StableDiffusionXLImg2ImgPipeline

CASES = {
    "zone": (835690, "anseladams, black and white fine art landscape photograph, mountain lake, layered rock, "
             "deep shadow detail, luminous snow and clouds, small wooden boats on still water; "
             "preserve the original peaks, boats, shoreline, trees and viewpoint"),
    "neon": (153894, "Liam Wong Style page, photograph of the same Shinjuku rainy night intersection, "
             "deep blue dusk shadows, restrained magenta and cyan light reflecting on the wet street, "
             "preserve every sign and character, all people, road markings, walls, railway bridge and framing"),
}
EXPECTED_ADAPTER = {835690: "d048b91c3acdd2656671555ae4427e1adafe9520b54d4979aa613702534e92f7",
                    153894: "f8876690194e1cd791568a279f8f23d769910942bd77730265de493fc36a12fe"}

def digest(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def main(args):
    version, prompt = CASES[args.case]
    actual_hash = digest(args.adapter)
    if actual_hash != EXPECTED_ADAPTER[version]:
        raise ValueError(f"Unexpected adapter for Civitai version {version}")
    if not 0.05 <= args.img2img_strength <= 1:
        raise ValueError("With 20 scheduled steps strength must be between 0.05 and 1")
    device = "mps"
    pipe = StableDiffusionXLImg2ImgPipeline.from_pretrained(
        args.base, variant="fp16", use_safetensors=True, torch_dtype=torch.float16,
        local_files_only=True, add_watermarker=False,
    ).to(device)
    image = Image.open(args.input).convert("RGB")
    args.output.mkdir(parents=True, exist_ok=True)
    report = {"base": "stabilityai/stable-diffusion-xl-base-1.0",
              "baseRevision": "462165984030d82259a11f4367a4eed129e94a7b",
              "loraVersion": version, "adapterSHA256": actual_hash, "sourceSHA256": digest(args.input),
              "scheduler": type(pipe.scheduler).__name__, "prompt": prompt, "negativePrompt": "",
              "seed": 31903, "inferenceSteps": 20, "img2imgStrength": args.img2img_strength, "guidance": 5.0, "size": list(image.size),
              "runs": {}}
    for label, weight in [("base", 0.0), ("with-lora", 0.7)]:
        if weight:
            pipe.load_lora_weights(str(args.adapter.parent), weight_name=args.adapter.name,
                                   adapter_name=args.case, local_files_only=True)
            pipe.set_adapters([args.case], adapter_weights=[weight])
        start = time.monotonic()
        with torch.inference_mode():
            result = pipe(prompt=prompt, negative_prompt="", image=image, generator=torch.Generator("cpu").manual_seed(31903),
                          num_inference_steps=20, strength=args.img2img_strength, guidance_scale=5.0).images[0]
        torch.mps.synchronize()
        seconds = round(time.monotonic() - start, 3)
        path = args.output / (label + ".png")
        result.save(path)
        arr = np.asarray(result, dtype=float)
        if arr.max() - arr.min() < 5:
            raise RuntimeError("Degenerate output")
        report["runs"][label] = {"adapterWeight": weight, "pipelineSeconds": seconds, "outputSHA256": digest(path),
                                 "meanMaxMinusMinRGB8": round(float(np.ptp(arr, axis=2).mean()), 3)}
        (args.output / "runs.json").write_text(json.dumps(report, indent=2) + "\n")
        print(label, seconds, flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=CASES, default="zone")
    parser.add_argument("--img2img-strength", type=float, default=0.5)
    for flag in ("base", "adapter", "input", "output"):
        parser.add_argument("--" + flag, type=Path, required=True)
    main(parser.parse_args())
