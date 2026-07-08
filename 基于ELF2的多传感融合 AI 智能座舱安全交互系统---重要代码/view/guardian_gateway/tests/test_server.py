import json
import unittest

from server import GuardianHub
from state import GuardianState


class FakeClient:
    def __init__(self):
        self.messages = []

    async def send(self, payload):
        self.messages.append(json.loads(payload))


class FailingClient:
    async def send(self, _payload):
        raise ConnectionError("closed")


class GuardianHubTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.now = 1751331600000
        state = GuardianState("ELF2-001", clock_ms=lambda: self.now)
        self.hub = GuardianHub(state)

    async def test_new_client_receives_snapshot(self):
        client = FakeClient()
        await self.hub.register(client)
        self.assertEqual("snapshot", client.messages[0]["type"])
        self.assertEqual("idle", client.messages[0]["state"])

    async def test_failed_snapshot_does_not_leave_a_dead_client_registered(self):
        client = FailingClient()
        with self.assertRaises(ConnectionError):
            await self.hub.register(client)
        self.assertNotIn(client, self.hub.clients)

    async def test_valid_datagram_is_broadcast_and_invalid_is_ignored(self):
        client = FakeClient()
        await self.hub.register(client)
        await self.hub.handle_datagram(
            b'{"version":1,"type":"trip_started","ts":1751331600000}')
        self.assertEqual("trip_started", client.messages[-1]["type"])
        before = len(client.messages)
        await self.hub.handle_datagram(b'broken')
        self.assertEqual(before, len(client.messages))

    async def test_heartbeat_is_broadcast(self):
        client = FakeClient()
        await self.hub.register(client)
        await self.hub.heartbeat_once()
        self.assertEqual("heartbeat", client.messages[-1]["type"])


if __name__ == "__main__":
    unittest.main()
