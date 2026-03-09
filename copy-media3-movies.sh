#!/bin/bash
# Copy loose video files from ~/media/media3 into their matching folders in ~/media/hdd8tb/movies
# Matching is done by imdbid (e.g. tt31193180) present in both the filename and the folder name.

SOURCE_DIR="$HOME/media/media3"
DEST_DIR="/home/brad/media/hdd8tb/movies"

copied=0
skipped=0
not_found=0

for filepath in "$SOURCE_DIR"/*.{mkv,mp4,avi,mov,MKV,MP4,AVI,MOV}; do
    [[ -e "$filepath" ]] || continue

    filename=$(basename "$filepath")

    # Extract imdbid from filename
    imdbid=$(echo "$filename" | grep -oP 'imdbid-tt\d+' | head -1)

    if [[ -z "$imdbid" ]]; then
        echo "WARNING: No imdbid found in: $filename"
        ((not_found++))
        continue
    fi

    # Find matching folder in destination
    dest_folder=$(find "$DEST_DIR" -maxdepth 1 -type d -name "*${imdbid}*" | head -1)

    if [[ -z "$dest_folder" ]]; then
        echo "WARNING: No matching folder found for imdbid '$imdbid': $filename"
        ((not_found++))
        continue
    fi

    dest_file="$dest_folder/$filename"

    if [[ -e "$dest_file" ]]; then
        echo "SKIP (exists): $filename"
        ((skipped++))
        continue
    fi

    echo "COPY: $filename"
    echo "   -> $(basename "$dest_folder")/"
    cp -- "$filepath" "$dest_file"
    if [[ $? -eq 0 ]]; then
        ((copied++))
    else
        echo "ERROR: Failed to copy: $filename"
    fi
done

echo ""
echo "Done.  Copied: $copied | Already existed: $skipped | No folder found: $not_found"
