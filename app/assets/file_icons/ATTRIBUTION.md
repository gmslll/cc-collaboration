# File-type icon attribution

The colorful per-type icons in this directory power the GoLand-style file tree
(`lib/file_icons.dart` → `lib/screens/file_browser_page.dart`).

## Source

Most icons are from **Material Icon Theme** by Philipp Kief and contributors,
a JetBrains-adjacent colorful file-type icon set.

- Repository: https://github.com/material-extensions/vscode-material-icon-theme
- License: **MIT**

These cover language/file types: `go`, `dart`, `markdown`, `console` (shell),
`powershell`, `json`, `yaml`, `toml`, `settings`, `xml`, `html`, `css`,
`javascript`, `typescript`, `python`, `rust`, `java`, `kotlin`, `c`, `cpp`,
`image`, `lock`, `document`, `git`, `docker`, `makefile`, `certificate`,
`database`, `tune`.

## Original to this project

`folder.svg` and `file.svg` (the generic folder / fallback file glyphs) were
authored for this project to read cleanly on the dark sidebar panel.

> Note: GoLand's own (proprietary) IDE icons are intentionally not bundled.
> Material Icon Theme is used instead — MIT-licensed, consistent across every
> file type (including Go), and visually in the same colorful spirit.
