#!/usr/bin/env bash

# SDCard Media Importer
# Copies MP4 and WAV files from SD card(s) and organizes them by date

# Check bash version (need 4.0+ for associative arrays)
if ((BASH_VERSINFO[0] < 4)); then
    echo "ERROR: This script requires bash 4.0 or higher" >&2
    echo "Current version: $BASH_VERSION" >&2
    echo "" >&2
    echo "On macOS, install modern bash with:" >&2
    echo "  brew install bash" >&2
    echo "Then run the script with:" >&2
    echo "  /usr/local/bin/bash $(basename "$0") [arguments]" >&2
    echo "  or" >&2
    echo "  /opt/homebrew/bin/bash $(basename "$0") [arguments]" >&2
    exit 3
fi

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
SOURCE_PATHS=()
TARGET_PATH=""
CONFIG_FILE=""
DRY_RUN=false
VERBOSE=false
AUTO_EJECT=false
START_TIME=0

# Associative array for UUID to name mapping
declare -A UUID_MAP

# Per-source statistics (associative arrays keyed by source path)
declare -A SOURCE_FILES_COPIED
declare -A SOURCE_BYTES_COPIED
declare -A SOURCE_FILES_SKIPPED
declare -A SOURCE_FILES_ERROR
declare -A SOURCE_TIME_ELAPSED

# Overall statistics
TOTAL_FILES_COPIED=0
TOTAL_BYTES_COPIED=0
TOTAL_FILES_SKIPPED=0
TOTAL_FILES_ERROR=0

# Lists for tracking
declare -a SKIPPED_FILES_LIST
declare -a ERROR_FILES_LIST

# File formats to process (configurable via config file)
declare -a FILE_FORMATS
# Default formats if not specified in config
FILE_FORMATS=(mp4 mov wav jpg)

# Duplicate file handling state
DUPLICATE_ACTION=""
APPLY_TO_ALL=false

# Show help message
show_help() {
    cat << EOF
SDCard Media Importer v1.0

DESCRIPTION:
    Copies files from one or more SD cards and organizes them by date taken.

    Folder structure:
    - With config: <target>/<YYYYMMDD>/<mapped_name>/files
    - Without config: <target>/<YYYYMMDD>/<volume_name>/files

    When a config file is provided, uses UUID-based SD card identification for consistent
    folder names across different mount points. Without a config file, uses the volume name.

    Preserves original file timestamps during copy.

USAGE:
    sync.sh --source <path> [--source <path2> ...] --target <path> [OPTIONS]
    sync.sh --help

REQUIRED ARGUMENTS:
    --source <path>     Path to SD card mount point (can be specified multiple times)
                        Example: /Volumes/CARD or /media/CARD
                        Use multiple times: --source /Volumes/GOPRO1 --source /Volumes/GOPRO2
                        NOTE: When using config file, all volumes must be defined in the config

    --target <path>     Destination directory for organized files
                        Example: ~/GoPro_Backup or /backup/gopro

OPTIONS:
    --config <path>     Path to UUID mapping config file (optional)
                        Config is only used if explicitly specified with this flag
                        Without --config, volume names will be used
                        Example: ./sdcard_config.txt
                        Format: Each line contains UUID=friendly/name
                        Lines starting with # are comments

    --eject             Automatically eject/unmount SD cards after successful processing
                        Without this flag, SD cards will remain mounted

    --dry-run           Preview operations without actually copying files
                        Shows what would be copied and where

    --verbose           Display detailed progress information during copy

    --help              Display this help message and exit

CONFIG FILE FORMAT:
    The config file has two optional sections:

    1. FORMATS (optional) - Comma-separated list of file extensions to process
       Default: mp4,mov,wav,jpg
       Example: FORMATS=mp4,mov,lrv,wav,jpg

    2. LABELS (optional) - SD Card UUID to Name Mapping
       Format: UUID=owner/cardname
       If not specified, SD card volume names will be used for organization
       Lines starting with # are comments

    Example config file:
        # File formats to process (comma-separated, without dot)
        FORMATS=mp4,mov,lrv,wav,jpg,png

        # SD Card Labels (optional - omit to use volume names)
        LABELS:
        E957-B26D=chad/Hero12
        9696-0289=chad/Front-Hero13
        B139-BCC7=chad/Helmet-Hero11mini

    To find a UUID:
    - macOS: diskutil info /Volumes/CARDNAME | grep UUID
    - Linux: blkid or lsblk -n -o UUID /dev/sdX

EXAMPLES:
    # Basic usage without config (uses volume names)
    sync.sh --source /Volumes/GOPRO --target ~/Backup

    # Using config file for UUID mapping
    sync.sh --config sdcard_config.txt --source /Volumes/GOPRO --target ~/Backup

    # Import from multiple SD cards with config file
    sync.sh --config sdcard_config.txt --source /Volumes/GOPRO1 --source /Volumes/GOPRO2 --target ~/Backup

    # Preview operations without copying
    sync.sh --source /Volumes/GOPRO --target ~/Backup --dry-run

    # Verbose output with multiple sources
    sync.sh --source /Volumes/GOPRO1 --source /Volumes/GOPRO2 --target ~/Backup --verbose

    # Auto-eject SD cards after importing with config
    sync.sh --config sdcard_config.txt --source /Volumes/GOPRO --target ~/Backup --eject

UNKNOWN SD CARDS (when using config file):
    If a source path contains an SD card that is not in the config file, the script will:
    - Exit immediately before processing any files
    - Display the unknown UUID
    - Provide the exact line to add to your config file

    Without a config file, all SD cards will be processed using their volume names.

DEPENDENCIES:
    The script will attempt to use the following tools:

    UUID detection (required):
    - macOS: diskutil (built-in)
    - Linux: lsblk or blkid (usually available)

    File copying (required):
    - rsync (usually available on all systems)

    Metadata extraction and date fixing:
    - exiftool (preferred) - Extracts video metadata and sets file modification times
    - ffprobe (fallback) - Extracts video metadata only
    - file modification time (final fallback)

DUPLICATE HANDLING:
    Duplicate files (files with the same name) are automatically skipped.
    The script uses rsync with --ignore-existing to skip files that already exist
    in the destination. Skipped files are logged and shown in the summary.

PARALLEL PROCESSING:
    When multiple SD cards are specified with --source, they will be processed
    in parallel for faster imports. Each SD card is processed independently and
    statistics are tracked per-source and overall.

EXIT CODES:
    0  - Success
    1  - General error
    2  - Invalid arguments
    3  - Missing dependencies
    4  - Source/target/config path issues or unknown SD card UUID

EOF
}

# Print error message
error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
}

# Print warning message
warning() {
    echo -e "${YELLOW}WARNING:${NC} $1"
}

# Print success message
success() {
    echo -e "${GREEN}$1${NC}"
}

# Print info message
info() {
    echo -e "${BLUE}$1${NC}"
}

# Print verbose message
verbose() {
    if [ "$VERBOSE" = true ]; then
        echo "$1"
    fi
}

# Check for required dependencies
check_dependencies() {
    if command -v exiftool &> /dev/null; then
        echo "exiftool"
        return 0
    elif command -v ffprobe &> /dev/null; then
        echo "ffprobe"
        return 0
    else
        echo "none"
        return 0
    fi
}

# Display metadata extraction method
display_metadata_method() {
    local tool="$1"
    case "$tool" in
        exiftool)
            info "Metadata extraction: exiftool (preferred)"
            ;;
        ffprobe)
            warning "Metadata extraction: ffprobe (fallback) exiftool would be preferred"
            ;;
        none)
            warning "Metadata extraction: file modification times (exiftool/ffprobe not found)"
            ;;
    esac
}

# Load UUID mapping from config file
load_config() {
    local config_file="$1"

    if [ ! -f "$config_file" ]; then
        error "Config file not found: $config_file"
        exit 4
    fi

    if [ ! -r "$config_file" ]; then
        error "Config file is not readable: $config_file"
        exit 4
    fi

    verbose "Loading config from: $config_file"

    local in_labels_section=false
    local found_labels_header=false

    # Read config file line by line
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Check for FORMATS= line
        if [[ "$line" =~ ^FORMATS=(.+)$ ]]; then
            local formats_value="${BASH_REMATCH[1]}"
            # Parse comma-separated formats
            IFS=',' read -ra FILE_FORMATS <<< "$formats_value"
            # Trim whitespace from each format
            for i in "${!FILE_FORMATS[@]}"; do
                FILE_FORMATS[$i]=$(echo "${FILE_FORMATS[$i]}" | tr -d ' ')
            done
            verbose "Loaded formats: ${FILE_FORMATS[*]}"
            continue
        fi

        # Check for LABELS: section header
        if [[ "$line" =~ ^LABELS:$ ]]; then
            found_labels_header=true
            in_labels_section=true
            verbose "Found LABELS section"
            continue
        fi

        # Parse UUID=name format (only if in LABELS section or if we haven't found header yet for backward compat check)
        if [[ "$line" =~ ^([^=]+)=(.+)$ ]]; then
            if [ "$found_labels_header" = false ]; then
                error "Config file must have 'LABELS:' section header before UUID mappings"
                error "Add 'LABELS:' line before your UUID entries"
                exit 4
            fi
            local uuid="${BASH_REMATCH[1]}"
            local name="${BASH_REMATCH[2]}"
            UUID_MAP["$uuid"]="$name"
            verbose "Loaded mapping: $uuid -> $name"
        fi
    done < "$config_file"

    # LABELS section is now optional - if not found or empty, will use volume names
    # Check if UUID_MAP has any entries (safe with set -u)
    local uuid_count=0
    if [ -n "${UUID_MAP[*]+x}" ]; then
        uuid_count=${#UUID_MAP[@]}
    fi

    if [ "$found_labels_header" = true ] && [ "$uuid_count" -eq 0 ]; then
        warning "LABELS section found but no UUID mappings defined - will use volume names"
    elif [ "$found_labels_header" = false ]; then
        info "No LABELS section in config - will use volume names"
    fi

    # Show what formats we're using
    if [ ${#FILE_FORMATS[@]} -eq 0 ]; then
        # Should not happen due to defaults, but just in case
        FILE_FORMATS=(mp4 mov wav jpg)
    fi
    info "File formats: ${FILE_FORMATS[*]}"

    if [ "$uuid_count" -gt 0 ]; then
        info "Loaded $uuid_count SD card mapping(s)"
    fi
}

# Extract short UUID from full UUID (for FAT32 compatibility)
# FAT32 UUIDs are 4-4 format (e.g., 0119-B4DD)
# Full UUIDs are 8-4-4-4-12 format
get_short_uuid() {
    local full_uuid="$1"

    # If already in short format (contains only one hyphen), return as-is
    if [[ "$full_uuid" =~ ^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$ ]]; then
        echo "$full_uuid"
        return 0
    fi

    # If in full format, extract last 4-4 bytes
    # Example: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX -> last 4 digits before and after last hyphen
    if [[ "$full_uuid" =~ -([0-9A-Fa-f]{4})([0-9A-Fa-f]{8})$ ]]; then
        echo "${BASH_REMATCH[1]}-${BASH_REMATCH[2]:0:4}" | tr '[:lower:]' '[:upper:]'
        return 0
    fi

    # Return original if no pattern matches
    echo "$full_uuid"
}

# Get UUID of a mounted volume (cross-platform)
get_volume_uuid() {
    local mount_path="$1"
    local uuid=""

    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS - use diskutil
        uuid=$(diskutil info "$mount_path" 2>/dev/null | grep "Volume UUID:" | awk '{print $3}')
        # If Volume UUID is not available, try Disk / Partition UUID
        if [ -z "$uuid" ]; then
            uuid=$(diskutil info "$mount_path" 2>/dev/null | grep "Disk / Partition UUID:" | awk '{print $5}')
        fi
        # If still empty, try getting the device UUID (for FAT32 volumes)
        if [ -z "$uuid" ]; then
            local device=$(diskutil info "$mount_path" 2>/dev/null | grep "Device Node:" | awk '{print $3}')
            if [ -n "$device" ]; then
                uuid=$(diskutil info "$device" 2>/dev/null | grep "Volume UUID:" | awk '{print $3}')
            fi
        fi
    else
        # Linux - use lsblk or blkid
        local device=$(df "$mount_path" 2>/dev/null | tail -1 | awk '{print $1}')
        if [ -n "$device" ]; then
            if command -v lsblk &> /dev/null; then
                uuid=$(lsblk -n -o UUID "$device" 2>/dev/null)
            elif command -v blkid &> /dev/null; then
                uuid=$(blkid -s UUID -o value "$device" 2>/dev/null)
            fi
        fi
    fi

    echo "$uuid"
}

# Validate all source paths have UUIDs in config
validate_source_uuids() {
    # If no UUID mappings defined, skip validation and use volume names
    local uuid_count=0
    if [ -n "${UUID_MAP[*]+x}" ]; then
        uuid_count=${#UUID_MAP[@]}
    fi

    if [ "$uuid_count" -eq 0 ]; then
        info "No UUID mappings defined - will use volume names for organization"
        echo ""
        return 0
    fi

    info "Validating SD card UUIDs..."
    echo ""

    for source_path in "${SOURCE_PATHS[@]}"; do
        local uuid=$(get_volume_uuid "$source_path")

        if [ -z "$uuid" ]; then
            error "Could not determine UUID for: $source_path"
            error "This may not be a mounted volume or the system lacks permission to read it"
            exit 4
        fi

        local short_uuid=$(get_short_uuid "$uuid")

        # Show both UUIDs if they differ
        if [ "$uuid" != "$short_uuid" ]; then
            verbose "Detected UUID for $source_path: $uuid (short: $short_uuid)"
        else
            verbose "Detected UUID for $source_path: $uuid"
        fi

        # Try to match with short UUID first, then full UUID
        local mapped_name=""
        if [[ -v "UUID_MAP[$short_uuid]" ]]; then
            mapped_name="${UUID_MAP[$short_uuid]}"
        elif [[ -v "UUID_MAP[$uuid]" ]]; then
            mapped_name="${UUID_MAP[$uuid]}"
        fi

        # Check if UUID exists in mapping
        if [ -z "$mapped_name" ]; then
            echo ""
            error "Unknown SD card detected at: $source_path"
            error "Full UUID: $uuid"
            if [ "$uuid" != "$short_uuid" ]; then
                error "Short UUID: $short_uuid"
            fi
            echo ""
            echo "Add this line to your config file ($CONFIG_FILE):"
            echo "  $short_uuid=owner/cardname"
            echo ""
            exit 4
        fi

        # Display which UUID was used for matching
        if [[ -v "UUID_MAP[$short_uuid]" ]]; then
            success "Found mapping: $short_uuid -> $mapped_name"
        else
            success "Found mapping: $uuid -> $mapped_name"
        fi
    done

    echo ""
}

# Get SD card name from path using UUID mapping or volume name
get_sdcard_name() {
    local source_path="$1"

    # If no config file is loaded, use volume name (old behavior)
    if [ -z "$CONFIG_FILE" ]; then
        local sdcard_name=""

        # Try to get volume name on macOS
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sdcard_name=$(basename "$source_path")
        else
            # On Linux, try to get the volume label
            if command -v lsblk &> /dev/null; then
                local device
                device=$(df "$source_path" | tail -1 | awk '{print $1}')
                sdcard_name=$(lsblk -no LABEL "$device" 2>/dev/null || basename "$source_path")
            else
                sdcard_name=$(basename "$source_path")
            fi
        fi

        # Fallback to basename if empty
        if [ -z "$sdcard_name" ]; then
            sdcard_name=$(basename "$source_path")
        fi

        # Sanitize name (remove special characters)
        sdcard_name=$(echo "$sdcard_name" | tr -cd '[:alnum:]_-')

        echo "$sdcard_name"
        return 0
    fi

    # Config file is loaded - use UUID mapping if available
    local uuid
    uuid=$(get_volume_uuid "$source_path")

    if [ -z "$uuid" ]; then
        error "Could not determine UUID for: $source_path"
        exit 4
    fi

    local short_uuid
    short_uuid=$(get_short_uuid "$uuid")

    # Try to match with short UUID first, then full UUID
    local mapped_name=""
    if [[ -v "UUID_MAP[$short_uuid]" ]]; then
        mapped_name="${UUID_MAP[$short_uuid]}"
    elif [[ -v "UUID_MAP[$uuid]" ]]; then
        mapped_name="${UUID_MAP[$uuid]}"
    fi

    # If no mapping found and UUID_MAP is empty, fall back to volume name
    if [ -z "$mapped_name" ]; then
        local uuid_count=0
        if [ -n "${UUID_MAP[*]+x}" ]; then
            uuid_count=${#UUID_MAP[@]}
        fi

        if [ "$uuid_count" -eq 0 ]; then
            # No UUID mappings configured - use volume name
            local sdcard_name=""

            # Try to get volume name on macOS
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sdcard_name=$(basename "$source_path")
            else
                # On Linux, try to get the volume label
                if command -v lsblk &> /dev/null; then
                    local device
                    device=$(df "$source_path" | tail -1 | awk '{print $1}')
                    sdcard_name=$(lsblk -no LABEL "$device" 2>/dev/null || basename "$source_path")
                else
                    sdcard_name=$(basename "$source_path")
                fi
            fi

            # Fallback to basename if empty
            if [ -z "$sdcard_name" ]; then
                sdcard_name=$(basename "$source_path")
            fi

            # Sanitize name (remove special characters)
            sdcard_name=$(echo "$sdcard_name" | tr -cd '[:alnum:]_-')

            echo "$sdcard_name"
            return 0
        else
            # UUID mappings exist but this UUID is not found
            error "No mapping found for UUID: $uuid (short: $short_uuid)"
            exit 4
        fi
    fi

    echo "$mapped_name"
}

# Extract date from file using metadata
extract_date() {
    local file="$1"
    local tool="$2"
    local date_str=""

    case "$tool" in
        exiftool)
            # Try to get CreateDate or MediaCreateDate from exiftool
            date_str=$(exiftool -CreateDate -MediaCreateDate -DateTimeOriginal -d "%Y%m%d" "$file" 2>/dev/null | grep -E "Create Date|Media Create Date|Date/Time Original" | head -1 | awk -F': ' '{print $2}')
            ;;
        ffprobe)
            # Try to get creation_time from ffprobe
            date_str=$(ffprobe -v quiet -select_streams v:0 -show_entries stream_tags=creation_time -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | cut -d'T' -f1 | tr -d '-')
            ;;
        none)
            # Use file modification time
            if [[ "$OSTYPE" == "darwin"* ]]; then
                date_str=$(stat -f "%Sm" -t "%Y%m%d" "$file")
            else
                date_str=$(stat -c "%y" "$file" | cut -d' ' -f1 | tr -d '-')
            fi
            ;;
    esac

    # Validate date format (YYYYMMDD)
    if [[ "$date_str" =~ ^[0-9]{8}$ ]]; then
        echo "$date_str"
    else
        # Fallback to file modification time
        if [[ "$OSTYPE" == "darwin"* ]]; then
            date_str=$(stat -f "%Sm" -t "%Y%m%d" "$file")
        else
            date_str=$(stat -c "%y" "$file" | cut -d' ' -f1 | tr -d '-')
        fi
        echo "$date_str"
    fi
}

# Find all media files
find_media_files() {
    local source="$1"

    # Build find command dynamically based on FILE_FORMATS array
    local find_cmd="find \"$source\" -type f \\("
    local first=true

    for format in "${FILE_FORMATS[@]}"; do
        if [ "$first" = true ]; then
            find_cmd+=" -iname \"*.${format}\""
            first=false
        else
            find_cmd+=" -o -iname \"*.${format}\""
        fi
    done

    find_cmd+=" \\) 2>/dev/null"

    # Execute the dynamically built command
    eval "$find_cmd"
}

# Get human-readable file size
get_file_size() {
    local file="$1"
    local size_bytes

    if [[ "$OSTYPE" == "darwin"* ]]; then
        size_bytes=$(stat -f "%z" "$file" 2>/dev/null)
    else
        size_bytes=$(stat -c "%s" "$file" 2>/dev/null)
    fi

    # Check if we got a valid size
    if [ -z "$size_bytes" ] || ! [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
        echo "unknown"
        return 1
    fi

    # Convert to human-readable format
    if [ "$size_bytes" -ge 1073741824 ]; then
        printf "%.1fGB" "$(echo "$size_bytes" | awk '{printf "%.1f", $1/1073741824}')"
    elif [ "$size_bytes" -ge 1048576 ]; then
        printf "%.1fMB" "$(echo "$size_bytes" | awk '{printf "%.1f", $1/1048576}')"
    elif [ "$size_bytes" -ge 1024 ]; then
        printf "%.1fKB" "$(echo "$size_bytes" | awk '{printf "%.1f", $1/1024}')"
    else
        echo "${size_bytes}B"
    fi
}

# Copy file using rsync with progress
rsync_file() {
    local source_file="$1"
    local target_dir="$2"
    local source_path="$3"  # For tracking stats
    local filename
    local target_file
    local file_size
    local bytes_copied=0

    filename=$(basename "$source_file")
    target_file="${target_dir}/${filename}"

    # Create target directory if it doesn't exist
    if [ "$DRY_RUN" = false ]; then
        mkdir -p "$target_dir"
    fi

    # Get file size for statistics
    file_size=$(get_file_size "$source_file")

    if [[ "$OSTYPE" == "darwin"* ]]; then
        bytes_copied=$(stat -f "%z" "$source_file" 2>/dev/null)
    else
        bytes_copied=$(stat -c "%s" "$source_file" 2>/dev/null)
    fi

    # Copy the file
    if [ "$DRY_RUN" = true ]; then
        echo " [DRY RUN] Would rsync"
        return 0
    fi

    # Use rsync with progress
    # --archive: preserve permissions, times, etc.
    # --progress: show progress bar
    # --info=progress2: show overall progress percentage
    # --ignore-existing: skip files that exist in destination (natural duplicate handling)

    # Check if file already exists (for skipped detection)
    if [ -f "$target_file" ]; then
        verbose "Skipped (exists): $filename"
        SOURCE_FILES_SKIPPED["$source_path"]=$((${SOURCE_FILES_SKIPPED["$source_path"]:-0} + 1))
        SKIPPED_FILES_LIST+=("$filename")
        return 2  # Return 2 to indicate skipped
    fi

    # File doesn't exist, copy it
    # Show progress bar only if verbose mode is enabled
    local rsync_opts="--archive"
    if [ "$VERBOSE" = true ]; then
        rsync_opts="$rsync_opts --progress --human-readable"
    fi

    if rsync $rsync_opts "$source_file" "$target_dir/" >/dev/null; then
        verbose "Copied: $filename -> $target_dir"
        SOURCE_FILES_COPIED["$source_path"]=$((${SOURCE_FILES_COPIED["$source_path"]:-0} + 1))
        SOURCE_BYTES_COPIED["$source_path"]=$((${SOURCE_BYTES_COPIED["$source_path"]:-0} + bytes_copied))
        return 0
    else
        error "Failed to copy: $filename"
        SOURCE_FILES_ERROR["$source_path"]=$((${SOURCE_FILES_ERROR["$source_path"]:-0} + 1))
        ERROR_FILES_LIST+=("$filename")
        return 1
    fi
}

# Fix file dates using exiftool to match video capture date
fix_file_dates() {
    local target_dir="$1"
    local tool="$2"

    if [ "$tool" != "exiftool" ]; then
        verbose "Skipping date fix - exiftool not available"
        return 0
    fi

    verbose "Fixing file dates to match video capture dates..."

    # Find all media files in target directory using configured formats
    local files_to_fix
    local find_cmd="find \"$target_dir\" -type f \\("
    local first=true

    for format in "${FILE_FORMATS[@]}"; do
        if [ "$first" = true ]; then
            find_cmd+=" -iname \"*.${format}\""
            first=false
        else
            find_cmd+=" -o -iname \"*.${format}\""
        fi
    done

    find_cmd+=" \\) 2>/dev/null"
    files_to_fix=$(eval "$find_cmd")

    if [ -z "$files_to_fix" ]; then
        return 0
    fi

    local fixed_count=0
    while IFS= read -r file; do
        if [ -f "$file" ]; then
            # Extract creation date from video metadata
            # Temporarily disable errexit for exiftool operations
            set +e
            local create_date
            create_date=$(exiftool -CreateDate -MediaCreateDate -DateTimeOriginal -d "%Y%m%d%H%M.%S" "$file" 2>/dev/null | grep -E "Create Date|Media Create Date|Date/Time Original" | head -1 | awk -F': ' '{print $2}' | tr -d ':' | sed 's/^\([0-9]\{8\}\) \([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1\2\3.\4/')
            set -e

            if [ -n "$create_date" ] && [[ "$create_date" =~ ^[0-9]{12}\.[0-9]{2}$ ]]; then
                # Set file modification time to match video capture date
                if touch -t "$create_date" "$file" 2>/dev/null; then
                    fixed_count=$((fixed_count + 1))
                    verbose "  Fixed date for: $(basename "$file")"
                fi
            fi
        fi
    done <<< "$files_to_fix"

    if [ $fixed_count -gt 0 ]; then
        info "Fixed dates for $fixed_count file(s)"
    fi
}

# Process files from a single source
process_single_source() {
    local source_path="$1"
    local tool="$2"
    local sdcard_name=$(get_sdcard_name "$source_path")

    # Initialize per-source statistics
    SOURCE_FILES_COPIED["$source_path"]=0
    SOURCE_BYTES_COPIED["$source_path"]=0
    SOURCE_FILES_SKIPPED["$source_path"]=0
    SOURCE_FILES_ERROR["$source_path"]=0

    # Track start time
    local start_time=$(date +%s)

    verbose "Scanning for media files in $source_path..."

    # Use mapfile/readarray if available (bash 4+), otherwise use while loop with temp array
    local files=()
    if command -v mapfile &> /dev/null; then
        mapfile -t files < <(find_media_files "$source_path")
    else
        while IFS= read -r file; do
            files+=("$file")
        done < <(find_media_files "$source_path")
    fi

    local total_files=${#files[@]}

    if [ "$total_files" -eq 0 ]; then
        warning "$sdcard_name: No media files found"
        # Track end time even if no files
        local end_time=$(date +%s)
        SOURCE_TIME_ELAPSED["$source_path"]=$((end_time - start_time))
        return 0
    fi

    # Combine SD card name and file count on one line
    info "$sdcard_name: Found $total_files media file(s)"
    echo ""

    local current=0
    local file
    for file in "${files[@]}"; do
        current=$((current + 1))

        verbose "Extracting date for file: $file"
        local date
        date=$(extract_date "$file" "$tool")
        verbose "Extracted date: $date"

        local target_dir="${TARGET_PATH}/${date}/${sdcard_name}"
        verbose "Target directory: $target_dir"

        echo -n "[$current/$total_files] Processing: $(basename "$file")"

        # Use rsync_file instead of copy_file
        # Disable errexit temporarily to capture return code
        local result
        set +e
        rsync_file "$file" "$target_dir" "$source_path"
        result=$?
        set -e

        case $result in
            0)
                # File copied successfully
                echo " - copied"
                ;;
            2)
                # File skipped (already exists)
                echo " - skipped (exists)"
                ;;
            1)
                # Error occurred
                echo " - failed"
                ERROR_FILES_LIST+=("$(basename "$file")")
                ;;
        esac
    done

    echo ""

    # Fix file dates using exiftool after all files are copied
    if [ "$DRY_RUN" = false ] && [ "$tool" = "exiftool" ]; then
        fix_file_dates "${TARGET_PATH}" "$tool"
    fi

    # Track end time
    local end_time=$(date +%s)
    SOURCE_TIME_ELAPSED["$source_path"]=$((end_time - start_time))

    # Unmount the SD card after processing if --eject flag is set
    if [ "$DRY_RUN" = false ] && [ "$AUTO_EJECT" = true ]; then
        echo ""
        info "Ejecting $sdcard_name..."

        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS - use diskutil
            if diskutil unmount "$source_path" >/dev/null 2>&1; then
                success "Successfully ejected $sdcard_name"
            else
                warning "Failed to eject $sdcard_name - you may need to eject manually"
            fi
        else
            # Linux - use umount
            if umount "$source_path" >/dev/null 2>&1; then
                success "Successfully ejected $sdcard_name"
            else
                warning "Failed to eject $sdcard_name - you may need to eject manually"
            fi
        fi
    fi

    return 0
}

# Process multiple sources in parallel
process_sources_parallel() {
    local tool="$1"
    shift
    local sources=("$@")

    # Create temporary directory for inter-process communication
    local temp_dir=$(mktemp -d)

    # Array to store background job PIDs and their corresponding source paths
    local -a pids=()
    declare -A pid_to_source

    # Launch each source processing in background
    for source_path in "${sources[@]}"; do
        (
            # Each background process runs process_single_source
            process_single_source "$source_path" "$tool"
            exit_code=$?

            # Write statistics to temp file for parent to read
            local stat_file="${temp_dir}/$(basename "$source_path").stats"
            cat > "$stat_file" << EOF
FILES_COPIED=${SOURCE_FILES_COPIED["$source_path"]:-0}
BYTES_COPIED=${SOURCE_BYTES_COPIED["$source_path"]:-0}
FILES_SKIPPED=${SOURCE_FILES_SKIPPED["$source_path"]:-0}
FILES_ERROR=${SOURCE_FILES_ERROR["$source_path"]:-0}
TIME_ELAPSED=${SOURCE_TIME_ELAPSED["$source_path"]:-0}
EOF

            # Report completion
            sdcard_name=$(get_sdcard_name "$source_path")
            if [ $exit_code -eq 0 ]; then
                echo ""
                echo -e "${GREEN}✓ Completed: $sdcard_name${NC}"
            else
                echo ""
                echo -e "${RED}✗ Failed: $sdcard_name${NC}"
            fi

            exit $exit_code
        ) &
        local pid=$!
        pids+=($pid)
        pid_to_source[$pid]="$source_path"
    done

    # Wait for all background jobs to complete
    local overall_status=0
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            overall_status=1
        fi
    done

    # Read statistics from temp files and aggregate
    for source_path in "${sources[@]}"; do
        local stat_file="${temp_dir}/$(basename "$source_path").stats"
        if [ -f "$stat_file" ]; then
            # Source the stats file to get variables
            local FILES_COPIED=0 BYTES_COPIED=0 FILES_SKIPPED=0 FILES_ERROR=0 TIME_ELAPSED=0
            source "$stat_file"

            # Store in parent's associative arrays
            SOURCE_FILES_COPIED["$source_path"]=$FILES_COPIED
            SOURCE_BYTES_COPIED["$source_path"]=$BYTES_COPIED
            SOURCE_FILES_SKIPPED["$source_path"]=$FILES_SKIPPED
            SOURCE_FILES_ERROR["$source_path"]=$FILES_ERROR
            SOURCE_TIME_ELAPSED["$source_path"]=$TIME_ELAPSED

            # Aggregate to overall statistics
            TOTAL_FILES_COPIED=$((TOTAL_FILES_COPIED + FILES_COPIED))
            TOTAL_BYTES_COPIED=$((TOTAL_BYTES_COPIED + BYTES_COPIED))
            TOTAL_FILES_SKIPPED=$((TOTAL_FILES_SKIPPED + FILES_SKIPPED))
            TOTAL_FILES_ERROR=$((TOTAL_FILES_ERROR + FILES_ERROR))
        fi
    done

    # Clean up temp directory
    rm -rf "$temp_dir"

    return $overall_status
}

# Main processing function
process_files() {
    local tool=$(check_dependencies)

    echo ""
    info "Target Directory: $TARGET_PATH"
    info "Number of source paths: ${#SOURCE_PATHS[@]}"
    display_metadata_method "$tool"

    if [ "$DRY_RUN" = true ]; then
        warning "DRY RUN MODE - No files will be copied"
    fi

    echo ""

    # Process sources in parallel if multiple sources, otherwise sequential
    if [ ${#SOURCE_PATHS[@]} -gt 1 ]; then
        info "Processing ${#SOURCE_PATHS[@]} SD cards in parallel..."
        echo ""
        process_sources_parallel "$tool" "${SOURCE_PATHS[@]}"
    else
        # Single source - process directly
        local source_path="${SOURCE_PATHS[0]}"
        process_single_source "$source_path" "$tool"

        # Aggregate statistics for single source
        TOTAL_FILES_COPIED=${SOURCE_FILES_COPIED["$source_path"]:-0}
        TOTAL_BYTES_COPIED=${SOURCE_BYTES_COPIED["$source_path"]:-0}
        TOTAL_FILES_SKIPPED=${SOURCE_FILES_SKIPPED["$source_path"]:-0}
        TOTAL_FILES_ERROR=${SOURCE_FILES_ERROR["$source_path"]:-0}
    fi

    return 0
}

# Format elapsed time
format_time() {
    local total_seconds=$1
    local hours=$((total_seconds / 3600))
    local minutes=$(((total_seconds % 3600) / 60))
    local seconds=$((total_seconds % 60))

    if [ $hours -gt 0 ]; then
        printf "%dh %dm %ds" $hours $minutes $seconds
    elif [ $minutes -gt 0 ]; then
        printf "%dm %ds" $minutes $seconds
    else
        printf "%ds" $seconds
    fi
}

# Format bytes to human-readable format
format_bytes() {
    local bytes=$1
    local -a units=("B" "KB" "MB" "GB" "TB")
    local unit=0
    local size=$bytes

    while [ $size -ge 1024 ] && [ $unit -lt 4 ]; do
        size=$((size / 1024))
        unit=$((unit + 1))
    done

    printf "%d %s" $size "${units[$unit]}"
}

# Print summary
print_summary() {
    local end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))
    local formatted_time=$(format_time $elapsed)

    echo ""
    echo "========================================"
    echo "Summary"
    echo "========================================"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        success "Dry run completed"
        info "Total time: $formatted_time"
        echo "========================================"
        return
    fi

    # Per-source statistics (always show, even for single source)
    if [ ${#SOURCE_PATHS[@]} -gt 1 ]; then
        echo "Per-Source Statistics:"
    else
        echo "SD Card Statistics:"
    fi
    echo "----------------------------------------"
    for source_path in "${SOURCE_PATHS[@]}"; do
        local sdcard_name=$(get_sdcard_name "$source_path")
        local files_copied=${SOURCE_FILES_COPIED["$source_path"]:-0}
        local bytes_copied=${SOURCE_BYTES_COPIED["$source_path"]:-0}
        local files_skipped=${SOURCE_FILES_SKIPPED["$source_path"]:-0}
        local files_error=${SOURCE_FILES_ERROR["$source_path"]:-0}
        local time_elapsed=${SOURCE_TIME_ELAPSED["$source_path"]:-0}
        local formatted_bytes=$(format_bytes $bytes_copied)
        local formatted_time_src=$(format_time $time_elapsed)

        echo ""
        info "SD Card: $sdcard_name"
        echo "  Files copied:   $files_copied"
        echo "  Size copied:    $formatted_bytes"
        if [ $files_skipped -gt 0 ]; then
            echo "  Files skipped:  $files_skipped"
        fi
        if [ $files_error -gt 0 ]; then
            echo "  Files error:    $files_error"
        fi
        echo "  Time taken:     $formatted_time_src"
    done
    echo ""
    echo "----------------------------------------"

    # Overall statistics
    echo ""
    echo "Overall Statistics:"
    echo "----------------------------------------"
    success "Total files copied:   $TOTAL_FILES_COPIED"
    local formatted_total_bytes=$(format_bytes $TOTAL_BYTES_COPIED)
    success "Total size copied:    $formatted_total_bytes"

    if [ $TOTAL_FILES_SKIPPED -gt 0 ]; then
        warning "Total files skipped:  $TOTAL_FILES_SKIPPED"
    fi

    if [ $TOTAL_FILES_ERROR -gt 0 ]; then
        error "Total files error:    $TOTAL_FILES_ERROR"
    fi

    info "Total time:           $formatted_time"
    echo ""

    # Show list of skipped files if any (use set +u to avoid unbound variable errors)
    set +u
    if [ ${#SKIPPED_FILES_LIST[@]} -gt 0 ]; then
        echo "Skipped files (already exist):"
        for file in "${SKIPPED_FILES_LIST[@]}"; do
            echo "  - $file"
        done
        echo ""
    fi

    # Show list of error files if any (use set +u to avoid unbound variable errors)
    if [ ${#ERROR_FILES_LIST[@]} -gt 0 ]; then
        echo "Files with errors:"
        for file in "${ERROR_FILES_LIST[@]}"; do
            echo "  - $file"
        done
        echo ""
    fi
    set -u

    echo "========================================"
}

# Validate arguments
validate_args() {
    if [ ${#SOURCE_PATHS[@]} -eq 0 ] || [ -z "$TARGET_PATH" ]; then
        error "Required arguments: --source and --target"
        echo ""
        show_help
        exit 2
    fi

    # Config file only used if explicitly specified
    if [ -z "$CONFIG_FILE" ]; then
        # No config file - will use volume names instead
        verbose "No config file specified - will use volume names"
    fi

    # Validate each source path
    for source_path in "${SOURCE_PATHS[@]}"; do
        if [ ! -d "$source_path" ]; then
            error "Source path does not exist or is not a directory: $source_path"
            exit 4
        fi

        if [ ! -r "$source_path" ]; then
            error "Source path is not readable: $source_path"
            exit 4
        fi
    done

    # Validate target path
    if [ ! -d "$TARGET_PATH" ]; then
        if [ "$DRY_RUN" = false ]; then
            mkdir -p "$TARGET_PATH" 2>/dev/null || {
                error "Cannot create target directory: $TARGET_PATH"
                exit 4
            }
        fi
    fi

    if [ "$DRY_RUN" = false ] && [ ! -w "$TARGET_PATH" ]; then
        error "Target path is not writable: $TARGET_PATH"
        exit 4
    fi
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --source)
                SOURCE_PATHS+=("$2")
                shift 2
                ;;
            --target)
                TARGET_PATH="$2"
                shift 2
                ;;
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --eject)
                AUTO_EJECT=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                echo ""
                show_help
                exit 2
                ;;
        esac
    done
}

# Main function
main() {
    if [ $# -eq 0 ]; then
        show_help
        exit 0
    fi

    parse_args "$@"
    validate_args

    echo ""
    success "SDCard Media Importer"
    echo ""

    # Load config file and validate UUIDs if config is specified
    if [ -n "$CONFIG_FILE" ]; then
        load_config "$CONFIG_FILE"
        validate_source_uuids
    fi

    # Start timer
    START_TIME=$(date +%s)

    process_files
    print_summary

    if [ "$TOTAL_FILES_ERROR" -gt 0 ]; then
        exit 1
    fi

    exit 0
}

# Run main function
main "$@"