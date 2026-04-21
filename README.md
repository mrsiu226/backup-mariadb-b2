# backup-mariadb-b2

Tự động backup toàn bộ databases MariaDB lên **Backblaze B2** qua rclone.  
Quản lý dễ dàng qua CLI `mybackup` sau khi cài.

---

## 🚀 Cài đặt (1 lệnh duy nhất)

```bash
curl -fsSL https://raw.githubusercontent.com/mrsiu226/backup-mariadb-b2/main/install.sh | sudo bash
```

Installer sẽ hỏi từng bước:

| Bước | Nội dung |
|------|----------|
| 1 | Backblaze B2 (Account ID, Application Key, Bucket) |
| 2 | MariaDB user backup + password |
| 3 | Retention days (local + B2) |
| 4 | Lịch cronjob |
| 5 | Telegram notification (tùy chọn) |
| 6 | Cài đặt + chạy thử |

> **Auto-detect:** Nếu server đã có rclone B2 hoặc cài trước đó, installer tự điền sẵn thông tin — chỉ cần nhấn Enter.

---

## 🛠️ Quản lý với `mybackup` CLI

Sau khi cài, dùng lệnh `mybackup` từ bất kỳ đâu:

```bash
mybackup                  # Interactive menu (chọn 1-7)
```

### Commands

```bash
mybackup --run            # Chạy backup ngay lập tức
mybackup --status         # Trạng thái + log gần nhất + B2 file count
mybackup --logs           # Xem 50 dòng log cuối
mybackup --cron           # Xem cronjob hiện tại
mybackup --update         # Cập nhật backup.sh từ GitHub
mybackup --config         # Chạy lại wizard cấu hình
mybackup --uninstall      # Gỡ bỏ hoàn toàn
mybackup --help           # Hiển thị help
```

### Ví dụ output

```
mybackup --status

━━━ Trạng thái backup ━━━
  ✔  Cronjob: 30 2 * * * /bin/bash /opt/backup-mariadb-b2/backup.sh
  →  Log gần nhất: /root/logs/backup_mariadb_20260421.log

    [2026-04-21 12:55:20]   Databases  : 45 backed up
    [2026-04-21 12:55:20]   Total size : 47.25 MB
    [2026-04-21 12:55:20] ✅ Backup completed

  ✔  rclone remote 'b2' đang hoạt động
  →  Tổng files trên B2: 92
```

### Uninstall

```bash
mybackup --uninstall
```

Sẽ xóa: script, config, CLI, cronjob  
Sẽ **giữ lại**: backup files, logs, MariaDB user, rclone config

---

## Tính năng

| Tính năng | Chi tiết |
|-----------|----------|
| 📦 Backup | Từng database riêng + 1 file all-in-one |
| 🗜️ Nén | gzip cấp 9 |
| ☁️ Upload | Backblaze B2 qua rclone |
| ✅ Verify | Kiểm tra số file sau upload |
| 🧹 Cleanup | Tự dọn local + B2 theo retention days |
| 🔔 Notify | Telegram notification (tùy chọn) |
| 🔒 Bảo mật | User backup riêng, credentials chmod 600 |
| 🖥️ CLI | `mybackup` command quản lý từ anywhere |

---

## Cấu trúc sau khi cài

```
/opt/backup-mariadb-b2/
├── backup.sh        # Script backup chính
├── mybackup         # CLI tool
├── config.env       # Config + credentials (chmod 600)
└── .my.cnf          # MySQL credentials (chmod 600)

/usr/local/bin/mybackup  → symlink tới trên

/root/backups/mariadb/
└── YYYY-MM-DD/
    ├── database1_YYYYMMDD_HHMMSS.sql.gz
    └── all_databases_YYYYMMDD_HHMMSS.sql.gz

/root/logs/
├── backup_mariadb_YYYYMMDD.log
└── backup_cron.log
```

---

## Cấu trúc backup trên B2

```
your-bucket/
└── server-hostname/
    └── 2026-04-21/
        ├── database1_20260421_023012.sql.gz
        └── all_databases_20260421_023045.sql.gz
```

---

## Restore database

```bash
# Tải từ B2 về
rclone copy b2:your-bucket/hostname/2026-04-21/database1.sql.gz ./

# Giải nén + import
gunzip database1.sql.gz
mysql -u root database1 < database1.sql
```

---

## Cập nhật script không cần reinstall

```bash
mybackup --update
# hoặc
curl -fsSL https://raw.githubusercontent.com/mrsiu226/backup-mariadb-b2/main/backup.sh \
    -o /opt/backup-mariadb-b2/backup.sh
```

---

## Yêu cầu hệ thống

- Ubuntu 20.04+ / Debian 10+
- MariaDB 10.3+
- Quyền `root` (để tạo user MariaDB và cài packages)
- Kết nối internet
