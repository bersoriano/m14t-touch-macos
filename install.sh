#!/usr/bin/env bash
#
# install.sh — build m14ttouch, calibrate, and optionally register a login launch agent.
#
# Usage:
#   ./install.sh              # build release binary and calibrate
#   ./install.sh --autostart  # build, calibrate, and install a LaunchAgent
#
set -euo pipefail
cd "$(dirname "$0")"

DISPLAY_INDEX="${DISPLAY_INDEX:-1}"
LABEL="com.talesfonseca.m14ttouch"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
INSTALL_DIR="$HOME/.local/bin"
APP="$HOME/Applications/M14t Touch.app"
INSTALL_BINARY="$APP/Contents/MacOS/m14ttouch"
CLI_BINARY="$INSTALL_DIR/m14ttouch"
# A real signing identity can preserve grants across rebuilds. Ad-hoc signing
# gives local installs a bundle identity, but changed builds may need approval.
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
AUTOSTART=false
BINARY_UPDATED=false
TWO_FINGER_SCROLL=false
PINCH_ZOOM=false
STYLUS=false
SKIP_CALIBRATION=false

if ! [[ "$DISPLAY_INDEX" =~ ^[0-9]+$ ]]; then
    echo "❌ DISPLAY_INDEX must be a non-negative integer, got: '$DISPLAY_INDEX'" >&2
    exit 1
fi

usage() {
    cat <<EOF
Usage:
  ./install.sh              Build and calibrate display index ${DISPLAY_INDEX}
  ./install.sh --autostart  Build, calibrate, and run automatically at login
  Add --stylus             Enable Gen 1 active stylus
  Add --two-finger-scroll   Enable Gen 1 two-finger scrolling
  Add --pinch-zoom          Enable pinch zoom and two-finger scrolling
  Add --skip-calibration    Keep existing ~/.m14ttouch.json

Set DISPLAY_INDEX=N to target a different display.
Set SIGNING_IDENTITY to a codesigning identity to sign updates consistently.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --autostart)
            AUTOSTART=true
            ;;
        --stylus)
            STYLUS=true
            ;;
        --two-finger-scroll)
            TWO_FINGER_SCROLL=true
            ;;
        --pinch-zoom)
            PINCH_ZOOM=true
            TWO_FINGER_SCROLL=true
            ;;
        --skip-calibration)
            SKIP_CALIBRATION=true
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "❌ Unknown option: $arg" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ "$SKIP_CALIBRATION" == true && ! -s "$HOME/.m14ttouch.json" ]]; then
    echo "❌ No saved calibration; run without --skip-calibration first." >&2
    exit 1
fi
STYLUS_ARGUMENT_XML=""
if [[ "$STYLUS" == true ]]; then
    STYLUS_ARGUMENT_XML="        <string>--stylus</string>"
fi
SCROLL_ARGUMENT_XML=""
if [[ "$TWO_FINGER_SCROLL" == true ]]; then
    SCROLL_ARGUMENT_XML="        <string>--two-finger-scroll</string>"
fi

PINCH_ARGUMENT_XML=""
if [[ "$PINCH_ZOOM" == true ]]; then
    PINCH_ARGUMENT_XML="        <string>--pinch-zoom</string>"
fi

calibration_pid=""

cleanup_calibration() {
    local pid="$calibration_pid"
    calibration_pid=""

    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    kill -TERM "$pid" 2>/dev/null || true

    for _ in {1..30}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done

    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
    fi

    wait "$pid" 2>/dev/null || true
}

trap cleanup_calibration EXIT
trap 'cleanup_calibration; exit 130' INT
trap 'cleanup_calibration; exit 143' TERM

calibrate() {
    echo ""
    echo "🎯 Calibrating display index ${DISPLAY_INDEX}…"
    echo "   Touch all four corners firmly. When the cursor mapping looks right, press Enter here."
    echo "   If macOS asks for Accessibility or Input Monitoring, grant it and rerun this installer."
    echo ""

    "$BINARY" "${DRIVER_ARGS[@]}" --auto-calibrate </dev/null &
    calibration_pid="$!"

    sleep 1
    if ! kill -0 "$calibration_pid" 2>/dev/null; then
        wait "$calibration_pid" || true
        calibration_pid=""
        echo "❌ Calibration could not start. Grant the installed app permissions, then retry." >&2
        exit 1
    fi

    read -r -p "Press Enter when calibration is done… "

    cleanup_calibration
    if [[ ! -s "$HOME/.m14ttouch.json" ]]; then
        echo "❌ No calibration was captured. Check Input Monitoring and touch all four corners." >&2
        exit 1
    fi
    echo "✅ Calibration stopped. Saved calibration: $HOME/.m14ttouch.json"
}

echo "🔨 Building release binary…"
swift build -c release

# Resolve the current index before stopping a working agent. Persist identity,
# since indices change when the main display or connection order changes.
BUILD_BINARY="$(pwd)/.build/release/m14ttouch"
DISPLAY_UUID="$("$BUILD_BINARY" --display "$DISPLAY_INDEX" --print-display-uuid)"
DISPLAY_HARDWARE_ID="$("$BUILD_BINARY" --display-uuid "$DISPLAY_UUID" --print-display-hardware-id)"
DRIVER_ARGS=(--display-uuid "$DISPLAY_UUID")
HARDWARE_ARGUMENT_XML=""
if [[ -n "$DISPLAY_HARDWARE_ID" ]]; then
    DRIVER_ARGS+=(--display-hardware-id "$DISPLAY_HARDWARE_ID")
    HARDWARE_ARGUMENT_XML="        <string>--display-hardware-id</string>
        <string>${DISPLAY_HARDWARE_ID}</string>"
else
    echo "⚠️ Display serial unavailable; reconnect recovery will use UUID only."
fi
if [[ "$STYLUS" == true ]]; then
    DRIVER_ARGS+=(--stylus)
fi
if [[ "$TWO_FINGER_SCROLL" == true ]]; then
    DRIVER_ARGS+=(--two-finger-scroll)
fi

if [[ "$PINCH_ZOOM" == true ]]; then
    DRIVER_ARGS+=(--pinch-zoom)
fi

# Do not run the old login agent alongside the calibration process.
if [[ "$AUTOSTART" == true ]]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
fi

SOURCE_HASH="$(shasum -a 256 "$BUILD_BINARY")"
SOURCE_HASH="${SOURCE_HASH%% *}"
mkdir -p "$INSTALL_DIR" "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ -f "$INSTALL_BINARY" ]] && [[ "$(cat "$APP/Contents/Resources/build-sha256" 2>/dev/null)" == "$SOURCE_HASH" ]] \
    && cmp -s Resources/Info.plist "$APP/Contents/Info.plist" \
    && [[ "$(cat "$APP/Contents/Resources/signing-identity" 2>/dev/null)" == "$SIGNING_IDENTITY" ]] \
    && codesign --verify "$APP" 2>/dev/null; then
    echo "✅ Installed app is unchanged; keeping its signature."
else
    cp "$BUILD_BINARY" "$INSTALL_BINARY"
    printf '%s' "$SOURCE_HASH" > "$APP/Contents/Resources/build-sha256"
    cp Resources/Info.plist "$APP/Contents/Info.plist"
    printf '%s' "$SIGNING_IDENTITY" > "$APP/Contents/Resources/signing-identity"
    chmod +x "$INSTALL_BINARY"
    codesign --force --sign "$SIGNING_IDENTITY" --identifier "$LABEL" "$APP"
    codesign --verify --strict "$APP"
    BINARY_UPDATED=true
fi
# The CLI and LaunchAgent now use the same executable in the same app bundle.
ln -sfn "$INSTALL_BINARY" "$CLI_BINARY"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
BINARY="$INSTALL_BINARY"
echo "✅ Installed: $APP (CLI: $CLI_BINARY)"

if [[ "$SKIP_CALIBRATION" == true ]]; then
    echo "✅ Keeping saved calibration: $HOME/.m14ttouch.json"
else
    calibrate
fi

if [[ "$AUTOSTART" == true ]]; then
    echo "📝 Installing LaunchAgent for display index ${DISPLAY_INDEX}…"
    mkdir -p "$HOME/Library/LaunchAgents"
    BINARY_XML="${BINARY//&/\&amp;}"
    BINARY_XML="${BINARY_XML//</\&lt;}"
    BINARY_XML="${BINARY_XML//>/\&gt;}"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BINARY_XML}</string>
        <string>--display-uuid</string>
        <string>${DISPLAY_UUID}</string>
${HARDWARE_ARGUMENT_XML}
${SCROLL_ARGUMENT_XML}
${PINCH_ARGUMENT_XML}
${STYLUS_ARGUMENT_XML}
        <string>--no-accessibility-prompt</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>Crashed</key>
        <true/>
    </dict>
    <key>StandardInPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/tmp/m14ttouch.err.log</string>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
</dict>
</plist>
EOF
    plutil -lint "$PLIST" >/dev/null
    launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    # bootstrap starts RunAtLoad. Check that process, without restarting it and
    # mistaking a successful launchctl command for a healthy driver.
    sleep 2
    AGENT_STATUS="$(launchctl print "gui/$(id -u)/$LABEL")"
    if [[ "$AGENT_STATUS" != *"state = running"* ]]; then
        echo "⚠️ Autostart registered, but the driver did not stay running." >&2
        tail -n 12 /tmp/m14ttouch.err.log >&2
        echo "   Add $APP to Accessibility and Input Monitoring, then enable it." >&2
        echo "   A terminal's permission does not authorize the login agent." >&2
        echo "   Restart: launchctl kickstart -k gui/$(id -u)/$LABEL" >&2
        exit 1
    fi
    echo "✅ Autostart enabled and driver running. Errors: /tmp/m14ttouch.err.log"
    if [[ "$BINARY_UPDATED" == true && "$SIGNING_IDENTITY" == "-" ]]; then
        echo "   Local ad-hoc builds may need renewed permission after an update."
    fi
    echo "   To disable: launchctl bootout gui/$(id -u) $PLIST && rm $PLIST"
else
    echo ""
    echo "Run it with:"
    echo "  \"$CLI_BINARY\" ${DRIVER_ARGS[*]}"
    echo ""
    echo "Or enable autostart with:"
    echo "  ./install.sh --autostart"
fi
