#!/usr/bin/env python3
"""Writes app/assets/basic_pitch/: Spotify's Basic Pitch model (the ICASSP 2022 one, Apache 2.0) as
the plain tensors BasicPitch (packages/score_engine/lib/src/basic_pitch.dart) runs, and its licence.

The tensors are read from the ONNX export the basic-pitch release ships (nmp.onnx, its batch
norms already folded into the convolutions), so the network is the one published, weight for weight.
Run from the repository root:
  python3 -m venv /tmp/onnx && /tmp/onnx/bin/pip install onnx
  /tmp/onnx/bin/python Tools/make_basic_pitch_weights.py

nmp.bin: 'BPW1', the number of tensors (uint32), then each: its name's length (uint8) and name,
its rank (uint8) and sizes (uint32 each), its values (float32); all little-endian.
"""
import hashlib
import io
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

import numpy as np
import onnx
from onnx import numpy_helper

VERSION = '0.4.0'
WHEEL = f'basic_pitch-{VERSION}-py2.py3-none-any.whl'
SHA256 = '738adb503aae7fdfc7d1e1511aa0ce35052315f260a19531ef4c356708425db0'
OUT = Path('app/assets/basic_pitch')


def wheel() -> bytes:
    with tempfile.TemporaryDirectory() as folder:
        subprocess.run([sys.executable, '-m', 'pip', 'download', f'basic-pitch=={VERSION}', '--no-deps', '-q', '-d', folder], check=True)
        data = (Path(folder) / WHEEL).read_bytes()
    if hashlib.sha256(data).hexdigest() != SHA256:
        sys.exit(f'{WHEEL}: not the release expected (SHA-256 differs)')
    return data


def tensors(model: onnx.ModelProto) -> list[tuple[str, np.ndarray]]:
    """The model's constants in the order BasicPitch reads them, found by what uses them."""
    nodes = list(model.graph.node)
    values = {t.name: numpy_helper.to_array(t) for t in model.graph.initializer}

    def constant(node, shape):
        found = [values[x] for x in node.input if x in values and values[x].shape == shape]
        assert len(found) == 1, (node.name, shape)
        return found[0].astype(np.float32)

    cqt = [n for n in nodes if n.op_type == 'Conv' and 'cq_t' in n.output[0]]
    # Each octave's two convolutions: one negated after (the imaginary part), one not.
    negated = {n.input[0] for n in nodes if n.op_type == 'Neg'}
    real = {n.input[1] for n in cqt if values[n.input[1]].shape[0] == 36 and n.output[0] not in negated}
    imaginary = {n.input[1] for n in cqt if values[n.input[1]].shape[0] == 36 and n.output[0] in negated}
    low_pass = {n.input[1] for n in cqt if values[n.input[1]].shape[0] == 1}
    assert len(real) == len(imaginary) == len(low_pass) == 1, (real, imaginary, low_pass)
    scale = next(n for n in nodes if n.op_type == 'Mul' and any(x in values and values[x].shape == (309, 1, 1) for x in n.input))
    norm_mul = next(n for n in nodes if n.op_type == 'Mul' and 'batch_normalization' in n.output[0])
    norm_add = next(n for n in nodes if n.op_type == 'Add' and 'batch_normalization' in n.output[0])

    convs = {}
    for n in nodes:
        if n.op_type == 'Conv' and 'cq_t' not in n.output[0]:
            w = values[n.input[1]]
            convs[w.shape] = (w.astype(np.float32), values[n.input[2]].astype(np.float32))
    out = [
        ('cqt.real', values[real.pop()][:, 0, 0, :]),
        ('cqt.imaginary', values[imaginary.pop()][:, 0, 0, :]),
        ('cqt.lowPass', values[low_pass.pop()].reshape(256)),
        ('cqt.scale', constant(scale, (309, 1, 1)).reshape(309)),
        ('cqt.norm', np.array([constant(norm_mul, (1,))[0], constant(norm_add, (1,))[0]], np.float32)),
    ]
    for name, shape in [
        ('onset', (32, 8, 5, 5)),
        ('contour', (8, 8, 3, 39)),
        ('contour.out', (1, 8, 5, 5)),
        ('note', (32, 1, 7, 7)),
        ('note.out', (1, 32, 7, 3)),
        ('onset.out', (1, 33, 3, 3)),
    ]:
        w, b = convs.pop(shape)
        out += [(f'{name}.weight', w), (f'{name}.bias', b)]
    assert not convs, convs.keys()
    return out


def main():
    with zipfile.ZipFile(io.BytesIO(wheel())) as z:
        model = onnx.load_from_string(z.read('basic_pitch/saved_models/icassp_2022/nmp.onnx'))
        licence = z.read(f'basic_pitch-{VERSION}.dist-info/LICENSE').decode()
        notice = z.read(f'basic_pitch-{VERSION}.dist-info/NOTICE').decode()
    OUT.mkdir(parents=True, exist_ok=True)
    blob = bytearray(b'BPW1')
    found = tensors(model)
    blob += struct.pack('<I', len(found))
    for name, value in found:
        value = np.ascontiguousarray(value, dtype='<f4')
        blob += struct.pack('<B', len(name)) + name.encode()
        blob += struct.pack('<B', value.ndim) + struct.pack(f'<{value.ndim}I', *value.shape)
        blob += value.tobytes()
    (OUT / 'nmp.bin').write_bytes(bytes(blob))
    (OUT / 'LICENSE.txt').write_text(f'{notice.strip()}\n\n{licence.strip()}\n')
    print(f'{OUT}/nmp.bin: {len(found)} tensors, {sum(v.size for _, v in found)} values, {len(blob)} bytes')


if __name__ == '__main__':
    main()
