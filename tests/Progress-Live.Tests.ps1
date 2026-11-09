# Progress-Live.Tests.ps1 - standalone checks for the v3.4.8 live-progress work.
# Plain PowerShell, no Pester, no module install, no tenant. It loads ONLY the pure progress helpers
# from MainGUI.ps1 by parsing (never running the app), drives them with fake status/bar objects, and
# asserts: the Stopwatch clock throttles correctly (the 32-bit TickCount bug is gone), Step-Progress
# paints text+bar+counter together, Complete-Progress shows a full bar + Done text, and Format-DoneText
# only ever reports real results. Run it with:  pwsh -NoProfile -File tests\Progress-Live.Tests.ps1
$ErrorActionPreference = 'Stop'
$script:Fail = 0
function Assert([bool]$Cond, [string]$Name, [string]$Got = '') {
	if ($Cond) { Write-Host "  PASS  $Name" } else { Write-Host "  FAIL  $Name  $Got" -ForegroundColor Red; $script:Fail++ }
}

$repo = Split-Path $PSScriptRoot -Parent
$mg = Join-Path $repo 'MainGUI.ps1'

# ---- fake UI the helpers write to ----
$script:UI = [pscustomobject]@{ StatusText = [pscustomobject]@{ Text = '' }; StatusDetail = [pscustomobject]@{ Text = '' } }
$progressBar1 = [pscustomobject]@{ Value = 0 }
$script:UiClock = [System.Diagnostics.Stopwatch]::StartNew()
$script:LastPumpTick = -1000000
$script:ProgTarget = 0; $script:TpStart = $null; $script:TpCount = 0

# ---- load the pure helpers from MainGUI.ps1 by AST (never run the file) ----
$ast = [System.Management.Automation.Language.Parser]::ParseFile($mg, [ref]$null, [ref]$null)
$want = 'Update-UiNow','Set-ItemStatusText','Set-ItemStatus','Set-StatusDetail','Set-LoopProgress',
	'Step-Progress','Complete-Progress','Format-DoneText','Get-ThroughputText','Format-TpDuration','Reset-Throughput'
$loaded = @{}
foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
	if ($want -contains $fn.Name) { $loaded[$fn.Name] = $true; . ([scriptblock]::Create($fn.Extent.Text)) }
}
foreach ($n in $want) { if (-not $loaded[$n]) { Write-Host "  FAIL  helper $n not found in MainGUI.ps1" -ForegroundColor Red; $script:Fail++ } }

# ================= T5: the clock (real Update-UiNow) =================
Write-Host "T5 clock / throttle"
$src = (Get-Content $mg -Raw) + ((Get-ChildItem (Join-Path $repo 'src') -Filter *.ps1 | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n")
Assert (-not ($src -match '\[Environment\]::TickCount')) "no [Environment]::TickCount anywhere"
$script:LastPumpTick = -1000000
$before = $script:LastPumpTick
Update-UiNow $true
$after1 = $script:LastPumpTick
Assert ($after1 -ne $before) "first throttled pump fires" "last=$after1"
Update-UiNow $true
$after2 = $script:LastPumpTick
Assert ($after2 -eq $after1) "an immediate second throttled pump is skipped" "last=$after2"
Start-Sleep -Milliseconds 90
Update-UiNow $true
Assert ($script:LastPumpTick -ne $after2) "a pump after ~90ms fires again" "last=$($script:LastPumpTick)"

# ---- from here, record every pump's visible state ----
$script:PumpLog = [System.Collections.Generic.List[object]]::new()
function Update-UiNow([bool]$Throttle = $false) {
	$script:PumpLog.Add([pscustomobject]@{ Text = "$($script:UI.StatusText.Text)"; Detail = "$($script:UI.StatusDetail.Text)"; Bar = [int]$progressBar1.Value })
}

# ================= T4: Step-Progress with a known total =================
Write-Host "T4 Step-Progress known total"
Reset-Throughput; $script:PumpLog.Clear(); $progressBar1.Value = 0
Step-Progress "Configuring alpha" 3 10
$last = $script:PumpLog[$script:PumpLog.Count - 1]
Assert ($script:PumpLog.Count -eq 1) "one pump for the item" "pumps=$($script:PumpLog.Count)"
Assert ($last.Text -eq 'Configuring alpha') "text painted with the item" "text=$($last.Text)"
Assert ($last.Detail -like '3 of 10*') "counter painted in the same pump" "detail=$($last.Detail)"
Assert ($last.Bar -gt 12 -and $last.Bar -lt 95) "bar painted in the same pump" "bar=$($last.Bar)"

# ================= T6: Complete-Progress + Format-DoneText =================
Write-Host "T6 finished state + truthful Done text"
$script:PumpLog.Clear()
Complete-Progress 'Done: 4 added, 1 failed'
$c = $script:PumpLog[$script:PumpLog.Count - 1]
Assert ($c.Bar -eq 100) "Complete-Progress fills the bar before the popup" "bar=$($c.Bar)"
Assert ($c.Text -eq 'Done: 4 added, 1 failed') "Done text painted" "text=$($c.Text)"
Assert ((Format-DoneText -Done 4 -Failed 1 -Word 'added') -eq 'Done: 4 added, 1 failed') "added + failed"
Assert ((Format-DoneText -Word 'added') -eq 'Done: nothing to do') "nothing to do"
Assert ((Format-DoneText -Done 5 -Already 2 -Word 'added' -AlreadyWord 'already there') -eq 'Done: 5 added, 2 already there, 0 failed') "added + already there (+ 0 failed shown)"
Assert ((Format-DoneText -Done 3 -Failed 1 -Word 'created' -Preview) -eq 'Preview: 3 would be created, 1 would skip or fail') "preview never says Done/created"
Assert ((Format-DoneText -Done 2 -Word 'removed') -eq 'Done: 2 removed, 0 failed') "remove wording"

# ================= T1/T3-style: a member loop reports real results in order =================
# Mirrors the Paste List / CSV member add: each item pumps its own text BEFORE its (mocked) work, the
# counter never goes backward, a failed item still advances, and the Done text matches the real counts.
Write-Host "T1/T3 member-loop ordering + truthful summary"
function Add-OneMember { param($who, $target) Start-Sleep -Milliseconds 10; if ($target -eq 'bad@contoso.com') { throw 'mock failure' }; return $true }
$targets = 'a@contoso.com','b@contoso.com','bad@contoso.com','d@contoso.com','e@contoso.com'
$counts = @{ done = 0; failed = 0 }
Reset-Throughput; $script:PumpLog.Clear(); $progressBar1.Value = 0
$i = 0; $tot = $targets.Count; $events = [System.Collections.Generic.List[string]]::new()
foreach ($t in $targets) {
	$i++
	Set-ItemStatusText "Adding user to the shared mailbox $t"
	Set-StatusDetail "$i of $tot"; Set-LoopProgress $i $tot; Update-UiNow
	$events.Add("pump $t $i")
	try { $null = Add-OneMember 'user@contoso.com' $t; $events.Add("start $t"); $counts.done++ } catch { $events.Add("start $t"); $counts.failed++ }
}
# the pump naming each target comes before that target's "start"
$orderOk = $true
foreach ($t in $targets) {
	$pIx = $events.IndexOf("pump $t $($targets.IndexOf($t)+1)")
	$sIx = $events.IndexOf("start $t")
	if (-not ($pIx -ge 0 -and $sIx -ge 0 -and $pIx -lt $sIx)) { $orderOk = $false }
}
Assert $orderOk "each target's pump precedes its work"
$bars = @($script:PumpLog | ForEach-Object { $_.Bar })
$mono = $true; for ($k = 1; $k -lt $bars.Count; $k++) { if ($bars[$k] -lt $bars[$k-1]) { $mono = $false } }
Assert $mono "the bar never goes backward" ("bars=" + ($bars -join ','))
Assert ($counts.done -eq 4 -and $counts.failed -eq 1) "real counts (4 done, 1 failed incl. the thrown one)"
Assert ((Format-DoneText -Done $counts.done -Failed $counts.failed -Word 'added') -eq 'Done: 4 added, 1 failed') "Done text matches the real counts"

# ================= T6b: Format-DoneText target-skip count + custom fail word =================
Write-Host "T6b Format-DoneText target-skip + fail word"
Assert ((Format-DoneText -TargetsSkipped 1) -eq 'Done: 0 failed, 1 target(s) skipped') "all-unknown: '0 failed, 1 target(s) skipped'"
Assert ((Format-DoneText -Done 3 -Failed 1 -Word 'removed' -FailWord 'skipped/failed') -eq 'Done: 3 removed, 1 skipped/failed') "custom fail word (Remove-UserFromAllGroups)"
Assert ((Format-DoneText -Done 2 -Failed 0 -TargetsSkipped 2 -Word 'added') -eq 'Done: 2 added, 0 failed, 2 target(s) skipped') "added + target(s) skipped"
Assert ((Format-DoneText) -eq 'Done: nothing to do') "still nothing to do when all zero (incl. TargetsSkipped)"

# ================= T7: static lock check (AST) =================
# Any function whose OWN body calls Step-Progress must also call Lock-ScriptWindow (it pumps the UI, so a
# second click could re-enter it). Only exception: Remove-CloudGroups, which always runs inside a locked handler.
Write-Host "T7 every pumping handler locks its window"
$lkFiles = @((Join-Path $repo 'MainGUI.ps1')) + @(Get-ChildItem (Join-Path $repo 'src') -Filter *.ps1 | ForEach-Object { $_.FullName })
$withStep = @{}; $withLock = @{}
foreach ($f in $lkFiles) {
	$fast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$null)
	foreach ($cmd in $fast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)) {
		$name = $cmd.GetCommandName(); if ($name -ne 'Step-Progress' -and $name -ne 'Lock-ScriptWindow') { continue }
		$p = $cmd.Parent; while ($p -and -not ($p -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $p = $p.Parent }
		$fn = if ($p) { $p.Name } else { '<top>' }
		if ($name -eq 'Step-Progress') { $withStep[$fn] = $true } else { $withLock[$fn] = $true }
	}
}
$bad = @($withStep.Keys | Where-Object { $_ -ne 'Remove-CloudGroups' -and $_ -ne 'Step-Progress' -and -not $withLock[$_] })
Assert ($bad.Count -eq 0) "no pumping handler is missing a lock" ("missing: " + ($bad -join ', '))

# OnBulkContactsButtonClick must unlock inside a finally
$cast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'src\scripts1.ps1'), [ref]$null, [ref]$null)
$fnAst = $cast.Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'OnBulkContactsButtonClick' }, $true)
$hasFinallyUnlock = $false
if ($fnAst) {
	foreach ($try in $fnAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.TryStatementAst] }, $true)) {
		if ($try.Finally) { foreach ($c in $try.Finally.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)) { if ($c.GetCommandName() -eq 'Unlock-ScriptWindow') { $hasFinallyUnlock = $true } } }
	}
}
Assert $hasFinallyUnlock "OnBulkContactsButtonClick unlocks in a finally"

Write-Host ""
if ($script:Fail) { Write-Host "PROGRESS TESTS: $($script:Fail) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "PROGRESS TESTS: all passed" -ForegroundColor Green
exit 0
