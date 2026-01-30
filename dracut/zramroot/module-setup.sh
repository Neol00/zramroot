#!/bin/bash
# dracut module-setup.sh for zramroot
# This file is called by dracut to install the zramroot module into initramfs

# check() is called by dracut to check if this module can/should be included
check() {
    # Only include if zramroot config exists or if explicitly requested
    # This allows the module to be included but remain dormant until kernel param is set
    return 0
}

# depends() returns list of dracut modules this module depends on
depends() {
    # We need basic filesystem support and device mapper if using LVM
    # Include crypt and lvm so encrypted roots are unlocked before zramroot runs
    echo "bash fs-lib crypt lvm"
    return 0
}

# install() is called by dracut to install all needed files
install() {
    local _CONFIG_FILE="/etc/zramroot.conf"

    # --- Install configuration file ---
    if [ -f "$_CONFIG_FILE" ]; then
        inst "$_CONFIG_FILE" "/etc/zramroot.conf"
        dinfo "zramroot: Installed configuration from $_CONFIG_FILE"
    else
        dwarn "zramroot: Configuration file $_CONFIG_FILE not found, using defaults"
    fi

    # --- Install required binaries ---
    # Core utilities for copying and ZRAM management
    inst_multiple \
        rsync \
        zramctl \
        blkid \
        readlink \
        mount \
        umount \
        sync \
        df \
        mkdir \
        chmod \
        sed \
        awk \
        grep \
        cat \
        head \
        tail \
        touch \
        date \
        mkswap \
        swapon \
        swapoff \
        du \
        nproc \
        find \
        sort \
        basename \
        cut \
        printf \
        sleep \
        rm \
        cp \
        mountpoint

    # Filesystem creation tools - based on config
    # ext4 always included as fallback
    inst_multiple mkfs.ext4 fsck.ext4 e2fsck

    # Read ZRAM_FS_TYPE from config to determine which fs tools to include
    local _zram_fs_type="ext4"
    if [ -f "$_CONFIG_FILE" ]; then
        local _fs_setting
        _fs_setting=$(grep "^ZRAM_FS_TYPE=" "$_CONFIG_FILE" 2>/dev/null | cut -d'"' -f2)
        if [ -n "$_fs_setting" ]; then
            _zram_fs_type="$_fs_setting"
            dinfo "zramroot: Using filesystem type from config: $_zram_fs_type"
        fi
    fi

    # Include filesystem-specific tools based on config
    case "$_zram_fs_type" in
        btrfs)
            if command -v mkfs.btrfs >/dev/null 2>&1; then
                inst_multiple mkfs.btrfs btrfs
                dinfo "zramroot: Included btrfs tools"
            else
                derror "zramroot: ZRAM_FS_TYPE=btrfs but btrfs tools not found!"
            fi
            ;;
        xfs)
            if command -v mkfs.xfs >/dev/null 2>&1; then
                inst_multiple mkfs.xfs xfs_repair
                dinfo "zramroot: Included xfs tools"
            else
                derror "zramroot: ZRAM_FS_TYPE=xfs but xfs tools not found!"
            fi
            ;;
    esac

    # Optional: LVM2 tools for LVM root devices
    if command -v vgchange >/dev/null 2>&1; then
        inst_multiple vgchange lvchange dmsetup lvscan vgscan pvscan || \
            dwarn "zramroot: LVM2 tools not fully available"
    fi

    # Debug utilities (useful for troubleshooting)
    inst_multiple lsmod modprobe || dwarn "zramroot: Debug utilities not available"

    # --- Install kernel modules ---
    # ZRAM module (required)
    instmods zram

    # Read compression algorithms from config
    local _zram_algo="lz4"
    local _zram_swap_algo="lz4"
    if [ -f "$_CONFIG_FILE" ]; then
        local _algo_setting
        _algo_setting=$(grep "^ZRAM_ALGO=" "$_CONFIG_FILE" 2>/dev/null | cut -d'"' -f2)
        if [ -n "$_algo_setting" ]; then
            _zram_algo="$_algo_setting"
            dinfo "zramroot: Using root compression algorithm from config: $_zram_algo"
        fi
        _algo_setting=$(grep "^ZRAM_SWAP_ALGO=" "$_CONFIG_FILE" 2>/dev/null | cut -d'"' -f2)
        if [ -n "$_algo_setting" ]; then
            _zram_swap_algo="$_algo_setting"
            dinfo "zramroot: Using swap compression algorithm from config: $_zram_swap_algo"
        fi
    fi

    # Helper function to install compression modules
    _install_compression_modules() {
        local algo="$1"
        case "$algo" in
            zstd)
                instmods zstd || dwarn "zramroot: zstd module not available"
                ;;
            lz4|lz4hc)
                instmods lz4 lz4_compress || dwarn "zramroot: lz4 modules not available"
                ;;
            lzo|lzo-rle)
                instmods lzo lzo_compress || dwarn "zramroot: lzo modules not available"
                ;;
            *)
                dwarn "zramroot: Unknown compression algorithm '$algo', including all"
                instmods zstd lz4 lz4_compress lzo lzo_compress || true
                ;;
        esac
    }

    # Install compression modules for root and swap
    _install_compression_modules "$_zram_algo"
    if [ "$_zram_swap_algo" != "$_zram_algo" ]; then
        _install_compression_modules "$_zram_swap_algo"
    fi

    # Filesystem modules - based on config
    instmods ext4 || dwarn "zramroot: ext4 module not available"
    case "$_zram_fs_type" in
        btrfs)
            instmods btrfs || dwarn "zramroot: btrfs module not available"
            ;;
        xfs)
            instmods xfs || dwarn "zramroot: xfs module not available"
            ;;
    esac

    # Device mapper for LVM (if needed)
    instmods dm-mod dm-log dm-mirror dm-snapshot || dwarn "zramroot: Device mapper modules may not be available"

    # --- Install hook scripts ---
    # Extract priority from module directory name (e.g., 94zramroot -> 94)
    local _moddir_base
    _moddir_base=$(basename "$moddir")
    local _priority
    _priority=$(echo "$_moddir_base" | sed -n 's/^\([0-9][0-9]*\).*/\1/p')
    if [ -z "$_priority" ]; then
        _priority=94  # fallback default
    fi

    # Pre-mount hook: prepares ZRAM device, copies filesystem, writes state file
    # The actual mounting is handled by systemd override or our mount hook
    inst_hook pre-mount "$_priority" "$moddir/zramroot-mount.sh"
    dinfo "zramroot: Installed pre-mount hook at priority $_priority"

    # Pre-pivot hook: moves physical root mount into the new root
    inst_hook pre-pivot "$_priority" "$moddir/zramroot-finalize.sh"
    dinfo "zramroot: Installed pre-pivot hook at priority $_priority"

    # --- Create necessary directories in initramfs ---
    # These will be used during the boot process
    mkdir -p "${initdir}/local_root"
    mkdir -p "${initdir}/zram_root"
    mkdir -p "${initdir}/mnt/real_root_rw"
    mkdir -p "${initdir}/mnt/physical_root"

    dinfo "zramroot: Module installation complete"
    return 0
}

# installkernel() can be used to install additional kernel modules
# We handle most modules in install() but this ensures zram is always included
installkernel() {
    # ZRAM module is always required
    instmods zram
}
