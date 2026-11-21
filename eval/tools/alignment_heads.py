#!/usr/bin/env python3
"""Find the decoder attention heads that follow the audio ("alignment heads").

Nabra places every decoded word in time by looking at a few cross-attention heads of the speech
model's decoder: the ones whose strongest frame moves steadily forward through the recording as
text is written. Which heads those are is a property of the model, so this has to be redone when
the model changes. The result goes into `TokenTiming.alignmentHeads` in
Nabra/Core/ASR/SpeechEngine.swift.

1. Dump the attention of every head for a varied set of clips, under both language hints:

       APP=build/Products/Release/Nabra.app/Contents/MacOS/Nabra
       for f in clips/*.wav; do
         for lang in en ar; do
           $APP --transcribe "$f" --model <model.gguf> --lang $lang \
                --attn-dump dumps/$(basename "$f" .wav)_$lang.bin >/dev/null
         done
       done

2. Rank the heads:

       python3 eval/tools/alignment_heads.py dumps/*.bin

A head is good when it is "active" (its peak is not parked on the first frames, where attention
rests when it follows nothing), moves forward from one token to the next, and agrees with the
other good heads. The script prints the ranking and the six best as a Swift array.

Dump format (little-endian), written by the engine patch when NABRA_ATTN_DUMP is set:
    int32 magic 0x4E415454, layers, heads, frames, tokens
    per token: int32 id, float32 log-probability, int32 text length, text bytes,
               float32 weights[layers][heads][frames]
"""
import struct
import sys

import numpy as np

MAGIC = 0x4E415454


def load(path):
    data = open(path, "rb").read()
    magic, layers, heads, frames, count = struct.unpack_from("<5i", data, 0)
    if magic != MAGIC:
        raise ValueError(f"{path}: not an attention dump")
    offset = 20
    weights = np.zeros((count, layers, heads, frames), dtype=np.float32)
    for index in range(count):
        _, _, length = struct.unpack_from("<ifi", data, offset)
        offset += 12 + length
        weights[index] = np.frombuffer(data, dtype="<f4", count=layers * heads * frames, offset=offset).reshape(
            layers, heads, frames
        )
        offset += 4 * layers * heads * frames
    return weights


def main(paths):
    peaks = []
    for path in paths:
        weights = load(path)
        if weights.shape[0] >= 4:
            peaks.append(weights[1:].argmax(axis=3))  # the first token has no weights of its own
    if not peaks:
        sys.exit("no usable dumps")
    layers, heads = peaks[0].shape[1:]

    active = np.mean([(p > 1).mean(axis=0) for p in peaks], axis=0)
    forward = np.mean([(np.diff(p, axis=0) >= -1).mean(axis=0) for p in peaks], axis=0)
    first_pass = np.argsort(-(active * forward).ravel())[:6]
    reference = [np.unravel_index(i, (layers, heads)) for i in first_pass]

    agreement = np.zeros((layers, heads))
    for p in peaks:
        consensus = np.median(np.stack([p[:, l, h] for l, h in reference], axis=1), axis=1)
        agreement += (np.abs(p - consensus[:, None, None]) <= 2).mean(axis=0)
    agreement /= len(peaks)

    order = [np.unravel_index(i, (layers, heads)) for i in np.argsort(-agreement.ravel())]
    print(f"{len(peaks)} dumps, {layers} layers x {heads} heads")
    print("layer head  agrees  active  forward")
    for layer, head in order[:12]:
        print(f"{layer:5d} {head:4d}  {agreement[layer, head]:6.2f}  {active[layer, head]:6.2f}  {forward[layer, head]:7.2f}")
    best = order[:6]
    flat = ", ".join(f"{layer}, {head}" for layer, head in best)
    print(f"\nstatic let alignmentHeads: [Int32] = [{flat}]")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
