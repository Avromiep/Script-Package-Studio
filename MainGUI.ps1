$version = "v3.1.88"
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

# Give the process its own taskbar identity. Without this the window is grouped
# under pwsh.exe and the taskbar shows the PowerShell icon instead of the app's.
# Must run before the window is created.
try {
	$aumidSig = '[DllImport("shell32.dll")] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);'
	$aumidType = Add-Type -MemberDefinition $aumidSig -Name 'AppUserModelId' -Namespace 'SPS' -PassThru -ErrorAction Stop
	[void]$aumidType::SetCurrentProcessExplicitAppUserModelID('Avromiep.ScriptPackageStudio')
} catch {}

$script:SrcDir = Join-Path $PSScriptRoot 'src'
$script:SettingsIniPath = Join-Path $PSScriptRoot 'settings.ini'

. (Join-Path $script:SrcDir 'ui.ps1')

# ---- settings (persisted in settings.ini) -----------------------------------
$script:Settings = @{
	theme           = 'Dark'
	winWidth        = 560
	winHeight       = 760
	winMaximized    = $false
	logExpanded     = $false
	blurTenant      = $false
	recipientSearch = $true
	bgSearch        = $true
}

function Read-AppSettings {
	if (-not (Test-Path -LiteralPath $script:SettingsIniPath)) { return }
	foreach ($line in (Get-Content -LiteralPath $script:SettingsIniPath -ErrorAction Ignore)) {
		if ($line -match '^\s*Theme\s*=\s*(Dark|Light)\s*$') { $script:Settings.theme = $Matches[1] }
		elseif ($line -match '^\s*WinWidth\s*=\s*(\d+)\s*$') { $script:Settings.winWidth = [Math]::Max(470, [int]$Matches[1]) }
		elseif ($line -match '^\s*WinHeight\s*=\s*(\d+)\s*$') { $script:Settings.winHeight = [Math]::Max(560, [int]$Matches[1]) }
		elseif ($line -match '^\s*WinMaximized\s*=\s*(0|1)\s*$') { $script:Settings.winMaximized = $Matches[1] -eq '1' }
		elseif ($line -match '^\s*LogExpanded\s*=\s*(0|1)\s*$') { $script:Settings.logExpanded = $Matches[1] -eq '1' }
		elseif ($line -match '^\s*BlurTenant\s*=\s*(0|1)\s*$') { $script:Settings.blurTenant = $Matches[1] -eq '1' }
		elseif ($line -match '^\s*RecipientSearch\s*=\s*(0|1)\s*$') { $script:Settings.recipientSearch = $Matches[1] -eq '1' }
		elseif ($line -match '^\s*BackgroundSearch\s*=\s*(0|1)\s*$') { $script:Settings.bgSearch = $Matches[1] -eq '1' }
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
			BlurTenant   = if ($script:Settings.blurTenant) { '1' } else { '0' }
			RecipientSearch = if ($script:Settings.recipientSearch) { '1' } else { '0' }
			BackgroundSearch = if ($script:Settings.bgSearch) { '1' } else { '0' }
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

# Use the icon font bundled with the app so glyphs render on EVERY Windows
# version. The Segoe Fluent Icons / Segoe MDL2 Assets fonts only ship with
# Windows 10/11 - on Windows Server 2012/2016 and older, they are missing and
# every icon shows as an empty box. Fluent System Icons (MIT) travels with us.
try {
	# Build the FontFamily via its TypeConverter, not New-Object: only a
	# converter-created FontFamily survives being applied through DynamicResource
	# (a New-Object one re-parses its source string and throws). The source is an
	# absolute, %20-encoded file URI so it holds even with spaces in the path.
	$iconFontRef = ([Uri]((Join-Path $PSScriptRoot 'Fonts') + '\')).AbsoluteUri + '#FluentSystemIcons-Resizable'
	$iconFontConv = [System.ComponentModel.TypeDescriptor]::GetConverter([System.Windows.Media.FontFamily])
	$script:StyleDict['IconFont'] = $iconFontConv.ConvertFromString($iconFontRef)
} catch {}

# ---- global TextBox behaviors (every TextBox in the app, dialogs included) --------
# Ctrl+Shift+V pastes (like Ctrl+V); double-clicking a text box selects all its text.
[System.Windows.EventManager]::RegisterClassHandler(
	[System.Windows.Controls.TextBox],
	[System.Windows.UIElement]::PreviewKeyDownEvent,
	[System.Windows.Input.KeyEventHandler] {
		param($s, $e)
		$mods = [System.Windows.Input.Keyboard]::Modifiers
		if ($e.Key -eq 'V' -and $mods -eq ([System.Windows.Input.ModifierKeys]::Control -bor [System.Windows.Input.ModifierKeys]::Shift)) {
			if ([System.Windows.Clipboard]::ContainsText()) { $s.Paste() }
			$e.Handled = $true
		}
	})
[System.Windows.EventManager]::RegisterClassHandler(
	[System.Windows.Controls.TextBox],
	[System.Windows.Controls.Control]::MouseDoubleClickEvent,
	[System.Windows.Input.MouseButtonEventHandler] {
		param($s, $e)
		$s.SelectAll()
	})

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
						<Image x:Name="TitleIcon" Width="28" Height="28" VerticalAlignment="Center"
							   RenderOptions.BitmapScalingMode="HighQuality"/>
						<TextBlock Text="Script-Package Studio" Margin="10,0,0,0" VerticalAlignment="Center"
								   FontFamily="{DynamicResource UiFont}" FontSize="13.5" FontWeight="SemiBold"
								   Foreground="{DynamicResource TextBrush}"/>
						<TextBlock Text="$version" Margin="8,1,0,0" VerticalAlignment="Center"
								   Style="{DynamicResource Small}"/>
					</StackPanel>
					<StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
						<Button x:Name="SettingsBtn" Style="{DynamicResource IconBtn}" Margin="0,7,6,0"
								ToolTip="Settings" WindowChrome.IsHitTestVisibleInChrome="True">
							<Path Width="15" Height="15" Stretch="Uniform" Fill="{DynamicResource TextBrush}"
								  Data="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94L14.4 2.81c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41L9.25 5.35C8.66 5.59 8.12 5.92 7.63 6.29L5.24 5.33c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.07.63-.07.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/>
						</Button>
						<Button x:Name="ThemeBtn" Style="{DynamicResource IconBtn}" Margin="0,7,6,0"
								ToolTip="Toggle dark / light theme" WindowChrome.IsHitTestVisibleInChrome="True">
							<TextBlock x:Name="ThemeIcon" Text="&#xF597;" FontFamily="{DynamicResource IconFont}" FontSize="14"/>
						</Button>
						<Button x:Name="MinBtn" Style="{DynamicResource TitleBtn}" Content="&#xF1A3;" Height="36"
								WindowChrome.IsHitTestVisibleInChrome="True"/>
						<Button x:Name="MaxBtn" Style="{DynamicResource TitleBtn}" Content="&#xEC2A;" Height="36"
								WindowChrome.IsHitTestVisibleInChrome="True"/>
						<Button x:Name="CloseBtn" Style="{DynamicResource TitleBtnClose}" Content="&#xE6D3;" Height="36"
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
							<ColumnDefinition Width="Auto"/>
						</Grid.ColumnDefinitions>
						<Ellipse x:Name="SignDot" Width="9" Height="9" Fill="{DynamicResource WarnBrush}"
								 VerticalAlignment="Center" Margin="0,0,11,0"/>
						<ComboBox x:Name="TenantCombo" Grid.Column="1" VerticalAlignment="Center" MinHeight="32"
								  ToolTip="Choose which Microsoft tenant to use. Selecting a tenant connects to it."/>
						<Button x:Name="BlurTenantBtn" Grid.Column="2" Style="{DynamicResource IconBtn}"
								Margin="6,0,0,0" ToolTip="Hide the tenant / account for screenshots">
							<TextBlock x:Name="BlurIcon" Text="&#xE883;" FontFamily="{DynamicResource IconFont}" FontSize="14"/>
						</Button>
						<Button x:Name="ForgetTenantBtn" Grid.Column="3" Style="{DynamicResource IconBtn}"
								Content="&#xE66D;" Margin="2,0,0,0"
								ToolTip="Forget the selected tenant (removes it from this list)"/>
						<Grid Grid.Column="4" Margin="8,0,0,0" VerticalAlignment="Center">
							<Button x:Name="ConnectBtn" Style="{DynamicResource BtnPrimary}" Content="Sign In" MinWidth="96"/>
							<StackPanel x:Name="ConnectedGroup" Visibility="Collapsed">
								<TextBlock Text="Connected" Foreground="{DynamicResource SuccessBrush}" FontSize="11"
										   HorizontalAlignment="Center" Margin="0,0,0,3"/>
								<Button x:Name="DisconnectBtn" Style="{DynamicResource BtnSecondary}" Content="Disconnect" MinWidth="96"/>
							</StackPanel>
						</Grid>
						<TextBlock x:Name="SignStatusText" Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="4"
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
								<StackPanel x:Name="SearchStatusPanel" Orientation="Horizontal" VerticalAlignment="Center"
											Margin="16,2,0,0" Visibility="Collapsed" ToolTip="Status of name/email search - not a button">
									<TextBlock x:Name="SearchStatusIcon" Text="&#xEFD7;" FontFamily="{DynamicResource IconFont}" FontSize="13"
											   Foreground="{DynamicResource TextFaintBrush}" VerticalAlignment="Center"/>
									<TextBlock x:Name="SearchStatusLabel" Text="Preparing search" Style="{DynamicResource Small}"
											   Margin="5,0,0,0" VerticalAlignment="Center"/>
									<Border x:Name="SearchStatusBar" Width="64" Height="4" Margin="9,0,2,0" VerticalAlignment="Center"
											CornerRadius="2" ClipToBounds="True" Background="{DynamicResource StrokeSoftBrush}" Visibility="Collapsed">
										<Border x:Name="SearchStatusBarSeg" Width="26" Height="4" CornerRadius="2" HorizontalAlignment="Left"
												Background="{DynamicResource AccentBrush}">
											<Border.RenderTransform><TranslateTransform x:Name="SearchStatusBarTT"/></Border.RenderTransform>
										</Border>
									</Border>
								</StackPanel>
							</StackPanel>
						</Grid>
						<Grid Grid.Row="1" Margin="0,10,0,0">
							<TextBox x:Name="SearchBox" MinHeight="30" Padding="30,5,32,5"
									 ToolTip="Search scripts  (Ctrl+F)"/>
							<TextBlock Text="&#xEFD7;" FontFamily="{DynamicResource IconFont}" FontSize="13"
									   Foreground="{DynamicResource TextFaintBrush}" IsHitTestVisible="False"
									   Margin="10,0,0,0" VerticalAlignment="Center"/>
							<TextBlock x:Name="SearchHint" Text="Search scripts...   (Ctrl+F)" Style="{DynamicResource Small}"
									   Margin="32,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
							<Button x:Name="SearchClearBtn" Style="{DynamicResource IconBtn}" Width="24" Height="24"
									HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,3,0"
									Visibility="Collapsed" ToolTip="Clear search">
								<TextBlock Text="&#xE6D3;" FontFamily="{DynamicResource IconFont}" FontSize="12"/>
							</Button>
						</Grid>
						<StackPanel x:Name="CatChipRow" Grid.Row="2" Orientation="Horizontal" Margin="0,10,0,0"/>
						<Grid Grid.Row="3">
							<ListBox x:Name="ScriptList" Margin="0,10,0,0" Background="Transparent"
									 BorderThickness="0" ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
							<StackPanel x:Name="EmptyState" VerticalAlignment="Center" HorizontalAlignment="Center"
										Visibility="Collapsed">
								<TextBlock Text="&#xEFD7;" FontFamily="{DynamicResource IconFont}" FontSize="22"
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
								<TextBlock x:Name="LogToggleIcon" Text="&#xE490;" FontFamily="{DynamicResource IconFont}" FontSize="10"/>
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
				<!-- Progress bar spans the FULL WIDTH along the bottom, UNDERNEATH the status text, so it can
				     never overlap a long "<script> finished at ..." message no matter how long the text is. -->
				<Grid>
					<Grid.RowDefinitions>
						<RowDefinition Height="*"/>
						<RowDefinition Height="Auto"/>
					</Grid.RowDefinitions>
					<Grid Grid.Row="0" Margin="14,0" VerticalAlignment="Center">
						<Grid.ColumnDefinitions>
							<ColumnDefinition Width="Auto"/>
							<ColumnDefinition Width="*"/>
						</Grid.ColumnDefinitions>
						<Ellipse x:Name="StatusDot" Grid.Column="0" Width="8" Height="8" Fill="{DynamicResource SuccessBrush}"
								 VerticalAlignment="Center"/>
						<TextBlock x:Name="StatusText" Grid.Column="1" Text="Ready" Style="{DynamicResource Dim}"
								   Margin="8,0,14,0" VerticalAlignment="Center" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
					</Grid>
					<ProgressBar x:Name="MainProgress" Grid.Row="1" Height="4" Maximum="100"
							 Margin="14,0,14,6" HorizontalAlignment="Stretch" VerticalAlignment="Bottom"
							 Background="{DynamicResource StrokeSoftBrush}" BorderThickness="0"/>
				</Grid>
			</Border>
		</Grid>
	</Border>
</Window>
"@

$script:Window = Read-XamlString $mainXaml
[void]$script:Window.Resources.MergedDictionaries.Add($script:StyleDict)

$script:UI = @{}
foreach ($n in @('RootBorder','Root','TitleIcon','SettingsBtn','ThemeBtn','ThemeIcon','MinBtn','MaxBtn','CloseBtn',
		'SignDot','SignStatusText','TenantCombo','BlurTenantBtn','BlurIcon','ForgetTenantBtn','ConnectBtn','ConnectedGroup','DisconnectBtn',
		'ScriptCountText','SearchBox','SearchHint','SearchClearBtn','CatChipRow','ScriptList','EmptyState','RunBtn',
		'LogToggleBtn','LogToggleIcon','LogCountText','LogCopyBtn','LogClearBtn','LogList',
		'StatusDot','StatusText','SearchStatusPanel','SearchStatusIcon','SearchStatusLabel','SearchStatusBar','SearchStatusBarTT','MainProgress')) {
	$el = $script:Window.FindName($n)
	if (-not $el) { throw "XAML element '$n' not found" }
	$script:UI[$n] = $el
}

# Register the home-screen search-status light as a status target (starts its sliding-bar anim +
# paints the current state). Recipient dialogs register their own copy so all stay in sync.
try { [void](Register-AcStatusTarget $script:UI.SearchStatusPanel $script:UI.SearchStatusIcon $script:UI.SearchStatusLabel $script:UI.SearchStatusBar $script:UI.SearchStatusBarTT) } catch {}

# load the largest frame from the multi-size .ico so the taskbar / Alt-Tab icon
# is crisp (BitmapImage alone would grab the 16px frame and upscale it)
try {
	$icoDec = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
		[Uri](Join-Path $PSScriptRoot 'Images\logo.ico'),
		[System.Windows.Media.Imaging.BitmapCreateOptions]::None,
		[System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
	$script:Window.Icon = ($icoDec.Frames | Sort-Object PixelWidth -Descending | Select-Object -First 1)
} catch {}

# same logo in the in-app title bar (top-left)
try {
	$script:UI.TitleIcon.Source = New-ImageSource (Join-Path $PSScriptRoot 'Images\logo.png')
} catch {}

# Global safety net: if any action throws an unhandled error mid-way (e.g. a
# cmdlet fails), show it instead of the action silently stopping with no
# feedback. Skipped in screenshot mode so automated runs never block on a modal.
if (-not $env:SP_SHOT) {
	$script:Window.Dispatcher.Add_UnhandledException({ param($s, $e)
		try {
			Write-Host "Error: $($e.Exception.Message)" -ForegroundColor Red
			[void](New-ErrorDialog (($e.Exception | Out-String).Trim())).ShowDialog()
		} catch {}
		$e.Handled = $true
	})
}

# Gentle "breathing" pulse on the progress bar while a script is running, so it never looks frozen.
# Opacity is an INDEPENDENT animation (runs on WPF's render thread), so it keeps moving even while a
# script blocks the UI thread mid-call - unlike the Value bar, which can only step between milestones.
$script:ProgPulsing = $false
function Start-ProgressPulse {
	if ($script:ProgPulsing) { return }
	try {
		$pb = $script:UI.MainProgress
		$a = New-Object System.Windows.Media.Animation.DoubleAnimation
		$a.From = 0.4; $a.To = 1.0
		$a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds(0.7))
		$a.AutoReverse = $true
		$a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
		$pb.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
		$script:ProgPulsing = $true
	} catch {}
}
function Stop-ProgressPulse {
	if (-not $script:ProgPulsing) { return }
	try { $pb = $script:UI.MainProgress; $pb.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null); $pb.Opacity = 1 } catch {}
	$script:ProgPulsing = $false
}

# $progressBar1 keeps the WinForms-era contract every script uses
# ($progressBar1.Value = n) and pumps the dispatcher so updates paint during
# synchronous work, like the old WinForms progress bar did.
$progressBar1 = [pscustomobject]@{}
$progressBar1 | Add-Member -MemberType ScriptProperty -Name Value `
	-Value { $script:UI.MainProgress.Value } `
	-SecondValue {
		param($v)
		$pb = $script:UI.MainProgress
		$target = [double]$v
		# Glide smoothly to the new value (ease-out) instead of snapping between milestones - looks
		# cleaner and reads as steadier progress. Reset (0) snaps instantly so it doesn't slide down.
		try {
			if ($target -le 0) {
				Stop-ProgressPulse                          # idle - stop the breathing pulse
				$script:ProgTarget = 0                      # reset the self-advancing loop ticker
				$pb.BeginAnimation([System.Windows.Controls.Primitives.RangeBase]::ValueProperty, $null)
				$pb.Value = 0
			} else {
				Start-ProgressPulse                         # a script is working - keep it visibly alive
				$anim = New-Object System.Windows.Media.Animation.DoubleAnimation
				$anim.To = $target
				$anim.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(280))
				$anim.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase
				$pb.BeginAnimation([System.Windows.Controls.Primitives.RangeBase]::ValueProperty, $anim)
			}
		} catch { try { $pb.Value = $target } catch {} }
		try { $pb.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render) } catch {}
	}

# Drive the progress bar smoothly across the items of a loop: call it after each item with how many
# are done out of the total, and it maps that to a value between $Lo and $Hi. Every set forces a
# repaint (via the proxy above), so the bar visibly climbs as a batch works through its items,
# instead of jumping only at the end. Start a script at $Lo and finish at 100 either side of this.
function Set-LoopProgress([int]$Done, [int]$Total, [int]$Lo = 12, [int]$Hi = 95) {
	if ($Total -le 0) { return }
	$v = $Lo + [int](($Hi - $Lo) * $Done / $Total)
	if ($v -gt $Hi) { $v = $Hi } elseif ($v -lt $Lo) { $v = $Lo }
	$progressBar1.Value = $v
}

# Self-advancing progress tick for loops where the item count isn't handy: call it once per item and
# it nudges the bar a fraction of the way toward ~93% (so it always moves forward, faster on fast
# items, and never quite finishes until the script sets 100). No total needed. It tracks its own
# target (not the mid-animation Value) so a fast loop keeps climbing; it resets when the bar goes idle.
$script:ProgTarget = 0
function Step-Progress {
	if ($script:ProgTarget -lt 8 -or $script:ProgTarget -ge 100) { $script:ProgTarget = 8 }
	$script:ProgTarget = $script:ProgTarget + [Math]::Max(1, [int]((93 - $script:ProgTarget) * 0.16))
	if ($script:ProgTarget -gt 93) { $script:ProgTarget = 93 }
	$progressBar1.Value = $script:ProgTarget
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
$script:GraphScopes = @("User.ReadWrite.All", "Directory.ReadWrite.All", "User.Invite.All", "Group.ReadWrite.All", "UserAuthenticationMethod.ReadWrite.All")

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

# On launch, if the required modules aren't installed yet, offer to install them.
# (PowerShell 7 itself is handled earlier by the launcher, so the user is prompted
# for PowerShell 7 first, then the modules here.)
function Confirm-ModulesAtStartup {
	$missing = @(Get-MissingModules)
	if ($missing.Count -eq 0) { return }
	Write-Host "Required modules not installed: $($missing -join ', ')" -ForegroundColor Yellow
	$choice = @{ Install = $false }
	$dlg = New-ModulesMissingDialog ($missing -join "`n") 'Script-Package Studio needs these PowerShell modules, which are not installed yet:'
	try { $dlg.Owner = $script:Window } catch {}
	$dlg.FindName('InstallBtn').Add_Click({ $choice.Install = $true; $dlg.Close() })
	$dlg.FindName('NotNowBtn').Add_Click({ $dlg.Close() })
	[void]$dlg.ShowDialog()
	if ($choice.Install) {
		$script:UI.StatusText.Text = 'Installing modules... this can take several minutes.'
		$script:Window.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Render)
		Install-RequiredModules
		$script:UI.StatusText.Text = 'Ready'
	}
}

function Set-SignState([bool]$Connected, [string]$Text) {
	$brush = if ($Connected) { 'SuccessBrush' } else { 'WarnBrush' }
	$script:UI.SignDot.SetResourceReference([System.Windows.Shapes.Ellipse]::FillProperty, $brush)
	$script:UI.SignStatusText.Text = $Text
}

# Show an in-progress state on the Connect/Disconnect button while a sign-in runs, so
# it's clear the tenant isn't connected yet. Rendered before the (UI-thread-blocking)
# connect so the user actually sees it; Update-TenantCombo resets it (to 'Connected' /
# 'Connect') and re-enables the button when the sign-in finishes.
function Set-ConnectingButton {
	$script:UI.ConnectedGroup.Visibility = 'Collapsed'
	$script:UI.ConnectBtn.Visibility = 'Visible'
	$script:UI.ConnectBtn.Content = 'Connecting...'
	$script:UI.ConnectBtn.IsEnabled = $false
	$script:UI.ConnectBtn.ToolTip = $null
	$script:Window.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Render)
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
		$script:UI.ConnectBtn.IsEnabled = $true
		if ($script:ActiveTenant) {
			# Connected: hide the Connect button; show the small "Connected" label + Disconnect button.
			$script:UI.ConnectBtn.Visibility = 'Collapsed'
			$script:UI.ConnectedGroup.Visibility = 'Visible'
		} else {
			$script:UI.ConnectedGroup.Visibility = 'Collapsed'
			$script:UI.ConnectBtn.Visibility = 'Visible'
			$script:UI.ConnectBtn.Content = if ($script:Tenants.Count -gt 0) { 'Connect' } else { 'Sign In' }
			$script:UI.ConnectBtn.ToolTip = $null
		}
	} finally {
		$script:SuppressTenantEvents = $false
	}
}

function Get-SelectedTenant {
	$item = $script:UI.TenantCombo.SelectedItem
	if ($item -and $item.Tag -ne 'add') { return $item.Tag }
	return $null
}

# fix A for the "second interactive sign-in freezes" deadlock. Connect-MgGraph and
# Connect-ExchangeOnline block the UI thread while doing async MSAL token work. WPF
# installs a DispatcherSynchronizationContext on the UI thread, so those awaited
# continuations try to resume ON the (blocked) UI thread -> deadlock, which froze
# the 2nd sign-in in a session. Running the cmdlet with the context temporarily
# cleared lets the continuations resume on the thread pool instead, so the cmdlet
# can return. Restored in finally so the rest of the app keeps its dispatcher context.
function Invoke-WithoutDispatcherContext([scriptblock]$Script) {
	$old = [System.Threading.SynchronizationContext]::Current
	[System.Threading.SynchronizationContext]::SetSynchronizationContext($null)
	try { & $Script } finally { [System.Threading.SynchronizationContext]::SetSynchronizationContext($old) }
}

# Connect to Exchange Online. -SkipLoadingCmdletHelp only exists in newer
# ExchangeOnlineManagement versions, so pass it only when the installed module
# supports it (older versions on other machines threw a parameter error).
function Connect-Exo([string]$Upn) {
	$p = @{ ShowBanner = $false }
	if ($Upn) { $p.UserPrincipalName = $Upn }
	$cmd = Get-Command Connect-ExchangeOnline -ErrorAction SilentlyContinue
	if ($cmd -and $cmd.Parameters.ContainsKey('SkipLoadingCmdletHelp')) { $p.SkipLoadingCmdletHelp = $true }
	# THE tenant-switch freeze fix. Since ExchangeOnlineManagement v3.7.0, Web Account
	# Manager (WAM) is the default auth broker. WAM shows an IN-PROCESS dialog that
	# needs this thread's message pump - but Connect-ExchangeOnline runs synchronously
	# on the (now-blocked) WPF UI thread, so on a switch that needs interactive auth
	# the dialog can never pump and the app deadlocks forever (progress stuck ~50%).
	# -DisableWAM forces the out-of-process browser flow (same as Connect-MgGraph),
	# which completes without the pump. Pass it on EVERY connect (WAM can't be
	# disabled once initialized in the process). Only exists in v3.7.0+.
	if ($cmd -and $cmd.Parameters.ContainsKey('DisableWAM')) { $p.DisableWAM = $true }
	# Clear the WPF dispatcher sync context INLINE (fix A for the sign-in deadlock) - do
	# NOT route this through Invoke-WithoutDispatcherContext {...}.GetNewClosure(). A
	# closure runs in a throwaway dynamic MODULE scope, and Connect-ExchangeOnline IMPORTS
	# its cmdlets (Get-Mailbox, Get-MailboxAutoReplyConfiguration, Set-Mailbox, ...) into
	# the CALLING scope - so wrapped, every Exchange cmdlet vanished after connect
	# ("not recognized as a cmdlet"). Calling it directly here keeps the import in the
	# app's runspace scope so the scripts can use those cmdlets.
	$oldCtx = [System.Threading.SynchronizationContext]::Current
	[System.Threading.SynchronizationContext]::SetSynchronizationContext($null)
	try { Connect-ExchangeOnline @p }
	finally { [System.Threading.SynchronizationContext]::SetSynchronizationContext($oldCtx) }
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
	Set-ConnectingButton

	# Silent switch: keep the previous session's cached tokens (do NOT Disconnect-MgGraph
	# first) and reconnect with -TenantId. With a cached token this is silent and instant
	# - no browser, no account picker. If the token isn't cached (new account, or the
	# cache was cleared/expired), Microsoft's normal browser sign-in appears - which no
	# longer freezes thanks to Invoke-WithoutDispatcherContext (the sync-context fix).
	Invoke-WithoutDispatcherContext { Connect-MgGraph -TenantId $Tenant.tenantId -Scopes $script:GraphScopes }
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

	# Connect-Exo passes -DisableWAM so this uses the out-of-process browser instead
	# of the in-process WAM dialog that used to deadlock the UI thread on a switch.
	$script:UI.StatusText.Text = 'Finishing sign-in (Exchange Online)...'
	try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction Ignore } catch {}
	Connect-Exo $Tenant.account
	$progressBar1.Value = 80
	CheckForErrors
	Write-Host "Connected to Exchange"
	# Connect the background-search worker + build the recipient index NOW (non-blocking), so by the
	# time the user opens a search box the index is loaded and searches are instant.
	try { Start-AcWarmup } catch {}

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
	Set-ConnectingButton

	# drop the current Graph context so the account picker appears instead of a
	# silent reconnect to the previous account
	try { Disconnect-MgGraph -ErrorAction Ignore | Out-Null } catch {}
	$Error.Clear()

	Invoke-WithoutDispatcherContext { Connect-MgGraph -Scopes $script:GraphScopes }
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

	Set-SignState $false 'Finishing sign-in (Exchange Online)...'
	$script:Window.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Render)

	# Drop any existing Exchange session first. Without this, adding a second
	# tenant while one is already connected hangs Connect-ExchangeOnline (the old
	# session is still active) and freezes the app before the tenant is saved.
	try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction Ignore } catch {}
	Connect-Exo $currentMgContext.Account
	$progressBar1.Value = 80
	CheckForErrors
	Write-Host "Connected to Exchange"
	try { Start-AcWarmup } catch {}   # connect the bg worker + build the recipient index early

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
	try { Reset-AcWorker } catch {}   # drop the background search worker + recipient index
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

# Matches email addresses so the tenant/account email in a log line can be blurred
# on its own (keeping "Connected to <tenant>..." readable) when the blur toggle is on.
$script:LogEmailRegex = [regex]'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}'
function New-LogEmailBlur { $fx = New-Object System.Windows.Media.Effects.BlurEffect; $fx.Radius = 5; $fx }

# Render a log line as inlines: plain Runs for the text, and each email in its own
# TextBlock (via InlineUIContainer) so the email alone can carry a BlurEffect. The full
# raw text is stashed in .Tag because InlineUIContainer content is NOT part of .Text
# (Copy reads .Tag so the copied log keeps the real addresses).
function Set-LogItemInlines([System.Windows.Controls.TextBlock]$Tb, [string]$FullText, [string]$BrushKey) {
	$Tb.Inlines.Clear()
	$Tb.Tag = $FullText
	$idx = 0
	foreach ($m in $script:LogEmailRegex.Matches($FullText)) {
		if ($m.Index -gt $idx) { $Tb.Inlines.Add((New-Object System.Windows.Documents.Run ($FullText.Substring($idx, $m.Index - $idx)))) }
		$eb = [System.Windows.Controls.TextBlock]::new()
		$eb.Text = $m.Value
		$eb.FontFamily = $Tb.FontFamily
		$eb.FontSize = $Tb.FontSize
		$eb.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $BrushKey)
		if ($script:Settings.blurTenant) { $eb.Effect = New-LogEmailBlur }
		$uic = New-Object System.Windows.Documents.InlineUIContainer $eb
		$uic.BaselineAlignment = [System.Windows.BaselineAlignment]::TextBottom
		$Tb.Inlines.Add($uic)
		$idx = $m.Index + $m.Length
	}
	if ($idx -lt $FullText.Length) { $Tb.Inlines.Add((New-Object System.Windows.Documents.Run ($FullText.Substring($idx)))) }
}

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
	$tb.FontFamily = $script:StyleDict['UiFont']
	$tb.FontSize = 12
	$tb.TextWrapping = 'Wrap'
	$tb.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $brushKey)
	Set-LogItemInlines $tb ("[{0:h:mm:ss tt}]  {1}" -f (Get-Date), $Text) $brushKey
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
	$script:UI.LogToggleIcon.Text = if ($Expanded) { [string][char]0xE488 } else { [string][char]0xE490 }
	if ($Expanded -and $script:UI.LogList.Items.Count -gt 0) {
		$script:UI.LogList.ScrollIntoView($script:UI.LogList.Items[$script:UI.LogList.Items.Count - 1])
	}
}

# ---- script catalog ----------------------------------------------------------
$script:ScriptCatalog = @(
	@{ Name = 'Add-AuthenticationPhoneMethod'; Desc = 'Add a 2FA phone number to an account, single or bulk.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xEE2F }
	@{ Name = 'Add-AutoReply'; Desc = 'Set an automatic reply on a mailbox, optionally scheduled.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xEBBC }
	@{ Name = 'Add-Contacts'; Desc = 'Add mail contacts to Microsoft 365, single or bulk.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xE249 }
	@{ Name = 'Add-DistributionListMember'; Desc = 'Add members to a distribution list.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xED75 }
	@{ Name = 'Add-EmailAlias'; Desc = 'Add aliases to a mailbox and view existing ones.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xEBBC }
	@{ Name = 'Add-MailboxMember'; Desc = 'Grant FullAccess / SendAs / SendOnBehalf on a mailbox.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xED93 }
	@{ Name = 'Add-TrustedSender'; Desc = 'Add a trusted sender or domain to every mailbox in the tenant.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xF039 }
	@{ Name = 'Add-UnifiedGroupMember'; Display = 'Add-TeamsGroupMember (UnifiedGroupMember)'; Desc = 'Add members to a Teams / Microsoft 365 group.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xED75 }
	@{ Name = 'Block-User'; Desc = 'Disable a user in AD and Microsoft 365, convert their mailbox to shared.'; SignIn = $true; Cat = 'Active Directory'; Icon = 0xEEE3 }
	@{ Name = 'Clear-RecycleBin'; Desc = 'Empty all recycle bins on this computer.'; SignIn = $false; Cat = 'System'; Icon = 0xE66D }
	@{ Name = 'Convert-UnifiedGroupToDistributionGroup'; Desc = 'Rebuild a Microsoft 365 group as a distribution list.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xE16F }
	@{ Name = 'Terminate-Disable-ADAndEmailAccounts'; Desc = 'Terminate a user: disable AD, convert mailbox to shared, strip licenses/2FA, optional add-members + auto-reply.'; SignIn = $true; Cat = 'Active Directory'; Icon = 0xEEE3 }
	@{ Name = 'Enable-Archive'; Desc = 'Enable, jumpstart or auto-expand mailbox archiving.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xE085 }
	@{ Name = 'Install-RequiredModules'; Desc = 'Install the Microsoft.Graph and ExchangeOnlineManagement modules.'; SignIn = $false; Cat = 'App'; Icon = 0xE0DD }
	@{ Name = 'New-ADAccounts'; Desc = 'Create Active Directory accounts in bulk from a CSV.'; SignIn = $false; Cat = 'Active Directory'; Icon = 0xEDBB }
	@{ Name = 'New-ADAndEmailAccounts'; Desc = 'Create AD accounts plus licensed mailboxes in bulk.'; SignIn = $true; Cat = 'Active Directory'; Icon = 0xEDBB }
	@{ Name = 'New-EmailAccounts'; Desc = 'Create licensed Microsoft 365 accounts in bulk.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xEBBC }
	@{ Name = 'Remove-DistributionListMember'; Desc = 'Remove members from a distribution list.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xED75 }
	@{ Name = 'Remove-EmailAlias'; Desc = 'Remove aliases from a mailbox.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xEBBC }
	@{ Name = 'Remove-MailboxMember'; Desc = 'Revoke FullAccess / SendAs / SendOnBehalf on a mailbox.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xED93 }
	@{ Name = 'Remove-UnifiedGroupMember'; Desc = 'Remove members from a Microsoft 365 group.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xED75 }
	@{ Name = 'Remove-UserFromAllGroups'; Desc = 'Remove a user from all (or selected) tenant groups - DLs, Teams/M365, security. Offboarding.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xED75 }
	@{ Name = 'Reset-MFA'; Desc = 'Clear a user''s MFA methods so they re-register, single or bulk.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xE72E }
	@{ Name = 'Set-License'; Desc = 'Assign, remove or swap Microsoft 365 licenses, single or bulk.'; SignIn = $true; Cat = 'Microsoft 365'; Icon = 0xE8FC }
	@{ Name = 'Set-ACLPermissions'; Desc = 'Add NTFS ACL permission rules to files and folders.'; SignIn = $false; Cat = 'System'; Icon = 0xEAA7 }
	@{ Name = 'Set-NTP'; Desc = 'Check or set the Windows time source.'; SignIn = $false; Cat = 'System'; Icon = 0xE508 }
	@{ Name = 'Show-Information'; Desc = 'Script-Package Studio info and links.'; SignIn = $false; Cat = 'App'; Icon = 0xEA88 }
)

# Plain-language help for each script, shown by the (i) info button on the home tiles and in the
# script windows. Keep it short and non-technical. Falls back to the catalog Desc when a script
# isn't listed here. What = one-paragraph summary; Steps = how-to bullets; Tip = optional note.
$script:ScriptHelp = @{
	'Add-AuthenticationPhoneMethod' = @{ What = 'Adds a phone number to someone''s account for two-step verification (2FA) - the code they get by text or call when signing in. You can also see and remove the 2FA methods they already have.'; Steps = @('Type the person''s email, then their phone number. For US/Canada just type the 10 digits - the +1 and flag fill in for you. For another country, type its code (like +44) and it hops up next to the flag. Either way, you can also type or paste the full number with the code, like +1 8585555555, and it works too.'; 'Pick Mobile (their main number) or Alternate mobile (a second one), then click Add Phone Number.'; 'Show current lists what they already have. Remove a 2FA method lets you delete one - handy if they lost a phone or security key.'); Tip = 'To add many at once: click Open Template, fill in the spreadsheet, save it, then click Add Phone Numbers.' }
	'Add-AutoReply' = @{ What = 'Turns on an automatic ''out of office'' reply for a mailbox.'; Steps = @('Type the mailbox''s email address.'; 'Write the message. Internal is for coworkers, External is for outside senders - leave Match Replies ticked to use the same text for both.'; 'Optionally tick Use Start and End Date to schedule it, then click Confirm.'; 'Show current loads the reply already on the mailbox so you can read or edit it before replacing it.'); Tip = '' }
	'Add-Contacts' = @{ What = 'Adds outside people to your Microsoft 365 address book as contacts, so their name and email show up when your staff compose messages.'; Steps = @('Fill in the contact''s name and email, or click Open Template to add many from a spreadsheet.'; 'Click Add.'); Tip = '' }
	'Add-DistributionListMember' = @{ What = 'Adds people to a distribution list - one email address that forwards to a whole group of people.'; Steps = @('Type the list''s email, then the person to add (start typing a name and pick them from the list).'; 'Click Add Member. To add lots of people, click Paste List and paste their names or emails.'); Tip = '' }
	'Add-EmailAlias' = @{ What = 'Gives a mailbox extra email addresses (aliases). Mail sent to any of them lands in the same inbox.'; Steps = @('Type the mailbox, then the alias address you want to add, and click Add Alias.'; 'To make a batch of numbered aliases, tick Create Incremental Aliases and set how many.'); Tip = 'Numbered aliases start at 1. Example: alias ''sales'' with the number 60 creates sales1@..., sales2@... up to sales60@... - that is 60 addresses in total. So just type how many you want (60 gives 60).' }
	'Add-MailboxMember' = @{ What = 'Gives someone access to another person''s mailbox - Full Access (open and manage it), Send As (send as that mailbox), or Send on Behalf.'; Steps = @('Type the person getting access, then the mailbox. Click a permission button (Full Access, Send As, Send on Behalf), or Add Member for Full Access plus Send As together.'; 'Use Paste List to grant access to many people at once.'); Tip = '' }
	'Add-TrustedSender' = @{ What = 'Marks an email address or a whole domain as trusted for EVERY mailbox in the tenant, so their messages won''t land in junk.'; Steps = @('Type the address or domain - for example news@vendor.com, or just vendor.com for everything from them.'; 'Click Add. It updates every mailbox, so in a large tenant it can take a while.'); Tip = '' }
	'Add-UnifiedGroupMember' = @{ What = 'Adds people to a Teams / Microsoft 365 group.'; Steps = @('Type the group, then the person to add. Click Add Member, or Paste List to add many at once.'); Tip = '' }
	'Block-User' = @{ What = 'Quickly locks someone out: disables their Active Directory and Microsoft 365 sign-in, turns their mailbox into a shared one, resets the password to something random, removes their licenses and 2FA, and signs them out everywhere.'; Steps = @('Type their email and their AD username, and tick what to block (Email, AD).'; 'Optionally give other people access to the now-shared mailbox and set an auto-reply.'; 'Click Block.'); Tip = 'For a full offboarding of someone who has left, use Terminate-Disable-ADAndEmailAccounts instead.' }
	'Clear-RecycleBin' = @{ What = 'Empties the Recycle Bin on this computer. On a shared or terminal server this empties everyone''s recycle bin.'; Steps = @('Run it. This cannot be undone, so be sure.'); Tip = '' }
	'Convert-UnifiedGroupToDistributionGroup' = @{ What = 'Recreates the members of a Microsoft 365 group as a plain distribution list.'; Steps = @('Type the group''s email. The new list gets the same name with ''-New'' added.'; 'Afterwards, rename or delete the old group in the admin center if you want.'); Tip = '' }
	'Terminate-Disable-ADAndEmailAccounts' = @{ What = 'Full offboarding for someone who has left: disables their Active Directory and Microsoft 365 accounts, converts the mailbox to shared, removes licenses and 2FA, and can set an auto-reply and hand the mailbox to a manager.'; Steps = @('Type the user and choose the options (who gets the mailbox, an auto-reply).'; 'Run it.'); Tip = '' }
	'Enable-Archive' = @{ What = 'Turns on the online archive mailbox for someone - extra storage that automatically moves their older mail out of the main inbox. Can also jump-start it or switch on auto-expanding archive.'; Steps = @('Type the mailbox, pick the option, and run.'); Tip = '' }
	'Install-RequiredModules' = @{ What = 'Installs the two PowerShell components this app needs (Microsoft Graph and Exchange Online). The app usually offers to do this for you on first run.'; Steps = @('Click to install. It needs an internet connection.'); Tip = '' }
	'New-ADAccounts' = @{ What = 'Creates many Active Directory user accounts at once from a spreadsheet.'; Steps = @('Click Open Template, fill in one row per person, and save.'; 'Run it. Tick Preview only first to check the list without creating anything.'); Tip = '' }
	'New-ADAndEmailAccounts' = @{ What = 'Creates Active Directory accounts AND their licensed Microsoft 365 mailboxes in bulk.'; Steps = @('Enter the email domain, pick a license, fill in the template, and run.'); Tip = 'Buy enough licenses first, or the new mailboxes won''t get one assigned.' }
	'New-EmailAccounts' = @{ What = 'Creates licensed Microsoft 365 accounts in bulk (mailboxes only, no Active Directory).'; Steps = @('Click Open Template, fill it in, pick a license, and run. Buy the licenses first.'); Tip = '' }
	'Remove-DistributionListMember' = @{ What = 'Removes people from a distribution list.'; Steps = @('Type the list and the person to remove, then click Remove Member. Paste List handles many at once.'); Tip = '' }
	'Remove-EmailAlias' = @{ What = 'Removes extra addresses (aliases) from a mailbox. The main address stays.'; Steps = @('Type the mailbox and the alias to remove, then click Remove. Bulk is available via the template.'; 'To remove a batch of numbered aliases, tick Remove Incremental Aliases and set how many - it deletes name1, name2, and so on up to that number.'); Tip = 'It also clears an old name0 if one exists (left over from before numbering started at 1), so nothing is left behind. Any alias that is not there is just skipped.' }
	'Remove-MailboxMember' = @{ What = 'Takes away someone''s access to another mailbox - Full Access, Send As, or Send on Behalf.'; Steps = @('Type the person and the mailbox, pick the permission to remove, and run. Paste List handles many at once.'); Tip = '' }
	'Remove-UnifiedGroupMember' = @{ What = 'Removes people from a Teams / Microsoft 365 group.'; Steps = @('Type the group and the person, then click Remove Member. Paste List handles many at once.'); Tip = '' }
	'Remove-UserFromAllGroups' = @{ What = 'Removes a person from all (or the ones you choose) of the tenant''s groups - distribution lists, Teams/M365 groups, and security groups. Handy when offboarding.'; Steps = @('Type the user, review the groups found, and remove them.'); Tip = '' }
	'Reset-MFA' = @{ What = 'Clears a user''s two-step verification (2FA) methods so they set them up fresh next sign-in - for example after they lost their phone.'; Steps = @('Type the user and run. Bulk is available via the template.'); Tip = 'To remove just ONE method instead of all of them, use Add-AuthenticationPhoneMethod and its ''Remove a 2FA method'' button.' }
	'Set-License' = @{ What = 'Assigns, removes, or swaps Microsoft 365 licenses for people.'; Steps = @('Type the user, pick the license and whether to add/remove/swap, and run. Bulk is available via the template.'); Tip = '' }
	'Set-ACLPermissions' = @{ What = 'Adds Windows file and folder permission rules - who is allowed to read or change a folder.'; Steps = @('Enter the folder, the user or group, and the access level, then run. Bulk is supported.'); Tip = '' }
	'Set-NTP' = @{ What = 'Checks or sets where this computer gets its clock time. It can point the computer at time.windows.com.'; Steps = @('Click to check the current setting; use the button to set it.'); Tip = '' }
	'Show-Information' = @{ What = 'About this app - the version you''re on and helpful links.'; Steps = @(); Tip = '' }
}

$script:Categories = @('All', 'Microsoft 365', 'Active Directory', 'System', 'App')
$script:CurrentCategory = 'All'

function New-ScriptListItem($Meta) {
	$item = [System.Windows.Controls.ListBoxItem]::new()
	$item.Style = $script:StyleDict['PaletteItemStyle']
	$item.Tag = $Meta.Name

	$grid = [System.Windows.Controls.Grid]::new()
	foreach ($w in @('Auto', '*', 'Auto')) {
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
	$name.Text = if ($Meta.Display) { $Meta.Display } else { $Meta.Name }
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

	# (i) info button: opens a plain-language explanation of what the script does + how to use it.
	# Handled so clicking it doesn't also start the script.
	$info = [System.Windows.Controls.Button]::new()
	$info.Style = $script:StyleDict['IconBtn']
	$info.Width = 27; $info.Height = 27
	$info.VerticalAlignment = 'Center'; $info.Margin = '8,0,0,0'
	$info.Tag = $Meta.Name
	$info.ToolTip = 'What this does and how to use it'
	$ig = [System.Windows.Controls.TextBlock]::new()
	$ig.Text = [string][char]0xEA88
	$ig.FontFamily = $script:StyleDict['IconFont']
	$ig.FontSize = 15
	$ig.HorizontalAlignment = 'Center'; $ig.VerticalAlignment = 'Center'
	$ig.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'TextDimBrush')
	$info.Content = $ig
	$info.Add_Click({ param($s, $e) $e.Handled = $true; Show-ScriptHelp ([string]$s.Tag) })
	[System.Windows.Controls.Grid]::SetColumn($info, 2)
	[void]$grid.Children.Add($info)

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
		if ($filter) {
			$hay = "$($s.Name) $($s.Desc) $($s.Display)"
			if ($hay.IndexOf($filter, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
		}
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
		"Terminate-Disable-ADAndEmailAccounts" { Terminate-Disable-ADAndEmailAccounts }
		"Enable-Archive" { Enable-Archive }
		"Install-RequiredModules" { Install-RequiredModules }
		"New-ADAccounts" { New-ADAccounts }
		"New-ADAndEmailAccounts" { New-ADAndEmailAccounts }
		"New-EmailAccounts" { New-EmailAccounts }
		"Remove-DistributionListMember" { Remove-DistributionListMember }
		"Remove-EmailAlias" { Remove-EmailAlias }
		"Remove-MailboxMember" { Add-MailboxMember }
		"Remove-UnifiedGroupMember" { Remove-UnifiedGroupMember }
		"Remove-UserFromAllGroups" { Remove-UserFromAllGroups }
		"Reset-MFA" { Reset-MFA }
		"Set-License" { Set-License }
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
		$script:UI.StatusText.Text = if ($known) { "$Name finished at $(Get-Date -Format 'h:mm tt')" } else { 'Ready' }
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
# Run a (UI-thread-blocking) sign-in only AFTER the just-closed tenant dropdown popup
# is fully gone. The popup is a separate always-on-top window; if the blocking sign-in
# starts before it's destroyed, it freezes open on top of the auth browser. A short
# timer lets the (now un-animated) popup close render first. Under SP_TEST there's no
# real browser, so run synchronously to keep the self-test deterministic.
function Start-DeferredSignIn([scriptblock]$Action) {
	if ($env:SP_TEST) { & $Action; return }
	$timer = New-Object System.Windows.Threading.DispatcherTimer
	$timer.Interval = [TimeSpan]::FromMilliseconds(250)
	$timer.Add_Tick({ $timer.Stop(); & $Action }.GetNewClosure())
	$timer.Start()
}

$script:UI.TenantCombo.Add_SelectionChanged({ param($s, $e)
	if ($script:SuppressTenantEvents) { return }
	$item = $s.SelectedItem
	if (-not $item) { return }
	# Close the dropdown, then defer the sign-in until the popup window is actually gone
	# (see Start-DeferredSignIn + the PopupAnimation=None set on DropDownOpened).
	$s.IsDropDownOpen = $false
	if ($item.Tag -eq 'add') {
		# put the selection back before starting the interactive sign-in
		$script:SuppressTenantEvents = $true
		$s.SelectedIndex = if ($script:ActiveTenant) { $script:Tenants.IndexOf($script:ActiveTenant) } else { -1 }
		$script:SuppressTenantEvents = $false
		Start-DeferredSignIn { Add-TenantSignIn }
		return
	}
	if ($script:ActiveTenant -ne $item.Tag) {
		$tenant = $item.Tag
		Start-DeferredSignIn ({ Connect-Tenant $tenant }.GetNewClosure())
	}
})

$script:UI.ConnectBtn.Add_Click({
	$sel = Get-SelectedTenant
	if ($sel) { Connect-Tenant $sel } else { Add-TenantSignIn }
})
$script:UI.DisconnectBtn.Add_Click({
	$who = if ($script:ActiveTenant) { " from `"$($script:ActiveTenant.name)`" ($($script:ActiveTenant.account))" } else { '' }
	if (-not (Confirm-YesNo 'Disconnect tenant' "Disconnect$who? You'll need to sign in again to run tenant scripts.")) { return }
	Disconnect-Tenant
})

$script:UI.ForgetTenantBtn.Add_Click({
	$sel = Get-SelectedTenant
	if (-not $sel) { return }
	if (-not (Confirm-YesNo 'Forget tenant' "Forget `"$($sel.name)`" ($($sel.account))? This removes it from the saved list.")) { return }
	if ($script:ActiveTenant -eq $sel) { Disconnect-Tenant }
	[void]$script:Tenants.Remove($sel)
	Save-Tenants
	Write-Host "Removed tenant '$($sel.name)' ($($sel.account)) from the list."
	Update-TenantCombo
})

# Blur/unblur the OPEN dropdown list. The Effect on the ComboBox element doesn't reach
# its popup (WPF renders the popup in a separate visual tree), so blur the popup's
# scroll content directly - which leaves the popup border + drop shadow crisp.
function Set-TenantPopupBlur([bool]$On) {
	try {
		$popup = $script:UI.TenantCombo.Template.FindName('PART_Popup', $script:UI.TenantCombo)
		if (-not $popup -or -not $popup.Child) { return }
		$content = $popup.Child.Child   # PART_Popup -> Border -> ScrollViewer (the items)
		if (-not $content) { return }
		$content.Effect = if ($On) { $fx = New-Object System.Windows.Media.Effects.BlurEffect; $fx.Radius = 8; $fx } else { $null }
	} catch {}
}
# On open: apply the current blur state to the popup content, AND force the popup's
# close animation OFF. WPF's dropdown fade-out gets frozen mid-fade by the blocking
# sign-in, which is what leaves the popup stuck (semi-transparent) on top of the auth
# browser. With no fade the popup closes instantly, so it's gone before sign-in starts.
$script:UI.TenantCombo.Add_DropDownOpened({
	Set-TenantPopupBlur ([bool]$script:Settings.blurTenant)
	try {
		$popup = $script:UI.TenantCombo.Template.FindName('PART_Popup', $script:UI.TenantCombo)
		if ($popup) { $popup.PopupAnimation = [System.Windows.Controls.Primitives.PopupAnimation]::None }
	} catch {}
})

# blur/unblur the tenant + account (for screenshots); remembered across launches
function Set-TenantBlur([bool]$On) {
	$script:Settings.blurTenant = $On
	if ($On) {
		$fx = New-Object System.Windows.Media.Effects.BlurEffect; $fx.Radius = 9
		$script:UI.TenantCombo.Effect = $fx
		$fx2 = New-Object System.Windows.Media.Effects.BlurEffect; $fx2.Radius = 6
		$script:UI.SignStatusText.Effect = $fx2
		$script:UI.BlurIcon.Text = [string][char]0xE889
		$script:UI.BlurTenantBtn.ToolTip = 'Show the tenant / account'
	} else {
		$script:UI.TenantCombo.Effect = $null
		$script:UI.SignStatusText.Effect = $null
		$script:UI.BlurIcon.Text = [string][char]0xE883
		$script:UI.BlurTenantBtn.ToolTip = 'Hide the tenant / account for screenshots'
	}
	Set-TenantPopupBlur $On
	# Blur/unblur the email address inside each activity-log line (the rest of the line
	# - "Connected to <tenant> as ..." - stays readable so the log is still useful).
	if ($script:UI.LogList) {
		foreach ($item in $script:UI.LogList.Items) {
			if ($item -is [System.Windows.Controls.TextBlock]) {
				foreach ($inline in $item.Inlines) {
					if ($inline -is [System.Windows.Documents.InlineUIContainer] -and $inline.Child) {
						$inline.Child.Effect = if ($On) { New-LogEmailBlur } else { $null }
					}
				}
			}
		}
	}
}
$script:UI.BlurTenantBtn.Add_Click({
	Set-TenantBlur (-not $script:Settings.blurTenant)
	Save-AppSettings
})
$script:UI.SearchBox.Add_TextChanged({
	$hasText = [bool]$script:UI.SearchBox.Text
	$script:UI.SearchHint.Visibility = if ($hasText) { 'Collapsed' } else { 'Visible' }
	$script:UI.SearchClearBtn.Visibility = if ($hasText) { 'Visible' } else { 'Collapsed' }
	Update-ScriptList
})
$script:UI.SearchClearBtn.Add_Click({ $script:UI.SearchBox.Clear(); $script:UI.SearchBox.Focus() })
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
	$text = ($script:UI.LogList.Items | ForEach-Object { if ($_.Tag) { [string]$_.Tag } else { [string]$_.Text } }) -join "`r`n"
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
		$script:UI.MaxBtn.Content = [char]0xF149
	} else {
		$script:UI.Root.Margin = '0'
		$script:UI.MaxBtn.Content = [char]0xEC2A
	}
})

# ---- theme toggle ---------------------------------------------------------------
$script:UI.ThemeBtn.Add_Click({
	$next = if ($script:Settings.theme -eq 'Dark') { 'Light' } else { 'Dark' }
	Apply-Theme $next
	Save-AppSettings
})

# ---- settings dialog (recipient type-ahead toggle + in-app updater) --------------
function New-SettingsDialog {
	New-StyledDialog -Title 'Settings' -Icon '&#xEA88;' -BodyXaml @'
<StackPanel Margin="16" Width="380">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<TextBlock Text="Recipient search" Style="{DynamicResource H3}"/>
			<CheckBox x:Name="RecipientSearchCheck" Content="Search recipients by name (type-ahead)" Margin="0,10,0,0"/>
			<TextBlock Text="Type a name in any email field to look up users, groups and mailboxes. If it ever causes trouble, turn this off and let us know so we can fix it." Style="{DynamicResource Small}" TextWrapping="Wrap" Margin="24,4,0,0"/>
			<CheckBox x:Name="BgSearchCheck" Content="Search in the background (smoother, animated)" Margin="0,12,0,0"/>
			<TextBlock Text="Runs the lookup off the main thread so the window never freezes and results load with an animated indicator. If searches misbehave, turn this off to use the classic lookup." Style="{DynamicResource Small}" TextWrapping="Wrap" Margin="24,4,0,0"/>
		</StackPanel>
	</Border>
	<Border Style="{DynamicResource Card}" Margin="0,12,0,0">
		<StackPanel>
			<TextBlock Text="Updates" Style="{DynamicResource H3}"/>
			<TextBlock x:Name="UpdateStatus" Style="{DynamicResource Small}" TextWrapping="Wrap" Margin="0,6,0,0"/>
			<ProgressBar x:Name="UpdateProg" Height="6" Maximum="100" Margin="0,10,0,0" Visibility="Collapsed"/>
			<Grid Margin="0,12,0,0">
				<Button x:Name="UpdateBtn" Style="{DynamicResource BtnPrimary}" Content="Check for updates" HorizontalAlignment="Left" MinWidth="150"/>
				<Button x:Name="RelaunchBtn" Style="{DynamicResource BtnPrimary}" Content="Relaunch now" HorizontalAlignment="Right" MinWidth="130" Visibility="Collapsed"/>
			</Grid>
		</StackPanel>
	</Border>
</StackPanel>
'@
}
# Finish a relaunch instantly: save window state + settings, then hard-exit so the helper that
# Restart-App spawned (it waits for THIS process to exit) starts the new copy right away. We
# force-exit instead of a graceful close because letting Exchange/Graph background threads wind
# down kept the process alive ~a minute, delaying the relaunch. Server sessions expire on their
# own and the fresh instance reconnects. Top-level fn so $script:Window/$script:Settings resolve.
function Complete-Relaunch {
	try {
		$script:Settings.winWidth = [int]$script:Window.Width
		$script:Settings.winHeight = [int]$script:Window.Height
		$script:Settings.winMaximized = $script:Window.WindowState -eq 'Maximized'
		Save-AppSettings
	} catch {}
	[System.Environment]::Exit(0)
}
function Show-Settings {
	$win = New-SettingsDialog
	$rc = $win.FindName('RecipientSearchCheck')
	$rc.IsChecked = [bool]$script:Settings.recipientSearch
	$rc.Add_Checked({ $script:Settings.recipientSearch = $true; Save-AppSettings })
	$rc.Add_Unchecked({ $script:Settings.recipientSearch = $false; Save-AppSettings })
	$bg = $win.FindName('BgSearchCheck')
	$bg.IsChecked = [bool]$script:Settings.bgSearch
	$bg.Add_Checked({ $script:Settings.bgSearch = $true; $script:AcWorkerFail = ''; try { Reset-AcWorker } catch {}; Save-AppSettings })
	$bg.Add_Unchecked({ $script:Settings.bgSearch = $false; try { Reset-AcWorker } catch {}; Save-AppSettings })

	$status = $win.FindName('UpdateStatus'); $prog = $win.FindName('UpdateProg')
	$updateBtn = $win.FindName('UpdateBtn'); $relaunchBtn = $win.FindName('RelaunchBtn')
	$status.Text = "You're on $version."
	# GetNewClosure() gives the click handler its own module scope, where $script:*
	# and inherited script vars read as $null. Snapshot them into locals first so the
	# closure captures real values (otherwise Split-Path $script:SrcDir got $null).
	$curVersion = $version
	$appRoot = Split-Path $script:SrcDir -Parent
	if (-not $appRoot) { $appRoot = $PSScriptRoot }
	$setStatus = { param($t) $status.Text = $t; try { $status.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Render) } catch {} }.GetNewClosure()

	$updateBtn.Add_Click({
		$updateBtn.IsEnabled = $false
		$prog.Visibility = 'Visible'; $prog.Value = 10
		& $setStatus 'Checking for updates...'
		try {
			try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}
			$resp = Invoke-WebRequest -Uri 'https://github.com/Avromiep/Script-Package-Studio/releases/latest' -UseBasicParsing
			$tag = @($resp.Links.href | Where-Object { $_ -like '*/releases/tag/v*' }) | Select-Object -First 1
			$remote = if ($tag) { ($tag -split 'tag/')[1] } else { '' }
			$prog.Value = 30
			if (-not $remote) { & $setStatus "Couldn't check for updates - try again later."; $prog.Visibility = 'Collapsed'; $updateBtn.IsEnabled = $true; return }
			if ($remote -eq $curVersion) { & $setStatus "You're on the latest version ($curVersion)."; $prog.Visibility = 'Collapsed'; $updateBtn.IsEnabled = $true; $updateBtn.Content = 'Check for updates'; return }
			& $setStatus "Downloading $remote..."; $prog.Value = 50
			$tmp = "$env:TEMP\Script-Package-Studio-Setup.exe"
			Remove-Item -Path $tmp -Force -ErrorAction Ignore
			Invoke-WebRequest -Uri 'https://github.com/Avromiep/Script-Package-Studio/releases/latest/download/Script-Package-Studio-Setup.exe' -OutFile $tmp -UseBasicParsing
			if (-not (Test-Path $tmp)) { & $setStatus 'Download failed - opening the releases page.'; Start-Process 'https://github.com/Avromiep/Script-Package-Studio/releases/latest'; $prog.Visibility = 'Collapsed'; $updateBtn.IsEnabled = $true; return }
			$prog.Value = 70; & $setStatus "Installing $remote..."
			Start-Process $tmp -ArgumentList '/SP-', '/SILENT', "/DIR=`"$appRoot`"" -Wait
			$prog.Value = 100
			& $setStatus "Update to $remote installed. Click Relaunch now to finish."
			$updateBtn.Visibility = 'Collapsed'; $relaunchBtn.Visibility = 'Visible'
		} catch { & $setStatus "Update failed: $($_.Exception.Message)"; $prog.Visibility = 'Collapsed'; $updateBtn.IsEnabled = $true }
	}.GetNewClosure())

	$relaunchBtn.Add_Click({
		if (-not $relaunchBtn.IsEnabled) { return }   # ignore repeat clicks - one relaunch only
		$relaunchBtn.IsEnabled = $false; $relaunchBtn.Content = "Relaunching$([char]0x2026)"
		Restart-App          # spawn the helper that waits for us to exit, then starts the new copy
		Complete-Relaunch    # save + hard-exit now so the relaunch happens immediately
	}.GetNewClosure())
	[void]$win.ShowDialog()
}
$script:UI.SettingsBtn.Add_Click({ Show-Settings })

# ---- shutdown (same disconnect behavior as before, guarded so a missing
# ---- module can't block the window from closing) ---------------------------------
$script:Relaunching = $false
$script:Window.Add_Closing({ param($s, $e)
	if ($env:SP_SHOT) { return }
	$script:Settings.winWidth = [int]$script:Window.Width
	$script:Settings.winHeight = [int]$script:Window.Height
	$script:Settings.winMaximized = $script:Window.WindowState -eq 'Maximized'
	Save-AppSettings
	try { Reset-AcWorker } catch {}   # dispose the background-search runspace + its connection
	# On a relaunch, skip the slow disconnect so the window closes instantly and the updated app
	# starts right away (the dying process's sessions expire on their own).
	if (-not $script:Relaunching) {
		try { Disconnect-ExchangeOnline -Confirm:$false } catch {}
		try { Disconnect-Graph } catch {}
	}
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
Set-TenantBlur ([bool]$script:Settings.blurTenant)
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

	# Sample 2FA methods for the Show-current / Remove-method screenshots (password excluded - it isn't 2FA).
	$script:SampleAuthMethods = @(
		[pscustomobject]@{ Id='p1'; Type='#microsoft.graph.phoneAuthenticationMethod'; Kind='Phone (Mobile)'; Detail='+1 2125550192'; Removable=$true },
		[pscustomobject]@{ Id='p2'; Type='#microsoft.graph.phoneAuthenticationMethod'; Kind='Phone (Alternate mobile)'; Detail='+972 541234567'; Removable=$true },
		[pscustomobject]@{ Id='a1'; Type='#microsoft.graph.microsoftAuthenticatorAuthenticationMethod'; Kind='Microsoft Authenticator app'; Detail="Sara's iPhone"; Removable=$true },
		[pscustomobject]@{ Id='o1'; Type='#microsoft.graph.softwareOathAuthenticationMethod'; Kind='Authenticator app (verification code)'; Detail='Authy'; Removable=$true },
		[pscustomobject]@{ Id='f1'; Type='#microsoft.graph.fido2AuthenticationMethod'; Kind='Security key (FIDO2)'; Detail='YubiKey 5C'; Removable=$true },
		[pscustomobject]@{ Id='e1'; Type='#microsoft.graph.emailAuthenticationMethod'; Kind='Email'; Detail='sara.personal@gmail.com'; Removable=$true }
	)
	$script:ShotBuilders = [ordered]@{
		'dlg-add-2fa'            = {
			$w = New-AuthenticationPhoneDialog
			$b = $w.FindName('PhoneBanner'); $t = $w.FindName('PhoneBannerText')
			$t.Text = 'CURRENT 2FA numbers for user@contoso.com:' + [char]10 + '  Mobile: +1 2224446666' + [char]10 + '  Alternate mobile: +44 2079460958' + [char]10 + [char]10 + 'Type another number below to add it (pick Mobile or Alternate mobile).'
			$b.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'WarnBrush')
			$t.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'WarnBrush')
			$w.FindName('ShowCurrentBtn').Content = 'Clear'
			$pc = [pscustomobject]@{ Group=$w.FindName('PhoneCcGroup'); Img=$w.FindName('FlagImg'); Chip=$w.FindName('FlagChip'); Code=$w.FindName('PhoneCcText') }
			$w.FindName('PhoneInput').Text = '+44 20 7946 0958'
			try { Update-AcPhoneField $pc $w.FindName('PhoneInput') } catch {}
			$w
		}
		'dlg-2fa-methods'        = {
			# Add-2FA "Show current" showing the read-only list of a user's registered 2FA methods.
			$w = New-AuthenticationPhoneDialog
			$b = $w.FindName('PhoneBanner'); $t = $w.FindName('PhoneBannerText')
			$t.Text = 'CURRENT 2FA methods for user@contoso.com. Use "Remove a 2FA method" to remove one, or add a new phone number below.'
			$b.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'WarnBrush')
			$t.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'WarnBrush')
			$panel = $w.FindName('MethodsPanel')
			foreach ($info in $script:SampleAuthMethods) { [void]$panel.Children.Add((New-AuthMethodRow $info).Element) }
			$w.FindName('MethodsScroller').Visibility = 'Visible'
			$w.FindName('MethodsScroller').MaxHeight = 320
			$w
		}
		'dlg-remove-2fa'         = {
			# The "Remove a 2FA method" picker, populated with sample removable methods.
			$w = New-RemoveMethodDialog
			$list = $w.FindName('PickList')
			foreach ($info in $script:SampleAuthMethods) {
				$it = New-Object System.Windows.Controls.ListBoxItem
				$it.Content = (New-AuthMethodRow $info).Element; $it.Tag = $info; $it.Padding = '0'
				[void]$list.Items.Add($it)
			}
			$list.SelectedIndex = 1
			$w
		}
		'dlg-help-alias'         = { New-ScriptHelpDialog 'Add-EmailAlias' }
		'dlg-help-removealias'   = { New-ScriptHelpDialog 'Remove-EmailAlias' }
		'dlg-help-2fa'           = { New-ScriptHelpDialog 'Add-AuthenticationPhoneMethod' }
		'dlg-add-autoreply'      = {
			$w = New-AutoReplyDialog
			$msg = "I'm out of the office until Monday. For anything urgent, contact sales@contoso.com."
			$w.FindName('InternalReplyBox').Text = $msg; $w.FindName('ExternalReplyBox').Text = $msg
			$t = $w.FindName('ReplyBannerText'); $b = $w.FindName('ReplyBanner')
			$t.Text = 'NEW auto-reply - this is what will be set on the mailbox when you click Confirm.'
			$b.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'AccentBrush')
			$t.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'AccentBrush')
			$w
		}
		'dlg-autoreply-current'  = {
			$w = New-AutoReplyDialog
			$msg = "Thank you for your message. I have left the company; please contact hr@contoso.com."
			$w.FindName('InternalReplyBox').Text = $msg; $w.FindName('ExternalReplyBox').Text = $msg
			$t = $w.FindName('ReplyBannerText'); $b = $w.FindName('ReplyBanner')
			$t.Text = 'PREVIEW - this is the auto-reply CURRENTLY on the mailbox. Edit it to compose a new one.'
			$b.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'WarnBrush')
			$t.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'WarnBrush')
			$w.FindName('ShowCurrentBtn').Content = 'Clear preview'
			$w
		}
		'dlg-add-contacts'       = { New-AddContactsDialog }
		'dlg-add-distlistmember' = { New-MemberGroupDialog -Title 'Add-DistributionListMember' -ActionText 'Add Member' -BulkText 'Add Members' -WithPaste }
		'dlg-remove-distlistmember' = { New-MemberGroupDialog -Title 'Remove-DistributionListMember' -ActionText 'Remove Member' -BulkText 'Remove Members' -WithPaste }
		'dlg-paste-remove'          = { New-PasteMembersDialog -TargetPrefill 'dl@contoso.com' -Action 'remove' }
		'dlg-add-emailalias'     = { New-EmailAliasDialog -WithPrimary }
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
		'dlg-reset-mfa'          = { New-ResetMfaDialog }
		'dlg-disable-accounts'   = { New-DisableAccountsDialog }
		'dlg-remove-groups'      = { New-RemoveGroupsDialog }
		'dlg-term-autoreply'     = { New-TermAutoReplyDialog 'user@contoso.com' }
		'dlg-set-license'        = { New-SetLicenseDialog }
		'dlg-settings'           = { $w = New-SettingsDialog; $w.FindName('RecipientSearchCheck').IsChecked = $true; $w.FindName('BgSearchCheck').IsChecked = $true; $w.FindName('UpdateStatus').Text = "You're on $version."; $w }
		'dlg-notice-blur'        = { New-NoticeDialog 'Add complete' "allstaff@contoso.com (distribution list):`n  added (2): john@contoso.com, jane@contoso.com`n  already there (1): bob@contoso.com" 'Info' }
		'dlg-ac-empty'           = {
			$w = New-StyledDialog -Title 'Type a name OR an email' -Icon '&#xE721;' -BodyXaml @'
<StackPanel Margin="16" Width="380">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<TextBlock Text="Add-DistributionListMember" Style="{DynamicResource H3}"/>
			<Grid Margin="0,12,0,0">
				<Grid.ColumnDefinitions><ColumnDefinition Width="70"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
				<Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
				<TextBlock Text="Member" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
				<TextBox x:Name="Mem" Grid.Column="1"/>
				<TextBlock Text="Group" Style="{DynamicResource Dim}" Grid.Row="1" VerticalAlignment="Center" Margin="0,8,0,0"/>
				<TextBox x:Name="Grp" Grid.Row="1" Grid.Column="1" Margin="0,8,0,0"/>
			</Grid>
		</StackPanel>
	</Border>
</StackPanel>
'@
			Set-FieldWatermark $w.FindName('Mem') 'Name or email address'
			Set-FieldWatermark $w.FindName('Grp') 'Name or email address'
			$w
		}
		'dlg-ac-mixed'           = { New-AcPreviewDialog 'Type-ahead - mixed results' 'Mailbox / user (start typing a name)' 'sa' @(
			@('Sara Adler', 'sara.adler.longname@contoso-corporation.com', ''),
			@('Sales', 'sales@contoso.com', 'shared mailbox'),
			@('All Staff', 'allstaff@contoso.com', 'distribution list'),
			@('Marketing Team', 'marketing@contoso.com', 'Teams / Microsoft 365 group'),
			@('Reception Room', 'reception@contoso.com', 'room')) }
		'dlg-ac-member'          = { New-AcPreviewDialog 'Type-ahead - a member field' 'Member (person to add)' 'jo' @(
			@('John Doe', 'jdoe@contoso.com', ''),
			@('Joanna Klein', 'jklein@contoso.com', ''),
			@('Jordan Prima', 'jprima@contoso.com', ''),
			@('Johnson, Alex', 'ajohnson@contoso.com', ''),
			@('Job Applicants', 'jobs@contoso.com', 'shared mailbox')) }
		'dlg-ac-group'           = { New-AcPreviewDialog 'Type-ahead - a group field' 'Group (distribution list / Teams group)' 'sal' @(
			@('Sales Team', 'salesteam@contoso.com', 'Teams / Microsoft 365 group'),
			@('Sales', 'sales@contoso.com', 'distribution list'),
			@('Sales Managers', 'salesmgrs@contoso.com', 'mail-enabled security group'),
			@('Sally Ann Reyes', 'sreyes@contoso.com', '')) }
		'dlg-show-information'   = { New-InformationDialog }
		'dlg-error'              = { New-ErrorDialog "Add-MailboxPermission: mailbox admin@contoso.com`nwas not found on the server." }
		'dlg-opcomplete'         = { New-OperationCompleteDialog }
		'dlg-warning'            = { New-WarningDialog "Turning on AutoExpandingArchive is irreversible - are you sure you'd like to continue?" }
		'dlg-updatecomplete'     = { New-UpdateCompleteDialog "Latest version already installed." }
		'dlg-modules'            = { New-ModulesMissingDialog "Microsoft.Graph`nExchangeOnlineManagement" }
		'dlg-notice-info'        = { New-NoticeDialog 'Already added' 'admin@contoso.com is already added to "Contoso Ltd".' 'Info' }
		'dlg-notice-warn'        = { New-NoticeDialog 'Wrong script for this target' "'sales@contoso.com' is a distribution list, not a mailbox.`n`nUse the 'Add-DistributionListMember' script for it instead." 'Warn' }
		'dlg-notice-summary'     = { New-NoticeDialog 'Add complete' "sales@contoso.com (shared mailbox): 5 added, 1 already there`nContoso Team (Teams / Microsoft 365 group): 5 added`ndl@contoso.com (distribution list): 4 added, 1 failed" 'Warn' }
		'dlg-paste'              = { New-PasteMembersDialog -TargetPrefill "sales@contoso.com`nContoso Team" }
		'dlg-confirm'            = { New-ConfirmDialog 'Forget tenant' 'Forget "Contoso Ltd" (admin@contoso.com)? This removes it from the saved list.' }
		'dlg-confirm-external'   = { New-ConfirmDialog 'External addresses found' "3 addresses aren't in your tenant's domains:`n`n  amy@gmail.com`n  ben@outlook.com`n  cara@partner.co`n`nBring them in so they can be added? Distribution lists get a mail contact; Teams / Microsoft 365 groups get a guest invite; shared mailboxes can't take external addresses, so those are skipped.`n`nYes = bring them in & add.  No = skip the external ones." '&#xEA88;' }
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

# On first launch, prompt to install the required modules if they're missing (after
# the window is visible). Guarded off during screenshot/self-test runs.
if (-not $env:SP_SHOT -and -not $env:SP_TEST) {
	$script:ModulesCheckedAtStartup = $false
	$script:Window.Add_ContentRendered({
		if ($script:ModulesCheckedAtStartup) { return }
		$script:ModulesCheckedAtStartup = $true
		try { Confirm-ModulesAtStartup } catch {}
	})
}

# Show MainWindow
[void]$script:Window.ShowDialog()
