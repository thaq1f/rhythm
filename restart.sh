#!/bin/bash
# Restart Rhythm (notchi.app) — run this anytime the app needs a fresh start
set -e
echo "⏹  Killing notchi..."
pkill -9 -f "notchi.app" 2>/dev/null || true
sleep 1
echo "🔨 Building..."
cd ~/conductor/workspaces/seiso-02/rhythm/notchi
xcodebuild -scheme notchi -configuration Debug \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  2>&1 | tail -3
echo "🚀 Launching..."
open "$(find ~/Library/Developer/Xcode/DerivedData/notchi-*/Build/Products/Debug -name 'notchi.app' -maxdepth 1)"
echo "✅ Rhythm is running"
