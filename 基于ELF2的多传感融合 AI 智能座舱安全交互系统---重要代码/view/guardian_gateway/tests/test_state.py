import unittest

from state import GuardianState


class GuardianStateTests(unittest.TestCase):
    def setUp(self):
        self.now = 1751331600000
        self.state = GuardianState("ELF2-001", clock_ms=lambda: self.now)

    def event(self, event_type, **extra):
        payload = {"version": 1, "type": event_type, "ts": self.now}
        payload.update(extra)
        return payload

    def test_trip_lifecycle_builds_timeline_and_summary(self):
        started = self.state.apply(self.event("trip_started"))
        self.assertEqual("trip_started", started[0]["type"])
        self.assertEqual("guarding", self.state.state)

        self.now += 1000
        alert = self.state.apply(self.event(
            "alert", alertType="fatigue", level="warning",
            title="检测到疲劳风险", summary="状态持续监测中"))
        self.assertEqual("warning", self.state.state)
        self.assertEqual(1, alert[0]["alertCount"])

        self.now += 1000
        recovered = self.state.apply(self.event(
            "recovered", alertType="fatigue", title="状态已恢复",
            summary="驾驶状态恢复平稳"))
        self.assertEqual("recovered", self.state.state)
        self.assertEqual("recovered", recovered[0]["type"])

        self.now += 1000
        ended = self.state.apply(self.event("trip_ended"))
        self.assertEqual("arrived", self.state.state)
        self.assertEqual("途中出现 1 次提醒，状态已恢复，最终平安到达。",
                         ended[0]["summary"])
        self.assertEqual(3, ended[0]["durationSec"])

    def test_duplicate_edges_are_ignored(self):
        self.assertEqual(1, len(self.state.apply(self.event("trip_started"))))
        self.assertEqual([], self.state.apply(self.event("trip_started")))
        self.assertEqual(1, len(self.state.apply(self.event("trip_ended"))))
        self.assertEqual([], self.state.apply(self.event("trip_ended")))

    def test_alert_without_start_creates_a_trip(self):
        messages = self.state.apply(self.event(
            "alert", alertType="suspected_impact", level="danger",
            title="疑似强冲击", summary="请及时确认驾驶员状态"))
        self.assertEqual(["trip_started", "alert"], [m["type"] for m in messages])
        self.assertEqual("warning", self.state.state)

    def test_snapshot_contains_current_trip_and_timeline(self):
        self.state.apply(self.event("trip_started"))
        snapshot = self.state.snapshot()
        self.assertEqual("snapshot", snapshot["type"])
        self.assertEqual("guarding", snapshot["state"])
        self.assertEqual(1, len(snapshot["trip"]["timeline"]))
        self.assertEqual(0, snapshot["trip"]["alertCount"])
        self.assertEqual(snapshot["trip"]["timeline"], snapshot["timeline"])
        self.assertEqual(0, snapshot["alertCount"])

    def test_trip_ids_remain_unique_for_fast_restarts(self):
        first = self.state.apply(self.event("trip_started"))[0]["tripId"]
        self.state.apply(self.event("trip_ended"))
        second = self.state.apply(self.event("trip_started"))[0]["tripId"]
        self.assertNotEqual(first, second)
        self.assertRegex(first, r"^trip-\d{8}-001$")
        self.assertRegex(second, r"^trip-\d{8}-002$")

    def test_zero_alert_trip_uses_calm_summary(self):
        self.state.apply(self.event("trip_started"))
        ended = self.state.apply(self.event("trip_ended"))[0]
        self.assertEqual("本次行程平稳，最终平安到达。", ended["summary"])


if __name__ == "__main__":
    unittest.main()
