#!/bin/bash
# Writes the wink cask for a release into a homebrew-tap checkout and retires the source-build formula.
# Usage: scripts/update-cask.sh TAP_DIR VERSION SHA256
set -euo pipefail
TAP="$1" VERSION="$2" SHA="$3"
mkdir -p "$TAP/Casks"
cat > "$TAP/Casks/wink.rb" <<CASK
cask "wink" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/xinding33/wink/releases/download/v#{version}/Wink-#{version}.zip"
  name "Wink"
  desc "Menu bar app to disconnect and reconnect external displays without unplugging"
  homepage "https://github.com/xinding33/wink"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "Wink.app"

  # Quitting reconnects displays. Wink turns remembered ones off again when it next opens.
  uninstall quit: "io.github.xinding33.wink"

  zap trash: [
    "~/Library/Application Support/Display Switch",
    "~/Library/Application Support/Wink",
    "~/Library/LaunchAgents/io.github.xinding33.wink.plist",
  ]
end
CASK
rm -f "$TAP/Formula/wink.rb"
