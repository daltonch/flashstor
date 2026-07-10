#!/usr/bin/env bats
# Unit tests: source sync.sh and exercise individual functions.

load test_helper

# --- sourcing guard ---------------------------------------------------------

@test "sourcing sync.sh does not run main" {
    run bash -c "source '$SYNC'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- formatting helpers -----------------------------------------------------

@test "format_bytes keeps small byte values exact" {
    run call format_bytes 512
    [ "$output" = "512 B" ]
}

@test "format_time formats hours minutes seconds" {
    run call format_time 3725
    [ "$output" = "1h 2m 5s" ]
}

# --- get_short_uuid ---------------------------------------------------------

@test "get_short_uuid passes through FAT32 short serials" {
    run call get_short_uuid E957-B26D
    [ "$output" = "E957-B26D" ]
}

# --- extract_date -----------------------------------------------------------

@test "extract_date falls back to file mtime when tool is none" {
    f="$BATS_TEST_TMPDIR/clip.mp4"
    printf 'x' > "$f"
    touch -t 202411020908 "$f"
    run call extract_date "'$f'" none
    [ "$output" = "20241102" ]
}

@test "extract_date with exiftool falls back to mtime without metadata" {
    require_exiftool
    f="$BATS_TEST_TMPDIR/clip.mp4"
    printf 'x' > "$f"
    touch -t 202411020908 "$f"
    run call extract_date "'$f'" exiftool
    [ "$output" = "20241102" ]
}

@test "extract_date reads exif capture date from jpg" {
    require_exiftool
    f="$BATS_TEST_TMPDIR/photo.jpg"
    make_jpg_with_date "$f" '2025:01:15 10:30:25'
    touch -t 202506010101 "$f"
    run call extract_date "'$f'" exiftool
    [ "$output" = "20250115" ]
}

# --- load_config ------------------------------------------------------------

@test "load_config parses FORMATS and trims surrounding whitespace" {
    cfg="$BATS_TEST_TMPDIR/cfg.txt"
    write_config "$cfg" 'FORMATS= mp4 , wav '
    run call "load_config '$cfg' >/dev/null; printf '%s|' \"\${FILE_FORMATS[@]}\""
    [ "$output" = "mp4|wav|" ]
}

@test "load_config parses LABELS mappings" {
    cfg="$BATS_TEST_TMPDIR/cfg.txt"
    write_config "$cfg" 'LABELS:' 'E957-B26D=chad/Hero12'
    run call "load_config '$cfg' >/dev/null; printf '%s' \"\${UUID_MAP[E957-B26D]}\""
    [ "$output" = "chad/Hero12" ]
}

@test "load_config rejects UUID mappings before LABELS header" {
    cfg="$BATS_TEST_TMPDIR/cfg.txt"
    write_config "$cfg" 'E957-B26D=chad/Hero12'
    run call "load_config '$cfg'"
    [ "$status" -eq 4 ]
}
