# MailboxMember-Progress.Tests.ps1 - the v3.4.9 "Add-MailboxMember progress per step + less screen-thread
# overhead" work, plus the follow-up that brought the two remove-member bulk loops in line. Plain
# PowerShell, no Pester, no module install, no tenant. It AST-loads the REAL chokepoint (Invoke-MemberRoute
# + Write-MemberStep), the single/bulk routers, and the real bulk click handlers from scripts1/scripts3, and
# drives them with every Exchange cmdlet mocked. Asserts: one repaint before each blocking call; the bar
# only moves forward and stays in-band; "i of N" shows on every repaint; cached lookups are skipped; the
# "timing:" line never carries an address; both remove-member bulk loops now pass row info and unlock in a
# finally; and the ui.ps1 timer gates are in place.
# Run:  pwsh -NoProfile -File tests\MailboxMember-Progress.Tests.ps1
$ErrorActionPreference = 'Stop'
$script:Fail = 0
$script:Skipped = 0
function Assert([bool]$Cond, [string]$Name, [string]$Got = '') {
	if ($Cond) { Write-Host "  PASS  $Name" } else { Write-Host "  FAIL  $Name  $Got" -ForegroundColor Red; $script:Fail++ }
}

$repo = Split-Path $PSScriptRoot -Parent
$mg = Join-Path $repo 'MainGUI.ps1'
$s1 = Join-Path $repo 'src\scripts1.ps1'
$s3 = Join-Path $repo 'src\scripts3.ps1'
$uiPath = Join-Path $repo 'src\ui.ps1'

# ---- fake UI + script state the chokepoint writes to ----
$script:UI = [pscustomobject]@{ StatusText = [pscustomobject]@{ Text = '' }; StatusDetail = [pscustomobject]@{ Text = '' } }
$progressBar1 = [pscustomobject]@{ Value = 0 }
$script:TpStart = $null; $script:TpCount = 0
$script:LastRecipientRaw = ''
$script:LockedWindow = $null
$script:MemberTypeName = @{ Mailbox = 'mailbox'; DistributionList = 'distribution list'; UnifiedGroup = 'Teams / Microsoft 365 group' }
$script:MemberTypeArticle = @{ Mailbox = 'a mailbox'; DistributionList = 'a distribution list'; UnifiedGroup = 'a Teams / Microsoft 365 group' }

# ---- load the REAL functions under test (by AST, never run the app) ----
$mgast = [System.Management.Automation.Language.Parser]::ParseFile($mg, [ref]$null, [ref]$null)
$s1ast = [System.Management.Automation.Language.Parser]::ParseFile($s1, [ref]$null, [ref]$null)
$s3ast = [System.Management.Automation.Language.Parser]::ParseFile($s3, [ref]$null, [ref]$null)
$uiast = [System.Management.Automation.Language.Parser]::ParseFile($uiPath, [ref]$null, [ref]$null)
$wantMg = 'Get-ThroughputText','Format-TpDuration','Reset-Throughput','Test-ScriptRunBusy'
$wantS1 = 'Invoke-MemberRoute','Write-MemberStep','Test-HarmlessMemberError','Invoke-SingleMemberChange','Invoke-BulkMemberRow'
$texts = @()
foreach ($fn in $mgast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) { if ($wantMg -contains $fn.Name) { $texts += $fn.Extent.Text } }
foreach ($fn in $s1ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) { if ($wantS1 -contains $fn.Name) { $texts += $fn.Extent.Text } }
. ([scriptblock]::Create($texts -join "`n`n"))
foreach ($n in $wantMg + $wantS1) { if (-not (Get-Command $n -ErrorAction SilentlyContinue)) { Write-Host "  FAIL  function $n not loaded" -ForegroundColor Red; exit 1 } }

# ---- the real bulk click handlers (by parent function name + a marker) ----
function Get-HandlerSb($ast, [string]$Name, [string]$Marker) {
	foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $Name }, $true)) {
		if ($fn.Extent.Text -match [regex]::Escape($Marker)) { return $fn.Body.GetScriptBlock() }
	}
	return $null
}
$sbRemoveDl = Get-HandlerSb $s3ast 'OnRemoveBulkMembersButtonClick' 'Remove-DistributionListMember.csv'
$sbRemoveUg = Get-HandlerSb $s3ast 'OnRemoveBulkMembersButtonClick' 'Remove-UnifiedGroupMember.csv'
$sbAddMbx   = Get-HandlerSb $s1ast 'OnBulkMembersButtonClick'        'Add-MailboxMember.csv'
foreach ($p in @(@{N='Remove DL bulk';B=$sbRemoveDl},@{N='Remove UG bulk';B=$sbRemoveUg},@{N='Add-Mailbox bulk';B=$sbAddMbx})) {
	if (-not $p.B) { Write-Host "  FAIL  could not extract handler: $($p.N)" -ForegroundColor Red; exit 1 }
}

# ---- module isolation ----
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop
Import-Module Microsoft.PowerShell.Management -ErrorAction Stop
$PSModuleAutoLoadingPreference = 'None'

# ---- recording + mocks ----
$script:PumpLog = [System.Collections.Generic.List[object]]::new()
$script:CmdLog = [System.Collections.Generic.List[string]]::new()
$script:AllTiming = [System.Collections.Generic.List[string]]::new()
$script:LastTiming = ''
$script:Types = @{}
$script:ThrowOn = $null
$script:LastCounts = $null

function Set-ItemStatusText([string]$Text) { $script:UI.StatusText.Text = "$Text" }
function Set-StatusDetail([string]$Text) { $script:UI.StatusDetail.Text = "$Text" }
function Set-ItemStatus([string]$Text) { $script:UI.StatusText.Text = "$Text" }
function Update-UiNow([bool]$Throttle = $false) { $script:PumpLog.Add([pscustomobject]@{ Text = "$($script:UI.StatusText.Text)"; Detail = "$($script:UI.StatusDetail.Text)"; Bar = [int]$progressBar1.Value }) }
function Get-RecipientCategory([string]$Target) { $m = $script:Types["$Target"]; $script:LastRecipientRaw = "$Target"; if ($m) { return $m.Cat } return 'Other' }
function Get-RecipientTypeName([string]$Raw) { $m = $script:Types["$Raw"]; if ($m) { return $m.Name } return '' }
function Log-Cmd([string]$Name, [string]$Id, [string]$Who) { $script:CmdLog.Add("$Name $Id $Who"); if ($script:ThrowOn -eq $Name -or "$Id" -like 'bad*') { throw "mock failure for $Who on $Id" } }
function Add-MailboxPermission    { param($Identity,$User,$AccessRights,$InheritanceType,$AutoMapping,$ErrorAction) Log-Cmd 'Add-MailboxPermission' $Identity $User }
function Remove-MailboxPermission { param($Identity,$User,$AccessRights,$InheritanceType,$Confirm,$ErrorAction) Log-Cmd 'Remove-MailboxPermission' $Identity $User }
function Add-RecipientPermission    { param($Identity,$Trustee,$AccessRights,$Confirm,$ErrorAction) Log-Cmd 'Add-RecipientPermission' $Identity $Trustee }
function Remove-RecipientPermission { param($Identity,$Trustee,$AccessRights,$Confirm,$ErrorAction) Log-Cmd 'Remove-RecipientPermission' $Identity $Trustee }
function Add-DistributionGroupMember    { param($Identity,$Member,$ErrorAction) Log-Cmd 'Add-DistributionGroupMember' $Identity $Member }
function Remove-DistributionGroupMember { param($Identity,$Member,$Confirm,$ErrorAction) Log-Cmd 'Remove-DistributionGroupMember' $Identity $Member }
function Add-UnifiedGroupLinks    { param($Identity,$LinkType,$Links,$ErrorAction) Log-Cmd 'Add-UnifiedGroupLinks' $Identity $Links }
function Remove-UnifiedGroupLinks { param($Identity,$LinkType,$Links,$Confirm,$ErrorAction) Log-Cmd 'Remove-UnifiedGroupLinks' $Identity $Links }
function Set-Mailbox { param($Identity,$GrantSendOnBehalfTo,$ErrorAction) Log-Cmd 'Set-Mailbox' $Identity 'sob' }
# flow mocks for the real handlers / single router
function Lock-ScriptWindow($Window) { $script:LockedWindow = $Window; $script:Log2.Add('lock') }
function Unlock-ScriptWindow { $script:LockedWindow = $null; $script:Log2.Add('unlock') }
function Show-BulkSummary($Counts, $Action, $Corrected) { $script:LastCounts = $Counts; $script:Log2.Add("summary d=$($Counts.done) n=$($Counts.noop) f=$($Counts.failed) s=$($Counts.skipped)") }
function Show-Notice([string]$Title, [string]$Message, [string]$Kind = 'Info') { $script:Log2.Add("popup $Title") }
function OperationComplete { $script:Log2.Add('operationcomplete') }
$script:Log2 = [System.Collections.Generic.List[string]]::new()

function Bars { @($script:PumpLog | ForEach-Object { $_.Bar }) }
function Monotonic($bars) { $ok = $true; for ($k = 1; $k -lt $bars.Count; $k++) { if ($bars[$k] -lt $bars[$k-1]) { $ok = $false } }; return $ok }

# Run the real chokepoint once, capturing its single Write-Host "timing:" line.
function Run-Route {
	param([string]$Target, [string]$Member, [string]$Action, [string]$Right, [int]$Ri, [int]$Rt, [hashtable]$Cache, [switch]$KeepBar)
	$script:PumpLog = [System.Collections.Generic.List[object]]::new()
	$script:CmdLog = [System.Collections.Generic.List[string]]::new()
	if (-not $KeepBar) { $progressBar1.Value = 0; $script:UI.StatusText.Text = ''; $script:UI.StatusDetail.Text = '' }
	function Write-Host { param([Parameter(ValueFromRemainingArguments = $true)]$a) $line = ($a -join ' '); if ($line -like 'timing:*') { $script:LastTiming = $line; $script:AllTiming.Add($line) } }
	$script:LastTiming = ''
	return Invoke-MemberRoute -Target $Target -Member $Member -Action $Action -MailboxRight $Right -FallbackCategory '' -Cache $Cache -RowIndex $Ri -RowTotal $Rt
}
# Run a real click handler, capturing timing lines, mocked Write-Host, and any throw.
function Run-Handler($sb) {
	$script:PumpLog = [System.Collections.Generic.List[object]]::new()
	$script:CmdLog = [System.Collections.Generic.List[string]]::new()
	$script:Log2 = [System.Collections.Generic.List[string]]::new()
	$script:LastCounts = $null; $script:LockedWindow = $null
	$progressBar1.Value = 0; $script:UI.StatusText.Text = ''; $script:UI.StatusDetail.Text = ''
	$script:Threw = $false
	function Write-Host { param([Parameter(ValueFromRemainingArguments = $true)]$a) $line = ($a -join ' '); if ($line -like 'timing:*') { $script:AllTiming.Add($line) } }
	try { . $sb } catch { $script:Threw = $true }
}

$who = 'user@contoso.com'
$mbx = 'mbx@contoso.com'

# ================= T1: bulk row (Full + Send As), not cached =================
Write-Host "T1 bulk mailbox add: lookup + Full Access + Send As = 3 steps, 3 repaints"
$script:Types = @{ $mbx = @{ Cat = 'Mailbox'; Name = 'shared mailbox' } }
Reset-Throughput
$r = Run-Route -Target $mbx -Member $who -Action 'add' -Right 'FullAndSendAs' -Ri 1 -Rt 5 -Cache @{}
Assert ($script:PumpLog.Count -eq 3) "one repaint per step (lookup + 2 cmdlets)" "pumps=$($script:PumpLog.Count)"
Assert ($script:PumpLog[0].Text -eq "Checking $mbx (1 of 5)") "step 1 names the lookup" "text=$($script:PumpLog[0].Text)"
Assert ($script:PumpLog[1].Text -eq "Adding $who to the shared mailbox ${mbx}: Full Access (1 of 5)") "step 2 names Full Access" "text=$($script:PumpLog[1].Text)"
Assert ($script:PumpLog[2].Text -eq "Adding $who to the shared mailbox ${mbx}: Send As (1 of 5)") "step 3 names Send As" "text=$($script:PumpLog[2].Text)"
$b = Bars
Assert (Monotonic $b) "the bar never goes backward" ("bars=" + ($b -join ','))
Assert (($b | Where-Object { $_ -lt 12 -or $_ -gt 95 }).Count -eq 0) "every repaint stays in the bulk band 12-95" ("bars=" + ($b -join ','))
Assert ($script:PumpLog[0].Detail -like '1 of 5*') "detail shows the row counter" "detail=$($script:PumpLog[0].Detail)"
Assert (@($script:CmdLog | Where-Object { $_ -like 'Add-MailboxPermission *' }).Count -eq 1 -and @($script:CmdLog | Where-Object { $_ -like 'Add-RecipientPermission *' }).Count -eq 1) "both the Full Access and Send As cmdlets ran"
Assert ("$($r.Status)" -eq 'done') "result is done"
Assert ($script:LastTiming -like 'timing: row 1 of 5 | lookup *ms*Full Access *ms*Send As *ms*screen *ms') "one timing line with each step + screen" "line=$($script:LastTiming)"
Assert ($script:LastTiming -notmatch '@') "the timing line carries NO address / name / UPN" "line=$($script:LastTiming)"
Assert ($script:PumpLog.Count -eq 3 -and $script:CmdLog.Count -eq 2) "the 3 repaints and 2 cmdlet calls are interleaved (repaint, then call)"

# ================= T2: cached lookup skips its step =================
Write-Host "T2 cached type: lookup step is skipped (still logged as cached)"
$cache = @{ $mbx = @{ Cat = 'Mailbox'; Name = 'shared mailbox' } }
Reset-Throughput
$r = Run-Route -Target $mbx -Member $who -Action 'add' -Right 'FullAndSendAs' -Ri 2 -Rt 5 -Cache $cache
Assert ($script:PumpLog.Count -eq 2) "cached run repaints only the two cmdlet steps" "pumps=$($script:PumpLog.Count)"
Assert ($script:PumpLog[0].Text -eq "Adding $who to the shared mailbox ${mbx}: Full Access (2 of 5)") "first repaint is Full Access (no lookup step)" "text=$($script:PumpLog[0].Text)"
Assert ($script:LastTiming -like '*lookup 0 ms (cached)*') "timing shows the cached lookup" "line=$($script:LastTiming)"

# ================= T3: single add (RowTotal 0) uses the 10-95 band, no (N of M), empty detail =================
Write-Host "T3 single Full-Access add: band 10-95, no '(N of M)', blank detail"
$script:Types = @{ $mbx = @{ Cat = 'Mailbox'; Name = 'shared mailbox' } }
Reset-Throughput
$r = Run-Route -Target $mbx -Member $who -Action 'add' -Right 'FullAccess' -Ri 0 -Rt 0 -Cache @{}
Assert ($script:PumpLog.Count -eq 2) "lookup + one cmdlet = 2 repaints" "pumps=$($script:PumpLog.Count)"
Assert ($script:PumpLog[1].Text -eq "Adding $who to the shared mailbox ${mbx}: Full Access") "single add drops the '(N of M)' suffix" "text=$($script:PumpLog[1].Text)"
Assert ($script:PumpLog[1].Detail -eq '') "single add shows no row counter" "detail=$($script:PumpLog[1].Detail)"
$b = Bars
Assert (($b | Where-Object { $_ -lt 10 -or $_ -gt 95 }).Count -eq 0) "single band is 10-95" ("bars=" + ($b -join ','))
Assert (@($script:CmdLog | Where-Object { $_ -like 'Add-MailboxPermission *' }).Count -eq 1 -and @($script:CmdLog | Where-Object { $_ -like 'Add-RecipientPermission *' }).Count -eq 0) "only Full Access ran (no Send As)"
Assert ($script:LastTiming -like 'timing: lookup *ms*Full Access *ms*screen *ms' -and $script:LastTiming -notlike '*row *') "single timing line has no 'row N of M'" "line=$($script:LastTiming)"

# ================= T4: a 3-row bulk run keeps the bar moving forward =================
Write-Host "T4 three bulk rows share a cache; the bar only moves forward across the whole run"
$script:Types = @{ 'a@contoso.com' = @{ Cat='Mailbox'; Name='shared mailbox' }; 'b@contoso.com' = @{ Cat='Mailbox'; Name='shared mailbox' }; 'c@contoso.com' = @{ Cat='Mailbox'; Name='shared mailbox' } }
$cache = @{}; $allBars = [System.Collections.Generic.List[int]]::new()
Reset-Throughput; $progressBar1.Value = 0; $script:UI.StatusText.Text = ''; $script:UI.StatusDetail.Text = ''
for ($row = 1; $row -le 3; $row++) {
	$t = @('a@contoso.com','b@contoso.com','c@contoso.com')[$row - 1]
	$null = Run-Route -Target $t -Member $who -Action 'add' -Right 'FullAndSendAs' -Ri $row -Rt 3 -Cache $cache -KeepBar
	foreach ($p in $script:PumpLog) { $allBars.Add($p.Bar) }
}
Assert (Monotonic $allBars) "the bar never goes backward across all 3 rows" ("bars=" + ($allBars -join ','))
Assert (($allBars | Where-Object { $_ -lt 12 -or $_ -gt 95 }).Count -eq 0) "all repaints stay in 12-95" ("bars=" + ($allBars -join ','))

# ================= T5: remove wording =================
Write-Host "T5 remove: 'Removing <who> from the <type> <target>'"
$script:Types = @{ $mbx = @{ Cat = 'Mailbox'; Name = 'shared mailbox' } }
Reset-Throughput
$r = Run-Route -Target $mbx -Member $who -Action 'remove' -Right 'FullAndSendAs' -Ri 1 -Rt 2 -Cache @{}
Assert ($script:PumpLog[1].Text -eq "Removing $who from the shared mailbox ${mbx}: Full Access (1 of 2)") "remove reads 'Removing ... from'" "text=$($script:PumpLog[1].Text)"
Assert (@($script:CmdLog | Where-Object { $_ -like 'Remove-MailboxPermission *' }).Count -eq 1) "the remove cmdlet ran"

# ================= T6: a failed cmdlet still logs a clean, secret-free timing line =================
Write-Host "T6 a failing step still writes a timing line with no leaked address or error text"
$script:Types = @{ $mbx = @{ Cat = 'Mailbox'; Name = 'shared mailbox' } }
$script:ThrowOn = 'Add-RecipientPermission'
Reset-Throughput
$r = Run-Route -Target $mbx -Member $who -Action 'add' -Right 'FullAndSendAs' -Ri 3 -Rt 4 -Cache @{}
$script:ThrowOn = $null
Assert ("$($r.Status)" -eq 'failed') "a real cmdlet error marks the row failed" "status=$($r.Status)"
Assert ($script:LastTiming -like 'timing: row 3 of 4 *' -and $script:LastTiming -notmatch '@' -and $script:LastTiming -notmatch 'mock failure') "the timing line has no address and no error text" "line=$($script:LastTiming)"

# ================= (m) unknown-type row still writes a clean timing line =================
Write-Host "(m) unknown-type row: a 'timing:' line with no '@', member or target"
$script:Types = @{}
Reset-Throughput
$r = Run-Route -Target 'zz@contoso.com' -Member $who -Action 'add' -Right 'FullAndSendAs' -Ri 1 -Rt 1 -Cache @{}
Assert ("$($r.Status)" -eq 'unknown') "an untyped target returns 'unknown'" "status=$($r.Status)"
Assert ($script:LastTiming -like 'timing: *lookup *ms*screen *ms' -and $script:LastTiming -notmatch '@') "unknown row still logs a clean timing line" "line=$($script:LastTiming)"

# ================= (i) remove-member bulk loops =================
$start = Get-Location
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('sps-mm-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $tmp 'Templates') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tmp 'Logs') -Force | Out-Null
Set-Location $tmp
try {
	$scriptForm8 = [pscustomobject]@{}   # the window the remove-bulk loops lock
	$scriptForm1 = [pscustomobject]@{}   # the window the add-mailbox bulk loops lock
	$mailboxMemberMode = 0

	foreach ($case in @(
		@{ N='distribution list'; Sb=$sbRemoveDl; Csv='Remove-DistributionListMember.csv'; Cat='DistributionList'; Nm='distribution list' },
		@{ N='Microsoft 365 group'; Sb=$sbRemoveUg; Csv='Remove-UnifiedGroupMember.csv'; Cat='UnifiedGroup'; Nm='Teams / Microsoft 365 group' }
	)) {
		Write-Host "(i) remove-member bulk ($($case.N)): row info, forward bar, unlock on throw"
		"Member,Group`n$who,a@contoso.com`n$who,b@contoso.com`n$who,bad@contoso.com" | Out-File (Join-Path $tmp "Templates\$($case.Csv)") -Encoding UTF8
		$script:Types = @{ 'a@contoso.com'=@{Cat=$case.Cat;Name=$case.Nm}; 'b@contoso.com'=@{Cat=$case.Cat;Name=$case.Nm}; 'bad@contoso.com'=@{Cat=$case.Cat;Name=$case.Nm} }
		Run-Handler $case.Sb
		$b = Bars
		Assert (Monotonic $b) "the bar never goes down" ("bars=" + ($b -join ','))
		$detailsOk = $true; $prevRow = 0
		foreach ($p in $script:PumpLog) {
			if ($p.Detail -notmatch '^([123]) of 3') { $detailsOk = $false }
			else { $rn = [int]$Matches[1]; if ($rn -lt $prevRow) { $detailsOk = $false }; $prevRow = $rn }
		}
		Assert $detailsOk "every repaint's detail starts 'i of 3' and the row number never drops"
		Assert ($script:LastCounts -and $script:LastCounts.done -eq 2 -and $script:LastCounts.failed -eq 1) "the summary counts are real (2 removed, 1 failed)" "d=$($script:LastCounts.done) f=$($script:LastCounts.failed)"
		Assert ($script:Log2 -contains 'unlock') "the window unlocked"

		# a row that throws uncaught still unlocks (shadow Invoke-BulkMemberRow to throw on the 2nd row)
		$realBulk = ${function:Invoke-BulkMemberRow}
		$script:BulkN = 0
		function Invoke-BulkMemberRow { $script:BulkN++; if ($script:BulkN -eq 2) { throw 'boom in a row' }; return 'done' }
		Run-Handler $case.Sb
		${function:Invoke-BulkMemberRow} = $realBulk
		Assert ($script:Threw -and ($script:Log2 -contains 'lock') -and ($script:Log2 -contains 'unlock')) "a throwing row still unlocks (finally)"
	}

	# ================= (l) Add-MailboxMember bulk: real counts + unlock on throw =================
	Write-Host "(l) Add-MailboxMember bulk: real counts and unlock on a throwing row"
	"Mailbox,Member`na@contoso.com,$who`nb@contoso.com,$who`nbad@contoso.com,$who" | Out-File (Join-Path $tmp 'Templates\Add-MailboxMember.csv') -Encoding UTF8
	$script:Types = @{ 'a@contoso.com'=@{Cat='Mailbox';Name='shared mailbox'}; 'b@contoso.com'=@{Cat='Mailbox';Name='shared mailbox'}; 'bad@contoso.com'=@{Cat='Mailbox';Name='shared mailbox'} }
	Run-Handler $sbAddMbx
	Assert ($script:LastCounts -and $script:LastCounts.done -eq 2 -and $script:LastCounts.failed -eq 1) "the summary counts are real (2 added, 1 failed)" "d=$($script:LastCounts.done) f=$($script:LastCounts.failed)"
	$realBulk = ${function:Invoke-BulkMemberRow}
	$script:BulkN = 0
	function Invoke-BulkMemberRow { $script:BulkN++; if ($script:BulkN -eq 2) { throw 'boom' }; return 'done' }
	Run-Handler $sbAddMbx
	${function:Invoke-BulkMemberRow} = $realBulk
	Assert ($script:Threw -and ($script:Log2 -contains 'unlock')) "Add-Mailbox bulk unlocks even when a row throws"
}
finally { Set-Location $start; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# ================= (n) single Add on a shared mailbox: first pump 10, <95 before last start, 100 after =================
Write-Host "(n) single Add Member: first pump at 10, below 95 before the last start, 100 only after"
$script:Types = @{ $mbx = @{ Cat = 'Mailbox'; Name = 'shared mailbox' } }
$script:PumpLog = [System.Collections.Generic.List[object]]::new(); $script:CmdLog = [System.Collections.Generic.List[string]]::new(); $script:Log2 = [System.Collections.Generic.List[string]]::new()
$progressBar1.Value = 0; $script:UI.StatusText.Text = ''; $script:UI.StatusDetail.Text = ''
Reset-Throughput
Invoke-SingleMemberChange -Target $mbx -Member $who -Expected 'Mailbox' -Action 'add' -MailboxRight 'FullAndSendAs' -Window $null
$routeBars = Bars
Assert ($routeBars.Count -ge 1 -and $routeBars[0] -eq 10) "the first repaint is at 10" "bars=$($routeBars -join ',')"
Assert (($routeBars | Where-Object { $_ -ge 95 }).Count -eq 0) "no repaint reaches 95 during the work" "bars=$($routeBars -join ',')"
# 100 is set by the single router AFTER the last cmdlet start (the bar ends at 0 after OperationComplete resets it,
# so assert no pump hit 100 and the router did reach the 'done' path)
Assert (@($script:CmdLog).Count -eq 2 -and ($script:Log2 -contains 'operationcomplete')) "both cmdlets ran and the add completed (100 only after the last start)"

# ================= (k) Invoke-SingleMemberChange -Window: throw still locks then unlocks =================
Write-Host "(k) Invoke-SingleMemberChange -Window: a route throw still logs lock then unlock"
$realRoute = ${function:Invoke-MemberRoute}
function Invoke-MemberRoute { throw 'route boom' }
$script:Log2 = [System.Collections.Generic.List[string]]::new(); $script:LockedWindow = $null; $threw = $false
try { Invoke-SingleMemberChange -Target $mbx -Member $who -Expected 'Mailbox' -Action 'add' -MailboxRight 'FullAndSendAs' -Window ([pscustomobject]@{}) } catch { $threw = $true }
${function:Invoke-MemberRoute} = $realRoute
$li = $script:Log2.IndexOf('lock'); $ui2 = $script:Log2.IndexOf('unlock')
Assert ($threw -and $li -ge 0 -and $ui2 -ge 0 -and $li -lt $ui2) "lock then unlock on a thrown route" "log=$($script:Log2 -join ',')"
Assert ((Test-ScriptRunBusy) -eq $false) "Test-ScriptRunBusy is `$false after unlock (LockedWindow cleared)"

# ================= (j) static: bulk callers pass row info, no Step-Progress, unlock in finally =================
Write-Host "(j) static: every Invoke-BulkMemberRow caller passes row info, drops Step-Progress, unlocks in a finally"
$srcFiles = @(Get-ChildItem (Join-Path $repo 'src') -Filter *.ps1 | ForEach-Object { $_.FullName })
$callerFns = @{}; $callsWithoutRow = 0; $bulkCalls = 0
foreach ($f in $srcFiles) {
	$ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$null)
	foreach ($c in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)) {
		if ($c.GetCommandName() -ne 'Invoke-BulkMemberRow') { continue }
		$bulkCalls++
		$txt = $c.Extent.Text
		if ($txt -notmatch '-RowIndex' -or $txt -notmatch '-RowTotal') { $callsWithoutRow++ }
		$p = $c.Parent; while ($p -and -not ($p -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $p = $p.Parent }
		if ($p) { $callerFns["$($f)::$($p.Name)"] = $p }
	}
}
Assert ($bulkCalls -ge 4 -and $callsWithoutRow -eq 0) "all $bulkCalls Invoke-BulkMemberRow calls pass -RowIndex and -RowTotal" "without=$callsWithoutRow"
$stepInCaller = 0; $lockNoFinally = 0
foreach ($fn in $callerFns.Values) {
	foreach ($c in $fn.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)) {
		if ($c.GetCommandName() -eq 'Step-Progress') { $stepInCaller++ }
	}
	foreach ($lk in $fn.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] -and $a.GetCommandName() -eq 'Lock-ScriptWindow' }, $true)) {
		$inFinally = $false
		$t = $lk.Parent
		while ($t) {
			if ($t -is [System.Management.Automation.Language.FunctionDefinitionAst]) { break }
			$t = $t.Parent
		}
		# does this caller have an Unlock inside a finally?
		$hasFinallyUnlock = $false
		foreach ($try in $fn.FindAll({ param($a) $a -is [System.Management.Automation.Language.TryStatementAst] }, $true)) {
			if ($try.Finally) { foreach ($u in $try.Finally.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] -and $a.GetCommandName() -eq 'Unlock-ScriptWindow' }, $true)) { $hasFinallyUnlock = $true } }
		}
		if (-not $hasFinallyUnlock) { $lockNoFinally++ }
	}
}
Assert ($stepInCaller -eq 0) "no Invoke-BulkMemberRow caller still calls Step-Progress" "found=$stepInCaller"
Assert ($lockNoFinally -eq 0) "every bulk caller unlocks in a finally" "missing=$lockNoFinally"

# ================= (o) static: the ui.ps1 timer gates =================
Write-Host "(o) static: ui.ps1 timer gates call Test-ScriptRunBusy before stopping"
$uiText = Get-Content $uiPath -Raw
Assert (([regex]::Matches($uiText, 'if \(Test-ScriptRunBusy\) \{ return \}')).Count -eq 1) "the warm-up tick calls Test-ScriptRunBusy with no argument (once)"
Assert (([regex]::Matches($uiText, 'if \(Test-ScriptRunBusy \$TextBox\) \{ return \}')).Count -eq 3) "the poll tick + both searches call Test-ScriptRunBusy `$TextBox (3x)"
Assert ([regex]::IsMatch($uiText, '\$t\.Add_Tick\(\{\s*if \(Test-ScriptRunBusy\) \{ return \}')) "the warm-up tick's FIRST line is the no-arg gate"
Assert ([regex]::IsMatch($uiText, '\$poll\.Add_Tick\(\{\s*if \(Test-ScriptRunBusy \$TextBox\) \{ return \}')) "the poll tick's FIRST line is the `$TextBox gate"
Assert (([regex]::Matches($uiText, '(?s)\$runQuery = \{\s*if \(Test-ScriptRunBusy \$TextBox\) \{ return \}\s*\$timer\.Stop\(\)')).Count -eq 2) "both `$runQuery blocks gate before `$timer.Stop() (2x)"
$script:LockedWindow = $null
Assert ((Test-ScriptRunBusy) -eq $false) "Test-ScriptRunBusy returns `$false when `$script:LockedWindow is empty"

Write-Host ""
$msg = "MAILBOX-MEMBER PROGRESS TESTS:"
if ($script:Skipped) { $msg += " $($script:Skipped) skipped;" }
if ($script:Fail) { Write-Host "$msg $($script:Fail) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "$msg all passed" -ForegroundColor Green
exit 0
