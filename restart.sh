#!/bin/bash
# Restart Rhythm — run this anytime the app needs a fresh start
set -e
echo "⏹  Killing Rhythm..."
pkill -9 -f "Rhythm.app" 2>/dev/null || true
pkill -9 -f "notchi.app" 2>/dev/null || true
sleep 1
echo "🔨 Building..."
cd "$(dirname "$0")/notchi"
xcodebuild -scheme notchi -configuration Debug \
  2>&1 | tail -3
APP_PATH="$(find ~/Library/Developer/Xcode/DerivedData/notchi-*/Build/Products/Debug -name 'Rhythm.app' -maxdepth 1 -print0 | xargs -0 ls -td | head -1)"
echo "📦 Installing to /Applications..."
rm -rf /Applications/Rhythm.app
cp -R "$APP_PATH" /Applications/Rhythm.app
echo "🚀 Launching..."
open /Applications/Rhythm.app
echo "✅ Rhythm is running"
