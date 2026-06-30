# Xterm Render Benchmark

Run manually:

```sh
cd app
/opt/homebrew/bin/flutter test --no-pub --dart-define=RUN_XTERM_BENCHMARKS=true test/xterm_render_benchmark_test.dart
```

The benchmark is skipped unless `RUN_XTERM_BENCHMARKS=true` is set, so normal
test runs do not depend on machine timing.

## 2026-06-30 Baseline

Branch: `feature/ghostty-shadow-terminal`

Commit under test: `226014d` plus benchmark harness worktree changes.

Environment: Flutter test runner on local macOS host. These numbers are useful
for relative comparisons in this repo, not as release-mode FPS guarantees.

### Painter Microbenchmarks

Scenario length: 600 cells. Average wall time per `TerminalPainter.paintLine`
call, after cache warmup.

| Scenario | Run 1 avg us | Run 2 avg us | Notes |
| --- | ---: | ---: | --- |
| ASCII text | 7.5 | 7.0 | 3 text runs, run paragraph cache hits |
| Latin-1 text | 4.9 | 4.9 | 3 safe text runs, run paragraph cache hits |
| Geometry glyphs | 266.3 | 265.7 | 600 glyph picture cache hits |
| Mixed text/glyph | 48.9 | 50.2 | 75 text runs, 75 glyph hits, 78 single cells |

### Render Overlay/Cache Benchmarks

Viewport: 720 x 360, 240 terminal rows, 23 visible rows.

| Scenario | Run 1 avg us | Run 2 avg us | Last-frame profile |
| --- | ---: | ---: | --- |
| Selection set + clear | 618.9 | 618.5 | content cache hit, 22 overlay signature skips, 1 overlay row miss |
| Cursor style toggle | 1562.9 | 1578.2 | content cache hit, 22 overlay signature skips, 1 overlay row miss |

Initial paint profile: 23 visible rows, 23 line signature checks, 23 line cache
misses, 1 viewport content cache miss, 22 text runs, 1 blank line.

## Current Bottlenecks

- Cursor benchmark includes widget rebuild overhead because the public route to
  trigger a cursor-only update is changing `TerminalView.cursorType`.
- These tests run in Flutter test mode, so they quantify relative cache/render
  behavior rather than production compositor FPS.

## 2026-06-30 Geometry Run Picture Cache

Change: consecutive geometry glyph spans are recorded into a run-level picture
cache, so dense box/block/braille runs draw one picture per run instead of one
picture per cell.

Painter microbenchmark, 600 cells:

| Scenario | Before avg us | After run 1 avg us | After run 2 avg us | Notes |
| --- | ---: | ---: | ---: | --- |
| Geometry glyphs | ~266 | 14.2 | 14.4 | 1 glyph-run picture cache hit |
| Mixed text/glyph | ~49-50 | 66.9 | 54.9 | short glyph runs fall back to the single-glyph cache |

Dense geometry improves by roughly 17x in this microbenchmark. Short
alternating text/glyph runs stay on the older single-glyph cache path to avoid
the extra key/list overhead of run-level picture caching.

Powerline private-use glyphs (`U+E0B0`-`U+E0BF`) now share the same cached sprite
glyph path as box/block/braille drawing, so prompt separators avoid text layout
when they can be represented by deterministic vector shapes.

## 2026-07-01 Sprite Atlas Gate

Change: deterministic terminal glyphs now have a small sprite atlas path.
Single glyphs and short geometry runs draw from an atlas image; long dense
geometry runs stay on the run-level picture cache because a single picture draw
is faster than submitting hundreds of atlas sprites in Flutter.

Painter microbenchmark, 600 cells:

| Scenario | Previous avg us | Atlas-gated avg us | Notes |
| --- | ---: | ---: | --- |
| ASCII text | 7.0 | 7.6 | unchanged paragraph-run path |
| Latin-1 text | 5.2 | 4.9 | unchanged paragraph-run path |
| Geometry glyphs | 14.4 | 14.7 | long runs stay on glyph-run picture cache |
| Mixed text/glyph | 54.9 | 48.7 | isolated geometry glyphs use atlas image draws |

An unbounded `drawAtlas` path for long geometry runs measured around 66.7 us,
so the atlas path is intentionally capped to short runs.

## 2026-07-01 Atlas/Dirty Observability

Change: atlas short-run drawing now reuses an internal transform/source buffer
instead of allocating fresh lists for every run. Emoji and wide glyph cells are
kept on the paragraph fallback path and are counted in render profiles, avoiding
platform-specific emoji image atlas churn. Viewport content signature scans now
report how many rows were hashed per paint.

This keeps the Flutter Canvas renderer conservative: deterministic sprite glyphs
use atlas batching, long dense geometry keeps picture-run caching, and emoji
rendering stays with the platform text stack until an image atlas has stronger
cross-platform test coverage.

## 2026-07-01 Dirty Content Direct Draw

Change: terminal content updates and scroll paints now bypass full viewport
picture recording and draw the visible line picture cache directly. Cursor,
focus, composing text, and controller/selection paints still use the viewport
content picture cache so overlay-only frames keep their cheap content-cache hit.

This avoids re-recording a whole viewport picture on high-frequency terminal
stream frames while preserving the existing line-level damage cache. Blank or
shortened lines remain safe because direct drawing uses the freshly rebuilt line
picture cache instead of compositing over an old viewport snapshot.

Paint reasons are merged by priority so a terminal content update cannot be
overwritten by a later scroll/cursor/controller signal in the same frame; this
keeps line signature validation enabled whenever content may have changed.

## 2026-07-01 Content Render Command Buffer

Change: content line picture draws now flow through a small render command
buffer before hitting Flutter Canvas. Both viewport picture recording and the
terminal/scroll direct-draw path record line-picture commands and flush them as
one batch.

This is a compatibility step toward a Ghostty/flterm-style renderer pipeline:
line damage, row scheduling, sprite draws, and future GPU backends can share a
single command stream without changing xterm input, selection, IME, or text
fallback behavior. The current backend still draws Flutter `Picture`s, so this
does not claim GPU text-atlas parity yet; it removes a renderer structure gap and
adds `renderCommandBuffers`, `renderCommands`, and
`renderCommandPictureDraws` counters for follow-up benchmarks.

## 2026-07-01 Overlay Command Buffer

Change: the render command buffer now reuses parallel picture/dx/dy/kind
arrays instead of allocating a command object per draw. Overlay row pictures
also use the same command stream as content line pictures, with command kinds
keeping `contentPicturesDrawn` and `overlayRowPictureDraws` profile counters
separate.

This reduces short-lived allocations on scroll/selection frames and moves the
renderer closer to a single GPU-style submit path while preserving the existing
overlay row cache, cursor, selection, highlight, and composing text behavior.

## 2026-07-01 Direct Overlay Rect Commands

Change: selection and highlight overlays now record rectangle commands directly
into the render command buffer. Cursor and IME composing text stay on the
existing overlay row picture cache because they involve text/caret fallback
behavior, but regular overlay color spans no longer force row picture recording.

This moves the most common overlay work toward a GPU-style rect stream while
keeping cursor/composing correctness isolated in the conservative picture path.

## 2026-07-01 Direct Content Background Commands

Change: terminal cell background runs now record rectangle commands directly
into the content command buffer. Line pictures are recorded without backgrounds,
so the picture path carries foreground text/glyph fallback while regular
background spans use the same rect stream as overlay spans.

This is the first content-layer split from line pictures toward span-level
commands. Text shaping, emoji, and sprite foreground drawing remain on the
existing conservative picture path.

## 2026-07-01 Direct Safe Text Run Commands

Change: safe fixed-width text runs now record cached `Paragraph` commands
directly into the content command buffer. The line picture recorder skips those
runs and remains responsible for short cells, width-mismatched fallback text,
emoji/wide glyph fallback, and geometry/sprite foreground drawing.

This moves the common ASCII/Latin foreground path out of line pictures while
preserving Flutter paragraph shaping validation and the existing fallback path
for complex text.
