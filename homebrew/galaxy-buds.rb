# Homebrew Cask for Galaxy Buds for Mac.
#
# Setup (one time):
#   1. Create a public repo named "homebrew-tap" on your GitHub account.
#   2. Put this file at "Casks/galaxy-buds.rb" in that repo.
#   3. Copy this file into that repo whenever it changes.
#
# On every release: bump `version` and paste the new `sha256` (package.sh
# prints it after building the .dmg), then commit to the tap repo.
#
# Users then install with:
#   brew install --cask vedatkilic/tap/galaxy-buds

cask "galaxy-buds" do
  version "1.1.0"
  sha256 "3c7af65a032e98f8a8a6273df9d28a8590ab9d8fc32ce41baf30b7b6a909a820"

  url "https://github.com/vedatkilic/galaxy-buds-mac/releases/download/v#{version}/Galaxy-Buds-#{version}.dmg"
  name "Galaxy Buds"
  desc "Menu-bar controller for Samsung Galaxy Buds"
  homepage "https://github.com/vedatkilic/galaxy-buds-mac"

  app "Galaxy Buds.app"

  zap trash: [
    "~/Library/Preferences/com.nivorbit.budsapp.plist",
  ]
end
