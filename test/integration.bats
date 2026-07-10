#!/usr/bin/env bats
# End-to-end tests: run sync.sh against fixture SD cards.

load test_helper

setup() {
    CARD="$BATS_TEST_TMPDIR/CARD_A"
    TARGET="$BATS_TEST_TMPDIR/target"
    mkdir -p "$TARGET"
}

@test "organizes files by mtime date and volume name" {
    make_card "$CARD" 202503151030
    run "$SYNC" --source "$CARD" --target "$TARGET"
    [ "$status" -eq 0 ]
    [ -f "$TARGET/20250315/CARD_A/GX010001.MP4" ]
    [ -f "$TARGET/20250315/CARD_A/GX010002.MP4" ]
}

@test "default ignore skips .Trashes" {
    make_card "$CARD"
    run "$SYNC" --source "$CARD" --target "$TARGET"
    [ "$status" -eq 0 ]
    run find "$TARGET" -name 'deleted.mp4'
    [ -z "$output" ]
}

@test "non-matching extensions are not copied" {
    make_card "$CARD"
    run "$SYNC" --source "$CARD" --target "$TARGET"
    run find "$TARGET" -name 'notes.txt'
    [ -z "$output" ]
}

@test "FORMATS config filters file types" {
    make_card "$CARD"
    printf 'audio' > "$CARD/DCIM/100GOPRO/GX010001.WAV"
    touch -t 202503151030 "$CARD/DCIM/100GOPRO/GX010001.WAV"
    write_config "$BATS_TEST_TMPDIR/cfg.txt" 'FORMATS=wav'
    run "$SYNC" --source "$CARD" --target "$TARGET" --config "$BATS_TEST_TMPDIR/cfg.txt"
    [ "$status" -eq 0 ]
    [ -f "$TARGET/20250315/CARD_A/GX010001.WAV" ]
    run find "$TARGET" -name '*.MP4'
    [ -z "$output" ]
}

@test "IGNORE_FOLDERS config skips extra folders" {
    make_card "$CARD"
    mkdir -p "$CARD/DCIM/MISC"
    printf 'x' > "$CARD/DCIM/MISC/skipme.mp4"
    write_config "$BATS_TEST_TMPDIR/cfg.txt" 'IGNORE_FOLDERS=.Trashes,MISC'
    run "$SYNC" --source "$CARD" --target "$TARGET" --config "$BATS_TEST_TMPDIR/cfg.txt"
    [ "$status" -eq 0 ]
    run find "$TARGET" -name 'skipme.mp4'
    [ -z "$output" ]
}

@test "config values cannot inject shell commands" {
    make_card "$CARD"
    write_config "$BATS_TEST_TMPDIR/cfg.txt" \
        "IGNORE_FOLDERS=.Trashes,\$(touch $BATS_TEST_TMPDIR/pwned)"
    run "$SYNC" --source "$CARD" --target "$TARGET" --config "$BATS_TEST_TMPDIR/cfg.txt"
    [ ! -f "$BATS_TEST_TMPDIR/pwned" ]
    [ -f "$TARGET/20250315/CARD_A/GX010001.MP4" ]
}

@test "existing files are skipped, not overwritten" {
    make_card "$CARD"
    "$SYNC" --source "$CARD" --target "$TARGET" > /dev/null
    copy="$TARGET/20250315/CARD_A/GX010001.MP4"
    printf 'edited' > "$copy"
    run "$SYNC" --source "$CARD" --target "$TARGET"
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipped (exists)"* ]]
    [ "$(cat "$copy")" = "edited" ]
}

@test "skipped files are listed exactly once in the summary" {
    make_card "$CARD"
    "$SYNC" --source "$CARD" --target "$TARGET" > /dev/null
    run "$SYNC" --source "$CARD" --target "$TARGET"
    [ "$(grep -c '^  - GX010001.MP4$' <<< "$output")" -eq 1 ]
}

@test "errored files are listed exactly once in the summary" {
    make_card "$CARD"
    chmod 000 "$CARD/DCIM/100GOPRO/GX010001.MP4"
    run "$SYNC" --source "$CARD" --target "$TARGET"
    [ "$status" -eq 1 ]
    [ "$(grep -c '^  - GX010001.MP4$' <<< "$output")" -eq 1 ]
}

@test "parallel mode lists skipped files in the summary" {
    make_card "$CARD"
    card_b="$BATS_TEST_TMPDIR/CARD_B"
    make_card "$card_b" 202504010900
    "$SYNC" --source "$CARD" --target "$TARGET" > /dev/null
    "$SYNC" --source "$card_b" --target "$TARGET" > /dev/null
    run "$SYNC" --source "$CARD" --source "$card_b" --target "$TARGET"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Total files skipped:  4"* ]]
    [ "$(grep -c '^  - GX010001.MP4$' <<< "$output")" -eq 2 ]
    [ "$(grep -c '^  - GX010002.MP4$' <<< "$output")" -eq 2 ]
}

@test "parallel mode lists errored files in the summary" {
    make_card "$CARD"
    card_b="$BATS_TEST_TMPDIR/CARD_B"
    make_card "$card_b" 202504010900
    chmod 000 "$CARD/DCIM/100GOPRO/GX010001.MP4"
    run "$SYNC" --source "$CARD" --source "$card_b" --target "$TARGET"
    [ "$status" -eq 1 ]
    [ "$(grep -c '^  - GX010001.MP4$' <<< "$output")" -eq 1 ]
}

@test "multiple sources are all imported (parallel mode)" {
    make_card "$CARD"
    card_b="$BATS_TEST_TMPDIR/CARD_B"
    make_card "$card_b" 202504010900
    run "$SYNC" --source "$CARD" --source "$card_b" --target "$TARGET"
    [ "$status" -eq 0 ]
    [ -f "$TARGET/20250315/CARD_A/GX010001.MP4" ]
    [ -f "$TARGET/20250401/CARD_B/GX010001.MP4" ]
}

@test "dry-run reports would-copy totals and writes nothing" {
    make_card "$CARD"
    run "$SYNC" --source "$CARD" --target "$TARGET" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Total files to copy:  2"* ]]
    [[ "$output" == *"Total size to copy:   14 B"* ]]
    run find "$TARGET" -type f
    [ -z "$output" ]
}

@test "dry-run counts skips and matches a subsequent real run" {
    make_card "$CARD"
    "$SYNC" --source "$CARD" --target "$TARGET" > /dev/null
    rm "$TARGET/20250315/CARD_A/GX010002.MP4"
    run "$SYNC" --source "$CARD" --target "$TARGET" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Total files to copy:  1"* ]]
    [[ "$output" == *"Total files skipped:  1"* ]]
    run "$SYNC" --source "$CARD" --target "$TARGET"
    [[ "$output" == *"Total files copied:   1"* ]]
    [[ "$output" == *"Total files skipped:  1"* ]]
}

@test "jpg with exif date is organized by capture date" {
    require_exiftool
    mkdir -p "$CARD/DCIM"
    make_jpg_with_date "$CARD/DCIM/photo.jpg" '2025:01:15 10:30:25'
    touch -t 202506010101 "$CARD/DCIM/photo.jpg"
    run "$SYNC" --source "$CARD" --target "$TARGET"
    [ "$status" -eq 0 ]
    [ -f "$TARGET/20250115/CARD_A/photo.jpg" ]
}

@test "imported file mtime is set to capture date" {
    require_exiftool
    mkdir -p "$CARD/DCIM"
    make_jpg_with_date "$CARD/DCIM/photo.jpg" '2025:01:15 10:30:25'
    touch -t 202506010101 "$CARD/DCIM/photo.jpg"
    run "$SYNC" --source "$CARD" --target "$TARGET"
    [ "$(file_mtime "$TARGET/20250115/CARD_A/photo.jpg")" = "202501151030.25" ]
}

@test "files from previous runs are not re-touched" {
    require_exiftool
    # A file imported earlier, with mtime deliberately different from its
    # capture date; a new import must not rewrite it
    prior="$TARGET/20240101/OLDCARD"
    mkdir -p "$prior"
    make_jpg_with_date "$prior/old.jpg" '2024:01:01 08:00:00'
    touch -t 202507070707 "$prior/old.jpg"

    mkdir -p "$CARD/DCIM"
    make_jpg_with_date "$CARD/DCIM/new.jpg" '2025:01:15 10:30:25'
    run "$SYNC" --source "$CARD" --target "$TARGET"
    [ "$status" -eq 0 ]
    [ "$(file_mtime "$prior/old.jpg")" = "202507070707.00" ]
}

@test "at most one exiftool invocation per imported file" {
    require_exiftool
    mkdir -p "$CARD/DCIM"
    make_jpg_with_date "$CARD/DCIM/one.jpg" '2025:01:15 10:30:25'
    make_jpg_with_date "$CARD/DCIM/two.jpg" '2025:01:16 11:00:00'
    count="$BATS_TEST_TMPDIR/count"
    make_exiftool_shim "$BATS_TEST_TMPDIR/shim" "$count"
    run env PATH="$BATS_TEST_TMPDIR/shim:$PATH" "$SYNC" --source "$CARD" --target "$TARGET"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$count")" -le 2 ]
}
