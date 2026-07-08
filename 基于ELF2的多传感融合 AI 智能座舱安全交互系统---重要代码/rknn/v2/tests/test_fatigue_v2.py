import os
import csv
import tempfile
import unittest
import subprocess
import sys

import cv2
import numpy as np


def _write_eye(path, value=128):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img = np.full((32, 32), value, dtype=np.uint8)
    cv2.imwrite(path, img)


class EyeCropMetadataTests(unittest.TestCase):
    def test_crop_eye_patches_reports_geometry_metadata(self):
        from eye_crop import crop_eye_patches

        frame = np.full((160, 220, 3), 127, dtype=np.uint8)
        det = np.array(
            [
                60,
                40,
                160,
                140,
                0.95,
                90,
                82,
                130,
                86,
                110,
                105,
                92,
                125,
                130,
                128,
            ],
            dtype=np.float32,
        )

        patches = crop_eye_patches(frame, det)

        self.assertIsNotNone(patches)
        self.assertEqual((32, 32), patches["left"].shape)
        self.assertEqual((32, 32), patches["right"].shape)
        self.assertAlmostEqual(40.1995, patches["eye_distance"], places=3)
        self.assertAlmostEqual(5.7106, patches["roll_angle_deg"], places=3)
        self.assertEqual((90.0, 82.0), patches["left_center"])
        self.assertEqual((130.0, 86.0), patches["right_center"])
        self.assertEqual((60.0, 40.0, 160.0, 140.0), patches["face_box"])


class PerclosTrinaryTests(unittest.TestCase):
    def test_squint_probability_does_not_count_as_closed_perclos(self):
        from perclos import PerclosTracker, STATE_CLOSED, STATE_SQUINT

        tracker = PerclosTracker(window_frames=4, min_valid_frames=1)

        tracker.update_probs([0.05, 0.05, 0.90], [0.05, 0.05, 0.90])
        tracker.update_probs([0.05, 0.05, 0.90], [0.05, 0.05, 0.90])
        self.assertEqual(STATE_SQUINT, tracker.snapshot()["last_eye_state"])
        self.assertEqual(0, tracker.snapshot()["closed_count"])
        self.assertEqual(2, tracker.snapshot()["squint_count"])
        self.assertEqual(0.0, tracker.perclos())

        tracker.update_probs([0.80, 0.10, 0.10], [0.80, 0.10, 0.10])
        self.assertEqual(STATE_CLOSED, tracker.snapshot()["last_eye_state"])
        self.assertEqual(1, tracker.snapshot()["closed_count"])
        self.assertEqual(1 / 3, tracker.perclos())


class EyeStateHelperTests(unittest.TestCase):
    def test_softmax_and_label_mapping_use_project_class_order(self):
        import eye_state

        probs = eye_state.softmax_probs(np.array([0.0, 3.0, 1.0], dtype=np.float32))

        self.assertEqual(0, eye_state.CLASS_CLOSED)
        self.assertEqual(1, eye_state.CLASS_OPEN)
        self.assertEqual(2, eye_state.CLASS_SQUINT)
        self.assertEqual(("closed", "open", "squint"), eye_state.CLASS_NAMES)
        self.assertAlmostEqual(1.0, float(probs.sum()), places=6)
        self.assertEqual("open", eye_state.label_from_probs(probs))
        self.assertAlmostEqual(float(probs[eye_state.CLASS_OPEN]), eye_state.p_open_from_probs(probs))


class TrainDataSplitTests(unittest.TestCase):
    def test_explicit_split_loader_keeps_train_and_val_separate(self):
        import train_eye_cnn

        with tempfile.TemporaryDirectory() as tmp:
            _write_eye(os.path.join(tmp, "train", "open", "front", "eye_L_20260510_100000_000.png"), 200)
            _write_eye(os.path.join(tmp, "train", "closed", "front_closed", "eye_L_20260510_100100_000.png"), 20)
            _write_eye(os.path.join(tmp, "train", "squint", "front_squint", "eye_L_20260510_100200_000.png"), 90)
            _write_eye(os.path.join(tmp, "val", "open", "left", "eye_L_20260510_101000_000.png"), 205)
            _write_eye(os.path.join(tmp, "val", "closed", "left_closed", "eye_L_20260510_101100_000.png"), 25)
            _write_eye(os.path.join(tmp, "val", "squint", "left_squint", "eye_L_20260510_101200_000.png"), 95)

            self.assertTrue(train_eye_cnn.has_explicit_split(tmp))
            train_pairs, val_pairs = train_eye_cnn.load_dataset_splits(tmp, seed=7)

            self.assertEqual(3, len(train_pairs))
            self.assertEqual(3, len(val_pairs))
            self.assertEqual(
                {train_eye_cnn.CLASS_CLOSED, train_eye_cnn.CLASS_OPEN, train_eye_cnn.CLASS_SQUINT},
                {label for _, label in train_pairs + val_pairs},
            )
            self.assertTrue(all(os.sep + "train" + os.sep in path for path, _ in train_pairs))
            self.assertTrue(all(os.sep + "val" + os.sep in path for path, _ in val_pairs))

    def test_train_help_does_not_require_torch(self):
        result = subprocess.run(
            [sys.executable, "train_eye_cnn.py", "--help"],
            cwd=os.getcwd(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("--data", result.stdout)


class DatasetAuditTests(unittest.TestCase):
    def test_audit_detects_same_frame_stamp_in_train_and_val(self):
        import audit_eye_dataset

        with tempfile.TemporaryDirectory() as tmp:
            stamp = "20260510_100000_123"
            _write_eye(os.path.join(tmp, "train", "open", "front", f"eye_L_{stamp}.png"), 200)
            _write_eye(os.path.join(tmp, "val", "open", "front", f"eye_R_{stamp}.png"), 200)

            records = audit_eye_dataset.scan_dataset(tmp)
            leaks = audit_eye_dataset.detect_split_leakage(records)

            self.assertEqual(2, len(records))
            self.assertEqual([("open", "front", stamp)], leaks)

    def test_audit_scans_legacy_unsplit_layout(self):
        import audit_eye_dataset

        with tempfile.TemporaryDirectory() as tmp:
            _write_eye(os.path.join(tmp, "open", "front", "eye_L_20260510_100000_123.png"), 200)
            _write_eye(os.path.join(tmp, "closed", "squint", "eye_R_20260510_100100_123.png"), 90)

            records = audit_eye_dataset.scan_dataset(tmp)

            self.assertEqual(2, len(records))
            self.assertEqual({"unsplit"}, {record["split"] for record in records})
            self.assertEqual({"open", "squint"}, {record["label"] for record in records})


class CollectDatasetWriterTests(unittest.TestCase):
    def test_writer_saves_v2_layout_and_metadata_rows(self):
        from collect_dataset import EyePatchDatasetWriter

        patches = {
            "left": np.full((32, 32), 200, dtype=np.uint8),
            "right": np.full((32, 32), 201, dtype=np.uint8),
            "left_box": (1, 2, 33, 34),
            "right_box": (40, 2, 72, 34),
            "score": 0.95,
            "box_h": 100.0,
            "eye_distance": 40.0,
            "roll_angle_deg": 3.5,
            "left_center": (17.0, 18.0),
            "right_center": (56.0, 18.0),
            "face_box": (10.0, 20.0, 110.0, 120.0),
        }

        with tempfile.TemporaryDirectory() as tmp:
            writer = EyePatchDatasetWriter(
                tmp,
                split="val",
                label="squint",
                session="front_squint",
                max_images=2,
                min_interval_sec=0.0,
            )

            self.assertEqual(2, writer.maybe_save(patches))

            out_dir = os.path.join(tmp, "val", "squint", "front_squint")
            files = sorted(name for name in os.listdir(out_dir) if name.endswith(".png"))
            self.assertEqual(2, len(files))
            self.assertTrue(files[0].startswith("eye_L_"))
            self.assertTrue(files[1].startswith("eye_R_"))

            with open(os.path.join(tmp, "metadata.csv"), newline="", encoding="utf-8") as f:
                rows = list(csv.DictReader(f))
            self.assertEqual(2, len(rows))
            self.assertEqual({"left", "right"}, {row["side"] for row in rows})
            self.assertEqual({"val"}, {row["split"] for row in rows})
            self.assertEqual({"squint"}, {row["label"] for row in rows})
            self.assertEqual({"front_squint"}, {row["session"] for row in rows})
            self.assertTrue(all(row["relative_path"].startswith("val/squint/front_squint/") for row in rows))
            self.assertEqual({"40.000000"}, {row["eye_distance"] for row in rows})



class QualityCheckTests(unittest.TestCase):
    def _good_patches(self):
        img = np.full((32, 32), 120, dtype=np.uint8)
        cv2.circle(img, (16, 16), 7, 55, -1)
        cv2.line(img, (4, 14), (28, 14), 210, 1)
        cv2.line(img, (5, 20), (27, 20), 180, 1)
        return {
            "left": img,
            "right": cv2.flip(img, 1),
            "left_box": (20, 30, 52, 62),
            "right_box": (72, 30, 104, 62),
            "score": 0.95,
            "box_h": 110.0,
            "eye_distance": 52.0,
            "roll_angle_deg": 4.0,
        }

    def test_quality_check_accepts_textured_eye_pair(self):
        from quality_check import evaluate_eye_patches

        result = evaluate_eye_patches(self._good_patches(), frame_shape=(160, 200))

        self.assertTrue(result.ok, result.rejects)
        self.assertEqual([], result.rejects)
        self.assertGreater(result.metrics["left_sharpness"], 0.0)
        self.assertGreater(result.metrics["left_contrast"], 10.0)

    def test_quality_check_rejects_dark_blank_pair(self):
        from quality_check import evaluate_eye_patches

        patches = self._good_patches()
        patches["left"] = np.full((32, 32), 5, dtype=np.uint8)
        patches["right"] = np.full((32, 32), 5, dtype=np.uint8)

        result = evaluate_eye_patches(patches, frame_shape=(160, 200))

        self.assertFalse(result.ok)
        self.assertIn("too_dark", result.rejects)
        self.assertIn("low_contrast", result.rejects)
        self.assertIn("low_sharpness", result.rejects)

    def test_quality_check_rejects_bad_geometry(self):
        from quality_check import evaluate_eye_patches

        patches = self._good_patches()
        patches["score"] = 0.40
        patches["box_h"] = 40.0
        patches["eye_distance"] = 10.0
        patches["left_box"] = (0, 2, 20, 34)

        result = evaluate_eye_patches(patches, frame_shape=(160, 200))

        self.assertFalse(result.ok)
        self.assertIn("low_face_score", result.rejects)
        self.assertIn("small_face", result.rejects)
        self.assertIn("small_eye_distance", result.rejects)
        self.assertIn("clipped_crop", result.rejects)
    def test_collection_quality_gate_rejects_bad_patch(self):
        from collect_dataset import CollectionQualityGate

        gate = CollectionQualityGate(enabled=True, profile="normal")
        patches = self._good_patches()
        patches["left"] = np.full((32, 32), 5, dtype=np.uint8)
        patches["right"] = np.full((32, 32), 5, dtype=np.uint8)

        accepted, result = gate.check(patches, frame_shape=(160, 200, 3))

        self.assertFalse(accepted)
        self.assertFalse(result.ok)
        self.assertEqual(1, gate.total)
        self.assertEqual(0, gate.accepted)
        self.assertEqual(1, gate.rejected)
        self.assertEqual(1, gate.reject_counts["too_dark"])

    def test_collection_quality_gate_can_be_disabled(self):
        from collect_dataset import CollectionQualityGate

        gate = CollectionQualityGate(enabled=False)
        patches = self._good_patches()
        patches["left"] = np.full((32, 32), 5, dtype=np.uint8)
        patches["right"] = np.full((32, 32), 5, dtype=np.uint8)

        accepted, result = gate.check(patches, frame_shape=(160, 200, 3))

        self.assertTrue(accepted)
        self.assertIsNone(result)
        self.assertEqual(1, gate.total)
        self.assertEqual(1, gate.accepted)
        self.assertEqual(0, gate.rejected)

if __name__ == "__main__":
    unittest.main()



