# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains utilities for a portable NAS system built around an Asustor Flashstor Pro 12. The system is designed for field media import operations, particularly for GoPro media files from multiple SD cards.

**Primary Script: sync.sh** - Cross-platform bash utility for importing and organizing GoPro media files by date. Supports both UUID-based card mapping and simple volume name fallback.

## Hardware Context

The target system is an Asustor Flashstor Pro 12 running Proxmox with:
- 12x 2TB NVMe drives (11 in ZFS-2 array, 1 for system)
- 32GB RAM
- Multiple LXC containers (Arch Linux with Samba, Ubuntu with Plex)
- Kingston Workflow Station hub supporting 8 simultaneous microSD cards

## Script Architecture

### sync.sh - GoPro Media Importer

**Purpose:** Cross-platform utility to import GoPro media (MP4/WAV/JPG) from one or more SD cards and organize by capture date.

**File Organization:**
- With config: `<target>/<YYYYMMDD>/<mapped_name>/files` (e.g., `Backup/20251008/chad/Hero12/`)
- Without config: `<target>/<YYYYMMDD>/<volume_name>/files` (e.g., `Backup/20251008/CDHero12/`)

Date folders at TOP level enable browsing by date across multiple SD cards. The path is built in `process_single_source()`.

**Capture Date Extraction:**
`extract_timestamp()` makes one metadata-tool call per file and returns the full capture timestamp in `touch -t` format (`YYYYMMDDhhmm.SS`), which drives both the date folder (first 8 characters) and the copied file's mtime:

1. `exiftool` (preferred) - CreateDate, MediaCreateDate, DateTimeOriginal
2. `ffprobe` (fallback) - creation_time from the video stream tags
3. No tool or no metadata - the file's mtime picks the date folder (via `stat_mtime_date`) and rsync's `--archive` preserves the original mtime on the copy

After a successful copy, `rsync_file()` sets the copy's mtime to the capture timestamp (when one was found). Only files copied by the current run are touched; existing archive content is never re-scanned.

**Config File Sections (Optional):**

1. **FORMATS:** Comma-separated file extensions to process (default: mp4,mov,wav,jpg)
2. **IGNORE_FOLDERS:** Comma-separated folder names to skip during scan (default: .Trashes). Values may contain spaces; only surrounding whitespace is trimmed.
3. **LABELS:** UUID to friendly name mappings for SD cards

The config is only read when `--config <path>` is passed explicitly.

**UUID Mapping (Optional):**
- Config file format: `UUID=friendly/name` (one per line, under a `LABELS:` header)
- Cross-platform UUID detection: macOS uses `diskutil`, Linux uses `lsblk`/`blkid`
- FAT32 cards report their 4-4 serial (e.g., `E957-B26D`) directly from the platform tools; config entries are matched verbatim against whatever UUID is detected
- Unknown card detection: exits immediately with the exact config line to add
- Config present but no LABELS entries: volume names are used, no UUID detection required

**Folder Exclusion:**
- Configurable via `IGNORE_FOLDERS` in config file
- Default: `.Trashes` (macOS system folder)
- Common additions: `.Spotlight-V100`, `.fseventsd`, `.TemporaryItems`
- Applied by `find_media_files()`, which builds a `find` argument array (never `eval`; config values are user-controlled and must not be shell-interpreted)

**Duplicate File Handling:**
Duplicates (same filename in the same destination folder) are automatically skipped, never overwritten. `rsync_file()` checks for the target file before copying, counts the skip, and records the filename for the summary. There is no interactive prompt.

**Key Features:**
- Multi-source support: multiple `--source` flags process cards in parallel (background subshells; stats and skip/error lists round-trip through per-source temp files)
- Optional auto-eject: `--eject` unmounts cards after processing
- Timestamp handling: rsync `--archive` preserves mtimes; metadata capture dates overwrite the copy's mtime when available
- Dual mode: works with or without a config file
- `--dry-run` reports would-copy/skip totals without writing anything

**Command Line Options:**
```bash
--source <path>      # SD card mount point (can specify multiple times)
--target <path>      # Destination directory
--config <path>      # Config file (optional; only used when passed)
--eject              # Auto-eject cards after processing
--dry-run            # Preview with would-copy totals, no writes
--verbose            # Detailed output
```

**Execution Flow:**
1. Argument parsing (`parse_args`)
2. Validation (`validate_args`)
3. Config loading if `--config` given (`load_config`), then UUID validation (`validate_source_uuids`)
4. Dependency check (`check_dependencies`)
5. For each source path (parallel when multiple):
   - SD card name detection (`get_sdcard_name`)
   - File discovery (`find_media_files`)
   - Processing loop (`process_single_source`): extract timestamp, build target path, copy (`rsync_file`), set capture-date mtime
   - Optional auto-eject
6. Summary statistics (`print_summary`)

## Testing

The bats-core suite lives in `test/` (`bats test/`):
- `test/unit.bats` sources sync.sh (main only runs when executed) and exercises individual functions
- `test/integration.bats` runs the script end-to-end against fixture SD cards generated in a temp dir
- `test/test_helper.bash` provides fixtures, including a metadata-capable 1x1 JPEG and an exiftool-counting PATH shim
- A test enforces that `shellcheck sync.sh` stays clean

Run the suite before and after any change to sync.sh. Write a failing test first for behavior changes.

## Important Implementation Details

### Date Format
YYYYMMDD format (e.g., 20251022) with NO separators:
- Sorts chronologically by string comparison
- Unambiguous across locales
- No special character handling needed

### Error Handling
`set -euo pipefail` is active:
- `e`: Exit on error
- `u`: Exit on undefined variable
- `pipefail`: Return exit code of failed command in pipeline

Operations that may fail gracefully (file copies, metadata reads) capture their status explicitly (`set +e` around the call, or `|| true` inside assignments). Avoid `local x=$(cmd)`; declare and assign separately so failures are not masked (shellcheck SC2155).

### stat Flavor
`stat` syntax is detected by capability (`stat --version` probe), not OS type: PATH may put GNU coreutils first even on macOS. Use the `stat_size_bytes` / `stat_mtime_date` helpers instead of calling `stat` directly.

### Bash Version Requirement
The script requires bash 4.0+ for associative array support. On macOS, the default bash is 3.2, so you need:
```bash
brew install bash
/opt/homebrew/bin/bash sync.sh [arguments]
```

The script includes a version check that provides installation instructions if needed.

## Modifying sync.sh

### Change Directory Structure
The folder structure is set in ONE location (`process_single_source`):
```bash
local target_dir="${TARGET_PATH}/${date}/${sdcard_name}"
```

Also update:
- Help text in `show_help()`
- This CLAUDE.md file
- The layout assertions in `test/integration.bats`

### Add File Types
Edit the config file's FORMATS line:
```
FORMATS=mp4,mov,wav,jpg,newtype
```

`find_media_files()` builds its find arguments from this configuration. No code changes needed.

### Add/Modify Ignored Folders
Edit the config file's IGNORE_FOLDERS line:
```
IGNORE_FOLDERS=.Trashes,.Spotlight-V100,.fseventsd,.TemporaryItems
```

No code changes needed.

### Add Metadata Tools
1. Add detection in `check_dependencies()`
2. Add a case in `extract_timestamp()` that yields `YYYYMMDDhhmm.SS`
3. Update help text in `show_help()` and add a unit test

### Add New SD Cards to Config
Edit `sdcard_config.txt` and add under `LABELS:`:
```
UUID=owner/cardname
```

Find UUID with:
- macOS: `diskutil info /Volumes/CARDNAME | grep UUID`
- Linux: `blkid` or `lsblk -n -o UUID /dev/sdX`

The script will show you the exact line to add if it encounters an unknown card.

## Platform Differences

### macOS vs Linux
- SD card detection: macOS uses `/Volumes/`, Linux uses `/media/` or `/mnt/`
- `stat` syntax: detected by capability, see above
- Unmount: macOS uses `diskutil unmount`, Linux uses `umount`

### Script Compatibility
**sync.sh**: Works on both macOS and Linux (cross-platform)
