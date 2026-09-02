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
											<TextBlock Text="&#xE35E;" FontFamily="{DynamicResource IconFont}" FontSize="13"
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

# Load an image WITHOUT keeping the file open. A plain BitmapImage(uri) holds a
# lock on the file, which makes the installer's file-replace fail during an
# in-app update ("being used by another process"). OnLoad reads it fully into
# memory and releases the handle, so updates work while the app is running.
function New-ImageSource([string]$Path) {
	$bi = [System.Windows.Media.Imaging.BitmapImage]::new()
	$bi.BeginInit()
	$bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
	$bi.UriSource = [Uri]$Path
	$bi.EndInit()
	$bi.Freeze()
	return $bi
}

# Builds a styled dialog window: dark custom title bar + close button, the merged
# style dictionary in ITS OWN Resources (DynamicResource lookups fail otherwise),
# and the caller's body XAML as content. SizeToContent, non-resizable, modal-ready.
function New-StyledDialog {
	param(
		[string]$Title,
		[string]$BodyXaml,
		[string]$Icon = '&#xE54E;',
		[object]$Owner
	)
	$xaml = @"
<Window
	xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
	xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
	Title="$Title" SizeToContent="WidthAndHeight" ResizeMode="NoResize"
	WindowStartupLocation="CenterOwner" Background="Transparent"
	WindowStyle="None" ShowInTaskbar="False"
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
					<Button x:Name="DlgCloseBtn" Style="{DynamicResource TitleBtnClose}" Content="&#xE6D3;"
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

# ---------------------------------------------------------------------------
# Recipient type-ahead: start typing a name in any email field and pick a match from the tenant.
# ---------------------------------------------------------------------------

# Short tag shown next to a suggestion. Empty for a normal user mailbox (so those just show
# name + email); a friendly label for anything else.
function Get-RecipientTypeLabel([string]$RecipientTypeDetails) {
	switch -Regex ($RecipientTypeDetails) {
		'SharedMailbox'                 { return 'shared mailbox' }
		'RoomMailbox'                   { return 'room' }
		'EquipmentMailbox'              { return 'equipment' }
		'SchedulingMailbox'             { return 'scheduling' }
		'GroupMailbox'                  { return 'Teams / Microsoft 365 group' }
		'DynamicDistributionGroup'      { return 'dynamic distribution list' }
		'MailUniversalSecurityGroup'    { return 'mail-enabled security group' }
		'RoomList'                      { return 'room list' }
		'MailUniversalDistributionGroup|MailNonUniversalGroup' { return 'distribution list' }
		'MailContact'                   { return 'contact' }
		'GuestMailUser'                 { return 'guest' }
		'MailUser'                      { return 'external / mail user' }
		'UserMailbox'                   { return '' }
		default                         { return '' }
	}
}
# Ranking bucket for a recipient type, used to float the field's relevant kind to the top.
function Get-RecipientBucket([string]$rtd) {
	if ($rtd -match 'GroupMailbox|Distribution|MailUniversal|MailNonUniversal|RoomList') { return 'Group' }
	if ($rtd -match 'Mailbox')  { return 'Mailbox' }
	return 'Other'
}

# Find recipients matching $Term for the type-ahead. Deliberately LIGHT so it never hangs the UI:
# no bulk preload - each lookup is a single, bounded, server-side query. Uses the fast REST cmdlet
# Get-EXORecipient (falls back to Get-Recipient -Anr). Needs >=3 characters. $Prefer
# ('User'/'Mailbox'/'Group'/'Any') only affects ordering - all types are still returned.
function Get-RecipientMatches([string]$Term, [string]$Prefer = 'Any', [int]$Max = 10) {
	$Term = "$Term".Trim()
	if ($Term.Length -lt 3) { return @() }
	try { if (-not (Get-ConnectionInformation -ErrorAction SilentlyContinue)) { return @() } } catch { return @() }
	$raw = @()
	try {
		if (Get-Command Get-EXORecipient -ErrorAction SilentlyContinue) {
			$safe = $Term -replace "'", "''"
			$filter = "Name -like '$safe*' -or Alias -like '$safe*' -or PrimarySmtpAddress -like '$safe*'"
			$raw = @(Get-EXORecipient -Filter $filter -Properties DisplayName, PrimarySmtpAddress, RecipientTypeDetails -ResultSize $Max -ErrorAction Stop)
		} else {
			$raw = @(Get-Recipient -Anr $Term -ResultSize $Max -ErrorAction Stop | Select-Object DisplayName, PrimarySmtpAddress, RecipientTypeDetails)
		}
	} catch { $raw = @() }
	$target = switch ($Prefer) { 'Group' { 'Group' } 'Mailbox' { 'Mailbox' } 'User' { 'Mailbox' } default { '' } }
	$out = foreach ($r in $raw) {
		$rtd = "$($r.RecipientTypeDetails)"
		[pscustomobject]@{
			Name  = "$($r.DisplayName)"
			Email = "$($r.PrimarySmtpAddress)"
			Label = Get-RecipientTypeLabel $rtd
			Rank  = if ($target -and (Get-RecipientBucket $rtd) -eq $target) { 0 } else { 1 }
		}
	}
	return @($out | Where-Object { $_.Email } | Sort-Object Rank, Name | Select-Object -First $Max)
}

# Faint placeholder text shown inside an empty field (e.g. "Name or email address") to make it
# clear you can type either. Overlays a non-clickable TextBlock in the field's Grid cell and
# hides it once you type. Only applies when the field lives in a Grid (which the recipient
# fields do); otherwise it's a harmless no-op.
function Set-FieldWatermark($TextBox, [string]$Text) {
	if (-not $TextBox) { return }
	$parent = $TextBox.Parent
	if (-not ($parent -is [System.Windows.Controls.Grid])) { return }
	try {
		$ph = New-Object System.Windows.Controls.TextBlock
		$ph.Text = $Text
		$ph.Foreground = $script:StyleDict['TextFaintBrush']
		$ph.IsHitTestVisible = $false
		$ph.VerticalAlignment = 'Center'
		$ph.FontSize = 13
		$ph.Margin = New-Object System.Windows.Thickness (11, 0, 6, 0)
		$ph.TextTrimming = 'CharacterEllipsis'
		[System.Windows.Controls.Grid]::SetColumn($ph, [System.Windows.Controls.Grid]::GetColumn($TextBox))
		[System.Windows.Controls.Grid]::SetRow($ph, [System.Windows.Controls.Grid]::GetRow($TextBox))
		[System.Windows.Controls.Grid]::SetColumnSpan($ph, [System.Windows.Controls.Grid]::GetColumnSpan($TextBox))
		[void]$parent.Children.Add($ph)
		$upd = { $ph.Visibility = if ("$($TextBox.Text)".Length -gt 0) { 'Collapsed' } else { 'Visible' } }.GetNewClosure()
		& $upd
		$TextBox.Add_TextChanged($upd)
	} catch {}
}

# Build one suggestion row: "Name" over "email" on the left, an optional type tag on the right.
function New-RecipientRow([string]$Name, [string]$Email, [string]$Label) {
	$g = New-Object System.Windows.Controls.Grid
	$c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = New-Object System.Windows.GridLength (1, ([System.Windows.GridUnitType]::Star))
	$c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto
	$g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
	$sp = New-Object System.Windows.Controls.StackPanel
	$nm = New-Object System.Windows.Controls.TextBlock; $nm.Text = $Name; $nm.Foreground = $script:StyleDict['TextBrush']; $nm.FontSize = 13; $nm.TextTrimming = 'CharacterEllipsis'
	$em = New-Object System.Windows.Controls.TextBlock; $em.Text = $Email; $em.Foreground = $script:StyleDict['TextDimBrush']; $em.FontSize = 11; $em.TextTrimming = 'CharacterEllipsis'
	[void]$sp.Children.Add($nm); [void]$sp.Children.Add($em)
	[System.Windows.Controls.Grid]::SetColumn($sp, 0); [void]$g.Children.Add($sp)
	if ($Label) {
		$lb = New-Object System.Windows.Controls.TextBlock; $lb.Text = $Label; $lb.Foreground = $script:StyleDict['TextDimBrush']; $lb.FontSize = 11; $lb.VerticalAlignment = 'Center'; $lb.Margin = '12,0,2,0'
		[System.Windows.Controls.Grid]::SetColumn($lb, 1); [void]$g.Children.Add($lb)
	}
	return $g
}

# Screenshot-only: a dialog showing a field with an open suggestion dropdown of sample rows.
function New-AcPreviewDialog([string]$Title, [string]$FieldLabel, [string]$Typed, $Rows) {
	$w = New-StyledDialog -Title $Title -Icon '&#xE721;' -BodyXaml @"
<StackPanel Margin="16" Width="380">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<TextBlock Text="$FieldLabel" Style="{DynamicResource Dim}"/>
			<TextBox x:Name="AcField" Margin="0,6,0,0" Text="$Typed"/>
			<Border Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource StrokeBrush}" BorderThickness="1" CornerRadius="8" Padding="3" Margin="0,4,0,0">
				<ListBox x:Name="AcList" Background="Transparent" BorderThickness="0"/>
			</Border>
		</StackPanel>
	</Border>
</StackPanel>
"@
	$list = $w.FindName('AcList')
	foreach ($r in $Rows) { $it = New-Object System.Windows.Controls.ListBoxItem; $it.Content = New-RecipientRow $r[0] $r[1] $r[2]; [void]$list.Items.Add($it) }
	return $w
}

# Attach name/email type-ahead to a TextBox. As the user types, a themed dropdown lists matching
# recipients (name + email, with a type tag for non-user mailboxes); picking one fills in the
# email. Free typing still works, and it stays silent when not connected to a tenant. $Prefer
# floats the field's relevant kind to the top. Never throws - on any error the box stays plain.
function Enable-RecipientAutocomplete($TextBox, [string]$Prefer = 'Any') {
	if (-not $TextBox) { return }
	Set-FieldWatermark $TextBox 'Name or email address'
	try {
		$borderXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource StrokeBrush}"
        BorderThickness="1" CornerRadius="8" Padding="3">
  <ListBox x:Name="AcList" Background="Transparent" BorderThickness="0" MaxHeight="264"
           ScrollViewer.HorizontalScrollBarVisibility="Disabled">
    <ListBox.ItemContainerStyle>
      <Style TargetType="ListBoxItem">
        <Setter Property="Padding" Value="8,5"/>
        <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="ListBoxItem">
              <Border x:Name="ib" Background="Transparent" CornerRadius="5" Padding="{TemplateBinding Padding}">
                <ContentPresenter/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ib" Property="Background" Value="{DynamicResource CardHoverBrush}"/></Trigger>
                <Trigger Property="IsSelected" Value="True"><Setter TargetName="ib" Property="Background" Value="{DynamicResource SelectionBrush}"/></Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Style>
    </ListBox.ItemContainerStyle>
  </ListBox>
</Border>
'@
		$border = Read-XamlString $borderXaml
		[void]$border.Resources.MergedDictionaries.Add($script:StyleDict)
		$list = $border.FindName('AcList')
		$popup = New-Object System.Windows.Controls.Primitives.Popup
		$popup.PlacementTarget = $TextBox
		$popup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
		$popup.StaysOpen = $false
		$popup.AllowsTransparency = $true
		$popup.Child = $border

		$state = [pscustomobject]@{ Suppress = $false }
		$timer = New-Object System.Windows.Threading.DispatcherTimer
		$timer.Interval = [TimeSpan]::FromMilliseconds(500)

		$choose = {
			if ($list.SelectedItem) {
				$state.Suppress = $true
				$TextBox.Text = [string]$list.SelectedItem.Tag
				try { $TextBox.CaretIndex = $TextBox.Text.Length } catch {}
				$state.Suppress = $false
				$popup.IsOpen = $false
				$TextBox.Focus()
			}
		}.GetNewClosure()

		$runQuery = {
			$timer.Stop()
			$term = "$($TextBox.Text)".Trim()
			if ($term.Length -lt 3) { $popup.IsOpen = $false; return }
			$hits = @(Get-RecipientMatches $term $Prefer 12)
			$list.Items.Clear()
			if (-not $hits.Count) { $popup.IsOpen = $false; return }
			foreach ($m in $hits) {
				$it = New-Object System.Windows.Controls.ListBoxItem
				$it.Content = New-RecipientRow $m.Name $m.Email $m.Label
				$it.Tag = $m.Email
				$it.Add_MouseLeftButtonUp($choose)
				[void]$list.Items.Add($it)
			}
			try { $popup.Width = [Math]::Max(240, $TextBox.ActualWidth) } catch {}
			$popup.IsOpen = $true
		}.GetNewClosure()

		$timer.Add_Tick($runQuery)
		$TextBox.Add_TextChanged({ if (-not $state.Suppress) { $timer.Stop(); $timer.Start() } }.GetNewClosure())
		$TextBox.Add_PreviewKeyDown({
			param($s, $e)
			if (-not $popup.IsOpen) { return }
			if ($e.Key -eq 'Down') {
				if ($list.Items.Count) { $list.SelectedIndex = 0; $c = $list.ItemContainerGenerator.ContainerFromIndex(0); if ($c) { [void]$c.Focus() } }
				$e.Handled = $true
			} elseif ($e.Key -eq 'Escape') { $popup.IsOpen = $false; $e.Handled = $true }
			elseif ($e.Key -eq 'Enter' -and $list.SelectedItem) { & $choose; $e.Handled = $true }
		}.GetNewClosure())
		$list.Add_PreviewKeyDown({
			param($s, $e)
			if ($e.Key -eq 'Enter') { & $choose; $e.Handled = $true }
			elseif ($e.Key -eq 'Escape') { $popup.IsOpen = $false; $TextBox.Focus(); $e.Handled = $true }
		}.GetNewClosure())
		$TextBox.Add_LostKeyboardFocus({ if ($popup.IsOpen -and -not $popup.IsKeyboardFocusWithin) { $popup.IsOpen = $false } }.GetNewClosure())
	} catch { }
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

# Redact email addresses in error text so an error screenshot can be shared without
# exposing them. Domain-only keeps the local part (admin@********); full hides all of it.
$script:EmailRx = [regex]'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}'
function Hide-EmailDomains([string]$Text) {
	$b = [string][char]0x2022
	([regex]'([A-Za-z0-9._%+\-]+)@([A-Za-z0-9.\-]+\.[A-Za-z]{2,})').Replace($Text, { param($m) $m.Groups[1].Value + '@' + ($b * $m.Groups[2].Value.Length) }.GetNewClosure())
}
function Hide-EmailsFull([string]$Text) {
	$b = [string][char]0x2022
	$script:EmailRx.Replace($Text, { param($m) $b * $m.Value.Length }.GetNewClosure())
}

function New-ErrorDialog([string]$Text) {
	$win = New-StyledDialog -Title 'Errors' -Icon '&#xE877;' -BodyXaml @'
<StackPanel Margin="16" Width="440">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<Grid>
				<StackPanel Orientation="Horizontal" HorizontalAlignment="Left">
					<TextBlock Text="&#xE877;" Style="{DynamicResource Icon}" Foreground="{DynamicResource ErrorBrush}"/>
					<TextBlock Text="One or more errors were reported" Style="{DynamicResource H3}" Margin="8,0,0,0" VerticalAlignment="Center"/>
				</StackPanel>
				<StackPanel x:Name="EmailBlurPanel" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Visibility="Collapsed">
					<TextBlock x:Name="EmailBlurLabel" Text="Emails shown" Style="{DynamicResource Small}" VerticalAlignment="Center" Margin="0,0,6,0"/>
					<Button x:Name="EmailBlurBtn" Style="{DynamicResource IconBtn}" Width="26" Height="26"
							ToolTip="Hide email addresses for a screenshot (cycles: off / domain only / whole address)">
						<TextBlock x:Name="EmailBlurIcon" Text="&#xE883;" FontFamily="{DynamicResource IconFont}" FontSize="14"/>
					</Button>
				</StackPanel>
			</Grid>
			<TextBox x:Name="ErrorBox" Style="{DynamicResource TextArea}" Margin="0,12,0,0" Height="240"
					 IsReadOnly="True" FontFamily="{DynamicResource MonoFont}" FontSize="12"/>
			<Button x:Name="ErrorOkBtn" Style="{DynamicResource BtnSecondary}" Content="Close"
					HorizontalAlignment="Right" MinWidth="90" Margin="0,12,0,0" IsDefault="True"/>
		</StackPanel>
	</Border>
</StackPanel>
'@
	$box = $win.FindName('ErrorBox')
	$box.Text = $Text
	$win.FindName('ErrorOkBtn').Add_Click({ param($s, $e) [System.Windows.Window]::GetWindow($s).Close() })

	# Only offer the blur control if there's actually an email address in the error.
	if ($script:EmailRx.IsMatch($Text)) {
		$win.FindName('EmailBlurPanel').Visibility = 'Visible'
		$label = $win.FindName('EmailBlurLabel')
		$icon  = $win.FindName('EmailBlurIcon')
		$raw   = $Text
		$state = [pscustomobject]@{ Mode = 0 }   # 0 = shown, 1 = domain hidden, 2 = whole email hidden
		$win.FindName('EmailBlurBtn').Add_Click({
			$state.Mode = ($state.Mode + 1) % 3
			switch ($state.Mode) {
				0 { $box.Text = $raw;                  $label.Text = 'Emails shown';  $icon.Text = [string][char]0xE883 }
				1 { $box.Text = Hide-EmailDomains $raw; $label.Text = 'Domain hidden'; $icon.Text = [string][char]0xE889 }
				2 { $box.Text = Hide-EmailsFull $raw;   $label.Text = 'Email hidden';  $icon.Text = [string][char]0xE889 }
			}
		}.GetNewClosure())
	}
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
	$win = New-StyledDialog -Title 'Operation Complete' -Icon '&#xE460;' -BodyXaml @'
<StackPanel Margin="16" Width="300">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
				<Border Width="34" Height="34" CornerRadius="17" Background="{DynamicResource SuccessSoftBrush}">
					<TextBlock Text="&#xE460;" FontFamily="{DynamicResource IconFont}" FontSize="15"
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

# Simple modal message popup with one OK button. $Kind = 'Info' | 'Warn' | 'Error'.
function New-NoticeDialog([string]$Title, [string]$Message, [string]$Kind = 'Info') {
	switch ($Kind) {
		'Warn'  { $glyph = '&#xF561;'; $brush = 'WarnBrush' }
		'Error' { $glyph = '&#xE877;'; $brush = 'ErrorBrush' }
		default { $glyph = '&#xEA88;'; $brush = 'AccentBrush' }
	}
	$win = New-StyledDialog -Title $Title -Icon $glyph -BodyXaml @"
<StackPanel Margin="16" Width="360">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<StackPanel Orientation="Horizontal">
				<TextBlock Text="$glyph" Style="{DynamicResource Icon}" Foreground="{DynamicResource $brush}" VerticalAlignment="Top" Margin="0,2,0,0"/>
				<ScrollViewer MaxHeight="380" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="10,0,0,0">
					<TextBlock x:Name="NoticeText" Style="{DynamicResource Body}" MaxWidth="290" TextWrapping="Wrap"/>
				</ScrollViewer>
			</StackPanel>
			<Button x:Name="NoticeOkBtn" Style="{DynamicResource BtnPrimary}" Content="OK" HorizontalAlignment="Right" MinWidth="90" Margin="0,16,0,0" IsDefault="True"/>
		</StackPanel>
	</Border>
</StackPanel>
"@
	$win.FindName('NoticeText').Text = $Message
	$win.FindName('NoticeOkBtn').Add_Click({ param($s, $e) [System.Windows.Window]::GetWindow($s).Close() })
	return $win
}
function Show-Notice([string]$Title, [string]$Message, [string]$Kind = 'Info') {
	if ($env:SP_SHOT -or $env:SP_TEST) { return }   # don't block automated runs
	[void](New-NoticeDialog $Title $Message $Kind).ShowDialog()
}

function New-WarningDialog([string]$WarningText) {
	$win = New-StyledDialog -Title 'Warning!' -Icon '&#xF561;' -BodyXaml @'
<StackPanel Margin="16" Width="380">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<StackPanel Orientation="Horizontal">
				<TextBlock Text="&#xF561;" Style="{DynamicResource Icon}" Foreground="{DynamicResource WarnBrush}" VerticalAlignment="Top" Margin="0,2,0,0"/>
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
	$win = New-StyledDialog -Title 'Update-ScriptPackage' -Icon '&#xE171;' -BodyXaml @'
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

function New-ModulesMissingDialog([string]$MissingText, [string]$Intro = 'Signing in needs PowerShell modules that are not installed yet:') {
	$win = New-StyledDialog -Title 'PowerShell modules required' -Icon '&#xE0DD;' -BodyXaml @'
<StackPanel Margin="16" Width="400">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<StackPanel Orientation="Horizontal">
				<TextBlock Text="&#xF561;" Style="{DynamicResource Icon}" Foreground="{DynamicResource WarnBrush}" VerticalAlignment="Top" Margin="0,2,0,0"/>
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
	$win.FindName('ModulesText').Text = "$Intro`n$MissingText"
	return $win
}

# Builds (but does not show) a Yes/No confirmation dialog.
function New-ConfirmDialog([string]$Title, [string]$Message, [string]$Icon = '&#xF561;') {
	$win = New-StyledDialog -Title $Title -Icon $Icon -BodyXaml @"
<StackPanel Margin="16" Width="330">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<StackPanel Orientation="Horizontal">
				<TextBlock Text="$Icon" Style="{DynamicResource Icon}" Foreground="{DynamicResource WarnBrush}" VerticalAlignment="Top" Margin="0,2,0,0"/>
				<ScrollViewer MaxHeight="340" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="10,0,0,0">
					<TextBlock x:Name="MsgText" Style="{DynamicResource Body}" MaxWidth="260" TextWrapping="Wrap"/>
				</ScrollViewer>
			</StackPanel>
			<Border Style="{DynamicResource Divider}"/>
			<Grid>
				<Button x:Name="NoBtn" Style="{DynamicResource BtnGhost}" Content="No" HorizontalAlignment="Left" MinWidth="82"/>
				<Button x:Name="YesBtn" Style="{DynamicResource BtnPrimary}" Content="Yes" HorizontalAlignment="Right" MinWidth="82" IsDefault="True"/>
			</Grid>
		</StackPanel>
	</Border>
</StackPanel>
"@
	$win.FindName('MsgText').Text = $Message
	return $win
}

# Shows a Yes/No confirmation dialog. Returns $true if the user chose Yes.
function Confirm-YesNo([string]$Title, [string]$Message, [string]$Icon = '&#xF561;') {
	# During automated runs (self-test / screenshots) a modal ShowDialog would BLOCK
	# the run and pop a window onto the screen that a human has to click to continue.
	# Auto-answer instead. $script:AutoConfirmAnswer lets a test force Yes/No; default Yes.
	if ($env:SP_TEST -or $env:SP_SHOT) {
		if ($null -ne $script:AutoConfirmAnswer) { return [bool]$script:AutoConfirmAnswer }
		return $true
	}
	$result = New-Object PSObject -Property @{ Yes = $false }
	$win = New-ConfirmDialog $Title $Message $Icon
	$win.FindName('YesBtn').Add_Click({ $result.Yes = $true; [System.Windows.Window]::GetWindow($this).Close() }.GetNewClosure())
	$win.FindName('NoBtn').Add_Click({ [System.Windows.Window]::GetWindow($this).Close() })
	[void]$win.ShowDialog()
	return $result.Yes
}

function UpdateProgressBar {
	param (
		$progressBarValue
	)
	$progressBar1.Value = $progressBarValue
}
