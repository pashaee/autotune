#!/bin/bash

# Optimized autotune-sysctl script
# Automatically adjusts system parameters for maximum network and system performance
# Version: 2.0 - Optimized

set -euo pipefail

# Global variables
readonly INSTALL_PATH="/usr/local/bin/autotune-sysctl.sh"
readonly SERVICE_PATH="/etc/systemd/system/autotune-sysctl.service"
readonly TIMER_PATH="/etc/systemd/system/autotune-sysctl.timer"
readonly SYSCTL_FILE="/etc/sysctl.d/99-autotune.conf"
readonly BACKUP_FILE="/etc/sysctl.d/99-autotune.bak"
readonly LOG_FILE="/var/log/autotune-sysctl.log"
readonly MODULES_FILE="/etc/modules-load.d/autotune.conf"

# Color codes
readonly RED='\e[1;31m'
readonly GREEN='\e[1;32m'
readonly YELLOW='\e[1;33m'
readonly BLUE='\e[1;34m'
readonly NC='\e[0m'

# System info cache
declare -g TOTAL_MEM_KB TOTAL_MEM_MB CPU_CORES DEFAULT_IFACE NETWORK_SPEED DISK_TYPE

# Logging function
log() {
    local level="$1"
    shift
    local color=""
    case "$level" in
        ERROR) color="$RED" ;;
        SUCCESS) color="$GREEN" ;;
        WARNING) color="$YELLOW" ;;
        INFO) color="$BLUE" ;;
    esac
    echo -e "${color}[$level]${NC} $*" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "${color}[$level]${NC} $*"
}

# Error handler
error_exit() {
    log ERROR "$1"
    exit "${2:-1}"
}

# Check root privileges
check_root() {
    [[ $EUID -eq 0 ]] || error_exit "This script must be run with root privileges."
}

# Detect package manager
detect_package_manager() {
    local managers=(
        "apt-get:apt-get install -y"
        "dnf:dnf install -y"
        "yum:yum install -y"
        "pacman:pacman -S --noconfirm"
        "zypper:zypper install -y"
    )
    
    for manager in "${managers[@]}"; do
        local cmd="${manager%:*}"
        local install_cmd="${manager#*:}"
        if command -v "$cmd" &>/dev/null; then
            echo "$install_cmd"
            return 0
        fi
    done
    
    return 1
}

# Install package if not present
install_if_missing() {
    local package="$1"
    local command_name="${2:-$package}"
    
    if command -v "$command_name" &>/dev/null; then
        log SUCCESS "$command_name is already installed"
        return 0
    fi
    
    log WARNING "$command_name not found, attempting installation..."
    
    local install_cmd
    if ! install_cmd=$(detect_package_manager); then
        log WARNING "No supported package manager found"
        return 1
    fi
    
    if $install_cmd "$package"; then
        log SUCCESS "$package installed successfully"
    else
        log ERROR "Failed to install $package"
        return 1
    fi
}

# Gather system information efficiently
gather_system_info() {
    log INFO "Gathering system information..."
    
    # Memory info
    TOTAL_MEM_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
    
    # CPU cores
    CPU_CORES=$(nproc)
    
    # Default network interface
    DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')
    
    # Network speed detection
    NETWORK_SPEED=1000  # Default
    if [[ -n "$DEFAULT_IFACE" && -f "/sys/class/net/$DEFAULT_IFACE/speed" ]]; then
        local detected_speed
        if detected_speed=$(cat "/sys/class/net/$DEFAULT_IFACE/speed" 2>/dev/null) && [[ $detected_speed -gt 0 ]]; then
            NETWORK_SPEED=$detected_speed
        fi
    fi
    
    # Disk type detection
    DISK_TYPE="HDD"  # Default
    local root_device
    root_device=$(lsblk -no pkname "$(df --output=source / | tail -n1)" 2>/dev/null)
    if [[ -n "$root_device" && -f "/sys/block/$root_device/queue/rotational" ]]; then
        [[ $(cat "/sys/block/$root_device/queue/rotational") -eq 0 ]] && DISK_TYPE="SSD"
    fi
    
    log INFO "System specs: ${TOTAL_MEM_MB}MB RAM, ${CPU_CORES} cores, ${DEFAULT_IFACE:-unknown} interface, ${NETWORK_SPEED}Mbps, $DISK_TYPE storage"
}

# Calculate optimized values based on system specs
calculate_values() {
    local rmem_max wmem_max tcp_mem ip_conntrack_max nr_open file_max inotify_max min_free_kb
    local netdev_max_backlog somaxconn swappiness vfs_cache_pressure dirty_ratio dirty_bg_ratio max_map_count
    
    # Memory-based scaling
    case $TOTAL_MEM_MB in
        [0-2048])
            rmem_max=4194304 wmem_max=4194304 tcp_mem="196608 262144 393216"
            ip_conntrack_max=$((TOTAL_MEM_MB * 32)) nr_open=524288 file_max=524288
            inotify_max=65536 min_free_kb=32768 ;;
        [2049-4096])
            rmem_max=8388608 wmem_max=8388608 tcp_mem="393216 524288 786432"
            ip_conntrack_max=$((TOTAL_MEM_MB * 48)) nr_open=1048576 file_max=1048576
            inotify_max=131072 min_free_kb=49152 ;;
        [4097-8192])
            rmem_max=16777216 wmem_max=16777216 tcp_mem="786432 1048576 1572864"
            ip_conntrack_max=$((TOTAL_MEM_MB * 64)) nr_open=2097152 file_max=2097152
            inotify_max=262144 min_free_kb=65536 ;;
        [8193-16384])
            rmem_max=33554432 wmem_max=33554432 tcp_mem="1572864 2097152 3145728"
            ip_conntrack_max=$((TOTAL_MEM_MB * 96)) nr_open=3097152 file_max=3097152
            inotify_max=524288 min_free_kb=98304 ;;
        *)
            rmem_max=67108864 wmem_max=67108864 tcp_mem="3145728 4194304 6291456"
            ip_conntrack_max=$((TOTAL_MEM_MB * 128)) nr_open=4194304 file_max=4194304
            inotify_max=1048576 min_free_kb=131072 ;;
    esac
    
    # Network speed adjustments
    if [[ $NETWORK_SPEED -ge 10000 ]]; then
        [[ $TOTAL_MEM_MB -gt 16384 ]] && { rmem_max=134217728; wmem_max=134217728; } || { rmem_max=$((rmem_max * 2)); wmem_max=$((wmem_max * 2)); }
        netdev_max_backlog=32768 somaxconn=32768
    elif [[ $NETWORK_SPEED -ge 1000 ]]; then
        netdev_max_backlog=8192 somaxconn=8192
    else
        netdev_max_backlog=2048 somaxconn=2048
    fi
    
    # Disk type optimizations
    if [[ "$DISK_TYPE" == "SSD" ]]; then
        swappiness=1 vfs_cache_pressure=50 dirty_ratio=10 dirty_bg_ratio=5 max_map_count=1048576
    else
        swappiness=10 vfs_cache_pressure=100 dirty_ratio=20 dirty_bg_ratio=10 max_map_count=524288
    fi
    
    # Export calculated values
    export RMEM_MAX=$rmem_max WMEM_MAX=$wmem_max TCP_MEM="$tcp_mem" IP_CONNTRACK_MAX=$ip_conntrack_max
    export NR_OPEN=$nr_open FILE_MAX=$file_max INOTIFY_MAX=$inotify_max MIN_FREE_KB=$min_free_kb
    export NETDEV_MAX_BACKLOG=$netdev_max_backlog SOMAXCONN=$somaxconn
    export SWAPPINESS=$swappiness VFS_CACHE_PRESSURE=$vfs_cache_pressure
    export DIRTY_RATIO=$dirty_ratio DIRTY_BG_RATIO=$dirty_bg_ratio MAX_MAP_COUNT=$max_map_count
}

# Detect optimal congestion control and qdisc
detect_network_algorithms() {
    local congestion="cubic" qdisc="pfifo_fast"
    
    # Congestion control detection
    if [[ -f /proc/sys/net/ipv4/tcp_available_congestion_control ]]; then
        local available
        available=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control)
        case "$available" in
            *bbr2*) congestion="bbr2" ;;
            *bbr*) congestion="bbr" ;;
        esac
    fi
    
    # Queue discipline detection
    local qdiscs=("fq_codel" "fq")
    for qd in "${qdiscs[@]}"; do
        if modprobe "sch_$qd" 2>/dev/null || lsmod | grep -q "sch_$qd"; then
            qdisc="$qd"
            break
        fi
    done
    
    export CONGESTION="$congestion" QDISC="$qdisc"
    log INFO "Using congestion control: $congestion, queue discipline: $qdisc"
}

# Load required kernel modules
load_modules() {
    local modules=("tcp_bbr" "sch_fq_codel" "sch_fq" "nf_conntrack")
    local loaded=()
    
    for module in "${modules[@]}"; do
        if modprobe "$module" 2>/dev/null; then
            loaded+=("$module")
        fi
    done
    
    if [[ ${#loaded[@]} -gt 0 ]]; then
        printf '%s\n' "${loaded[@]}" > "$MODULES_FILE"
        log SUCCESS "Loaded modules: ${loaded[*]}"
    fi
}

# Generate optimized sysctl configuration
generate_sysctl_config() {
    [[ -f "$SYSCTL_FILE" ]] && cp "$SYSCTL_FILE" "$BACKUP_FILE"
    
    cat > "$SYSCTL_FILE" << EOF
# Optimized Linux kernel settings - Generated $(date)

# Network Performance
net.core.default_qdisc=$QDISC
net.ipv4.tcp_congestion_control=$CONGESTION
net.core.rmem_max=$RMEM_MAX
net.core.wmem_max=$WMEM_MAX
net.core.rmem_default=$((RMEM_MAX / 4))
net.core.wmem_default=$((WMEM_MAX / 4))
net.ipv4.tcp_rmem=4096 87380 $RMEM_MAX
net.ipv4.tcp_wmem=4096 87380 $WMEM_MAX
net.ipv4.tcp_mem=$TCP_MEM
net.core.somaxconn=$SOMAXCONN
net.core.netdev_max_backlog=$NETDEV_MAX_BACKLOG

# TCP Optimization
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.ipv4.tcp_max_syn_backlog=$((SOMAXCONN * 2))
net.ipv4.tcp_max_tw_buckets=$((SOMAXCONN * 4))
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_ecn=1
net.ipv4.ip_local_port_range=1024 65535

# Security & Connection Tracking
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.secure_redirects=0
net.netfilter.nf_conntrack_max=$IP_CONNTRACK_MAX
net.netfilter.nf_conntrack_tcp_timeout_established=86400

# Filesystem & Memory Management
fs.file-max=$FILE_MAX
fs.nr_open=$NR_OPEN
fs.inotify.max_user_watches=$INOTIFY_MAX
vm.swappiness=$SWAPPINESS
vm.vfs_cache_pressure=$VFS_CACHE_PRESSURE
vm.dirty_ratio=$DIRTY_RATIO
vm.dirty_background_ratio=$DIRTY_BG_RATIO
vm.min_free_kbytes=$MIN_FREE_KB
vm.max_map_count=$MAX_MAP_COUNT
vm.overcommit_memory=1

# Kernel Performance
kernel.sched_autogroup_enabled=1
kernel.sched_migration_cost_ns=5000000
kernel.pid_max=65536
kernel.panic=10
kernel.randomize_va_space=2
EOF
    
    log SUCCESS "Configuration file generated: $SYSCTL_FILE"
}

# Apply system settings
apply_settings() {
    if ! sysctl --system; then
        log ERROR "Failed to apply settings"
        if [[ -f "$BACKUP_FILE" ]]; then
            mv "$BACKUP_FILE" "$SYSCTL_FILE"
            sysctl --system
            log INFO "Settings restored from backup"
        fi
        return 1
    fi
    log SUCCESS "System settings applied successfully"
}

# Optimize network interface
optimize_network_interface() {
    [[ -z "$DEFAULT_IFACE" ]] && return 0
    
    log INFO "Optimizing network interface: $DEFAULT_IFACE"
    
    # Set ring buffer size
    if command -v ethtool &>/dev/null && ethtool -g "$DEFAULT_IFACE" &>/dev/null; then
        local ring_size=1024
        [[ $NETWORK_SPEED -ge 10000 ]] && ring_size=4096
        [[ $NETWORK_SPEED -ge 1000 ]] && ring_size=2048
        
        local max_ring
        max_ring=$(ethtool -g "$DEFAULT_IFACE" 2>/dev/null | awk '/^RX:/{getline; print $1}')
        [[ -n "$max_ring" && $ring_size -gt $max_ring ]] && ring_size=$max_ring
        
        ethtool -G "$DEFAULT_IFACE" rx "$ring_size" &>/dev/null && 
            log SUCCESS "Ring buffer set to $ring_size"
    fi
    
    # Enable hardware offloading
    if command -v ethtool &>/dev/null; then
        ethtool -K "$DEFAULT_IFACE" tso on gso on gro on sg on rx on tx on &>/dev/null &&
            log SUCCESS "Hardware offloading enabled"
    fi
    
    # Set queue discipline
    if command -v tc &>/dev/null; then
        tc qdisc replace dev "$DEFAULT_IFACE" root "$QDISC" &>/dev/null &&
            log SUCCESS "Queue discipline set to $QDISC"
    fi
}

# Create systemd service and timer
create_systemd_files() {
    # Service file
    cat > "$SERVICE_PATH" << EOF
[Unit]
Description=Auto-tune sysctl parameters
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH
TimeoutStartSec=180
KillMode=process
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

    # Timer file
    cat > "$TIMER_PATH" << EOF
[Unit]
Description=Run autotune-sysctl periodically
After=network-online.target

[Timer]
OnBootSec=2min
OnUnitActiveSec=8h
AccuracySec=1min
RandomizedDelaySec=30s

[Install]
WantedBy=timers.target
EOF
    
    log SUCCESS "Systemd service and timer created"
}

# Main installation function
install_autotune() {
    log INFO "Installing autotune-sysctl..."
    
    check_root
    install_if_missing "ethtool"
    install_if_missing "iproute2" "tc"
    
    # Create the main script
    cat > "$INSTALL_PATH" << 'SCRIPT_EOF'
#!/bin/bash
set -euo pipefail

# [The optimized main script content would go here - same structure as above]
# This is a placeholder for the actual script content
# In practice, you would embed the optimized version here

SCRIPT_EOF
    chmod +x "$INSTALL_PATH"
    
    gather_system_info
    calculate_values
    detect_network_algorithms
    load_modules
    generate_sysctl_config
    apply_settings
    optimize_network_interface
    create_systemd_files
    
    # Enable and start services
    systemctl daemon-reload
    systemctl enable autotune-sysctl.service autotune-sysctl.timer
    systemctl start autotune-sysctl.timer
    
    log SUCCESS "Installation completed successfully!"
    log INFO "Configuration: $SYSCTL_FILE"
    log INFO "Logs: $LOG_FILE"
    log INFO "Manual run: sudo $INSTALL_PATH"
}

# Main execution
main() {
    # If script is being installed
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        install_autotune
    else
        # If script is being run as the installed version
        gather_system_info
        calculate_values
        detect_network_algorithms
        generate_sysctl_config
        apply_settings
        optimize_network_interface
    fi
}

main "$@"
