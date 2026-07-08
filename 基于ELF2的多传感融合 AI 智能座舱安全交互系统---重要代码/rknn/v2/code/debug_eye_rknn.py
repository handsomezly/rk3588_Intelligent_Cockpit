"""On-board sanity check for eye_cnn.rknn.

Runs the deployed RKNN model on labeled samples from ./eye_dataset and
reports per-class accuracy + the raw logits, so we can tell whether the
model itself is broken or only the pipeline integration is.

Usage on the board:
    python3 debug_eye_rknn.py
    python3 debug_eye_rknn.py --n 30  # 30 per category
"""

import argparse
import os
import random
from glob import glob

import cv2
import numpy as np
from rknnlite.api import RKNNLite

from eye_state import (
    CLASS_CLOSED,
    CLASS_NAMES,
    CLASS_OPEN,
    label_from_probs,
    p_open_from_probs,
    softmax_probs,
)


def load_rknn(model_path):
    rknn = RKNNLite()
    if rknn.load_rknn(model_path) != 0:
        raise RuntimeError(f"load_rknn failed: {model_path}")
    if rknn.init_runtime(core_mask=RKNNLite.NPU_CORE_0) != 0:
        raise RuntimeError("init_runtime failed")
    return rknn


def run_one(rknn, img_path, layout):
    """Try one inference under a given layout. Returns (logits, probs, pred)."""
    img = cv2.imread(img_path, cv2.IMREAD_GRAYSCALE)
    if img is None:
        return None
    if img.shape != (32, 32):
        img = cv2.resize(img, (32, 32), interpolation=cv2.INTER_AREA)

    if layout == "nhwc":
        # (1, 32, 32, 1) uint8 - what test.py uses today
        inp = img[None, :, :, None]
    elif layout == "nchw":
        # (1, 1, 32, 32) uint8
        inp = img[None, None, :, :]
    else:
        raise ValueError(layout)

    inp = np.ascontiguousarray(inp)
    out = rknn.inference(inputs=[inp], data_format=layout)
    logits = np.asarray(out[0]).reshape(-1)
    probs = softmax_probs(logits)
    return logits, probs, int(np.argmax(probs))


def evaluate_layout(rknn, samples, layout):
    correct = 0
    total = 0
    confusion = np.zeros((len(CLASS_NAMES), len(CLASS_NAMES)), dtype=np.int64)
    p_opens = {idx: [] for idx in range(len(CLASS_NAMES))}

    for path, label in samples:
        result = run_one(rknn, path, layout)
        if result is None:
            continue
        logits, probs, pred = result
        p_opens[label].append(p_open_from_probs(probs))
        total += 1
        if pred == label:
            correct += 1
        confusion[label, pred] += 1

    if total == 0:
        return None
    closed_total = int(confusion[CLASS_CLOSED].sum())
    open_total = int(confusion[CLASS_OPEN].sum())
    return {
        "layout": layout,
        "acc": correct / total,
        "confusion": confusion,
        "closed_recall": (confusion[CLASS_CLOSED, CLASS_CLOSED] / closed_total) if closed_total else 0.0,
        "open_as_closed": (confusion[CLASS_OPEN, CLASS_CLOSED] / open_total) if open_total else 0.0,
        "closed_p_open_mean": float(np.mean(p_opens[CLASS_CLOSED])) if p_opens[CLASS_CLOSED] else None,
        "open_p_open_mean": float(np.mean(p_opens[CLASS_OPEN])) if p_opens[CLASS_OPEN] else None,
        "n_closed": closed_total,
        "n_open": open_total,
    }


def _class_root(data_root, split, class_name):
    split_root = os.path.join(data_root, split) if split else data_root
    return os.path.join(split_root, class_name)


def collect_samples(data_root, n_per_cls, split="val"):
    """Pick n_per_cls images per class at random."""
    rng = random.Random(0)
    samples = []
    split_to_use = split if os.path.isdir(os.path.join(data_root, split)) else ""
    for cls_id, cls_name in enumerate(CLASS_NAMES):
        all_imgs = []
        root = _class_root(data_root, split_to_use, cls_name)
        if not os.path.isdir(root):
            continue
        for sub in sorted(os.listdir(root)):
            sub_path = os.path.join(root, sub)
            if os.path.isdir(sub_path):
                all_imgs.extend(glob(os.path.join(sub_path, "*.png")))
        rng.shuffle(all_imgs)
        for p in all_imgs[:n_per_cls]:
            samples.append((p, cls_id))
    rng.shuffle(samples)
    return samples


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="./eye_cnn.rknn")
    ap.add_argument("--data", default="./eye_dataset_v2")
    ap.add_argument("--split", default="val", help="prefer this split when data has train/val")
    ap.add_argument("--n", type=int, default=30, help="samples per class")
    ap.add_argument("--show-each", action="store_true", help="print every sample")
    args = ap.parse_args()

    samples = collect_samples(args.data, args.n, split=args.split)
    print(f"Loaded {len(samples)} test samples ({args.n}/class, split={args.split})")

    rknn = load_rknn(args.model)

    for layout in ("nhwc", "nchw"):
        print(f"\n=== Trying data_format='{layout}' ===")
        if args.show_each:
            for path, label in samples[:10]:
                r = run_one(rknn, path, layout)
                if r is None:
                    continue
                logits, probs, pred = r
                cls_str = CLASS_NAMES[label].upper()
                pred_str = label_from_probs(probs)
                ok = "OK " if pred == label else "ERR"
                print(
                    f"  {ok} {cls_str:6s} {os.path.basename(path):40s} "
                    f"logits={logits.round(3)} probs={probs.round(3)} -> {pred_str}"
                )
        result = evaluate_layout(rknn, samples, layout)
        if result is None:
            print("  no samples evaluated")
            continue
        print(
            f"  acc={result['acc']:.3f}  "
            f"closed_recall={result['closed_recall']:.3f} ({result['n_closed']})  "
            f"open_as_closed={result['open_as_closed']:.3f} ({result['n_open']})"
        )
        print(f"  confusion rows=true cols=pred {CLASS_NAMES}: {result['confusion'].tolist()}")
        print(
            f"  mean p_open on TRUE-CLOSED = {result['closed_p_open_mean']:.3f}  "
            f"(expect << 0.5)"
        )
        print(
            f"  mean p_open on TRUE-OPEN   = {result['open_p_open_mean']:.3f}  "
            f"(expect >> 0.5)"
        )

    rknn.release()
    print(
        "\nInterpretation:\n"
        "  acc>=0.9 in either layout: model fine; pick that layout for test.py.\n"
        "  closed_p_open_mean ~= open_p_open_mean: quantization collapsed; redo with bigger calib set or fp16.\n"
        "  open_as_closed > 0.03: too many false fatigue frames; fix data/crop before tuning PERCLOS.\n"
        "  closed_recall < 0.95: model misses closed eyes; add cleaner closed samples.\n"
        "  closed_acc low + open_acc high: layout/channel mismatch (try the other data_format).\n"
    )


if __name__ == "__main__":
    main()
