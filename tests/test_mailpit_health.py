#!/usr/bin/env python3
"""Unit tests for Mailpit operational checks using Docker/network mocks."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "mailpit_health", ROOT / "scripts" / "mailpit-health.py"
)
health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(health)


def inspect_data():
    binding = [{"HostIp": "127.0.0.1", "HostPort": "8025"}]
    return {
        "State": {"Running": True},
        "HostConfig": {"PortBindings": {"8025/tcp": binding}},
        "NetworkSettings": {
            "Networks": {
                "docal-proxy": {
                    "IPAddress": "172.30.0.10",
                    "Aliases": ["docal-mailpit", "mailpit"],
                }
            },
            "Ports": {"8025/tcp": binding, "1025/tcp": None},
        },
    }


class MailpitHealthTests(unittest.TestCase):
    def setUp(self):
        self.data = inspect_data()
        self.inspect = mock.patch.object(
            health.subprocess,
            "run",
            side_effect=lambda *args, **kwargs: mock.Mock(
                stdout=json.dumps([self.data])
            ),
        ).start()
        self.http_response = mock.MagicMock()
        self.http_response.__enter__.return_value = self.http_response
        self.http_response.status = 200
        self.http_response.read.return_value = b'{"messages":[],"messages_count":0}'
        self.urlopen = mock.patch.object(
            health, "urlopen", return_value=self.http_response
        ).start()
        self.tcp = mock.patch.object(health.socket, "create_connection").start()
        self.addCleanup(mock.patch.stopall)

    def run_check(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            result = health.check()
        return result, output.getvalue()

    def test_operational_mailpit_passes(self):
        result, output = self.run_check()
        self.assertEqual(result, 0, output)
        self.assertIn("operational", output)
        self.urlopen.assert_called_once_with(health.HTTP_URL, timeout=health.TIMEOUT)
        self.tcp.assert_called_once_with(("172.30.0.10", 1025), timeout=health.TIMEOUT)

    def test_stopped_container_fails(self):
        self.data["State"]["Running"] = False
        result, output = self.run_check()
        self.assertNotEqual(result, 0)
        self.assertIn("not running", output)

    def test_running_container_without_network_fails(self):
        self.data["NetworkSettings"]["Networks"] = {}
        result, output = self.run_check()
        self.assertNotEqual(result, 0)
        self.assertIn("not connected", output)

    def test_http_port_not_published_fails(self):
        self.data["HostConfig"]["PortBindings"] = {}
        result, output = self.run_check()
        self.assertNotEqual(result, 0)
        self.assertIn("published only", output)

    def test_wrong_host_binding_fails_as_port_conflict_or_misconfiguration(self):
        self.data["HostConfig"]["PortBindings"]["8025/tcp"][0]["HostIp"] = "0.0.0.0"
        result, output = self.run_check()
        self.assertNotEqual(result, 0)
        self.assertIn("127.0.0.1:8025", output)

    def test_api_connection_error_fails(self):
        self.urlopen.side_effect = OSError("connection refused")
        result, output = self.run_check()
        self.assertNotEqual(result, 0)
        self.assertIn("API is not responding", output)

    def test_invalid_api_json_fails(self):
        self.http_response.read.return_value = b"not-json"
        result, output = self.run_check()
        self.assertNotEqual(result, 0)
        self.assertIn("API is not responding", output)

    def test_missing_api_messages_list_fails(self):
        self.http_response.read.return_value = b'{"ok":true}'
        result, output = self.run_check()
        self.assertNotEqual(result, 0)
        self.assertIn("unexpected JSON", output)

    def test_internal_smtp_connection_error_fails(self):
        self.tcp.side_effect = OSError("connection refused")
        result, output = self.run_check()
        self.assertNotEqual(result, 0)
        self.assertIn("SMTP port 1025 is not reachable", output)

    def test_host_published_smtp_fails(self):
        self.data["HostConfig"]["PortBindings"]["1025/tcp"] = [
            {"HostIp": "0.0.0.0", "HostPort": "1025"}
        ]
        result, output = self.run_check()
        self.assertNotEqual(result, 0)
        self.assertIn("must not be published", output)

    def test_docker_inspect_failure_fails(self):
        self.inspect.stop()
        with mock.patch.object(
            health.subprocess,
            "run",
            side_effect=subprocess.CalledProcessError(1, ["docker", "inspect"]),
        ):
            result, output = self.run_check()
        self.assertNotEqual(result, 0)
        self.assertIn("cannot inspect", output)


if __name__ == "__main__":
    unittest.main(verbosity=2)
