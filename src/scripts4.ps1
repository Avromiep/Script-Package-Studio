# ============================ Get-UserMemberships ====================================
# Read-only report of what a person belongs to and can act as: their cloud group
# memberships (security groups, Teams / Microsoft 365 groups, distribution lists) plus the
# mailboxes they can Send As - laid out side by side, one column per type with a count, per
# person, with a grand total and a Copy button that produces a tidy plain-text list for email.
#
# Deliberately FAST: it reuses Get-UserAccessInventory with Mailbox/Full-Access OFF, so there
# is NO slow per-mailbox Full Access scan - just one Graph group lookup + one Send As reverse
# lookup per person. Groups are cloud only (Graph); dynamic and on-prem-synced groups are
# included (tagged) because they're still real memberships.

function New-UserMembershipsDialog {
	New-StyledDialog -Title 'Get-UserMemberships' -Icon '&#xED75;' -BodyXaml @'
<StackPanel Margin="16" Width="820">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<TextBlock Text="People" Style="{DynamicResource Dim}"/>
			<TextBox x:Name="UsersInput" Height="54" AcceptsReturn="True" TextWrapping="Wrap"
					 VerticalScrollBarVisibility="Auto" Margin="0,6,0,0"/>
			<StackPanel Orientation="Horizontal" Margin="0,10,0,0">
				<Button x:Name="LookupBtn" Style="{DynamicResource BtnPrimary}" Content="Look up" MinWidth="110"/>
				<Button x:Name="CopyBtn" Style="{DynamicResource BtnSecondary}" Content="Copy" MinWidth="90" Margin="8,0,0,0" IsEnabled="False"/>
				<TextBlock x:Name="TotalText" Style="{DynamicResource Dim}" VerticalAlignment="Center" Margin="12,0,0,0"/>
			</StackPanel>
			<TextBlock x:Name="ResultStatus" Style="{DynamicResource Small}" Margin="0,8,0,0" TextWrapping="Wrap"/>
		</StackPanel>
	</Border>
	<ScrollViewer MaxHeight="470" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,12,0,0">
		<StackPanel x:Name="ResultsHost"/>
	</ScrollViewer>
</StackPanel>
'@
}

# The five columns a person's access is split into, in display order. $Inv is a
# Get-UserAccessInventory result; Send As is split into shared vs user mailboxes.
function Get-MembershipColumns($Inv) {
	$saShared = @($Inv.SendAs | Where-Object { -not $_.Personal })
	$saUser   = @($Inv.SendAs | Where-Object { $_.Personal })
	@(
		@{ Head = 'Security groups';              Items = @($Inv.Security) }
		@{ Head = 'Teams / Microsoft 365 groups'; Items = @($Inv.Unified) }
		@{ Head = 'Distribution lists';           Items = @($Inv.Dl) }
		@{ Head = 'Shared mailboxes (Send As)';   Items = $saShared }
		@{ Head = 'User mailboxes (Send As)';     Items = $saUser }
	)
}

# Build one column (header with count + a scrollable list of items) for a person card.
function New-MembershipColumn([int]$GridCol, [string]$Head, $Items) {
	$items = @($Items)
	$panel = New-Object System.Windows.Controls.StackPanel
	[System.Windows.Controls.Grid]::SetColumn($panel, $GridCol)
	$panel.Margin = '0,0,10,0'

	$h = New-Object System.Windows.Controls.TextBlock
	$h.Text = "$Head ($($items.Count))"
	$h.FontWeight = 'SemiBold'; $h.FontSize = 11; $h.TextWrapping = 'Wrap'; $h.Margin = '0,0,0,4'
	$h.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'TextBrush')
	[void]$panel.Children.Add($h)

	$sv = New-Object System.Windows.Controls.ScrollViewer
	$sv.MaxHeight = 220; $sv.VerticalScrollBarVisibility = 'Auto'; $sv.HorizontalScrollBarVisibility = 'Disabled'
	$inner = New-Object System.Windows.Controls.StackPanel
	if (-not $items.Count) {
		$e = New-Object System.Windows.Controls.TextBlock
		$e.Text = 'None'; $e.FontSize = 11
		$e.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'TextFaintBrush')
		[void]$inner.Children.Add($e)
	} else {
		foreach ($it in $items) {
			$t = New-Object System.Windows.Controls.TextBlock
			$disp = "$([char]0x2022) $($it.Name)"
			if ($it.Note) { $disp += "  ($($it.Note))" }
			$t.Text = $disp
			$t.FontSize = 11; $t.TextWrapping = 'Wrap'; $t.Margin = '0,1,0,1'
			$t.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'TextDimBrush')
			if ($it.Id -and $it.Id -ne $it.Name) { $t.ToolTip = "$($it.Name)  <$($it.Id)>" }
			[void]$inner.Children.Add($t)
		}
	}
	$sv.Content = $inner
	[void]$panel.Children.Add($sv)
	return $panel
}

# Add a person's card (header + total + the five columns) to $Container. Returns the person's total.
function Add-MembershipPersonCard($Container, [string]$Email, $Inv) {
	$cols = Get-MembershipColumns $Inv
	$total = 0; foreach ($c in $cols) { $total += @($c.Items).Count }

	$card = New-Object System.Windows.Controls.Border
	$card.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'Card')
	$card.Margin = '0,0,0,12'
	$outer = New-Object System.Windows.Controls.StackPanel

	$hg = New-Object System.Windows.Controls.Grid
	foreach ($w in @('*', 'Auto')) {
		$cd = New-Object System.Windows.Controls.ColumnDefinition
		$cd.Width = if ($w -eq '*') { [System.Windows.GridLength]::new(1, 'Star') } else { [System.Windows.GridLength]::Auto }
		[void]$hg.ColumnDefinitions.Add($cd)
	}
	$hn = New-Object System.Windows.Controls.TextBlock
	$hn.Text = $Email; $hn.FontWeight = 'SemiBold'; $hn.FontSize = 13; $hn.TextWrapping = 'Wrap'
	$hn.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'TextBrush')
	$ht = New-Object System.Windows.Controls.TextBlock
	$ht.Text = "$total total"; $ht.VerticalAlignment = 'Center'; $ht.FontSize = 12; $ht.Margin = '10,0,0,0'
	[System.Windows.Controls.Grid]::SetColumn($ht, 1)
	$ht.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'AccentBrush')
	[void]$hg.Children.Add($hn); [void]$hg.Children.Add($ht)
	[void]$outer.Children.Add($hg)

	$cg = New-Object System.Windows.Controls.Grid
	$cg.Margin = '0,8,0,0'
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

# Plain-text block for one person, for the Copy button (nice to paste into an email).
function Get-MembershipPersonText([string]$Email, $Inv) {
	$cols = Get-MembershipColumns $Inv
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
				if ($it.Note) { $line += " [$($it.Note)]" }
				$lines.Add($line)
			}
		}
	}
	return ($lines -join "`r`n")
}

function Get-UserMemberships {
	$dlg = New-UserMembershipsDialog
	$usersBox   = $dlg.FindName('UsersInput')
	$resultsHost = $dlg.FindName('ResultsHost')
	$status     = $dlg.FindName('ResultStatus')
	$totalText  = $dlg.FindName('TotalText')
	$copyBtn    = $dlg.FindName('CopyBtn')
	Set-FieldWatermark $usersBox 'One or more email addresses (comma, semicolon or new line separated)'
	$script:UmCopyText = ''

	function OnMembershipsLookup {
		if (-not (Test-SignedIn)) { Show-Notice 'Not connected' 'Connect to the tenant first (top bar).' 'Warn'; return }
		$people = @($usersBox.Text -split '[\s;,]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
		if (-not $people.Count) { Show-Notice 'No one to look up' 'Enter at least one email address.' 'Warn'; return }

		$resultsHost.Children.Clear()
		$copyBtn.IsEnabled = $false
		$totalText.Text = ''
		$progressBar1.Value = 12
		$script:TpStart = $null; $script:TpCount = 0
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

	function OnMembershipsCopy {
		if (-not $script:UmCopyText) { return }
		try { [System.Windows.Clipboard]::SetText($script:UmCopyText); $status.Text = 'Copied to the clipboard - paste it into your email.' }
		catch { Show-Notice 'Copy failed' "Couldn't copy to the clipboard: $($_.Exception.Message)" 'Warn' }
	}

	$dlg.FindName('LookupBtn').Add_Click({ OnMembershipsLookup })
	$dlg.FindName('CopyBtn').Add_Click({ OnMembershipsCopy })
	[void]$dlg.ShowDialog()
}
