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

@test "format_bytes reports one decimal for kilobytes" {
    run call format_bytes 1536
    [ "$output" = "1.5 KB" ]
}

@test "format_bytes reports one decimal for large sizes" {
    run call format_bytes 5000000000
    [ "$output" = "4.7 GB" ]
}

@test "format_time formats hours minutes seconds" {
    run call format_time 3725
    [ "$output" = "1h 2m 5s" ]
}

# --- UUID to name mapping ---------------------------------------------------
# get_volume_uuid is overridden in the sourced shell to simulate a card.

@test "get_sdcard_name resolves mapped name from FAT32 short serial" {
    run call "get_volume_uuid() { echo E957-B26D; }
        CONFIG_FILE=cfg; UUID_MAP[E957-B26D]=chad/Hero12
        get_sdcard_name /Volumes/FOO"
    [ "$output" = "chad/Hero12" ]
}

@test "get_sdcard_name resolves mapped name from full UUID" {
    run call "get_volume_uuid() { echo 238ECE38-E071-3604-90C9-1234ABCD5678; }
        CONFIG_FILE=cfg; UUID_MAP[238ECE38-E071-3604-90C9-1234ABCD5678]=pete/pd1
        get_sdcard_name /Volumes/FOO"
    [ "$output" = "pete/pd1" ]
}

@test "get_sdcard_name errors on unmapped UUID when mappings exist" {
    run call "get_volume_uuid() { echo AAAA-BBBB; }
        CONFIG_FILE=cfg; UUID_MAP[E957-B26D]=chad/Hero12
        get_sdcard_name /Volumes/FOO"
    [ "$status" -eq 4 ]
}

# --- extract_timestamp ------------------------------------------------------

@test "extract_timestamp returns touch format from exif capture date" {
    require_exiftool
    f="$BATS_TEST_TMPDIR/photo.jpg"
    make_jpg_with_date "$f" '2025:01:15 10:30:25'
    touch -t 202506010101 "$f"
    run call extract_timestamp "'$f'" exiftool
    [ "$output" = "202501151030.25" ]
}

@test "extract_timestamp is empty for files without metadata" {
    require_exiftool
    f="$BATS_TEST_TMPDIR/clip.mp4"
    printf 'x' > "$f"
    touch -t 202411020908 "$f"
    run call extract_timestamp "'$f'" exiftool
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "extract_timestamp is empty when no metadata tool is available" {
    f="$BATS_TEST_TMPDIR/clip.mp4"
    printf 'x' > "$f"
    run call extract_timestamp "'$f'" none
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "stat_mtime_date reports file mtime as YYYYMMDD" {
    f="$BATS_TEST_TMPDIR/clip.mp4"
    printf 'x' > "$f"
    touch -t 202411020908 "$f"
    run call stat_mtime_date "'$f'"
    [ "$output" = "20241102" ]
}

# --- load_config ------------------------------------------------------------

@test "load_config parses FORMATS and trims surrounding whitespace" {
    cfg="$BATS_TEST_TMPDIR/cfg.txt"
    write_config "$cfg" 'FORMATS= mp4 , wav '
    run call "load_config '$cfg' >/dev/null; printf '%s|' \"\${FILE_FORMATS[@]}\""
    [ "$output" = "mp4|wav|" ]
}

@test "load_config preserves internal spaces in IGNORE_FOLDERS" {
    cfg="$BATS_TEST_TMPDIR/cfg.txt"
    write_config "$cfg" 'IGNORE_FOLDERS=.Trashes, Temporary Items'
    run call "load_config '$cfg' >/dev/null; printf '%s|' \"\${IGNORE_FOLDERS[@]}\""
    [ "$output" = ".Trashes|Temporary Items|" ]
}

@test "load_config trims tabs around config values" {
    cfg="$BATS_TEST_TMPDIR/cfg.txt"
    printf 'FORMATS=\tmp4\t,\twav\t\n' > "$cfg"
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
