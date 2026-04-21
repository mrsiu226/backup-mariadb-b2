# backup-mariadb-b2

Tự động backup toàn bộ databases MariaDB lên **Backblaze B2** qua rclone.  
Deploy 1 lần duy nhất trên mỗi server bằng `install.sh`.

## Tính năng

- ✅ Backup từng database riêng + 1 file all-in-one
- ✅ Nén gzip cấp 9
- ✅ Upload lên Backblaze B2 tự động
- ✅ Verify số file sau khi upload
- ✅ Tự dọn dẹp local (mặc định: 3 ngày)
- ✅ Tự dọn dẹp B2 (mặc định: 30 ngày)
- ✅ Thông báo Telegram (tùy chọn)
- ✅ Deploy tự động qua `install.sh`

---

## Cấu trúc project

```
backup-mariadb-b2/
├── backup.sh           # Script backup chính
├── install.sh          # Installer - chạy 1 lần trên server mới
├── config.example.env  # Template config (commit lên git)
├── config.env          # Config thật (.gitignored - KHÔNG commit)
├── .my.cnf             # MySQL credentials (.gitignored)
├── .gitignore
└── README.md
```

---

## Deploy lên server mới

### Bước 1: Clone repo

```bash
git clone https://github.com/YOUR_ORG/backup-mariadb-b2.git /opt/backup-mariadb-b2
cd /opt/backup-mariadb-b2
```

### Bước 2: Tạo config.env

```bash
cp config.example.env config.env
nano config.env   # Điền thông tin B2 + MariaDB
```

Các thông tin cần điền:

| Biến | Mô tả |
|------|--------|
| `B2_ACCOUNT_ID` | Account ID hoặc Application Key ID từ Backblaze |
| `B2_APPLICATION_KEY` | Application Key từ Backblaze |
| `B2_BUCKET` | Tên bucket trên B2 |
| `MYSQL_BACKUP_USER` | Tên user backup MariaDB (mặc định: `backup_user`) |
| `MYSQL_BACKUP_PASSWORD` | Password cho user backup |
| `LOCAL_RETENTION_DAYS` | Số ngày giữ backup local (mặc định: `3`) |
| `B2_RETENTION_DAYS` | Số ngày giữ backup trên B2 (mặc định: `30`) |
| `TELEGRAM_BOT_TOKEN` | (Tùy chọn) Token bot Telegram |
| `TELEGRAM_CHAT_ID` | (Tùy chọn) Chat ID nhận thông báo |

### Bước 3: Chạy installer

```bash
sudo bash install.sh
```

Installer sẽ tự động:
1. Cài đặt dependencies (rclone, mariadb-client, gzip, bc, curl)
2. Cấu hình rclone remote B2
3. Tạo MariaDB user `backup_user` với đúng quyền
4. Tạo file `/root/.my.cnf` (chmod 600)
5. Tạo thư mục backup và log
6. Thêm cronjob chạy hàng ngày

### Bước 4: Chạy thử

```bash
bash backup.sh
```

---

## Cấu trúc backup trên B2

```
your-bucket/
└── server-hostname/
    └── 2026-04-21/
        ├── database1_20260421_023012.sql.gz
        ├── database2_20260421_023015.sql.gz
        └── all_databases_20260421_023045.sql.gz
```

---

## Restore

```bash
# Giải nén
gunzip database1_20260421_023012.sql.gz

# Import
mysql -u root database1 < database1_20260421_023012.sql
```

---

## Cấu hình Cronjob

Mặc định chạy lúc **2:30 AM** mỗi ngày. Thay đổi trong `config.env`:

```bash
CRON_HOUR=2
CRON_MINUTE=30
```

Sau đó re-run installer để cập nhật:
```bash
bash install.sh
```

---

## Yêu cầu hệ thống

- Ubuntu 20.04+ / Debian 10+
- MariaDB 10.3+
- Quyền `root` để tạo user MariaDB
- Kết nối internet để upload lên B2
