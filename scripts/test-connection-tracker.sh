#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_binary="$(mktemp /tmp/choice-tracker.XXXXXX)"
trap 'rm -f "$test_binary"' EXIT
swiftc "$project_dir/Sources/Choice/ConnectionTracker.swift" \
  "$project_dir/Sources/Choice/RememberedChoices.swift" \
  "$project_dir/Sources/Choice/AppSettings.swift" \
  "$project_dir/Sources/Choice/AudioDevices.swift" \
  "$project_dir/Sources/Choice/Diagnostics.swift" \
  "$project_dir/Sources/Choice/SingleInstance.swift" \
  "$project_dir/Sources/Choice/GlobalShortcut.swift" \
  "$project_dir/Sources/Choice/LaunchAgentStatus.swift" \
  "$project_dir/Tests/ConnectionTrackerTests.swift" \
  "$project_dir/Tests/RememberedChoicesTests.swift" \
  "$project_dir/Tests/AppSettingsTests.swift" \
  "$project_dir/Tests/GlobalShortcutTests.swift" -framework Carbon -o "$test_binary"
"$test_binary"
