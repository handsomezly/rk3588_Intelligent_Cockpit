import json
import math


SUPPORTED_TYPES = {"trip_started", "alert", "recovered", "trip_ended"}


class ProtocolError(ValueError):
    pass


def encode_server_message(message):
    if not isinstance(message, dict) or message.get("version") != 1:
        raise ProtocolError("unsupported server protocol version")
    if not isinstance(message.get("type"), str):
        raise ProtocolError("server message type is required")
    timestamp = message.get("ts")
    if (isinstance(timestamp, bool) or
            not isinstance(timestamp, (int, float)) or
            not math.isfinite(timestamp)):
        raise ProtocolError("server timestamp is required")
    if not isinstance(message.get("deviceId"), str):
        raise ProtocolError("server device id is required")
    return json.dumps(message, ensure_ascii=False, separators=(",", ":"))


def parse_local_event(payload):
    if isinstance(payload, bytes):
        try:
            payload = payload.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ProtocolError("event is not utf-8") from exc
    if isinstance(payload, str):
        try:
            payload = json.loads(payload)
        except json.JSONDecodeError as exc:
            raise ProtocolError("event is not valid json") from exc
    if not isinstance(payload, dict):
        raise ProtocolError("event must be an object")
    if payload.get("version") != 1:
        raise ProtocolError("unsupported protocol version")
    if payload.get("type") not in SUPPORTED_TYPES:
        raise ProtocolError("unsupported event type")
    timestamp = payload.get("ts")
    if (isinstance(timestamp, bool) or
            not isinstance(timestamp, (int, float)) or
            not math.isfinite(timestamp)):
        raise ProtocolError("event timestamp is required")
    if payload["type"] in {"alert", "recovered"}:
        required = ("alertType", "level", "title", "summary")
        if any(not isinstance(payload.get(field), str) or not payload[field]
               for field in required):
            raise ProtocolError("alert fields are required")
    return dict(payload)
