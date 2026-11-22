"""Export the authors' EfficientViT-B2 ADE20K checkpoint for MaskAI on CPU."""

import argparse
import hashlib
from pathlib import Path
import sys
import types

import onnx
import torch


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("upstream", type=Path, help="EfficientViT checkout at 5c423e51ba97")
    parser.add_argument("checkpoint", type=Path)
    parser.add_argument("model_root", type=Path)
    args = parser.parse_args()
    digest = hashlib.sha256(args.checkpoint.read_bytes()).hexdigest()
    if digest != "fabfa7163e35d14888690969cd852069f399137be39697bfe5165f03ea76b510":
        raise ValueError("Unexpected upstream checkpoint digest")
    sys.path.insert(0, str(args.upstream.resolve()))
    # Its package __init__ also imports training-only drop/scheduler utilities.
    # The segmentation factory never calls them in eval mode on macOS.
    sys.modules["efficientvit.models.nn.drop"] = types.ModuleType("efficientvit.models.nn.drop")
    from efficientvit.seg_model_zoo import create_seg_model

    torch.set_num_threads(2)
    model = create_seg_model("b2", "ade20k", weight_url=str(args.checkpoint)).eval()
    output = args.model_root / "efficientvit-seg-b2-ade20k" / "model.onnx"
    output.parent.mkdir(parents=True, exist_ok=True)
    with torch.inference_mode():
        torch.onnx.export(
            model, (torch.zeros(1, 3, 512, 768),), str(output),
            input_names=["image"], output_names=["logits"],
            dynamic_axes={"image": {2: "height", 3: "width"}, "logits": {2: "out_height", 3: "out_width"}},
            opset_version=17, dynamo=False, external_data=False,
        )
    onnx.checker.check_model(str(output))
