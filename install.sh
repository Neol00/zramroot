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

# Function to create backup of a file
backup_file() {
    local file=$1
    if [ -f "$file" ]; then
        cp "$file" "$file.bak.$(date +%Y%m%d%H%M%S)"
        print_info "Created backup of $file"
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

# Find an available custom file name (40_custom, 41_custom, etc.)
custom_num=40
grub_custom_file="/etc/grub.d/${custom_num}_custom"

while [ -f "$grub_custom_file" ]; do
    print_info "File $grub_custom_file already exists, trying next number..."
    custom_num=$((custom_num + 1))
    grub_custom_file="/etc/grub.d/${custom_num}_custom"
done

print_info "Using GRUB custom file: $grub_custom_file"

# Get root UUID
root_uuid=$(grep -oP 'UUID=\K[a-f0-9-]+' /proc/cmdline 2>/dev/null || \
            grep -oP 'root=UUID=\K[a-f0-9-]+' /proc/cmdline 2>/dev/null || \
            awk '$2 == "/" {print $1}' /etc/fstab | grep -oP 'UUID=\K[a-f0-9-]+' 2>/dev/null || \
            blkid -s UUID -o value $(findmnt -no SOURCE /))

if [ -z "$root_uuid" ]; then
    print_error "Could not determine root UUID. Please edit $grub_custom_file manually after installation."
    root_uuid="YOUR-ROOT-UUID-HERE"
fi

# Try to extract info from existing GRUB config
grub_config="/boot/grub/grub.cfg"
if [ -f "$grub_config" ]; then
    print_info "Analyzing existing GRUB configuration..."
    
    # Get current OS name from grub
    os_name=$(grep -m1 -oP "menuentry '\K[^']*" "$grub_config" | grep -v "Memory test" | head -1)
    
    # Get kernel and initrd paths
    kernel_path=$(grep -m1 -oP '\tlinux\s+\K[^\s]+' "$grub_config" | head -1)
    initrd_path=$(grep -m1 -oP '\tinitrd\s+\K[^\s]+' "$grub_config" | head -1)
    
    # Check for devicetree
    if grep -q "devicetree" "$grub_config"; then
        devicetree_path=$(grep -m1 -oP '\tdevicetree\s+\K[^\s]+' "$grub_config" | head -1)
    fi
fi

# Set defaults if not found
if [ -z "$os_name" ]; then
    os_name=$(lsb_release -d 2>/dev/null | cut -f2)
    if [ -z "$os_name" ]; then
        os_name="Linux"
    fi
fi

if [ -z "$kernel_path" ]; then
    kernel_path="/boot/vmlinuz"
fi

if [ -z "$initrd_path" ]; then
    initrd_path="/boot/initrd.img"
fi

# Create custom GRUB file
print_info "Creating custom GRUB entry with OS: $os_name, UUID: $root_uuid"

cat > "$grub_custom_file" << EOF
#!/bin/sh
exec tail -n +3 \$0
# This file provides an easy way to add custom menu entries. Simply type the
# menu entries you want to add after this comment. Be careful not to change
# the 'exec tail' line above.

# --- ZRAM Root Custom Entry ---

menuentry '${os_name} (Load Root to ZRAM)' --class ubuntu --class gnu-linux --class gnu --class os {
	recordfail
	load_video
	gfxmode \$linux_gfx_mode
	insmod gzio
	if [ x\$grub_platform = xxen ]; then insmod xzio; insmod lzopio; fi
	insmod part_gpt
	insmod ext2
	search --no-floppy --fs-uuid --set=root ${root_uuid}
	linux	${kernel_path} root=UUID=${root_uuid} rw zramroot
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
