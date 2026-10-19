#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  limine-theme — interactive theme installer for the Limine bootloader
#
#  * 16 themes (palette + procedurally generated wallpaper + margins/glass/etc.)
#  * Arrow-key picker with a live colour preview in your terminal
#  * Works on any distro: finds limine.conf by itself, computes the boot():/ path,
#    needs only bash + python3 (stdlib only, no pip, no ImageMagick)
#  * Re-runnable and reversible: everything lives in ONE marked block at the top
#    of limine.conf; your own lines are never deleted (conflicting ones are
#    commented out and restored by --remove)
#
#  Targets Limine's `limine.conf` format (v9+). Colour options use RRGGBB hex on
#  Limine >= 12 and 0-7 palette indices on older versions (auto-detected).
# ──────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

VERSION="1.0.0"
ARGS=("$@")
SELF="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]:-$0}")"

if [ -t 1 ]; then B=$'\e[1m'; D=$'\e[2m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; Z=$'\e[0m'
else B=""; D=""; G=""; Y=""; R=""; C=""; Z=""; fi
info() { printf '%s::%s %s\n' "$C" "$Z" "$*"; }
ok()   { printf '%s✔%s %s\n' "$G" "$Z" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$Z" "$*" >&2; }
die()  { printf '%s✘%s %s\n' "$R" "$Z" "$*" >&2; exit 1; }

usage() {
cat <<EOF
${B}limine-theme ${VERSION}${Z} — themes for the Limine boot menu

${B}Usage${Z}
  limine-theme.sh                       interactive picker (←/→ browse, Enter install)
  limine-theme.sh -t NAME [options]     install a theme non-interactively
  limine-theme.sh list                  list themes with colour swatches
  limine-theme.sh preview NAME          preview a theme in this terminal
  limine-theme.sh status                show the installed theme
  limine-theme.sh remove                uninstall (restores your original lines)

${B}Options${Z}
  -t, --theme NAME         theme to install (see 'list')
  -c, --conf FILE          limine.conf to edit (default: auto-detect)
  -y, --yes                don't ask for confirmation
      --variants N         generate N wallpaper variants; Limine picks one at random each boot
      --res WxH            wallpaper render size (default 960x540 smooth themes / 1280x720 detailed; Limine stretches it)
      --format png|qoi     wallpaper format (default png; qoi decodes faster in the bootloader)
      --ui card|hud|none   paint a UI frame (window card / sci-fi HUD) into the wallpaper, aligned to the
                           menu. Default: per theme. Locks the UI resolution to --screen.
      --screen WxH         your screen's native resolution (default 1920x1080) — used by --ui
      --title TEXT         title drawn in the frame (default: distro name)
      --branding TEXT      text shown above the menu (default: your distro name, themed)
      --panel TT           panel transparency, 2 hex digits (00..ff, see notes) — e.g. --panel a0
      --scale N            terminal font scale 1..8 (use 2 on HiDPI / 4K screens)
      --font FILE          custom raw CP437 bitmap font (256 glyphs, 8x16) → term_font
      --interface-res WxH  force the Limine UI resolution (interface_resolution)
      --hide-help          hide the key-binding help line
      --wallpaper FILE     use your own image(s) (png/jpg/bmp/qoi); repeatable
      --no-wallpaper       palette/colours only
      --hash / --no-hash   append BLAKE2b hashes to wallpaper paths (auto-on with Secure Boot)
      --colour-mode MODE   hex | index | auto (default auto, from 'limine --version')
      --dry-run            print the block that would be written, change nothing
      --force              skip safety stops (e.g. NixOS)
  -h, --help

${B}Env${Z}
  LIMINE_THEME_ROOTS=/mnt/esp:/mnt/boot   extra mount points to search for limine.conf
EOF
}

# ─── argument parsing (anything unknown is forwarded to the engine) ───────────
cmd="install"; theme=""; conf=""; yes=0; pass=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    install) cmd=install ;;
    list|-l|--list) cmd=list ;;
    status|-s|--status) cmd=status ;;
    remove|-r|--remove|uninstall) cmd=remove ;;
    preview|-p|--preview) cmd=preview; [ $# -ge 2 ] || die "preview needs a theme name"; theme="$2"; shift ;;
    -t|--theme) [ $# -ge 2 ] || die "$1 needs a value"; theme="$2"; shift ;;
    -c|--conf)  [ $# -ge 2 ] || die "$1 needs a value"; conf="$2"; shift ;;
    -y|--yes) yes=1 ;;
    *) pass+=("$1") ;;
  esac
  shift
done

command -v python3 >/dev/null 2>&1 || die "python3 is required (standard library only — no extra packages)."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/limine-theme.XXXXXX")"
cleanup() { [ -t 1 ] && command -v tput >/dev/null 2>&1 && tput cnorm 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM
PY="$WORK/engine.py"

# ══════════════════════════════════════════════════════════════════════════════
#  Embedded engine (Python 3, standard library only)
# ══════════════════════════════════════════════════════════════════════════════
cat > "$PY" <<'PYEOF'
# -*- coding: utf-8 -*-
import argparse, glob, hashlib, math, os, random, re, shutil, struct, subprocess, sys, time, zlib

BEGIN = "# >>> limine-theme >>>"
END = "# <<< limine-theme <<<"
OFF = "#[limine-theme] "
SUBDIR = "limine-theme"


def die(msg, code=1):
    sys.stderr.write("\x1b[31m✘\x1b[0m %s\n" % msg)
    sys.exit(code)


def warn(msg):
    sys.stderr.write("\x1b[33m!\x1b[0m %s\n" % msg)


def hx(s):
    s = s.lstrip("#")
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def clamp8(v):
    return 0 if v < 0 else 255 if v > 255 else int(v)


# ─────────────────────────────── THEMES ──────────────────────────────────────
# pal/bright: the 8+8 terminal colours (black red green brown blue magenta cyan gray)
# bg/fg      : term_background / term_foreground (selected entry = reverse video,
#              so fg becomes the selection bar colour and bg the text on it)
# panel      : transparency byte of term_background (TT in TTRRGGBB). 0x80 is a
#              50% blend whichever way a Limine version reads the byte.
# wall       : procedural wallpaper recipe
THEMES = {}


def add(key, **kw):
    THEMES[key] = kw


add("catppuccin-mocha", title="Catppuccin Mocha", desc="soft pastel dark, mauve accents, frosted panel",
    pal="1e1e2e;f38ba8;a6e3a1;f9e2af;89b4fa;cba6f7;94e2d5;bac2de",
    bright="585b70;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;a6adc8",
    bg="11111b", fg="cdd6f4", bg_b="181825", fg_b="f5e0dc",
    brand_c="cba6f7", help_c="7f849c", help_cb="f5c2e7", brand_i=5, help_i=7,
    brand=":: {os} ::", panel="80", margin=72, grad=48, spacing=1,
    wall=dict(kind="glow", base="11111b", vig=0.55,
              glows=[(0.18, 0.20, 0.28, 0.35, "3a2a5c", 1.0), (0.85, 0.85, 0.30, 0.35, "1b3350", 1.0),
                     (0.90, 0.12, 0.20, 0.25, "4a2440", 0.8)]))

add("nord", title="Nord", desc="arctic blue-grey with aurora bands",
    pal="3b4252;bf616a;a3be8c;ebcb8b;81a1c1;b48ead;88c0d0;e5e9f0",
    bright="4c566a;bf616a;a3be8c;ebcb8b;81a1c1;b48ead;8fbcbb;eceff4",
    bg="2e3440", fg="d8dee9", bg_b="3b4252", fg_b="eceff4",
    brand_c="88c0d0", help_c="616e88", help_cb="8fbcbb", brand_i=6, help_i=4,
    brand="[ {os} ]", panel="80", margin=64, grad=32, spacing=1,
    wall=dict(kind="glow", base="1c2029", vig=0.5,
              glows=[(0.50, 0.30, 0.55, 0.06, "123c36", 1.0), (0.35, 0.44, 0.50, 0.05, "1a2e4e", 1.0),
                     (0.70, 0.22, 0.40, 0.05, "2c2250", 0.9), (0.5, 1.0, 0.6, 0.25, "0e2030", 0.8)]))

add("gruvbox", title="Gruvbox Dark", desc="warm retro earth tones with film grain",
    pal="282828;cc241d;98971a;d79921;458588;b16286;689d6a;a89984",
    bright="928374;fb4934;b8bb26;fabd2f;83a598;d3869b;8ec07c;ebdbb2",
    bg="1d2021", fg="ebdbb2", bg_b="282828", fg_b="fbf1c7",
    brand_c="fabd2f", help_c="928374", help_cb="fe8019", brand_i=3, help_i=7,
    brand="# {os}", panel="80", margin=64, grad=24, spacing=1,
    wall=dict(kind="glow", base="1a1c1d", vig=0.5, noise=3,
              glows=[(0.20, 0.92, 0.40, 0.30, "40220a", 1.0), (0.85, 0.15, 0.30, 0.30, "2e2a08", 0.9)]))

add("tokyo-night", title="Tokyo Night", desc="moonlit skyline, lit windows, indigo sky",
    pal="15161e;f7768e;9ece6a;e0af68;7aa2f7;bb9af7;7dcfff;a9b1d6",
    bright="414868;f7768e;9ece6a;e0af68;7aa2f7;bb9af7;7dcfff;c0caf5",
    bg="1a1b26", fg="c0caf5", bg_b="24283b", fg_b="c0caf5",
    brand_c="7aa2f7", help_c="565f89", help_cb="bb9af7", brand_i=4, help_i=7,
    brand="{os}", panel="88", margin=64, grad=32, spacing=1,
    wall=dict(kind="skyline", sky_top="0b0c16", sky_bot="2b2d55", horizon=0.88, stars=170,
              moon=(0.80, 0.20, 44, "c0caf5"),
              layers=[dict(color="1f2140", h=(0.20, 0.42), w=(50, 110), win=None),
                      dict(color="161831", h=(0.12, 0.32), w=(60, 120), win=(["3b4261", "565f89"], 0.10)),
                      dict(color="0d0e1d", h=(0.05, 0.22), w=(70, 150), win=(["e0af68", "7aa2f7"], 0.16))]))

add("rose-pine", title="Rosé Pine", desc="muted rose and iris on deep plum",
    pal="26233a;eb6f92;9ccfd8;f6c177;31748f;c4a7e7;ebbcba;e0def4",
    bright="6e6a86;eb6f92;9ccfd8;f6c177;31748f;c4a7e7;ebbcba;e0def4",
    bg="191724", fg="e0def4", bg_b="1f1d2e", fg_b="ebbcba",
    brand_c="c4a7e7", help_c="6e6a86", help_cb="ebbcba", brand_i=5, help_i=7,
    brand="~ {os} ~", panel="80", margin=72, grad=48, spacing=1,
    wall=dict(kind="glow", base="12101c", vig=0.55,
              glows=[(0.25, 0.25, 0.30, 0.35, "3a2038", 1.0), (0.80, 0.80, 0.30, 0.30, "20304a", 1.0),
                     (0.60, 0.15, 0.20, 0.20, "40302a", 0.7)]))

add("dracula", title="Dracula", desc="vivid purple and pink on charcoal",
    pal="21222c;ff5555;50fa7b;f1fa8c;bd93f9;ff79c6;8be9fd;f8f8f2",
    bright="6272a4;ff6e6e;69ff94;ffffa5;d6acff;ff92df;a4ffff;ffffff",
    bg="282a36", fg="f8f8f2", bg_b="44475a", fg_b="ffffff",
    brand_c="bd93f9", help_c="6272a4", help_cb="ff79c6", brand_i=5, help_i=4,
    brand="{os}", panel="80", margin=64, grad=32, spacing=1,
    wall=dict(kind="glow", base="1b1c25", vig=0.55,
              glows=[(0.15, 0.20, 0.30, 0.30, "3a2a5a", 1.0), (0.85, 0.85, 0.30, 0.30, "4a2040", 1.0)]))

add("solarized-dark", title="Solarized Dark", desc="the classic teal low-contrast scheme",
    pal="073642;dc322f;859900;b58900;268bd2;d33682;2aa198;eee8d5",
    bright="002b36;cb4b16;586e75;657b83;839496;6c71c4;93a1a1;fdf6e3",
    bg="002b36", fg="93a1a1", bg_b="073642", fg_b="eee8d5",
    brand_c="2aa198", help_c="586e75", help_cb="b58900", brand_i=6, help_i=4,
    brand="{os}", panel="80", margin=64, grad=32, spacing=1,
    wall=dict(kind="glow", base="001f27", vig=0.6, glows=[(0.5, 0.45, 0.45, 0.40, "063a44", 1.0)]))

add("synthwave", title="Synthwave", desc="striped sunset, neon grid horizon",
    pal="1a0b2e;ff3c8e;3cf5a6;ffd86b;5b6cff;ff2ec4;00f0ff;e6d9ff",
    bright="4b2a7a;ff6fb0;7dffc8;fff09a;8a96ff;ff6ae0;7dfaff;ffffff",
    bg="12061f", fg="f2e9ff", bg_b="1a0b2e", fg_b="ffffff",
    brand_c="ff2ec4", help_c="8a6fc0", help_cb="00f0ff", brand_i=5, help_i=6,
    brand=">> {os} <<", panel="90", margin=64, grad=40, spacing=1,
    wall=dict(kind="synthwave", sky_top="0b0220", sky_mid="3a0a5e", sky_hor="ff5ea8",
              sun_top="ffe36e", sun_bot="ff2ec4", floor="12041f", hor_floor="5a0f6a",
              grid1="ff2ec4", grid2="00f0ff", stars=120))

add("neon-city", title="Neon City", desc="rain-dark cyberpunk skyline, cyan/magenta windows",
    pal="0a0a12;ff2a6d;05ffa1;fcee0a;3a6bff;d300c5;00e5ff;d1f7ff",
    bright="3a3a55;ff5c8d;5dffc4;fff75e;6f93ff;ff3df0;5ff3ff;ffffff",
    bg="07070d", fg="d1f7ff", bg_b="0e0e1a", fg_b="ffffff",
    brand_c="ff2a6d", help_c="5c6490", help_cb="00e5ff", brand_i=1, help_i=6,
    brand="{os} // BOOT", panel="90", margin=64, grad=32, spacing=1,
    wall=dict(kind="skyline", sky_top="05030c", sky_bot="45115c", horizon=0.92, stars=70, moon=None,
              layers=[dict(color="1a0b28", h=(0.25, 0.55), w=(50, 110), win=(["5a2a6a"], 0.08)),
                      dict(color="0f0618", h=(0.15, 0.40), w=(60, 130), win=(["00e5ff", "ff2a6d"], 0.12)),
                      dict(color="06020b", h=(0.06, 0.26), w=(70, 160), win=(["00e5ff", "ff2a6d", "fcee0a"], 0.20))]))

add("matrix", title="Matrix Rain", desc="falling green code columns on black",
    pal="000000;ff3b3b;00ff41;d7ff5a;1fbf5f;00a86b;00ffa3;b6ffcb",
    bright="0a3d1a;ff6b6b;5dff87;eaff8a;4fe38a;2fe6a0;6dffc9;eafff0",
    bg="000a03", fg="00ff41", bg_b="001a08", fg_b="b6ffcb",
    brand_c="00ff41", help_c="087a2a", help_cb="b6ffcb", brand_i=2, help_i=2,
    brand="> {os}_", panel="90", margin=64, grad=32, spacing=1,
    wall=dict(kind="rain", bg="000803", color="00ff41"))

add("crt-amber", title="CRT Amber", desc="amber phosphor monitor with scanlines",
    pal="140c00;cc5500;a67c00;ffb000;8a5a00;d98200;ffc04d;e6a000",
    bright="4d3300;ff7a2e;d4a017;ffd24d;b37700;ffa31a;ffdc80;ffe0a3",
    bg="140b00", fg="ffb000", bg_b="1f1200", fg_b="ffd060",
    brand_c="ffd060", help_c="9a6a00", help_cb="ffb000", brand_i=3, help_i=3,
    brand="> {os}_", panel="80", margin=56, grad=40, spacing=0,
    wall=dict(kind="crt", base="0d0700", tint="402600", scan=0.74, vig=0.95))

add("crt-green", title="CRT Phosphor", desc="green phosphor terminal with scanlines",
    pal="001a00;cc3333;33ff33;b3b000;1f8f1f;2fbf2f;33ffa0;b0ffb0",
    bright="0a4d0a;ff5555;66ff66;d4d400;3fbf3f;55ef55;77ffbb;d8ffd8",
    bg="011401", fg="33ff33", bg_b="022002", fg_b="b0ffb0",
    brand_c="b0ffb0", help_c="1f8f1f", help_cb="33ff33", brand_i=2, help_i=2,
    brand="$ {os}_", panel="80", margin=56, grad=40, spacing=0,
    wall=dict(kind="crt", base="020a02", tint="053a05", scan=0.74, vig=0.95))

add("gameboy", title="Game Boy DMG", desc="four shades of green on a dot-matrix screen",
    pal="0f380f;306230;306230;306230;0f380f;306230;306230;306230",
    bright="306230;306230;306230;306230;306230;306230;306230;0f380f",
    bg="9bbc0f", fg="0f380f", bg_b="8bac0f", fg_b="0f380f",
    brand_c="0f380f", help_c="306230", help_cb="0f380f", brand_i=0, help_i=1,
    brand="[ {os} ]", panel="00", margin=48, grad=16, spacing=0,
    wall=dict(kind="tile", size=8, base="9bbc0f", gap="8bac0f", style="tiled"))

add("old-bios", title="Old BIOS", desc="full-screen blue text-mode setup utility",
    pal="000000;aa0000;00aa00;aa5500;0000aa;aa00aa;00aaaa;aaaaaa",
    bright="555555;ff5555;55ff55;ffff55;5555ff;ff55ff;55ffff;ffffff",
    bg="0000aa", fg="aaaaaa", bg_b="0000aa", fg_b="ffffff",
    brand_c="ffff55", help_c="00aaaa", help_cb="55ffff", brand_i=3, help_i=6,
    brand="{os} Setup Utility", panel="80", margin=0, grad=0, spacing=0,
    wall=dict(kind="tile", size=4, base="0000aa", gap=None, style="tiled"))

add("glass", title="Liquid Glass", desc="aurora blobs behind a wide frosted-glass panel",
    pal="0b1020;ff6b8b;6be5a8;ffd479;6ba8ff;c58bff;6be0ff;e6edff",
    bright="3a4566;ff8fa8;8dffc4;ffe29a;8fc0ff;d9b0ff;9aeaff;ffffff",
    bg="0b1020", fg="ffffff", bg_b="101830", fg_b="ffffff",
    brand_c="9ad0ff", help_c="8fa3d6", help_cb="ffffff", brand_i=6, help_i=4,
    brand="{os}", panel="90", margin=96, grad=64, spacing=1,
    wall=dict(kind="glow", base="070b18", vig=0.30, noise=1,
              glows=[(0.20, 0.25, 0.28, 0.36, "2070d0", 1.0), (0.82, 0.30, 0.26, 0.32, "9030c0", 1.0),
                     (0.50, 0.88, 0.40, 0.28, "10a090", 1.0), (0.70, 0.70, 0.18, 0.20, "d04080", 0.7)]))

add("minimal", title="Minimal Mono", desc="pure black, white text, whisper-soft vignette",
    pal="0a0a0a;e5484d;46a758;e5b53b;3e63dd;8e4ec6;12a594;d4d4d4",
    bright="555555;ff6369;5bb86e;f5c542;5c7cfa;a07ae0;2ec4b0;ffffff",
    bg="000000", fg="e6e6e6", bg_b="0a0a0a", fg_b="ffffff",
    brand_c="ffffff", help_c="6b6b6b", help_cb="e6e6e6", brand_i=7, help_i=7,
    brand="{os}", panel="80", margin=64, grad=24, spacing=1,
    wall=dict(kind="glow", base="040404", vig=0.7, glows=[(0.5, 0.5, 0.40, 0.40, "151515", 1.0)]))


def wall_tone(t):
    w = t["wall"]
    k = w["kind"]
    if k == "glow":
        b = hx(w["base"]); g = hx(w["glows"][0][4])
        return "%02x%02x%02x" % tuple(clamp8(b[i] + g[i] * 0.6) for i in range(3))
    if k == "skyline":
        return "%02x%02x%02x" % lerp(hx(w["sky_top"]), hx(w["sky_bot"]), 0.6)
    if k == "synthwave":
        return w["sky_mid"]
    if k == "rain":
        return w["bg"]
    if k == "crt":
        b = hx(w["base"]); g = hx(w["tint"])
        return "%02x%02x%02x" % tuple(clamp8(b[i] + g[i] * 0.5) for i in range(3))
    return w["base"]


# ─────────────────────────── image buffer & encoders ─────────────────────────
class Img(object):
    def __init__(self, W, H, fill=(0, 0, 0)):
        self.W, self.H = W, H
        self.rows = [bytearray(bytes(fill) * W) for _ in range(H)]

    def fill(self, c):
        for y in range(self.H):
            self.rows[y][:] = bytes(c) * self.W

    def rect(self, x0, y0, x1, y1, c):
        x0 = max(0, int(x0)); x1 = min(self.W, int(x1))
        y0 = max(0, int(y0)); y1 = min(self.H, int(y1))
        if x1 <= x0 or y1 <= y0:
            return
        seg = bytes(c) * (x1 - x0)
        for y in range(y0, y1):
            self.rows[y][x0 * 3:x1 * 3] = seg

    def px_blend(self, x, y, c, a):
        row = self.rows[y]; i = x * 3
        row[i] = clamp8(row[i] + (c[0] - row[i]) * a)
        row[i + 1] = clamp8(row[i + 1] + (c[1] - row[i + 1]) * a)
        row[i + 2] = clamp8(row[i + 2] + (c[2] - row[i + 2]) * a)


def png_bytes(img):
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    raw = b"".join(b"\x00" + bytes(r) for r in img.rows)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", img.W, img.H, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def qoi_bytes(img):
    out = bytearray(b"qoif" + struct.pack(">IIBB", img.W, img.H, 3, 0))
    index = [None] * 64
    pr = pg = pb = 0
    run = 0
    data = b"".join(bytes(r) for r in img.rows)
    n = img.W * img.H
    for i in range(n):
        r = data[3 * i]; g = data[3 * i + 1]; b = data[3 * i + 2]
        if r == pr and g == pg and b == pb:
            run += 1
            if run == 62:
                out.append(0xc0 | (run - 1)); run = 0
            continue
        if run:
            out.append(0xc0 | (run - 1)); run = 0
        h = (r * 3 + g * 5 + b * 7 + 255 * 11) % 64
        if index[h] == (r, g, b):
            out.append(h)
        else:
            index[h] = (r, g, b)
            vr = ((r - pr + 128) & 255) - 128
            vg = ((g - pg + 128) & 255) - 128
            vb = ((b - pb + 128) & 255) - 128
            vgr = vr - vg; vgb = vb - vg
            if -2 <= vr <= 1 and -2 <= vg <= 1 and -2 <= vb <= 1:
                out.append(0x40 | ((vr + 2) << 4) | ((vg + 2) << 2) | (vb + 2))
            elif -32 <= vg <= 31 and -8 <= vgr <= 7 and -8 <= vgb <= 7:
                out.append(0x80 | (vg + 32)); out.append(((vgr + 8) << 4) | (vgb + 8))
            else:
                out.append(0xfe); out += bytes((r, g, b))
        pr, pg, pb = r, g, b
    if run:
        out.append(0xc0 | (run - 1))
    out += b"\x00" * 7 + b"\x01"
    return bytes(out)


# ─────────────────────────── wallpaper generators ────────────────────────────
def glow_fill(img, base, glows, vig=0.0, noise=1, rnd=random, jitter=0.0):
    W, H = img.W, img.H
    gs = []
    for (cx, cy, sx, sy, tint, amp) in glows:
        if jitter:
            cx += rnd.uniform(-jitter, jitter); cy += rnd.uniform(-jitter, jitter)
        gx = [math.exp(-((x / W - cx) ** 2) / (2 * sx * sx)) for x in range(W)]
        gy = [amp * math.exp(-((y / H - cy) ** 2) / (2 * sy * sy)) for y in range(H)]
        gs.append((gx, gy, hx(tint)))
    vx = [((x / W - 0.5) * 2) ** 2 for x in range(W)]
    vy = [((y / H - 0.5) * 2) ** 2 for y in range(H)]
    nz = [rnd.randint(-noise, noise) for _ in range(W + 256)] if noise else [0] * (W + 256)
    br, bg_, bb = base
    for y in range(H):
        off = rnd.randrange(256)
        coef = [(g[0], g[1][y] * g[2][0], g[1][y] * g[2][1], g[1][y] * g[2][2]) for g in gs]
        vyy = vy[y]
        out = bytearray(W * 3)
        j = 0
        for x in range(W):
            r = br; g_ = bg_; b = bb
            for (gx, cr, cg, cb) in coef:
                w = gx[x]
                r += w * cr; g_ += w * cg; b += w * cb
            if vig:
                f = 1.0 - vig * (vx[x] + vyy) * 0.5
                if f < 0.0:
                    f = 0.0
                r *= f; g_ *= f; b *= f
            d = nz[x + off]
            r = int(r + d); g_ = int(g_ + d); b = int(b + d)
            out[j] = 0 if r < 0 else 255 if r > 255 else r
            out[j + 1] = 0 if g_ < 0 else 255 if g_ > 255 else g_
            out[j + 2] = 0 if b < 0 else 255 if b > 255 else b
            j += 3
        img.rows[y] = out


def disc_glow(img, cx, cy, r, color, glow=3.0, strength=0.5, ymax=None, solid=True):
    W, H = img.W, img.H
    R = int(r * glow)
    ymax = H if ymax is None else ymax
    for y in range(max(0, int(cy - R)), min(ymax, int(cy + R) + 1)):
        for x in range(max(0, int(cx - R)), min(W, int(cx + R) + 1)):
            d = math.hypot(x - cx, y - cy)
            if d <= r:
                a = 1.0 if solid else strength
            else:
                a = strength * max(0.0, 1 - (d - r) / (R - r)) ** 2
            if a > 0.004:
                img.px_blend(x, y, color, a)


def gen_skyline(img, p, rnd):
    W, H = img.W, img.H
    u = W / 1280.0
    top, bot = hx(p["sky_top"]), hx(p["sky_bot"])
    hz = p.get("horizon", 0.85)
    for y in range(H):
        t = min(1.0, (y / (H * hz))) ** 1.5
        img.rows[y][:] = bytes(lerp(top, bot, t)) * W
    for _ in range(p.get("stars", 120)):
        x = rnd.randrange(W); y = rnd.randrange(int(H * 0.55)); v = rnd.randint(90, 230)
        img.rect(x, y, x + 1 + (rnd.random() < 0.15), y + 1, (v, v, min(255, v + 25)))
    if p.get("moon"):
        mx, my, mr, mc = p["moon"]
        disc_glow(img, mx * W, my * H, mr * u, hx(mc), glow=3.2, strength=0.35)
    for layer in p["layers"]:
        col = hx(layer["color"])
        x = -rnd.randint(0, int(40 * u))
        while x < W:
            bw = int(rnd.randint(*layer["w"]) * u)
            bh = int(H * rnd.uniform(*layer["h"]))
            ty = H - bh
            img.rect(x, ty, x + bw, H, col)
            if rnd.random() < 0.25:  # antenna / roof step
                img.rect(x + bw // 2 - 1, ty - int(rnd.randint(8, 30) * u), x + bw // 2 + 1, ty, col)
            if rnd.random() < 0.3:
                img.rect(x + int(bw * 0.15), ty - int(8 * u), x + int(bw * 0.7), ty, col)
            win = layer.get("win")
            if win:
                cols, prob = win
                sx, sy = int(11 * u) or 1, int(15 * u) or 1
                ww, wh = max(1, int(5 * u)), max(1, int(7 * u))
                for wy in range(ty + int(12 * u), H - int(8 * u), sy):
                    for wx in range(x + int(6 * u), x + bw - int(8 * u), sx):
                        if rnd.random() < prob:
                            img.rect(wx, wy, wx + ww, wy + wh, hx(rnd.choice(cols)))
            x += bw + rnd.randint(0, int(5 * u))


def gen_synthwave(img, p, rnd):
    W, H = img.W, img.H
    u = W / 1280.0
    hy = int(H * 0.58)
    top, mid, hor = hx(p["sky_top"]), hx(p["sky_mid"]), hx(p["sky_hor"])
    for y in range(hy):
        t = y / float(hy)
        c = lerp(top, mid, t / 0.6) if t < 0.6 else lerp(mid, hor, ((t - 0.6) / 0.4) ** 1.3)
        img.rows[y][:] = bytes(c) * W
    for _ in range(p.get("stars", 100)):
        x = rnd.randrange(W); y = rnd.randrange(int(hy * 0.6)); v = rnd.randint(110, 255)
        img.rect(x, y, x + 1 + (rnd.random() < 0.2), y + 1, (v, v, v))
    R = int(H * 0.26)
    cx, cy = W // 2, hy - int(R * 0.30)
    disc_glow(img, cx, cy, R, hx(p["sun_bot"]), glow=1.9, strength=0.40, ymax=hy, solid=False)
    st, sb = hx(p["sun_top"]), hx(p["sun_bot"])
    period = max(4, int(15 * u))
    for y in range(cy - R, hy):
        dy = y - cy
        half = int(math.sqrt(max(0.0, R * R - dy * dy)))
        if dy > -0.12 * R:
            k = (dy + 0.12 * R) / (1.12 * R)
            if (y - cy) % period < k * period * 0.85:
                continue
        img.rect(cx - half, y, cx + half, y + 1, lerp(st, sb, (y - (cy - R)) / (2.0 * R)))
    fl, hf = hx(p["floor"]), hx(p["hor_floor"])
    fh = H - hy
    for y in range(hy, H):
        img.rows[y][:] = bytes(lerp(hf, fl, ((y - hy) / float(fh)) ** 0.45)) * W
    g1, g2 = hx(p["grid1"]), hx(p["grid2"])
    n = 16
    for k in range(1, n + 1):
        t = (k / float(n)) ** 2.3
        y = int(hy + fh * t)
        th = 1 + int(2 * t * u)
        img.rect(0, y, W, y + th, lerp(fl, g1, 0.35 + 0.65 * t))
    spacing = W / 7.0
    for i in range(-18, 19):
        xb = W / 2.0 + i * spacing
        for y in range(hy + 1, H):
            t = (y - hy) / float(fh)
            if t < 0.05:          # lines closer than a few px just alias into speckle
                continue
            x = W / 2.0 + (xb - W / 2.0) * t
            x2 = W / 2.0 + (xb - W / 2.0) * ((y + 1 - hy) / float(fh))   # join this row to the next one
            wd = max(1, int((1 + 2 * t) * u))
            fade = min(1.0, (t - 0.05) * 7)
            img.rect(min(x, x2) - wd // 2, y, max(x, x2) + wd // 2 + 1, y + 1, lerp(fl, g2, (0.25 + 0.75 * t) * fade))
    img.rect(0, hy - 1, W, hy + 2, lerp(hor, (255, 255, 255), 0.5))


def gen_rain(img, p, rnd):
    W, H = img.W, img.H
    u = W / 1280.0
    img.fill(hx(p["bg"]))
    col = hx(p["color"])
    cw, ch = max(6, int(15 * u)), max(8, int(19 * u))
    pw, ph = max(1, int(2 * u)), max(1, int(3 * u))
    for c in range(W // cw):
        if rnd.random() < 0.22:
            continue
        head = rnd.randint(-4, H // ch + 6)
        L = rnd.randint(7, 30)
        for k in range(L):
            cy = head - k
            if cy < 0 or cy * ch >= H:
                continue
            inten = (1 - k / float(L)) ** 1.7
            cc = (200, 255, 215) if k == 0 else tuple(int(v * inten) for v in col)
            x0, y0 = c * cw + int(2 * u), cy * ch + int(2 * u)
            for gy in range(5):
                for gx in range(4):
                    if rnd.random() < 0.46:
                        img.rect(x0 + gx * pw * 2, y0 + gy * ph, x0 + gx * pw * 2 + pw * 2 - 1, y0 + gy * ph + ph, cc)


def gen_crt(img, p, rnd, jitter=0.0):
    glow_fill(img, hx(p["base"]), [(0.5, 0.5, 0.34, 0.34, p["tint"], 1.0)], vig=p.get("vig", 0.9), noise=1, rnd=rnd,
              jitter=jitter)
    tbl = bytes(int(i * p.get("scan", 0.75)) for i in range(256))
    for y in range(2, img.H, 3):
        img.rows[y][:] = img.rows[y].translate(tbl)


def gen_tile(p):
    s = p["size"]
    img = Img(s, s, hx(p["base"]))
    if p.get("gap"):
        img.rect(s - 1, 0, s, s, hx(p["gap"]))
        img.rect(0, s - 1, s, s, hx(p["gap"]))
    return img



# ─────────────────────── UI chrome (frame drawn into the wallpaper) ──────────
# Limine draws only a text terminal, so the "UI" is painted into the wallpaper and
# lined up with the terminal rectangle (needs a fixed interface_resolution).
UI_DEFAULT = {"catppuccin-mocha": "card", "nord": "card", "gruvbox": "card", "tokyo-night": "card",
              "rose-pine": "card", "dracula": "card", "solarized-dark": "card", "glass": "card",
              "synthwave": "hud", "neon-city": "hud", "matrix": "hud", "crt-amber": "hud", "crt-green": "hud",
              "minimal": "hud", "gameboy": "none", "old-bios": "none"}

FONT5 = {  # 5x7 pixel font; each row is a 5-bit mask
    "A": (0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11), "B": (0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E),
    "C": (0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E), "D": (0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E),
    "E": (0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F), "F": (0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10),
    "G": (0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F), "H": (0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11),
    "I": (0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E), "J": (0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C),
    "K": (0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11), "L": (0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F),
    "M": (0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11), "N": (0x11, 0x11, 0x19, 0x15, 0x13, 0x11, 0x11),
    "O": (0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E), "P": (0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10),
    "Q": (0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D), "R": (0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11),
    "S": (0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E), "T": (0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04),
    "U": (0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E), "V": (0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04),
    "W": (0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A), "X": (0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11),
    "Y": (0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04), "Z": (0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F),
    "0": (0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E), "1": (0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E),
    "2": (0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F), "3": (0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E),
    "4": (0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02), "5": (0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E),
    "6": (0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E), "7": (0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08),
    "8": (0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E), "9": (0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C),
    "-": (0, 0, 0, 0x1F, 0, 0, 0), ".": (0, 0, 0, 0, 0, 0x0C, 0x0C), ":": (0, 0x0C, 0x0C, 0, 0x0C, 0x0C, 0),
    "/": (0x01, 0x01, 0x02, 0x04, 0x08, 0x10, 0x10), "_": (0, 0, 0, 0, 0, 0, 0x1F),
    ">": (0x10, 0x08, 0x04, 0x02, 0x04, 0x08, 0x10), "<": (0x01, 0x02, 0x04, 0x08, 0x04, 0x02, 0x01),
    "+": (0, 0x04, 0x04, 0x1F, 0x04, 0x04, 0), " ": (0, 0, 0, 0, 0, 0, 0),
}


def text_w(txt, s, gap=1):
    return max(0, len(txt) * (5 + gap) * s - gap * s)


def draw_text(img, x, y, txt, s, color, gap=1):
    for ch in txt.upper():
        g = FONT5.get(ch)
        if g:
            for ry, bits in enumerate(g):
                for rx in range(5):
                    if bits & (0x10 >> rx):
                        img.rect(x + rx * s, y + ry * s, x + (rx + 1) * s, y + (ry + 1) * s, color)
        x += (5 + gap) * s


def tint_rect(img, x0, y0, x1, y1, c, a):
    x0 = max(0, int(x0)); y0 = max(0, int(y0)); x1 = min(img.W, int(x1)); y1 = min(img.H, int(y1))
    if x1 <= x0 or y1 <= y0 or a <= 0:
        return
    tabs = [bytes(min(255, int(i * (1 - a) + c[k] * a + 0.5)) for i in range(256)) for k in range(3)]
    for y in range(y0, y1):
        row = img.rows[y]
        for k in range(3):
            row[x0 * 3 + k:x1 * 3:3] = row[x0 * 3 + k:x1 * 3:3].translate(tabs[k])


def tint_ring(img, outer, inner, c, a):
    ox0, oy0, ox1, oy1 = outer; ix0, iy0, ix1, iy1 = inner
    tint_rect(img, ox0, oy0, ox1, iy0, c, a); tint_rect(img, ox0, iy1, ox1, oy1, c, a)
    tint_rect(img, ox0, iy0, ix0, iy1, c, a); tint_rect(img, ix1, iy0, ox1, iy1, c, a)


def aa_px(img, x, y, c, a):
    if 0 <= x < img.W and 0 <= y < img.H and a > 0:
        img.px_blend(x, y, c, min(1.0, a))


def rrect(img, x0, y0, x1, y1, r, th, c, a=1.0):
    tint_rect(img, x0 + r, y0, x1 - r, y0 + th, c, a); tint_rect(img, x0 + r, y1 - th, x1 - r, y1, c, a)
    tint_rect(img, x0, y0 + r, x0 + th, y1 - r, c, a); tint_rect(img, x1 - th, y0 + r, x1, y1 - r, c, a)
    for (cx, cy, sx, sy) in ((x0 + r, y0 + r, -1, -1), (x1 - r, y0 + r, 1, -1), (x0 + r, y1 - r, -1, 1), (x1 - r, y1 - r, 1, 1)):
        for dy in range(r + 1):
            for dx in range(r + 1):
                d = math.hypot(dx + 0.5, dy + 0.5)
                cov = max(0.0, min(1.0, min(d - (r - th) + 0.5, r - d + 0.5)))
                if cov > 0:
                    aa_px(img, cx + dx if sx > 0 else cx - 1 - dx, cy + dy if sy > 0 else cy - 1 - dy, c, a * cov)


def disc(img, cx, cy, r, c):
    for y in range(int(cy - r - 1), int(cy + r + 2)):
        for x in range(int(cx - r - 1), int(cx + r + 2)):
            aa_px(img, x, y, c, max(0.0, min(1.0, r - math.hypot(x + 0.5 - cx, y + 0.5 - cy) + 0.5)))


def term_geom(W, H, margin, scale, spacing):
    """Where Limine's text terminal ends up: whole glyph cells, centred inside the margin."""
    cw, ch = 8 * scale + spacing, 16 * scale
    cols, rows = max(1, (W - 2 * margin) // cw), max(1, (H - 2 * margin) // ch)
    x0, y0 = (W - cols * cw) // 2, (H - rows * ch) // 2
    return x0, y0, x0 + cols * cw, y0 + rows * ch


def clean_title(txt):
    txt = "".join(ch for ch in (txt or "").upper() if ch in FONT5).strip()
    return txt or "BOOT MANAGER"


def chrome(img, t, style, geom, title):
    W, H = img.W, img.H
    u = H / 1080.0
    x0, y0, x1, y1 = geom
    acc, fg, wall = hx(t["brand_c"]), hx(t["fg"]), hx(wall_tone(t))
    dim = lerp(wall, fg, 0.55)
    pal = [hx(c) for c in t["pal"].split(";")]
    px, pt, pb = int(24 * u), int(58 * u), int(46 * u)
    cx0, cy0, cx1, cy1 = x0 - px, y0 - pt, x1 + px, y1 + pb
    ts, ss = max(2, int(3 * u)), max(1, int(2 * u))
    for i in range(12):   # soft accent glow around the frame
        tint_ring(img, (cx0 - i - 1, cy0 - i - 1, cx1 + i + 1, cy1 + i + 1), (cx0 - i, cy0 - i, cx1 + i, cy1 + i),
                  acc, 0.16 * (1 - i / 12.0) ** 2)
    sep_t, sep_b = y0 - int(8 * u), y1 + int(8 * u)
    if style == "card":
        rrect(img, cx0, cy0, cx1, cy1, int(18 * u), max(2, int(2 * u)), acc)
        tint_rect(img, cx0 + 6, sep_t, cx1 - 6, sep_t + 1, acc, 0.35)
        tint_rect(img, cx0 + 6, sep_b, cx1 - 6, sep_b + 1, acc, 0.35)
        for i, col in enumerate((pal[1], pal[3], pal[2])):
            disc(img, cx0 + int(36 * u) + i * int(26 * u), cy0 + pt // 2, 7 * u, col)
        draw_text(img, (W - text_w(title, ts)) // 2, cy0 + (pt - 7 * ts) // 2, title, ts, fg)
        draw_text(img, cx1 - int(30 * u) - text_w("LIMINE", ss), cy0 + (pt - 7 * ss) // 2, "LIMINE", ss, dim)
        fy = sep_b + (cy1 - sep_b - 7 * ss) // 2
        draw_text(img, cx0 + int(30 * u), fy, "UP/DOWN SELECT   ENTER BOOT   E EDIT", ss, dim)
    else:  # hud
        L, th = int(48 * u), max(2, int(3 * u))
        for (ax, ay, sx, sy) in ((cx0, cy0, 1, 1), (cx1, cy0, -1, 1), (cx0, cy1, 1, -1), (cx1, cy1, -1, -1)):
            img.rect(min(ax, ax + sx * L), ay if sy > 0 else ay - th, max(ax, ax + sx * L), (ay + th) if sy > 0 else ay, acc)
            img.rect(ax if sx > 0 else ax - th, min(ay, ay + sy * L), (ax + th) if sx > 0 else ax, max(ay, ay + sy * L), acc)
        tint_rect(img, cx0 + L, cy0, cx1 - L, cy0 + 1, acc, 0.45); tint_rect(img, cx0 + L, cy1 - 1, cx1 - L, cy1, acc, 0.45)
        tint_rect(img, cx0, cy0 + L, cx0 + 1, cy1 - L, acc, 0.45); tint_rect(img, cx1 - 1, cy0 + L, cx1, cy1 - L, acc, 0.45)
        step = max(6, int(18 * u))
        for i, x in enumerate(range(cx0 + L + step, cx1 - L, step)):
            h = int((9 if i % 5 == 4 else 4) * u)
            tint_rect(img, x, cy0 + 2, x + 1, cy0 + 2 + h, acc, 0.55)
        draw_text(img, cx0 + L + int(10 * u), cy0 + int(14 * u) + (pt - int(14 * u) - 7 * ts) // 2, "SYS // BOOT", ss, acc)
        draw_text(img, (W - text_w(title, ts)) // 2, cy0 + (pt - 7 * ts) // 2 + int(6 * u), title, ts, fg)
        draw_text(img, cx1 - L - int(10 * u) - text_w("LIMINE", ss), cy0 + int(14 * u) + (pt - int(14 * u) - 7 * ss) // 2, "LIMINE", ss, dim)
        tint_rect(img, cx0 + 6, sep_t, cx1 - 6, sep_t + 1, acc, 0.25)
        tint_rect(img, cx0 + 6, sep_b, cx1 - 6, sep_b + 1, acc, 0.25)
        fy = sep_b + (cy1 - sep_b - 7 * ss) // 2
        draw_text(img, cx0 + L, fy, "READY", ss, acc)
        img.rect(cx0 + L + text_w("READY", ss) + int(10 * u), fy, cx0 + L + text_w("READY", ss) + int(10 * u) + 5 * ss, fy + 7 * ss, acc)
        for i in range(12):
            h = int((4 + (i * 5) % 17) * u) + 2
            tint_rect(img, cx1 - L - (12 - i) * int(9 * u), fy + 7 * ss - h, cx1 - L - (12 - i) * int(9 * u) + int(5 * u) + 1, fy + 7 * ss, acc, 0.7)
    # a focus panel where the entry list lands (the list is centred in the terminal)
    pw, ph, r = int(W * 0.36), int(H * 0.34), int(14 * u)
    qx0, qy0 = (W - pw) // 2, (H - ph) // 2
    tint_rect(img, qx0, qy0, qx0 + pw, qy0 + ph, fg, 0.05)
    rrect(img, qx0, qy0, qx0 + pw, qy0 + ph, r, max(1, int(2 * u)), acc, 0.75)
    draw_text(img, qx0 + int(6 * u), qy0 - 7 * ss - int(12 * u), "BOOT MENU", ss, dim)


def upscale2(img):
    out = Img.__new__(Img)
    out.W, out.H, out.rows = img.W * 2, img.H * 2, []
    for r in img.rows:
        n = bytearray(out.W * 3)
        for k in range(3):
            n[k::6] = r[k::3]
            n[3 + k::6] = r[k::3]
        out.rows.append(n)
        out.rows.append(bytearray(n))
    return out


def render_full(theme_key, W, H, variant, ui, lay, title):
    t = THEMES[theme_key]
    k = t["wall"]["kind"]
    if k == "tile":
        tile = gen_tile(t["wall"])
        s = tile.W
        row = (tile.rows[0] * (W // s + 1))[:W * 3]
        img = Img(W, H)
        for y in range(H):
            img.rows[y][:] = (tile.rows[y % s] * (W // s + 1))[:W * 3]
    elif k in ("glow", "crt") and W % 2 == 0 and H % 2 == 0:
        img = upscale2(render(theme_key, W // 2, H // 2, variant))   # smooth art: cheap to make, small to store
    else:
        img = render(theme_key, W, H, variant)
    if ui != "none":
        chrome(img, t, ui, term_geom(W, H, lay["margin"], lay["scale"], lay["spacing"]), title)
    return img


def render(theme_key, W, H, variant=0):
    t = THEMES[theme_key]
    w = t["wall"]
    k = w["kind"]
    rnd = random.Random("%s/%d" % (theme_key, variant))
    if k == "tile":
        return gen_tile(w)
    img = Img(W, H)
    jit = 0.0 if variant == 0 else 0.10
    if k == "glow":
        glow_fill(img, hx(w["base"]), w["glows"], vig=w.get("vig", 0.0), noise=w.get("noise", 1), rnd=rnd, jitter=jit)
    elif k == "crt":
        gen_crt(img, w, rnd, jitter=jit)
    elif k == "skyline":
        gen_skyline(img, w, rnd)
    elif k == "synthwave":
        gen_synthwave(img, w, rnd)
    elif k == "rain":
        gen_rain(img, w, rnd)
    return img


# ───────────────────────────── system probing ────────────────────────────────
def osname():
    try:
        d = {}
        for ln in open("/etc/os-release", encoding="utf-8", errors="replace"):
            if "=" in ln:
                a, b = ln.rstrip("\n").split("=", 1)
                d[a] = b.strip('"')
        n = d.get("NAME") or d.get("PRETTY_NAME") or "Linux"
    except Exception:
        n = "Linux"
    return re.sub(r"[#\n]", "", n)


def limine_major():
    for c in ("limine",):
        try:
            out = subprocess.run([c, "--version"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=5)
            m = re.search(r"(\d+)\.(\d+)", out.stdout.decode("utf-8", "replace"))
            if m:
                return int(m.group(1))
        except Exception:
            pass
    return None


def secure_boot():
    for f in glob.glob("/sys/firmware/efi/efivars/SecureBoot-*"):
        try:
            return open(f, "rb").read()[-1] == 1
        except Exception:
            pass
    return False


def mounts():
    res = []
    try:
        for ln in open("/proc/mounts"):
            p = ln.split()
            if len(p) >= 3:
                res.append((p[1].replace("\\040", " "), p[2]))
    except Exception:
        pass
    return res


def fstype(mnt):
    t = "?"
    for m, f in mounts():
        if m == mnt:
            t = f
    return t


def mountpoint(p):
    p = os.path.realpath(p)
    forced = os.environ.get("LIMINE_THEME_MOUNT")      # for chroots / testing: treat this dir as the partition root
    if forced and (p == forced or p.startswith(forced.rstrip("/") + "/")):
        return forced
    while not os.path.ismount(p):
        p = os.path.dirname(p)
    return p


def find_confs():
    roots = [r for r in os.environ.get("LIMINE_THEME_ROOTS", "").split(":") if r]
    roots += ["/boot", "/boot/efi", "/efi", "/esp", "/"]
    roots += [m for m, f in mounts() if f in ("vfat", "msdos", "fat", "exfat")]
    seen, found = set(), []
    for r in roots:
        if not os.path.isdir(r):
            continue
        cands = []
        for ext, tag in (("conf", "conf"), ("cfg", "legacy")):
            cands += [(p, tag) for p in sorted(glob.glob(os.path.join(r, "EFI", "*", "limine." + ext)))]
            for sub in ("boot/limine/limine.", "boot/limine.", "limine/limine.", "limine."):
                cands.append((os.path.join(r, sub + ext), tag))
        for p, tag in cands:
            if os.path.isfile(p):
                rp = os.path.realpath(p)
                if rp not in seen:
                    seen.add(rp)
                    found.append((p, tag))
    return found


# ─────────────────────────────── config editing ──────────────────────────────
KEYRE = re.compile(r"^\s*([A-Za-z_]+)\s*:")
ALIASES = {"interface_branding_colour": "interface_branding_color", "interface_help_colour": "interface_help_color",
           "interface_help_colour_bright": "interface_help_color_bright"}


def strip_block(text):
    if (BEGIN in text) != (END in text):
        die("found an unpaired limine-theme marker in the config; fix it by hand (delete the stray marker line)")
    out, skip, after_end = [], False, False
    for ln in text.splitlines(True):
        s = ln.strip()
        if s == BEGIN:
            skip = True
            continue
        if skip:
            if s == END:
                skip, after_end = False, True   # also drop the one blank separator line we added after the block
            continue
        if after_end:
            after_end = False
            if s == "":
                continue
        if ln.startswith(OFF):
            ln = ln[len(OFF):]
        out.append(ln)
    return "".join(out)


def disable_conflicts(text, keys):
    allk = set(keys)
    for k in list(keys):
        if k in ALIASES:
            allk.add(ALIASES[k])
    out = []
    for ln in text.splitlines(True):
        m = KEYRE.match(ln)
        if m and m.group(1).lower() in allk:
            ln = OFF + ln
        out.append(ln)
    return "".join(out)


def block_keys(block):
    ks = set()
    for ln in block.splitlines():
        m = KEYRE.match(ln)
        if m and not ln.lstrip().startswith("#"):
            ks.add(m.group(1).lower())
    return ks


def atomic_write(path, data):
    tmp = path + ".lt-tmp"
    with open(tmp, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    try:
        shutil.copymode(path, tmp)
    except Exception:
        pass
    os.replace(tmp, path)


def read_conf(path):
    with open(path, encoding="utf-8", errors="surrogateescape", newline="") as f:
        return f.read()


def b2(data):
    return hashlib.blake2b(data).hexdigest()


# ─────────────────────────────── commands ────────────────────────────────────
def swatch(hexes):
    return "".join("\x1b[48;2;%d;%d;%dm  " % hx(h) for h in hexes) + "\x1b[0m"


def cmd_list(a):
    if a.names:
        print("\n".join(THEMES))
        return
    for k, t in THEMES.items():
        sw = swatch([t["bg"], t["brand_c"], t["fg"]] + t["pal"].split(";")[1:7])
        print("  \x1b[1m%-18s\x1b[0m %s  %s" % (k, sw, t["desc"]))


def cmd_preview(a):
    if a.theme not in THEMES:
        die("unknown theme '%s' (try: list)" % a.theme)
    t = THEMES[a.theme]
    ui = UI_DEFAULT.get(a.theme, "none")
    wall = hx(wall_tone(t))
    tt = int(t["panel"], 16) / 255.0
    bgc = hx(t["bg"])
    panel = tuple(int(bgc[i] * (1 - tt) + wall[i] * tt) for i in range(3))
    fg, brand, hlp = hx(t["fg"]), hx(t["brand_c"]), hx(t["help_cb"])
    IW, RST = 66, "\x1b[0m"
    edge = brand if ui != "none" else None

    def bg(c): return "\x1b[48;2;%d;%d;%dm" % c

    def fgc(c): return "\x1b[38;2;%d;%d;%dm" % c

    def wallrow(): return bg(wall) + " " * (IW + 4) + RST

    def mk(spans, border=True):
        n = sum(len(s[0]) for s in spans)
        o = bg(wall) + " " + (fgc(edge) + "\u2502" if edge and border else " ")
        for txt, f, b in spans:
            o += fgc(f) + bg(b or panel) + txt
        return o + bg(panel) + " " * max(0, IW - n) + bg(wall) + (fgc(edge) + "\u2502" if edge and border else " ") + " " + RST

    def center(txt, f, b=None):
        pad = (IW - len(txt)) // 2
        return mk([(" " * pad, f, None), (txt, f, b)])

    entries = ["Arch Linux", "Arch Linux (fallback)", "Windows Boot Manager"]
    ew = max(len(e) for e in entries) + 2
    lines = [wallrow()]
    if edge:
        title = "\u256d\u2500 " + clean_title(osname()) + " " + "\u2500" * (IW - len(clean_title(osname())) - 4) + "\u256e"
        lines.append(bg(wall) + " " + fgc(edge) + title + bg(wall) + " " + RST)
    lines += [center(t["brand"].format(os="Arch Linux"), brand), mk([]),
              mk([(" ARROWS", hlp, None), (" Select  ", fg, None), ("ENTER", hlp, None), (" Boot  ", fg, None),
                  ("E", hlp, None), (" Edit", fg, None), (" " * 12, fg, None), ("S", hlp, None), (" Firmware  ", fg, None),
                  ("B", hlp, None), (" Blank", fg, None)]), mk([]), mk([])]
    for i, e in enumerate(entries):
        txt = (" " + e).ljust(ew)
        pad = " " * ((IW - ew) // 2)
        lines.append(mk([(pad, fg, None), (txt, bgc, fg) if i == 0 else (txt, fg, None)]))
    lines += [mk([]), mk([]), mk([(" Linux 6.x - root on /dev/nvme0n1p2", hlp, None)])]
    if edge:
        lines.append(bg(wall) + " " + fgc(edge) + "\u2570" + "\u2500" * IW + "\u256f" + bg(wall) + " " + RST)
    lines.append(wallrow())
    print("\n".join(lines))
    print("  \x1b[1m%s\x1b[0m — %s   \x1b[2m[ui: %s]\x1b[0m" % (t["title"], t["desc"], ui))
    print("  " + swatch(t["pal"].split(";")) + " " + swatch(t["bright"].split(";")))


def make_block(a, t, name, wall_lines, font_line, colour_mode, lay):
    L = [BEGIN, "# theme: %s  — managed by limine-theme (re-run it to change; edits inside this block are overwritten)" % name]
    L.append("interface_branding: " + (a.branding if a.branding else t["brand"].format(os=osname())))
    if colour_mode == "hex":
        L += ["interface_branding_colour: " + t["brand_c"], "interface_help_colour: " + t["help_cb"],
              "interface_help_colour_bright: " + t["fg_b"]]
    else:
        L += ["interface_branding_colour: %d" % t["brand_i"], "interface_help_colour: %d" % t["help_i"]]
    if a.hide_help:
        L.append("interface_help_hidden: yes")
    if lay["ires"]:
        L.append("interface_resolution: " + lay["ires"])
    L += ["term_palette: " + t["pal"], "term_palette_bright: " + t["bright"],
          "term_background: " + lay["panel"].lower() + t["bg"],
          "term_foreground: " + t["fg"], "term_background_bright: " + t["bg_b"], "term_foreground_bright: " + t["fg_b"],
          "term_margin: %d" % lay["margin"], "term_margin_gradient: %d" % lay["grad"],
          "term_font_spacing: %d" % lay["spacing"]]
    if lay["scale"] and lay["scale"] > 1:
        L.append("term_font_scale: %dx%d" % (lay["scale"], lay["scale"]))
    if font_line:
        L += font_line
    L += wall_lines
    L.append(END)
    return "\n".join(L) + "\n"


def cmd_apply(a):
    if a.theme not in THEMES:
        die("unknown theme '%s' (try: list)" % a.theme)
    t = THEMES[a.theme]
    conf = os.path.abspath(a.conf)
    if not os.path.isfile(conf):
        die("config not found: " + conf)
    if conf.endswith(".cfg"):
        die("%s is a legacy limine.cfg (Limine <= 8 syntax). Upgrade Limine and migrate to limine.conf first." % conf)
    if os.path.exists("/etc/NIXOS") and not a.force:
        die("NixOS regenerates limine.conf on every rebuild. Use boot.loader.limine.style.* in your NixOS config "
            "instead (or pass --force to edit the file anyway).")
    confdir = os.path.dirname(conf)
    mnt = mountpoint(confdir)
    fs = fstype(mnt)
    if fs not in ("vfat", "msdos", "ext2", "ext3", "ext4", "iso9660", "ntfs", "ntfs3", "fuseblk", "exfat", "?"):
        warn("config lives on a '%s' filesystem (%s). Limine only reads FAT/ext2-4/ISO9660 — make sure this is "
             "really the config Limine loads." % (fs, mnt))
    rel = os.path.relpath(confdir, mnt).replace(os.sep, "/")
    base = "" if rel == "." else rel + "/"
    bootpath = lambda fn: "boot():/" + base + SUBDIR + "/" + fn
    wdir = os.path.join(confdir, SUBDIR)

    sb = secure_boot()
    use_hash = a.hash or (sb and not a.no_hash)
    cm = a.colour_mode
    if cm == "auto":
        mj = limine_major()
        cm = "index" if (mj is not None and mj < 12) else "hex"
    text = read_conf(conf)
    clean = strip_block(text)

    # ── layout: with a UI frame the terminal geometry must be predictable
    ui = a.ui or UI_DEFAULT.get(a.theme, "none")
    sw, sh = a.screen
    lay = dict(margin=t["margin"], grad=t["grad"], spacing=t["spacing"], scale=a.scale or 1,
               ires=a.interface_res, panel=(a.panel or t["panel"]))
    if ui != "none":
        lay.update(margin=int(sh * 0.115), grad=0, spacing=0, scale=a.scale or (2 if sh >= 1000 else 1),
                   ires=a.interface_res or "%dx%d" % (sw, sh), panel=(a.panel or "80"))
    title = clean_title(a.title or osname())

    # ── wallpapers / font
    files = []   # (filename, bytes)
    wall_lines = []
    style = "stretched"
    if not a.no_wallpaper and not a.dry_run:
        if a.wallpaper:
            for i, src in enumerate(a.wallpaper):
                ext = os.path.splitext(src)[1].lower().lstrip(".") or "png"
                if ext not in ("png", "jpg", "jpeg", "bmp", "qoi"):
                    die("unsupported wallpaper type: " + src)
                files.append(("wp%d.%s" % (i, ext), open(src, "rb").read()))
            style = a.wallpaper_style or "stretched"
        else:
            w = t["wall"]
            if w["kind"] == "tile" and ui == "none":
                variants, style = 1, "tiled"
            else:
                variants = max(1, a.variants)
            if ui != "none":
                W, H = sw, sh          # frame must line up pixel-for-pixel with the terminal
            else:
                # smooth gradients survive Limine's stretching fine, and smaller files load faster in the bootloader
                W, H = a.res or ((960, 540) if w["kind"] in ("glow", "crt") else (1280, 720))
            for v in range(variants):
                sys.stdout.write("\x1b[36m::\x1b[0m rendering wallpaper %d/%d (%dx%d)…\n" % (v + 1, variants, W, H))
                sys.stdout.flush()
                img = render_full(a.theme, W, H, v, ui, lay, title) if ui != "none" else render(a.theme, W, H, v)
                if a.format == "qoi":
                    files.append(("wp%d.qoi" % v, qoi_bytes(img)))
                else:
                    files.append(("wp%d.png" % v, png_bytes(img)))
    elif not a.no_wallpaper and a.dry_run:
        files = [("wp0.png", b"")]
        style = "tiled" if (t["wall"]["kind"] == "tile" and ui == "none") else "stretched"
    for fn, data in files:
        wall_lines.append("wallpaper: " + bootpath(fn) + ("#" + b2(data) if use_hash and data else ""))
    if files:
        wall_lines.append("wallpaper_style: " + style)
        if style == "centered":
            wall_lines.append("backdrop: " + t["bg"])
    font_line = []
    if a.font:
        data = open(a.font, "rb").read()
        if len(data) != 4096:
            warn("font is %d bytes; a 256-glyph 8x16 CP437 font should be exactly 4096" % len(data))
        files.append(("font.bin", data))
        font_line = ["term_font: " + bootpath("font.bin") + ("#" + b2(data) if use_hash else "")]

    block = make_block(a, t, a.theme, wall_lines, font_line, cm, lay)
    new = disable_conflicts(clean, block_keys(block))
    if re.search(r"(?im)^\s*graphics\s*:\s*no\b", new):
        warn("your config has 'graphics: no' (text mode) — wallpaper, palette and margins are ignored in text mode.")
    result = block + ("\n" if new and not new.startswith("\n") else "") + new

    if a.dry_run:
        print(block)
        print("(dry run — nothing written to %s)" % conf)
        return

    os.makedirs(wdir, exist_ok=True)
    bdir = os.path.join(wdir, "backups")
    os.makedirs(bdir, exist_ok=True)
    shutil.copy2(conf, os.path.join(bdir, "limine.conf.%s" % time.strftime("%Y%m%d-%H%M%S")))
    olds = sorted(glob.glob(os.path.join(bdir, "limine.conf.*")))
    for o in olds[:-5]:
        os.remove(o)
    for old in glob.glob(os.path.join(wdir, "wp*")) + glob.glob(os.path.join(wdir, "font.bin")):
        os.remove(old)
    for fn, data in files:
        with open(os.path.join(wdir, fn), "wb") as f:
            f.write(data)
            f.flush(); os.fsync(f.fileno())
        if len(data) > 1500000:
            warn("%s is %.1f MB — big wallpapers load slowly in Limine; try --format qoi or --res 960x540" %
                 (fn, len(data) / 1e6))
    atomic_write(conf, result)
    print("\x1b[32m✔\x1b[0m theme \x1b[1m%s\x1b[0m written to %s" % (t["title"], conf))
    print("   wallpaper files: %s   colour mode: %s   hashes: %s" %
          ("%s/%s/" % (mnt.rstrip("/"), (base + SUBDIR)) if files else "none", cm, "yes" if use_hash else "no"))
    if sb:
        warn("Secure Boot is ON. If you enrolled a config hash into the Limine binary, re-enroll it now "
             "(limine enroll-config <limine EFI binary> $(b2sum %s | cut -d' ' -f1)), otherwise Limine will refuse "
             "the modified config." % conf)
    if os.path.exists("/usr/bin/limine-entry-tool") or os.path.exists("/usr/bin/limine-update"):
        print("   limine-entry-tool detected: your theme block sits above the auto-generated entries and is left alone.")
    print("   Reboot to see it. Undo any time with: limine-theme.sh remove")


def cmd_status(a):
    text = read_conf(a.conf)
    m = re.search(r"^# theme: (\S+)", text, re.M)
    if BEGIN in text and m:
        print("%s: theme '%s' installed" % (a.conf, m.group(1)))
    else:
        print("%s: no limine-theme block" % a.conf)


def cmd_remove(a):
    conf = os.path.abspath(a.conf)
    text = read_conf(conf)
    if BEGIN not in text and not any(l.startswith(OFF) for l in text.splitlines()):
        print("nothing to remove in " + conf)
        return
    atomic_write(conf, strip_block(text))
    wdir = os.path.join(os.path.dirname(conf), SUBDIR)
    for old in glob.glob(os.path.join(wdir, "wp*")) + glob.glob(os.path.join(wdir, "font.bin")):
        os.remove(old)
    print("\x1b[32m✔\x1b[0m theme block removed from %s; your original lines are restored "
          "(backups kept in %s/backups)." % (conf, wdir))


def cmd_detect(a):
    for p, tag in find_confs():
        print(("legacy:" if tag == "legacy" else "") + p)


def main():
    ap = argparse.ArgumentParser(prog="engine")
    sp = ap.add_subparsers(dest="cmd")
    l = sp.add_parser("list"); l.add_argument("--names", action="store_true")
    p = sp.add_parser("preview"); p.add_argument("theme")
    sp.add_parser("detect")
    for nm in ("status", "remove"):
        s = sp.add_parser(nm); s.add_argument("--conf", required=True)
    s = sp.add_parser("apply")
    s.add_argument("--conf", required=True)
    s.add_argument("--theme", required=True)
    s.add_argument("--variants", type=int, default=1)
    s.add_argument("--res", default=None, type=lambda v: tuple(int(x) for x in v.lower().split("x")))
    s.add_argument("--format", choices=("png", "qoi"), default="png")
    s.add_argument("--branding")
    s.add_argument("--ui", choices=("card", "hud", "none"))
    s.add_argument("--screen", default="1920x1080", type=lambda v: tuple(int(x) for x in v.lower().split("x")))
    s.add_argument("--title")
    s.add_argument("--panel", type=lambda v: v if re.fullmatch(r"[0-9a-fA-F]{2}", v) else die("--panel needs 2 hex digits"))
    s.add_argument("--scale", type=int, choices=range(1, 9))
    s.add_argument("--font")
    s.add_argument("--interface-res", dest="interface_res")
    s.add_argument("--hide-help", action="store_true")
    s.add_argument("--wallpaper", action="append")
    s.add_argument("--wallpaper-style", choices=("stretched", "centered", "tiled"))
    s.add_argument("--no-wallpaper", action="store_true")
    s.add_argument("--hash", action="store_true")
    s.add_argument("--no-hash", action="store_true")
    s.add_argument("--colour-mode", "--color-mode", dest="colour_mode", choices=("auto", "hex", "index"), default="auto")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--force", action="store_true")
    a = ap.parse_args()
    {"list": cmd_list, "preview": cmd_preview, "apply": cmd_apply, "status": cmd_status, "remove": cmd_remove,
     "detect": cmd_detect}.get(a.cmd, lambda _: ap.print_help())(a)


if __name__ == "__main__":
    main()
PYEOF

eng() { python3 "$PY" "$@"; }

# ─── root escalation (needed to read/write the ESP) ───────────────────────────
need_root() {
  [ "$(id -u)" -eq 0 ] && return 0
  [ -f "$SELF" ] || die "re-run as root:  sudo bash limine-theme.sh ..."
  for s in sudo doas; do
    if command -v "$s" >/dev/null 2>&1; then
      info "need root to edit the boot partition — re-running with $s"
      exec "$s" bash "$SELF" "${ARGS[@]}"
    fi
  done
  die "root required and neither sudo nor doas found; run this script as root."
}

# ─── locate limine.conf ───────────────────────────────────────────────────────
pick_conf() {
  [ -n "$conf" ] && return 0
  local found=() legacy=() line
  while IFS= read -r line; do
    case "$line" in legacy:*) legacy+=("${line#legacy:}") ;; ?*) found+=("$line") ;; esac
  done < <(eng detect)
  if [ ${#found[@]} -eq 0 ]; then
    [ ${#legacy[@]} -gt 0 ] && die "only legacy limine.cfg found (${legacy[0]}). This tool needs Limine v9+ 'limine.conf'."
    die "no limine.conf found. Is the ESP mounted? Pass --conf /path/to/limine.conf (or LIMINE_THEME_ROOTS=/mnt/esp)."
  fi
  if [ ${#found[@]} -eq 1 ] || [ ! -t 0 ]; then
    conf="${found[0]}"
    [ ${#found[@]} -gt 1 ] && warn "several limine.conf files found; using ${conf} (override with --conf). Others: ${found[*]:1}"
    return 0
  fi
  echo "${B}Several limine.conf files found${Z} (Limine reads the first one it finds, EFI-directory ones first):"
  local i=1; for line in "${found[@]}"; do printf '  %d) %s\n' "$i" "$line"; i=$((i+1)); done
  local n; read -r -p "Which one is yours? [1] " n; n=${n:-1}
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#found[@]} ] || die "invalid choice"
  conf="${found[$((n-1))]}"
}

# ─── interactive picker ───────────────────────────────────────────────────────
pick_theme() {
  [ -t 0 ] && [ -t 1 ] || die "no --theme given and not running in a terminal (see: limine-theme.sh list)"
  mapfile -t TH < <(eng list --names)
  local i=0 n=${#TH[@]} key rest
  tput civis 2>/dev/null || true
  while :; do
    printf '\e[H\e[2J'
    printf '%s  limine-theme%s — pick a look for your boot menu\n\n' "$B" "$Z"
    eng preview "${TH[$i]}"
    printf '\n  %s◀%s  %d/%d  %s%s%s  %s▶%s\n' "$D" "$Z" $((i+1)) "$n" "$B" "${TH[$i]}" "$Z" "$D" "$Z"
    printf '  %s←/→ browse   Enter install   q quit%s\n' "$D" "$Z"
    IFS= read -rsn1 key || exit 1
    if [[ $key == $'\e' ]]; then read -rsn2 -t 0.05 rest || true; key+="$rest"; fi
    case "$key" in
      $'\e[C'|$'\e[B'|l|j|' ') i=$(( (i+1) % n )) ;;
      $'\e[D'|$'\e[A'|h|k)     i=$(( (i-1+n) % n )) ;;
      '') theme="${TH[$i]}"; break ;;
      q|Q) tput cnorm 2>/dev/null || true; printf '\n'; exit 0 ;;
    esac
  done
  tput cnorm 2>/dev/null || true
  printf '\e[H\e[2J'
}

# ─── dispatch ─────────────────────────────────────────────────────────────────
case "$cmd" in
  list)    eng list; exit 0 ;;
  preview) eng preview "$theme"; exit 0 ;;
  status)  need_root; pick_conf; eng status --conf "$conf"; exit 0 ;;
  remove)  need_root; pick_conf
           if [ "$yes" -eq 0 ] && [ -t 0 ]; then read -r -p "Remove the limine-theme block from $conf? [y/N] " a; [[ "$a" =~ ^[Yy] ]] || exit 0; fi
           eng remove --conf "$conf"; exit 0 ;;
  install)
    need_root
    pick_conf
    [ -n "$theme" ] || pick_theme
    info "config:  $conf"
    info "theme:   $theme"
    if [ "$yes" -eq 0 ] && [ -t 0 ] && [[ " ${pass[*]-} " != *" --dry-run "* ]]; then
      read -r -p "Apply? A timestamped backup of limine.conf is kept. [Y/n] " a
      [[ -z "$a" || "$a" =~ ^[Yy] ]] || exit 0
    fi
    eng apply --conf "$conf" --theme "$theme" ${pass[@]+"${pass[@]}"}
    ;;
esac
