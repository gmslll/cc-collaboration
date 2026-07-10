// kAppVersion is the semver this build reports (matches the v<X.Y.Z> release
// tag), injected at build time from the repo VERSION file via
// `--dart-define=APP_VERSION=$(cat VERSION)` (see scripts/package.*). Unstamped
// local builds report 'dev' — the update check treats that as "never behind".
const String kAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'dev',
);
