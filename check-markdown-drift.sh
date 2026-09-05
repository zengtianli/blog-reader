#!/bin/bash
# MarkdownView.swift 是**从 ask-claude 逐字 vendored** 来的,不是这里写的。
# 上游: ~/Apps/mac/ask-claude/Sources/MarkdownView.swift(450 行,纯 SwiftUI 零 AppKit)。
#
# 为什么是复制而不是共享包:两个 app 是**物理独立的 repo**,且 mac 舰队标准是
# 「无 SPM / 无 xcodeproj / swiftc 直编」——为一个文件引入 SPM 不划算。
# 但复制的代价是会漂,所以配这道守卫:逐字节比,不一致即红。
# (先例: ~/Apps/mac/hydro-mac/scripts/check-vendor-drift.sh 守 Rust 计算核。)
#
# 漂了怎么办:先判方向。上游改进 → 直接 cp 过来;本 app 的 iOS 专属需求 →
# **改上游让两边都受益**,别在这里分叉(分叉之后这道门就永远红,红久了人就不看了)。
set -euo pipefail
cd "$(dirname "$0")"
UP=$HOME/Apps/mac/ask-claude/Sources/MarkdownView.swift
MINE=Sources/MarkdownView.swift
[ -f "$UP" ]   || { echo "❌ 上游不在: $UP —— 拒绝在缺源的情况下报绿" >&2; exit 1; }
[ -f "$MINE" ] || { echo "❌ 本地不在: $MINE" >&2; exit 1; }
if cmp -s "$UP" "$MINE"; then
  echo "✅ MarkdownView.swift 与上游 ask-claude 逐字节一致 ($(wc -l < "$MINE" | tr -d ' ') 行)"
else
  echo "🔴 MarkdownView.swift 与上游漂移:" >&2
  diff "$UP" "$MINE" | head -40 >&2
  exit 1
fi
