import importlib
import queue
import sys
import types
import unittest
from concurrent.futures import Future


class RknnPoolDrainTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if "rknnlite.api" not in sys.modules:
            package = types.ModuleType("rknnlite")
            api = types.ModuleType("rknnlite.api")
            api.RKNNLite = object
            package.api = api
            sys.modules["rknnlite"] = package
            sys.modules["rknnlite.api"] = api
        cls.module = importlib.import_module("rknnpool_ld")

    def test_drain_waits_for_and_removes_all_pending_results(self):
        executor = object.__new__(self.module.rknnPoolExecutor)
        executor.queue = queue.Queue()
        for value in ("first", "second", "third"):
            future = Future()
            future.set_result(value)
            executor.queue.put(future)

        drained = executor.drain()

        self.assertEqual(3, drained)
        self.assertTrue(executor.queue.empty())


if __name__ == "__main__":
    unittest.main()
