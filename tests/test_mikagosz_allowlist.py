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

    def test_mask_and_diag_tools_forward_to_bridge(self):
        # Narzędzia dla poleceń mostu mikagosz: są na liście i wołają właściwą metodę z parametrami.
        server = load_server()
        server._apply_allowlist(server.mcp)
        names = registered(server)
        calls = []
        server.bridge.call = lambda method, **params: calls.append((method, params)) or {"status": "ok", "items": [], "count": 0}
        cases = [
            ("diag_menu_actions", {}, "diag.menuActions", {}),
            ("diag_selector_implementors", {"selectors": ["addTransition:"]}, "diag.selectorImplementors",
             {"selectors": ["addTransition:"], "limit": 12}),
            ("mask_list_points", {}, "mask.listControlPoints", {}),
            ("mask_add_point", {"x": 0.245, "y": 0.76, "offset": 2.0}, "mask.addControlPoint",
             {"x": 0.245, "y": 0.76, "offset": 2.0, "include": True, "analyze": False}),
            ("mask_remove_point", {"index": 0, "offset": 2.0}, "mask.removeControlPoint", {"index": 0, "offset": 2.0}),
            ("mask_analyze", {}, "mask.analyze", {"direction": "both"}),
            ("mask_status", {}, "mask.status", {}),
            ("mask_attach", {"effect": "Color Adjustments"}, "mask.attach", {"effect": "Color Adjustments"}),
            ("mask_analyze", {"effect": "Color Adjustments"}, "mask.analyze",
             {"direction": "both", "effect": "Color Adjustments"}),
            ("mask_list_points", {"effect": "Color Adjustments"}, "mask.listControlPoints", {"effect": "Color Adjustments"}),
            ("browser_select", {"names": ["IMG_1990"]}, "browser.select", {"names": ["IMG_1990"]}),
            ("browser_select", {"names": [], "event": "durok"}, "browser.select", {"names": [], "event": "durok"}),
            ("browser_get_selection", {}, "browser.getSelection", {}),
        ]
        for tool, args, method, params in cases:
            self.assertIn(tool, names)
            calls.clear()
            getattr(server, tool)(**args)
            self.assertEqual(calls, [(method, params)], tool)

    def test_menu_filter_matches_path_and_action(self):
        server = load_server()
        server.bridge.call = lambda method, **params: {"count": 2, "items": [
            {"path": "File > Share > Export File (default)…", "action": "shareToDefaultDestination:"},
            {"path": "Mark > Set Range Start", "action": "setSelectionStart:"}]}
        out = server.diag_menu_actions(filter="selectionstart")
        self.assertIn("setSelectionStart:", out)
        self.assertNotIn("Export File", out)

    def test_native_captions_from_srt(self):
        import tempfile
        server = load_server()
        calls = []
        server.bridge.call = lambda method, **params: calls.append((method, params)) or {"status": "ok"}
        with tempfile.NamedTemporaryFile("w", suffix=".srt", delete=False, encoding="utf-8") as f:
            f.write("\ufeff1\r\n00:00:00,160 --> 00:00:01,600\r\nZ czego są zrobieni.\r\n\r\n"
                    "2\n00:00:05,760 --> 00:00:12,960\nO'Conner, Parker\ni reszta ekipy.\n")
        server.generate_native_captions(language="pl", srt_path=f.name)
        method, params = calls[0]
        self.assertEqual(method, "nativeCaptions.generate")
        self.assertEqual(params["language"], "pl")
        self.assertEqual(params["segments"], [
            {"start": 0.16, "end": 1.6, "text": "Z czego są zrobieni."},
            {"start": 5.76, "end": 12.96, "text": "O'Conner, Parker\ni reszta ekipy."}])
        self.assertTrue(server.generate_native_captions(srt_path="/nie/ma/pliku.srt").startswith("Error"))


if __name__ == "__main__":
    unittest.main()
