# zramroot

zramroot is a collection of init scripts that allows your Linux system to operate entirely from RAM. It supports **initramfs-tools** (Debian/Ubuntu), **mkinitcpio** (Arch Linux/Artix/Manjaro) and **dracut** (Fedora/RHEL/CentOS/Qubes OS).

By loading the root filesystem into compressed ZRAM during boot, zramroot allows your system to run without requiring the original storage device after boot completion. This provides benefits such as:
- **Faster system performance** - All filesystem operations happen in RAM
- **Reduced disk wear** - Especially useful for systems running on SD cards or SSDs
- **Diskless operation** - Physical storage can be disconnected after boot
- **Privacy** - Changes are stored in RAM and lost on reboot (unless explicitly saved to disk)

## How It Works

zramroot integrates with your system's initramfs to:

1. **Detect the zramroot kernel parameter** during boot (configurable)
2. **Mount your physical root partition** for filesystem copying
3. **Calculate optimal ZRAM size** based on your configuration and available RAM
4. **Create and configure a ZRAM device** using your chosen compression algorithm
5. **Format the ZRAM device** with your selected filesystem
6. **Copy your entire root filesystem** from physical storage to ZRAM using parallel operations
7. **Adjust system configurations** in the ZRAM root to prevent mounting original partitions
8. **Switch root** to the ZRAM device and continue booting
9. **Graceful fallback** - If ZRAM setup fails, the system falls back to normal boot automatically

## Supported Systems

- **Debian/Ubuntu** (and derivatives) - Uses initramfs-tools
- **Arch Linux/Artix/Manjaro** (and derivatives) - Uses mkinitcpio
- **Fedora/RHEL/CentOS** (and derivatives) - Uses dracut
- **Qubes OS** - Uses dracut (see [Qubes OS Configuration](#qubes-os-configuration) section below)

**Warning**: Always backup your system before installing zramroot. While the installation script includes safety measures and backups, improper configuration can result in an unbootable system. The normal boot entry (without the zramroot kernel parameter) will remain available as a fallback.

## Installation

### Using the Install Script (Recommended)

1. Download the zramroot files and enter the directory
   ```bash
   git clone https://github.com/Neol00/zramroot.git && cd zramroot
   ```
2. Optionally configure the zramroot.conf file before installation
   ```bash
   nano zramroot.conf
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
- **Auto-detect your init system** (initramfs-tools, mkinitcpio or dracut)
- **Detect your bootloader** (GRUB, systemd-boot, or extlinux)
- **Check for required dependencies** and suggest installation commands
- **Install all components** to the appropriate locations
- **Create backups** of files it replaces
- **Add a new boot entry** with the configurable activation kernel parameter (defaults to `zramroot`)

### Manual Installation

#### For Debian/Ubuntu (initramfs-tools)

1. Copy the files to their respective locations:
   ```bash
   sudo cp initramfs-tools/scripts/local-premount/zramroot-boot /usr/share/initramfs-tools/scripts/local-premount/zramroot-boot
   sudo cp initramfs-tools/scripts/local /usr/share/initramfs-tools/scripts/local
   sudo cp initramfs-tools/scripts/local-bottom/zramroot-final /usr/share/initramfs-tools/scripts/local-bottom/zramroot-final
   sudo cp initramfs-tools/hooks/zramroot /usr/share/initramfs-tools/hooks/zramroot
   sudo cp initramfs-tools/conf.d/zramroot-config /usr/share/initramfs-tools/conf.d/zramroot-config
   sudo cp zramroot.conf /etc/zramroot.conf
   ```

2. Make scripts executable:
   ```bash
   sudo chmod +x /usr/share/initramfs-tools/scripts/local-premount/zramroot-boot
   sudo chmod +x /usr/share/initramfs-tools/scripts/local
   sudo chmod +x /usr/share/initramfs-tools/scripts/local-bottom/zramroot-final
   sudo chmod +x /usr/share/initramfs-tools/hooks/zramroot
   ```

3. Rebuild the initramfs:
   ```bash
   sudo update-initramfs -c -k all
   ```

#### For Arch Linux (mkinitcpio)

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

3. Edit `/etc/mkinitcpio.conf` and add `zramroot` to the HOOKS array:
   - Place it **BEFORE** `filesystems`
   - If using encryption, place it **AFTER** `encrypt`
   ```bash
   HOOKS=(base udev autodetect modconf block encrypt zramroot filesystems keyboard fsck)
   ```

4. Rebuild the initramfs:
   ```bash
   sudo mkinitcpio -P
   ```

#### For Fedora/RHEL/CentOS/Qubes OS (dracut)

**Important**: If you use disk encryption (LUKS), ensure the zramroot module priority number is higher than your encryption module (e.g., `90crypt`). If zramroot loads too early, the encrypted root won't be available yet. If it loads too late (e.g., `99`), the root filesystem may already be mounted.
Dracut modules are loaded based on their directory name priority (the two-digit prefix). Lower numbers load earlier. The zramroot module must load **AFTER** block devices and encryption are set up, but **BEFORE** the root filesystem is mounted.
Recommended priority: `95` (after `90crypt` for encryption, before `98dracut-systemd`/`99base`)
Also make sure that if the XXrootfs-block directory already exists inside /usr/lib/dracut/modules.d that you skip creating another directory with the priority 95 and replace the mount-root.sh script after backing up the original.

1. Create the dracut module directories with appropriate priority:
   ```bash
   sudo mkdir -p /usr/lib/dracut/modules.d/95zramroot
   sudo mkdir -p /usr/lib/dracut/modules.d/95rootfs-block    # Only do this if rootfs-block does not exist or if it already has priority 95
   ```

2. Copy the zramroot module scripts:
   ```bash
   sudo cp dracut/zramroot/module-setup.sh /usr/lib/dracut/modules.d/95zramroot/
   sudo cp dracut/zramroot/zramroot-mount.sh /usr/lib/dracut/modules.d/95zramroot/
   sudo cp dracut/zramroot/zramroot-finalize.sh /usr/lib/dracut/modules.d/95zramroot/
   ```

3. Copy and replace the modified rootfs-block module script:
   ```bash
   sudo cp dracut/rootfs-block/mount-root.sh /usr/lib/dracut/modules.d/95rootfs-block/
   ```
   Or:
   ```bash
   sudo cp dracut/rootfs-block/mount-root.sh /usr/lib/dracut/modules.d/XXrootfs-block/    # Replace XX with the correct priority number
   ```

4. Copy the configuration file:
   ```bash
   sudo cp zramroot.conf /etc/zramroot.conf
   ```

5. Make scripts executable:
   ```bash
   sudo chmod +x /usr/lib/dracut/modules.d/95zramroot/*.sh
   sudo chmod +x /usr/lib/dracut/modules.d/95rootfs-block/mount-root.sh
   ```

6. Create a dracut configuration to include the zramroot module:
   ```bash
   echo 'add_drivers+=" zram "' | sudo tee /etc/dracut.conf.d/zramroot.conf
   ```

7. Rebuild the initramfs:
   ```bash
   # For all kernels:
   sudo dracut -f --regenerate-all

   # Or for the current kernel only:
   sudo dracut -f
   ```

**Note for Qubes OS**: The dracut module directory is located at `/usr/lib/dracut/modules.d/` in dom0.

#### Bootloader Configuration

After installing the files, you need to add a boot entry with the `zramroot` kernel parameter (or your custom trigger parameter if configured).
You can also temporarily edit your bootloader entry during boot to add the parameter for testing.

**For GRUB:**
- Create or edit `/etc/grub.d/40_custom` with an entry similar to:
```
menuentry 'Linux (Load Root to ZRAM)' {
  search --no-floppy --fs-uuid --set=root YOUR_ROOT_UUID
  linux /boot/vmlinuz-linux root=UUID=YOUR_ROOT_UUID rw zramroot
  initrd /boot/initramfs-linux.img
}
```
- Note: Adjust kernel and initrd paths for your distribution:
  - Arch: `/boot/vmlinuz-linux` and `/boot/initramfs-linux.img`
  - Debian/Ubuntu: `/boot/vmlinuz` and `/boot/initrd.img`
  - Fedora: `/boot/vmlinuz-$(uname -r)` and `/boot/initramfs-$(uname -r).img`

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

Replace `YOUR_ROOT_UUID` with your actual root partition UUID (find it with `blkid`).

**Update your bootloader:**
```bash
# For GRUB:
sudo update-grub                                    # Debian/Ubuntu
sudo grub-mkconfig -o /boot/grub/grub.cfg          # Arch
sudo grub2-mkconfig -o /boot/grub2/grub.cfg        # Fedora/RHEL

# For systemd-boot:
sudo bootctl update

# For extlinux:
sudo extlinux --update /boot/extlinux
```

Adjust the commands above as needed for your system.
The bootloader configuration location varies and might be located inside your EFI partition instead of /boot. For example Qubes OS has got two grub.cfg files, one inside `/boot/grub2` and another inside `/boot/efi/EFI/qubes` .

## Configuration

zramroot can be configured before installation in `zramroot.conf` or when already installed by editing `/etc/zramroot.conf`. The configuration file is shared between all init systems and uses the same format.
After making changes to `/etc/zramroot.conf`, rebuild your initramfs to apply the new configuration:

**For Debian/Ubuntu (initramfs-tools):**
```bash
sudo update-initramfs -c -k all
```

**For Arch Linux (mkinitcpio):**
```bash
sudo mkinitcpio -P
```

**For Fedora/RHEL/dracut:**
```bash
sudo dracut -f --regenerate-all
```

### Configuration Options

#### Debugging
```
DEBUG_MODE="no"
DEBUG_LOG_DIR="/var/log"
DEBUG_LOG_DEVICE=""
```
Set `DEBUG_MODE="yes"` for verbose logging. Logs are written to `${DEBUG_LOG_DIR}/zramroot-*.log` on the physical storage device during boot.

**Notes:**
- During boot, the physical root is temporarily mounted to write logs, ensuring they persist even if ZRAM setup fails.
- If you want to log to an unencrypted partition (e.g., `/boot`), set `DEBUG_LOG_DIR="/boot"` and specify its device in `DEBUG_LOG_DEVICE` (for example, `UUID=XXXX-XXXX` or `/dev/sda1`).

#### ZRAM Device Settings
```
ZRAM_SIZE_MiB=0
ZRAM_ALGO="zstd"
ZRAM_FS_TYPE="ext4"
ZRAM_MOUNT_OPTS="rw,noatime"
```
- `ZRAM_SIZE_MiB`: Manual ZRAM size in MiB (0 for automatic calculation)
- `ZRAM_ALGO`: Compression algorithm (options: `zstd`, `lz4`, `lz4hc`, `lzo`, `lzo-rle`)
- `ZRAM_FS_TYPE`: Filesystem for ZRAM (options: `ext4`, `btrfs`, `xfs`)
- `ZRAM_MOUNT_OPTS`: Mount options for the ZRAM filesystem

#### RAM Management Settings
```
RAM_MIN_FREE_MiB=512
RAM_PREF_FREE_MiB=1024
ZRAM_MIN_FREE_MiB=256
ZRAM_MAX_FREE_MiB=35840
ZRAM_BUFFER_PERCENT=10
```
- `RAM_MIN_FREE_MiB`: Minimum physical RAM to keep free (MiB) - boot will fail if this cannot be satisfied
- `RAM_PREF_FREE_MiB`: Preferred physical RAM to keep free (MiB)
- `ZRAM_MIN_FREE_MiB`: Minimum free space to keep in ZRAM (MiB)
- `ZRAM_MAX_FREE_MiB`: Maximum free space to allocate in ZRAM (MiB)
- `ZRAM_BUFFER_PERCENT`: Buffer percentage to add to calculated root size

#### ZRAM Swap Settings
```
ZRAM_SWAP_ENABLED="yes"
ZRAM_SWAP_DEVICE_NUM=1
ZRAM_SWAP_SIZE_MiB=0
ZRAM_SWAP_ALGO="lz4"
ZRAM_SWAP_PRIORITY=10
```
- `ZRAM_SWAP_ENABLED`: Enable ZRAM-based swap to replace original drive swap partitions
- `ZRAM_SWAP_DEVICE_NUM`: ZRAM device number for swap (must be different from `ZRAM_DEVICE_NUM`)
- `ZRAM_SWAP_SIZE_MiB`: ZRAM swap size in MiB (0 for automatic calculation based on system RAM)
- `ZRAM_SWAP_ALGO`: Compression algorithm for swap
- `ZRAM_SWAP_PRIORITY`: Priority for ZRAM swap (higher numbers = higher priority)

**Important:** `ZRAM_DEVICE_NUM` and `ZRAM_SWAP_DEVICE_NUM` must be different values. If they are the same, zramroot will automatically adjust `ZRAM_SWAP_DEVICE_NUM` to avoid conflicts.

#### Include/Exclude Patterns
```
ZRAM_EXCLUDE_PATTERNS=""
ZRAM_INCLUDE_PATTERNS=""
```
- `ZRAM_EXCLUDE_PATTERNS`: Space-separated patterns to exclude from ZRAM copy (supports wildcards)
  - Example: `ZRAM_EXCLUDE_PATTERNS="/var/cache/* /tmp/* *.iso *.img"`
  - These are in addition to default exclusions: `/dev, /proc, /sys, /tmp, /run, /mnt, /media, /lost+found, /var/log/journal/*`
- `ZRAM_INCLUDE_PATTERNS`: Space-separated patterns to explicitly include (overrides excludes)
  - Only needed if you want to include something that would otherwise be excluded
  - Example: `ZRAM_INCLUDE_PATTERNS="/var/cache/important-data"`

**Use Cases:**
- Exclude large cache directories: `ZRAM_EXCLUDE_PATTERNS="/var/cache/* /home/*/.cache"`
- Exclude VM disk images: `ZRAM_EXCLUDE_PATTERNS="*.qcow2 *.vmdk *.vdi"`
- **Qubes OS**: Exclude VM storage: `ZRAM_EXCLUDE_PATTERNS="/var/lib/qubes/appvms/* /var/lib/qubes/vm-templates/*"`

#### Mount-on-Disk (Bind Mounts)
```
ZRAM_MOUNT_ON_DISK=""
ZRAM_PHYSICAL_ROOT_OPTS="rw"
```
- `ZRAM_MOUNT_ON_DISK`: Space-separated directories to exclude from ZRAM but mount from physical disk after boot
  - These directories will be created as empty directories in ZRAM, then bind-mounted from the physical root partition
  - Physical root will remain mounted at `/mnt/physical_root`
  - Example: `ZRAM_MOUNT_ON_DISK="/var/lib/qubes /home"`
  - **Note**: Paths listed here are automatically added to `ZRAM_EXCLUDE_PATTERNS`
- `ZRAM_PHYSICAL_ROOT_OPTS`: Mount options for physical root when using mount-on-disk (default: `rw` for read-write)
  - Use `ro` if you do not need write access to the bind-mounted directories

**Use Cases:**
- **Qubes OS Dom0**: Load Dom0 to ZRAM but keep VM storage on disk:
  ```
  ZRAM_MOUNT_ON_DISK="/var/lib/qubes"
  ZRAM_PHYSICAL_ROOT_OPTS="rw"
  ```
- **Docker/Podman**: Keep containers on disk while running system from ZRAM:
  ```
  ZRAM_MOUNT_ON_DISK="/var/lib/docker /var/lib/containers"
  ZRAM_PHYSICAL_ROOT_OPTS="rw"
  ```
- **Home directory on disk**: Keep user data on disk:
  ```
  ZRAM_MOUNT_ON_DISK="/home"
  ZRAM_PHYSICAL_ROOT_OPTS="rw"
  ```

**How it works:**
1. Specified directories are excluded from the ZRAM copy (not copied)
2. Empty directories are created in the ZRAM root at those paths
3. Physical root remains mounted at `/mnt/physical_root`
4. Bind mount entries are added to `/etc/fstab` in the ZRAM root
5. On boot, the directories are bind-mounted from the physical disk

This is especially useful for:
- Large data directories that don't benefit from being in RAM
- Persistent storage that needs to survive reboots
- VM disk images, container storage, database files, etc.

#### Advanced Settings
```
ZRAM_DEVICE_NUM=0
TRIGGER_PARAMETER="zramroot"
WAIT_TIMEOUT=120
```
- `ZRAM_DEVICE_NUM`: ZRAM device number to use for root (usually 0)
- `TRIGGER_PARAMETER`: Kernel parameter to activate zramroot (default: `zramroot`)
- `WAIT_TIMEOUT`: Seconds to wait for root device to appear during boot

## Debugging

zramroot includes comprehensive logging to help troubleshoot issues:

1. **Enable Debug Mode**: Edit `/etc/zramroot.conf` and set `DEBUG_MODE="yes"`, then rebuild initramfs.

2. **Check Log Files**:
   - Logs are written to the physical root partition at `/var/log/zramroot-*.log`
   - Early boot logs are also written to the kernel message buffer (view with `dmesg | grep zramroot`)

3. **How Logging Works**:
   - During boot, the physical root partition is temporarily mounted for logging
   - All logs are written to `/var/log/zramroot-*.log` on the physical disk
   - This ensures logs persist even if there are problems with the ZRAM setup
   - Log files include timestamps for tracking

4. **Common Issues**:

   - **System fails to boot with zramroot**:
     - Boot with the normal bootloader entry (without the zramroot parameter)
     - Check logs in `/var/log/zramroot-*.log`
     - Verify your configuration settings
     - Note: zramroot will automatically fall back to normal boot if ZRAM setup fails

   - **Not enough RAM**:
     - If the system has insufficient RAM, zramroot will log this and fall back to normal boot
     - Try adjusting `RAM_MIN_FREE_MiB` and `ZRAM_MIN_FREE_MiB` to lower values

   - **ZRAM module issues**:
     - Verify the ZRAM module is available: `modinfo zram`
     - If using custom compression, ensure the compression module is available (e.g., `modinfo lz4`, `modinfo zstd`)

   - **Filesystem tools missing**:
     - Ensure filesystem tools for your chosen `ZRAM_FS_TYPE` are installed and included in initramfs
     - For ext4: `e2fsprogs`
     - For btrfs: `btrfs-progs`
     - For xfs: `xfsprogs`
     - The error message will indicate which package to install and which command to rebuild initramfs

5. **Debugging Commands**:
   ```bash
   # View ZRAM status
   zramctl

   # Check mountpoints
   findmnt | grep zram

   # Verify RAM usage
   free -m

   # View kernel logs
   dmesg | grep -i zramroot

   # Check persistent logs (on physical disk)
   ls -la /var/log/zramroot-*.log

   # View latest log
   cat /var/log/zramroot-*.log | tail -100
   ```

## Qubes OS Configuration

Here is an example configuration for dom0 to run from ZRAM while keeping VM storage on disk.

### Recommended Configuration for Qubes OS dom0

Edit `/etc/zramroot.conf` in dom0 with the following settings:

```bash
# Load dom0 to ZRAM but keep VM storage on disk
ZRAM_MOUNT_ON_DISK="/var/lib/qubes"

# Allow read-write access to VM storage
ZRAM_PHYSICAL_ROOT_OPTS="rw"

# Exclude VM-related large files from ZRAM copy
ZRAM_EXCLUDE_PATTERNS="/var/cache/qubes-*"

# Recommended ZRAM settings for Qubes
ZRAM_ALGO="zstd"           # Best compression for Dom0 system files
ZRAM_FS_TYPE="ext4"        # Stable and well-tested
RAM_MIN_FREE_MiB=2048      # Keep extra RAM free for dom0 operations
RAM_PREF_FREE_MiB=4096     # Preferred free RAM for dom0
```

### Installation in Qubes OS dom0

Since dom0 has limited network access, you'll need to copy the files from another VM:

1. Download zramroot in a VM (e.g., a disposable VM):
   ```bash
   git clone https://github.com/Neol00/zramroot.git
   ```

2. Copy to dom0:
   ```bash
   # In dom0:
   qvm-run --pass-io <vm-name> 'tar -C /home/user -cf - zramroot' | tar -C /home/user -xf -
   ```

3. Install in dom0:
   ```bash
   cd ~/zramroot
   sudo ./install.sh
   ```

4. Rebuild initramfs and reboot:
   ```bash
   sudo dracut -f --regenerate-all
   ```
