"""Run the three fixed offline Q8 cases in order with the pinned MLX environment."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import time


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(model_dir, inputs, out):
    from flux_klein_mlx.__main__ import main as cli

    definitions_path = Path(__file__).resolve().parents[1] / 'poc' / 'cases.json'
    definitions = json.loads(definitions_path.read_text())
    width, height = definitions['size']
    jobs = [('lake', 'lake', 8521), ('portrait', 'portrait', 8521), ('lake-repeat', 'lake', 8522)]
    records = []
    out.mkdir(parents=True, exist_ok=True)
    os.environ['FLUX_MLX_CACHE_DIR'] = str(out / '.verification-cache')
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['TRANSFORMERS_OFFLINE'] = '1'
    for run_id, case_id, seed in jobs:
        case = definitions['cases'][case_id]
        source = inputs / case['input']
        image = out / f'{run_id}.png'
        sys.argv = ['flux-klein', '--model-dir', str(model_dir), '--preset', 'q8-16',
                    '--width', str(width), '--height', str(height), '--prompt', case['prompt'],
                    '--image', str(source), '--seed', str(seed), '--out', str(image)]
        started = time.perf_counter()
        cli()
        cli_seconds = time.perf_counter() - started
        metrics = json.loads(image.with_suffix('.metrics.json').read_text())
        records.append({
            'run': run_id, 'seed': seed, 'input_sha256': sha256(source),
            'caption_sha256': hashlib.sha256(case['prompt'].encode()).hexdigest(),
            'output_file_sha256': sha256(image), 'width': width, 'height': height,
            'cli_seconds': cli_seconds, 'pipeline_seconds': metrics['wall_seconds'],
            'verification_seconds': metrics['verification_seconds'],
            'denoise_seconds': metrics['denoise']['compute_seconds'],
            'peak_mlx_active_bytes': metrics['peak_mlx_active_bytes'],
            'peak_process_footprint_bytes': metrics['peak_physical_footprint_bytes'],
            'stage_step_seconds': metrics['denoise']['step_seconds']})
        (out / 'timings.json').write_text(json.dumps(records, indent=2) + '\n')
        print(f'{run_id} finished in {cli_seconds:.2f}s incl. CLI and checksums', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-dir', type=Path, required=True)
    parser.add_argument('--inputs', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    run(args.model_dir.resolve(), args.inputs.resolve(), args.out.resolve())
