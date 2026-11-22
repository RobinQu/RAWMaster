from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

root = Path(__file__).resolve().parents[1]
fixtures = root / "Fixtures" / "Downloaded"
masks = root / "Validation" / "Tests"
rows = [
    [("car.png", "Car · input", fixtures), ("subject-car.png", "IS-Net · subject", masks),
     ("object-point-car.png", "SlimSAM · point", masks), ("object-box-car-candidate-0.png", "SlimSAM · box + center", masks),
     ("background-car.png", "IS-Net · background", masks)],
    [("mountain-lake.jpg", "Landscape · input", fixtures), ("landscape-sky.png", "Sky", masks),
     ("landscape-water.png", "Water", masks), ("landscape-mountains.png", "Mountains", masks),
     ("landscape-vegetation.png", "Vegetation probability", masks)],
    [("lena.jpg", "Portrait · input", fixtures), ("person-entirePerson.png", "Entire person", masks),
     ("person-faceSkin.png", "Face skin", masks), ("person-hair.png", "Hair probability", masks),
     ("person-eyeSclera.png", "Eye sclera", masks)],
    [("messi5.jpg", "Full body · input", fixtures), ("person-selected-messi.png", "Selected person", masks),
     ("person-all-messi.png", "All detected people", masks)],
    [("snow.jpg", "Snow · input", fixtures), ("landscape-snow.png", "Snow compatibility experiment", masks)],
]
cell_w, cell_h, label_h = 280, 210, 32
sheet = Image.new("RGB", (cell_w * 5, (cell_h + label_h) * len(rows)), "#11161d")
draw = ImageDraw.Draw(sheet)
try:
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 16)
except OSError:
    font = ImageFont.load_default()
for row_index, row in enumerate(rows):
    for column, (name, label, directory) in enumerate(row):
        image = Image.open(directory / name).convert("RGB")
        image.thumbnail((cell_w, cell_h), Image.Resampling.LANCZOS)
        x = column * cell_w + (cell_w - image.width) // 2
        y = row_index * (cell_h + label_h) + label_h + (cell_h - image.height) // 2
        sheet.paste(image, (x, y))
        draw.text((column * cell_w + 8, row_index * (cell_h + label_h) + 7), label, fill="#eef2f6", font=font)
output = root / "Validation" / "contact-sheet.jpg"
sheet.save(output, quality=92)
print(output)
