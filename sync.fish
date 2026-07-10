# Fish completions for sync.sh
# Place this file in ~/.config/fish/completions/sync.fish
# Or source it from your fish config: source /path/to/sync.fish

# Complete command name - works for both sync.sh and if installed as 'sync'
set -l prog sync.sh

# Disable file completions by default (we'll enable them where needed)
complete -c $prog -f

# --help option
complete -c $prog -l help -s h -d "Display help message and exit"

# --source option (can be specified multiple times)
# Complete with directories, prioritizing /Volumes/* on macOS and /media/* on Linux
complete -c $prog -l source -d "SD card mount point (can be specified multiple times)" -r -a "
(__fish_complete_directories)
(test -d /Volumes && find /Volumes -maxdepth 1 -type d ! -name Volumes 2>/dev/null)
(test -d /media && find /media -maxdepth 2 -type d ! -name media 2>/dev/null)
(test -d /mnt && find /mnt -maxdepth 1 -type d ! -name mnt 2>/dev/null)
"

# --target option
complete -c $prog -l target -d "Destination directory for organized files" -r -a "(__fish_complete_directories)"

# --config option
# Complete with files, suggesting sdcard_config.txt if it exists in current directory
complete -c $prog -l config -d "Path to UUID mapping config file (optional)" -r -a "
(__fish_complete_path)
(test -f sdcard_config.txt && echo sdcard_config.txt)
(test -f ./sdcard_config.txt && echo ./sdcard_config.txt)
"

# --eject flag
complete -c $prog -l eject -d "Automatically eject/unmount SD cards after successful processing"

# --dry-run flag
complete -c $prog -l dry-run -d "Preview operations without actually copying files"

# --verbose flag
complete -c $prog -l verbose -d "Display detailed progress information during copy"