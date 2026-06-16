#!/bin/bash
set -euo pipefail

APP_NAME="BudsApp"
APP_BUNDLE="$APP_NAME.app"
SDK_PATH=$(xcrun --show-sdk-path)

echo "Building $APP_NAME..."

swiftc -parse-as-library \
  -O \
  -target arm64-apple-macosx14.0 \
  -sdk "$SDK_PATH" \
  -framework IOBluetooth \
  -framework CoreBluetooth \
  -framework ServiceManagement \
  -framework AppKit \
  -framework SwiftUI \
  Sources/Models/BudsModel.swift \
  Sources/Models/BudsStatus.swift \
  Sources/Models/NoiseControlMode.swift \
  Sources/Models/EqualizerPreset.swift \
  Sources/Models/TouchControls.swift \
  Sources/Bluetooth/CRC16.swift \
  Sources/Bluetooth/MessageId.swift \
  Sources/Bluetooth/SppMessage.swift \
  Sources/Bluetooth/BluetoothManager.swift \
  Sources/Views/BudsModelUI.swift \
  Sources/Views/CircularBatteryGauge.swift \
  Sources/Views/MenuPopoverView.swift \
  Sources/Views/WizardView.swift \
  Sources/Views/DashboardView.swift \
  Sources/Views/SoundAncView.swift \
  Sources/Views/EarbudControlsView.swift \
  Sources/Views/FindMyEarbudsView.swift \
  Sources/Views/AboutView.swift \
  Sources/Views/PopoverView.swift \
  Sources/App/LaunchAtLogin.swift \
  Sources/App/StatusBarController.swift \
  Sources/App/AppDelegate.swift \
  Sources/App/BudsApp.swift \
  -o "$APP_NAME"

echo "Creating app bundle..."

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

mv "$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
cp Sources/Resources/Info.plist "$APP_BUNDLE/Contents/"
[ -f Sources/Resources/AppIcon.icns ] && cp Sources/Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/"

# Copy localization bundles (*.lproj) so the app follows the Mac's language.
for lproj in Sources/Resources/*.lproj; do
  [ -d "$lproj" ] && cp -R "$lproj" "$APP_BUNDLE/Contents/Resources/"
done

# Ad-hoc code sign so macOS TCC can establish a stable identity for the app.
# Without a signature, TCC cannot read the Info.plist usage strings and the
# app crashes on first Bluetooth access ("missing usage description").
echo "Signing (ad-hoc)..."
codesign --force --sign - \
  --identifier com.nivorbit.budsapp \
  "$APP_BUNDLE"
codesign --verify --verbose "$APP_BUNDLE" 2>&1 | tail -1

echo "Done! Run with: open $APP_BUNDLE"
