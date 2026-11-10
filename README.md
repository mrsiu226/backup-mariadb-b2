# backup-mariadb-b2

Tự động backup toàn bộ databases MariaDB lên **Backblaze B2** qua rclone.  
Quản lý dễ dàng qua CLI `mybackup` sau khi cài.

---

## 🚀 Cài đặt (2 bước)

**Bước 1 — cài scripts (non-interactive):**

```bash
curl -fsSL https://raw.githubusercontent.com/mrsiu226/backup-mariadb-b2/main/install.sh | sudo bash
```

Installer chỉ tải file + cài dependencies (rclone, mariadb-client, ...). Không hỏi gì.

**Bước 2 — cấu hình interactive:**

```bash
sudo mybackup --setup
```

Wizard sẽ hỏi từng bước:

| Bước | Nội dung |
|------|----------|
| 1 | Backblaze B2 (Account ID, Application Key, Bucket) |
| 2 | MariaDB user backup + password |
| 3 | Retention days (local + B2) |
| 4 | Backup source code website (tùy chọn, xem [bên dưới](#-backup-source-code-website-hostvn)) |
| 5 | Lịch cronjob |
| 6 | Telegram notification (tùy chọn) |

> **Auto-detect:** Nếu server đã có rclone B2 hoặc config cũ, wizard tự điền sẵn — chỉ cần nhấn Enter.
>
> **Vì sao tách 2 bước?** `curl | sudo bash` không có terminal interactive trên nhiều VPS (Contabo, etc.) nên không đọc được input. Tách riêng bước setup tránh hoàn toàn vấn đề này.

---

## 🛠️ Quản lý với `mybackup` CLI

Sau khi cài, dùng lệnh `mybackup` từ bất kỳ đâu:

```bash
mybackup                  # Interactive menu (chọn 1-7)
```

### Commands

```bash
sudo mybackup --setup     # Wizard cấu hình (lần đầu hoặc thay đổi)
mybackup --run            # Chạy backup database ngay (+ source nếu bật)
mybackup --run-source     # Chạy backup source code ngay
mybackup --status         # Trạng thái + log gần nhất + B2 file count
mybackup --logs           # Xem 50 dòng log cuối
mybackup --cron           # Xem cronjob hiện tại
mybackup --update         # Cập nhật scripts từ GitHub
sudo mybackup --uninstall # Gỡ bỏ hoàn toàn
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
| 📁 Source code | Backup source website (HostVN), zip theo domain — [chi tiết](#-backup-source-code-website-hostvn) |
| ☁️ Upload | Backblaze B2 qua rclone |
| ✅ Verify | Kiểm tra số file sau upload |
| 🧹 Cleanup | Tự dọn local + B2 theo retention days (riêng cho DB và source) |
| 🔔 Notify | Telegram notification (tùy chọn) |
| 🔒 Bảo mật | User backup riêng, credentials chmod 600 |
| 🖥️ CLI | `mybackup` command quản lý từ anywhere |

---

## 📁 Backup source code website (HostVN)

Tự động phát hiện toàn bộ website chạy trên server thông qua config của **HostVN**, hỗ trợ cả 2 phiên bản:

| Phiên bản | Vị trí config | Source lấy từ |
|-----------|---------------|----------------|
| Cũ  | `/var/hostvn/users/.<domain>.conf` | `public_html=` |
| Mới | `/var/hostvn/data/websites/<domain>/.settings.conf` | `base_dir=` + `/public_html` |

Script tự nhận diện phiên bản đang dùng (kiểm tra cả 2 thư mục, ưu tiên bản mới nếu domain trùng), zip từng site rồi upload B2 — **không cần khai báo danh sách domain thủ công**.

### Bật tính năng

```bash
sudo mybackup --setup
# → Bước 4/6: chọn "y" cho "Bật backup source code website?"
```

Hoặc bật trực tiếp trong `config.env`:

```bash
ENABLE_SOURCE_BACKUP="yes"
```

Khi bật, `backup.sh` sẽ tự động chạy `backup_source.sh` nối tiếp sau backup database (dùng chung 1 cronjob). Có thể chạy riêng bằng `mybackup --run-source` (luôn chạy, bỏ qua chu kỳ).

### Backup theo chu kỳ (server ít dung lượng)

Database vẫn backup hàng ngày, riêng source có thể thưa hơn:

```bash
SOURCE_BACKUP_INTERVAL_DAYS=3   # 1=hàng ngày (mặc định), 3, 5, 7=hàng tuần
```

Cron vẫn chạy mỗi ngày, script tự bỏ qua nếu lần thành công gần nhất chưa đủ N ngày (mốc lưu ở `/root/backups/source/.last_success`). Nếu có site lỗi, mốc không được ghi → lần cron sau tự thử lại. Nên đặt `SOURCE_B2_RETENTION_DAYS` ≥ 2 × chu kỳ để B2 luôn giữ ít nhất 2 bản.

### Loại trừ file/thư mục khi zip

Mặc định loại trừ cache/log/thư mục sinh lại được của Laravel, Next.js, Symfony, WordPress và các plugin backup:

```
/vendor node_modules .git .svn .cache cache tmp logs *.log error_log*
storage/framework/sessions storage/framework/views storage/debugbar var/log .next/cache
wp-content/{updraft,backups,upgrade,wflogs,et-cache,ai1wm-backups,wp-snapshots,backups-dup-lite,wpvividbackups}
```

Quy tắc pattern: tên thư mục → loại ở mọi cấp; có `*` → khớp file; bắt đầu bằng `/` → chỉ ở gốc site (`/vendor` loại `vendor` của Laravel nhưng giữ `vendor` trong plugin WordPress). Video/zip/sql **không** bị loại mặc định — muốn bỏ thì tự thêm `*.mp4 *.zip *.sql` vào `SOURCE_EXCLUDE_PATTERNS`.

Chỉnh sửa qua biến `SOURCE_EXCLUDE_PATTERNS` trong `config.env` (cách nhau bởi khoảng trắng). Loại trừ hẳn 1 domain không muốn backup qua `SOURCE_EXCLUDE_DOMAINS`.

### Chọn site backup tự động

`mybackup --setup` (Bước 4) liệt kê các website phát hiện được để chọn theo số, hoặc `all`. Kết quả lưu ở `SOURCE_INCLUDE_DOMAINS` trong `config.env` (cách nhau bởi khoảng trắng, **trống = tất cả**). Site mới thêm sau đó sẽ không tự được backup cho đến khi thêm vào danh sách. `SOURCE_EXCLUDE_DOMAINS` vẫn được ưu tiên hơn. Xem nhanh danh sách site: `bash /opt/backup-mariadb-b2/backup_source.sh --list`.

Mỗi zip còn chứa thư mục `_nginx/` (`nginx.conf` = vhost từ `/etc/nginx/sites-available`, `nginx.enabled` = `enabled`/`disabled`) để dựng lại server mới. Site nào không có vhost thì bỏ qua.

### Cấu trúc backup source trên B2

```
your-bucket/
└── server-hostname/
    └── source/
        └── 2026-04-21/
            ├── domain1.com_20260421_023012.zip
            └── domain2.com_20260421_023015.zip
```

### Restore source code

```bash
rclone copy b2:your-bucket/hostname/source/2026-04-21/domain1.com.zip ./
unzip domain1.com.zip -d /home/user/domain1.com/
```

---

## Cấu trúc sau khi cài

```
/opt/backup-mariadb-b2/
├── backup.sh          # Script backup database
├── backup_source.sh   # Script backup source code (HostVN)
├── mybackup           # CLI tool
├── config.env         # Config + credentials (chmod 600)
└── .my.cnf             # MySQL credentials (chmod 600)

/usr/local/bin/mybackup  → symlink tới trên

/root/backups/mariadb/
└── YYYY-MM-DD/
    ├── database1_YYYYMMDD_HHMMSS.sql.gz
    └── all_databases_YYYYMMDD_HHMMSS.sql.gz

/root/backups/source/
└── YYYY-MM-DD/
    └── domain1.com_YYYYMMDD_HHMMSS.zip

/root/logs/
├── backup_mariadb_YYYYMMDD.log
├── backup_source_YYYYMMDD.log
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
- (Tùy chọn) Server dùng HostVN — để backup source code, cần quyền đọc `/var/hostvn/` và `/home/`
- Kết nối internet
