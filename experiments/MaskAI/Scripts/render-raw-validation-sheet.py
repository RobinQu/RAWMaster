from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

root = Path(__file__).resolve().parents[1]
out = root / "Validation" / "RAW"
rows = [
    [("sony-landscape-base.png", "Sunset RAW · base"),
     ("8f96d2fd-landscape-sky-mask.png", "Sky mask"),
     ("8f96d2fd-landscape-sky-effect.png", "Sky +0.75 EV"),
     ("8f96d2fd-landscape-water-mask.png", "Water mask"),
     ("8f96d2fd-landscape-water-effect.png", "Water +0.75 EV")],
    [("sony-sample-02-base.png", "Forest RAW · base"),
     ("4e7e80f4-landscape-vegetation-mask.png", "Vegetation mask"),
     ("4e7e80f4-landscape-vegetation-effect.png", "Vegetation +0.75 EV"),
     ("4e7e80f4-landscape-mountains-mask.png", "Mountains mask"),
     ("4e7e80f4-landscape-mountains-effect.png", "Mountains +0.75 EV")],
    [("sony-sample-03-base.png", "Bird RAW · base"),
     ("7e1c08d9-subject-mask.png", "Subject mask"),
     ("7e1c08d9-subject-effect.png", "Subject +0.75 EV"),
     ("7e1c08d9-object-point-mask.png", "Point mask"),
     ("7e1c08d9-object-point-effect.png", "Point +0.75 EV")],
    [("sony-sample-03-native-crop-base.png", "Native crop · base"),
     ("sony-sample-03-native-crop-mask.png", "Native crop mask"),
     ("sony-sample-03-native-crop-effect.png", "Native crop +0.75 EV")],
]
cell_w, cell_h, label_h = 280, 205, 32
sheet = Image.new("RGB", (cell_w * 5, (cell_h + label_h) * len(rows)), "#11161d")
draw = ImageDraw.Draw(sheet)
try:
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 16)
except OSError:
    font = ImageFont.load_default()
for row_index, row in enumerate(rows):
    for column, (name, label) in enumerate(row):
        image = Image.open(out / name).convert("RGB")
        image.thumbnail((cell_w, cell_h), Image.Resampling.LANCZOS)
        x = column * cell_w + (cell_w - image.width) // 2
        y = row_index * (cell_h + label_h) + label_h + (cell_h - image.height) // 2
        sheet.paste(image, (x, y))
        draw.text((column * cell_w + 8, row_index * (cell_h + label_h) + 7), label, fill="#eef2f6", font=font)
output = out / "raw-contact-sheet.jpg"
sheet.save(output, quality=92)
print(output)
