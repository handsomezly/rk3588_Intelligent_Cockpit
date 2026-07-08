"""Quantize eye_cnn.onnx to eye_cnn.rknn for RK3588 deployment.

Run on a PC that has rknn-toolkit2 installed (the toolkit2 package, not
rknn-lite which is for the board). The toolkit lives at:
    F:\\ELF2\\zly\\rknn-toolkit2-master

Calibration uses images sampled from ./eye_dataset_v2/train (your on-board
captures), balanced across closed/open/squint and sessions. The plan is firm on this point: never use external datasets
(MRL/CEW) as the calibration set - their brightness/contrast distribution
differs from your camera and will hurt int8 accuracy badly.

Usage:
    python convert_eye_rknn.py \\
        --onnx eye_cnn.onnx \\
        --data ./eye_dataset_v2 \\
        --out eye_cnn.rknn
"""

import argparse
import os
import random
import sys
from glob import glob

from eye_state import CLASS_NAMES, label_from_probs, softmax_probs

try:
    from rknn.api import RKNN  # toolkit2
except ImportError as e:
    sys.exit(
        "rknn-toolkit2 not importable. Install from "
        "F:\\ELF2\\zly\\rknn-toolkit2-master\\rknn-toolkit2\\packages "
        f"(error: {e})"
    )


def _iter_label_session_dirs(scan_root):
    for label in CLASS_NAMES:
        class_root = os.path.join(scan_root, label)
        if not os.path.isdir(class_root):
            continue
        for session in sorted(os.listdir(class_root)):
            session_path = os.path.join(class_root, session)
            if not os.path.isdir(session_path):
                continue
            actual_label = "squint" if label == "closed" and "squint" in session.lower() else label
            yield actual_label, session, session_path


def collect_calibration_images(data_root, n_per_class=100):
    """Sample n_per_class images per class, balanced across sessions.

    Returns a list of absolute paths. We sample evenly across subcategories
    (front, left, glasses_reflect, ...) so the calibration covers all the
    poses/lighting the model will actually see.
    """
    scan_root = os.path.join(data_root, "train") if os.path.isdir(os.path.join(data_root, "train")) else data_root
    by_label = {label: [] for label in CLASS_NAMES}
    for label, _session, session_path in _iter_label_session_dirs(scan_root):
        by_label[label].append(session_path)

    selected = []
    for label, sessions in by_label.items():
        if not sessions:
            raise FileNotFoundError(f"missing calibration samples for class: {label}")
        per_session = max(1, n_per_class // len(sessions))
        label_selected = []
        for session_path in sessions:
            imgs = []
            for ext in ("*.png", "*.jpg", "*.jpeg", "*.bmp"):
                imgs.extend(glob(os.path.join(session_path, ext)))
            random.shuffle(imgs)
            label_selected.extend(imgs[:per_session])
        random.shuffle(label_selected)
        selected.extend(label_selected[:n_per_class])
    random.shuffle(selected)
    return selected


def write_dataset_txt(image_paths, out_path):
    """RKNN expects one path per line."""
    with open(out_path, "w", encoding="utf-8") as f:
        for p in image_paths:
            f.write(os.path.abspath(p) + "\n")
    print(f"Wrote {len(image_paths)} calibration paths -> {out_path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--onnx", default="./eye_cnn.onnx")
    ap.add_argument("--data", default="./eye_dataset")
    ap.add_argument("--out", default="./eye_cnn.rknn")
    ap.add_argument("--dataset-txt", default="./eye_calib.txt")
    ap.add_argument("--n-calib", type=int, default=200,
                    help="approx number of calibration images (split between open/closed)")
    ap.add_argument("--no-quantize", action="store_true",
                    help="export fp16 RKNN (debug only - bigger and slower on NPU)")
    ap.add_argument("--target", default="rk3588")
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    random.seed(args.seed)

    # Calibration set first; quantization needs it before build().
    calib_imgs = collect_calibration_images(args.data, n_per_class=args.n_calib // 2)
    if len(calib_imgs) < 20:
        sys.exit(f"Only {len(calib_imgs)} calibration images found; need more samples.")
    write_dataset_txt(calib_imgs, args.dataset_txt)

    rknn = RKNN(verbose=True)

    # Match the train_eye_cnn.py preprocessing: x = uint8 / 255 -> float [0, 1].
    # RKNN does (input - mean) / std, so mean=0, std=255 reproduces /255.
    rknn.config(
        mean_values=[[0.0]],
        std_values=[[255.0]],
        target_platform=args.target,
        # Eye crops are grayscale; suppress any RGB-channel handling.
        quant_img_RGB2BGR=False,
    )

    print(f"Loading ONNX: {args.onnx}")
    ret = rknn.load_onnx(model=args.onnx)
    if ret != 0:
        sys.exit(f"load_onnx failed: {ret}")

    print(f"Building RKNN (quantize={not args.no_quantize})...")
    ret = rknn.build(do_quantization=not args.no_quantize, dataset=args.dataset_txt)
    if ret != 0:
        sys.exit(f"build failed: {ret}")

    print(f"Exporting: {args.out}")
    ret = rknn.export_rknn(args.out)
    if ret != 0:
        sys.exit(f"export_rknn failed: {ret}")

    # Sanity check: load on PC simulator and run a single inference.
    # This catches preprocessing mismatches before we deploy to the board.
    ret = rknn.init_runtime(target=None)  # PC simulator
    if ret == 0:
        import cv2
        import numpy as np
        sample = cv2.imread(calib_imgs[0], cv2.IMREAD_GRAYSCALE)
        if sample is not None:
            if sample.shape != (32, 32):
                sample = cv2.resize(sample, (32, 32))
            inp = sample[None, :, :, None]  # NHWC for RKNN simulator
            out = rknn.inference(inputs=[inp])
            logits = np.asarray(out[0]).reshape(-1)
            probs = softmax_probs(logits)
            print(f"sample inference output shape: {[o.shape for o in out]}")
            print(f"sample logits: {logits}")
            print(f"sample probs: {probs.round(4)}  label={label_from_probs(probs)}")
    else:
        print("init_runtime simulator failed (skip sanity check)")

    rknn.release()
    print(f"\nDone. Deploy {args.out} to the board and run:")
    print("    python test.py --display --eye-model ./eye_cnn.rknn")


if __name__ == "__main__":
    main()
