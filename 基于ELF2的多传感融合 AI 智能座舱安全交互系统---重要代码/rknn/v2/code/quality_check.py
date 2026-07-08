"""Objective quality checks for 32x32 eye patches.

This module has no RKNN dependency so it can run on both the board and PC.
It is intentionally conservative: hard rejects are reserved for samples that
are very likely to hurt training.
"""

from dataclasses import dataclass

import cv2
import numpy as np


@dataclass(frozen=True)
class QualityProfile:
    min_face_score: float = 0.70
    min_face_height: float = 80.0
    min_eye_distance: float = 24.0
    crop_border_margin: int = 1
    min_brightness: float = 15.0
    max_brightness: float = 240.0
    min_contrast: float = 8.0
    min_sharpness: float = 5.0
    max_saturated_fraction: float = 0.95
    warn_roll_angle: float = 25.0
    warn_brightness_margin: float = 10.0
    warn_contrast: float = 14.0
    warn_side_mean_delta: float = 35.0


PROFILES = {
    "relaxed": QualityProfile(
        min_face_score=0.60,
        min_face_height=65.0,
        min_eye_distance=18.0,
        min_brightness=10.0,
        max_brightness=248.0,
        min_contrast=5.0,
        min_sharpness=2.0,
    ),
    "normal": QualityProfile(),
    "strict": QualityProfile(
        min_face_score=0.80,
        min_face_height=95.0,
        min_eye_distance=30.0,
        min_brightness=25.0,
        max_brightness=230.0,
        min_contrast=12.0,
        min_sharpness=10.0,
    ),
}


@dataclass(frozen=True)
class QualityResult:
    ok: bool
    score: float
    warnings: list
    rejects: list
    metrics: dict


def get_quality_profile(profile="normal"):
    if isinstance(profile, QualityProfile):
        return profile
    try:
        return PROFILES[profile]
    except KeyError as exc:
        names = ", ".join(sorted(PROFILES))
        raise ValueError(f"unknown quality profile {profile!r}; expected one of: {names}") from exc


def _add_unique(items, reason):
    if reason not in items:
        items.append(reason)


def _as_gray_patch(patch):
    arr = np.asarray(patch)
    if arr.ndim == 3:
        arr = cv2.cvtColor(arr, cv2.COLOR_BGR2GRAY)
    if arr.shape != (32, 32):
        arr = cv2.resize(arr, (32, 32), interpolation=cv2.INTER_AREA)
    return arr.astype(np.uint8, copy=False)


def patch_quality_metrics(patch):
    gray = _as_gray_patch(patch)
    lap = cv2.Laplacian(gray, cv2.CV_32F)
    saturated = np.logical_or(gray <= 2, gray >= 253)
    return {
        "brightness": float(np.mean(gray)),
        "contrast": float(np.std(gray)),
        "sharpness": float(np.var(lap)),
        "min": float(np.min(gray)),
        "max": float(np.max(gray)),
        "saturated_fraction": float(np.mean(saturated)),
    }


def _frame_size(frame_shape):
    if frame_shape is None:
        return None
    if len(frame_shape) < 2:
        raise ValueError("frame_shape must contain at least height and width")
    return int(frame_shape[1]), int(frame_shape[0])


def _is_clipped(box, frame_shape, margin):
    size = _frame_size(frame_shape)
    if size is None or box is None:
        return False
    frame_w, frame_h = size
    x1, y1, x2, y2 = [int(round(v)) for v in box]
    return (
        x1 <= margin
        or y1 <= margin
        or x2 >= frame_w - 1 - margin
        or y2 >= frame_h - 1 - margin
    )


def _check_patch(side, patch, profile, rejects, warnings, metrics):
    pm = patch_quality_metrics(patch)
    for key, value in pm.items():
        metrics[f"{side}_{key}"] = value

    if pm["brightness"] < profile.min_brightness:
        _add_unique(rejects, "too_dark")
    if pm["brightness"] > profile.max_brightness:
        _add_unique(rejects, "too_bright")
    if pm["contrast"] < profile.min_contrast:
        _add_unique(rejects, "low_contrast")
    if pm["sharpness"] < profile.min_sharpness:
        _add_unique(rejects, "low_sharpness")
    if pm["saturated_fraction"] > profile.max_saturated_fraction:
        _add_unique(rejects, "saturated_patch")

    if pm["brightness"] < profile.min_brightness + profile.warn_brightness_margin:
        _add_unique(warnings, "near_dark")
    if pm["brightness"] > profile.max_brightness - profile.warn_brightness_margin:
        _add_unique(warnings, "near_bright")
    if pm["contrast"] < profile.warn_contrast:
        _add_unique(warnings, "low_contrast_margin")


def evaluate_eye_patches(patches, frame_shape=None, profile="normal"):
    """Evaluate a left/right eye patch pair.

    Args:
        patches: dict returned by eye_crop.crop_eye_patches.
        frame_shape: optional original frame shape, used to detect clipped crop
            boxes. Accepts OpenCV-style (height, width[, channels]).
        profile: "relaxed", "normal", "strict", or a QualityProfile instance.

    Returns:
        QualityResult with stable reason strings suitable for counters/CSV.
    """
    profile = get_quality_profile(profile)
    rejects = []
    warnings = []
    metrics = {}

    score = float(patches.get("score", 0.0))
    face_height = float(patches.get("box_h", 0.0))
    eye_distance = float(patches.get("eye_distance", 0.0))
    roll_angle = float(patches.get("roll_angle_deg", 0.0))
    metrics.update(
        {
            "face_score": score,
            "face_height": face_height,
            "eye_distance": eye_distance,
            "roll_angle_deg": roll_angle,
        }
    )

    if score < profile.min_face_score:
        _add_unique(rejects, "low_face_score")
    if face_height < profile.min_face_height:
        _add_unique(rejects, "small_face")
    if eye_distance < profile.min_eye_distance:
        _add_unique(rejects, "small_eye_distance")
    if abs(roll_angle) > profile.warn_roll_angle:
        _add_unique(warnings, "large_roll_angle")

    for side in ("left", "right"):
        if side not in patches:
            _add_unique(rejects, f"missing_{side}_patch")
            continue
        _check_patch(side, patches[side], profile, rejects, warnings, metrics)
        if _is_clipped(patches.get(f"{side}_box"), frame_shape, profile.crop_border_margin):
            _add_unique(rejects, "clipped_crop")

    if "left_brightness" in metrics and "right_brightness" in metrics:
        delta = abs(metrics["left_brightness"] - metrics["right_brightness"])
        metrics["side_brightness_delta"] = float(delta)
        if delta > profile.warn_side_mean_delta:
            _add_unique(warnings, "side_brightness_mismatch")

    penalty = len(rejects) * 0.25 + len(warnings) * 0.05
    score_out = max(0.0, min(1.0, 1.0 - penalty))
    return QualityResult(
        ok=not rejects,
        score=score_out,
        warnings=warnings,
        rejects=rejects,
        metrics=metrics,
    )
