#!/bin/bash
#
# Author: Isaac Kay
# Version: v0.1
# License: GNU General Public License (GPL)
# Copyright (C) <2025> <Isaac Kay>
# Declaration: 
#
#
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program. If not, see <https://www.gnu.org/licenses/>.
#
#
#
# A Brief Overview: Jetson Linux Version Management Script
# This script automates upgrading/downgrading the Jetson Linux (L4T) version on a Jetson device,
# including kernel compilation and installation. It provides interactive prompts and explanations.
# It also supports backing up and reverting to the previous kernel/OS state.
#

# --- Usage and Help Information ---
print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Upgrade or rebuild the NVIDIA Jetson Linux kernel and OS components interactively."
    echo
    echo "Options:"
    echo "  -t, --target <version>    Specify target Jetson Linux version (e.g. 36.4.4, or JetPack 6.2.1)."
    echo "  -y, --yes                 Assume 'Yes' for all prompts (run non-interactively)."
    echo "  -q, --quiet               Quiet mode (suppress detailed explanations)."
    echo "      --revert [version]    Revert to a previously backed-up Jetson Linux version."
    echo "      --dry-run             Simulate the process without making changes (for testing)."
    echo "  -h, --help                Show this help message and exit."
    echo
    echo "Example: $0 --target 36.4.4 -y"
    echo "         (Upgrades to Jetson Linux 36.4.4/JetPack 6.2.1 non-interactively)"
}

# Parse command-line arguments
TARGET_VERSION_INPUT=""    # user-specified target (could be JetPack or L4T version string)
ASSUME_YES=false
VERBOSE=true
REVERT_MODE=false
REVERT_VERSION=""          # specific version to revert to, if provided
DRY_RUN=false

# Loop through arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target)
            if [[ -n "$2" ]]; then
                TARGET_VERSION_INPUT="$2"
                shift 2
            else
                echo "Error: --target requires an argument (e.g., 35.4.1 or \"JetPack 5.1.2\")."
                exit 1
            fi
            ;;
        -y|--yes)
            ASSUME_YES=true
            shift
            ;;
        -q|--quiet)
            VERBOSE=false
            shift
            ;;
        --revert)
            REVERT_MODE=true
            if [[ -n "$2" && "$2" != "-"* ]]; then
                # If a specific version is provided after --revert, use it
                REVERT_VERSION="$2"
                shift 2
            else
                shift
            fi
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# Function to print info messages (only if VERBOSE mode is on)
info() {
    if [ "$VERBOSE" = true ]; then
        echo -e "$1"
    fi
}

# Secure tarball extraction: always extract to a temporary directory first, then move expected files
# Usage example: `extract_tarball_safely "$TARBALL_PATH" "$DESTINATION_PATH"``
extract_tarball_safely() {
    local tarball="$1"
    local dest_dir="$2"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    # Extract only relative paths, ignore absolute and parent traversal
    tar --strip-components=0 --no-same-owner --no-same-permissions -xf "$tarball" -C "$tmp_dir"
    # Only move expected subdirs/files (e.g., kernel_src, rootfs, etc.)
    # Example: move kernel_src if present
    if [ -d "$tmp_dir/kernel_src" ]; then
        mv "$tmp_dir/kernel_src" "$dest_dir/"
    fi
    # Clean up
    rm -rf "$tmp_dir"
}

# --- SECURITY: Explicitly check for symlinks during backup ---
check_symlinks_before_backup() {
    local src_boot="/boot"
    local src_modules="/lib/modules"
    local found_symlinks=false

    # Check for symlinks in /boot
    if [ -d "$src_boot" ]; then
        symlinks_boot=$(find "$src_boot" -type l)
        if [ -n "$symlinks_boot" ]; then
            echo "Warning: Symlinks found in $src_boot:"
            echo "$symlinks_boot"
            found_symlinks=true
        fi
    fi

    # Check for symlinks in /lib/modules
    if [ -d "$src_modules" ]; then
        symlinks_modules=$(find "$src_modules" -type l)
        if [ -n "$symlinks_modules" ]; then
            echo "Warning: Symlinks found in $src_modules:"
            echo "$symlinks_modules"
            found_symlinks=true
        fi
    fi

    # If symlinks found, ask user how to proceed for each
    if [ "$found_symlinks" = true ]; then
        echo "Symlinks detected in backup source directories."
        echo "For each symlink, you can:"
        echo "  [r] Remove the symlink"
        echo "  [s] Skip backing up this symlink"
        echo "  [a] Abort backup process"
        for symlink in $symlinks_boot $symlinks_modules; do
            while true; do
                read -rp "Symlink: $symlink - [r]emove, [s]kip, [a]bort? " action
                case "$action" in
                    r|R)
                        sudo rm "$symlink"
                        echo "Removed $symlink"
                        break
                        ;;
                    s|S)
                        echo "Skipped $symlink"
                        break
                        ;;
                    a|A)
                        echo "Aborting backup."
                        exit 1
                        ;;
                    *)
                        echo "Invalid choice. Please enter r, s, or a."
                        ;;
                esac
            done
        done
    fi
}

# --- Pre-run Checks and Environment Setup ---
info "\nWelcome! This script will help you update or rebuild your Jetson's Linux kernel and system."
info "Tip: You can run this script with the -h option to see all available flags and usage instructions."

# Ensure script is run with root privileges or has sudo for later.
# (We won't force exit here if not root, but later commands will use sudo as needed.)
if [ "$EUID" -ne 0 ]; then
    info "Note: You are not running as root. The script will use 'sudo' for installation steps when required."
fi

# Detect architecture and Jetson environment
ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" ]]; then
    info "\nWARNING: You are running this script on a non-Jetson system ($ARCH)."
    info "The script will attempt to cross-compile for Jetson. Make sure you have an ARM64 toolchain installed."
    info "Please set the CROSS_COMPILE environment variable to point to your aarch64 toolchain prefix (e.g., /usr/bin/aarch64-linux-gnu-).:contentReference[oaicite:34]{index=34}"
    # If CROSS_COMPILE is not set, we cannot proceed with cross-compilation
    if [[ -z "$CROSS_COMPILE" ]]; then
        echo "Error: CROSS_COMPILE is not set. Export your toolchain path prefix to CROSS_COMPILE and re-run."
        exit 1
    fi
    CROSS_BUILD=true
else
    CROSS_BUILD=false
fi

# Get current Jetson Linux version if available
CURRENT_L4T_VERSION="unknown"
JETSON_MODEL="Unknown Jetson"
if [ -f "/etc/nv_tegra_release" ]; then
    # nv_tegra_release format example: "# R35 (release), REVISION: 3.1, GCID: ..., BOARD: ..., EABI: ..."
    # We'll parse the RXX and REVISION fields to get e.g. "35.3.1"
    rel_line=$(head -n1 /etc/nv_tegra_release)
    # Use Bash regex to extract R<number> and REVISION
    if [[ $rel_line =~ R([0-9]+)\ .*REVISION:\ ([0-9]+\.[0-9]+) ]]; then
        CURRENT_L4T_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    fi
fi
# Get Jetson model name from device tree, if available
if [ -f "/sys/firmware/devicetree/base/model" ]; then
    # Read model (remove any null characters)
    JETSON_MODEL=$(tr -d '\0' < /sys/firmware/devicetree/base/model)
fi

# Announce current system info
info "\nCurrent device: $JETSON_MODEL"
if [[ "$CURRENT_L4T_VERSION" != "unknown" ]]; then
    info "Current Jetson Linux (L4T) version: $CURRENT_L4T_VERSION"
else
    info "Current Jetson Linux (L4T) version: Unknown (non-NVIDIA or non-L4T OS)."
fi

# If in dry-run mode, and running on a non-Jetson or missing nv_tegra_release, simulate a current version for testing
if [ "$DRY_RUN" = true ] && [[ "$CURRENT_L4T_VERSION" == "unknown" ]]; then
    CURRENT_L4T_VERSION="35.3.1"
    JETSON_MODEL="Jetson AGX Orin (Simulated)"
    info "\n[DRY-RUN] Simulating current environment as $JETSON_MODEL with Jetson Linux $CURRENT_L4T_VERSION."
fi

# If the device is Jetson AGX Orin Industrial and current version is older than 35.4.1, warn about limited support
if [[ "$JETSON_MODEL" == *"Orin Industrial"* && "$CURRENT_L4T_VERSION" != "unknown" ]]; then
    # Compare version to 35.4.1 - this check is coarse, for exact match only.
    if [[ "$CURRENT_L4T_VERSION" < "35.4.1" ]]; then
        info "\nNOTE: Your Jetson AGX Orin Industrial is running $CURRENT_L4T_VERSION. Jetson Linux 35.3.1 did not support the Industrial module:contentReference[oaicite:35]{index=35}."
        info "Upgrading to 35.4.1 or newer is required for full support."
    fi
fi

# --- Revert Mode Handling ---
# If --revert was requested, perform the restoration of a previous version and exit.
if [ "$REVERT_MODE" = true ]; then
    info "\n*** Revert Mode Selected ***"
    # Find backup directories under /usr/local/src/L4T that end with "_backup"
    BACKUP_BASE="/usr/local/src/L4T"
    mapfile -t backup_dirs < <(find "$BACKUP_BASE" -maxdepth 1 -type d -name "*_backup")
    if [[ ${#backup_dirs[@]} -eq 0 ]]; then
        echo "No backup directories found in $BACKUP_BASE. Cannot revert."
        exit 1
    fi

    # Restore files from backup
    # We expect backup dir to have 'boot' and 'lib' subdirectories mirroring the system.

    # --- SECURITY: Validate backup directory before restoring ---
    validate_backup_dir() {
        local dir="$1"
        # Ensure path is absolute and under /usr/local/src/L4T
        if [[ ! "$dir" =~ ^/usr/local/src/L4T/.+_backup$ ]]; then
            echo "Error: Backup directory path is invalid: $dir"
            exit 1
        fi
        # Ensure no symlinks in boot or lib/modules
        if find "$dir/boot" "$dir/lib/modules" -type l 2>/dev/null | grep -q .; then
            echo "Error: Backup contains symlinks, which are not allowed for restore."
            exit 1
        fi
        # Ensure no files outside /usr/local/src/L4T
        if find "$dir" -type f | grep -v "^$dir" | grep -q .; then
            echo "Error: Backup contains files outside expected directory."
            exit 1
        fi
    }

    validate_backup_dir "$REVERT_CHOSEN_DIR"

    if [ -d "$REVERT_CHOSEN_DIR/boot" ]; then
        info "Restoring /boot files (kernel Image, initrd, dtb)..."
        sudo cp -af "$REVERT_CHOSEN_DIR/boot/"* /boot/
    fi
    if [ -d "$REVERT_CHOSEN_DIR/lib" ]; then
        info "Restoring /lib/modules for version $BACKUP_VER_NAME..."
        sudo cp -af "$REVERT_CHOSEN_DIR/lib/modules"/* /lib/modules/
    fi

    REVERT_CHOSEN_DIR=""
    if [[ -n "$REVERT_VERSION" ]]; then
        # User specified a version to revert to
        search_dir="$BACKUP_BASE/${REVERT_VERSION}_backup"
        if [ -d "$search_dir" ]; then
            REVERT_CHOSEN_DIR="$search_dir"
        else
            echo "Specified backup version $REVERT_VERSION not found under $BACKUP_BASE."
            # List available backups for user's reference
            echo "Available backups:"
            for d in "${backup_dirs[@]}"; do
                ver=$(basename "$d")
                echo " - ${ver%_backup}"
            done
            exit 1
        fi
    else
        # No specific version given, if only one backup available use it, otherwise ask user.
        if [[ ${#backup_dirs[@]} -eq 1 ]]; then
            REVERT_CHOSEN_DIR="${backup_dirs[0]}"
        else
            info "Multiple backups are available. Please choose which version to revert to:"
            # List options for user
            select opt in "${backup_dirs[@]}"; do
                if [[ -n "$opt" ]]; then
                    REVERT_CHOSEN_DIR="$opt"
                    break
                fi
            done
        fi
    fi

    if [[ -z "$REVERT_CHOSEN_DIR" ]]; then
        echo "No backup selected. Aborting revert."
        exit 1
    fi

    # Confirm with user (unless auto-confirmed) 
    BACKUP_VER_NAME=$(basename "$REVERT_CHOSEN_DIR")
    BACKUP_VER_NAME="${BACKUP_VER_NAME%_backup}"  # strip trailing _backup
    if [ "$ASSUME_YES" = false ]; then
        read -rp "Restore Jetson Linux $BACKUP_VER_NAME from backup? This will overwrite current kernel and modules. (Y/n) " ans
        ans=${ans:-Y}
        ans=$(echo "$ans" | tr '[:upper:]' '[:lower:]')
        if [[ "$ans" != "y" ]]; then
            echo "Revert canceled by user."
            exit 0
        fi
    else
        info "Auto-confirming revert to $BACKUP_VER_NAME (--yes was used)."
    fi

    info "\nReverting to Jetson Linux $BACKUP_VER_NAME ..."

    # Restore files from backup
    # We expect backup dir to have 'boot' and 'lib' subdirectories mirroring the system.
    if [ -d "$REVERT_CHOSEN_DIR/boot" ]; then
        info "Restoring /boot files (kernel Image, initrd, dtb)..."
        sudo cp -af "$REVERT_CHOSEN_DIR/boot/"* /boot/
    fi
    if [ -d "$REVERT_CHOSEN_DIR/lib" ]; then
        info "Restoring /lib/modules for version $BACKUP_VER_NAME..."
        sudo cp -af "$REVERT_CHOSEN_DIR/lib/modules"/* /lib/modules/
    fi

    info "Revert completed. The system has been restored to Jetson Linux $BACKUP_VER_NAME."
    info "Please reboot the device to start using the restored kernel and system."
    exit 0
fi

# --- User Input for Target Version (if not provided as argument) ---
TARGET_VERSION=""
TARGET_JETPACK=""
TARGET_KERNEL_VER=""
TARGET_UBUNTU_VER=""

if [[ -z "$TARGET_VERSION_INPUT" ]]; then
    # Prompt user to enter a target version
    info "\nPlease enter the Jetson Linux version or JetPack you want to switch to."
    info "You can specify it in various ways (e.g., '35.4.1', 'JetPack 6.2', 'Ubuntu 22.04', 'kernel 5.10')."
    read -rp "Target Jetson Linux version: " TARGET_VERSION_INPUT
fi

# Normalize the input (trim spaces, to lower-case for keywords)
TARGET_VERSION_INPUT=$(echo "$TARGET_VERSION_INPUT" | xargs)  # trim whitespace
INPUT_LOWER=$(echo "$TARGET_VERSION_INPUT" | tr '[:upper:]' '[:lower:]')

# Mapping tables for known versions
declare -A JETPACK_TO_L4T
JETPACK_TO_L4T["5.1.1"]="35.3.1"
JETPACK_TO_L4T["5.1.2"]="35.4.1"
JETPACK_TO_L4T["6.0"]="36.2"      # 6.0 DP corresponds to 36.2.0
JETPACK_TO_L4T["6.1"]="36.4"      # JetPack 6.1 -> 36.4.0
JETPACK_TO_L4T["6.2"]="36.4.3"
JETPACK_TO_L4T["6.2.1"]="36.4.4"

declare -A L4T_TO_JETPACK
for jp in "${!JETPACK_TO_L4T[@]}"; do
    L4T_TO_JETPACK["${JETPACK_TO_L4T[$jp]}"]="$jp"
done

# Also map kernel version and Ubuntu version to possible L4T
KERNEL_TO_L4T_ARR_5_10=("35.3.1" "35.4.1")
KERNEL_TO_L4T_ARR_5_15=("36.2" "36.4" "36.4.3" "36.4.4")
UBUNTU_TO_L4T_20=("35.3.1" "35.4.1")
UBUNTU_TO_L4T_22=("36.2" "36.4" "36.4.3" "36.4.4")

# Helper function to display multiple matching versions and have user choose
choose_from_list() {
    local prompt="$1"
    shift
    local options=("$@")
    if [ ${#options[@]} -eq 0 ]; then
        return 1  # nothing to choose
    elif [ ${#options[@]} -eq 1 ]; then
        TARGET_VERSION="${options[0]}"
        return 0
    fi
    info "$prompt"
    local i=1
    for opt in "${options[@]}"; do
        local jp="${L4T_TO_JETPACK[$opt]}"
        local kern=""
        local ubu=""
        # Determine kernel/ubuntu for display
        case "$opt" in
            "35.3.1") kern="5.10"; ubu="Ubuntu 20.04" ;;
            "35.4.1") kern="5.10"; ubu="Ubuntu 20.04" ;;
            "36.2")   kern="5.15"; ubu="Ubuntu 22.04" ;;
            "36.4")   kern="5.15"; ubu="Ubuntu 22.04" ;;
            "36.4.3") kern="5.15"; ubu="Ubuntu 22.04" ;;
            "36.4.4") kern="5.15"; ubu="Ubuntu 22.04" ;;
        esac
        if [[ -n "$jp" ]]; then
            echo "  $i) Jetson Linux $opt (JetPack $jp, kernel $kern, $ubu)"
        else
            echo "  $i) Jetson Linux $opt (kernel $kern, $ubu)"
        fi
        i=$((i+1))
    done
    local choice
    read -rp "Enter the number of your choice: " choice
    if [[ "$choice" =~ ^[0-9]+$ && $choice -ge 1 && $choice -le ${#options[@]} ]]; then
        TARGET_VERSION="${options[choice-1]}"
        return 0
    else
        echo "Invalid selection."
        return 1
    fi
}

# Determine target version based on input
if [[ "$INPUT_LOWER" == jetson* || "$INPUT_LOWER" == l4t* || "$INPUT_LOWER" =~ ^[0-9]{2}\.[0-9] ]]; then
    # The input explicitly looks like a Jetson Linux version number (e.g., "35.4.1" or has "jetson"/"l4t")
    # Extract numeric parts from input
    if [[ $INPUT_LOWER =~ ([0-9]{2}\.[0-9]\.?[0-9]?) ]]; then
        TARGET_VERSION="${BASH_REMATCH[1]}"
        # If user input only two components like "36.4", append .0
        if [[ "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
            TARGET_VERSION="${TARGET_VERSION}.0"
        fi
    fi
elif [[ "$INPUT_LOWER" == jetpack* || "$INPUT_LOWER" == jp* || "$INPUT_LOWER" =~ ^[0-9]\.[0-9] ]]; then
    # The input looks like a JetPack version
    # Extract JetPack version number
    if [[ $INPUT_LOWER =~ ([0-9]+\.[0-9]+\.?[0-9]*) ]]; then
        TARGET_JETPACK="${BASH_REMATCH[1]}"
        # If user wrote "5.1" assume latest patch (5.1.2)
        if [[ "$TARGET_JETPACK" == "5.1" ]]; then
            TARGET_JETPACK="5.1.2"
        fi
        if [[ -n "${JETPACK_TO_L4T[$TARGET_JETPACK]}" ]]; then
            TARGET_VERSION="${JETPACK_TO_L4T[$TARGET_JETPACK]}"
        else
            # If unknown JetPack, we cannot map directly
            echo "Unknown or unsupported JetPack version: $TARGET_JETPACK"
            exit 1
        fi
    fi
elif [[ "$INPUT_LOWER" == *"ubuntu 20.04"* || "$INPUT_LOWER" == "20.04" ]]; then
    # Ubuntu 20.04 implies JetPack 5.x (L4T 35.x)
    if ! choose_from_list "Ubuntu 20.04 is used by the following Jetson Linux releases:" "${UBUNTU_TO_L4T_20[@]}"; then
        exit 1
    fi
elif [[ "$INPUT_LOWER" == *"ubuntu 22.04"* || "$INPUT_LOWER" == "22.04" ]]; then
    # Ubuntu 22.04 implies JetPack 6.x (L4T 36.x)
    if ! choose_from_list "Ubuntu 22.04 is used by the following Jetson Linux releases:" "${UBUNTU_TO_L4T_22[@]}"; then
        exit 1
    fi
elif [[ "$INPUT_LOWER" == *"5.10"* ]]; then
    # Kernel 5.10 is used by Jetson 35.3.1 and 35.4.1
    if ! choose_from_list "Linux kernel 5.10 corresponds to these Jetson Linux versions:" "${KERNEL_TO_L4T_ARR_5_10[@]}"; then
        exit 1
    fi
elif [[ "$INPUT_LOWER" == *"5.15"* ]]; then
    # Kernel 5.15 is used by Jetson 36.x series
    if ! choose_from_list "Linux kernel 5.15 corresponds to these Jetson Linux versions:" "${KERNEL_TO_L4T_ARR_5_15[@]}"; then
        exit 1
    fi
else
    # Unrecognized input format
    echo "Error: Could not interpret target version input '$TARGET_VERSION_INPUT'."
    echo "Please specify a Jetson Linux version (e.g., 35.4.1) or JetPack version (e.g., 5.1.2) or other supported format."
    exit 1
fi

# At this point, TARGET_VERSION should be set, like "36.4.4" or "35.3.1"
if [[ -z "$TARGET_VERSION" ]]; then
    echo "Failed to determine target version from input '$TARGET_VERSION_INPUT'."
    exit 1
fi

# Format target version for consistency (remove any trailing .0 for display purposes)
TARGET_VERSION_DISPLAY="$TARGET_VERSION"
if [[ "$TARGET_VERSION_DISPLAY" =~ \.0$ ]]; then
    TARGET_VERSION_DISPLAY="${TARGET_VERSION_DISPLAY%\.0}"
fi

# Determine JetPack, kernel, Ubuntu for the target (for confirmation message)
if [[ -n "${L4T_TO_JETPACK[$TARGET_VERSION]}" ]]; then
    TARGET_JETPACK="${L4T_TO_JETPACK[$TARGET_VERSION]}"
fi
case "$TARGET_VERSION" in
    "35.3.1")
        TARGET_KERNEL_VER="5.10"; TARGET_UBUNTU_VER="Ubuntu 20.04" ;;
    "35.4.1")
        TARGET_KERNEL_VER="5.10"; TARGET_UBUNTU_VER="Ubuntu 20.04" ;;
    "36.2")
        TARGET_KERNEL_VER="5.15"; TARGET_UBUNTU_VER="Ubuntu 22.04" ;;
    "36.4")
        TARGET_KERNEL_VER="5.15"; TARGET_UBUNTU_VER="Ubuntu 22.04" ;;
    "36.4.3")
        TARGET_KERNEL_VER="5.15"; TARGET_UBUNTU_VER="Ubuntu 22.04" ;;
    "36.4.4")
        TARGET_KERNEL_VER="5.15"; TARGET_UBUNTU_VER="Ubuntu 22.04" ;;
esac

# Confirm selection with the user
info "\nTarget selection:"
info " -> Jetson Linux $TARGET_VERSION_DISPLAY"
if [[ -n "$TARGET_JETPACK" ]]; then
    info "    (JetPack $TARGET_JETPACK):contentReference[oaicite:36]{index=36}"
fi
if [[ -n "$TARGET_KERNEL_VER" && -n "$TARGET_UBUNTU_VER" ]]; then
    info "    Kernel: $TARGET_KERNEL_VER, OS: $TARGET_UBUNTU_VER"
fi

if [ "$ASSUME_YES" = false ]; then
    read -rp "Proceed with this target version? (Y/n) " confirm
    confirm=${confirm:-Y}
    confirm=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')
    if [[ "$confirm" != "y" ]]; then
        echo "Aborted by user."
        exit 0
    fi
else
    info "Auto-confirming target version (running with --yes)."
fi

# If the target version is the same as current, inform user (it might be a rebuild operation)
if [[ "$CURRENT_L4T_VERSION" == "$TARGET_VERSION" ]]; then
    info "\nNOTE: The target version you selected is the same as the current system version."
    info "The script will rebuild/reinstall the kernel for Jetson Linux $TARGET_VERSION, which can be used to apply custom kernel changes."
fi

# Special check: prevent choosing 35.3.1 for Orin Industrial
if [[ "$JETSON_MODEL" == *"Orin Industrial"* && "$TARGET_VERSION" == "35.3.1" ]]; then
    echo "Error: Jetson AGX Orin Industrial is not supported on Jetson Linux 35.3.1:contentReference[oaicite:37]{index=37}. Please choose 35.4.1 or later."
    exit 1
fi

# --- Prepare for Download and Extraction ---
# Define expected filenames for tarballs
BSP_TARBALL="Jetson_Linux_R${TARGET_VERSION}_aarch64.tbz2"
SRC_TARBALL="public_sources.tbz2"
DOWNLOAD_DIR="$HOME/Downloads"
NEED_BSP=false
NEED_SRC=false

# Check if files exist
if [ ! -f "$DOWNLOAD_DIR/$BSP_TARBALL" ]; then
    NEED_BSP=true
fi
if [ ! -f "$DOWNLOAD_DIR/$SRC_TARBALL" ]; then
    NEED_SRC=true
fi

# If any required file is missing, prompt user to download
if $NEED_BSP || $NEED_SRC; then
    info "\nThe required files for Jetson Linux $TARGET_VERSION_DISPLAY need to be in your ~/Downloads directory:"
    if $NEED_BSP; then info " - $BSP_TARBALL (Jetson Linux Driver Package BSP)"; fi
    if $NEED_SRC; then info " - $SRC_TARBALL (Jetson Linux BSP Sources)"; fi
    # Construct the URL for the Jetson Linux release page (replace dots in version for the URL format)
    URL_VER=$(echo "$TARGET_VERSION" | sed 's/\.//g')   # e.g., "36.4.4" -> "3644"
    # Some versions might drop the last zero (for .0 releases) in the URL, handle that:
    if [[ "$TARGET_VERSION" =~ \.0$ ]]; then
        URL_VER="${URL_VER%0}"  # e.g., "3640" -> "364"
    fi
    DOWNLOAD_PAGE="https://developer.nvidia.com/embedded/jetson-linux-r${URL_VER}"
    info "\nPlease download the files from NVIDIA's website:"
    info " 👉 $DOWNLOAD_PAGE"
    info "(You may need to log in to the NVIDIA developer site to download.)"
    # Prompt user to download and confirm
    if [ "$ASSUME_YES" = false ]; then
        while true; do
            read -rp "Press Y after you have downloaded the required file(s) to $DOWNLOAD_DIR, or N to abort: " dl_confirm
            dl_confirm=${dl_confirm:-Y}
            dl_confirm=$(echo "$dl_confirm" | tr '[:upper:]' '[:lower:]')
            if [[ "$dl_confirm" == "y" ]]; then
                # Re-check files
                missing=""
                $NEED_BSP && [ ! -f "$DOWNLOAD_DIR/$BSP_TARBALL" ] && missing+=" $BSP_TARBALL"
                $NEED_SRC && [ ! -f "$DOWNLOAD_DIR/$SRC_TARBALL" ] && missing+=" $SRC_TARBALL"
                if [[ -z "$missing" ]]; then
                    info "All required files are now present. Continuing."
                    break
                else
                    echo "Still missing:${missing}. Please ensure the files are in $DOWNLOAD_DIR."
                    # Loop again
                fi
            elif [[ "$dl_confirm" == "n" ]]; then
                echo "Aborting as requested. Please download the files and run the script again."
                exit 0
            else
                echo "Please answer Y or N."
            fi
        done
    else
        # In auto mode, just check once and abort if not present
        if $NEED_BSP && [ ! -f "$DOWNLOAD_DIR/$BSP_TARBALL" ]; then
            echo "Error: $BSP_TARBALL not found in $DOWNLOAD_DIR. (Auto mode, cannot prompt.)"
            exit 1
        fi
        if $NEED_SRC && [ ! -f "$DOWNLOAD_DIR/$SRC_TARBALL" ]; then
            echo "Error: $SRC_TARBALL not found in $DOWNLOAD_DIR. (Auto mode, cannot prompt.)"
            exit 1
        fi
        info "Auto mode: required files found. Proceeding."
    fi
fi

# --- Create Working Directory and Extract Tarballs ---
WORKDIR_BASE="/usr/local/src/L4T"
WORKDIR_TARGET="$WORKDIR_BASE/$TARGET_VERSION"
if [ "$DRY_RUN" = true ]; then
    info "\n[DRY-RUN] Working directory would be $WORKDIR_TARGET"
fi

# If the work directory already exists, decide whether to reuse or clean it
if [ -d "$WORKDIR_TARGET" ]; then
    info "\nNote: Working directory for Jetson Linux $TARGET_VERSION ($WORKDIR_TARGET) already exists."
    info "The script will reuse this directory and its contents."
    # Optionally, we could ask to delete and re-extract, but we'll assume reuse is fine to avoid losing user changes.
else
    info "\nCreating working directory: $WORKDIR_TARGET"
    if [ "$DRY_RUN" = false ]; then
        sudo mkdir -p "$WORKDIR_TARGET"
        sudo chown "$USER":"$USER" "$WORKDIR_TARGET"   # ensure current user can write
    fi
fi

# Now extract the BSP and public_sources tarballs
info "Extracting Jetson Linux BSP and sources into $WORKDIR_TARGET ... (this may take a few minutes)"
if [ "$DRY_RUN" = false ]; then
    cd "$WORKDIR_TARGET" || exit 1
    # Extract BSP tarball
    extract_tarball_safely "$DOWNLOAD_DIR/$BSP_TARBALL" "$WORKDIR_TARGET"
    # Extract sources tarball
    extract_tarball_safely "$DOWNLOAD_DIR/$SRC_TARBALL" "$WORKDIR_TARGET"
    # Extract kernel source from within public_sources
    if [ -f "Linux_for_Tegra/source/public/kernel_src.tbz2" ]; then
        cd Linux_for_Tegra/source/public || exit 1
        extract_tarball_safely kernel_src.tbz2
        cd "$WORKDIR_TARGET" || exit 1
    else
        echo "Error: kernel_src.tbz2 not found in public_sources package. Extraction might have failed."
        exit 1
    fi
    info "Extraction complete."
    # (We now have Linux_for_Tegra directory with kernel source ready.)
else
    info "[DRY-RUN] Would extract $BSP_TARBALL and $SRC_TARBALL here."
fi

# --- Kernel Build Setup ---
# Determine kernel subdirectory name (e.g., kernel-5.10 or kernel-5.15) based on target kernel version
if [[ "$TARGET_KERNEL_VER" == "5.10" ]]; then
    KERNEL_SUBDIR="kernel/kernel-5.10"
elif [[ "$TARGET_KERNEL_VER" == "5.15" ]]; then
    KERNEL_SUBDIR="kernel/kernel-5.15"
else
    # Fallback: find 'kernel-' dir under source/public/kernel
    kernel_dir_found=$(find "$WORKDIR_TARGET/Linux_for_Tegra/source/public/kernel" -maxdepth 1 -type d -name "kernel-*")
    KERNEL_SUBDIR="kernel/$(basename "$kernel_dir_found")"
fi

# Create a build output directory for the kernel compile
BUILD_DIR="$WORKDIR_TARGET/kernel_build"
if [ "$DRY_RUN" = false ]; then
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
fi

# Move into the kernel source directory
if [ "$DRY_RUN" = false ]; then
    cd "$WORKDIR_TARGET/Linux_for_Tegra/source/public/$KERNEL_SUBDIR" || exit 1
fi

info "\nConfiguring the kernel source (applying default NVIDIA config)..."
if [ "$DRY_RUN" = false ]; then
    # Use tegra_defconfig to set up .config in the build output directory
    make ARCH=arm64 O="$BUILD_DIR" tegra_defconfig
else
    info "[DRY-RUN] Would run: make ARCH=arm64 O=$BUILD_DIR tegra_defconfig"
fi

# Ensure LOCALVERSION is set to "-tegra" for compatibility (especially in cross-compile case)
# We'll append it to the make command if needed.
LOCALVERSION_ARG="LOCALVERSION=-tegra"

# --- Kernel Compilation ---
info "Building the kernel and modules. This can take a while..."
if [ "$DRY_RUN" = false ]; then
    # Compile the kernel, modules, and dtbs using all CPU cores
    if ! make ARCH=arm64 O="$BUILD_DIR" -j"$(nproc)" $LOCALVERSION_ARG; then
        echo "Kernel compilation failed. Aborting."
        exit 1
    fi
else
    info "[DRY-RUN] Would run: make ARCH=arm64 O=$BUILD_DIR -j$(nproc) $LOCALVERSION_ARG"
    info "[DRY-RUN] Simulating successful kernel build."
fi

info "Kernel build completed successfully."
# Determine the new kernel release string (version) from the build
NEW_KERNEL_RELEASE=""
if [ "$DRY_RUN" = false ]; then
    NEW_KERNEL_RELEASE=$(make -s ARCH=arm64 O="$BUILD_DIR" kernelrelease)
else
    # Simulate kernelrelease for dry-run
    if [[ -n "$TARGET_KERNEL_VER" ]]; then
        # e.g., "5.15.85-tegra" or similar
        NEW_KERNEL_RELEASE="${TARGET_KERNEL_VER}.x-tegra"
    fi
fi
if [[ -z "$NEW_KERNEL_RELEASE" ]]; then
    NEW_KERNEL_RELEASE="$TARGET_KERNEL_VER-tegra"
fi
info "New kernel version string: $NEW_KERNEL_RELEASE"

# --- Backup Current System Files (before installing new ones) ---
BACKUP_DIR="$WORKDIR_BASE/${CURRENT_L4T_VERSION}_backup"
info "\nBacking up current system files (kernel, DTBs, modules) to $BACKUP_DIR"
if [ "$DRY_RUN" = false ]; then
    check_symlinks_before_backup
    sudo mkdir -p "$BACKUP_DIR"
    # Backup /boot Image and initrd
    if [ -f "/boot/Image" ]; then
        sudo cp -p "/boot/Image" "$BACKUP_DIR/boot_Image"
    fi
    if [ -f "/boot/initrd" ]; then
        sudo cp -p "/boot/initrd" "$BACKUP_DIR/boot_initrd"
    fi
    # Backup /boot/dtb directory
    if [ -d "/boot/dtb" ]; then
        sudo cp -pr "/boot/dtb" "$BACKUP_DIR/boot_dtb"
    fi
    # Backup /lib/modules of current kernel
    if [ -n "$CURRENT_L4T_VERSION" ] && [ "$CURRENT_L4T_VERSION" != "unknown" ]; then
        # Find current kernel release (uname -r) for modules
        CURR_UNAME=$(uname -r)
        if [ -d "/lib/modules/$CURR_UNAME" ]; then
            sudo mkdir -p "$BACKUP_DIR/lib/modules"
            sudo cp -pr "/lib/modules/$CURR_UNAME" "$BACKUP_DIR/lib/modules/"
        fi
    fi
else
    info "[DRY-RUN] Would backup current /boot and /lib/modules to $BACKUP_DIR"
fi

# --- Install New Kernel Files ---
if [ "$CROSS_BUILD" = true ]; then
    info "\nCross-build mode: skipping direct installation to system."
    info "Please manually copy the following files to your Jetson device:"
    info " - Kernel image: $BUILD_DIR/arch/arm64/boot/Image  ->  /boot/Image (on Jetson)"
    info " - Device Tree blobs: $BUILD_DIR/arch/arm64/boot/dts/nvidia/*.dtb  ->  /boot/dtb/ (on Jetson)"
    info " - Modules: copy the entire $BUILD_DIR/lib/modules/$NEW_KERNEL_RELEASE directory to /lib/modules/ on the Jetson."
    info "Alternatively, you can create a kernel module package (kernel_supplements.tbz2) as per NVIDIA's documentation:contentReference[oaicite:38]{index=38}."
else
    info "\nInstalling new kernel and device tree files..."
    if [ "$DRY_RUN" = false ]; then
        # Copy kernel Image to /boot
        sudo cp -v "$BUILD_DIR/arch/arm64/boot/Image" /boot/Image
        # Copy all dtb files
        if [ -d "/boot/dtb" ]; then
            sudo cp -v "$BUILD_DIR/arch/arm64/boot/dts/"*/*.dtb /boot/dtb/ 2>/dev/null || sudo cp -v "$BUILD_DIR/arch/arm64/boot/dts/"*.dtb /boot/dtb/
        fi
    else
        info "[DRY-RUN] Would copy new Image to /boot and DTBs to /boot/dtb/"
    fi

    info "Installing kernel modules..."
    if [ "$DRY_RUN" = false ]; then
        sudo make ARCH=arm64 O="$BUILD_DIR" modules_install
    else
        info "[DRY-RUN] Would run: make ARCH=arm64 O=$BUILD_DIR modules_install"
    fi

    info "Updating module dependencies (depmod)..."
    if [ "$DRY_RUN" = false ]; then
        sudo depmod "$NEW_KERNEL_RELEASE"
    else
        info "[DRY-RUN] Would run: depmod $NEW_KERNEL_RELEASE"
    fi

    info "Generating new initramfs..."
    if [ "$DRY_RUN" = false ]; then
        sudo update-initramfs -c -k "$NEW_KERNEL_RELEASE"
        # If generated a versioned initrd, replace generic /boot/initrd
        if [ -f "/boot/initrd.img-$NEW_KERNEL_RELEASE" ]; then
            sudo cp -v "/boot/initrd.img-$NEW_KERNEL_RELEASE" /boot/initrd
        fi
    else
        info "[DRY-RUN] Would run: update-initramfs -c -k $NEW_KERNEL_RELEASE and update /boot/initrd"
    endif

    info "\nInstallation of Jetson Linux $TARGET_VERSION_DISPLAY is complete."
    info "The new kernel (version $NEW_KERNEL_RELEASE) has been installed."
    info "A backup of the previous system is saved at $BACKUP_DIR."
    info "Please reboot the system to start using the new kernel."
fi

# If we reach here in dry-run mode, just conclude
if [ "$DRY_RUN" = true ]; then
    info "\n[DRY-RUN] Simulation complete. No changes were made to the system."
fi
