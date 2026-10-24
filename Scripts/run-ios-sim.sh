#!/usr/bin/env bash
#
# run-ios-sim.sh — build HermesMobile for the iOS Simulator and launch it.
#
# SwiftPM has no iOS application product type, so `xcodebuild -scheme HermesMobile`
# stops at per-module object files: there is no .app to install. This script
# finishes the job reproducibly:
#
#   1. xcodebuild the package for the iOS Simulator into .build/ios-sim
#   2. link the three module object files into a .app with a generated Info.plist
#   3. ad-hoc sign it, boot a simulator, install and launch
#
# Everything it produces lives under .build/ios-sim/ (gitignored); no source
# files are touched.
#
# Usage:
#   Scripts/run-ios-sim.sh                        # booted device, else first iPhone
#   Scripts/run-ios-sim.sh --device "iPhone 16 Pro"
#   Scripts/run-ios-sim.sh --clean --logs
#
# Options:
#   --device NAME|UDID  Simulator to use (default: booted, else first iPhone)
#   --clean             Delete .build/ios-sim before building
#   --logs              Stream the app's stdout/stderr until it exits (Ctrl-C detaches)
#   --no-open           Do not bring the simulator UI to the front
#   -h, --help          Show this help
#
# Requirements: macOS with Xcode installed (xcodebuild, the iOS Simulator SDK,
# and at least one installed simulator runtime).
#
# If xcode-select points at the Command Line Tools instead of Xcode, this script
# uses /Applications/Xcode.app when it exists. It makes no system-wide changes.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

SCHEME=HermesMobile
BUNDLE_ID=com.hermesmobile.app
APP_NAME=HermesMobile
MIN_IOS=17.0
OUT_DIR=$ROOT/.build/ios-sim
DD=$OUT_DIR/DerivedData
APP=$OUT_DIR/$APP_NAME.app
BUILD_LOG=$OUT_DIR/xcodebuild.log

DEVICE_NAME=
CLEAN=0
FOLLOW_LOGS=0
OPEN_UI=1

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '==> %s\n' "$*"
}

usage() {
    sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'
}

while (($#)); do
    case $1 in
        --device)
            (($# >= 2)) || die "--device needs a simulator name or UDID"
            DEVICE_NAME=$2
            shift 2
            ;;
        --device=*)
            DEVICE_NAME=${1#*=}
            shift
            ;;
        --clean) CLEAN=1; shift ;;
        --logs) FOLLOW_LOGS=1; shift ;;
        --no-open) OPEN_UI=0; shift ;;
        -h | --help) usage; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

[[ $(uname -s) == Darwin ]] || die "the iOS Simulator requires macOS"

# MARK: - Xcode

# xcodebuild follows xcode-select, which may point at the Command Line Tools.
# Prefer an installed Xcode without changing the system-wide selection.
ensure_xcode() {
    if xcodebuild -version >/dev/null 2>&1; then
        return 0
    fi

    local candidate
    for candidate in \
        /Applications/Xcode.app \
        /Applications/Xcode-beta.app \
        "$HOME/Applications/Xcode.app"; do
        if [[ -x "$candidate/Contents/Developer/usr/bin/xcodebuild" ]]; then
            export DEVELOPER_DIR=$candidate/Contents/Developer
            break
        fi
    done

    if ! xcodebuild -version >/dev/null 2>&1; then
        candidate=$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -n 1 || true)
        if [[ -n $candidate && -x "$candidate/Contents/Developer/usr/bin/xcodebuild" ]]; then
            export DEVELOPER_DIR=$candidate/Contents/Developer
        fi
    fi

    xcodebuild -version >/dev/null 2>&1 || die \
        "Xcode is required: xcode-select is '$(xcode-select -p 2>/dev/null || true)'.
       Install Xcode, or select it with: sudo xcode-select -s /Applications/Xcode.app"
}

ensure_xcode
DEV_DIR=${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}
[[ -n $DEV_DIR && -d $DEV_DIR ]] || DEV_DIR=/Applications/Xcode.app/Contents/Developer

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null) || die \
    "the iOS Simulator SDK is unavailable; install it in Xcode > Settings > Components"
[[ -d $SDK ]] || die "the iOS Simulator SDK path does not exist: $SDK"

case $(uname -m) in
    arm64) ARCH=arm64 ;;
    x86_64) ARCH=x86_64 ;;
    *) die "unsupported host architecture: $(uname -m)" ;;
esac

# MARK: - Pick a simulator

list_devices() {
    xcrun simctl list devices available 2>/dev/null
}

udid_from_line() {
    sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\)).*/\1/p'
}

UDID=
if [[ -n $DEVICE_NAME ]]; then
    if [[ $DEVICE_NAME =~ ^[0-9A-Fa-f-]{36}$ ]]; then
        UDID=$DEVICE_NAME
    else
        UDID=$(list_devices | grep -F " $DEVICE_NAME (" | head -n 1 | udid_from_line || true)
    fi
    [[ -n $UDID ]] || die \
        "no available simulator named '$DEVICE_NAME' (see: xcrun simctl list devices available)"
else
    UDID=$(list_devices | sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\)) (Booted).*/\1/p' | head -n 1 || true)
    if [[ -z $UDID ]]; then
        UDID=$(list_devices | grep -E '^[[:space:]]+iPhone ' | grep -v 'unavailable' | head -n 1 | udid_from_line || true)
    fi
    [[ -n $UDID ]] || die \
        "no available iPhone simulator; install a runtime in Xcode > Settings > Components"
fi

# MARK: - Build

if ((CLEAN)); then
    log "cleaning $OUT_DIR"
    rm -rf "$OUT_DIR"
fi
mkdir -p "$OUT_DIR"

log "building $SCHEME for the iOS Simulator ($ARCH)"
if ! xcodebuild \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DD" \
    ARCHS="$ARCH" \
    ONLY_ACTIVE_ARCH=YES \
    build >"$BUILD_LOG" 2>&1; then
    tail -n 40 "$BUILD_LOG" >&2
    die "xcodebuild failed (full log: $BUILD_LOG)"
fi

# MARK: - Collect the module objects

# xcodebuild emits one merged object per Swift target under
# <DerivedData>/Build/Intermediates.noindex/.../<Module>.build/Objects-normal/<arch>/.
# Collect every object in each module's directory so per-file compilation also works.
OBJECTS=()
for module in HermesMobile GeneratedModels HermesLogger; do
    while IFS= read -r dir; do
        [[ -n $dir ]] || continue
        while IFS= read -r obj; do
            OBJECTS+=("$obj")
        done < <(find "$dir" -type f -name '*.o' 2>/dev/null)
    done < <(find "$DD/Build/Intermediates.noindex" -type d \
        -path "*/Debug-iphonesimulator/${module}.build/Objects-normal/${ARCH}*" 2>/dev/null)
done

if ((${#OBJECTS[@]} == 0)); then
    # Fallback: any module objects for this architecture, whatever the layout.
    while IFS= read -r dir; do
        [[ -n $dir ]] || continue
        while IFS= read -r obj; do
            OBJECTS+=("$obj")
        done < <(find "$dir" -type f -name '*.o' 2>/dev/null)
    done < <(find "$DD/Build/Intermediates.noindex" -type d \
        -path "*/Debug-iphonesimulator/*/Objects-normal/${ARCH}*" 2>/dev/null)
fi

((${#OBJECTS[@]} > 0)) || die \
    "xcodebuild produced no object files for $ARCH (see $BUILD_LOG)"

# MARK: - Assemble the .app bundle

log "assembling $APP_NAME.app (${#OBJECTS[@]} object files)"
rm -rf "$APP"
mkdir -p "$APP"

cat >"$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Hermes</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>iPhoneSimulator</string>
    </array>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSRequiresIPhoneOS</key>
    <true/>
    <key>MinimumOSVersion</key>
    <string>${MIN_IOS}</string>
    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>
    <key>UILaunchScreen</key>
    <dict/>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
</dict>
</plist>
PLIST

if ! xcrun --sdk iphonesimulator swiftc \
    -sdk "$SDK" \
    -target "${ARCH}-apple-ios${MIN_IOS}-simulator" \
    -module-name "$APP_NAME" \
    -o "$APP/$APP_NAME" \
    "${OBJECTS[@]}" >"$OUT_DIR/link.log" 2>&1; then
    tail -n 40 "$OUT_DIR/link.log" >&2
    die "linking failed (full log: $OUT_DIR/link.log)"
fi

codesign --force --sign - "$APP" >/dev/null 2>&1 ||
    die "codesign failed for $APP"

# MARK: - Boot and show the simulator

log "booting simulator $UDID"
if ! xcrun simctl bootstatus "$UDID" -b >"$OUT_DIR/boot.log" 2>&1; then
    tail -n 20 "$OUT_DIR/boot.log" >&2
    die "could not boot simulator $UDID (is a runtime installed for this device?)"
fi

# Show the running device: Xcode 27 ships DeviceHub instead of Simulator.app.
if ((OPEN_UI)); then
    if [[ -d "$DEV_DIR/Applications/DeviceHub.app" ]]; then
        open "$DEV_DIR/Applications/DeviceHub.app" >/dev/null 2>&1 || true
    elif [[ -d "$DEV_DIR/Applications/Simulator.app" ]]; then
        open "$DEV_DIR/Applications/Simulator.app" --args -CurrentDeviceUDID "$UDID" >/dev/null 2>&1 || true
    elif open -Ra Simulator >/dev/null 2>&1; then
        open -a Simulator --args -CurrentDeviceUDID "$UDID" >/dev/null 2>&1 || true
    fi
fi

# MARK: - Install and launch

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
log "installing $APP"
xcrun simctl install "$UDID" "$APP" || die "simctl could not install $APP onto $UDID"

log "launching $BUNDLE_ID"
if ((FOLLOW_LOGS)); then
    exec xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID"
fi

LAUNCH_OUT=$(xcrun simctl launch "$UDID" "$BUNDLE_ID") || die "simctl could not launch $BUNDLE_ID"
printf '%s\n' "$LAUNCH_OUT"
log "running on $UDID"
printf '    app: %s\n' "$APP"
