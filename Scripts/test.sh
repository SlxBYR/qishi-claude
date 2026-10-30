#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${QISHI_BUILD_DIR:-$ROOT/.build}"
mkdir -p "$BUILD"
run_motion_tests() {
  command -v node >/dev/null || { printf '%s\n' 'FAIL: Node.js is required for motion tests.' >&2; return 1; }
  node --test "$ROOT/Windows/test/native-motion.test.cjs"
  xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx27.0 \
    -module-cache-path "$BUILD/ModuleCache" "$ROOT/Tests/CompanionWebTests.swift" -o "$BUILD/CompanionWebTests"
  local motion_output="${QISHI_MOTION_TEST_OUTPUT:-$BUILD/MotionVerification}"
  mkdir -p "$motion_output"
  local web_motion_output
  web_motion_output="$("$BUILD/CompanionWebTests" "$ROOT/Resources" "$motion_output")"
  printf '%s\n' "$web_motion_output"
  [[ "$web_motion_output" == *'real WKWebView checks completed'* ]] || { printf '%s\n' 'FAIL: WebKit companion checks did not complete; run in a logged-in macOS desktop session.' >&2; return 1; }
  xcrun swiftc -swift-version 5 -D QISHI_TESTS -parse-as-library -target arm64-apple-macosx27.0 \
    -module-cache-path "$BUILD/ModuleCache" "$ROOT"/Sources/*.swift "$ROOT/Tests/NativeMotionTests.swift" -o "$BUILD/NativeMotionTests"
  local native_motion_output
  native_motion_output="$("$BUILD/NativeMotionTests")"
  printf '%s\n' "$native_motion_output"
  [[ "$native_motion_output" == *'native motion regression tests complete'* ]] || { printf '%s\n' 'FAIL: native motion checks did not complete; run in a logged-in macOS desktop session.' >&2; return 1; }
}
if [[ "${1:-}" == '--motion-only' ]]; then
  run_motion_tests
  exit 0
fi
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$BUILD/ModuleCache" \
  "$ROOT/Sources/Core.swift" "$ROOT/Sources/IMAP.swift" "$ROOT/Sources/DesktopUsage.swift" "$ROOT/Tests/CoreTests.swift" -o "$BUILD/QishiTests"
"$BUILD/QishiTests"
xcrun swiftc -swift-version 5 -parse-as-library -application-extension -target arm64-apple-macosx27.0 \
  -module-cache-path "$BUILD/ModuleCache" "$ROOT/Sources/Core.swift" "$ROOT/Widget/QishiWidget.swift" -o "$BUILD/QishiWidget"
printf '%s\n' 'PASS: WidgetKit extension compiles'
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$BUILD/ModuleCache" \
  "$ROOT/Sources/ClaudeCore.swift" "$ROOT/Sources/ClaudeBridge.swift" "$ROOT/Tests/ClaudeHarness.swift" -o "$BUILD/ClaudeHarness"
python3 "$ROOT/Tests/ClaudeIntegrationTests.py" "$BUILD/ClaudeHarness"
xcrun swiftc -swift-version 5 -D QISHI_TESTS -parse-as-library -target arm64-apple-macosx27.0 \
  -module-cache-path "$BUILD/ModuleCache" "$ROOT"/Sources/*.swift "$ROOT/Tests/LifecycleTests.swift" -o "$BUILD/QishiLifecycleTests"
python3 "$ROOT/Tests/SingleInstanceTests.py" "$BUILD/QishiLifecycleTests"
lifecycle_output="$("$BUILD/QishiLifecycleTests")"
printf '%s\n' "$lifecycle_output"
[[ "$lifecycle_output" == *'PASS: lifecycle integration complete'* ]] || { printf '%s\n' 'FAIL: window-system tests did not complete; run in a logged-in macOS desktop session.' >&2; exit 1; }
run_motion_tests
