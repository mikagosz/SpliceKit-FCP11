# SpliceKit for Final Cut Pro 11 — mikagosz edition

A modified version of **[SpliceKit](https://github.com/elliotttate/SpliceKit) by Elliott Tate**
(MIT), adapted to run on **Final Cut Pro 11.2** and trimmed down for one job:
letting Claude edit an open Final Cut Pro project over MCP.

All credit for SpliceKit itself — the injected runtime, the JSON-RPC bridge, the MCP
server and everything not listed below as changed — goes to the original author and
contributors. Their full git history is kept in this repository. This edition only adds
the changes listed here.

> **Why a separate edition?** Upstream targets newer Final Cut Pro releases (12.x).
> SpliceKit talks to private Final Cut Pro internals, and Apple renames and reshapes
> them between versions. On Final Cut Pro 11.2 several upstream commands silently did
> nothing. This edition fixes the ones found so far and stays on 11.2.

## Status

| | |
|---|---|
| Tested on | Final Cut Pro **11.2** (build 442095), macOS 27.2, Apple Silicon |
| Based on | upstream SpliceKit **3.3.9** (`223694a`) |
| Not tested | Final Cut Pro 12.x — use [upstream](https://github.com/elliotttate/SpliceKit) there |

Any command not listed below as fixed should be treated as **unverified on 11.2**.

## What is different from upstream

1. **No telemetry.** Upstream reports crashes and logs to the author's Sentry project,
   on by default and with `sendDefaultPii` enabled. Here `SpliceKitSentry.m` is a
   no-op stub with the same symbols, and the Sentry SDK is neither downloaded nor linked.
   Crashes are logged locally only.
2. **One build script** — `mikagosz-build.sh` builds the dylib, injects it into the
   Final Cut Pro copy, signs it with *your* local code-signing certificate (no silent
   ad-hoc fallback) and verifies the result. It replaces `patcher/patch_fcp.sh`, which
   is out of date upstream, and `make deploy`, which does not inject.
3. **Smaller MCP surface** — 73 of 242 tools, listed in `mcp/mikagosz-tools.txt`
   (editing, transcripts, captions, export, dialogs, Magnetic Mask, browser selection,
   11.2 diagnostics). Tools that can run arbitrary code inside Final Cut Pro
   (`raw_call`, `call_method*`, `debug_*`, `execute_menu_command`) are left out.
   Set `SPLICEKIT_ALL_TOOLS=1` to get the full upstream set. Tool failures come back
   as MCP errors (`isError`), not as plain text.
4. **Fixes for Final Cut Pro 11.2** — the fixes below were checked live on 11.2 after a
   rebuild; the renamed actions were matched against the running app's menu.
   - **55 action names** whose selector is different in 11.2 now use the real selectors
     read from the running app's menu (`setRangeStart:` → `setSelectionStart:`, `duplicate:` →
     `duplicateProjectAs:`, `showMagneticMaskEditor` → `toggleSegmentationMaskEditor:`,
     `retimeSlow10` → `retimeSlowTenPercent:`, `projectProperties` →
     `showProviderSettings:` …). Effects and Transitions browsers open through their
     menu items (the action reads the item's tag).
   - **Crash guard**: an action Final Cut Pro greys out in its menu for the current
     state is not sent (`collapseToConnectedStoryline` on a primary clip used to crash it).
   - **Background operation**: navigation, seek, range and tool selection go straight to
     the timeline instead of the responder chain, which silently did nothing while FCP
     was not the frontmost app.
   - **Editing**: one undo step per batch (blade at times, transcript edits), marker
     names kept, frame times without rounding drift; a transition can be added again
     where one was just undone (FCP needs the playhead to move first).
   - **Transcripts**: silence removal no longer cuts into speech; a transcript that no
     longer matches the timeline is refused instead of cutting in the wrong places.
   - **Native captions** start at the project start (not at the playhead), keep the
     original letter case, and the temporary import project goes to the library trash.
     `verify_native_captions` finds them (it always reported 0 on 11.2) and lists each
     caption with its start time.
   - **Browser**: `browser_list_clips` skips projects in the library trash and the empty
     leftovers they turn into after a restart, like Final Cut Pro's own browser
     (`include_trashed=True` lists them). `browser_append_clip` by index or name uses the
     same list, so an index from `browser_list_clips` points at the same clip.
   - **`select_clip_in_lane`** finds connected clips again (on 11.2 `anchoredItems` is a
     set, so no candidate was ever found); when nothing is under the playhead the error
     lists the clips in that lane with their time ranges.
   - **Seek right after opening a project**: just after Final Cut Pro started, the first
     `seek_to_time` after `open_project` reported 9.5 s while the playhead ended up at
     8.97 s. For a few seconds after opening a project (and in the first minute after
     launch) `seek_to_time` now watches the playhead and sets it again if it moves.
   - **Dialogs**: popup and checkbox handling no longer crash FCP; `detect_dialog`
     reports popups and checkboxes; `share_project` accepts 11.2 destination names and
     reports a modal share window instead of a false error. All seven built-in
     destinations of 11.2 were opened and cancelled this way; "Add Destination" is
     refused, since it opens Settings, not an export.
   - **Inspector**: effect parameters live on the clip's container (`videoEffects`);
     reads and writes go there, scale in percent, non-numeric values refused.
   - `retimeReverse` → `retimeReverseClip:`; volume ±1 dB → `volumeUp:`/`volumeDown:`.
5. **New commands**
   - `diag.menuActions`, `diag.selectorImplementors` (MCP `diag_menu_actions`,
     `diag_selector_implementors`) — the menu with its selectors, and which classes
     implement a selector. Use them before trusting an upstream command on 11.2.
   - Magnetic Mask: `mask_add_point` (point as a fraction of the frame from the top-left
     corner), `mask_list_points`, `mask_remove_point`, `mask_analyze`, `mask_status`;
     `mask_attach` puts a Magnetic Mask on an effect (e.g. a colour correction limited to
     the subject) and the other mask tools take `effect=` to work on it.
   - `browser_select` / `browser_get_selection` — select clips or projects in the browser
     by name, for menu commands that act on the browser selection.
   - `set_effect_enabled` — turn a video effect on the selected clip on or off, like the
     checkbox in the Video inspector (settings kept, one undo step). Flipping the effect's
     own `enabled` flag is not enough on 11.2: the model changes, the picture does not.
6. **Build fixes** — paths with spaces (`Makefile`), missing BRAW stubs when the
   Blackmagic RAW SDK is not installed, `parakeet-transcriber` pinned to FluidAudio
   0.13.6 (0.13.7 changed the `transcribe` API).

### Known on 11.2, not fixed yet

- No menu command in 11.2 for: `addChannelEQ`, `addTodoMarker`, `enableBeatDetection`,
  `beatDetectionGrid`, `toggleVerifyObjectAlignment`, `audioCurves`.
- `histogram` / `vectorscope` / `waveform` return an error — 11.2 has one Video Scopes
  panel (`videoScopes`), the scope type is picked inside it.
- `get_selected_clips` lists only primary-storyline clips; a connected clip selected with
  `select_clip_in_lane` is selected in Final Cut Pro but not reported there.
- `fullscreenViewer` is "Play Full Screen" in 11.2 — it starts playback; leave it with
  `exitFullscreenViewer` (a second `fullscreenViewer` does not exit).
- Moving transcript words uses Cut/Paste, so it replaces the clipboard.
- `share_project()` without a destination waits about 20 s before it reports the
  Export File window as open.

### Left in the tree, unused

The GUI patcher (`patcher/`), `release.sh` and the Sentry docs and scripts are upstream
files this edition does not use. They still reference Sentry.

### Language

Comments added in this edition, `mikagosz-build.sh` messages and the test names are in
Polish. Everything the MCP server returns to a client is in English.

## Build and install

Requirements:

- Final Cut Pro 11.2 and an Apple Silicon Mac.
- Xcode — built with Xcode 27.0 beta. If `xcode-select -p` points at the command line
  tools, prefix the build commands with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (or your Xcode path).
- A local code-signing certificate — a self-signed one is enough (Keychain Access →
  Certificate Assistant → Create a Certificate…, type *Code Signing*). Look it up with
  `security find-identity -p codesigning` **without** `-v`: `-v` hides self-signed
  certificates.
- Python **3.10 or newer** for the MCP server. The `python3` that ships with macOS is
  3.9 and cannot install the `mcp` package; use one from python.org or Homebrew.
- `git` and network access on the first build: the script clones
  [insert_dylib](https://github.com/tyilo/insert_dylib) into `build/`, and the
  transcriber fetches FluidAudio.

```bash
# 1. a writable copy of Final Cut Pro — the original is never touched
mkdir -p ~/Applications/SpliceKit
ditto "/Applications/Final Cut Pro.app" ~/Applications/SpliceKit/"Final Cut Pro.app"

# 2. tell the script which certificate to sign with (SHA-1 from `security find-identity -p codesigning`)
export SPLICEKIT_SIGN_IDENTITY=<certificate SHA-1>

# 3. build, inject, sign, verify
./mikagosz-build.sh

# 4. on-device transcription (Parakeet) — optional, needed for the transcript tools
swift build -c release --package-path tools/parakeet-transcriber
mkdir -p ~/Applications/SpliceKit/tools
cp tools/parakeet-transcriber/.build/release/parakeet-transcriber ~/Applications/SpliceKit/tools/

# 5. MCP server (python3.12 or any 3.10+)
python3.12 -m venv ~/.local/venvs/splicekit
~/.local/venvs/splicekit/bin/pip install -r mcp/requirements.txt
claude mcp add --scope user splicekit -- ~/.local/venvs/splicekit/bin/python "$PWD/mcp/server.py"
```

Open the copy (`open ~/Applications/SpliceKit/"Final Cut Pro.app"`), not the original —
they share a name and icon. Check the bridge:
`echo '{"jsonrpc":"2.0","method":"system.version","id":1}' | nc -w 3 127.0.0.1 9876`.

After a Final Cut Pro update, redo step 1 and run the script again.

## License

MIT, same as upstream — see [LICENSE](LICENSE). The original copyright notice is kept.

## Original SpliceKit

For what SpliceKit itself can do — the command palette, text-based editing, the audio
mixer and the rest — see the [original README](https://github.com/elliotttate/SpliceKit/blob/223694a/README.md)
of the version this edition is based on. Its screenshots, videos and install steps come
from the original author, were not made on Final Cut Pro 11.2 and do not apply here.
