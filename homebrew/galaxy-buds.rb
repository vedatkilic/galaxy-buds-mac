# Homebrew Cask for Galaxy Buds for Mac.
#
# Setup (one time):
#   1. Create a public repo named "homebrew-tap" on your GitHub account.
#   2. Put this file at "Casks/galaxy-buds.rb" in that repo.
#   3. After publishing a GitHub Release with the .dmg, fill in `version` and
#      `sha256` below (package.sh prints the SHA256), then commit.
#
# Users then install with:
#   brew install --cask vedatkilic/tap/galaxy-buds

cask "galaxy-buds" do
  version "1.0.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/vedatkilic/galaxy-buds-mac/releases/download/v#{version}/Galaxy-Buds-#{version}.dmg"
  name "Galaxy Buds"
  desc "Menu-bar controller for Samsung Galaxy Buds"
  homepage "https://github.com/vedatkilic/galaxy-buds-mac"

  app "Galaxy Buds.app"

  zap trash: [
    "~/Library/Preferences/com.nivorbit.budsapp.plist",
  ]
end
