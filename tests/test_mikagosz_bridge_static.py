#!/usr/bin/env python3
"""Poprawki mostu z 2026-09-28, których nie da się uruchomić bez Final Cuta — sprawdzamy źródło.

Testy na żywo są w notatce „Test narzędzi MCP” (sejf). Tu pilnujemy, żeby poprawka nie
zniknęła po cichu przy scalaniu z upstreamem.

    python3 -m unittest tests.test_mikagosz_bridge_static
"""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SERVER = (REPO / "Sources" / "SpliceKitServer.m").read_text(encoding="utf-8")
DIAG = (REPO / "Sources" / "SpliceKitMikagoszDiag.m").read_text(encoding="utf-8")


def body(source, signature):
    """Ciało funkcji od sygnatury do klamry zamykającej na początku linii."""
    start = source.index(signature)
    end = source.index("\n}\n", start)
    return source[start:end]


class CaptionsVerifyTests(unittest.TestCase):
    def test_uses_sequence_caption_query(self):
        # 11.2 nie ma allCaptions, a napisy wiszą na klipach — stąd dawniej zawsze 0.
        b = body(SERVER, "static NSDictionary *SpliceKit_handleNativeCaptionsVerify(")
        self.assertIn("captionsWithRoleUID:includeDisabled:", b)
        self.assertLess(b.index("captionsWithRoleUID:includeDisabled:"), b.index('@"allCaptions"'))
        self.assertIn('info[@"start"]', b)


if __name__ == "__main__":
    unittest.main()
