import unittest

from imu_motion import MotionDecision, MotionGate, apply_alarm_gate


class MotionGateTests(unittest.TestCase):
    def test_missing_or_stale_imu_is_neutral_not_a_blind_spot(self):
        gate = MotionGate(stale_after_s=0.5)

        missing = gate.decide(None, now=10.0)
        stale = gate.decide(
            {"received_at": 9.0, "available": True, "calibrated": True,
             "vision_confidence": 0.1},
            now=10.0,
        )

        self.assertTrue(missing.allow_observation)
        self.assertTrue(missing.allow_new_alarm)
        self.assertTrue(stale.allow_observation)
        self.assertTrue(stale.allow_new_alarm)
        self.assertEqual("imu_stale", stale.reason)

    def test_violent_motion_suppression_has_two_second_safety_cap(self):
        gate = MotionGate(low_confidence=0.55, max_suppression_s=2.0)
        context = {
            "received_at": 0.0, "available": True, "calibrated": True,
            "vision_confidence": 0.25,
        }

        start = gate.decide(context, now=0.0)
        context["received_at"] = 1.0
        during = gate.decide(context, now=1.0)
        context["received_at"] = 2.1
        capped = gate.decide(context, now=2.1)

        self.assertFalse(start.allow_observation)
        self.assertFalse(during.allow_new_alarm)
        self.assertTrue(capped.allow_observation)
        self.assertTrue(capped.allow_new_alarm)
        self.assertEqual("suppression_cap", capped.reason)

    def test_new_alarm_waits_for_stable_motion_confirmation(self):
        gate = MotionGate(stable_confirm_s=1.5)
        unstable = {
            "received_at": 0.0, "available": True, "calibrated": True,
            "vision_confidence": 0.2,
        }
        stable = {
            "received_at": 0.4, "available": True, "calibrated": True,
            "vision_confidence": 0.95,
        }

        gate.decide(unstable, now=0.0)
        recovering = gate.decide(stable, now=0.4)
        stable["received_at"] = 2.0
        confirmed = gate.decide(stable, now=2.0)

        self.assertTrue(recovering.allow_observation)
        self.assertFalse(recovering.allow_new_alarm)
        self.assertTrue(confirmed.allow_new_alarm)

    def test_suppression_never_clears_an_existing_alarm(self):
        suppressed = MotionDecision(False, False, True, "vehicle_shaking", 0.2)

        self.assertTrue(apply_alarm_gate(False, True, suppressed))
        self.assertFalse(apply_alarm_gate(True, False, suppressed))
        self.assertTrue(apply_alarm_gate(True, False,
                                        MotionDecision(True, True, False, "stable", 1.0)))

    def test_metrics_expose_motion_fusion_state(self):
        from fatigue_service import build_metrics

        decision = MotionDecision(False, False, True, "vehicle_shaking", 0.25)
        metrics = build_metrics(
            1, 25.0, {},
            {"status": "normal", "perclos": 0.1, "valid_count": 20,
             "window_len": 30},
            {"rate_per_min": 10.0, "mean_dur_ms": None,
             "long_blink_count": 0},
            False, None, 640, 480,
            motion_decision=decision,
            motion_context={"motion_state": "likely_moving"},
        )

        self.assertTrue(metrics["motion_gated"])
        self.assertEqual("vehicle_shaking", metrics["motion_gate_reason"])
        self.assertEqual(0.25, metrics["vision_confidence"])
        self.assertEqual("likely_moving", metrics["vehicle_motion_state"])
        self.assertTrue(metrics["camera_enabled"])
        self.assertEqual("running", metrics["camera_state"])
        self.assertEqual("", metrics["camera_error"])

    def test_idle_metrics_clear_stale_fatigue_and_publish_camera_state(self):
        from camera_control import CameraState
        from fatigue_service import build_idle_metrics

        state = CameraState()
        metrics = build_idle_metrics(state)

        self.assertEqual("camera_off", metrics["status"])
        self.assertFalse(metrics["fatigue_alarm"])
        self.assertEqual(0.0, metrics["perclos"])
        self.assertFalse(metrics["face_found"])
        self.assertFalse(metrics["camera_enabled"])
        self.assertEqual("off", metrics["camera_state"])


if __name__ == "__main__":
    unittest.main()
