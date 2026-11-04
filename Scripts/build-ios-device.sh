#!/usr/bin/env bash
#
# build-ios-device.sh — build HermesMobile for a physical iOS device and
# assemble a signed .app (optionally a .ipa) for prerelease testing.
#
# SwiftPM has no iOS application product type, so `xcodebuild -scheme
# HermesMobile` stops at per-module object files: there is no .app. This script
# finishes the job the same way Scripts/run-ios-sim.sh does for the simulator:
#
#   1. xcodebuild the package for iphoneos (arm64), signing disabled
#   2. link the module object files into an executable inside a .app with a
#      generated Info.plist
#   3. embed a provisioning profile and codesign (ad-hoc if none is given)
#   4. optionally package Payload/ → .ipa (Ad Hoc / TestFlight upload)
#   5. optionally install onto a connected device with devicectl
#
# Everything it produces lives under .build/ios-device/ (gitignored); no source
# files are touched.
#
# Usage:
#   Scripts/build-ios-device.sh                                  # ad-hoc .app
#   Scripts/build-ios-device.sh --profile ~/Downloads/x.mobileprovision
#   Scripts/build-ios-device.sh --profile x.mobileprovision --ipa
#   Scripts/build-ios-device.sh --configuration Debug --install
#
# Options:
#   --configuration C     Debug or Release (default: Release)
#   --bundle-id ID        CFBundleIdentifier (default: com.hermesmobile.app)
#   --display-name NAME   home-screen name (default: Hermes)
#   --version V           CFBundleShortVersionString (default: 0.1.0)
#   --build N             CFBundleVersion (default: 1)
#   --profile PATH        .mobileprovision to embed; its TeamIdentifier and
#                         Entitlements are used unless overridden below
#   --identity NAME       codesign identity (default: auto-detected
#                         "Apple Development"/"Apple Distribution" certificate)
#   --team ID             Apple team identifier (default: from profile/cert)
#   --entitlements PATH   entitlements plist (default: extracted from profile)
#   --ipa                 also write <App>.ipa next to the .app
#   --install             install the signed .app on a connected device
#   --device UDID         device for --install (default: first paired device)
#   --out DIR             output directory (default: .build/ios-device)
#   --clean               delete the output directory before building
#   -h, --help            show this help
#
# Requirements: macOS with Xcode and the iOS SDK. Installing on a device also
# needs a provisioning profile whose App ID matches --bundle-id and whose device
# list includes that device; create/download it in the Apple Developer portal or
# via Xcode > Settings > Accounts > Manage Certificates/Profiles.
#
# Signing notes:
#   * ad-hoc (`codesign -s -`) output runs only on a jailbroken device or in a
#     simulator — it is useful for inspecting the bundle, not for sideloading.
#   * a development profile needs get-task-allow (it is in the profile).
#   * TestFlight/App Store needs an Apple Distribution profile + an App Store
#     Connect app record; upload the .ipa with `xcrun altool --upload-app` or
#     Transporter.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

SCHEME=HermesMobile
APP_NAME=HermesMobile
MIN_IOS=17.0

BUNDLE_ID=com.hermesmobile.app
DISPLAY_NAME=Hermes
VERSION=0.1.0
BUILD_NUMBER=1
CONFIGURATION=Release

OUT_DIR=$ROOT/.build/ios-device
PROFILE=
IDENTITY=
TEAM_ID=
ENTITLEMENTS=
MAKE_IPA=0
INSTALL=0
DEVICE_UDID=
CLEAN=0

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '==> %s\n' "$*"
}

usage() {
    sed -n '3,58p' "$0" | sed 's/^# \{0,1\}//'
}

need_arg() {
    (($# >= 2)) || die "$1 needs a value"
}

while (($#)); do
    case $1 in
        --configuration) need_arg "$@"; CONFIGURATION=$2; shift 2 ;;
        --configuration=*) CONFIGURATION=${1#*=}; shift ;;
        --bundle-id) need_arg "$@"; BUNDLE_ID=$2; shift 2 ;;
        --bundle-id=*) BUNDLE_ID=${1#*=}; shift ;;
        --display-name) need_arg "$@"; DISPLAY_NAME=$2; shift 2 ;;
        --display-name=*) DISPLAY_NAME=${1#*=}; shift ;;
        --version) need_arg "$@"; VERSION=$2; shift 2 ;;
        --version=*) VERSION=${1#*=}; shift ;;
        --build) need_arg "$@"; BUILD_NUMBER=$2; shift 2 ;;
        --build=*) BUILD_NUMBER=${1#*=}; shift ;;
        --profile) need_arg "$@"; PROFILE=$2; shift 2 ;;
        --profile=*) PROFILE=${1#*=}; shift ;;
        --identity) need_arg "$@"; IDENTITY=$2; shift 2 ;;
        --identity=*) IDENTITY=${1#*=}; shift ;;
        --team) need_arg "$@"; TEAM_ID=$2; shift 2 ;;
        --team=*) TEAM_ID=${1#*=}; shift ;;
        --entitlements) need_arg "$@"; ENTITLEMENTS=$2; shift 2 ;;
        --entitlements=*) ENTITLEMENTS=${1#*=}; shift ;;
        --ipa) MAKE_IPA=1; shift ;;
        --install) INSTALL=1; shift ;;
        --device) need_arg "$@"; DEVICE_UDID=$2; shift 2 ;;
        --device=*) DEVICE_UDID=${1#*=}; shift ;;
        --out) need_arg "$@"; OUT_DIR=$2; shift 2 ;;
        --out=*) OUT_DIR=${1#*=}; shift ;;
        --clean) CLEAN=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

[[ $(uname -s) == Darwin ]] || die "iOS device builds require macOS"

case $CONFIGURATION in
    Debug | Release) ;;
    *) die "--configuration must be Debug or Release (got '$CONFIGURATION')" ;;
esac

# MARK: - Xcode

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

    xcodebuild -version >/dev/null 2>&1 || die \
        "Xcode is required: xcode-select is '$(xcode-select -p 2>/dev/null || true)'.
       Install Xcode, or select it with: sudo xcode-select -s /Applications/Xcode.app"
}

ensure_xcode
SDK=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null) || die \
    "the iOS SDK is unavailable; install it in Xcode > Settings > Components"
[[ -d $SDK ]] || die "the iOS SDK path does not exist: $SDK"

# MARK: - Signing inputs

PROFILE_TMP=
cleanup() {
    [[ -n $PROFILE_TMP && -f $PROFILE_TMP ]] && rm -f "$PROFILE_TMP"
    return 0
}
trap cleanup EXIT

profile_field() {
    # profile_field <plist-path> <key-path>; prints nothing when absent
    plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}

if [[ -n $PROFILE ]]; then
    [[ -f $PROFILE ]] || die "provisioning profile not found: $PROFILE"
    PROFILE_TMP=$(mktemp -t hermes-profile)
    security cms -D -i "$PROFILE" >"$PROFILE_TMP" 2>/dev/null ||
        die "could not decode $PROFILE (is it a .mobileprovision?)"

    if [[ -z $TEAM_ID ]]; then
        TEAM_ID=$(profile_field "$PROFILE_TMP" TeamIdentifier.0)
    fi

    if [[ -z $ENTITLEMENTS ]]; then
        ENTITLEMENTS=$OUT_DIR/entitlements.plist
        plutil -extract Entitlements xml1 -o "$ENTITLEMENTS" "$PROFILE_TMP" 2>/dev/null ||
            die "could not read Entitlements from $PROFILE"
    fi
fi

if [[ -z $TEAM_ID ]]; then
    TEAM_ID=$(security find-certificate -c "Apple Development" -p 2>/dev/null |
        openssl x509 -noout -subject 2>/dev/null |
        sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p' || true)
fi

if [[ -z $IDENTITY ]]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null |
        sed -n 's/.*"\(Apple \(Development\|Distribution\): [^"]*\)"/\1/p' | head -n 1 || true)
fi

if ((INSTALL)) && [[ -z $PROFILE ]]; then
    die "--install needs --profile: an ad-hoc signature cannot be installed on a device"
fi

# MARK: - Build

if ((CLEAN)); then
    log "cleaning $OUT_DIR"
    rm -rf "$OUT_DIR"
fi
mkdir -p "$OUT_DIR"

DD=$OUT_DIR/DerivedData
APP=$OUT_DIR/$APP_NAME.app
BUILD_LOG=$OUT_DIR/xcodebuild.log

log "building $SCHEME for iphoneos ($CONFIGURATION, arm64)"
if ! xcodebuild \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    build >"$BUILD_LOG" 2>&1; then
    tail -n 40 "$BUILD_LOG" >&2
    die "xcodebuild failed (full log: $BUILD_LOG)"
fi

# MARK: - Collect the module objects

OBJECTS=()
while IFS= read -r obj; do
    OBJECTS+=("$obj")
done < <(find "$DD/Build/Intermediates.noindex" \
    -type f -name '*.o' \
    -path "*/${CONFIGURATION}-iphoneos/*/Objects-normal/arm64/*" 2>/dev/null | sort -u)

((${#OBJECTS[@]} > 0)) || die \
    "xcodebuild produced no object files (see $BUILD_LOG)"

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
    <string>${DISPLAY_NAME}</string>
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
    <string>${VERSION}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>iPhoneOS</string>
    </array>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>ITSAppUsesNonExemptEncryption</key>
    <false/>
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
    <key>UIRequiredDeviceCapabilities</key>
    <array>
        <string>arm64</string>
    </array>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
</dict>
</plist>
PLIST

log "linking $APP_NAME"
if ! xcrun --sdk iphoneos swiftc \
    -sdk "$SDK" \
    -target "arm64-apple-ios${MIN_IOS}" \
    -module-name "$APP_NAME" \
    -o "$APP/$APP_NAME" \
    "${OBJECTS[@]}" >"$OUT_DIR/link.log" 2>&1; then
    tail -n 40 "$OUT_DIR/link.log" >&2
    die "linking failed (full log: $OUT_DIR/link.log)"
fi

# MARK: - Sign

if [[ -n $PROFILE ]]; then
    cp "$PROFILE" "$APP/embedded.mobileprovision"
    [[ -n $IDENTITY ]] || die \
        "no codesigning identity found; pass --identity \"Apple Development: …\""

    log "signing with '$IDENTITY'${TEAM_ID:+ (team $TEAM_ID)}"
    SIGN_ARGS=(--force --sign "$IDENTITY" --timestamp=none)
    [[ -n $ENTITLEMENTS && -f $ENTITLEMENTS ]] && SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
    if ! codesign "${SIGN_ARGS[@]}" "$APP" >"$OUT_DIR/codesign.log" 2>&1; then
        tail -n 20 "$OUT_DIR/codesign.log" >&2
        die "codesign failed (full log: $OUT_DIR/codesign.log)"
    fi
    codesign --verify --deep --strict "$APP" ||
        die "codesign verification failed for $APP"
    SIGNED=1
else
    log "no --profile given: signing ad-hoc (not installable on a device)"
    codesign --force --sign - "$APP" >/dev/null 2>&1 ||
        die "codesign failed for $APP"
    SIGNED=0
fi

# MARK: - Package an .ipa

if ((MAKE_IPA)); then
    IPA=$OUT_DIR/$APP_NAME-$VERSION-$BUILD_NUMBER.ipa
    log "packaging $IPA"
    rm -rf "$OUT_DIR/Payload" "$IPA"
    mkdir -p "$OUT_DIR/Payload"
    cp -R "$APP" "$OUT_DIR/Payload/"
    (cd "$OUT_DIR" && zip -qry "$IPA" Payload) || die "could not create $IPA"
    rm -rf "$OUT_DIR/Payload"
fi

# MARK: - Install on a device

if ((INSTALL)); then
    if [[ -z $DEVICE_UDID ]]; then
        DEVICE_UDID=$(xcrun devicectl list devices 2>/dev/null |
            awk '/physical/ && /available/ {print $3; exit}')
    fi
    [[ -n $DEVICE_UDID ]] || die \
        "no connected device found (see: xcrun devicectl list devices)"

    log "installing on $DEVICE_UDID"
    xcrun devicectl device install app --device "$DEVICE_UDID" "$APP" ||
        die "devicectl could not install $APP"
    printf '    launch with:\n'
    printf '      xcrun devicectl device process launch --device %s %s\n' \
        "$DEVICE_UDID" "$BUNDLE_ID"
fi

# MARK: - Summary

log "done"
printf '    app:  %s\n' "$APP"
((MAKE_IPA)) && printf '    ipa:  %s\n' "$IPA"
if ((SIGNED == 0)); then
    printf '\n    Signed ad-hoc — copy it anywhere, but it will not install on a device.\n'
    printf '    For a device build supply a provisioning profile:\n'
    printf '      %s --profile ~/Downloads/Hermes_Development.mobileprovision --ipa\n' "$0"
fi
