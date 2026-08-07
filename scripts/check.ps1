#requires -RunAsAdministrator
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$SvcName = 'dnsonlien-dns'
$Report = @()
function Rep($s) { $Report += $s; Write-Host $s }

Write-Host ''
Write-Host '================  dnsonlien status  ================'
Rep '  --- Network adapter used by default (route 0.0.0.0) ---'
$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -notmatch '0\.0\.0\.0' } | Sort-Object RouteMetric | Select-Object -First 1
if ($route) {
    $a = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
    Rep ("    Default gateway via: {0} (ifIndex {1})" -f $a.Name, $route.InterfaceIndex)
} else { Rep '    NO default route found' }

Rep '  --- Service ---'
$svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
if (-not $svc) { Rep '  NOT INSTALLED' } else {
    $col = if ($svc.Status -eq 'Running') { [ConsoleColor]::Green } else { [ConsoleColor]::Red }
    Rep ("  {0}: {1}" -f $SvcName, $svc.Status)
}

Rep '  --- Who owns port 53 ---'
$listeners = Get-NetTCPConnection -LocalPort 53 -State Listen -ErrorAction SilentlyContinue
if (-not $listeners) {
    Rep '    NOBODY is listening on 53 (proxy is DOWN)' 
} else {
    foreach ($l in $listeners) {
        $p = Get-Process -Id $l.OwningProcess -ErrorAction SilentlyContinue
        Rep ("    {0}:{1} -> PID {2} ({3})" -f $l.LocalAddress, $l.LocalPort, $l.OwningProcess, $p.ProcessName)
    }
    $ours = Get-Process dnsonlien-dns -ErrorAction SilentlyContinue
    if (-not $ours) { Rep '    WARN: port 53 is held by ANOTHER program - proxy cannot bind!' }
}

Rep '--- DNS servers (IPv4) ---'
Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses } | ForEach-Object {
    Rep ("    {0}: {1}" -f $_.InterfaceAlias, ($_.ServerAddresses -join ', '))
}

Rep '--- VPN / WARP / proxy adapters present? ---'
$vpns = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Virtual|TAP|TUN|WireGuard|WARP|Cloudflare|VPN|vEthernet' }
if ($vpns) { foreach ($v in $vpns) { Rep ("    ACTIVE: {0} ({1})" -f $v.Name, $v.InterfaceDescription) } }
else { Rep '    none' }
$warp = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'Cloudflare|WARP' }
if ($warp) { Rep '    Cloudflare WARP process is RUNNING' }

Rep '--- DNS via our proxy (127.0.0.1) ---'
$r = Resolve-DnsName tr.rbxcdn.com -Server 127.0.0.1 -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1
if ($r) { Rep ("    OK: tr.rbxcdn.com -> {0}" -f $r.IPAddress) }
else { Rep '    FAIL: proxy returned no A record' }

Rep '--- Direct DNS to 8.8.8.8 (UDP) to detect ISP spoofing ---'
$d = Resolve-DnsName tr.rbxcdn.com -Server 8.8.8.8 -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1
if ($d) { Rep ("    direct: tr.rbxcdn.com -> {0}" -f $d.IPAddress) }
else { Rep '    FAIL: direct 8.8.8.8 returned nothing (spoofed/blocked - exactly what we fix)' }

Rep '--- DoH bootstrap: can we reach upstream DNS over TCP/443? ---'
foreach ($hp in @('1.1.1.1','8.8.8.8')) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect($hp, 443, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(3000)) { $c.EndConnect($iar); Rep ("    OK: TCP {0}:443 reachable" -f $hp); $c.Close() }
        else { $c.Close(); Rep ("    FAIL: TCP {0}:443 blocked/stalled" -f $hp) }
    } catch { Rep ("    FAIL: TCP {0}:443 -> {1}" -f $hp, $_.Exception.Message) }
}

Rep '--- Roblox thumbnail test ---'
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
    if ($isPng) { Rep ("    OK: image loaded ({0} bytes, PNG)" -f $b.Length) }
    else { Rep ("    WARN: got {0} bytes, not a PNG" -f $b.Length) }
} catch { Rep ("    FAIL: {0}" -f $_.Exception.Message) }

Rep '===================================================='
if ($Report.Count -gt 0) {
    try { $Report | Set-Content -LiteralPath (Join-Path $PSScriptRoot '..\logs\check.txt') -Encoding UTF8 } catch {}
}
Write-Host ''
Write-Host 'Full report saved to logs\check.txt - attach it if asking for help.'