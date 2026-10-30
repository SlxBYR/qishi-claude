#!/usr/bin/env python3
"""Describe the two fixed edge drawings and their restrained procedural rigs.

No pixels are generated or edited. Every presented frame deforms the same source
for its side, so independent drawings cannot change the face, scale or outline.
"""
import argparse
import hashlib
import json
from pathlib import Path
from PIL import Image

RIGS = {
    'left': {'armPivot': [.32, .54], 'armCenter': [.24, .435], 'faceCenter': [.48, .40]},
    'right': {'armPivot': [.63, .54], 'armCenter': [.72, .435], 'faceCenter': [.44, .41]},
}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resources', type=Path, default=Path(__file__).resolve().parents[1] / 'Resources')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--qa-output', type=Path)
    args = parser.parse_args()
    resources = args.resources.resolve()
    images, hashes = {}, {}
    for side, rig in RIGS.items():
        source = resources / 'Claude' / 'edge-hover' / f'{side}-11.png'
        with Image.open(source) as image:
            width, height = image.size
        images[f'{side}-11'] = {'url': f'../Claude/edge-hover/{side}-11.png',
            'width': width, 'height': height, 'scale': 1, 'offsetX': 0, 'offsetY': 0, 'rig': rig}
        hashes[str(source.relative_to(resources))] = hashlib.sha256(source.read_bytes()).hexdigest()
    data = {'version': 2, 'mode': 'single-source-rig', 'images': images, 'pairs': {},
            'gesture': {'periodSeconds': 10, 'quietSeconds': 6, 'durationSeconds': 2.4}}
    destination = args.output or resources / 'CrossPet' / 'motion-data.js'
    destination.write_text('// Fixed original drawings; each side retains one texture for the entire motion.\nwindow.qishiMotionData=' + json.dumps(data, separators=(',', ':')) + ';\n')
    qa = {'mode': data['mode'], 'imageCount': 2, 'pairCount': 0, 'originalImagesUnchanged': True,
          'sourceSHA256': hashes, 'gesture': data['gesture'],
          'continuity': 'Position and velocity persist between presentation frames; the source artwork never switches.'}
    (args.qa_output or resources / 'Claude' / 'motion-qa.json').write_text(json.dumps(qa, ensure_ascii=False, indent=2)+'\n')
    print('Prepared two fixed edge drawings; no redraws, optical-flow pairs or drag animation.')

if __name__ == '__main__':
    main()
