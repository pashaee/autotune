 ---

# Xray-Linux-Autotune

## فارسی

### معرفی

اسکریپت `Xray-Linux-Autotune` یک ابزار پیشرفته و تخصصی برای بهینه‌سازی خودکار پارامترهای هسته لینوکس و کارت شبکه است. این اسکریپت به طور ویژه برای سرورهای VPN با هسته **Xray / V2Ray** (با تمرکز روی ترافیک سنگین **Instagram، HTTP/3، QUIC و UDP**) و مدیریت همزمان **۱۰۰ تا ۴۰۰+ کاربر** طراحی شده است تا با کمترین مصرف پردازنده (CPU)، بالاترین پایداری و سرعت را ارائه دهد.

### ویژگی‌ها

* **تخصیص هوشمند بر اساس منابع**: تنظیم خودکار بافرهای TCP/UDP و صف‌های شبکه بر اساس میزان رم و تعداد هسته‌های پردازنده سرور
* **بهینه‌سازی تخصصی ترافیک اینستاگرام و QUIC**: افزایش بافرهای UDP، غیرسازی Slow Start پس از وقفه، و تنظیمات انعطاف‌پذیر برای مقابله با پکت‌لاس و پینگ بالا
* **مدیریت پیشرفته پردازنده (RPS / RFS)**: توزیع خودکار بار پردازش بسته‌های شبکه روی تمام هسته‌های CPU (جلوگیری از درگیری تک‌هسته)
* **فعال‌سازی BBR و صف FQ**: استفاده از الگوریتم BBR همراه با صف `fq` برای کاهش تأخیر و کاهش چشمگیر بار پردازنده
* **مدیریت هوشمند فایروال**: عدم فعال‌سازی اجباری ماژول `nf_conntrack` برای ذخیره ۱۵ الی ۲۵ درصد مصرف CPU (و تنظیم خودکار آن تنها در صورت فعال بودن پیش‌فرض توسط سیستم یا داکر)
* **بدون قطعی‌های دوره‌ای**: برخلاف اسکریپت‌های قدیمی، این ابزار به صورت **Boot-Once** اجرا می‌شود و کارت شبکه را حین کار کاربران ریست نمی‌کند.
* **افزایش سقف فایل‌های باز**: تنظیم خودکار `ulimit` و محدودیت‌های سیستمی روی `524288` برای پشتیبانی بی‌проблеم از هزاران کانکشن موازی

### نصب و راه‌اندازی

```bash
bash <(curl -Ls https://raw.githubusercontent.com/pashaee/autotune/main/install.sh)

```

### نحوه عملکرد

* پس از نصب، اسکریپت به صورت یک سرویس سیستمی (`xray-autotune.service`) ثبت می‌شود و در هر بار روشن‌شدن مجدد سرور (Boot)، تنظیمات را اعمال می‌کند.

### گزارش‌ها و فایل‌های پیکربندی

* **فایل تنظیمات کرنل**: `/etc/sysctl.d/99-xray-autotune.conf`
* **گزارش‌های اجرایی**: `/var/log/xray-autotune.log`
* **محدودیت فایل‌های باز**: `/etc/security/limits.d/99-xray-nofile.conf`

### نحوه حذف (Uninstallation)

```bash
# غیرفعال کردن و حذف سرویس سیستمی
sudo systemctl disable --now xray-autotune.service
sudo rm /etc/systemd/system/xray-autotune.service

# حذف فایل‌های اسکریپت و پیکربندی
sudo rm /usr/local/bin/xray-autotune.sh
sudo rm /etc/sysctl.d/99-xray-autotune.conf
sudo rm /etc/security/limits.d/99-xray-nofile.conf
sudo rm /var/log/xray-autotune.log

# بازنشانی تنظیمات سیستم
sudo sysctl --system

```

### توصیه‌های استفاده

* این اسکریپت بهینه‌سازی ایده‌آلی برای سرورهای خارج از ایران میزبان پنل‌های مدیریت Xray (مانند 3x-ui) با تعداد کاربران بالا است.
* تنظیمات اعمال‌شده کاملاً ایمن بوده و در فایل‌های ذکر شده قابل بازبینی و شخصی‌سازی هستند.

### مجوز

MIT License

---

## English

### Introduction

The `Xray-Linux-Autotune` script is an advanced, specialized tool designed to automatically optimize Linux kernel and network interface parameters. It is specifically tailored for high-concurrency **Xray / V2Ray VPN servers** (handling **100 to 400+ simultaneous users** with heavy **Instagram, HTTP/3, QUIC, and UDP** traffic profiles), ensuring maximum network throughput while keeping CPU overhead to an absolute minimum.

### Features

* **Smart Hardware-Based Tuning**: Automatically scales TCP/UDP buffers and network queues based on available RAM and CPU core counts.
* **Instagram & QUIC Traffic Optimization**: Tuned UDP minimum buffers, disabled slow-start after idle, and high-latency mobile ISP resilience.
* **Multi-Core CPU Distribution (RPS / RFS)**: Automatically calculates core bitmasks to distribute network packet processing evenly across all CPU cores.
* **BBR & FQ Integration**: Enforces the BBR congestion control algorithm coupled with `fq` packet pacing to minimize CPU usage and packet drops.
* **Zero-Overhead Firewall Policy**: Avoids forcing `nf_conntrack` on clean servers (saving 15-25% CPU overhead), while intelligently tuning it if Docker or firewalls are already present.
* **Boot-Once Architecture**: Runs strictly at system startup as a oneshot service—eliminating periodic 8-hour disruptions or live interface resets.
* **High-Concurrency File Limits**: Automatically raises system-wide file descriptors (`nofile`) to `524288` to seamlessly support tens of thousands of simultaneous TCP/UDP sockets.

### Installation

```bash
bash <(curl -Ls https://raw.githubusercontent.com/pashaee/autotune/main/install.sh)

```

### Usage & Behavior

* Upon installation, the script registers as a systemd service (`xray-autotune.service`) and automatically applies all optimizations securely during system boot.

### Logs and Configuration Paths

* **Kernel Tunables**: `/etc/sysctl.d/99-xray-autotune.conf`
* **Execution Logs**: `/var/log/xray-autotune.log`
* **File Limits Config**: `/etc/security/limits.d/99-xray-nofile.conf`

### Uninstallation

```bash
# Disable and remove the systemd service
sudo systemctl disable --now xray-autotune.service
sudo rm /etc/systemd/system/xray-autotune.service

# Remove script and configuration files
sudo rm /usr/local/bin/xray-autotune.sh
sudo rm /etc/sysctl.d/99-xray-autotune.conf
sudo rm /etc/security/limits.d/99-xray-nofile.conf
sudo rm /var/log/xray-autotune.log

# Reload default kernel settings
sudo sysctl --system

```

### Recommendations

* Ideal for remote VPS nodes running Xray/V2Ray panels (such as 3x-ui) serving heavy video/social media traffic.
* All applied settings are fully transparent and open for manual review inside the configuration files.

### License

MIT License
