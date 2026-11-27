#!/bin/sh
# Encode one PQ16 frame with each libavif encoder and collect comparable receipts.
# Usage: avif_bakeoff.sh <input.png> <output-dir> <tag> <qcolor> <speed> <jobs> <yuv>
set -eu
input=$1
out=$2
tag=$3
quality=$4
speed=$5
jobs=$6
yuv=$7
mkdir -p "$out"
for codec in aom svt rav1e; do
    avif="$out/$tag-$codec.avif"
    echo "== $codec"
    /usr/bin/time -f "%e %M" -o "$out/$tag-$codec.time" \
        avifenc -q "$quality" -s "$speed" -j "$jobs" --yuv "$yuv" -d 10 \
        --cicp 9/16/1 --range full -c "$codec" "$input" "$avif"
    stat -c %s "$avif" > "$out/$tag-$codec.bytes"
    avifdec --info "$avif" > "$out/$tag-$codec.info" 2>&1
    avifdec -j all -d 16 -u best "$avif" "$out/$tag-$codec.png" >/dev/null
    ffmpeg -hide_banner -loglevel error -f image2 -i "$out/$tag-$codec.png" \
        -f rawvideo -pix_fmt rgb48le -y "$out/$tag-$codec.rgb"
    width=$(identify -format '%w' "$out/$tag-$codec.png")
    height=$(identify -format '%h' "$out/$tag-$codec.png")
    python3 "$(dirname "$0")/avif_metrics.py" \
        --input "$out/$tag-source.rgb" --decoded "$out/$tag-$codec.rgb" \
        --width "$width" --height "$height" \
        --report "$out/$tag-$codec.metrics.json"
    ffprobe -v error -show_streams -show_format -of json "$avif" > "$out/$tag-$codec.ffprobe.json"
done
echo "done: $out/$tag"
