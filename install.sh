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

print_header

# Display warning and get confirmation
print_warning "ZRAMroot might make your installation unbootable if not configured correctly."
print_warning "This script will replace /usr/share/initramfs-tools/scripts/local and add a GRUB menu entry."
print_warning "It will also update your GRUB configuration and rebuild your initramfs."
echo ""
print_info "It is STRONGLY recommended to make a backup before continuing."
echo ""
read -p "Are you sure you want to continue? (y/n): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    print_info "Installation aborted by user."
    exit 0
fi

print_header

# Check for required files
FILES=("zramroot-boot" "local" "zramroot" "zramroot-config")
MISSING=0

for file in "${FILES[@]}"; do
    if [ ! -f "$file" ]; then
        print_error "Required file not found: $file"
        MISSING=1
    fi
done

if [ $MISSING -eq 1 ]; then
    print_error "Some required files are missing. Please make sure all files are in the current directory."
    exit 1
fi

# Get additional modules from user - use a loop to allow corrections
print_header
print_info "You can specify additional kernel modules to load during early boot."
print_info "These might be needed for specific hardware support."
print_info "Enter module names separated by spaces, or leave empty for no additional modules."
echo ""

# Initialize module selection variables
additional_modules=""
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

# Create directory structure if it doesn't exist
print_info "Creating directory structure..."
mkdir -p /usr/share/initramfs-tools/scripts/local-premount
mkdir -p /usr/share/initramfs-tools/hooks
mkdir -p /usr/share/initramfs-tools/conf.d

# Add user modules to the hook script if provided
if [ -n "$additional_modules" ]; then
    print_info "Adding custom modules to hook script..."
    # Create a temporary file with the modified content
    cat "zramroot" | sed "s/^EXTRA_MODULES=.*/EXTRA_MODULES=\"$additional_modules\"/" > zramroot.modified
    mv zramroot.modified zramroot
    chmod +x zramroot
fi

# Copy files to their destinations
print_info "Copying files to system directories..."

# Backup existing files
backup_file "/usr/share/initramfs-tools/scripts/local"
backup_file "/etc/grub.d/40_custom"
backup_file "/usr/share/initramfs-tools/conf.d/zramroot-config"
backup_file "/etc/zramroot.conf"

# Copy files
cp "zramroot-boot" "/usr/share/initramfs-tools/scripts/local-premount/zramroot-boot"
chmod +x "/usr/share/initramfs-tools/scripts/local-premount/zramroot-boot"

cp "local" "/usr/share/initramfs-tools/scripts/local"
chmod +x "/usr/share/initramfs-tools/scripts/local"

cp "zramroot" "/usr/share/initramfs-tools/hooks/zramroot"
chmod +x "/usr/share/initramfs-tools/hooks/zramroot"

cp "zramroot-config" "/usr/share/initramfs-tools/conf.d/zramroot-config"
cp "zramroot-config" "/etc/zramroot.conf"

# Create custom GRUB entry
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
        additional_modules="insmod part_gpt; insmod ext2"
        ;;
    "debian")
        grub_class="debian"
        additional_modules="insmod part_gpt; insmod ext2"
        ;;
    "fedora")
        grub_class="fedora"
        additional_modules="insmod part_gpt; insmod ext2; insmod xfs"
        ;;
    "centos"|"rhel")
        grub_class="centos"
        additional_modules="insmod part_gpt; insmod ext2; insmod xfs"
        ;;
    "arch"|"manjaro")
        grub_class="arch"
        additional_modules="insmod part_gpt; insmod ext2"
        ;;
    "opensuse"|"suse")
        grub_class="opensuse"
        additional_modules="insmod part_gpt; insmod ext2; insmod btrfs; insmod xfs"
        ;;
    *)
        # Generic Linux fallback
        grub_class="gnu-linux"
        additional_modules="insmod part_gpt; insmod ext2"
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
    initrd_path=$(grep -m1 -oP '\tinitrd\s+\K[^\s]+' "$grub_config" | head -1)
    
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
	${additional_modules}
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

# Update initramfs
print_info "Updating initramfs..."
if ! update-initramfs -u -k all; then
    print_error "Failed to update initramfs."
    print_info "You may need to run 'update-initramfs -u -k all' manually."
fi

print_header
print_success "ZRAMroot installation completed!"
echo ""
print_info "A new GRUB menu entry has been added: '${os_name} (Load Root to ZRAM)'"
print_info "You can select this entry at boot time to use ZRAMroot."
echo ""
print_info "Configuration file is located at: /etc/zramroot.conf"
print_info "You can edit this file to change ZRAMroot settings."
echo ""
print_warning "Remember that after modifying the configuration, you need to update the initramfs:"
print_info "  sudo update-initramfs -u -k all"
echo ""
print_info "Press any key to exit..."
read -n 1
exit 0
