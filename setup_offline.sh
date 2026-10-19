#!/usr/bin/env bash
# یک‌بار با اینترنت اجرا شود؛ بعد از آن پروژه کاملاً آفلاین است.
# نسخه را قفل کنید:  V=<نسخه> ./setup_offline.sh
set -e
mkdir -p web/mediapipe assets/audio assets/fonts
T=$(mktemp -d)
(cd "$T" && npm pack "@mediapipe/tasks-vision@${V:-latest}" && tar xzf ./*.tgz)
echo "نسخهٔ دریافت‌شده: $(grep '"version"' "$T/package/package.json")  ← همین را در V قفل کنید"
cp -r "$T/package/wasm" web/mediapipe/wasm
cp "$T/package/vision_bundle.mjs" web/mediapipe/
curl -L -o web/mediapipe/pose_landmarker_full.task \
  https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_full/float16/latest/pose_landmarker_full.task
echo "حالا: افزودن <script type=\"module\" src=\"pose_bridge.js\"></script> به web/index.html"
echo "سپس: flutter build web --release --no-web-resources-cdn"
