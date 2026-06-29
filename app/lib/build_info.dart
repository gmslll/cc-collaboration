// kBuildMarker is a hand-bumped build tag shown in the 账号 page so you can
// confirm AT A GLANCE which build a device is actually running — desktop and
// phone must both show the latest tag for cross-device features (e.g. remote
// workspace/project sync) to work. Bump it whenever you cut a build to verify.
const String kBuildMarker = 'b25 · 2026-06-29 · 退化保护阈值抬到<20列/<8行(挡窄中间帧)';

// kAppVersion is the semver this build reports (matches the v<X.Y.Z> release
// tag), injected at build time from the repo VERSION file via
// `--dart-define=APP_VERSION=$(cat VERSION)` (see scripts/package.*). Unstamped
// local builds report 'dev' — the update check treats that as "never behind".
const String kAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'dev',
);
