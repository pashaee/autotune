#!/bin/bash

# اسکریپت بهینه‌سازی شده autotune-sysctl
# تنظیم خودکار پارامترهای سیستم برای حداکثر کارایی شبکه و سیستم

set -e

echo -e "\e[1;34m[*] نصب اسکریپت بهینه‌شده autotune-sysctl...\e[0m"

INSTALL_PATH="/usr/local/bin/autotune-sysctl.sh"
SERVICE_PATH="/etc/systemd/system/autotune-sysctl.service"
TIMER_PATH="/etc/systemd/system/autotune-sysctl.timer"
SYSCTL_FILE="/etc/sysctl.d/99-autotune.conf"

# بررسی دسترسی روت
if [ "$(id -u)" -ne 0 ]; then
    echo -e "\e[1;31m[خطا] این اسکریپت باید با دسترسی روت اجرا شود.\e[0m"
    exit 1
fi

# بررسی و نصب ابزارهای مورد نیاز
echo -e "\e[1;34m[*] بررسی ابزارهای مورد نیاز...\e[0m"

# تشخیص نوع سیستم مدیریت بسته
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
elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
    PKG_INSTALL="zypper install -y"
else
    echo -e "\e[1;33m[هشدار] سیستم مدیریت بسته شناسایی نشد. نصب خودکار ابزارها امکان‌پذیر نیست.\e[0m"
    PKG_MANAGER=""
    PKG_INSTALL=""
fi

# بررسی و نصب ethtool
if ! command -v ethtool >/dev/null 2>&1; then
    echo -e "\e[1;33m[هشدار] ethtool نصب نشده است، تلاش برای نصب...\e[0m"
    if [ -n "$PKG_MANAGER" ]; then
        $PKG_INSTALL ethtool
        if command -v ethtool >/dev/null 2>&1; then
            echo -e "\e[1;32m[✓] ethtool با موفقیت نصب شد.\e[0m"
        else
            echo -e "\e[1;31m[خطا] نصب ethtool ناموفق بود.\e[0m"
        fi
    fi
else
    echo -e "\e[1;32m[✓] ethtool نصب شده است.\e[0m"
fi

# بررسی و نصب iproute2 (برای tc)
if ! command -v tc >/dev/null 2>&1; then
    echo -e "\e[1;33m[هشدار] tc (از بسته iproute2) نصب نشده است، تلاش برای نصب...\e[0m"
    if [ -n "$PKG_MANAGER" ]; then
        if [ "$PKG_MANAGER" = "apt-get" ] || [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
            $PKG_INSTALL iproute2
        elif [ "$PKG_MANAGER" = "pacman" ]; then
            $PKG_INSTALL iproute2
        elif [ "$PKG_MANAGER" = "zypper" ]; then
            $PKG_INSTALL iproute2
        fi
        
        if command -v tc >/dev/null 2>&1; then
            echo -e "\e[1;32m[✓] tc با موفقیت نصب شد.\e[0m"
        else
            echo -e "\e[1;31m[خطا] نصب tc ناموفق بود.\e[0m"
        fi
    fi
else
    echo -e "\e[1;32m[✓] tc نصب شده است.\e[0m"
fi

# ایجاد یک فایل پیکربندی اصلی
cat <<'EOF' > "$INSTALL_PATH"
#!/bin/bash

# تنظیم متغیرهای مسیر
SYSCTL_FILE="/etc/sysctl.d/99-autotune.conf"
BACKUP_FILE="/etc/sysctl.d/99-autotune.bak"
LOG_FILE="/var/log/autotune-sysctl.log"

# بررسی نصب ابزارهای مورد نیاز
check_and_install_tools() {
    # تشخیص نوع سیستم مدیریت بسته
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
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MANAGER="zypper"
        PKG_INSTALL="zypper install -y"
    else
        echo "[هشدار] سیستم مدیریت بسته شناسایی نشد. نصب خودکار ابزارها امکان‌پذیر نیست."
        return 1
    fi

    # بررسی و نصب ethtool
    if ! command -v ethtool >/dev/null 2>&1; then
        echo "[هشدار] ethtool نصب نشده است، تلاش برای نصب..."
        $PKG_INSTALL ethtool
        if ! command -v ethtool >/dev/null 2>&1; then
            echo "[خطا] نصب ethtool ناموفق بود."
        else
            echo "[✓] ethtool با موفقیت نصب شد."
        fi
    fi

    # بررسی و نصب iproute2 (برای tc)
    if ! command -v tc >/dev/null 2>&1; then
        echo "[هشدار] tc (از بسته iproute2) نصب نشده است، تلاش برای نصب..."
        if [ "$PKG_MANAGER" = "apt-get" ] || [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "zypper" ]; then
            $PKG_INSTALL iproute2
        elif [ "$PKG_MANAGER" = "pacman" ]; then
            $PKG_INSTALL iproute2
        fi
        
        if ! command -v tc >/dev/null 2>&1; then
            echo "[خطا] نصب tc ناموفق بود."
        else
            echo "[✓] tc با موفقیت نصب شد."
        fi
    fi
    
    return 0
}

# بررسی و نصب ابزارها
check_and_install_tools

# ایجاد فایل گزارش
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "--- $(date): اجرای autotune-sysctl ---"

# پشتیبان‌گیری از تنظیمات قبلی
if [ -f "$SYSCTL_FILE" ]; then
    cp "$SYSCTL_FILE" "$BACKUP_FILE"
    echo "[*] از تنظیمات قبلی پشتیبان گرفته شد: $BACKUP_FILE"
fi

# جمع‌آوری اطلاعات سیستم
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
CPU_CORES=$(nproc)
DEFAULT_IFACE=$(ip route | awk '/default/ {print $5}' | head -n 1)
NETWORK_SPEED=1000  # پیش‌فرض: 1Gbps
DISK_TYPE="HDD"     # پیش‌فرض: HDD

# تشخیص نوع دیسک (SSD یا HDD)
if [ -d "/sys/block" ]; then
    ROOT_DEVICE=$(df / | awk 'NR==2 {print $1}' | sed 's/\/dev\///' | sed 's/[0-9]*$//')
    if [ -n "$ROOT_DEVICE" ] && [ -d "/sys/block/$ROOT_DEVICE" ]; then
        if grep -q "0" "/sys/block/$ROOT_DEVICE/queue/rotational" 2>/dev/null; then
            DISK_TYPE="SSD"
        fi
    fi
fi

# تشخیص سرعت شبکه
if [ -n "$DEFAULT_IFACE" ] && [ -d "/sys/class/net/$DEFAULT_IFACE" ]; then
    if [ -f "/sys/class/net/$DEFAULT_IFACE/speed" ]; then
        DETECTED_SPEED=$(cat "/sys/class/net/$DEFAULT_IFACE/speed" 2>/dev/null || echo 1000)
        if [ "$DETECTED_SPEED" -gt 0 ]; then
            NETWORK_SPEED=$DETECTED_SPEED
        fi
    fi
fi

echo "[*] اطلاعات سیستم:"
echo "    - حافظه کل: $TOTAL_MEM_MB MB"
echo "    - تعداد هسته‌های CPU: $CPU_CORES"
echo "    - رابط شبکه پیش‌فرض: $DEFAULT_IFACE"
echo "    - سرعت شبکه: $NETWORK_SPEED Mbps"
echo "    - نوع دیسک: $DISK_TYPE"

# تنظیم مقادیر بر اساس حافظه سیستم
if [ "$TOTAL_MEM_MB" -le 2048 ]; then
    # سیستم با حافظه کم (≤ 2GB)
    RMEM_MAX=4194304           # ~4MB
    WMEM_MAX=4194304           # ~4MB
    TCP_MEM="196608 262144 393216"
    IP_CONNTRACK_MAX=$((TOTAL_MEM_MB * 32))
    NR_OPEN=524288
    FILE_MAX=524288
    INOTIFY_MAX=65536
    MIN_FREE_KB=32768
elif [ "$TOTAL_MEM_MB" -le 4096 ]; then
    # سیستم با حافظه متوسط (≤ 4GB)
    RMEM_MAX=8388608           # ~8MB
    WMEM_MAX=8388608           # ~8MB
    TCP_MEM="393216 524288 786432"
    IP_CONNTRACK_MAX=$((TOTAL_MEM_MB * 48))
    NR_OPEN=1048576
    FILE_MAX=1048576
    INOTIFY_MAX=131072
    MIN_FREE_KB=49152
elif [ "$TOTAL_MEM_MB" -le 8192 ]; then
    # سیستم با حافظه بالا (≤ 8GB)
    RMEM_MAX=16777216          # ~16MB
    WMEM_MAX=16777216          # ~16MB
    TCP_MEM="786432 1048576 1572864"
    IP_CONNTRACK_MAX=$((TOTAL_MEM_MB * 64))
    NR_OPEN=2097152
    FILE_MAX=2097152
    INOTIFY_MAX=262144
    MIN_FREE_KB=65536
elif [ "$TOTAL_MEM_MB" -le 16384 ]; then
    # سیستم با حافظه خیلی بالا (≤ 16GB)
    RMEM_MAX=33554432          # ~32MB
    WMEM_MAX=33554432          # ~32MB
    TCP_MEM="1572864 2097152 3145728"
    IP_CONNTRACK_MAX=$((TOTAL_MEM_MB * 96))
    NR_OPEN=3097152
    FILE_MAX=3097152
    INOTIFY_MAX=524288
    MIN_FREE_KB=98304
else
    # سیستم با حافظه فوق‌العاده (> 16GB)
    RMEM_MAX=67108864          # ~64MB
    WMEM_MAX=67108864          # ~64MB
    TCP_MEM="3145728 4194304 6291456"
    IP_CONNTRACK_MAX=$((TOTAL_MEM_MB * 128))
    NR_OPEN=4194304
    FILE_MAX=4194304
    INOTIFY_MAX=1048576
    MIN_FREE_KB=131072
fi

# تنظیم بر اساس سرعت شبکه
if [ "$NETWORK_SPEED" -ge 10000 ]; then
    # شبکه 10Gbps یا بیشتر
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
    # شبکه 1Gbps
    NETDEV_MAX_BACKLOG=8192
    SOMAXCONN=8192
else
    # شبکه کمتر از 1Gbps
    NETDEV_MAX_BACKLOG=2048
    SOMAXCONN=2048
fi

# تنظیم الگوریتم صف و کنترل ازدحام
QDISC="fq_codel"
CONGESTION="bbr"
if ! grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    echo "[*] BBR در دسترس نیست، استفاده از cubic به جای آن"
    CONGESTION="cubic"
elif grep -q "bbr2" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    echo "[*] BBR2 در دسترس است، استفاده از bbr2 به جای bbr"
    CONGESTION="bbr2"
fi

# بررسی پشتیبانی از fq_codel
if ! tc qdisc show 2>/dev/null | grep -q "fq_codel"; then
    if modprobe sch_fq_codel 2>/dev/null; then
        echo "[*] ماژول fq_codel با موفقیت بارگذاری شد"
    else
        echo "[*] fq_codel پشتیبانی نمی‌شود، استفاده از fq به جای آن"
        QDISC="fq"
        if ! tc qdisc show 2>/dev/null | grep -q "fq"; then
            if ! modprobe sch_fq 2>/dev/null; then
                echo "[*] fq نیز پشتیبانی نمی‌شود، استفاده از پیش‌فرض"
                QDISC="pfifo_fast"
            fi
        fi
    fi
fi

# بهینه‌سازی برای نوع دیسک
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

# ایجاد فایل پیکربندی سیستم
cat <<EOT > "$SYSCTL_FILE"
# تنظیمات بهینه‌سازی شده کرنل لینوکس
# تاریخ ایجاد: $(date)

# --- تنظیمات شبکه ---
# صف و کنترل ازدحام
net.core.default_qdisc=$QDISC
net.ipv4.tcp_congestion_control=$CONGESTION

# بافرهای دریافت و ارسال
net.core.rmem_max=$RMEM_MAX
net.core.wmem_max=$WMEM_MAX
net.core.rmem_default=$((RMEM_MAX / 4))
net.core.wmem_default=$((WMEM_MAX / 4))
net.ipv4.tcp_rmem=4096 87380 $RMEM_MAX
net.ipv4.tcp_wmem=4096 87380 $WMEM_MAX
net.ipv4.tcp_mem=$TCP_MEM
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192

# بهینه‌سازی اتصالات TCP
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

# افزایش محدوده پورت‌های محلی
net.ipv4.ip_local_port_range=1024 65535

# سایر تنظیمات شبکه
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

# تنظیمات نظارت بر اتصال
net.netfilter.nf_conntrack_max=$IP_CONNTRACK_MAX
net.netfilter.nf_conntrack_tcp_timeout_established=86400
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30

# --- تنظیمات سیستم فایل و حافظه ---
fs.inotify.max_user_watches=$INOTIFY_MAX
fs.inotify.max_user_instances=1024
fs.file-max=$FILE_MAX
fs.nr_open=$NR_OPEN
fs.suid_dumpable=0
fs.protected_hardlinks=1
fs.protected_symlinks=1

# تنظیمات مربوط به حافظه مجازی
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

# --- تنظیمات کرنل و امنیتی ---
kernel.sched_autogroup_enabled=1
kernel.sched_migration_cost_ns=5000000
kernel.sched_latency_ns=10000000
kernel.sched_min_granularity_ns=4000000
kernel.panic=10
kernel.pid_max=65536
kernel.threads-max=$((FILE_MAX / 4))
kernel.sysrq=1
kernel.randomize_va_space=2

# تنظیمات منطبق با نوع سیستم
kernel.sched_child_runs_first=0
kernel.numa_balancing=0
EOT

# بررسی و اعمال تنظیمات جدید
if ! sysctl --system; then
    echo -e "\e[1;31m[خطا] اعمال تنظیمات با مشکل مواجه شد.\e[0m"
    # بازگرداندن فایل پشتیبان در صورت خطا
    if [ -f "$BACKUP_FILE" ]; then
        mv "$BACKUP_FILE" "$SYSCTL_FILE"
        sysctl --system
        echo "[*] تنظیمات به حالت قبل بازگردانده شد."
    fi
    exit 1
fi

# اعمال تنظیمات خاص برای رابط شبکه فعلی
if [ -n "$DEFAULT_IFACE" ]; then
    echo "[*] تنظیم پارامترهای رابط شبکه $DEFAULT_IFACE"
    
    # افزایش بافر حلقه برای کارت شبکه
    if [ -d "/sys/class/net/$DEFAULT_IFACE/queues" ]; then
        RX_QUEUES=$(ls -1 /sys/class/net/$DEFAULT_IFACE/queues/ | grep "rx-" | wc -l)
        if [ "$RX_QUEUES" -gt 0 ]; then
            echo "[*] تنظیم $RX_QUEUES صف دریافت"
            if [ "$NETWORK_SPEED" -ge 10000 ]; then
                RX_RING=4096
            elif [ "$NETWORK_SPEED" -ge 1000 ]; then
                RX_RING=2048
            else
                RX_RING=1024
            fi
            
            # تلاش برای تنظیم اندازه حلقه
            if ethtool -g "$DEFAULT_IFACE" &>/dev/null; then
                MAX_RING=$(ethtool -g "$DEFAULT_IFACE" 2>/dev/null | grep "RX:" -A 1 | tail -1 | awk '{print $1}')
                if [ -n "$MAX_RING" ] && [ "$MAX_RING" -gt 0 ]; then
                    if [ "$RX_RING" -gt "$MAX_RING" ]; then
                        RX_RING=$MAX_RING
                    fi
                    ethtool -G "$DEFAULT_IFACE" rx "$RX_RING" &>/dev/null && \
                        echo "[*] اندازه حلقه دریافت $DEFAULT_IFACE به $RX_RING تنظیم شد" || \
                        echo "[*] خطا در تنظیم اندازه حلقه دریافت"
                fi
            fi
        fi
    fi
    
    # بررسی و تنظیم TSO و LRO
    if ethtool -k "$DEFAULT_IFACE" &>/dev/null; then
        echo "[*] بهینه‌سازی offload انتقال"
        # فعال کردن قابلیت‌های offload
        ethtool -K "$DEFAULT_IFACE" tso on gso on gro on sg on rx on tx on &>/dev/null || true
    fi
    
    # تنظیم قوانین صف برای رابط شبکه
    if tc qdisc show dev "$DEFAULT_IFACE" &>/dev/null; then
        echo "[*] تنظیم سیاست صف برای $DEFAULT_IFACE به $QDISC"
        tc qdisc replace dev "$DEFAULT_IFACE" root "$QDISC" &>/dev/null || \
            echo "[*] خطا در تنظیم سیاست صف"
    fi
    
    # تنظیم MTU حذف شد طبق درخواست
fi

echo -e "\e[1;32m[✓] تنظیمات سیستم با موفقیت بهینه‌سازی شد.\e[0m"
exit 0
EOF

chmod +x "$INSTALL_PATH"

# ایجاد سرویس systemd
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

# ایجاد تایمر systemd
cat <<EOF > "$TIMER_PATH"
[Unit]
Description=اجرای دوره‌ای autotune-sysctl
After=network.target

[Timer]
OnBootSec=2min
OnUnitActiveSec=24h
AccuracySec=1m
RandomizedDelaySec=30s
Unit=autotune-sysctl.service

[Install]
WantedBy=timers.target
EOF

# نصب درایورها و ماژول‌های مورد نیاز
echo -e "\e[1;34m[*] بررسی و نصب ماژول‌های مورد نیاز...\e[0m"
for MODULE in tcp_bbr sch_fq_codel sch_fq nf_conntrack; do
    if ! lsmod | grep -q "$MODULE"; then
        echo "[*] بارگذاری ماژول $MODULE"
        modprobe "$MODULE" 2>/dev/null || echo "[!] ماژول $MODULE در دسترس نیست"
    fi
done

# ثبت ماژول‌ها برای بارگذاری در هنگام بوت
if [ ! -f "/etc/modules-load.d/autotune.conf" ]; then
    echo -e "# ماژول‌های مورد نیاز برای autotune-sysctl\ntcp_bbr\nsch_fq_codel\nsch_fq\nnf_conntrack" > "/etc/modules-load.d/autotune.conf"
    echo "[*] ماژول‌های مورد نیاز به فایل پیکربندی بوت اضافه شدند"
fi

# بازخوانی پیکربندی سیستم
systemctl daemon-reload

# فعال‌سازی سرویس‌ها
echo -e "\e[1;34m[*] فعال‌سازی سرویس و تایمر...\e[0m"
systemctl enable autotune-sysctl.service
systemctl enable autotune-sysctl.timer
systemctl start autotune-sysctl.service
systemctl start autotune-sysctl.timer

echo -e "\e[1;32m[✓] نصب و پیکربندی autotune-sysctl با موفقیت انجام شد.\e[0m"
echo -e "\e[1;34m[*] تنظیمات در مسیر $SYSCTL_FILE ذخیره شدند.\e[0m"
echo -e "\e[1;34m[*] گزارش‌ها در /var/log/autotune-sysctl.log ذخیره می‌شوند.\e[0m"
echo -e "\e[1;34m[*] اسکریپت هر 24 ساعت یکبار اجرا خواهد شد.\e[0m"
echo -e "\e[1;34m[*] برای اجرای دستی: sudo $INSTALL_PATH\e[0m"

exit 0
