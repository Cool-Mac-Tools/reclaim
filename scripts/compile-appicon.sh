#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Resources/CompiledIcons
xcrun actool Resources/Assets.xcassets \
  --compile Resources/CompiledIcons --platform macosx \
  --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist Resources/CompiledIcons/asset-info.plist \
  --output-format human-readable-text
shasum -a 256 Resources/reclaim-icon-full-canvas.png > Resources/CompiledIcons/source.sha256
