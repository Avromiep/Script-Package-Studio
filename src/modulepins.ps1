# modulepins.ps1 - module version planning, loading, install and diagnostics.
# NO WPF, Show-Notice or Set-ItemStatus here: this file is shared by the app AND the isolated
# self-test. It logs through an optional -Log scriptblock and returns objects.

# ======================= PINNED MODULE VERSIONS (edit ONLY here) =======================
# Graph: all six Microsoft.Graph.* modules must be the SAME version. Used ONLY when the Graph that PowerShell
# would autoload is 2.34+ (forced Windows pop-up). Otherwise the app loads Graph exactly as v3.4.2 did.
$script:GraphModuleNames = @('Microsoft.Graph.Authentication','Microsoft.Graph.Users','Microsoft.Graph.Users.Actions',
	'Microsoft.Graph.Groups','Microsoft.Graph.Identity.SignIns','Microsoft.Graph.Identity.DirectoryManagement')
$script:GraphPinCandidates = @('1.23.0', '2.33.0')   # best first; 2.33.0 only if already installed (last 2.x with browser sign-in by default)
$script:GraphWamFrom = [version]'2.34.0'
# Exchange candidates per PowerShell (pwsh) major.minor, best first. Support per Microsoft Learn
# (exchange-online-powershell-v2): 3.10.0+ needs 7.6+, 3.5.0-3.9.2 need 7.4+, 3.0.0-3.4.0 need 7.2+.
# NEVER list 3.7.0 or 3.7.1 (WAM forced on, no -DisableWAM). 3.7.2+ is fine: Connect-Exo passes -DisableWAM (browser sign-in).
$script:ExoCompat = [ordered]@{
	'7.2' = @('3.4.0','3.1.0','3.0.0')
	'7.3' = @('3.4.0','3.1.0','3.0.0')
	'7.4' = @('3.9.2','3.1.0','3.0.0','3.4.0','3.5.0','3.6.0')
	'7.5' = @('3.9.2','3.1.0','3.0.0','3.4.0','3.5.0','3.6.0')
	'7.6' = @('3.10.1','3.9.2','3.1.0','3.0.0','3.4.0','3.5.0','3.6.0')
}
# What the Install button installs, per row (newest supported). An ALREADY-installed working Exchange is used as-is (office PC / Albert: 3.1.0 = no prompt).
$script:ExoInstallDefault = [ordered]@{ '7.2'='3.4.0'; '7.3'='3.4.0'; '7.4'='3.9.2'; '7.5'='3.9.2'; '7.6'='3.10.1' }
$script:GraphInstallDefault = '1.23.0'
# =======================================================================================

# "<major>.<minor>" of the running pwsh, e.g. '7.6'.
function Get-PwshRowKey { '{0}.{1}' -f $PSVersionTable.PSVersion.Major, $PSVersionTable.PSVersion.Minor }

# List installed versions of a module WITHOUT importing anything. Without -Roots: Get-Module
# -ListAvailable. With -Roots: read <root>\<Name>\<ver>\<Name>.psd1 directly. Returns Version,
# ManifestPath, ModuleBase, Scope (CurrentUser / AllUsers / Built-in / Other), sorted by version.
# Read a module manifest's ModuleVersion by PARSING ONLY (never runs the .psd1 - real EXO manifests
# have if($PSEdition...) code that the built-in data-file loader runs and throws on, polluting $Error). Never throws.
function Get-ManifestVersion([string]$Path) {
	$tok = $null; $perr = $null
	try { $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tok, [ref]$perr) } catch { return $null }
	$h = $ast.Find({ param($a) $a -is [System.Management.Automation.Language.HashtableAst] }, $false)
	if (-not $h) { return $null }
	foreach ($kv in $h.KeyValuePairs) {
		if ("$($kv.Item1.Value)" -eq 'ModuleVersion') {
			$s = $kv.Item2.Find({ param($a) $a -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
			$v = $null; if ($s -and [version]::TryParse($s.Value, [ref]$v)) { return $v }
		}
	}
	return $null
}

function Get-InstalledModuleVersions([string]$Name, [string[]]$Roots) {
	$errN = $Error.Count
	try {
	$docs = $null; try { $docs = [Environment]::GetFolderPath('MyDocuments') } catch {}
	$cuPwsh = $null; $cuWin = $null; $puPwsh = $null; $puWin = $null; $home2 = $null
	if ($docs)             { $cuPwsh = Join-Path $docs 'PowerShell\Modules'; $cuWin = Join-Path $docs 'WindowsPowerShell\Modules' }
	if ($env:ProgramFiles) { $puPwsh = Join-Path $env:ProgramFiles 'PowerShell\Modules'; $puWin = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules' }
	if ($PSHOME)           { $home2 = Join-Path $PSHOME 'Modules' }
	$starts = {
		param([string]$base, [string]$dir)
		($dir -and $base -and $base.StartsWith($dir, [System.StringComparison]::OrdinalIgnoreCase))
	}
	$classify = {
		param([string]$base)
		if ((& $starts $base $cuPwsh) -or (& $starts $base $cuWin)) { return 'CurrentUser' }
		if ((& $starts $base $puPwsh) -or (& $starts $base $puWin)) { return 'AllUsers' }
		if (& $starts $base $home2) { return 'Built-in' }
		return 'Other'
	}
	$out = [System.Collections.Generic.List[object]]::new()
	if ($Roots) {
		foreach ($root in $Roots) {
			if (-not $root) { continue }
			$dir = Join-Path $root $Name
			if (-not (Test-Path -LiteralPath $dir)) { continue }
			foreach ($vdir in @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue)) {
				$manifest = Join-Path $vdir.FullName "$Name.psd1"
				if (-not (Test-Path -LiteralPath $manifest)) { continue }
				$ver = $null; [void][version]::TryParse("$($vdir.Name)", [ref]$ver)
				if (-not $ver) { continue }
				$out.Add([pscustomobject]@{ Version = $ver; ManifestPath = $manifest; ModuleBase = $vdir.FullName; Scope = (& $classify $vdir.FullName) })
			}
		}
	} else {
		foreach ($m in @(Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue)) {
			$base = "$($m.ModuleBase)"
			$out.Add([pscustomobject]@{ Version = [version]$m.Version; ManifestPath = (Join-Path $base "$Name.psd1"); ModuleBase = $base; Scope = (& $classify $base) })
		}
	}
	return @($out | Sort-Object Version)
	} finally { while ($Error.Count -gt $errN) { $Error.RemoveAt(0) } }
}

# What PowerShell autoload would REALLY load for $Name. PowerShell does NOT pick the newest version
# installed: it stops at the FIRST $env:PSModulePath folder (or the first -Roots entry) that contains
# the module, and loads the highest version in THAT folder. On Windows the user's Documents folder
# comes before Program Files, so the version there wins even if Program Files has a newer one.
# A version folder whose .psd1 ModuleVersion doesn't match its folder name is skipped (PowerShell
# skips it too). An unversioned <Name>\<Name>.psd1 is read for its ModuleVersion. Returns
# { Version; ManifestPath; Folder } or $null. Never imports.
# NOTE: command autoload actually finds the first module that EXPORTS the command, so a newer version
# in a later folder can still load for a 2.x-only Graph command name - which is why the app never
# Get-Commands those and uses Test-LoadedGraphCommand. But every Authentication / ExchangeOnlineManagement
# version exports Connect-MgGraph / Connect-ExchangeOnline, so "first folder, highest in it" is exact here.
function Get-AutoloadVersion([string]$Name, [string[]]$Roots) {
	$errN = $Error.Count
	try {
	$folders = if ($Roots) { @($Roots) } else { @("$env:PSModulePath" -split [IO.Path]::PathSeparator) }
	foreach ($folder in $folders) {
		if (-not $folder) { continue }
		$dir = Join-Path $folder $Name
		if (-not (Test-Path -LiteralPath $dir)) { continue }
		$best = $null
		foreach ($vdir in @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue)) {
			$manifest = Join-Path $vdir.FullName "$Name.psd1"
			if (-not (Test-Path -LiteralPath $manifest)) { continue }
			$fv = $null; [void][version]::TryParse("$($vdir.Name)", [ref]$fv)
			if (-not $fv) { continue }
			$mv = Get-ManifestVersion $manifest
			if ($mv -and "$mv" -ne "$fv") { continue }   # PowerShell skips a folder whose manifest version mismatches
			if (-not $best -or $fv -gt $best.Version) { $best = [pscustomobject]@{ Version = $fv; ManifestPath = $manifest; Folder = $folder } }
		}
		if (-not $best) {
			$flat = Join-Path $dir "$Name.psd1"
			if (Test-Path -LiteralPath $flat) {
				$mv = Get-ManifestVersion $flat
				if ($mv) { $best = [pscustomobject]@{ Version = $mv; ManifestPath = $flat; Folder = $folder } }
			}
		}
		if ($best) { return $best }   # first folder that has the module wins
	}
	return $null
	} finally { while ($Error.Count -gt $errN) { $Error.RemoveAt(0) } }
}

# True ONLY for Exchange + pwsh combinations KNOWN to fail. Everything else is left alone (it may
# be working today even if Microsoft doesn't officially support it).
function Test-ExoBrokenHere([version]$v, [version]$ps) {
	if (-not $v) { return $false }
	if (-not $ps) { $ps = $PSVersionTable.PSVersion }
	if ($v -eq [version]'3.7.0' -or $v -eq [version]'3.7.1') { return $true }   # WAM forced, no -DisableWAM
	if ($ps -lt [version]'7.4'   -and $v -ge [version]'3.5.1')  { return $true }   # .NET 8 build
	if ($ps -lt [version]'7.4.6' -and $v -ge [version]'3.10.0') { return $true }   # SMA 7.4.6.500
	return $false
}

# Read the user's "known bad" version list (set by Import-ModulePlan after a failed import). Safe
# when $script:Settings doesn't exist (e.g. the isolated self-test).
function Get-BadModuleVersions {
	try { if ($script:Settings -and $script:Settings.badModuleVersions) { return @($script:Settings.badModuleVersions | ForEach-Object { "$_" }) } } catch {}
	return @()
}
function Add-BadModuleVersion([string]$NameVersion) {
	try {
		if (-not $script:Settings) { return }
		$cur = Get-BadModuleVersions
		if ($NameVersion -notin $cur) { $cur = @($cur) + $NameVersion; $script:Settings.badModuleVersions = $cur }
		if (Get-Command Save-AppSettings -ErrorAction Ignore) { Save-AppSettings }
	} catch {}
}

# Decide what to load, from the version autoload would REALLY load (first folder, not newest). Pure.
# $PSVersion is for dry-runs only; the app never passes it.
function Resolve-ModulePlan {
	param([string[]]$Roots, [version]$PSVersion)
	$errN = $Error.Count
	try {
	$ps = if ($PSVersion) { $PSVersion } else { $PSVersionTable.PSVersion }
	$rowKey = '{0}.{1}' -f $ps.Major, $ps.Minor
	if ($ps.Major -eq 7 -and $ps.Minor -ge 7) { $rowKey = '7.6' }   # 7.7+ uses the 7.6 row
	$bad = @(Get-BadModuleVersions)
	$attempts = [System.Collections.Generic.List[string]]::new()

	# ---- Graph ----
	$authInstalled = @(Get-InstalledModuleVersions 'Microsoft.Graph.Authentication' -Roots $Roots)
	$graphNewest = if ($authInstalled.Count) { ($authInstalled | Select-Object -Last 1).Version } else { $null }
	$graphAuto = Get-AutoloadVersion 'Microsoft.Graph.Authentication' -Roots $Roots   # what v3.4.2 really loads
	$graphDefaultBad = @($script:GraphModuleNames | Where-Object { "$_=$($script:GraphInstallDefault)" -in $bad }).Count -gt 0
	$graphMode = 'missing'; $graphVer = $null; $graphManifests = @{}
	if ($graphAuto) {
		if ($graphAuto.Version -lt $script:GraphWamFrom) {
			$graphMode = 'asToday'; $graphVer = $graphAuto.Version    # exactly the version v3.4.2 loads
		} else {
			$graphMode = 'needsRevert'
			foreach ($cand in $script:GraphPinCandidates) {
				if (@($script:GraphModuleNames | Where-Object { "$_=$cand" -in $bad }).Count) { continue }   # any submodule marked bad
				$ok = $true; $mans = @{}
				foreach ($gm in $script:GraphModuleNames) {
					$iv = @(Get-InstalledModuleVersions $gm -Roots $Roots | Where-Object { "$($_.Version)" -eq $cand })
					if (-not $iv.Count) { $ok = $false; break }
					$mans[$gm] = $iv[0].ManifestPath
				}
				if ($ok) { $graphMode = 'pin'; $graphVer = [version]$cand; $graphManifests = $mans; break }
			}
			if ($graphMode -eq 'needsRevert' -and $graphDefaultBad) { $graphMode = 'blocked'; $attempts.Add("Graph $($script:GraphInstallDefault) is on the failed-version list - no offer until cleared.") }
		}
	}

	# ---- Exchange ----
	$exoInstalled = @(Get-InstalledModuleVersions 'ExchangeOnlineManagement' -Roots $Roots)
	$exoNewest = if ($exoInstalled.Count) { ($exoInstalled | Select-Object -Last 1).Version } else { $null }
	$exoAuto = Get-AutoloadVersion 'ExchangeOnlineManagement' -Roots $Roots
	$exoDefault = if ($script:ExoInstallDefault.Contains($rowKey)) { $script:ExoInstallDefault[$rowKey] } else { $null }
	$exoMode = 'missing'; $exoVer = $null; $exoManifest = $null
	if ($exoAuto) {
		if (-not (Test-ExoBrokenHere $exoAuto.Version $ps)) {
			$exoMode = 'asToday'; $exoVer = $exoAuto.Version        # exactly the version v3.4.2 loads
		} else {
			$exoMode = 'needsInstall'
			$cands = @(); if ($script:ExoCompat.Contains($rowKey)) { $cands = @($script:ExoCompat[$rowKey]) }
			foreach ($cand in $cands) {
				if ("ExchangeOnlineManagement=$cand" -in $bad) { continue }
				if (Test-ExoBrokenHere ([version]$cand) $ps) { continue }
				$iv = @($exoInstalled | Where-Object { "$($_.Version)" -eq $cand })
				if (-not $iv.Count) { continue }
				$man = $iv[0].ManifestPath
				$dll = Join-Path (Split-Path $man -Parent) 'netCore\Microsoft.Exchange.Management.ExoPowershellGalleryModule.dll'
				if (-not (Test-Path -LiteralPath $dll)) { continue }
				$exoMode = 'pin'; $exoVer = [version]$cand; $exoManifest = $man; break
			}
			if ($exoMode -eq 'needsInstall' -and (-not $exoDefault -or "ExchangeOnlineManagement=$exoDefault" -in $bad)) { $exoMode = 'blocked'; $attempts.Add("Exchange install default is missing or on the failed-version list - no offer until cleared.") }
		}
	}

	# ---- NeedsInstall (row defaults; never a version on the failed list) ----
	$needsInstall = [System.Collections.Generic.List[object]]::new()
	if (($graphMode -eq 'missing' -or $graphMode -eq 'needsRevert') -and -not $graphDefaultBad) {
		foreach ($gm in $script:GraphModuleNames) { [void]$needsInstall.Add([pscustomobject]@{ Name = $gm; Version = $script:GraphInstallDefault }) }
	}
	if ($exoMode -eq 'missing' -or $exoMode -eq 'needsInstall') {
		if ($exoDefault -and ("ExchangeOnlineManagement=$exoDefault" -notin $bad)) { [void]$needsInstall.Add([pscustomobject]@{ Name = 'ExchangeOnlineManagement'; Version = $exoDefault }) }
	}

	return [pscustomobject]@{
		PwshRow        = $rowKey
		GraphMode      = $graphMode
		Graph          = $graphVer
		GraphNewest    = $graphNewest
		GraphAutoload  = $(if ($graphAuto) { $graphAuto.Version } else { $null })   # what autoload would load (the problematic 2.x one on needsRevert)
		GraphManifests = $graphManifests
		ExoMode        = $exoMode
		Exo            = $exoVer
		ExoNewest      = $exoNewest
		ExoAutoload    = $(if ($exoAuto) { $exoAuto.Version } else { $null })
		ExoManifest    = $exoManifest
		NeedsInstall   = @($needsInstall)
		Attempts       = @($attempts)
		Bad            = @($bad)
	}
	} finally { while ($Error.Count -gt $errN) { $Error.RemoveAt(0) } }
}

# Should the Graph "switch to browser sign-in" offer be shown? Only when the plan says needsRevert
# and the user hasn't already declined THIS autoload Graph version. Pure (dry-run 5 calls it).
function Test-ShouldOfferGraphRevert($Plan, [string]$Declined) {
	if (-not $Plan) { return $false }
	if ($Plan.GraphMode -ne 'needsRevert') { return $false }
	if ($Declined -and "$Declined" -eq "$($Plan.GraphAutoload)") { return $false }
	return $true
}

# Load the plan. Graph first (Authentication first), then Exchange - exactly v3.4.2's order. Imports
# each module ONCE (E3): on failure, records the bad version and returns Step='restart'. No Jwt
# preload or gate. No wholesale clearing of the error list.
function Import-ModulePlan {
	param($Plan, [switch]$ByPath, [string]$IsolatedPath, [scriptblock]$Log)
	$emitLog = $Log; $log = { param($m) if ($emitLog) { & $emitLog $m } }   # NOT if($Log): $log IS $Log (case-insensitive) -> infinite recursion
	$loaded = [System.Collections.Generic.List[string]]::new()
	if ($Plan.GraphMode -eq 'pin') {
		$la = Get-Module -Name 'Microsoft.Graph.Authentication' | Sort-Object Version -Descending | Select-Object -First 1
		if ($la -and "$($la.Version)" -ne "$($Plan.Graph)") {
			& $log "A different Microsoft Graph ($($la.Version)) is already loaded; restart needed to load $($Plan.Graph)."
			return [pscustomobject]@{ Ok = $false; Step = 'restart'; Error = "Graph $($la.Version) already loaded"; Loaded = @($loaded) }
		}
		foreach ($gm in $script:GraphModuleNames) {
			$already = Get-Module -Name $gm | Where-Object { "$($_.Version)" -eq "$($Plan.Graph)" } | Select-Object -First 1
			if ($already) { $loaded.Add("$gm $($Plan.Graph)"); continue }
			try {
				if ($ByPath -and $Plan.GraphManifests -and $Plan.GraphManifests[$gm]) { Import-Module -Name $Plan.GraphManifests[$gm] -Global -ErrorAction Stop -WarningAction SilentlyContinue }
				else { Import-Module -Name $gm -RequiredVersion "$($Plan.Graph)" -Global -ErrorAction Stop -WarningAction SilentlyContinue }
				$loaded.Add("$gm $($Plan.Graph)")
				if ($IsolatedPath) { $env:PSModulePath = $IsolatedPath }
			} catch {
				$msg = "$($_.Exception.Message)"
				& $log "Couldn't load $gm $($Plan.Graph): $msg"
				Add-BadModuleVersion "$gm=$($Plan.Graph)"
				Add-BadModuleVersion "Microsoft.Graph.Authentication=$($Plan.Graph)"   # the key for the whole set
				return [pscustomobject]@{ Ok = $false; Step = 'restart'; Error = "$gm $($Plan.Graph): $msg"; Loaded = @($loaded) }
			}
		}
	}
	if ($Plan.ExoMode -eq 'pin') {
		$le = Get-Module -Name 'ExchangeOnlineManagement' | Sort-Object Version -Descending | Select-Object -First 1
		if ($le -and "$($le.Version)" -ne "$($Plan.Exo)") {
			& $log "A different Exchange ($($le.Version)) is already loaded; restart needed to load $($Plan.Exo)."
			return [pscustomobject]@{ Ok = $false; Step = 'restart'; Error = "Exchange $($le.Version) already loaded"; Loaded = @($loaded) }
		}
		$already = Get-Module -Name 'ExchangeOnlineManagement' | Where-Object { "$($_.Version)" -eq "$($Plan.Exo)" } | Select-Object -First 1
		if ($already) { $loaded.Add("ExchangeOnlineManagement $($Plan.Exo)") }
		else {
			try {
				if ($ByPath -and $Plan.ExoManifest) { Import-Module -Name $Plan.ExoManifest -Global -ErrorAction Stop -WarningAction SilentlyContinue }
				else { Import-Module -Name 'ExchangeOnlineManagement' -RequiredVersion "$($Plan.Exo)" -Global -ErrorAction Stop -WarningAction SilentlyContinue }
				$loaded.Add("ExchangeOnlineManagement $($Plan.Exo)")
				if ($IsolatedPath) { $env:PSModulePath = $IsolatedPath }
			} catch {
				$msg = "$($_.Exception.Message)"
				& $log "Couldn't load ExchangeOnlineManagement $($Plan.Exo): $msg"
				if ($msg -notmatch 'already loaded') { Add-BadModuleVersion "ExchangeOnlineManagement=$($Plan.Exo)" }
				return [pscustomobject]@{ Ok = $false; Step = 'restart'; Error = "ExchangeOnlineManagement $($Plan.Exo): $msg"; Loaded = @($loaded) }
			}
		}
	}
	return [pscustomobject]@{ Ok = $true; Step = 'ok'; Error = $null; Loaded = @($loaded) }
}

# Does the running process have a given Graph command, WITHOUT importing anything? If the submodule
# isn't loaded yet, decide by the loaded/newest Authentication major (2.x has the WindowsHello /
# PlatformCredential names; 1.x doesn't).
function Test-LoadedGraphCommand([string]$Name) {
	$errN = $Error.Count
	try {
	foreach ($m in @(Get-Module -Name 'Microsoft.Graph.*')) {
		try { if ($m.ExportedCommands.ContainsKey($Name)) { return $true } } catch {}
	}
	$authMajor = $null
	$la = Get-Module -Name 'Microsoft.Graph.Authentication' | Sort-Object Version -Descending | Select-Object -First 1
	if ($la) { $authMajor = $la.Version.Major }
	else { $auto = Get-AutoloadVersion 'Microsoft.Graph.Authentication'; if ($auto) { $authMajor = $auto.Version.Major } }   # the version autoload would load, not the newest
	if ($null -eq $authMajor) { return $false }
	return ($authMajor -ge 2)
	} finally { while ($Error.Count -gt $errN) { $Error.RemoveAt(0) } }
}

# Make the PowerShell Gallery reachable for THIS process only. No admin, nothing machine-wide.
function Initialize-GalleryAccessPlain([scriptblock]$Log) {
	$emitLog = $Log; $log = { param($m) if ($emitLog) { & $emitLog $m } }   # NOT if($Log): $log IS $Log (case-insensitive) -> infinite recursion
	try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
	try { [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials } catch {}
	try {
		$nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
		if (-not $nuget -or $nuget.Version -lt [version]'2.8.5.201') { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -ErrorAction Stop | Out-Null }
	} catch { & $log "NuGet provider: $($_.Exception.Message)" }
	try {
		$psg = Get-Module PowerShellGet -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
		if ($psg -and $psg.Version -lt [version]'2.2.5') {
			$have = Get-Module PowerShellGet -ListAvailable | Where-Object { $_.Version -ge [version]'2.2.5' } | Select-Object -First 1
			if ($have) { Import-Module PowerShellGet -MinimumVersion 2.2.5 -Global -ErrorAction SilentlyContinue }
		}
	} catch {}
}

# ---- Verified staged install (v3.4.5) ---------------------------------------------------------
# Graph 1.23.0 ships unsigned .psd1 files and no .cat. PowerShellGet 2.2.5 refuses to install it when a
# Microsoft-signed Graph (2.x) is already installed anywhere ("is not catalog signed ... use the
# publisher-check bypass"). For SPS's pinned Graph set ONLY, and ONLY after that exact error, we
# Save-Module to a temp stage, verify it ourselves, then copy it into the CurrentUser module folder.
# Never bypass the publisher check, never overwrite or remove an existing version folder.
function Test-StagedInstallAllowed([string]$Name, [string]$Version) {
	return (($script:GraphModuleNames -contains $Name) -and ("$Version" -eq "$script:GraphInstallDefault"))
}
# The folder Install-Module -Scope CurrentUser uses (Documents\PowerShell\Modules on Windows, OneDrive-redirected too).
function Get-CurrentUserModulesPath {
	$p = $null
	try { $m = Get-Module PowerShellGet | Sort-Object Version -Descending | Select-Object -First 1; if ($m) { $p = & $m { $script:MyDocumentsModulesPath } } } catch {}
	if (-not $p) {
		$docs = $null; try { $docs = [Environment]::GetFolderPath('MyDocuments') } catch {}
		if ($docs) { $p = Join-Path $docs 'PowerShell\Modules' } elseif ($HOME) { $p = Join-Path $HOME 'Documents\PowerShell\Modules' }
	}
	return $p
}
# RequiredModules (ModuleName=RequiredVersion) of a manifest, read by parsing only.
function Get-ManifestRequiredModules([string]$Path) {
	$out = @()
	try {
		$ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
		$h = $ast.Find({ param($a) $a -is [System.Management.Automation.Language.HashtableAst] }, $false)
		foreach ($kv in @($h.KeyValuePairs)) {
			if ("$($kv.Item1.Value)" -ne 'RequiredModules') { continue }
			foreach ($rh in @($kv.Item2.FindAll({ param($a) $a -is [System.Management.Automation.Language.HashtableAst] }, $true))) {
				$n = ''; $v = ''
				foreach ($p in $rh.KeyValuePairs) {
					$val = $p.Item2.Find({ param($a) $a -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
					if ("$($p.Item1.Value)" -eq 'ModuleName') { $n = "$($val.Value)" }
					if ("$($p.Item1.Value)" -eq 'RequiredVersion') { $v = "$($val.Value)" }
				}
				if ($n) { $out += "$n=$v" }
			}
		}
	} catch {}
	return @($out)
}
# (v3.4.6) SHA-256 of the Graph 1.23.0 files that ship UNSIGNED (keyed "<ModuleName>\<file name>"). A NotSigned
# file in the staged set is only accepted when its hash is here; any other unsigned file is rejected. Some of
# these are actually signed (Valid) on Windows - that's fine, they're just never consulted then.
$script:StagedUnsignedSha256 = @{
	'Microsoft.Graph.Authentication\Microsoft.Graph.Authentication.psd1'                            = 'AC45B307B74A85FD790C78E2E7A9431E53AE8BD10698C46B59B5F2E0E10EF5FD'
	'Microsoft.Graph.Authentication\Microsoft.Graph.Authentication.format.ps1xml'                   = '1E984FE3FE08D217FE3196BFB2B3108E49D347452AB8803E0A3A052994FA2FA2'
	'Microsoft.Graph.Authentication\Microsoft.Graph.Authentication.psm1'                            = '7EDBA25BB93F69FD10B1A9B2B5735D4E2564284F38DEDD98EA4AA2997C895B65'
	'Microsoft.Graph.Groups\Microsoft.Graph.Groups.psd1'                                            = 'D6DCF42411C589BD72B6827E77E52C4E294B214186852896DB74F008D65EC8F1'
	'Microsoft.Graph.Groups\Microsoft.Graph.Groups.format.ps1xml'                                   = '025B6E83B6A4581E4A589ADB7BBF77E74D37EC0DD610A45DDC660ADEB800E988'
	'Microsoft.Graph.Identity.DirectoryManagement\Microsoft.Graph.Identity.DirectoryManagement.psd1'          = '9AD1C85B59D039AC8014BE9497FC8B758B9AB99701EB8668818E3C11C5393611'
	'Microsoft.Graph.Identity.DirectoryManagement\Microsoft.Graph.Identity.DirectoryManagement.format.ps1xml' = '54E9B7419A979DE2BF93C033A808C34A810878D97780F65F8F0CB4ABC64C3F2C'
	'Microsoft.Graph.Identity.SignIns\Microsoft.Graph.Identity.SignIns.psd1'                        = '070854040A1D233D9AAAAAF063C743DF87B810CEA71CF07FA073548C57CFEA72'
	'Microsoft.Graph.Identity.SignIns\Microsoft.Graph.Identity.SignIns.format.ps1xml'               = '8849BE18931556D6701124CE905ED6E305BC78944E7F47BAB8E63C69B9EACA79'
	'Microsoft.Graph.Users\Microsoft.Graph.Users.psd1'                                              = 'E0AEB24051942ED6678A009CBD64A66879A50B4D1B2E5A91E31C82A2E6F2C976'
	'Microsoft.Graph.Users\Microsoft.Graph.Users.format.ps1xml'                                     = 'E2651EC4AC639E7B7DC1BB72812EE9B0B31D5646CCA115F019A92DBA32CA6608'
	'Microsoft.Graph.Users.Actions\Microsoft.Graph.Users.Actions.psd1'                              = 'CC22B8A0ECEF5B1C9D070A01CFF2C8082951C6DFE3A9DCDCB17E7938A24615FA'
	'Microsoft.Graph.Users.Actions\Microsoft.Graph.Users.Actions.format.ps1xml'                     = '53F5C7133D336E5919653D62423A9252E8351EEB6DB0A6ED058FBB7FC9AC8F8C'
}
# '' if $Cert chains to the Microsoft Root CA 2011 AND its Subject O= is exactly "Microsoft Corporation", else a
# reason. Build() can return false on a good file (the 1.23.0 signing cert is expired), so we ignore its result,
# ignore time validity, and only read the last chain element's thumbprint; Get-AuthenticodeSignature 'Valid'
# already proved trust via the timestamp. Any exception = not signed by Microsoft.
function Test-MicrosoftSigner($Cert) {
	try {
		if (-not $Cert) { return 'not signed by Microsoft (no signer certificate)' }
		$chain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
		$chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
		$chain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::IgnoreNotTimeValid
		[void]$chain.Build($Cert)
		$root = "$($chain.ChainElements[$chain.ChainElements.Count - 1].Certificate.Thumbprint)"
		if ($root -ne '8F43288AD272F3103B6FB1428485EA3014C0BCFE') { return "not signed by Microsoft (root $root)" }
		$o = ''
		$m = [regex]::Match("$($Cert.Subject)", '(?:^|,\s*)O=("[^"]+"|[^,]+)')
		if ($m.Success) { $o = $m.Groups[1].Value.Trim('"') }
		if ($o -ne 'Microsoft Corporation') { return "not signed by Microsoft (O=$o)" }
		return ''
	} catch { return "not signed by Microsoft ($($_.Exception.Message))" }
}
# Returns '' when the staged <Name>\<Version> folder is OK, otherwise the reason.
function Test-StagedModuleFolder([string]$Folder, [string]$Name, [string]$Version) {
	$psd1 = Join-Path $Folder "$Name.psd1"
	if (-not (Test-Path -LiteralPath $psd1)) { return 'manifest missing' }
	if ("$(Get-ManifestVersion $psd1)" -ne "$Version") { return 'manifest version mismatch' }
	$main = if ($Name -eq 'Microsoft.Graph.Authentication') { Join-Path $Folder 'Microsoft.Graph.Authentication.dll' } else { Join-Path (Join-Path $Folder 'bin') "$Name.private.dll" }
	if (-not (Test-Path -LiteralPath $main)) { return "main file missing ($(Split-Path $main -Leaf))" }
	$ms = Get-AuthenticodeSignature -FilePath $main
	if ("$($ms.Status)" -ne 'Valid') { return "main file not validly signed by Microsoft ($(Split-Path $main -Leaf): $($ms.Status))" }
	$sigWhy = Test-MicrosoftSigner $ms.SignerCertificate
	if ($sigWhy) { return "main file ($(Split-Path $main -Leaf)) $sigWhy" }
	foreach ($f in @(Get-ChildItem -LiteralPath $Folder -Recurse -File -ErrorAction Stop | Where-Object { $_.Extension -in '.dll','.psd1','.psm1','.ps1','.ps1xml' })) {
		$st = "$((Get-AuthenticodeSignature -FilePath $f.FullName).Status)"
		if ($st -eq 'Valid') { continue }
		if ($st -ne 'NotSigned') { return "$($f.Name): signature $st" }
		$want = $script:StagedUnsignedSha256["$Name\$($f.Name)"]
		if (-not $want) { return "$($f.Name): not signed and not on the allowed-unsigned list" }
		$have = "$((Get-FileHash -Algorithm SHA256 -LiteralPath $f.FullName).Hash)"
		if ($have -ne "$want") { return "$($f.Name): not signed and its contents don't match the known-good copy" }
	}
	if ($Name -ne 'Microsoft.Graph.Authentication') {
		if (@(Get-ManifestRequiredModules $psd1) -notcontains "Microsoft.Graph.Authentication=$Version") { return 'unexpected RequiredModules' }
	}
	return ''
}
function Install-StagedModule([string]$Name, [string]$Version, [scriptblock]$Log) {
	$say = $Log
	$stage = Join-Path ([IO.Path]::GetTempPath()) ('sps-stage-' + [guid]::NewGuid().ToString('N'))
	try {
		if (-not (Test-StagedInstallAllowed $Name $Version)) { return [pscustomobject]@{ Ok = $false; Reason = 'not on the pin list' } }
		New-Item -ItemType Directory -Path $stage -Force -ErrorAction Stop | Out-Null
		$sp = @{ Name = $Name; RequiredVersion = $Version; Path = $stage; Repository = 'PSGallery'; Force = $true; ErrorAction = 'Stop' }
		try { if ((Get-Command Save-Module).Parameters.ContainsKey('AcceptLicense')) { $sp.AcceptLicense = $true } } catch {}
		Save-Module @sp
		$dest = Get-CurrentUserModulesPath
		if (-not $dest) { return [pscustomobject]@{ Ok = $false; Reason = 'no CurrentUser module folder' } }
		foreach ($md in @(Get-ChildItem -LiteralPath $stage -Directory)) {
			$n = $md.Name
			$vdir = Join-Path $md.FullName $Version
			if (-not (Test-Path -LiteralPath $vdir)) { continue }
			if (-not (Test-StagedInstallAllowed $n $Version)) { if ($say) { & $say "Staged install: ignoring $n (not on the pin list)" }; continue }
			$target = Join-Path (Join-Path $dest $n) $Version
			if (Test-Path -LiteralPath $target) { continue }   # never overwrite an existing version folder
			$why = Test-StagedModuleFolder $vdir $n $Version
			if ($why) { return [pscustomobject]@{ Ok = $false; Reason = "$n ${Version} failed verification: $why" } }
			$partial = "$target.sps-partial"
			try {
				New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force -ErrorAction Stop | Out-Null
				if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Recurse -Force -ErrorAction Stop }
				Copy-Item -LiteralPath $vdir -Destination $partial -Recurse -Force -ErrorAction Stop
				$xml = Join-Path $partial 'PSGetModuleInfo.xml'
				if (Test-Path -LiteralPath $xml) {
					try {
						[IO.File]::SetAttributes($xml, [IO.FileAttributes]::Normal)
						$o = [System.Management.Automation.PSSerializer]::Deserialize([IO.File]::ReadAllText($xml))
						$o.InstalledLocation = $target
						[IO.File]::WriteAllText($xml, [System.Management.Automation.PSSerializer]::Serialize($o))
					} catch { if ($say) { & $say "Staged install: could not update PSGetModuleInfo.xml for $n ($($_.Exception.Message)); the module still works." } }
					finally { try { [IO.File]::SetAttributes($xml, [IO.FileAttributes]::Hidden) } catch {} }
				}
				Rename-Item -LiteralPath $partial -NewName $Version -ErrorAction Stop
				if ($say) { & $say "Staged install: copied verified $n $Version to the CurrentUser module folder" }
			} catch {
				try { if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
				return [pscustomobject]@{ Ok = $false; Reason = "copy failed: $($_.Exception.Message)" }
			}
		}
		$ok = Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $dest $Name) $Version) "$Name.psd1")
		return [pscustomobject]@{ Ok = $ok; Reason = $(if ($ok) { '' } else { 'module not found after copy' }) }
	} catch {
		return [pscustomobject]@{ Ok = $false; Reason = "$($_.Exception.Message)" }
	} finally {
		try { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
	}
}
# Install (CurrentUser) or Save (-Destination) the given {Name;Version} items from PSGallery. Never
# uninstalls, never writes machine-wide. Returns Installed / Already / Failed / NetworkError.
function Install-PlanModules {
	param($Items, [string]$Destination, [switch]$ForceCurrentUser, [scriptblock]$Log)
	$emitLog = $Log; $log = { param($m) if ($emitLog) { & $emitLog $m } }   # NOT if($Log): $log IS $Log (case-insensitive) -> infinite recursion
	Initialize-GalleryAccessPlain -Log $emitLog
	$acceptLic = $false; try { $acceptLic = (Get-Command Install-Module).Parameters.ContainsKey('AcceptLicense') } catch {}
	$installed = @(); $already = @(); $failed = @(); $netErr = $false
	foreach ($it in @($Items)) {
		$name = "$($it.Name)"; $ver = "$($it.Version)"
		if (-not $name -or -not $ver) { continue }
		# -ForceCurrentUser (the Settings "Install 3.10.1" button): install to CurrentUser even if a copy
		# exists elsewhere, so the CurrentUser folder (first on the path) wins. Otherwise skip if present.
		if (-not $ForceCurrentUser) {
			$have = if ($Destination) { @(Get-InstalledModuleVersions $name -Roots @($Destination) | Where-Object { "$($_.Version)" -eq $ver }) } else { @(Get-InstalledModuleVersions $name | Where-Object { "$($_.Version)" -eq $ver }) }
			if ($have.Count) { $already += "$name $ver"; continue }
		}
		$errItem = $Error.Count
		try {
			if ($Destination -and -not $ForceCurrentUser) {
				$sp = @{ Name = $name; RequiredVersion = $ver; Path = $Destination; Repository = 'PSGallery'; Force = $true; ErrorAction = 'Stop' }
				if ($acceptLic) { $sp.AcceptLicense = $true }
				Save-Module @sp
			} else {
				$ip = @{ Name = $name; RequiredVersion = $ver; Scope = 'CurrentUser'; Repository = 'PSGallery'; Force = $true; AllowClobber = $true; ErrorAction = 'Stop' }
				if ($acceptLic) { $ip.AcceptLicense = $true }
				Install-Module @ip
			}
			& $log "Installed $name $ver"
			$installed += "$name $ver"
		} catch {
			$msg = "$($_.Exception.Message)"
			$notCat = ("$($_.FullyQualifiedErrorId)" -match 'ModuleIsNotCatalogSigned') -or ($msg -match 'is not catalog signed')
			if ($notCat -and -not ($Destination -and -not $ForceCurrentUser) -and (Test-StagedInstallAllowed $name $ver)) {
				& $log "PowerShellGet refused $name $ver (a signed newer copy is installed); trying the verified staged install."
				$sr = Install-StagedModule -Name $name -Version $ver -Log $emitLog
				if ($sr.Ok) {
					while ($Error.Count -gt $errItem) { $Error.RemoveAt(0) }   # handled - don't show the refused attempt as an error later
					& $log "Installed $name $ver (verified staged install)"
					$installed += "$name $ver"
					continue
				}
				$msg = "$msg  [Staged install also failed: $($sr.Reason)]"
			}
			& $log "Failed $name ${ver}: $msg"
			$failed += "$name ${ver}: $msg"
			if ($msg -match 'Unable to resolve package source|No match was found|unable to connect|proxy|407|could not be resolved|The remote name|timed out|SSL|TLS') { $netErr = $true }
		}
	}
	return [pscustomobject]@{ Installed = @($installed); Already = @($already); Failed = @($failed); NetworkError = $netErr }
}

# Plain-words gallery-unreachable help. Current endpoints (Microsoft Learn: gallery troubleshooting).
function Get-GalleryHelpText {
	"Couldn't reach the PowerShell Gallery. This computer may have no internet access, or a proxy/firewall is blocking it. Ask your network admin to allow HTTPS (port 443) to: cdn.oneget.org, cdn.powershellgallery.com, *.powershellgallery.com, go.microsoft.com, aka.ms."
}

# Redact machine-/user-identifying text (E8, N2). Secrets/identifiers FIRST (token, e-mail, GUID) so a
# later name/path pass can't mangle them (e.g. leaving "albert" from albert@contoso.com). Then paths.
# Then USERNAME / USERDOMAIN / COMPUTERNAME as WHOLE words only, so a short name can't scramble others.
function Protect-DiagText([string]$Text) {
	if (-not $Text) { return $Text }
	$t = $Text
	$t = $t -replace 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*', '<token>'
	$t = $t -replace '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '<upn>'
	$t = $t -replace '(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '<guid>'
	foreach ($pair in @(@($env:USERPROFILE, '<profile>'), @($env:OneDrive, '<onedrive>'), @($env:OneDriveCommercial, '<onedrive>'))) {
		if ($pair[0]) { $t = $t -replace [regex]::Escape($pair[0]), $pair[1] }
	}
	$t = $t -replace '(?i)OneDrive - [^\\/\r\n]+', 'OneDrive - <org>'
	if ($env:USERNAME)     { $t = $t -replace ('(?i)(?<![A-Za-z0-9])' + [regex]::Escape($env:USERNAME)     + '(?![A-Za-z0-9])'), '<user>' }
	if ($env:USERDOMAIN)   { $t = $t -replace ('(?i)(?<![A-Za-z0-9])' + [regex]::Escape($env:USERDOMAIN)   + '(?![A-Za-z0-9])'), '<domain>' }
	if ($env:COMPUTERNAME) { $t = $t -replace ('(?i)(?<![A-Za-z0-9])' + [regex]::Escape($env:COMPUTERNAME) + '(?![A-Za-z0-9])'), '<pc>' }
	return $t
}

# Plain-text diagnostics (redacted). Information only; never signs in, never prints a token.
function Get-ModuleDiagnostics {
	param($Plan)
	$errN = $Error.Count
	try {
	$sb = [System.Text.StringBuilder]::new()
	$add = { param($line) [void]$sb.AppendLine("$line") }
	$appVer = ''; try { $appVer = "$version" } catch {}
	if (-not $appVer) { try { $mg = Join-Path (Split-Path $PSScriptRoot -Parent) 'MainGUI.ps1'; if (Test-Path -LiteralPath $mg) { $m1 = [regex]::Match(([IO.File]::ReadAllLines($mg)[0]), 'v\d+\.\d+\.\d+'); if ($m1.Success) { $appVer = $m1.Value } } } catch {} }
	& $add "App version: $appVer"
	$fw = ''; try { $fw = [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription } catch {}
	& $add "PowerShell: $($PSVersionTable.PSVersion) ($fw)"
	$osb = ''; try { $osb = [System.Environment]::OSVersion.Version.Build } catch {}
	& $add "OS build: $osb"
	$elev = 'no'
	try { $id = [Security.Principal.WindowsIdentity]::GetCurrent(); $elev = if ((New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'yes' } else { 'no' } } catch {}
	& $add "Elevated: $elev"
	$pAAH = 'no'; $pACH = 'no'; $pCAH = 'no'; $pCCH = 'no'
	try { if ($PROFILE.AllUsersAllHosts      -and (Test-Path -LiteralPath $PROFILE.AllUsersAllHosts))      { $pAAH = 'yes' } } catch {}
	try { if ($PROFILE.AllUsersCurrentHost   -and (Test-Path -LiteralPath $PROFILE.AllUsersCurrentHost))   { $pACH = 'yes' } } catch {}
	try { if ($PROFILE.CurrentUserAllHosts   -and (Test-Path -LiteralPath $PROFILE.CurrentUserAllHosts))   { $pCAH = 'yes' } } catch {}
	try { if ($PROFILE.CurrentUserCurrentHost -and (Test-Path -LiteralPath $PROFILE.CurrentUserCurrentHost)) { $pCCH = 'yes' } } catch {}
	& $add "Profile files: AllUsersAllHosts=$pAAH AllUsersCurrentHost=$pACH CurrentUserAllHosts=$pCAH CurrentUserCurrentHost=$pCCH"
	& $add ""
	& $add "PSModulePath:"
	foreach ($e in @(("$env:PSModulePath" -split [IO.Path]::PathSeparator) | Where-Object { $_ })) { & $add "  $e" }
	& $add ""
	& $add "Installed modules:"
	foreach ($name in (@($script:GraphModuleNames) + 'ExchangeOnlineManagement')) {
		$iv = @(Get-InstalledModuleVersions $name)
		if ($iv.Count) { foreach ($v in $iv) { & $add ("  {0} {1} [{2}]" -f $name, $v.Version, $v.Scope) } }
		else { & $add "  $name (none)" }
	}
	& $add ""
	if (-not $Plan) { try { $Plan = Resolve-ModulePlan } catch {} }
	if ($Plan) {
		$gExtra = if ($Plan.GraphNewest -and "$($Plan.GraphNewest)" -ne "$($Plan.Graph)") { " (newest installed: $($Plan.GraphNewest))" } else { '' }
		$eExtra = if ($Plan.ExoNewest -and "$($Plan.ExoNewest)" -ne "$($Plan.Exo)") { " (newest installed: $($Plan.ExoNewest))" } else { '' }
		& $add "Plan: pwsh row $($Plan.PwshRow) -> Graph $($Plan.Graph) ($($Plan.GraphMode)) autoload $($Plan.GraphAutoload)$gExtra / Exchange $($Plan.Exo) ($($Plan.ExoMode)) autoload $($Plan.ExoAutoload)$eExtra"
		if (@($Plan.NeedsInstall).Count) { & $add ("  NeedsInstall: " + ((@($Plan.NeedsInstall) | ForEach-Object { "$($_.Name) $($_.Version)" }) -join ', ')) }
		if (@($Plan.Attempts).Count)     { foreach ($a in @($Plan.Attempts)) { & $add "  attempt: $a" } }
	}
	& $add ""
	# Graph set check (information only, never a failure/install): the version autoload would pick for each
	# submodule next to Authentication; a mismatch means that part of Graph won't load (same as v3.4.2).
	$authAuto = Get-AutoloadVersion 'Microsoft.Graph.Authentication'
	if ($authAuto) {
		& $add "Graph autoload set (Authentication $($authAuto.Version)):"
		foreach ($gm in $script:GraphModuleNames) {
			$sa = Get-AutoloadVersion $gm
			& $add ("  {0} {1}" -f $gm, $(if ($sa) { "$($sa.Version)" } else { '(none)' }))
			if ($sa -and "$($sa.Version)" -ne "$($authAuto.Version)") { & $add "  Note: Microsoft Graph $gm $($sa.Version) needs Authentication $($sa.Version), but $($authAuto.Version) loads first - that part of Graph won't load (same as v3.4.2)." }
		}
	}
	& $add ("badModuleVersions: " + ((Get-BadModuleVersions) -join ', '))
	& $add ""
	& $add "Loaded modules:"
	foreach ($m in @(Get-Module | Sort-Object Name)) { & $add ("  {0} {1}" -f $m.Name, $m.Version) }
	& $add ""
	& $add "Loaded identity assemblies (information only - Jwt 5.6 with Graph 1.x is normal; it only matters for certificate or access-token Exchange sign-in, which SPS doesn't use):"
	try {
		foreach ($a in [System.AppDomain]::CurrentDomain.GetAssemblies()) {
			$n = $a.GetName().Name
			if ($n -eq 'Microsoft.Identity.Client' -or $n -eq 'System.IdentityModel.Tokens.Jwt') {
				$ctx = ''; try { $ctx = [System.Runtime.Loader.AssemblyLoadContext]::GetLoadContext($a).Name } catch {}
				& $add ("  {0} {1} (context: {2})" -f $n, $a.GetName().Version, $ctx)
			}
		}
	} catch {}
	& $add ""
	$pol = ''; try { $pol = (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy } catch {}
	$nug = ''; try { $nug = (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1).Version } catch {}
	$pget = ''; try { $pget = (Get-Module PowerShellGet -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1).Version } catch {}
	& $add "PSGallery policy: $pol; NuGet: $nug; PowerShellGet: $pget"
	$wam = ''
	try { $gp = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.mg\mg.graphoptions.json'; if (Test-Path -LiteralPath $gp) { $wam = "$((Get-Content -LiteralPath $gp -Raw | ConvertFrom-Json).DisableWAMForMSGraph)" } } catch {}
	& $add "mg.graphoptions.json DisableWAMForMSGraph: $(if ($wam -ne '') { $wam } else { '(not set)' })"
	return (Protect-DiagText $sb.ToString())
	} finally { while ($Error.Count -gt $errN) { $Error.RemoveAt(0) } }
}
