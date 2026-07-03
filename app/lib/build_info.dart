// kBuildMarker is a hand-bumped build tag shown in the 账号 page so you can
// confirm AT A GLANCE which build a device is actually running — desktop and
// phone must both show the latest tag for cross-device features (e.g. remote
// workspace/project sync) to work. Bump it whenever you cut a build to verify.
const String kBuildMarker = 'b35 · 2026-07-03 · 待办分组/8态状态 + 分屏 + 语法高亮 + Codex串味修复';

// kAppVersion is the semver this build reports (matches the v<X.Y.Z> release
// tag), injected at build time from the repo VERSION file via
// `--dart-define=APP_VERSION=$(cat VERSION)` (see scripts/package.*). Unstamped
// local builds report 'dev' — the update check treats that as "never behind".
const String kAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'dev',
);
