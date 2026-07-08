from __future__ import annotations

import datetime as _dt
import time


class GuardianState:
    def __init__(self, device_id="ELF2-001", clock_ms=None):
        self.device_id = device_id
        self._clock_ms = clock_ms or (lambda: int(time.time() * 1000))
        self._sequence = 0
        self._trip_sequence = 0
        self.state = "idle"
        self.trip = None
        self.last_heartbeat_ms = self._clock_ms()

    def _next_trip_id(self, ts):
        self._trip_sequence += 1
        stamp = _dt.datetime.fromtimestamp(ts / 1000).strftime("%Y%m%d")
        return f"trip-{stamp}-{self._trip_sequence:03d}"

    def _next_event_id(self, ts):
        self._sequence += 1
        return f"{self.device_id}-{ts}-{self._sequence}"

    def _message(self, event_type, ts, **fields):
        message = {
            "version": 1,
            "eventId": self._next_event_id(ts),
            "deviceId": self.device_id,
            "tripId": self.trip["tripId"] if self.trip else None,
            "type": event_type,
            "ts": ts,
        }
        message.update(fields)
        return message

    def _append_timeline(self, message):
        if not self.trip:
            return
        self.trip["timeline"].append({
            key: value for key, value in message.items()
            if key in ("eventId", "type", "ts", "level", "alertType", "title", "summary")
        })

    def _start_trip(self, ts):
        self.trip = {
            "tripId": self._next_trip_id(ts),
            "startTs": ts,
            "endTs": None,
            "durationSec": 0,
            "alertCount": 0,
            "summary": "",
            "timeline": [],
        }
        self.state = "guarding"
        message = self._message(
            "trip_started", ts, level="normal",
            title="已出发", summary="平安守护已开启", alertCount=0)
        self._append_timeline(message)
        return message

    def apply(self, event):
        event_type = event["type"]
        ts = int(event.get("ts") or self._clock_ms())
        self.last_heartbeat_ms = self._clock_ms()

        if event_type == "trip_started":
            if self.trip and self.trip.get("endTs") is None:
                return []
            return [self._start_trip(ts)]

        if event_type == "alert":
            messages = []
            if not self.trip or self.trip.get("endTs") is not None:
                messages.append(self._start_trip(ts))
            self.trip["alertCount"] += 1
            self.state = "warning"
            message = self._message(
                "alert", ts,
                level=event.get("level", "warning"),
                alertType=event.get("alertType", "unknown"),
                title=event.get("title", "检测到需要关注的状态"),
                summary=event.get("summary", "状态持续监测中"),
                alertCount=self.trip["alertCount"],
            )
            self._append_timeline(message)
            messages.append(message)
            return messages

        if event_type == "recovered":
            if not self.trip or self.trip.get("endTs") is not None or self.state != "warning":
                return []
            self.state = "recovered"
            message = self._message(
                "recovered", ts,
                level=event.get("level", "normal"),
                alertType=event.get("alertType", "fatigue"),
                title=event.get("title", "状态已恢复"),
                summary=event.get("summary", "驾驶状态恢复平稳"),
                alertCount=self.trip["alertCount"],
            )
            self._append_timeline(message)
            return [message]

        if event_type == "trip_ended":
            if not self.trip or self.trip.get("endTs") is not None:
                return []
            self.trip["endTs"] = ts
            self.trip["durationSec"] = max(0, (ts - self.trip["startTs"]) // 1000)
            count = self.trip["alertCount"]
            summary = ("本次行程平稳，最终平安到达。" if count == 0 else
                       f"途中出现 {count} 次提醒，状态已恢复，最终平安到达。")
            self.trip["summary"] = summary
            self.state = "arrived"
            message = self._message(
                "trip_ended", ts, level="normal", title="平安到达",
                summary=summary, startTs=self.trip["startTs"], endTs=ts,
                durationSec=self.trip["durationSec"], alertCount=count)
            self._append_timeline(message)
            message["timeline"] = list(self.trip["timeline"])
            return [message]

        return []

    def snapshot(self):
        timeline = [] if self.trip is None else list(self.trip["timeline"])
        alert_count = 0 if self.trip is None else self.trip["alertCount"]
        return {
            "version": 1,
            "type": "snapshot",
            "ts": self._clock_ms(),
            "deviceId": self.device_id,
            "state": self.state,
            "trip": None if self.trip is None else {
                **self.trip,
                "timeline": timeline,
            },
            "timeline": timeline,
            "alertCount": alert_count,
            "lastHeartbeatTs": self.last_heartbeat_ms,
        }

    def heartbeat(self):
        self.last_heartbeat_ms = self._clock_ms()
        return {
            "version": 1,
            "type": "heartbeat",
            "ts": self.last_heartbeat_ms,
            "deviceId": self.device_id,
            "state": self.state,
        }
