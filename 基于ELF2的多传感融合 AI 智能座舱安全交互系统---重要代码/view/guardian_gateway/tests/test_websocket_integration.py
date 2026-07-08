import asyncio
import contextlib
import json
import os
import socket
import tempfile
import unittest

import websockets

from server import GuardianHub, run_gateway
from state import GuardianState


class WebSocketIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def test_real_client_receives_snapshot_and_board_event(self):
        now = 1751331600000
        hub = GuardianHub(GuardianState("ELF2-001", clock_ms=lambda: now))

        async with websockets.serve(hub.websocket_handler, "127.0.0.1", 0) as server:
            port = server.sockets[0].getsockname()[1]
            async with websockets.connect(f"ws://127.0.0.1:{port}") as client:
                snapshot = json.loads(await client.recv())
                self.assertEqual("snapshot", snapshot["type"])
                self.assertEqual("idle", snapshot["state"])

                await hub.handle_datagram(
                    b'{"version":1,"type":"trip_started",'
                    b'"ts":1751331600000}')
                event = json.loads(await client.recv())
                self.assertEqual("trip_started", event["type"])
                self.assertEqual("guarding", hub.state.state)

    async def test_real_gateway_bridges_unix_datagram_to_websocket(self):
        if not hasattr(socket, "AF_UNIX"):
            self.skipTest("AF_UNIX is unavailable")

        with tempfile.TemporaryDirectory() as directory:
            event_socket = os.path.join(directory, "events.sock")
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]

            gateway = asyncio.create_task(run_gateway(
                host="127.0.0.1",
                port=port,
                event_socket=event_socket,
                heartbeat_seconds=60.0,
            ))
            try:
                client = None
                for _ in range(50):
                    if gateway.done():
                        await gateway
                    try:
                        client = await websockets.connect(
                            f"ws://127.0.0.1:{port}")
                        break
                    except OSError:
                        await asyncio.sleep(0.02)
                self.assertIsNotNone(client, "gateway did not start")

                async with client:
                    snapshot = json.loads(await asyncio.wait_for(
                        client.recv(), timeout=2.0))
                    self.assertEqual("snapshot", snapshot["type"])

                    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sender:
                        sender.sendto(
                            b'{"version":1,"type":"trip_started",'
                            b'"ts":1751331600000}',
                            event_socket,
                        )
                    event = json.loads(await asyncio.wait_for(
                        client.recv(), timeout=2.0))
                    self.assertEqual("trip_started", event["type"])
                    self.assertEqual("ELF2-001", event["deviceId"])
                    self.assertTrue(event["eventId"].startswith("ELF2-001-"))
            finally:
                gateway.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await gateway


if __name__ == "__main__":
    unittest.main()
