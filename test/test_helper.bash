#!/usr/bin/env bash
# Shared helpers for the sync.sh bats suite.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$PROJECT_ROOT/sync.sh"
export PROJECT_ROOT SYNC

# Minimal valid 1x1 JPEG, used as a metadata-capable media fixture.
TINY_JPG_B64='/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AVN//2Q=='

make_jpg() {
    printf '%s' "$TINY_JPG_B64" | base64 -d > "$1"
}

# make_jpg_with_date <path> <exif-date "YYYY:MM:DD HH:MM:SS">
make_jpg_with_date() {
    make_jpg "$1"
    exiftool -q -overwrite_original -DateTimeOriginal="$2" "$1"
}

# make_card <dir> [mtime YYYYMMDDhhmm]
# Fixture SD card: two mp4s without metadata, a file inside .Trashes,
# and a non-matching extension.
make_card() {
    local dir="$1" mtime="${2:-202503151030}"
    mkdir -p "$dir/DCIM/100GOPRO" "$dir/.Trashes"
    printf 'video-1' > "$dir/DCIM/100GOPRO/GX010001.MP4"
    printf 'video-2' > "$dir/DCIM/100GOPRO/GX010002.MP4"
    printf 'trash' > "$dir/.Trashes/deleted.mp4"
    printf 'notes' > "$dir/DCIM/notes.txt"
    touch -t "$mtime" \
        "$dir/DCIM/100GOPRO/GX010001.MP4" \
        "$dir/DCIM/100GOPRO/GX010002.MP4" \
        "$dir/.Trashes/deleted.mp4"
}

# write_config <path> [line...]
write_config() {
    local path="$1"
    shift
    printf '%s\n' "$@" > "$path"
}

# mtime as YYYYMMDDhhmm.SS; detect stat flavor by capability, since PATH may
# put GNU coreutils first even on macOS
file_mtime() {
    if stat --version >/dev/null 2>&1; then
        date -d "@$(stat -c '%Y' "$1")" '+%Y%m%d%H%M.%S'
    else
        stat -f "%Sm" -t "%Y%m%d%H%M.%S" "$1"
    fi
}

require_exiftool() {
    command -v exiftool >/dev/null || skip "exiftool not installed"
}

# make_exiftool_shim <shim_dir> <count_file>
# Builds a PATH shim that logs one line per exiftool invocation, then execs
# the real exiftool.
make_exiftool_shim() {
    local shim_dir="$1" count_file="$2"
    local real
    real=$(command -v exiftool)
    mkdir -p "$shim_dir"
    printf '#!/usr/bin/env bash\necho x >> "%s"\nexec "%s" "$@"\n' \
        "$count_file" "$real" > "$shim_dir/exiftool"
    chmod +x "$shim_dir/exiftool"
}

# Run a snippet in a fresh bash that has sourced sync.sh.
call() {
    bash -c "source '$SYNC'; $*"
}
