#!/usr/bin/env python3
"""生成 app 图标：画的就是这个 app 干的事 —— 三个站的文章汇成一条时间线。
三条彩色短棒 = 三个来源（蓝 blog / 绿 options / 紫 ai，与 app 内 Palette.site 同色），
下面几条灰线 = 汇成的一条阅读流。亮底深字，与 app 主题一致。
不用外部素材、不联网，重跑结果逐像素一致。"""
from PIL import Image, ImageDraw
import pathlib

S = 1024
BG   = (247, 247, 249)      # 浅底（与 iOS 列表背景同族）
INK  = (28, 30, 36)
DIM  = (196, 199, 206)
BLUE = (10, 122, 255)       # blog —— 与 Palette.accent 同值
GREEN= (38, 153, 89)        # options —— Palette.site("options")
PURP = (140, 89, 217)       # ai —— Palette.site("ai")

img = Image.new("RGB", (S, S), BG)
d = ImageDraw.Draw(img)

M = 168                     # 留白，iOS 会再切圆角
x0, x1 = M, S - M
y0 = M + 30

# ── 上半：三个来源，三根粗短棒并排 ────────────────────────────────────────
BAR_W = 132
GAP   = (x1 - x0 - BAR_W * 3) // 2
BAR_H = 132
for i, c in enumerate((BLUE, GREEN, PURP)):
    bx = x0 + i * (BAR_W + GAP)
    d.rounded_rectangle([bx, y0, bx + BAR_W, y0 + BAR_H], radius=30, fill=c)

# ── 汇流：三根各自向中间收，画成三条渐窄的引线 ────────────────────────────
mid_y = y0 + BAR_H + 96
cx = (x0 + x1) // 2
for i, c in enumerate((BLUE, GREEN, PURP)):
    bx = x0 + i * (BAR_W + GAP) + BAR_W // 2
    d.line([(bx, y0 + BAR_H + 12), (cx, mid_y)], fill=c, width=16)

# ── 下半：汇成的一条阅读流（长短不一的行，像一篇文章）────────────────────
ROW_H, ROW_GAP = 46, 40
widths = (1.00, 0.86, 0.94, 0.70)
ry = mid_y + 52
for i, w in enumerate(widths):
    ww = int((x1 - x0) * w)
    fill = INK if i == 0 else DIM        # 首行当标题，深色
    d.rounded_rectangle([x0, ry, x0 + ww, ry + ROW_H], radius=ROW_H // 2, fill=fill)
    ry += ROW_H + ROW_GAP

out = pathlib.Path("Resources/icon-1024.png")
out.parent.mkdir(parents=True, exist_ok=True)
img.save(out)
print(f"✅ {out} {img.size[0]}x{img.size[1]}")
