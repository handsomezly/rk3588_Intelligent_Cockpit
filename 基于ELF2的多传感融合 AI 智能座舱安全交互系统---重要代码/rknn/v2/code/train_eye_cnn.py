"""Train a tiny CNN to classify 32x32 grayscale eye crops as closed/open/squint.

Run on a PC (with PyTorch). Inputs come from the on-board sampling pass:

    eye_dataset_v2/
        train/{closed,open,squint}/{session}/*.png
        val/{closed,open,squint}/{session}/*.png

Output: eye_cnn.onnx (1x1x32x32 input). Run convert_eye_rknn.py next.

Usage:
    python train_eye_cnn.py --data ./eye_dataset_v2 --epochs 60 --out eye_cnn.onnx
"""

import argparse
import os
import random
import sys
from glob import glob

import cv2
import numpy as np

from eye_state import CLASS_CLOSED, CLASS_OPEN, CLASS_SQUINT, CLASS_NAMES

try:
    import torch
    import torch.nn as nn
    import torch.nn.functional as F
    from torch.utils.data import DataLoader, Dataset
except ImportError:
    torch = None
    nn = None
    F = None
    DataLoader = None
    Dataset = object


def _torch_no_grad():
    if torch is None:
        def decorator(fn):
            return fn
        return decorator
    return torch.no_grad()


def default_device():
    return "cuda" if torch is not None and torch.cuda.is_available() else "cpu"


# Class id convention: 0 = closed, 1 = open, 2 = squint. Matches downstream
# `softmax[..., 1]` -> p_open used by the on-board pipeline. Squint is tracked
# separately and is not counted as PERCLOS-closed.
LABEL_TO_CLASS = {"closed": CLASS_CLOSED, "open": CLASS_OPEN, "squint": CLASS_SQUINT}
PATCH_SIZE = 32


# --------------------------------------------------------------------------- #
# Data
# --------------------------------------------------------------------------- #


def has_explicit_split(root):
    """Return True when dataset uses root/train and root/val split dirs."""
    return (
        os.path.isdir(os.path.join(root, "train"))
        and os.path.isdir(os.path.join(root, "val"))
    )


def _label_for_subdir(class_name, sub_name):
    """Map v2 class dirs and legacy closed/squint sessions to class ids."""
    class_name = class_name.lower()
    sub_name = sub_name.lower()
    if class_name == "closed" and "squint" in sub_name:
        return CLASS_SQUINT
    if class_name not in LABEL_TO_CLASS:
        raise ValueError(f"unknown class dir: {class_name}")
    return LABEL_TO_CLASS[class_name]


def list_images(root, split=None):
    """Walk v2 or legacy eye dataset trees and yield (path, label).

    Supported layouts:
      root/train/{open,closed,squint}/session/*.png
      root/val/{open,closed,squint}/session/*.png
      root/{open,closed,squint}/session/*.png
      root/closed/squint/*.png  (legacy, remapped to CLASS_SQUINT)
    """
    pairs = []
    scan_root = os.path.join(root, split) if split else root
    for label_name in CLASS_NAMES:
        class_root = os.path.join(scan_root, label_name)
        if not os.path.isdir(class_root):
            continue
        # One level of subcategories (front, left, glasses_reflect, ...).
        for sub in sorted(os.listdir(class_root)):
            sub_path = os.path.join(class_root, sub)
            if not os.path.isdir(sub_path):
                continue
            class_id = _label_for_subdir(label_name, sub)
            for ext in ("*.png", "*.jpg", "*.jpeg", "*.bmp"):
                for p in glob(os.path.join(sub_path, ext)):
                    pairs.append((p, class_id))
    if not pairs:
        raise FileNotFoundError(f"No eye images found under: {scan_root}")
    return pairs


class EyePatchDataset(Dataset):
    def __init__(self, pairs, train=True):
        self.pairs = pairs
        self.train = train

    def __len__(self):
        return len(self.pairs)

    def _augment(self, img):
        # Random horizontal flip (left/right eye symmetry).
        if random.random() < 0.5:
            img = cv2.flip(img, 1)
        # Brightness + contrast jitter.
        alpha = random.uniform(0.85, 1.15)  # contrast
        beta = random.uniform(-15, 15)       # brightness
        img = np.clip(img.astype(np.float32) * alpha + beta, 0, 255).astype(np.uint8)
        # Small rotation + translation (eye landmarks are imprecise on board).
        angle = random.uniform(-12, 12)
        tx = random.uniform(-2, 2)
        ty = random.uniform(-2, 2)
        M = cv2.getRotationMatrix2D((PATCH_SIZE / 2, PATCH_SIZE / 2), angle, 1.0)
        M[0, 2] += tx
        M[1, 2] += ty
        img = cv2.warpAffine(
            img, M, (PATCH_SIZE, PATCH_SIZE),
            flags=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_REFLECT,
        )
        return img

    def __getitem__(self, idx):
        path, label = self.pairs[idx]
        img = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
        if img is None:
            raise IOError(f"failed to read {path}")
        if img.shape != (PATCH_SIZE, PATCH_SIZE):
            img = cv2.resize(img, (PATCH_SIZE, PATCH_SIZE), interpolation=cv2.INTER_AREA)
        if self.train:
            img = self._augment(img)
        # CHW float32 in [0, 1]. Mean/std normalization is folded into the
        # RKNN conversion step (mean=0, std=255), so we just divide here.
        x = img.astype(np.float32) / 255.0
        x = x[None, :, :]  # (1, 32, 32)
        return torch.from_numpy(x), torch.tensor(label, dtype=torch.long)


# --------------------------------------------------------------------------- #
# Model
# --------------------------------------------------------------------------- #


if nn is not None:
    class EyeCNN(nn.Module):
        """4-conv + GAP + FC. ~60K params, well under 1ms on RK3588 NPU."""

        def __init__(self, num_classes=len(CLASS_NAMES)):
            super().__init__()
            self.conv1 = nn.Conv2d(1, 16, 3, padding=1, bias=False)
            self.bn1 = nn.BatchNorm2d(16)
            self.conv2 = nn.Conv2d(16, 32, 3, padding=1, bias=False)
            self.bn2 = nn.BatchNorm2d(32)
            self.conv3 = nn.Conv2d(32, 64, 3, padding=1, bias=False)
            self.bn3 = nn.BatchNorm2d(64)
            self.conv4 = nn.Conv2d(64, 64, 3, padding=1, bias=False)
            self.bn4 = nn.BatchNorm2d(64)
            self.fc = nn.Linear(64, num_classes)

        def forward(self, x):
            x = F.max_pool2d(F.relu(self.bn1(self.conv1(x))), 2)  # 32 -> 16
            x = F.max_pool2d(F.relu(self.bn2(self.conv2(x))), 2)  # 16 -> 8
            x = F.max_pool2d(F.relu(self.bn3(self.conv3(x))), 2)  # 8  -> 4
            x = F.relu(self.bn4(self.conv4(x)))                   # 4
            x = F.adaptive_avg_pool2d(x, 1).flatten(1)            # (B, 64)
            return self.fc(x)                                     # (B, 3) logits
else:
    class EyeCNN:
        def __init__(self, *args, **kwargs):
            raise ImportError("PyTorch is required for training/exporting EyeCNN.")


# --------------------------------------------------------------------------- #
# Train / eval / export
# --------------------------------------------------------------------------- #


def split_train_val(pairs, val_ratio=0.15, seed=42):
    """Shuffle then split. Stratify by class so val has each class."""
    rng = random.Random(seed)
    by_label = {class_id: [] for class_id in range(len(CLASS_NAMES))}
    for p in pairs:
        by_label[p[1]].append(p)
    train, val = [], []
    for label, items in by_label.items():
        if not items:
            continue
        rng.shuffle(items)
        n_val = max(1, int(len(items) * val_ratio))
        val.extend(items[:n_val])
        train.extend(items[n_val:])
    rng.shuffle(train)
    rng.shuffle(val)
    return train, val


def load_dataset_splits(root, val_ratio=0.15, seed=42):
    """Load explicit root/train + root/val when present, otherwise split legacy data."""
    if has_explicit_split(root):
        train_pairs = list_images(root, split="train")
        val_pairs = list_images(root, split="val")
        return train_pairs, val_pairs
    pairs = list_images(root)
    return split_train_val(pairs, val_ratio=val_ratio, seed=seed)


@_torch_no_grad()
def evaluate(model, loader, device):
    model.eval()
    correct = 0
    total = 0
    confusion = np.zeros((len(CLASS_NAMES), len(CLASS_NAMES)), dtype=np.int64)
    for x, y in loader:
        x, y = x.to(device), y.to(device)
        logits = model(x)
        pred = logits.argmax(dim=1)
        correct += (pred == y).sum().item()
        total += y.numel()
        for t, p in zip(y.cpu().numpy(), pred.cpu().numpy()):
            confusion[t, p] += 1
    return correct / max(total, 1), confusion


def export_onnx(model, out_path, device):
    model.eval()
    # Fixed batch=1 keeps the RKNN conversion straightforward.
    # The on-board pipeline runs left + right eyes as two separate inferences.
    dummy = torch.zeros(1, 1, PATCH_SIZE, PATCH_SIZE, device=device)
    torch.onnx.export(
        model,
        dummy,
        out_path,
        input_names=["eye"],
        output_names=["logits"],
        opset_version=12,
        do_constant_folding=True,
        dynamic_axes=None,
        external_data=False,
    )
    print(f"ONNX written: {out_path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="./eye_dataset")
    ap.add_argument("--out", default="./eye_cnn.onnx")
    ap.add_argument("--ckpt", default="./eye_cnn.pt")
    ap.add_argument("--epochs", type=int, default=60)
    ap.add_argument("--batch", type=int, default=128)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--weight-decay", type=float, default=1e-4)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--device", default=default_device())
    ap.add_argument("--export-only", action="store_true", help="load --ckpt and export --out without training")
    args = ap.parse_args()

    if torch is None:
        sys.exit("PyTorch is required to train/export EyeCNN. Install torch on the PC training machine.")

    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)

    train_pairs, val_pairs = load_dataset_splits(args.data, val_ratio=0.15, seed=args.seed)
    pairs = train_pairs + val_pairs
    print(f"Loaded {len(pairs)} images.")
    counts = {name: sum(1 for _, l in pairs if l == idx) for idx, name in enumerate(CLASS_NAMES)}
    print("  " + "  ".join(f"{name}={counts[name]}" for name in CLASS_NAMES))
    if counts["open"] == 0 or counts["closed"] == 0 or counts["squint"] == 0:
        sys.exit("All three classes must have samples: closed, open, squint.")
    train_counts = {
        name: sum(1 for _, label in train_pairs if label == idx)
        for idx, name in enumerate(CLASS_NAMES)
    }
    if any(count == 0 for count in train_counts.values()):
        sys.exit(f"Train split must contain all three classes, got: {train_counts}")

    split_mode = "explicit train/val" if has_explicit_split(args.data) else "legacy stratified fallback"
    print(f"Split mode: {split_mode}")
    print(f"Split: train={len(train_pairs)}  val={len(val_pairs)}")

    train_ds = EyePatchDataset(train_pairs, train=True)
    val_ds = EyePatchDataset(val_pairs, train=False)
    # num_workers=0 keeps the script Windows-friendly. Bump to 2-4 on Linux.
    train_loader = DataLoader(train_ds, batch_size=args.batch, shuffle=True, num_workers=0)
    val_loader = DataLoader(val_ds, batch_size=args.batch, shuffle=False, num_workers=0)

    device = torch.device(args.device)
    model = EyeCNN().to(device)
    n_params = sum(p.numel() for p in model.parameters())
    print(f"EyeCNN params: {n_params}")

    if args.export_only:
        model.load_state_dict(torch.load(args.ckpt, map_location=device))
        export_onnx(model, args.out, device)
        print(f"ONNX written from checkpoint: {args.out}")
        return

    # Class weights compensate class imbalance without hiding minority errors.
    cls_count = np.array(
        [sum(1 for _, label in train_pairs if label == idx) for idx in range(len(CLASS_NAMES))],
        dtype=np.float32,
    )
    cls_weight = cls_count.sum() / (len(CLASS_NAMES) * cls_count)
    print(f"class weights ({', '.join(CLASS_NAMES)}): {cls_weight}")
    criterion = nn.CrossEntropyLoss(weight=torch.tensor(cls_weight, device=device))

    opt = torch.optim.Adam(model.parameters(), lr=args.lr, weight_decay=args.weight_decay)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.epochs)

    best_val_acc = 0.0
    for epoch in range(1, args.epochs + 1):
        model.train()
        running_loss = 0.0
        seen = 0
        correct = 0
        for x, y in train_loader:
            x, y = x.to(device), y.to(device)
            logits = model(x)
            loss = criterion(logits, y)
            opt.zero_grad()
            loss.backward()
            opt.step()
            running_loss += loss.item() * y.numel()
            correct += (logits.argmax(dim=1) == y).sum().item()
            seen += y.numel()
        sched.step()
        train_loss = running_loss / max(seen, 1)
        train_acc = correct / max(seen, 1)

        val_acc, cm = evaluate(model, val_loader, device)
        open_total = cm[CLASS_OPEN].sum()
        closed_total = cm[CLASS_CLOSED].sum()
        open_as_closed = cm[CLASS_OPEN, CLASS_CLOSED] / max(open_total, 1)
        closed_recall = cm[CLASS_CLOSED, CLASS_CLOSED] / max(closed_total, 1)
        print(
            f"epoch {epoch:02d}/{args.epochs}  "
            f"train_loss={train_loss:.4f}  train_acc={train_acc:.4f}  "
            f"val_acc={val_acc:.4f}  "
            f"open_as_closed={open_as_closed:.4f}  "
            f"closed_recall={closed_recall:.4f}  "
            f"cm={cm.tolist()}"
        )
        if val_acc > best_val_acc:
            best_val_acc = val_acc
            torch.save(model.state_dict(), args.ckpt)

    print(f"best val_acc={best_val_acc:.4f}  ckpt={args.ckpt}")

    # Reload best weights before export so the ONNX matches the best epoch.
    model.load_state_dict(torch.load(args.ckpt, map_location=device))
    export_onnx(model, args.out, device)
    print("Done. Next: python convert_eye_rknn.py --onnx eye_cnn.onnx")


if __name__ == "__main__":
    main()
