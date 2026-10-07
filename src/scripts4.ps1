# ============================ Get-UserMemberships ====================================
# Read-only report of what a person belongs to and can act as - the cloud groups that HAVE an
# email address (distribution lists, Teams / Microsoft 365 groups, mail-enabled security groups)
# plus the mailboxes they can Send As - shown one column per type, each a scrollable list that
# looks like the email search, with the name AND the address on every row. Look up one person
# (type to search) or paste a list to do several at once; Copy (at the bottom) gives a tidy
# plain-text list grouped by person, ready to paste into an email.
#
# FAST by design: one Graph group lookup + one Send As reverse lookup per person - NO per-mailbox
# Full Access scan. Groups are cloud only; dynamic and on-prem-synced groups are listed too, tagged.

# The email-search look for each column: a rounded card holding a scrollable, hover-highlighting
# list (same styling as the recipient autocomplete popup).
$script:MemColListXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource StrokeBrush}"
        BorderThickness="1" CornerRadius="8" Padding="3">
  <ListBox x:Name="ColList" Background="Transparent" BorderThickness="0" MaxHeight="300"
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

function New-UserMembershipsDialog {
	New-StyledDialog -Title 'Get-UserMemberships' -Icon '&#xED75;' -BodyXaml @'
<StackPanel Margin="16" Width="1040">
	<Border Style="{DynamicResource Card}">
		<Grid>
			<Grid.ColumnDefinitions>
				<ColumnDefinition Width="Auto"/>
				<ColumnDefinition Width="*"/>
				<ColumnDefinition Width="Auto"/>
				<ColumnDefinition Width="Auto"/>
			</Grid.ColumnDefinitions>
			<TextBlock Text="Person" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
			<TextBox x:Name="UserInput" Grid.Column="1" Margin="10,0,0,0"/>
			<Button x:Name="LookupBtn" Grid.Column="2" Style="{DynamicResource BtnPrimary}" Content="Look up" MinWidth="110" Margin="10,0,0,0"/>
			<Button x:Name="PasteBtn" Grid.Column="3" Style="{DynamicResource BtnSecondary}" Content="Paste list" MinWidth="110" Margin="8,0,0,0"/>
		</Grid>
	</Border>
	<TextBlock x:Name="ResultStatus" Style="{DynamicResource Small}" Margin="2,8,0,0" TextWrapping="Wrap"/>
	<ScrollViewer MaxHeight="440" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,8,0,0">
		<StackPanel x:Name="ResultsHost"/>
	</ScrollViewer>
	<Grid Margin="0,12,0,0">
		<Grid.ColumnDefinitions>
			<ColumnDefinition Width="*"/>
			<ColumnDefinition Width="Auto"/>
		</Grid.ColumnDefinitions>
		<TextBlock x:Name="TotalText" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
		<Button x:Name="CopyBtn" Grid.Column="1" Style="{DynamicResource BtnPrimary}" Content="Copy" MinWidth="120" IsEnabled="False"/>
	</Grid>
</StackPanel>
'@
}

# The report's columns, in display order. Only items WITH an email address are kept. Mail-enabled
# security groups (which come back as "Dl" from the inventory) get their own Security column.
function Get-MembershipReportColumns($Inv) {
	$dls     = @($Inv.Dl      | Where-Object { "$($_.Id)".Trim() })
	$secMail = @($dls         | Where-Object { $_.SecurityEnabled })
	$dlOnly  = @($dls         | Where-Object { -not $_.SecurityEnabled })
	$unified = @($Inv.Unified | Where-Object { "$($_.Id)".Trim() })
	$saShared = @($Inv.SendAs | Where-Object { -not $_.Personal -and "$($_.Id)".Trim() })
	$saUser   = @($Inv.SendAs | Where-Object { $_.Personal -and "$($_.Id)".Trim() })
	@(
		@{ Head = 'Shared mailboxes';              Items = $saShared }
		@{ Head = 'Security groups';               Items = $secMail }
		@{ Head = 'Distribution lists';            Items = $dlOnly }
		@{ Head = 'Teams / Microsoft 365 groups';  Items = $unified }
		@{ Head = 'User mailboxes';                Items = $saUser }
	)
}

# Right-hand label on a row: "Send As" for a mailbox, a short dynamic/on-prem tag for a group
# (kept short so it doesn't squeeze the name + email in a narrow column).
function Get-MembershipRowLabel($Item) {
	if ($Item.Kind -eq 'SendAs') { return 'Send As' }
	$n = "$($Item.Note)"
	if ($n -match 'on-prem') { return 'on-prem' }
	if ($n -match 'dynamic') { return 'dynamic' }
	return $n
}

# One column: a centred header with a count, then the email-search-style scrollable list.
function New-MembershipColumn([int]$GridCol, [string]$Head, $Items) {
	$items = @($Items)
	$panel = New-Object System.Windows.Controls.StackPanel
	[System.Windows.Controls.Grid]::SetColumn($panel, $GridCol)
	$panel.Margin = '0,0,10,0'

	$h = New-Object System.Windows.Controls.TextBlock
	$h.Text = "$Head ($($items.Count))"
	$h.FontWeight = 'SemiBold'; $h.FontSize = 11; $h.TextWrapping = 'Wrap'; $h.TextAlignment = 'Center'; $h.Margin = '0,0,0,5'
	$h.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'TextBrush')
	[void]$panel.Children.Add($h)

	$border = Read-XamlString $script:MemColListXaml
	[void]$border.Resources.MergedDictionaries.Add($script:StyleDict)
	$list = $border.FindName('ColList')
	if (-not $items.Count) {
		$it = New-Object System.Windows.Controls.ListBoxItem
		$t = New-Object System.Windows.Controls.TextBlock; $t.Text = 'None'; $t.FontSize = 11
		$t.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'TextFaintBrush')
		$it.Content = $t; $it.IsHitTestVisible = $false
		[void]$list.Items.Add($it)
	} else {
		foreach ($x in $items) {
			$rn = "$($x.Name)"; $re = "$($x.Id)"
			if ($rn -eq $re) { $re = '' }   # a Send As row whose name is just its address: show it once
			$it = New-Object System.Windows.Controls.ListBoxItem
			$it.Content = New-RecipientRow $rn $re (Get-MembershipRowLabel $x)
			if ($x.Id) { $it.ToolTip = if ($rn -and $rn -ne "$($x.Id)") { "$rn  <$($x.Id)>" } else { "$($x.Id)" } }
			[void]$list.Items.Add($it)
		}
	}
	[void]$panel.Children.Add($border)
	return $panel
}

# Add a person's block (centred header + total, then the five columns) to $Container. Returns the total.
function Add-MembershipPersonCard($Container, [string]$Email, $Inv) {
	$cols = Get-MembershipReportColumns $Inv
	$total = 0; foreach ($c in $cols) { $total += @($c.Items).Count }

	$card = New-Object System.Windows.Controls.Border
	$card.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'Card')
	$card.Margin = '0,0,0,14'
	$outer = New-Object System.Windows.Controls.StackPanel

	$hn = New-Object System.Windows.Controls.TextBlock
	$hn.Text = $Email; $hn.FontWeight = 'SemiBold'; $hn.FontSize = 14; $hn.TextAlignment = 'Center'; $hn.TextWrapping = 'Wrap'
	$hn.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'TextBrush')
	[void]$outer.Children.Add($hn)
	$ht = New-Object System.Windows.Controls.TextBlock
	$ht.Text = "$total total"; $ht.FontSize = 12; $ht.TextAlignment = 'Center'; $ht.Margin = '0,2,0,0'
	$ht.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'AccentBrush')
	[void]$outer.Children.Add($ht)

	$cg = New-Object System.Windows.Controls.Grid
	$cg.Margin = '0,10,0,0'
	for ($i = 0; $i -lt $cols.Count; $i++) {
		$cd = New-Object System.Windows.Controls.ColumnDefinition
		$cd.Width = [System.Windows.GridLength]::new(1, 'Star')
		[void]$cg.ColumnDefinitions.Add($cd)
	}
	for ($i = 0; $i -lt $cols.Count; $i++) {
		[void]$cg.Children.Add((New-MembershipColumn $i $cols[$i].Head $cols[$i].Items))
	}
	[void]$outer.Children.Add($cg)

	$card.Child = $outer
	[void]$Container.Children.Add($card)
	return $total
}

# Plain-text block for one person, for the Copy button.
function Get-MembershipPersonText([string]$Email, $Inv) {
	$cols = Get-MembershipReportColumns $Inv
	$total = 0; foreach ($c in $cols) { $total += @($c.Items).Count }
	$lines = [System.Collections.Generic.List[string]]::new()
	$lines.Add("$Email - $total total")
	foreach ($c in $cols) {
		$items = @($c.Items)
		$lines.Add("  $($c.Head) ($($items.Count)):")
		if (-not $items.Count) { $lines.Add("    (none)") }
		else {
			foreach ($it in $items) {
				$line = "    - $($it.Name)"
				if ($it.Id -and $it.Id -ne $it.Name) { $line += " <$($it.Id)>" }
				$lbl = Get-MembershipRowLabel $it
				if ($lbl) { $line += " [$lbl]" }
				$lines.Add($line)
			}
		}
	}
	return ($lines -join "`r`n")
}

# A simple "paste a list of people" dialog. Returns the pasted text, or $null if cancelled.
function Show-MembershipPasteDialog {
	$script:MemPasteResult = $null
	$d = New-StyledDialog -Title 'Paste a list of people' -Icon '&#xED75;' -HelpKey '' -BodyXaml @'
<StackPanel Margin="16" Width="420">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<TextBlock Text="Paste email addresses - one per line, or separated by commas." Style="{DynamicResource Dim}" TextWrapping="Wrap"/>
			<TextBox x:Name="PasteBox" Height="210" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Margin="0,8,0,0"/>
			<StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
				<Button x:Name="PasteCancelBtn" Style="{DynamicResource BtnSecondary}" Content="Cancel" MinWidth="90"/>
				<Button x:Name="PasteOkBtn" Style="{DynamicResource BtnPrimary}" Content="Look up" MinWidth="120" Margin="8,0,0,0" IsDefault="True"/>
			</StackPanel>
		</StackPanel>
	</Border>
</StackPanel>
'@
	$box = $d.FindName('PasteBox')
	$d.FindName('PasteOkBtn').Add_Click({ $script:MemPasteResult = $box.Text; $d.Close() })
	$d.FindName('PasteCancelBtn').Add_Click({ $d.Close() })
	[void]$d.ShowDialog()
	return $script:MemPasteResult
}

function Get-UserMemberships {
	$dlg = New-UserMembershipsDialog
	$userBox    = $dlg.FindName('UserInput')
	$resultsHost = $dlg.FindName('ResultsHost')
	$status     = $dlg.FindName('ResultStatus')
	$totalText  = $dlg.FindName('TotalText')
	$copyBtn    = $dlg.FindName('CopyBtn')
	Enable-RecipientAutocomplete $userBox 'User'
	Set-FieldWatermark $userBox 'Start typing a name or email'
	$script:UmCopyText = ''

	function Invoke-MembershipLookup([string[]]$People) {
		$people = @($People | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
		if (-not $people.Count) { Show-Notice 'No one to look up' 'Enter or paste at least one email address.' 'Warn'; return }
		if (-not (Test-SignedIn)) { Show-Notice 'Not connected' 'Connect to the tenant first (top bar).' 'Warn'; return }

		$resultsHost.Children.Clear()
		$copyBtn.IsEnabled = $false
		$totalText.Text = ''
		$progressBar1.Value = 12
		Reset-Throughput
		$opts = @{ Dl = $true; Unified = $true; Security = $true; SendAs = $true; FullAccess = $false; IncludeUnmanaged = $true }

		$blocks = [System.Collections.Generic.List[string]]::new()
		$grand = 0; $n = 0; $tc = $people.Count; $skipped = 0
		foreach ($email in $people) {
			$n++
			$tp = Get-ThroughputText ($n - 1) $tc
			$tail = if ($tp) { "  ($tp)" } else { '...' }
			$status.Text = "Looking up $n of $tc`: $email$tail"
			Set-LoopProgress $n $tc 12 95
			$inv = $null
			try { $inv = Get-UserAccessInventory $email $opts $null }
			catch {
				Write-Host "Couldn't look up $email`: $($_.Exception.Message)" -ForegroundColor Yellow
				$inv = [ordered]@{ Full = @(); SendAs = @(); Dl = @(); Unified = @(); Security = @(); Skipped = @("lookup failed: $($_.Exception.Message)") }
			}
			$grand += (Add-MembershipPersonCard $resultsHost $email $inv)
			$skipped += @($inv.Skipped).Count
			$blocks.Add((Get-MembershipPersonText $email $inv))
			Write-Host "Looked up $email." -ForegroundColor Cyan
		}

		$progressBar1.Value = 100
		$header = "Group memberships & access`r`nGenerated $(Get-Date -Format 'dddd, MMMM d, yyyy h:mm tt')"
		$script:UmCopyText = $header + "`r`n`r`n" + ($blocks -join "`r`n`r`n")
		$copyBtn.IsEnabled = [bool]$blocks.Count
		$peopleWord = if ($tc -eq 1) { 'person' } else { 'people' }
		$totalText.Text = "$grand total across $tc $peopleWord"
		$status.Text = "Done - looked up $tc $peopleWord." + $(if ($skipped) { "  $skipped item(s) not shown (no address / unreadable)." } else { '' })
		$progressBar1.Value = 0
	}

	function OnMembershipsLookupOne { Invoke-MembershipLookup @($userBox.Text -split '[\s;,]+') }
	function OnMembershipsPaste {
		$txt = Show-MembershipPasteDialog
		if ($null -eq $txt) { return }
		Invoke-MembershipLookup @($txt -split '[\s;,]+')
	}
	function OnMembershipsCopy {
		if (-not $script:UmCopyText) { return }
		try { [System.Windows.Clipboard]::SetText($script:UmCopyText); $status.Text = 'Copied to the clipboard - paste it into your email.' }
		catch { Show-Notice 'Copy failed' "Couldn't copy to the clipboard: $($_.Exception.Message)" 'Warn' }
	}

	$dlg.FindName('LookupBtn').Add_Click({ OnMembershipsLookupOne })
	$dlg.FindName('PasteBtn').Add_Click({ OnMembershipsPaste })
	$dlg.FindName('CopyBtn').Add_Click({ OnMembershipsCopy })
	[void]$dlg.ShowDialog()
}
