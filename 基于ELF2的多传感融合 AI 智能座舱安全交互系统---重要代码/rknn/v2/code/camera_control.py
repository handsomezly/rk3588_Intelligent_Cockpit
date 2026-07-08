"""Local camera on/off control for the fatigue inference service."""

import json
import os
import socket


DEFAULT_CONTROL_SOCK = "/tmp/cockpit_fatigue_control.sock"


class CameraState:
    """Authoritative camera lifecycle state published to Qt."""

    def __init__(self):
        self.enabled = False
        self.requested = False
        self.state = "off"
        self.error = ""

    def request(self, enabled):
        self.requested = bool(enabled)

    def metrics(self):
        return {
            "camera_enabled": self.enabled,
            "camera_state": self.state,
            "camera_error": self.error,
        }


class CameraLifecycle:
    """Synchronously reconciles a requested state with one camera session."""

    def __init__(self, open_session, close_session):
        self._open_session = open_session
        self._close_session = close_session
        self.state = CameraState()
        self.resource = None

    def request(self, enabled):
        enabled = bool(enabled)
        if not enabled and not self.state.enabled and self.state.state == "error":
            self.state.error = ""
            self.state.state = "off"
        self.state.request(enabled)
        self.reconcile()

    def reconcile(self):
        if self.state.requested:
            if self.state.enabled:
                return
            self.state.state = "starting"
            self.state.error = ""
            try:
                self.resource = self._open_session()
            except Exception as exc:
                self.resource = None
                self.state.enabled = False
                self.state.requested = False
                self.state.state = "error"
                self.state.error = str(exc)
                return
            self.state.enabled = True
            self.state.state = "running"
            return

        if not self.state.enabled:
            return
        self.state.state = "stopping"
        try:
            self._close_session(self.resource)
        except Exception as exc:
            self.state.error = str(exc)
            self.state.state = "error"
        else:
            self.state.error = ""
            self.state.state = "off"
        finally:
            self.resource = None
            self.state.enabled = False

    def fail(self, error):
        """Close an active session and retain a terminal error for the UI."""
        close_error = ""
        if self.resource is not None:
            try:
                self._close_session(self.resource)
            except Exception as exc:
                close_error = str(exc)
        self.resource = None
        self.state.enabled = False
        self.state.requested = False
        self.state.state = "error"
        self.state.error = str(error)
        if close_error:
            self.state.error += "; " + close_error


class CameraControlServer:
    """Nonblocking AF_UNIX datagram receiver with last-command-wins semantics."""

    def __init__(self, path=DEFAULT_CONTROL_SOCK):
        self.path = path
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self._sock.bind(path)
        self._sock.setblocking(False)
        self._closed = False

    def poll(self):
        latest = None
        while True:
            try:
                payload = self._sock.recv(4096)
            except (BlockingIOError, InterruptedError):
                break
            except OSError:
                if self._closed:
                    break
                raise

            try:
                command = json.loads(payload.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            if not isinstance(command, dict):
                continue
            if command.get("command") != "set_camera":
                continue
            enabled = command.get("enabled")
            if not isinstance(enabled, bool):
                continue
            latest = enabled
        return latest

    def close(self):
        if self._closed:
            return
        self._closed = True
        self._sock.close()
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass
