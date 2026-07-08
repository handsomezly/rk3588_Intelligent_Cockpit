"""Per-pose fatigue diagnostic for the ELF2 board.

Runs a scripted sequence of head-pose tests against the same RKNN pipeline that
test.py uses, prints PERCLOS / blink stats once per second, and gives a clean
per-pose + cross-pose summary at the end. No X11 / OpenCV window needed - all
output is on the terminal.

Usage (run from the board terminal):
    python3 diagnose_pose.py --eye-model ./eye_cnn.rknn

To skip poses (e.g. run only baseline + tilt):
    python3 diagnose_pose.py --skip head_pitch_up,head_pitch_down,distance_1m

Each pose prints lines like:
    t=12.0s  PERCLOS=0.034  p_open=(0.81,0.78)  BLINKS=3  status=normal

then a small block summarizing means / ranges / blink count, then moves on.
At the end a single table compares all poses against their expected behavior.
"""

import argparse
import os
import sys
import time

import cv2
import numpy as np

# Reuse the production pipeline so we measure exactly what test.py measures.
import test as test_mod
from rknnpool_ld import rknnPoolExecutor
from perclos import PerclosTracker, BlinkTracker
from eye_crop import EyePatchSaver


# Pose script: label, duration in seconds, on-screen instruction.
POSES = [
    ("baseline_frontal",    30, "正脸 ~50cm  自然睁眼+正常眨眼"),
    ("eyes_closed",          5, "完全闭眼（基线对照：闭眼应该被识到）"),
    ("head_left_tilt_30",   30, "头左歪 ~30°  保持睁眼"),
    ("head_right_tilt_30",  30, "头右歪 ~30°  保持睁眼"),
    ("head_pitch_up",       30, "抬头  保持睁眼（本次未修，可能偏高）"),
    ("head_pitch_down",     30, "低头  保持睁眼（本次未修，可能偏高）"),
    ("distance_1m",         30, "退到 ~1m 远  正脸睁眼（看 face_rate）"),
]


def expected(label):
    """(max_perclos_or_None, comment) - used to mark pass/fail in the summary."""
    if label == "baseline_frontal":
        return (0.05, "基线应接近 0")
    if label == "eyes_closed":
        return (None, "应该高 (>0.5)，证明分类器还会判闭")
    if "tilt" in label:
        return (0.05, "旋转对齐生效则应低")
    if "pitch" in label:
        return (0.30, "pitch 未修，仅做基线测量")
    if "distance" in label:
        return (None, "看 face_rate 是否仍 >50%")
    return (None, "")


def countdown(seconds, prefix="准备 ", display_win=None, label=""):
    for i in range(seconds, 0, -1):
        print(f"\r{prefix}{i}...", end="", flush=True)
        # Keep the OpenCV window responsive during countdown so it doesn't
        # freeze/grey-out on the desktop while the user is getting into pose.
        if display_win is not None:
            placeholder = np.zeros((180, 640, 3), dtype=np.uint8)
            cv2.putText(placeholder, f"NEXT: {label}", (16, 50),
                        cv2.FONT_HERSHEY_DUPLEX, 0.9, (255, 255, 255), 2, cv2.LINE_AA)
            cv2.putText(placeholder, f"get ready... {i}", (16, 110),
                        cv2.FONT_HERSHEY_DUPLEX, 1.4, (0, 255, 255), 2, cv2.LINE_AA)
            cv2.imshow(display_win, placeholder)
            cv2.waitKey(1000)
        else:
            time.sleep(1)
    print(f"\r{prefix}GO!       ")


def draw_hud(img, label, elapsed, duration, perclos_snap, blink_snap, pL, pR):
    """Top banner with pose label, timer, PERCLOS, p_open, blinks, status."""
    h, w = img.shape[:2]
    cv2.rectangle(img, (0, 0), (w, 64), (0, 0, 0), -1)

    perclos = perclos_snap["perclos"]
    status = perclos_snap["status"]
    blink_n = blink_snap["blink_count"]

    pL_s = f"{pL:.2f}" if pL is not None else " -- "
    pR_s = f"{pR:.2f}" if pR is not None else " -- "

    color_top = (0, 255, 0) if status == "normal" else (0, 165, 255) if status == "warming_up" else (0, 0, 255)
    line1 = f"POSE: {label}    t={elapsed:4.1f}/{duration}s"
    line2 = f"PERCLOS={perclos:.3f}  p_open=({pL_s},{pR_s})  BLINKS={blink_n}  {status}"
    cv2.putText(img, line1, (10, 24), cv2.FONT_HERSHEY_DUPLEX, 0.6, (240, 240, 240), 1, cv2.LINE_AA)
    cv2.putText(img, line2, (10, 52), cv2.FONT_HERSHEY_DUPLEX, 0.55, color_top, 1, cv2.LINE_AA)
    return img


def run_pose(pool, cap, label, duration, instruction,
             save_root=None, save_per_pose=80,
             display_win=None, display_every=2):
    print()
    print("=" * 72)
    print(f"姿态: {label}    ({duration}s)")
    print(f"指示: {instruction}")
    countdown(3, display_win=display_win, label=label)

    tracker = PerclosTracker()
    blink = BlinkTracker()

    # Optional: save eye patches into a per-pose subdir for visual forensics.
    saver = None
    if save_root:
        out_dir = os.path.join(save_root, label)
        saver = EyePatchSaver(out_dir, max_images=save_per_pose, min_interval_sec=0.20)
        print(f"  存图: {out_dir}  (最多 {save_per_pose} 张, ~5/s 采样)")

    n_frames = 0
    n_eyes = 0
    n_open_both = 0
    n_closed_both = 0
    n_squint_any = 0
    pL_sum = pR_sum = 0.0
    pL_min = pR_min = 1.0
    pL_max = pR_max = 0.0

    # Prime the worker pool with a few frames so .get() doesn't return empty.
    for _ in range(4):
        ret, frame = cap.read()
        if ret:
            pool.put(frame)

    start = time.time()
    last_print = start
    while True:
        now = time.time()
        elapsed = now - start
        if elapsed >= duration:
            break

        ret, frame = cap.read()
        if not ret:
            print("  摄像头读帧失败，提前结束")
            break
        pool.put(frame)

        pkg, ok = pool.get()
        if not ok:
            break
        frame_result, eye_state, _profile = pkg

        n_frames += 1
        pL = eye_state["p_left"]
        pR = eye_state["p_right"]
        probsL = eye_state.get("probs_left")
        probsR = eye_state.get("probs_right")

        if saver is not None and eye_state.get("patches") is not None:
            saver.maybe_save(eye_state["patches"])

        if pL is not None and pR is not None:
            n_eyes += 1
            pL_sum += pL
            pR_sum += pR
            pL_min = min(pL_min, pL); pL_max = max(pL_max, pL)
            pR_min = min(pR_min, pR); pR_max = max(pR_max, pR)
            if pL >= 0.5 and pR >= 0.5:
                n_open_both += 1
            if eye_state.get("label_left") == "squint" or eye_state.get("label_right") == "squint":
                n_squint_any += 1
            elif pL < 0.5 and pR < 0.5:
                n_closed_both += 1
            if probsL is not None and probsR is not None:
                tracker.update_probs(probsL, probsR)
            else:
                tracker.update(pL, pR)
            blink.update(pL, pR)
        else:
            tracker.update(None, None)
            blink.update(None, None)

        if now - last_print >= 1.0:
            ps = tracker.snapshot()
            bs = blink.snapshot()
            pL_s = f"{pL:.2f}" if pL is not None else " -- "
            pR_s = f"{pR:.2f}" if pR is not None else " -- "
            print(
                f"  t={elapsed:4.1f}s  "
                f"PERCLOS={ps['perclos']:.3f}  "
                f"p_open=({pL_s},{pR_s})  "
                f"BLINKS={bs['blink_count']}  "
                f"status={ps['status']}"
            )
            last_print = now

        if display_win is not None and n_frames % display_every == 0:
            ps_now = tracker.snapshot()
            bs_now = blink.snapshot()
            # frame_result already has face box + eye boxes drawn by myFunc_pipeline
            # because we set test_mod.DRAW_RESULTS = True when --display is on.
            hud_frame = draw_hud(frame_result, label, elapsed, duration,
                                 ps_now, bs_now, pL, pR)
            cv2.imshow(display_win, hud_frame)
            if cv2.waitKey(1) & 0xFF == ord("q"):
                print("\n  收到 q，跳过当前姿态。")
                break

    # --- per-pose summary ----------------------------------------------------
    eyes_seen = max(n_eyes, 1)
    pL_mean = pL_sum / eyes_seen
    pR_mean = pR_sum / eyes_seen
    summary = {
        "label": label,
        "frames": n_frames,
        "eye_rate": n_eyes / max(n_frames, 1),
        "pL_mean": pL_mean,
        "pR_mean": pR_mean,
        "pL_range": (pL_min, pL_max) if n_eyes else (0, 0),
        "pR_range": (pR_min, pR_max) if n_eyes else (0, 0),
        "frac_open": n_open_both / eyes_seen,
        "frac_closed": n_closed_both / eyes_seen,
        "frac_squint": n_squint_any / eyes_seen,
        "perclos": tracker.perclos(),
        "blink_count": len(blink.blink_events),
        "blink_rate": blink.blink_rate_per_min(),
    }

    print()
    print(f"  --- {label} 小结 ---")
    print(f"  人脸+眼检出率: {summary['eye_rate']*100:5.1f}%  ({n_eyes}/{n_frames} 帧)")
    if n_eyes > 0:
        print(f"  p_open 左眼:   均值={pL_mean:.2f}   范围=[{pL_min:.2f}, {pL_max:.2f}]")
        print(f"  p_open 右眼:   均值={pR_mean:.2f}   范围=[{pR_min:.2f}, {pR_max:.2f}]")
        print(f"  双眼都睁:      {summary['frac_open']*100:5.1f}%")
        print(f"  双眼都闭:      {summary['frac_closed']*100:5.1f}%")
        print(f"  任一眼眯眼:    {summary['frac_squint']*100:5.1f}%")
    print(f"  PERCLOS:       {summary['perclos']:.3f}")
    print(f"  眨眼:          {summary['blink_count']} 次  ({summary['blink_rate']:.1f}/min)")
    return summary


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--camera", default="/dev/video21")
    ap.add_argument("--camera-size", default="640x480")
    ap.add_argument("--camera-fps", type=int, default=30)
    ap.add_argument("--fourcc", default="MJPG")
    ap.add_argument("--model", default="./RetinaFace_mobile320.rknn")
    ap.add_argument("--eye-model", default="./eye_cnn.rknn")
    ap.add_argument("--skip", default="",
                    help="逗号分隔的要跳过的 pose 标签，例如 distance_1m,head_pitch_up")
    ap.add_argument("--save-by-pose", default="",
                    help="把每个姿态的眼睛 patch 存到该目录下的子文件夹，方便事后用眼睛检查")
    ap.add_argument("--save-per-pose", type=int, default=80,
                    help="每个姿态最多保存几张眼睛 patch (左右算两张)，默认 80")
    ap.add_argument("--display", action="store_true",
                    help="打开 OpenCV 实时预览窗口（带 HUD 显示当前姿态、PERCLOS 等）")
    ap.add_argument("--display-size", default="640x480",
                    help="预览窗口大小，例如 640x480")
    ap.add_argument("--display-every", type=int, default=2,
                    help="每 N 帧刷新一次预览，默认 2")
    args = ap.parse_args()

    # When --display is on we want the face/eye boxes drawn for us by
    # myFunc_pipeline (it copies the frame and draws RetinaFace + eye boxes).
    # Without --display we keep DRAW_RESULTS off to save CPU.
    test_mod.DRAW_RESULTS = bool(args.display)
    test_mod.PROFILE_ENABLED = False
    test_mod.MODEL_ONLY = False
    test_mod.FATIGUE_ENABLED = True
    test_mod.EYE_SAVER = None

    skip = {s.strip() for s in args.skip.split(",") if s.strip()}

    width, height = (int(x) for x in args.camera_size.lower().split("x"))
    cap = cv2.VideoCapture(args.camera, cv2.CAP_V4L2)
    if args.fourcc:
        cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*args.fourcc.upper()))
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    cap.set(cv2.CAP_PROP_FPS, args.camera_fps)
    if not cap.isOpened():
        sys.exit(f"无法打开 {args.camera}")

    print(f"摄像头: {args.camera}  {width}x{height}  fps={args.camera_fps}  fourcc={args.fourcc}")
    print(f"模型:   face={args.model}  eye={args.eye_model}")
    print(f"姿态序列 ({len(POSES)} 项):")
    for label, dur, instr in POSES:
        tag = " [跳过]" if label in skip else ""
        print(f"  - {label:22s} {dur:3d}s   {instr}{tag}")
    print()
    print("提示：每个姿态会自动倒计时 3 秒再开始，期间请进入到指定姿态。")
    print("      想中断按 Ctrl+C；想跳过整段姿态用 --skip 参数。")
    print()
    input("准备好了按回车开始...")

    pool = rknnPoolExecutor(
        face_model=args.model,
        eye_model=args.eye_model,
        TPEs=3,
        func=test_mod.myFunc_pipeline,
    )

    save_root = args.save_by_pose.strip() or None
    if save_root:
        os.makedirs(save_root, exist_ok=True)
        print(f"按姿态存图根目录: {save_root}")

    display_win = None
    if args.display:
        display_win = "Fatigue_Diagnose"
        try:
            dw, dh = (int(x) for x in args.display_size.lower().split("x"))
        except ValueError:
            dw, dh = 640, 480
        cv2.namedWindow(display_win, cv2.WINDOW_NORMAL)
        cv2.resizeWindow(display_win, dw, dh)
        print(f"实时预览窗口: {display_win}  ({dw}x{dh})  (姿态进行中按 q 可跳过本姿态)")

    results = []
    try:
        for label, duration, instruction in POSES:
            if label in skip:
                continue
            results.append(run_pose(
                pool, cap, label, duration, instruction,
                save_root=save_root, save_per_pose=args.save_per_pose,
                display_win=display_win, display_every=args.display_every,
            ))
    except KeyboardInterrupt:
        print("\n\n用户中断 (Ctrl+C)。已完成的姿态会出现在汇总表里。")

    # --- final cross-pose table ---------------------------------------------
    print()
    print("=" * 86)
    print("总览对比")
    print("=" * 86)
    print(f"{'姿态':<22} {'eyes%':>6} {'pL':>5} {'pR':>5} {'sq%':>5} {'PERCLOS':>8} {'rate':>7}  判定")
    print("-" * 86)
    for r in results:
        max_p, comment = expected(r["label"])
        if max_p is None:
            mark = "?"
        elif r["perclos"] <= max_p:
            mark = "OK"
        else:
            mark = "FAIL"
        print(
            f"{r['label']:<22} "
            f"{r['eye_rate']*100:>5.1f}% "
            f"{r['pL_mean']:>5.2f} "
            f"{r['pR_mean']:>5.2f} "
            f"{r['frac_squint']*100:>4.0f}% "
            f"{r['perclos']:>8.3f} "
            f"{r['blink_rate']:>6.1f}/m  "
            f"{mark:<4} {comment}"
        )

    cap.release()
    pool.release()
    if display_win is not None:
        cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
