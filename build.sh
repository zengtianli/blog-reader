#!/bin/bash
# iOS 模拟器构建：裸 swiftc 直编 + 手搓 .app，不需要 Xcode 工程、不需要 $99 证书。
set -euo pipefail
# ── 挑 Xcode：走总部 SSOT，禁写死路径（铁律 #5）───────────────────────────
#    SSOT: $HOME/Dev/tools/dev/lib/tools/macapp/xcode_env.{py,sh}
#    判据：toolchain 活着 + 有该平台 SDK + 宿主 SDK 不老于当前 macOS + min-sdk。
#    挑不出就在这里硬失败 —— 回落到写死路径只会把失败推迟到真构建那一刻。
_XCODE_ENV_SH=$HOME/Dev/tools/dev/lib/tools/macapp/xcode_env.sh
[ -f "$_XCODE_ENV_SH" ] || { echo "❌ 缺总部 Xcode SSOT $_XCODE_ENV_SH（禁写死 Xcode 路径顶上）" >&2; exit 1; }
# shellcheck source=/dev/null
source "$_XCODE_ENV_SH"
xcode_env_use iphonesimulator
cd "$(dirname "$0")"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
APP=build/BlogReader.app
rm -rf build && mkdir -p "$APP"

# -Xclang-linker -isysroot：swiftc 链接期默认拿 host(MacOSX) 的 sysroot 交给 clang,
# 会报 `using sysroot for 'MacOSX' but targeting 'iPhone'`。显式把 iOS SDK 传下去就干净了。
xcrun swiftc -target arm64-apple-ios18.0-simulator -sdk "$SDK" \
  -Xclang-linker -isysroot -Xclang-linker "$SDK" \
  -O -parse-as-library \
  Sources/Feed.swift Sources/Store.swift Sources/MarkdownView.swift \
  Sources/ContentView.swift Sources/App.swift \
  -o "$APP/BlogReader"

cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>BlogReader</string>
  <key>CFBundleDisplayName</key><string>我的文章</string>
  <key>CFBundleIdentifier</key><string>cyou.tianli.blogreader</string>
  <key>CFBundleExecutable</key><string>BlogReader</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>18.0</string>
  <key>UILaunchScreen</key><dict/>
  <key>UISupportedInterfaceOrientations</key>
  <array><string>UIInterfaceOrientationPortrait</string></array>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
</dict></plist>
PLIST

plutil -lint "$APP/Info.plist" >/dev/null

# ── 图标 ──────────────────────────────────────────────────────────────────
# swiftc 那条路径**不经 actool**,所以图标不会自己进 .app —— 2026-08-18 独立复核
# 挖出来的:图当时只躺在 Assets.xcassets 里,装出来的 app 是没有图标的。
# actool 要求模拟器 runtime 与 SDK 版本匹配(缺就 `xcodebuild -downloadPlatform iOS`)。
xcrun actool Resources/Assets.xcassets \
  --compile "$APP" \
  --platform iphonesimulator \
  --minimum-deployment-target 18.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$APP/../icon-partial.plist" \
  --output-format human-readable-text >/dev/null

# actool 只吐出该合并的键(CFBundleIcons / CFBundleIcons~ipad),得自己并进 Info.plist
python3 - "$APP/Info.plist" "$APP/../icon-partial.plist" <<'PYMERGE'
import plistlib, sys
info_path, partial_path = sys.argv[1], sys.argv[2]
with open(info_path, "rb") as f:
    info = plistlib.load(f)
with open(partial_path, "rb") as f:
    partial = plistlib.load(f)
assert partial, "actool 没吐出任何键 —— 图标没编进去,拒绝当成功"
info.update(partial)
with open(info_path, "wb") as f:
    plistlib.dump(info, f)
print(f"  图标键已并入: {', '.join(sorted(partial))}")
PYMERGE
rm -f "$APP/../icon-partial.plist"

# fail-closed:图标产物必须真的在 .app 里,否则这次构建不算数
for need in Assets.car AppIcon60x60@2x.png; do
  [ -f "$APP/$need" ] || { echo "❌ $need 没进 .app —— 图标构建失败" >&2; exit 1; }
done
echo "✅ 构建完成: $APP ($(du -h "$APP/BlogReader" | cut -f1))"
