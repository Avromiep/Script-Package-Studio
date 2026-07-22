# Script-Package - shared UI framework (WPF, BatchAV Studio design system)

# Styles.xaml is copied unchanged from BatchAV Studio; this small dictionary adds
# the one control that project never used (DatePicker), themed to match. It gets
# merged into the style dictionary at startup.
$script:ExtraStylesXaml = @'
<ResourceDictionary
	xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
	xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">

	<!-- Multiline text areas: same look as the shared TextBox style, but the content
		 host stretches from the top instead of vertically centering -->
	<Style x:Key="TextArea" TargetType="TextBox">
		<Setter Property="Background" Value="{DynamicResource InputBrush}"/>
		<Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
		<Setter Property="BorderBrush" Value="{DynamicResource StrokeBrush}"/>
		<Setter Property="CaretBrush" Value="{DynamicResource AccentBrush}"/>
		<Setter Property="SelectionBrush" Value="{DynamicResource SelectionBrush}"/>
		<Setter Property="FontFamily" Value="{DynamicResource UiFont}"/>
		<Setter Property="FontSize" Value="13"/>
		<Setter Property="Padding" Value="9,6"/>
		<Setter Property="AcceptsReturn" Value="True"/>
		<Setter Property="TextWrapping" Value="Wrap"/>
		<Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
		<Setter Property="Template">
			<Setter.Value>
				<ControlTemplate TargetType="TextBox">
					<Border x:Name="Bd" CornerRadius="8" Background="{TemplateBinding Background}"
							BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
						<ScrollViewer x:Name="PART_ContentHost" Focusable="False"
									  HorizontalScrollBarVisibility="Hidden"
									  VerticalScrollBarVisibility="{TemplateBinding VerticalScrollBarVisibility}"/>
					</Border>
					<ControlTemplate.Triggers>
						<Trigger Property="IsMouseOver" Value="True">
							<Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource TextFaintBrush}"/>
						</Trigger>
						<Trigger Property="IsKeyboardFocused" Value="True">
							<Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
						</Trigger>
						<Trigger Property="IsEnabled" Value="False">
							<Setter Property="Opacity" Value="0.5"/>
						</Trigger>
					</ControlTemplate.Triggers>
				</ControlTemplate>
			</Setter.Value>
		</Setter>
	</Style>

	<Style TargetType="{x:Type DatePickerTextBox}">
		<Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
		<Setter Property="CaretBrush" Value="{DynamicResource TextBrush}"/>
		<Setter Property="Background" Value="Transparent"/>
		<Setter Property="FontFamily" Value="{DynamicResource UiFont}"/>
		<Setter Property="FontSize" Value="13"/>
		<Setter Property="Template">
			<Setter.Value>
				<ControlTemplate TargetType="{x:Type DatePickerTextBox}">
					<Grid Background="Transparent">
						<ContentControl x:Name="PART_Watermark" Focusable="False" IsHitTestVisible="False" Opacity="0"/>
						<ScrollViewer x:Name="PART_ContentHost" Background="Transparent" BorderThickness="0"
									  HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"
									  VerticalAlignment="Center"/>
					</Grid>
				</ControlTemplate>
			</Setter.Value>
		</Setter>
	</Style>

	<Style TargetType="{x:Type DatePicker}">
		<Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
		<Setter Property="MinHeight" Value="30"/>
		<Setter Property="Template">
			<Setter.Value>
				<ControlTemplate TargetType="{x:Type DatePicker}">
					<Border x:Name="Bd" Background="{DynamicResource InputBrush}"
							BorderBrush="{DynamicResource StrokeBrush}" BorderThickness="1" CornerRadius="8">
						<Grid x:Name="PART_Root">
							<Grid.ColumnDefinitions>
								<ColumnDefinition Width="*"/>
								<ColumnDefinition Width="Auto"/>
							</Grid.ColumnDefinitions>
							<DatePickerTextBox x:Name="PART_TextBox" Grid.Column="0" Margin="9,0,0,0"
											   VerticalAlignment="Center"/>
							<Button x:Name="PART_Button" Grid.Column="1" Focusable="False" Cursor="Hand">
								<Button.Template>
									<ControlTemplate TargetType="Button">
										<Border Background="Transparent" Padding="9,0,10,0">
											<TextBlock Text="&#xE787;" FontFamily="{DynamicResource IconFont}" FontSize="13"
													   Foreground="{DynamicResource TextDimBrush}" VerticalAlignment="Center"/>
										</Border>
									</ControlTemplate>
								</Button.Template>
							</Button>
							<Popup x:Name="PART_Popup" AllowsTransparency="True" Placement="Bottom"
								   PlacementTarget="{Binding ElementName=PART_TextBox}" StaysOpen="False"/>
						</Grid>
					</Border>
					<ControlTemplate.Triggers>
						<Trigger Property="IsEnabled" Value="False">
							<Setter TargetName="Bd" Property="Opacity" Value="0.55"/>
						</Trigger>
					</ControlTemplate.Triggers>
				</ControlTemplate>
			</Setter.Value>
		</Setter>
	</Style>
</ResourceDictionary>
'@

function Read-XamlString([string]$Xaml) {
	$sr = [System.IO.StringReader]::new($Xaml)
	$xr = [System.Xml.XmlReader]::Create($sr)
	try { return [System.Windows.Markup.XamlReader]::Load($xr) } finally { $xr.Close() }
}

function Read-XamlFile([string]$Path) {
	$xml = [System.Xml.XmlReader]::Create($Path)
	try { return [System.Windows.Markup.XamlReader]::Load($xml) } finally { $xml.Close() }
}

# Builds a styled dialog window: dark custom title bar + close button, the merged
# style dictionary in ITS OWN Resources (DynamicResource lookups fail otherwise),
# and the caller's body XAML as content. SizeToContent, non-resizable, modal-ready.
function New-StyledDialog {
	param(
		[string]$Title,
		[string]$BodyXaml,
		[string]$Icon = '&#xE756;',
		[object]$Owner
	)
	$xaml = @"
<Window
	xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
	xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
	Title="$Title" SizeToContent="WidthAndHeight" ResizeMode="NoResize"
	WindowStartupLocation="CenterOwner" Background="Transparent"
	WindowStyle="SingleBorderWindow" ShowInTaskbar="False"
	TextOptions.TextFormattingMode="Ideal" UseLayoutRounding="True">
	<WindowChrome.WindowChrome>
		<WindowChrome CaptionHeight="42" ResizeBorderThickness="4" CornerRadius="0"
					  GlassFrameThickness="1" UseAeroCaptionButtons="False"/>
	</WindowChrome.WindowChrome>
	<Border Background="{DynamicResource BgBrush}">
		<Grid>
			<Grid.RowDefinitions>
				<RowDefinition Height="42"/>
				<RowDefinition Height="Auto"/>
			</Grid.RowDefinitions>
			<Border Grid.Row="0" Background="{DynamicResource PanelBrush}"
					BorderBrush="{DynamicResource StrokeSoftBrush}" BorderThickness="0,0,0,1">
				<Grid>
					<StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="14,0,120,0">
						<Border Width="22" Height="22" CornerRadius="6" Background="{DynamicResource AccentBrush}">
							<TextBlock Text="$Icon" FontFamily="{DynamicResource IconFont}" FontSize="11"
									   Foreground="{DynamicResource OnAccentBrush}"
									   HorizontalAlignment="Center" VerticalAlignment="Center"/>
						</Border>
						<TextBlock x:Name="DlgTitleText" Text="$Title" Margin="9,0,0,0" VerticalAlignment="Center"
								   FontFamily="{DynamicResource UiFont}" FontSize="13" FontWeight="SemiBold"
								   Foreground="{DynamicResource TextBrush}"/>
					</StackPanel>
					<Button x:Name="DlgCloseBtn" Style="{DynamicResource TitleBtnClose}" Content="&#xE8BB;"
							Height="34" HorizontalAlignment="Right" VerticalAlignment="Top"
							WindowChrome.IsHitTestVisibleInChrome="True"/>
				</Grid>
			</Border>
			<Grid Grid.Row="1">
$BodyXaml
			</Grid>
		</Grid>
	</Border>
</Window>
"@
	$win = Read-XamlString $xaml
	[void]$win.Resources.MergedDictionaries.Add($script:StyleDict)
	$win.FindName('DlgCloseBtn').Add_Click({ param($s, $e) [System.Windows.Window]::GetWindow($s).Close() })
	$ownerWin = if ($Owner) { $Owner } elseif ($script:Window -and $script:Window.IsVisible) { $script:Window } else { $null }
	if ($ownerWin) { $win.Owner = $ownerWin }
	return $win
}

function Set-DialogTitle($Win, [string]$Text) {
	$Win.Title = $Text
	$t = $Win.FindName('DlgTitleText')
	if ($t) { $t.Text = $Text }
}

# Reads a bounded integer out of a plain TextBox (replaces WinForms NumericUpDown)
function Get-NumericValue($TextBox, [int]$Max = 100) {
	$n = 0
	[void][int]::TryParse(([string]$TextBox.Text).Trim(), [ref]$n)
	return [Math]::Max(0, [Math]::Min($Max, $n))
}

# Wraps a TextBox so ported code can keep using .Value / .Enabled like the old NumericUpDown
function New-NumericProxy($TextBox, [int]$Max = 100) {
	$o = [pscustomobject]@{ Box = $TextBox; Max = $Max }
	$o | Add-Member -MemberType ScriptProperty -Name Value `
		-Value { Get-NumericValue $this.Box $this.Max } `
		-SecondValue { param($v) $this.Box.Text = [string][int]$v }
	$o | Add-Member -MemberType ScriptProperty -Name Enabled `
		-Value { $this.Box.IsEnabled } `
		-SecondValue { param($v) $this.Box.IsEnabled = [bool]$v }
	return $o
}

# ---------------------------------------------------------------------------
# Shared dialogs (Errors / Operation Complete / Warning / Update Complete)
# ---------------------------------------------------------------------------

function New-ErrorDialog([string]$Text) {
	$win = New-StyledDialog -Title 'Errors' -Icon '&#xEA39;' -BodyXaml @'
<StackPanel Margin="16" Width="440">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<StackPanel Orientation="Horizontal">
				<TextBlock Text="&#xEA39;" Style="{DynamicResource Icon}" Foreground="{DynamicResource ErrorBrush}"/>
				<TextBlock Text="One or more errors were reported" Style="{DynamicResource H3}" Margin="8,0,0,0" VerticalAlignment="Center"/>
			</StackPanel>
			<TextBox x:Name="ErrorBox" Style="{DynamicResource TextArea}" Margin="0,12,0,0" Height="240"
					 IsReadOnly="True" FontFamily="{DynamicResource MonoFont}" FontSize="12"/>
			<Button x:Name="ErrorOkBtn" Style="{DynamicResource BtnSecondary}" Content="Close"
					HorizontalAlignment="Right" MinWidth="90" Margin="0,12,0,0" IsDefault="True"/>
		</StackPanel>
	</Border>
</StackPanel>
'@
	$win.FindName('ErrorBox').Text = $Text
	$win.FindName('ErrorOkBtn').Add_Click({ param($s, $e) [System.Windows.Window]::GetWindow($s).Close() })
	return $win
}

# Check for errors and show the error dialog if there are any (same contract as before)
function CheckForErrors {
	if ($Error) {
		$win = New-ErrorDialog (($Error | Out-String).Trim())
		[void]$win.ShowDialog()
		$Error.Clear()
	}
}

function New-OperationCompleteDialog {
	$win = New-StyledDialog -Title 'Operation Complete' -Icon '&#xE73E;' -BodyXaml @'
<StackPanel Margin="16" Width="300">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
				<Border Width="34" Height="34" CornerRadius="17" Background="{DynamicResource SuccessSoftBrush}">
					<TextBlock Text="&#xE73E;" FontFamily="{DynamicResource IconFont}" FontSize="15"
							   Foreground="{DynamicResource SuccessBrush}"
							   HorizontalAlignment="Center" VerticalAlignment="Center"/>
				</Border>
				<TextBlock Text="Operation complete." Style="{DynamicResource H3}" Margin="12,0,0,0" VerticalAlignment="Center"/>
			</StackPanel>
			<Button x:Name="OkBtn" Style="{DynamicResource BtnPrimary}" Content="OK!" Margin="0,16,0,0" IsDefault="True"/>
		</StackPanel>
	</Border>
</StackPanel>
'@
	$win.FindName('OkBtn').Add_Click({ param($s, $e)
		$progressBar1.Value = 0
		[System.Windows.Window]::GetWindow($s).Close()
		Write-Host "Closed OperationComplete form."
	})
	return $win
}

# Show operation complete dialog (same contract as before)
function OperationComplete {
	$progressBar1.Value = 100
	Write-Host "Operation complete."
	[void](New-OperationCompleteDialog).ShowDialog()
}

function New-WarningDialog([string]$WarningText) {
	$win = New-StyledDialog -Title 'Warning!' -Icon '&#xE7BA;' -BodyXaml @'
<StackPanel Margin="16" Width="380">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<StackPanel Orientation="Horizontal">
				<TextBlock Text="&#xE7BA;" Style="{DynamicResource Icon}" Foreground="{DynamicResource WarnBrush}" VerticalAlignment="Top" Margin="0,2,0,0"/>
				<TextBlock x:Name="WarningTextLabel" Style="{DynamicResource Body}" Margin="10,0,0,0" MaxWidth="310"/>
			</StackPanel>
			<Border Style="{DynamicResource Divider}"/>
			<CheckBox x:Name="ConfirmWarningCheck" Content="I know what I'm doing"/>
			<Button x:Name="ConfirmWarningBtn" Style="{DynamicResource BtnDanger}" Content="Confirm"
					Margin="0,14,0,0" IsEnabled="False"/>
		</StackPanel>
	</Border>
</StackPanel>
'@
	$win.FindName('WarningTextLabel').Text = $WarningText
	return $win
}

# Show warning dialog with confirm gate; returns $true only if the user confirmed
function ShowWarningForm {
	param(
		[Parameter(Mandatory = $true)]
		[string]$warningText
	)
	Write-Host "Showing warning form..."
	$userClickedConfirm = New-Object PSObject -Property @{ Value = $false }
	Write-Host "userClickedConfirm is $($userClickedConfirm.Value)"
	$warningForm = New-WarningDialog $warningText
	$confirmWarningCheckBox = $warningForm.FindName('ConfirmWarningCheck')
	$confirmWarningButton = $warningForm.FindName('ConfirmWarningBtn')
	$onCheck = {
		if ($confirmWarningCheckBox.IsChecked) {
			Write-Host "confirmWarningCheckBox is checked."
			$confirmWarningButton.IsEnabled = $true
		} else {
			Write-Host "confirmWarningCheckBox is unchecked."
			$confirmWarningButton.IsEnabled = $false
		}
	}
	$confirmWarningCheckBox.Add_Checked($onCheck)
	$confirmWarningCheckBox.Add_Unchecked($onCheck)
	$confirmWarningButton.Add_Click({
		Write-Host "User clicked confirm."
		$userClickedConfirm.Value = $true
		Write-Host "userClickedConfirm is $($userClickedConfirm.Value)"
		$warningForm.Close()
	})
	[void]$warningForm.ShowDialog()
	Write-Host "Returning result... $($userClickedConfirm.Value)"
	return $userClickedConfirm.Value
}

function New-UpdateCompleteDialog([string]$Message) {
	$win = New-StyledDialog -Title 'Update-ScriptPackage' -Icon '&#xE777;' -BodyXaml @'
<StackPanel Margin="16" Width="300">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<TextBlock x:Name="UpdateMsgText" Style="{DynamicResource Body}" HorizontalAlignment="Center"/>
			<Button x:Name="CoolBtn" Style="{DynamicResource BtnPrimary}" Content="COOL!" Margin="0,16,0,0" IsDefault="True"/>
		</StackPanel>
	</Border>
</StackPanel>
'@
	$win.FindName('UpdateMsgText').Text = $Message
	$win.FindName('CoolBtn').Add_Click({ param($s, $e)
		$progressBar1.Value = 0
		[System.Windows.Window]::GetWindow($s).Close()
		Write-Host "Closed UpdateComplete form."
	})
	return $win
}

function New-ModulesMissingDialog([string]$MissingText) {
	$win = New-StyledDialog -Title 'PowerShell modules required' -Icon '&#xE896;' -BodyXaml @'
<StackPanel Margin="16" Width="400">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<StackPanel Orientation="Horizontal">
				<TextBlock Text="&#xE7BA;" Style="{DynamicResource Icon}" Foreground="{DynamicResource WarnBrush}" VerticalAlignment="Top" Margin="0,2,0,0"/>
				<TextBlock x:Name="ModulesText" Style="{DynamicResource Body}" Margin="10,0,0,0" MaxWidth="330"/>
			</StackPanel>
			<TextBlock Style="{DynamicResource Small}" Margin="26,8,0,0"
					   Text="Installation can take several minutes - the Microsoft.Graph module is large."/>
			<Border Style="{DynamicResource Divider}"/>
			<Grid>
				<Button x:Name="NotNowBtn" Style="{DynamicResource BtnGhost}" Content="Not Now"
						HorizontalAlignment="Left" MinWidth="90"/>
				<Button x:Name="InstallBtn" Style="{DynamicResource BtnPrimary}" Content="Install Modules"
						HorizontalAlignment="Right" MinWidth="130" IsDefault="True"/>
			</Grid>
		</StackPanel>
	</Border>
</StackPanel>
'@
	$win.FindName('ModulesText').Text = "Signing in needs PowerShell modules that are not installed yet:`n$MissingText"
	return $win
}

function UpdateProgressBar {
	param (
		$progressBarValue
	)
	$progressBar1.Value = $progressBarValue
}
