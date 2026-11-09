# PasteList-Live.Tests.ps1 - drives the REAL Paste List "Add All" handler (the Add_Click block from
# New-PasteMembersDialog), not a copy, with Exchange/Graph mocked. Plain PowerShell, no Pester, no
# module install, no tenant, no real dialog. Run:  pwsh -NoProfile -File tests\PasteList-Live.Tests.ps1
$ErrorActionPreference = 'Stop'
$script:Fail = 0
function Assert([bool]$Cond, [string]$Name, [string]$Got = '') {
	if ($Cond) { Write-Host "  PASS  $Name" } else { Write-Host "  FAIL  $Name  $Got" -ForegroundColor Red; $script:Fail++ }
}

$repo = Split-Path $PSScriptRoot -Parent
$mg = Join-Path $repo 'MainGUI.ps1'
$s1 = Join-Path $repo 'src\scripts1.ps1'

# ---- fake UI the helpers write to ----
$script:UI = [pscustomobject]@{ StatusText = [pscustomobject]@{ Text = '' }; StatusDetail = [pscustomobject]@{ Text = '' } }
$progressBar1 = [pscustomobject]@{ Value = 0 }
$script:UiClock = [System.Diagnostics.Stopwatch]::StartNew()
$script:LastPumpTick = -1000000
$script:ProgTarget = 0; $script:TpStart = $null; $script:TpCount = 0
$script:LastRecipientRaw = ''

# ---- load the real helpers (MainGUI) + real paste helpers (scripts1) by AST; never run the app ----
# Dot-source at THIS (script) scope so the functions are visible to the whole test, not trapped in a helper.
$mgast = [System.Management.Automation.Language.Parser]::ParseFile($mg, [ref]$null, [ref]$null)
$s1ast = [System.Management.Automation.Language.Parser]::ParseFile($s1, [ref]$null, [ref]$null)
$wantMg = 'Update-UiNow','Set-ItemStatusText','Set-ItemStatus','Set-StatusDetail','Set-LoopProgress','Step-Progress','Complete-Progress','Format-DoneText','Get-ThroughputText','Format-TpDuration','Reset-Throughput'
$wantS1 = 'Get-RecipientCategory','Get-LastRecipientRaw','Get-RecipientTypeName','Get-EmailsFromText','Get-AcceptedDomainList','Test-IsExternalAddress','Test-HarmlessMemberError','Show-PasteMembersDialog'
$texts = @()
foreach ($fn in $mgast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) { if ($wantMg -contains $fn.Name) { $texts += $fn.Extent.Text } }
foreach ($fn in $s1ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) { if ($wantS1 -contains $fn.Name) { $texts += $fn.Extent.Text } }
. ([scriptblock]::Create($texts -join "`n`n"))

# ---- extract the REAL PasteAddBtn Add_Click script block from New-PasteMembersDialog ----
$blockAst = $s1ast.Find({ param($a) $a -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and $a.Extent.Text -match 'Get-EmailsFromText \$previewBox\.Text' }, $true)
if (-not $blockAst) { Write-Host "  FAIL  could not find the real PasteAddBtn block" -ForegroundColor Red; exit 1 }
$script:PasteRealBlock = $blockAst.ScriptBlock.GetScriptBlock()

# ---- module isolation: any Exchange/Graph name that isn't mocked must FAIL, not autoload ----
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop
Import-Module Microsoft.PowerShell.Management -ErrorAction Stop
$PSModuleAutoLoadingPreference = 'None'

# ---- recording + mocks ----
$script:Log = [System.Collections.Generic.List[string]]::new()
$script:MockTypes = @{}
$script:ConfirmAnswer = $false
$script:LockDepth = 0; $script:NestedLock = $false
$script:people = ''; $script:targets = ''; $script:isRemove = $false; $script:kind = ''

function Get-Recipient { param([string]$Identity, $ErrorAction)
	$m = $script:MockTypes["$Identity"]
	if (-not $m -or $m -eq 'UNKNOWN') { throw "recipient not found: $Identity" }
	[pscustomobject]@{ RecipientTypeDetails = $m.Details; RecipientType = $m.Type }
}
function Get-AcceptedDomain { param($ErrorAction) [pscustomobject]@{ DomainName = 'contoso.com' } }
function script:LogCmd([string]$Name, [string]$Id, [string]$Member) {
	$script:Log.Add("start $Name $Id $Member")
	if ("$Id" -match '^bad') { throw "mock failure on $Id" }
}
function Add-MailboxPermission    { param($Identity,$User,$AccessRights,$InheritanceType,$AutoMapping,$ErrorAction) LogCmd 'Add-MailboxPermission' $Identity $User }
function Remove-MailboxPermission { param($Identity,$User,$AccessRights,$InheritanceType,$Confirm,$ErrorAction) LogCmd 'Remove-MailboxPermission' $Identity $User }
function Add-RecipientPermission    { param($Identity,$Trustee,$AccessRights,$Confirm,$ErrorAction) LogCmd 'Add-RecipientPermission' $Identity $Trustee }
function Remove-RecipientPermission { param($Identity,$Trustee,$AccessRights,$Confirm,$ErrorAction) LogCmd 'Remove-RecipientPermission' $Identity $Trustee }
function Add-DistributionGroupMember    { param($Identity,$Member,$ErrorAction) LogCmd 'Add-DistributionGroupMember' $Identity $Member }
function Remove-DistributionGroupMember { param($Identity,$Member,$Confirm,$ErrorAction) LogCmd 'Remove-DistributionGroupMember' $Identity $Member }
function Add-UnifiedGroupLinks    { param($Identity,$LinkType,$Links,$ErrorAction) LogCmd 'Add-UnifiedGroupLinks' $Identity $Links }
function Remove-UnifiedGroupLinks { param($Identity,$LinkType,$Links,$Confirm,$ErrorAction) LogCmd 'Remove-UnifiedGroupLinks' $Identity $Links }

# every mocked Exchange/Graph name must resolve to a FUNCTION (not a real cmdlet that loaded)
foreach ($n in 'Get-Recipient','Get-AcceptedDomain','Add-MailboxPermission','Remove-MailboxPermission','Add-RecipientPermission','Remove-RecipientPermission','Add-DistributionGroupMember','Remove-DistributionGroupMember','Add-UnifiedGroupLinks','Remove-UnifiedGroupLinks') {
	$c = Get-Command $n -ErrorAction SilentlyContinue
	if (-not $c -or $c.CommandType -ne 'Function') { Write-Host "  FAIL  mock $n is not a Function (got $($c.CommandType))" -ForegroundColor Red; exit 1 }
}

# UI/dialog mocks
function Update-UiNow([bool]$Throttle = $false) { $script:Log.Add("pump $($script:UI.StatusText.Text)|$($script:UI.StatusDetail.Text)|$([int]$progressBar1.Value)") }
function Show-Notice([string]$Title, [string]$Message, [string]$Kind = 'Info') { $script:Log.Add("popup $Title") }
function Confirm-YesNo([string]$Title, [string]$Message, [string]$Icon = '') { $script:Log.Add("confirm $Title"); return $script:ConfirmAnswer }
function Lock-ScriptWindow($Window) { if ($script:LockDepth -gt 0) { $script:NestedLock = $true }; $script:LockDepth++; $script:Log.Add('lock') }
function Unlock-ScriptWindow { if ($script:LockDepth -gt 0) { $script:LockDepth-- }; $script:Log.Add('unlock') }

# fake New-PasteMembersDialog whose ShowDialog() runs the REAL Add_Click block
function New-PasteMembersDialog {
	param([string]$TargetPrefill = '', [string]$Action = 'add', [string]$TargetKind = '')
	$result = @{ Counts = $null; Lines = $null; AnyFailed = $false; TargetCount = 0; Action = $Action }
	$win = [pscustomobject]@{ Tag = $result }
	$win | Add-Member -MemberType ScriptMethod -Name Close -Value { $script:Log.Add('close') }
	$win | Add-Member -MemberType ScriptMethod -Name ShowDialog -Value {
		$previewBox = [pscustomobject]@{ Text = $script:people }
		$targetsPreview = [pscustomobject]@{ Text = $script:targets }
		$isRemove = $script:isRemove
		$TargetKind = $script:kind
		$verbLow = if ($isRemove) { 'remove' } else { 'add' }
		$result = $this.Tag
		$win = $this
		. $script:PasteRealBlock
	}
	return $win
}

function Run-Paste([string]$People, [string]$Targets, [string]$Action, [string]$Kind, [hashtable]$Types, [bool]$Confirm = $false) {
	$script:people = $People; $script:targets = $Targets; $script:isRemove = ($Action -eq 'remove'); $script:kind = $Kind
	$script:MockTypes = $Types; $script:ConfirmAnswer = $Confirm
	$script:Log = [System.Collections.Generic.List[string]]::new()
	$progressBar1.Value = 0; $script:UI.StatusText.Text = ''; $script:UI.StatusDetail.Text = ''
	Reset-Throughput; $script:LockDepth = 0; $script:NestedLock = $false
	try { Show-PasteMembersDialog -Action $Action -TargetKind $Kind } catch { $script:Log.Add("threw $($_.Exception.Message)") }
	return $script:Log
}
function IdxFirst($log, [string]$needle) { for ($k = 0; $k -lt $log.Count; $k++) { if ($log[$k] -like "*$needle*") { return $k } }; return -1 }
function Bars($log) { @($log | Where-Object { $_ -like 'pump *' } | ForEach-Object { [int]($_ -split '\|')[-1] }) }

$start = Get-Location
$tmp = Join-Path $env:TEMP ('sps-paste-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $tmp 'Templates') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tmp 'Logs') -Force | Out-Null
Set-Location $tmp
try {
	$person = 'user@contoso.com'

	# ========== T1: 1 person x 5 shared mailboxes, one fails ==========
	Write-Host "T1 add to 5 shared mailboxes (one fails)"
	$types = @{ 'user@contoso.com' = @{ Details='UserMailbox'; Type='UserMailbox' } }
	$t1targets = 'a@contoso.com','b@contoso.com','bad@contoso.com','d@contoso.com','e@contoso.com'
	foreach ($t in $t1targets) { $types[$t] = @{ Details='SharedMailbox'; Type='UserMailbox' } }
	$log = Run-Paste $person ($t1targets -join "`n") 'add' 'Mailbox' $types
	$firstStart = IdxFirst $log 'start '
	$lastCheck = -1; for ($k = 0; $k -lt $log.Count; $k++) { if ($log[$k] -like 'pump Checking mailbox *') { $lastCheck = $k } }
	Assert ($lastCheck -ge 0 -and $firstStart -ge 0 -and $lastCheck -lt $firstStart) "all 'Checking mailbox N of 5' pumps come before any add starts"
	$ordOk = $true
	for ($n = 1; $n -le 5; $n++) {
		$t = $t1targets[$n - 1]
		$p = IdxFirst $log "pump Adding $person to the shared mailbox $t ($n of 5)|$n of 5|"
		$s = IdxFirst $log "start Add-MailboxPermission $t "
		if (-not ($p -ge 0 -and $s -ge 0 -and $p -lt $s)) { $ordOk = $false }
	}
	Assert $ordOk "each 'Adding ... shared mailbox <t> (N of 5)' is pumped before that pair's start"
	$bars = Bars $log; $mono = $true; for ($k = 1; $k -lt $bars.Count; $k++) { if ($bars[$k] -lt $bars[$k-1]) { $mono = $false } }
	Assert $mono "the bar never goes down" ("bars=" + ($bars -join ','))
	$doneIx = IdxFirst $log 'pump Done: 4 added, 1 failed|'
	$popIx = IdxFirst $log 'popup Add complete'
	$doneBar = if ($doneIx -ge 0) { [int](($log[$doneIx] -split '\|')[-1]) } else { -1 }
	Assert ($doneIx -ge 0 -and $popIx -ge 0 -and $doneIx -lt $popIx -and $doneBar -eq 100) "'Done: 4 added, 1 failed' at bar 100 before 'popup Add complete'" "doneIx=$doneIx popIx=$popIx bar=$doneBar"
	$locks = @($log | Where-Object { $_ -eq 'lock' }).Count
	$unlockIx = $log.IndexOf('unlock'); $closeIx = $log.IndexOf('close')
	Assert ($locks -eq 1 -and -not $script:NestedLock) "exactly one lock, no nested lock" "locks=$locks nested=$($script:NestedLock)"
	Assert ($unlockIx -ge 0 -and $closeIx -ge 0 -and $unlockIx -lt $closeIx) "unlock comes before close"

	# ========== T2: remove from a distribution list and a Microsoft 365 group ==========
	Write-Host "T2 remove from a distribution list + a Microsoft 365 group (type words)"
	$types = @{ $person = @{ Details='UserMailbox'; Type='UserMailbox' };
		'dl@contoso.com' = @{ Details='MailUniversalDistributionGroup'; Type='MailUniversalDistributionGroup' };
		'team@contoso.com' = @{ Details='GroupMailbox'; Type='MailUniversalDistributionGroup' } }
	$log = Run-Paste $person "dl@contoso.com`nteam@contoso.com" 'remove' 'DistributionList' $types
	$dlP = IdxFirst $log "pump Removing $person from the distribution list dl@contoso.com (1 of 2)|"
	$dlS = IdxFirst $log 'start Remove-DistributionGroupMember dl@contoso.com '
	Assert ($dlP -ge 0 -and $dlS -ge 0 -and $dlP -lt $dlS) "distribution-list remove: correct type word + pump before start"
	$tmP = IdxFirst $log "pump Removing $person from the Teams / Microsoft 365 group team@contoso.com (2 of 2)|"
	$tmS = IdxFirst $log 'start Remove-UnifiedGroupLinks team@contoso.com '
	Assert ($tmP -ge 0 -and $tmS -ge 0 -and $tmP -lt $tmS) "M365-group remove: correct type word + pump before start"
	Assert ((IdxFirst $log 'pump Done: 2 removed, 0 failed|') -lt (IdxFirst $log 'popup Remove complete')) "remove Done text before popup"

	# ========== unknown target: keeps its skip line, counts in targetsSkipped ==========
	Write-Host "unknown target -> skipped, truthful Done"
	$types = @{ $person = @{ Details='UserMailbox'; Type='UserMailbox' }; 'nope@contoso.com' = 'UNKNOWN' }
	$log = Run-Paste $person 'nope@contoso.com' 'add' 'Mailbox' $types
	Assert ((IdxFirst $log 'start Add-') -lt 0) "unknown target: no add cmdlet ran"
	Assert ((IdxFirst $log 'pump Done: 0 failed, 1 target(s) skipped|') -ge 0) "all-unknown Done text = 'Done: 0 failed, 1 target(s) skipped'"

	# ========== swap 'go back' (Yes) -> unlock, no close, no add, no popup ==========
	Write-Host "swap guard 'go back' (Yes)"
	$types = @{ 'grouplike@contoso.com' = @{ Details='MailUniversalDistributionGroup'; Type='MailUniversalDistributionGroup' };
		'x@contoso.com' = @{ Details='SharedMailbox'; Type='UserMailbox' } }
	$log = Run-Paste 'grouplike@contoso.com' 'x@contoso.com' 'add' 'Mailbox' $types $true
	Assert ((IdxFirst $log 'confirm These look swapped') -ge 0) "swap confirm fired"
	Assert (($log.IndexOf('lock') -ge 0) -and ($log.IndexOf('unlock') -ge 0)) "locked then unlocked"
	Assert ((IdxFirst $log 'close') -lt 0 -and (IdxFirst $log 'start Add-') -lt 0 -and (IdxFirst $log 'popup ') -lt 0) "go back: no close, no add, no popup"

	# ========== a throw mid-run still unlocks without close ==========
	Write-Host "throw mid-run -> unlock, no close"
	$savedTypeName = ${function:Get-RecipientTypeName}
	function Get-RecipientTypeName([string]$Raw) { throw 'boom in checking' }
	$types = @{ $person = @{ Details='UserMailbox'; Type='UserMailbox' }; 'z@contoso.com' = @{ Details='SharedMailbox'; Type='UserMailbox' } }
	$log = Run-Paste $person 'z@contoso.com' 'add' 'Mailbox' $types
	${function:Get-RecipientTypeName} = $savedTypeName
	Assert ((IdxFirst $log 'threw ') -ge 0) "the run threw"
	Assert (($log.IndexOf('lock') -ge 0) -and ($log.IndexOf('unlock') -ge 0) -and (IdxFirst $log 'close') -lt 0) "throw: locked, unlocked, never closed"
}
finally {
	Set-Location $start
	Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:Fail) { Write-Host "PASTE LIST TESTS: $($script:Fail) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "PASTE LIST TESTS: all passed" -ForegroundColor Green
exit 0
