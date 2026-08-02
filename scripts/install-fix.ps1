#requires -RunAsAdministrator
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Scripts = $PSScriptRoot
$Root   = Split-Path -Parent $Scripts
$Src        = Join-Path $Root 'src\dnsonlien-dns.cs'
$Exe        = Join-Path $Root 'bin\dnsonlien-dns.exe'
$LogsDir    = Join-Path $Root 'logs'
$BackupFile = Join-Path $Root 'backup\dns-backup.json'
$LogFile    = Join-Path $Root 'logs\dnsonlien.log'
$ProgressFile = Join-Path $Root 'logs\install-progress.txt'
$SvcName    = 'dnsonlien-dns'

foreach ($d in @($LogsDir, (Join-Path $Root 'backup'), (Join-Path $Root 'bin'))) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}

function Log([string]$m) {
    $line = "{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Mark([string]$m) {
    try { Add-Content -LiteralPath $ProgressFile -Value ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $m) -Encoding UTF8 } catch { }
}

function Test-Port([string]$ip, [int]$port) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($ip, $port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne(700)) { $c.EndConnect($ar); return $true }
    } catch { }
    finally { try { $c.Close() } catch { } }
    return $false
}

function Invoke-Compile {
    $csc = @(
        'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe',
        'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $csc) { throw 'csc.exe not found' }
    Log "Compiling proxy... ($csc)"
    $compileOut = & $csc /nologo /optimize+ /target:exe /out:$Exe $Src 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Exe)) {
        foreach ($l in $compileOut) { Log "  csc: $l" }
        throw 'Compilation failed'
    }
    Log "Compiled OK: $Exe"
}

function Stop-ExistingService {
    Get-Process dnsonlien-dns -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 600
    $old = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
    if ($old) {
        Log "Stopping existing service '$SvcName'..."
        Stop-Service -Name $SvcName -Force -ErrorAction SilentlyContinue
        sc.exe delete $SvcName | Out-Null
        Start-Sleep -Milliseconds 600
    }
}

function Get-RealAdapters {
    Get-NetAdapter | Where-Object {
        $_.Status -eq 'Up' -and
        $_.InterfaceDescription -notmatch 'Virtual|Loopback|TAP|Hyper-V|vEthernet|Bluetooth|WFP|VPN'
    }
}

function Get-DnsRows {
    $rows = @()
    foreach ($a in Get-RealAdapters) {
        $v4 = Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $v6 = Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue
        if (@($v4.ServerAddresses).Count -gt 0 -or @($v6.ServerAddresses).Count -gt 0) {
            $rows += [pscustomobject]@{
                Alias = $a.Name
                IfIndex = $a.ifIndex
                V4 = @($v4.ServerAddresses)
                V6 = @($v6.ServerAddresses)
            }
        }
    }
    return @($rows)
}

function Backup-Dns {
    if (Test-Path $BackupFile) {
        Log "DNS backup already exists, keeping original: $BackupFile"
        return
    }
    $rows = Get-DnsRows
    if ($rows.Count -gt 0) {
        $rows | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $BackupFile -Encoding UTF8
        Log "DNS backup saved: $BackupFile ($($rows.Count) adapter(s))"
    } else {
        Log "WARN: no DNS servers found to back up"
    }
}

function Set-LocalDns($rows) {
    $useV6 = Test-Port '::1' 53
    $count = @($rows).Count
    foreach ($r in $rows) {
        Set-DnsClientServerAddress -InterfaceIndex $r.IfIndex -ServerAddresses '127.0.0.1' -ErrorAction SilentlyContinue | Out-Null
        if ($useV6) { Set-DnsClientServerAddress -InterfaceIndex $r.IfIndex -ServerAddresses '::1' -ErrorAction SilentlyContinue | Out-Null }
    }
    $suffix = if ($useV6) { ' / ::1' } else { '' }
    Log "System DNS switched to 127.0.0.1$suffix on $count adapter(s)"
}

function Install-Service {
    $old = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
    if ($old) {
        sc.exe delete $SvcName | Out-Null
        Start-Sleep -Milliseconds 600
    }
    Mark "before New-Service"
    $bin = '"' + $Exe + '" --run --logdir "' + $LogsDir + '"'
    New-Service -Name $SvcName -BinaryPathName $bin -DisplayName 'dnsonlien DNS over HTTPS proxy' -StartupType Automatic | Out-Null
    Mark "after New-Service"
    sc.exe failure $SvcName reset= 3600 actions= restart/5000/restart/5000/restart/5000 | Out-Null
    Mark "after sc failure"
    Start-Service -Name $SvcName
    Mark "after Start-Service"
    Log "Service '$SvcName' installed and started (auto-start on boot)"
}

function Wait-ProxyReady {
    for ($i = 0; $i -lt 40; $i++) {
        if (Test-Port '127.0.0.1' 53) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Test-Roblox {
    $ok = $true
    $r = Resolve-DnsName tr.rbxcdn.com -Server 127.0.0.1 -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1
    if (-not $r) { Log "WARN: tr.rbxcdn.com did not resolve via proxy"; $ok = $false }
    else { Log "OK: tr.rbxcdn.com -> $($r.IPAddress)" }

    try {
        $api = Invoke-RestMethod 'https://thumbnails.roblox.com/v1/users/avatar?userIds=1&size=100x100&format=Png' -TimeoutSec 20
        $url = $api.data[0].imageUrl
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Timeout = 20000
        $req.UserAgent = 'Mozilla/5.0'
        $resp = $req.GetResponse()
        $ms = New-Object System.IO.MemoryStream
        $rs = $resp.GetResponseStream()
        $buf = New-Object byte[] 4096
        while (($n = $rs.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
        $b = $ms.ToArray()
        $isPng = $b.Length -gt 8 -and $b[0] -eq 0x89 -and $b[1] -eq 0x50 -and $b[2] -eq 0x4E -and $b[3] -eq 0x47
        if ($isPng) { Log "OK: test image downloaded ($($b.Length) bytes, valid PNG): $url" }
        else { Log "WARN: image downloaded but not a PNG ($($b.Length) bytes)"; $ok = $false }
    } catch { Log "WARN: image test failed: $($_.Exception.Message)"; $ok = $false }
    return $ok
}

Write-Host ''
Write-Host '============================================'
Write-Host '  dnsonlien - Roblox image DNS fix (DoH)'
Write-Host '============================================'
Write-Host ''

try {
    Mark "start"
    Stop-ExistingService
    Invoke-Compile

    $svcRunning = (Get-Service -Name $SvcName -ErrorAction SilentlyContinue).Status -eq 'Running'
    if (-not $svcRunning) {
        Log 'Standalone pre-test (does not touch system DNS yet)...'
        $p = Start-Process -FilePath $Exe -ArgumentList @('--logdir', $LogsDir) -PassThru -WindowStyle Hidden
        Start-Sleep -Milliseconds 1500
        $r = Resolve-DnsName tr.rbxcdn.com -Server 127.0.0.1 -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        if ($r) { Log "OK: pre-test passed (tr.rbxcdn.com -> $($r.IPAddress))" }
        else { Log 'WARN: pre-test could not resolve tr.rbxcdn.com, continuing anyway' }
    }

    $backup = Get-DnsRows
    Backup-Dns
    Install-Service

    if (-not (Wait-ProxyReady)) { Log 'WARN: proxy port 53 not responding after start' }

    Set-LocalDns $backup
    Mark "after Set-LocalDns"
    Clear-DnsClientCache | Out-Null
    ipconfig /flushdns | Out-Null
    Log 'DNS cache flushed'

    Mark "before verification"
    Log 'Running final verification...'
    $ok = Test-Roblox
    Mark "verification done"

    Write-Host ''
    Write-Host '--------------------------------------------------------'
    if ($ok) {
        Write-Host '  FIX APPLIED SUCCESSFULLY. Restart Roblox and images'
        Write-Host '  should load now. The service works automatically.'
        Write-Host '  Use check.bat to verify anytime.'
    } else {
        Write-Host '  Installed, but final verification had warnings.'
        Write-Host '  Run check.bat to see details.'
    }
    Write-Host '--------------------------------------------------------'
    Write-Host ''
} catch {
    Mark ("FATAL: " + $_.Exception.Message)
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    exit 1
}
