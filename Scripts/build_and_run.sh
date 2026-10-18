#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="NeoBar"
CLI_NAME="window-lab"
PROJECT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/NeoBar.xcodeproj"
DERIVED_DATA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build/DerivedData"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Debug/$APP_NAME.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

build_app() {
  # Force the universal product to be re-created on every build. After an `xcodebuild test` has
  # already relinked the per-arch binaries, a plain build can skip CreateUniversalBinary and leave
  # the previous executable in the .app (re-signed below, so its mtime looks fresh) — the launched
  # app then runs old code while the build log says BUILD SUCCEEDED.
  rm -f "$APP_EXECUTABLE"
  xcodebuild -project "$PROJECT_PATH" -scheme "$APP_NAME" -configuration Debug -derivedDataPath "$DERIVED_DATA_DIR" build >/tmp/NeoBar-build.log 2>&1
}

sign_app() {
  # Xcode already signs the Debug build ad hoc (CODE_SIGN_IDENTITY = "-"); nothing to add.
  :
}

run_cli() {
  xcodebuild -project "$PROJECT_PATH" -scheme "$CLI_NAME" -configuration Debug -derivedDataPath "$DERIVED_DATA_DIR" build >/tmp/NeoBar-build.log 2>&1
  "$DERIVED_DATA_DIR/Build/Products/Debug/$CLI_NAME" "$@"
}

# First make sure the old process has really exited before launching. This used to use `open -n` (force a new instance),
# so whenever pkill lagged a beat or an instance launched elsewhere wasn't covered by pkill, two identical
# taskbars would appear on screen, and during acceptance there was no telling which version was being tested.
wait_for_exit() {
  local attempt
  for attempt in $(seq 1 25); do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || return 0
    sleep 0.2
  done
  echo "warning: 旧实例 5 秒内未退出，强制结束" >&2
  pkill -9 -x "$APP_NAME" >/dev/null 2>&1 || true
  sleep 0.3
}

open_app() {
  wait_for_exit
  /usr/bin/open "$APP_BUNDLE"
}

wait_for_app() {
  local attempt
  for attempt in $(seq 1 20); do
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

case "$MODE" in
  run)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
    sign_app
    open_app
    ;;
  --debug|debug)
    build_app
    lldb -- "$APP_EXECUTABLE"
    ;;
  --logs|logs)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
    sign_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
    sign_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"app.neobar.NeoBar\""
    ;;
  --launch-trace|launch-trace)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
    sign_app
    wait_for_exit
    DOCK_LAUNCH_TRACE=1 "$APP_EXECUTABLE" > /tmp/launch-trace.log 2>&1 &
    wait_for_app
    echo "launch trace: /tmp/launch-trace.log"
    ;;
  --verify|verify)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
    sign_app
    open_app
    wait_for_app
    ;;
  --lab|lab)
    run_cli "${@:2}"
    ;;
  --lab-minimize|lab-minimize)
    run_cli minimizeRestore "${@:2}"
    ;;
  --lab-close|lab-close)
    run_cli closeTarget "${@:2}"
    ;;
  --lab-replay|lab-replay)
    run_cli replay "${2:-minimize-restore-replay}"
    ;;
  --lab-placement|lab-placement)
    run_cli placementReplay "${2:-placement-permanent-hold-replay}"
    ;;
  --lab-transition|lab-transition)
    run_cli transitionReplay "${2:-focused-active-replay}"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--launch-trace|--verify|--lab|--lab-minimize|--lab-close|--lab-replay [scenario-name]|--lab-placement [scenario-name]|--lab-transition [scenario-name]]" >&2
    exit 2
    ;;
esac
