"""Guided eye-patch dataset collector for the ELF2 fatigue pipeline.

Works on both Windows (PyCharm + rknn-toolkit2 PC simulator) and the ELF2 board
(rknnlite).  Both platforms produce identical 32×32 patches because the crop
logic is pure Python + OpenCV.

Windows usage (camera index 0, rknn-toolkit2 must be installed):
    python collect_dataset.py --face-model ./RetinaFace_mobile320.rknn \\
        --out ./eye_dataset_v2 --split train --camera 0
    python collect_dataset.py --face-model ./RetinaFace_mobile320.rknn \\
        --out ./eye_dataset_v2 --split val --camera 0

ELF2 board usage:
    python3 collect_dataset.py --face-model ./RetinaFace_mobile320.rknn \\
        --out ./eye_dataset_v2 --split train --camera /dev/video21
    python3 collect_dataset.py --face-model ./RetinaFace_mobile320.rknn \\
        --out ./eye_dataset_v2 --split val --camera /dev/video21

After collecting, retrain and re-quantise on the PC:
    python audit_eye_dataset.py --data ./eye_dataset_v2
    python train_eye_cnn.py  --data ./eye_dataset_v2 --epochs 60
    python convert_eye_rknn.py --onnx eye_cnn.onnx --data ./eye_dataset_v2
"""

import argparse
import csv
import os
import sys
import time
from collections import Counter
from itertools import product
from math import ceil

import cv2
import numpy as np

from eye_crop import select_driver, crop_eye_patches
from quality_check import evaluate_eye_patches


# ── RetinaFace post-processing (copied from test.py; pure NumPy, no RKNN dep) ─

MODEL_WIDTH = 320
MODEL_HEIGHT = 320
LETTERBOX_COLOR = 114
PRE_NMS_SCORE_THRESHOLD = 0.40
NMS_THRESHOLD = 0.50
NMS_TOP_K = 200


def _letterbox_resize(image, size, bg_color):
    tw, th = size
    ih, iw = image.shape[:2]
    r = min(tw / iw, th / ih)
    nw, nh = int(iw * r), int(ih * r)
    resized = cv2.resize(image, (nw, nh), interpolation=cv2.INTER_AREA)
    out = np.full((th, tw, 3), bg_color, dtype=np.uint8)
    ox, oy = (tw - nw) // 2, (th - nh) // 2
    out[oy:oy + nh, ox:ox + nw] = resized
    return out, r, ox, oy


def _prior_box():
    anchors = []
    min_sizes = ((16, 32), (64, 128), (256, 512))
    steps = (8, 16, 32)
    fmaps = [[ceil(MODEL_HEIGHT / s), ceil(MODEL_WIDTH / s)] for s in steps]
    for k, fmap in enumerate(fmaps):
        for i, j in product(range(fmap[0]), range(fmap[1])):
            for ms in min_sizes[k]:
                anchors.append([
                    (j + 0.5) * steps[k] / MODEL_WIDTH,
                    (i + 0.5) * steps[k] / MODEL_HEIGHT,
                    ms / MODEL_WIDTH,
                    ms / MODEL_HEIGHT,
                ])
    return np.asarray(anchors, dtype=np.float32)


_PRIORS = _prior_box()
_BOX_SCALE = np.asarray([MODEL_WIDTH, MODEL_HEIGHT, MODEL_WIDTH, MODEL_HEIGHT], dtype=np.float32)
_LM_SCALE = np.tile([MODEL_WIDTH, MODEL_HEIGHT], 5).astype(np.float32)


def _box_decode(loc):
    v = (0.1, 0.2)
    boxes = np.concatenate((
        _PRIORS[:, :2] + loc[:, :2] * v[0] * _PRIORS[:, 2:],
        _PRIORS[:, 2:] * np.exp(loc[:, 2:] * v[1]),
    ), axis=1)
    boxes[:, :2] -= boxes[:, 2:] / 2
    boxes[:, 2:] += boxes[:, :2]
    return boxes


def _lm_decode(lm):
    v = 0.1
    parts = [_PRIORS[:, :2] + lm[:, 2 * i:2 * i + 2] * v * _PRIORS[:, 2:] for i in range(5)]
    return np.concatenate(parts, axis=1)


def _nms(dets, thr):
    x1, y1, x2, y2 = dets[:, 0], dets[:, 1], dets[:, 2], dets[:, 3]
    scores = dets[:, 4]
    areas = (x2 - x1 + 1) * (y2 - y1 + 1)
    order = scores.argsort()[::-1]
    keep = []
    while order.size > 0:
        i = order[0]
        keep.append(i)
        xx1 = np.maximum(x1[i], x1[order[1:]])
        yy1 = np.maximum(y1[i], y1[order[1:]])
        xx2 = np.minimum(x2[i], x2[order[1:]])
        yy2 = np.minimum(y2[i], y2[order[1:]])
        inter = np.maximum(0.0, xx2 - xx1 + 1) * np.maximum(0.0, yy2 - yy1 + 1)
        ovr = inter / (areas[i] + areas[order[1:]] - inter)
        order = order[np.where(ovr <= thr)[0] + 1]
    return keep


def _post_process(outputs, img_shape, ratio, ox, oy):
    ih, iw = img_shape
    loc = np.squeeze(outputs[0], 0)
    conf = np.squeeze(outputs[1], 0)
    lm = np.squeeze(outputs[2], 0)

    boxes = _box_decode(loc) * _BOX_SCALE
    boxes[:, 0::2] = np.clip((boxes[:, 0::2] - ox) / ratio, 0, iw - 1)
    boxes[:, 1::2] = np.clip((boxes[:, 1::2] - oy) / ratio, 0, ih - 1)

    scores = conf[:, 1]
    landmarks = _lm_decode(lm) * _LM_SCALE
    landmarks[:, 0::2] = np.clip((landmarks[:, 0::2] - ox) / ratio, 0, iw - 1)
    landmarks[:, 1::2] = np.clip((landmarks[:, 1::2] - oy) / ratio, 0, ih - 1)

    valid = np.where(scores > PRE_NMS_SCORE_THRESHOLD)[0]
    if valid.size == 0:
        return np.empty((0, 15), dtype=np.float32)
    boxes, scores, landmarks = boxes[valid], scores[valid], landmarks[valid]
    order = scores.argsort()[::-1][:NMS_TOP_K]
    boxes, scores, landmarks = boxes[order], scores[order], landmarks[order]
    dets = np.hstack((boxes, scores[:, None])).astype(np.float32, copy=False)
    keep = _nms(dets, NMS_THRESHOLD)
    return np.concatenate((dets[keep], landmarks[keep]), axis=1)


# ── Session list ──────────────────────────────────────────────────────────────

SESSIONS = [
    # (子目录,                           max_images,  采集指示)
    ("open/front",                    200, "正脸 ~50cm  保持睁眼，偶尔自然眨眼"),
    ("open/left",                     200, "头左歪 ~30°  保持睁眼"),
    ("open/right",                    200, "头右歪 ~30°  保持睁眼"),
    ("open/up_down",                  200, "抬头/低头缓慢交替  保持睁眼"),
    ("open/near_far",                 200, "距离 30-80cm 来回移动  保持睁眼"),
    ("open/glasses_reflect",          200, "戴眼镜 正脸 保持睁眼（没有眼镜就重复 front）"),
    ("closed/front_closed",           200, "正脸  轻闭眼保持"),
    ("closed/left_closed",            200, "头左歪 ~30°  闭眼保持"),
    ("closed/right_closed",           200, "头右歪 ~30°  闭眼保持"),
    ("closed/up_down_closed",         200, "抬头/低头缓慢交替  闭眼保持"),
    ("closed/squint",                 400, "疲劳眯眼（半睁半闭），或慢速闭合动作"),
    ("closed/glasses_reflect_closed", 200, "戴眼镜 闭眼保持（没有眼镜就重复 front_closed）"),
]

VALID_SPLITS = ("train", "val")
METADATA_FIELDS = (
    "timestamp",
    "split",
    "label",
    "session",
    "side",
    "relative_path",
    "face_score",
    "face_height",
    "eye_distance",
    "roll_angle_deg",
    "center_x",
    "center_y",
    "crop_box",
    "face_box",
)


def session_label(session_path):
    """Map a collection session path to the v2 class label."""
    first, _, second = session_path.partition("/")
    if first == "open":
        return "open"
    if "squint" in second.lower():
        return "squint"
    return "closed"


def session_name(session_path):
    """Return the v2 session directory name from open/front-style labels."""
    _first, sep, second = session_path.partition("/")
    return second if sep else session_path


def session_output_dir(out_root, split, session_path):
    return os.path.join(out_root, split, session_label(session_path), session_name(session_path))


def _fmt_float(value):
    return f"{float(value):.6f}"


def _fmt_tuple(values):
    return ",".join(_fmt_float(v) for v in values)


class EyePatchDatasetWriter:
    """Write v2 eye patches and append per-image metadata.csv rows."""

    def __init__(self, out_root, split, label, session, max_images=2000, min_interval_sec=0.10):
        if split not in VALID_SPLITS:
            raise ValueError(f"split must be one of {VALID_SPLITS}, got {split!r}")
        if label not in ("open", "closed", "squint"):
            raise ValueError(f"label must be open/closed/squint, got {label!r}")
        self.out_root = out_root
        self.split = split
        self.label = label
        self.session = session
        self.max_images = max_images
        self.min_interval_sec = min_interval_sec
        self._last_save = 0.0
        self.out_dir = os.path.join(out_root, split, label, session)
        self.metadata_path = os.path.join(out_root, "metadata.csv")
        os.makedirs(self.out_dir, exist_ok=True)
        os.makedirs(out_root, exist_ok=True)
        self.count = sum(
            1 for name in os.listdir(self.out_dir)
            if name.lower().endswith((".png", ".jpg", ".jpeg", ".bmp"))
        )
        self._ensure_metadata_header()

    def _ensure_metadata_header(self):
        needs_header = not os.path.exists(self.metadata_path) or os.path.getsize(self.metadata_path) == 0
        if needs_header:
            with open(self.metadata_path, "w", newline="", encoding="utf-8") as f:
                writer = csv.DictWriter(f, fieldnames=METADATA_FIELDS)
                writer.writeheader()

    def _metadata_row(self, stamp, side, rel_path, patches):
        center = patches[f"{side}_center"]
        crop_box = patches[f"{side}_box"]
        return {
            "timestamp": stamp,
            "split": self.split,
            "label": self.label,
            "session": self.session,
            "side": side,
            "relative_path": rel_path.replace(os.sep, "/"),
            "face_score": _fmt_float(patches["score"]),
            "face_height": _fmt_float(patches["box_h"]),
            "eye_distance": _fmt_float(patches["eye_distance"]),
            "roll_angle_deg": _fmt_float(patches["roll_angle_deg"]),
            "center_x": _fmt_float(center[0]),
            "center_y": _fmt_float(center[1]),
            "crop_box": _fmt_tuple(crop_box),
            "face_box": _fmt_tuple(patches["face_box"]),
        }

    def maybe_save(self, patches):
        """Save left/right patches when interval/limit allow. Returns count saved."""
        if patches is None:
            return 0
        if self.count >= self.max_images:
            return 0
        now = time.time()
        if now - self._last_save < self.min_interval_sec:
            return 0
        self._last_save = now

        stamp = time.strftime("%Y%m%d_%H%M%S") + f"_{int((now * 1000) % 1000):03d}"
        rows = []
        saved = 0
        for side, prefix in (("left", "eye_L"), ("right", "eye_R")):
            if self.count + saved >= self.max_images:
                break
            filename = f"{prefix}_{stamp}.png"
            path = os.path.join(self.out_dir, filename)
            if not cv2.imwrite(path, patches[side]):
                continue
            rel_path = os.path.relpath(path, self.out_root)
            rows.append(self._metadata_row(stamp, side, rel_path, patches))
            saved += 1

        if rows:
            with open(self.metadata_path, "a", newline="", encoding="utf-8") as f:
                writer = csv.DictWriter(f, fieldnames=METADATA_FIELDS)
                writer.writerows(rows)
            self.count += saved
        return saved

    def is_full(self):
        return self.count >= self.max_images

class CollectionQualityGate:
    """Runtime quality gate used before saving eye patches."""

    def __init__(self, enabled=True, profile="normal"):
        self.enabled = enabled
        self.profile = profile
        self.total = 0
        self.accepted = 0
        self.rejected = 0
        self.reject_counts = Counter()
        self.warning_counts = Counter()

    def check(self, patches, frame_shape=None):
        self.total += 1
        if not self.enabled:
            self.accepted += 1
            return True, None

        result = evaluate_eye_patches(patches, frame_shape=frame_shape, profile=self.profile)
        if result.ok:
            self.accepted += 1
        else:
            self.rejected += 1
            self.reject_counts.update(result.rejects)
        self.warning_counts.update(result.warnings)
        return result.ok, result

    def accept_rate(self):
        if self.total == 0:
            return 0.0
        return self.accepted / self.total

    def reject_summary(self, max_items=4):
        if not self.reject_counts:
            return "-"
        parts = [f"{reason}={count}" for reason, count in self.reject_counts.most_common(max_items)]
        return " ".join(parts)

# ── Platform-aware RKNN init ──────────────────────────────────────────────────

def _init_face_rknn_windows(model_path):
    from rknn.api import RKNN  # rknn-toolkit2, PC simulator
    rknn = RKNN()
    if rknn.load_rknn(model_path) != 0:
        sys.exit("load_rknn failed")
    if rknn.init_runtime(target=None) != 0:
        sys.exit("init_runtime (PC simulator) failed")
    print(f"RetinaFace loaded (PC simulator): {model_path}")
    return rknn


def _init_face_rknn_board(model_path):
    from rknnlite.api import RKNNLite
    rknn = RKNNLite()
    if rknn.load_rknn(model_path) != 0:
        sys.exit("load_rknn failed")
    if rknn.init_runtime(core_mask=RKNNLite.NPU_CORE_0) != 0:
        sys.exit("init_runtime failed")
    print(f"RetinaFace loaded (NPU core 0): {model_path}")
    return rknn


def init_face_rknn(model_path):
    if sys.platform == "win32":
        return _init_face_rknn_windows(model_path)
    return _init_face_rknn_board(model_path)


# ── Camera open ───────────────────────────────────────────────────────────────

def open_camera(camera_arg):
    if sys.platform == "win32":
        cap = cv2.VideoCapture(int(camera_arg))
    else:
        cap = cv2.VideoCapture(camera_arg, cv2.CAP_V4L2)
        cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    cap.set(cv2.CAP_PROP_FPS, 30)
    return cap


# ── Single-frame inference ────────────────────────────────────────────────────

def detect_face(rknn, frame):
    """Run RetinaFace on one frame, return post-processed detections array."""
    lb, ratio, ox, oy = _letterbox_resize(frame, (MODEL_WIDTH, MODEL_HEIGHT), LETTERBOX_COLOR)
    inp = cv2.cvtColor(lb, cv2.COLOR_BGR2RGB)
    inp = np.ascontiguousarray(inp[None])          # (1, 320, 320, 3)
    outputs = rknn.inference(inputs=[inp], data_format="nhwc")
    return _post_process(outputs, frame.shape[:2], ratio, ox, oy)


# ── Post-session montage check ────────────────────────────────────────────────

def _show_session_montage(session_dir, label, use_window=False, n=16):
    """Build a montage grid, save it, and optionally display it.

    With use_window=True (--display mode): show cv2 window, wait for keypress.
    Headless: save PNG and ask via stdin; user can inspect from Windows via NFS.
    Returns False if the user wants to quit collection.
    """
    files = sorted(f for f in os.listdir(session_dir) if f.lower().endswith(".png"))
    if not files:
        print("  [montage] 目录为空，跳过预览")
        return True

    step = max(1, len(files) // n)
    sel = files[::step][:n]
    imgs = [cv2.imread(os.path.join(session_dir, f), cv2.IMREAD_GRAYSCALE) for f in sel]
    imgs = [im for im in imgs if im is not None]
    if not imgs:
        return True

    big = [cv2.resize(im, (128, 128), interpolation=cv2.INTER_NEAREST) for im in imgs]
    cols = int(np.ceil(np.sqrt(len(big))))
    rows = int(np.ceil(len(big) / cols))
    while len(big) < cols * rows:
        big.append(np.zeros((128, 128), dtype=np.uint8))

    grid = np.vstack([np.hstack(big[r * cols:(r + 1) * cols]) for r in range(rows)])
    mont = cv2.cvtColor(grid, cv2.COLOR_GRAY2BGR)
    for i, f in enumerate(sel):
        r, c = i // cols, i % cols
        eye = "L" if "eye_L" in f else "R"
        cv2.putText(mont, eye, (c * 128 + 4, r * 128 + 16),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1, cv2.LINE_AA)

    # Always save to disk so it's visible from Windows via NFS
    safe_label = label.replace("/", "_").replace("\\", "_")
    out_png = os.path.join(os.path.dirname(session_dir), f"_montage_{safe_label}.png")
    cv2.imwrite(out_png, mont)
    print(f"  [montage] {len(files)} 张  →  {out_png}")

    if use_window:
        h, w = mont.shape[:2]
        banner = np.zeros((40, w, 3), dtype=np.uint8)
        cv2.putText(banner, f"{label} ({len(files)})  Enter:next  Q:quit",
                    (8, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 255), 1, cv2.LINE_AA)
        disp = np.vstack([banner, mont])
        win = f"review: {label}"
        cv2.namedWindow(win, cv2.WINDOW_NORMAL)
        cv2.resizeWindow(win, max(w, 640), disp.shape[0])
        cv2.imshow(win, disp)
        key = cv2.waitKey(0) & 0xFF
        cv2.destroyWindow(win)
        return key not in (ord("q"), ord("Q"))
    else:
        # Headless: user checks the saved PNG from Windows, confirms via terminal
        ans = input("  检查 montage 图片后按回车继续，输入 q 退出: ").strip().lower()
        return ans != "q"


# ── Session runner ────────────────────────────────────────────────────────────

def run_session(label, max_images, instruction, rknn, cap, out_root, split, display_win,
                quality_enabled=True, quality_profile="normal"):
    cls_label = session_label(label)
    sess_name = session_name(label)
    print()
    print("=" * 68)
    print(f"  Session : {label} -> {split}/{cls_label}/{sess_name}   (目标: {max_images} 张)")
    print(f"  指示   : {instruction}")
    for i in range(3, 0, -1):
        print(f"\r  准备 {i}...", end="", flush=True)
        if display_win:
            placeholder = np.zeros((120, 500, 3), dtype=np.uint8)
            cv2.putText(placeholder, instruction, (10, 30),
                        cv2.FONT_HERSHEY_DUPLEX, 0.55, (255, 255, 255), 1, cv2.LINE_AA)
            cv2.putText(placeholder, f"Ready in {i}...", (10, 80),
                        cv2.FONT_HERSHEY_DUPLEX, 1.0, (0, 255, 255), 2, cv2.LINE_AA)
            cv2.imshow(display_win, placeholder)
            cv2.waitKey(1000)
        else:
            time.sleep(1)
    print("\r  GO!               ")

    out_dir = session_output_dir(out_root, split, label)
    saver = EyePatchDatasetWriter(
        out_root,
        split=split,
        label=cls_label,
        session=sess_name,
        max_images=max_images,
        min_interval_sec=0.10,
    )
    quality_gate = CollectionQualityGate(enabled=quality_enabled, profile=quality_profile)
    if quality_gate.enabled:
        print(f"  质量门控: {quality_profile}（不合格眼图不保存）")
    else:
        print("  质量门控: OFF（所有可裁剪眼图都会保存）")

    n_frames = 0
    n_no_face = 0
    t_start = time.time()
    last_report = t_start

    while not saver.is_full():
        ret, frame = cap.read()
        if not ret:
            print("  摄像头读帧失败，提前结束本 session")
            break
        n_frames += 1

        detections = detect_face(rknn, frame)
        driver = select_driver(detections)
        patches = crop_eye_patches(frame, driver) if driver is not None else None

        if patches is None:
            n_no_face += 1

        if patches is not None:
            accepted, _quality = quality_gate.check(patches, frame_shape=frame.shape)
            if accepted:
                saver.maybe_save(patches)

        # Optional live preview
        if display_win is not None and n_frames % 3 == 0:
            vis = frame.copy()
            if driver is not None:
                x1, y1, x2, y2 = driver[:4].astype(int)
                cv2.rectangle(vis, (x1, y1), (x2, y2), (0, 255, 0), 2)
            if patches is not None:
                for box in (patches["left_box"], patches["right_box"]):
                    bx1, by1, bx2, by2 = box
                    cv2.rectangle(vis, (bx1, by1), (bx2, by2), (0, 165, 255), 1)
            pct = saver.count / max(max_images, 1) * 100
            cv2.putText(vis, f"{label}  {saver.count}/{max_images} ({pct:.0f}%)",
                        (8, 24), cv2.FONT_HERSHEY_DUPLEX, 0.6, (0, 255, 255), 1, cv2.LINE_AA)
            cv2.imshow(display_win, vis)
            if cv2.waitKey(1) & 0xFF == ord("q"):
                print("  收到 q，跳过本 session")
                break

        now = time.time()
        if now - last_report >= 2.0:
            face_rate = (n_frames - n_no_face) / max(n_frames, 1) * 100
            if quality_gate.enabled:
                quality_text = (
                    f"质检通过: {quality_gate.accept_rate() * 100:>4.0f}%  "
                    f"拒绝: {quality_gate.reject_summary()}  "
                )
            else:
                quality_text = "质检: OFF  "
            print(
                f"  已存: {saver.count:>4}/{max_images}  "
                f"检出率: {face_rate:>4.0f}%  "
                f"{quality_text}"
                f"用时: {now - t_start:>4.0f}s"
            )
            last_report = now

    elapsed = time.time() - t_start
    print(f"  完成: {saver.count} 张  ({elapsed:.1f}s  共处理 {n_frames} 帧)")
    if quality_gate.enabled:
        print(
            f"  质检统计: checked={quality_gate.total}  "
            f"accepted={quality_gate.accepted}  rejected={quality_gate.rejected}  "
            f"rejects={quality_gate.reject_summary()}"
        )
    return saver.count


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(
        description="采集 eye_dataset_v2（rotation-aligned 32×32 patch，与推理 pipeline 完全一致）"
    )
    ap.add_argument("--face-model", default="./RetinaFace_mobile320.rknn",
                    help="RetinaFace .rknn 路径")
    ap.add_argument("--out", default="./eye_dataset_v2",
                    help="输出根目录（自动创建子目录）")
    ap.add_argument("--split", default="train", choices=VALID_SPLITS,
                    help="写入 train 或 val 子集；建议先采 train，再用 --split val 单独采验证集")
    ap.add_argument("--camera",
                    default="0" if sys.platform == "win32" else "/dev/video21",
                    help="Windows: 摄像头索引(0/1/...)；板子: /dev/videoX")
    ap.add_argument("--session", default="",
                    help="只采集指定的一个 session，例如 open/front 或 closed/squint；"
                         "留空则顺序跑全部 12 个")
    ap.add_argument("--skip", default="",
                    help="逗号分隔的要跳过的子目录，例如 open/front,closed/squint")
    ap.add_argument("--resume", action="store_true",
                    help="自动跳过已经达到 max_images 的 session（断点续采）")
    ap.add_argument("--display", action="store_true",
                    help="打开实时预览窗口，显示人脸框和眼睛裁剪框")
    ap.add_argument("--no-quality-gate", action="store_true",
                    help="关闭采集时质量过滤；默认会丢弃明显不合格的眼图")
    ap.add_argument("--quality-profile", default="normal", choices=("relaxed", "normal", "strict"),
                    help="质量过滤强度：relaxed 更宽松，strict 更严格，默认 normal")
    args = ap.parse_args()

    # --session 过滤：只保留指定的那一条
    if args.session:
        target = args.session.strip()
        matched = [s for s in SESSIONS if s[0] == target]
        if not matched:
            valid = ", ".join(s[0] for s in SESSIONS)
            sys.exit(f"未知 session '{target}'。可用值：\n  {valid}")
        sessions_to_run = matched
    else:
        sessions_to_run = SESSIONS

    skip = {s.strip() for s in args.skip.split(",") if s.strip()}

    print(f"平台   : {'Windows (rknn-toolkit2 PC 模拟器)' if sys.platform == 'win32' else '开发板 (rknnlite)'}")
    print(f"摄像头 : {args.camera}")
    print(f"输出   : {args.out}")
    print(f"Split  : {args.split}")
    print(f"质检   : {'OFF' if args.no_quality_gate else args.quality_profile}")
    print()
    print(f"{'Session':<36} {'目标':>6}  指示")
    print("-" * 80)
    for label, n, instr in sessions_to_run:
        tag = " [跳过]" if label in skip else ""
        print(f"  {label:<34} {n:>4}  {instr}{tag}")
    print()
    input("准备好后按回车开始...")

    rknn = init_face_rknn(args.face_model)
    cap = open_camera(args.camera)
    if not cap.isOpened():
        rknn.release()
        sys.exit(f"无法打开摄像头: {args.camera}")

    display_win = None
    if args.display:
        display_win = "collect_dataset"
        cv2.namedWindow(display_win, cv2.WINDOW_NORMAL)
        cv2.resizeWindow(display_win, 640, 480)

    total = 0
    try:
        for label, max_images, instruction in sessions_to_run:
            if label in skip:
                continue

            if args.resume:
                session_dir = session_output_dir(args.out, args.split, label)
                existing = 0
                if os.path.isdir(session_dir):
                    existing = sum(
                        1 for f in os.listdir(session_dir)
                        if f.lower().endswith(".png")
                    )
                if existing >= max_images:
                    print(f"  跳过 {label}（已有 {existing} 张，达到目标 {max_images}）")
                    total += existing
                    continue

            saved = run_session(
                label, max_images, instruction,
                rknn, cap, args.out, args.split, display_win,
                quality_enabled=not args.no_quality_gate,
                quality_profile=args.quality_profile,
            )
            total += saved
            session_dir = session_output_dir(args.out, args.split, label)
            if not _show_session_montage(session_dir, label):
                print("收到 Q，退出采集。")
                break
    except KeyboardInterrupt:
        print("\n\n用户中断 (Ctrl+C)。已完成的 session 数据已保存。")

    print()
    print(f"采集结束，共写入 {total} 张图片至 {args.out}/")
    print()
    print("下一步:")
    if args.split == "train":
        print(f"  先采验证集: python collect_dataset.py --out {args.out} --split val --face-model {args.face_model}")
    print(f"  质检: python audit_eye_dataset.py --data {args.out}")
    print(f"  训练: python train_eye_cnn.py --data {args.out} --epochs 60")
    print(f"  转换: python convert_eye_rknn.py --onnx eye_cnn.onnx --data {args.out}")

    cap.release()
    rknn.release()
    if display_win is not None:
        cv2.destroyAllWindows()


if __name__ == "__main__":
    main()






