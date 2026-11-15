#!/usr/bin/env python3
"""Composes the App Store and Google Play screenshots, the images for the top
of the App Store's product page and for its search results, Google Play's
feature graphic and its app icon, from the raw screens run.sh took.

    tool/store_screenshots/compose.py [locale ...]

Reads build/store-screenshots/raw/<device>/<locale>/*.png and
captions/<locale>.json, lays each screenshot out as a web page (a caption,
set left, above the screen in a drawn device that runs off the bottom edge)
and has headless Google Chrome render it at the size the store takes. The
results are build/store-screenshots/out/<device>/<locale>/NN-<shot>.jpg
(`android` for Google Play, a generic phone with a punch-hole camera), and
out/creative/<locale>/header.png and search.jpg, which show three iPhones
on the same background, the search one beside the caption of the first
screenshot, and feature.png, Google Play's, which shows three Android
screens beside it (CREATIVE). Google Play takes up to eight screenshots, and
SHOTS has seven, so both stores show the same ones. out/play-icon.png is
Google Play's app icon. Without arguments it composes every locale run.sh
has taken. Needs Google Chrome, ImageMagick 7 (`magick`) and resvg.

The photos on the simulated card are vivid ones, and a screen full of them
outshines its caption, so each screen is shown a little calmer than the
simulator took it (TONE).

A locale is one of the app's (app/l10n.yaml). The chips of the first shot
name the app's features as its messages for that locale do.
"""

import html
import json
import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
WORK = ROOT / "build" / "store-screenshots"
FONTS = ROOT / "app" / "assets" / "fonts"
L10N = ROOT / "app" / "lib" / "l10n"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# The sizes App Store Connect takes for the 6.9-inch iPhone, the 13-inch
# iPad and the open iPhone Duo, which are also what the simulators'
# screenshots measure, and the one Google Play takes for a phone (9:16, at
# least 1080 px a side for the listing to be promoted, where an emulator's
# screen is taller), and the type unit of each as a share of a hundredth of
# its width: less on the wider canvases, so the caption keeps its
# proportions, and less on Google Play's, which asks for captions that take
# up no more than a fifth of a screenshot.
DEVICES = {
    "iphone": {"width": 1320, "height": 2868, "unit": 1.0},
    "ipad": {"width": 2064, "height": 2752, "unit": 0.7},
    "duo": {"width": 2853, "height": 2007, "unit": 0.5},
    "android": {"width": 1080, "height": 1920, "unit": 0.84},
}

# Each shot in the order of the listing: its caption key, its layout, the raw
# screens it shows and the colour of its glow.
SHOTS = [
    (
        "overview",
        "trio",
        ["look-editor-colour", "live-view", "library"],
        "#6EA8FF",
    ),
    ("library", "single", ["library"], "#FFB454"),
    ("viewer", "single", ["viewer"], "#FF7A59"),
    ("live-view", "single", ["live-view"], "#5BD08B"),
    ("looks", "single", ["looks-loaded"], "#B48CFF"),
    ("look-editor", "single", ["look-editor-colour"], "#FFD166"),
    (
        "geotagging",
        "pair",
        ["viewer-map", "lock-screen"],
        "#4FD1C5",
    ),
]

# The screens a device shows in a shot instead of those above. The open
# iPhone Duo has the photo beside the Library's grid, where the others open
# the viewer on it.
SCREENS_ON = {"duo": {"viewer": ["library-shot"]}}

# How much calmer a screen is shown than it was taken, each a fraction: the
# chroma every colour loses, the further share a fully saturated one loses
# (what tames neon signs), the further share yellow loses, and the lightness
# a fully saturated colour loses. The app's own greys are left as they are.
TONE = {"chroma": 0.05, "vivid": 0.20, "yellow": 0.14, "light": 0.05}

# The app's messages that name the features on the first shot's chips.
CHIPS = ["libraryTitle", "shootModeLiveView", "looksTitle", "geotagNoticeChannel"]

# The system fonts that stand in where Inter has no glyphs.
FALLBACK_FONTS = {
    "ja": "'Hiragino Sans'",
    "ko": "'Apple SD Gothic Neo'",
    "zh": "'PingFang SC'",
    "zh_Hant": "'PingFang TC'",
    "th": "'Thonburi'",
}

CSS = """
@font-face { font-family: Inter; font-weight: 400; src: url('%(fonts)s/Inter-Regular.ttf'); }
@font-face { font-family: Inter; font-weight: 500; src: url('%(fonts)s/Inter-Medium.ttf'); }
@font-face { font-family: Inter; font-weight: 600; src: url('%(fonts)s/Inter-SemiBold.ttf'); }
@font-face { font-family: Inter; font-weight: 700; src: url('%(fonts)s/Inter-Bold.ttf'); }
@font-face { font-family: Mono; src: url('%(fonts)s/JetBrainsMono-Medium.ttf'); }
* { box-sizing: border-box; }
html, body { margin: 0; }
body {
  width: %(width)spx; height: %(height)spx; overflow: hidden; position: relative;
  display: flex; flex-direction: column;
  background: #0A0A0B; color: #F3F1EC; font-family: Inter, %(fallback)s sans-serif;
  -webkit-font-smoothing: antialiased;
}
.glow {
  position: absolute; inset: 0;
  background:
    radial-gradient(ellipse 75%% 38%% at 92%% 30%%, color-mix(in srgb, %(glow)s 34%%, transparent), transparent 72%%),
    radial-gradient(ellipse 80%% 30%% at 10%% 104%%, color-mix(in srgb, %(glow)s 18%%, transparent), transparent 70%%);
}
.caption { position: relative; flex: none; padding: calc(var(--u) * 10.5) 8%% 0; }
.label {
  margin-bottom: calc(var(--u) * 3.2); font-family: Mono, %(fallback)s monospace;
  font-size: calc(var(--u) * 2.9); letter-spacing: .14em; text-transform: uppercase;
  color: %(glow)s;
}
h1 {
  margin: 0; font-weight: 700; font-size: calc(var(--u) * 10.8); line-height: 1;
  letter-spacing: -0.042em; text-wrap: balance;
}
/* Japanese and Korean break between phrases and words, not inside them. */
:lang(ja) :is(h1, p) { word-break: auto-phrase; }
:lang(ko) :is(h1, p) { word-break: keep-all; }
:is(:lang(ja), :lang(ko), :lang(zh), :lang(th)) h1 { letter-spacing: 0; line-height: 1.16; }
.phrase { display: inline-block; }
p {
  margin: calc(var(--u) * 2.8) 0 0; max-width: 84%%; font-weight: 400;
  font-size: calc(var(--u) * 4.05); line-height: 1.32; color: #B4B2AC; text-wrap: pretty;
}
.chips {
  margin-top: calc(var(--u) * 3.6); display: flex; flex-wrap: wrap; gap: calc(var(--u) * 1.4);
  white-space: nowrap;
}
.chip {
  padding: calc(var(--u) * 1.3) calc(var(--u) * 2.6); border-radius: 999px; font-weight: 600;
  font-size: calc(var(--u) * 3.1); background: rgba(255,255,255,.07);
  border: calc(var(--u) * .12) solid rgba(255,255,255,.13); color: #F3F1EC;
}
/* What the caption leaves of the canvas: the devices are sized by its height. */
.stage { position: relative; flex: 1; min-height: 0; container-type: size; }
.device {
  --w: calc(var(--h) * var(--aspect) * 1cqh);
  position: absolute; left: calc(var(--x) * 1cqw); top: calc(var(--y) * 1cqh); width: var(--w);
  transform: translateX(-50%%) rotate(var(--r, 0deg)); transform-origin: 50%% 30%%;
  padding: calc(var(--w) * var(--bezel)); background: #050506;
  border-radius: calc(var(--w) * var(--radius));
  box-shadow:
    0 0 0 calc(var(--w) * .0035) #4A4A50,
    0 0 0 calc(var(--w) * .0095) #19191C,
    0 calc(var(--w) * .05) calc(var(--w) * .16) rgba(0,0,0,.72);
}
.device img {
  display: block; width: 100%%;
  border-radius: calc(var(--w) * (var(--radius) - var(--bezel)));
}
.device.back { filter: brightness(.74); }
.iphone { --bezel: .021; --radius: .152; }
.ipad { --bezel: .028; --radius: .062; }
.duo { --bezel: .011; --radius: .043; }
.android { --bezel: .024; --radius: .118; }
/* The fold of the open display. */
.duo::after {
  content: ""; position: absolute; top: calc(var(--w) * var(--bezel));
  bottom: calc(var(--w) * var(--bezel)); left: calc(50%% - var(--w) * .006);
  width: calc(var(--w) * .012);
  background: linear-gradient(to right, transparent, rgba(0,0,0,.22) 45%%,
    rgba(255,255,255,.05) 62%%, transparent);
}
.iphone .island {
  position: absolute; left: 50%%; top: calc(var(--w) * (var(--bezel) + .0305));
  width: calc(var(--w) * .276); height: calc(var(--w) * .081);
  transform: translateX(-50%%); border-radius: 999px; background: #000;
}
/* A generic Android phone: a punch-hole camera in the middle of the status
   bar, and the power key above the volume rocker on its right edge. */
.android .hole {
  position: absolute; left: 50%%; top: calc(var(--w) * (var(--bezel) + .062));
  width: calc(var(--w) * .036); height: calc(var(--w) * .036);
  transform: translate(-50%%, -50%%); border-radius: 50%%;
  background: radial-gradient(circle at 40%% 38%%, #23262E, #000 62%%);
}
.android::before, .android::after {
  content: ""; position: absolute; right: calc(var(--w) * -.014);
  width: calc(var(--w) * .012); border-radius: calc(var(--w) * .006);
  background: #26262A;
}
.android::before { top: 20%%; height: 7%%; }
.android::after { top: 30%%; height: 14%%; }
"""

# Where the devices of each layout stand on the stage, the part of the canvas
# below the caption: centre x as a fraction of its width, top and height as
# fractions of its height, and a turn in degrees. A device alone is taller
# than the stage, so the canvas cuts it off.
LAYOUTS = {
    "iphone": {
        "single": [(0.5, 0.045, 1.1, 0, "")],
        "trio": [
            (0.16, 0.185, 0.80, -8, "back"),
            (0.84, 0.185, 0.80, 8, "back"),
            (0.5, 0.085, 0.88, 0, ""),
        ],
        "pair": [(0.295, 0.03, 0.68, 0, ""), (0.705, 0.26, 0.68, 0, "")],
    },
    "ipad": {
        "single": [(0.5, 0.05, 1.04, 0, "")],
        "trio": [
            (0.16, 0.2, 0.71, -6, "back"),
            (0.84, 0.2, 0.71, 6, "back"),
            (0.5, 0.1, 0.82, 0, ""),
        ],
        "pair": [(0.3, 0.04, 0.58, 0, ""), (0.7, 0.35, 0.58, 0, "")],
    },
    "duo": {
        "single": [(0.5, 0.05, 1.1, 0, "")],
        "trio": [
            (0.12, 0.24, 0.76, -5, "back"),
            (0.88, 0.24, 0.76, 5, "back"),
            (0.5, 0.1, 0.94, 0, ""),
        ],
        "pair": [(0.67, 0.03, 0.62, 0, ""), (0.33, 0.42, 0.62, 0, "")],
    },
    # The canvas is shorter for its width than an iPhone's, so the stage is
    # too, and the phones stand taller on it to be as wide.
    "android": {
        "single": [(0.5, 0.045, 1.24, 0, "")],
        "trio": [
            (0.16, 0.185, 0.92, -8, "back"),
            (0.84, 0.185, 0.92, 8, "back"),
            (0.5, 0.075, 1.0, 0, ""),
        ],
        "pair": [(0.3, 0.03, 0.76, 0, ""), (0.7, 0.24, 0.76, 0, "")],
    },
}


# The creative assets of each store: the App Store's image at the top of the
# product page and the one in search results, and Google Play's feature
# graphic. Each has the device whose screens it shows and what they are shown
# in, the size the store takes, its art safe area as left, top, width and
# height (the store may crop everything outside it), the screens it shows,
# each with its centre x, top and width in pixels, its turn and its class,
# and the box its words are centred in with the size of their type unit,
# when it has words.
#
# App Store Connect Help (Creative assets specifications) gives the App
# Store's safe areas. An iPhone in portrait shows much more than the safe
# area: the whole search image, and the header's full height and middle two
# thirds, under the status bar and the page's buttons (Apple's renders in App
# Store asset best practices). So the phones are sized for that view and run
# out of the safe area, and only the words are kept inside it.
#
# Google Play shows the feature graphic in a wide card above the listing and
# in collections of apps, where formats crop its edges and lay their own
# controls over it, and asks for no device imagery and no pure black or dark
# grey, which melt into the store's own background (Play Console Help, Add
# preview assets to showcase your app). So the screens are bare, on a deep
# blue, and the words keep clear of the edges.
CREATIVE = {
    "header": {
        "device": "iphone",
        "frame": "iphone",
        "size": (3840, 1646),
        "safe": (1097, 493, 1646, 661),
        "phones": [
            ("look-editor-colour", 1180, 700, 760, -7, "back"),
            ("live-view", 2660, 700, 760, 7, "back"),
            ("library", 1920, 560, 900, 0, ""),
        ],
        "words": None,
    },
    "search": {
        "device": "iphone",
        "frame": "iphone",
        "size": (3840, 2560),
        "safe": (836, 765, 2168, 1030),
        "phones": [
            ("look-editor-colour", 2480, 820, 800, -7, "back"),
            ("live-view", 3540, 820, 800, 7, "back"),
            ("library", 3010, 640, 1000, 0, ""),
        ],
        "words": ((860, 765, 1120, 1030), 19),
    },
    "feature": {
        "device": "android",
        "frame": "screen",
        "size": (1024, 500),
        "safe": (64, 48, 896, 404),
        "phones": [
            ("look-editor-colour", 668, 112, 184, -7, "back"),
            ("live-view", 932, 112, 184, 7, "back"),
            ("library", 800, 64, 216, 0, ""),
        ],
        "words": ((72, 48, 470, 404), 4.4),
    },
}
CREATIVE_GLOW = "#6EA8FF"

CREATIVE_CSS = """
body { display: block; }
body.feature { background: #142A6B; }
.feature .glow {
  background:
    radial-gradient(ellipse 60% 110% at 80% 30%, color-mix(in srgb, #6EA8FF 70%, transparent), transparent 72%),
    radial-gradient(ellipse 60% 90% at 6% 104%, color-mix(in srgb, #FFB454 58%, transparent), transparent 72%),
    radial-gradient(ellipse 50% 70% at 40% -10%, color-mix(in srgb, #B48CFF 60%, transparent), transparent 72%);
}
.glow {
  background:
    radial-gradient(ellipse 46% 90% at 74% 34%, color-mix(in srgb, #6EA8FF 62%, transparent), transparent 72%),
    radial-gradient(ellipse 50% 80% at 22% 96%, color-mix(in srgb, #FFB454 46%, transparent), transparent 72%),
    radial-gradient(ellipse 44% 60% at 46% -6%, color-mix(in srgb, #B48CFF 34%, transparent), transparent 72%);
}
.stage { position: absolute; inset: 0; }
.words { position: absolute; display: flex; flex-direction: column; justify-content: center; }
.words p { max-width: none; font-size: calc(var(--u) * 4.6); }
/* A screen alone, without a device around it. */
.device.screen {
  --bezel: 0; --radius: .07; background: none;
  box-shadow: 0 calc(var(--w) * .05) calc(var(--w) * .16) rgba(0,0,0,.55);
}
"""

# A title with a word wider than the box of the words (Finnish and Turkish
# have one) would run under the phones, one of four lines (Greek) is too much
# for the space, and words taller than their box would run out of the safe
# area, so the type shrinks until the title fits in three lines and all the
# words fit in the box.
CREATIVE_FIT = """
document.fonts.ready.then(() => {
  const words = document.querySelector('.words');
  const title = document.querySelector('.words h1');
  const tooBig = () =>
    title.scrollWidth > title.clientWidth ||
    title.offsetHeight > 3.2 * parseFloat(getComputedStyle(title).lineHeight) ||
    words.firstElementChild.getBoundingClientRect().top < words.getBoundingClientRect().top;
  let unit = parseFloat(document.body.style.getPropertyValue('--u'));
  while (title && tooBig() && unit > 6) {
    unit -= 0.2;
    document.body.style.setProperty('--u', unit + 'px');
  }
});
"""


def heading(locale, title):
    """The markup of [title]. Chinese and Japanese have no spaces to break a
    line at, so a balanced title would break inside a word: it breaks after
    its comma, and inside a half only when that is wider than the line.
    """
    comma = {"zh": "，", "zh_Hant": "，", "ja": "、"}.get(locale)
    if comma is None:
        return html.escape(title)
    phrases = title.replace(comma, f"{comma}\n").split("\n")
    return "".join(f'<span class="phrase">{html.escape(p)}</span>' for p in phrases)


def captions(locale, device):
    """The captions of [locale] as [device] words them, by shot."""
    shots = json.loads((HERE / "captions" / f"{locale}.json").read_text())
    messages = json.loads((L10N / f"app_{locale}.arb").read_text())
    for caption in shots.values():
        # What the caption says of the phone, an iPad says of itself.
        on_ipad = caption.pop("ipad", {})
        if device == "ipad":
            caption.update(on_ipad)
    shots["overview"]["chips"] = [messages[key] for key in CHIPS]
    return shots


def tone_table(folder):
    """A colour lookup table for TONE, written into [folder]."""
    table = folder / "tone.png"
    # ImageMagick's HCL has hue, chroma and lightness in its red, green and
    # blue channels, with yellow at a hue of about 0.15.
    chroma = (
        "cc=u.g; ww=exp(-pow((u.r-0.15)/0.06,2)); "
        f"cc*(1-{TONE['chroma']})*(1-{TONE['vivid']}*cc)*(1-{TONE['yellow']}*ww)"
    )
    subprocess.run(
        ["magick", "hald:8", "-colorspace", "HCL"]
        + ["-channel", "G", "-fx", chroma]
        + ["-channel", "B", "-fx", f"u.b*(1-{TONE['light']}*u.g)"]
        + ["+channel", "-colorspace", "sRGB", str(table)],
        check=True,
    )
    return table


def toned(screen, table, folder):
    """A copy of the raw [screen] in [folder], its colours through [table]."""
    target = folder / screen.name
    if not target.exists():
        subprocess.run(
            ["magick", str(screen), str(table), "-hald-clut"]
            + ["-define", "png:compression-level=1", str(target)],
            check=True,
        )
    return target


def style(locale, width, height, glow):
    """CSS for a canvas of [width] by [height] in [locale] and the [glow] colour."""
    fallback = FALLBACK_FONTS.get(locale)
    return CSS % {
        "fonts": FONTS.as_uri(),
        "width": width,
        "height": height,
        "glow": glow,
        "fallback": f"{fallback}," if fallback else "",
    }


def frame(device, source, place):
    """The screen at [source] in a drawn [device] at [place] on the stage."""
    x, y, h, turn, extra = place
    cutout = {
        "iphone": '<div class="island"></div>',
        "android": '<div class="hole"></div>',
    }.get(device, "")
    return (
        f'<div class="device {device} {extra}" style="--x:{x * 100:.1f};'
        f'--y:{y * 100:.1f};--h:{h * 100:.1f};--r:{turn}deg">'
        f'<img src="{source.as_uri()}">{cutout}</div>'
    )


def aspect(screen):
    """The width of the image at [screen] over its height."""
    width, height = subprocess.run(
        ["magick", "identify", "-format", "%w %h", str(screen)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.split()
    return int(width) / int(height)


def snap(markup, width, height, target, folder):
    """Has Chrome render [markup] at [width] by [height] into the PNG [target]."""
    source = target.with_suffix(".html")
    source.write_text(markup)
    subprocess.run(
        [
            CHROME,
            "--headless=new",
            "--hide-scrollbars",
            "--force-device-scale-factor=1",
            # Time for a page's script to run once its fonts have loaded.
            "--virtual-time-budget=2000",
            # Its own profile, so several runs can render at once.
            f"--user-data-dir={folder / 'chrome'}",
            f"--window-size={width},{height}",
            f"--screenshot={target}",
            source.as_uri(),
        ],
        check=True,
        capture_output=True,
    )
    source.unlink()


def page(device, locale, caption, layout, screens, glow, sources):
    size = DEVICES[device]
    width, height = size["width"], size["height"]
    css = style(locale, width, height, glow)
    devices = [
        frame(device, sources[screen], place)
        for screen, place in zip(screens, LAYOUTS[device][layout])
    ]
    chips = "".join(
        f'<span class="chip">{html.escape(c)}</span>' for c in caption.get("chips", [])
    )
    chips = f'<div class="chips">{chips}</div>' if chips else ""
    unit = width / 100 * size["unit"]
    return (
        f'<!doctype html><html lang="{locale.replace("_", "-")}">'
        f'<meta charset="utf-8"><style>{css}</style>'
        f'<body style="--u:{unit:.2f}px;--aspect:{aspect(sources[screens[0]]):.4f}">'
        f'<div class="glow"></div>'
        f'<div class="caption">'
        f"<h1>{heading(locale, caption['title'])}</h1>"
        f"<p>{html.escape(caption['subtitle'])}</p>{chips}</div>"
        f'<div class="stage">{"".join(devices)}</div></body>'
    )


def creative(locale, device, table, folder):
    """The creative assets of [locale] that show [device]'s screens."""
    assets = {n: a for n, a in CREATIVE.items() if a["device"] == device}
    if not assets:
        return
    raw = WORK / "raw" / device / locale
    (folder / "creative" / locale).mkdir(parents=True, exist_ok=True)
    caption = captions(locale, device)["overview"]
    out = WORK / "out" / "creative" / locale
    out.mkdir(parents=True, exist_ok=True)
    for name, asset in assets.items():
        width, height = asset["size"]
        screens = {
            shown: toned(raw / f"{shown}.png", table, folder / "creative" / locale)
            for shown, *_ in asset["phones"]
        }
        ratio = aspect(next(iter(screens.values())))
        phones = "".join(
            frame(
                asset["frame"],
                screens[shown],
                (x / width, top / height, across / ratio / height, turn, extra),
            )
            for shown, x, top, across, turn, extra in asset["phones"]
        )
        words, unit = "", 0
        if asset["words"]:
            (left, top, across, down), unit = asset["words"]
            words = (
                f'<div class="words" style="left:{left}px;top:{top}px;'
                f'width:{across}px;height:{down}px">'
                '<div class="label">GR Photo</div>'
                f"<h1>{heading(locale, caption['title'])}</h1>"
                f"<p>{html.escape(caption['subtitle'])}</p></div>"
            )
        shot = out / f"{name}-shot.png"
        snap(
            f'<!doctype html><html lang="{locale.replace("_", "-")}">'
            f'<meta charset="utf-8"><style>'
            f"{style(locale, width, height, CREATIVE_GLOW)}{CREATIVE_CSS}</style>"
            f'<body class="{name}" style="--u:{unit}px;--aspect:{ratio:.4f}">'
            f'<div class="glow"></div><div class="stage">{phones}</div>{words}'
            f"<script>{CREATIVE_FIT}</script></body>",
            width,
            height,
            shot,
            folder,
        )
        # The App Store takes the header as a PNG only, and neither store
        # takes an image with an alpha channel.
        target = out / (f"{name}.jpg" if name == "search" else f"{name}.png")
        subprocess.run(
            ["magick", str(shot), "-alpha", "off", "-quality", "95"]
            + [f"PNG24:{target}" if target.suffix == ".png" else str(target)],
            check=True,
        )
        shot.unlink()
        print(target)


def render(device, locale, table, folder):
    size = DEVICES[device]
    raw = WORK / "raw" / device / locale
    (folder / device / locale).mkdir(parents=True)
    shown = {
        shot: SCREENS_ON.get(device, {}).get(shot, screens)
        for shot, _, screens, _ in SHOTS
    }
    sources = {
        screen: toned(raw / f"{screen}.png", table, folder / device / locale)
        for screens in shown.values()
        for screen in screens
    }
    shots = captions(locale, device)
    out = WORK / "out" / device / locale
    out.mkdir(parents=True, exist_ok=True)
    for number, (shot, layout, _, glow) in enumerate(SHOTS, start=1):
        target = out / f"{number:02d}-{shot}.png"
        snap(
            page(device, locale, shots[shot], layout, shown[shot], glow, sources),
            size["width"],
            size["height"],
            target,
            folder,
        )
        # Neither store takes a screenshot with an alpha channel.
        subprocess.run(
            [
                "sips",
                "-s",
                "format",
                "jpeg",
                "-s",
                "formatOptions",
                "100",
                str(target),
                "--out",
                str(target.with_suffix(".jpg")),
            ],
            check=True,
            capture_output=True,
        )
        target.unlink()
        print(target.with_suffix(".jpg"))


def play_icon():
    """Google Play's 512 px app icon: the square of the App Store's, from the
    icon's source (tool/render_app_icon.sh), which Google Play rounds itself.
    """
    target = WORK / "out" / "play-icon.png"
    target.parent.mkdir(parents=True, exist_ok=True)
    # The square is the middle two thirds of the page, which resvg draws
    # with every variant but the App Store's default one hidden.
    stylesheet = target.with_suffix(".css")
    stylesheet.write_text(".variant { display: none } #ios-default { display: inline }")
    subprocess.run(
        ["resvg", "--skip-system-fonts", "--use-fonts-dir", str(FONTS)]
        + ["--stylesheet", str(stylesheet), "--width", "768"]
        + [str(ROOT / "app" / "icon" / "icon.svg"), str(target)],
        check=True,
    )
    stylesheet.unlink()
    subprocess.run(
        ["magick", str(target), "-gravity", "center", "-crop", "512x512+0+0"]
        + ["+repage", "-alpha", "off", f"PNG24:{target}"],
        check=True,
    )
    print(target)


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as scratch:
        scratch = pathlib.Path(scratch)
        lookup = tone_table(scratch)
        for name in DEVICES:
            # A device run.sh was not given has no screens.
            taken = sorted(d.name for d in (WORK / "raw" / name).glob("*/"))
            for code in sys.argv[1:] or taken:
                if code not in taken:
                    continue
                render(name, code, lookup, scratch)
                creative(code, name, lookup, scratch)
        play_icon()
