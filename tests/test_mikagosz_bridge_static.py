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


class BrowserTrashTests(unittest.TestCase):
    def test_helper_checks_record_and_shell(self):
        b = body(SERVER, "BOOL SpliceKit_browserClipIsTrashed(id clip)")
        for needle in ("isInTrash", "targetSequenceRecord", "timescale <= 0"):
            self.assertIn(needle, b)
        # po restarcie skorupa ma primaryObject (pusty FFAnchoredClip) — nie może o tym decydować
        self.assertNotIn('"primaryObject"', b)
        # skorupa nie odpowiada na duration (2026-09-28) — długość z clippedRange
        self.assertIn('"clippedRange"', b)

    def test_list_place_and_select_share_the_filter(self):
        listing = body(SERVER, "static NSDictionary *SpliceKit_handleBrowserListClips(")
        self.assertIn("SpliceKit_browserClipIsTrashed(clip)", listing)
        self.assertIn("includeTrashed", listing)
        place = body(SERVER, "static NSDictionary *SpliceKit_handleBrowserPlaceClip(")
        self.assertIn("SpliceKit_browserEventClips(event)", place)
        self.assertIn("SpliceKit_browserClipIsTrashed(c)", place)
        self.assertNotIn('NSSelectorFromString(@"ownedClips")', place)
        self.assertIn("return SpliceKit_browserClipIsTrashed(obj);", DIAG)


class SeekGuardTests(unittest.TestCase):
    def test_open_marks_time_and_seek_reapplies(self):
        self.assertIn("SpliceKit_lastProjectOpen = CFAbsoluteTimeGetCurrent();",
                      body(SERVER, "NSDictionary *SpliceKit_handleProjectOpen("))
        seek = body(SERVER, "NSDictionary *SpliceKit_handlePlaybackSeek(")
        self.assertIn("SpliceKit_seekNeedsGuard()", seek)
        self.assertIn('r[@"reapplied"]', seek)
        self.assertIn("frameSecs / 2.0", seek)


class EffectEnableTests(unittest.TestCase):
    def test_channel_change_order_like_fcp(self):
        # Samo setEnabled: zmienia model, ale nie render — kolejność jak w toggleAllColorCorrectionOff:.
        b = body(DIAG, "NSDictionary *SpliceKit_handleEffectsSetEnabled(")
        order = ["beginChannelChanges:forObject:", "willSetChannel:flagsOnly:", '"setEnabled:"',
                 "didSetChannel:flagsOnly:", "endChannelChanges:forObject:"]
        positions = [b.index(n) for n in order]
        self.assertEqual(positions, sorted(positions))
        self.assertIn('@"effects.setEnabled"', SERVER)


class ShareTests(unittest.TestCase):
    def test_add_destination_is_refused(self):
        b = body(SERVER, "static NSDictionary *SpliceKit_handleShareExport(")
        self.assertTrue(re.search(r'hasPrefix:@"add destination"', b))


if __name__ == "__main__":
    unittest.main()
