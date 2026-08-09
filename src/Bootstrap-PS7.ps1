# Runs under Windows PowerShell 5.1 (launched by Script-Package-Studio.bat only when
# PowerShell 7 / pwsh is NOT installed). Prompts to install PowerShell 7, installs it
# via winget (or the MSI as a fallback), then relaunches the app under pwsh.
Add-Type -AssemblyName PresentationFramework

$appRoot = Split-Path $PSScriptRoot -Parent
$mainPs1 = Join-Path $appRoot 'MainGUI.ps1'

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
	# Prefer winget (present on current Windows 10/11).
	if (Get-Command winget -ErrorAction SilentlyContinue) {
		try {
			Start-Process winget -ArgumentList 'install','--id','Microsoft.PowerShell','-e','--source','winget','--accept-source-agreements','--accept-package-agreements' -Wait
		} catch {}
		if (Find-Pwsh) { return $true }
	}
	# Fallback: download the latest x64 MSI from GitHub and install it silently.
	try {
		[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
		$rel = Invoke-RestMethod 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -UseBasicParsing
		$asset = $rel.assets | Where-Object { $_.name -match 'win-x64\.msi$' } | Select-Object -First 1
		if ($asset) {
			$msi = Join-Path $env:TEMP $asset.name
			Invoke-WebRequest $asset.browser_download_url -OutFile $msi -UseBasicParsing
			Start-Process msiexec.exe -ArgumentList '/i',"`"$msi`"",'/passive','/norestart' -Wait
		}
	} catch {}
	return [bool](Find-Pwsh)
}

# If pwsh is actually present (installed but maybe not on this session's PATH), just
# launch the app - no need to prompt.
$existing = Find-Pwsh
if ($existing) {
	Start-Process -FilePath $existing -WorkingDirectory $appRoot -ArgumentList '-NoProfile','-WindowStyle','Hidden','-File',$mainPs1
	return
}

$answer = [System.Windows.MessageBox]::Show(
	"Script-Package Studio runs on PowerShell 7, which isn't installed on this computer.`n`nInstall PowerShell 7 now? (This may take a few minutes.)",
	'PowerShell 7 required', 'YesNo', 'Warning')
if ($answer -ne 'Yes') { return }

if (Install-PS7) {
	$pwsh = Find-Pwsh
	Start-Process -FilePath $pwsh -WorkingDirectory $appRoot -ArgumentList '-NoProfile','-WindowStyle','Hidden','-File',$mainPs1
} else {
	[void][System.Windows.MessageBox]::Show(
		"PowerShell 7 couldn't be installed automatically.`n`nPlease install it from https://aka.ms/powershell and then start Script-Package Studio again.",
		'Install failed', 'OK', 'Error')
}
