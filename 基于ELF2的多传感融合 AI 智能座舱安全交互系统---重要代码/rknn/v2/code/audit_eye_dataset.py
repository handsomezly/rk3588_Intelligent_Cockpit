"""Audit ELF2 eye-patch datasets before training.

The v2 layout is:
    eye_dataset_v2/{train,val}/{open,closed,squint}/{session}/*.png

This script checks image dimensions, left/right balance, and split leakage
caused by the same frame timestamp appearing in both train and val. It also
builds per-session montages for quick human review.
"""

import argparse
import json
import os
import re
from collections import Counter, defaultdict

import cv2
import numpy as np

PATCH_SIZE = 32
VALID_LABELS = {"open", "closed", "squint"}
VALID_SPLITS = {"train", "val"}
STAMP_RE = re.compile(r"^eye_([LR])_(.+)\.(png|jpg|jpeg|bmp)$", re.IGNORECASE)


def parse_eye_filename(filename):
    """Return (side, frame_stamp) for eye_L_*.png / eye_R_*.png names."""
    match = STAMP_RE.match(filename)
    if not match:
        return None, None
    side = "left" if match.group(1).upper() == "L" else "right"
    return side, match.group(2)


def _record_from_path(root, path):
    rel_path = os.path.relpath(path, root)
    parts = rel_path.split(os.sep)

    if parts[0] in VALID_SPLITS:
        if len(parts) < 4:
            return None
        split, label, session = parts[0], parts[1], parts[2]
    else:
        if len(parts) < 3:
            return None
        split, label, session = "unsplit", parts[0], parts[1]
    if label == "closed" and "squint" in session.lower():
        label = "squint"
    if label not in VALID_LABELS:
        return None

    side, stamp = parse_eye_filename(os.path.basename(path))
    img = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    if img is None:
        shape = None
        valid_image = False
    else:
        shape = list(img.shape[:2])
        valid_image = tuple(img.shape[:2]) == (PATCH_SIZE, PATCH_SIZE)

    return {
        "path": path,
        "relative_path": rel_path.replace(os.sep, "/"),
        "split": split,
        "label": label,
        "session": session,
        "side": side,
        "stamp": stamp,
        "shape": shape,
        "valid_image": valid_image,
    }


def scan_dataset(root):
    """Return one record per image in a v2 or legacy eye dataset."""
    records = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for filename in sorted(filenames):
            if not filename.lower().endswith((".png", ".jpg", ".jpeg", ".bmp")):
                continue
            record = _record_from_path(root, os.path.join(dirpath, filename))
            if record is not None:
                records.append(record)
    return records


def detect_split_leakage(records):
    """Find frame stamps that appear in both train and val for same label/session."""
    by_key = defaultdict(set)
    for record in records:
        if record["split"] not in VALID_SPLITS or not record["stamp"]:
            continue
        key = (record["label"], record["session"], record["stamp"])
        by_key[key].add(record["split"])
    leaks = [key for key, splits in by_key.items() if {"train", "val"}.issubset(splits)]
    return sorted(leaks)


def summarize(records):
    counts = Counter()
    invalid = []
    unnamed = []
    for record in records:
        counts[(record["split"], record["label"], record["session"], record["side"])] += 1
        if not record["valid_image"]:
            invalid.append(record["relative_path"])
        if record["side"] is None or record["stamp"] is None:
            unnamed.append(record["relative_path"])
    return {
        "total_images": len(records),
        "counts": {
            "|".join(str(part) for part in key): value
            for key, value in sorted(counts.items())
        },
        "invalid_images": invalid,
        "unnamed_images": unnamed,
        "split_leakage": [
            {"label": label, "session": session, "stamp": stamp}
            for label, session, stamp in detect_split_leakage(records)
        ],
    }


def write_montages(records, out_dir, sample_count=16):
    os.makedirs(out_dir, exist_ok=True)
    by_session = defaultdict(list)
    for record in records:
        if record["valid_image"]:
            by_session[(record["split"], record["label"], record["session"])].append(record)

    written = []
    for (split, label, session), items in sorted(by_session.items()):
        items = sorted(items, key=lambda r: r["relative_path"])
        step = max(1, len(items) // sample_count)
        chosen = items[::step][:sample_count]
        imgs = []
        for record in chosen:
            img = cv2.imread(record["path"], cv2.IMREAD_GRAYSCALE)
            if img is not None:
                imgs.append((record, cv2.resize(img, (128, 128), interpolation=cv2.INTER_NEAREST)))
        if not imgs:
            continue

        cols = int(np.ceil(np.sqrt(len(imgs))))
        rows = int(np.ceil(len(imgs) / cols))
        blank = np.zeros((128, 128), dtype=np.uint8)
        tiles = [img for _record, img in imgs]
        while len(tiles) < rows * cols:
            tiles.append(blank.copy())
        grid = np.vstack([np.hstack(tiles[r * cols:(r + 1) * cols]) for r in range(rows)])
        grid = cv2.cvtColor(grid, cv2.COLOR_GRAY2BGR)
        for idx, (record, _img) in enumerate(imgs):
            r, c = idx // cols, idx % cols
            side = "L" if record["side"] == "left" else "R"
            cv2.putText(
                grid,
                side,
                (c * 128 + 4, r * 128 + 16),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.5,
                (0, 255, 0),
                1,
                cv2.LINE_AA,
            )

        safe = f"{split}_{label}_{session}".replace("/", "_").replace("\\", "_")
        out_path = os.path.join(out_dir, f"montage_{safe}.png")
        cv2.imwrite(out_path, grid)
        written.append(out_path)
    return written


def main():
    parser = argparse.ArgumentParser(description="Audit v2 eye-patch dataset quality before training.")
    parser.add_argument("--data", default="./eye_dataset_v2")
    parser.add_argument("--out", default="", help="audit output dir; default: <data>/_audit")
    parser.add_argument("--montage-n", type=int, default=16)
    args = parser.parse_args()

    out_dir = args.out or os.path.join(args.data, "_audit")
    records = scan_dataset(args.data)
    report = summarize(records)
    montage_dir = os.path.join(out_dir, "montages")
    report["montages"] = [
        os.path.relpath(path, out_dir).replace(os.sep, "/")
        for path in write_montages(records, montage_dir, sample_count=args.montage_n)
    ]

    os.makedirs(out_dir, exist_ok=True)
    report_path = os.path.join(out_dir, "audit_report.json")
    with open(report_path, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)

    print(f"images={report['total_images']}")
    print(f"invalid_images={len(report['invalid_images'])}")
    print(f"unnamed_images={len(report['unnamed_images'])}")
    print(f"split_leakage={len(report['split_leakage'])}")
    print(f"report={report_path}")
    if report["split_leakage"]:
        print("ERROR: same frame stamp appears in both train and val")
        raise SystemExit(2)


if __name__ == "__main__":
    main()
