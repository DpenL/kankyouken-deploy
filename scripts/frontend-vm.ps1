<#
.SYNOPSIS
  Run the KanKyouKen frontend against the VM without clobbering your local dev setup.

.DESCRIPTION
  frontend/.env.local is your LOCAL DEV configuration and stays that way. This script
  swaps in the VM configuration for the length of one session and puts your dev file
  back when you stop the server - including on Ctrl-C, which is the case that matters,
  because that is how you will actually exit it.

  The VM configuration lives at %USERPROFILE%\.kankyouken\frontend-vm.env, outside
  every checkout. It is never committed, and this script never prints its contents.

.PARAMETER Fetch
  Pull ANON_KEY and SERVICE_ROLE_KEY from ~/deploy/.env on the VM into that file.
  Values are written straight to disk and never echoed.

.EXAMPLE
  scripts\frontend-vm.ps1 -Fetch
  scripts\frontend-vm.ps1
#>
param([switch]$Fetch)

$ErrorActionPreference = "Stop"
$Frontend = "$env:USERPROFILE\projects\KanKyouKen\frontend"
$ConfDir  = "$env:USERPROFILE\.kankyouken"
$VmEnv    = "$ConfDir\frontend-vm.env"
$VmHost   = "gr-stiftl.ndx.cit.tum.de"

if ($Fetch) {
  New-Item -ItemType Directory -Force -Path $ConfDir | Out-Null
  Write-Host "Reading ANON_KEY and SERVICE_ROLE_KEY from $VmHost ..." -ForegroundColor Cyan
  # Runs through WSL so it uses the ssh config and key already set up there.
  $vals = wsl -e ssh $VmHost "grep -E '^(ANON_KEY|SERVICE_ROLE_KEY)=' ~/deploy/.env"
  if (-not $vals) { throw "Could not read keys from the VM. Is it reachable? Does ~/deploy/.env exist?" }
  $lines = @("NEXT_PUBLIC_SUPABASE_URL=https://$VmHost")
  foreach ($l in $vals) {
    if ($l -match '^ANON_KEY=(.*)$')         { $lines += "NEXT_PUBLIC_SUPABASE_ANON_KEY=$($Matches[1])" }
    if ($l -match '^SERVICE_ROLE_KEY=(.*)$') { $lines += "SUPABASE_SERVICE_ROLE_KEY=$($Matches[1])" }
  }
  if ($lines.Count -ne 3) { throw "Expected both keys in ~/deploy/.env, found $($lines.Count - 1)." }
  [System.IO.File]::WriteAllText($VmEnv, ($lines -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "Wrote $VmEnv (contents not shown)." -ForegroundColor Green
  Write-Host "Now run:  scripts\frontend-vm.ps1"
  exit 0
}

if (-not (Test-Path $VmEnv)) { throw "$VmEnv does not exist. Run: scripts\frontend-vm.ps1 -Fetch" }
if (-not (Test-Path $Frontend)) { throw "Frontend not found at $Frontend" }

$Local  = "$Frontend\.env.local"
$Backup = "$Frontend\.env.local.devbackup"

try {
  if (Test-Path $Local) {
    Copy-Item $Local $Backup -Force
    Write-Host "Your dev .env.local is backed up to .env.local.devbackup" -ForegroundColor DarkGray
  }
  Copy-Item $VmEnv $Local -Force
  Write-Host "Frontend pointed at $VmHost. Ctrl-C to stop and restore." -ForegroundColor Cyan
  Push-Location $Frontend
  npm run dev
}
finally {
  Pop-Location -ErrorAction SilentlyContinue
  if (Test-Path $Backup) {
    Move-Item $Backup $Local -Force
    Write-Host "`nRestored your dev .env.local." -ForegroundColor Green
  } else {
    Remove-Item $Local -Force -ErrorAction SilentlyContinue
    Write-Host "`nRemoved the VM .env.local (you had no dev file to restore)." -ForegroundColor Green
  }
}