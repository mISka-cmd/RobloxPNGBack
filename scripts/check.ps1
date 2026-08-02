#requires -RunAsAdministrator
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$SvcName = 'dnsonlien-dns'

Write-Host ''
Write-Host '================  dnsonlien status  ================'

$svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Host '  Service: NOT INSTALLED (run install-fix.bat)' -ForegroundColor Red
} else {
    $col = if ($svc.Status -eq 'Running') { 'Green' } else { 'Red' }
    Write-Host ("  Service {0}: {1}" -f $SvcName, $svc.Status) -ForegroundColor $col
}

Write-Host '  --- Current DNS servers ---'
Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses } | ForEach-Object {
    Write-Host ("    {0}: {1}" -f $_.InterfaceAlias, ($_.ServerAddresses -join ', '))
}

Write-Host '  --- Resolving tr.rbxcdn.com (image CDN) ---'
$r = Resolve-DnsName tr.rbxcdn.com -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1
if ($r) { Write-Host ("    OK: {0} -> {1}" -f 'tr.rbxcdn.com', $r.IPAddress) -ForegroundColor Green }
else { Write-Host '    FAIL: tr.rbxcdn.com does not resolve' -ForegroundColor Red }

Write-Host '  --- Roblox thumbnail test ---'
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
    if ($isPng) { Write-Host ("    OK: image loaded ({0} bytes, PNG)" -f $b.Length) -ForegroundColor Green }
    else { Write-Host "    WARN: got $($b.Length) bytes, not a PNG" -ForegroundColor Yellow }
} catch {
    Write-Host ("    FAIL: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

Write-Host '===================================================='
Write-Host ''
