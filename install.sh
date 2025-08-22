#!/bin/bash

#Optimized autotune-sysctl script
#Automatically adjusts system parameters for maximum network and system performance

set -e

echo -e "\e[1;34m[*] Installing script autotune-sysctl...\e[0m"

INSTALL_PATH="/usr/local/bin/autotune-sysctl.sh"
SERVICE_PATH="/etc/systemd/system/autotune-sysctl.service"
TIMER_PATH="/etc/systemd/system/autotune-sysctl.timer"
SYSCTL_FILE="/etc/sysctl.d/99-autotune.conf"
CRON_FILE="/etc/cron.d/autotune-sysctl"

# root access check
if [ "$(id -u)" -ne 0 ]; then
    echo -e "\e[1;31m[ERROR] This script must be run with root privileges.\e[0m"
    exit 1
fi


echo -e "\e[1;34m[*] Checking required tools...\e[0m"


if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt-get"
    PKG_INSTALL="apt-get install -y"
elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    PKG_INSTALL="yum install -y"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    PKG_INSTALL="dnf install -y"
elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
    PKG_INSTALL="pacman -S --noconfirm"
elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    PKG_INSTALL="apk add --no-cache"
elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
    PKG_INSTALL="zypper install -y"
else
    echo -e "\e[1;33m[!!!] Package manager not detected. Automatic installation of tools is not possible.\e[0m"
    PKG_MANAGER=""
    PKG_INSTALL=""
fi

# installing ethtool
if ! command -v ethtool >/dev/null 2>&1; then
    echo -e "\e[1;33m[WARNING] ethtool is not installed, attempting to install...\e[0m"
    if [ -n "$PKG_MANAGER" ]; then
        $PKG_INSTALL ethtool
        if command -v ethtool >/dev/null 2>&1; then
            echo -e "\e[1;32m[✓] ethtool was successfully installed.\e[0m"
        else
            echo -e "\e[1;31m[ERROR] Failed to install ethtool.\e[0m"
        fi
    fi
else
    echo -e "\e[1;32m[✓] ethtool is installed.\e[0m"
fi

# Check and install iproute2 (for tc)
if ! command -v tc >/dev/null 2>&1; then
    echo -e "\e[1;33m[WARNING] tc (from iproute2 package) is not installed, attempting to install...\e[0m"
    if [ -n "$PKG_MANAGER" ]; then
        if [ "$PKG_MANAGER" = "apt-get" ] || [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "pacman" ] || [ "$PKG_MANAGER" = "zypper" ] || [ "$PKG_MANAGER" = "apk" ]; then
            $PKG_INSTALL iproute2
        fi

        if command -v tc >/dev/null 2>&1; then
            echo -e "\e[1;32m[✓] tc was successfully installed.\e[0m"
        else
            echo -e "\e[1;31m[ERROR] Failed to install tc.\e[0m"
        fi
    fi
else
    echo -e "\e[1;32m[✓] tc is installed.\e[0m"
fi

# Create main configuration file
cat <<'EOF' > "$INSTALL_PATH"
#!/bin/bash

# Set path variables
SYSCTL_FILE="/etc/sysctl.d/99-autotune.conf"
BACKUP_FILE="/etc/sysctl.d/99-autotune.bak"
LOG_FILE="/var/log/autotune-sysctl.log"

# Check and install required tools
check_and_install_tools() {
    # Detect package management system
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt-get"
        PKG_INSTALL="apt-get install -y"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
        PKG_INSTALL="yum install -y"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
        PKG_INSTALL="dnf install -y"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MANAGER="pacman"
        PKG_INSTALL="pacman -S --noconfirm"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk"
        PKG_INSTALL="apk add --no-cache"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MANAGER="zypper"
        PKG_INSTALL="zypper install -y"
    else
        echo "[WARNING] Package manager not detected. Automatic installation of tools is not possible."
        return 1
    fi

    # Check and install ethtool
    if ! command -v ethtool >/dev/null 2>&1; then
        echo "[WARNING] ethtool is not installed, attempting to install..."
        $PKG_INSTALL ethtool
        if ! command -v ethtool >/dev/null 2>&1; then
            echo "[ERROR] Failed to install ethtool."
        else
            echo "[✓] ethtool was successfully installed."
        fi
    fi

    # Check and install iproute2 (for tc)
    if ! command -v tc >/dev/null 2>&1; then
        echo "[WARNING] tc (from iproute2 package) is not installed, attempting to install..."
        if [ "$PKG_MANAGER" = "apt-get" ] || [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "zypper" ] || [ "$PKG_MANAGER" = "pacman" ] || [ "$PKG_MANAGER" = "apk" ]; then
            $PKG_INSTALL iproute2
        fi

        if ! command -v tc >/dev/null 2>&1; then
            echo "[ERROR] Failed to install tc."
        else
            echo "[✓] tc was successfully installed."
        fi
    fi
    
    return 0
}

# Check and install tools
check_and_install_tools

# Create log file
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "--- $(date): Running autotune-sysctl ---"

# Backup previous settings
if [ -f "$SYSCTL_FILE" ]; then
    cp "$SYSCTL_FILE" "$BACKUP_FILE"
    echo "[*] Previous settings backed up to: $BACKUP_FILE"
fi

# Collect system information
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
CPU_CORES=$(nproc)
DEFAULT_IFACE=$(ip route | awk '/default/ {print $5}' | head -n 1)
NETWORK_SPEED=1000  # Default: 1Gbps
DISK_TYPE="HDD"     # Default: HDD

# Detect disk type (SSD or HDD)
if [ -d "/sys/block" ]; then
    ROOT_DEVICE=$(df / | awk 'NR==2 {print $1}' | sed 's/\/dev\///' | sed 's/[0-9]*$//')
    if [ -n "$ROOT_DEVICE" ] && [ -d "/sys/block/$ROOT_DEVICE" ]; then
        if grep -q "0" "/sys/block/$ROOT_DEVICE/queue/rotational" 2>/dev/null; then
            DISK_TYPE="SSD"
        fi
    fi
fi

# Detect network speed
if [ -n "$DEFAULT_IFACE" ] && [ -d "/sys/class/net/$DEFAULT_IFACE" ]; then
    if [ -f "/sys/class/net/$DEFAULT_IFACE/speed" ]; then
        DETECTED_SPEED=$(cat "/sys/class/net/$DEFAULT_IFACE/speed" 2>/dev/null || echo 1000)
        if [ "$DETECTED_SPEED" -gt 0 ]; then
            NETWORK_SPEED=$DETECTED_SPEED
        fi
    fi
fi

echo "[*] System Information:"
echo "    - Total Memory: $TOTAL_MEM_MB MB"
echo "    - CPU Cores: $CPU_CORES"
echo "    - Default Network Interface: $DEFAULT_IFACE"
echo "    - Network Speed: $NETWORK_SPEED Mbps"
echo "    - Disk Type: $DISK_TYPE"

# Configure values based on system memory
if [ "$TOTAL_MEM_MB" -le 2048 ]; then
    # Low memory system (≤ 2GB)
    RMEM_MAX=4194304           # ~4MB
    WMEM_MAX=4194304           # ~4MB
    TCP_MEM="196608 262144 393216"
    IP_CONNTRACK_MAX=$((TOTAL_MEM_MB * 32))
    NR_OPEN=524288
    FILE_MAX=524288
    INOTIFY_MAX=65536
    MIN_FREE_KB=32768
elif [ "$TOTAL_MEM_MB" -le 4096 ]; then
    # Medium memory system (≤ 4GB)
    RMEM_MAX=8388608           # ~8MB
    WMEM_MAX=8388608           # ~8MB
    TCP_MEM="393216 524288 786432"
    IP_CONNTRACK_MAX=$((TOTAL_MEM_MB * 48))
    NR_OPEN=1048576
    FILE_MAX=1048576
    INOTIFY_MAX=131072
    MIN_FREE_KB=49152
elif [ "$TOTAL_MEM_MB" -le 8192 ]; then
    # High memory system (≤ 8GB)
    RMEM_MAX=16777216          # ~16MB
    WMEM_MAX=16777216          # ~16MB
    TCP_MEM="786432 1048576 1572864"
    IP_CONNTRACK_MAX=$((TOTAL_MEM_MB * 64))
    NR_OPEN=2097152
    FILE_MAX=2097152
    INOTIFY_MAX=262144
    MIN_FREE_KB=65536
elif [ "$TOTAL_MEM_MB" -le 16384 ]; then
    # Very high memory system (≤ 16GB)
    RMEM_MAX=33554432          # ~32MB
    WMEM_MAX=33554432          # ~32MB
    TCP_MEM="1572864 2097152 3145728"
    IP_CONNTRACK_MAX=$((TOTAL_MEM_MB * 96))
    NR_OPEN=3097152
    FILE_MAX=3097152
    INOTIFY_MAX=524288
    MIN_FREE_KB=98304
else
    # Extremely high memory system (> 16GB)
    RMEM_MAX=67108864          # ~64MB
    WMEM_MAX=67108864          # ~64MB
    TCP_MEM="3145728 4194304 6291456"
    IP_CONNTRACK_MAX=$((TOTAL_MEM_MB * 128))
    NR_OPEN=4194304
    FILE_MAX=4194304
    INOTIFY_MAX=1048576
    MIN_FREE_KB=131072
fi

# Configure based on network speed
if [ "$NETWORK_SPEED" -ge 10000 ]; then
    # 10Gbps network or higher
    if [ "$TOTAL_MEM_MB" -gt 16384 ]; then
        RMEM_MAX=134217728     # ~128MB
        WMEM_MAX=134217728     # ~128MB
        NETDEV_MAX_BACKLOG=32768
        SOMAXCONN=32768
    else
        RMEM_MAX=$((RMEM_MAX * 2))
        WMEM_MAX=$((WMEM_MAX * 2))
        NETDEV_MAX_BACKLOG=16384
        SOMAXCONN=16384
    fi
elif [ "$NETWORK_SPEED" -ge 1000 ]; then
    # 1Gbps network
    NETDEV_MAX_BACKLOG=8192
    SOMAXCONN=8192
else
    # Less than 1Gbps network
    NETDEV_MAX_BACKLOG=2048
    SOMAXCONN=2048
fi

# Configure queue algorithm and congestion control
QDISC="fq_codel"
CONGESTION="bbr"
if ! grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    echo "[*] BBR is not available, using cubic instead"
    CONGESTION="cubic"
elif grep -q "bbr2" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    echo "[*] BBR2 is available, using bbr2 instead of bbr"
    CONGESTION="bbr2"
fi

# Check fq_codel support
if ! tc qdisc show 2>/dev/null | grep -q "fq_codel"; then
    if modprobe sch_fq_codel 2>/dev/null; then
        echo "[*] fq_codel module loaded successfully"
    else
        echo "[*] fq_codel is not supported, using fq instead"
        QDISC="fq"
        if ! tc qdisc show 2>/dev/null | grep -q "fq"; then
            if ! modprobe sch_fq 2>/dev/null; then
                echo "[*] fq is also not supported, using default"
                QDISC="pfifo_fast"
            fi
        fi
    fi
fi

# Disk type optimization
if [ "$DISK_TYPE" = "SSD" ]; then
    SWAPPINESS=1
    VFS_CACHE_PRESSURE=50
    DIRTY_RATIO=10
    DIRTY_BACKGROUND_RATIO=5
    MAX_MAP_COUNT=1048576
else
    SWAPPINESS=10
    VFS_CACHE_PRESSURE=100
    DIRTY_RATIO=20
    DIRTY_BACKGROUND_RATIO=10
    MAX_MAP_COUNT=524288
fi

# Create system configuration file
cat <<EOT > "$SYSCTL_FILE"
# Optimized Linux kernel settings
# Created on: $(date)

# --- Network Settings ---
# Queue and congestion control
net.core.default_qdisc=$QDISC
net.ipv4.tcp_congestion_control=$CONGESTION

# Send and receive buffers
net.core.rmem_max=$RMEM_MAX
net.core.wmem_max=$WMEM_MAX
net.core.rmem_default=$((RMEM_MAX / 4))
net.core.wmem_default=$((WMEM_MAX / 4))
net.ipv4.tcp_rmem=4096 87380 $RMEM_MAX
net.ipv4.tcp_wmem=4096 87380 $WMEM_MAX
net.ipv4.tcp_mem=$TCP_MEM
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192

# TCP connection optimization
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_max_syn_backlog=$((SOMAXCONN * 2))
net.ipv4.tcp_max_tw_buckets=$((SOMAXCONN * 4))
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_ecn=1

# Increase local port range
net.ipv4.ip_local_port_range=1024 65535

# Other network settings
net.core.somaxconn=$SOMAXCONN
net.core.netdev_max_backlog=$NETDEV_MAX_BACKLOG
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_adv_win_scale=-2
net.ipv4.route.gc_timeout=100
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.secure_redirects=0
net.ipv4.conf.default.secure_redirects=0

# Connection tracking settings
net.netfilter.nf_conntrack_max=$IP_CONNTRACK_MAX
net.netfilter.nf_conntrack_tcp_timeout_established=86400
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30

# --- Filesystem and Memory Settings ---
fs.inotify.max_user_watches=$INOTIFY_MAX
fs.inotify.max_user_instances=1024
fs.file-max=$FILE_MAX
fs.nr_open=$NR_OPEN
fs.suid_dumpable=0
fs.protected_hardlinks=1
fs.protected_symlinks=1

# Virtual memory settings
vm.swappiness=$SWAPPINESS
vm.vfs_cache_pressure=$VFS_CACHE_PRESSURE
vm.dirty_ratio=$DIRTY_RATIO
vm.dirty_background_ratio=$DIRTY_BACKGROUND_RATIO
vm.min_free_kbytes=$MIN_FREE_KB
vm.max_map_count=$MAX_MAP_COUNT
vm.overcommit_memory=1
vm.overcommit_ratio=50
vm.page-cluster=3
vm.dirty_expire_centisecs=3000
vm.dirty_writeback_centisecs=500

# --- Kernel and Security Settings ---
kernel.sched_autogroup_enabled=1
kernel.sched_migration_cost_ns=5000000
kernel.sched_latency_ns=10000000
kernel.sched_min_granularity_ns=4000000
kernel.panic=10
kernel.pid_max=65536
kernel.threads-max=$((FILE_MAX / 4))
kernel.sysrq=1
kernel.randomize_va_space=2

# System-specific settings
kernel.sched_child_runs_first=0
kernel.numa_balancing=0
EOT

# Apply the new settings
if ! sysctl --system; then
    echo -e "\e[1;31m[ERROR] Problem applying settings.\e[0m"
    # Restore backup file in case of error
    if [ -f "$BACKUP_FILE" ]; then
        mv "$BACKUP_FILE" "$SYSCTL_FILE"
        sysctl --system
        echo "[*] Settings restored to previous state."
    fi
    exit 1
fi

# Apply specific settings for current network interface
if [ -n "$DEFAULT_IFACE" ]; then
    echo "[*] Setting parameters for network interface $DEFAULT_IFACE"
    
    # Increase ring buffer for network card
    if [ -d "/sys/class/net/$DEFAULT_IFACE/queues" ]; then
        RX_QUEUES=$(ls -1 /sys/class/net/$DEFAULT_IFACE/queues/ | grep "rx-" | wc -l)
        if [ "$RX_QUEUES" -gt 0 ]; then
            echo "[*] Setting $RX_QUEUES receive queues"
            if [ "$NETWORK_SPEED" -ge 10000 ]; then
                RX_RING=4096
            elif [ "$NETWORK_SPEED" -ge 1000 ]; then
                RX_RING=2048
            else
                RX_RING=1024
            fi
            
            # Try to set ring size
            if ethtool -g "$DEFAULT_IFACE" &>/dev/null; then
                MAX_RING=$(ethtool -g "$DEFAULT_IFACE" 2>/dev/null | grep "RX:" -A 1 | tail -1 | awk '{print $1}')
                if [ -n "$MAX_RING" ] && [ "$MAX_RING" -gt 0 ]; then
                    if [ "$RX_RING" -gt "$MAX_RING" ]; then
                        RX_RING=$MAX_RING
                    fi
                    ethtool -G "$DEFAULT_IFACE" rx "$RX_RING" &>/dev/null && \
                        echo "[*] $DEFAULT_IFACE receive ring size set to $RX_RING" || \
                        echo "[*] Error setting receive ring size"
                fi
            fi
        fi
    fi
    
    # Check and set TSO and LRO
    if ethtool -k "$DEFAULT_IFACE" &>/dev/null; then
        echo "[*] Optimizing transfer offload"
        # Enable offload capabilities
        ethtool -K "$DEFAULT_IFACE" tso on gso on gro on sg on rx on tx on &>/dev/null || true
    fi
    
    # Set queue rules for network interface
    if tc qdisc show dev "$DEFAULT_IFACE" &>/dev/null; then
        echo "[*] Setting queue policy for $DEFAULT_IFACE to $QDISC"
        tc qdisc replace dev "$DEFAULT_IFACE" root "$QDISC" &>/dev/null || \
            echo "[*] Error setting queue policy"
    fi
    
    # MTU setting removed as requested
fi

echo -e "\e[1;32m[✓] System settings have been successfully optimized.\e[0m"
exit 0
EOF

chmod +x "$INSTALL_PATH"

# Create service or scheduling mechanism
if command -v systemctl >/dev/null 2>&1; then
    # systemd service
    cat <<EOF > "$SERVICE_PATH"
[Unit]
Description=Auto-tune sysctl parameters
After=network.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH
TimeoutStartSec=300
KillMode=process
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF

    # systemd timer
    cat <<EOF > "$TIMER_PATH"
[Unit]
Description=Run autotune-sysctl periodically
After=network.target

[Timer]
OnBootSec=2min
OnUnitActiveSec=8h
AccuracySec=1m
RandomizedDelaySec=30s
Unit=autotune-sysctl.service

[Install]
WantedBy=timers.target
EOF
fi

# Install required drivers and modules
echo -e "\e[1;34m[*] Checking and installing required modules...\e[0m"
for MODULE in tcp_bbr sch_fq_codel sch_fq nf_conntrack; do
    if ! lsmod | grep -q "$MODULE"; then
        echo "[*] Loading module $MODULE"
        modprobe "$MODULE" 2>/dev/null || echo "[!] Module $MODULE is not available"
    fi
done

# Register modules to be loaded at boot
if [ ! -f "/etc/modules-load.d/autotune.conf" ]; then
    echo -e "# Required modules for autotune-sysctl\ntcp_bbr\nsch_fq_codel\nsch_fq\nnf_conntrack" > "/etc/modules-load.d/autotune.conf"
    echo "[*] Required modules added to boot configuration file"
fi

# Setup scheduling mechanism
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload

    echo -e "\e[1;34m[*] Enabling service and timer...\e[0m"
    systemctl enable autotune-sysctl.service
    systemctl enable autotune-sysctl.timer
    systemctl start autotune-sysctl.service
    systemctl start autotune-sysctl.timer
    echo -e "\e[1;34m[*] The script will run every 8 hours via systemd timer.\e[0m"
else
    echo -e "\e[1;34m[*] Setting up cron job...\e[0m"
    echo "0 */8 * * * root $INSTALL_PATH" > "$CRON_FILE"
    chmod 644 "$CRON_FILE"
    if command -v service >/dev/null 2>&1; then
        service cron reload 2>/dev/null || service crond reload 2>/dev/null || true
    fi
    echo -e "\e[1;34m[*] The script will run every 8 hours via cron.\e[0m"
fi

echo -e "\e[1;32m[✓] Installation and configuration of autotune-sysctl completed successfully.\e[0m"
echo -e "\e[1;34m[*] Settings saved to $SYSCTL_FILE.\e[0m"
echo -e "\e[1;34m[*] Logs are saved to /var/log/autotune-sysctl.log.\e[0m"
echo -e "\e[1;34m[*] For manual execution: sudo $INSTALL_PATH\e[0m"

exit 0
