#!/usr/bin/env bash
# Build thumbnails for the wallpaper picker.
# Usage: wallpaper-prep.sh [wallpaper-dir]
set -u

SRC_DIR="${1:-${WALLPAPER_DIR:-$HOME/Pictures/Wallpapers}}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/quickshell/wallpaper_picker"
THUMB_DIR="$CACHE/thumbs"
MANIFEST="$THUMB_DIR/.manifest"

mkdir -p "$THUMB_DIR"
[ -d "$SRC_DIR" ] || exit 0

LOCK="$CACHE/.prep.lock"
if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK")" 2>/dev/null; then
    exit 0
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

# If the wallpaper directory changed, start with a clean thumbnail set.
if [ -f "$THUMB_DIR/.source_dir" ] && [ "$(cat "$THUMB_DIR/.source_dir")" != "$SRC_DIR" ]; then
    find "$THUMB_DIR" -maxdepth 1 -type f ! -name '.source_dir' -delete
    : > "$MANIFEST"
fi
echo "$SRC_DIR" > "$THUMB_DIR/.source_dir"
[ -f "$MANIFEST" ] || : > "$MANIFEST"

MAGICK="$(command -v magick || command -v convert || true)"
[ -n "$MAGICK" ] || exit 0

# Drop thumbnails whose source has been deleted (including old video thumbs).
for thumb in "$THUMB_DIR"/*; do
    [ -f "$thumb" ] || continue
    base="${thumb##*/}"
    case "$base" in
        .*|000_*) rm -f "$thumb" ;;
        *) [ -e "$SRC_DIR/$base" ] || rm -f "$thumb" ;;
    esac
done

find "$SRC_DIR" -maxdepth 1 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
       -o -iname '*.webp' -o -iname '*.gif' \) -printf '%f\n' \
    | sort | while IFS= read -r f; do
        [ -e "$SRC_DIR/$f" ] || continue
        thumb="$THUMB_DIR/$f"
        if [ ! -s "$thumb" ]; then
            "$MAGICK" "$SRC_DIR/$f" -resize x420 -quality 70 "$thumb" >/dev/null 2>&1 || continue
            echo "$f" >> "$MANIFEST"
        fi
    done
