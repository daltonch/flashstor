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

**Purpose:** Cross-platform utility to import GoPro media (MP4/WAV) from one or more SD cards and organize by creation date.

**File Organization:**
- With config: `<target>/<YYYYMMDD>/<mapped_name>/files` (e.g., `Backup/20251008/chad/Hero12/`)
- Without config: `<target>/<YYYYMMDD>/<volume_name>/files` (e.g., `Backup/20251008/CDHero12/`)

Date folders at TOP level enable browsing by date across multiple SD cards. Implemented in `process_single_source()` at line 732.

**Metadata Extraction Cascade:**
1. `exiftool` (preferred) - Looks for CreateDate, MediaCreateDate, DateTimeOriginal
2. `ffprobe` (fallback) - Extracts creation_time from video stream metadata
3. File modification time (final fallback) - Uses `stat` command

This ensures the script works without external dependencies. Logic in `extract_date()` function (lines 443-480).

**UUID Mapping (Optional):**
- Config file format: `UUID=friendly/name` (one per line)
- Default config: `sdcard_config.txt` (if present in current directory)
- Cross-platform UUID detection: macOS uses `diskutil`, Linux uses `lsblk`/`blkid`
- Short UUID extraction for FAT32 compatibility (e.g., `E957-B26D`)
- Unknown card detection: Exits immediately with helpful error message showing UUID

**Duplicate File Handling:**
- Interactive prompt on first duplicate (skip/overwrite/rename/apply-to-all)
- State stored in global variables `DUPLICATE_ACTION` and `APPLY_TO_ALL`
- Managed by `handle_duplicate()` function (lines 488-558)

**Key Features:**
- Multi-source support: Can process multiple SD cards in one invocation
- Optional auto-eject: `--eject` flag unmounts cards after processing
- Progress display: Uses `pv` if available, falls back to size display
- Timestamp preservation: Uses `cp -p` to maintain original file timestamps
- Platform compatibility: Handles macOS vs Linux differences in `stat`, mount points
- Dual mode: Works with or without config file

**Command Line Options:**
```bash
--source <path>      # SD card mount point (can specify multiple times)
--target <path>      # Destination directory
--config <path>      # UUID mapping config (optional, defaults to sdcard_config.txt)
--eject              # Auto-eject cards after processing
--dry-run            # Preview without copying
--verbose            # Detailed output
```

**Usage Examples:**
```bash
# Basic usage with auto-detected config
./sync.sh --source /Volumes/GOPRO --target ~/Backup

# Multiple cards with auto-eject
./sync.sh --source /Volumes/GOPRO1 --source /Volumes/GOPRO2 --target ~/Backup --eject

# Without config (uses volume names)
./sync.sh --source /Volumes/GOPRO --target ~/Backup --config /dev/null

# Preview operations
./sync.sh --source /Volumes/GOPRO --target ~/Backup --dry-run --verbose
```

**Execution Flow:**
1. Argument parsing (`parse_args`)
2. Validation (`validate_args`)
3. Config loading if present (`load_config`)
4. UUID validation if config loaded (`validate_source_uuids`)
5. Dependency check (`check_dependencies`)
6. For each source path:
   - SD card name detection (`get_sdcard_name`)
   - File discovery (`find_media_files`)
   - Processing loop (`process_single_source`)
     - Extract date → Build target path → Copy file → Handle duplicates
   - Optional auto-eject
7. Summary statistics (`print_summary`)

## Important Implementation Details

### Date Format
YYYYMMDD format (e.g., 20251022) with NO separators:
- Sorts chronologically by string comparison
- Unambiguous across locales
- No special character handling needed

### Error Handling
Both scripts use `set -euo pipefail`:
- `e`: Exit on error
- `u`: Exit on undefined variable
- `pipefail`: Return exit code of failed command in pipeline

Operations that may fail gracefully (like file copies) are wrapped in conditionals.

### Bash Version Requirement
The script requires bash 4.0+ for associative array support. On macOS, the default bash is 3.2, so you need:
```bash
brew install bash
/usr/local/bin/bash sync.sh [arguments]
```

The script includes a version check that provides installation instructions if needed.

## Modifying sync.sh

### Change Directory Structure
The folder structure is set in ONE location (`process_single_source` function, line 732):
```bash
local target_dir="${TARGET_PATH}/${date}/${sdcard_name}"
```

Also update:
- Help text in `show_help()` function (line 50)
- This CLAUDE.md file

### Add File Types
Modify `find_media_files()` function (line 483):
```bash
find "$source" -type f \( -iname "*.mp4" -o -iname "*.wav" -o -iname "*.newtype" \) 2>/dev/null
```

### Add Metadata Tools
1. Add detection in `check_dependencies()` (line 198)
2. Add extraction logic in `extract_date()` (line 443) as new case statement
3. Update help text in `show_help()` (line 50)

### Add New SD Cards to Config
Edit `sdcard_config.txt` and add:
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
- `stat` syntax: macOS uses `-f`, Linux uses `-c`
- Unmount: macOS uses `diskutil unmount`, Linux uses `umount`

### Script Compatibility
**sync.sh**: Works on both macOS and Linux (cross-platform)