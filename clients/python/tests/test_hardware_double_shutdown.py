"""TEST DOUBLE ONLY lifecycle checks. No physical device, acceptance or qualification evidence."""

import inspect
from pathlib import Path
import selectors
import socket
import sys
import threading
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from surface_control import Client
from surface_control_testing import TestOnlyHardwareHost, _LoopbackHTTPServer


class HardwareDoubleShutdownTests(unittest.TestCase):
    def test_default_service_poll_interval_remains_half_a_second(self):
        signature = inspect.signature(_LoopbackHTTPServer.serve_forever)
        self.assertEqual(signature.parameters["poll_interval"].default, 0.5)

    def test_shutdown_wakes_an_already_waiting_selector_without_polling_time(self):
        # A deliberately long interval proves teardown uses readiness, not a shortened timer.
        # The two-second deadline only guards against a hung test; successful shutdown is event-driven.
        selected = threading.Event()
        stopped = threading.Event()
        real_selector = selectors.DefaultSelector()

        class ObservedSelector:
            def __enter__(self):
                return self

            def __exit__(self, *_):
                real_selector.close()

            def register(self, *args):
                return real_selector.register(*args)

            def select(self, timeout):
                selected.set()
                return real_selector.select(timeout)

        host = TestOnlyHardwareHost("test-only-token")
        serve = _LoopbackHTTPServer.serve_forever
        with (mock.patch("surface_control_testing.selectors.DefaultSelector", return_value=ObservedSelector()),
              mock.patch.object(_LoopbackHTTPServer, "serve_forever", lambda server: serve(server, poll_interval=60))):
            host.start()
            try:
                self.assertTrue(selected.wait(2), "Server never entered select")
                close = threading.Thread(target=lambda: (host.close(), stopped.set()), daemon=True)
                close.start()
                finished = stopped.wait(2)
                if not finished:
                    # Rescue cleanup after a regression without changing the failed result.
                    with socket.create_connection(host.server.server_address, timeout=1):
                        pass
                close.join(2)
                self.assertTrue(finished, "Shutdown waited for a timer instead of waking the selector")
                self.assertFalse(host.thread.is_alive())
            finally:
                if host.server is not None:
                    host.close()

    def test_close_joins_the_server_and_a_fresh_host_can_restart(self):
        host = TestOnlyHardwareHost("test-only-token")
        for _ in range(2):
            host.start()
            try:
                client = Client(host.url, "test-only-token", host.instance_id, accepted_sources=("hardware",))
                self.assertEqual(client.discover()["source"], "hardware")
            finally:
                host.close()
            self.assertFalse(host.thread.is_alive())
            host.close()
