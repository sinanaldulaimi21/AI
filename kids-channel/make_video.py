"""Build a 30-second kids video teaching the Arabic letter ب (baa).

Everything is drawn with code (Pillow) and the background music is
synthesised with numpy, so the video can be regenerated or changed at any time.

Usage:  python3 make_video.py            -> out/letter_baa.mp4 + out/thumbnail.png
"""
import math
import os
import subprocess
import wave

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
FONT = os.path.join(HERE, "fonts", "Lalezar-Regular.ttf")

W, H = 1280, 720          # output size
S = 2                     # draw at 2x then downscale = smooth edges
FPS = 30
DUR = 30.0
SR = 44100                # audio sample rate

# Colours
SKY_TOP, SKY_BOT = (110, 196, 250), (205, 238, 255)
GRASS, GRASS_DARK = (124, 200, 82), (96, 172, 62)
INK = (52, 40, 92)
RED = (235, 64, 82)
YELLOW = (255, 210, 30)
ORANGE = (255, 140, 30)
WHITE = (255, 255, 255)


# ---------------------------------------------------------------- helpers
def p(v):
    return int(round(v * S))


def clamp(x, a=0.0, b=1.0):
    return max(a, min(b, x))


def ease_out_back(x):
    x = clamp(x)
    c1 = 1.9
    return 1 + (c1 + 1) * (x - 1) ** 3 + c1 * (x - 1) ** 2


def ease_out_elastic(x):
    x = clamp(x)
    if x in (0, 1):
        return x
    return 2 ** (-10 * x) * math.sin((x * 10 - 0.75) * (2 * math.pi / 3)) + 1


def ease_in_out(x):
    x = clamp(x)
    return x * x * (3 - 2 * x)


def pop(t, start, end, d_in=0.45, d_out=0.35):
    """Scale factor for an element that pops in at `start` and out at `end`."""
    if t < start or t > end:
        return 0.0
    if t < start + d_in:
        return ease_out_back((t - start) / d_in)
    if t > end - d_out:
        return 1 - ease_in_out((t - (end - d_out)) / d_out)
    return 1.0


def font(size):
    return ImageFont.truetype(FONT, p(size), layout_engine=ImageFont.Layout.RAQM)


def text_sprite(text, size, color=INK, stroke=10, hl_color=None, hl_first=None, bbox_text=None):
    """Render Arabic text into an RGBA sprite with a white outline.

    If hl_first is given (e.g. 'ب'), the first (right-most) letter is painted
    in hl_color so kids can see where the letter sits inside the word.
    """
    f = font(size)
    kw = dict(direction="rtl", language="ar")
    sw = p(stroke)
    l, t, r, b = f.getbbox(bbox_text or text, stroke_width=sw, **kw)
    w, h = r - l + 4, b - t + 4
    stroke_mask = Image.new("L", (w, h), 0)
    fill_mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(stroke_mask).text((-l + 2, -t + 2), text, font=f, fill=255,
                                     stroke_width=sw, stroke_fill=255, **kw)
    ImageDraw.Draw(fill_mask).text((-l + 2, -t + 2), text, font=f, fill=255, **kw)

    color_layer = Image.new("RGB", (w, h), color)
    if hl_first:
        # approx. width of the initial form of the letter inside the word
        wl = f.getlength(hl_first + "ـ", **kw) - 0.35 * f.getlength("ـ", **kw)
        x0 = int(r - l + 2 - sw - wl - p(4))
        ImageDraw.Draw(color_layer).rectangle([x0, 0, w, h], fill=hl_color)

    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    out.paste(Image.new("RGBA", (w, h), WHITE + (255,)), (0, 0), stroke_mask)
    out.paste(color_layer, (0, 0), fill_mask)
    # soft drop shadow
    shadow = Image.new("RGBA", (w + p(8), h + p(8)), (0, 0, 0, 0))
    shadow.paste(Image.new("RGBA", (w, h), (40, 30, 80, 70)), (p(6), p(6)), stroke_mask)
    shadow.alpha_composite(out)
    return shadow


def paste(frame, sprite, cx, cy, scale=1.0, alpha=1.0, angle=0.0):
    if scale <= 0.01 or alpha <= 0.01:
        return
    sp = sprite
    if abs(scale - 1) > 1e-3:
        sp = sp.resize((max(1, int(sp.width * scale)), max(1, int(sp.height * scale))),
                       Image.BILINEAR)
    if angle:
        sp = sp.rotate(angle, resample=Image.BICUBIC, expand=True)
    if alpha < 1:
        a = sp.getchannel("A").point(lambda v: int(v * alpha))
        sp = sp.copy()
        sp.putalpha(a)
    frame.alpha_composite(sp, (int(p(cx) - sp.width / 2), int(p(cy) - sp.height / 2)))


# ---------------------------------------------------------------- drawings
def background():
    img = Image.new("RGBA", (p(W), p(H)))
    d = ImageDraw.Draw(img)
    for y in range(p(H)):
        k = y / p(H)
        c = tuple(int(SKY_TOP[i] * (1 - k) + SKY_BOT[i] * k) for i in range(3))
        d.line([(0, y), (p(W), y)], fill=c)
    # rolling hills
    d.ellipse([p(-200), p(560), p(700), p(980)], fill=GRASS_DARK)
    d.ellipse([p(500), p(580), p(1500), p(1000)], fill=GRASS_DARK)
    d.rectangle([0, p(640), p(W), p(H)], fill=GRASS)
    d.ellipse([p(-100), p(600), p(1400), p(760)], fill=GRASS)
    # little flowers
    rng = np.random.default_rng(3)
    for _ in range(26):
        x, y = rng.uniform(20, W - 20), rng.uniform(655, 705)
        c = [(255, 255, 255), (255, 120, 170), (255, 220, 60)][rng.integers(3)]
        for a in range(5):
            ang = a * 2 * math.pi / 5
            fx, fy = x + 6 * math.cos(ang), y + 6 * math.sin(ang)
            d.ellipse([p(fx - 4), p(fy - 4), p(fx + 4), p(fy + 4)], fill=c)
        d.ellipse([p(x - 3), p(y - 3), p(x + 3), p(y + 3)], fill=(255, 190, 0))
    return img


def sun(d, t):
    cx, cy, r = 1150, 105, 52
    for i in range(12):
        a = t * 0.6 + i * math.pi / 6
        pts = [(cx + (r + 12) * math.cos(a - 0.12), cy + (r + 12) * math.sin(a - 0.12)),
               (cx + (r + 38) * math.cos(a), cy + (r + 38) * math.sin(a)),
               (cx + (r + 12) * math.cos(a + 0.12), cy + (r + 12) * math.sin(a + 0.12))]
        d.polygon([(p(x), p(y)) for x, y in pts], fill=(255, 200, 40))
    d.ellipse([p(cx - r), p(cy - r), p(cx + r), p(cy + r)], fill=(255, 222, 60))
    # smiley face
    for ex in (-17, 17):
        d.ellipse([p(cx + ex - 5), p(cy - 14), p(cx + ex + 5), p(cy - 2)], fill=INK)
    d.arc([p(cx - 20), p(cy - 12), p(cx + 20), p(cy + 24)], 20, 160, fill=INK, width=p(5))


def cloud(d, x, y, s=1.0):
    for dx, dy, r in [(0, 0, 38), (40, -18, 46), (85, 0, 38), (42, 12, 40)]:
        d.ellipse([p(x + dx * s - r * s), p(y + dy * s - r * s),
                   p(x + dx * s + r * s), p(y + dy * s + r * s)], fill=WHITE)


def duck(d, x, y, s, t, walking=False, flap=0.0):
    """Cute yellow duck facing left. (x, y) = centre of body."""
    def E(cx, cy, rx, ry, fill):
        d.ellipse([p(x + (cx - rx) * s), p(y + (cy - ry) * s),
                   p(x + (cx + rx) * s), p(y + (cy + ry) * s)], fill=fill)

    def poly(pts, fill):
        d.polygon([(p(x + px * s), p(y + py * s)) for px, py in pts], fill=fill)

    # legs
    step = math.sin(t * 14) * 10 if walking else 0
    for lx, ph in ((-15, 1), (18, -1)):
        o = step * ph
        d.line([p(x + lx * s), p(y + 45 * s), p(x + (lx + o * 0.3) * s), p(y + 75 * s)],
               fill=ORANGE, width=p(7 * s))
        poly([(lx + o * 0.3 - 20, 80), (lx + o * 0.3 + 6, 72), (lx + o * 0.3 + 6, 84)], ORANGE)
    # body + tail
    poly([(60, -10), (95, -40), (80, 10)], YELLOW)
    E(0, 0, 80, 56, YELLOW)
    # wing (flaps)
    wy = -6 - flap * 22
    poly([(-10, 0), (50, wy - 20), (55, wy + 10), (20, 30)], (245, 190, 10))
    # head
    E(-58, -62, 44, 42, YELLOW)
    E(-38, -50, 10, 7, (255, 150, 160))   # cheek
    E(-70, -72, 11, 13, INK)              # eye
    E(-73, -77, 4, 4, WHITE)
    # beak
    poly([(-95, -60), (-130, -52), (-96, -42)], ORANGE)
    # little hat — a bit of Baghdad style
    poly([(-80, -98), (-40, -100), (-46, -128), (-74, -127)], RED)
    E(-60, -130, 7, 7, (255, 220, 60))


def door(d, x, y, s, open_amt):
    fw, fh = 150 * s, 240 * s
    left, top = x - fw / 2, y - fh / 2
    d.rounded_rectangle([p(left - 14 * s), p(top - 14 * s), p(left + fw + 14 * s), p(top + fh)],
                        radius=p(20 * s), fill=(140, 80, 40))
    d.rectangle([p(left), p(top), p(left + fw), p(top + fh)], fill=(255, 236, 170))
    # light rays inside when open
    if open_amt > 0.05:
        for i in range(5):
            d.line([p(left + fw * 0.2 * i + 10 * s), p(top + 10 * s),
                    p(left + fw * 0.2 * i + 10 * s), p(top + fh - 10 * s)],
                   fill=(255, 245, 205), width=p(6 * s))
    # door panel shrinks toward the hinge (left) as it opens
    pw = fw * (1 - 0.85 * open_amt)
    d.rectangle([p(left), p(top), p(left + pw), p(top + fh)], fill=(200, 110, 50))
    if pw > 30 * s:
        for py0 in (0.08, 0.55):
            d.rounded_rectangle([p(left + pw * 0.15), p(top + fh * py0),
                                 p(left + pw * 0.85), p(top + fh * (py0 + 0.37))],
                                radius=p(8 * s), outline=(160, 85, 35), width=p(5 * s))
        kx, ky = left + pw * 0.85, top + fh * 0.52
        d.ellipse([p(kx - 9 * s), p(ky - 9 * s), p(kx + 9 * s), p(ky + 9 * s)], fill=YELLOW)


def house(d, x, y, s, t):
    w, h = 230 * s, 170 * s
    left, top = x - w / 2, y - h / 2 + 40 * s
    # chimney + smoke
    d.rectangle([p(left + w * 0.68), p(top - 120 * s), p(left + w * 0.82), p(top - 30 * s)],
                fill=(150, 70, 60))
    for i in range(4):
        k = (t * 0.6 + i / 4) % 1
        r = (10 + 18 * k) * s
        sx = left + w * 0.75 + math.sin(k * 6 + i) * 10 * s
        sy = top - 130 * s - k * 120 * s
        c = int(235 - 20 * k)
        d.ellipse([p(sx - r), p(sy - r), p(sx + r), p(sy + r)], fill=(c, c, c))
    # walls + roof
    d.rectangle([p(left), p(top), p(left + w), p(top + h)], fill=(255, 190, 110))
    d.polygon([(p(left - 30 * s), p(top + 4 * s)), (p(x), p(top - 125 * s)),
               (p(left + w + 30 * s), p(top + 4 * s))], fill=RED)
    # door
    d.rounded_rectangle([p(x - 28 * s), p(top + h - 95 * s), p(x + 28 * s), p(top + h)],
                        radius=p(14 * s), fill=(150, 85, 45))
    # windows that glow
    glow = int(200 + 55 * (0.5 + 0.5 * math.sin(t * 4)))
    for wx in (left + 25 * s, left + w - 85 * s):
        d.rectangle([p(wx), p(top + 35 * s), p(wx + 60 * s), p(top + 90 * s)],
                    fill=(255, glow, 120), outline=(120, 70, 40), width=p(5 * s))
        d.line([p(wx + 30 * s), p(top + 35 * s), p(wx + 30 * s), p(top + 90 * s)],
               fill=(120, 70, 40), width=p(4 * s))
        d.line([p(wx), p(top + 62 * s), p(wx + 60 * s), p(top + 62 * s)],
               fill=(120, 70, 40), width=p(4 * s))


def star(d, cx, cy, r, color):
    pts = []
    for i in range(10):
        a = -math.pi / 2 + i * math.pi / 5
        rr = r if i % 2 == 0 else r * 0.45
        pts.append((p(cx + rr * math.cos(a)), p(cy + rr * math.sin(a))))
    d.polygon(pts, fill=color)


# ---------------------------------------------------------------- sprites
SP = {}


def build_sprites():
    SP["title"] = text_sprite("حرف الباء", 110, color=RED, stroke=12)
    SP["subtitle"] = text_sprite("ويّا دودو", 60, color=INK, stroke=8)
    SP["baa"] = text_sprite("ب", 300, color=RED, stroke=16)
    SP["baa_nodot"] = text_sprite("ٮ", 300, color=RED, stroke=16, bbox_text="ب")
    SP["forms"] = text_sprite("بـ      ـبـ      ـب", 95, color=INK, stroke=8)
    for key, word in (("w1", "بطة"), ("w2", "باب"), ("w3", "بيت")):
        SP[key] = text_sprite(word, 170, color=INK, stroke=14, hl_color=RED, hl_first="ب")
    SP["bubble"] = text_sprite("ب", 70, color=WHITE, stroke=0)
    SP["recap"] = text_sprite("ب بطة • ب باب • ب بيت", 80, color=INK, stroke=10)
    SP["sub"] = text_sprite("اشترك", 60, color=WHITE, stroke=0)
    SP["bye"] = text_sprite("نشوفكم بالحرف الجاي!", 64, color=RED, stroke=9)

    # the dot = difference between ب and dotless ٮ (same size sprites)
    a = np.asarray(SP["baa"]).astype(int)
    b = np.asarray(SP["baa_nodot"]).astype(int)
    diff = (np.abs(a[..., 3] - b[..., 3]) > 40)
    ys, xs = np.nonzero(diff)
    pad = p(8)
    box = (xs.min() - pad, ys.min() - pad, xs.max() + pad, ys.max() + pad)
    SP["dot"] = SP["baa"].crop(box)
    # where the dot sits relative to the letter centre (in base pixels)
    SP["dot_off"] = ((box[0] + box[2]) / 2 / S - SP["baa"].width / 2 / S,
                     (box[1] + box[3]) / 2 / S - SP["baa"].height / 2 / S)


# ---------------------------------------------------------------- scenes
# timeline (seconds) — also used for sound effects
T_TITLE, T_LETTER, T_DOT, T_FORMS = 0.4, 4.8, 6.2, 7.6
T_W1, T_W2, T_W3, T_OUT = 10.0, 15.0, 20.0, 25.0


def word_scene(frame, d, t, start, key, draw_pic):
    end = start + 5.0
    k = pop(t, start, end)
    if k <= 0:
        return
    # picture on the left, word on the right (Arabic reads right-to-left)
    draw_pic(k, t - start)
    wk = pop(t, start + 0.35, end)
    paste(frame, SP[key], 900, 330 + math.sin(t * 3) * 6, wk)
    # bubble with the letter
    bk = pop(t, start + 1.2, end)
    if bk > 0:
        r = 52 * bk
        d.ellipse([p(900 - r), p(530 - r), p(900 + r), p(530 + r)], fill=RED)
        paste(frame, SP["bubble"], 900, 524, bk)


def render(t, bg):
    frame = bg.copy()
    d = ImageDraw.Draw(frame)
    sun(d, t)
    for i, (cx, cy, sp, sc) in enumerate([(200, 120, 18, 1.0), (650, 80, 11, 0.8),
                                          (1000, 210, 14, 0.7)]):
        x = (cx + t * sp) % (W + 300) - 150
        cloud(d, x, cy, sc)

    # --- intro: duck walks in from the right, title drops
    if t < T_LETTER:
        tx = ease_in_out(t / 2.6)
        dx = 1450 - (1450 - 760) * tx
        walking = t < 2.6
        duck(d, dx, 545 + (abs(math.sin(t * 7)) * -10 if walking else 0), 1.15, t,
             walking=walking, flap=(0.5 + 0.5 * math.sin(t * 12)) if t > 2.8 else 0)
        k = pop(t, T_TITLE, T_LETTER)
        drop = (1 - ease_out_elastic((t - T_TITLE) / 1.2)) * -300
        paste(frame, SP["title"], 640, 210 + drop, 1.0 if t > T_TITLE else 0, k)
        paste(frame, SP["subtitle"], 640, 320, pop(t, 1.6, T_LETTER))

    # --- big letter + falling dot + its three forms
    if T_LETTER <= t < T_W1:
        k = pop(t, T_LETTER, T_W1, d_in=0.8)
        k = ease_out_elastic((t - T_LETTER) / 1.0) if t < T_LETTER + 1.0 else k
        wob = math.sin(t * 2.5) * 3
        cx, cy = 640, 300
        paste(frame, SP["baa_nodot"], cx, cy, k, angle=wob)
        if t >= T_DOT:
            fall = clamp((t - T_DOT) / 0.6)
            bounce = abs(math.sin(clamp((t - T_DOT - 0.6) / 0.5) * math.pi)) * 30 * \
                (1 - clamp((t - T_DOT - 0.6) / 0.5))
            ox, oy = SP["dot_off"]
            y_end = cy + oy * k
            y = -60 + (y_end + 60) * (fall ** 2) - (bounce if fall >= 1 else 0)
            paste(frame, SP["dot"], cx + ox * k, y, k, angle=wob)
        paste(frame, SP["forms"], 640, 590, pop(t, T_FORMS, T_W1))
        # little duck peeking on the side cheering
        duck(d, 1120, 560, 0.75, t, flap=0.5 + 0.5 * math.sin(t * 10))

    # --- words
    def pic_duck(k, lt):
        duck(d, 380, 420 - abs(math.sin(lt * 5)) * 18 * k, 1.5 * k, lt,
             flap=0.5 + 0.5 * math.sin(lt * 10))

    def pic_door(k, lt):
        open_amt = ease_in_out(clamp((lt - 1.0) / 1.0)) * (1 - ease_in_out(clamp((lt - 3.4) / 0.8)))
        door(d, 380, 400, 1.2 * k, open_amt)

    def pic_house(k, lt):
        house(d, 380, 400, 1.25 * k, lt)

    word_scene(frame, d, t, T_W1, "w1", pic_duck)
    word_scene(frame, d, t, T_W2, "w2", pic_door)
    word_scene(frame, d, t, T_W3, "w3", pic_house)

    # --- outro: recap, subscribe button, stars
    if t >= T_OUT:
        lt = t - T_OUT
        paste(frame, SP["recap"], 640, 170, pop(t, T_OUT, DUR + 1))
        paste(frame, SP["bye"], 640, 290, pop(t, T_OUT + 0.8, DUR + 1))
        bk = pop(t, T_OUT + 1.4, DUR + 1) * (1 + 0.06 * math.sin(lt * 8))
        if bk > 0:
            bw, bh = 260 * bk, 90 * bk
            d.rounded_rectangle([p(640 - bw / 2), p(420 - bh / 2), p(640 + bw / 2), p(420 + bh / 2)],
                                radius=p(24 * bk), fill=(230, 33, 23))
            paste(frame, SP["sub"], 640, 414, bk)
        duck(d, 300, 540 - abs(math.sin(lt * 6)) * 25, 1.0, t, flap=0.5 + 0.5 * math.sin(t * 14))
        rng = np.random.default_rng(int(1))
        for i in range(18):
            sx = rng.uniform(60, W - 60)
            sy = (rng.uniform(-200, 0) + lt * rng.uniform(120, 220)) % (H + 40) - 20
            col = [(255, 210, 30), (255, 110, 160), (110, 220, 255), (150, 240, 120)][i % 4]
            star(d, sx, sy, 14 + 6 * math.sin(lt * 5 + i), col)

    # fade from / to white at the very edges
    out = frame.resize((W, H), Image.LANCZOS).convert("RGB")
    fade = min(clamp(t / 0.4), clamp((DUR - t) / 0.6))
    if fade < 1:
        out = Image.blend(Image.new("RGB", (W, H), WHITE), out, fade)
    return out


# ---------------------------------------------------------------- audio
def note_freq(n):
    return 440.0 * 2 ** ((n - 69) / 12)


def tone(freq, dur, vol=0.3, kind="sine"):
    tt = np.arange(int(SR * dur)) / SR
    if kind == "sine":
        w = np.sin(2 * np.pi * freq * tt) + 0.3 * np.sin(4 * np.pi * freq * tt)
    else:  # soft square-ish
        w = np.tanh(3 * np.sin(2 * np.pi * freq * tt)) * 0.6
    env = np.minimum(1, tt / 0.01) * np.exp(-tt * 5)
    return w * env * vol


def add(buf, sig, at):
    i = int(at * SR)
    j = min(len(buf), i + len(sig))
    buf[i:j] += sig[: j - i]


def sfx_pop(vol=0.35):
    tt = np.arange(int(SR * 0.18)) / SR
    f = 400 + 1400 * tt / 0.18
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-tt * 18) * vol


def sfx_whistle_down(vol=0.25):
    tt = np.arange(int(SR * 0.6)) / SR
    f = 1600 - 1100 * tt / 0.6
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * vol * np.minimum(1, (0.6 - tt) * 20)


def sfx_boing(vol=0.4):
    tt = np.arange(int(SR * 0.4)) / SR
    f = 180 + 120 * np.sin(tt * 60) * np.exp(-tt * 8)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-tt * 7) * vol


def sfx_ding(vol=0.3):
    return tone(note_freq(84), 0.8, vol) + tone(note_freq(91), 0.8, vol * 0.5)


def make_audio(path):
    buf = np.zeros(int(SR * DUR))
    bpm = 116
    beat = 60 / bpm
    # happy pentatonic tune in C (MIDI numbers, 0 = rest), 2 bars per line
    melody = [72, 74, 76, 79, 76, 74, 72, 0,
              74, 76, 79, 81, 79, 76, 74, 0,
              76, 79, 81, 84, 81, 79, 76, 74,
              72, 76, 74, 72, 67, 69, 72, 0]
    bass = [48, 48, 55, 55, 45, 45, 53, 55]
    n = 0
    tcur = 0.0
    while tcur < DUR - 1:
        m = melody[n % len(melody)]
        if m:
            add(buf, tone(note_freq(m), beat * 0.9, 0.11), tcur)
        if n % 2 == 0:
            add(buf, tone(note_freq(bass[(n // 4) % len(bass)]), beat * 1.6, 0.13, "square"), tcur)
        if n % 2 == 1:  # soft shaker
            noise = np.random.default_rng(n).normal(0, 1, int(SR * 0.05))
            add(buf, noise * np.exp(-np.arange(len(noise)) / SR * 80) * 0.03, tcur)
        tcur += beat / 2
        n += 1

    for at in (T_TITLE + 0.3, 1.7, T_LETTER + 0.1, T_FORMS, T_W1 + 0.1, T_W1 + 0.4,
               T_W2 + 0.1, T_W2 + 0.4, T_W3 + 0.1, T_W3 + 0.4, T_OUT + 0.1, T_OUT + 1.5):
        add(buf, sfx_pop(), at)
    add(buf, sfx_whistle_down(), T_DOT)
    add(buf, sfx_boing(), T_DOT + 0.6)
    for at in (T_W1 + 1.2, T_W2 + 1.2, T_W3 + 1.2):
        add(buf, sfx_ding(), at)

    # fade out + normalise
    fl = int(SR * 1.2)
    buf[-fl:] *= np.linspace(1, 0, fl)
    buf = buf / max(1e-6, np.abs(buf).max()) * 0.8
    pcm = (buf * 32767).astype(np.int16)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


# ---------------------------------------------------------------- main
def main():
    os.makedirs(OUT, exist_ok=True)
    build_sprites()
    bg = background()
    audio = os.path.join(OUT, "music.wav")
    make_audio(audio)

    video = os.path.join(OUT, "letter_baa.mp4")
    cmd = ["ffmpeg", "-y", "-loglevel", "error",
           "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
           "-i", audio,
           "-c:v", "libx264", "-preset", "medium", "-crf", "21", "-pix_fmt", "yuv420p",
           "-c:a", "aac", "-b:a", "128k", "-shortest", "-movflags", "+faststart", video]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    total = int(DUR * FPS)
    for i in range(total):
        t = i / FPS
        img = render(t, bg)
        proc.stdin.write(img.tobytes())
        if i == int(6.5 * FPS):
            img.save(os.path.join(OUT, "thumbnail.png"))
        if i % 150 == 0:
            print(f"frame {i}/{total}", flush=True)
    proc.stdin.close()
    proc.wait()
    os.remove(audio)
    print("done ->", video)


if __name__ == "__main__":
    main()
