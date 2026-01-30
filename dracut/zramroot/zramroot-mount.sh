#!/bin/bash
# dracut pre-mount hook for zramroot
# This script runs during the pre-mount phase to setup ZRAM root filesystem

# Note: dracut sources /lib/dracut-lib.sh which provides helper functions like:
# - info, warn, die (logging)
# - getarg (kernel parameter parsing)
# - wait_for_dev (device waiting)

type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

# --- Global Variables ---
CONFIG_FILE="/etc/zramroot.conf"
TRIGGER_PARAMETER="zramroot" # Default

# Load configuration if it exists to get TRIGGER_PARAMETER
if [ -f "${CONFIG_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${CONFIG_FILE}"
fi

# Use configured trigger parameter, default to "zramroot"
TRIGGER="${TRIGGER_PARAMETER:-zramroot}"

# --- CRITICAL: Check for kernel parameter FIRST ---
if ! getarg "${TRIGGER}" >/dev/null; then
    # No trigger parameter - exit silently and let normal boot continue
    info "zramroot: Kernel parameter '${TRIGGER}' not found, skipping ZRAM root setup"
    return 0
fi

info "zramroot: Detected '${TRIGGER}' kernel parameter, starting ZRAM root setup"

# --- Validate device number configuration ---
if [ "$ZRAM_DEVICE_NUM" -eq "$ZRAM_SWAP_DEVICE_NUM" ] && [ "$ZRAM_SWAP_ENABLED" = "yes" ]; then
    warn "zramroot: ZRAM_DEVICE_NUM ($ZRAM_DEVICE_NUM) equals ZRAM_SWAP_DEVICE_NUM ($ZRAM_SWAP_DEVICE_NUM)"
    warn "zramroot: Automatically adjusting ZRAM_SWAP_DEVICE_NUM to $((ZRAM_SWAP_DEVICE_NUM + 1))"
    ZRAM_SWAP_DEVICE_NUM=$((ZRAM_SWAP_DEVICE_NUM + 1))
fi

REAL_ROOT_MNT="/mnt/real_root_rw"  # For persistent logging and copying
DATE_TIME=$(date '+%Y%m%d-%H%M%S' 2>/dev/null || echo "unknown")
ZRAM_TEMP_MNT="/zram_root"  # Temporary mount point for ZRAM
BOOT_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "unknown")

# Log directory will be set after loading config (to support DEBUG_ROOT_MOUNT)
REAL_ROOT_LOG_DIR=""
REAL_ROOT_LOG_FILE=""

# --- Configuration Defaults ---
DEBUG_MODE="no"
DEBUG_ROOT_MOUNT=""
DEBUG_LOG_DIR="/var/log"
DEBUG_LOG_DEVICE=""
ZRAM_SIZE_MiB=0
ZRAM_ALGO="lz4"
ZRAM_FS_TYPE="ext4"
ZRAM_MOUNT_OPTS="noatime"
RAM_MIN_FREE_MiB=512
ZRAM_MIN_FREE_MiB=256
RAM_PREF_FREE_MiB=1024
ZRAM_MAX_FREE_MiB=35840
ZRAM_BUFFER_PERCENT=10
ZRAM_DEVICE_NUM=0
ZRAM_SWAP_ENABLED="yes"
ZRAM_SWAP_DEVICE_NUM=1
ZRAM_SWAP_SIZE_MiB=0
ZRAM_SWAP_ALGO="lz4"
ZRAM_SWAP_PRIORITY=10
ZRAM_EXCLUDE_PATTERNS=""
ZRAM_INCLUDE_PATTERNS=""
ZRAM_MOUNT_ON_DISK=""
ZRAM_PHYSICAL_ROOT_OPTS="rw"
WAIT_TIMEOUT=120

# Load configuration if it exists
if [ -f "${CONFIG_FILE}" ]; then
    info "zramroot: Loading configuration from ${CONFIG_FILE}"
    # shellcheck disable=SC1090
    . "${CONFIG_FILE}"
    
    # Reload trigger just in case
    TRIGGER="${TRIGGER_PARAMETER:-zramroot}"
else
    warn "zramroot: Configuration file ${CONFIG_FILE} not found, using defaults"
fi

# Sanity-check debug log directory to avoid mounting over initramfs root
if [ -z "${DEBUG_LOG_DIR}" ] || [ "${DEBUG_LOG_DIR}" = "/" ]; then
    warn "zramroot: DEBUG_LOG_DIR is empty or '/', forcing /var/log"
    DEBUG_LOG_DIR="/var/log"
fi

# Set up log paths based on DEBUG_LOG_DIR/DEBUG_LOG_DEVICE (and legacy DEBUG_ROOT_MOUNT)
if [ -n "${DEBUG_LOG_DEVICE}" ]; then
    mkdir -p "${DEBUG_LOG_DIR}" 2>/dev/null || true
    if ! mountpoint -q "${DEBUG_LOG_DIR}" 2>/dev/null; then
        mount -o rw "${DEBUG_LOG_DEVICE}" "${DEBUG_LOG_DIR}" 2>/dev/null || true
    fi
    REAL_ROOT_LOG_DIR="${DEBUG_LOG_DIR}"
    info "zramroot: Using DEBUG_LOG_DIR on ${DEBUG_LOG_DEVICE}: ${DEBUG_LOG_DIR}"
elif [ -n "${DEBUG_ROOT_MOUNT}" ]; then
    # Legacy support
    REAL_ROOT_LOG_DIR="${DEBUG_ROOT_MOUNT}"
    info "zramroot: Using DEBUG_ROOT_MOUNT for logging: ${DEBUG_ROOT_MOUNT}"
else
    # Default: log under /var/log on the physical root
    REAL_ROOT_LOG_DIR="${REAL_ROOT_MNT}${DEBUG_LOG_DIR}"
fi
REAL_ROOT_LOG_FILE="${REAL_ROOT_LOG_DIR}/zramroot-${DATE_TIME}.log"

# --- Enhanced Logging Functions ---
# These wrap dracut's logging but also log to physical drive

log_to_physical() {
    local level="$1"
    shift
    local message="$*"

    if [ -w "${REAL_ROOT_LOG_FILE}" ]; then
        local now
        now=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
        echo "${now} ZRAMROOT ${level}: ${message}" >> "${REAL_ROOT_LOG_FILE}" 2>/dev/null || true
    fi
}

log_error() {
    warn "zramroot: ERROR: $*" >&2
    # Always log errors to physical drive
    log_to_physical "ERROR" "$*"
}

log_info() {
    info "zramroot: $*" >&2
    # Log info to physical drive only if debug mode is on
    if [ "${DEBUG_MODE}" = "yes" ]; then
        log_to_physical "INFO" "$*"
    fi
}

log_debug() {
    if [ "${DEBUG_MODE}" = "yes" ]; then
        info "zramroot: DEBUG: $*" >&2
        log_to_physical "DEBUG" "$*"
    fi
}

fallback_to_normal_boot() {
    log_error "$*"
    log_error "Falling back to normal boot (zramroot disabled)"

    # Best-effort cleanup
    if mountpoint -q "${ZRAM_TEMP_MNT}" 2>/dev/null; then
        umount "${ZRAM_TEMP_MNT}" 2>/dev/null || umount -l "${ZRAM_TEMP_MNT}" 2>/dev/null || true
    fi
    if mountpoint -q "${REAL_ROOT_MNT}" 2>/dev/null; then
        umount "${REAL_ROOT_MNT}" 2>/dev/null || umount -l "${REAL_ROOT_MNT}" 2>/dev/null || true
    fi
    if mountpoint -q "/mnt/physical_root" 2>/dev/null; then
        umount "/mnt/physical_root" 2>/dev/null || umount -l "/mnt/physical_root" 2>/dev/null || true
    fi

    return 0
}

# --- Root Device Resolution Helpers ---
resolve_root_device() {
    local root_arg="$1"
    local resolved="$root_arg"

    if [ -z "$resolved" ]; then
        resolved=$(getarg root=)
    fi

    if [ -z "$resolved" ]; then
        echo ""
        return 1
    fi

    # Strip dracut prefix like block: or rd. before device paths
    case "$resolved" in
        block:*)
            resolved="${resolved#block:}"
            ;;
    esac

    case "$resolved" in
        UUID=*|LABEL=*|PARTUUID=*|PARTLABEL=*)
            resolved=$(blkid -o device -t "$resolved" 2>/dev/null | head -n1)
            ;;
        /dev/disk/by-*)
            resolved=$(readlink -f "$resolved" 2>/dev/null || echo "$resolved")
            ;;
    esac

    echo "$resolved"
    return 0
}

get_lvm_root_from_args() {
    local root_arg="$1"
    local lvm_arg
    local vg
    local lv

    # If root= already points at a mapper, prefer it
    if echo "$root_arg" | grep -q '^/dev/mapper/'; then
        echo "$root_arg"
        return 0
    fi

    lvm_arg=$(getarg rd.lvm.lv=)
    if [ -n "$lvm_arg" ]; then
        for item in $lvm_arg; do
            vg="${item%%/*}"
            lv="${item#*/}"
            if [ -n "$vg" ] && [ -n "$lv" ]; then
                echo "/dev/mapper/${vg}-${lv}"
                return 0
            fi
        done
    fi

    echo ""
    return 1
}

get_root_uuid() {
    local root_arg="$1"
    local root_dev="$2"

    case "$root_arg" in
        UUID=*) echo "${root_arg#UUID=}"; return 0 ;;
        PARTUUID=*) echo "${root_arg#PARTUUID=}"; return 0 ;;
    esac

    if [ -n "$root_dev" ] && command -v blkid >/dev/null 2>&1; then
        blkid -o value -s UUID "$root_dev" 2>/dev/null | head -n1
        return 0
    fi

    echo ""
    return 1
}

find_luks_mapper_candidate() {
    local root_uuid="$1"
    local arg
    local item
    local uuid
    local name

    arg=$(getarg rd.luks.name=)
    if [ -n "$arg" ]; then
        for item in $arg; do
            uuid="${item%%=*}"
            name="${item#*=}"
            if [ -n "$name" ]; then
                if [ -z "$root_uuid" ] || [ "$uuid" = "$root_uuid" ]; then
                    echo "/dev/mapper/$name"
                    return 0
                fi
            fi
        done
    fi

    arg=$(getarg rd.luks.uuid=)
    if [ -n "$arg" ]; then
        for uuid in $arg; do
            uuid="${uuid#UUID=}"
            if [ -n "$uuid" ]; then
                if [ -z "$root_uuid" ] || [ "$uuid" = "$root_uuid" ]; then
                    if echo "$uuid" | grep -q '^luks-'; then
                        echo "/dev/mapper/$uuid"
                    else
                        echo "/dev/mapper/luks-$uuid"
                    fi
                    return 0
                fi
            fi
        done
    fi

    echo ""
    return 1
}

# --- Progress Bar Functions ---
ESC='\033'
GREEN="${ESC}[0;32m"
YELLOW="${ESC}[1;33m"
BLUE="${ESC}[0;34m"
NC="${ESC}[0m"

draw_parallel_progress_bar() {
    local percentage=$1
    local total_threads=$2
    local active_threads=${3:-$total_threads}
    local bar_width=50
    local filled=$((percentage * bar_width / 100))
    local empty=$((bar_width - filled))

    local bar=""
    local i=0
    while [ $i -lt $filled ]; do
        bar="${bar}█"
        i=$((i + 1))
    done
    i=0
    while [ $i -lt $empty ]; do
        bar="${bar}░"
        i=$((i + 1))
    done

    printf "\r${BLUE}[${GREEN}%s${BLUE}] ${GREEN}%3d%%${NC} ${YELLOW}[%d/%d threads]${NC} Copying...     " \
        "$bar" "$percentage" "$active_threads" "$total_threads"

    if [ "${DEBUG_MODE}" = "yes" ]; then
        log_to_physical "PROGRESS" "${percentage}% (${active_threads}/${total_threads} threads)"
    fi
}

# --- Build rsync filters from configuration ---
build_rsync_filters() {
    local filters=""

    # Add include patterns first (they take precedence)
    if [ -n "$ZRAM_INCLUDE_PATTERNS" ]; then
        log_debug "Processing include patterns: $ZRAM_INCLUDE_PATTERNS"
        for pattern in $ZRAM_INCLUDE_PATTERNS; do
            filters="$filters --include=$pattern"
            log_debug "  Include: $pattern"
        done
    fi

    # Add mount-on-disk paths to exclude patterns
    local exclude_patterns="$ZRAM_EXCLUDE_PATTERNS"
    if [ -n "$ZRAM_MOUNT_ON_DISK" ]; then
        log_debug "Adding mount-on-disk paths to exclusions: $ZRAM_MOUNT_ON_DISK"
        for mount_path in $ZRAM_MOUNT_ON_DISK; do
            mount_path=$(echo "$mount_path" | sed 's:^/::; s:/$::')
            if [ -n "$mount_path" ]; then
                exclude_patterns="$exclude_patterns /$mount_path /$mount_path/*"
                log_debug "  Excluding (will bind-mount): /$mount_path"
            fi
        done
    fi

    # Add exclude patterns
    if [ -n "$exclude_patterns" ]; then
        log_debug "Processing exclude patterns: $exclude_patterns"
        for pattern in $exclude_patterns; do
            filters="$filters --exclude=$pattern"
            log_debug "  Exclude: $pattern"
        done
    fi

    echo "$filters"
}

# --- Detect optimal thread count ---
detect_optimal_threads() {
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo "1")
    local available_ram_mb
    available_ram_mb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null)
    if ! echo "$available_ram_mb" | grep -q '^[0-9][0-9]*$'; then
        available_ram_mb=$(awk '/MemFree/ {print $2}' /proc/meminfo 2>/dev/null)
    fi
    if ! echo "$available_ram_mb" | grep -q '^[0-9][0-9]*$'; then
        available_ram_mb=0
    fi
    available_ram_mb=$((available_ram_mb / 1024))

    local optimal_threads=$cpu_cores
    local max_ram_threads=1
    if [ "$available_ram_mb" -gt 0 ]; then
        max_ram_threads=$((available_ram_mb / 75))
    fi

    if [ "$max_ram_threads" -lt "$optimal_threads" ]; then
        optimal_threads=$max_ram_threads
    fi

    if [ "$optimal_threads" -lt 1 ]; then
        optimal_threads=1
    elif [ "$optimal_threads" -gt 16 ]; then
        optimal_threads=16
    fi

    log_debug "Detected ${cpu_cores} CPU cores, ${available_ram_mb}MB RAM"
    log_debug "Using ${optimal_threads} parallel rsync operations"

    echo "$optimal_threads"
}

# --- Work distribution for parallel copy ---
create_work_distribution() {
    local source="$1"
    local thread_count="$2"
    local work_dir="/tmp/parallel_rsync_work"

    if ! echo "$thread_count" | grep -q '^[0-9][0-9]*$'; then
        thread_count=1
    fi

    log_debug "Creating work distribution for ${thread_count} threads"

    mkdir -p "$work_dir" 2>/dev/null || true
    if [ ! -d "$work_dir" ]; then
        work_dir="/run/parallel_rsync_work"
        mkdir -p "$work_dir" 2>/dev/null || true
    fi
    if [ ! -d "$work_dir" ]; then
        log_error "Cannot create work directory for parallel copy"
        echo ""
        return 1
    fi
    rm -f "${work_dir}"/job_* 2>/dev/null || true

    # Get top-level directories and their sizes
    local dir_list="${work_dir}/directories.list"
    du -sk "${source}"/* 2>/dev/null | \
        grep -v -e '/dev$' -e '/proc$' -e '/sys$' -e '/tmp$' -e '/run$' \
                -e '/mnt$' -e '/media$' -e '/lost+found$' 2>/dev/null | \
        sort -rn > "$dir_list" || true

    # Initialize job files
    local i=0
    while [ $i -lt $thread_count ]; do
        touch "${work_dir}/job_${i}.list"
        echo "0" > "${work_dir}/job_${i}.size"
        i=$((i + 1))
    done

    # Distribute directories across jobs
    while IFS=$'\t' read -r size dir_path; do
        # Find job with minimum size
        local min_job=0
        local min_size
        min_size=$(cat "${work_dir}/job_0.size" 2>/dev/null || echo 0)

        i=1
        while [ $i -lt $thread_count ]; do
            local current_size
            current_size=$(cat "${work_dir}/job_${i}.size" 2>/dev/null || echo 0)
            if [ "$current_size" -lt "$min_size" ]; then
                min_size=$current_size
                min_job=$i
            fi
            i=$((i + 1))
        done

        # Add to job with minimum size
        local dir_name
        dir_name=$(basename "$dir_path")
        echo "$dir_name" >> "${work_dir}/job_${min_job}.list"
        local new_size=$((min_size + size))
        echo "$new_size" > "${work_dir}/job_${min_job}.size"
    done < "$dir_list"

    # Add root files to job 0
    echo "ROOT_FILES" >> "${work_dir}/job_0.list"

    echo "$work_dir"
}

# --- Parallel copy with progress ---
copy_with_parallel_progress() {
    local source="$1"
    local dest="$2"

    log_info "Starting parallel copy from ${source} to ${dest}"

    local thread_count
    thread_count=$(detect_optimal_threads)
    if ! echo "$thread_count" | grep -q '^[0-9][0-9]*$'; then
        thread_count=1
    fi

    local total_kb
    total_kb=$(du -sk "$source" 2>/dev/null | awk '{print $1}')

    if [ -z "$total_kb" ] || [ "$total_kb" -eq 0 ]; then
        log_error "Could not determine source directory size"
        return 1
    fi

    log_debug "Total size to copy: ${total_kb} KB ($((total_kb / 1024)) MB)"

    local work_dir
    work_dir=$(create_work_distribution "$source" "$thread_count")
    if [ -z "$work_dir" ] || [ ! -d "$work_dir" ]; then
        log_error "Parallel copy setup failed"
        return 1
    fi

    # Build user-configured filters
    local USER_FILTERS
    USER_FILTERS=$(build_rsync_filters)
    local RSYNC_EXCLUDE="--exclude=/dev/* --exclude=/proc/* --exclude=/sys/* --exclude=/tmp/* --exclude=/run/* --exclude=/mnt/* --exclude=/media/* --exclude=/lost+found --exclude=/var/log/journal/*"

    if [ -n "$USER_FILTERS" ]; then
        log_info "Applying user-configured include/exclude filters"
        # shellcheck disable=SC2086
        RSYNC_EXCLUDE="$RSYNC_EXCLUDE $USER_FILTERS"
    fi

    # Display header
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "            Copying filesystem to ZRAM (${thread_count} parallel operations)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    draw_parallel_progress_bar 0 "$thread_count"

    # Start rsync jobs in parallel
    local start_time
    start_time=$(date +%s)

    local i=0
    while [ $i -lt $thread_count ]; do
        local job_file="${work_dir}/job_${i}.list"
        local job_log="${work_dir}/job_${i}.log"

        if [ -s "$job_file" ]; then
            (
                while read -r item; do
                    local rsync_exit=1
                    local retry_count=0
                    local max_retries=3

                    while [ $rsync_exit -ne 0 ] && [ $retry_count -lt $max_retries ]; do
                        if [ "$item" = "ROOT_FILES" ]; then
                            # shellcheck disable=SC2086
                            rsync -ax \
                                  --include="/*" --exclude="/*/" \
                                  --exclude="/dev" --exclude="/proc" --exclude="/sys" --exclude="/tmp" \
                                  --exclude="/run" --exclude="/mnt" --exclude="/media" --exclude="/lost+found" \
                                  $USER_FILTERS \
                                  "${source}/" "${dest}/" 2>>"$job_log"
                            rsync_exit=$?
                        else
                            mkdir -p "${dest}/${item}"
                            # shellcheck disable=SC2086
                            rsync -ax --delete \
                                  $RSYNC_EXCLUDE \
                                  "${source}/${item}/" "${dest}/${item}/" 2>>"$job_log"
                            rsync_exit=$?
                        fi

                        if [ $rsync_exit -ne 0 ]; then
                            retry_count=$((retry_count + 1))
                            if [ $retry_count -lt $max_retries ]; then
                                echo "Retry $retry_count/$max_retries for $item" >> "$job_log"
                                sleep 1
                            else
                                echo "FAILED after $max_retries retries: $item (exit code: $rsync_exit)" >> "$job_log"
                            fi
                        fi
                    done
                done < "$job_file"
            ) &

            local job_pid=$!
            echo "$job_pid" > "${work_dir}/job_${i}.pid"
            log_debug "Started job $i with PID $job_pid"
        fi
        i=$((i + 1))
    done

    # Monitor progress
    local last_percentage=0
    local max_wait=1800  # 30 minutes timeout

    while true; do
        local active_jobs=0
        i=0
        while [ $i -lt $thread_count ]; do
            local pid_file="${work_dir}/job_${i}.pid"
            if [ -f "$pid_file" ]; then
                local pid
                pid=$(cat "$pid_file")
                if kill -0 "$pid" 2>/dev/null; then
                    active_jobs=$((active_jobs + 1))
                fi
            fi
            i=$((i + 1))
        done

        if [ $active_jobs -eq 0 ]; then
            break
        fi

        # Calculate progress
        local current_kb
        current_kb=$(du -sk "$dest" 2>/dev/null | awk '{print $1}')
        local percentage=$((current_kb * 100 / total_kb))

        if [ $percentage -gt 99 ]; then
            percentage=99
        fi

        if [ $percentage -ne $last_percentage ]; then
            draw_parallel_progress_bar $percentage "$thread_count" "$active_jobs"
            last_percentage=$percentage
        fi

        # Check timeout
        local elapsed=$(($(date +%s) - start_time))
        if [ $elapsed -gt $max_wait ]; then
            log_error "Copy operation timed out after ${max_wait} seconds"
            return 1
        fi

        sleep 2
    done

    # Show 100% completion
    draw_parallel_progress_bar 100 "$thread_count" 0
    echo ""
    echo ""

    # Calculate and log copy speed
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    if [ $duration -gt 0 ]; then
        local speed_mb_s
        speed_mb_s=$(awk -v kb="$total_kb" -v sec="$duration" 'BEGIN{printf "%.1f", (kb/1024)/sec}')
        log_info "Parallel copy completed in ${duration} seconds (${speed_mb_s} MB/s)"
    else
        log_info "Parallel copy completed successfully"
    fi

    # Clean up
    rm -rf "$work_dir"

    return 0
}

# --- ZRAM Swap Setup ---
setup_zram_swap() {
    local swap_device_num="${ZRAM_SWAP_DEVICE_NUM}"
    local max_attempts=10
    local attempt=0
    local swap_setup_ok=0
    local zram_swap_device=""

    log_info "Setting up ZRAM swap..."

    # Calculate swap size if set to auto (0)
    local swap_size_bytes
    if [ "$ZRAM_SWAP_SIZE_MiB" -eq 0 ]; then
        local total_ram_mib
        total_ram_mib=$(($(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024))

        # Auto: 25% of total RAM, capped at 4GB, minimum 512MB
        local auto_swap=$((total_ram_mib / 4))
        if [ $auto_swap -lt 512 ]; then
            auto_swap=512
        elif [ $auto_swap -gt 4096 ]; then
            auto_swap=4096
        fi

        swap_size_bytes=$((auto_swap * 1024 * 1024))
        log_debug "Auto-calculated ZRAM swap size: ${auto_swap} MiB"
    else
        swap_size_bytes=$((ZRAM_SWAP_SIZE_MiB * 1024 * 1024))
        log_debug "Using configured ZRAM swap size: ${ZRAM_SWAP_SIZE_MiB} MiB"
    fi

    # Try to set up ZRAM swap, retrying on different devices if needed
    while [ $attempt -lt $max_attempts ] && [ $swap_setup_ok -eq 0 ]; do
        local candidate_num=$((swap_device_num + attempt))

        # Skip the device number used for root
        if [ "$candidate_num" -eq "$ZRAM_DEVICE_NUM" ]; then
            attempt=$((attempt + 1))
            continue
        fi

        zram_swap_device="/dev/zram${candidate_num}"
        log_info "Attempting ZRAM swap setup on ${zram_swap_device} (attempt $((attempt + 1))/${max_attempts})..."

        # Check if device exists (should have been created when module was loaded)
        if [ ! -b "$zram_swap_device" ]; then
            log_error "ZRAM swap device ${zram_swap_device} does not exist"
            attempt=$((attempt + 1))
            continue
        fi

        # Reset the device to ensure clean state
        # First disable swap and unmount if in use
        swapoff "$zram_swap_device" 2>/dev/null || true
        umount "$zram_swap_device" 2>/dev/null || true
        if [ -w "/sys/block/zram${candidate_num}/reset" ]; then
            log_debug "Resetting ZRAM swap device ${zram_swap_device}"
            echo 1 > "/sys/block/zram${candidate_num}/reset" 2>/dev/null || true
        else
            log_error "Cannot reset ${zram_swap_device} - reset not writable"
            attempt=$((attempt + 1))
            continue
        fi

        # Configure compression algorithm
        if [ -w "/sys/block/zram${candidate_num}/comp_algorithm" ]; then
            if ! echo "$ZRAM_SWAP_ALGO" > "/sys/block/zram${candidate_num}/comp_algorithm" 2>/dev/null; then
                log_error "Failed to set ZRAM swap compression algorithm on ${zram_swap_device}"
                attempt=$((attempt + 1))
                continue
            fi
        else
            log_error "comp_algorithm not writable for ${zram_swap_device}"
            attempt=$((attempt + 1))
            continue
        fi

        # Set size
        if [ -w "/sys/block/zram${candidate_num}/disksize" ]; then
            if ! echo "$swap_size_bytes" > "/sys/block/zram${candidate_num}/disksize" 2>/dev/null; then
                log_error "Failed to set ZRAM swap size on ${zram_swap_device}"
                attempt=$((attempt + 1))
                continue
            fi
        else
            log_error "disksize not writable for ${zram_swap_device}"
            attempt=$((attempt + 1))
            continue
        fi

        # Format as swap
        if ! mkswap "$zram_swap_device" >/dev/null 2>&1; then
            log_error "Failed to format ZRAM swap on ${zram_swap_device}"
            attempt=$((attempt + 1))
            continue
        fi

        # Success!
        swap_setup_ok=1
        log_info "ZRAM swap device ${zram_swap_device} configured successfully"
    done

    # Only add to fstab if swap setup succeeded
    if [ $swap_setup_ok -eq 1 ]; then
        if [ -f "${ZRAM_TEMP_MNT}/etc/fstab" ]; then
            echo "" >> "${ZRAM_TEMP_MNT}/etc/fstab"
            echo "# ZRAM Swap (replaces original drive swap for safety)" >> "${ZRAM_TEMP_MNT}/etc/fstab"
            echo "$zram_swap_device none swap sw,pri=${ZRAM_SWAP_PRIORITY} 0 0" >> "${ZRAM_TEMP_MNT}/etc/fstab"
            log_debug "Added ZRAM swap entry to /etc/fstab with priority ${ZRAM_SWAP_PRIORITY}"
        fi
        log_info "ZRAM swap setup complete"
    else
        log_error "ZRAM swap setup failed after ${max_attempts} attempts - swap will not be available"
        log_error "System will boot without ZRAM swap"
    fi
}

# ============================================================================
# MAIN EXECUTION STARTS HERE
# ============================================================================

log_info "=== STARTING ZRAM ROOT SETUP PROCESS ==="
log_debug "Boot ID: ${BOOT_ID}"

# --- Get the root device from dracut ---
# In dracut, the root device is available as $root
ROOT_ARG=$(getarg root=)
REAL_ROOT_DEVICE=$(resolve_root_device "${root}")

if [ -z "$REAL_ROOT_DEVICE" ]; then
    log_error "Root device not specified, cannot proceed"
    log_error "Falling back to normal boot (zramroot disabled)"
    return 0
fi

# If root is encrypted and not already a mapper device, prefer the LUKS mapper
ROOT_UUID=$(get_root_uuid "${ROOT_ARG}" "${REAL_ROOT_DEVICE}")
ROOT_TYPE=$(blkid -o value -s TYPE "${REAL_ROOT_DEVICE}" 2>/dev/null || echo "")
if [ "$ROOT_TYPE" = "crypto_LUKS" ] && ! echo "${REAL_ROOT_DEVICE}" | grep -q '^/dev/mapper/'; then
    LUKS_MAPPER=$(find_luks_mapper_candidate "${ROOT_UUID}")
    if [ -n "$LUKS_MAPPER" ]; then
        log_info "Detected encrypted root, waiting for mapper device: ${LUKS_MAPPER}"
        REAL_ROOT_DEVICE="$LUKS_MAPPER"
    fi
fi

# If the device is an LVM2 member, activate VG/LV and point to the LV
if [ "$ROOT_TYPE" = "LVM2_member" ]; then
    if command -v vgchange >/dev/null 2>&1; then
        log_info "Detected LVM2 member, activating volume groups"
        vgchange -ay >/dev/null 2>&1 || true
    fi

    LVM_ROOT=$(get_lvm_root_from_args "${ROOT_ARG}")
    if [ -n "$LVM_ROOT" ]; then
        log_info "Using LVM root device: ${LVM_ROOT}"
        REAL_ROOT_DEVICE="$LVM_ROOT"
    fi
fi

log_info "Physical root device: ${REAL_ROOT_DEVICE}"

# --- Wait for the root device to be available ---
# This is critical for LUKS-encrypted systems where the device mapper
# needs time to unlock and create the device
log_info "Waiting for root device to become available (timeout: ${WAIT_TIMEOUT}s)..."

# Try to wait for device using dracut's wait_for_dev function
if command -v wait_for_dev >/dev/null 2>&1; then
    if ! wait_for_dev "${REAL_ROOT_DEVICE}" "${WAIT_TIMEOUT}"; then
        log_error "Root device ${REAL_ROOT_DEVICE} did not become available within ${WAIT_TIMEOUT} seconds"
        log_error "Falling back to normal boot (zramroot disabled)"
        return 0
    fi
else
    # Fallback: manual wait loop
    wait_count=0
    while [ $wait_count -lt "${WAIT_TIMEOUT}" ]; do
        if [ -b "${REAL_ROOT_DEVICE}" ] || [ -e "${REAL_ROOT_DEVICE}" ]; then
            log_info "Root device is now available"
            break
        fi
        sleep 1
        wait_count=$((wait_count + 1))
    done

    if [ $wait_count -ge "${WAIT_TIMEOUT}" ]; then
        log_error "Root device ${REAL_ROOT_DEVICE} did not become available within ${WAIT_TIMEOUT} seconds"
        log_error "Device may not exist or LUKS unlock may have failed"
        log_error "Falling back to normal boot (zramroot disabled)"
        return 0
    fi
fi

log_info "Root device ${REAL_ROOT_DEVICE} is available"

# --- Mount physical root for logging and copying ---
log_info "Mounting physical root at ${REAL_ROOT_MNT} for logging and copying"
mkdir -p "${REAL_ROOT_MNT}"

if mount -o rw "${REAL_ROOT_DEVICE}" "${REAL_ROOT_MNT}" 2>&1; then
    log_info "Physical root mounted successfully (read-write)"
else
    mount_error=$?
    log_error "Failed to mount physical root device ${REAL_ROOT_DEVICE} (exit code: $mount_error)"
    log_error "Device exists: $([ -e "${REAL_ROOT_DEVICE}" ] && echo yes || echo no)"
    log_error "Device is block device: $([ -b "${REAL_ROOT_DEVICE}" ] && echo yes || echo no)"
    log_error "Attempting to get filesystem type..."
    blkid "${REAL_ROOT_DEVICE}" 2>&1 | while read -r line; do log_error "blkid: $line"; done
    fallback_to_normal_boot "Cannot mount physical root - check LUKS unlock succeeded"
    return 0
fi

# Set up logging regardless of DEBUG_ROOT_MOUNT
if [ -n "${DEBUG_ROOT_MOUNT}" ]; then
    # Using separate partition for debug logs
    mkdir -p "${DEBUG_ROOT_MOUNT}" 2>/dev/null || true
    REAL_ROOT_LOG_DIR="${DEBUG_ROOT_MOUNT}"
    REAL_ROOT_LOG_FILE="${REAL_ROOT_LOG_DIR}/zramroot-${DATE_TIME}.log"
else
    # Using standard location on mounted root
    mkdir -p "${REAL_ROOT_LOG_DIR}"
fi

touch "${REAL_ROOT_LOG_FILE}" 2>/dev/null || warn "zramroot: Cannot create log file"

# Write initial log header
log_to_physical "INFO" "========================================="
log_to_physical "INFO" "ZRAMROOT Boot Process Started"
log_to_physical "INFO" "Boot ID: ${BOOT_ID}"
log_to_physical "INFO" "Date/Time: ${DATE_TIME}"
log_to_physical "INFO" "Physical Root Device: ${REAL_ROOT_DEVICE}"
log_to_physical "INFO" "========================================="

# --- Set compression ratio based on algorithm ---
case "${ZRAM_ALGO}" in
    "zstd")
        ESTIMATED_COMPRESSION_RATIO=3.0
        ;;
    "lz4hc")
        ESTIMATED_COMPRESSION_RATIO=2.5
        ;;
    "lz4")
        ESTIMATED_COMPRESSION_RATIO=2.0
        ;;
    "lzo"|"lzo-rle")
        ESTIMATED_COMPRESSION_RATIO=1.8
        ;;
    *)
        ESTIMATED_COMPRESSION_RATIO=2.2
        ;;
esac

log_debug "Using compression ratio estimate of ${ESTIMATED_COMPRESSION_RATIO} for algorithm ${ZRAM_ALGO}"

# --- Calculate ZRAM size ---
ZRAM_DEVICE="/dev/zram${ZRAM_DEVICE_NUM}"

if [ "$ZRAM_SIZE_MiB" -eq 0 ]; then
    log_info "Auto-calculating ZRAM size..."

    # Get used space on root
    local root_used_kb
    root_used_kb=$(df -k "${REAL_ROOT_MNT}" | awk 'NR==2 {print $3}')
    local root_used_mib=$((root_used_kb / 1024))

    log_debug "Root filesystem used: ${root_used_mib} MiB"

    # Add buffer
    local buffer_mib=$((root_used_mib * ZRAM_BUFFER_PERCENT / 100))
    local total_needed_mib=$((root_used_mib + buffer_mib))

    log_debug "With ${ZRAM_BUFFER_PERCENT}% buffer: ${total_needed_mib} MiB"

    # Apply compression ratio - use awk for proper floating-point division
    local compressed_mib
    compressed_mib=$(awk -v total="$total_needed_mib" -v ratio="$ESTIMATED_COMPRESSION_RATIO" 'BEGIN{printf "%.0f", total / ratio}')

    log_debug "After compression (${ESTIMATED_COMPRESSION_RATIO}x): ${compressed_mib} MiB"

    # Check RAM availability
    local total_ram_mib
    total_ram_mib=$(($(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024))
    local available_ram_mib
    available_ram_mib=$(($(awk '/MemAvailable/ {print $2}' /proc/meminfo) / 1024))

    log_debug "Total RAM: ${total_ram_mib} MiB, Available: ${available_ram_mib} MiB"

    # Calculate required RAM
    local required_ram=$((compressed_mib + ZRAM_MIN_FREE_MiB + RAM_MIN_FREE_MiB))

    if [ $available_ram_mib -lt $required_ram ]; then
        log_error "Insufficient RAM: need ${required_ram} MiB, have ${available_ram_mib} MiB"
        fallback_to_normal_boot "Not enough RAM for ZRAM root"
        return 0
    fi

    # Add extra free space if RAM allows
    local preferred_required=$((compressed_mib + ZRAM_MIN_FREE_MiB + RAM_PREF_FREE_MiB))

    if [ $available_ram_mib -ge $preferred_required ]; then
        local extra_space=$((available_ram_mib - preferred_required))
        if [ $extra_space -gt $ZRAM_MAX_FREE_MiB ]; then
            extra_space=$ZRAM_MAX_FREE_MiB
        fi
        ZRAM_SIZE_MiB=$((compressed_mib + ZRAM_MIN_FREE_MiB + extra_space))
    else
        ZRAM_SIZE_MiB=$((compressed_mib + ZRAM_MIN_FREE_MiB))
    fi

    log_info "Calculated ZRAM size: ${ZRAM_SIZE_MiB} MiB"
else
    log_info "Using manually configured ZRAM size: ${ZRAM_SIZE_MiB} MiB"
fi

# --- Load ZRAM kernel module ---
log_info "Loading ZRAM kernel module..."
# Calculate how many zram devices we need (root + swap if enabled)
local num_zram_devices=$((ZRAM_DEVICE_NUM + 1))
if [ "${ZRAM_SWAP_ENABLED}" = "yes" ]; then
    # Need devices for both root and swap
    local min_for_swap=$((ZRAM_SWAP_DEVICE_NUM + 1))
    if [ $min_for_swap -gt $num_zram_devices ]; then
        num_zram_devices=$min_for_swap
    fi
fi
log_debug "Loading zram module with num_devices=${num_zram_devices}"
modprobe zram num_devices=${num_zram_devices} 2>/dev/null || log_error "Failed to load ZRAM module"

# --- Wait for ZRAM control interface with polling ---
log_info "Waiting for ZRAM control interface..."
local zram_wait=0
local zram_max_wait=30
while [ $zram_wait -lt $zram_max_wait ]; do
    if [ -e /sys/class/zram-control ] || [ -e "/sys/block/zram${ZRAM_DEVICE_NUM}" ]; then
        log_debug "ZRAM control interface available after ${zram_wait}s"
        break
    fi
    sleep 1
    zram_wait=$((zram_wait + 1))
    if [ $((zram_wait % 5)) -eq 0 ]; then
        log_debug "Still waiting for ZRAM control interface... (${zram_wait}s/${zram_max_wait}s)"
    fi
done

# Ensure zram-control or /sys/block/zramX is available
if [ ! -e /sys/class/zram-control ] && [ ! -e "/sys/block/zram${ZRAM_DEVICE_NUM}" ]; then
    log_error "zram-control not available after ${zram_max_wait}s (zram module missing or not loaded)"
    log_error "Ensure the kernel has CONFIG_ZRAM enabled and the module is included in initramfs"
    fallback_to_normal_boot "ZRAM device control not available"
    return 0
fi

# --- Create/Configure ZRAM device with retries ---
local zram_size_bytes=$((ZRAM_SIZE_MiB * 1024 * 1024))
local setup_ok=0
local attempt=0

while [ $attempt -lt 10 ]; do
    local candidate_num=$((ZRAM_DEVICE_NUM + attempt))
    if [ "$candidate_num" -eq "$ZRAM_SWAP_DEVICE_NUM" ]; then
        attempt=$((attempt + 1))
        continue
    fi

    ZRAM_DEVICE_NUM="$candidate_num"
    ZRAM_DEVICE="/dev/zram${ZRAM_DEVICE_NUM}"

    log_info "Creating ZRAM device ${ZRAM_DEVICE} (attempt $((attempt + 1))/10)..."

    if [ -b "$ZRAM_DEVICE" ]; then
        log_debug "ZRAM device ${ZRAM_DEVICE} already exists"
    else
        if [ -w /sys/class/zram-control/hot_add ]; then
            echo "$ZRAM_DEVICE_NUM" > /sys/class/zram-control/hot_add 2>/dev/null || \
                log_error "Failed to create ZRAM device"
        else
            log_error "hot_add not writable; cannot create ZRAM device"
            # Fallback: try creating devices via modprobe option
            modprobe zram num_devices=$((ZRAM_DEVICE_NUM + 1)) 2>/dev/null || true
        fi
    fi

    # Reset existing ZRAM device if needed
    if [ -b "$ZRAM_DEVICE" ] && [ -w "/sys/block/zram${ZRAM_DEVICE_NUM}/reset" ]; then
        log_info "Resetting existing ZRAM device ${ZRAM_DEVICE}"
        swapoff "$ZRAM_DEVICE" 2>/dev/null || true
        umount "$ZRAM_DEVICE" 2>/dev/null || umount -l "$ZRAM_DEVICE" 2>/dev/null || true
        echo 1 > "/sys/block/zram${ZRAM_DEVICE_NUM}/reset" 2>/dev/null || \
            log_error "Failed to reset ${ZRAM_DEVICE}"
    fi

    log_info "Configuring ZRAM device with ${ZRAM_ALGO} compression..."

    if [ -w "/sys/block/zram${ZRAM_DEVICE_NUM}/comp_algorithm" ]; then
        echo "$ZRAM_ALGO" > "/sys/block/zram${ZRAM_DEVICE_NUM}/comp_algorithm" || \
            log_error "Failed to set compression algorithm"
    fi

    if [ -w "/sys/block/zram${ZRAM_DEVICE_NUM}/disksize" ]; then
        if echo "$zram_size_bytes" > "/sys/block/zram${ZRAM_DEVICE_NUM}/disksize" 2>/dev/null; then
            setup_ok=1
        fi
    else
        # Fallback to zramctl if sysfs is not writable
        if command -v zramctl >/dev/null 2>&1; then
            zramctl --reset "$ZRAM_DEVICE" 2>/dev/null || true
            if zramctl --algorithm "$ZRAM_ALGO" --size "$zram_size_bytes" "$ZRAM_DEVICE" 2>/dev/null; then
                setup_ok=1
            fi
        fi
    fi

    if [ "$setup_ok" -eq 1 ]; then
        break
    fi

    log_error "ZRAM setup failed for ${ZRAM_DEVICE}, trying next device"
    attempt=$((attempt + 1))
done

if [ "$setup_ok" -ne 1 ]; then
    fallback_to_normal_boot "Failed to set up ZRAM device after multiple attempts"
    return 0
fi

log_info "ZRAM device configured: ${ZRAM_SIZE_MiB} MiB with ${ZRAM_ALGO} compression"

# --- Format ZRAM device ---
log_info "Formatting ZRAM device with ${ZRAM_FS_TYPE}..."

case "${ZRAM_FS_TYPE}" in
    "ext4")
        if ! command -v mkfs.ext4 >/dev/null 2>&1; then
            fallback_to_normal_boot "mkfs.ext4 not found in initramfs - install e2fsprogs and rebuild initramfs"
            return 0
        fi
        mkfs.ext4 -F -q "$ZRAM_DEVICE" || { fallback_to_normal_boot "Failed to format ZRAM as ext4"; return 0; }
        ;;
    "btrfs")
        if ! command -v mkfs.btrfs >/dev/null 2>&1; then
            fallback_to_normal_boot "mkfs.btrfs not found in initramfs - install btrfs-progs and rebuild initramfs"
            return 0
        fi
        mkfs.btrfs -f "$ZRAM_DEVICE" || { fallback_to_normal_boot "Failed to format ZRAM as btrfs"; return 0; }
        ;;
    "xfs")
        if ! command -v mkfs.xfs >/dev/null 2>&1; then
            fallback_to_normal_boot "mkfs.xfs not found in initramfs - install xfsprogs and rebuild initramfs"
            return 0
        fi
        mkfs.xfs -f "$ZRAM_DEVICE" || { fallback_to_normal_boot "Failed to format ZRAM as xfs"; return 0; }
        ;;
    *)
        fallback_to_normal_boot "Unsupported filesystem type: ${ZRAM_FS_TYPE}"
        return 0
        ;;
esac

log_info "ZRAM device formatted successfully"

# --- Mount ZRAM device ---
log_info "Mounting ZRAM device at ${ZRAM_TEMP_MNT}..."
mkdir -p "${ZRAM_TEMP_MNT}"

if mount -t "${ZRAM_FS_TYPE}" -o "rw,${ZRAM_MOUNT_OPTS}" "$ZRAM_DEVICE" "${ZRAM_TEMP_MNT}"; then
    log_info "ZRAM device mounted successfully"

    # --- Copy filesystem to ZRAM ---
    log_info "Copying root filesystem to ZRAM..."

    if copy_with_parallel_progress "${REAL_ROOT_MNT}" "${ZRAM_TEMP_MNT}"; then
        # --- Create required directories in ZRAM root ---
        log_debug "Creating required system directories in ZRAM root"
        for dir in dev proc sys tmp run mnt media; do
            mkdir -p "${ZRAM_TEMP_MNT}/${dir}"
            chmod 755 "${ZRAM_TEMP_MNT}/${dir}"
        done

        # --- Modify /etc/fstab in ZRAM root ---
        if [ -f "${ZRAM_TEMP_MNT}/etc/fstab" ]; then
            log_debug "Backing up and modifying /etc/fstab in ZRAM root"
            cp "${ZRAM_TEMP_MNT}/etc/fstab" "${ZRAM_TEMP_MNT}/etc/fstab.zram_backup"

            local temp_fstab="/tmp/fstab_temp.$$"
            local vg_name=""

            # Try to detect VG name from root device for LVM-based systems (Qubes)
            # Note: LVM uses single dash to separate VG-LV names, double dash for literal dashes
            # So "my--vg-root" means VG="my-vg", LV="root"
            if echo "${REAL_ROOT_DEVICE}" | grep -q "/dev/mapper/"; then
                # Try dmsetup first for accurate VG name (handles dashes correctly)
                local dm_name=$(basename "${REAL_ROOT_DEVICE}")
                if command -v dmsetup >/dev/null 2>&1; then
                    # Get the LVM name which shows VG/LV format
                    local lvm_info=$(dmsetup info --noheadings -c -o name "${dm_name}" 2>/dev/null)
                    if [ -n "$lvm_info" ] && command -v lvs >/dev/null 2>&1; then
                        vg_name=$(lvs --noheadings -o vg_name "/dev/mapper/${dm_name}" 2>/dev/null | tr -d ' ')
                    fi
                fi
                # Fallback to regex if dmsetup/lvs didn't work
                # This handles the common case where VG name has no dashes
                if [ -z "$vg_name" ]; then
                    vg_name=$(echo "${REAL_ROOT_DEVICE}" | sed 's|/dev/mapper/\([^-]*\)-.*|\1|')
                fi
            elif echo "${REAL_ROOT_DEVICE}" | grep -q "/dev/.*/"; then
                vg_name=$(echo "${REAL_ROOT_DEVICE}" | sed 's|/dev/\([^/]*\)/.*|\1|')
            fi

            # Comment out various mount points
            sed 's|^\([^#].*[[:space:]]/[[:space:]].*\)$|# ZRAMROOT: \1|g' "${ZRAM_TEMP_MNT}/etc/fstab" > "$temp_fstab"
            sed 's|^\([^#].*[[:space:]]/boot[[:space:]].*\)$|# ZRAMROOT: \1|g' "$temp_fstab" > "$temp_fstab.2"
            sed 's|^\([^#].*[[:space:]]/boot/efi[[:space:]].*\)$|# ZRAMROOT: \1|g' "$temp_fstab.2" > "$temp_fstab.3"
            sed 's|^\([^#].*[[:space:]]/home[[:space:]].*\)$|# ZRAMROOT: \1|g' "$temp_fstab.3" > "$temp_fstab.4"
            sed 's|^\([^#].*[[:space:]]/var[[:space:]].*\)$|# ZRAMROOT: \1|g' "$temp_fstab.4" > "$temp_fstab.5"
            sed 's|^\([^#].*[[:space:]]swap[[:space:]].*\)$|# ZRAMROOT-SWAP-DISABLED: \1|g' "$temp_fstab.5" > "$temp_fstab.6"

            # Comment out LVM device entries for this VG to avoid missing device errors
            if [ -n "$vg_name" ]; then
                sed "s|^\([^#][[:space:]]*/dev/mapper/${vg_name}-[^[:space:]]*.*\)$|# ZRAMROOT: \1|g" "$temp_fstab.6" > "$temp_fstab.7"
                sed "s|^\([^#][[:space:]]*/dev/${vg_name}/[^[:space:]]*.*\)$|# ZRAMROOT: \1|g" "$temp_fstab.7" > "$temp_fstab.8"
                cp "$temp_fstab.8" "${ZRAM_TEMP_MNT}/etc/fstab"
                rm -f "$temp_fstab" "$temp_fstab".{2,3,4,5,6,7,8}
            else
                cp "$temp_fstab.6" "${ZRAM_TEMP_MNT}/etc/fstab"
                rm -f "$temp_fstab" "$temp_fstab".{2,3,4,5,6}
            fi

            log_debug "Successfully modified /etc/fstab"

            # --- Setup mount-on-disk bind mounts if configured ---
            if [ -n "$ZRAM_MOUNT_ON_DISK" ]; then
                log_info "Configuring mount-on-disk directories..."

                # Add the physical root mount itself to fstab so systemd knows about it
                # and doesn't unmount it during cleanup
                echo "" >> "${ZRAM_TEMP_MNT}/etc/fstab"
                echo "# ZRAMROOT: Physical root mount (required for bind mounts)" >> "${ZRAM_TEMP_MNT}/etc/fstab"
                local phys_opts="${ZRAM_PHYSICAL_ROOT_OPTS:-rw}"
                echo "${REAL_ROOT_DEVICE} /mnt/physical_root auto ${phys_opts},nofail 0 0" >> "${ZRAM_TEMP_MNT}/etc/fstab"
                log_debug "Added physical root mount entry to /etc/fstab: ${REAL_ROOT_DEVICE} -> /mnt/physical_root"

                for mount_path in $ZRAM_MOUNT_ON_DISK; do
                    mount_path=$(echo "$mount_path" | sed 's:^/::; s:/$::')

                    if [ -z "$mount_path" ]; then
                        continue
                    fi

                    if [ -d "${REAL_ROOT_MNT}/${mount_path}" ]; then
                        mkdir -p "${ZRAM_TEMP_MNT}/${mount_path}"
                        log_debug "Created mount point /${mount_path} in ZRAM root"

                        echo "" >> "${ZRAM_TEMP_MNT}/etc/fstab"
                        echo "# ZRAMROOT: Bind mount from physical disk" >> "${ZRAM_TEMP_MNT}/etc/fstab"
                        echo "/mnt/physical_root/${mount_path} /${mount_path} none bind 0 0" >> "${ZRAM_TEMP_MNT}/etc/fstab"
                        log_info "Added bind mount for /${mount_path} from physical disk"
                    else
                        log_error "Warning: Mount-on-disk path /${mount_path} does not exist on physical root - skipping"
                    fi
                done

                export ZRAMROOT_KEEP_PHYSICAL_MOUNTED="yes"
            fi
        fi

        # --- Setup ZRAM swap if enabled ---
        if [ "${ZRAM_SWAP_ENABLED}" = "yes" ]; then
            log_info "Setting up ZRAM swap..."
            setup_zram_swap
        fi
    else
        log_error "Failed to copy files from physical root to ZRAM!"
        fallback_to_normal_boot "Filesystem copy failed"
        return 0
    fi
else
    log_error "Failed to mount ZRAM device for file copy!"
    fallback_to_normal_boot "ZRAM mount failed"
    return 0
fi

# --- Unmount ZRAM temporarily ---
sync
umount "${ZRAM_TEMP_MNT}" || {
    log_error "Failed to unmount ZRAM root!"
    fallback_to_normal_boot "ZRAM unmount failed"
    return 0
}
log_debug "ZRAM root unmounted successfully"

# --- LVM2 Cleanup Function ---
cleanup_lvm2() {
    # Check if LVM tools are available
    if ! command -v vgchange >/dev/null 2>&1; then
        log_debug "LVM2 tools not available - skipping LVM2 cleanup"
        return 0
    fi

    log_info "Attempting to deactivate LVM2 volumes..."

    # Get the root device info to determine which VG to deactivate
    local root_dev="${REAL_ROOT_DEVICE}"
    local vg_name=""

    # Try to extract VG name from device path
    # Note: LVM uses single dash to separate VG-LV names, double dash for literal dashes
    if echo "${root_dev}" | grep -q "/dev/mapper/"; then
        # Try dmsetup/lvs first for accurate VG name (handles dashes correctly)
        local dm_name=$(basename "${root_dev}")
        if command -v lvs >/dev/null 2>&1; then
            vg_name=$(lvs --noheadings -o vg_name "/dev/mapper/${dm_name}" 2>/dev/null | tr -d ' ')
        fi
        # Fallback to regex if lvs didn't work (common case: VG has no dashes)
        if [ -z "$vg_name" ]; then
            vg_name=$(echo "${root_dev}" | sed 's|/dev/mapper/\([^-]*\)-.*|\1|')
        fi
    elif echo "${root_dev}" | grep -q "/dev/.*/"; then
        # Extract VG name from LVM path like /dev/vg0/root
        vg_name=$(echo "${root_dev}" | sed 's|/dev/\([^/]*\)/.*|\1|')
    fi

    if [ -n "${vg_name}" ]; then
        log_debug "Detected volume group: ${vg_name}"

        # First try to deactivate the specific logical volume
        if command -v lvchange >/dev/null 2>&1; then
            log_debug "Deactivating logical volume: ${root_dev}"
            lvchange -an "${root_dev}" 2>/dev/null || true
        fi

        # Then try to deactivate the entire volume group
        log_debug "Deactivating volume group: ${vg_name}"
        vgchange -an "${vg_name}" 2>/dev/null || true

        # Give it a moment to complete
        sleep 2

        log_info "LVM2 volume group '${vg_name}' deactivated"
    else
        log_debug "Could not determine volume group name from ${root_dev}"

        # Fallback: try to deactivate all volume groups
        log_debug "Attempting to deactivate all volume groups"
        vgchange -an 2>/dev/null || true
        sleep 2
        log_info "All LVM2 volumes deactivated"
    fi
}

# --- Handle physical root mount ---
if [ "${ZRAMROOT_KEEP_PHYSICAL_MOUNTED}" = "yes" ]; then
    log_info "Keeping physical root mounted at /mnt/physical_root for bind mounts"

    mkdir -p /mnt/physical_root

    local phys_mount_opts="${ZRAM_PHYSICAL_ROOT_OPTS:-rw}"
    log_debug "Physical root will be mounted with options: ${phys_mount_opts}"

    # Unmount from temp location
    sync
    umount "${REAL_ROOT_MNT}" 2>/dev/null || umount -l "${REAL_ROOT_MNT}" 2>/dev/null || true

    # Mount at final location
    if mount -o "${phys_mount_opts}" "${REAL_ROOT_DEVICE}" /mnt/physical_root; then
        log_info "Physical root remounted successfully at /mnt/physical_root"
    else
        log_error "Failed to remount physical root at /mnt/physical_root"
        log_error "Bind mounts will not work!"
    fi
else
    log_debug "Unmounting physical root (no mount-on-disk configured)"
    sync
    umount "${REAL_ROOT_MNT}" || umount -l "${REAL_ROOT_MNT}" || true

    # After unmounting, try to deactivate LVM2 volumes if applicable
    cleanup_lvm2
fi

# --- Update dracut's root variable to point to ZRAM ---
log_info "Setting root to ZRAM device: ${ZRAM_DEVICE}"

# Calculate final mount options
final_mount_opts=$(echo "${ZRAM_MOUNT_OPTS},rw" | sed 's/,defaults//g; s/,ro//g; s/,rw,rw/,rw/g; s/^,\|,$//g')
[ -z "$final_mount_opts" ] && final_mount_opts="rw"

# Write state file for mount hook to use
# The mount hook will read this and mount ZRAM at $NEWROOT
mkdir -p /run/initramfs
cat > /run/initramfs/zramroot.env << EOF
ZRAMROOT_DEVICE=${ZRAM_DEVICE}
ZRAMROOT_FSTYPE=${ZRAM_FS_TYPE}
ZRAMROOT_ROOTFLAGS=${final_mount_opts}
EOF

# Also write to /tmp as backup
cat > /tmp/zramroot.env << EOF
ZRAMROOT_DEVICE=${ZRAM_DEVICE}
ZRAMROOT_FSTYPE=${ZRAM_FS_TYPE}
ZRAMROOT_ROOTFLAGS=${final_mount_opts}
EOF

log_info "ZRAMROOT_DEVICE=${ZRAM_DEVICE}"
log_info "ZRAMROOT_FSTYPE=${ZRAM_FS_TYPE}"
log_info "ZRAMROOT_ROOTFLAGS=${final_mount_opts}"

# --- SYSTEMD INTEGRATION ---
# On systemd-based initramfs (Fedora/Qubes/RHEL), root is mounted by sysroot.mount.
# The legacy mount-root.sh hook is often ignored if sysroot.mount exists.
# We must override sysroot.mount to point to our ZRAM device.

if [ -d /run/systemd/system ]; then
    log_info "Systemd detected. Overriding sysroot.mount..."
    mkdir -p /run/systemd/system/sysroot.mount.d
    
    # Override What, Options, and Type
    # Note: We do not change Where because it must be /sysroot
    cat > /run/systemd/system/sysroot.mount.d/zramroot.conf << EOF
[Mount]
What=${ZRAM_DEVICE}
Options=${final_mount_opts}
Type=${ZRAM_FS_TYPE}
EOF

    # Reload systemd to pick up the change
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        log_info "Systemd daemon reloaded to apply sysroot.mount override"
    else
        log_error "systemctl not found! sysroot.mount override might fail"
    fi
fi

log_info "zramroot finished successfully."

# Return success
return 0
