# modulepins.ps1 - module version planning, loading, install and diagnostics.
# NO WPF, Show-Notice or Set-ItemStatus here: this file is shared by the app AND the isolated
# self-test. It logs through an optional -Log scriptblock and returns objects.

# ======================= PINNED MODULE VERSIONS (edit ONLY here) =======================
# Graph: all six Microsoft.Graph.* modules must be the SAME version. Used ONLY when the newest installed
# Graph is 2.34+ (forced Windows pop-up). Otherwise the app loads Graph exactly as v3.4.2 did (newest installed).
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
function Get-InstalledModuleVersions([string]$Name, [string[]]$Roots) {
	$cuPwsh = $null; $cuWin = $null; $puPwsh = $null; $puWin = $null; $home2 = $null
	try { $cuPwsh = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules' } catch {}
	try { $cuWin  = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules' } catch {}   # E10
	try { if ($env:ProgramFiles) { $puPwsh = Join-Path $env:ProgramFiles 'PowerShell\Modules'; $puWin = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules' } } catch {}
	try { $home2 = Join-Path $PSHOME 'Modules' } catch {}
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
				$ver = $null; try { $ver = [version]$vdir.Name } catch {}
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

# Decide what to load. Returns the plan (modes + chosen versions + manifests + NeedsInstall). Pure.
function Resolve-ModulePlan {
	param([string[]]$Roots)
	$ps = $PSVersionTable.PSVersion
	$rowKey = Get-PwshRowKey
	if ($ps.Major -eq 7 -and $ps.Minor -ge 7) { $rowKey = '7.6' }   # 7.7+ uses the 7.6 row
	$bad = @(Get-BadModuleVersions)
	$attempts = [System.Collections.Generic.List[string]]::new()

	# ---- Graph ----
	$authInstalled = @(Get-InstalledModuleVersions 'Microsoft.Graph.Authentication' -Roots $Roots)
	$graphMode = 'missing'; $graphVer = $null; $graphManifests = @{}
	if ($authInstalled.Count) {
		$newestAuth = ($authInstalled | Select-Object -Last 1).Version
		if ($newestAuth -lt $script:GraphWamFrom) {
			$graphMode = 'asToday'; $graphVer = $newestAuth    # v3.4.2 autoload picks the newest, exactly as today
		} else {
			$graphMode = 'needsRevert'
			foreach ($cand in $script:GraphPinCandidates) {
				if ("Microsoft.Graph.Authentication=$cand" -in $bad) { continue }
				$ok = $true; $mans = @{}
				foreach ($gm in $script:GraphModuleNames) {
					$iv = @(Get-InstalledModuleVersions $gm -Roots $Roots | Where-Object { "$($_.Version)" -eq $cand })
					if (-not $iv.Count) { $ok = $false; break }
					$mans[$gm] = $iv[0].ManifestPath
				}
				if ($ok) { $graphMode = 'pin'; $graphVer = [version]$cand; $graphManifests = $mans; break }
			}
		}
	}

	# ---- Exchange ----
	$exoInstalled = @(Get-InstalledModuleVersions 'ExchangeOnlineManagement' -Roots $Roots)
	$exoMode = 'missing'; $exoVer = $null; $exoManifest = $null
	if ($exoInstalled.Count) {
		$newestExo = ($exoInstalled | Select-Object -Last 1).Version
		if (-not (Test-ExoBrokenHere $newestExo $ps)) {
			$exoMode = 'asToday'; $exoVer = $newestExo        # autoload loads the newest as v3.4.2 did
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
		}
	}

	# ---- NeedsInstall (row defaults; NEVER installed silently) ----
	$needsInstall = [System.Collections.Generic.List[object]]::new()
	if ($graphMode -eq 'missing' -or $graphMode -eq 'needsRevert') {
		foreach ($gm in $script:GraphModuleNames) { [void]$needsInstall.Add([pscustomobject]@{ Name = $gm; Version = $script:GraphInstallDefault }) }
	}
	if ($exoMode -eq 'missing' -or $exoMode -eq 'needsInstall') {
		$ev = if ($script:ExoInstallDefault.Contains($rowKey)) { $script:ExoInstallDefault[$rowKey] } else { $null }
		if ($ev) { [void]$needsInstall.Add([pscustomobject]@{ Name = 'ExchangeOnlineManagement'; Version = $ev }) }
	}

	return [pscustomobject]@{
		PwshRow        = $rowKey
		GraphMode      = $graphMode
		Graph          = $graphVer
		GraphManifests = $graphManifests
		ExoMode        = $exoMode
		Exo            = $exoVer
		ExoManifest    = $exoManifest
		NeedsInstall   = @($needsInstall)
		Attempts       = @($attempts)
		Bad            = @($bad)
	}
}

# Load the plan. Graph first (Authentication first), then Exchange - exactly v3.4.2's order. Imports
# each module ONCE (E3): on failure, records the bad version and returns Step='restart'. No Jwt
# preload or gate. No wholesale $Error.Clear().
function Import-ModulePlan {
	param($Plan, [switch]$ByPath, [string]$IsolatedPath, [scriptblock]$Log)
	$log = { param($m) if ($Log) { & $Log $m } }
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
				return [pscustomobject]@{ Ok = $false; Step = 'restart'; Error = "$gm $($Plan.Graph): $msg"; Loaded = @($loaded) }
			}
		}
	}
	if ($Plan.ExoMode -eq 'pin') {
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
				Add-BadModuleVersion "ExchangeOnlineManagement=$($Plan.Exo)"
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
	foreach ($m in @(Get-Module -Name 'Microsoft.Graph.*')) {
		try { if ($m.ExportedCommands.ContainsKey($Name)) { return $true } } catch {}
	}
	$authMajor = $null
	$la = Get-Module -Name 'Microsoft.Graph.Authentication' | Sort-Object Version -Descending | Select-Object -First 1
	if ($la) { $authMajor = $la.Version.Major }
	else { $ai = @(Get-InstalledModuleVersions 'Microsoft.Graph.Authentication'); if ($ai.Count) { $authMajor = ($ai | Select-Object -Last 1).Version.Major } }
	if ($null -eq $authMajor) { return $false }
	return ($authMajor -ge 2)
}

# Make the PowerShell Gallery reachable for THIS process only. No admin, nothing machine-wide.
function Initialize-GalleryAccessPlain([scriptblock]$Log) {
	$log = { param($m) if ($Log) { & $Log $m } }
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

# Install (CurrentUser) or Save (-Destination) the given {Name;Version} items from PSGallery. Never
# uninstalls, never writes machine-wide. Returns Installed / Already / Failed / NetworkError.
function Install-PlanModules {
	param($Items, [string]$Destination, [scriptblock]$Log)
	$log = { param($m) if ($Log) { & $Log $m } }
	Initialize-GalleryAccessPlain -Log $Log
	$acceptLic = $false; try { $acceptLic = (Get-Command Install-Module).Parameters.ContainsKey('AcceptLicense') } catch {}
	$installed = @(); $already = @(); $failed = @(); $netErr = $false
	foreach ($it in @($Items)) {
		$name = "$($it.Name)"; $ver = "$($it.Version)"
		if (-not $name -or -not $ver) { continue }
		$have = if ($Destination) { @(Get-InstalledModuleVersions $name -Roots @($Destination) | Where-Object { "$($_.Version)" -eq $ver }) } else { @(Get-InstalledModuleVersions $name | Where-Object { "$($_.Version)" -eq $ver }) }
		if ($have.Count) { $already += "$name $ver"; continue }
		try {
			if ($Destination) {
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

# Redact machine-/user-identifying text (E8). Order matters: longer/profile paths first.
function Protect-DiagText([string]$Text) {
	if (-not $Text) { return $Text }
	$t = $Text
	foreach ($pair in @(@($env:USERPROFILE,'<profile>'), @($env:OneDrive,'<onedrive>'), @($env:OneDriveCommercial,'<onedrive>'))) {
		if ($pair[0]) { $t = $t -replace [regex]::Escape($pair[0]), $pair[1] }
	}
	$t = $t -replace '(?i)OneDrive - [^\\/\r\n]+', 'OneDrive - <org>'
	if ($env:USERNAME)     { $t = $t -replace ('(?i)' + [regex]::Escape($env:USERNAME)),     '<user>' }
	if ($env:USERDOMAIN)   { $t = $t -replace ('(?i)' + [regex]::Escape($env:USERDOMAIN)),   '<domain>' }
	if ($env:COMPUTERNAME) { $t = $t -replace ('(?i)' + [regex]::Escape($env:COMPUTERNAME)), '<pc>' }
	$t = $t -replace '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '<upn>'
	$t = $t -replace '(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '<guid>'
	$t = $t -replace 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*', '<token>'
	return $t
}

# Plain-text diagnostics (redacted). Information only; never signs in, never prints a token.
function Get-ModuleDiagnostics {
	param($Plan)
	$sb = [System.Text.StringBuilder]::new()
	$add = { param($line) [void]$sb.AppendLine("$line") }
	$appVer = ''; try { $appVer = "$version" } catch {}
	& $add "App version: $appVer"
	$fw = ''; try { $fw = [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription } catch {}
	& $add "PowerShell: $($PSVersionTable.PSVersion) ($fw)"
	$osb = ''; try { $osb = [System.Environment]::OSVersion.Version.Build } catch {}
	& $add "OS build: $osb"
	$elev = 'no'
	try { $id = [Security.Principal.WindowsIdentity]::GetCurrent(); $elev = if ((New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'yes' } else { 'no' } } catch {}
	& $add "Elevated: $elev"
	$pAll = 'no'; $pCur = 'no'
	try { if ($PROFILE.CurrentUserAllHosts  -and (Test-Path -LiteralPath $PROFILE.CurrentUserAllHosts))  { $pAll = 'yes' } } catch {}
	try { if ($PROFILE.CurrentUserCurrentHost -and (Test-Path -LiteralPath $PROFILE.CurrentUserCurrentHost)) { $pCur = 'yes' } } catch {}
	& $add "Profile files: AllHosts=$pAll CurrentHost=$pCur"
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
		& $add "Plan: pwsh row $($Plan.PwshRow) -> Graph $($Plan.Graph) ($($Plan.GraphMode)) / Exchange $($Plan.Exo) ($($Plan.ExoMode))"
		if (@($Plan.NeedsInstall).Count) { & $add ("  NeedsInstall: " + ((@($Plan.NeedsInstall) | ForEach-Object { "$($_.Name) $($_.Version)" }) -join ', ')) }
		if (@($Plan.Attempts).Count)     { foreach ($a in @($Plan.Attempts)) { & $add "  attempt: $a" } }
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
}
