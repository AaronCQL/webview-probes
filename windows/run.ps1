# usage: run.ps1 <log> <timeoutSecs> <probe args...>
param([string]$Log, [int]$Timeout)
$probeArgs = $args
$exe = Join-Path $PSScriptRoot "..\build\win\app\Probe.exe"
$p = Start-Process -FilePath $exe -ArgumentList $probeArgs -PassThru -NoNewWindow -RedirectStandardOutput $Log -RedirectStandardError "$Log.err"
if (-not $p.WaitForExit($Timeout * 1000)) {
  Write-Host "TIMEOUT after $Timeout s, killing"
  Stop-Process -Id $p.Id -Force
}
Get-Content $Log
if (Test-Path "$Log.err") { Get-Content "$Log.err" | Select-Object -Last 30 }
Write-Host "exit: $($p.ExitCode)"
