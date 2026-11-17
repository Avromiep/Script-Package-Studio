# Short runner for the live-progress / AD-preflight / mailbox-member tests. No Pester, no install, no tenant.
# Runs all four test files and exits non-zero if ANY one fails.
#   pwsh -NoProfile -File tests\Run-ProgressTests.ps1
$exe = (Get-Process -Id $PID).Path
$rc = 0
foreach ($t in 'Progress-Live.Tests.ps1', 'PasteList-Live.Tests.ps1', 'AD-Preflight.Tests.ps1', 'MailboxMember-Progress.Tests.ps1') {
	Write-Host "=== $t ===" -ForegroundColor Cyan
	& $exe -NoProfile -File (Join-Path $PSScriptRoot $t)
	if ($LASTEXITCODE -ne 0) { $rc = 1 }
}
if ($rc) { Write-Host "SOME TESTS FAILED" -ForegroundColor Red } else { Write-Host "ALL TEST FILES PASSED" -ForegroundColor Green }
exit $rc
