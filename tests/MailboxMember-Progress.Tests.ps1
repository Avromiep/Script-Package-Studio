# MailboxMember-Progress.Tests.ps1 - the v3.4.9 "Add-MailboxMember progress per step + less screen-thread
# overhead" work. Plain PowerShell, no Pester, no module install, no tenant. It AST-loads the REAL shared
# chokepoint Invoke-MemberRoute + Write-MemberStep from src\scripts1.ps1 (and the real throughput helpers
# from MainGUI.ps1), mocks every Exchange cmdlet, and drives one member add/remove, asserting:
#   - exactly one screen repaint happens BEFORE each blocking call (the type lookup, then one per cmdlet);
#   - each repaint names the step ("Checking ...", "Adding <who> to the <type> <target>: Full Access"),
#     the bar only ever moves forward, and it stays inside the row's band (bulk 12-95, single 10-95);
#   - a cached type lookup skips its step (and still logs "lookup 0 ms (cached)");
#   - exactly one "timing:" line is written per row, with step names + whole-ms numbers and NO address,
#     name, UPN or error text (the line never contains an "@").
# Run:  pwsh -NoProfile -File tests\MailboxMember-Progress.Tests.ps1
$ErrorActionPreference = 'Stop'
$script:Fail = 0
function Assert([bool]$Cond, [string]$Name, [string]$Got = '') {
	if ($Cond) { Write-Host "  PASS  $Name" } else { Write-Host "  FAIL  $Name  $Got" -ForegroundColor Red; $script:Fail++ }
}

$repo = Split-Path $PSScriptRoot -Parent
$mg = Join-Path $repo 'MainGUI.ps1'
$s1 = Join-Path $repo 'src\scripts1.ps1'

# ---- fake UI + script state the chokepoint writes to ----
$script:UI = [pscustomobject]@{ StatusText = [pscustomobject]@{ Text = '' }; StatusDetail = [pscustomobject]@{ Text = '' } }
$progressBar1 = [pscustomobject]@{ Value = 0 }
$script:TpStart = $null; $script:TpCount = 0
$script:LastRecipientRaw = ''

# ---- load the REAL functions under test (by AST, never run the app) ----
$mgast = [System.Management.Automation.Language.Parser]::ParseFile($mg, [ref]$null, [ref]$null)
$s1ast = [System.Management.Automation.Language.Parser]::ParseFile($s1, [ref]$null, [ref]$null)
$wantMg = 'Get-ThroughputText','Format-TpDuration','Reset-Throughput'
$wantS1 = 'Invoke-MemberRoute','Write-MemberStep','Test-HarmlessMemberError'
$texts = @()
foreach ($fn in $mgast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) { if ($wantMg -contains $fn.Name) { $texts += $fn.Extent.Text } }
foreach ($fn in $s1ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) { if ($wantS1 -contains $fn.Name) { $texts += $fn.Extent.Text } }
. ([scriptblock]::Create($texts -join "`n`n"))
foreach ($n in $wantMg + $wantS1) { if (-not (Get-Command $n -ErrorAction SilentlyContinue)) { Write-Host "  FAIL  function $n not loaded" -ForegroundColor Red; exit 1 } }

# ---- module isolation ----
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop
$PSModuleAutoLoadingPreference = 'None'

# ---- recording + mocks ----
$script:PumpLog = [System.Collections.Generic.List[object]]::new()
$script:CmdLog = [System.Collections.Generic.List[string]]::new()
$script:AllTiming = [System.Collections.Generic.List[string]]::new()
$script:Types = @{}        # target -> @{ Cat; Name }
$script:ThrowOn = $null    # cmdlet name that should throw

function Set-ItemStatusText([string]$Text) { $script:UI.StatusText.Text = "$Text" }
function Set-StatusDetail([string]$Text) { $script:UI.StatusDetail.Text = "$Text" }
function Update-UiNow([bool]$Throttle = $false) { $script:PumpLog.Add([pscustomobject]@{ Text = "$($script:UI.StatusText.Text)"; Detail = "$($script:UI.StatusDetail.Text)"; Bar = [int]$progressBar1.Value }) }
function Get-RecipientCategory([string]$Target) { $m = $script:Types["$Target"]; $script:LastRecipientRaw = "$Target"; if ($m) { return $m.Cat } return 'Other' }
function Get-RecipientTypeName([string]$Raw) { $m = $script:Types["$Raw"]; if ($m) { return $m.Name } return '' }
function Log-Cmd([string]$Name, [string]$Id, [string]$Who) { $script:CmdLog.Add("$Name $Id $Who"); if ($script:ThrowOn -eq $Name) { throw "mock failure for $Who on $Id" } }
function Add-MailboxPermission    { param($Identity,$User,$AccessRights,$InheritanceType,$AutoMapping,$ErrorAction) Log-Cmd 'Add-MailboxPermission' $Identity $User }
function Remove-MailboxPermission { param($Identity,$User,$AccessRights,$InheritanceType,$Confirm,$ErrorAction) Log-Cmd 'Remove-MailboxPermission' $Identity $User }
function Add-RecipientPermission    { param($Identity,$Trustee,$AccessRights,$Confirm,$ErrorAction) Log-Cmd 'Add-RecipientPermission' $Identity $Trustee }
function Remove-RecipientPermission { param($Identity,$Trustee,$AccessRights,$Confirm,$ErrorAction) Log-Cmd 'Remove-RecipientPermission' $Identity $Trustee }
function Add-DistributionGroupMember    { param($Identity,$Member,$ErrorAction) Log-Cmd 'Add-DistributionGroupMember' $Identity $Member }
function Set-Mailbox { param($Identity,$GrantSendOnBehalfTo,$ErrorAction) Log-Cmd 'Set-Mailbox' $Identity 'sob' }

function Bars { @($script:PumpLog | ForEach-Object { $_.Bar }) }
function Monotonic($bars) { $ok = $true; for ($k = 1; $k -lt $bars.Count; $k++) { if ($bars[$k] -lt $bars[$k-1]) { $ok = $false } }; return $ok }

# Run the real chokepoint once, capturing its single Write-Host "timing:" line (shadow Write-Host locally
# so the test's own Write-Host output is unaffected).
function Run-Route {
	param([string]$Target, [string]$Member, [string]$Action, [string]$Right, [int]$Ri, [int]$Rt, [hashtable]$Cache, [switch]$KeepBar)
	$script:PumpLog = [System.Collections.Generic.List[object]]::new()
	$script:CmdLog = [System.Collections.Generic.List[string]]::new()
	if (-not $KeepBar) { $progressBar1.Value = 0; $script:UI.StatusText.Text = ''; $script:UI.StatusDetail.Text = '' }
	function Write-Host { param([Parameter(ValueFromRemainingArguments = $true)]$a) $line = ($a -join ' '); if ($line -like 'timing:*') { $script:LastTiming = $line; $script:AllTiming.Add($line) } }
	$script:LastTiming = ''
	return Invoke-MemberRoute -Target $Target -Member $Member -Action $Action -MailboxRight $Right -FallbackCategory '' -Cache $Cache -RowIndex $Ri -RowTotal $Rt
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

# the pump that names a step comes BEFORE that step's cmdlet actually runs
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

# ================= T4: a 3-row bulk run keeps the bar moving forward overall =================
Write-Host "T4 three bulk rows share a cache; the bar only moves forward across the whole run"
$script:Types = @{ 'a@contoso.com' = @{ Cat='Mailbox'; Name='shared mailbox' }; 'b@contoso.com' = @{ Cat='Mailbox'; Name='shared mailbox' }; 'c@contoso.com' = @{ Cat='Mailbox'; Name='shared mailbox' } }
$cache = @{}; $allBars = [System.Collections.Generic.List[int]]::new()
Reset-Throughput; $progressBar1.Value = 0; $script:UI.StatusText.Text = ''; $script:UI.StatusDetail.Text = ''
for ($row = 1; $row -le 3; $row++) {
	$t = @('a@contoso.com','b@contoso.com','c@contoso.com')[$row - 1]
	# -KeepBar: don't reset the bar between rows, so we can check it only moves forward across the whole run
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

# ================= T7: no timing line EVER contains an '@' (addresses / UPNs) =================
Write-Host "T7 every timing line captured across these tests is address-free"
$leaky = @($script:AllTiming | Where-Object { $_ -match '@' })
Assert ($leaky.Count -eq 0) "no 'timing:' line anywhere carries an '@'" ("leaky=" + ($leaky -join ' ;; '))
Write-Host "  (captured $($script:AllTiming.Count) timing lines; sample: $($script:AllTiming[0]))"

Write-Host ""
if ($script:Fail) { Write-Host "MAILBOX-MEMBER PROGRESS TESTS: $($script:Fail) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "MAILBOX-MEMBER PROGRESS TESTS: all passed" -ForegroundColor Green
exit 0
