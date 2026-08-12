#!/bin/bash
# 构建 + 签名 + 打 dmg 一条龙。
#
# 默认仍使用本机自签证书 "DeepSeekMonitor Dev"（缺证书时回退 ad-hoc），
# 方便开源贡献者本地构建。维护者拿到 Apple Developer 后，可通过环境变量启用
# Developer ID 签名与公证：
#
#   DEVELOPER_ID_APPLICATION="Developer ID Application: Name (TEAMID)"
#   NOTARY_KEYCHAIN_PROFILE="tokenmeter-notary"
#   NOTARIZE=required
#   ./scripts/package.sh
#
# NOTARY_KEYCHAIN_PROFILE 由 `xcrun notarytool store-credentials` 写入 Keychain。
# 也可临时使用 NOTARY_APPLE_ID / NOTARY_TEAM_ID / NOTARY_PASSWORD。
set -euo pipefail

cd "$(dirname "$0")/.."
SELF_SIGN_IDENTITY="${SELF_SIGN_IDENTITY:-DeepSeekMonitor Dev}"
DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-}"
NOTARIZE="${NOTARIZE:-auto}" # auto / required / skip
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-${NOTARY_PROFILE:-}}"
NOTARY_APPLE_ID="${NOTARY_APPLE_ID:-}"
NOTARY_TEAM_ID="${NOTARY_TEAM_ID:-}"
NOTARY_PASSWORD="${NOTARY_PASSWORD:-}"

APP=build/Build/Products/Release/TokenMeter.app
CLEAN_DIR=""
STAGE=""

cleanup() {
    [[ -n "$STAGE" ]] && rm -rf "$STAGE"
    [[ -n "$CLEAN_DIR" ]] && rm -rf "$CLEAN_DIR"
}
trap cleanup EXIT

has_identity() {
    local identity="$1"
    [[ -n "$identity" ]] && security find-identity -v -p codesigning | grep -Fq "$identity"
}

require_notary_credentials() {
    if [[ "$NOTARIZE" == "required" ]]; then
        echo "ERROR: NOTARIZE=required，但未配置 NOTARY_KEYCHAIN_PROFILE 或 NOTARY_APPLE_ID/NOTARY_TEAM_ID/NOTARY_PASSWORD" >&2
        exit 1
    fi
}

sign_app() {
    local app="$1"
    if [[ -n "$DEVELOPER_ID_APPLICATION" ]]; then
        if ! has_identity "$DEVELOPER_ID_APPLICATION"; then
            echo "ERROR: 未找到 Developer ID 证书：$DEVELOPER_ID_APPLICATION" >&2
            exit 1
        fi
        codesign --force --deep --sign "$DEVELOPER_ID_APPLICATION" --options runtime --timestamp "$app"
        return
    fi

    if has_identity "$SELF_SIGN_IDENTITY"; then
        codesign --force --deep --sign "$SELF_SIGN_IDENTITY" --timestamp=none "$app"
    else
        echo "WARN: 未找到证书 ${SELF_SIGN_IDENTITY}，回退 ad-hoc 签名" >&2
        codesign --force --deep --sign - "$app"
    fi
}

maybe_notarize() {
    local dmg="$1"
    if [[ "$NOTARIZE" == "skip" ]]; then
        echo "INFO: NOTARIZE=skip，跳过公证"
        return
    fi
    if [[ -z "$DEVELOPER_ID_APPLICATION" ]]; then
        if [[ "$NOTARIZE" == "required" ]]; then
            echo "ERROR: NOTARIZE=required，但未配置 DEVELOPER_ID_APPLICATION" >&2
            exit 1
        fi
        echo "INFO: 未配置 DEVELOPER_ID_APPLICATION，跳过公证"
        return
    fi

    local args=()
    if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
        args=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
    elif [[ -n "$NOTARY_APPLE_ID" && -n "$NOTARY_TEAM_ID" && -n "$NOTARY_PASSWORD" ]]; then
        args=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
    else
        require_notary_credentials
        echo "WARN: 已使用 Developer ID 签名，但未配置 notary 凭据，跳过公证" >&2
        return
    fi

    xcrun notarytool submit "$dmg" "${args[@]}" --wait
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    spctl -a -vvv -t install "$dmg"
}

xcodegen generate
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
    -configuration Release -derivedDataPath build build | tail -1

VERSION=$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString)

# iCloud 同步目录会给 build 产物挂 com.apple.fileprovider 等顽固扩展属性，
# xattr -cr 清不掉（codesign 报 detritus not allowed）。ditto --noextattr
# 重建一份干净副本再签名。
CLEAN_DIR=$(mktemp -d)
CLEAN="$CLEAN_DIR/TokenMeter.app"
ditto --norsrc --noextattr --noacl "$APP" "$CLEAN"
sign_app "$CLEAN"
codesign -v "$CLEAN"
rm -rf "$APP"
ditto "$CLEAN" "$APP"

DMG="/tmp/TokenMeter_${VERSION}_aarch64.dmg"
STAGE=$(mktemp -d)
ditto "$CLEAN" "$STAGE/TokenMeter.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "TokenMeter" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
hdiutil verify "$DMG"
maybe_notarize "$DMG"

echo "OK: $DMG"
