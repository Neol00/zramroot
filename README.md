# zramroot

zramroot is a collection of init scripts that allows your Linux system to operate entirely from RAM. It supports both **initramfs-tools** (Debian/Ubuntu) and **mkinitcpio** (Arch Linux/Artix/Manjaro) based systems.

By loading the root filesystem into compressed ZRAM during boot, zramroot allows your system to run without requiring the original storage device after boot completion. This provides benefits such as:
- **Faster system performance** - All filesystem operations happen in RAM
- **Reduced disk wear** - Especially useful for systems running on SD cards or SSDs
- **Diskless operation** - Physical storage can be disconnected after boot
- **Privacy** - Changes are stored in RAM and lost on reboot (unless explicitly saved)

## How It Works

zramroot integrates with your system's initramfs to:

1. **Detect the zramroot cmdline kernel parameter** during boot
2. **Mount your physical root partition** read-write for logging and filesystem copying
3. **Calculate optimal ZRAM size** based on your configuration and available RAM
4. **Create and configure a ZRAM device** using your chosen compression algorithm
5. **Format the ZRAM device** with your selected filesystem
6. **Copy your entire root filesystem** from physical storage to ZRAM
7. **Adjust system configurations** in the ZRAM root to prevent mounting original partitions
8. **Switch root** to the ZRAM device and continue booting

## Supported Systems

- **Debian/Ubuntu** (and derivatives) - Uses initramfs-tools
- **Arch Linux/Artix/Manjaro** (and derivatives) - Uses mkinitcpio

**⚠️ Important Warning**: Always backup your system before installing zramroot. While the installation script includes safety measures and backups, improper configuration can result in an unbootable system. The normal boot entry (without zramroot) will remain available as a fallback. 

## Installation

### Using the Install Script (Recommended)

1. Download the zramroot files and enter the directory
   
   ```bash
   git clone https://github.com/Neol00/zramroot.git
   ```
   ```bash
   cd zramroot
   ```
3. Make the install script executable:
   ```bash
   chmod +x install.sh
   ```
4. Run the script with sudo:
   ```bash
   sudo ./install.sh
   ```
5. Follow the prompts to complete installation
6. Reboot and select the zramroot entry in your bootloader menu

The install script will:
- **Auto-detect your init system** (initramfs-tools or mkinitcpio)
- **Detect your bootloader** (GRUB, systemd-boot, or extlinux)
- **Check for required dependencies** and suggest installation commands
- **For Arch/mkinitcpio**: Automatically configure `/etc/mkinitcpio.conf` and rebuild initramfs
- **For Debian/Ubuntu**: Ask for additional kernel modules if needed
- **Install all components** to the appropriate locations
- **Create backups** of files it replaces
- **Add a new boot entry** with the `zramroot` kernel parameter

### Manual Installation

#### For Arch Linux / mkinitcpio

1. Copy the files to their respective locations:
   ```bash
   sudo cp mkinitcpio/hooks/zramroot /usr/lib/initcpio/hooks/zramroot
   sudo cp mkinitcpio/install/zramroot /usr/lib/initcpio/install/zramroot
   sudo cp zramroot.conf /etc/zramroot.conf
   ```

2. Make scripts executable:
   ```bash
   sudo chmod +x /usr/lib/initcpio/hooks/zramroot
   sudo chmod +x /usr/lib/initcpio/install/zramroot
   ```

3. Edit `/etc/mkinitcpio.conf` and add `zramroot` to the HOOKS array BEFORE `filesystems`:
   ```bash
   HOOKS=(base udev autodetect modconf block zramroot filesystems keyboard fsck)
   ```

4. Rebuild the initramfs:
   ```bash
   sudo mkinitcpio -P
   ```

#### For Debian/Ubuntu / initramfs-tools

1. Copy the files to their respective locations:
   ```bash
   sudo cp initramfs-tools/scripts/local-premount/zramroot-boot /usr/share/initramfs-tools/scripts/local-premount/zramroot-boot
   sudo cp initramfs-tools/scripts/local /usr/share/initramfs-tools/scripts/local
   sudo cp initramfs-tools/hooks/zramroot /usr/share/initramfs-tools/hooks/zramroot
   sudo cp initramfs-tools/conf.d/zramroot-config /usr/share/initramfs-tools/conf.d/zramroot-config
   sudo cp initramfs-tools/conf.d/zramroot-config /etc/zramroot.conf
   ```

2. Make scripts executable:
   ```bash
   sudo chmod +x /usr/share/initramfs-tools/scripts/local-premount/zramroot-boot
   sudo chmod +x /usr/share/initramfs-tools/scripts/local
   sudo chmod +x /usr/share/initramfs-tools/hooks/zramroot
   ```

3. Rebuild the initramfs:
   ```bash
   sudo update-initramfs -u -k all
   ```

#### Bootloader Configuration (Both Systems)

After installing the files, you need to add a boot entry with the `zramroot` kernel parameter:

   **For GRUB:**
   - Create or edit `/etc/grub.d/40_custom` with an entry similar to:
   ```
   menuentry 'Linux (Load Root to ZRAM)' {
     search --no-floppy --fs-uuid --set=root YOUR_ROOT_UUID
     linux /boot/vmlinuz-linux root=UUID=YOUR_ROOT_UUID rw zramroot
     initrd /boot/initramfs-linux.img
   }
   ```
   - Note: Adjust kernel and initrd paths for your system:
     - Arch: `/boot/vmlinuz-linux` and `/boot/initramfs-linux.img`
     - Debian/Ubuntu: `/boot/vmlinuz` and `/boot/initrd.img`
   
   **For systemd-boot:**
   - Create `/boot/loader/entries/zramroot.conf`:
   ```
   title Linux (Load Root to ZRAM)
   linux /vmlinuz
   initrd /initrd.img
   options root=UUID=YOUR_ROOT_UUID rw zramroot
   ```
   
   **For extlinux:**
   - Edit `/boot/extlinux/extlinux.conf` or `/boot/syslinux/syslinux.cfg` and add:
   ```
   LABEL zramroot
   MENU LABEL Linux (Load Root to ZRAM)
   KERNEL /boot/vmlinuz
   APPEND root=UUID=YOUR_ROOT_UUID rw zramroot
   INITRD /boot/initrd.img
   ```
   - Replace `YOUR_ROOT_UUID` with your actual root partition UUID (find it with `blkid`)

4. Update your bootloader:
   ```bash
   # For GRUB (all systems):
   sudo update-grub    # Debian/Ubuntu
   sudo grub-mkconfig -o /boot/grub/grub.cfg    # Arch

   # For systemd-boot:
   sudo bootctl update

   # For extlinux:
   sudo extlinux --update /boot/extlinux
   ```

## Configuration

zramroot can be configured by editing `/etc/zramroot.conf`. The configuration file is shared between both init systems and uses the same format.

After making changes to `/etc/zramroot.conf`, rebuild your initramfs:

**For Arch/mkinitcpio:**
```bash
sudo mkinitcpio -P
```

**For Debian/Ubuntu/initramfs-tools:**
```bash
sudo update-initramfs -u -k all
```

### Configuration Options

#### Debugging
```
DEBUG_MODE="no"
```
Set to "yes" for verbose logging to `/var/log/zramroot-*.log` on the physical hard-drive root partition. All debug logs are exclusively written to the physical storage device, never to the zram device, ensuring logs persist even if zramroot encounters issues.

**Note:** Persistent logging to the physical disk is fully implemented in both initramfs-tools and mkinitcpio versions.

#### ZRAM Device Settings
```
ZRAM_SIZE_MiB=0
ZRAM_ALGO="zstd"
ZRAM_FS_TYPE="ext4"
ZRAM_MOUNT_OPTS="rw,noatime"
```
- `ZRAM_SIZE_MiB`: Manual ZRAM size in MiB (0 for automatic calculation)
- `ZRAM_ALGO`: Compression algorithm (options: zstd, lz4, lzo)
- `ZRAM_FS_TYPE`: Filesystem for ZRAM (options: ext4, btrfs, xfs)
- `ZRAM_MOUNT_OPTS`: Mount options for the ZRAM filesystem

#### RAM Management Settings
```
RAM_MIN_FREE_MiB=512
RAM_PREF_FREE_MiB=512
ZRAM_MIN_FREE_MiB=256
ZRAM_MAX_FREE_MiB=35840
```
- `RAM_MIN_FREE_MiB`: Minimum physical RAM to keep free (MiB)
- `RAM_PREF_FREE_MiB`: Preferred physical RAM to keep free (MiB)
- `ZRAM_MIN_FREE_MiB`: Minimum free space to keep in ZRAM (MiB)
- `ZRAM_MAX_FREE_MiB`: Maximum free space to allocate in ZRAM (MiB)

#### Resource Calculation
```
ESTIMATED_COMPRESSION_RATIO=2.5
ZRAM_BUFFER_PERCENT=10
```
- `ESTIMATED_COMPRESSION_RATIO`: Expected compression ratio
- `ZRAM_BUFFER_PERCENT`: Buffer percentage to add to root size

#### ZRAM Swap Settings
```
ZRAM_SWAP_ENABLED="yes"
ZRAM_SWAP_DEVICE_NUM=1
ZRAM_SWAP_SIZE_MiB=0
ZRAM_SWAP_ALGO="lz4"
ZRAM_SWAP_PRIORITY=10
```
- `ZRAM_SWAP_ENABLED`: Enable ZRAM-based swap to replace original drive swap partitions
- `ZRAM_SWAP_DEVICE_NUM`: ZRAM device number for swap (usually 1, since 0 is used for root)
- `ZRAM_SWAP_SIZE_MiB`: ZRAM swap size in MiB (0 for automatic calculation based on system RAM)
- `ZRAM_SWAP_ALGO`: Compression algorithm for swap (should match or be compatible with root ZRAM)
- `ZRAM_SWAP_PRIORITY`: Priority for ZRAM swap (higher numbers = higher priority)

#### Advanced Settings
```
ZRAM_DEVICE_NUM=0
TRIGGER_PARAMETER="zramroot"
WAIT_TIMEOUT=5
```
- `ZRAM_DEVICE_NUM`: ZRAM device number to use for root (usually 0)
- `TRIGGER_PARAMETER`: Kernel parameter to activate zramroot (both systems check for this parameter)
- `WAIT_TIMEOUT`: Seconds to wait for root device to appear (initramfs-tools only)

## Debugging

zramroot includes comprehensive logging to help troubleshoot issues:

1. **Enable Debug Mode**: Edit `/etc/zramroot.conf` and set `DEBUG_MODE="yes"`, then rebuild initramfs.

2. **Check Log Files**:
   - All logs are written to the physical root partition at `/var/log/zramroot-*.log`
   - Early boot logs are also written to the kernel message buffer (view with `dmesg | grep zramroot`)
   
3. **How Logging Works**:
   - The boot script mounts the physical root partition read-write at `/mnt/real_root_rw`
   - All logs are written to `/mnt/real_root_rw/var/log/zramroot-*.log` (never to the zram device)
   - This ensures logs persist even if there are problems with the zram setup
   - Log files include timestamps and a unique boot ID for tracking

3. **Common Issues**:

   - **System fails to boot with zramroot**:
     - Boot with the normal bootloader entry (without zramroot)
     - Check logs in `/var/log/zramroot-*.log`
     - Verify your configuration settings

   - **Not enough RAM**:
     - If the system has insufficient RAM, zramroot will log this in the error logs
     - Try adjusting `RAM_MIN_FREE_MiB` and `ZRAM_MIN_FREE_MiB` to lower values

   - **ZRAM module issues**:
     - Verify the ZRAM module is available: `modinfo zram`
     - If using custom compression, ensure the compression module is available

   - **Filesystem tools missing**:
     - Ensure filesystem tools for your chosen `ZRAM_FS_TYPE` are installed
     - For ext4: `e2fsprogs`
     - For btrfs: `btrfs-progs`
     - For xfs: `xfsprogs`

4. **Debugging Commands**:
   - View ZRAM status: `zramctl`
   - Check mountpoints: `findmnt | grep zram`
   - Verify RAM usage: `free -m`
   - View kernel logs: `dmesg | grep -i zramroot`
   - Check persistent logs: `ls -la /var/log/zramroot-*.log`
