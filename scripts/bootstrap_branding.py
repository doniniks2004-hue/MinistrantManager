from __future__ import annotations
import base64
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
PAYLOAD = ROOT / "branding-bootstrap"

def decode_parts(group: str, target: Path) -> None:
    parts = sorted((PAYLOAD / group).glob("*.part"))
    if not parts:
        raise RuntimeError(f"Missing branding payload for {group}")
    raw = base64.b64decode("".join(p.read_text().strip() for p in parts), validate=True)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(raw)

work = ROOT / ".branding-work"
work.mkdir(exist_ok=True)
icon_src = work / "app_icon.png"
logo_src = work / "logo.png"
decode_parts("icon", icon_src)
decode_parts("logo", logo_src)

icon = Image.open(icon_src).convert("RGBA")
logo = Image.open(logo_src).convert("RGBA")

def fit_on_canvas(img: Image.Image, size: tuple[int, int], padding: float = 0.10, bg=(245,245,245,255)) -> Image.Image:
    canvas = Image.new("RGBA", size, bg)
    max_w = int(size[0] * (1 - 2 * padding))
    max_h = int(size[1] * (1 - 2 * padding))
    copy = img.copy()
    copy.thumbnail((max_w, max_h), Image.Resampling.LANCZOS)
    x = (size[0] - copy.width) // 2
    y = (size[1] - copy.height) // 2
    canvas.alpha_composite(copy, (x, y))
    return canvas

def save_rgb(img: Image.Image, path: Path, size: tuple[int,int] | None = None) -> None:
    if size:
        img = img.resize(size, Image.Resampling.LANCZOS)
    bg = Image.new("RGB", img.size, (255,255,255))
    if img.mode == "RGBA":
        bg.paste(img, mask=img.getchannel("A"))
    else:
        bg.paste(img)
    path.parent.mkdir(parents=True, exist_ok=True)
    bg.save(path, "PNG", optimize=True)

# Source branding assets for both Flutter projects.
for project in ("mobile-android", "mobile-ios"):
    brand = ROOT / project / "assets" / "branding"
    brand.mkdir(parents=True, exist_ok=True)
    save_rgb(icon, brand / "app_icon.png", (1024,1024))
    save_rgb(logo, brand / "logo.png")
    splash = fit_on_canvas(logo, (1200, 600), padding=0.12)
    save_rgb(splash, brand / "splash_logo.png")

# Android launcher mipmaps.
android_sizes = {"mdpi":48, "hdpi":72, "xhdpi":96, "xxhdpi":144, "xxxhdpi":192}
for density, px in android_sizes.items():
    out = ROOT / "mobile-android" / "android" / "app" / "src" / "main" / "res" / f"mipmap-{density}" / "ic_launcher.png"
    save_rgb(icon, out, (px, px))

# iOS AppIcon set. All exported without alpha (App Store requirement).
ios_icons = {
    "Icon-App-20x20@1x.png":20, "Icon-App-20x20@2x.png":40, "Icon-App-20x20@3x.png":60,
    "Icon-App-29x29@1x.png":29, "Icon-App-29x29@2x.png":58, "Icon-App-29x29@3x.png":87,
    "Icon-App-40x40@1x.png":40, "Icon-App-40x40@2x.png":80, "Icon-App-40x40@3x.png":120,
    "Icon-App-60x60@2x.png":120, "Icon-App-60x60@3x.png":180,
    "Icon-App-76x76@1x.png":76, "Icon-App-76x76@2x.png":152,
    "Icon-App-83.5x83.5@2x.png":167, "Icon-App-1024x1024@1x.png":1024,
}
ios_dir = ROOT / "mobile-ios" / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
for name, px in ios_icons.items():
    save_rgb(icon, ios_dir / name, (px, px))

# Legacy iOS LaunchImage set; flutter_native_splash will also refresh launch resources.
launch_dir = ROOT / "mobile-ios" / "ios" / "Runner" / "Assets.xcassets" / "LaunchImage.imageset"
for name, px in (("LaunchImage.png", 320), ("LaunchImage@2x.png", 640), ("LaunchImage@3x.png", 960)):
    save_rgb(fit_on_canvas(logo, (px, px), padding=0.14), launch_dir / name)

print("Branding sources and launcher icons generated successfully.")
