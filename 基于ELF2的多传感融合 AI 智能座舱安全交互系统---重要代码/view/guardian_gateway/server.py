from __future__ import annotations

import argparse
import asyncio
import contextlib
import os
import socket

try:
    from .protocol import ProtocolError, encode_server_message, parse_local_event
    from .state import GuardianState
except ImportError:  # Direct board-side execution.
    from protocol import ProtocolError, encode_server_message, parse_local_event
    from state import GuardianState


DEFAULT_EVENT_SOCKET = "/tmp/cockpit_guardian_events.sock"


class GuardianHub:
    def __init__(self, state=None):
        self.state = state or GuardianState()
        self.clients = set()

    async def register(self, client):
        self.clients.add(client)
        try:
            await client.send(encode_server_message(self.state.snapshot()))
        except Exception:
            self.unregister(client)
            raise

    def unregister(self, client):
        self.clients.discard(client)

    async def broadcast(self, message):
        if not self.clients:
            return
        payload = encode_server_message(message)
        clients = list(self.clients)
        results = await asyncio.gather(
            *(client.send(payload) for client in clients), return_exceptions=True)
        for client, result in zip(clients, results):
            if isinstance(result, Exception):
                self.unregister(client)

    async def handle_datagram(self, payload):
        try:
            event = parse_local_event(payload)
        except ProtocolError:
            return
        for message in self.state.apply(event):
            await self.broadcast(message)

    async def heartbeat_once(self):
        await self.broadcast(self.state.heartbeat())

    async def websocket_handler(self, websocket, _path=None):
        await self.register(websocket)
        try:
            await websocket.wait_closed()
        finally:
            self.unregister(websocket)


class GuardianDatagramProtocol(asyncio.DatagramProtocol):
    def __init__(self, hub):
        self.hub = hub

    def datagram_received(self, data, _address):
        asyncio.get_running_loop().create_task(self.hub.handle_datagram(data))


async def _heartbeat_loop(hub, interval_seconds):
    while True:
        await asyncio.sleep(interval_seconds)
        await hub.heartbeat_once()


async def run_gateway(host="0.0.0.0", port=8765,
                      event_socket=DEFAULT_EVENT_SOCKET,
                      device_id="ELF2-001", heartbeat_seconds=5.0):
    try:
        import websockets
    except ImportError as exc:
        raise RuntimeError(
            "缺少 websockets 依赖，请安装 requirements.txt") from exc

    try:
        os.unlink(event_socket)
    except FileNotFoundError:
        pass

    hub = GuardianHub(GuardianState(device_id))
    loop = asyncio.get_running_loop()
    transport, _ = await loop.create_datagram_endpoint(
        lambda: GuardianDatagramProtocol(hub),
        family=socket.AF_UNIX,
        local_addr=event_socket,
    )
    heartbeat_task = asyncio.create_task(
        _heartbeat_loop(hub, heartbeat_seconds))
    try:
        async with websockets.serve(hub.websocket_handler, host, port):
            print(f"[guardian] ws://{host}:{port} event_socket={event_socket}")
            await asyncio.Future()
    finally:
        heartbeat_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await heartbeat_task
        transport.close()
        try:
            os.unlink(event_socket)
        except FileNotFoundError:
            pass


def parse_args():
    parser = argparse.ArgumentParser(description="ELF2 guardian WebSocket gateway")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--event-sock", default=DEFAULT_EVENT_SOCKET)
    parser.add_argument("--device-id", default="ELF2-001")
    parser.add_argument("--heartbeat", type=float, default=5.0)
    return parser.parse_args()


def main():
    args = parse_args()
    asyncio.run(run_gateway(
        host=args.host,
        port=args.port,
        event_socket=args.event_sock,
        device_id=args.device_id,
        heartbeat_seconds=args.heartbeat,
    ))


if __name__ == "__main__":
    main()
