#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
stage_dir="$project_dir/Sources/Choice/StageManagerFill"
test_binary="$(mktemp /tmp/stage-fill-tests.XXXXXX)"
trap 'rm -f "$test_binary"' EXIT
# -Onone keeps assert() active.
swiftc -Onone "$stage_dir/StageFillGeometry.swift" \
  "$stage_dir/StageFillPreferences.swift" \
  "$stage_dir/StageManagerEnvironment.swift" \
  "$stage_dir/StageStripTracker.swift" \
  "$stage_dir/StagePointerPolicy.swift" \
  "$stage_dir/StageDoubleClickPolicy.swift" \
  "$stage_dir/StageFrameWriter.swift" \
  "$stage_dir/StageRestoreState.swift" \
  "$project_dir/Sources/Choice/AppSettings.swift" \
  "$project_dir/Tests/StageFillTests.swift" \
  -framework AppKit -framework ColorSync -o "$test_binary"
"$test_binary"
