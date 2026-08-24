# Redirect www.airexplorer.net và www.airlivedrive.com -> IP của ongbantat.store
# Yêu cầu: chạy với quyền Administrator
# Usage: .\redirect-airexplorer-airlivedrive-to-obt.ps1 [-Action setup|remove]

param(
    [ValidateSet("setup", "remove", "")]
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

# ── Interactive menu nếu không truyền -Action ──────────────────────────────────

function Show-Menu {
    Write-Host "=== OBT Redirect Tool (Windows) ==="
    Write-Host "Domain nguồn : $SOURCE_DOMAIN"
    Write-Host "Domain đích  : $($TARGET_DOMAINS -join ', ')"
    Write-Host ""
    Write-Host "Chọn hành động:"
    Write-Host "  1) Setup  - Thêm redirect vào hosts"
    Write-Host "  2) Remove - Gỡ redirect khỏi hosts"
    Write-Host "  3) Thoát"
    Write-Host ""
    $choice = Read-Host "Lựa chọn (1/2/3)"
    switch ($choice) {
        "1" { Invoke-Setup }
        "2" { Invoke-Remove }
        "3" { exit 0 }
        default { Write-Error "Lựa chọn không hợp lệ."; exit 1 }
    }
}

# ── Entry point ────────────────────────────────────────────────────────────────

if (-not (Test-Admin)) {
    Write-Error "Script cần chạy với quyền Administrator. Click chuột phải -> 'Run as Administrator'."
    exit 1
}

switch ($Action) {
    "setup"  { Invoke-Setup }
    "remove" { Invoke-Remove }
    ""       { Show-Menu }
}
