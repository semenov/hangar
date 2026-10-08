"""Renders the 1024x1024 app icon: a stack of three session cards, the top one live, under a Claude-style spark."""
import math, sys
from PIL import Image, ImageDraw, ImageFilter

S = 4096  # supersampled, downscaled at the end
top, bottom = (58, 40, 32), (16, 12, 11)
grad = Image.new("RGB", (512, 512))
gp = grad.load()
for y in range(512):
    for x in range(512):
        t = min(1.0, math.hypot(x * 8 - S * 0.5, y * 8 - S * 0.3) / (S * 0.88)) ** 1.2
        gp[x, y] = tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
img = grad.resize((S, S), Image.BICUBIC).convert("RGBA")

coral, peach, cream, green = (217, 119, 87), (245, 168, 128), (250, 236, 226), (126, 207, 136)
W, H, R = S * 0.64, S * 0.15, S * 0.045
x0 = (S - W) / 2
for i, (y, alpha) in enumerate([(0.45, 255), (0.63, 150), (0.81, 80)]):
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    y0 = S * y - H / 2
    d.rounded_rectangle([x0, y0, x0 + W, y0 + H], R, fill=(255, 255, 255, int(alpha * 0.10)),
                        outline=(255, 255, 255, int(alpha * 0.22)), width=int(S * 0.006))
    dot = (green if i == 0 else peach) + (alpha,)
    cx, cy, r = x0 + H * 0.55, y0 + H / 2, H * 0.17
    if i == 0:  # glow
        glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ImageDraw.Draw(glow).ellipse([cx - r * 2.2, cy - r * 2.2, cx + r * 2.2, cy + r * 2.2], fill=green + (120,))
        layer = Image.alpha_composite(layer, glow.filter(ImageFilter.GaussianBlur(S * 0.02)))
        d = ImageDraw.Draw(layer)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=dot)
    lx = x0 + H * 1.05
    d.rounded_rectangle([lx, cy - H * 0.16, lx + W * 0.42, cy - H * 0.02], H * 0.07, fill=cream + (int(alpha * 0.9),))
    d.rounded_rectangle([lx, cy + H * 0.08, lx + W * 0.28, cy + H * 0.2], H * 0.06, fill=cream + (int(alpha * 0.4),))
    img = Image.alpha_composite(img, layer)

# Spark above the stack.
d = ImageDraw.Draw(img)
c, r = (S / 2, S * 0.215), S * 0.105
for k in range(12):
    a = k * math.pi / 6 - math.pi / 2
    ln = r * (1 if k % 2 == 0 else 0.78)
    d.line([(c[0] + math.cos(a) * r * 0.12, c[1] + math.sin(a) * r * 0.12),
            (c[0] + math.cos(a) * ln, c[1] + math.sin(a) * ln)], fill=coral, width=int(r * 0.2))
    d.ellipse([c[0] + math.cos(a) * ln - r * 0.1, c[1] + math.sin(a) * ln - r * 0.1,
               c[0] + math.cos(a) * ln + r * 0.1, c[1] + math.sin(a) * ln + r * 0.1], fill=coral)

img.convert("RGB").resize((1024, 1024), Image.LANCZOS).save(sys.argv[1] if len(sys.argv) > 1 else "icon.png")
