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
# Thêm bare domain (không www.) cho hosts: cả hai đều trỏ về cùng IP nguồn.
$ALL_HOSTS_DOMAINS = @($TARGET_DOMAINS)
foreach ($d in $TARGET_DOMAINS) {
    $bare = $d -replace '^www\.', ''
    if ($bare -ne $d) { $ALL_HOSTS_DOMAINS += $bare }
}
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

# Tách các bản ghi bị gộp chung 1 dòng (lỗi cũ: IP đúng nhưng dòng airexplorer
# dính liền airlivedrive). Chỉ tách tại ranh giới thật: ngay sau "# obt-redirect"
# có IP của bản ghi tiếp theo, giữ nguyên mọi nội dung khác.
function Repair-HostsContent {
    param([string[]]$Lines)
    $out = @()
    foreach ($line in $Lines) {
        $parts = $line -split '(?<=obt-redirect)\s*(?=\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\s+\S+)'
        foreach ($p in $parts) {
            if ($p.Trim().Length -gt 0) { $out += $p.TrimEnd() }
        }
    }
    return $out
}

function Get-HostsContent {
    # @() ép thành mảng cụ thể trong bộ nhớ, tránh giữ stream đọc từ file
    $raw = @(Get-Content -Path $HOSTS_FILE -Encoding UTF8 -ErrorAction SilentlyContinue)
    $repaired = Repair-HostsContent -Lines $raw
    # Đánh dấu nếu bản ghi bị gộp dòng đã được tách ra -> cần ghi lại file.
    $script:HostsRepaired = (($raw.Count -ne $repaired.Count) -or
                             (($raw -join [Environment]::NewLine) -ne ($repaired -join [Environment]::NewLine)))
    return $repaired
}

# Ghi nội dung hosts dưới dạng 1 chuỗi đã vật hóa (không truyền stream của
# Get-Content vào Set-Content, tránh lỗi "Stream was not readable").
function Write-HostsFile {
    param([string[]]$Lines)
    $text = $Lines -join [Environment]::NewLine
    if ($text.Length -gt 0) { $text += [Environment]::NewLine }
    Set-Content -Path $HOSTS_FILE -Value $text -Encoding UTF8 -NoNewline
}

# ── Actions ────────────────────────────────────────────────────────────────────

function Invoke-Setup {
    $ip = Resolve-SourceIP
    Write-Host "IP của $SOURCE_DOMAIN : $ip"

    # [string[]] ép luôn là mảng -> += sẽ THÊM 1 DÒNG MỚI, không nối chuỗi
    # (khi file rỗng/1 dòng, += vào scalar sẽ gộp các entry cùng 1 dòng).
    $lines = [string[]]@(Get-HostsContent)
    $changed = $script:HostsRepaired   # ghi lại nếu vừa tách bản ghi bị gộp dòng

    foreach ($domain in $ALL_HOSTS_DOMAINS) {
        $existingLine = $lines | Where-Object { $_ -match "\s+$([regex]::Escape($domain))(\s|$)" }

        if ($existingLine) {
            $currentIP = ($existingLine -split '\s+')[0]
            if ($currentIP -ne $ip) {
                Write-Host "  [UPDATE] $domain - IP cũ=$currentIP -> mới=$ip"
            }
            # Luôn xóa entry cũ rồi ghi lại IP mới nhất
            $lines = @($lines | Where-Object { $_ -notmatch "\s+$([regex]::Escape($domain))(\s|$)" })
        } else {
            Write-Host "  [ADD] $domain -> $ip"
        }

        $lines += "$ip $domain $MARKER"
        $changed = $true
    }

    if ($changed) {
        Write-HostsFile -Lines $lines
        Write-Host ""
        Write-Host "Done. Flush DNS cache..."
        ipconfig /flushdns | Out-Null
        Write-Host "Hoàn tất. Kiểm tra: ping www.airexplorer.net"
    } else {
        Write-Host "Không có thay đổi."
    }
}

function Invoke-Remove {
    # [string[]] ép luôn là mảng -> += (nếu thêm lại) THÊM 1 DÒNG MỚI, không nối chuỗi.
    $lines = [string[]]@(Get-HostsContent)
    $found = $script:HostsRepaired   # ghi lại nếu vừa tách bản ghi bị gộp dòng

    foreach ($domain in $ALL_HOSTS_DOMAINS) {
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
        Write-HostsFile -Lines $lines
        Write-Host ""
        Write-Host "Done. Flush DNS cache..."
        ipconfig /flushdns | Out-Null
        Write-Host "Hoàn tất. Đã gỡ các redirect."
    }
}

# ── Trust cert ─────────────────────────────────────────────────────────────────

function Get-FilterDomains {
    # Gồm domain đích + bare domain (không www.) + domain nguồn để lọc/gỡ cert.
    $set = @{}
    foreach ($d in $TARGET_DOMAINS) {
        $set[$d] = $true
        # Bỏ "www." -> bare domain (cert CN có thể chỉ ghi airexplorer.net)
        $bare = $d -replace '^www\.', ''
        if ($bare -ne $d) { $set[$bare] = $true }
    }
    $set[$SOURCE_DOMAIN] = $true
    return @($set.Keys)
}

function Invoke-TrustCert {
    # Kết nối TLS tới mỗi domain, lấy toàn bộ certificate chain,
    # export từng cert ra file tạm rồi import vào Trusted Root CA
    # của CurrentUser (không cần quyền Administrator cho user store).
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
        [System.Security.Cryptography.X509Certificates.StoreName]::Root,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
    )
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    $ok = $false

    foreach ($domain in $TARGET_DOMAINS) {
        Write-Host "Kết nối TLS tới $domain để lấy certificate chain..."
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient($domain, 443)
            $sslStream = New-Object System.Net.Security.SslStream(
                $tcpClient.GetStream(), $false,
                { param($sender, $cert, $chain, $errors) $true }
            )
            $sslStream.AuthenticateAsClient($domain)
            $leaf = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($sslStream.RemoteCertificate)
            $sslStream.Close()
            $tcpClient.Close()

            # Build chain: leaf -> ... -> root (vẫn lấy được ngay cả khi chưa trust)
            $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
            $chain.Build($leaf) | Out-Null

            $count = 0
            foreach ($el in $chain.ChainElements) {
                $c = $el.Certificate
                # Export cert ra file tạm rồi import (tương tự openssl s_client -showcerts)
                $tmpFile = Join-Path $env:TEMP "obt-cert-$([guid]::NewGuid().ToString('N').Substring(0,8)).crt"
                $bytes = $c.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
                [System.IO.File]::WriteAllBytes($tmpFile, $bytes)
                $imported = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($tmpFile)
                $store.Add($imported)
                Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue

                $count++
                Write-Host "  [OK] Subject: $($c.Subject)"
                Write-Host "       Issuer : $($c.Issuer)"
                Write-Host "       SAN    : $(($c.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | ForEach-Object { $_.Format($true) }))"
            }

            Write-Host "  Đã thêm $count certificate(s) của $domain vào Trusted Root (CurrentUser)."
            $ok = $true
        } catch {
            Write-Warning "  [FAIL] Không thể lấy hoặc trust chain của $domain`: $_"
        }
    }

    $store.Close()

    Write-Host ""
    if ($ok) {
        Write-Host "Hoàn tất. Có thể cần restart browser để có hiệu lực."
    } else {
        Write-Host "Không cài được certificate nào."
    }
}

# ── Untrust cert ───────────────────────────────────────────────────────────────

function Get-DnsNames {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)
    $names = @()

    # Thử DnsNameList (có trên .NET 4.6.2+) trước
    try {
        foreach ($dns in $Cert.DnsNameList) {
            if (-not [string]::IsNullOrEmpty($dns.DnsName)) { $names += $dns.DnsName }
        }
    } catch { }

    # Fallback: parse thủ công extension SAN (OID 2.5.29.17) để tương thích
    # framework cũ và bắt wildcard (vd: *.airexplorer.net).
    if ($names.Count -eq 0) {
        foreach ($ext in $Cert.Extensions) {
            if ($ext.Oid.Value -ne "2.5.29.17") { continue }
            $raw = $ext.RawData
            $i = 0
            while ($i -lt $raw.Length) {
                # dNSName = context tag [0] = 0x82
                if ($raw[$i] -eq 0x82) {
                    $i++
                    $len = $raw[$i]; $i++
                    if ($len -ge 0x80) { $len = $raw[$i]; $i++ }
                    if ($i + $len -le $raw.Length) {
                        $s = [System.Text.Encoding]::ASCII.GetString($raw, $i, $len)
                        $names += $s
                    }
                    $i += $len
                } else {
                    $i++
                }
            }
        }
    }
    return $names
}

function Invoke-UntrustCert {
    # CN chứa domain đích hoặc nguồn -> gỡ cert khỏi CẢ LocalMachine VÀ CurrentUser.
    $filter = Get-FilterDomains
    $locations = @(
        [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
    )

    foreach ($loc in $locations) {
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
            [System.Security.Cryptography.X509Certificates.StoreName]::Root, $loc
        )
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $all = @($store.Certificates)
        $toRemove = @()

        foreach ($cert in $all) {
            $hit = $false
            foreach ($d in $filter) {
                # CN/Subject hoặc SAN chứa domain -> gỡ.
                if ($cert.Subject -match [regex]::Escape($d) -or
                    (Get-DnsNames $cert) -contains $d) {
                    $hit = $true
                    break
                }
            }
            if ($hit -and $toRemove -notcontains $cert) { $toRemove += $cert }
        }

        if ($toRemove.Count -gt 0) {
            foreach ($cert in $toRemove) {
                Write-Host "  [REMOVE] $($loc)\Root: Subject=$($cert.Subject) Issuer=$($cert.Issuer)"
                $store.Remove($cert)
            }
        } else {
            Write-Host "  Không có cert OBT nào trong $($loc)\Root."
        }

        $store.Close()
    }

    Write-Host "Lưu ý: Có thể cần restart browser để có hiệu lực."
}

# ── Interactive menu nếu không truyền -Action ──────────────────────────────────

function Show-Menu {
    while ($true) {
        Clear-Host
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
            "5" { Write-Host "Thoát."; return }
            default { Write-Host "Lựa chọn không hợp lệ." }
        }
        Write-Host ""
        Write-Host "Nhấn phím bất kỳ để tiếp tục..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
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
