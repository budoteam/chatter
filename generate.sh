#!/bin/bash
# Regenerates Chatter.xcodeproj from project.yml.
# Use this instead of calling `xcodegen generate` directly.
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate

# Workaround for an Xcode 26 / macOS 26 debugger bug: the scheme option
# "Enable backtrace recording" (Queue Debugging) corrupts libdispatch state
# and crashes the app under LLDB with
#   -[OS_dispatch_mach_msg _setContext:]: unrecognized selector
# XcodeGen has no spec option for it, so patch the generated scheme directly.
SCHEME="Chatter.xcodeproj/xcshareddata/xcschemes/Chatter.xcscheme"
if [ -f "$SCHEME" ] && ! grep -q "queueDebuggingEnabled" "$SCHEME"; then
  sed -i '' 's/<LaunchAction$/<LaunchAction\
      queueDebuggingEnabled = "No"/' "$SCHEME"
  # Fallback if <LaunchAction has attributes on the same line
  if ! grep -q "queueDebuggingEnabled" "$SCHEME"; then
    sed -i '' 's/<LaunchAction /<LaunchAction queueDebuggingEnabled = "No" /' "$SCHEME"
  fi
  echo "Patched scheme: queue debugging (backtrace recording) disabled"
fi
