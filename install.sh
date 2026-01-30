#!/bin/bash
# zramroot Installation Script
# This script installs zramroot components and configures your system to use it

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
    echo "                  zramroot Installation                     "
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

    # Check for dracut (Fedora, RHEL, Qubes OS, openSUSE)
    if command -v dracut >/dev/null 2>&1 && [ -d "/usr/lib/dracut" ]; then
        print_info "Detected: Fedora/RHEL/Qubes OS (dracut)" >&2
        echo "dracut"
        return 0
    fi

    # Unknown init system
    print_error "Could not detect a supported init system" >&2
    print_info "Supported systems:" >&2
    print_info "  - Debian/Ubuntu (initramfs-tools)" >&2
    print_info "  - Arch Linux/Artix/Manjaro (mkinitcpio)" >&2
    print_info "  - Fedora/RHEL/Qubes OS (dracut)" >&2
    echo "unknown"
    return 1
}

INIT_SYSTEM=$(detect_init_system)

if [ "$INIT_SYSTEM" = "unsupported" ] || [ "$INIT_SYSTEM" = "unknown" ]; then
    print_error "Cannot continue installation on unsupported system"
    exit 1
fi

# --- Load configuration from zramroot.conf ---
# This allows user customizations to take effect during install
TRIGGER_PARAMETER="zramroot"  # Default value
ZRAM_FS_TYPE="ext4"           # Default filesystem type
CONFIG_FILE="zramroot.conf"   # Local config in current directory

if [ -f "$CONFIG_FILE" ]; then
    # Extract TRIGGER_PARAMETER from config file
    trigger_setting=$(grep "^TRIGGER_PARAMETER=" "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2)
    if [ -n "$trigger_setting" ]; then
        TRIGGER_PARAMETER="$trigger_setting"
        print_info "Using custom trigger parameter from config: ${TRIGGER_PARAMETER}"
    fi

    # Extract ZRAM_FS_TYPE from config file
    fs_type_setting=$(grep "^ZRAM_FS_TYPE=" "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2)
    if [ -n "$fs_type_setting" ]; then
        ZRAM_FS_TYPE="$fs_type_setting"
        print_info "Using filesystem type from config: ${ZRAM_FS_TYPE}"
    fi
fi

print_header

# Dependency checking function
check_dependencies() {
    print_info "=== Checking System Dependencies ==="
    echo ""

    # Core required binaries (from zramroot hook script copy_bin_list)
    local core_bins="busybox sh mount umount mkdir rmdir echo cat grep sed df awk rsync cp touch date \
                     mountpoint zramctl lsmod modprobe fsck blkid udevadm fuser find tail head ls sync"

    # Filesystem tools - based on configured ZRAM_FS_TYPE
    local fs_bins="mkfs.ext4 fsck.ext4"  # ext4 always included as fallback
    case "${ZRAM_FS_TYPE}" in
        btrfs)
            fs_bins="$fs_bins mkfs.btrfs btrfs"
            print_info "Including btrfs tools (ZRAM_FS_TYPE=${ZRAM_FS_TYPE})"
            ;;
        xfs)
            fs_bins="$fs_bins mkfs.xfs xfs_repair"
            print_info "Including xfs tools (ZRAM_FS_TYPE=${ZRAM_FS_TYPE})"
            ;;
    esac

    # Additional binaries used in zramroot-boot script
    local boot_bins="cut du kill mkfs mkswap nproc printf rm sort sleep timeout wait wc"

    # System utilities that may not be in core but are needed
    local util_bins="seq"

    # Optional binaries (for different filesystems) - only checked if LVM detected
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
        qubes)
            print_info "For Qubes systems, run:"
            echo "    sudo qubes-dom0-update --action=install ${packages[*]}"
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
print_warning "zramroot might make your installation unbootable if not configured correctly."
print_warning "This script will:"

if [ "$INIT_SYSTEM" = "initramfs-tools" ]; then
    print_info "  • Replace /usr/share/initramfs-tools/scripts/local with zramroot version"
    print_info "  • Install zramroot hooks and configuration files"
    print_info "  • Optionally configure a bootloader entry (GRUB, systemd-boot, or extlinux)"
    print_info "  • Rebuild your initramfs to include zramroot support"
elif [ "$INIT_SYSTEM" = "mkinitcpio" ]; then
    print_info "  • Install zramroot hooks to /usr/lib/initcpio/"
    print_info "  • Install configuration file to /etc/zramroot.conf"
    print_info "  • Provide instructions for manual mkinitcpio.conf configuration"
elif [ "$INIT_SYSTEM" = "dracut" ]; then
    print_info "  • Install zramroot dracut module to an auto-detected /usr/lib/dracut/modules.d/XXzramroot/"
    print_info "  • Install configuration file to /etc/zramroot.conf"
    print_info "  • Rebuild initramfs with dracut --force --regenerate-all"
    print_info "  • Optionally configure a GRUB2 bootloader entry"
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
        "initramfs-tools/scripts/local-bottom/zramroot-final"
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
elif [ "$INIT_SYSTEM" = "dracut" ]; then
    FILES=(
        "dracut/zramroot/module-setup.sh"
        "dracut/zramroot/zramroot-mount.sh"
        "dracut/zramroot/zramroot-finalize.sh"
        "dracut/rootfs-block/mount-root.sh"
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
        print_info "  initramfs-tools/scripts/local-bottom/zramroot-final"
        print_info "  initramfs-tools/conf.d/zramroot-config"
    elif [ "$INIT_SYSTEM" = "mkinitcpio" ]; then
        print_info "  mkinitcpio/hooks/zramroot"
        print_info "  mkinitcpio/install/zramroot"
        print_info "  zramroot.conf"
    elif [ "$INIT_SYSTEM" = "dracut" ]; then
        print_info "  dracut/zramroot/module-setup.sh"
        print_info "  dracut/zramroot/zramroot-mount.sh"
        print_info "  dracut/zramroot/zramroot-finalize.sh"
        print_info "  dracut/rootfs-block/mount-root.sh"
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
    print_info "Skipping additional module selection (not applicable for mkinitcpio and dracut)"
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

# Install based on init system
if [ "$INIT_SYSTEM" = "initramfs-tools" ]; then
    print_info "Installing for initramfs-tools (Debian/Ubuntu)..."

    # Create directory structure
    print_info "Creating directory structure..."
    mkdir -p /usr/share/initramfs-tools/scripts/local-premount
    mkdir -p /usr/share/initramfs-tools/scripts/local-bottom
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

    cp "initramfs-tools/scripts/local-bottom/zramroot-final" "/usr/share/initramfs-tools/scripts/local-bottom/zramroot-final"
    chmod +x "/usr/share/initramfs-tools/scripts/local-bottom/zramroot-final"

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

elif [ "$INIT_SYSTEM" = "dracut" ]; then
    print_info "Installing for dracut (Fedora/RHEL/Qubes OS)..."

    DRACUT_MODULES_DIR="/usr/lib/dracut/modules.d"

    # Determine a priority that is after any crypt module and before any fstab/filesystem module
    get_dracut_zramroot_priority() {
        local max_crypt=0
        local min_post=999
        local base prefix name

        for d in "${DRACUT_MODULES_DIR}"/*; do
            [ -d "$d" ] || continue
            base=$(basename "$d")
            prefix=$(echo "$base" | sed -n 's/^\([0-9][0-9]*\).*/\1/p')
            [ -n "$prefix" ] || continue
            name=${base#${prefix}}

            case "$name" in
                *crypt*)
                    if [ "$prefix" -gt "$max_crypt" ]; then
                        max_crypt="$prefix"
                    fi
                    ;;
            esac

            case "$name" in
                *fstab*|*fs-lib*|*rootfs*|*filesystem*|*filesystems*)
                    if [ "$prefix" -lt "$min_post" ]; then
                        min_post="$prefix"
                    fi
                    ;;
            esac
        done

        local target=94
        if [ "$max_crypt" -gt 0 ] && [ "$min_post" -lt 999 ]; then
            target=$((max_crypt + 1))
            if [ "$target" -ge "$min_post" ]; then
                target=$((min_post - 1))
            fi
        elif [ "$max_crypt" -gt 0 ]; then
            target=$((max_crypt + 1))
        elif [ "$min_post" -lt 999 ]; then
            target=$((min_post - 1))
        fi

        if [ "$target" -lt 1 ]; then
            target=94
        fi

        echo "$target"
    }

    ZRAMROOT_PRIORITY=$(get_dracut_zramroot_priority)
    ZRAMROOT_MODULE_DIR="${DRACUT_MODULES_DIR}/${ZRAMROOT_PRIORITY}zramroot"

    # Find existing rootfs-block module directory
    get_rootfs_block_dir() {
        for d in "${DRACUT_MODULES_DIR}"/*rootfs-block; do
            if [ -d "$d" ] && [ -f "$d/mount-root.sh" ]; then
                echo "$d"
                return 0
            fi
        done
        echo ""
        return 1
    }

    ROOTFS_BLOCK_DIR=$(get_rootfs_block_dir)
    if [ -z "$ROOTFS_BLOCK_DIR" ]; then
        print_error "Could not find rootfs-block module directory in ${DRACUT_MODULES_DIR}"
        print_error "Expected to find a directory like ${DRACUT_MODULES_DIR}/95rootfs-block/"
        exit 1
    fi
    print_info "Found rootfs-block module at: ${ROOTFS_BLOCK_DIR}"

    # Create directory structure
    print_info "Creating directory structure..."
    print_info "Using dracut zramroot module priority: ${ZRAMROOT_PRIORITY} (auto-detected)"
    mkdir -p "${ZRAMROOT_MODULE_DIR}"

    # Clean up legacy zramroot module directories to avoid conflicts
    for d in "${DRACUT_MODULES_DIR}"/*zramroot; do
        [ -d "$d" ] || continue
        if [ "$d" != "${ZRAMROOT_MODULE_DIR}" ]; then
            print_warning "Removing legacy zramroot module directory: $d"
            rm -rf "$d"
        fi
    done

    # Backup existing files
    backup_file "${ZRAMROOT_MODULE_DIR}/module-setup.sh"
    backup_file "${ZRAMROOT_MODULE_DIR}/zramroot-mount.sh"
    backup_file "${ZRAMROOT_MODULE_DIR}/zramroot-finalize.sh"
    backup_file "${ROOTFS_BLOCK_DIR}/mount-root.sh"
    backup_file "/etc/zramroot.conf"

    # Copy zramroot module files
    print_info "Copying zramroot module files..."
    cp "dracut/zramroot/module-setup.sh" "${ZRAMROOT_MODULE_DIR}/module-setup.sh"
    chmod +x "${ZRAMROOT_MODULE_DIR}/module-setup.sh"

    cp "dracut/zramroot/zramroot-mount.sh" "${ZRAMROOT_MODULE_DIR}/zramroot-mount.sh"
    chmod +x "${ZRAMROOT_MODULE_DIR}/zramroot-mount.sh"

    cp "dracut/zramroot/zramroot-finalize.sh" "${ZRAMROOT_MODULE_DIR}/zramroot-finalize.sh"
    chmod +x "${ZRAMROOT_MODULE_DIR}/zramroot-finalize.sh"

    # Replace rootfs-block mount-root.sh with our modified version
    print_info "Installing modified mount-root.sh to ${ROOTFS_BLOCK_DIR}..."
    cp "dracut/rootfs-block/mount-root.sh" "${ROOTFS_BLOCK_DIR}/mount-root.sh"
    chmod +x "${ROOTFS_BLOCK_DIR}/mount-root.sh"

    cp "zramroot.conf" "/etc/zramroot.conf"

    # Ensure zram driver is included in initramfs even in hostonly mode
    print_info "Configuring dracut to include zram driver..."
    cat > /etc/dracut.conf.d/zramroot.conf <<'EOF'
add_drivers+=" zram "
EOF

    print_success "Dracut module files installed successfully!"

    # Rebuild initramfs
    print_info ""
    print_info "=== Rebuilding initramfs with dracut ==="
    print_warning "This may take a minute..."

    # Detect if this is Qubes OS
    IS_QUBES=0
    if [ -f "/etc/qubes-release" ] || command -v qubes-dom0-update >/dev/null 2>&1; then
        IS_QUBES=1
        print_info "Detected Qubes OS Dom0"
    fi

    # Rebuild initramfs for all kernels
    if dracut --force --regenerate-all; then
        print_success "Initramfs rebuilt successfully!"

        # Verify module was included
        print_info "Verifying zramroot module inclusion..."
        if lsinitrd 2>/dev/null | grep -q "zramroot"; then
            print_success "zramroot module successfully included in initramfs"
        else
            print_warning "Could not verify module inclusion (lsinitrd may not be available)"
            print_info "You can verify manually with: lsinitrd | grep zramroot"
        fi
    else
        print_error "Failed to rebuild initramfs"
        print_info "You may need to run 'sudo dracut --force --regenerate-all' manually"
        exit 1
    fi

    print_success "Dracut configuration completed!"

    # Qubes-specific recommendations
    if [ $IS_QUBES -eq 1 ]; then
        echo ""
        print_info "=== Qubes OS Specific Recommendations ==="
        print_warning "Qubes Dom0 only sees its assigned RAM. zramroot will use Dom0's memory limit, not total system RAM."
        print_info "If zramroot reports insufficient RAM, increase Dom0 memory in Qubes settings (e.g., dom0_mem) or set ZRAM_SIZE_MiB manually."
        print_info "For Dom0 in Qubes OS, consider adding to /etc/zramroot.conf:"
        print_info "  ZRAM_MOUNT_ON_DISK=\"/var/lib/qubes\""
        print_info "  ZRAM_PHYSICAL_ROOT_OPTS=\"rw\""
        print_info "  ZRAM_EXCLUDE_PATTERNS=\"/var/lib/qubes/appvms/* /var/lib/qubes/vm-templates/*\""
        print_info "  ZRAM_ALGO=\"zstd\""
        print_info "  RAM_MIN_FREE_MiB=2048"
        print_info "  DEBUG_MODE=\"yes\"  # Recommended for first boot"
        echo ""
    fi
fi

# Bootloader Configuration
echo ""
print_info "=== Bootloader Configuration ==="
print_info "${TRIGGER_PARAMETER} requires adding a kernel parameter to your bootloader."
print_info "You can either:"
print_info "  1. Let the script automatically configure a bootloader entry"
print_info "  2. Skip bootloader configuration and do it manually later"
echo ""

read -p "Would you like to configure a bootloader entry automatically? (y/n): " configure_bootloader

if [[ ! "$configure_bootloader" =~ ^[Yy]$ ]]; then
    print_info "Skipping bootloader configuration."
    print_warning "You'll need to manually add '${TRIGGER_PARAMETER}' to your kernel parameters."
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

        # Check for GRUB (both GRUB and GRUB2)
        # GRUB can be in multiple locations: /boot/grub/, /boot/grub2/, or /boot/efi/EFI/*/
        grub_detected=0

        # Check for GRUB config files
        if [ -f "/boot/grub/grub.cfg" ] || [ -f "/boot/grub2/grub.cfg" ] || \
           [ -f "/boot/efi/EFI/qubes/grub.cfg" ] || [ -f "/boot/efi/EFI/fedora/grub.cfg" ] || \
           [ -f "/boot/efi/EFI/centos/grub.cfg" ] || [ -f "/boot/efi/EFI/redhat/grub.cfg" ]; then
            grub_detected=1
        fi

        # Also check if /etc/grub.d/ exists (common for all GRUB installations)
        if [ -d "/etc/grub.d" ]; then
            grub_detected=1
        fi

        # Verify GRUB commands are available
        if [ $grub_detected -eq 1 ]; then
            if command -v update-grub >/dev/null 2>&1 || \
               command -v grub-mkconfig >/dev/null 2>&1 || \
               command -v grub2-mkconfig >/dev/null 2>&1; then
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
            print_info "  - GRUB/GRUB2 (requires /etc/grub.d/ and grub-mkconfig/grub2-mkconfig)"
            print_info "  - systemd-boot (requires /boot/loader/ and bootctl command)"
            print_info "  - extlinux/syslinux (requires config files and commands)"
            echo ""
            print_info "Note: For GRUB2 systems (Fedora/RHEL/Qubes), the script looks for:"
            print_info "  - /boot/grub2/grub.cfg or /boot/efi/EFI/qubes/grub.cfg"
            print_info "  - /etc/grub.d/ directory"
            print_info "  - grub2-mkconfig command"
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

    # Check if 40_zramroot already exists
    existing_zramroot_file=""
    if [ -f "/etc/grub.d/40_zramroot" ]; then
        existing_zramroot_file="/etc/grub.d/40_zramroot"
        print_info "Found existing ${TRIGGER_PARAMETER} entry in $existing_zramroot_file"
    fi

    # If we found an existing zramroot entry, ask user what to do
    if [ -n "$existing_zramroot_file" ]; then
        print_warning "A ${TRIGGER_PARAMETER} GRUB entry already exists in $existing_zramroot_file"
        echo ""
        read -p "Do you want to update the existing entry? (y/n): " update_existing
        
        if [[ "$update_existing" =~ ^[Yy]$ ]]; then
            grub_custom_file="$existing_zramroot_file"
            print_info "Will update existing ${TRIGGER_PARAMETER} entry in $grub_custom_file"
        else
            grub_custom_file="/etc/grub.d/40_zramroot"
            print_info "Will create new GRUB custom file: $grub_custom_file"
        fi
    else
        # No existing zramroot entry found, use 40_zramroot
        grub_custom_file="/etc/grub.d/40_zramroot"

        if [ -f "$grub_custom_file" ]; then
            print_warning "File $grub_custom_file already exists"
            read -p "Overwrite it? (y/n): " overwrite
            if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
                print_error "Installation cancelled"
                exit 1
            fi
        fi

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

    # Check for Qubes OS first (special handling needed for Xen)
    IS_QUBES_GRUB=0
    if [ -f "/etc/qubes-release" ]; then
        IS_QUBES_GRUB=1
        distro_id="qubes"
        distro_name="Qubes OS"
        distro_version=$(cat /etc/qubes-release | grep -oE 'R[0-9.]+')
        print_info "Detected Qubes OS (Xen-based system)"
    fi

    # Method 1: Try /etc/os-release (most modern systems)
    if [ -f "/etc/os-release" ] && [ $IS_QUBES_GRUB -eq 0 ]; then
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
        "qubes")
            grub_class="qubes"
            additional_modules="\tinsmod part_gpt\n\tinsmod ext2"
            # Qubes uses Xen hypervisor - will need special GRUB entry format
            ;;
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
            additional_modules="\tinsmod part_gpt\n\tinsmod xfs"
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

# Find the actual GRUB config file
grub_config=""
for cfg in /boot/efi/EFI/qubes/grub.cfg /boot/grub2/grub.cfg /boot/grub/grub.cfg /boot/efi/EFI/fedora/grub.cfg /boot/efi/EFI/centos/grub.cfg /boot/efi/EFI/redhat/grub.cfg; do
    if [ -f "$cfg" ] && [ -r "$cfg" ]; then
        grub_config="$cfg"
        print_info "Found GRUB config: $grub_config"
        break
    fi
done

if [ -n "$grub_config" ]; then
    print_info "Analyzing existing GRUB configuration..."

    # Detect if this is a Xen-based entry (Qubes OS)
    GRUB_ENTRY_TYPE="linux"
    if grep -q "multiboot2.*xen" "$grub_config"; then
        GRUB_ENTRY_TYPE="xen"
        print_info "Detected Xen-based GRUB entries (Qubes OS)"
    fi

    if [ "$GRUB_ENTRY_TYPE" = "xen" ]; then
        # Extract Xen-based entry
        print_info "Extracting existing Xen menuentry..."
        EXISTING_XEN_ENTRY=$(awk '/menuentry.*Qubes.*Xen/{p=1} p{print} /^}$/ && p{exit}' "$grub_config")

        if [ -n "$EXISTING_XEN_ENTRY" ]; then
            print_info "Found Xen entry, will create modified version with ${TRIGGER_PARAMETER}"
        else
            print_warning "Could not extract Xen entry, will use template"
        fi
    else
        # Standard Linux entry - extract paths
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

# If updating an existing file, preserve non-zramroot content
if [ -n "$existing_zramroot_file" ] && [ "$grub_custom_file" = "$existing_zramroot_file" ]; then
    print_info "Updating existing ${TRIGGER_PARAMETER} entry..."

    # Create temporary file with content before zramroot section
    temp_file=$(mktemp)
    if grep -q "# --- zramroot" "$grub_custom_file"; then
        # Extract everything before the zramroot section
        sed '/# --- zramroot/,$d' "$grub_custom_file" > "$temp_file"
    else
        # No zramroot section found, keep entire file
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

    # Prepare kernel parameters - preserve important ones and add trigger parameter
    clean_kernel_params=""
    if [ -n "$kernel_params" ]; then
        # Remove root= parameter as we'll add our own, and remove ro/rw as we need rw
        clean_kernel_params=$(echo "$kernel_params" | sed -e 's/root=[^[:space:]]*//g' -e 's/\bro\b//g' -e 's/\brw\b//g' -e 's/[[:space:]]\+/ /g' -e 's/^[[:space:]]*//g' -e 's/[[:space:]]*$//g')
    fi

    # Build final kernel parameters
    final_kernel_params="root=UUID=${root_uuid} rw ${TRIGGER_PARAMETER}"
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

    # Copy the first menuentry from grub.cfg and add trigger parameter
    if [ -n "$grub_config" ] && [ -f "$grub_config" ]; then
        print_info "Extracting first boot entry from $grub_config..."

        # Extract the entire first menuentry
        FIRST_ENTRY=$(awk '/^menuentry /{p=1} p{print} /^}$/ && p{exit}' "$grub_config")

        if [ -n "$FIRST_ENTRY" ]; then
            # Change the title
            MODIFIED_ENTRY=$(echo "$FIRST_ENTRY" | sed "s/menuentry '[^']*'/menuentry '${TRIGGER_PARAMETER}'/")

            # Add trigger parameter to kernel line (works for both 'linux' and 'module2' commands)
            MODIFIED_ENTRY=$(echo "$MODIFIED_ENTRY" | sed "/\(linux\|module2\).*vmlinuz/s/vmlinuz[^ ]*/& ${TRIGGER_PARAMETER}/")

            # --- Qubes OS: Dom0 Memory Adjustment ---
            # Check if this is Qubes OS by looking for dom0_mem parameter
            if echo "$MODIFIED_ENTRY" | grep -q "dom0_mem"; then
                # Extract current max memory setting
                current_dom0_max=$(echo "$MODIFIED_ENTRY" | grep -o "dom0_mem=[^[:space:]]*" | grep -o "max:[0-9]*" | cut -d: -f2)
                
                # If cannot find max: syntax, try just simple integer (rare but possible)
                if [ -z "$current_dom0_max" ]; then
                    current_dom0_max=$(echo "$MODIFIED_ENTRY" | grep -o "dom0_mem=[0-9]*[kMGT]*" | sed 's/dom0_mem=//')
                fi

                if [ -n "$current_dom0_max" ]; then
                    echo ""
                    print_info "Qubes OS detected: dom0_mem configuration found."
                    print_info "Current dom0 memory limit: ${current_dom0_max}MB"
                    print_warning "${TRIGGER_PARAMETER} loads the entire root filesystem into RAM."
                    print_warning "Standard Qubes dom0 limits (often 4096MB) may be insufficient."
                    
                    read -p "Would you like to increase dom0 memory for the ${TRIGGER_PARAMETER} entry? (Recommended: 8192) (y/n): " increase_mem
                    
                    if [[ "$increase_mem" =~ ^[Yy]$ ]]; then
                        read -p "Enter new max memory in MB (default: 8192): " new_mem
                        if [ -z "$new_mem" ]; then
                            new_mem=8192
                        fi
                        
                        if [[ "$new_mem" =~ ^[0-9]+$ ]]; then
                            print_info "Updating dom0_mem to max:${new_mem}M for ${TRIGGER_PARAMETER} entry..."
                            # Replace dom0_mem=... with new value
                            # This handles the complex multiboot/module syntax of Xen/Qubes
                            # And handles cases with multiple dom0_mem parameters (e.g. min/max split)
                            MODIFIED_ENTRY=$(echo "$MODIFIED_ENTRY" | sed "s/dom0_mem=[^[:space:]]*/__DOM0_MEM_PLACEHOLDER__/")
                            MODIFIED_ENTRY=$(echo "$MODIFIED_ENTRY" | sed "s/dom0_mem=[^[:space:]]*//g")
                            MODIFIED_ENTRY=$(echo "$MODIFIED_ENTRY" | sed "s/__DOM0_MEM_PLACEHOLDER__/dom0_mem=min:1024M,max:${new_mem}M/")
                        else
                            print_error "Invalid number, skipping memory adjustment."
                        fi
                    fi
                fi
            fi
            # --- End Qubes OS Memory Adjustment ---

            # Write the custom entry
            cat > "$grub_custom_file" << 'HEADER'
#!/bin/sh
exec tail -n +3 $0
# This file provides an easy way to add custom menu entries.
# Simply type the menu entries you want to add after this comment.

HEADER

            cat >> "$grub_custom_file" << EOF
# --- zramroot Boot Entry ---
# Auto-generated by install.sh on $(date)

$MODIFIED_ENTRY

# --- END zramroot Entry ---
EOF

            chmod +x "$grub_custom_file"

            print_success "Created GRUB entry in $grub_custom_file"

            # Verify trigger parameter was added
            if grep -q "${TRIGGER_PARAMETER}" "$grub_custom_file"; then
                print_success "✓ ${TRIGGER_PARAMETER} parameter added"
            else
                print_warning "Could not add ${TRIGGER_PARAMETER} parameter automatically"
                print_info "Please manually add '${TRIGGER_PARAMETER}' to the kernel line in $grub_custom_file"
            fi
        else
            print_error "Could not extract menuentry from $grub_config"
            print_info "Please manually create a GRUB entry in $grub_custom_file"
        fi
    else
        print_error "Could not find GRUB config file"
        print_info "Please manually create a GRUB entry in /etc/grub.d/40_zramroot"
    fi

    # Make the file executable
    chmod +x "$grub_custom_file"

    # Update GRUB configuration
    print_info "Updating GRUB configuration..."

    # Try update-grub first (Debian/Ubuntu)
    if command -v update-grub >/dev/null 2>&1; then
        if ! update-grub; then
            print_error "Failed to update GRUB configuration."
            print_info "You may need to run 'update-grub' manually."
        fi
    # Try grub2-mkconfig (Fedora/RHEL/Qubes OS)
    elif command -v grub2-mkconfig >/dev/null 2>&1; then
        # For RHEL-based systems, we may need to update multiple configs
        # Detect all possible GRUB config locations
        grub_configs=()

        # Check EFI locations first (these are usually the ones actually used for EFI boot)
        if [ -f "/boot/efi/EFI/qubes/grub.cfg" ]; then
            grub_configs+=("/boot/efi/EFI/qubes/grub.cfg")
        fi
        if [ -f "/boot/efi/EFI/fedora/grub.cfg" ]; then
            grub_configs+=("/boot/efi/EFI/fedora/grub.cfg")
        fi
        if [ -f "/boot/efi/EFI/centos/grub.cfg" ]; then
            grub_configs+=("/boot/efi/EFI/centos/grub.cfg")
        fi
        if [ -f "/boot/efi/EFI/redhat/grub.cfg" ]; then
            grub_configs+=("/boot/efi/EFI/redhat/grub.cfg")
        fi

        # Check /boot locations
        if [ -f "/boot/grub2/grub.cfg" ]; then
            grub_configs+=("/boot/grub2/grub.cfg")
        fi
        # Some systems have grub.cfg in /boot/grub/ even with grub2
        if [ -f "/boot/grub/grub.cfg" ]; then
            grub_configs+=("/boot/grub/grub.cfg")
        fi

        if [ ${#grub_configs[@]} -eq 0 ]; then
            print_error "Could not find any GRUB2 config files"
            print_info "Please run 'grub2-mkconfig' manually to update your GRUB configuration"
        else
            print_info "Found ${#grub_configs[@]} GRUB config file(s) to update:"
            for cfg in "${grub_configs[@]}"; do
                print_info "  - $cfg"
            done
            echo ""

            # Update each config file
            for grub_cfg in "${grub_configs[@]}"; do
                print_info "Generating GRUB config at: $grub_cfg"
                if grub2-mkconfig -o "$grub_cfg"; then
                    print_success "Successfully updated: $grub_cfg"
                else
                    print_error "Failed to update: $grub_cfg"
                    print_info "You may need to run 'sudo grub2-mkconfig -o $grub_cfg' manually"
                fi
            done
        fi
    # Try grub-mkconfig (Arch)
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        if ! grub-mkconfig -o /boot/grub/grub.cfg; then
            print_error "Failed to update GRUB configuration."
            print_info "You may need to run 'sudo grub-mkconfig -o /boot/grub/grub.cfg' manually."
        fi
    else
        print_error "Could not find GRUB configuration command (update-grub, grub2-mkconfig, or grub-mkconfig)"
        print_info "Please update your GRUB configuration manually."
    fi

    # Verify and show the entry
    echo ""
    if [ -f "$grub_custom_file" ] && grep -q "${TRIGGER_PARAMETER}" "$grub_custom_file" 2>/dev/null; then
        print_success "✓ ${TRIGGER_PARAMETER} entry created in $grub_custom_file"

        echo ""
        print_info "Generated GRUB entry preview:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        grep -A 20 "^menuentry" "$grub_custom_file" | head -25
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        print_warning "Could not verify ${TRIGGER_PARAMETER} entry"
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
    
    # Clean kernel parameters and add trigger parameter
    clean_kernel_params=""
    if [ -n "$existing_kernel_params" ]; then
        # Remove root= parameter as we'll add our own, and remove ro/rw as we need rw
        clean_kernel_params=$(echo "$existing_kernel_params" | sed -e 's/root=[^[:space:]]*//g' -e 's/\bro\b//g' -e 's/\brw\b//g' -e 's/[[:space:]]\+/ /g' -e 's/^[[:space:]]*//g' -e 's/[[:space:]]*$//g')
    fi

    # Build final kernel parameters
    final_kernel_params="root=UUID=${root_uuid} rw ${TRIGGER_PARAMETER}"
    if [ -n "$clean_kernel_params" ]; then
        final_kernel_params="$final_kernel_params $clean_kernel_params"
    fi

    # Create systemd-boot entry
    entry_file="/boot/loader/entries/${TRIGGER_PARAMETER}.conf"
    
    print_info "Creating systemd-boot entry: $entry_file"
    print_info "Kernel: $kernel_file"
    print_info "Initrd: $initrd_file"
    print_info "Parameters: $final_kernel_params"
    
    # Check if entry already exists
    if [ -f "$entry_file" ]; then
        print_warning "${TRIGGER_PARAMETER} systemd-boot entry already exists at $entry_file"
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
title   ${distro_name} (${TRIGGER_PARAMETER})
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
    
    # Clean kernel parameters and add trigger parameter
    clean_kernel_params=""
    if [ -n "$existing_kernel_params" ]; then
        # Remove root= parameter as we'll add our own, and remove ro/rw as we need rw
        clean_kernel_params=$(echo "$existing_kernel_params" | sed -e 's/root=[^[:space:]]*//g' -e 's/\bro\b//g' -e 's/\brw\b//g' -e 's/[[:space:]]\+/ /g' -e 's/^[[:space:]]*//g' -e 's/[[:space:]]*$//g')
    fi

    # Build final kernel parameters
    final_kernel_params="root=UUID=${root_uuid} rw ${TRIGGER_PARAMETER}"
    if [ -n "$clean_kernel_params" ]; then
        final_kernel_params="$final_kernel_params $clean_kernel_params"
    fi

    print_info "Configuration file: $config_file"
    print_info "Kernel: $kernel_file"
    print_info "Initrd: $initrd_file"
    print_info "Parameters: $final_kernel_params"

    # Check if trigger parameter entry already exists
    trigger_entry_exists=false
    if [ -f "$config_file" ] && grep -q "${TRIGGER_PARAMETER}" "$config_file"; then
        trigger_entry_exists=true
        print_warning "${TRIGGER_PARAMETER} entry already exists in $config_file"
        read -p "Do you want to update the existing entry? (y/n): " update_existing
        
        if [[ ! "$update_existing" =~ ^[Yy]$ ]]; then
            print_info "Skipping extlinux entry creation."
        fi
    fi
    
    if [ "$trigger_entry_exists" = false ] || [[ "$update_existing" =~ ^[Yy]$ ]]; then
        # Create directory if needed
        mkdir -p "$(dirname "$config_file")"

        # Get distribution name for label
        if [ -f "/etc/os-release" ]; then
            . /etc/os-release
            distro_name="${PRETTY_NAME:-${NAME:-Linux}}"
        else
            distro_name="Linux"
        fi

        if [ "$trigger_entry_exists" = true ]; then
            # Remove existing trigger parameter entry
            sed -i "/# ${TRIGGER_PARAMETER} Entry/,/^$/d" "$config_file"
            print_info "Removed existing ${TRIGGER_PARAMETER} entry."
        fi

        # Add new trigger parameter entry
        cat >> "$config_file" << EOF

# ${TRIGGER_PARAMETER} Entry
LABEL ${TRIGGER_PARAMETER}
  MENU LABEL ${distro_name} (${TRIGGER_PARAMETER})
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
    print_info "To use ${TRIGGER_PARAMETER} with your bootloader, you need to:"
    print_info "1. Create a new boot entry that loads the same kernel and initramfs"
    print_info "2. Add '${TRIGGER_PARAMETER}' to the kernel command line parameters"
    echo ""
    
    # Get root UUID for manual configuration
    root_uuid=$(grep -oP 'UUID=\K[a-f0-9-]+' /proc/cmdline 2>/dev/null || \
                grep -oP 'root=UUID=\K[a-f0-9-]+' /proc/cmdline 2>/dev/null || \
                awk '$2 == "/" {print $1}' /etc/fstab | grep -oP 'UUID=\K[a-f0-9-]+' 2>/dev/null || \
                blkid -s UUID -o value $(findmnt -no SOURCE /))
    
    print_info "Your root UUID is: ${root_uuid}"
    print_info "Example kernel parameters: root=UUID=${root_uuid} rw ${TRIGGER_PARAMETER}"
    echo ""

elif [ "$bootloader" = "skip" ]; then
    print_info "Bootloader configuration skipped as requested."
    
    # Get root UUID for informational purposes
    root_uuid=$(grep -oP 'UUID=\K[a-f0-9-]+' /proc/cmdline 2>/dev/null || \
                grep -oP 'root=UUID=\K[a-f0-9-]+' /proc/cmdline 2>/dev/null || \
                awk '$2 == "/" {print $1}' /etc/fstab | grep -oP 'UUID=\K[a-f0-9-]+' 2>/dev/null || \
                blkid -s UUID -o value $(findmnt -no SOURCE /))
    
    echo ""
    print_warning "To enable ${TRIGGER_PARAMETER}, you'll need to manually add '${TRIGGER_PARAMETER}' to your kernel parameters."
    print_info "Your root UUID is: ${root_uuid}"
    print_info "Example kernel parameters: root=UUID=${root_uuid} rw ${TRIGGER_PARAMETER}"

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
print_success "zramroot installation completed!"
echo ""

if [ "$INIT_SYSTEM" = "initramfs-tools" ]; then
    # Display bootloader-specific success messages
    case "$bootloader" in
        "grub")
            print_info "A new GRUB menu entry has been added: '${TRIGGER_PARAMETER}'"
            print_info "You can select this entry at boot time to use ${TRIGGER_PARAMETER}."
            ;;
        "systemd-boot")
            print_info "A new systemd-boot entry has been added: '${distro_name} (${TRIGGER_PARAMETER})'"
            print_info "You can select this entry at boot time to use ${TRIGGER_PARAMETER}."
            ;;
        "extlinux")
            print_info "A new extlinux/syslinux entry has been added: '${distro_name} (${TRIGGER_PARAMETER})'"
            print_info "You can select this entry at boot time to use ${TRIGGER_PARAMETER}."
            ;;
        "manual")
            print_warning "Manual bootloader configuration is required!"
            print_info "Please create a boot entry with the '${TRIGGER_PARAMETER}' kernel parameter."
            ;;
        "skip")
            print_info "Bootloader configuration was skipped."
            print_warning "Remember to manually add '${TRIGGER_PARAMETER}' to your kernel parameters when ready."
            ;;
    esac
    echo ""
    print_info "Configuration file is located at: /etc/zramroot.conf"
    print_info "You can edit this file to change zramroot settings."
    echo ""
    print_warning "Remember that after modifying the configuration, you need to update the initramfs:"
    print_info "  sudo update-initramfs -u -k all"
fi

if [ "$INIT_SYSTEM" = "dracut" ]; then
    # Display bootloader-specific success messages for dracut systems
    if [ -f "/etc/qubes-release" ]; then
        # Qubes OS specific messages
        print_info "=== Next Steps for Qubes OS ==="
        echo ""
        print_info "1. Configure /etc/zramroot.conf with recommended settings:"
        print_info "   ZRAM_MOUNT_ON_DISK=\"/var/lib/qubes\""
        print_info "   ZRAM_PHYSICAL_ROOT_OPTS=\"rw\""
        print_info "   DEBUG_MODE=\"yes\""
        echo ""
        print_info "2. Reboot and select '${TRIGGER_PARAMETER}' from GRUB menu"
    else
        # Standard dracut system (Fedora/RHEL)
        case "$bootloader" in
            "grub")
                print_info "A new GRUB menu entry '${TRIGGER_PARAMETER}' has been added"
                print_info "Select this entry at boot time to use ${TRIGGER_PARAMETER}"
                ;;
            "systemd-boot")
                print_info "A new systemd-boot entry has been added"
                print_info "Select this entry at boot time to use ${TRIGGER_PARAMETER}"
                ;;
            "manual"|"skip")
                print_warning "Add '${TRIGGER_PARAMETER}' to your kernel parameters manually"
                ;;
        esac
    fi
    echo ""
    print_info "Configuration file is located at: /etc/zramroot.conf"
    print_info "You can edit this file to change zramroot settings."
    echo ""
    print_warning "Remember that after modifying the configuration, you need to rebuild initramfs:"
    print_info "  sudo dracut --force --regenerate-all"
fi

if [ "$INIT_SYSTEM" = "mkinitcpio" ]; then
    # Display bootloader-specific success messages for Arch systems
    case "$bootloader" in
        "grub")
            print_info "A new GRUB menu entry has been added: '${TRIGGER_PARAMETER}'"
            print_info "You can select this entry at boot time to use ${TRIGGER_PARAMETER}."
            ;;
        "systemd-boot")
            print_info "A new systemd-boot entry has been added: '${distro_name} (${TRIGGER_PARAMETER})'"
            print_info "You can select this entry at boot time to use ${TRIGGER_PARAMETER}."
            ;;
        "manual")
            print_warning "Manual bootloader configuration is required!"
            print_info "Please create a boot entry with the '${TRIGGER_PARAMETER}' kernel parameter."
            ;;
        "skip")
            print_info "Bootloader configuration was skipped."
            print_warning "Remember to manually add '${TRIGGER_PARAMETER}' to your kernel parameters when ready."
            ;;
    esac
    echo ""
    print_info "Configuration file is located at: /etc/zramroot.conf"
    print_info "You can edit this file to change zramroot settings."
    echo ""
    print_warning "Remember that after modifying the configuration, you need to rebuild initramfs:"
    print_info "  sudo mkinitcpio -P"
fi

echo ""
print_info "Press any key to exit..."
read -n 1
exit 0
