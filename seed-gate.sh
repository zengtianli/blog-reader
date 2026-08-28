#!/bin/bash
# 把访问闸密码喂给手机上的 app 一次 —— 之后它存进 iOS 钥匙串,再也不用喂。
#
# 为什么要这一步:blog-options 整站挂 authgate,app 不带凭证读不到(实测 82 篇一篇都进不来)。
# 为什么密码源是 **macOS 钥匙串**而不是 ~/.personal_env:
#   2026-08-28 实测 XCBuildData 会把构建时的完整环境**连值一起**记进中间产物
#   (当时那里躺着 68 个真实凭证的明文)。凭证进环境变量 = 会跟着构建产物散出去。
#
# 存密码(只做一次):
#   security add-generic-password -U -s tlz-gate -a "$(whoami)" -w '<闸密码>'
#
#   bash seed-gate.sh          # 装机之后跑,或者直接 bash install-to-iphone.sh && bash seed-gate.sh
set -uo pipefail
die() { echo "❌ $*" >&2; exit 1; }
cd "$(dirname "$0")" || exit 1

PW=$(security find-generic-password -s tlz-gate -w 2>/dev/null) \
  || die "macOS 钥匙串里没有 tlz-gate。先存一次:
   security add-generic-password -U -s tlz-gate -a \"\$(whoami)\" -w '<闸密码>'"
[ -n "$PW" ] || die "钥匙串里的 tlz-gate 是空的"

# 先在**本机**验一次密码。不验就喂的话,密码错了的表现是「喂了、没反应」——
# 而 app 那边对错密码是静默丢弃的(存错密码会让它每次刷新都去撞限流)。
CODE=$(curl -s -o /tmp/.seedgate.$$ -w '%{http_code}' --max-time 20 \
       -X POST -d "password=$PW" https://tianli.cyou/_gate/api/login)
OK=$(python3 -c "
import json,sys
try: print('1' if json.load(open('/tmp/.seedgate.$$')).get('ok') else '0')
except Exception: print('0')")
rm -f "/tmp/.seedgate.$$"
[ "$CODE" = "200" ] && [ "$OK" = "1" ] || die "钥匙串里的密码开不了闸(HTTP $CODE) —— 先把它改对"
echo "      ✅ 密码本机验过"

source /Users/tianli/Dev/tools/dev/lib/tools/macapp/xcode_env.sh
xcode_env_use ios >/dev/null

xcrun devicectl list devices --json-output /tmp/.seeddev.$$ >/dev/null 2>&1 \
  || die "列不出设备"
LINE=$(python3 /Users/tianli/Dev/tools/dev/lib/tools/macapp/ios/detect_device.py "/tmp/.seeddev.$$") \
  || die "找不到连着的 iPhone"
rm -f "/tmp/.seeddev.$$"
UDID=$(printf '%s' "$LINE" | cut -d' ' -f1)
BUNDLE=$(sed -n 's/.*PRODUCT_BUNDLE_IDENTIFIER: *//p' project.yml | head -1)
[ -n "$BUNDLE" ] || die "project.yml 里读不出 bundle id"

echo "      喂给 $BUNDLE @ $UDID"
xcrun devicectl device process launch --device "$UDID" "$BUNDLE" \
  -- -gatepw "$PW" >/dev/null 2>&1 \
  || die "启动失败 —— 手机锁着的话先解锁再跑(devicectl 拉不起锁屏设备)"

echo "      ✅ 已喂。app 验过就写进 iOS 钥匙串,以后主屏点开自动带凭证。"
echo "         （这个参数只在这一次启动里存在，不落文件）"
