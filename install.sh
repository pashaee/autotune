#!/bin/bash

set -e

echo "[*] نصب اسکریپت autotune-sysctl..."

INSTALL_PATH="/usr/local/bin/autotune-sysctl.sh"
SERVICE_PATH="/etc/systemd/system/autotune-sysctl.service"
TIMER_PATH="/etc/systemd/system/autotune-sysctl.timer"

cat <<'EOF' > "$INSTALL_PATH"
#!/bin/bash

SYSCTL_FILE="/etc/sysctl.d/99-autotune.conf"

TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
CPU_CORES=$(nproc)
DEFAULT_IFACE=$(ip route | awk '/default/ {print $5}' | head -n 1)

if [ "$TOTAL_MEM_MB" -le 2048 ]; then
  RMEM_MAX=4194304
  WMEM_MAX=4194304
  TCP_MEM="196608 262144 393216"
elif [ "$TOTAL_MEM_MB" -le 4096 ]; then
  RMEM_MAX=8388608
  WMEM_MAX=8388608
  TCP_MEM="393216 524288 786432"
else
  RMEM_MAX=16777216
  WMEM_MAX=16777216
  TCP_MEM="786432 1048576 1572864"
fi

QDISC="fq_codel"
CONGESTION="bbr"
if ! grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control; then
  CONGESTION="cubic"
fi

cat <<EOT > "$SYSCTL_FILE"
net.core.default_qdisc=$QDISC
net.ipv4.tcp_congestion_control=$CONGESTION
net.core.rmem_max=$RMEM_MAX
net.core.wmem_max=$WMEM_MAX
net.ipv4.tcp_rmem=4096 87380 $RMEM_MAX
net.ipv4.tcp_wmem=4096 65536 $WMEM_MAX
net.ipv4.tcp_mem=$TCP_MEM
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_max_syn_backlog=2048
net.core.somaxconn=2048
net.core.netdev_max_backlog=2048
net.ipv4.tcp_max_tw_buckets=16384
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3
fs.inotify.max_user_watches=262144
fs.file-max=1048576
fs.nr_open=1048576
vm.swappiness=10
vm.vfs_cache_pressure=70
vm.min_free_kbytes=65536
kernel.sched_autogroup_enabled=1
kernel.sched_migration_cost_ns=5000000
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_adv_win_scale=-2
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.conf.all.rp_filter=1
EOT

sysctl --system
echo "[OK] sysctl تنظیم شد."
EOF

chmod +x "$INSTALL_PATH"

# سرویس systemd
cat <<EOF > "$SERVICE_PATH"
[Unit]
Description=Auto-tune sysctl parameters

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH
EOF

# تایمر systemd
cat <<EOF > "$TIMER_PATH"
[Unit]
Description=Run autotune-sysctl every 6 hours

[Timer]
OnBootSec=10min
OnUnitActiveSec=6h
Unit=autotune-sysctl.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable --now autotune-sysctl.timer

echo "[✓] نصب کامل شد و تایمر فعال شد."
