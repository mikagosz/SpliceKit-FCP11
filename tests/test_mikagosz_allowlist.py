#!/usr/bin/env python3
"""Lista dozwolonych narzędzi MCP (wersja mikagosz).

Ładuje server.py z prawdziwym FastMCP — sprawdzamy remove_tool, więc atrapa
z test_mcp_tool_annotations.py by tu nic nie dowiodła. Uruchamiać z venv,
w którym jest pakiet mcp:

    ~/.local/venvs/splicekit/bin/python -m unittest tests.test_mikagosz_allowlist
"""
import importlib.util
import os
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ALLOWLIST = REPO / "mcp" / "mikagosz-tools.txt"


def load_server():
    spec = importlib.util.spec_from_file_location("splicekit_mcp_server_allowlist", REPO / "mcp" / "server.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def registered(server_module):
    return {tool.name for tool in server_module.mcp._tool_manager.list_tools()}


def allowlist_names():
    names = set()
    for line in ALLOWLIST.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            names.add(line)
    return names


class AllowlistTests(unittest.TestCase):
    def test_every_allowlisted_name_exists_upstream(self):
        # Literówka w liście = narzędzie po cichu znika; ma paść test, nie montaż.
        server = load_server()
        missing = allowlist_names() - registered(server)
        self.assertEqual(missing, set())

    def test_filter_leaves_exactly_the_allowlist(self):
        server = load_server()
        self.assertGreater(len(registered(server)), 200)  # kontrola dodatnia: pełny zestaw przed filtrem
        server._apply_allowlist(server.mcp)
        self.assertEqual(registered(server), allowlist_names())

    def test_all_tools_env_disables_filter(self):
        server = load_server()
        before = registered(server)
        os.environ["SPLICEKIT_ALL_TOOLS"] = "1"
        try:
            server._apply_allowlist(server.mcp)
        finally:
            del os.environ["SPLICEKIT_ALL_TOOLS"]
        self.assertEqual(registered(server), before)


if __name__ == "__main__":
    unittest.main()
