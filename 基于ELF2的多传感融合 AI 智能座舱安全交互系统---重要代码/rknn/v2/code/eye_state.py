"""Shared eye-state class order and probability helpers."""

import numpy as np

CLASS_CLOSED = 0
CLASS_OPEN = 1
CLASS_SQUINT = 2
CLASS_NAMES = ("closed", "open", "squint")


def softmax_probs(logits):
    values = np.asarray(logits, dtype=np.float32).reshape(-1)
    if values.size != len(CLASS_NAMES):
        raise ValueError(f"expected {len(CLASS_NAMES)} logits, got {values.size}")
    exps = np.exp(values - np.max(values))
    return exps / np.sum(exps)


def label_from_probs(probs):
    values = np.asarray(probs, dtype=np.float32).reshape(-1)
    if values.size != len(CLASS_NAMES):
        raise ValueError(f"expected {len(CLASS_NAMES)} probabilities, got {values.size}")
    return CLASS_NAMES[int(np.argmax(values))]


def p_open_from_probs(probs):
    values = np.asarray(probs, dtype=np.float32).reshape(-1)
    if values.size != len(CLASS_NAMES):
        raise ValueError(f"expected {len(CLASS_NAMES)} probabilities, got {values.size}")
    return float(values[CLASS_OPEN])


def state_letter(label):
    if label == "open":
        return "O"
    if label == "closed":
        return "C"
    if label == "squint":
        return "S"
    return "?"
