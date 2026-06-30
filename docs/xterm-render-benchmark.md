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
