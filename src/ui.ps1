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
	# The title is plain text dropped into XAML attributes - escape &, <, >, " so a title like
	# "Create AD & Email accounts" can't break the parse. ($Icon is a glyph entity - left as-is.)
	$Title = [System.Security.SecurityElement]::Escape([string]$Title)
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
# Get-EXORecipient (falls back to Get-Recipient -Anr). Needs >=2 characters. $Prefer
# ('User'/'Mailbox'/'Group'/'Any') only affects ordering - all types are still returned.
# Session cache so NARROWING a search (typing more letters, or backspacing within a prefix we
# already fetched) filters locally instead of calling Exchange again. The server filter is
# Name/Alias/PrimarySmtp -like 'term*', so every match for a longer term is a strict subset of
# the anchor term's matches - filtering the cached rows is exact, not an approximation. Only a
# COMPLETE result set (server returned fewer than the cap) becomes an anchor, so we never narrow
# from a truncated list and miss someone. Reset when the tenant changes.
$script:AcAnchorTerm = ''
$script:AcAnchorRows = @()
$script:AcAnchorTenant = ''

# Prefix-cache narrow: if $Term extends a previously-cached COMPLETE result for the same tenant,
# return those rows filtered locally (instant, no network). Otherwise $null (caller must fetch).
# Shared by the sync path and the background (async) path so both benefit from the cache.
function Get-AcCacheNarrow([string]$Term, [string]$Tid) {
	$ic = [System.StringComparison]::OrdinalIgnoreCase
	if ($script:AcAnchorTenant -eq $Tid -and $script:AcAnchorTerm -and $Term.StartsWith($script:AcAnchorTerm, $ic)) {
		return @($script:AcAnchorRows | Where-Object {
			$_.Name.StartsWith($Term, $ic) -or $_.Alias.StartsWith($Term, $ic) -or $_.Email.StartsWith($Term, $ic)
		})
	}
	return $null
}

# Project raw Get-EXORecipient/Get-Recipient objects into cache rows and update the prefix anchor
# (cache only a COMPLETE fetch - fewer rows than the cap - so later narrowing can't miss anyone).
function ConvertTo-AcRows($Raw, [string]$Term, [string]$Tid, [int]$Max) {
	$rows = @(foreach ($r in $Raw) {
		[pscustomobject]@{
			Name = "$($r.DisplayName)"; Email = "$($r.PrimarySmtpAddress)"; Alias = "$($r.Alias)"
			Rtd  = "$($r.RecipientTypeDetails)"; Label = Get-RecipientTypeLabel "$($r.RecipientTypeDetails)"
		}
	}) | Where-Object { $_.Email }
	$rows = @($rows)
	if (@($Raw).Count -lt $Max) { $script:AcAnchorTerm = $Term; $script:AcAnchorRows = $rows; $script:AcAnchorTenant = $Tid }
	else { $script:AcAnchorTerm = ''; $script:AcAnchorRows = @(); $script:AcAnchorTenant = '' }
	return $rows
}

# Rank (float the field's preferred kind up) + sort + trim cache rows into the final suggestion list.
function Format-AcMatches($Rows, [string]$Prefer, [int]$Max, [string]$Term = '') {
	$target = switch ($Prefer) { 'Group' { 'Group' } 'Mailbox' { 'Mailbox' } 'User' { 'Mailbox' } default { '' } }
	$ic = [System.StringComparison]::OrdinalIgnoreCase
	$out = foreach ($r in $Rows) {
		[pscustomobject]@{
			Name = $r.Name; Email = $r.Email; Label = $r.Label
			# A match on the NAME the user typed ranks above one that only matched by alias/email, so
			# the first result always starts with what was typed (not a stray alias/email match).
			NameRank = if ($Term -and "$($r.Name)".StartsWith($Term, $ic)) { 0 } else { 1 }
			Rank = if ($target -and (Get-RecipientBucket $r.Rtd) -eq $target) { 0 } else { 1 }
		}
	}
	return @($out | Sort-Object NameRank, Rank, Name | Select-Object -First $Max)
}

# The SYNCHRONOUS lookup (default path). Cache-narrow if possible, else one bounded server query
# on the UI thread. The background path (below) runs the same query on a worker runspace instead.
function Get-RecipientMatches([string]$Term, [string]$Prefer = 'Any', [int]$Max = 10) {
	$Term = "$Term".Trim()
	if ($Term.Length -lt 2) { return @() }
	$conn = $null
	try { $conn = @(Get-ConnectionInformation -ErrorAction SilentlyContinue)[0] } catch { return @() }
	if (-not $conn) { return @() }
	$tid = "$($conn.TenantId)"
	$rows = Get-AcCacheNarrow $Term $tid
	if ($null -eq $rows) {
		$raw = @()
		try {
			if (Get-Command Get-EXORecipient -ErrorAction SilentlyContinue) {
				$safe = $Term -replace "'", "''"
				$filter = "Name -like '$safe*' -or Alias -like '$safe*' -or PrimarySmtpAddress -like '$safe*'"
				$raw = @(Get-EXORecipient -Filter $filter -Properties DisplayName, PrimarySmtpAddress, Alias, RecipientTypeDetails -ResultSize $Max -ErrorAction Stop)
			} else {
				$raw = @(Get-Recipient -Anr $Term -ResultSize $Max -ErrorAction Stop | Select-Object DisplayName, PrimarySmtpAddress, Alias, RecipientTypeDetails)
			}
		} catch { $raw = @() }
		$rows = ConvertTo-AcRows $raw $Term $tid $Max
	}
	return Format-AcMatches $rows $Prefer $Max $Term
}

# Would the NEXT lookup for $Term hit the network, or can it be served instantly from the prefix
# cache? Lets the dropdown skip the debounce for instant local narrowing, and only show the
# "Searching..." indicator when a real Exchange round-trip is coming. (Tenant isn't re-checked
# here - if it changed, Get-RecipientMatches re-fetches anyway; worst case we skip one indicator.)
# Defined as a top-level function so it reads the real $script: cache vars, not a closure's scope.
function Test-AcWouldQueryNetwork([string]$Term) {
	$Term = "$Term".Trim()
	if ($Term.Length -lt 2) { return $false }
	if (-not $script:AcAnchorTerm) { return $true }
	return -not $Term.StartsWith($script:AcAnchorTerm, [System.StringComparison]::OrdinalIgnoreCase)
}

# The field already holds a COMPLETE email address (e.g. the user pasted or finished typing one)?
# Then there's nothing to look up - suppress the dropdown so we don't pop it up just to show back
# the address that's already in the box (needs a dot in the domain, so "john@contoso" still searches).
function Test-AcIsCompleteEmail([string]$s) {
	return ("$s".Trim() -match '^[^@\s]+@[^@\s]+\.[^@\s]+$')
}

# One-time-per-tenant warm-up. The FIRST recipient lookup after signing in is slow (cold Exchange
# connection); a tiny priming query absorbs that cost once, so the user's first real search is
# fast. Tracked per tenant so it re-warms after a tenant switch. Top-level fns so they read the
# real $script scope (not a closure's).
$script:AcWarmedTenant = ''
function Test-AcNeedsWarmup {
	$conn = $null
	try { $conn = @(Get-ConnectionInformation -ErrorAction SilentlyContinue)[0] } catch { return $false }
	if (-not $conn) { return $false }
	return ("$($conn.TenantId)" -ne $script:AcWarmedTenant)
}
function Invoke-AcWarmup {
	$conn = $null
	try { $conn = @(Get-ConnectionInformation -ErrorAction SilentlyContinue)[0] } catch { return }
	if (-not $conn) { return }
	$tid = "$($conn.TenantId)"
	if ($script:AcWarmedTenant -eq $tid) { return }
	# Minimal query just to warm the connection - results are discarded, and we bypass the prefix
	# cache so it isn't polluted with this throwaway term.
	try {
		if (Get-Command Get-EXORecipient -ErrorAction SilentlyContinue) {
			[void](Get-EXORecipient -Filter "Name -like 'a*'" -Properties PrimarySmtpAddress -ResultSize 1 -ErrorAction Stop)
		} else {
			[void](Get-Recipient -Anr 'a' -ResultSize 1 -ErrorAction Stop)
		}
	} catch {}
	$script:AcWarmedTenant = $tid
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
	$em = New-Object System.Windows.Controls.TextBlock; $em.Text = $Email; $em.Foreground = $script:StyleDict['TextDimBrush']; $em.FontSize = 11
	[void]$sp.Children.Add($nm); [void]$sp.Children.Add($em)
	[System.Windows.Controls.Grid]::SetColumn($sp, 0); [void]$g.Children.Add($sp)
	if ($Label) {
		$lb = New-Object System.Windows.Controls.TextBlock; $lb.Text = $Label; $lb.Foreground = $script:StyleDict['TextDimBrush']; $lb.FontSize = 11; $lb.VerticalAlignment = 'Center'; $lb.Margin = '12,0,2,0'
		[System.Windows.Controls.Grid]::SetColumn($lb, 1); [void]$g.Children.Add($lb)
	}
	return $g
}

# ============================ Background (async) search engine ================================
# Runs Get-EXORecipient on a dedicated worker RUNSPACE so the UI thread stays free - the progress
# bar animates and the window never freezes. One worker per tenant, shared by every recipient
# field, connected silently (reuses the app's sign-in). Gated by $script:Settings.bgSearch, and
# EVERY failure path falls back to the synchronous Get-RecipientMatches, so search always works.
$script:AcWorker     = $null   # @{ RS; Key; ConnPS; ConnAsync; Ready; Started }
$script:AcQ          = $null   # in-flight query: @{ PS; Async; Gen; Render; Term; Prefer; Max }
$script:AcQGen       = 0
$script:AcWorkerFail = ''      # tenant key whose bg connect failed - fall back to sync, don't retry

# Diagnostic log for the background worker (Activity log + Logs\bg-search.txt) so a failed silent
# connect is visible instead of silently falling back.
function Write-BgLog([string]$msg) {
	try { Write-Host "bg: $msg" } catch {}
	try { $p = Join-Path (Split-Path $script:SrcDir -Parent) 'Logs\bg-search.txt'; "[$([datetime]::Now.ToString('s'))] $msg" | Out-File -LiteralPath $p -Append -Encoding utf8 } catch {}
}
$script:AcOffMsg = ''
function Write-BgOnce([string]$m) { if ($script:AcOffMsg -ne $m) { $script:AcOffMsg = $m; Write-BgLog $m } }

# Closure-safe accessors. Event-handler closures are .GetNewClosure(), where $script:Foo reads as
# null - so the bg-enabled and in-flight-query checks MUST go through these top-level functions
# (they read the REAL $script scope). This is the trap that made bg search never run.
function Test-AcBgEnabled { return [bool]($script:Settings -and $script:Settings.bgSearch) }
function Test-AcBusy      { return [bool]$script:AcQ }
function Clear-AcQuery    { if ($script:AcQ) { try { $script:AcQ.PS.Stop() } catch {}; try { $script:AcQ.PS.Dispose() } catch {}; $script:AcQ = $null } }

# Identity string for the current connection - "tenantId|org|upn". Changing it means a switch.
function Get-AcTenantKey {
	try { $c = @(Get-ConnectionInformation -ErrorAction SilentlyContinue)[0]; if ($c) { return "$($c.TenantId)|$($c.Organization)|$($c.UserPrincipalName)" } } catch {}
	return ''
}
function Reset-AcWorker {
	if ($script:AcQ) { try { $script:AcQ.PS.Stop() } catch {}; try { $script:AcQ.PS.Dispose() } catch {}; $script:AcQ = $null }
	try { Clear-AcIndex } catch {}
	if ($script:AcWorker) {
		try { if ($script:AcWorker.ConnPS) { $script:AcWorker.ConnPS.Dispose() } } catch {}
		try { $script:AcWorker.RS.Close(); $script:AcWorker.RS.Dispose() } catch {}
	}
	$script:AcWorker = $null
	try { Update-AcStatus } catch {}
}
# Ensure a worker exists + is connecting/connected for the CURRENT tenant. Never blocks. Returns
# 'ready' | 'connecting' | 'off' (flag off / not connected / EXO cmdlet missing / setup failed).
function Step-AcWorker {
	if ($env:SP_TEST -or $env:SP_SHOT) { return 'off' }   # never spin a real worker in test/shot runs
	if (-not ($script:Settings -and $script:Settings.bgSearch)) { return 'off' }
	# Gate on the MODULE being present (Connect-ExchangeOnline), NOT on Get-EXORecipient in THIS
	# runspace - that cmdlet may not be loaded in the app's main runspace even though the worker
	# (which imports its own module) has it. The worker query falls back to Get-Recipient anyway.
	if (-not (Get-Command Connect-ExchangeOnline -ErrorAction SilentlyContinue)) { Write-BgOnce 'ExchangeOnlineManagement not available - using classic search'; return 'off' }
	$key = Get-AcTenantKey
	if (-not $key) { Write-BgOnce 'not connected to a tenant yet - using classic search'; return 'off' }
	# Wait for the sign-in identity to fully populate before connecting the worker. Right after a
	# sign-in the UPN can be momentarily blank; connecting then, and reconnecting once it fills in,
	# wastes a runspace + a few seconds. The key is "tenantId|org|upn" - require the upn segment.
	# 'wait' keeps the warm-up polling but makes searches fall back to live (never a stuck queue).
	if (-not (($key -split '\|')[2])) { return 'wait' }
	if ($script:AcWorkerFail -and $script:AcWorkerFail -ne $key) { $script:AcWorkerFail = '' }  # new tenant, retry
	if ($script:AcWorkerFail -eq $key) { return 'off' }   # already failed this tenant - use sync, no thrash
	if ($script:AcWorker -and $script:AcWorker.Key -ne $key) { Reset-AcWorker }   # tenant switched
	if (-not $script:AcWorker) {
		try {
			$script:AcOffMsg = ''
			$rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
			$parts = $key -split '\|'; $org = $parts[1]; $upn = $parts[2]
			$ps = [PowerShell]::Create(); $ps.Runspace = $rs
			[void]$ps.AddScript({
				param($org, $upn)
				Import-Module ExchangeOnlineManagement
				$cp = @{ ShowBanner = $false; ErrorAction = 'Stop' }
				if ($org) { $cp.Organization = $org }; if ($upn) { $cp.UserPrincipalName = $upn }
				$k = (Get-Command Connect-ExchangeOnline).Parameters
				if ($k.ContainsKey('DisableWAM'))            { $cp.DisableWAM = $true }
				if ($k.ContainsKey('SkipLoadingCmdletHelp')) { $cp.SkipLoadingCmdletHelp = $true }
				Connect-ExchangeOnline @cp; 'ok'
			}).AddParameters(@{ org = $org; upn = $upn }) | Out-Null
			$script:AcWorker = @{ RS = $rs; Key = $key; ConnPS = $ps; ConnAsync = $ps.BeginInvoke(); Ready = $false; Started = [datetime]::Now }
			Write-BgLog "connecting worker (upn=$upn org=$org module=$((Get-Module ExchangeOnlineManagement | Select-Object -First 1).Version))..."
		} catch { Write-BgLog "worker SETUP failed: $($_.Exception.Message)"; Reset-AcWorker; $script:AcWorkerFail = $key; return 'off' }
	}
	if ($script:AcWorker.Ready) { return 'ready' }
	if ($script:AcWorker.ConnAsync.IsCompleted) {
		try {
			[void]$script:AcWorker.ConnPS.EndInvoke($script:AcWorker.ConnAsync)
			$ms = [int]([datetime]::Now - $script:AcWorker.Started).TotalMilliseconds
			Write-BgLog "worker READY in ${ms}ms."
			try { $script:AcWorker.ConnPS.Dispose() } catch {}
			$script:AcWorker.ConnPS = $null; $script:AcWorker.ConnAsync = $null; $script:AcWorker.Ready = $true
			return 'ready'
		} catch {
			$err = "$($_.Exception.Message)"
			try { $se = @($script:AcWorker.ConnPS.Streams.Error | ForEach-Object { "$_" }); if ($se.Count) { $err += ' ;; ' + ($se -join ' ;; ') } } catch {}
			Write-BgLog "worker CONNECT FAILED: $err"
			Reset-AcWorker; $script:AcWorkerFail = $key; return 'off'
		}
	}
	return 'connecting'
}
# Start an async query on the worker (superseding any in-flight one). $Render is a UI scriptblock
# called by Step-AcSearch with the finished matches. No-op unless the worker is ready.
function Request-AcSearch([string]$Term, [string]$Prefer, [int]$Max, [scriptblock]$Render) {
	if (-not ($script:AcWorker -and $script:AcWorker.Ready)) { return }
	if ($script:AcQ) { try { $script:AcQ.PS.Stop() } catch {}; try { $script:AcQ.PS.Dispose() } catch {}; $script:AcQ = $null }
	$script:AcQGen++
	$safe = $Term -replace "'", "''"
	$filter = "Name -like '$safe*' -or Alias -like '$safe*' -or PrimarySmtpAddress -like '$safe*'"
	try {
		$ps = [PowerShell]::Create(); $ps.Runspace = $script:AcWorker.RS
		[void]$ps.AddScript({
			param($filter, $term, $max)
			$(if (Get-Command Get-EXORecipient -ErrorAction SilentlyContinue) { Get-EXORecipient -Filter $filter -Properties DisplayName, PrimarySmtpAddress, Alias, RecipientTypeDetails -ResultSize $max -ErrorAction Stop } else { Get-Recipient -Anr $term -ResultSize $max -ErrorAction Stop }) |
				Select-Object DisplayName, PrimarySmtpAddress, Alias, RecipientTypeDetails
		}).AddParameters(@{ filter = $filter; term = $Term; max = $Max }) | Out-Null
		$script:AcQ = @{ PS = $ps; Async = $ps.BeginInvoke(); Gen = $script:AcQGen; Render = $Render; Term = $Term; Prefer = $Prefer; Max = $Max }
	} catch { $script:AcQ = $null }
}
# Poll hook (called from a UI DispatcherTimer): if the in-flight query finished, project+cache its
# rows and invoke its Render on the UI thread. On a worker error, rebuild the worker and fall back
# to a one-off synchronous lookup so the user still gets results.
function Step-AcSearch {
	if (-not $script:AcQ) { return }
	if (-not $script:AcQ.Async.IsCompleted) { return }
	$q = $script:AcQ; $script:AcQ = $null
	$failed = $false; $raw = @()
	try { $raw = @($q.PS.EndInvoke($q.Async)) } catch { $failed = $true }
	try { $q.PS.Dispose() } catch {}
	if ($failed) {
		Reset-AcWorker
		$matches = @(Get-RecipientMatches $q.Term $q.Prefer $q.Max)   # sync fallback for this term
	} else {
		$tid = ((Get-AcTenantKey) -split '\|')[0]   # tenantId segment, for the prefix cache
		$rows = ConvertTo-AcRows $raw $q.Term $tid $q.Max
		$matches = Format-AcMatches $rows $q.Prefer $q.Max $q.Term
	}
	try { & $q.Render $matches } catch {}
}

# ---- Background INDEX ---------------------------------------------------------------------------
# Load the tenant's recipients ONCE (in the worker) right after sign-in, so every search is then
# INSTANT (local filtering, no per-name network round-trip). Small/medium tenants only: a result at
# the cap means the tenant is bigger than we index, so we keep the live per-name search for it.
$script:AcIndex      = $null   # array of {Name;Email;Alias;Rtd;Label} or $null
$script:AcIndexKey   = ''      # tenant key the index (or in-flight load) belongs to
$script:AcIndexPS    = $null
$script:AcIndexAsync = $null
$script:AcIndexCap   = 5000

function Clear-AcIndex {
	if ($script:AcIndexPS) { try { $script:AcIndexPS.Stop() } catch {}; try { $script:AcIndexPS.Dispose() } catch {} }
	$script:AcIndexPS = $null; $script:AcIndexAsync = $null; $script:AcIndex = $null; $script:AcIndexKey = ''
}
function Test-AcIndexSettled { return [bool](-not $script:AcIndexAsync) }
# Kick off the background bulk load (once per tenant) on the connected worker.
function Start-AcIndex {
	if (-not ($script:AcWorker -and $script:AcWorker.Ready)) { return }
	$key = $script:AcWorker.Key
	if ($script:AcIndexKey -eq $key) { return }   # already loaded or loading for this tenant
	try {
		$ps = [PowerShell]::Create(); $ps.Runspace = $script:AcWorker.RS
		[void]$ps.AddScript({
			param($cap)
			if (Get-Command Get-EXORecipient -ErrorAction SilentlyContinue) {
				Get-EXORecipient -ResultSize $cap -Properties DisplayName, PrimarySmtpAddress, Alias, RecipientTypeDetails -ErrorAction Stop | Select-Object DisplayName, PrimarySmtpAddress, Alias, RecipientTypeDetails
			} else {
				Get-Recipient -ResultSize $cap -ErrorAction Stop | Select-Object DisplayName, PrimarySmtpAddress, Alias, RecipientTypeDetails
			}
		}).AddParameters(@{ cap = $script:AcIndexCap }) | Out-Null
		$script:AcIndexPS = $ps; $script:AcIndexAsync = $ps.BeginInvoke(); $script:AcIndexKey = $key
		Write-BgLog "indexing recipients in the background (up to $($script:AcIndexCap))..."
	} catch { Clear-AcIndex }
}
# Poll: finish the load and build the local index (only if COMPLETE - a result AT the cap means the
# tenant is bigger than we index, so stay on live search).
function Step-AcIndex {
	if (-not $script:AcIndexAsync) { return }
	if (-not $script:AcIndexAsync.IsCompleted) { return }
	$raw = @(); $ok = $true
	try { $raw = @($script:AcIndexPS.EndInvoke($script:AcIndexAsync)) } catch { $ok = $false }
	try { $script:AcIndexPS.Dispose() } catch {}
	$script:AcIndexPS = $null; $script:AcIndexAsync = $null
	if ($ok -and $raw.Count -gt 0 -and $raw.Count -lt $script:AcIndexCap) {
		$rows = @(foreach ($r in $raw) {
			[pscustomobject]@{ Name = "$($r.DisplayName)"; Email = "$($r.PrimarySmtpAddress)"; Alias = "$($r.Alias)"; Rtd = "$($r.RecipientTypeDetails)"; Label = Get-RecipientTypeLabel "$($r.RecipientTypeDetails)" }
		}) | Where-Object { $_.Email }
		$script:AcIndex = @($rows)
		Write-BgLog "indexed $($script:AcIndex.Count) recipients - searches are now instant."
	} else {
		$script:AcIndex = $null
		Write-BgLog "not indexing (rows=$($raw.Count) ok=$ok) - staying on live search."
	}
}
# Is a usable recipient index loaded for the CURRENT tenant? When true, searches are instant and
# can start from a single character (no network cost); when false the live search needs >=2 chars.
function Test-AcHasIndex {
	return [bool]($script:AcIndex -and $script:AcWorker -and $script:AcWorker.Ready -and $script:AcIndexKey -eq $script:AcWorker.Key)
}
# Instant local search over the index, or $null if there's no usable index for the current tenant.
function Get-AcIndexMatches([string]$Term, [string]$Prefer, [int]$Max) {
	if ("$Term".Length -lt 1) { return $null }
	if (-not (Test-AcHasIndex)) { return $null }
	$ic = [System.StringComparison]::OrdinalIgnoreCase
	$hits = @($script:AcIndex | Where-Object { $_.Name.StartsWith($Term, $ic) -or $_.Alias.StartsWith($Term, $ic) -or $_.Email.StartsWith($Term, $ic) })
	return Format-AcMatches $hits $Prefer $Max $Term
}
# Reflect the search state as a status LIGHT on the home screen (a search icon + short label, not a
# button): grey "Preparing search..." while it loads, green "Search ready" once instant search is
# available, amber "Live search" for a tenant too large to index. At-a-glance, no log needed.
function Update-AcStatus {
	$panel = $null; $icon = $null; $label = $null
	try { $panel = $script:UI.SearchStatusPanel; $icon = $script:UI.SearchStatusIcon; $label = $script:UI.SearchStatusLabel } catch {}
	if (-not ($panel -and $icon -and $label)) { return }
	if ((-not (Test-AcBgEnabled)) -or (-not $script:AcWorker)) { $panel.Visibility = 'Collapsed'; return }
	if (Test-AcHasIndex) {
		$label.Text = 'Search ready'; $panel.ToolTip = "Name/email search is ready - instant ($(@($script:AcIndex).Count) recipients loaded)"
		$icon.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'SuccessBrush')
		$label.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'SuccessBrush')
	} elseif ($script:AcWorker.Ready -and $script:AcIndexKey -eq $script:AcWorker.Key -and (-not $script:AcIndexAsync) -and (-not $script:AcIndex)) {
		$label.Text = 'Live search'; $panel.ToolTip = 'This tenant is too large to pre-load; name/email search runs live (slightly slower)'
		$icon.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'WarnBrush')
		$label.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'TextDimBrush')
	} else {
		$label.Text = "Preparing search$([char]0x2026)"; $panel.ToolTip = 'Loading this tenant''s recipients so name/email search will be instant...'
		$icon.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'TextFaintBrush')
		$label.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'TextDimBrush')
	}
	$panel.Visibility = 'Visible'
}

# App-level driver: after sign-in, connect the worker + build the index in the background so later
# searches are instant - independent of any field. Idempotent per tenant.
$script:AcWarmupTimer = $null
function Start-AcWarmup {
	if (-not (Test-AcBgEnabled)) { return }
	if ($script:AcWarmupTimer) { try { $script:AcWarmupTimer.Stop() } catch {} }
	$t = New-Object System.Windows.Threading.DispatcherTimer
	$t.Interval = [TimeSpan]::FromMilliseconds(250)
	$t.Add_Tick({
		try {
			$st = Step-AcWorker
			if ($st -eq 'off') { Update-AcStatus; $t.Stop(); return }
			Update-AcStatus; if ($st -ne 'ready') { return }
			Start-AcIndex
			Step-AcIndex
			Update-AcStatus; if (Test-AcIndexSettled) { $t.Stop() }
		} catch { try { $t.Stop() } catch {} }
	}.GetNewClosure())
	$script:AcWarmupTimer = $t
	$t.Start()
}

# One non-selectable dropdown row shown WHILE a live lookup runs. INTERIM: plain text only - an
# animated progress bar can't actually animate here because the lookup blocks the UI thread (the
# animation clock ticks on that same thread), so a bar just freezes on one frame and looks broken.
# The real animated bar returns with the background/async search (which frees the UI thread).
# Must be a top-level function (not inlined in the runQuery closure) - inside a .GetNewClosure()
# $script:StyleDict reads as null, and indexing it threw "Cannot index into a null array".
function New-AcLoadingRow {
	$si = New-Object System.Windows.Controls.ListBoxItem
	$si.IsHitTestVisible = $false
	$tb = New-Object System.Windows.Controls.TextBlock
	$tb.Text = "Preparing to search$([char]0x2026)"
	$tb.Foreground = $script:StyleDict['TextDimBrush']; $tb.FontSize = 12; $tb.FontStyle = 'Italic'
	$si.Content = $tb
	return $si
}

# Animated "Preparing to search..." row shown ONCE while the background worker connects (the UI
# thread is free then, so it animates). A hand-rolled sliding accent segment - the app's themed
# ProgressBar template is determinate-only and won't animate an indeterminate bar. The Loaded
# closure is created inside this function, so it can drive the captured transform safely.
function New-AcConnectingRow {
	$si = New-Object System.Windows.Controls.ListBoxItem
	$si.IsHitTestVisible = $false
	$sp = New-Object System.Windows.Controls.StackPanel
	# A full-width accent bar that PULSES its opacity - width-independent and started immediately,
	# so it animates reliably inside the popup (no dependency on ActualWidth or a Loaded event).
	$bar = New-Object System.Windows.Controls.Border
	$bar.Height = 3; $bar.CornerRadius = New-Object System.Windows.CornerRadius 2
	$bar.Background = $script:StyleDict['AccentBrush']
	$tb = New-Object System.Windows.Controls.TextBlock
	$tb.Text = "Preparing to search$([char]0x2026)"
	$tb.Foreground = $script:StyleDict['TextDimBrush']; $tb.FontSize = 12; $tb.FontStyle = 'Italic'
	$tb.Margin = New-Object System.Windows.Thickness (0, 8, 0, 0)
	[void]$sp.Children.Add($bar); [void]$sp.Children.Add($tb)
	$si.Content = $sp
	try {
		$anim = New-Object System.Windows.Media.Animation.DoubleAnimation
		$anim.From = 0.3; $anim.To = 1.0
		$anim.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds(0.7))
		$anim.AutoReverse = $true
		$anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
		$bar.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $anim)
	} catch {}
	return $si
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
	if ($script:Settings -and $script:Settings.recipientSearch -eq $false) { return }   # disabled in Settings
	Set-FieldWatermark $TextBox 'Name or email address'
	try {
		$borderXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource StrokeBrush}"
        BorderThickness="1" CornerRadius="8" Padding="3" MaxWidth="660">
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
		# Short debounce - only applied before a NETWORK fetch. Local (cached) narrowing runs with
		# no delay at all, straight from TextChanged.
		$timer.Interval = [TimeSpan]::FromMilliseconds(120)

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

		# Size the dropdown to at least the field width, but let it grow (up to MaxWidth) so long
		# email addresses show in full instead of being clipped.
		$sizePopup = { try { $border.MinWidth = [Math]::Max(260, $TextBox.ActualWidth) } catch {} }.GetNewClosure()

		# Fill the dropdown from a finished matches array (used by both the sync and background paths).
		$renderMatches = {
			param($matches)
			$list.Items.Clear()
			if (-not @($matches).Count) { $popup.IsOpen = $false; return }
			foreach ($m in $matches) {
				$it = New-Object System.Windows.Controls.ListBoxItem
				$it.Content = New-RecipientRow $m.Name $m.Email $m.Label
				$it.Tag = $m.Email
				$it.Add_MouseLeftButtonUp($choose)
				[void]$list.Items.Add($it)
			}
			& $sizePopup
			$popup.IsOpen = $true
		}.GetNewClosure()

		# Background path plumbing. $pending.Term = a search queued while the worker is still
		# connecting; $pending.Indicator = the animated "Preparing to search..." row is on screen (we
		# show it ONCE, during the connect - not per keystroke). An ~80ms poll advances the connect
		# and renders finished queries, self-stopping when idle.
		$pending = [pscustomobject]@{ Term = ''; Indicator = $false }
		# Show the one-time animated connecting indicator (only if it isn't already up).
		$showConnecting = {
			if (-not $pending.Indicator) { $list.Items.Clear(); [void]$list.Items.Add((New-AcConnectingRow)); & $sizePopup; $popup.IsOpen = $true; $pending.Indicator = $true }
		}.GetNewClosure()
		$poll = New-Object System.Windows.Threading.DispatcherTimer
		$poll.Interval = [TimeSpan]::FromMilliseconds(80)
		$poll.Add_Tick({
			try {
				$st = Step-AcWorker
				if ($st -eq 'off') { if ($pending.Indicator) { $popup.IsOpen = $false; $pending.Indicator = $false }; $poll.Stop(); return }
				if ($st -eq 'connecting' -or $st -eq 'wait') { return }    # still connecting/waiting: keep polling
				# Worker is ready:
				if ($pending.Term) { $t = $pending.Term; $pending.Term = ''; $pending.Indicator = $false; Request-AcSearch $t $Prefer 12 $renderMatches; return }
				Step-AcSearch                                              # renders a finished query (reads real $script:AcQ)
				if (Test-AcBusy) { return }                                # a query is still running - keep polling
				if ($pending.Indicator) { $popup.IsOpen = $false; $pending.Indicator = $false }  # connect done, nothing typed
				$poll.Stop()
			} catch { try { $poll.Stop() } catch {} }
		}.GetNewClosure())

		# Kick off a background lookup. If the worker is ready, dispatch quietly (no per-search
		# indicator - results just appear). If it's still doing its one-time connect, show the
		# animated indicator once and queue the term. Returns $false if background search is off.
		$startAsync = {
			param($term)
			$st = Step-AcWorker
			if ($st -eq 'off' -or $st -eq 'wait') { return $false }   # fall back to live/sync search
			if ($st -eq 'ready') { Request-AcSearch $term $Prefer 12 $renderMatches }
			else { & $showConnecting; $pending.Term = $term }
			$poll.Start()
			return $true
		}.GetNewClosure()

		$runQuery = {
			$timer.Stop()
			$term = "$($TextBox.Text)".Trim()
			if (Test-AcIsCompleteEmail $term) { $popup.IsOpen = $false; return }
			# INSTANT: if the tenant's recipients were indexed on sign-in, filter that locally - no
			# network, no wait. Works from ONE character (it's free). This is the common case.
			$idx = Get-AcIndexMatches $term $Prefer 12
			if ($null -ne $idx) { & $renderMatches (@($idx)); return }
			# No index -> live/network search needs at least 2 characters.
			if ($term.Length -lt 2) { $popup.IsOpen = $false; return }
			# Cache hit -> instant, no network round-trip (same in both modes).
			if (-not (Test-AcWouldQueryNetwork $term)) { & $renderMatches (@(Get-RecipientMatches $term $Prefer 12)); return }
			# Background mode: run the lookup off the UI thread (animated bar, no freeze). startAsync
			# self-gates (returns $false when bg is off / not connected), then we fall back to sync.
			if (& $startAsync $term) { return }
			# Synchronous fallback (original behavior): text hint, then a blocking lookup.
			$list.Items.Clear(); [void]$list.Items.Add((New-AcLoadingRow)); & $sizePopup; $popup.IsOpen = $true
			try { $border.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Render) } catch {}
			& $renderMatches (@(Get-RecipientMatches $term $Prefer 12))
		}.GetNewClosure()

		$timer.Add_Tick($runQuery)
		# The first time a recipient field is focused for a given tenant, run a one-time warm-up so
		# the first real search isn't cold. Show the "Preparing to search..." hint during it, then
		# clear it (nothing typed yet). After that, focusing does nothing until the tenant changes.
		$TextBox.Add_GotKeyboardFocus({
			$t = "$($TextBox.Text)".Trim()
			if ($t.Length -ge 2 -or (Test-AcIsCompleteEmail $t)) { return }
			# Background mode: start the worker connecting NOW. While it connects (the one time per
			# tenant), show the animated indicator; once ready it disappears and stays quiet.
			if (Test-AcBgEnabled) {
				Start-AcWarmup
				return
			}
			if (-not (Test-AcNeedsWarmup)) { return }
			$list.Items.Clear(); [void]$list.Items.Add((New-AcLoadingRow)); & $sizePopup; $popup.IsOpen = $true
			try { $border.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Render) } catch {}
			Invoke-AcWarmup
			$popup.IsOpen = $false
		}.GetNewClosure())
		# Local narrowing (cache hit) runs with no delay; a network fetch is debounced. The
		# "Preparing to search..." bar only shows during an actual live lookup (in runQuery) and is
		# replaced the moment results are ready.
		$TextBox.Add_TextChanged({
			if ($state.Suppress) { return }
			$timer.Stop()
			$t = "$($TextBox.Text)".Trim()
			# Nothing to search (too short, or a complete address already typed/pasted) - close it.
			if (Test-AcIsCompleteEmail $t) { $popup.IsOpen = $false; return }
			# Indexed tenant: search instantly from the FIRST character, no debounce.
				if ((Test-AcHasIndex) -and $t.Length -ge 1) { & $runQuery; return }
				# Live search needs >=2 chars; a network fetch is debounced, a cache narrow is instant.
				if ($t.Length -lt 2) { $popup.IsOpen = $false; return }
				if (Test-AcWouldQueryNetwork $t) { $timer.Start() } else { & $runQuery }
		}.GetNewClosure())
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
		$TextBox.Add_LostKeyboardFocus({
			# Leaving the field: stop this field's poll and drop any in-flight background query so a
			# late result can't re-open the dropdown after it's closed.
			$pending.Term = ''
			try { $poll.Stop() } catch {}
			Clear-AcQuery
			if ($popup.IsOpen -and -not $popup.IsKeyboardFocusWithin) { $popup.IsOpen = $false }
		}.GetNewClosure())
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
			<Grid>
				<Grid.ColumnDefinitions>
					<ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
				</Grid.ColumnDefinitions>
				<TextBlock Grid.Column="0" Text="$glyph" Style="{DynamicResource Icon}" Foreground="{DynamicResource $brush}" VerticalAlignment="Top" Margin="0,2,0,0"/>
				<ScrollViewer Grid.Column="1" MaxHeight="380" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="10,0,0,0">
					<TextBlock x:Name="NoticeText" Style="{DynamicResource Body}" TextWrapping="Wrap"/>
				</ScrollViewer>
				<Button Grid.Column="2" x:Name="EmailBlurBtn" Style="{DynamicResource IconBtn}" Width="26" Height="26" VerticalAlignment="Top" Margin="8,0,0,0" Visibility="Collapsed"
						ToolTip="Hide email addresses for a screenshot (cycles: off / domain only / whole address)">
					<TextBlock x:Name="EmailBlurIcon" Text="&#xE883;" FontFamily="{DynamicResource IconFont}" FontSize="14"/>
				</Button>
			</Grid>
			<Button x:Name="NoticeOkBtn" Style="{DynamicResource BtnPrimary}" Content="OK" HorizontalAlignment="Right" MinWidth="90" Margin="0,16,0,0" IsDefault="True"/>
		</StackPanel>
	</Border>
</StackPanel>
"@
	$notice = $win.FindName('NoticeText')
	$notice.Text = $Message
	$win.FindName('NoticeOkBtn').Add_Click({ param($s, $e) [System.Windows.Window]::GetWindow($s).Close() })

	# Blur/redact emails for screenshots - same cycle as the Errors dialog. Only offered when the
	# message actually contains an address.
	if ($script:EmailRx.IsMatch($Message)) {
		$blurBtn = $win.FindName('EmailBlurBtn'); $blurBtn.Visibility = 'Visible'
		$icon = $win.FindName('EmailBlurIcon')
		$raw  = $Message
		$st   = [pscustomobject]@{ Mode = 0 }   # 0 = shown, 1 = domain hidden, 2 = whole email hidden
		$blurBtn.Add_Click({
			$st.Mode = ($st.Mode + 1) % 3
			switch ($st.Mode) {
				0 { $notice.Text = $raw;                   $icon.Text = [string][char]0xE883 }
				1 { $notice.Text = Hide-EmailDomains $raw;  $icon.Text = [string][char]0xE889 }
				2 { $notice.Text = Hide-EmailsFull $raw;    $icon.Text = [string][char]0xE889 }
			}
		}.GetNewClosure())
	}
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
