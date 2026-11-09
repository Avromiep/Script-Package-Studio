# Short runner for the live-progress tests. No Pester, no install, no tenant.
#   pwsh -NoProfile -File tests\Run-ProgressTests.ps1
$t = Join-Path $PSScriptRoot 'Progress-Live.Tests.ps1'
& (Get-Process -Id $PID).Path -NoProfile -File $t
exit $LASTEXITCODE
