import unittest

from protocol import ProtocolError, encode_server_message, parse_local_event


class ProtocolTests(unittest.TestCase):
    def test_accepts_supported_event(self):
        event = parse_local_event(
            b'{"version":1,"type":"trip_started","ts":1751331600000}')
        self.assertEqual("trip_started", event["type"])

        alert = parse_local_event({
            "version": 1, "type": "alert", "ts": 1751331600001,
            "alertType": "fatigue", "level": "warning",
            "title": "检测到疲劳风险", "summary": "状态持续监测中",
        })
        self.assertEqual("fatigue", alert["alertType"])

    def test_rejects_invalid_json_version_and_type(self):
        for payload in (
            b'not-json',
            b'{"version":2,"type":"trip_started","ts":1}',
            b'{"version":1,"type":"unknown","ts":1}',
            b'{"version":1,"type":"alert"}',
            b'{"version":1,"type":"trip_started","ts":true}',
            b'{"version":1,"type":"trip_started","ts":NaN}',
            b'{"version":1,"type":"alert","ts":1}',
        ):
            with self.subTest(payload=payload):
                with self.assertRaises(ProtocolError):
                    parse_local_event(payload)

    def test_encodes_compact_utf8_websocket_message(self):
        encoded = encode_server_message({
            "version": 1, "type": "heartbeat", "ts": 1,
            "deviceId": "ELF2-001", "state": "守护中",
        })
        self.assertIn('"state":"守护中"', encoded)
        self.assertNotIn(" ", encoded)
        with self.assertRaises(ProtocolError):
            encode_server_message({"version": 2, "type": "heartbeat"})


if __name__ == "__main__":
    unittest.main()
