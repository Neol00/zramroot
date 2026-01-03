#!/bin/bash
# ZRAMroot Installation Script
# This script installs ZRAMroot components and configures your system to use it

# Colors for better UX
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print messages with colors
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Function to print header
print_header() {
    clear
    echo "============================================================"
    echo "                  ZRAMroot Installation                     "
    echo "============================================================"
    echo ""
}

# Check if script is run as root
if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root (with sudo)"
    exit 1
fi

# Detect init system
detect_init_system() {
    print_info "Detecting init system..." >&2

    # Check for mkinitcpio (Arch Linux and derivatives)
    # Priority check: Look for mkinitcpio command and directory first
    if command -v mkinitcpio >/dev/null 2>&1 && [ -d "/usr/lib/initcpio" ]; then
        print_info "Detected: Arch-based system (mkinitcpio)" >&2
        echo "mkinitcpio"
        return 0
    fi

    # Check for initramfs-tools (Debian, Ubuntu, and derivatives)
    if command -v update-initramfs >/dev/null 2>&1 && [ -d "/usr/share/initramfs-tools" ]; then
        print_info "Detected: Debian/Ubuntu (initramfs-tools)" >&2
        echo "initramfs-tools"
        return 0
    fi

    # Check for dracut (Fedora, RHEL, openSUSE)
    if command -v dracut >/dev/null 2>&1; then
        print_error "Detected dracut init system" >&2
        print_error "dracut is not currently supported by ZRAMroot" >&2
        print_info "Supported systems: Debian/Ubuntu (initramfs-tools), Arch Linux (mkinitcpio)" >&2
        echo "unsupported"
        return 1
    fi

    # Unknown init system
    print_error "Could not detect a supported init system" >&2
    print_info "Supported systems:" >&2
    print_info "  - Debian/Ubuntu (initramfs-tools)" >&2
    print_info "  - Arch Linux/Artix/Manjaro (mkinitcpio)" >&2
    echo "unknown"
    return 1
}

INIT_SYSTEM=$(detect_init_system)

if [ "$INIT_SYSTEM" = "unsupported" ] || [ "$INIT_SYSTEM" = "unknown" ]; then
    print_error "Cannot continue installation on unsupported system"
    exit 1
fi

print_header

# Dependency checking function
check_dependencies() {
    print_info "=== Checking System Dependencies ==="
    echo ""
    
    # Core required binaries (from zramroot hook script copy_bin_list)
    local core_bins="busybox sh mount umount mkdir rmdir echo cat grep sed df awk rsync cp touch date \
                     mountpoint zramctl lsmod modprobe fsck blkid udevadm fuser find tail head ls sync"
    
    # Filesystem tools
    local fs_bins="mkfs.ext4 fsck.ext4"
    
    # Additional binaries used in zramroot-boot script
    local boot_bins="cut du kill mkfs mkswap nproc printf rm sort sleep timeout wait wc"
    
    # System utilities that may not be in core but are needed
    local util_bins="seq"
    
    # Optional binaries (for different filesystems)
    local btrfs_bins="mkfs.btrfs btrfs"
    local xfs_bins="mkfs.xfs xfs_repair"
    local lvm_bins="vgchange lvchange dmsetup lvscan vgscan pvscan"
    
    local missing_core=()
    local missing_optional=()
    local all_good=true
    
    # Function to check if binary exists
    check_binary() {
        local bin="$1"

        # Check for shell builtins first
        case "$bin" in
            wait|kill|echo|printf|cd|pwd|test|true|false|shift|export|unset|set|read)
                # These are shell builtins available in all POSIX shells
                return 0
                ;;
        esac

        # Special handling for busybox on Arch/mkinitcpio systems
        if [ "$bin" = "busybox" ] && [ "$INIT_SYSTEM" = "mkinitcpio" ]; then
            # On Arch, busybox is in /usr/lib/initcpio/busybox
            if [ -x "/usr/lib/initcpio/busybox" ]; then
                return 0
            fi
            # Also check if mkinitcpio-busybox package is installed
            if command -v pacman >/dev/null 2>&1; then
                if pacman -Q mkinitcpio-busybox >/dev/null 2>&1; then
                    return 0
                fi
            fi
        fi

        # Check for external binaries
        for dir in /bin /usr/bin /sbin /usr/sbin /usr/lib/initcpio; do
            if [ -x "${dir}/${bin}" ]; then
                return 0
            fi
        done

        # For some binaries, also check if they're available via command -v
        if command -v "$bin" >/dev/null 2>&1; then
            return 0
        fi

        return 1
    }
    
    # Check all core binaries
    print_info "Checking core utilities..."
    for bin in $core_bins; do
        if ! check_binary "$bin"; then
            missing_core+=("$bin")
            print_warning "Missing: $bin"
            all_good=false
        else
            print_info "✓ Found: $bin"
        fi
    done
    
    # Check filesystem tools
    print_info "Checking filesystem utilities..."
    for bin in $fs_bins; do
        if ! check_binary "$bin"; then
            missing_core+=("$bin")
            print_warning "Missing: $bin"
            all_good=false
        else
            print_info "✓ Found: $bin"
        fi
    done
    
    # Check boot script binaries
    print_info "Checking boot script utilities..."
    for bin in $boot_bins; do
        if ! check_binary "$bin"; then
            missing_core+=("$bin")
            print_warning "Missing: $bin"
            all_good=false
        else
            print_info "✓ Found: $bin"
        fi
    done
    
    # Check additional utilities
    print_info "Checking additional utilities..."
    for bin in $util_bins; do
        if ! check_binary "$bin"; then
            missing_core+=("$bin")
            print_warning "Missing: $bin"
            all_good=false
        else
            print_info "✓ Found: $bin"
        fi
    done
    
    # Check filesystem-specific tools
    if [ -f "/etc/zramroot.conf" ]; then
        local fs_type=$(grep "^ZRAM_FS_TYPE=" "/etc/zramroot.conf" 2>/dev/null | cut -d'"' -f2)
        case "$fs_type" in
            btrfs)
                print_info "Checking btrfs utilities (required for ZRAM_FS_TYPE=btrfs)..."
                for bin in $btrfs_bins; do
                    if ! check_binary "$bin"; then
                        missing_core+=("$bin")
                        print_warning "Missing: $bin"
                        all_good=false
                    fi
                done
                ;;
            xfs)
                print_info "Checking XFS utilities (required for ZRAM_FS_TYPE=xfs)..."
                for bin in $xfs_bins; do
                    if ! check_binary "$bin"; then
                        missing_core+=("$bin")
                        print_warning "Missing: $bin"
                        all_good=false
                    fi
                done
                ;;
        esac
    fi
    
    # Check LVM tools if system uses LVM
    local root_device="${ROOT:-$(grep -oP 'root=\K[^[:space:]]+' /proc/cmdline)}"
    if echo "$root_device" | grep -q "/dev/mapper/\|/dev/.*-.*" && command -v vgdisplay >/dev/null 2>&1; then
        if vgdisplay 2>/dev/null | grep -q "VG Status.*available"; then
            print_info "LVM detected, checking LVM utilities..."
            for bin in $lvm_bins; do
                if ! check_binary "$bin"; then
                    missing_optional+=("$bin")
                    print_warning "Missing LVM tool: $bin"
                fi
            done
        fi
    fi
    
    echo ""
    
    # Report results
    if [ ${#missing_core[@]} -eq 0 ]; then
        print_success "All core dependencies satisfied!"
        return 0
    else
        print_error "Missing ${#missing_core[@]} required dependencies!"
        echo ""
        show_package_install_instructions "${missing_core[@]}"
        return 1
    fi
}

# Function to show package installation instructions
show_package_install_instructions() {
    local missing_bins=("$@")
    
    print_warning "The following packages need to be installed:"
    echo ""
    
    # Detect distribution
    local distro=""
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        distro="${ID}"
    elif [ -f /etc/debian_version ]; then
        distro="debian"
    elif [ -f /etc/redhat-release ]; then
        distro="rhel"
    fi
    
    # Create package recommendations based on missing binaries
    local packages=()
    
    for bin in "${missing_bins[@]}"; do
        case "$bin" in
            # Core system utilities
            rsync) packages+=("rsync") ;;
            busybox) packages+=("busybox") ;;
            
            # Filesystem and disk utilities  
            zramctl|blkid|mountpoint|mount|umount|df) packages+=("util-linux") ;;
            mkfs.ext4|fsck.ext4|fsck) packages+=("e2fsprogs") ;;
            mkfs|mkswap) packages+=("util-linux") ;;
            
            # Process and system management
            fuser) packages+=("psmisc") ;;
            modprobe|lsmod) packages+=("kmod") ;;
            udevadm) packages+=("udev") ;;
            
            # Core utilities (coreutils package) - excluding shell builtins
            mkdir|rmdir|cat|cp|touch|date|sync|find|tail|head|ls|cut|rm|sort|sleep|wc|nproc|du) packages+=("coreutils") ;;
            # Note: echo and printf are shell builtins, no package needed
            
            # Text processing
            grep|sed|awk) packages+=("grep" "sed" "gawk") ;;
            
            # Additional utilities
            seq) packages+=("coreutils") ;;
            timeout) packages+=("coreutils") ;;
            # Note: kill and wait are shell builtins, no package needed
            
            # Filesystem-specific tools
            mkfs.btrfs|btrfs) packages+=("btrfs-progs") ;;
            mkfs.xfs|xfs_repair) packages+=("xfsprogs") ;;
            
            # LVM tools
            vgchange|lvchange|dmsetup|lvscan|vgscan|pvscan) packages+=("lvm2") ;;
        esac
    done
    
    # Remove duplicates
    packages=($(printf '%s\n' "${packages[@]}" | sort -u))
    
    # Show installation commands for different distributions
    case "$distro" in
        ubuntu|debian)
            print_info "For Debian/Ubuntu systems, run:"
            echo "    sudo apt update"
            echo "    sudo apt install ${packages[*]}"
            ;;
        fedora)
            print_info "For Fedora systems, run:"
            echo "    sudo dnf install ${packages[*]}"
            ;;
        centos|rhel|rocky|alma)
            print_info "For RHEL/CentOS systems, run:"
            echo "    sudo yum install ${packages[*]}"
            ;;
        arch|manjaro|artix)
            # Special handling for busybox on Arch-based systems
            local arch_packages=()
            for pkg in "${packages[@]}"; do
                if [ "$pkg" = "busybox" ]; then
                    arch_packages+=("mkinitcpio-busybox")
                else
                    arch_packages+=("$pkg")
                fi
            done
            print_info "For Arch Linux/Artix systems, run:"
            echo "    sudo pacman -S ${arch_packages[*]}"
            ;;
        opensuse|suse)
            print_info "For openSUSE systems, run:"
            echo "    sudo zypper install ${packages[*]}"
            ;;
        *)
            print_info "Please install these packages using your system's package manager:"
            for pkg in "${packages[@]}"; do
                echo "    - $pkg"
            done
            ;;
    esac
    
    echo ""
    print_warning "Please install the missing packages and run this script again."
}

# Run dependency check
if ! check_dependencies; then
    echo ""
    read -p "Would you like to continue anyway? (NOT RECOMMENDED) (y/n): " force_continue
    if [[ ! "$force_continue" =~ ^[Yy]$ ]]; then
        print_info "Installation cancelled. Please install the required packages first."
        exit 1
    fi
    print_warning "Continuing with missing dependencies - installation may fail!"
fi

print_header

# Display warning and get confirmation
print_warning "ZRAMroot might make your installation unbootable if not configured correctly."
print_warning "This script will:"

if [ "$INIT_SYSTEM" = "initramfs-tools" ]; then
    print_info "  • Replace /usr/share/initramfs-tools/scripts/local with ZRAMroot version"
    print_info "  • Install ZRAMroot hooks and configuration files"
    print_info "  • Optionally configure a bootloader entry (GRUB, systemd-boot, or extlinux)"
    print_info "  • Rebuild your initramfs to include ZRAMroot support"
elif [ "$INIT_SYSTEM" = "mkinitcpio" ]; then
    print_info "  • Install ZRAMroot hooks to /usr/lib/initcpio/"
    print_info "  • Install configuration file to /etc/zramroot.conf"
    print_info "  • Provide instructions for manual mkinitcpio.conf configuration"
fi

echo ""
print_info "It is STRONGLY recommended to make a backup before continuing."
echo ""
read -p "Are you sure you want to continue? (y/n): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    print_info "Installation aborted by user."
    exit 0
fi

print_header

# Check for required files based on init system
print_info "Checking for required files for ${INIT_SYSTEM}..."

if [ "$INIT_SYSTEM" = "initramfs-tools" ]; then
    FILES=(
        "initramfs-tools/scripts/local-premount/zramroot-boot"
        "initramfs-tools/scripts/local"
        "initramfs-tools/hooks/zramroot"
        "initramfs-tools/conf.d/zramroot-config"
    )
elif [ "$INIT_SYSTEM" = "mkinitcpio" ]; then
    FILES=(
        "mkinitcpio/hooks/zramroot"
        "mkinitcpio/install/zramroot"
        "zramroot.conf"
    )
else
    print_error "Unknown init system: ${INIT_SYSTEM}"
    exit 1
fi

MISSING=0
for file in "${FILES[@]}"; do
    if [ ! -f "$file" ]; then
        print_error "Required file not found: $file"
        MISSING=1
    fi
done

if [ $MISSING -eq 1 ]; then
    print_error "Some required files are missing. Please make sure all files are in the correct directory structure."
    print_info "Expected directory structure:"
    if [ "$INIT_SYSTEM" = "initramfs-tools" ]; then
        print_info "  initramfs-tools/hooks/zramroot"
        print_info "  initramfs-tools/scripts/local"
        print_info "  initramfs-tools/scripts/local-premount/zramroot-boot"
        print_info "  initramfs-tools/conf.d/zramroot-config"
    else
        print_info "  mkinitcpio/hooks/zramroot"
        print_info "  mkinitcpio/install/zramroot"
        print_info "  zramroot.conf"
    fi
    exit 1
fi

# Get additional modules from user - only for initramfs-tools
additional_modules=""

if [ "$INIT_SYSTEM" = "initramfs-tools" ]; then
    print_header
    print_info "You can specify additional kernel modules to load during early boot."
    print_info "These might be needed for specific hardware support."
    print_info "Enter module names separated by spaces, or leave empty for no additional modules."
    echo ""

    # Initialize module selection variables
    module_selection_complete=false

    while [ "$module_selection_complete" = false ]; do
        # Show current selection if any
        if [ -n "$additional_modules" ]; then
            print_info "Current module selection: $additional_modules"
        fi

        # Read module input, pre-populate with current selection
        read -e -p "Additional modules: " -i "$additional_modules" input_modules
        additional_modules="$input_modules"

        # If no modules specified, we're done
        if [ -z "$additional_modules" ]; then
            print_info "No additional modules selected."
            module_selection_complete=true
            continue
        fi

        echo ""
        print_info "Checking if modules exist in your system..."

        # Create arrays for existing and non-existing modules
        # Important: Clear these arrays each time to prevent carrying over previous checks
        existing_modules=()
        nonexisting_modules=()

        # Check each module
        for module in $additional_modules; do
            if modinfo $module &>/dev/null || [ -f "/lib/modules/$(uname -r)/kernel/$module.ko" ] || find /lib/modules/$(uname -r) -name "${module}.ko*" | grep -q .; then
                existing_modules+=("$module")
                print_info "Module '$module' exists in the system."
            else
                nonexisting_modules+=("$module")
                print_warning "Module '$module' was not found in the system."
            fi
        done

        # Warn about non-existing modules
        if [ ${#nonexisting_modules[@]} -gt 0 ]; then
            echo ""
            print_warning "The following modules were not found in your system:"
            for module in "${nonexisting_modules[@]}"; do
                echo "  - $module"
            done
            echo ""
            print_warning "These modules might not load correctly during boot."
            read -p "Do you want to continue with these modules? (y/n): " include_nonexisting

            if [[ ! "$include_nonexisting" =~ ^[Yy]$ ]]; then
                print_info "Please correct your module selection."
                # Continue loop without setting module_selection_complete
                continue
            fi
        fi

        # Final confirmation of modules
        echo ""
        print_info "The following modules will be added:"
        echo "$additional_modules"
        echo ""
        read -p "Is this correct? (y/n): " confirm_modules

        if [[ "$confirm_modules" =~ ^[Yy]$ ]]; then
            module_selection_complete=true
        else
            print_info "Please correct your module selection."
            # Loop continues with current selection in the input field
        fi
    done
else
    print_info "Skipping additional module selection (not applicable for mkinitcpio)"
fi

print_header
print_warning "Please wait until the installation is complete."
print_warning "Do not close this terminal or interrupt the script."
echo ""
print_info "Starting installation process..."
sleep 2

# Function to create backup of a file (but NOT in /etc/grub.d)
backup_file() {
    local file=$1
    # Skip backup for files in /etc/grub.d as they cause duplicate menu entries
    if [[ "$file" == /etc/grub.d/* ]]; then
        print_info "Skipping backup of $file (GRUB directory - backups cause duplicate menu entries)"
        return
    fi

    if [ -f "$file" ]; then
        # Create backup in /tmp instead of in-place to avoid issues
        local backup_dir="/tmp/zramroot-backups-$(date +%Y%m%d)"
        mkdir -p "$backup_dir"
        local backup_file="$backup_dir/$(basename "$file").bak.$(date +%Y%m%d%H%M%S)"
        cp "$file" "$backup_file"
        print_info "Created backup of $file at $backup_file"
    fi
}

# Function to enable interactive prompt mode in zramroot.conf
enable_interactive_prompt() {
    local config_file="/etc/zramroot.conf"

    echo ""
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_info "           Interactive Prompt Mode (Alternative to Kernel Parameter)"
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_info "Since bootloader configuration is not available, you can enable"
    print_info "interactive prompt mode instead. This will ask you at boot time"
    print_info "whether you want to boot with ZRAM or not."
    echo ""
    print_info "With interactive prompt mode:"
    print_info "  • You'll see a prompt during boot: 'Boot with ZRAM? [y/N]'"
    print_info "  • Press 'y' to boot with ZRAM, or 'n' (or wait) for normal boot"
    print_info "  • No kernel parameter needed"
    echo ""

    read -p "Would you like to enable interactive prompt mode? (y/n): " enable_prompt

    if [[ "$enable_prompt" =~ ^[Yy]$ ]]; then
        if [ ! -f "$config_file" ]; then
            print_error "Configuration file not found at $config_file"
            print_warning "Please run the installation first, then manually edit the config file."
            return 1
        fi

        # Backup the config file
        backup_file "$config_file"

        # Enable interactive prompt mode
        sed -i 's/^ZRAM_INTERACTIVE_PROMPT=.*/ZRAM_INTERACTIVE_PROMPT="yes"/' "$config_file"

        # Verify the change
        if grep -q '^ZRAM_INTERACTIVE_PROMPT="yes"' "$config_file"; then
            print_success "Interactive prompt mode enabled in $config_file"
            echo ""
            print_info "At boot time, you will see:"
            print_info "  Boot with ZRAM (copy root filesystem to RAM)? [y/N]"
            print_info "  Default: NO"
            print_info "  Timeout: 10 seconds"
            echo ""
            print_info "You can customize the timeout and default choice by editing:"
            print_info "  $config_file"
            echo ""
            print_info "Look for these settings:"
            print_info "  ZRAM_INTERACTIVE_PROMPT=\"yes\"    # Enable prompt"
            print_info "  ZRAM_DEFAULT_CHOICE=\"no\"         # Default if no input"
            print_info "  ZRAM_PROMPT_TIMEOUT=10            # Seconds to wait"

            return 0
        else
            print_error "Failed to enable interactive prompt mode"
            return 1
        fi
    else
        print_info "Interactive prompt mode not enabled."
        print_info "You will need to manually add 'zramroot' to your kernel parameters."
        return 1
    fi
}

# Install based on init system
if [ "$INIT_SYSTEM" = "initramfs-tools" ]; then
    print_info "Installing for initramfs-tools (Debian/Ubuntu)..."

    # Create directory structure
    print_info "Creating directory structure..."
    mkdir -p /usr/share/initramfs-tools/scripts/local-premount
    mkdir -p /usr/share/initramfs-tools/hooks
    mkdir -p /usr/share/initramfs-tools/conf.d

    # Add user modules to the hook script if provided
    if [ -n "$additional_modules" ]; then
        print_info "Adding custom modules to hook script..."
        # Create a temporary file with the modified content
        cat "initramfs-tools/hooks/zramroot" | sed "s/^EXTRA_MODULES=.*/EXTRA_MODULES=\"$additional_modules\"/" > /tmp/zramroot.modified
        mv /tmp/zramroot.modified initramfs-tools/hooks/zramroot
        chmod +x initramfs-tools/hooks/zramroot
    fi

    # Backup existing files
    backup_file "/usr/share/initramfs-tools/scripts/local"
    backup_file "/usr/share/initramfs-tools/conf.d/zramroot-config"
    backup_file "/etc/zramroot.conf"

    # Copy files
    print_info "Copying initramfs-tools files..."
    cp "initramfs-tools/scripts/local-premount/zramroot-boot" "/usr/share/initramfs-tools/scripts/local-premount/zramroot-boot"
    chmod +x "/usr/share/initramfs-tools/scripts/local-premount/zramroot-boot"

    cp "initramfs-tools/scripts/local" "/usr/share/initramfs-tools/scripts/local"
    chmod +x "/usr/share/initramfs-tools/scripts/local"

    cp "initramfs-tools/hooks/zramroot" "/usr/share/initramfs-tools/hooks/zramroot"
    chmod +x "/usr/share/initramfs-tools/hooks/zramroot"

    cp "initramfs-tools/conf.d/zramroot-config" "/usr/share/initramfs-tools/conf.d/zramroot-config"
    cp "initramfs-tools/conf.d/zramroot-config" "/etc/zramroot.conf"

elif [ "$INIT_SYSTEM" = "mkinitcpio" ]; then
    print_info "Installing for mkinitcpio (Arch Linux)..."

    # Create directory structure
    print_info "Creating directory structure..."
    mkdir -p /usr/lib/initcpio/hooks
    mkdir -p /usr/lib/initcpio/install

    # Backup existing files
    backup_file "/usr/lib/initcpio/hooks/zramroot"
    backup_file "/usr/lib/initcpio/install/zramroot"
    backup_file "/etc/zramroot.conf"

    # Copy files
    print_info "Copying mkinitcpio files..."
    cp "mkinitcpio/hooks/zramroot" "/usr/lib/initcpio/hooks/zramroot"
    chmod +x "/usr/lib/initcpio/hooks/zramroot"

    cp "mkinitcpio/install/zramroot" "/usr/lib/initcpio/install/zramroot"
    chmod +x "/usr/lib/initcpio/install/zramroot"

    cp "zramroot.conf" "/etc/zramroot.conf"

    print_success "mkinitcpio files installed successfully!"

    # Automatically configure mkinitcpio.conf
    print_info ""
    print_info "=== Configuring mkinitcpio.conf ==="

    MKINITCPIO_CONF="/etc/mkinitcpio.conf"

    if [ ! -f "$MKINITCPIO_CONF" ]; then
        print_error "mkinitcpio.conf not found at $MKINITCPIO_CONF"
        exit 1
    fi

    # Backup mkinitcpio.conf
    backup_file "$MKINITCPIO_CONF"

    # Check if zramroot is already in HOOKS
    if grep "^HOOKS=" "$MKINITCPIO_CONF" | grep -q "zramroot"; then
        print_warning "zramroot hook already present in HOOKS array"
    else
        print_info "Adding zramroot hook to HOOKS array..."

        # Add zramroot before filesystems in HOOKS array
        # This handles both cases: with and without spaces around 'filesystems'
        if grep "^HOOKS=" "$MKINITCPIO_CONF" | grep -q "filesystems"; then
            # Use sed to add zramroot before filesystems
            sed -i 's/\(HOOKS=([^)]*\)\<filesystems\>/\1zramroot filesystems/' "$MKINITCPIO_CONF"
            print_success "Added zramroot hook before filesystems"
        else
            print_warning "Could not find 'filesystems' in HOOKS array"
            print_info "Please manually add 'zramroot' to HOOKS in $MKINITCPIO_CONF"
            print_info "Example: HOOKS=(base udev autodetect modconf block zramroot filesystems keyboard fsck)"
        fi
    fi

    # Show the current HOOKS configuration
    print_info "Current HOOKS configuration:"
    grep "^HOOKS=" "$MKINITCPIO_CONF" | sed 's/^/  /'
    echo ""

    # Rebuild initramfs
    print_info "=== Rebuilding initramfs ==="
    print_warning "This may take a minute..."

    if mkinitcpio -P; then
        print_success "Initramfs rebuilt successfully!"
    else
        print_error "Failed to rebuild initramfs"
        print_info "You may need to run 'sudo mkinitcpio -P' manually"
        exit 1
    fi

    print_success "mkinitcpio configuration completed!"
fi

# Bootloader Configuration
echo ""
print_info "=== Bootloader Configuration ==="
print_info "ZRAMroot requires adding a kernel parameter to your bootloader."
print_info "You can either:"
print_info "  1. Let the script automatically configure a bootloader entry"
print_info "  2. Skip bootloader configuration and do it manually later"
echo ""

read -p "Would you like to configure a bootloader entry automatically? (y/n): " configure_bootloader

if [[ ! "$configure_bootloader" =~ ^[Yy]$ ]]; then
    print_info "Skipping bootloader configuration."
    print_warning "You'll need to manually add 'zramroot' to your kernel parameters."
    bootloader="skip"
else
    echo ""
    print_info "Bootloader configuration options:"
    print_info "  1. Auto-detect bootloader (recommended)"
    print_info "  2. Manually choose bootloader"
    echo ""
    
    while true; do
        read -p "Choose detection method (1-2): " detection_method
        case $detection_method in
            1)
                print_info "Auto-detecting bootloader..."
                break
                ;;
            2)
                print_info "Manual bootloader selection..."
                break
                ;;
            *)
                print_warning "Please enter 1 or 2"
                ;;
        esac
    done

    # Enhanced bootloader detection function
    detect_all_bootloaders() {
        local found_bootloaders=()
        
        # Check for GRUB
        if [ -f "/boot/grub/grub.cfg" ] && [ -d "/etc/grub.d" ]; then
            if command -v update-grub >/dev/null 2>&1 || command -v grub-mkconfig >/dev/null 2>&1; then
                found_bootloaders+=("grub")
            fi
        fi
        
        # Check for systemd-boot
        if [ -d "/boot/loader" ] && [ -f "/boot/loader/loader.conf" ]; then
            if command -v bootctl >/dev/null 2>&1; then
                found_bootloaders+=("systemd-boot")
            fi
        fi
        
        # Check for systemd-boot in EFI directory
        if [ -d "/boot/EFI/systemd" ] || [ -d "/boot/efi/systemd" ]; then
            if command -v bootctl >/dev/null 2>&1; then
                if [[ ! " ${found_bootloaders[@]} " =~ " systemd-boot " ]]; then
                    found_bootloaders+=("systemd-boot")
                fi
            fi
        fi
        
        # Check for extlinux/syslinux
        if [ -f "/boot/extlinux/extlinux.conf" ] || [ -f "/boot/syslinux/syslinux.cfg" ] || [ -f "/boot/syslinux.cfg" ]; then
            if command -v extlinux >/dev/null 2>&1 || command -v syslinux >/dev/null 2>&1; then
                found_bootloaders+=("extlinux")
            fi
        fi
        
        echo "${found_bootloaders[@]}"
    }

    if [ "$detection_method" = "1" ]; then
        # Auto-detection
        found_bootloaders=($(detect_all_bootloaders))
        
        if [ ${#found_bootloaders[@]} -eq 0 ]; then
            print_warning "No supported bootloaders detected automatically."
            echo ""
            print_warning "Supported bootloaders:"
            print_info "  - GRUB (requires /boot/grub/grub.cfg and update-grub command)"
            print_info "  - systemd-boot (requires /boot/loader/ and bootctl command)"
            print_info "  - extlinux/syslinux (requires config files and commands)"
            echo ""
            print_info "You have two options:"
            print_info "  1. Continue with manual bootloader configuration"
            print_info "  2. Enable interactive prompt mode (ask at boot time)"
            echo ""
            read -p "Continue with manual configuration? (y/n): " continue_manual
            if [[ ! "$continue_manual" =~ ^[Yy]$ ]]; then
                print_info "Installation cancelled by user."
                exit 0
            fi
            bootloader="manual"
            
        elif [ ${#found_bootloaders[@]} -eq 1 ]; then
            bootloader="${found_bootloaders[0]}"
            print_info "Detected bootloader: $bootloader"
            echo ""
            read -p "Use $bootloader for configuration? (y/n): " confirm_bootloader
            if [[ ! "$confirm_bootloader" =~ ^[Yy]$ ]]; then
                bootloader="manual"
                print_info "Will provide manual configuration instructions."
            fi
            
        else
            # Multiple bootloaders found
            echo ""
            print_info "Multiple bootloaders detected:"
            for i in "${!found_bootloaders[@]}"; do
                print_info "  $((i+1)). ${found_bootloaders[i]}"
            done
            print_info "  $((${#found_bootloaders[@]}+1)). Manual configuration"
            echo ""
            
            while true; do
                read -p "Which bootloader would you like to configure? (1-$((${#found_bootloaders[@]}+1))): " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $((${#found_bootloaders[@]}+1)) ]; then
                    if [ "$choice" -eq $((${#found_bootloaders[@]}+1)) ]; then
                        bootloader="manual"
                        print_info "Manual configuration selected."
                    else
                        bootloader="${found_bootloaders[$((choice-1))]}"
                        print_info "Selected bootloader: $bootloader"
                    fi
                    break
                else
                    print_warning "Please enter a number between 1 and $((${#found_bootloaders[@]}+1))"
                fi
            done
        fi
        
    else
        # Manual selection
        echo ""
        print_info "Available bootloader options:"
        print_info "  1. GRUB"
        print_info "  2. systemd-boot" 
        print_info "  3. extlinux/syslinux"
        print_info "  4. Manual configuration"
        echo ""
        
        while true; do
            read -p "Choose your bootloader (1-4): " manual_choice
            case $manual_choice in
                1)
                    bootloader="grub"
                    print_info "GRUB selected."
                    break
                    ;;
                2)
                    bootloader="systemd-boot"
                    print_info "systemd-boot selected."
                    break
                    ;;
                3)
                    bootloader="extlinux"
                    print_info "extlinux/syslinux selected."
                    break
                    ;;
                4)
                    bootloader="manual"
                    print_info "Manual configuration selected."
                    break
                    ;;
                *)
                    print_warning "Please enter 1, 2, 3, or 4"
                    ;;
            esac
        done
    fi
fi

# Configure bootloader based on detection
if [ "$bootloader" = "grub" ]; then
    print_info "Configuring GRUB..."

    # First, check if a ZRAMroot entry already exists in any grub.d file
    existing_zramroot_file=""
    for grub_file in /etc/grub.d/*_custom; do
        if [ -f "$grub_file" ] && grep -q "ZRAM Root Custom Entry" "$grub_file"; then
            existing_zramroot_file="$grub_file"
            print_info "Found existing ZRAMroot entry in $grub_file"
            break
        fi
    done

    # If we found an existing ZRAMroot entry, ask user what to do
    if [ -n "$existing_zramroot_file" ]; then
        print_warning "A ZRAMroot GRUB entry already exists in $existing_zramroot_file"
        echo ""
        read -p "Do you want to update the existing entry? (y/n): " update_existing
        
        if [[ "$update_existing" =~ ^[Yy]$ ]]; then
            grub_custom_file="$existing_zramroot_file"
            print_info "Will update existing ZRAMroot entry in $grub_custom_file"
        else
            # Find a new available custom file name
            custom_num=40
            grub_custom_file="/etc/grub.d/${custom_num}_custom"
            
            while [ -f "$grub_custom_file" ]; do
                print_info "File $grub_custom_file already exists, trying next number..."
                custom_num=$((custom_num + 1))
                grub_custom_file="/etc/grub.d/${custom_num}_custom"
            done
            
            print_info "Will create new GRUB custom file: $grub_custom_file"
        fi
    else
        # No existing ZRAMroot entry found, find an available custom file name
        custom_num=40
        grub_custom_file="/etc/grub.d/${custom_num}_custom"
        
        while [ -f "$grub_custom_file" ]; do
            print_info "File $grub_custom_file already exists, trying next number..."
            custom_num=$((custom_num + 1))
            grub_custom_file="/etc/grub.d/${custom_num}_custom"
        done
        
        print_info "Using GRUB custom file: $grub_custom_file"
    fi

    # Get root UUID
    root_uuid=$(grep -oP 'UUID=\K[a-f0-9-]+' /proc/cmdline 2>/dev/null || \
                grep -oP 'root=UUID=\K[a-f0-9-]+' /proc/cmdline 2>/dev/null || \
                awk '$2 == "/" {print $1}' /etc/fstab | grep -oP 'UUID=\K[a-f0-9-]+' 2>/dev/null || \
                blkid -s UUID -o value $(findmnt -no SOURCE /))

    if [ -z "$root_uuid" ]; then
        print_error "Could not determine root UUID. Please edit $grub_custom_file manually after installation."
        root_uuid="YOUR-ROOT-UUID-HERE"
    fi

    # --- Advanced Linux Distribution Detection ---
    print_info "Detecting Linux distribution..."

    # Initialize variables
    distro_id=""
    distro_name=""
    distro_version=""
    grub_class=""
    additional_modules=""

    # Method 1: Try /etc/os-release (most modern systems)
    if [ -f "/etc/os-release" ]; then
        . /etc/os-release
        distro_id="${ID}"
        distro_name="${NAME}"
        distro_version="${VERSION_ID}"
        print_info "Detected from /etc/os-release: $distro_name"
    fi

    # Method 2: Try lsb_release command
    if [ -z "$distro_id" ] && command -v lsb_release >/dev/null 2>&1; then
        distro_name=$(lsb_release -d 2>/dev/null | cut -f2)
        distro_id=$(lsb_release -i 2>/dev/null | cut -f2 | tr '[:upper:]' '[:lower:]')
        distro_version=$(lsb_release -r 2>/dev/null | cut -f2)
        print_info "Detected from lsb_release: $distro_name"
    fi

    # Method 3: Try legacy release files
    if [ -z "$distro_id" ]; then
        if [ -f "/etc/debian_version" ]; then
            if grep -qi ubuntu /etc/issue 2>/dev/null; then
                distro_id="ubuntu"
                distro_name="Ubuntu"
            else
                distro_id="debian"
                distro_name="Debian"
            fi
            distro_version=$(cat /etc/debian_version 2>/dev/null)
            print_info "Detected from /etc/debian_version: $distro_name"
        elif [ -f "/etc/redhat-release" ]; then
            if grep -qi fedora /etc/redhat-release; then
                distro_id="fedora"
                distro_name="Fedora"
            elif grep -qi centos /etc/redhat-release; then
                distro_id="centos"
                distro_name="CentOS"
            else
                distro_id="rhel"
                distro_name="Red Hat Enterprise Linux"
            fi
            distro_version=$(grep -oE '[0-9]+(\.[0-9]+)?' /etc/redhat-release | head -1)
            print_info "Detected from /etc/redhat-release: $distro_name"
        elif [ -f "/etc/arch-release" ]; then
            distro_id="arch"
            distro_name="Arch Linux"
            print_info "Detected Arch Linux"
        elif [ -f "/etc/opensuse-release" ]; then
            distro_id="opensuse"
            distro_name="openSUSE"
            distro_version=$(grep "VERSION" /etc/opensuse-release | cut -d= -f2 | tr -d '"')
            print_info "Detected openSUSE"
        fi
    fi

    # Set GRUB class and additional modules based on distribution
    case "$distro_id" in
        "ubuntu")
            grub_class="ubuntu"
            additional_modules="\tinsmod part_gpt\n\tinsmod ext2"
            ;;
        "debian")
            grub_class="debian"
            additional_modules="\tinsmod part_gpt\n\tinsmod ext2"
            ;;
        "fedora")
            grub_class="fedora"
            additional_modules="\tinsmod part_gpt\n\tinsmod ext2\n\tinsmod xfs"
            ;;
        "centos"|"rhel")
            grub_class="centos"
            additional_modules="\tinsmod part_gpt\n\tinsmod ext2\n\tinsmod xfs"
            ;;
        "arch"|"manjaro")
            grub_class="arch"
            additional_modules="\tinsmod part_gpt\n\tinsmod ext2"
            ;;
        "opensuse"|"suse")
            grub_class="opensuse"
            additional_modules="\tinsmod part_gpt\n\tinsmod ext2\n\tinsmod btrfs\n\tinsmod xfs"
            ;;
        *)
            # Generic Linux fallback
            grub_class="gnu-linux"
            additional_modules="\tinsmod part_gpt\n\tinsmod ext2"
            if [ -z "$distro_name" ]; then
                distro_name="Linux"
            fi
            ;;
    esac

    # Special handling for specific distributions
    case "$distro_id" in
    "fedora"|"centos"|"rhel")
        # Red Hat family might use different partition schemes and filesystems
        if [ -z "$kernel_path" ]; then
            # Try common Fedora/RHEL kernel paths
            if [ -f "/boot/vmlinuz-$(uname -r)" ]; then
                kernel_path="/boot/vmlinuz-$(uname -r)"
            elif [ -f "/boot/kernel-$(uname -r)" ]; then
                kernel_path="/boot/kernel-$(uname -r)"
            fi
        fi
        if [ -z "$initrd_path" ]; then
            if [ -f "/boot/initramfs-$(uname -r).img" ]; then
                initrd_path="/boot/initramfs-$(uname -r).img"
            fi
        fi
        ;;
    "arch"|"manjaro")
        # Arch Linux specific paths
        if [ -z "$kernel_path" ]; then
            if [ -f "/boot/vmlinuz-linux" ]; then
                kernel_path="/boot/vmlinuz-linux"
            fi
        fi
        if [ -z "$initrd_path" ]; then
            if [ -f "/boot/initramfs-linux.img" ]; then
                initrd_path="/boot/initramfs-linux.img"
            fi
        fi
        ;;
    "opensuse"|"suse")
        # openSUSE might have different naming conventions
        if [ -z "$kernel_path" ]; then
            if [ -f "/boot/vmlinuz-$(uname -r)-default" ]; then
                kernel_path="/boot/vmlinuz-$(uname -r)-default"
            fi
        fi
        if [ -z "$initrd_path" ]; then
            if [ -f "/boot/initrd-$(uname -r)-default" ]; then
                initrd_path="/boot/initrd-$(uname -r)-default"
            fi
        fi
        ;;
esac

print_info "Using GRUB class: $grub_class for $distro_name"

# Try to extract info from existing GRUB config
grub_config="/boot/grub/grub.cfg"
if [ -f "$grub_config" ]; then
    print_info "Analyzing existing GRUB configuration..."
    
    # Get current OS name from grub (but prefer our detected name)
    existing_os_name=$(grep -m1 -oP "menuentry '\K[^']*" "$grub_config" | grep -v "Memory test" | head -1)
    
    # Get kernel and initrd paths
    kernel_path=$(grep -m1 -oP '\tlinux\s+\K[^\s]+' "$grub_config" | head -1)
    # Get ALL initrd paths (microcode + initramfs), not just the first one
    initrd_path=$(grep -m1 -oP '\tinitrd\s+\K.*' "$grub_config" | head -1 | sed 's/[[:space:]]*$//')
    
    # Check for devicetree
    if grep -q "devicetree" "$grub_config"; then
        devicetree_path=$(grep -m1 -oP '\tdevicetree\s+\K[^\s]+' "$grub_config" | head -1)
    fi
    
    # Extract additional kernel parameters that might be needed
    kernel_params=$(grep -m1 -oP '\tlinux\s+[^\s]+\s+\K.*' "$grub_config" | head -1)
    
    print_info "Found existing kernel parameters: $kernel_params"
fi

# Use our detected name, fall back to existing name if detection failed
if [ -n "$distro_name" ]; then
    os_name="$distro_name"
elif [ -n "$existing_os_name" ]; then
    os_name="$existing_os_name"
else
    os_name="Linux"
fi

if [ -z "$kernel_path" ]; then
    kernel_path="/boot/vmlinuz"
fi

if [ -z "$initrd_path" ]; then
    initrd_path="/boot/initrd.img"
fi

# Create or update custom GRUB file
print_info "Creating custom GRUB entry with OS: $os_name, UUID: $root_uuid"

# If updating an existing file, preserve non-ZRAMroot content
if [ -n "$existing_zramroot_file" ] && [ "$grub_custom_file" = "$existing_zramroot_file" ]; then
    print_info "Updating existing ZRAMroot entry..."
    
    # Create temporary file with content before ZRAMroot section
    temp_file=$(mktemp)
    if grep -q "# --- ZRAM Root Custom Entry ---" "$grub_custom_file"; then
        # Extract everything before the ZRAMroot section
        sed '/# --- ZRAM Root Custom Entry ---/,$d' "$grub_custom_file" > "$temp_file"
    else
        # No ZRAMroot section found, keep entire file
        cp "$grub_custom_file" "$temp_file"
    fi
    
    # Start building the new file content
    cp "$temp_file" "$grub_custom_file"
    rm "$temp_file"
else
    # Creating new file
    cat > "$grub_custom_file" << 'EOF'
#!/bin/sh
exec tail -n +3 $0
# This file provides an easy way to add custom menu entries. Simply type the
# menu entries you want to add after this comment. Be careful not to change
# the 'exec tail' line above.

EOF
fi

    # Prepare kernel parameters - preserve important ones and add zramroot
    clean_kernel_params=""
    if [ -n "$kernel_params" ]; then
        # Remove root= parameter as we'll add our own, and remove ro/rw as we need rw
        clean_kernel_params=$(echo "$kernel_params" | sed -e 's/root=[^[:space:]]*//g' -e 's/\bro\b//g' -e 's/\brw\b//g' -e 's/[[:space:]]\+/ /g' -e 's/^[[:space:]]*//g' -e 's/[[:space:]]*$//g')
    fi

    # Build final kernel parameters
    final_kernel_params="root=UUID=${root_uuid} rw zramroot"
    if [ -n "$clean_kernel_params" ]; then
        final_kernel_params="$final_kernel_params $clean_kernel_params"
    fi

    print_info "Final kernel parameters: $final_kernel_params"

    # Display detection summary
    echo ""
    print_info "=== GRUB Entry Configuration Summary ==="
    print_info "Distribution: $distro_name ($distro_id)"
    print_info "GRUB Class: $grub_class"
    print_info "Kernel Path: $kernel_path"
    print_info "Initrd Path: $initrd_path"
    if [ -n "$devicetree_path" ]; then
        print_info "Device Tree: $devicetree_path"
    fi
    print_info "Root UUID: $root_uuid"
    echo ""

    # Add the ZRAMroot section with distribution-specific formatting
    cat >> "$grub_custom_file" << EOF
# --- ZRAM Root Custom Entry ---

menuentry '${os_name} (Load Root to ZRAM)' --class ${grub_class} --class gnu-linux --class gnu --class os {
	recordfail
	load_video
	gfxmode \$linux_gfx_mode
	insmod gzio
	if [ x\$grub_platform = xxen ]; then insmod xzio; insmod lzopio; fi
EOF

    # Add the additional modules with proper formatting
    echo -e "$additional_modules" >> "$grub_custom_file"

    # Continue with the rest of the entry
    cat >> "$grub_custom_file" << EOF
	search --no-floppy --fs-uuid --set=root ${root_uuid}
	linux	${kernel_path} ${final_kernel_params}
	initrd	${initrd_path}
EOF

    # Add devicetree line if it exists in current config
    if [ -n "$devicetree_path" ]; then
        echo "	devicetree	${devicetree_path}" >> "$grub_custom_file"
    fi

    # Finish the menuentry
    echo "}" >> "$grub_custom_file"
    echo "" >> "$grub_custom_file"
    echo "# --- END ZRAM Root Custom Entry ---" >> "$grub_custom_file"

    # Make the file executable
    chmod +x "$grub_custom_file"

    # Update GRUB configuration
    print_info "Updating GRUB configuration..."
    if ! update-grub; then
        print_error "Failed to update GRUB configuration."
        print_info "You may need to run 'update-grub' manually."
    fi

elif [ "$bootloader" = "systemd-boot" ]; then
    print_info "Configuring systemd-boot..."
    
    # Get root UUID for systemd-boot
    root_uuid=$(grep -oP 'UUID=\K[a-f0-9-]+' /proc/cmdline 2>/dev/null || \
                grep -oP 'root=UUID=\K[a-f0-9-]+' /proc/cmdline 2>/dev/null || \
                awk '$2 == "/" {print $1}' /etc/fstab | grep -oP 'UUID=\K[a-f0-9-]+' 2>/dev/null || \
                blkid -s UUID -o value $(findmnt -no SOURCE /))
    
    if [ -z "$root_uuid" ]; then
        print_error "Could not determine root UUID. Please configure systemd-boot manually after installation."
        root_uuid="YOUR-ROOT-UUID-HERE"
    fi
    
    # Detect kernel and initramfs for systemd-boot
    kernel_version=$(uname -r)
    if [ -f "/boot/vmlinuz-${kernel_version}" ]; then
        kernel_file="vmlinuz-${kernel_version}"
    elif [ -f "/boot/vmlinuz" ]; then
        kernel_file="vmlinuz"
    else
        print_error "Could not find kernel file in /boot/"
        kernel_file="vmlinuz-${kernel_version}"
    fi
    
    if [ -f "/boot/initrd.img-${kernel_version}" ]; then
        initrd_file="initrd.img-${kernel_version}"
    elif [ -f "/boot/initramfs-${kernel_version}.img" ]; then
        initrd_file="initramfs-${kernel_version}.img"
    elif [ -f "/boot/initrd.img" ]; then
        initrd_file="initrd.img"
    else
        print_error "Could not find initramfs file in /boot/"
        initrd_file="initrd.img-${kernel_version}"
    fi
    
    # Extract existing kernel parameters
    existing_kernel_params=""
    if command -v bootctl >/dev/null 2>&1; then
        # Try to get existing parameters from current boot entry
        current_entry=$(bootctl list 2>/dev/null | grep "default" | head -1 | awk '{print $2}')
        if [ -n "$current_entry" ] && [ -f "/boot/loader/entries/${current_entry}" ]; then
            existing_kernel_params=$(grep "^options" "/boot/loader/entries/${current_entry}" | sed 's/^options[[:space:]]*//')
        fi
    fi
    
    # Clean kernel parameters and add zramroot
    clean_kernel_params=""
    if [ -n "$existing_kernel_params" ]; then
        # Remove root= parameter as we'll add our own, and remove ro/rw as we need rw
        clean_kernel_params=$(echo "$existing_kernel_params" | sed -e 's/root=[^[:space:]]*//g' -e 's/\bro\b//g' -e 's/\brw\b//g' -e 's/[[:space:]]\+/ /g' -e 's/^[[:space:]]*//g' -e 's/[[:space:]]*$//g')
    fi
    
    # Build final kernel parameters
    final_kernel_params="root=UUID=${root_uuid} rw zramroot"
    if [ -n "$clean_kernel_params" ]; then
        final_kernel_params="$final_kernel_params $clean_kernel_params"
    fi
    
    # Create systemd-boot entry
    entry_file="/boot/loader/entries/zramroot.conf"
    
    print_info "Creating systemd-boot entry: $entry_file"
    print_info "Kernel: $kernel_file"
    print_info "Initrd: $initrd_file"
    print_info "Parameters: $final_kernel_params"
    
    # Check if entry already exists
    if [ -f "$entry_file" ]; then
        print_warning "ZRAMroot systemd-boot entry already exists at $entry_file"
        read -p "Do you want to update the existing entry? (y/n): " update_existing
        
        if [[ ! "$update_existing" =~ ^[Yy]$ ]]; then
            print_info "Skipping systemd-boot entry creation."
        else
            print_info "Updating existing systemd-boot entry..."
        fi
    fi
    
    if [ ! -f "$entry_file" ] || [[ "$update_existing" =~ ^[Yy]$ ]]; then
        # Get distribution name for title
        if [ -f "/etc/os-release" ]; then
            . /etc/os-release
            distro_name="${PRETTY_NAME:-${NAME:-Linux}}"
        else
            distro_name="Linux"
        fi
        
        cat > "$entry_file" << EOF
title   ${distro_name} (ZRAMroot)
version ${kernel_version}
linux   /${kernel_file}
initrd  /${initrd_file}
options ${final_kernel_params}
EOF
        
        print_info "Created systemd-boot entry at $entry_file"
    fi
    
elif [ "$bootloader" = "extlinux" ]; then
    print_info "Configuring extlinux/syslinux..."
    
    # Get root UUID for extlinux
    root_uuid=$(grep -oP 'UUID=\K[a-f0-9-]+' /proc/cmdline 2>/dev/null || \
                grep -oP 'root=UUID=\K[a-f0-9-]+' /proc/cmdline 2>/dev/null || \
                awk '$2 == "/" {print $1}' /etc/fstab | grep -oP 'UUID=\K[a-f0-9-]+' 2>/dev/null || \
                blkid -s UUID -o value $(findmnt -no SOURCE /))
    
    if [ -z "$root_uuid" ]; then
        print_error "Could not determine root UUID. Please configure extlinux manually after installation."
        root_uuid="YOUR-ROOT-UUID-HERE"
    fi
    
    # Find extlinux configuration file
    config_file=""
    if [ -f "/boot/extlinux/extlinux.conf" ]; then
        config_file="/boot/extlinux/extlinux.conf"
    elif [ -f "/boot/syslinux/syslinux.cfg" ]; then
        config_file="/boot/syslinux/syslinux.cfg"
    elif [ -f "/boot/syslinux.cfg" ]; then
        config_file="/boot/syslinux.cfg"
    else
        print_error "Could not find extlinux/syslinux configuration file."
        print_info "Expected locations:"
        print_info "  - /boot/extlinux/extlinux.conf"
        print_info "  - /boot/syslinux/syslinux.cfg" 
        print_info "  - /boot/syslinux.cfg"
        config_file="/boot/extlinux/extlinux.conf"
        print_warning "Will create new config at: $config_file"
    fi
    
    # Detect kernel and initramfs
    kernel_version=$(uname -r)
    if [ -f "/boot/vmlinuz-${kernel_version}" ]; then
        kernel_file="/vmlinuz-${kernel_version}"
    elif [ -f "/boot/vmlinuz" ]; then
        kernel_file="/vmlinuz"
    else
        print_error "Could not find kernel file in /boot/"
        kernel_file="/vmlinuz-${kernel_version}"
    fi
    
    if [ -f "/boot/initrd.img-${kernel_version}" ]; then
        initrd_file="/initrd.img-${kernel_version}"
    elif [ -f "/boot/initramfs-${kernel_version}.img" ]; then
        initrd_file="/initramfs-${kernel_version}.img"
    elif [ -f "/boot/initrd.img" ]; then
        initrd_file="/initrd.img"
    else
        print_error "Could not find initramfs file in /boot/"
        initrd_file="/initrd.img-${kernel_version}"
    fi
    
    # Extract existing kernel parameters if config exists
    existing_kernel_params=""
    if [ -f "$config_file" ]; then
        existing_kernel_params=$(grep -m1 "APPEND" "$config_file" | sed 's/.*APPEND[[:space:]]*//' | head -1)
    fi
    
    # Clean kernel parameters and add zramroot
    clean_kernel_params=""
    if [ -n "$existing_kernel_params" ]; then
        # Remove root= parameter as we'll add our own, and remove ro/rw as we need rw
        clean_kernel_params=$(echo "$existing_kernel_params" | sed -e 's/root=[^[:space:]]*//g' -e 's/\bro\b//g' -e 's/\brw\b//g' -e 's/[[:space:]]\+/ /g' -e 's/^[[:space:]]*//g' -e 's/[[:space:]]*$//g')
    fi
    
    # Build final kernel parameters
    final_kernel_params="root=UUID=${root_uuid} rw zramroot"
    if [ -n "$clean_kernel_params" ]; then
        final_kernel_params="$final_kernel_params $clean_kernel_params"
    fi
    
    print_info "Configuration file: $config_file"
    print_info "Kernel: $kernel_file"
    print_info "Initrd: $initrd_file"
    print_info "Parameters: $final_kernel_params"
    
    # Check if ZRAMroot entry already exists
    zramroot_exists=false
    if [ -f "$config_file" ] && grep -q "ZRAMroot" "$config_file"; then
        zramroot_exists=true
        print_warning "ZRAMroot entry already exists in $config_file"
        read -p "Do you want to update the existing entry? (y/n): " update_existing
        
        if [[ ! "$update_existing" =~ ^[Yy]$ ]]; then
            print_info "Skipping extlinux entry creation."
        fi
    fi
    
    if [ "$zramroot_exists" = false ] || [[ "$update_existing" =~ ^[Yy]$ ]]; then
        # Create directory if needed
        mkdir -p "$(dirname "$config_file")"
        
        # Get distribution name for label
        if [ -f "/etc/os-release" ]; then
            . /etc/os-release
            distro_name="${PRETTY_NAME:-${NAME:-Linux}}"
        else
            distro_name="Linux"
        fi
        
        if [ "$zramroot_exists" = true ]; then
            # Remove existing ZRAMroot entry
            sed -i '/# ZRAMroot Entry/,/^$/d' "$config_file"
            print_info "Removed existing ZRAMroot entry."
        fi
        
        # Add new ZRAMroot entry
        cat >> "$config_file" << EOF

# ZRAMroot Entry
LABEL zramroot
  MENU LABEL ${distro_name} (ZRAMroot)
  KERNEL ${kernel_file}
  APPEND ${final_kernel_params}
  INITRD ${initrd_file}

EOF
        
        print_info "Created extlinux entry in $config_file"
        
        # Update extlinux if command is available
        if command -v extlinux >/dev/null 2>&1; then
            print_info "Updating extlinux..."
            if ! extlinux --install "$(dirname "$config_file")" 2>/dev/null; then
                print_warning "Failed to update extlinux. You may need to run 'extlinux --install $(dirname "$config_file")' manually."
            fi
        elif command -v syslinux >/dev/null 2>&1; then
            print_info "Note: You may need to update your syslinux installation manually."
        fi
    fi
    
elif [ "$bootloader" = "manual" ]; then
    print_warning "Manual bootloader configuration required!"
    echo ""
    print_info "To use ZRAMroot with your bootloader, you need to:"
    print_info "1. Create a new boot entry that loads the same kernel and initramfs"
    print_info "2. Add 'zramroot' to the kernel command line parameters"
    echo ""

    # Get root UUID for manual configuration
    root_uuid=$(grep -oP 'UUID=\K[a-f0-9-]+' /proc/cmdline 2>/dev/null || \
                grep -oP 'root=UUID=\K[a-f0-9-]+' /proc/cmdline 2>/dev/null || \
                awk '$2 == "/" {print $1}' /etc/fstab | grep -oP 'UUID=\K[a-f0-9-]+' 2>/dev/null || \
                blkid -s UUID -o value $(findmnt -no SOURCE /))

    print_info "Your root UUID is: ${root_uuid}"
    print_info "Example kernel parameters: root=UUID=${root_uuid} rw zramroot"
    echo ""

    # Offer interactive prompt mode as an alternative
    enable_interactive_prompt

elif [ "$bootloader" = "skip" ]; then
    print_info "Bootloader configuration skipped as requested."

    # Get root UUID for informational purposes
    root_uuid=$(grep -oP 'UUID=\K[a-f0-9-]+' /proc/cmdline 2>/dev/null || \
                grep -oP 'root=UUID=\K[a-f0-9-]+' /proc/cmdline 2>/dev/null || \
                awk '$2 == "/" {print $1}' /etc/fstab | grep -oP 'UUID=\K[a-f0-9-]+' 2>/dev/null || \
                blkid -s UUID -o value $(findmnt -no SOURCE /))

    echo ""
    print_warning "To enable ZRAMroot, you'll need to manually add 'zramroot' to your kernel parameters."
    print_info "Your root UUID is: ${root_uuid}"
    print_info "Example kernel parameters: root=UUID=${root_uuid} rw zramroot"
    echo ""

    # Offer interactive prompt mode as an alternative
    enable_interactive_prompt

fi

# Update initramfs/initcpio
if [ "$INIT_SYSTEM" = "initramfs-tools" ]; then
    print_info "Updating initramfs..."
    if ! update-initramfs -u -k all; then
        print_error "Failed to update initramfs."
        print_info "You may need to run 'update-initramfs -u -k all' manually."
    fi
fi

print_header
print_success "ZRAMroot installation completed!"
echo ""

if [ "$INIT_SYSTEM" = "initramfs-tools" ]; then
    # Display bootloader-specific success messages
    case "$bootloader" in
        "grub")
            print_info "A new GRUB menu entry has been added: '${os_name} (Load Root to ZRAM)'"
            print_info "You can select this entry at boot time to use ZRAMroot."
            ;;
        "systemd-boot")
            print_info "A new systemd-boot entry has been added: '${distro_name} (ZRAMroot)'"
            print_info "You can select this entry at boot time to use ZRAMroot."
            ;;
        "extlinux")
            print_info "A new extlinux/syslinux entry has been added: '${distro_name} (ZRAMroot)'"
            print_info "You can select this entry at boot time to use ZRAMroot."
            ;;
        "manual")
            print_warning "Manual bootloader configuration is required!"
            print_info "Please create a boot entry with the 'zramroot' kernel parameter."
            ;;
        "skip")
            print_info "Bootloader configuration was skipped."
            print_warning "Remember to manually add 'zramroot' to your kernel parameters when ready."
            ;;
    esac
    echo ""
    print_info "Configuration file is located at: /etc/zramroot.conf"
    print_info "You can edit this file to change ZRAMroot settings."
    echo ""
    print_warning "Remember that after modifying the configuration, you need to update the initramfs:"
    print_info "  sudo update-initramfs -u -k all"
fi

echo ""
print_info "Press any key to exit..."
read -n 1
exit 0
