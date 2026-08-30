# OBT-Scripts

Tập hợp scripts hỗ trợ vận hành hệ thống OBT.

---

## redirect-airexplorer-airlivedrive-to-obt

Trỏ `www.airexplorer.net` và `www.airlivedrive.com` vào IP của `ongbantat.store` qua `/etc/hosts` (macOS/Linux) hoặc `hosts` file (Windows).

### macOS / Linux

**Chạy trực tiếp (interactive menu):**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/OngBanTat/OBT-Scripts/main/redirect-airexplorer-to-obt.sh)
```

**Hoặc clone về chạy:**
```bash
chmod +x redirect-airexplorer-to-obt.sh
./redirect-airexplorer-to-obt.sh              # menu tương tác
./redirect-airexplorer-to-obt.sh setup        # thêm redirect
./redirect-airexplorer-to-obt.sh remove       # gỡ redirect
./redirect-airexplorer-to-obt.sh trust-cert   # tin tưởng toàn bộ certificate chain (leaf -> root) từ domain sau redirect
./redirect-airexplorer-to-obt.sh untrust-cert # gỡ toàn bộ certificate chain của OBT khỏi hệ thống CA
```

### Windows (PowerShell)

**Chạy remote command (mở PowerShell với quyền Administrator):**
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass; Invoke-Expression (Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/OngBanTat/OBT-Scripts/main/redirect-airexplorer-airlivedrive-to-obt.ps1").Content
```

**Hoặc với tham số cụ thể:**
```powershell
# Setup
$s = (Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/OngBanTat/OBT-Scripts/main/redirect-airexplorer-airlivedrive-to-obt.ps1").Content; Invoke-Expression "$s; Invoke-Setup"

# Remove
$s = (Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/OngBanTat/OBT-Scripts/main/redirect-airexplorer-airlivedrive-to-obt.ps1").Content; Invoke-Expression "$s; Invoke-Remove"

# Trust Cert
$s = (Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/OngBanTat/OBT-Scripts/main/redirect-airexplorer-airlivedrive-to-obt.ps1").Content; Invoke-Expression "$s; Invoke-TrustCert"

# Untrust Cert
$s = (Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/OngBanTat/OBT-Scripts/main/redirect-airexplorer-airlivedrive-to-obt.ps1").Content; Invoke-Expression "$s; Invoke-UntrustCert"
```

**Hoặc clone về chạy:**
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\redirect-airexplorer-airlivedrive-to-obt.ps1                        # menu tương tác
.\redirect-airexplorer-airlivedrive-to-obt.ps1 -Action setup
.\redirect-airexplorer-airlivedrive-to-obt.ps1 -Action remove
.\redirect-airexplorer-airlivedrive-to-obt.ps1 -Action trust-cert     # tin tưởng toàn bộ certificate chain (leaf -> root) từ domain sau redirect
.\redirect-airexplorer-airlivedrive-to-obt.ps1 -Action untrust-cert   # gỡ toàn bộ certificate chain của OBT khỏi Trusted Root CA
```

> **Lưu ý:** PowerShell phải chạy với quyền **Administrator** (click chuột phải → *Run as Administrator*).

### Domain được redirect

| Domain | Script |
|--------|--------|
| `www.airexplorer.net` | macOS + Windows |
| `www.airlivedrive.com` | Windows |