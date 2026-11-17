# AD-Preflight.Tests.ps1 - the v3.4.9 "Active Directory check up front (nothing runs half-way)" work.
# Plain PowerShell, no Pester, no module install, no tenant, no real AD, no real dialog. It AST-loads the
# REAL click handlers (Block-User, Terminate single + bulk, Set-ACLPermissions) from src\scripts2.ps1 and
# src\scripts3.ps1 and drives them with the AD / Exchange / Graph cmdlets mocked, asserting:
#   - when "Block AD" is ticked and the AD module is missing, the handler STOPS before anything is
#     changed or even the tenant is touched (no Test-SignedIn, no lock, no disable, no Set-Mailbox);
#   - an email-only run never calls the AD check at all;
#   - Set-ACLPermissions builds the rule from the RESOLVED SID (not a bare name), applies Deny as Deny
#     (the v3.4.9 bug fix - it used to be written as Allow), refuses a local account, and stops cleanly
#     when the name can't be found or Allow/Deny isn't picked.
# Run:  pwsh -NoProfile -File tests\AD-Preflight.Tests.ps1
$ErrorActionPreference = 'Stop'
$script:Fail = 0
function Assert([bool]$Cond, [string]$Name, [string]$Got = '') {
	if ($Cond) { Write-Host "  PASS  $Name" } else { Write-Host "  FAIL  $Name  $Got" -ForegroundColor Red; $script:Fail++ }
}
function Has($log, [string]$needle) { @($log | Where-Object { $_ -like "*$needle*" }).Count -gt 0 }

$repo = Split-Path $PSScriptRoot -Parent
$s2 = Join-Path $repo 'src\scripts2.ps1'
$s3 = Join-Path $repo 'src\scripts3.ps1'
$ui = Join-Path $repo 'src\ui.ps1'

$s2ast = [System.Management.Automation.Language.Parser]::ParseFile($s2, [ref]$null, [ref]$null)
$s3ast = [System.Management.Automation.Language.Parser]::ParseFile($s3, [ref]$null, [ref]$null)
$uiast = [System.Management.Automation.Language.Parser]::ParseFile($ui, [ref]$null, [ref]$null)

# Grab a nested click handler's body scriptblock by its function name + a unique marker (two handlers
# share the name OnBlockButtonClick, in different dialogs, so the marker disambiguates).
function Get-HandlerBody($ast, [string]$Name, [string]$Marker) {
	foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $Name }, $true)) {
		if ($fn.Extent.Text -match [regex]::Escape($Marker)) { return $fn.Body.GetScriptBlock() }
	}
	return $null
}
$sbBlockUser  = Get-HandlerBody $s2ast 'OnBlockButtonClick'      'Set-Mailbox -Identity $user -Type Shared'
$sbTermSingle = Get-HandlerBody $s2ast 'OnBlockButtonClick'      'Disable-OneEmail $email'
$sbTermBulk   = Get-HandlerBody $s2ast 'OnDisableBulkButtonClick' 'Import-Csv $csv'
$sbAcl        = Get-HandlerBody $s3ast 'OnSetPermissionsButtonClick' 'Resolve-AclAccount $identityText'
foreach ($pair in @(@{N='Block-User OnBlockButtonClick';B=$sbBlockUser}, @{N='Terminate OnBlockButtonClick';B=$sbTermSingle}, @{N='Terminate OnDisableBulkButtonClick';B=$sbTermBulk}, @{N='Set-ACLPermissions OnSetPermissionsButtonClick';B=$sbAcl})) {
	if (-not $pair.B) { Write-Host "  FAIL  could not extract handler: $($pair.N)" -ForegroundColor Red; exit 1 }
}

# ---- module isolation: any AD/Exchange/Graph name that isn't mocked must FAIL, not autoload ----
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop
Import-Module Microsoft.PowerShell.Management -ErrorAction Stop
$PSModuleAutoLoadingPreference = 'None'

# ---- recording + shared mocks ----
$script:Log = [System.Collections.Generic.List[string]]::new()
$script:ADok = $true
$script:GetADUserThrows = $false
$progressBar1 = [pscustomobject]@{ Value = 0 }

function Confirm-ADAvailable { $script:Log.Add('confirm-ad'); return $script:ADok }
function Test-ADModule { return $script:ADok }
function Test-SignedIn { $script:Log.Add('test-signedin'); return $true }
function Get-ADUser { param($Identity, $Filter, $Properties, $ErrorAction) $script:Log.Add("get-aduser $Identity"); if ($script:GetADUserThrows) { throw "not found" }; [pscustomobject]@{ Enabled = $true; SamAccountName = "$Identity" } }
function Disable-ADAccount { param($Identity, $ErrorAction) $script:Log.Add("disable-adaccount $Identity") }
function Set-Mailbox { param($Identity, $Type, $ErrorAction) $script:Log.Add("set-mailbox $Identity") }
function Get-Mailbox { param($Identity, $ErrorAction) $script:Log.Add("get-mailbox $Identity"); [pscustomobject]@{ } }
# Terminate inner workers (siblings of the handler) - mocked so a run that reaches them is visible
function Disable-OneAd { param($username) $script:Log.Add("disable-onead $username") }
function Disable-OneEmail { param($email) $script:Log.Add("disable-oneemail $email") }
function Invoke-AddMemberPrompt { param($email) $script:Log.Add('addmember') }
function Invoke-AutoReplyPrompt { param($email) $script:Log.Add('autoreply') }
# UI / flow mocks
function Lock-ScriptWindow($Window) { $script:Log.Add('lock') }
function Unlock-ScriptWindow { $script:Log.Add('unlock') }
function Show-Notice([string]$Title, [string]$Message, [string]$Kind = 'Info') { $script:Log.Add("popup $Title") }
function Show-AccountResults { param($What, $Created, $Failed, [switch]$Preview, $DoneWord, $FailWord) $script:Log.Add('summary') }
function Step-Progress { param($Text, $i, $tot) }
function Complete-Progress { param($Text) $script:Log.Add("complete $Text") }
function Set-ItemStatus { param($Text) }
function CheckForErrors { }
function OperationComplete { $script:Log.Add('operationcomplete') }
# Block-User email-path Graph cmdlets (must NOT run in the AD-missing test)
function Get-MgUserAuthenticationPasswordMethod { param($UserId) $script:Log.Add('mg-pwd'); [pscustomobject]@{ Id = '1' } }
function Reset-MgUserAuthenticationMethodPassword { param($UserId, $AuthenticationMethodId) $script:Log.Add('mg-reset') }
function Revoke-MgUserSignInSession { param($UserId) $script:Log.Add('mg-revoke') }
function Update-MgUser { param($UserId, $AccountEnabled) $script:Log.Add('mg-update') }
function Remove-UserLicenses { param($User) $script:Log.Add('remove-lic') }
function Clear-UserAuthMethods { param($User) $script:Log.Add('clear-mfa'); 0 }

# every name a handler might call must be a Function here, never a real cmdlet that autoloaded
foreach ($n in 'Confirm-ADAvailable','Get-ADUser','Disable-ADAccount','Set-Mailbox','Disable-OneAd','Disable-OneEmail','Test-SignedIn') {
	$c = Get-Command $n -ErrorAction SilentlyContinue
	if (-not $c -or $c.CommandType -ne 'Function') { Write-Host "  FAIL  mock $n is not a Function" -ForegroundColor Red; exit 1 }
}

function Reset([bool]$ADok = $true, [bool]$Throws = $false) {
	$script:Log = [System.Collections.Generic.List[string]]::new()
	$script:ADok = $ADok; $script:GetADUserThrows = $Throws; $progressBar1.Value = 0
}

# ================================================================= Block-User
Write-Host "Block-User: AD ticked + AD module missing"
# both AD and email ticked; AD is missing -> must stop before ANY change, incl. the email part
$adCheckBox = [pscustomobject]@{ IsChecked = $true }
$emailCheckBox = [pscustomobject]@{ IsChecked = $true }
$addMembersCheckBox = [pscustomobject]@{ IsChecked = $false }
$adNameInputBox = [pscustomobject]@{ Text = 'bob' }
$emailInputBox = [pscustomobject]@{ Text = 'bob@contoso.com' }
Reset -ADok $false
. $sbBlockUser
Assert (Has $script:Log 'confirm-ad') "the AD check ran"
Assert (-not (Has $script:Log 'disable-adaccount')) "no AD account was disabled"
Assert (-not (Has $script:Log 'get-aduser')) "AD user was not even looked up"
Assert (-not (Has $script:Log 'set-mailbox')) "the EMAIL part did not run either (nothing half-way)"
Assert ([int]$progressBar1.Value -eq 0) "the bar was reset to 0"

Write-Host "Block-User: AD present but the user doesn't exist"
Reset -ADok $true -Throws $true
. $sbBlockUser
Assert (Has $script:Log "get-aduser bob") "the AD user was looked up"
Assert (Has $script:Log 'popup') "a 'couldn''t find' notice was shown"
Assert (-not (Has $script:Log 'disable-adaccount')) "nothing was disabled for a missing user"
Assert (-not (Has $script:Log 'set-mailbox')) "the email part did not run after the AD preflight failed"

# ================================================================= Terminate (single)
Write-Host "Terminate single: AD ticked + AD module missing -> stops before the tenant"
$emailInput = [pscustomobject]@{ Text = 'bob@contoso.com' }
$adUserInput = [pscustomobject]@{ Text = 'bob' }
$blockEmailCheck = [pscustomobject]@{ IsChecked = $true }
$blockAdCheck = [pscustomobject]@{ IsChecked = $true }
$addMembersCheck = [pscustomobject]@{ IsChecked = $false }
$addAutoReplyCheck = [pscustomobject]@{ IsChecked = $false }
$form = [pscustomobject]@{ }
Reset -ADok $false
. $sbTermSingle
Assert (Has $script:Log 'confirm-ad') "the AD check ran"
Assert (-not (Has $script:Log 'test-signedin')) "the tenant was NOT contacted (AD check is before the email connection check)"
Assert (-not ($script:Log -contains 'lock')) "the window was never locked"
Assert (-not (Has $script:Log 'disable-onead')) "no AD account was disabled"
Assert (-not (Has $script:Log 'disable-oneemail')) "no mailbox was touched"

Write-Host "Terminate single: email only (AD unticked) -> AD check is skipped entirely"
$blockEmailCheck = [pscustomobject]@{ IsChecked = $true }
$blockAdCheck = [pscustomobject]@{ IsChecked = $false }
Reset -ADok $false
. $sbTermSingle
Assert (-not (Has $script:Log 'confirm-ad')) "email-only run never calls the AD check"
Assert (Has $script:Log 'test-signedin') "email-only run checks the tenant connection"
Assert (Has $script:Log 'disable-oneemail') "email-only run disabled the mailbox"

# ================================================================= Terminate (bulk)
$start = Get-Location
$tmp = Join-Path $env:TEMP ('sps-adpre-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $tmp 'Templates') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tmp 'Logs') -Force | Out-Null
"Username,Email`nbob,bob@contoso.com" | Out-File (Join-Path $tmp 'Templates\Terminate-Disable-ADAndEmailAccounts.csv') -Encoding UTF8
Set-Location $tmp
try {
	Write-Host "Terminate bulk: AD ticked + AD module missing -> stops before any row"
	$blockEmailCheck = [pscustomobject]@{ IsChecked = $true }
	$blockAdCheck = [pscustomobject]@{ IsChecked = $true }
	Reset -ADok $false
	. $sbTermBulk
	Assert (Has $script:Log 'confirm-ad') "the AD check ran"
	Assert (-not (Has $script:Log 'test-signedin')) "the tenant was NOT contacted"
	Assert (-not ($script:Log -contains 'lock')) "the window was never locked"
	Assert (-not (Has $script:Log 'disable-onead')) "no AD account was disabled"
	Assert (-not (Has $script:Log 'disable-oneemail')) "no mailbox was touched"
	Assert (-not (Has $script:Log 'summary')) "no summary - the run never started"
}
finally { Set-Location $start; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# ================================================================= Set-ACLPermissions
Write-Host "Set-ACLPermissions: rule built from the resolved SID, Deny stays Deny"
$script:ResolveReturn = $null
$script:AddedRules = [System.Collections.Generic.List[object]]::new()
$script:SetAclPaths = [System.Collections.Generic.List[string]]::new()
function Resolve-AclAccount([string]$Name) { $script:Log.Add("resolve $Name"); return $script:ResolveReturn }
function Get-Acl { param($Path) $acl = [pscustomobject]@{ }; $acl | Add-Member ScriptMethod AddAccessRule { param($r) $script:AddedRules.Add($r) }; return $acl }
function Set-Acl { param($Path, $AclObject) $script:SetAclPaths.Add("$Path") }

function Run-Acl {
	$script:Log = [System.Collections.Generic.List[string]]::new()
	$script:AddedRules = [System.Collections.Generic.List[object]]::new()
	$script:SetAclPaths = [System.Collections.Generic.List[string]]::new()
	. $sbAcl
}
$continuousProgressBar = [pscustomobject]@{ Value = 0 }
$pathTextBox = [pscustomobject]@{ Text = 'C:\data' }
$domainTextBox = [pscustomobject]@{ Text = 'CONTOSO' }
$userGroupComboBox = [pscustomobject]@{ Text = 'jdoe' }
$singleRadioButton = [pscustomobject]@{ IsChecked = $true }
$multipleRadioButton = [pscustomobject]@{ IsChecked = $false }
$actAllowRadioButton = [pscustomobject]@{ IsChecked = $false }
$actDenyRadioButton = [pscustomobject]@{ IsChecked = $true }
$rightsCheckBoxes = @([pscustomobject]@{ IsChecked = $true; Content = 'Read' })
$inheritanceCheckBoxes = @([pscustomobject]@{ IsChecked = $true; Content = 'ContainerInherit' })
$propagationCheckBoxes = @([pscustomobject]@{ IsChecked = $true; Content = 'None' })

$domainSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1111111111-2222222222-3333333333-1001')
$script:ResolveReturn = @{ Sid = $domainSid; Name = 'CONTOSO\jdoe' }
Run-Acl
Assert ($script:AddedRules.Count -eq 1) "one access rule was built" "count=$($script:AddedRules.Count)"
if ($script:AddedRules.Count -eq 1) {
	$rule = $script:AddedRules[0]
	Assert ("$($rule.AccessControlType)" -eq 'Deny') "Deny is applied as Deny (not Allow)" "got=$($rule.AccessControlType)"
	$ruleSid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
	Assert ($ruleSid -eq $domainSid.Value) "the rule's identity is the RESOLVED SID (not a bare typed name)" "got=$ruleSid"
}
Assert ($script:SetAclPaths.Count -eq 1 -and $script:SetAclPaths[0] -eq 'C:\data') "the change was written to the folder"

Write-Host "Set-ACLPermissions: Allow stays Allow"
$actAllowRadioButton.IsChecked = $true; $actDenyRadioButton.IsChecked = $false
Run-Acl
Assert ($script:AddedRules.Count -eq 1 -and "$($script:AddedRules[0].AccessControlType)" -eq 'Allow') "Allow is applied as Allow"
$actAllowRadioButton.IsChecked = $false; $actDenyRadioButton.IsChecked = $true

Write-Host "Set-ACLPermissions: unknown name -> nothing changed"
$script:ResolveReturn = $null
Run-Acl
Assert (Has $script:Log 'popup') "a 'couldn''t find' notice was shown"
Assert ($script:SetAclPaths.Count -eq 0) "no folder was changed for an unknown name"

Write-Host "Set-ACLPermissions: a bare name that resolves to a LOCAL account is refused"
$userGroupComboBox.Text = 'bob'; $domainTextBox.Text = ''
$localSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-9999999999-8888888888-7777777777-1002')
$script:ResolveReturn = @{ Sid = $localSid; Name = "$env:COMPUTERNAME\bob" }
Run-Acl
Assert (Has $script:Log 'popup') "the local-account refusal notice was shown"
Assert ($script:SetAclPaths.Count -eq 0) "no folder was changed for a local account"
$userGroupComboBox.Text = 'jdoe'; $domainTextBox.Text = 'CONTOSO'

Write-Host "Set-ACLPermissions: neither Allow nor Deny picked -> stops"
$script:ResolveReturn = @{ Sid = $domainSid; Name = 'CONTOSO\jdoe' }
$actAllowRadioButton.IsChecked = $false; $actDenyRadioButton.IsChecked = $false
Run-Acl
Assert (Has $script:Log 'popup') "a 'pick Allow or Deny' notice was shown"
Assert ($script:SetAclPaths.Count -eq 0) "no folder was changed when neither was picked"

# ================================================================= static inventory
# Every user-facing entry point that uses on-prem AD must gate on Confirm-ADAvailable (or Test-ADModule).
# This list is printed in the report so the reviewer can see exactly which features are AD-gated.
Write-Host "Static inventory: every AD entry point is gated"
$inventory = @(
	@{ File = $s2; Fn = 'Block-User';                              Why = 'Block AD: disable the on-prem account' },
	@{ File = $s2; Fn = 'Terminate-Disable-ADAndEmailAccounts';    Why = 'Terminate: disable AD + email (single + bulk)' },
	@{ File = $s2; Fn = 'New-ADAccounts';                          Why = 'Create AD accounts' },
	@{ File = $s2; Fn = 'New-ADAndEmailAccounts';                  Why = 'Create AD + email accounts' },
	@{ File = $s3; Fn = 'Set-ACLPermissions';                      Why = 'Folder permissions: name-box autocomplete from AD' }
)
$astCache = @{ $s2 = $s2ast; $s3 = $s3ast }
foreach ($e in $inventory) {
	$ast = $astCache[$e.File]
	$fn = $ast.Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $e.Fn }, $true)
	$gated = $fn -and ($fn.Extent.Text -match 'Confirm-ADAvailable' -or $fn.Extent.Text -match 'Test-ADModule')
	Assert $gated "$($e.Fn) is AD-gated  ($($e.Why))"
}
Write-Host ""
Write-Host "AD-gated entry points (static inventory):"
foreach ($e in $inventory) { Write-Host ("  - {0,-38} {1}" -f $e.Fn, $e.Why) }

Write-Host ""
if ($script:Fail) { Write-Host "AD PREFLIGHT TESTS: $($script:Fail) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "AD PREFLIGHT TESTS: all passed" -ForegroundColor Green
exit 0
