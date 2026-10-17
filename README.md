# Makstat

A macOS menu bar system monitor with a widget and process-killing rules.

The point of Makstat is that it lists processes **by executable name**, not by
app. When everything you run comes out of a terminal, "Terminal is using 40 GB"
is useless; "rustc ×7 is using 40 GB" is what you want to know.

## What it shows

- **Menu bar**: icon plus CPU % (configurable: icon only, CPU, CPU + memory).
- **Popover**: CPU (user/system, per-core, load, sparkline), memory (app, wired,
  compressed, cached, swap, pressure), volumes with free space, disk and network
  throughput, and the heaviest process groups sorted by CPU, memory or disk I/O.
  Expand a group to see each pid with its command line, thread count and a
  terminate/kill menu. Right-click a group to signal all of its processes.
- **Widget** (small, medium, large): the same gauges and top groups, sorted by
  CPU or memory. WidgetKit throttles reloads, so the widget lags behind the
  popover by the configured refresh interval (default 5 minutes).
- **Rules**: watch any process matching a glob (`rustc`, `cargo*`, `*`) for
  memory (physical footprint, like Activity Monitor) or CPU (% of one core)
  crossing a threshold, optionally sustained for N seconds, then notify,
  terminate (SIGTERM, escalating to SIGKILL after 10 s) or kill. Everything a
  rule does is written to the Events log. Names in the protected list are never
  signalled.

Processes owned by other users (including root) are listed by name but cannot
be inspected or signalled without elevated privileges; the footer shows how
many are hidden.

## Building

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
make build            # generates Makstat.xcodeproj and builds Release into build/
make run              # build and launch
make install          # copy to /Applications and launch
```

Signing is set to the Karpeles Lab team in `project.yml`. To build without that
certificate, sign ad hoc:

```sh
xcodegen generate
xcodebuild -project Makstat.xcodeproj -scheme Makstat -configuration Release \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
```

With an ad-hoc signature macOS may ask for permission the first time the app
and the widget share data through their app group container.

## Releases and updates

Pushing a tag such as `v0.2.0` (`make tag VERSION=0.2.0`) runs the Release
workflow, which builds a universal (arm64 + x86_64) binary with the version
taken from the tag and attaches `Makstat-macos-universal.zip` (plus a sha256
sidecar) and `Makstat-macos-universal.dmg` to the GitHub release.

The app checks the latest GitHub release every six hours (and on launch),
shows an "Update to x.y.z" link in the popover and a notification, and on
confirmation downloads the zip, verifies the code signature, swaps the bundle
in place and relaunches. `Makstat --update` does the same without asking.

Signature policy: if the running copy is signed by a team, the update must be
signed by the same team, otherwise it is refused. The workflow uses the same
repository secrets as KarpelesLab/cterm to produce Developer ID signed and
notarized builds that satisfy that check:

| Secret | Content |
|---|---|
| `APPLE_CERTIFICATE_BASE64` | base64 of the "Developer ID Application" certificate exported as .p12 |
| `APPLE_CERTIFICATE_PASSWORD` | password of that .p12 |
| `APPLE_TEAM_ID` | team ID of the certificate |
| `APPLE_ID`, `APPLE_ID_PASSWORD` | Apple ID and app-specific password for `notarytool` |

Without the secrets, releases are ad-hoc signed; those updates install only
on copies that are themselves ad-hoc signed.

## Debug flags

- `Makstat --window` shows the popover content in a regular window and prints
  its window number.
- `Makstat --screenshot <dir>` renders the popover and the settings tabs to PNG
  files and exits. CI uses this to attach screenshots to every build.
- `Makstat --update` installs the latest GitHub release if it is newer, then quits.

## Layout

- `Shared/` samplers and models used by both targets (`SystemSampler`,
  `ProcessSampler`, `Snapshot`, `SharedStore`).
- `Makstat/` the menu bar app: `Monitor` (sampling loop), `RuleEngine`,
  `RuleStore`, SwiftUI views.
- `MakstatWidget/` the WidgetKit extension.

Rules and the event log live in `~/Library/Application Support/Makstat/`.
