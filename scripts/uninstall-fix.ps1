#requires -RunAsAdministrator
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Scripts = $PSScriptRoot
$Root = Split-Path -Parent $Scripts
$BackupFile = Join-Path $Root 'backup\dns-backup.json'
$SvcName = 'dnsonlien-dns'

Write-Host '============================================'
Write-Host '  dnsonlien - uninstall / rollback'
Write-Host '============================================'

# 1. Stop and delete the service
Get-Process dnsonlien-dns -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
$svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host "Stopping service $SvcName..."
    Stop-Service -Name $SvcName -Force -ErrorAction SilentlyContinue
    sc.exe delete $SvcName | Out-Null
    Write-Host 'Service removed.'
} else {
    Write-Host 'Service not installed.'
}

# 2. Restore DNS from backup, otherwise reset everything pointing to 127.0.0.1
$restored = 0
if (Test-Path $BackupFile) {
    $rows = Get-Content -LiteralPath $BackupFile -Raw | ConvertFrom-Json
    foreach ($r in $rows) {
        try {
            if (@($r.V4).Count -gt 0) {
                Set-DnsClientServerAddress -InterfaceIndex $r.IfIndex -ServerAddresses @($r.V4) -ErrorAction Stop
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $r.IfIndex -ResetServerAddresses -ErrorAction Stop
            }
            if (@($r.V6).Count -gt 0) {
                Set-DnsClientServerAddress -InterfaceIndex $r.IfIndex -ServerAddresses @($r.V6) -ErrorAction SilentlyContinue
            }
            $restored++
        } catch { Write-Host "  Could not restore adapter $($r.Alias): $($_.Exception.Message)" }
    }
    Write-Host "Restored DNS from backup for $restored adapter(s)."
} else {
    Write-Host 'No backup found. Resetting all adapters that use 127.0.0.1/::1...'
    Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
        $c4 = Get-DnsClientServerAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($c4.ServerAddresses -contains '127.0.0.1') {
            Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
            $restored++
        }
    }
    Write-Host "Reset $restored adapter(s) back to DHCP."
}

# 3. Safety net: reset any leftover DNS that still points at the local proxy
foreach ($a in Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }) {
    $v4 = Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $v6 = Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue
    $hasLocal4 = @($v4.ServerAddresses) -contains '127.0.0.1'
    $hasLocal6 = @($v6.ServerAddresses) -contains '::1'
    if ($hasLocal4 -or $hasLocal6) {
        Write-Host "Resetting leftover proxy DNS on $($a.Name)..."
        Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
    }
}

Clear-DnsClientCache | Out-Null
ipconfig /flushdns | Out-Null

Write-Host 'DNS cache flushed. Rollback complete.'
Write-Host ''
