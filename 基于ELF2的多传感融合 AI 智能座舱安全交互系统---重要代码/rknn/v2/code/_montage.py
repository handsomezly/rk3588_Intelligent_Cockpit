"""View a grid of eye patches from a single session directory.

Usage:
    python _montage.py eye_dataset_v2/open/front
    python _montage.py eye_dataset_v2/closed/squint --n 32
"""
import argparse
import os

import cv2
import numpy as np

ap = argparse.ArgumentParser()
ap.add_argument("dir", help="session subdirectory, e.g. eye_dataset_v2/open/front")
ap.add_argument("--n", type=int, default=16, help="number of patches to sample (perfect square recommended)")
args = ap.parse_args()

files = sorted(f for f in os.listdir(args.dir) if f.lower().endswith(".png"))
if not files:
    raise SystemExit(f"No PNG files in {args.dir}")

n = args.n
step = max(1, len(files) // n)
sel = files[::step][:n]

imgs = [cv2.imread(os.path.join(args.dir, f), cv2.IMREAD_GRAYSCALE) for f in sel]
imgs = [im for im in imgs if im is not None]

# Upscale 32x32 → 128x128 for clarity
big = [cv2.resize(im, (128, 128), interpolation=cv2.INTER_NEAREST) for im in imgs]

cols = int(np.ceil(np.sqrt(len(big))))
rows = int(np.ceil(len(big) / cols))
# Pad to fill the grid
while len(big) < cols * rows:
    big.append(np.zeros((128, 128), dtype=np.uint8))

grid_rows = [np.hstack(big[r * cols:(r + 1) * cols]) for r in range(rows)]
mont = np.vstack(grid_rows)
mont_color = cv2.cvtColor(mont, cv2.COLOR_GRAY2BGR)

for i, f in enumerate(sel):
    r, c = i // cols, i % cols
    eye = "L" if "eye_L" in f else "R"
    ts = f.split("_")[-1].replace(".png", "")
    cv2.putText(mont_color, f"{eye} {ts}", (c * 128 + 4, r * 128 + 14),
                cv2.FONT_HERSHEY_SIMPLEX, 0.4, (0, 255, 0), 1, cv2.LINE_AA)

label = args.dir.replace("/", "_").replace("\\", "_").strip("_")
out_path = f"_montage_{label}.png"
cv2.imwrite(out_path, mont_color)
print(f"Saved {len(sel)} patches ({len(files)} total) → {out_path}  size={mont_color.shape[:2]}")

cv2.imshow(f"montage: {args.dir}", mont_color)
cv2.waitKey(0)
cv2.destroyAllWindows()
