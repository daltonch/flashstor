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
DUPLICATE_ACTION=""
APPLY_TO_ALL=false
START_TIME=0

# Associative array for UUID to name mapping
declare -A UUID_MAP

# Statistics
FILES_COPIED=0
FILES_SKIPPED=0
FILES_RENAMED=0
FILES_ERROR=0

# Show help message
show_help() {
    cat << EOF
SDCard Media Importer v1.0

DESCRIPTION:
    Copies MP4 and WAV files from one or more SD cards and organizes them by date taken.

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
    # SD Card UUID to Name Mapping
    # Lines starting with # are comments
    UUID=friendly/name

    Example:
    0119-B4DD=chad/cd1
    04D5-EF09=chad/cd2
    abcd-1234=pete/pd1

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

    Metadata extraction:
    - exiftool (preferred)
    - ffprobe (fallback)
    - file modification time (final fallback)

    Progress display (optional):
    - pv (pipe viewer) - Shows progress bar during file copy
      Without pv, file size will be displayed instead

DUPLICATE HANDLING:
    When a file with the same name exists in the destination, you will be prompted:
    - (s) Skip: Keep existing file, don't copy
    - (o) Overwrite: Replace existing file with new one
    - (r) Rename: Copy with _1, _2, etc. suffix
    - (a) Apply choice to all remaining duplicates

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

    # Check for pv availability
    if ! command -v pv &> /dev/null; then
        warning "Progress display: pv not found - install for progress bars during copy"
    fi
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

    # Read config file line by line
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Parse UUID=name format
        if [[ "$line" =~ ^([^=]+)=(.+)$ ]]; then
            local uuid="${BASH_REMATCH[1]}"
            local name="${BASH_REMATCH[2]}"
            UUID_MAP["$uuid"]="$name"
            verbose "Loaded mapping: $uuid -> $name"
        fi
    done < "$config_file"

    if [ ${#UUID_MAP[@]} -eq 0 ]; then
        error "No valid UUID mappings found in config file"
        exit 4
    fi

    info "Loaded ${#UUID_MAP[@]} SD card mapping(s)"
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
        local mapped_name="${UUID_MAP[$short_uuid]}"
        if [ -z "$mapped_name" ]; then
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
        if [ -n "${UUID_MAP[$short_uuid]}" ]; then
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

    # Config file is loaded - use UUID mapping
    local uuid
    uuid=$(get_volume_uuid "$source_path")

    if [ -z "$uuid" ]; then
        error "Could not determine UUID for: $source_path"
        exit 4
    fi

    local short_uuid
    short_uuid=$(get_short_uuid "$uuid")

    # Try to match with short UUID first, then full UUID
    local mapped_name="${UUID_MAP[$short_uuid]}"
    if [ -z "$mapped_name" ]; then
        mapped_name="${UUID_MAP[$uuid]}"
    fi

    if [ -z "$mapped_name" ]; then
        error "No mapping found for UUID: $uuid (short: $short_uuid)"
        exit 4
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
    find "$source" -type f \( -iname "*.mp4" -o -iname "*.wav" \) 2>/dev/null
}

# Handle duplicate files - sets DUPLICATE_ACTION global variable
handle_duplicate() {
    local source_file="$1"
    local target_file="$2"

    # If we already have a decision for all files, use it
    if [ "$APPLY_TO_ALL" = true ] && [ -n "$DUPLICATE_ACTION" ]; then
        return 0
    fi

    echo ""
    warning "File already exists: $(basename "$target_file")"
    echo "Source: $source_file"
    echo "Target: $target_file"
    echo ""
    echo "Choose action:"
    echo "  (s) Skip - keep existing file"
    echo "  (o) Overwrite - replace with new file"
    echo "  (r) Rename - add suffix (_1, _2, etc.)"
    echo "  (a) Apply choice to all remaining duplicates"
    echo ""

    while true; do
        read -p "Action [(s)kip/(o)verwrite/(r)ename/(a)ll]: " -n 1 -r choice
        echo ""

        case "$choice" in
            s|S)
                DUPLICATE_ACTION="skip"
                return 0
                ;;
            o|O)
                DUPLICATE_ACTION="overwrite"
                return 0
                ;;
            r|R)
                DUPLICATE_ACTION="rename"
                return 0
                ;;
            a|A)
                while true; do
                    read -p "Apply which action to all? [(s)kip/(o)verwrite/(r)ename]: " -n 1 -r all_choice
                    echo ""
                    case "$all_choice" in
                        s|S)
                            APPLY_TO_ALL=true
                            DUPLICATE_ACTION="skip"
                            return 0
                            ;;
                        o|O)
                            APPLY_TO_ALL=true
                            DUPLICATE_ACTION="overwrite"
                            return 0
                            ;;
                        r|R)
                            APPLY_TO_ALL=true
                            DUPLICATE_ACTION="rename"
                            return 0
                            ;;
                        *)
                            echo "Invalid choice. Please enter s, o, or r."
                            ;;
                    esac
                done
                ;;
            *)
                echo "Invalid choice. Please enter s, o, r, or a."
                ;;
        esac
    done
}

# Get unique filename by adding suffix
get_unique_filename() {
    local target_file="$1"
    local dir=$(dirname "$target_file")
    local filename=$(basename "$target_file")
    local name="${filename%.*}"
    local ext="${filename##*.}"
    local counter=1

    while [ -e "${dir}/${name}_${counter}.${ext}" ]; do
        ((counter++))
    done

    echo "${dir}/${name}_${counter}.${ext}"
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

# Copy file with timestamp preservation
copy_file() {
    local source_file="$1"
    local target_dir="$2"
    local filename
    local target_file
    local file_size

    filename=$(basename "$source_file")
    target_file="${target_dir}/${filename}"

    # Create target directory if it doesn't exist
    if [ "$DRY_RUN" = false ]; then
        mkdir -p "$target_dir"
    fi

    # Check if file already exists
    if [ -e "$target_file" ]; then
        if [ "$DRY_RUN" = false ]; then
            # Reset DUPLICATE_ACTION for this file if not applying to all
            if [ "$APPLY_TO_ALL" = false ]; then
                DUPLICATE_ACTION=""
            fi

            handle_duplicate "$source_file" "$target_file"

            case "$DUPLICATE_ACTION" in
                skip)
                    info "Skipped: $filename"
                    ((FILES_SKIPPED++))
                    return 0
                    ;;
                overwrite)
                    verbose "Overwriting: $target_file"
                    ;;
                rename)
                    target_file=$(get_unique_filename "$target_file")
                    filename=$(basename "$target_file")
                    info "Renaming to: $filename"
                    ((FILES_RENAMED++))
                    ;;
            esac
        else
            warning "[DRY RUN] File exists: $filename"
        fi
    fi

    # Copy the file
    if [ "$DRY_RUN" = true ]; then
        echo " [DRY RUN] Would copy"
    else
        file_size=$(get_file_size "$source_file")

        # Check if pv is available for progress bar
        if command -v pv &> /dev/null; then
            # Use pv for progress bar
            echo ""  # New line before progress bar
            if pv -pterb "$source_file" > "$target_file"; then
                # Preserve timestamps after copy
                touch -r "$source_file" "$target_file" 2>/dev/null
                verbose "Copied: $filename -> $target_dir"
                ((FILES_COPIED++))
            else
                error "Failed to copy: $filename"
                ((FILES_ERROR++))
                return 1
            fi
        else
            # Fallback to cp with size indicator (no pv)
            echo -n "... ($file_size) "
            if cp -p "$source_file" "$target_file" 2>/dev/null; then
                echo "done"
                verbose "Copied: $filename -> $target_dir"
                ((FILES_COPIED++))
            else
                echo "failed"
                error "Failed to copy: $filename"
                ((FILES_ERROR++))
                return 1
            fi
        fi
    fi

    return 0
}

# Process files from a single source
process_single_source() {
    local source_path="$1"
    local tool="$2"
    local sdcard_name=$(get_sdcard_name "$source_path")

    info "Processing SD Card: $sdcard_name ($source_path)"

    echo ""
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
        warning "No MP4 or WAV files found in $source_path"
        return 0
    fi

    info "Found $total_files media file(s)"
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

        if copy_file "$file" "$target_dir"; then
            # copy_file handles the "done" output
            :
        else
            # copy_file handles the "failed" output
            :
        fi
    done

    echo ""

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

    # Process each source path sequentially
    for source_path in "${SOURCE_PATHS[@]}"; do
        process_single_source "$source_path" "$tool"
    done

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

# Print summary
print_summary() {
    local end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))
    local formatted_time=$(format_time $elapsed)

    echo ""
    echo "================================"
    echo "Summary"
    echo "================================"

    if [ "$DRY_RUN" = true ]; then
        success "Dry run completed"
    else
        success "Files copied: $FILES_COPIED"
        if [ "$FILES_RENAMED" -gt 0 ]; then
            info "Files renamed: $FILES_RENAMED"
        fi
        if [ "$FILES_SKIPPED" -gt 0 ]; then
            warning "Files skipped: $FILES_SKIPPED"
        fi
        if [ "$FILES_ERROR" -gt 0 ]; then
            error "Files with errors: $FILES_ERROR"
        fi
    fi

    info "Total time: $formatted_time"

    echo "================================"
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

    if [ "$FILES_ERROR" -gt 0 ]; then
        exit 1
    fi

    exit 0
}

# Run main function
main "$@"