#!/usr/bin/env python3
"""Błąd narzędzia MCP ma dojść do klienta jako isError, nie jako zwykły tekst.

    ~/.local/venvs/splicekit/bin/python -m unittest tests.test_mikagosz_tool_errors
"""
import asyncio
import importlib.util
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


def load_server():
    spec = importlib.util.spec_from_file_location("splicekit_mcp_server_errors", REPO / "mcp" / "server.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ErrorTextTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = load_server()

    def test_error_shapes_are_detected(self):
        e = self.server._error_text
        self.assertIsNotNone(e("Error: {'message': 'No event found'}"))
        self.assertIsNotNone(e("SpliceKit NOT connected: refused"))
        self.assertIsNotNone(e('{"error": "boom"}'))
        self.assertIsNotNone(e('{\n  "status": "error",\n  "imported": []\n}'))

    def test_results_pass_through(self):
        e = self.server._error_text
        self.assertIsNone(e('{"status": "ok"}'))
        self.assertIsNone(e("Sequence: test\nItems: 1"))
        self.assertIsNone(e('{"clips": [{"name": "Error log"}]}'))  # słowo w środku to nie błąd
        self.assertIsNone(e(None))

    def test_wrapped_tool_raises_and_keeps_signature(self):
        server = self.server
        tool = server.mcp._tool_manager.get_tool("import_media")
        params_before = tool.parameters
        server._raise_on_error_text(server.mcp)
        self.assertEqual(tool.parameters, params_before)
        with self.assertRaises(Exception) as ctx:
            asyncio.run(tool.run({}))  # bez ścieżek: narzędzie zwraca "Error: provide `paths`…"
        self.assertIn("provide `paths`", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
