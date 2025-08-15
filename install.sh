#!/bin/bash

# Optimized autotune-sysctl installer
# Automatically adjusts system parameters for maximum network and system performance
# Version 2.0

set -euo pipefail
IFS=$'\n\t'

# Configuration constants
readonly INSTALL_PATH="/usr/local/bin/autotune-sysctl.sh"
readonly SERVICE_PATH="/etc/systemd/system/autotune-sysctl.service"
readonly TIMER_PATH="/etc/systemd/system/autotune-sysctl.timer"
readonly SYSCTL_FILE="/etc/sysctl.d/99-autotune.conf"
readonly LOG_FILE="/var/log/autotune-sysctl.log"
readonly MODULES_FILE="/etc/modules-load.d/autotune.conf"
readonly REQUIRED_TOOLS=("ethtool" "ip" "grep" "awk" "sed" "modprobe")
readonly REQUIRED_PACKAGES=("ethtool" "iproute2")

# Color constants
readonly RED='\e[1;31m'
readonly GREEN='\e[1;32m'
readonly YELLOW='\e[1;33m'
readonly BLUE='\e[1;34m'
readonly NC='\e[0m'

# Root access check
if [[ $(id -u) -ne 0 ]]; then
    printf "${RED}[ERROR] This script must be run with root privileges.${NC}\n" >&2
    exit 1
fi

log() {
    local level="$1"
    local message="$2"
    local color="$3"
    printf "${color}[%s] %s${NC}\n" "$level" "$message"
}

check_dependencies() {
    local missing=()
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing+=("$tool")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log "ERROR" "Missing required tools: ${missing[*]}" "$RED"
        log "INFO" "Please install the required packages manually" "$YELLOW"
        exit 1
    fi
}

detect_package_manager() {
    if command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v yum &>/dev/null; then
        echo "yum"
    elif command -v zypper &>/dev/null; then
        echo "zypper"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

install_packages() {
    local pkg_manager="$1"
    local -a packages=("${!2}")
    
    case "$pkg_manager" in
        apt)
            apt-get update -qq && apt-get install -yq "${packages[@]}"
            ;;
        dnf|yum)
            "$pkg_manager" install -yq "${packages[@]}"
            ;;
        zypper)
            zypper install -yq "${packages[@]}"
            ;;
        pacman)
            pacman -Sy --noconfirm "${packages[@]}"
            ;;
        *)
            return 1
            ;;
    esac
}

install_required_tools() {
    local pkg_manager
    pkg_manager=$(detect_package_manager)
    
    if [[ "$pkg_manager" == "unknown" ]]; then
        log "WARNING" "Package manager not detected. Automatic installation not possible." "$YELLOW"
        return 1
    fi

    local missing_pkgs=()
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null || 
           ! rpm -q "$pkg" &>/dev/null || 
           ! pacman -Q "$pkg" &>/dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [[ ${#missing_pkgs[@]} -eq 0 ]]; then
        log "INFO" "All required tools are already installed" "$GREEN"
        return 0
    fi

    log "INFO" "Installing required packages: ${missing_pkgs[*]}" "$BLUE"
    if ! install_packages "$pkg_manager" missing_pkgs[@]; then
        log "ERROR" "Failed to install required packages" "$RED"
        return 1
    fi

    # Verify installation
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! command -v "$pkg" &>/dev/null; then
            log "ERROR" "Installation verification failed for $pkg" "$RED"
            return 1
        fi
    done

    log "INFO" "Required tools installed successfully" "$GREEN"
    return 0
}

log "INFO" "Installing autotune-sysctl v2.0..." "$BLUE"

# Check dependencies
check_dependencies

# Install required tools
if ! install_required_tools; then
    log "WARNING" "Proceeding without required tools. Some features may be limited." "$YELLOW"
fi

# Create main script
cat << 'EOF' > "$INSTALL_PATH"
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Configuration
readonly SYSCTL_FILE="/etc/sysctl.d/99-autotune.conf"
readonly BACKUP_FILE="/etc/sysctl.d/99-autotune.bak"
readonly LOG_FILE="/var/log/autotune-sysctl.log"
readonly VERSION="2.0"

# Initialize logging
exec > >(tee -a "$LOG_FILE") 2>&1
printf "--- $(date): Starting autotune-sysctl v%s ---\n" "$VERSION"

# System information collection
get_system_info() {
    local mem_kb
    mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    readonly TOTAL_MEM_MB=$((mem_kb / 1024))
    
    readonly CPU_CORES=$(nproc)
    
    readonly DEFAULT_IFACE=$(ip -o route get 8.8.8.8 2>/dev/null | 
        awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | 
        head -n1)
    
    # Network speed detection
    local speed
    speed=1000  # Default 1Gbps
    if [[ -n "$DEFAULT_IFACE" && -f "/sys/class/net/$DEFAULT_IFACE/speed" ]]; then
        if speed=$(cat "/sys/class/net/$DEFAULT_IFACE/speed" 2>/dev/null); then
            if [[ "$speed" =~ ^[0-9]+$ && "$speed" -gt 0 ]]; then
                readonly NETWORK_SPEED="$speed"
            fi
        fi
    fi
    readonly NETWORK_SPEED

    # Disk type detection
    local disk_type="HDD"
    if command -v lsblk &>/dev/null; then
        local root_dev
        root_dev=$(df --output=source / | tail -n1 | sed 's/p[0-9]$//; s/[0-9]$//')
        if lsblk -d -no rota "/dev/$root_dev" 2>/dev/null | grep -q "0"; then
            disk_type="SSD"
        fi
    elif [[ -d "/sys/block" ]]; then
        local sysfs_dev
        sysfs_dev=$(df --output=source / | tail -n1 | sed 's/\/dev\///; s/p[0-9]$//; s/[0-9]$//')
        if [[ -n "$sysfs_dev" && -f "/sys/block/$sysfs_dev/queue/rotational" ]]; then
            if grep -q "0" "/sys/block/$sysfs_dev/queue/rotational"; then
                disk_type="SSD"
            fi
        fi
    fi
    readonly DISK_TYPE="$disk_type"
}

# Calculate optimal parameters
calculate_parameters() {
    # Memory-based parameters
    if (( TOTAL_MEM_MB <= 2048 )); then
        rmem_max=4194304
        wmem_max=4194304
        tcp_mem="196608 262144 393216"
        ip_conntrack_max=$((TOTAL_MEM_MB * 32))
        nr_open=524288
        file_max=524288
        inotify_max=65536
        min_free_kb=32768
    elif (( TOTAL_MEM_MB <= 4096 )); then
        rmem_max=8388608
        wmem_max=8388608
        tcp_mem="393216 524288 786432"
        ip_conntrack_max=$((TOTAL_MEM_MB * 48))
        nr_open=1048576
        file_max=1048576
        inotify_max=131072
        min_free_kb=49152
    elif (( TOTAL_MEM_MB <= 8192 )); then
        rmem_max=16777216
        wmem_max=16777216
        tcp_mem="786432 1048576 1572864"
        ip_conntrack_max=$((TOTAL_MEM_MB * 64))
        nr_open=2097152
        file_max=2097152
        inotify_max=262144
        min_free_kb=65536
    elif (( TOTAL_MEM_MB <= 16384 )); then
        rmem_max=33554432
        wmem_max=33554432
        tcp_mem="1572864 2097152 3145728"
        ip_conntrack_max=$((TOTAL_MEM_MB * 96))
        nr_open=3097152
        file_max=3097152
        inotify_max=524288
        min_free_kb=98304
    else
        rmem_max=67108864
        wmem_max=67108864
        tcp_mem="3145728 4194304 6291456"
        ip_conntrack_max=$((TOTAL_MEM_MB * 128))
        nr_open=4194304
        file_max=4194304
        inotify_max=1048576
        min_free_kb=131072
    fi

    # Network speed adjustments
    if (( NETWORK_SPEED >= 10000 )); then
        if (( TOTAL_MEM_MB > 16384 )); then
            rmem_max=134217728
            wmem_max=134217728
        else
            (( rmem_max *= 2 ))
            (( wmem_max *= 2 ))
        fi
        netdev_max_backlog=32768
        somaxconn=32768
    elif (( NETWORK_SPEED >= 1000 )); then
        netdev_max_backlog=8192
        somaxconn=8192
    else
        netdev_max_backlog=2048
        somaxconn=2048
    fi

    # Queue and congestion control
    local qdisc="fq_codel"
    local congestion="bbr"
    
    if ! grep -qw "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        congestion="cubic"
    elif grep -qw "bbr2" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        congestion="bbr2"
    fi

    if ! tc qdisc show | grep -q "fq_codel"; then
        if modprobe sch_fq_codel 2>/dev/null; then
            printf "[INFO] Loaded sch_fq_codel module\n"
        else
            qdisc="fq"
            if ! tc qdisc show | grep -q "fq"; then
                if ! modprobe sch_fq 2>/dev/null; then
                    qdisc="pfifo_fast"
                fi
            fi
        fi
    fi

    # Disk type optimizations
    local swappiness
    local vfs_cache_pressure
    local dirty_ratio
    local dirty_background_ratio
    local max_map_count
    
    if [[ "$DISK_TYPE" == "SSD" ]]; then
        swappiness=1
        vfs_cache_pressure=50
        dirty_ratio=10
        dirty_background_ratio=5
        max_map_count=1048576
    else
        swappiness=10
        vfs_cache_pressure=100
        dirty_ratio=20
        dirty_background_ratio=10
        max_map_count=524288
    fi

    # Export calculated parameters
    export RMEM_MAX="$rmem_max"
    export WMEM_MAX="$wmem_max"
    export TCP_MEM="$tcp_mem"
    export IP_CONNTRACK_MAX="$ip_conntrack_max"
    export NR_OPEN="$nr_open"
    export FILE_MAX="$file_max"
    export INOTIFY_MAX="$inotify_max"
    export MIN_FREE_KB="$min_free_kb"
    export NETDEV_MAX_BACKLOG="$netdev_max_backlog"
    export SOMAXCONN="$somaxconn"
    export QDISC="$qdisc"
    export CONGESTION="$congestion"
    export SWAPPINESS="$swappiness"
    export VFS_CACHE_PRESSURE="$vfs_cache_pressure"
    export DIRTY_RATIO="$dirty_ratio"
    export DIRTY_BACKGROUND_RATIO="$dirty_background_ratio"
    export MAX_MAP_COUNT="$max_map_count"
}

# Apply network interface optimizations
optimize_network_interface() {
    local iface="$1"
    
    # Ring buffer optimization
    if [[ -d "/sys/class/net/$iface/queues" ]]; then
        local rx_queues
        rx_queues=$(find "/sys/class/net/$iface/queues" -name 'rx-*' | wc -l)
        
        if (( rx_queues > 0 )); then
            local rx_ring
            if (( NETWORK_SPEED >= 10000 )); then
                rx_ring=4096
            elif (( NETWORK_SPEED >= 1000 )); then
                rx_ring=2048
            else
                rx_ring=1024
            fi
            
            # Check current ring size
            local current_rx
            current_rx=$(ethtool -g "$iface" 2>/dev/null | 
                awk '/Current hardware settings:/ { getline; print $2 }')
            
            if [[ -n "$current_rx" && "$current_rx" -ge "$rx_ring" ]]; then
                printf "[INFO] %s RX ring size already sufficient (%d >= %d)\n" \
                    "$iface" "$current_rx" "$rx_ring"
                return
            fi
            
            if ethtool -G "$iface" rx "$rx_ring" &>/dev/null; then
                printf "[INFO] Set %s RX ring size to %d\n" "$iface" "$rx_ring"
            else
                printf "[WARNING] Failed to set RX ring size for %s\n" "$iface"
            fi
        fi
    fi

    # Offload optimizations
    if ethtool -k "$iface" &>/dev/null; then
        printf "[INFO] Optimizing offload settings for %s\n" "$iface"
        ethtool -K "$iface" tso on gso on gro on sg on rx on tx on &>/dev/null || true
    fi

    # Queue discipline
    if tc qdisc show dev "$iface" &>/dev/null; then
        if ! tc qdisc show dev "$iface" | grep -q "$QDISC"; then
            tc qdisc replace dev "$iface" root "$QDISC" &>/dev/null && 
                printf "[INFO] Set %s queue discipline to %s\n" "$iface" "$QDISC" ||
                printf "[WARNING] Failed to set queue discipline for %s\n" "$iface"
        fi
    fi
}

# Main execution
main() {
    get_system_info
    
    printf "[INFO] System Information:\n"
    printf "    - Total Memory: %d MB\n" "$TOTAL_MEM_MB"
    printf "    - CPU Cores: %d\n" "$CPU_CORES"
    printf "    - Default Interface: %s\n" "$DEFAULT_IFACE"
    printf "    - Network Speed: %d Mbps\n" "$NETWORK_SPEED"
    printf "    - Disk Type: %s\n" "$DISK_TYPE"
    
    calculate_parameters
    
    # Backup existing configuration
    if [[ -f "$SYSCTL_FILE" ]]; then
        cp -f "$SYSCTL_FILE" "$BACKUP_FILE"
        printf "[INFO] Backed up previous configuration to %s\n" "$BACKUP_FILE"
    fi
    
    # Generate new configuration
    cat << EOT > "$SYSCTL_FILE"
# Optimized Linux kernel settings (autotune-sysctl v$VERSION)
# Generated: $(date)

# --- Network Settings ---
net.core.default_qdisc = $QDISC
net.ipv4.tcp_congestion_control = $CONGESTION

net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $WMEM_MAX
net.core.rmem_default = $((RMEM_MAX / 4))
net.core.wmem_default = $((WMEM_MAX / 4))
net.ipv4.tcp_rmem = 4096 87380 $RMEM_MAX
net.ipv4.tcp_wmem = 4096 87380 $WMEM_MAX
net.ipv4.tcp_mem = $TCP_MEM
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_syn_backlog = $((SOMAXCONN * 2))
net.ipv4.tcp_max_tw_buckets = $((SOMAXCONN * 4))
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_ecn = 1

net.ipv4.ip_local_port_range = 1024 65535

net.core.somaxconn = $SOMAXCONN
net.core.netdev_max_backlog = $NETDEV_MAX_BACKLOG
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.route.gc_timeout = 100
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0

net.netfilter.nf_conntrack_max = $IP_CONNTRACK_MAX
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

# --- Filesystem and Memory ---
fs.inotify.max_user_watches = $INOTIFY_MAX
fs.inotify.max_user_instances = 1024
fs.file-max = $FILE_MAX
fs.nr_open = $NR_OPEN
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1

vm.swappiness = $SWAPPINESS
vm.vfs_cache_pressure = $VFS_CACHE_PRESSURE
vm.dirty_ratio = $DIRTY_RATIO
vm.dirty_background_ratio = $DIRTY_BACKGROUND_RATIO
vm.min_free_kbytes = $MIN_FREE_KB
vm.max_map_count = $MAX_MAP_COUNT
vm.overcommit_memory = 1
vm.overcommit_ratio = 50
vm.page-cluster = 3
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500

# --- Kernel and Security ---
kernel.sched_autogroup_enabled = 1
kernel.sched_migration_cost_ns = 5000000
kernel.sched_latency_ns = 10000000
kernel.sched_min_granularity_ns = 4000000
kernel.panic = 10
kernel.pid_max = 65536
kernel.threads-max = $((FILE_MAX / 4))
kernel.sysrq = 1
kernel.randomize_va_space = 2

kernel.sched_child_runs_first = 0
kernel.numa_balancing = 0
EOT

    # Apply new configuration
    if ! sysctl --system &>/dev/null; then
        printf "[ERROR] Failed to apply sysctl settings\n"
        if [[ -f "$BACKUP_FILE" ]]; then
            mv -f "$BACKUP_FILE" "$SYSCTL_FILE"
            sysctl --system &>/dev/null
            printf "[INFO] Restored previous configuration\n"
        fi
        exit 1
    fi

    # Interface-specific optimizations
    if [[ -n "$DEFAULT_IFACE" ]]; then
        optimize_network_interface "$DEFAULT_IFACE"
    fi

    printf "[SUCCESS] System optimization completed successfully\n"
}

main
exit 0
EOF

chmod +x "$INSTALL_PATH"

# Create systemd service
cat > "$SERVICE_PATH" << EOF
[Unit]
Description=Auto-tune sysctl parameters
After=network.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH
TimeoutStartSec=300
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

# Create systemd timer
cat > "$TIMER_PATH" << EOF
[Unit]
Description=Run autotune-sysctl periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=8h
AccuracySec=1m
RandomizedDelaySec=30s
Unit=autotune-sysctl.service

[Install]
WantedBy=timers.target
EOF

# Load required kernel modules
load_kernel_modules() {
    local -a modules=("tcp_bbr" "sch_fq_codel" "sch_fq" "nf_conntrack")
    local loaded=()
    
    for module in "${modules[@]}"; do
        if ! lsmod | grep -q "^$module"; then
            if modprobe "$module" 2>/dev/null; then
                loaded+=("$module")
            fi
        fi
    done

    if [[ ${#loaded[@]} -gt 0 ]]; then
        printf "# Required modules for autotune-sysctl\n%s\n" "${loaded[@]}" \
            > "$MODULES_FILE"
        log "INFO" "Added ${#loaded[@]} modules to boot configuration" "$GREEN"
    fi
}

log "INFO" "Configuring kernel modules..." "$BLUE"
load_kernel_modules

# Final setup
log "INFO" "Reloading systemd configuration..." "$BLUE"
systemctl daemon-reload

log "INFO" "Enabling autotune services..." "$BLUE"
systemctl enable --now autotune-sysctl.timer &>/dev/null
systemctl start autotune-sysctl.service &>/dev/null

log "SUCCESS" "Installation completed successfully!" "$GREEN"
printf "\n${BLUE}[*] Configuration:${NC} ${SYSCTL_FILE}\n"
printf "${BLUE}[*] Log file:${NC} ${LOG_FILE}\n"
printf "${BLUE}[*] Execution:${NC} sudo ${INSTALL_PATH}\n"
printf "${BLUE}[*] Next run:${NC} $(systemctl list-timers autotune-sysctl.timer --no-pager | awk '/next/ {print $3, $4}')\n\n"

exit 0
