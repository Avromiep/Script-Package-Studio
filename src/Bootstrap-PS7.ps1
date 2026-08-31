# Runs under Windows PowerShell (launched by Script-Package-Studio.bat only when PowerShell 7 /
# pwsh is NOT installed). Prompts to install PowerShell 7, installs it, then relaunches the app
# under pwsh. Designed to work back to Windows Server 2012 / 2012 R2:
#   - winget isn't on Windows Server, so the MSI path is the real installer there.
#   - the LATEST PowerShell 7 (7.4/7.5) needs .NET 8/9 = Server 2016+, so on older OSes we pin
#     to PowerShell 7.2, the last release that supports Server 2012 / 2012 R2.
#   - TLS 1.2 is forced on (old servers default to TLS 1.0 and downloads fail otherwise).
#   - the MSI is launched elevated; falls back to a console prompt on Server Core (no WPF).

$appRoot = Split-Path $PSScriptRoot -Parent
$mainPs1 = Join-Path $appRoot 'MainGUI.ps1'

# Last PowerShell 7.2 (LTS) release - the newest 7.x that still runs on Server 2012 / 2012 R2.
$legacyMsiUrl = 'https://github.com/PowerShell/PowerShell/releases/download/v7.2.24/PowerShell-7.2.24-win-x64.msi'

# .NET 8/9 (PowerShell 7.4/7.5) require Windows 10 1607 / Server 2016 (build 14393) or newer.
# Anything older (Server 2012 = 6.2, 2012 R2 = 6.3, Win10 pre-1607) must use PowerShell 7.2.
$osv = [Environment]::OSVersion.Version
$isLegacy = ($osv.Major -lt 10) -or ($osv.Major -eq 10 -and $osv.Build -lt 14393)

# Prompt helpers: use WPF message boxes when available, fall back to the console (Server Core).
$script:HasWpf = $false
try { Add-Type -AssemblyName PresentationFramework -ErrorAction Stop; $script:HasWpf = $true } catch { $script:HasWpf = $false }
function Ask-YesNo([string]$Title, [string]$Message) {
	if ($script:HasWpf) { return ([System.Windows.MessageBox]::Show($Message, $Title, 'YesNo', 'Warning') -eq 'Yes') }
	Write-Host "`n=== $Title ===`n$Message" -ForegroundColor Yellow
	return ((Read-Host 'Type Y to continue (anything else cancels)') -match '^(y|yes)$')
}
function Show-Msg([string]$Title, [string]$Message, [string]$Icon = 'Information') {
	if ($script:HasWpf) { [void][System.Windows.MessageBox]::Show($Message, $Title, 'OK', $Icon) }
	else { Write-Host "`n=== $Title ===`n$Message" }
}

function Find-Pwsh {
	$c = Get-Command pwsh -ErrorAction SilentlyContinue
	if ($c) { return $c.Source }
	foreach ($p in @(
		"$env:ProgramFiles\PowerShell\7\pwsh.exe",
		"${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe",
		"$env:LOCALAPPDATA\Microsoft\PowerShell\7\pwsh.exe")) {
		if (Test-Path $p) { return $p }
	}
	return $null
}

function Install-PS7 {
	# Force TLS 1.2 (old servers negotiate TLS 1.0 by default and GitHub/Microsoft reject it).
	try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}

	# winget only exists on modern Windows 10/11 clients (never on Windows Server) - and it would
	# pull the latest build, so only use it on non-legacy machines.
	if (-not $isLegacy -and (Get-Command winget -ErrorAction SilentlyContinue)) {
		try { Start-Process winget -ArgumentList 'install','--id','Microsoft.PowerShell','-e','--source','winget','--accept-source-agreements','--accept-package-agreements' -Wait } catch {}
		if (Find-Pwsh) { return $true }
	}

	# MSI path: pin 7.2 on legacy OSes, otherwise grab the latest x64 MSI from GitHub.
	try {
		$url = $null
		if ($isLegacy) {
			$url = $legacyMsiUrl
		} else {
			$rel = Invoke-RestMethod 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -UseBasicParsing
			$asset = $rel.assets | Where-Object { $_.name -match 'win-x64\.msi$' } | Select-Object -First 1
			if ($asset) { $url = $asset.browser_download_url }
		}
		if ($url) {
			$msi = Join-Path $env:TEMP (Split-Path $url -Leaf)
			Invoke-WebRequest $url -OutFile $msi -UseBasicParsing
			# Installing to Program Files needs elevation; -Verb RunAs triggers the UAC prompt.
			Start-Process msiexec.exe -ArgumentList '/i', "`"$msi`"", '/passive', '/norestart' -Verb RunAs -Wait
		}
	} catch {}
	return [bool](Find-Pwsh)
}

function Start-App([string]$Pwsh) {
	Start-Process -FilePath $Pwsh -WorkingDirectory $appRoot -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-File', $mainPs1
}

# Already installed (just not on this session's PATH)? Launch and go, no prompt.
$existing = Find-Pwsh
if ($existing) { Start-App $existing; return }

$verNote = if ($isLegacy) { "`n`nThis computer is an older Windows version (Server 2012 / 2012 R2 era), so PowerShell 7.2 - the last version that supports it - will be installed." } else { '' }
if (-not (Ask-YesNo 'PowerShell 7 required' "Script-Package Studio runs on PowerShell 7, which isn't installed on this computer.`n`nInstall PowerShell 7 now? (This may take a few minutes and will ask for admin approval.)$verNote")) { return }

if (Install-PS7) {
	Start-App (Find-Pwsh)
} else {
	$link = if ($isLegacy) { 'https://github.com/PowerShell/PowerShell/releases (choose a 7.2.x win-x64 MSI)' } else { 'https://aka.ms/powershell' }
	Show-Msg 'Install failed' "PowerShell 7 couldn't be installed automatically.`n`nInstall it manually from:`n$link`n`nThen start Script-Package Studio again." 'Error'
}
