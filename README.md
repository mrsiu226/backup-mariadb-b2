# backup-mariadb-b2

Tự động backup toàn bộ databases MariaDB lên **Backblaze B2** qua rclone.

## 🚀 Cài đặt (1 lệnh duy nhất)

```bash
curl -fsSL https://raw.githubusercontent.com/mrsiu226/backup-mariadb-b2/main/install.sh | sudo bash
```

Installer sẽ hỏi từng bước:
- Thông tin **Backblaze B2** (Account ID, Application Key, Bucket)
- Thông tin **MariaDB** (user backup, password)
- Cấu hình **retention** (giữ bao nhiêu ngày)
- Lịch **cronjob**
- (Tùy chọn) **Telegram** notification
- Chạy thử ngay sau khi cài

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

---

## Cấu trúc sau khi cài

```
/opt/backup-mariadb-b2/
├── backup.sh        # Script backup chính
├── config.env       # Config + credentials (chmod 600)
└── .my.cnf          # MySQL credentials (chmod 600)

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

## Chạy thủ công

```bash
bash /opt/backup-mariadb-b2/backup.sh
```

## Restore database

```bash
# Tải từ B2 về
rclone copy b2:your-bucket/hostname/2026-04-21/database1.sql.gz ./

# Giải nén
gunzip database1.sql.gz

# Import
mysql -u root database1 < database1.sql
```

---

## Yêu cầu hệ thống

- Ubuntu 20.04+ / Debian 10+
- MariaDB 10.3+
- Quyền `root` (để tạo user MariaDB và cài packages)
- Kết nối internet

---

## Cập nhật backup.sh lên server đã cài

```bash
curl -fsSL https://raw.githubusercontent.com/mrsiu226/backup-mariadb-b2/main/backup.sh \
    -o /opt/backup-mariadb-b2/backup.sh && chmod +x /opt/backup-mariadb-b2/backup.sh
```
