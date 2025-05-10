# AutoTune-Sysctl

<div dir="rtl">

## فارسی

### معرفی
اسکریپت `autotune-sysctl` یک ابزار قدرتمند برای بهینه‌سازی خودکار پارامترهای هسته لینوکس است. این اسکریپت تنظیمات سیستم را برای دستیابی به حداکثر کارایی در زمینه‌های شبکه، مدیریت حافظه و عملکرد کلی سیستم بهینه می‌کند.

### ویژگی‌ها
- **بهینه‌سازی هوشمند**: پیکربندی خودکار بر اساس مشخصات سخت‌افزاری
- **تنظیمات شبکه**: بهبود عملکرد TCP/IP با تنظیمات پیشرفته بافر و پارامترهای کنترل ازدحام
- **بهینه‌سازی حافظه**: تنظیم پارامترهای حافظه مجازی و سیستم فایل
- **تشخیص خودکار**: شناسایی نوع دیسک (SSD/HDD) و سرعت شبکه
- **اجرای زمان‌بندی شده**: اعمال مجدد تنظیمات به صورت دوره‌ای
- **پشتیبان‌گیری**: ایجاد پشتیبان از تنظیمات قبلی برای امکان بازگشت
```bash
bash <(curl -Ls https://raw.githubusercontent.com/pashaee/autotune/main/install.sh)
```
### استفاده

پس از نصب، اسکریپت به صورت خودکار اجرا می‌شود و هر ۲۴ ساعت یکبار تنظیمات را بروزرسانی می‌کند.

### گزارش‌ها و پیکربندی
- تنظیمات در مسیر `/etc/sysctl.d/99-autotune.conf` ذخیره می‌شوند
- گزارش‌ها در فایل `/var/log/autotune-sysctl.log` ثبت می‌شوند
- فایل پشتیبان با نام `/etc/sysctl.d/99-autotune.bak` ایجاد می‌شود

### حذف

```bash
# غیرفعال کردن و حذف سرویس و تایمر
sudo systemctl disable --now autotune-sysctl.service
sudo systemctl disable --now autotune-sysctl.timer
sudo rm /etc/systemd/system/autotune-sysctl.service
sudo rm /etc/systemd/system/autotune-sysctl.timer

# حذف فایل‌های اسکریپت و پیکربندی
sudo rm /usr/local/bin/autotune-sysctl.sh
sudo rm /etc/sysctl.d/99-autotune.conf
sudo rm /var/log/autotune-sysctl.log

# اعمال تنظیمات پیش‌فرض سیستم
sudo sysctl --system
```

### توصیه‌های استفاده
- این اسکریپت برای محیط‌های مختلف از جمله سرورها، سیستم‌های دسکتاپ و VPS‌ها مناسب است
- برای سرورهای با ترافیک بالا و سیستم‌های با منابع زیاد بیشترین تأثیر را دارد
- تنظیمات اعمال شده در فایل `/etc/sysctl.d/99-autotune.conf` قابل بررسی و تغییر دستی هستند

### توجه
- همیشه توصیه می‌شود قبل از اجرا در محیط تولید، اسکریپت را در محیط تست بررسی کنید
- در صورت بروز مشکل، فایل پشتیبان امکان بازگشت به تنظیمات قبلی را فراهم می‌کند

### مجوز

</div>

## English

### Introduction
The `autotune-sysctl` script is a powerful tool for automatically optimizing Linux kernel parameters. It fine-tunes system settings to achieve maximum performance in networking, memory management, and overall system performance.

### Features
- **Smart Optimization**: Automatic configuration based on hardware specifications
- **Network Tuning**: Enhanced TCP/IP performance with advanced buffer and congestion control parameters
- **Memory Optimization**: Virtual memory and filesystem parameter tuning
- **Automatic Detection**: Identification of disk type (SSD/HDD) and network speed
- **Scheduled Execution**: Periodic reapplication of settings
- **Backup**: Creation of backups for previous settings to enable rollback

### Prerequisites
The script automatically checks for and installs the following prerequisites if needed:
- `ethtool`: For advanced network card settings
- `iproute2` (tc): For network traffic management

### Installation

```bash
bash <(curl -Ls https://raw.githubusercontent.com/pashaee/autotune/main/install.sh)

```

### Usage

After installation, the script runs automatically and updates settings every 24 hours.

### Logs and Configuration
- Settings are stored in `/etc/sysctl.d/99-autotune.conf`
- Logs are written to `/var/log/autotune-sysctl.log`
- Backup file is created as `/etc/sysctl.d/99-autotune.bak`

### Uninstallation

```bash
# Disable and remove service and timer
sudo systemctl disable --now autotune-sysctl.service
sudo systemctl disable --now autotune-sysctl.timer
sudo rm /etc/systemd/system/autotune-sysctl.service
sudo rm /etc/systemd/system/autotune-sysctl.timer

# Remove script and configuration files
sudo rm /usr/local/bin/autotune-sysctl.sh
sudo rm /etc/sysctl.d/99-autotune.conf
sudo rm /var/log/autotune-sysctl.log

# Apply default system settings
sudo sysctl --system
```

### Usage Recommendations
- This script is suitable for various environments including servers, desktop systems, and VPSs
- It has the most impact on high-traffic servers and systems with substantial resources
- The applied settings in `/etc/sysctl.d/99-autotune.conf` can be manually reviewed and modified

### Note
- It's always recommended to test the script in a non-production environment before deploying
- In case of issues, the backup file allows for a rollback to previous settings

