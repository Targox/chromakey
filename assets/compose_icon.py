from pathlib import Path
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parent
base = Image.open(root / 'icon-work/passwords-1024.png').convert('RGBA')
chrome = Image.open(root / 'icon-work/chrome-1024.png').convert('RGBA')
logo = chrome.crop((182, 182, 842, 842))
scale = 4
mask = Image.new('L', (660 * scale, 660 * scale), 0)
ImageDraw.Draw(mask).ellipse((0, 0, 660 * scale - 1, 660 * scale - 1), fill=255)
logo.putalpha(mask.resize((660, 660), Image.Resampling.LANCZOS))
logo.save(root / 'chrome-emblem.png')
head = logo.resize((280, 280), Image.Resampling.LANCZOS)
for x, angle in zip((203, 372, 541), (0, 120, 240)):
    rotated = head.rotate(angle, resample=Image.Resampling.BICUBIC, expand=True)
    base.alpha_composite(rotated, (x + (280 - rotated.width) // 2,
                                  243 + (280 - rotated.height) // 2))
tile = base.crop(base.getchannel('A').point(lambda alpha: 255 if alpha > 64 else 0).getbbox())
tile.save(root / 'AppIcon.png')
tile.resize((256, 256), Image.Resampling.LANCZOS).save(root / 'AppIcon-preview.png')
iconset = root / 'AppIcon.iconset'
iconset.mkdir(exist_ok=True)
for points in (16, 32, 128, 256, 512):
    for multiplier in (1, 2):
        suffix = '@2x' if multiplier == 2 else ''
        size = points * multiplier
        base.resize((size, size), Image.Resampling.LANCZOS).save(iconset / f'icon_{points}x{points}{suffix}.png')
