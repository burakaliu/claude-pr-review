<#
.SYNOPSIS
  Stop and remove the scheduled task.

.DESCRIPTION
  Leaves your config, state, and logs alone so reinstalling picks up where it
  left off. Pass -Purge to delete those too.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File local\windows\uninstall.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File local\windows\uninstall.ps1 -Purge
#>
[CmdletBinding()]
param(
  [string]$TaskName = 'claude-pr-review',
  [switch]$Purge
)

$ErrorActionPreference = 'Stop'

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
  # A pass already under way keeps running otherwise, and it holds the lock.
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
  Write-Host "Task '$TaskName' stopped and removed."
} else {
  Write-Host "No task named '$TaskName' is registered."
}

$ConfigDir = Join-Path $HOME '.config\claude-pr-review'
$StateDir = Join-Path $HOME '.local\state\claude-pr-review'
$CacheDir = Join-Path $HOME '.cache\claude-pr-review'

if ($Purge) {
  foreach ($d in @($ConfigDir, $StateDir, $CacheDir)) {
    if (Test-Path $d) { Remove-Item -Recurse -Force $d }
  }
  Write-Host "Purged config, state, and the repo cache."
} else {
  Write-Host "Config and state kept. Delete them with: $PSCommandPath -Purge"
}
