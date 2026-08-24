# Redirect www.airexplorer.net và www.airlivedrive.com -> IP của ongbantat.store
# Yêu cầu: chạy với quyền Administrator
# Usage: .\redirect-airexplorer-airlivedrive-to-obt.ps1 [-Action setup|remove]

param(
    [ValidateSet("setup", "remove", "trust-cert", "untrust-cert", "")]
    [string]$Action = ""
)

$ErrorActionPreference = "Stop"

$SOURCE_DOMAIN  = "ongbantat.store"
$TARGET_DOMAINS = @("www.airexplorer.net", "www.airlivedrive.com")
$HOSTS_FILE     = "$env:SystemRoot\System32\drivers\etc\hosts"
$MARKER         = "# obt-redirect"

# ── Helpers ────────────────────────────────────────────────────────────────────

function Test-Admin {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$current
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-SourceIP {
    try {
        $result = Resolve-DnsName -Name $SOURCE_DOMAIN -Type A -ErrorAction Stop |
                  Where-Object { $_.QueryType -eq "A" } |
                  Select-Object -First 1 -ExpandProperty IPAddress
        if (-not $result) { throw "Không có bản ghi A" }
        return $result
    } catch {
        Write-Error "ERROR: Không thể resolve IP của $SOURCE_DOMAIN. $_"
        exit 1
    }
}

function Get-HostsContent {
    return Get-Content -Path $HOSTS_FILE -Encoding UTF8 -ErrorAction SilentlyContinue
}

# ── Actions ────────────────────────────────────────────────────────────────────

function Invoke-Setup {
    $ip = Resolve-SourceIP
    Write-Host "IP của $SOURCE_DOMAIN : $ip"

    $lines = Get-HostsContent
    $changed = $false

    foreach ($domain in $TARGET_DOMAINS) {
        $existingLine = $lines | Where-Object { $_ -match "\s+$([regex]::Escape($domain))(\s|$)" }

        if ($existingLine) {
            $currentIP = ($existingLine -split '\s+')[0]
            if ($currentIP -eq $ip) {
                Write-Host "  [SKIP] $domain - entry đúng IP ($ip), bỏ qua."
                continue
            }
            Write-Host "  [UPDATE] $domain - IP cũ=$currentIP -> mới=$ip"
            $lines = $lines | Where-Object { $_ -notmatch "\s+$([regex]::Escape($domain))(\s|$)" }
        } else {
            Write-Host "  [ADD] $domain"
        }

        $lines += "$ip $domain $MARKER"
        $changed = $true
    }

    if ($changed) {
        Set-Content -Path $HOSTS_FILE -Value $lines -Encoding UTF8
        Write-Host ""
        Write-Host "Done. Flush DNS cache..."
        ipconfig /flushdns | Out-Null
        Write-Host "Hoàn tất. Kiểm tra: ping www.airexplorer.net"
    } else {
        Write-Host "Không có thay đổi."
    }
}

function Invoke-Remove {
    $lines = Get-HostsContent
    $found = $false

    foreach ($domain in $TARGET_DOMAINS) {
        $before = $lines.Count
        $lines = $lines | Where-Object { $_ -notmatch "\s+$([regex]::Escape($domain))(\s|$)" }
        if ($lines.Count -lt $before) {
            Write-Host "  [REMOVED] $domain"
            $found = $true
        } else {
            Write-Host "  [NOT FOUND] $domain - không có entry"
        }
    }

    if ($found) {
        Set-Content -Path $HOSTS_FILE -Value $lines -Encoding UTF8
        Write-Host ""
        Write-Host "Done. Flush DNS cache..."
        ipconfig /flushdns | Out-Null
        Write-Host "Hoàn tất. Đã gỡ các redirect."
    }
}

# ── Trust cert ─────────────────────────────────────────────────────────────────

function Invoke-TrustCert {
    $certFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.cer'

    foreach ($domain in $TARGET_DOMAINS) {
        Write-Host "Tải certificate từ $domain..."
        try {
            # Kết nối TLS và lấy certificate
            $tcpClient = New-Object System.Net.Sockets.TcpClient($domain, 443)
            $sslStream = New-Object System.Net.Security.SslStream(
                $tcpClient.GetStream(), $false,
                { param($sender, $cert, $chain, $errors) $true }
            )
            $sslStream.AuthenticateAsClient($domain)
            $cert = $sslStream.RemoteCertificate
            $sslStream.Close()
            $tcpClient.Close()

            # Xuất certificate dạng DER
            $certBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
            [System.IO.File]::WriteAllBytes($certFile, $certBytes)

            Write-Host "  Subject : $($cert.Subject)"
            Write-Host "  Issuer  : $($cert.Issuer)"
            Write-Host "  Expires : $($cert.GetExpirationDateString())"

            # Thêm vào Root CA store
            $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
                [System.Security.Cryptography.X509Certificates.StoreName]::Root,
                [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
            )
            $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            $x509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certFile)
            $store.Add($x509)
            $store.Close()

            Write-Host "  [OK] Certificate của $domain đã được thêm vào Trusted Root CA."
        } catch {
            Write-Warning "  [FAIL] Không thể lấy hoặc trust certificate của $domain`: $_"
        }
    }

    if (Test-Path $certFile) { Remove-Item $certFile -Force }

    Write-Host ""
    Write-Host "Hoàn tất. Lưu ý: Có thể cần restart browser để có hiệu lực."
}

# ── Untrust cert ───────────────────────────────────────────────────────────────

function Invoke-UntrustCert {
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
        [System.Security.Cryptography.X509Certificates.StoreName]::Root,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
    )
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)

    foreach ($domain in $TARGET_DOMAINS) {
        # Tìm cert theo CN hoặc subject chứa domain
        $toRemove = $store.Certificates | Where-Object {
            $_.Subject -match [regex]::Escape($domain) -or
            $_.GetNameInfo(
                [System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false
            ) -eq $domain
        }

        if ($toRemove) {
            foreach ($cert in $toRemove) {
                Write-Host "  [REMOVE] $domain - Subject: $($cert.Subject)"
                $store.Remove($cert)
            }
        } else {
            Write-Host "  [NOT FOUND] Không tìm thấy certificate nào cho $domain trong Trusted Root CA."
        }
    }

    $store.Close()
    Write-Host ""
    Write-Host "Hoàn tất. Lưu ý: Có thể cần restart browser để có hiệu lực."
}

# ── Interactive menu nếu không truyền -Action ──────────────────────────────────

function Show-Menu {
    Write-Host "=== OBT Redirect Tool (Windows) ==="
    Write-Host "Domain nguồn : $SOURCE_DOMAIN"
    Write-Host "Domain đích  : $($TARGET_DOMAINS -join ', ')"
    Write-Host ""
    Write-Host "Chọn hành động:"
    Write-Host "  1) Setup        - Thêm redirect vào hosts"
    Write-Host "  2) Remove       - Gỡ redirect khỏi hosts"
    Write-Host "  3) Trust Cert   - Tin tưởng certificate từ các domain đích"
    Write-Host "  4) Untrust Cert - Gỡ certificate OBT khỏi Trusted Root CA"
    Write-Host "  5) Thoát"
    Write-Host ""
    $choice = Read-Host "Lựa chọn (1/2/3/4/5)"
    switch ($choice) {
        "1" { Invoke-Setup }
        "2" { Invoke-Remove }
        "3" { Invoke-TrustCert }
        "4" { Invoke-UntrustCert }
        "5" { exit 0 }
        default { Write-Error "Lựa chọn không hợp lệ."; exit 1 }
    }
}

# ── Entry point ────────────────────────────────────────────────────────────────

if (-not (Test-Admin)) {
    Write-Error "Script cần chạy với quyền Administrator. Click chuột phải -> 'Run as Administrator'."
    exit 1
}

switch ($Action) {
    "setup"        { Invoke-Setup }
    "remove"       { Invoke-Remove }
    "trust-cert"   { Invoke-TrustCert }
    "untrust-cert" { Invoke-UntrustCert }
    ""             { Show-Menu }
}
