import argparse
import time
from itertools import product
from math import ceil

import cv2
import numpy as np

from rknnpool_ld import rknnPoolExecutor
from eye_crop import (
    select_driver,
    crop_eye_patches,
    dummy_classify_eye,
    EyePatchSaver,
)
from eye_state import label_from_probs, p_open_from_probs, softmax_probs, state_letter
from perclos import (
    PerclosTracker,
    BlinkTracker,
    STATUS_WARMING_UP,
    STATUS_LOW_VISIBILITY,
    STATUS_NORMAL,
    STATUS_FATIGUE,
)

cv2.setNumThreads(1)

PROFILE_ENABLED = False
DRAW_RESULTS = True
MODEL_ONLY = False
EYE_SAVER = None
FATIGUE_ENABLED = True

MODEL_WIDTH = 320
MODEL_HEIGHT = 320
LETTERBOX_COLOR = 114
PRE_NMS_SCORE_THRESHOLD = 0.40
DRAW_SCORE_THRESHOLD = 0.40
NMS_THRESHOLD = 0.50
NMS_TOP_K = 200
WINDOW_SIZE = (1280, 720)
CAMERA_SIZE = (640, 480)
CAMERA_FPS = 30


def parse_args():
    parser = argparse.ArgumentParser(description="Run RetinaFace RKNN camera inference.")
    parser.add_argument("--camera", default="/dev/video21", help="camera device path")
    parser.add_argument(
        "--camera-size",
        default=f"{CAMERA_SIZE[0]}x{CAMERA_SIZE[1]}",
        help="camera capture size, for example 640x480",
    )
    parser.add_argument("--camera-fps", type=int, default=CAMERA_FPS, help="requested camera FPS")
    parser.add_argument("--fourcc", default="", help="requested camera FOURCC, for example MJPG or YUYV")
    parser.add_argument("--model", default="./RetinaFace_mobile320.rknn", help="rknn model path")
    parser.add_argument(
        "--display",
        action="store_true",
        help="show OpenCV window; requires a working X11 display",
    )
    parser.add_argument(
        "--display-every",
        type=int,
        default=1,
        help="show one frame every N processed frames",
    )
    parser.add_argument(
        "--display-size",
        default=f"{WINDOW_SIZE[0]}x{WINDOW_SIZE[1]}",
        help="OpenCV window size, for example 640x480",
    )
    parser.add_argument("--profile", action="store_true", help="print stage timing every 30 frames")
    parser.add_argument("--no-draw", action="store_true", help="skip drawing boxes and landmarks")
    parser.add_argument(
        "--model-only",
        action="store_true",
        help="skip RetinaFace decode/NMS/drawing; useful for model throughput checks",
    )
    parser.add_argument("--camera-only", action="store_true", help="only measure camera capture FPS")
    parser.add_argument(
        "--save-eyes",
        default="",
        help="directory to save cropped left/right eye patches (for RKNN calibration set)",
    )
    parser.add_argument(
        "--save-eyes-max",
        type=int,
        default=2000,
        help="stop saving after this many eye images",
    )
    parser.add_argument(
        "--eye-model",
        default="",
        help="(reserved for Step 7) rknn eye-state classifier; empty = use dummy classifier",
    )
    parser.add_argument(
        "--no-fatigue",
        action="store_true",
        help="disable PERCLOS pipeline; only run RetinaFace",
    )
    return parser.parse_args()


def parse_size(value, argument_name):
    try:
        width, height = value.lower().split("x", maxsplit=1)
        width = int(width)
        height = int(height)
    except ValueError as exc:
        raise ValueError(f"{argument_name} must look like 640x480") from exc
    if width <= 0 or height <= 0:
        raise ValueError(f"{argument_name} width and height must be positive")
    return width, height


def fourcc_to_str(value):
    value = int(value)
    chars = [chr((value >> 8 * i) & 0xFF) for i in range(4)]
    return "".join(char if char.isprintable() else " " for char in chars).strip()


def print_camera_info(cap):
    print(
        "摄像头实际参数:\t",
        int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)),
        "x",
        int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)),
        "fps=",
        round(cap.get(cv2.CAP_PROP_FPS), 2),
        "fourcc=",
        fourcc_to_str(cap.get(cv2.CAP_PROP_FOURCC)),
    )


def measure_camera(cap):
    frames = 0
    loop_time = time.time()
    print("开始摄像头纯采集测速...")
    try:
        while cap.isOpened():
            ret, _ = cap.read()
            if not ret:
                break
            frames += 1
            if frames % 120 == 0:
                print("最近120帧摄像头采集帧率:\t", round(120 / (time.time() - loop_time), 2), "FPS")
                loop_time = time.time()
    except KeyboardInterrupt:
        print("\n收到 Ctrl+C，正在退出...")


def letterbox_resize(image, size, bg_color):
    target_width, target_height = size
    image_height, image_width = image.shape[:2]

    aspect_ratio = min(target_width / image_width, target_height / image_height)
    new_width = int(image_width * aspect_ratio)
    new_height = int(image_height * aspect_ratio)

    resized = cv2.resize(image, (new_width, new_height), interpolation=cv2.INTER_AREA)

    result = np.full((target_height, target_width, 3), bg_color, dtype=np.uint8)
    offset_x = (target_width - new_width) // 2
    offset_y = (target_height - new_height) // 2
    result[offset_y:offset_y + new_height, offset_x:offset_x + new_width] = resized
    return result, aspect_ratio, offset_x, offset_y


def prior_box(image_size):
    anchors = []
    min_sizes = ((16, 32), (64, 128), (256, 512))
    steps = (8, 16, 32)
    feature_maps = [[ceil(image_size[0] / step), ceil(image_size[1] / step)] for step in steps]

    for k, feature_map in enumerate(feature_maps):
        min_sizes_per_stride = min_sizes[k]
        for i, j in product(range(feature_map[0]), range(feature_map[1])):
            for min_size in min_sizes_per_stride:
                scale_x = min_size / image_size[1]
                scale_y = min_size / image_size[0]
                center_x = (j + 0.5) * steps[k] / image_size[1]
                center_y = (i + 0.5) * steps[k] / image_size[0]
                anchors.append([center_x, center_y, scale_x, scale_y])

    return np.asarray(anchors, dtype=np.float32)


PRIORS = prior_box((MODEL_HEIGHT, MODEL_WIDTH))
BOX_SCALE = np.asarray([MODEL_WIDTH, MODEL_HEIGHT, MODEL_WIDTH, MODEL_HEIGHT], dtype=np.float32)
LANDMARK_SCALE = np.asarray(
    [
        MODEL_WIDTH,
        MODEL_HEIGHT,
        MODEL_WIDTH,
        MODEL_HEIGHT,
        MODEL_WIDTH,
        MODEL_HEIGHT,
        MODEL_WIDTH,
        MODEL_HEIGHT,
        MODEL_WIDTH,
        MODEL_HEIGHT,
    ],
    dtype=np.float32,
)


def box_decode(loc, priors):
    variances = (0.1, 0.2)
    boxes = np.concatenate(
        (
            priors[:, :2] + loc[:, :2] * variances[0] * priors[:, 2:],
            priors[:, 2:] * np.exp(loc[:, 2:] * variances[1]),
        ),
        axis=1,
    )
    boxes[:, :2] -= boxes[:, 2:] / 2
    boxes[:, 2:] += boxes[:, :2]
    return boxes


def decode_landmarks(predictions, priors):
    variances = (0.1, 0.2)
    return np.concatenate(
        (
            priors[:, :2] + predictions[:, 0:2] * variances[0] * priors[:, 2:],
            priors[:, :2] + predictions[:, 2:4] * variances[0] * priors[:, 2:],
            priors[:, :2] + predictions[:, 4:6] * variances[0] * priors[:, 2:],
            priors[:, :2] + predictions[:, 6:8] * variances[0] * priors[:, 2:],
            priors[:, :2] + predictions[:, 8:10] * variances[0] * priors[:, 2:],
        ),
        axis=1,
    )


def nms(dets, threshold):
    x1 = dets[:, 0]
    y1 = dets[:, 1]
    x2 = dets[:, 2]
    y2 = dets[:, 3]
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

        width = np.maximum(0.0, xx2 - xx1 + 1)
        height = np.maximum(0.0, yy2 - yy1 + 1)
        inter = width * height
        overlap = inter / (areas[i] + areas[order[1:]] - inter)

        inds = np.where(overlap <= threshold)[0]
        order = order[inds + 1]

    return keep


def post_process(outputs, image_shape, aspect_ratio, offset_x, offset_y):
    if len(outputs) != 3:
        raise ValueError(f"RetinaFace outputs mismatch, expect 3 tensors but got {len(outputs)}")

    img_height, img_width = image_shape
    loc, conf, landmarks = outputs

    loc = np.squeeze(loc, axis=0)
    conf = np.squeeze(conf, axis=0)
    landmarks = np.squeeze(landmarks, axis=0)

    boxes = box_decode(loc, PRIORS) * BOX_SCALE
    boxes[..., 0::2] = np.clip((boxes[..., 0::2] - offset_x) / aspect_ratio, 0, img_width - 1)
    boxes[..., 1::2] = np.clip((boxes[..., 1::2] - offset_y) / aspect_ratio, 0, img_height - 1)

    scores = conf[:, 1]

    landmarks = decode_landmarks(landmarks, PRIORS) * LANDMARK_SCALE
    landmarks[..., 0::2] = np.clip((landmarks[..., 0::2] - offset_x) / aspect_ratio, 0, img_width - 1)
    landmarks[..., 1::2] = np.clip((landmarks[..., 1::2] - offset_y) / aspect_ratio, 0, img_height - 1)

    valid = np.where(scores > PRE_NMS_SCORE_THRESHOLD)[0]
    if valid.size == 0:
        return np.empty((0, 15), dtype=np.float32)

    boxes = boxes[valid]
    scores = scores[valid]
    landmarks = landmarks[valid]

    order = scores.argsort()[::-1][:NMS_TOP_K]
    boxes = boxes[order]
    scores = scores[order]
    landmarks = landmarks[order]

    dets = np.hstack((boxes, scores[:, np.newaxis])).astype(np.float32, copy=False)
    keep = nms(dets, NMS_THRESHOLD)
    dets = dets[keep]
    landmarks = landmarks[keep]
    return np.concatenate((dets, landmarks), axis=1)


def _empty_eye_state():
    return {
        "p_left": None,
        "p_right": None,
        "probs_left": None,
        "probs_right": None,
        "label_left": None,
        "label_right": None,
        "left_box": None,
        "right_box": None,
        "score": None,
        "box_h": None,
        "patches": None,
    }


def _classify_with_rknn(rknn_eye, patch_gray):
    """Run the eye-state RKNN model on one 32x32 grayscale patch -> probs."""
    if patch_gray is None:
        return None
    # NHWC for RKNN: (1, 32, 32, 1) uint8. The RKNN config sets mean=0/std=255
    # so the model receives the same [0,1] range as PyTorch training.
    inp = patch_gray[None, :, :, None]
    inp = np.ascontiguousarray(inp)
    outputs = rknn_eye.inference(inputs=[inp], data_format="nhwc")
    logits = np.asarray(outputs[0]).reshape(-1)
    return softmax_probs(logits)


def myFunc_pipeline(rknn_face, rknn_eye, frame):
    """RetinaFace -> select driver -> crop eyes -> classify.

    rknn_eye is None when the user did not pass --eye-model; the dummy
    Sobel-based classifier is used in that case (Step 1-4 fallback).

    Returns (frame_or_drawn, eye_state_dict, timings_or_None). The main thread
    feeds eye_state into the PerclosTracker and overlays the HUD.
    """
    start_time = time.perf_counter()
    letterbox_img, aspect_ratio, offset_x, offset_y = letterbox_resize(
        frame, (MODEL_WIDTH, MODEL_HEIGHT), LETTERBOX_COLOR
    )
    preprocess_time = time.perf_counter()

    infer_img = cv2.cvtColor(letterbox_img, cv2.COLOR_BGR2RGB)
    infer_img = np.expand_dims(infer_img, axis=0)
    infer_img = np.ascontiguousarray(infer_img)

    outputs = rknn_face.inference(inputs=[infer_img], data_format="nhwc")
    inference_time = time.perf_counter()

    eye_state = _empty_eye_state()

    if MODEL_ONLY:
        timings = {
            "pre": preprocess_time - start_time,
            "infer": inference_time - preprocess_time,
            "post": 0.0,
            "eye": 0.0,
            "draw": 0.0,
            "worker": inference_time - start_time,
        }
        return frame, eye_state, (timings if PROFILE_ENABLED else None)

    detections = post_process(outputs, frame.shape[:2], aspect_ratio, offset_x, offset_y)
    postprocess_time = time.perf_counter()

    if FATIGUE_ENABLED:
        driver = select_driver(detections)
        patches = crop_eye_patches(frame, driver) if driver is not None else None
        if patches is not None:
            if rknn_eye is not None:
                probs_left = _classify_with_rknn(rknn_eye, patches["left"])
                probs_right = _classify_with_rknn(rknn_eye, patches["right"])
                eye_state["probs_left"] = probs_left.tolist()
                eye_state["probs_right"] = probs_right.tolist()
                eye_state["label_left"] = label_from_probs(probs_left)
                eye_state["label_right"] = label_from_probs(probs_right)
                eye_state["p_left"] = p_open_from_probs(probs_left)
                eye_state["p_right"] = p_open_from_probs(probs_right)
            else:
                eye_state["p_left"] = dummy_classify_eye(patches["left"])
                eye_state["p_right"] = dummy_classify_eye(patches["right"])
                eye_state["probs_left"] = [1.0 - eye_state["p_left"], eye_state["p_left"], 0.0]
                eye_state["probs_right"] = [1.0 - eye_state["p_right"], eye_state["p_right"], 0.0]
                eye_state["label_left"] = "open" if eye_state["p_left"] >= 0.5 else "closed"
                eye_state["label_right"] = "open" if eye_state["p_right"] >= 0.5 else "closed"
            eye_state["left_box"] = patches["left_box"]
            eye_state["right_box"] = patches["right_box"]
            eye_state["score"] = patches["score"]
            eye_state["box_h"] = patches["box_h"]
            eye_state["patches"] = patches
    eye_time = time.perf_counter()

    if not DRAW_RESULTS:
        timings = {
            "pre": preprocess_time - start_time,
            "infer": inference_time - preprocess_time,
            "post": postprocess_time - inference_time,
            "eye": eye_time - postprocess_time,
            "draw": 0.0,
            "worker": eye_time - start_time,
        }
        return frame, eye_state, (timings if PROFILE_ENABLED else None)

    draw_img = frame.copy()
    landmark_colors = ((0, 0, 255), (0, 255, 255), (255, 0, 255), (0, 255, 0), (255, 0, 0))

    for det in detections:
        score = float(det[4])
        if score < DRAW_SCORE_THRESHOLD:
            continue

        x1, y1, x2, y2 = det[:4].astype(int)
        cv2.rectangle(draw_img, (x1, y1), (x2, y2), (0, 0, 255), 2)
        cv2.putText(
            draw_img,
            f"{score:.3f}",
            (x1, max(y1 - 6, 0)),
            cv2.FONT_HERSHEY_DUPLEX,
            0.5,
            (255, 255, 255),
            1,
            cv2.LINE_AA,
        )

        landmark_points = det[5:].astype(int).reshape(5, 2)
        for point, color in zip(landmark_points, landmark_colors):
            cv2.circle(draw_img, tuple(point), 1, color, 4)

    if eye_state["p_left"] is not None:
        for box, p in (
            (eye_state["left_box"], eye_state["p_left"]),
            (eye_state["right_box"], eye_state["p_right"]),
        ):
            if p > 0.55:
                color = (0, 255, 0)
            elif p < 0.35:
                color = (0, 0, 255)
            else:
                color = (0, 255, 255)
            ex1, ey1, ex2, ey2 = box
            cv2.rectangle(draw_img, (ex1, ey1), (ex2, ey2), color, 1)

    draw_time = time.perf_counter()
    timings = {
        "pre": preprocess_time - start_time,
        "infer": inference_time - preprocess_time,
        "post": postprocess_time - inference_time,
        "eye": eye_time - postprocess_time,
        "draw": draw_time - eye_time,
        "worker": draw_time - start_time,
    }
    return draw_img, eye_state, (timings if PROFILE_ENABLED else None)


def render_hud(img, perclos_snap, blink_snap, combined_fatigue, eye_state):
    """Overlay PERCLOS + blink stats + per-eye state. Mutates img (already a copy)."""
    h, w = img.shape[:2]
    perclos_status = perclos_snap["status"]
    perclos = perclos_snap["perclos"]

    if eye_state["label_left"] is not None and eye_state["label_right"] is not None:
        eye_letters = state_letter(eye_state["label_left"]) + state_letter(eye_state["label_right"])
    elif eye_state["p_left"] is not None and eye_state["p_right"] is not None:
        eye_letters = ("O" if eye_state["p_left"] >= 0.5 else "C") + (
            "O" if eye_state["p_right"] >= 0.5 else "C"
        )
    else:
        eye_letters = "??"

    # Status priority: warming_up/low_visibility > combined fatigue > normal.
    if perclos_status == STATUS_WARMING_UP:
        status_str = "WARMING_UP"
        text_color = (0, 255, 255)
    elif perclos_status == STATUS_LOW_VISIBILITY:
        status_str = "LOW_VIS"
        text_color = (0, 255, 255)
    elif combined_fatigue:
        status_str = "FATIGUE"
        text_color = (0, 0, 255)
    else:
        status_str = "NORMAL"
        text_color = (0, 255, 0)

    rate = blink_snap["rate_per_min"]
    mean_dur = blink_snap["mean_dur_ms"]
    long_count = blink_snap["long_blink_count"]
    blink_n = blink_snap["blink_count"]
    dur_str = f"{mean_dur:.0f}ms" if mean_dur is not None else "--"

    line1 = (
        f"PERCLOS: {perclos:.3f}  EYES: {eye_letters}  "
        f"BLINKS: {blink_n} ({rate:.1f}/min)  STATUS: {status_str}"
    )
    line2 = (
        f"avg_dur={dur_str}  long={long_count}  "
        f"valid={perclos_snap['valid_count']}/{perclos_snap['window_len']}  "
        f"closed={perclos_snap['closed_count']}  "
        f"squint={perclos_snap.get('squint_count', 0)}"
    )

    cv2.rectangle(img, (0, 0), (w, 60), (0, 0, 0), -1)
    cv2.putText(img, line1, (10, 24), cv2.FONT_HERSHEY_DUPLEX, 0.55, text_color, 1, cv2.LINE_AA)
    cv2.putText(img, line2, (10, 50), cv2.FONT_HERSHEY_DUPLEX, 0.45, (200, 200, 200), 1, cv2.LINE_AA)

    if combined_fatigue and perclos_status not in (STATUS_WARMING_UP, STATUS_LOW_VISIBILITY):
        cv2.rectangle(img, (0, 0), (w - 1, h - 1), (0, 0, 255), 8)

    return img


if __name__ == "__main__":
    args = parse_args()
    PROFILE_ENABLED = args.profile
    DRAW_RESULTS = args.display and not args.no_draw
    MODEL_ONLY = args.model_only
    FATIGUE_ENABLED = not args.no_fatigue and not args.model_only
    if args.save_eyes:
        EYE_SAVER = EyePatchSaver(args.save_eyes, max_images=args.save_eyes_max)
        print(f"--save-eyes enabled, writing to {args.save_eyes} (max {args.save_eyes_max})")
    camera_width, camera_height = parse_size(args.camera_size, "--camera-size")
    display_every = max(args.display_every, 1)
    display_width, display_height = parse_size(args.display_size, "--display-size")
    out_win = "RetinaFace_Fatigue_Monitor"

    cap = cv2.VideoCapture(args.camera, cv2.CAP_V4L2)
    if args.fourcc:
        fourcc = args.fourcc.upper()
        if len(fourcc) != 4:
            raise ValueError("--fourcc must be exactly 4 characters, for example MJPG or YUYV")
        cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*fourcc))
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, camera_width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, camera_height)
    cap.set(cv2.CAP_PROP_FPS, args.camera_fps)
    print_camera_info(cap)

    if args.camera_only:
        measure_camera(cap)
        cap.release()
        raise SystemExit(0)

    modelPath = args.model
    eyeModelPath = args.eye_model if args.eye_model else None
    TPEs = 3

    pool = rknnPoolExecutor(
        face_model=modelPath,
        eye_model=eyeModelPath,
        TPEs=TPEs,
        func=myFunc_pipeline,
    )
    if eyeModelPath is not None:
        print(f"Eye classifier (RKNN): {eyeModelPath}")
    else:
        print("Eye classifier: dummy (Sobel-based) - pass --eye-model to use the real CNN")

    if args.display:
        cv2.namedWindow(out_win, cv2.WINDOW_NORMAL)
        cv2.resizeWindow(out_win, display_width, display_height)

    if cap.isOpened():
        for _ in range(TPEs + 1):
            ret, frame = cap.read()
            if not ret:
                print(f"无法读取摄像头，请检查 {args.camera} 节点状态。")
                cap.release()
                pool.release()
                raise SystemExit(-1)
            pool.put(frame)

    tracker = PerclosTracker() if FATIGUE_ENABLED else None
    blink_tracker = BlinkTracker() if FATIGUE_ENABLED else None
    last_combined_fatigue = False
    last_save_report = 0

    frames = 0
    loopTime = time.time()
    initTime = time.time()
    profile_sum = {
        "read": 0.0, "wait": 0.0, "display": 0.0,
        "pre": 0.0, "infer": 0.0, "post": 0.0,
        "eye": 0.0, "draw": 0.0, "worker": 0.0,
    }

    print("开始实时人脸检测推理...")
    try:
        while cap.isOpened():
            frames += 1
            read_start = time.perf_counter()
            ret, frame = cap.read()
            profile_sum["read"] += time.perf_counter() - read_start
            if not ret:
                break

            pool.put(frame)

            wait_start = time.perf_counter()
            pkg, flag = pool.get()
            profile_sum["wait"] += time.perf_counter() - wait_start
            if flag is False:
                break
            frame_result, eye_state, worker_profile = pkg
            if args.profile and worker_profile is not None:
                for key in ("pre", "infer", "post", "eye", "draw", "worker"):
                    profile_sum[key] += worker_profile[key]

            if EYE_SAVER is not None and eye_state["patches"] is not None:
                saved = EYE_SAVER.maybe_save(eye_state["patches"])
                if saved and EYE_SAVER.count - last_save_report >= 100:
                    last_save_report = EYE_SAVER.count
                    print(f"--save-eyes progress: {EYE_SAVER.count}/{EYE_SAVER.max_images}")
                if EYE_SAVER.is_full():
                    print(f"--save-eyes reached max: {EYE_SAVER.count}/{EYE_SAVER.max_images}")
                    break

            if tracker is not None:
                if eye_state.get("probs_left") is not None and eye_state.get("probs_right") is not None:
                    tracker.update_probs(eye_state["probs_left"], eye_state["probs_right"])
                else:
                    tracker.update(eye_state["p_left"], eye_state["p_right"])
                blink_tracker.update(eye_state["p_left"], eye_state["p_right"])
                perclos_snap = tracker.snapshot()
                blink_snap = blink_tracker.snapshot()
                # Suppress fatigue while warming up / face mostly missing.
                gate_clear = perclos_snap["status"] not in (
                    STATUS_WARMING_UP, STATUS_LOW_VISIBILITY
                )
                perclos_fatigue = perclos_snap["status"] == STATUS_FATIGUE
                blink_fatigue = blink_snap["is_fatigued"]
                combined_fatigue = gate_clear and (perclos_fatigue or blink_fatigue)

                if combined_fatigue and not last_combined_fatigue:
                    reasons = []
                    if perclos_fatigue:
                        reasons.append(f"PERCLOS={perclos_snap['perclos']:.3f}")
                    if blink_fatigue and blink_snap["fatigue_reason"]:
                        reasons.append(blink_snap["fatigue_reason"])
                    print(f"[FATIGUE] {' | '.join(reasons)} - DRIVER MAY BE FATIGUED")
                elif not combined_fatigue and last_combined_fatigue:
                    print(
                        f"[OK] PERCLOS={perclos_snap['perclos']:.3f}  "
                        f"avg_blink={blink_snap['mean_dur_ms']}ms - back to normal"
                    )
                last_combined_fatigue = combined_fatigue
            else:
                perclos_snap = None
                blink_snap = None
                combined_fatigue = False

            if args.display and frames % display_every == 0:
                display_start = time.perf_counter()
                if perclos_snap is not None and DRAW_RESULTS:
                    frame_result = render_hud(
                        frame_result, perclos_snap, blink_snap,
                        combined_fatigue, eye_state,
                    )
                cv2.imshow(out_win, frame_result)

                if cv2.waitKey(1) & 0xFF == ord("q"):
                    break
                profile_sum["display"] += time.perf_counter() - display_start

            if frames % 30 == 0:
                print("最近30帧平均帧率:\t", round(30 / (time.time() - loopTime), 2), "FPS")
                if args.profile:
                    print(
                        "阶段耗时(ms): read={read:.2f}, wait={wait:.2f}, pre={pre:.2f}, "
                        "infer={infer:.2f}, post={post:.2f}, eye={eye:.2f}, "
                        "draw={draw:.2f}, display={display:.2f}".format(
                            **{key: profile_sum[key] / 30 * 1000 for key in profile_sum}
                        )
                    )
                    profile_sum = {
                        "read": 0.0, "wait": 0.0, "display": 0.0,
                        "pre": 0.0, "infer": 0.0, "post": 0.0,
                        "eye": 0.0, "draw": 0.0, "worker": 0.0,
                    }
                loopTime = time.time()
    except KeyboardInterrupt:
        print("\n收到 Ctrl+C，正在退出...")

    if EYE_SAVER is not None:
        print(f"--save-eyes wrote {EYE_SAVER.count} files to {args.save_eyes}")
    if tracker is not None:
        snap = tracker.snapshot()
        print(
            f"最终 PERCLOS={snap['perclos']:.3f}  status={snap['status']}  "
            f"valid={snap['valid_count']}/{snap['window_len']}"
        )
    if blink_tracker is not None:
        bsnap = blink_tracker.snapshot()
        dur_str = f"{bsnap['mean_dur_ms']:.0f}ms" if bsnap["mean_dur_ms"] is not None else "--"
        print(
            f"最终 BLINKS={bsnap['blink_count']}  rate={bsnap['rate_per_min']:.1f}/min  "
            f"avg_dur={dur_str}  long={bsnap['long_blink_count']}  "
            f"fatigue={bsnap['is_fatigued']}"
        )

    print("运行结束。总平均帧率:\t", round(frames / (time.time() - initTime), 2), "FPS")

    cap.release()
    if args.display:
        cv2.destroyAllWindows()
    pool.release()
