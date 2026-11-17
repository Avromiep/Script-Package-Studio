# AD-Preflight.Tests.ps1 - the v3.4.9 "Active Directory check up front (nothing runs half-way)" work.
# Plain PowerShell, no Pester, no module install, no tenant, no real AD, no real dialog. It AST-loads the
# REAL click handlers (Block-User, Terminate single + bulk, Set-ACLPermissions) from src\scripts2.ps1 and
# src\scripts3.ps1 and drives them with AD / Exchange / Graph cmdlets mocked, asserting that an AD-needing
# action STOPS before anything is changed or the tenant is touched, that Block-User disables exactly the
# trimmed name and reports a failed AD step truthfully, and that Set-ACLPermissions builds the rule from
# the resolved SID (Deny stays Deny) and refuses a blank / unknown / local name. A static pass discovers
# every AD entry point from the code and order-checks that the AD gate comes first.
# Run:  pwsh -NoProfile -File tests\AD-Preflight.Tests.ps1
$ErrorActionPreference = 'Stop'
$script:Fail = 0
$script:Skipped = 0
$onWin = ($IsWindows -ne $false)   # $IsWindows is $null on Windows PowerShell 5.1, which still counts as Windows
function Assert([bool]$Cond, [string]$Name, [string]$Got = '') {
	if ($Cond) { Write-Host "  PASS  $Name" } else { Write-Host "  FAIL  $Name  $Got" -ForegroundColor Red; $script:Fail++ }
}
function Skip([string]$Name) { Write-Host "  SKIP  $Name (needs Windows)" -ForegroundColor Yellow; $script:Skipped++ }
function Has($log, [string]$needle) { @($log | Where-Object { $_ -like "*$needle*" }).Count -gt 0 }

$repo = Split-Path $PSScriptRoot -Parent
$s2 = Join-Path $repo 'src\scripts2.ps1'
$s3 = Join-Path $repo 'src\scripts3.ps1'
$ui = Join-Path $repo 'src\ui.ps1'
$mg = Join-Path $repo 'MainGUI.ps1'
$s2ast = [System.Management.Automation.Language.Parser]::ParseFile($s2, [ref]$null, [ref]$null)
$s3ast = [System.Management.Automation.Language.Parser]::ParseFile($s3, [ref]$null, [ref]$null)
$uiast = [System.Management.Automation.Language.Parser]::ParseFile($ui, [ref]$null, [ref]$null)
$mgast = [System.Management.Automation.Language.Parser]::ParseFile($mg, [ref]$null, [ref]$null)

# Find a nested handler's FunctionDefinitionAst by name + a unique marker (two handlers share the name
# OnBlockButtonClick, in different dialogs).
function Get-HandlerAst($ast, [string]$Name, [string]$Marker) {
	foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $Name }, $true)) {
		if ($fn.Extent.Text -match [regex]::Escape($Marker)) { return $fn }
	}
	return $null
}
$astBlockUser  = Get-HandlerAst $s2ast 'OnBlockButtonClick'       'Set-Mailbox -Identity $user -Type Shared'
$astTermSingle = Get-HandlerAst $s2ast 'OnBlockButtonClick'       'Disable-OneEmail $email'
$astTermBulk   = Get-HandlerAst $s2ast 'OnDisableBulkButtonClick' 'Import-Csv $csv'
$astAcl        = Get-HandlerAst $s3ast 'OnSetPermissionsButtonClick' 'Resolve-AclAccount $identityText'
foreach ($p in @(@{N='Block-User';A=$astBlockUser},@{N='Terminate single';A=$astTermSingle},@{N='Terminate bulk';A=$astTermBulk},@{N='Set-ACL';A=$astAcl})) {
	if (-not $p.A) { Write-Host "  FAIL  could not extract handler: $($p.N)" -ForegroundColor Red; exit 1 }
}
$sbBlockUser = $astBlockUser.Body.GetScriptBlock()
$sbTermSingle = $astTermSingle.Body.GetScriptBlock()
$sbTermBulk = $astTermBulk.Body.GetScriptBlock()
$sbAcl = $astAcl.Body.GetScriptBlock()

# ---- module isolation: an AD/Exchange/Graph name that isn't mocked must FAIL, not autoload ----
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop
Import-Module Microsoft.PowerShell.Management -ErrorAction Stop
$PSModuleAutoLoadingPreference = 'None'

# ================= (b) the REAL Test-ADModule returns $false when AD isn't installed =================
# Do this BEFORE any Get-ADUser mock exists, or Test-ADModule's own Get-Command check would see the mock.
Write-Host "(b) real Test-ADModule with no AD module present"
$tamFn = $uiast.Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Test-ADModule' }, $true)
. ([scriptblock]::Create($tamFn.Extent.Text))
if (@(Get-Module -ListAvailable ActiveDirectory).Count -gt 0) { Skip "real Test-ADModule returns false (ActiveDirectory IS installed here)" }
else { Assert ((Test-ADModule) -eq $false) "real Test-ADModule returns `$false when the module is absent" }
Remove-Item function:Test-ADModule -ErrorAction SilentlyContinue

# ---- recording + shared mocks ----
$script:Log = [System.Collections.Generic.List[string]]::new()
$script:HostLog = [System.Collections.Generic.List[string]]::new()
$script:Threw = $false
$script:ADok = $true; $script:ADThrows = $false; $script:GetADUserThrows = $false; $script:DisableADMode = 'ok'
$progressBar1 = [pscustomobject]@{ Value = 0 }

function Confirm-ADAvailable { $script:Log.Add('confirm-ad'); if ($script:ADThrows) { throw 'AD check boom' }; return $script:ADok }
function Test-SignedIn { $script:Log.Add('test-signedin'); return $true }
function Get-ADUser { param($Identity, $Filter, $Properties, $ErrorAction) $script:Log.Add("get-aduser $Identity"); if ($script:GetADUserThrows -or -not "$Identity".Trim()) { throw "not found" }; [pscustomobject]@{ Enabled = $true; SamAccountName = "$Identity" } }
function Disable-ADAccount { [CmdletBinding()] param($Identity) $script:Log.Add("disable-adaccount $Identity"); if ($script:DisableADMode -eq 'error') { Write-Error 'Access is denied' } }
function Set-Mailbox { param($Identity, $Type, $ErrorAction) $script:Log.Add("set-mailbox $Identity") }
function Get-Mailbox { param($Identity, $ErrorAction) $script:Log.Add("get-mailbox $Identity"); [pscustomobject]@{} }
function Disable-OneAd { param($username) $script:Log.Add("disable-onead $username") }
function Disable-OneEmail { param($email) $script:Log.Add("disable-oneemail $email") }
function Invoke-AddMemberPrompt { param($email) $script:Log.Add('addmember') }
function Invoke-AutoReplyPrompt { param($email) $script:Log.Add('autoreply') }
function Lock-ScriptWindow($Window) { $script:Log.Add('lock') }
function Unlock-ScriptWindow { $script:Log.Add('unlock') }
function Show-Notice([string]$Title, [string]$Message, [string]$Kind = 'Info') { $script:Log.Add("popup $Title") }
function Show-AccountResults { param($What, $Created, $Failed, [switch]$Preview, $DoneWord, $FailWord) $script:Log.Add('summary') }
function Step-Progress { param($Text, $i, $tot) }
function Reset-Throughput {}
function Complete-Progress { param($Text) $script:Log.Add("complete $Text") }
function Set-ItemStatus { param($Text) }
function CheckForErrors {}
function OperationComplete { $script:Log.Add('operationcomplete') }
# Block-User email-path Graph cmdlets
function Get-MgUserAuthenticationPasswordMethod { param($UserId) $script:Log.Add('mg-pwd'); [pscustomobject]@{ Id = '1' } }
function Reset-MgUserAuthenticationMethodPassword { param($UserId, $AuthenticationMethodId) $script:Log.Add('mg-reset') }
function Revoke-MgUserSignInSession { param($UserId) $script:Log.Add('mg-revoke') }
function Update-MgUser { param($UserId, $AccountEnabled) $script:Log.Add('mg-update') }
function Remove-UserLicenses { param($User) $script:Log.Add('remove-lic') }
function Clear-UserAuthMethods { param($User) $script:Log.Add('clear-mfa'); 0 }

foreach ($n in 'Confirm-ADAvailable','Get-ADUser','Disable-ADAccount','Set-Mailbox','Disable-OneAd','Disable-OneEmail','Test-SignedIn') {
	$c = Get-Command $n -ErrorAction SilentlyContinue
	if (-not $c -or $c.CommandType -ne 'Function') { Write-Host "  FAIL  mock $n is not a Function" -ForegroundColor Red; exit 1 }
}

function Reset([bool]$ADok = $true, [bool]$GetThrows = $false, [bool]$ADThrows = $false, [string]$DisableMode = 'ok') {
	$script:Log = [System.Collections.Generic.List[string]]::new()
	$script:HostLog = [System.Collections.Generic.List[string]]::new()
	$script:Threw = $false
	$script:ADok = $ADok; $script:GetADUserThrows = $GetThrows; $script:ADThrows = $ADThrows; $script:DisableADMode = $DisableMode
	$progressBar1.Value = 0
}
# run a handler scriptblock with Write-Host captured and any throw caught. The real app runs with the
# default ErrorActionPreference (Continue), so a non-terminating Write-Error (e.g. a failed Disable-ADAccount)
# is captured by -ErrorVariable and execution continues - mirror that here instead of the test's own Stop.
function Fire($sb) {
	$ErrorActionPreference = 'Continue'
	function Write-Host { param([Parameter(ValueFromRemainingArguments = $true)]$a) $script:HostLog.Add(($a -join ' ')) }
	try { . $sb } catch { $script:Threw = $true }
}

# ---- fixed fake controls (reset per group) ----
function Set-BlockUserControls([bool]$ad, [bool]$email, [string]$adText = 'bob') {
	$script:adCheckBox = [pscustomobject]@{ IsChecked = $ad }
	$script:emailCheckBox = [pscustomobject]@{ IsChecked = $email }
	$script:addMembersCheckBox = [pscustomobject]@{ IsChecked = $false }
	$script:addAutoReplyCheckBox = [pscustomobject]@{ IsChecked = $false }
	$script:adNameInputBox = [pscustomobject]@{ Text = $adText }
	$script:emailInputBox = [pscustomobject]@{ Text = 'bob@contoso.com' }
}
function Set-TermControls([bool]$ad, [bool]$email) {
	$script:emailInput = [pscustomobject]@{ Text = 'bob@contoso.com' }
	$script:adUserInput = [pscustomobject]@{ Text = 'bob' }
	$script:blockEmailCheck = [pscustomobject]@{ IsChecked = $email }
	$script:blockAdCheck = [pscustomobject]@{ IsChecked = $ad }
	$script:addMembersCheck = [pscustomobject]@{ IsChecked = $false }
	$script:addAutoReplyCheck = [pscustomobject]@{ IsChecked = $false }
	$script:form = [pscustomobject]@{}
}

# ================= (a) fails closed: the AD check THROWS -> nothing happens, throw is caught =================
Write-Host "(a) Block-User: AD check throws -> no change, throw caught"
Set-BlockUserControls -ad $true -email $true
Reset -ADThrows $true
Fire $sbBlockUser
Assert $script:Threw "the thrown AD check was caught (the gate really ran)"
Assert (Has $script:Log 'confirm-ad') "the AD check was reached"
Assert (-not (Has $script:Log 'get-aduser')) "no AD user lookup"
Assert (-not (Has $script:Log 'disable-adaccount')) "no AD disable"
Assert (-not (Has $script:Log 'set-mailbox')) "no email change"
Assert (-not ($script:Log -contains 'lock')) "no lock"

Write-Host "(a) Terminate single: AD check throws -> nothing, throw caught"
Set-TermControls -ad $true -email $true
Reset -ADThrows $true
Fire $sbTermSingle
Assert $script:Threw "throw caught"
Assert (-not (Has $script:Log 'test-signedin')) "tenant not contacted"
Assert (-not ($script:Log -contains 'lock')) "no lock"
Assert (-not (Has $script:Log 'disable-onead')) "no AD disable"
Assert (-not (Has $script:Log 'disable-oneemail')) "no mailbox change"

$start = Get-Location
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('sps-adpre-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $tmp 'Templates') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tmp 'Logs') -Force | Out-Null
"Username,Email`nbob,bob@contoso.com" | Out-File (Join-Path $tmp 'Templates\Terminate-Disable-ADAndEmailAccounts.csv') -Encoding UTF8
Set-Location $tmp
try {
	Write-Host "(a) Terminate bulk: AD check throws -> nothing, throw caught"
	Set-TermControls -ad $true -email $true
	Reset -ADThrows $true
	Fire $sbTermBulk
	Assert $script:Threw "throw caught"
	Assert (-not (Has $script:Log 'test-signedin')) "tenant not contacted"
	Assert (-not ($script:Log -contains 'lock')) "no lock"
	Assert (-not (Has $script:Log 'disable-onead')) "no AD disable"
	Assert (-not (Has $script:Log 'disable-oneemail')) "no mailbox change"

	# ======== AD-missing (returns false): same stop, no throw ========
	Write-Host "Block-User: AD missing (both AD+email ticked) -> nothing half-way"
	Set-BlockUserControls -ad $true -email $true
	Reset -ADok $false
	Fire $sbBlockUser
	Assert (Has $script:Log 'confirm-ad') "AD check ran"
	Assert (-not (Has $script:Log 'disable-adaccount')) "no AD disable"
	Assert (-not (Has $script:Log 'set-mailbox')) "email part did not run either"
	Assert ([int]$progressBar1.Value -eq 0) "bar reset to 0"

	Write-Host "Terminate single: AD missing -> stops before the tenant"
	Set-TermControls -ad $true -email $true
	Reset -ADok $false
	Fire $sbTermSingle
	Assert (Has $script:Log 'confirm-ad') "AD check ran"
	Assert (-not (Has $script:Log 'test-signedin')) "tenant NOT contacted (AD check is first)"
	Assert (-not ($script:Log -contains 'lock')) "window never locked"
	Assert (-not (Has $script:Log 'disable-oneemail')) "no mailbox change"

	Write-Host "Terminate bulk: AD missing -> stops before any row"
	Set-TermControls -ad $true -email $true
	Reset -ADok $false
	Fire $sbTermBulk
	Assert (Has $script:Log 'confirm-ad') "AD check ran"
	Assert (-not (Has $script:Log 'test-signedin')) "tenant NOT contacted"
	Assert (-not (Has $script:Log 'summary')) "no summary - run never started"

	# ======== email-only path never touches the AD check ========
	Write-Host "Terminate single: email only -> AD check skipped, tenant checked"
	Set-TermControls -ad $false -email $true
	Reset -ADok $false
	Fire $sbTermSingle
	Assert (-not (Has $script:Log 'confirm-ad')) "email-only never calls the AD check"
	Assert (Has $script:Log 'test-signedin') "email-only checks the tenant"
	Assert (Has $script:Log 'disable-oneemail') "email-only disabled the mailbox"

	# ======== (c) Terminate single, module present, user not found ========
	Write-Host "(c) Terminate single: user not found -> couldn't-find popup, no change"
	Set-TermControls -ad $true -email $true
	Reset -ADok $true -GetThrows $true
	Fire $sbTermSingle
	Assert (Has $script:Log 'get-aduser bob') "the AD user was looked up"
	Assert (Has $script:Log 'popup') "a couldn't-find notice was shown"
	Assert (-not (Has $script:Log 'test-signedin')) "tenant NOT contacted after a missing user"
	Assert (-not ($script:Log -contains 'lock')) "no lock"
	Assert (-not (Has $script:Log 'disable-onead')) "no AD disable"

	# ======== (d) Block-User, empty AD name -> couldn't-find, no change ========
	Write-Host "(d) Block-User: empty AD name -> couldn't-find, no change"
	Set-BlockUserControls -ad $true -email $false -adText '   '
	Reset -ADok $true
	Fire $sbBlockUser
	Assert (Has $script:Log 'popup') "a couldn't-find notice was shown for a blank name"
	Assert (-not (Has $script:Log 'disable-adaccount')) "nothing was disabled"

	# ======== (e) Block-User, '  bob  ' -> lookup + disable both get exactly 'bob' ========
	Write-Host "(e) Block-User: '  bob  ' -> lookup and disable both get exactly 'bob'"
	Set-BlockUserControls -ad $true -email $false -adText '  bob  '
	Reset -ADok $true
	Fire $sbBlockUser
	Assert (Has $script:Log 'get-aduser bob') "Get-ADUser got the trimmed name"
	Assert (Has $script:Log 'disable-adaccount bob') "Disable-ADAccount got the trimmed name"
	Assert (-not (Has $script:Log 'disable-adaccount   bob')) "it did NOT disable the untrimmed name"

	# ======== (e2) Block-User, module present, user found: AD success vs AD error ========
	Write-Host "(e2) Block-User: AD disable FAILS (non-terminating) -> truthful error, email still ran, no Operation complete"
	Set-BlockUserControls -ad $true -email $true -adText 'bob'
	Reset -ADok $true -DisableMode 'error'
	Fire $sbBlockUser
	Assert (-not (Has $script:HostLog 'Disabled AD account')) "no 'Disabled AD account' success line"
	Assert (Has $script:Log 'popup Finished with an error') "the 'Finished with an error' popup fired"
	Assert (Has $script:HostLog 'Couldn''t disable AD account bob') "it says the AD account was not disabled"
	Assert (-not (Has $script:Log 'operationcomplete')) "OperationComplete was NOT called"
	Assert (Has $script:Log 'set-mailbox bob@contoso.com') "the email steps still ran"

	Write-Host "(e2) Block-User: AD disable SUCCEEDS -> 'Disabled AD account' + Operation complete"
	Set-BlockUserControls -ad $true -email $true -adText 'bob'
	Reset -ADok $true -DisableMode 'ok'
	Fire $sbBlockUser
	Assert (Has $script:HostLog 'Disabled AD account bob') "the success line is logged"
	Assert (Has $script:Log 'operationcomplete') "OperationComplete was called"

	# ======== (f) Terminate single, user found: Disable-OneAd before Disable-OneEmail ========
	Write-Host "(f) Terminate single: AD disable comes before the email disable"
	Set-TermControls -ad $true -email $true
	Reset -ADok $true
	Fire $sbTermSingle
	$adIx = $script:Log.IndexOf('disable-onead bob'); $emIx = $script:Log.IndexOf('disable-oneemail bob@contoso.com')
	Assert ($adIx -ge 0 -and $emIx -ge 0 -and $adIx -lt $emIx) "Disable-OneAd is logged before Disable-OneEmail" "ad=$adIx email=$emIx"
}
finally { Set-Location $start; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# ================= (h) Set-ACLPermissions =================
$script:ResolveReturn = $null
$script:ResolveSeen = [System.Collections.Generic.List[string]]::new()
$script:AddedRules = [System.Collections.Generic.List[object]]::new()
$script:SetAclPaths = [System.Collections.Generic.List[string]]::new()
function Resolve-AclAccount([string]$Name) { $script:Log.Add("resolve $Name"); $script:ResolveSeen.Add("$Name"); return $script:ResolveReturn }
function Get-Acl { param($Path) $script:Log.Add("get-acl $Path"); $acl = [pscustomobject]@{}; $acl | Add-Member ScriptMethod AddAccessRule { param($r) $script:AddedRules.Add($r) }; return $acl }
function Set-Acl { param($Path, $AclObject) $script:SetAclPaths.Add("$Path") }

function Set-AclControls {
	$script:continuousProgressBar = [pscustomobject]@{ Value = 0 }
	$script:pathTextBox = [pscustomobject]@{ Text = 'C:\data' }
	$script:domainTextBox = [pscustomobject]@{ Text = 'CONTOSO' }
	$script:userGroupComboBox = [pscustomobject]@{ Text = 'jdoe' }
	$script:singleRadioButton = [pscustomobject]@{ IsChecked = $true }
	$script:multipleRadioButton = [pscustomobject]@{ IsChecked = $false }
	$script:actAllowRadioButton = [pscustomobject]@{ IsChecked = $false }
	$script:actDenyRadioButton = [pscustomobject]@{ IsChecked = $true }
	$script:rightsCheckBoxes = @([pscustomobject]@{ IsChecked = $true; Content = 'Read' })
	$script:inheritanceCheckBoxes = @([pscustomobject]@{ IsChecked = $true; Content = 'ContainerInherit' })
	$script:propagationCheckBoxes = @([pscustomobject]@{ IsChecked = $true; Content = 'None' })
	$script:setPermissionsForm = [pscustomobject]@{}
}
function Run-Acl {
	$script:Log = [System.Collections.Generic.List[string]]::new()
	$script:HostLog = [System.Collections.Generic.List[string]]::new()
	$script:ResolveSeen = [System.Collections.Generic.List[string]]::new()
	$script:AddedRules = [System.Collections.Generic.List[object]]::new()
	$script:SetAclPaths = [System.Collections.Generic.List[string]]::new()
	Fire $sbAcl
}
Set-AclControls

if ($onWin) {
	$domainSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1111111111-2222222222-3333333333-1001')
	$localSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-9999999999-8888888888-7777777777-1002')
	Write-Host "(h) Set-ACL: Deny stays Deny, rule built from the resolved SID"
	Set-AclControls; $script:ResolveReturn = @{ Sid = $domainSid; Name = 'CONTOSO\jdoe' }
	Run-Acl
	Assert ($script:AddedRules.Count -eq 1) "one rule built" "count=$($script:AddedRules.Count)"
	if ($script:AddedRules.Count -eq 1) {
		Assert ("$($script:AddedRules[0].AccessControlType)" -eq 'Deny') "Deny applied as Deny (not Allow)" "got=$($script:AddedRules[0].AccessControlType)"
		$rsid = $script:AddedRules[0].IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
		Assert ($rsid -eq $domainSid.Value) "rule identity is the resolved SID" "got=$rsid"
	}
	Assert ($script:SetAclPaths.Count -eq 1) "the change was written"

	Write-Host "(h) Set-ACL: Allow stays Allow"
	Set-AclControls; $script:actAllowRadioButton.IsChecked = $true; $script:actDenyRadioButton.IsChecked = $false
	$script:ResolveReturn = @{ Sid = $domainSid; Name = 'CONTOSO\jdoe' }
	Run-Acl
	Assert ($script:AddedRules.Count -eq 1 -and "$($script:AddedRules[0].AccessControlType)" -eq 'Allow') "Allow applied as Allow"

	Write-Host "(h) Set-ACL: empty Domain box -> the mock gets exactly 'bob'"
	Set-AclControls; $script:userGroupComboBox.Text = 'bob'; $script:domainTextBox.Text = ''
	$script:ResolveReturn = @{ Sid = $domainSid; Name = 'CONTOSO\bob' }
	Run-Acl
	Assert ($script:ResolveSeen.Count -eq 1 -and $script:ResolveSeen[0] -eq 'bob') "Resolve-AclAccount got exactly 'bob'" "seen=$($script:ResolveSeen -join ',')"

	Write-Host "(h) Set-ACL: a bare name that resolves to a LOCAL account is refused"
	Set-AclControls; $script:userGroupComboBox.Text = 'bob'; $script:domainTextBox.Text = ''
	$script:ResolveReturn = @{ Sid = $localSid; Name = "$($env:COMPUTERNAME.ToLower())\bob" }
	Run-Acl
	Assert (Has $script:Log 'popup Local account') "the local-account refusal fired"
	Assert ($script:SetAclPaths.Count -eq 0) "no folder changed for a local account"
	Assert (-not (Has $script:Log 'operationcomplete')) "no OperationComplete for a local account"

	Write-Host "(h) Set-ACL: a typed COMPUTERNAME\jane is ALLOWED"
	Set-AclControls; $script:userGroupComboBox.Text = "$($env:COMPUTERNAME)\jane"; $script:domainTextBox.Text = ''
	$script:ResolveReturn = @{ Sid = $domainSid; Name = "$($env:COMPUTERNAME)\jane" }
	Run-Acl
	Assert ($script:AddedRules.Count -eq 1 -and $script:SetAclPaths.Count -eq 1) "a typed machine-qualified name builds one rule and writes"

	Write-Host "(h) Set-ACL: the Multiple branch builds every rule from the SID, keeps Deny"
	$mstart = Get-Location
	$mtmp = Join-Path ([IO.Path]::GetTempPath()) ('sps-acl-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
	New-Item -ItemType Directory -Path (Join-Path $mtmp 'Templates') -Force | Out-Null
	"C:\one`nC:\two" | Out-File (Join-Path $mtmp 'Templates\Set-ACLPermissions.txt') -Encoding UTF8
	Set-Location $mtmp
	try {
		Set-AclControls; $script:singleRadioButton.IsChecked = $false; $script:multipleRadioButton.IsChecked = $true
		$script:ResolveReturn = @{ Sid = $domainSid; Name = 'CONTOSO\jdoe' }
		Run-Acl
		Assert ($script:AddedRules.Count -eq 2) "two rules built for two folders" "count=$($script:AddedRules.Count)"
		$allDeny = @($script:AddedRules | Where-Object { "$($_.AccessControlType)" -ne 'Deny' }).Count -eq 0
		$allSid = @($script:AddedRules | Where-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -ne $domainSid.Value }).Count -eq 0
		Assert ($allDeny) "both rules are Deny"
		Assert ($allSid) "both rules use the resolved SID"
		Assert ($script:SetAclPaths.Count -eq 2) "both folders written"
	}
	finally { Set-Location $mstart; Remove-Item $mtmp -Recurse -Force -ErrorAction SilentlyContinue }
}
else {
	Skip "Set-ACL rule-from-SID / Deny / local-account / machine-qualified / Multiple-branch (need SIDs)"
}

Write-Host "(h) Set-ACL: a blank name stops before Resolve-AclAccount"
Set-AclControls; $script:userGroupComboBox.Text = '   '; $script:domainTextBox.Text = 'CONTOSO'
Run-Acl
Assert (Has $script:Log "popup Couldn't find the account") "the blank-name popup fired"
Assert ($script:ResolveSeen.Count -eq 0) "Resolve-AclAccount was never called for a blank name"
Assert ($script:SetAclPaths.Count -eq 0) "no folder changed for a blank name"

Write-Host "(h) Set-ACL: unknown name -> nothing changed"
Set-AclControls; $script:ResolveReturn = $null
Run-Acl
Assert (Has $script:Log 'popup') "a couldn't-find notice was shown"
Assert ($script:SetAclPaths.Count -eq 0) "no folder changed for an unknown name"
Assert (-not (Has $script:Log 'operationcomplete')) "no OperationComplete for an unknown name"

if ($onWin) {
	Write-Host "(h) Set-ACL: neither Allow nor Deny -> nothing, and 'Setting permissions' not logged"
	Set-AclControls; $script:actAllowRadioButton.IsChecked = $false; $script:actDenyRadioButton.IsChecked = $false
	$script:ResolveReturn = @{ Sid = $domainSid; Name = 'CONTOSO\jdoe' }
	Run-Acl
	Assert (Has $script:Log 'popup Missing info') "the 'pick Allow or Deny' notice fired"
	Assert ($script:SetAclPaths.Count -eq 0) "no folder changed when neither is ticked"
	Assert (-not (Has $script:Log 'operationcomplete')) "no OperationComplete when neither is ticked"
	Assert (-not (Has $script:HostLog 'Setting permissions')) "'Setting permissions' is NOT logged when neither is ticked"
}

# ================= (h) unmocked Resolve-AclAccount, Windows only =================
Remove-Item function:Resolve-AclAccount -ErrorAction SilentlyContinue
$raFn = $s3ast.Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Resolve-AclAccount' }, $true)
. ([scriptblock]::Create($raFn.Extent.Text))
if ($onWin) {
	Write-Host "(h) real Resolve-AclAccount resolves a well-known account and rejects a made-up one"
	$bu = Resolve-AclAccount 'BUILTIN\Users'
	Assert ($bu -and "$($bu.Sid)" -eq 'S-1-5-32-545') "'BUILTIN\Users' -> S-1-5-32-545" "got=$($bu.Sid)"
	Assert ($null -eq (Resolve-AclAccount 'NoSuch\zzqq_not_real_12345')) "a made-up name returns `$null"
}
else { Skip "real Resolve-AclAccount SID lookup (needs Windows)" }

# ================= (g) AST-discovered AD inventory + order checks =================
Write-Host "(g) AD inventory is discovered from the code and frozen"
$files = @($mg) + @(Get-ChildItem (Join-Path $repo 'src') -Filter *.ps1 | ForEach-Object { $_.FullName })
$skipHelpers = 'New-ADUserRow','Get-ADUserMatches','Enable-ADUserAutocomplete','Assert-ADUserNotExists'
$rx = '^(Get|Set|New|Remove|Disable|Enable|Add|Move|Unlock|Search|Rename|Clear)-AD'
$found = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($f in $files) {
	$ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$null)
	foreach ($c in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)) {
		$n = $c.GetCommandName(); if (-not $n) { continue }
		$isAd = ($n -match $rx)
		$isImp = ($n -eq 'Import-Module' -and $c.Extent.Text -match 'ActiveDirectory')
		if (-not ($isAd -or $isImp)) { continue }
		$p = $c.Parent; while ($p -and -not ($p -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $p = $p.Parent }
		$fn = if ($p) { $p.Name } else { '<top>' }
		if ($skipHelpers -notcontains $fn) { [void]$found.Add($fn) }
	}
}
# Frozen inventory (prefix-name matches include our own New-AD*/New-Add* helper calls - this list only has
# to stay STABLE; any add/remove of an AD-touching function trips it so it gets re-reviewed).
$expectedInv = @('<top>','Add-Contacts','Block-User','CreateADAccounts','CreateAccounts','Disable-OneAd','New-ADAccounts','New-ADAndEmailAccounts','OnBlockButtonClick','OnRunButtonClick','Set-ACLPermissions','Terminate-Disable-ADAndEmailAccounts','Test-ADModule')
$foundArr = @($found)
$missing = @($expectedInv | Where-Object { $foundArr -notcontains $_ })
$extra = @($foundArr | Where-Object { $expectedInv -notcontains $_ })
Assert ($missing.Count -eq 0 -and $extra.Count -eq 0) "the discovered AD inventory matches the frozen list" ("missing=[" + ($missing -join ',') + "] extra=[" + ($extra -join ',') + "]")
Write-Host "AD-touching functions (discovered, frozen):"
foreach ($x in $foundArr) { Write-Host "  - $x" }

Write-Host "(g) each AD entry handler gates BEFORE its first tenant call / lock / change / transcript"
function First-Offset($fn, [string[]]$names) {
	$best = [int]::MaxValue
	foreach ($c in $fn.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)) {
		$n = $c.GetCommandName(); if ($n -and ($names -contains $n)) { if ($c.Extent.StartOffset -lt $best) { $best = $c.Extent.StartOffset } }
	}
	return $best
}
$gate = 'Confirm-ADAvailable','Test-ADModule'
$anchors = 'Test-SignedIn','Lock-ScriptWindow','Disable-ADAccount','Disable-OneAd','Disable-OneEmail','Set-Mailbox','New-ADUser','Set-ADUser','Add-ADGroupMember','Start-Transcript'
$newAcc = $s2ast.Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'New-ADAccounts' }, $true)
$newAccEmail = $s2ast.Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'New-ADAndEmailAccounts' }, $true)
$entryHandlers = @(
	@{ N = 'New-ADAccounts'; A = $newAcc },
	@{ N = 'New-ADAndEmailAccounts'; A = $newAccEmail },
	@{ N = 'Block-User OnBlockButtonClick'; A = $astBlockUser },
	@{ N = 'Terminate OnBlockButtonClick'; A = $astTermSingle },
	@{ N = 'Terminate OnDisableBulkButtonClick'; A = $astTermBulk }
)
foreach ($e in $entryHandlers) {
	$g = First-Offset $e.A $gate
	$an = First-Offset $e.A $anchors
	Assert ($g -lt $an) "$($e.N): the AD check comes before its first tenant/lock/change/transcript" "gate=$g anchor=$an"
}

# ================= Set-ACL static order within OnSetPermissionsButtonClick =================
Write-Host "(h-static) Resolve-AclAccount runs before Get-Acl / lock / Set-Acl, blank-name check first, no NTAccount/Translate"
$aclText = $astAcl.Extent.Text
$iBlank = $aclText.IndexOf("Couldn't find the account")
$iResolve = $aclText.IndexOf('Resolve-AclAccount')
$iGetAcl = $aclText.IndexOf('Get-Acl')
$iLock = $aclText.IndexOf('Lock-ScriptWindow')
$iSetAcl = $aclText.IndexOf('Set-Acl ')
Assert ($iBlank -ge 0 -and $iBlank -lt $iResolve) "the blank-name check comes before Resolve-AclAccount"
Assert ($iResolve -ge 0 -and $iResolve -lt $iGetAcl) "Resolve-AclAccount runs before the first Get-Acl"
Assert ($iResolve -lt $iLock) "Resolve-AclAccount runs before Lock-ScriptWindow"
Assert ($iResolve -lt $iSetAcl) "Resolve-AclAccount runs before Set-Acl"
Assert ($aclText -notmatch 'NTAccount') "the handler has no NTAccount of its own (resolution is in Resolve-AclAccount)"
Assert ($aclText -notmatch '\.Translate\(') "the handler has no .Translate( of its own"

Write-Host ""
$msg = "AD PREFLIGHT TESTS:"
if ($script:Skipped) { $msg += " $($script:Skipped) skipped;" }
if ($script:Fail) { Write-Host "$msg $($script:Fail) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "$msg all passed" -ForegroundColor Green
exit 0
