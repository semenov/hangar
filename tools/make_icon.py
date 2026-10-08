"""Renders the 1024x1024 app icon: a mint arched hangar on a night-blue background, its open
door lit, with three session lights inside."""
import math, sys
from PIL import Image, ImageDraw, ImageFilter

S = 4096  # supersampled, downscaled at the end
top, bottom = (24, 36, 62), (6, 9, 17)
grad = Image.new("RGB", (512, 512))
gp = grad.load()
for y in range(512):
    for x in range(512):
        t = min(1.0, math.hypot(x * 8 - S * 0.5, y * 8 - S * 0.32) / (S * 0.85)) ** 1.15
        gp[x, y] = tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
img = grad.resize((S, S), Image.BICUBIC).convert("RGBA")

mint, mint_dark, sky, amber = (77, 217, 179), (46, 160, 132), (126, 197, 249), (249, 194, 85)
cx, ground = S / 2, S * 0.68
RX, RY = S * 0.34, S * 0.36           # the arch: half an ellipse
box = [cx - RX, ground - RY, cx + RX, ground + RY]

# Hangar silhouette with a soft glow.
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).pieslice(box, 180, 360, fill=255)
glow = Image.new("RGBA", (S, S), mint + (0,))
glow.putalpha(mask.filter(ImageFilter.GaussianBlur(S * 0.035)).point(lambda v: int(v * 0.55)))
img = Image.alpha_composite(img, glow)

body = Image.new("RGBA", (S, S), (0, 0, 0, 0))
# Vertical gradient on the body: lighter at the top.
for y in range(int(ground - RY), int(ground) + 1):
    t = (y - (ground - RY)) / RY
    c = tuple(int(mint[i] * (1 - t * 0.35) + mint_dark[i] * t * 0.35) for i in range(3))
    ImageDraw.Draw(body).line([(0, y), (S, y)], fill=c + (255,))
body.putalpha(mask)
d = ImageDraw.Draw(body)
# Ribs of the corrugated roof: smaller concentric half-ellipses.
for k in (0.8, 0.6):
    d.arc([cx - RX * k, ground - RY * k - RY * (1 - k) * 0.25, cx + RX * k, ground + RY * k],
          180, 360, fill=mint_dark + (255,), width=int(S * 0.012))
img = Image.alpha_composite(img, body)

# Open door, lit from inside.
dw, dh = RX * 0.95, RY * 0.5
door = [cx - dw / 2, ground - dh, cx + dw / 2, ground]
inside = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(inside).rounded_rectangle(door, S * 0.02, fill=(12, 20, 38, 255))
img = Image.alpha_composite(img, inside)
light = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(light).ellipse([cx - dw * 0.55, ground - dh * 0.7, cx + dw * 0.55, ground + dh * 0.6], fill=sky + (90,))
light = light.filter(ImageFilter.GaussianBlur(S * 0.04))
dmask = Image.new("L", (S, S), 0)
ImageDraw.Draw(dmask).rounded_rectangle(door, S * 0.02, fill=255)
light.putalpha(Image.composite(light.getchannel("A"), Image.new("L", (S, S), 0), dmask))
img = Image.alpha_composite(img, light)

# Three session lights inside the door.
lights = Image.new("RGBA", (S, S), (0, 0, 0, 0))
for i, c in enumerate([mint, mint, amber]):
    lx, ly, rr = cx + (i - 1) * dw * 0.28, ground - dh * 0.45, S * 0.03
    g = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(g).ellipse([lx - rr * 2.3, ly - rr * 2.3, lx + rr * 2.3, ly + rr * 2.3], fill=c + (120,))
    lights = Image.alpha_composite(lights, g.filter(ImageFilter.GaussianBlur(S * 0.016)))
    ImageDraw.Draw(lights).ellipse([lx - rr, ly - rr, lx + rr, ly + rr], fill=c + (255,))
img = Image.alpha_composite(img, lights)

# Ground.
g = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(g).rounded_rectangle([S * 0.12, ground + S * 0.014, S * 0.88, ground + S * 0.032], S * 0.009,
                                    fill=(255, 255, 255, 45))
img = Image.alpha_composite(img, g)

img.convert("RGB").resize((1024, 1024), Image.LANCZOS).save(sys.argv[1] if len(sys.argv) > 1 else "icon.png")
