#!/bin/bash

# ==============================================================================
# Xray / V2Ray High-Concurrency Kernel & Network Optimizer
# Optimized for: 100-400+ Concurrent Users | Instagram (HTTP/3, QUIC, UDP & TCP)
# Target OS: Ubuntu / Debian / CentOS / AlmaLinux / Rocky / Arch / Alpine
# ==============================================================================

set -e

INSTALL_PATH="/usr/local/bin/xray-autotune.sh"
SERVICE_PATH="/etc/systemd/system/xray-autotune.service"
SYSCTL_FILE="/etc/sysctl.d/99-xray-autotune.conf"
LIMITS_FILE="/etc/security/limits.d/99-xray-nofile.conf"

# 1. Root privilege check
if [ "$(id -u)" -ne 0 ]; then
    echo -e "\e[1;31m[ERROR] This script must be run as root.\e[0m"
    exit 1
fi

echo -e "\e[1;34m[*] Starting Xray/V2Ray Server Optimization Setup...\e[0m"

# 2. Cleanup legacy/faulty 8-hour timers from previous script (if present)
echo -e "\e[1;34m[*] Cleaning up any legacy 8-hour autotune timers and conflicting files...\e[0m"
systemctl stop autotune-sysctl.timer autotune-sysctl.service 2>/dev/null || true
systemctl disable autotune-sysctl.timer autotune-sysctl.service 2>/dev/null || true
rm -f /etc/systemd/system/autotune-sysctl.timer \
      /etc/systemd/system/autotune-sysctl.service \
      /etc/cron.d/autotune-sysctl \
      /usr/local/bin/autotune-sysctl.sh \
      /etc/sysctl.d/99-autotune.conf \
      /etc/sysctl.d/99-v2ray-optimize.conf \
      /etc/modules-load.d/autotune.conf

# Also disable duplicate network-rps service if created manually earlier
systemctl stop network-rps.service 2>/dev/null || true
systemctl disable network-rps.service 2>/dev/null || true
rm -f /etc/systemd/system/network-rps.service

# 3. Install required network utilities ONCE during installation
install_dependencies() {
    local MISSING_PKGS=""
    command -v ethtool >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS ethtool"
    command -v tc >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS iproute2"

    if [ -n "$MISSING_PKGS" ]; then
        echo -e "\e[1;33m[*] Installing required packages:$MISSING_PKGS...\e[0m"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $MISSING_PKGS
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y -q $MISSING_PKGS
        elif command -v yum >/dev/null 2>&1; then
            yum install -y -q $MISSING_PKGS
        elif command -v pacman >/dev/null 2>&1; then
            pacman -Sy --noconfirm $MISSING_PKGS
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache $MISSING_PKGS
        elif command -v zypper >/dev/null 2>&1; then
            zypper install -y $MISSING_PKGS
        else
            echo -e "\e[1;33m[!] Package manager not found. Please install$MISSING_PKGS manually.\e[0m"
        fi
    fi
}
install_dependencies

# 4. Load ONLY essential congestion/queue modules (Strictly NO nf_conntrack!)
echo -e "\e[1;34m[*] Configuring kernel modules (BBR & FQ)...\e[0m"
modprobe tcp_bbr 2>/dev/null || true
modprobe sch_fq 2>/dev/null || true

cat << 'EOF' > /etc/modules-load.d/xray-autotune.conf
tcp_bbr
sch_fq
EOF

# 5. Ensure safety Swap exists (2GB) if system has 0 Swap
TOTAL_SWAP_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
if [ "${TOTAL_SWAP_KB:-0}" -eq 0 ]; then
    AVAIL_DISK_GB=$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')
    if [ "${AVAIL_DISK_GB:-0}" -ge 5 ]; then
        echo -e "\e[1;34m[*] No swap detected. Creating a 2GB safety swapfile...\e[0m"
        if [ ! -f /swapfile ]; then
            fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null
            swapon /swapfile
            if ! grep -q "/swapfile" /etc/fstab; then
                echo '/swapfile none swap sw 0 0' >> /etc/fstab
            fi
            echo -e "\e[1;32m[✓] 2GB Swap created and activated.\e[0m"
        fi
    fi
fi

# 6. Configure system-wide Open Files Limits (ulimit & systemd)
echo -e "\e[1;34m[*] Applying system-wide file descriptor limits (524288)...\e[0m"
mkdir -p /etc/security/limits.d
cat << 'EOF' > "$LIMITS_FILE"
* soft nofile 524288
* hard nofile 524288
* soft nproc 65535
* hard nproc 65535
root soft nofile 524288
root hard nofile 524288
root soft nproc 65535
root hard nproc 65535
EOF

if [ -f /etc/pam.d/common-session ] && ! grep -q "pam_limits.so" /etc/pam.d/common-session; then
    echo "session required pam_limits.so" >> /etc/pam.d/common-session
fi

if [ -f /etc/systemd/system.conf ]; then
    sed -i 's/^#*DefaultLimitNOFILE=.*/DefaultLimitNOFILE=524288/g' /etc/systemd/system.conf
    if ! grep -q "^DefaultLimitNOFILE=" /etc/systemd/system.conf; then
        echo "DefaultLimitNOFILE=524288" >> /etc/systemd/system.conf
    fi
    systemctl daemon-reexec 2>/dev/null || true
fi

# 7. Create the main boot/runtime optimization script
cat << 'EOF' > "$INSTALL_PATH"
#!/bin/bash

SYSCTL_FILE="/etc/sysctl.d/99-xray-autotune.conf"
LOG_FILE="/var/log/xray-autotune.log"

exec > >(tee -a "${LOG_FILE}") 2>&1
echo "============================================================"
echo "--- $(date): Running Xray Kernel & Hardware Auto-Tuner ---"

# Gather hardware metrics
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
CPU_CORES=$(nproc 2>/dev/null || echo 2)
DEFAULT_IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk -- '{printf $5}' | head -n 1)
[ -z "$DEFAULT_IFACE" ] && DEFAULT_IFACE=$(ip route | awk '/default/ {print $5}' | head -n 1)

# Scale network buffers & file limits based on RAM
if [ "$TOTAL_MEM_MB" -le 2048 ]; then
    # <= 2GB RAM (100-150 concurrent users)
    RMEM_MAX=8388608           # 8 MB
    WMEM_MAX=8388608           # 8 MB
    TCP_MEM="196608 262144 393216"
    UDP_MEM="196608 262144 393216"
    SOMAXCONN=32768
    BACKLOG=32768
    TW_BUCKETS=32768
    FILE_MAX=524288
    MIN_FREE_KB=32768
elif [ "$TOTAL_MEM_MB" -le 4096 ]; then
    # 2GB - 4GB RAM (150-250 concurrent users)
    RMEM_MAX=16777216          # 16 MB
    WMEM_MAX=16777216          # 16 MB
    TCP_MEM="393216 524288 786432"
    UDP_MEM="393216 524288 786432"
    SOMAXCONN=49152
    BACKLOG=49152
    TW_BUCKETS=49152
    FILE_MAX=1048576
    MIN_FREE_KB=49152
elif [ "$TOTAL_MEM_MB" -le 8192 ]; then
    # 4GB - 8GB RAM (250-400+ concurrent users)
    RMEM_MAX=33554432          # 32 MB
    WMEM_MAX=33554432          # 32 MB
    TCP_MEM="786432 1048576 1572864"
    UDP_MEM="786432 1048576 1572864"
    SOMAXCONN=65535
    BACKLOG=65535
    TW_BUCKETS=65536
    FILE_MAX=2097152
    MIN_FREE_KB=65536
else
    # > 8GB RAM (400+ heavy concurrent users)
    RMEM_MAX=67108864          # 64 MB
    WMEM_MAX=67108864          # 64 MB
    TCP_MEM="1572864 2097152 3145728"
    UDP_MEM="1572864 2097152 3145728"
    SOMAXCONN=65535
    BACKLOG=65535
    TW_BUCKETS=65536
    FILE_MAX=4194304
    MIN_FREE_KB=98304
fi

# Strictly prioritize 'fq' for BBR pacing (reduces CPU overhead & packet drops)
QDISC="fq"
if ! modprobe sch_fq 2>/dev/null && ! grep -q "fq" /proc/net/psched 2>/dev/null; then
    QDISC="fq_codel"
fi

CONGESTION="bbr"
if ! grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    CONGESTION="cubic"
fi

echo "[*] Detected Hardware: ${TOTAL_MEM_MB}MB RAM | ${CPU_CORES} CPU Cores | NIC: ${DEFAULT_IFACE}"
echo "[*] Selected Profile: Congestion=${CONGESTION} | Qdisc=${QDISC} | MaxBuffer=$((RMEM_MAX/1048576))MB | Backlog=${BACKLOG}"

# Write the sysctl configuration
cat <<EOT > "$SYSCTL_FILE"
# ==============================================================================
# Xray / V2Ray High-Concurrency Kernel Profile (Instagram TCP/UDP/QUIC Tuned)
# Generated on: $(date)
# ==============================================================================

# 1. Congestion Control & Packet Pacing
net.core.default_qdisc = $QDISC
net.ipv4.tcp_congestion_control = $CONGESTION

# 2. File Descriptors & Socket Capacities
fs.file-max = $FILE_MAX
fs.nr_open = $FILE_MAX
fs.inotify.max_user_watches = 262144
fs.inotify.max_user_instances = 1024

# 3. High-Concurrency Listen & Network Queues
net.core.somaxconn = $SOMAXCONN
net.core.netdev_max_backlog = $BACKLOG
net.ipv4.tcp_max_syn_backlog = $BACKLOG
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000

# 4. TCP & UDP Socket Buffers (Tuned for Instagram Reels/Stories & QUIC bursts)
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $WMEM_MAX
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 87380 $RMEM_MAX
net.ipv4.tcp_wmem = 4096 65536 $WMEM_MAX
net.ipv4.tcp_mem = $TCP_MEM
net.ipv4.udp_mem = $UDP_MEM
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# 5. TCP Connection Lifecycle (Fast recycling for CDN outbound connections)
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = $TW_BUCKETS
net.ipv4.tcp_max_orphans = 32768

# 6. Keepalive & Idle Optimization (Prevents speed drop between Instagram scrolls)
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_fastopen = 3

# 7. High-Latency / Mobile ISP Resilience (Iran -> Server path)
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_Window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_moderate_rcvbuf = 1

# 8. Memory & Swap Management (Protect CPU & Disk I/O)
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.min_free_kbytes = $MIN_FREE_KB
vm.overcommit_memory = 0
vm.max_map_count = 524288

# 9. Security & Kernel Stability
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
kernel.panic = 10
kernel.pid_max = 65536
EOT

# fixing window_scaling case typo safely
sed -i 's/tcp_Window_scaling/tcp_window_scaling/g' "$SYSCTL_FILE"

# 10. Conditional Conntrack Tuning (ONLY if nf_conntrack is ALREADY loaded by Docker/UFW)
if [ -d "/proc/sys/net/netfilter" ]; then
    CONNTRACK_MAX=$((TOTAL_MEM_MB * 64))
    [ "$CONNTRACK_MAX" -lt 131072 ] && CONNTRACK_MAX=131072
    echo "[*] Active nf_conntrack detected. Tuning conntrack table for UDP/QUIC..."
    cat <<EOT >> "$SYSCTL_FILE"

# 10. Conntrack Optimization (Active only because firewall/Docker is loaded)
net.netfilter.nf_conntrack_max = $CONNTRACK_MAX
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_udp_timeout = 15
net.netfilter.nf_conntrack_udp_timeout_stream = 60
EOT
    # Adjust hashsize dynamically to reduce CPU lookup time
    if [ -w "/sys/module/nf_conntrack/parameters/hashsize" ]; then
        echo $((CONNTRACK_MAX / 4)) > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
    fi
else
    echo "[✓] nf_conntrack is NOT active (Optimal: Saves 15-25% CPU overhead)."
fi

# 11. Sanitize /etc/sysctl.conf so it NEVER overrides our 99-xray-autotune.conf
if [ -f /etc/sysctl.conf ]; then
    cp /etc/sysctl.conf /etc/sysctl.conf.bak-xray 2>/dev/null || true
    KEYS=$(grep -E '^[a-zA-Z0-9_.]+\s*=' "$SYSCTL_FILE" | awk -F= '{print $1}' | tr -d ' ')
    for KEY in $KEYS; do
        ESCAPED_KEY=$(echo "$KEY" | sed 's/\./\\./g')
        sed -i -E "s/^(\s*${ESCAPED_KEY}\s*=)/# [Overridden by xray-autotune] \1/g" /etc/sysctl.conf
    done
fi

# Apply sysctl parameters
sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1

# 12. Hardware NIC, Qdisc, and Multi-Core CPU RPS/RFS Optimization
if [ -n "$DEFAULT_IFACE" ] && [ -d "/sys/class/net/$DEFAULT_IFACE" ]; then
    echo "[*] Optimizing Network Interface ($DEFAULT_IFACE) & CPU Core Distribution..."

    # Increase TX Queue Length for high packet rates
    ip link set dev "$DEFAULT_IFACE" txqueuelen 10000 2>/dev/null || true

    # Apply root qdisc immediately
    if command -v tc >/dev/null 2>&1; then
        tc qdisc replace dev "$DEFAULT_IFACE" root "$QDISC" 2>/dev/null || true
    fi

    # Enable hardware offloading to reduce CPU load
    if command -v ethtool >/dev/null 2>&1; then
        ethtool -K "$DEFAULT_IFACE" tso on gso on gro on sg on rx on tx on 2>/dev/null || true

        # Safely maximize NIC RX/TX ring buffers (runs ONLY at boot/install)
        MAX_RX=$(ethtool -g "$DEFAULT_IFACE" 2>/dev/null | awk '/Pre-set maximums:/,/^$/' | awk '/RX:/ {print $2}' | head -n 1)
        CUR_RX=$(ethtool -g "$DEFAULT_IFACE" 2>/dev/null | awk '/Current hardware settings:/,/^$/' | awk '/RX:/ {print $2}' | head -n 1)
        if [[ "$MAX_RX" =~ ^[0-9]+$ ]] && [ "$MAX_RX" -gt 0 ]; then
            TARGET_RX=$MAX_RX
            [ "$TARGET_RX" -gt 4096 ] && TARGET_RX=4096
            if [ "${CUR_RX:-0}" -lt "$TARGET_RX" ]; then
                ethtool -G "$DEFAULT_IFACE" rx "$TARGET_RX" 2>/dev/null || true
            fi
        fi
    fi

    # Calculate Hexadecimal Bitmask for ALL CPU cores (RPS) & RFS flow entries
    if [ -d "/sys/class/net/$DEFAULT_IFACE/queues" ]; then
        # Safe calculation of CPU hex mask for 1 to 64 cores
        if [ "$CPU_CORES" -ge 32 ]; then
            CPU_MASK="ffffffff"
        else
            CPU_MASK=$(printf '%x' $(( (1 << CPU_CORES) - 1 )))
        fi

        RX_COUNT=$(ls -1d /sys/class/net/"$DEFAULT_IFACE"/queues/rx-* 2>/dev/null | wc -l)
        if [ "$RX_COUNT" -gt 0 ]; then
            RFS_ENTRIES=32768
            FLOW_CNT=$((RFS_ENTRIES / RX_COUNT))
            sysctl -w net.core.rps_sock_flow_entries=$RFS_ENTRIES >/dev/null 2>&1 || true

            for rx_dir in /sys/class/net/"$DEFAULT_IFACE"/queues/rx-*; do
                [ -w "$rx_dir/rps_cpus" ] && echo "$CPU_MASK" > "$rx_dir/rps_cpus" 2>/dev/null || true
                [ -w "$rx_dir/rps_flow_cnt" ] && echo "$FLOW_CNT" > "$rx_dir/rps_flow_cnt" 2>/dev/null || true
            done
            echo "[✓] RPS/RFS enabled across $CPU_CORES CPU cores (Mask: 0x$CPU_MASK, Queues: $RX_COUNT)."
        fi

        # Enable XPS (Transmit Packet Steering) if multiple TX queues exist
        for tx_dir in /sys/class/net/"$DEFAULT_IFACE"/queues/tx-*; do
            [ -w "$tx_dir/xps_cpus" ] && echo "$CPU_MASK" > "$tx_dir/xps_cpus" 2>/dev/null || true
        done
    fi
fi

echo "[✓] Xray optimization completed successfully at $(date)."
EOF

chmod +x "$INSTALL_PATH"

# 8. Create Boot-Once Systemd Service (NO periodic timer!)
echo -e "\e[1;34m[*] Registering boot-time systemd service (xray-autotune.service)...\e[0m"
cat << EOF > "$SERVICE_PATH"
[Unit]
Description=Xray/V2Ray High-Concurrency Kernel & NIC Optimizer
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray-autotune.service >/dev/null 2>&1
systemctl restart xray-autotune.service

# 9. Final Verification Summary Table
echo ""
echo -e "\e[1;32m==================================================================\e[0m"
echo -e "\e[1;32m       XRAY / V2RAY OPTIMIZATION VERIFICATION REPORT              \e[0m"
echo -e "\e[1;32m==================================================================\e[0m"
MAIN_IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk -- '{printf $5}' | head -n 1)
RPS_VAL=$(cat /sys/class/net/${MAIN_IFACE}/queues/rx-0/rps_cpus 2>/dev/null || echo "N/A")
CONNTRACK_STATUS=$( [ -d /proc/sys/net/netfilter ] && echo "Active (Tuned to $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null))" || echo "Disabled (Optimal - Zero CPU Overhead)" )

printf "%-32s : \e[1;36m%s\e[0m\n" "1. Congestion Control" "$(sysctl -n net.ipv4.tcp_congestion_control)"
printf "%-32s : \e[1;36m%s\e[0m\n" "2. Default Queue Discipline" "$(sysctl -n net.core.default_qdisc)"
printf "%-32s : \e[1;36m%s\e[0m\n" "3. Max Socket Backlog (somaxconn)" "$(sysctl -n net.core.somaxconn)"
printf "%-32s : \e[1;36m%s\e[0m\n" "4. Netdev Max Backlog" "$(sysctl -n net.core.netdev_max_backlog)"
printf "%-32s : \e[1;36m%s\e[0m\n" "5. Max Time-Wait Buckets" "$(sysctl -n net.ipv4.tcp_max_tw_buckets)"
printf "%-32s : \e[1;36m%s\e[0m\n" "6. UDP Min Rmem/Wmem (QUIC)" "$(sysctl -n net.ipv4.udp_rmem_min) bytes"
printf "%-32s : \e[1;36m%s\e[0m\n" "7. TCP Slow Start After Idle" "$(sysctl -n net.ipv4.tcp_slow_start_after_idle) (Disabled)"
printf "%-32s : \e[1;36m%s\e[0m\n" "8. System File-Max" "$(sysctl -n fs.file-max)"
printf "%-32s : \e[1;36m%s\e[0m\n" "9. CPU Multi-Core RPS Mask" "0x${RPS_VAL} (Interface: ${MAIN_IFACE})"
printf "%-32s : \e[1;36m%s\e[0m\n" "10. Conntrack Status" "${CONNTRACK_STATUS}"
printf "%-32s : \e[1;36m%s\e[0m\n" "11. Boot Service Status" "$(systemctl is-enabled xray-autotune.service)"
echo -e "\e[1;32m==================================================================\e[0m"
echo -e "\e[1;33m[NOTE] Reconnect your SSH session once to see 'ulimit -n' updated to 524288.\e[0m"
