import json
import os
import socket
import tempfile
import unittest


class CameraControlServerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "camera-control.sock")
        self.client = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)

    def tearDown(self):
        self.client.close()
        self.tmp.cleanup()

    def test_valid_command_is_received_once(self):
        from camera_control import CameraControlServer

        server = CameraControlServer(self.path)
        try:
            self.client.sendto(
                json.dumps({"command": "set_camera", "enabled": True}).encode("utf-8"),
                self.path,
            )

            self.assertIs(True, server.poll())
            self.assertIsNone(server.poll())
        finally:
            server.close()

    def test_poll_drains_queue_and_returns_latest_valid_command(self):
        from camera_control import CameraControlServer

        server = CameraControlServer(self.path)
        try:
            self.client.sendto(b'{"command":"set_camera","enabled":true}', self.path)
            self.client.sendto(b'{"command":"set_camera","enabled":false}', self.path)

            self.assertIs(False, server.poll())
            self.assertIsNone(server.poll())
        finally:
            server.close()

    def test_invalid_datagrams_are_ignored(self):
        from camera_control import CameraControlServer

        server = CameraControlServer(self.path)
        try:
            invalid = (
                b"not-json",
                b'{"command":"unknown","enabled":true}',
                b'{"command":"set_camera","enabled":1}',
            )
            for payload in invalid:
                self.client.sendto(payload, self.path)

            self.assertIsNone(server.poll())
        finally:
            server.close()

    def test_close_removes_socket_file(self):
        from camera_control import CameraControlServer

        server = CameraControlServer(self.path)
        self.assertTrue(os.path.exists(self.path))

        server.close()

        self.assertFalse(os.path.exists(self.path))


class CameraStateTests(unittest.TestCase):
    def test_initial_state_is_camera_off(self):
        from camera_control import CameraState

        state = CameraState()

        self.assertFalse(state.enabled)
        self.assertFalse(state.requested)
        self.assertEqual("off", state.state)
        self.assertEqual("", state.error)
        self.assertEqual(
            {
                "camera_enabled": False,
                "camera_state": "off",
                "camera_error": "",
            },
            state.metrics(),
        )

    def test_request_is_idempotent_and_boolean(self):
        from camera_control import CameraState

        state = CameraState()
        state.request(True)
        state.request(True)
        self.assertTrue(state.requested)

        state.request(False)
        state.request(False)
        self.assertFalse(state.requested)


class CameraLifecycleTests(unittest.TestCase):
    def test_default_state_does_not_open_camera(self):
        from camera_control import CameraLifecycle

        opens = []
        lifecycle = CameraLifecycle(lambda: opens.append("open") or object(), lambda _: None)

        lifecycle.reconcile()

        self.assertEqual([], opens)
        self.assertEqual("off", lifecycle.state.state)

    def test_enable_and_disable_are_idempotent(self):
        from camera_control import CameraLifecycle

        resource = object()
        opens = []
        closes = []
        lifecycle = CameraLifecycle(
            lambda: opens.append("open") or resource,
            lambda current: closes.append(current),
        )

        lifecycle.request(True)
        lifecycle.request(True)
        self.assertEqual(["open"], opens)
        self.assertTrue(lifecycle.state.enabled)
        self.assertEqual("running", lifecycle.state.state)

        lifecycle.request(False)
        lifecycle.request(False)
        self.assertEqual([resource], closes)
        self.assertFalse(lifecycle.state.enabled)
        self.assertEqual("off", lifecycle.state.state)

    def test_open_failure_is_reported_without_leaking_enabled_state(self):
        from camera_control import CameraLifecycle

        def fail_open():
            raise RuntimeError("camera busy")

        lifecycle = CameraLifecycle(fail_open, lambda _: None)

        lifecycle.request(True)

        self.assertFalse(lifecycle.state.enabled)
        self.assertFalse(lifecycle.state.requested)
        self.assertEqual("error", lifecycle.state.state)
        self.assertEqual("camera busy", lifecycle.state.error)

    def test_each_reenable_creates_a_fresh_session(self):
        from camera_control import CameraLifecycle

        sessions = []

        def open_session():
            session = object()
            sessions.append(session)
            return session

        lifecycle = CameraLifecycle(open_session, lambda _: None)
        lifecycle.request(True)
        lifecycle.request(False)
        lifecycle.request(True)

        self.assertEqual(2, len(sessions))
        self.assertIs(sessions[-1], lifecycle.resource)

    def test_runtime_failure_closes_session_and_exposes_error(self):
        from camera_control import CameraLifecycle

        resource = object()
        closes = []
        lifecycle = CameraLifecycle(lambda: resource, lambda value: closes.append(value))
        lifecycle.request(True)

        lifecycle.fail("camera read failed")

        self.assertEqual([resource], closes)
        self.assertIsNone(lifecycle.resource)
        self.assertFalse(lifecycle.state.enabled)
        self.assertFalse(lifecycle.state.requested)
        self.assertEqual("error", lifecycle.state.state)
        self.assertEqual("camera read failed", lifecycle.state.error)


if __name__ == "__main__":
    unittest.main()
