# SelfTest-Modules.ps1 - loads the planned modules in an ISOLATED temp folder and checks them.
# Never touches the real CurrentUser module folder; never signs in or out; never prints a token.
# Outer run: make a temp folder, download the row defaults into it, launch a child that loads them
# in isolation and writes the report, then clean the temp folder up. Child run (-Inner): load + check.
[CmdletBinding()]
param(
	[switch]$ExcludeAllUsers,
	[switch]$SkipDownload,
	[string]$OutFile,
	[switch]$Inner,
	[string]$Root
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'modulepins.ps1')

function Get-AllUsersRoots {
	$r = @()
	if ($env:ProgramFiles) { $r += (Join-Path $env:ProgramFiles 'PowerShell\Modules'); $r += (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules') }
	return @($r | Where-Object { $_ })
}

if (-not $Inner) {
	# ============ OUTER: temp folder, download, launch child, guarded cleanup ============
	try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
	$root = Join-Path $env:TEMP ('SPS-SelfTest-{0}-{1}' -f (Get-Date -Format yyyyMMdd-HHmmss), [guid]::NewGuid().ToString('N').Substring(0, 8))
	if (Test-Path -LiteralPath $root) { Write-Host 'FAIL: temp folder already exists'; exit 1 }
	New-Item -ItemType Directory -Path $root -ErrorAction Stop | Out-Null
	$mods = Join-Path $root 'Modules'
	New-Item -ItemType Directory -Path $mods -ErrorAction Stop | Out-Null
	# OutFile defaults OUTSIDE the folder that gets deleted (F7a).
	if (-not $OutFile) { $OutFile = Join-Path $env:TEMP ('SPS-selftest-{0}.txt' -f (Get-Date -Format yyyyMMdd-HHmmss)) }
	$roots = @($mods); if (-not $ExcludeAllUsers) { $roots += Get-AllUsersRoots }   # NEVER MyDocuments
	$plan = Resolve-ModulePlan -Roots $roots
	# Download ONLY what the plan says is needed (N3): everything when the set is bare, nothing when the
	# AllUsers roots already hold a working set. The child copies download.txt into the report.
	if (-not $SkipDownload -and @($plan.NeedsInstall).Count) {
		Write-Host "Downloading module set into the temp folder (this can take up to ~5 min)..."
		$dl = $null; $mpPath = Join-Path $PSScriptRoot 'modulepins.ps1'
		if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
			$job = Start-ThreadJob -ScriptBlock { param($sp, $items, $dest) . $sp; Install-PlanModules -Items $items -Destination $dest } -ArgumentList $mpPath, @($plan.NeedsInstall), $mods
			if (Wait-Job $job -Timeout 300) { $dl = Receive-Job $job } else { Stop-Job $job -ErrorAction SilentlyContinue; Write-Host 'Download timed out after 5 minutes.' }
			Remove-Job $job -Force -ErrorAction SilentlyContinue
		} else {
			$dl = Install-PlanModules -Items @($plan.NeedsInstall) -Destination $mods -Log { param($m) Write-Host $m }
		}
		$dlText = @()
		if ($dl) {
			if (@($dl.Installed).Count) { $dlText += "Downloaded: " + (@($dl.Installed) -join ', ') }
			if (@($dl.Failed).Count)    { $dlText += "Download failed: " + (@($dl.Failed) -join '; ') }
			if ($dl.NetworkError)       { $dlText += (Get-GalleryHelpText) }
		} else { $dlText += 'Download timed out after 5 minutes.' }
		if ($dlText.Count) { Set-Content -LiteralPath (Join-Path $root 'download.txt') -Value ($dlText -join "`n") -Encoding UTF8 }
	}
	$exe = (Get-Process -Id $PID).Path
	# Quote paths: Start-Process -ArgumentList joins with spaces and does NOT quote, so a spaced path breaks.
	$childArgs = @('-NoProfile', '-NonInteractive', '-File', ('"' + $PSCommandPath + '"'), '-Inner', '-Root', ('"' + $root + '"'), '-OutFile', ('"' + $OutFile + '"'))
	if ($ExcludeAllUsers) { $childArgs += '-ExcludeAllUsers' }
	$proc = Start-Process $exe -ArgumentList $childArgs -PassThru -NoNewWindow
	if (-not $proc.WaitForExit(300000)) { try { $proc.Kill($true) } catch {}; Write-Host 'Self-test timed out after 5 minutes.'; $code = 2 } else { $code = $proc.ExitCode }
	# Guarded cleanup - only a folder we created, under TEMP, with our name pattern, not under MyDocuments.
	try {
		$full = [IO.Path]::GetFullPath($root); $tmp = [IO.Path]::GetFullPath($env:TEMP)
		$docs = [Environment]::GetFolderPath('MyDocuments'); $leaf = Split-Path $root -Leaf
		$underDocs = $false; if ($docs) { $underDocs = $full.StartsWith([IO.Path]::GetFullPath($docs), [System.StringComparison]::OrdinalIgnoreCase) }
		$okDel = $root -and $full.StartsWith($tmp, [System.StringComparison]::OrdinalIgnoreCase) -and ($leaf -match '^SPS-SelfTest-\d{8}-\d{6}-[0-9a-f]{8}$') -and (-not $underDocs)
		if ($okDel) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
		if (Test-Path -LiteralPath $root) { Write-Host "leftover temp folder: $root" }
	} catch {}
	Write-Host "Report: $OutFile"
	exit $code
}

# ============ INNER (child): load in isolation, run checks, write the report ============
$results = [System.Collections.Generic.List[string]]::new()
$info = [System.Collections.Generic.List[string]]::new()
$pass = $true
$mods = Join-Path $Root 'Modules'
$allUsers = @(); if (-not $ExcludeAllUsers) { $allUsers = Get-AllUsersRoots }
$iso = (@($mods) + $allUsers + (Join-Path $PSHOME 'Modules')) -join [IO.Path]::PathSeparator
$env:PSModulePath = $iso                                   # AFTER startup, inside the child
foreach ($c in 'Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Management', 'Microsoft.PowerShell.Security') {
	try { Import-Module (Join-Path $PSHOME "Modules\$c\$c.psd1") -Global -ErrorAction Stop } catch {}
}
$PSModuleAutoloadingPreference = 'None'
. (Join-Path $PSScriptRoot 'modulepins.ps1')

# Build a FORCED-pin plan from what's under the roots, so the child always loads explicit versions.
$roots2 = @($mods) + $allUsers
$plan = Resolve-ModulePlan -Roots $roots2
foreach ($cand in (@("$($script:GraphInstallDefault)") + @(Get-InstalledModuleVersions 'Microsoft.Graph.Authentication' -Roots $roots2 | Select-Object -ExpandProperty Version | Sort-Object -Descending | ForEach-Object { "$_" }))) {
	$ok = $true; $mans = @{}
	foreach ($gm in $script:GraphModuleNames) { $iv = @(Get-InstalledModuleVersions $gm -Roots $roots2 | Where-Object { "$($_.Version)" -eq $cand }); if (-not $iv.Count) { $ok = $false; break }; $mans[$gm] = $iv[0].ManifestPath }
	if ($ok) { $plan.GraphMode = 'pin'; $plan.Graph = [version]$cand; $plan.GraphManifests = $mans; break }
}
foreach ($cand in (@("$($plan.Exo)") + @(Get-InstalledModuleVersions 'ExchangeOnlineManagement' -Roots $roots2 | Select-Object -ExpandProperty Version | Sort-Object -Descending | ForEach-Object { "$_" }))) {
	if (-not $cand -or (Test-ExoBrokenHere ([version]$cand) $PSVersionTable.PSVersion)) { continue }
	$iv = @(Get-InstalledModuleVersions 'ExchangeOnlineManagement' -Roots $roots2 | Where-Object { "$($_.Version)" -eq "$cand" })
	if (-not $iv.Count) { continue }
	$dll = Join-Path (Split-Path $iv[0].ManifestPath -Parent) 'netCore\Microsoft.Exchange.Management.ExoPowershellGalleryModule.dll'
	if (-not (Test-Path -LiteralPath $dll)) { continue }
	$plan.ExoMode = 'pin'; $plan.Exo = [version]$cand; $plan.ExoManifest = $iv[0].ManifestPath; break
}

$imp = Import-ModulePlan -Plan $plan -ByPath -IsolatedPath $iso -Log { param($m) $info.Add("load: $m") }
if (-not $imp.Ok) { $info.Add("load step: $($imp.Step) - $($imp.Error)") }

# ---- CHECK 1: isolation ----
# $PSHOME itself (not only $PSHOME\Modules): Store-packaged pwsh reports built-in modules under $PSHOME.
$okRoots = @([IO.Path]::GetFullPath($Root)) + @($allUsers | ForEach-Object { [IO.Path]::GetFullPath($_) }) + @([IO.Path]::GetFullPath($PSHOME))
$isoOk = $true
foreach ($m in @(Get-Module)) {
	$base = [IO.Path]::GetFullPath("$($m.ModuleBase)")
	if (-not (@($okRoots | Where-Object { $base.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) }).Count)) { $isoOk = $false; $info.Add("outside module: $($m.Name) $($m.Version) @ $base") }
}
if ($isoOk) { $results.Add('PASS isolation (no module loaded from outside the temp / AllUsers / built-in)') } else { $results.Add('FAIL isolation'); $pass = $false }

# ---- CHECK 2: commands via ExportedCommands (not Get-Command) ----
$exported = @{}
foreach ($m in @(Get-Module)) { foreach ($k in $m.ExportedCommands.Keys) { $exported[$k] = $true } }
foreach ($w in 'Connect-MgGraph', 'Get-MgUser', 'Set-MgUserLicense', 'Reset-MgUserAuthenticationMethodPassword', 'Get-MgGroup', 'Connect-ExchangeOnline', 'Get-EXOMailbox') {
	if ($exported.ContainsKey($w)) { $results.Add("PASS command $w") } else { $results.Add("FAIL command $w"); $pass = $false }
}
if ($exported.ContainsKey('Remove-MgUserAuthenticationWindowsHelloForBusinessMethod') -or $exported.ContainsKey('Remove-MgUserAuthenticationWindowHelloForBusinessMethod')) { $results.Add('PASS command Remove-MgUserAuthentication(Window|Windows)HelloForBusinessMethod') } else { $results.Add('FAIL command WindowsHello remove'); $pass = $false }

# ---- CHECK 3: Exchange -DisableWAM ----
$exoMod = Get-Module ExchangeOnlineManagement | Sort-Object Version -Descending | Select-Object -First 1
if ($exoMod) {
	$v = $exoMod.Version
	$hasWam = $false; try { $hasWam = [bool]($exoMod.ExportedCommands['Connect-ExchangeOnline'].Parameters.ContainsKey('DisableWAM')) } catch {}
	$expectWam = ($v -ge [version]'3.7.2')
	$notBad = -not ($v -eq [version]'3.7.0' -or $v -eq [version]'3.7.1')
	if (($hasWam -eq $expectWam) -and $notBad) { $results.Add("PASS Exchange -DisableWAM ($v)") } else { $results.Add("FAIL Exchange -DisableWAM ($v hasWam=$hasWam)"); $pass = $false }
} else { $results.Add('FAIL Exchange module not loaded'); $pass = $false }

# ---- information only (never a failure; never connect/disconnect) ----
try { $dlf = Join-Path $Root 'download.txt'; if (Test-Path -LiteralPath $dlf) { foreach ($line in @(Get-Content -LiteralPath $dlf)) { if ("$line".Trim()) { $info.Add("download: $line") } } } } catch {}
try { foreach ($a in [System.AppDomain]::CurrentDomain.GetAssemblies()) { $n = $a.GetName().Name; if ($n -eq 'Microsoft.Identity.Client' -or $n -eq 'System.IdentityModel.Tokens.Jwt') { $info.Add("info: $n $($a.GetName().Version)") } } } catch {}
$info.Add("info: Jwt 5.6 with Graph 1.x is normal; it only matters for certificate or access-token Exchange sign-in, which SPS doesn't use.")

# ---- report ----
$report = [System.Text.StringBuilder]::new()
[void]$report.AppendLine($Root)
[void]$report.AppendLine("SelfTest $(if ($pass) { 'PASS' } else { 'FAIL' }) - $(Get-Date -Format o)")
foreach ($r in $results) { [void]$report.AppendLine($r) }
[void]$report.AppendLine('')
[void]$report.AppendLine("Plan: Graph $($plan.Graph) ($($plan.GraphMode)) / Exchange $($plan.Exo) ($($plan.ExoMode))")
foreach ($i in $info) { [void]$report.AppendLine($i) }
[void]$report.AppendLine('')
try { [void]$report.AppendLine((Get-ModuleDiagnostics -Plan $plan)) } catch { [void]$report.AppendLine("diagnostics error: $($_.Exception.Message)") }
$text = Protect-DiagText ($report.ToString())
if (-not $OutFile) { $OutFile = Join-Path $Root 'selftest-report.txt' }
try { Set-Content -LiteralPath $OutFile -Value $text -Encoding UTF8 } catch {}
if ($pass) { exit 0 } else { exit 1 }
