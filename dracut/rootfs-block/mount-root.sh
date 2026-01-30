#!/usr/bin/sh

type getarg > /dev/null 2>&1 || . /lib/dracut-lib.sh
type det_fs > /dev/null 2>&1 || . /lib/fs-lib.sh

# --- ZRAMROOT: Check if zramroot is enabled ---
# Load configuration
CONFIG_FILE="/etc/zramroot.conf"
TRIGGER="zramroot"
if [ -f "${CONFIG_FILE}" ]; then
    . "${CONFIG_FILE}"
    if [ -n "${TRIGGER_PARAMETER}" ]; then
        TRIGGER="${TRIGGER_PARAMETER}"
    fi
fi

if getarg "${TRIGGER}" > /dev/null 2>&1; then
    # Read ZRAM configuration from state file written by zramroot-mount.sh
    ZRAMROOT_DEVICE=""
    ZRAMROOT_FSTYPE=""
    ZRAMROOT_ROOTFLAGS=""

    if [ -f /run/initramfs/zramroot.env ]; then
        . /run/initramfs/zramroot.env
    elif [ -f /tmp/zramroot.env ]; then
        . /tmp/zramroot.env
    fi

    # Fall back to config file values if state file not found
    if [ -z "$ZRAMROOT_DEVICE" ]; then
        ZRAM_DEVICE_NUM="${ZRAM_DEVICE_NUM:-0}"
        ZRAMROOT_DEVICE="/dev/zram${ZRAM_DEVICE_NUM}"
    fi
    if [ -z "$ZRAMROOT_FSTYPE" ]; then
        ZRAMROOT_FSTYPE="${ZRAM_FS_TYPE:-ext4}"
    fi
    if [ -z "$ZRAMROOT_ROOTFLAGS" ]; then
        ZRAMROOT_ROOTFLAGS="${ZRAM_MOUNT_OPTS:-noatime}"
        ZRAMROOT_ROOTFLAGS="rw,${ZRAMROOT_ROOTFLAGS}"
    fi

    # Check if ZRAM device exists and is ready
    if [ -b "$ZRAMROOT_DEVICE" ]; then
        info "zramroot: Mounting ZRAM device $ZRAMROOT_DEVICE as root"

        # Mount ZRAM device at NEWROOT
        if mount -t "$ZRAMROOT_FSTYPE" -o "$ZRAMROOT_ROOTFLAGS" "$ZRAMROOT_DEVICE" "$NEWROOT"; then
            info "zramroot: Successfully mounted ZRAM root at $NEWROOT"

            # Handle physical root bind mount if it was kept mounted
            if [ -d /mnt/physical_root ] && mountpoint -q /mnt/physical_root 2>/dev/null; then
                mkdir -p "$NEWROOT/mnt/physical_root"
                if mount --move /mnt/physical_root "$NEWROOT/mnt/physical_root" 2>/dev/null; then
                    info "zramroot: Moved physical root to $NEWROOT/mnt/physical_root"
                elif mount --bind /mnt/physical_root "$NEWROOT/mnt/physical_root" 2>/dev/null; then
                    info "zramroot: Bind-mounted physical root to $NEWROOT/mnt/physical_root"
                else
                    warn "zramroot: Failed to move/bind physical root"
                fi
            fi

            # Skip the normal mount_root function - we're done
            return 0
        else
            warn "zramroot: Failed to mount ZRAM device, falling back to normal boot"
        fi
    else
        warn "zramroot: ZRAM device $ZRAMROOT_DEVICE not found, falling back to normal boot"
    fi
fi
# --- END ZRAMROOT ---

mount_root() {
    local _rflags_ro
    # sanity - determine/fix fstype
    rootfs=$(det_fs "${root#block:}" "$fstype")

    journaldev=$(getarg "root.journaldev=")
    if [ -n "$journaldev" ]; then
        case "$rootfs" in
            xfs)
                rflags="${rflags:+${rflags},}logdev=$journaldev"
                ;;
            reiserfs)
                fsckoptions="-j $journaldev $fsckoptions"
                rflags="${rflags:+${rflags},}jdev=$journaldev"
                ;;
            *) ;;
        esac
    fi

    _rflags_ro="$rflags,ro"
    _rflags_ro="${_rflags_ro##,}"

    while ! mount -t "${rootfs}" -o "$_rflags_ro" "${root#block:}" "$NEWROOT"; do
        warn "Failed to mount -t ${rootfs} -o $_rflags_ro ${root#block:} $NEWROOT"
        fsck_ask_err
    done

    fsckoptions=
    if [ -f "$NEWROOT"/etc/sysconfig/readonly-root ]; then
        # shellcheck disable=SC1090
        . "$NEWROOT"/etc/sysconfig/readonly-root
    fi

    if [ -f "$NEWROOT"/fastboot ]; then
        fastboot=yes
    fi

    if ! getargbool 0 rd.skipfsck; then
        if [ -f "$NEWROOT"/fsckoptions ]; then
            read -r fsckoptions < "$NEWROOT"/fsckoptions
        fi

        if [ -f "$NEWROOT"/forcefsck ] || getargbool 0 forcefsck; then
            fsckoptions="-f $fsckoptions"
        elif [ -f "$NEWROOT"/.autofsck ]; then
            # shellcheck disable=SC1090
            [ -f "$NEWROOT"/etc/sysconfig/autofsck ] \
                && . "$NEWROOT"/etc/sysconfig/autofsck
            if [ "$AUTOFSCK_DEF_CHECK" = "yes" ]; then
                AUTOFSCK_OPT="$AUTOFSCK_OPT -f"
            fi
            if [ -n "$AUTOFSCK_SINGLEUSER" ]; then
                warn "*** Warning -- the system did not shut down cleanly. "
                warn "*** Dropping you to a shell; the system will continue"
                warn "*** when you leave the shell."
                emergency_shell
            fi
            fsckoptions="$AUTOFSCK_OPT $fsckoptions"
        fi
    fi

    rootopts=
    if getargbool 1 rd.fstab -d -n rd_NO_FSTAB \
        && ! getarg rootflags > /dev/null \
        && [ -f "$NEWROOT/etc/fstab" ] \
        && ! [ -L "$NEWROOT/etc/fstab" ]; then
        # if $NEWROOT/etc/fstab contains special mount options for
        # the root filesystem,
        # remount it with the proper options
        rootopts="defaults"
        while read -r dev mp fs opts _ fsck || [ -n "$dev" ]; do
            # skip comments
            [ "${dev%%#*}" != "$dev" ] && continue

            if [ "$mp" = "/" ]; then
                # sanity - determine/fix fstype
                rootfs=$(det_fs "${root#block:}" "$fs")
                rootopts=$opts
                rootfsck=$fsck
                break
            fi
        done < "$NEWROOT/etc/fstab"
    fi

    # we want rootflags (rflags) to take precedence so prepend rootopts to
    # them
    rflags="${rootopts},${rflags}"
    rflags="${rflags#,}"
    rflags="${rflags%,}"

    # backslashes are treated as escape character in fstab
    # esc_root=$(echo ${root#block:} | sed 's,\\,\\\\,g')
    # printf '%s %s %s %s 1 1 \n' "$esc_root" "$NEWROOT" "$rootfs" "$rflags" >/etc/fstab

    if ! getargbool 0 ro && fsck_able "$rootfs" \
        && [ "$rootfsck" != "0" ] && [ -z "$fastboot" ] \
        && ! strstr "${rflags}" _netdev \
        && ! getargbool 0 rd.skipfsck; then
        umount "$NEWROOT"
        fsck_single "${root#block:}" "$rootfs" "$rflags" "$fsckoptions"
    fi

    echo "${root#block:} $NEWROOT $rootfs ${rflags:-defaults} 0 ${rootfsck:-0}" >> /etc/fstab

    if ! ismounted "$NEWROOT"; then
        info "Mounting ${root#block:} with -o ${rflags}"
        mount "$NEWROOT" 2>&1 | vinfo
    elif ! are_lists_eq , "$rflags" "$_rflags_ro" defaults; then
        info "Remounting ${root#block:} with -o ${rflags}"
        mount -o remount "$NEWROOT" 2>&1 | vinfo
    fi

    if ! getargbool 0 rd.skipfsck; then
        [ -f "$NEWROOT"/forcefsck ] && rm -f -- "$NEWROOT"/forcefsck 2> /dev/null
        [ -f "$NEWROOT"/.autofsck ] && rm -f -- "$NEWROOT"/.autofsck 2> /dev/null
    fi
}

if [ -n "$root" ] && [ -z "${root%%block:*}" ]; then
    mount_root
fi
