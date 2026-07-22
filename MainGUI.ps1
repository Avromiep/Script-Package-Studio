$version = "v3.0.0"
# Script-Package GUI - WPF, styled with the BatchAV Studio design system.
# All script logic and cmdlet calls are unchanged; only the UI layer moved
# from WinForms to WPF (src/ui.ps1 + src/scripts*.ps1 + src/xaml/Styles.xaml).
#
# Need these 2 modules:
# Install-Module -Name Microsoft.Graph -Force -AllowClobber
# Install-Module -Name ExchangeOnlineManagement -Force -AllowClobber

# Must run as administrator (runtime check instead of #Requires so automated
# UI tests can run un-elevated with SP_SHOT / SP_TEST set)
if (-not $env:SP_SHOT -and -not $env:SP_TEST) {
	$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
	if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
		Add-Type -AssemblyName PresentationFramework
		[void][System.Windows.MessageBox]::Show(
			"Script-Package Studio must be run as administrator.`nRight-click Script-Package-Studio.bat and choose 'Run as administrator'.",
			"Script-Package Studio", 'OK', 'Error')
		exit 1
	}
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$script:SrcDir = Join-Path $PSScriptRoot 'src'
$script:SettingsIniPath = Join-Path $PSScriptRoot 'settings.ini'

. (Join-Path $script:SrcDir 'ui.ps1')

# ---- settings (persisted in settings.ini) -----------------------------------
$script:Settings = @{
	theme        = 'Dark'
	winWidth     = 560
	winHeight    = 760
	winMaximized = $false
	logExpanded  = $false
}

function Read-AppSettings {
	if (-not (Test-Path -LiteralPath $script:SettingsIniPath)) { return }
	foreach ($line in (Get-Content -LiteralPath $script:SettingsIniPath -ErrorAction Ignore)) {
		if ($line -match '^\s*Theme\s*=\s*(Dark|Light)\s*$') { $script:Settings.theme = $Matches[1] }
		elseif ($line -match '^\s*WinWidth\s*=\s*(\d+)\s*$') { $script:Settings.winWidth = [Math]::Max(470, [int]$Matches[1]) }
		elseif ($line -match '^\s*WinHeight\s*=\s*(\d+)\s*$') { $script:Settings.winHeight = [Math]::Max(560, [int]$Matches[1]) }
		elseif ($line -match '^\s*WinMaximized\s*=\s*(0|1)\s*$') { $script:Settings.winMaximized = $Matches[1] -eq '1' }
		elseif ($line -match '^\s*LogExpanded\s*=\s*(0|1)\s*$') { $script:Settings.logExpanded = $Matches[1] -eq '1' }
	}
}

function Save-AppSettings {
	try {
		$values = [ordered]@{
			Theme        = $script:Settings.theme
			WinWidth     = [string][int]$script:Settings.winWidth
			WinHeight    = [string][int]$script:Settings.winHeight
			WinMaximized = if ($script:Settings.winMaximized) { '1' } else { '0' }
			LogExpanded  = if ($script:Settings.logExpanded) { '1' } else { '0' }
		}
		$lines = @()
		if (Test-Path -LiteralPath $script:SettingsIniPath) { $lines = @(Get-Content -LiteralPath $script:SettingsIniPath) }
		else { $lines = @('[General]') }
		$pending = [System.Collections.Generic.HashSet[string]]::new([string[]]$values.Keys)
		$lines = @($lines | ForEach-Object {
			$out = $_
			foreach ($k in $values.Keys) {
				if ($_ -match "^\s*$k\s*=") { $out = "$k=$($values[$k])"; [void]$pending.Remove($k); break }
			}
			$out
		})
		foreach ($k in $values.Keys) { if ($pending.Contains($k)) { $lines += "$k=$($values[$k])" } }
		Set-Content -LiteralPath $script:SettingsIniPath -Value $lines -Encoding UTF8
	} catch {}
}

# Settings retrieval function (kept for the hidden "Reload-Settings" entry)
function LoadSettings {
	Write-Host "Loading settings from settings.ini..."
	Read-AppSettings
	Apply-Theme $script:Settings.theme
	Write-Host "Loaded settings."
}

Read-AppSettings

# ---- styles + theme engine ---------------------------------------------------
$script:StyleDict = Read-XamlFile (Join-Path $script:SrcDir 'xaml\Styles.xaml')
[void]$script:StyleDict.MergedDictionaries.Add((Read-XamlString $script:ExtraStylesXaml))

. (Join-Path $script:SrcDir 'theme.ps1')
. (Join-Path $script:SrcDir 'scripts1.ps1')
. (Join-Path $script:SrcDir 'scripts2.ps1')
. (Join-Path $script:SrcDir 'scripts3.ps1')

# ---- main window ---------------------------------------------------------------
$mainXaml = @"
<Window
	xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
	xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
	Title="Script-Package Studio $version" Width="560" Height="760" MinWidth="470" MinHeight="560"
	WindowStartupLocation="CenterScreen" Background="Transparent"
	WindowStyle="SingleBorderWindow"
	TextOptions.TextFormattingMode="Ideal" UseLayoutRounding="True">

	<WindowChrome.WindowChrome>
		<WindowChrome CaptionHeight="50" ResizeBorderThickness="6" CornerRadius="0"
					  GlassFrameThickness="1" UseAeroCaptionButtons="False"/>
	</WindowChrome.WindowChrome>

	<Border x:Name="RootBorder" Background="{DynamicResource BgBrush}">
		<Grid x:Name="Root">
			<Grid.RowDefinitions>
				<RowDefinition Height="50"/>
				<RowDefinition Height="*"/>
				<RowDefinition Height="Auto"/>
				<RowDefinition Height="36"/>
			</Grid.RowDefinitions>

			<!-- Title bar -->
			<Border Grid.Row="0" Background="{DynamicResource PanelBrush}"
					BorderBrush="{DynamicResource StrokeSoftBrush}" BorderThickness="0,0,0,1">
				<Grid>
					<StackPanel Orientation="Horizontal" Margin="16,0,0,0" VerticalAlignment="Center">
						<Border Width="26" Height="26" CornerRadius="7" Background="{DynamicResource AccentBrush}">
							<TextBlock Text="&#xE756;" FontFamily="{DynamicResource IconFont}" FontSize="14"
									   Foreground="{DynamicResource OnAccentBrush}"
									   HorizontalAlignment="Center" VerticalAlignment="Center"/>
						</Border>
						<TextBlock Text="Script-Package Studio" Margin="10,0,0,0" VerticalAlignment="Center"
								   FontFamily="{DynamicResource UiFont}" FontSize="13.5" FontWeight="SemiBold"
								   Foreground="{DynamicResource TextBrush}"/>
						<TextBlock Text="$version" Margin="8,1,0,0" VerticalAlignment="Center"
								   Style="{DynamicResource Small}"/>
					</StackPanel>
					<StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
						<Button x:Name="ThemeBtn" Style="{DynamicResource IconBtn}" Margin="0,7,6,0"
								ToolTip="Toggle dark / light theme" WindowChrome.IsHitTestVisibleInChrome="True">
							<TextBlock x:Name="ThemeIcon" Text="&#xE706;" FontFamily="{DynamicResource IconFont}" FontSize="14"/>
						</Button>
						<Button x:Name="MinBtn" Style="{DynamicResource TitleBtn}" Content="&#xE921;" Height="36"
								WindowChrome.IsHitTestVisibleInChrome="True"/>
						<Button x:Name="MaxBtn" Style="{DynamicResource TitleBtn}" Content="&#xE922;" Height="36"
								WindowChrome.IsHitTestVisibleInChrome="True"/>
						<Button x:Name="CloseBtn" Style="{DynamicResource TitleBtnClose}" Content="&#xE8BB;" Height="36"
								WindowChrome.IsHitTestVisibleInChrome="True"/>
					</StackPanel>
				</Grid>
			</Border>

			<!-- Content -->
			<Grid Grid.Row="1" Margin="16">
				<Grid.RowDefinitions>
					<RowDefinition Height="Auto"/>
					<RowDefinition Height="*"/>
				</Grid.RowDefinitions>

				<!-- Tenant card: pick which Microsoft tenant the scripts run against -->
				<Border Style="{DynamicResource Card}" Padding="16,14">
					<Grid>
						<Grid.RowDefinitions>
							<RowDefinition Height="Auto"/>
							<RowDefinition Height="Auto"/>
						</Grid.RowDefinitions>
						<Grid.ColumnDefinitions>
							<ColumnDefinition Width="Auto"/>
							<ColumnDefinition Width="*"/>
							<ColumnDefinition Width="Auto"/>
							<ColumnDefinition Width="Auto"/>
						</Grid.ColumnDefinitions>
						<Ellipse x:Name="SignDot" Width="9" Height="9" Fill="{DynamicResource WarnBrush}"
								 VerticalAlignment="Center" Margin="0,0,11,0"/>
						<ComboBox x:Name="TenantCombo" Grid.Column="1" VerticalAlignment="Center" MinHeight="32"
								  ToolTip="Choose which Microsoft tenant to use. Selecting a tenant connects to it."/>
						<Button x:Name="ForgetTenantBtn" Grid.Column="2" Style="{DynamicResource IconBtn}"
								Content="&#xE74D;" Margin="6,0,0,0"
								ToolTip="Forget the selected tenant (removes it from this list)"/>
						<Button x:Name="ConnectBtn" Grid.Column="3" Style="{DynamicResource BtnPrimary}"
								Content="Sign In" MinWidth="96" Margin="8,0,0,0"/>
						<TextBlock x:Name="SignStatusText" Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="3"
								   Text="Currently not signed in." Style="{DynamicResource Small}" Margin="1,7,0,0"/>
					</Grid>
				</Border>

				<!-- Scripts card -->
				<Border Grid.Row="1" Style="{DynamicResource Card}" Margin="0,12,0,0" Padding="18,16">
					<Grid>
						<Grid.RowDefinitions>
							<RowDefinition Height="Auto"/>
							<RowDefinition Height="Auto"/>
							<RowDefinition Height="Auto"/>
							<RowDefinition Height="*"/>
							<RowDefinition Height="Auto"/>
						</Grid.RowDefinitions>
						<Grid Grid.Row="0">
							<StackPanel Orientation="Horizontal" VerticalAlignment="Center">
								<TextBlock Text="Scripts" Style="{DynamicResource H2}"/>
								<TextBlock x:Name="ScriptCountText" Style="{DynamicResource Small}"
										   Margin="10,4,0,0" VerticalAlignment="Center"/>
							</StackPanel>
						</Grid>
						<Grid Grid.Row="1" Margin="0,10,0,0">
							<TextBox x:Name="SearchBox" MinHeight="30" Padding="30,5,8,5"
									 ToolTip="Search scripts  (Ctrl+F)"/>
							<TextBlock Text="&#xE721;" FontFamily="{DynamicResource IconFont}" FontSize="13"
									   Foreground="{DynamicResource TextFaintBrush}" IsHitTestVisible="False"
									   Margin="10,0,0,0" VerticalAlignment="Center"/>
							<TextBlock x:Name="SearchHint" Text="Search scripts...   (Ctrl+F)" Style="{DynamicResource Small}"
									   Margin="32,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
						</Grid>
						<StackPanel x:Name="CatChipRow" Grid.Row="2" Orientation="Horizontal" Margin="0,10,0,0"/>
						<Grid Grid.Row="3">
							<ListBox x:Name="ScriptList" Margin="0,10,0,0" Background="Transparent"
									 BorderThickness="0" ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
							<StackPanel x:Name="EmptyState" VerticalAlignment="Center" HorizontalAlignment="Center"
										Visibility="Collapsed">
								<TextBlock Text="&#xE721;" FontFamily="{DynamicResource IconFont}" FontSize="22"
										   Foreground="{DynamicResource TextFaintBrush}" HorizontalAlignment="Center"/>
								<TextBlock Text="No scripts match your search." Style="{DynamicResource Dim}"
										   Margin="0,8,0,0" HorizontalAlignment="Center"/>
							</StackPanel>
						</Grid>
						<Grid Grid.Row="4" Margin="0,12,0,0">
							<TextBlock Text="Double-click a script, or press Enter, to run it."
									   Style="{DynamicResource Small}" VerticalAlignment="Center"/>
							<Button x:Name="RunBtn" Style="{DynamicResource BtnPrimary}" Content="Run"
									MinWidth="96" HorizontalAlignment="Right" IsDefault="True"/>
						</Grid>
					</Grid>
				</Border>
			</Grid>

			<!-- Activity log drawer: everything the scripts Write-Host lands here,
				 which used to be invisible (the launcher runs pwsh hidden) -->
			<Border Grid.Row="2" Background="{DynamicResource LogBgBrush}"
					BorderBrush="{DynamicResource StrokeSoftBrush}" BorderThickness="0,1,0,0">
				<Grid>
					<Grid.RowDefinitions>
						<RowDefinition Height="30"/>
						<RowDefinition Height="Auto"/>
					</Grid.RowDefinitions>
					<Grid Grid.Row="0" Margin="10,0,16,0">
						<StackPanel Orientation="Horizontal" VerticalAlignment="Center">
							<Button x:Name="LogToggleBtn" Style="{DynamicResource IconBtn}" Width="26" Height="22"
									ToolTip="Show / hide the activity log  (Ctrl+L)">
								<TextBlock x:Name="LogToggleIcon" Text="&#xE76C;" FontFamily="{DynamicResource IconFont}" FontSize="10"/>
							</Button>
							<TextBlock Text="Activity" Style="{DynamicResource H3}" Margin="6,0,0,0" VerticalAlignment="Center"/>
							<TextBlock x:Name="LogCountText" Style="{DynamicResource Small}" Margin="10,1,0,0" VerticalAlignment="Center"/>
						</StackPanel>
						<StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
							<Button x:Name="LogCopyBtn" Style="{DynamicResource BtnGhost}" Content="Copy" Padding="8,2"
									ToolTip="Copy the log to the clipboard"/>
							<Button x:Name="LogClearBtn" Style="{DynamicResource BtnGhost}" Content="Clear" Padding="8,2"/>
						</StackPanel>
					</Grid>
					<ListBox x:Name="LogList" Grid.Row="1" Height="150" Margin="4,0,4,4" Background="Transparent"
							 BorderThickness="0" Visibility="Collapsed"
							 ScrollViewer.HorizontalScrollBarVisibility="Disabled"
							 VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling"/>
				</Grid>
			</Border>

			<!-- Status bar -->
			<Border Grid.Row="3" Background="{DynamicResource PanelBrush}"
					BorderBrush="{DynamicResource StrokeSoftBrush}" BorderThickness="0,1,0,0">
				<Grid Margin="14,0">
					<StackPanel Orientation="Horizontal" VerticalAlignment="Center">
						<Ellipse x:Name="StatusDot" Width="8" Height="8" Fill="{DynamicResource SuccessBrush}"
								 VerticalAlignment="Center"/>
						<TextBlock x:Name="StatusText" Text="Ready" Style="{DynamicResource Dim}"
								   Margin="8,0,0,0" VerticalAlignment="Center"/>
					</StackPanel>
					<ProgressBar x:Name="MainProgress" Width="180" Height="6" Maximum="100"
								 HorizontalAlignment="Right" VerticalAlignment="Center"/>
				</Grid>
			</Border>
		</Grid>
	</Border>
</Window>
"@

$script:Window = Read-XamlString $mainXaml
[void]$script:Window.Resources.MergedDictionaries.Add($script:StyleDict)

$script:UI = @{}
foreach ($n in @('RootBorder','Root','ThemeBtn','ThemeIcon','MinBtn','MaxBtn','CloseBtn',
		'SignDot','SignStatusText','TenantCombo','ForgetTenantBtn','ConnectBtn',
		'ScriptCountText','SearchBox','SearchHint','CatChipRow','ScriptList','EmptyState','RunBtn',
		'LogToggleBtn','LogToggleIcon','LogCountText','LogCopyBtn','LogClearBtn','LogList',
		'StatusDot','StatusText','MainProgress')) {
	$el = $script:Window.FindName($n)
	if (-not $el) { throw "XAML element '$n' not found" }
	$script:UI[$n] = $el
}

try { $script:Window.Icon = [System.Windows.Media.Imaging.BitmapImage]::new([Uri](Join-Path $PSScriptRoot 'Images\logo.ico')) } catch {}

# $progressBar1 keeps the WinForms-era contract every script uses
# ($progressBar1.Value = n) and pumps the dispatcher so updates paint during
# synchronous work, like the old WinForms progress bar did.
$progressBar1 = [pscustomobject]@{}
$progressBar1 | Add-Member -MemberType ScriptProperty -Name Value `
	-Value { $script:UI.MainProgress.Value } `
	-SecondValue {
		param($v)
		$script:UI.MainProgress.Value = [double]$v
		try { $script:UI.MainProgress.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render) } catch {}
	}

# ---- tenant profiles ------------------------------------------------------------
# Saved tenants live in tenants.json next to the app (portable, like settings.ini).
# Only names/accounts/tenant ids are stored - the actual credentials stay in the
# Graph and Exchange Online token caches, which persist on this machine, so
# switching to a known tenant normally reconnects without any prompt.
$script:TenantsPath = Join-Path $PSScriptRoot 'tenants.json'
$script:Tenants = [System.Collections.Generic.List[object]]::new()
$script:ActiveTenant = $null
$script:SuppressTenantEvents = $false
$script:GraphScopes = @("User.ReadWrite.All", "Directory.ReadWrite.All")

function Load-Tenants {
	$script:Tenants.Clear()
	if (Test-Path -LiteralPath $script:TenantsPath) {
		try {
			foreach ($t in @(Get-Content -LiteralPath $script:TenantsPath -Raw | ConvertFrom-Json)) {
				if ($t.account -and $t.tenantId) { $script:Tenants.Add($t) }
			}
		} catch {}
	}
}

function Save-Tenants {
	try {
		ConvertTo-Json @($script:Tenants) -Depth 3 | Set-Content -LiteralPath $script:TenantsPath -Encoding UTF8
	} catch {}
}

function Get-MissingModules {
	$missing = @()
	if (-not (Get-Command Connect-MgGraph -ErrorAction Ignore)) { $missing += 'Microsoft.Graph' }
	if (-not (Get-Command Connect-ExchangeOnline -ErrorAction Ignore)) { $missing += 'ExchangeOnlineManagement' }
	return $missing
}

# Ensures the Microsoft modules are available before a sign-in attempt; offers
# to run Install-RequiredModules if they are not. Returns $true when ready.
function Confirm-RequiredModules {
	$missing = @(Get-MissingModules)
	if ($missing.Count -eq 0) { return $true }
	Write-Host "Missing PowerShell modules: $($missing -join ', ')" -ForegroundColor Yellow
	$choice = @{ Install = $false }
	$dlg = New-ModulesMissingDialog ($missing -join "`n")
	$dlg.FindName('InstallBtn').Add_Click({ $choice.Install = $true; $dlg.Close() })
	$dlg.FindName('NotNowBtn').Add_Click({ $dlg.Close() })
	[void]$dlg.ShowDialog()
	if (-not $choice.Install) { return $false }
	$script:UI.StatusText.Text = 'Installing modules... this can take several minutes.'
	Install-RequiredModules
	$script:UI.StatusText.Text = 'Ready'
	$missing = @(Get-MissingModules)
	if ($missing.Count -gt 0) {
		Write-Host "Modules still missing after install: $($missing -join ', ')" -ForegroundColor Red
		return $false
	}
	Write-Host "Modules installed." -ForegroundColor Green
	return $true
}

function Set-SignState([bool]$Connected, [string]$Text) {
	$brush = if ($Connected) { 'SuccessBrush' } else { 'WarnBrush' }
	$script:UI.SignDot.SetResourceReference([System.Windows.Shapes.Ellipse]::FillProperty, $brush)
	$script:UI.SignStatusText.Text = $Text
}

function Update-TenantCombo {
	$script:SuppressTenantEvents = $true
	try {
		$combo = $script:UI.TenantCombo
		$combo.Items.Clear()
		foreach ($t in $script:Tenants) {
			$item = [System.Windows.Controls.ComboBoxItem]::new()
			$item.Content = "$($t.name)  -  $($t.account)"
			$item.Tag = $t
			[void]$combo.Items.Add($item)
		}
		$addItem = [System.Windows.Controls.ComboBoxItem]::new()
		$addItem.Content = '+  Add a tenant...'
		$addItem.Tag = 'add'
		$addItem.FontStyle = 'Italic'
		[void]$combo.Items.Add($addItem)

		# preselect the active tenant, else the most recently used one
		$target = $script:ActiveTenant
		if (-not $target -and $script:Tenants.Count -gt 0) {
			$target = $script:Tenants | Sort-Object { [string]$_.lastUsed } -Descending | Select-Object -First 1
		}
		$combo.SelectedIndex = if ($target) { $script:Tenants.IndexOf($target) } else { -1 }

		$script:UI.ForgetTenantBtn.IsEnabled = $script:Tenants.Count -gt 0
		$script:UI.ConnectBtn.Content = if ($script:ActiveTenant) { 'Disconnect' }
			elseif ($script:Tenants.Count -gt 0) { 'Connect' }
			else { 'Sign In' }
	} finally {
		$script:SuppressTenantEvents = $false
	}
}

function Get-SelectedTenant {
	$item = $script:UI.TenantCombo.SelectedItem
	if ($item -and $item.Tag -ne 'add') { return $item.Tag }
	return $null
}

# Connect Graph + Exchange Online to a saved tenant. With cached tokens this is
# silent; otherwise Microsoft's normal auth prompt appears (usually one click
# thanks to browser SSO).
function Connect-Tenant($Tenant) {
	if (-not $Tenant) { return }
	if (-not (Confirm-RequiredModules)) { Update-TenantCombo; return }
	$script:UI.StatusText.Text = "Connecting to $($Tenant.name)..."
	Set-SignState $false "Connecting to $($Tenant.name) as $($Tenant.account)..."
	$script:UI.SignDot.SetResourceReference([System.Windows.Shapes.Ellipse]::FillProperty, 'AccentBrush')
	Write-Host "Connecting to tenant $($Tenant.name) ($($Tenant.tenantId)) as $($Tenant.account)..."
	$progressBar1.Value = 10

	Connect-MgGraph -TenantId $Tenant.tenantId -Scopes $script:GraphScopes
	$progressBar1.Value = 40
	CheckForErrors
	$currentMgContext = Get-MgContext
	if (-not $currentMgContext -or [string]$currentMgContext.TenantId -ne [string]$Tenant.tenantId) {
		Write-Host "Could not connect to $($Tenant.name)." -ForegroundColor Red
		$script:ActiveTenant = $null
		Set-SignState $false 'Currently not signed in.'
		Update-TenantCombo
		$script:UI.StatusText.Text = 'Ready'
		$progressBar1.Value = 0
		return
	}
	Write-Host "Connected to Graph"
	if ([string]$currentMgContext.Account -and [string]$currentMgContext.Account -ne [string]$Tenant.account) {
		Write-Host "Note: Graph connected as $($currentMgContext.Account) (this tenant was saved for $($Tenant.account))." -ForegroundColor Yellow
	}

	try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction Ignore } catch {}
	Connect-ExchangeOnline -UserPrincipalName $Tenant.account -ShowBanner:$false -SkipLoadingCmdletHelp
	$progressBar1.Value = 80
	CheckForErrors
	Write-Host "Connected to Exchange"

	$script:ActiveTenant = $Tenant
	$Tenant.lastUsed = (Get-Date).ToString('o')
	Save-Tenants
	Update-TenantCombo
	Set-SignState $true "Connected to $($Tenant.name) as $($currentMgContext.Account)"
	$script:UI.StatusText.Text = 'Ready'
	$progressBar1.Value = 0
}

# Interactive sign-in to a new account/tenant; saves it as a profile
function Add-TenantSignIn {
	if (-not (Confirm-RequiredModules)) { return }
	Write-Host "Signing in to a new tenant..."
	$script:UI.SignDot.SetResourceReference([System.Windows.Shapes.Ellipse]::FillProperty, 'AccentBrush')
	Set-SignState $false 'Waiting for Microsoft sign-in...'
	$progressBar1.Value = 10

	# drop the current Graph context so the account picker appears instead of a
	# silent reconnect to the previous account
	try { Disconnect-MgGraph -ErrorAction Ignore | Out-Null } catch {}
	$Error.Clear()

	Connect-MgGraph -Scopes $script:GraphScopes
	$progressBar1.Value = 40
	CheckForErrors
	$currentMgContext = Get-MgContext
	if (-not $currentMgContext) {
		$script:ActiveTenant = $null
		Set-SignState $false 'Currently not signed in.'
		Update-TenantCombo
		$progressBar1.Value = 0
		return
	}
	Write-Host "Connected to Graph"

	$orgName = $null
	try { $orgName = [string](Get-MgOrganization -ErrorAction Ignore | Select-Object -First 1).DisplayName } catch {}
	if (-not $orgName) { $orgName = ([string]$currentMgContext.Account -split '@')[-1] }
	$Error.Clear()

	Connect-ExchangeOnline -UserPrincipalName $currentMgContext.Account -ShowBanner:$false -SkipLoadingCmdletHelp
	$progressBar1.Value = 80
	CheckForErrors
	Write-Host "Connected to Exchange"

	$tenantProfile = $script:Tenants | Where-Object {
		[string]$_.tenantId -eq [string]$currentMgContext.TenantId -and [string]$_.account -eq [string]$currentMgContext.Account
	} | Select-Object -First 1
	if ($tenantProfile) {
		$tenantProfile.name = $orgName
	} else {
		$tenantProfile = [pscustomobject]@{
			name     = $orgName
			account  = [string]$currentMgContext.Account
			tenantId = [string]$currentMgContext.TenantId
			lastUsed = ''
		}
		$script:Tenants.Add($tenantProfile)
	}
	$tenantProfile.lastUsed = (Get-Date).ToString('o')
	$script:ActiveTenant = $tenantProfile
	Save-Tenants
	Update-TenantCombo
	Set-SignState $true "Connected to $orgName as $($currentMgContext.Account)"
	Write-Host "Saved tenant '$orgName' ($($currentMgContext.Account))." -ForegroundColor Green
	$progressBar1.Value = 0
}

function Disconnect-Tenant {
	Write-Host "Disconnecting..."
	$progressBar1.Value = 10
	try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction Ignore } catch {}
	$progressBar1.Value = 50
	try { Disconnect-MgGraph -ErrorAction Ignore | Out-Null } catch {}
	$Error.Clear()
	Write-Host "Disconnected from Graph and Exchange"
	$script:ActiveTenant = $null
	Set-SignState $false 'Currently not signed in.'
	Update-TenantCombo
	$progressBar1.Value = 0
}

# ---- activity log --------------------------------------------------------------
# The launcher runs pwsh hidden, so console output was never visible. Shadowing
# Write-Host mirrors every message the scripts print into the log drawer (and
# still writes to the console for anyone running from a terminal).
$script:UI.LogList.ItemContainerStyle = $script:StyleDict['LogItemStyle']

function Add-UiLog([string]$Text, [string]$Color = '') {
	if (-not $script:UI -or -not $script:UI.LogList) { return }
	if (-not $Text.Trim()) { return }
	$brushKey = switch ($Color) {
		'Red'      { 'ErrorBrush' }
		'Yellow'   { 'WarnBrush' }
		'Green'    { 'SuccessBrush' }
		'Cyan'     { 'InfoBrush' }
		default    { 'TextDimBrush' }
	}
	$tb = [System.Windows.Controls.TextBlock]::new()
	$tb.Text = "[{0:HH:mm:ss}]  {1}" -f (Get-Date), $Text
	$tb.FontFamily = $script:StyleDict['UiFont']
	$tb.FontSize = 12
	$tb.TextWrapping = 'Wrap'
	$tb.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $brushKey)
	$list = $script:UI.LogList
	[void]$list.Items.Add($tb)
	while ($list.Items.Count -gt 500) { $list.Items.RemoveAt(0) }
	$script:UI.LogCountText.Text = "$($list.Items.Count) entries"
	if ($list.IsVisible) { $list.ScrollIntoView($list.Items[$list.Items.Count - 1]) }
}

function Write-Host {
	[CmdletBinding()]
	param(
		[Parameter(Position = 0, ValueFromRemainingArguments = $true)]
		[Alias('Msg', 'Message')]
		[object]$Object,
		[switch]$NoNewline,
		[object]$Separator = ' ',
		[System.ConsoleColor]$ForegroundColor,
		[System.ConsoleColor]$BackgroundColor
	)
	$fwd = @{ Object = $Object; NoNewline = $NoNewline; Separator = $Separator }
	if ($PSBoundParameters.ContainsKey('ForegroundColor')) { $fwd.ForegroundColor = $ForegroundColor }
	if ($PSBoundParameters.ContainsKey('BackgroundColor')) { $fwd.BackgroundColor = $BackgroundColor }
	Microsoft.PowerShell.Utility\Write-Host @fwd
	$color = if ($PSBoundParameters.ContainsKey('ForegroundColor')) { [string]$ForegroundColor } else { '' }
	try { Add-UiLog ([string]"$Object") $color } catch {}
}

function Set-LogExpanded([bool]$Expanded) {
	$script:Settings.logExpanded = $Expanded
	$script:UI.LogList.Visibility = if ($Expanded) { 'Visible' } else { 'Collapsed' }
	$script:UI.LogToggleIcon.Text = if ($Expanded) { [string][char]0xE70D } else { [string][char]0xE76C }
	if ($Expanded -and $script:UI.LogList.Items.Count -gt 0) {
		$script:UI.LogList.ScrollIntoView($script:UI.LogList.Items[$script:UI.LogList.Items.Count - 1])
	}
}

# ---- script catalog ----------------------------------------------------------
$script:ScriptCatalog = @(
	@{ Name = 'Add-AuthenticationPhoneMethod'; Desc = 'Add a 2FA phone number to an account, single or bulk.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xE717 }
	@{ Name = 'Add-AutoReply'; Desc = 'Set an automatic reply on a mailbox, optionally scheduled.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xE715 }
	@{ Name = 'Add-Contacts'; Desc = 'Add mail contacts to Microsoft 365, single or bulk.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xE77B }
	@{ Name = 'Add-DistributionListMember'; Desc = 'Add members to a distribution list.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xE716 }
	@{ Name = 'Add-EmailAlias'; Desc = 'Add aliases to a mailbox and view existing ones.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xE715 }
	@{ Name = 'Add-MailboxMember'; Desc = 'Grant FullAccess / SendAs / SendOnBehalf on a mailbox.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xE779 }
	@{ Name = 'Add-TrustedSender'; Desc = 'Add a trusted sender or domain to every mailbox in the tenant.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xE8F8 }
	@{ Name = 'Add-UnifiedGroupMember'; Desc = 'Add members to a Microsoft 365 group.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xE716 }
	@{ Name = 'Block-User'; Desc = 'Disable a user in AD and Microsoft 365, convert their mailbox to shared.'; SignIn = $true; Cat = 'Active Directory'; Icon = 0xE72E }
	@{ Name = 'Clear-RecycleBin'; Desc = 'Empty all recycle bins on this computer.'; SignIn = $false; Cat = 'System'; Icon = 0xE74D }
	@{ Name = 'Convert-UnifiedGroupToDistributionGroup'; Desc = 'Rebuild a Microsoft 365 group as a distribution list.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xE8F1 }
	@{ Name = 'Enable-Archive'; Desc = 'Enable, jumpstart or auto-expand mailbox archiving.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xE7B8 }
	@{ Name = 'Install-RequiredModules'; Desc = 'Install the Microsoft.Graph and ExchangeOnlineManagement modules.'; SignIn = $false; Cat = 'App'; Icon = 0xE896 }
	@{ Name = 'New-ADAccounts'; Desc = 'Create Active Directory accounts in bulk from a CSV.'; SignIn = $false; Cat = 'Active Directory'; Icon = 0xE7EE }
	@{ Name = 'New-ADAndEmailAccounts'; Desc = 'Create AD accounts plus licensed mailboxes in bulk.'; SignIn = $true; Cat = 'Active Directory'; Icon = 0xE7EE }
	@{ Name = 'New-EmailAccounts'; Desc = 'Create licensed Microsoft 365 accounts in bulk.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xE715 }
	@{ Name = 'Remove-DistributionListMember'; Desc = 'Remove members from a distribution list.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xE716 }
	@{ Name = 'Remove-EmailAlias'; Desc = 'Remove aliases from a mailbox.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xE715 }
	@{ Name = 'Remove-MailboxMember'; Desc = 'Revoke FullAccess / SendAs / SendOnBehalf on a mailbox.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xE779 }
	@{ Name = 'Remove-UnifiedGroupMember'; Desc = 'Remove members from a Microsoft 365 group.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xE716 }
	@{ Name = 'Update-ScriptPackage'; Desc = 'Download and install the latest release.'; SignIn = $false; Cat = 'App'; Icon = 0xE72C }
	@{ Name = 'Set-ACLPermissions'; Desc = 'Add NTFS ACL permission rules to files and folders.'; SignIn = $false; Cat = 'System'; Icon = 0xE8D7 }
	@{ Name = 'Set-NTP'; Desc = 'Check or set the Windows time source.'; SignIn = $false; Cat = 'System'; Icon = 0xE823 }
	@{ Name = 'Show-Information'; Desc = 'Script-Package Studio info and links.'; SignIn = $false; Cat = 'App'; Icon = 0xE946 }
)

$script:Categories = @('All', 'Microsoft 365', 'Active Directory', 'System', 'App')
$script:CurrentCategory = 'All'

function New-ScriptListItem($Meta) {
	$item = [System.Windows.Controls.ListBoxItem]::new()
	$item.Style = $script:StyleDict['PaletteItemStyle']
	$item.Tag = $Meta.Name

	$grid = [System.Windows.Controls.Grid]::new()
	foreach ($w in @('Auto', '*')) {
		$c = [System.Windows.Controls.ColumnDefinition]::new()
		$c.Width = if ($w -eq '*') { [System.Windows.GridLength]::new(1, 'Star') } else { [System.Windows.GridLength]::Auto }
		[void]$grid.ColumnDefinitions.Add($c)
	}

	$tile = [System.Windows.Controls.Border]::new()
	$tile.Width = 30; $tile.Height = 30
	$tile.CornerRadius = '8'
	$tile.VerticalAlignment = 'Center'
	$tile.Margin = '0,0,11,0'
	$tile.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'AccentSoftBrush')
	$glyph = [System.Windows.Controls.TextBlock]::new()
	$glyph.Text = [string][char][int]$Meta.Icon
	$glyph.FontFamily = $script:StyleDict['IconFont']
	$glyph.FontSize = 14
	$glyph.HorizontalAlignment = 'Center'
	$glyph.VerticalAlignment = 'Center'
	$glyph.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'AccentBrush')
	$tile.Child = $glyph
	[void]$grid.Children.Add($tile)

	$sp = [System.Windows.Controls.StackPanel]::new()
	$sp.VerticalAlignment = 'Center'
	$name = [System.Windows.Controls.TextBlock]::new()
	$name.Text = $Meta.Name
	$name.FontFamily = $script:StyleDict['UiFont']
	$name.FontSize = 13
	$name.FontWeight = 'SemiBold'
	$name.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'TextBrush')
	$desc = [System.Windows.Controls.TextBlock]::new()
	$desc.Text = $Meta.Desc
	$desc.Style = $script:StyleDict['Small']
	$desc.Margin = '0,2,0,0'
	$desc.TextTrimming = 'CharacterEllipsis'
	$desc.TextWrapping = 'NoWrap'
	[void]$sp.Children.Add($name)
	[void]$sp.Children.Add($desc)
	[System.Windows.Controls.Grid]::SetColumn($sp, 1)
	[void]$grid.Children.Add($sp)

	if ($Meta.SignIn) {
		$item.ToolTip = 'Requires signing in to Microsoft Graph / Exchange Online first'
	}

	$item.Content = $grid
	$item.Add_MouseDoubleClick({ param($s, $e) Invoke-ScriptByName ([string]$s.Tag) })
	return $item
}

function Update-ScriptList {
	$filter = $script:UI.SearchBox.Text.Trim()
	$list = $script:UI.ScriptList
	$list.Items.Clear()
	foreach ($s in $script:ScriptCatalog) {
		if ($script:CurrentCategory -ne 'All' -and $s.Cat -ne $script:CurrentCategory) { continue }
		if ($filter -and
			$s.Name.IndexOf($filter, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -and
			$s.Desc.IndexOf($filter, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
		[void]$list.Items.Add((New-ScriptListItem $s))
	}
	$script:UI.ScriptCountText.Text = "$($list.Items.Count) of $($script:ScriptCatalog.Count)"
	$script:UI.EmptyState.Visibility = if ($list.Items.Count -eq 0) { 'Visible' } else { 'Collapsed' }
	if (($filter -or $script:CurrentCategory -ne 'All') -and $list.Items.Count -gt 0) { $list.SelectedIndex = 0 }
}

# category filter chips
foreach ($cat in $script:Categories) {
	$chip = [System.Windows.Controls.RadioButton]::new()
	$chip.Style = $script:StyleDict['Chip']
	$chip.GroupName = 'Category'
	$chip.Content = $cat
	$chip.Tag = $cat
	$chip.FontSize = 12
	$chip.Margin = '0,0,7,0'
	if ($cat -eq 'All') { $chip.IsChecked = $true }
	$chip.Add_Checked({ param($s, $e)
		$script:CurrentCategory = [string]$s.Tag
		Update-ScriptList
	})
	[void]$script:UI.CatChipRow.Children.Add($chip)
}

# ---- run / sign-in wiring (logic unchanged) -----------------------------------
function OnRunButtonClick {
	param([string]$selectedScript)

	# Perform actions based on the selected script
	switch ($selectedScript) {
		"Add-AuthenticationPhoneMethod" { Add-AuthenticationPhoneMethod }
		"Add-AutoReply" { Add-AutoReply }
		"Add-Contacts" { Add-Contacts }
		"Add-DistributionListMember" { Add-DistributionListMember }
		"Add-EmailAlias" { Add-EmailAlias }
		"Add-MailboxMember" { Add-MailboxMember }
		"Add-TrustedSender" { Add-TrustedSender }
		"Add-UnifiedGroupMember" { Add-UnifiedGroupMember }
		"Block-User" { Block-User }
		"Clear-RecycleBin" { Clear-RecycleBin }
		"Convert-UnifiedGroupToDistributionGroup" { Convert-UnifiedGroupToDistributionGroup }
		"Enable-Archive" { Enable-Archive }
		"Install-RequiredModules" { Install-RequiredModules }
		"New-ADAccounts" { New-ADAccounts }
		"New-ADAndEmailAccounts" { New-ADAndEmailAccounts }
		"New-EmailAccounts" { New-EmailAccounts }
		"Remove-DistributionListMember" { Remove-DistributionListMember }
		"Remove-EmailAlias" { Remove-EmailAlias }
		"Remove-MailboxMember" { Add-MailboxMember }
		"Remove-UnifiedGroupMember" { Remove-UnifiedGroupMember }
		"Update-ScriptPackage" { Update-ScriptPackage }
		"Set-ACLPermissions" { Set-ACLPermissions }
		"Set-NTP" { Set-NTP }
		"Show-Information" { Show-Information }
		"Debug" { Start-Process pwsh .\MainGUI.ps1 }
		"Reload-Settings" { LoadSettings }
		default { Write-Host "No script selected." }
	}
}

function Invoke-ScriptByName([string]$Name) {
	if (-not $Name) { Write-Host "No script selected."; return }
	$script:UI.StatusText.Text = "Running $Name..."
	$script:UI.StatusDot.SetResourceReference([System.Windows.Shapes.Ellipse]::FillProperty, 'AccentBrush')
	$known = $script:ScriptCatalog | Where-Object { $_.Name -eq $Name }
	try {
		OnRunButtonClick $Name
	} finally {
		$script:UI.StatusText.Text = if ($known) { "$Name finished at $(Get-Date -Format 'HH:mm')" } else { 'Ready' }
		$script:UI.StatusDot.SetResourceReference([System.Windows.Shapes.Ellipse]::FillProperty, 'SuccessBrush')
	}
}

function Invoke-RunSelected {
	$name = $null
	if ($script:UI.ScriptList.SelectedItem) { $name = [string]$script:UI.ScriptList.SelectedItem.Tag }
	elseif ($script:UI.SearchBox.Text.Trim()) { $name = $script:UI.SearchBox.Text.Trim() }
	Invoke-ScriptByName $name
}

$script:UI.RunBtn.Add_Click({ Invoke-RunSelected })

# ---- tenant card wiring -----------------------------------------------------------
$script:UI.TenantCombo.Add_SelectionChanged({ param($s, $e)
	if ($script:SuppressTenantEvents) { return }
	$item = $s.SelectedItem
	if (-not $item) { return }
	if ($item.Tag -eq 'add') {
		# put the selection back before starting the interactive sign-in
		$script:SuppressTenantEvents = $true
		$s.SelectedIndex = if ($script:ActiveTenant) { $script:Tenants.IndexOf($script:ActiveTenant) } else { -1 }
		$script:SuppressTenantEvents = $false
		Add-TenantSignIn
		return
	}
	if ($script:ActiveTenant -ne $item.Tag) { Connect-Tenant $item.Tag }
})

$script:UI.ConnectBtn.Add_Click({
	if ($script:ActiveTenant) {
		Disconnect-Tenant
		return
	}
	$sel = Get-SelectedTenant
	if ($sel) { Connect-Tenant $sel } else { Add-TenantSignIn }
})

$script:UI.ForgetTenantBtn.Add_Click({
	$sel = Get-SelectedTenant
	if (-not $sel) { return }
	if ($script:ActiveTenant -eq $sel) { Disconnect-Tenant }
	[void]$script:Tenants.Remove($sel)
	Save-Tenants
	Write-Host "Removed tenant '$($sel.name)' ($($sel.account)) from the list."
	Update-TenantCombo
})
$script:UI.SearchBox.Add_TextChanged({
	$script:UI.SearchHint.Visibility = if ($script:UI.SearchBox.Text) { 'Collapsed' } else { 'Visible' }
	Update-ScriptList
})
$script:UI.ScriptList.Add_KeyDown({ param($s, $e)
	if ($e.Key -eq 'Return') { Invoke-RunSelected; $e.Handled = $true }
})

# ---- activity log wiring ---------------------------------------------------------
$script:UI.LogToggleBtn.Add_Click({ Set-LogExpanded (-not $script:Settings.logExpanded); Save-AppSettings })
$script:UI.LogClearBtn.Add_Click({
	$script:UI.LogList.Items.Clear()
	$script:UI.LogCountText.Text = ''
})
$script:UI.LogCopyBtn.Add_Click({
	$text = ($script:UI.LogList.Items | ForEach-Object { $_.Text }) -join "`r`n"
	if ($text) { [System.Windows.Clipboard]::SetText($text) }
})

# ---- keyboard shortcuts ------------------------------------------------------------
$script:Window.Add_PreviewKeyDown({ param($s, $e)
	$ctrl = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control
	if ($ctrl) {
		switch ($e.Key) {
			'F' { $script:UI.SearchBox.Focus() | Out-Null; $script:UI.SearchBox.SelectAll(); $e.Handled = $true }
			'L' { Set-LogExpanded (-not $script:Settings.logExpanded); Save-AppSettings; $e.Handled = $true }
		}
	} elseif ($e.Key -eq 'Escape' -and $script:UI.SearchBox.Text) {
		$script:UI.SearchBox.Text = ''
		$e.Handled = $true
	}
})

# ---- window chrome -------------------------------------------------------------
$script:UI.MinBtn.Add_Click({ $script:Window.WindowState = 'Minimized' })
$script:UI.MaxBtn.Add_Click({
	$script:Window.WindowState = if ($script:Window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }
})
$script:UI.CloseBtn.Add_Click({ $script:Window.Close() })
$script:Window.Add_StateChanged({
	if ($script:Window.WindowState -eq 'Maximized') {
		$script:UI.Root.Margin = '7'
		$script:UI.MaxBtn.Content = [char]0xE923
	} else {
		$script:UI.Root.Margin = '0'
		$script:UI.MaxBtn.Content = [char]0xE922
	}
})

# ---- theme toggle ---------------------------------------------------------------
$script:UI.ThemeBtn.Add_Click({
	$next = if ($script:Settings.theme -eq 'Dark') { 'Light' } else { 'Dark' }
	Apply-Theme $next
	Save-AppSettings
})

# ---- shutdown (same disconnect behavior as before, guarded so a missing
# ---- module can't block the window from closing) ---------------------------------
$script:Window.Add_Closing({ param($s, $e)
	if ($env:SP_SHOT) { return }
	$script:Settings.winWidth = [int]$script:Window.Width
	$script:Settings.winHeight = [int]$script:Window.Height
	$script:Settings.winMaximized = $script:Window.WindowState -eq 'Maximized'
	Save-AppSettings
	try { Disconnect-ExchangeOnline -Confirm:$false } catch {}
	try { Disconnect-Graph } catch {}
})

# ---- startup ----------------------------------------------------------------------
# the scripts write transcripts to .\Logs, which is gitignored (transcripts
# contain usernames/machine names) - make sure it exists on fresh clones
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Logs'))) {
	New-Item -ItemType Directory -Path (Join-Path $PSScriptRoot 'Logs') -Force | Out-Null
}

$script:Window.Width = [double]$script:Settings.winWidth
$script:Window.Height = [double]$script:Settings.winHeight
if ($script:Settings.winMaximized) { $script:Window.WindowState = 'Maximized' }
Set-LogExpanded ([bool]$script:Settings.logExpanded)
Apply-Theme $script:Settings.theme
Load-Tenants
Update-TenantCombo
if ($script:Tenants.Count -gt 0) {
	Set-SignState $false 'Not connected - pick a tenant above, or click Connect.'
}
$missingModules = @(Get-MissingModules)
if ($missingModules.Count -gt 0) {
	Set-SignState $false "Missing modules: $($missingModules -join ', ') - you will be offered an install on sign-in."
}
Update-ScriptList

Write-Host "Loaded MainGUI."
if (-not $env:SP_SHOT) { CheckForErrors }

# ---- automated screenshot hook (set SP_SHOT to an output dir): renders the main
# ---- window and every dialog in both themes, then exits -----------------------------
if ($env:SP_SHOT) {
	function Save-VisualShot($Visual, [string]$Path) {
		$w = [int][Math]::Ceiling($Visual.ActualWidth)
		$h = [int][Math]::Ceiling($Visual.ActualHeight)
		if ($w -le 0 -or $h -le 0) { return }
		$rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
		$rtb.Render($Visual)
		$enc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
		$enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
		$fs = [System.IO.FileStream]::new($Path, 'Create')
		$enc.Save($fs)
		$fs.Close()
	}

	$script:ShotBuilders = [ordered]@{
		'dlg-add-2fa'            = { New-AuthenticationPhoneDialog }
		'dlg-add-autoreply'      = { New-AutoReplyDialog }
		'dlg-add-contacts'       = { New-AddContactsDialog }
		'dlg-add-distlistmember' = { New-MemberGroupDialog -Title 'Add-DistributionListMember' -ActionText 'Add Member' -BulkText 'Add Members' }
		'dlg-add-emailalias'     = { New-EmailAliasDialog }
		'dlg-add-mailboxmember'  = { New-MailboxMemberDialog }
		'dlg-add-trustedsender'  = { New-TrustedSenderDialog }
		'dlg-block-user'         = { New-BlockUserDialog }
		'dlg-block-addmember'    = { New-BlockAddMemberDialog }
		'dlg-block-autoreply'    = { New-BlockAutoReplyDialog }
		'dlg-clear-recyclebin'   = { New-ClearRecycleBinDialog }
		'dlg-convert-group'      = { New-ConvertGroupDialog }
		'dlg-enable-archive'     = { New-EnableArchiveDialog }
		'dlg-new-adaccounts'     = { New-ADAccountsDialog -ForestName 'contoso.local' }
		'dlg-new-ademail'        = { New-ADAndEmailAccountsDialog -ForestName 'contoso.local' }
		'dlg-new-emailaccounts'  = { New-EmailAccountsDialog }
		'dlg-set-acl'            = { New-AclPermissionsDialog -DomainName 'CONTOSO' -UserGroupList @('Administrator', 'Domain Admins', 'Domain Users') }
		'dlg-remove-emailalias'  = { New-EmailAliasDialog -Title 'Remove-EmailAlias' -ActionText 'Remove Alias' -BulkText 'Remove Aliases' -CheckText 'Remove Incremental Aliases' }
		'dlg-set-ntp'            = { New-SetNTPDialog }
		'dlg-show-information'   = { New-InformationDialog }
		'dlg-error'              = { New-ErrorDialog "Example error output`nAnother line of error detail" }
		'dlg-opcomplete'         = { New-OperationCompleteDialog }
		'dlg-warning'            = { New-WarningDialog "Turning on AutoExpandingArchive is irreversible - are you sure you'd like to continue?" }
		'dlg-updatecomplete'     = { New-UpdateCompleteDialog "Latest version already installed." }
		'dlg-modules'            = { New-ModulesMissingDialog "Microsoft.Graph`nExchangeOnlineManagement" }
	}

	$script:Window.Add_ContentRendered({
		try {
			$outDir = $env:SP_SHOT
			New-Item -ItemType Directory -Path $outDir -Force | Out-Null
			Write-Host "Example activity entry" -ForegroundColor Cyan
			Write-Host "Example warning entry" -ForegroundColor Red
			# sample tenants so the switcher renders populated
			$script:Tenants.Clear()
			$script:Tenants.Add([pscustomobject]@{ name = 'Contoso Ltd'; account = 'admin@contoso.com'; tenantId = '00000000-0000-0000-0000-000000000001'; lastUsed = (Get-Date).ToString('o') })
			$script:Tenants.Add([pscustomobject]@{ name = 'Fabrikam Inc'; account = 'admin@fabrikam.com'; tenantId = '00000000-0000-0000-0000-000000000002'; lastUsed = '' })
			$script:ActiveTenant = $script:Tenants[0]
			Update-TenantCombo
			Set-SignState $true 'Connected to Contoso Ltd as admin@contoso.com'
			foreach ($themeName in @('Dark', 'Light')) {
				Apply-Theme $themeName
				$script:Window.UpdateLayout()
				$script:Window.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
				Save-VisualShot $script:UI.RootBorder (Join-Path $outDir "main-$themeName.png")
				Set-LogExpanded $true
				$script:Window.UpdateLayout()
				$script:Window.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
				Save-VisualShot $script:UI.RootBorder (Join-Path $outDir "main-log-$themeName.png")
				Set-LogExpanded $false
				foreach ($key in $script:ShotBuilders.Keys) {
					$dlg = & $script:ShotBuilders[$key]
					$dlg.WindowStartupLocation = 'Manual'
					$dlg.Left = 40; $dlg.Top = 40
					$dlg.ShowActivated = $false
					$dlg.Show()
					$dlg.UpdateLayout()
					$dlg.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
					Save-VisualShot $dlg.Content (Join-Path $outDir "$key-$themeName.png")
					$dlg.Close()
				}
			}
			Apply-Theme 'Dark'
		} catch {
			Set-Content -Path (Join-Path $env:SP_SHOT 'error.txt') -Value ($_ | Out-String)
		}
		$script:Window.Close()
	})
}

# ---- automation hook (dot-sources a script into app scope; used by self-tests) ------
if ($env:SP_TEST -and (Test-Path -LiteralPath $env:SP_TEST)) {
	. $env:SP_TEST
}

# Show MainWindow
[void]$script:Window.ShowDialog()
