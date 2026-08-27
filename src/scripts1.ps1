# Script-Package - script dialogs (Add-*)
# Every function keeps its original logic and cmdlet calls; only the UI layer
# changed from WinForms to WPF windows styled by the merged design dictionary.

# Classify a recipient so the member scripts can catch "wrong script for this target"
# mistakes (e.g. running Add-MailboxMember against a distribution list).
# Returns 'Mailbox' | 'DistributionList' | 'UnifiedGroup' | 'Other', or $null if the
# recipient can't be looked up. $script:LastRecipientRaw holds the raw type string for
# diagnostics/logging.
function Get-RecipientCategory([string]$Identity) {
	$script:LastRecipientRaw = ''
	if (-not $Identity) { return $null }
	$r = $null
	try { $r = Get-Recipient -Identity $Identity -ErrorAction Stop | Select-Object -First 1 } catch { return $null }
	if (-not $r) { return $null }
	$d = "$($r.RecipientTypeDetails) $($r.RecipientType)"
	$script:LastRecipientRaw = $d.Trim()
	if ($d -match 'GroupMailbox') { return 'UnifiedGroup' }                                       # Microsoft 365 / Teams group
	if ($d -match 'Distribution|MailUniversal|MailNonUniversal|RoomList') { return 'DistributionList' }
	if ($d -match 'Mailbox') { return 'Mailbox' }                                                 # User/Shared/Room/etc.
	return 'Other'
}

# Friendly, specific type name from a raw "RecipientTypeDetails RecipientType" string
# (e.g. 'SharedMailbox UserMailbox' -> 'shared mailbox') so the summary can say exactly
# what each target was. Pass $script:LastRecipientRaw captured right after Get-RecipientCategory.
function Get-RecipientTypeName([string]$Raw) {
	switch -Regex ($Raw) {
		'SharedMailbox'                 { return 'shared mailbox' }
		'RoomMailbox'                   { return 'room mailbox' }
		'EquipmentMailbox'              { return 'equipment mailbox' }
		'GroupMailbox'                  { return 'Teams / Microsoft 365 group' }
		'DynamicDistribution'           { return 'dynamic distribution list' }
		'MailUniversalSecurityGroup'    { return 'mail-enabled security group' }
		'MailUniversalDistributionGroup|MailNonUniversalGroup|DistributionGroup' { return 'distribution list' }
		'UserMailbox'                   { return "user's mailbox" }
		default                         { return 'recipient' }
	}
}

# True if an add/remove error just means "nothing to do" (already a member on add, or
# not a member on remove) rather than a real failure - used to summarize bulk runs.
function Test-HarmlessMemberError([string]$Message) {
	return ($Message -match "already a member|already exists|already has|is already|AlreadyExists|already present|isn't a member|is not a member|not a member|no matching|couldn't be found|not found")
}

# Show ONE summary popup after a bulk add/remove (instead of a popup per row). $Counts has
# done/noop/failed/skipped; $Action is 'add' or 'remove' for the wording.
function Show-BulkSummary([hashtable]$Counts, [string]$Action, $Corrected = $null) {
	$doneWord = if ($Action -eq 'remove') { 'removed' } else { 'added' }
	$noopWord = if ($Action -eq 'remove') { "weren't members" } else { 'already there' }
	$parts = @()
	if ($Counts.done -gt 0)    { $parts += "$($Counts.done) $doneWord" }
	if ($Counts.noop -gt 0)    { $parts += "$($Counts.noop) $noopWord" }
	if ($Counts.skipped -gt 0) { $parts += "$($Counts.skipped) skipped (couldn't look up)" }
	if ($Counts.failed -gt 0)  { $parts += "$($Counts.failed) failed" }
	$summary = if ($parts.Count) { $parts -join ', ' } else { 'nothing to do' }
	Write-Host "Bulk result: $summary." -ForegroundColor Cyan
	# Note any targets that were auto-routed to a different type than the script is named for.
	$note = ''
	$corr = @($Corrected)
	if ($corr.Count) {
		$note = "`n`nNote - some targets were a different type than this script, and were handled as their real type:`n" + (($corr | ForEach-Object { "  - $_" }) -join "`n")
	}
	$kind  = if ($Counts.failed -gt 0) { 'Warn' } else { 'Info' }
	$title = if ($Action -eq 'remove') { 'Bulk remove complete' } else { 'Bulk add complete' }
	Show-Notice $title "Finished processing the list:`n`n$summary.$note" $kind
	$progressBar1.Value = 0
}

# Add or remove ONE member on ONE target, auto-routing by the target's REAL type instead of
# assuming the script's own type. So 'Add distribution list member' still works when the
# address is really a shared mailbox (grants access) or a Teams group (adds as member), etc.
# Returns @{ Category; TypeName; Status ('done'|'noop'|'failed'|'unknown'); Message }.
# Shows no UI - the caller decides how to report. $MailboxRight picks what to do when the
# target turns out to be a mailbox: 'FullAndSendAs' (default) | 'FullAccess' | 'SendAs' |
# 'SendOnBehalf'. $FallbackCategory is used when the target can't be classified (e.g. lookup
# failed) so we still try the script's native cmdlet and surface its real error. Pass a shared
# [hashtable]$Cache across a bulk run to avoid re-querying the same target.
function Invoke-MemberRoute {
	param(
		[string]$Target,
		[string]$Member,
		[string]$Action = 'add',
		[string]$MailboxRight = 'FullAndSendAs',
		[string]$FallbackCategory = '',
		[hashtable]$Cache = $null
	)
	$isRemove = ($Action -eq 'remove')
	if ($Cache -and $Cache.ContainsKey($Target)) {
		$cat = $Cache[$Target].Cat; $typeName = $Cache[$Target].Name
	} else {
		$cat = Get-RecipientCategory $Target
		$typeName = Get-RecipientTypeName $script:LastRecipientRaw
		if ($Cache) { $Cache[$Target] = @{ Cat = $cat; Name = $typeName } }
	}
	$res = @{ Category = $cat; TypeName = $typeName; Status = 'unknown'; Message = '' }
	$effCat = if ($cat -and $cat -ne 'Other') { $cat } elseif ($FallbackCategory) { $FallbackCategory } else { '' }
	if (-not $effCat) { return $res }
	try {
		if ($isRemove) {
			switch ($effCat) {
				'DistributionList' { Remove-DistributionGroupMember -Identity $Target -Member $Member -Confirm:$false -ErrorAction Stop }
				'UnifiedGroup'     { Remove-UnifiedGroupLinks -Identity $Target -LinkType Members -Links $Member -Confirm:$false -ErrorAction Stop }
				'Mailbox' {
					switch ($MailboxRight) {
						'SendAs'       { Remove-RecipientPermission -Identity $Target -Trustee $Member -AccessRights SendAs -Confirm:$false -ErrorAction Stop }
						'SendOnBehalf' { Set-Mailbox -Identity $Target -GrantSendOnBehalfTo @{Remove=$Member} -ErrorAction Stop }
						'FullAccess'   { Remove-MailboxPermission -Identity $Target -User $Member -AccessRights FullAccess -InheritanceType All -Confirm:$false -ErrorAction Stop }
						default {
							Remove-MailboxPermission -Identity $Target -User $Member -AccessRights FullAccess -InheritanceType All -Confirm:$false -ErrorAction Stop
							Remove-RecipientPermission -Identity $Target -Trustee $Member -AccessRights SendAs -Confirm:$false -ErrorAction Stop
						}
					}
				}
			}
		} else {
			switch ($effCat) {
				'DistributionList' { Add-DistributionGroupMember -Identity $Target -Member $Member -ErrorAction Stop }
				'UnifiedGroup'     { Add-UnifiedGroupLinks -Identity $Target -LinkType Members -Links $Member -ErrorAction Stop }
				'Mailbox' {
					switch ($MailboxRight) {
						'SendAs'       { Add-RecipientPermission -Identity $Target -Trustee $Member -AccessRights SendAs -Confirm:$false -ErrorAction Stop }
						'SendOnBehalf' { Set-Mailbox -Identity $Target -GrantSendOnBehalfTo @{Add=$Member} -ErrorAction Stop }
						'FullAccess'   { Add-MailboxPermission -Identity $Target -User $Member -AccessRights FullAccess -InheritanceType All -AutoMapping $true -ErrorAction Stop }
						default {
							Add-MailboxPermission -Identity $Target -User $Member -AccessRights FullAccess -InheritanceType All -AutoMapping $true -ErrorAction Stop
							Add-RecipientPermission -Identity $Target -Trustee $Member -AccessRights SendAs -Confirm:$false -ErrorAction Stop
						}
					}
				}
			}
		}
		$res.Status = 'done'
	} catch {
		$msg = "$($_.Exception.Message)".Trim()
		$res.Message = $msg
		$res.Status = if (Test-HarmlessMemberError $msg) { 'noop' } else { 'failed' }
	}
	return $res
}

# What each detected type is "called" for the after-the-fact note.
$script:MemberTypeArticle = @{ Mailbox = 'a mailbox'; DistributionList = 'a distribution list'; UnifiedGroup = 'a Teams / Microsoft 365 group' }

# Run one single-target add/remove through Invoke-MemberRoute and report the outcome with a
# popup - INCLUDING a friendly note when the target turned out to be a different type than the
# script is named for (e.g. "that address is actually a distribution list, but Jane was added
# to it anyway"). No confirmation gate: it just does the right thing, then tells you. $Expected
# is the category this script is for (used only for the note + as the fallback cmdlet).
function Invoke-SingleMemberChange {
	param([string]$Target, [string]$Member, [string]$Expected, [string]$Action = 'add', [string]$MailboxRight = 'FullAndSendAs')
	$isRemove = ($Action -eq 'remove')
	$verbPast = if ($isRemove) { 'removed from' } else { 'added to' }
	if (-not $Target -or -not $Member) {
		Show-Notice 'Missing info' "Enter both a member and a target first." 'Warn'; $progressBar1.Value = 0; return
	}
	$progressBar1.Value = 40
	$r = Invoke-MemberRoute -Target $Target -Member $Member -Action $Action -MailboxRight $MailboxRight -FallbackCategory $Expected
	$typeName = $r.TypeName
	$mismatch = ($r.Category -and $r.Category -ne 'Other' -and $r.Category -ne $Expected)
	$expArticle = $script:MemberTypeArticle[$Expected]
	switch ($r.Status) {
		'unknown' {
			Write-Host "Couldn't determine the type of '$Target'." -ForegroundColor Red
			Show-Notice 'Not found' "Couldn't find `"$Target`" or work out its type (mailbox, distribution list, or Teams / Microsoft 365 group).`n`nCheck the address and that you're connected to the right tenant." 'Error'
		}
		'done' {
			Write-Host "$Member $verbPast $Target ($typeName)." -ForegroundColor Cyan
			$progressBar1.Value = 80
			$note = if ($mismatch) { "`n`nNote: `"$Target`" is actually $typeName, not $expArticle - but $Member was still $verbPast it." } else { '' }
			Show-Notice $(if ($isRemove) { 'Removed' } else { 'Added' }) "$Member was $verbPast `"$Target`" ($typeName).$note" 'Info'
			OperationComplete
		}
		'noop' {
			$noopMsg = if ($isRemove) { "$Member wasn't on `"$Target`" ($typeName) - nothing to remove." } else { "$Member is already on `"$Target`" ($typeName)." }
			Write-Host $noopMsg -ForegroundColor Yellow
			$note = if ($mismatch) { "`n`n(Heads up: `"$Target`" is actually $typeName, not $expArticle.)" } else { '' }
			Show-Notice 'Nothing to do' "$noopMsg$note" 'Info'
		}
		'failed' {
			$vb = if ($isRemove) { 'remove' } else { 'add' }
			$pp = if ($isRemove) { 'from' } else { 'to' }
			Write-Host "Couldn't $vb $Member $pp '$Target': $($r.Message)" -ForegroundColor Red
			Show-Notice "$(if ($isRemove) { 'Remove' } else { 'Add' }) failed" "Couldn't $vb $Member $pp `"$Target`":`n`n$($r.Message)" 'Error'
		}
	}
	$progressBar1.Value = 0
}

# Bulk (CSV) auto-route for one row. Uses the shared $Cache + $Notes list so the end summary
# can mention any targets whose real type differed. Returns 'done'|'noop'|'failed'|'unknown'.
function Invoke-BulkMemberRow {
	param([string]$Target, [string]$Member, [string]$Expected, [string]$Action, [hashtable]$Cache, [System.Collections.Generic.HashSet[string]]$Corrected, [string]$MailboxRight = 'FullAndSendAs')
	$r = Invoke-MemberRoute -Target $Target -Member $Member -Action $Action -MailboxRight $MailboxRight -FallbackCategory $Expected -Cache $Cache
	if ($r.Category -and $r.Category -ne 'Other' -and $r.Category -ne $Expected -and $Corrected) {
		[void]$Corrected.Add("$Target is $($r.TypeName)")
	}
	$verbPast = if ($Action -eq 'remove') { 'removed from' } else { 'added to' }
	switch ($r.Status) {
		'done'    { Write-Host "$Member $verbPast $Target ($($r.TypeName))." }
		'noop'    { Write-Host "${Member}: nothing to do on '$Target' ($($r.TypeName))." -ForegroundColor Yellow }
		'failed'  { Write-Host "Couldn't process $Member on '$Target': $($r.Message)" -ForegroundColor Red }
		'unknown' { Write-Host "Skipped $Member on '$Target' - couldn't determine its type." -ForegroundColor Yellow }
	}
	return $r.Status
}

# Pull unique email addresses out of arbitrary pasted text (case-insensitive de-dupe,
# original order kept). Same idea as a standalone email-extractor utility.
function Get-EmailsFromText([string]$Text) {
	if (-not $Text) { return @() }
	$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	$out  = [System.Collections.Generic.List[string]]::new()
	foreach ($m in ([regex]'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}').Matches($Text)) {
		if ($seen.Add($m.Value)) { $out.Add($m.Value) }
	}
	return $out.ToArray()
}

# --- External-address handling ------------------------------------------------------------
# When a pasted address isn't in one of the tenant's accepted domains it can't be added to a
# group/mailbox as-is. We offer to bring it in first: distribution lists take a MAIL CONTACT,
# Teams / Microsoft 365 groups take a GUEST invite, shared mailboxes can't take an external at
# all. These helpers do the lookups/provisioning and are called from the paste "Add All" flow.

# Tenant's accepted domains (lowercased HashSet), or $null if the lookup fails (then we skip
# the whole external check and just let the normal cmdlets run + surface their own errors).
function Get-AcceptedDomainList {
	try {
		$set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
		foreach ($d in (Get-AcceptedDomain -ErrorAction Stop)) { [void]$set.Add(("$($d.DomainName)").Trim()) }
		if ($set.Count -eq 0) { return $null }
		return $set
	} catch { return $null }
}

# Is $Email outside every accepted domain? $Accepted is the HashSet from Get-AcceptedDomainList.
function Test-IsExternalAddress([string]$Email, $Accepted) {
	if (-not $Accepted) { return $false }
	$at = $Email.LastIndexOf('@')
	if ($at -lt 0) { return $false }
	$dom = $Email.Substring($at + 1).Trim()
	return (-not $Accepted.Contains($dom))
}

# Ensure a mail contact exists for an external address; returns the identity to use as a DL
# member (the existing recipient if one already resolves, else a freshly created contact).
# Throws on failure so the caller can record it.
function Resolve-OrCreateMailContact([string]$Email) {
	$existing = $null
	try { $existing = Get-Recipient -Identity $Email -ErrorAction Stop | Select-Object -First 1 } catch { $existing = $null }
	if ($existing) { return $Email }
	# Name must be unique in the OU; the address itself is a safe, unique choice.
	New-MailContact -Name $Email -ExternalEmailAddress $Email -ErrorAction Stop | Out-Null
	return $Email
}

# Ensure the external address exists as a guest user; returns its AAD object id. Reuses an
# existing guest if one is already present, otherwise sends an invitation. Throws on failure.
function Resolve-OrInviteGuest([string]$Email) {
	$u = $null
	try { $u = Get-MgUser -Filter "mail eq '$Email'" -ErrorAction Stop | Select-Object -First 1 } catch { $u = $null }
	if (-not $u) { try { $u = Get-MgUser -Filter "otherMails/any(x:x eq '$Email')" -ErrorAction Stop | Select-Object -First 1 } catch { $u = $null } }
	if ($u) { return $u.Id }
	$inv = New-MgInvitation -InvitedUserEmailAddress $Email -InviteRedirectUrl 'https://myapps.microsoft.com' -SendInvitationMessage:$true -ErrorAction Stop
	return $inv.InvitedUser.Id
}

# Add an already-resolved guest (AAD object id) to a Microsoft 365 / Teams group given by its
# SMTP address. Resolves the group's AAD id via Get-UnifiedGroup, then New-MgGroupMember.
function Add-GuestToUnifiedGroup([string]$GroupSmtp, [string]$GuestId) {
	$g = Get-UnifiedGroup -Identity $GroupSmtp -ErrorAction Stop
	$gid = $g.ExternalDirectoryObjectId
	if (-not $gid) { throw "Couldn't resolve the group's directory id for '$GroupSmtp'." }
	New-MgGroupMember -GroupId $gid -DirectoryObjectId $GuestId -ErrorAction Stop
}

# Universal paste-to-add/remove: paste people (top, live-extracted) + paste one or more
# targets (bottom) that can be ANY mix of distribution lists, shared mailboxes, or Teams /
# M365 groups. On Add/Remove All, each target's real type is detected (Get-RecipientCategory)
# and the right cmdlet is used per target. $Action = 'add' | 'remove'. The CSV path is kept.
function New-PasteMembersDialog {
	param([string]$TargetPrefill = '', [string]$Action = 'add')
	$isRemove = ($Action -eq 'remove')
	$verb     = if ($isRemove) { 'Remove' } else { 'Add' }
	$verbLow  = if ($isRemove) { 'remove' } else { 'add' }
	$prep     = if ($isRemove) { 'from' } else { 'to' }
	$topLabel = "Paste text with the people to $verbLow (emails are pulled out automatically):"
	$tgtLabel = "$verb them $prep these - distribution lists, shared mailboxes, or Teams / M365 groups, one per line:"
	$win = New-StyledDialog -Title "$verb members (paste)" -Icon '&#xED75;' -BodyXaml @"
<StackPanel Margin="16" Width="480">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<TextBlock Text="$topLabel" Style="{DynamicResource Dim}" TextWrapping="Wrap" Margin="0,0,0,4"/>
			<TextBox x:Name="PasteInput" Style="{DynamicResource TextArea}" Height="90" TextWrapping="Wrap" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"/>
			<Grid Margin="0,10,0,4">
				<TextBlock Text="Members - edit if needed:" Style="{DynamicResource Dim}" HorizontalAlignment="Left"/>
				<TextBlock x:Name="PasteCount" Style="{DynamicResource Small}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
			</Grid>
			<TextBox x:Name="PastePreview" Style="{DynamicResource TextArea}" Height="90" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"/>
			<Border Style="{DynamicResource Divider}"/>
			<TextBlock Text="$tgtLabel" Style="{DynamicResource Dim}" TextWrapping="Wrap" Margin="0,0,0,4"/>
			<TextBox x:Name="PasteTargets" Style="{DynamicResource TextArea}" Height="70" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"/>
			<Grid Margin="0,14,0,0">
				<Button x:Name="PasteCancelBtn" Style="{DynamicResource BtnGhost}" Content="Cancel" HorizontalAlignment="Left" MinWidth="90"/>
				<Button x:Name="PasteAddBtn" Style="{DynamicResource BtnPrimary}" Content="$verb All" HorizontalAlignment="Right" MinWidth="140"/>
			</Grid>
		</StackPanel>
	</Border>
</StackPanel>
"@
	$pasteBox   = $win.FindName('PasteInput')
	$previewBox = $win.FindName('PastePreview')
	$countText  = $win.FindName('PasteCount')
	$targetsBox = $win.FindName('PasteTargets'); $targetsBox.Text = $TargetPrefill
	$result = @{ Counts = $null; Lines = $null; AnyFailed = $false; TargetCount = 0; Action = $Action }
	$win.Tag = $result

	# Live: refill the members list from the top box whenever it changes (no button needed).
	$pasteBox.Add_TextChanged({
		$emails = @(Get-EmailsFromText $pasteBox.Text)
		$previewBox.Text = ($emails -join "`r`n")
		$countText.Text = "$($emails.Count) unique"
	}.GetNewClosure())

	$win.FindName('PasteCancelBtn').Add_Click({ $win.Close() }.GetNewClosure())

	$win.FindName('PasteAddBtn').Add_Click({
		$members = @(Get-EmailsFromText $previewBox.Text)
		# targets: one per line; use the email in the line if present, else the whole line
		$targets = @()
		foreach ($line in ($targetsBox.Text -split "\r?\n")) {
			$line = $line.Trim(); if (-not $line) { continue }
			$em = @(Get-EmailsFromText $line)
			$targets += if ($em.Count) { $em[0] } else { $line }
		}
		$targets = @($targets | Select-Object -Unique)
		if ($members.Count -eq 0) { Show-Notice 'Nothing to do' "No people to $verbLow - paste some text with email addresses at the top." 'Warn'; return }
		if ($targets.Count -eq 0) { Show-Notice 'Nothing to do' 'Add at least one target (distribution list, shared mailbox, or Teams / M365 group) at the bottom.' 'Warn'; return }
		$counts = @{ done = 0; noop = 0; failed = 0; skipped = 0 }
		$lines = [System.Collections.Generic.List[string]]::new()
		$anyFailed = $false
		$doneWord = if ($isRemove) { 'removed' } else { 'added' }
		$noopWord = if ($isRemove) { "weren't members" } else { 'already there' }
			# External (non-tenant-domain) addresses: offer once to bring them in first, so a
			# batch doesn't need a separate contact/guest step. Add only. 'bring-in' | 'skip'.
			$externalMode = 'skip'
			$externalSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
			if (-not $isRemove) {
				$accepted = Get-AcceptedDomainList
				$ext = @($members | Where-Object { Test-IsExternalAddress $_ $accepted })
				foreach ($e in $ext) { [void]$externalSet.Add($e) }
				if ($ext.Count -gt 0) {
					$plural = if ($ext.Count -ne 1) { 'es' } else { '' }
					$shown = if ($ext.Count -gt 15) { (@($ext | Select-Object -First 15) -join "`n  ") + "`n  ...and $($ext.Count - 15) more" } else { $ext -join "`n  " }
					$msg = "$($ext.Count) address$plural aren't in your tenant's domains:`n`n  $shown`n`nBring them in so they can be added? Distribution lists get a mail contact; Teams / Microsoft 365 groups get a guest invite; shared mailboxes can't take external addresses, so those are skipped.`n`nYes = bring them in & add.  No = skip the external ones."
					if (Confirm-YesNo 'External addresses found' $msg '&#xEA88;') { $externalMode = 'bring-in' }
				}
			}
		$progressBar1.Value = 10
		foreach ($target in $targets) {
			$cat = Get-RecipientCategory $target
			$typeName = Get-RecipientTypeName $script:LastRecipientRaw
			if (-not $cat -or $cat -eq 'Other') {
				Write-Host "Skipping '$target' - couldn't determine its type (not a mailbox / list / group)." -ForegroundColor Yellow
				$lines.Add("$target - skipped (not a mailbox, list, or group)")
				continue
			}
			$skipM  = [System.Collections.Generic.List[string]]::new()
			$addedM = [System.Collections.Generic.List[string]]::new()
			$noopM  = [System.Collections.Generic.List[string]]::new()
			$failM  = [System.Collections.Generic.List[string]]::new()
			foreach ($m in $members) {
				try {
					if ($isRemove) {
						switch ($cat) {
							'DistributionList' { Remove-DistributionGroupMember -Identity $target -Member $m -Confirm:$false -ErrorAction Stop }
							'UnifiedGroup'     { Remove-UnifiedGroupLinks -Identity $target -LinkType Members -Links $m -Confirm:$false -ErrorAction Stop }
							'Mailbox'          {
								Remove-MailboxPermission -Identity $target -User $m -AccessRights FullAccess -InheritanceType All -Confirm:$false -ErrorAction Stop
								Remove-RecipientPermission -Identity $target -Trustee $m -AccessRights SendAs -Confirm:$false -ErrorAction Stop
							}
						}
					} else {
						switch ($cat) {
							'DistributionList' { $mm = $m; if ($externalSet.Contains($m)) { if ($externalMode -ne 'bring-in') { throw 'SP_SKIP' }; $mm = Resolve-OrCreateMailContact $m }; Add-DistributionGroupMember -Identity $target -Member $mm -ErrorAction Stop }
							'UnifiedGroup'     { if ($externalSet.Contains($m)) { if ($externalMode -ne 'bring-in') { throw 'SP_SKIP' }; $gid = Resolve-OrInviteGuest $m; Add-GuestToUnifiedGroup $target $gid } else { Add-UnifiedGroupLinks -Identity $target -LinkType Members -Links $m -ErrorAction Stop } }
							'Mailbox'          {
								if ($externalSet.Contains($m)) { throw 'SP_SKIP_MB' }
								Add-MailboxPermission -Identity $target -User $m -AccessRights FullAccess -InheritanceType All -AutoMapping $true -ErrorAction Stop
								Add-RecipientPermission -Identity $target -Trustee $m -AccessRights SendAs -Confirm:$false -ErrorAction Stop
							}
						}
					}
					Write-Host "$m $(if ($isRemove) { 'removed from' } else { 'added to' }) $target ($typeName)"
					$counts.done++; $addedM.Add($m)
				} catch {
					$msg = "$($_.Exception.Message)".Trim()
					if ($msg -eq 'SP_SKIP') { Write-Host "${m}: external, skipped on '$target'." -ForegroundColor Yellow; $skipM.Add("$m (external - skipped)"); $counts.skipped++ }
						elseif ($msg -eq 'SP_SKIP_MB') { Write-Host "${m}: external, can't get mailbox access on '$target'." -ForegroundColor Yellow; $skipM.Add("$m (external - no mailbox access)"); $counts.skipped++ }
						elseif (Test-HarmlessMemberError $msg) { Write-Host "${m}: nothing to do on '$target'." -ForegroundColor Yellow; $counts.noop++; $noopM.Add($m) }
					else { Write-Host "Failed: $m on '$target': $msg" -ForegroundColor Red; $counts.failed++; $anyFailed = $true; $failM.Add($m) }
				}
			}
			# Name the actual addresses under each target (not just counts) so it's clear WHAT
			# was added/removed where. Indented one level under the target header.
			$detail = @()
			if ($addedM.Count) { $detail += "  $doneWord ($($addedM.Count)): $($addedM -join ', ')" }
			if ($noopM.Count)  { $detail += "  $noopWord ($($noopM.Count)): $($noopM -join ', ')" }
			if ($skipM.Count)  { $detail += "  skipped ($($skipM.Count)): $($skipM -join ', ')" }
				if ($failM.Count)  { $detail += "  failed ($($failM.Count)): $($failM -join ', ')" }
			$lineText = if ($detail.Count) { "$target ($typeName):`n" + ($detail -join "`n") } else { "$target ($typeName): nothing to do" }
			$lines.Add($lineText)
			Write-Host $lineText -ForegroundColor Cyan
		}
		$result.Counts = $counts; $result.Lines = $lines; $result.AnyFailed = $anyFailed; $result.TargetCount = $targets.Count
		$win.Close()
	}.GetNewClosure())

	return $win
}
function Show-PasteMembersDialog {
	param([string]$TargetPrefill = '', [string]$Action = 'add')
	$win = New-PasteMembersDialog -TargetPrefill $TargetPrefill -Action $Action
	[void]$win.ShowDialog()
	$r = $win.Tag
	if ($r -and $r.Lines) {
		# One line per target, naming its actual type (shared mailbox / distribution list /
		# Teams group) so it's clear what was added to / removed from where.
		$body = $r.Lines -join "`n"
		$kind = if ($r.AnyFailed) { 'Warn' } else { 'Info' }
		$title = if ($Action -eq 'remove') { 'Remove complete' } else { 'Add complete' }
		Show-Notice $title $body $kind
		$progressBar1.Value = 0
	}
}

# Shared shape used by Add/Remove DistributionListMember and UnifiedGroupMember
function New-MemberGroupDialog {
	param([string]$Title, [string]$ActionText, [string]$BulkText, [string]$Icon = '&#xED75;', [switch]$WithPaste)
	$pasteBtn = if ($WithPaste) { '<Button x:Name="PasteBtn" Style="{DynamicResource BtnSecondary}" Content="Paste List..." Margin="0,8,0,0"/>' } else { '' }
	New-StyledDialog -Title $Title -Icon $Icon -BodyXaml @"
<StackPanel Margin="16" Width="340">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<TextBlock Text="Single" Style="{DynamicResource H3}"/>
			<Grid Margin="0,12,0,0">
				<Grid.ColumnDefinitions>
					<ColumnDefinition Width="70"/><ColumnDefinition Width="*"/>
				</Grid.ColumnDefinitions>
				<Grid.RowDefinitions>
					<RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
				</Grid.RowDefinitions>
				<TextBlock Text="Member" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
				<TextBox x:Name="MemberInput" Grid.Column="1"/>
				<TextBlock Text="Group" Style="{DynamicResource Dim}" Grid.Row="1" VerticalAlignment="Center" Margin="0,8,0,0"/>
				<TextBox x:Name="GroupInput" Grid.Row="1" Grid.Column="1" Margin="0,8,0,0"/>
			</Grid>
			<Button x:Name="ActionBtn" Style="{DynamicResource BtnPrimary}" Content="$ActionText" Margin="0,14,0,0"/>
		</StackPanel>
	</Border>
	<Border Style="{DynamicResource Card}" Margin="0,12,0,0">
		<StackPanel>
			<TextBlock Text="Bulk" Style="{DynamicResource H3}"/>
			<Button x:Name="OpenTemplateBtn" Style="{DynamicResource BtnSecondary}" Content="Open Template" Margin="0,12,0,0"/>
			<Button x:Name="BulkBtn" Style="{DynamicResource BtnPrimary}" Content="$BulkText" Margin="0,8,0,0"/>
			$pasteBtn
		</StackPanel>
	</Border>
</StackPanel>
"@
}

# ---------------------------------------------------------------------------
function New-AuthenticationPhoneDialog {
	New-StyledDialog -Title 'Add-AuthenticationPhoneMethod' -Icon '&#xEE2F;' -BodyXaml @'
<StackPanel Margin="16" Width="340">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<TextBlock Text="Single" Style="{DynamicResource H3}"/>
			<Grid Margin="0,12,0,0">
				<Grid.ColumnDefinitions>
					<ColumnDefinition Width="70"/><ColumnDefinition Width="*"/>
				</Grid.ColumnDefinitions>
				<Grid.RowDefinitions>
					<RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
				</Grid.RowDefinitions>
				<TextBlock Text="Email" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
				<TextBox x:Name="EmailInput" Grid.Column="1"/>
				<TextBlock Text="Phone" Style="{DynamicResource Dim}" Grid.Row="1" VerticalAlignment="Center" Margin="0,8,0,0"/>
				<TextBox x:Name="PhoneInput" Grid.Row="1" Grid.Column="1" Margin="0,8,0,0"/>
			</Grid>
			<TextBlock Text="Example: +1 2224446666" Style="{DynamicResource Small}" Margin="70,6,0,0"/>
			<Button x:Name="AddPhoneBtn" Style="{DynamicResource BtnPrimary}" Content="Add Phone Number" Margin="0,14,0,0"/>
		</StackPanel>
	</Border>
	<Border Style="{DynamicResource Card}" Margin="0,12,0,0">
		<StackPanel>
			<TextBlock Text="Bulk" Style="{DynamicResource H3}"/>
			<Button x:Name="OpenTemplateBtn" Style="{DynamicResource BtnSecondary}" Content="Open Template" Margin="0,12,0,0"/>
			<Button x:Name="AddBulkPhoneBtn" Style="{DynamicResource BtnPrimary}" Content="Add Phone Numbers" Margin="0,8,0,0"/>
		</StackPanel>
	</Border>
</StackPanel>
'@
}

function Add-AuthenticationPhoneMethod {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Add-AuthenticationPhoneMethod.txt"
	Write-Host "Running Add-2FA script..."
	$progressBar1.Value = 10
	function OnAddPhoneButtonClick {
		$progressBar1.Value = 10
		$user = $emailInput.Text
		$phoneNumber = $phoneInput.Text
		$progressBar1.Value = 40
		New-MgUserAuthenticationPhoneMethod -UserId $user -phoneType "mobile" -phoneNumber $phoneNumber
		Write-Host "Added $phoneNumber to $user."
		$progressBar1.Value = 80
		CheckForErrors
		OperationComplete
	}
	function OnOpenTemplateButtonClick {
		Write-Host "Open template button clicked."
		$progressBar1.Value = 10
		Invoke-Item ".\Templates\Add-AuthenticationPhoneMethod.csv"
		$progressBar1.Value = 100
		CheckForErrors
		$progressBar1.Value = 0
	}
	function OnAddBulkPhoneButtonClick {
		Write-Host "AddBulkPhone button clicked."
		$progressBar1.Value = 10
		Import-Csv -Path ".\Templates\Add-AuthenticationPhoneMethod.csv" | ForEach-Object {
			$progressBar1.Value = 20
			$user = $_.Email
			$phoneNumber = $_.Phone
			$progressBar1.Value = 40
			New-MgUserAuthenticationPhoneMethod -UserId $user -phoneType "mobile" -phoneNumber $phoneNumber
			$progressBar1.Value = 80
			Write-Host "Added $phoneNumber to $user."
		}
		CheckForErrors
		OperationComplete
	}

	$scriptForm8 = New-AuthenticationPhoneDialog
	$emailInput = $scriptForm8.FindName('EmailInput')
	$phoneInput = $scriptForm8.FindName('PhoneInput')
	$scriptForm8.FindName('AddPhoneBtn').Add_Click({ OnAddPhoneButtonClick })
	$scriptForm8.FindName('OpenTemplateBtn').Add_Click({ OnOpenTemplateButtonClick })
	$scriptForm8.FindName('AddBulkPhoneBtn').Add_Click({ OnAddBulkPhoneButtonClick })

	Write-Host "Loaded ScriptForm8."
	$progressBar1.Value = 0

	[void]$scriptForm8.ShowDialog()

	Stop-Transcript
}

# ---------------------------------------------------------------------------
# Exchange stores auto-reply messages as HTML; convert to readable plain text so an
# existing reply can be shown in the plain-text boxes.
function ConvertFrom-AutoReplyHtml([string]$Html) {
	if (-not $Html) { return '' }
	$t = $Html -replace '(?is)<br\s*/?>', "`n" -replace '(?is)</p\s*>', "`n" -replace '(?is)<[^>]+>', ''
	$t = [System.Net.WebUtility]::HtmlDecode($t)
	return $t.Trim()
}

function New-AutoReplyDialog {
	$win = New-StyledDialog -Title 'Add-AutoReply' -Icon '&#xEBBC;' -BodyXaml @'
<StackPanel Margin="16" Width="520">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<Grid>
				<Grid.ColumnDefinitions>
					<ColumnDefinition Width="70"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
				</Grid.ColumnDefinitions>
				<TextBlock Text="Mailbox" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
				<TextBox x:Name="EmailInputBox" Grid.Column="1"/>
				<Button x:Name="ShowCurrentBtn" Grid.Column="2" Style="{DynamicResource BtnSecondary}" Content="Show current" Margin="8,0,0,0"
						ToolTip="Load the mailbox's current auto-reply so you can review it"/>
			</Grid>
			<Grid Margin="0,14,0,0">
				<Grid.ColumnDefinitions>
					<ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/>
				</Grid.ColumnDefinitions>
				<StackPanel Grid.Column="0">
					<TextBlock Text="Internal Auto-Reply" Style="{DynamicResource Dim}"/>
					<TextBox x:Name="InternalReplyBox" Style="{DynamicResource TextArea}" Height="170" Margin="0,6,0,0"/>
				</StackPanel>
				<StackPanel Grid.Column="2">
					<TextBlock Text="External Auto-Reply" Style="{DynamicResource Dim}"/>
					<TextBox x:Name="ExternalReplyBox" Style="{DynamicResource TextArea}" Height="170" Margin="0,6,0,0"/>
				</StackPanel>
			</Grid>
			<CheckBox x:Name="MatchRepliesCheck" Content="Match Replies" IsChecked="True" Margin="0,12,0,0"/>
			<Border Style="{DynamicResource Divider}"/>
			<CheckBox x:Name="UseScheduleCheck" Content="Use Start and End Date"/>
			<Grid Margin="0,10,0,0">
				<Grid.ColumnDefinitions>
					<ColumnDefinition Width="70"/><ColumnDefinition Width="*"/>
				</Grid.ColumnDefinitions>
				<Grid.RowDefinitions>
					<RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
				</Grid.RowDefinitions>
				<TextBlock Text="Start" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
				<DatePicker x:Name="StartDatePicker" Grid.Column="1" IsEnabled="False"/>
				<TextBlock Text="End" Style="{DynamicResource Dim}" Grid.Row="1" VerticalAlignment="Center" Margin="0,8,0,0"/>
				<DatePicker x:Name="EndDatePicker" Grid.Row="1" Grid.Column="1" IsEnabled="False" Margin="0,8,0,0"/>
			</Grid>
			<Button x:Name="ConfirmBtn" Style="{DynamicResource BtnPrimary}" Content="Confirm" Margin="0,16,0,0"/>
		</StackPanel>
	</Border>
</StackPanel>
'@
	$win.FindName('StartDatePicker').SelectedDate = [DateTime]::Now
	$win.FindName('EndDatePicker').SelectedDate = [DateTime]::Now
	return $win
}

function Add-AutoReply {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Add-AutoReply.txt"
	Write-Host "Running Add-AutoReply script..."

	function OnConfirmAutoReplyButtonClick {
		$progressBar1.Value = 20
		Write-Host "ConfirmAutoReplyButton clicked, adding auto-replies..."
		$internalMessage = $internalReplyTextBox.Text
		$externalMessage = $externalReplyTextBox.Text
		$mailbox = $emailInputBox.Text

		if ($useScheduleCheckBox.IsChecked -eq $true) {
			Write-Host "Use schedule is checked, creating auto-reply with schedule..."
			$startTime = $startDatePicker.SelectedDate
			$endTime = $endDatePicker.SelectedDate
			Set-MailboxAutoReplyConfiguration -Identity $mailbox -AutoReplyState Scheduled -StartTime $startTime -EndTime $endTime -InternalMessage $internalMessage -ExternalMessage $externalMessage -ExternalAudience All -Confirm:$false
			$progressBar1.Value = 50
		}
		else {
			Write-Host "Use schedule isn't checked, creating auto-reply..."
			Set-MailboxAutoReplyConfiguration -Identity $mailbox -AutoReplyState Enabled -InternalMessage $internalMessage -ExternalMessage $externalMessage -ExternalAudience All -Confirm:$false
			$progressBar1.Value = 50
		}
		CheckForErrors
		OperationComplete
	}

	$addAutoReplyForm = New-AutoReplyDialog
	$emailInputBox = $addAutoReplyForm.FindName('EmailInputBox')
	$internalReplyTextBox = $addAutoReplyForm.FindName('InternalReplyBox')
	$externalReplyTextBox = $addAutoReplyForm.FindName('ExternalReplyBox')
	$matchRepliesCheckBox = $addAutoReplyForm.FindName('MatchRepliesCheck')
	$useScheduleCheckBox = $addAutoReplyForm.FindName('UseScheduleCheck')
	$startDatePicker = $addAutoReplyForm.FindName('StartDatePicker')
	$endDatePicker = $addAutoReplyForm.FindName('EndDatePicker')
	$startDatePicker.SelectedDate = [DateTime]::Now
	$endDatePicker.SelectedDate = [DateTime]::Now

	$internalReplyTextBox.Add_TextChanged({
		if ($matchRepliesCheckBox.IsChecked -eq $true) { $externalReplyTextBox.Text = $internalReplyTextBox.Text }
	})
	$externalReplyTextBox.Add_TextChanged({
		if ($matchRepliesCheckBox.IsChecked -eq $true) { $internalReplyTextBox.Text = $externalReplyTextBox.Text }
	})
	$onSchedule = {
		if ($useScheduleCheckBox.IsChecked -eq $true) {
			$startDatePicker.IsEnabled = $true
			$endDatePicker.IsEnabled = $true
		}
		else {
			$startDatePicker.IsEnabled = $false
			$endDatePicker.IsEnabled = $false
		}
	}
	$useScheduleCheckBox.Add_Checked($onSchedule)
	$useScheduleCheckBox.Add_Unchecked($onSchedule)

	# "Show current": load the mailbox's existing auto-reply so the user can see if
	# there's already one they like before writing a new one.
	$addAutoReplyForm.FindName('ShowCurrentBtn').Add_Click({
		$mailbox = $emailInputBox.Text.Trim()
		if (-not $mailbox) { Write-Host "Enter a mailbox email address first." -ForegroundColor Yellow; return }
		Write-Host "Fetching current auto-reply for $mailbox..."
		$progressBar1.Value = 20
		try {
			$cfg = Get-MailboxAutoReplyConfiguration -Identity $mailbox -ErrorAction Stop
		} catch {
			Write-Host "Could not read auto-reply for $mailbox : $($_.Exception.Message)" -ForegroundColor Red
			$progressBar1.Value = 0
			return
		}
		$progressBar1.Value = 60
		$state = [string]$cfg.AutoReplyState
		if (-not $state -or $state -eq 'Disabled') {
			$internalReplyTextBox.Text = ''
			$externalReplyTextBox.Text = ''
			Write-Host "No auto-reply is currently set on $mailbox (state: $state). You can create a new one." -ForegroundColor Cyan
		} else {
			$intText = ConvertFrom-AutoReplyHtml ([string]$cfg.InternalMessage)
			$extText = ConvertFrom-AutoReplyHtml ([string]$cfg.ExternalMessage)
			# if internal/external differ, turn off Match Replies so loading one doesn't overwrite the other
			if ($intText -ne $extText) { $matchRepliesCheckBox.IsChecked = $false }
			$internalReplyTextBox.Text = $intText
			$externalReplyTextBox.Text = $extText
			if ($state -eq 'Scheduled') {
				$useScheduleCheckBox.IsChecked = $true
				if ($cfg.StartTime) { try { $startDatePicker.SelectedDate = [datetime]$cfg.StartTime } catch {} }
				if ($cfg.EndTime)   { try { $endDatePicker.SelectedDate   = [datetime]$cfg.EndTime }   catch {} }
			}
			Write-Host "Current auto-reply on $mailbox is '$state' - loaded its message(s) below for review." -ForegroundColor Green
		}
		CheckForErrors
		$progressBar1.Value = 0
	})

	$addAutoReplyForm.FindName('ConfirmBtn').Add_Click({ OnConfirmAutoReplyButtonClick })

	[void]$addAutoReplyForm.ShowDialog()

	Stop-Transcript
}

# ---------------------------------------------------------------------------
function New-AddContactsDialog {
	New-StyledDialog -Title 'Add-Contacts' -Icon '&#xE249;' -BodyXaml @'
<StackPanel Margin="16" Width="340">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<TextBlock Text="Mode" Style="{DynamicResource H3}"/>
			<StackPanel Orientation="Horizontal" Margin="0,10,0,0">
				<RadioButton x:Name="AllInfoChip" Style="{DynamicResource Chip}" GroupName="ContactMode" Content="All info" IsChecked="True"/>
				<RadioButton x:Name="JustEmailChip" Style="{DynamicResource Chip}" GroupName="ContactMode" Content="Just email" Margin="8,0,0,0"/>
			</StackPanel>
		</StackPanel>
	</Border>
	<Border Style="{DynamicResource Card}" Margin="0,12,0,0">
		<StackPanel>
			<TextBlock Text="Single" Style="{DynamicResource H3}"/>
			<Grid Margin="0,12,0,0">
				<Grid.ColumnDefinitions>
					<ColumnDefinition Width="70"/><ColumnDefinition Width="*"/>
				</Grid.ColumnDefinitions>
				<Grid.RowDefinitions>
					<RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
				</Grid.RowDefinitions>
				<TextBlock Text="Name" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
				<TextBox x:Name="NameInput" Grid.Column="1"/>
				<TextBlock Text="Email" Style="{DynamicResource Dim}" Grid.Row="1" VerticalAlignment="Center" Margin="0,8,0,0"/>
				<TextBox x:Name="EmailInput" Grid.Row="1" Grid.Column="1" Margin="0,8,0,0"/>
			</Grid>
			<Button x:Name="AddContactBtn" Style="{DynamicResource BtnPrimary}" Content="Add Contact" Margin="0,14,0,0"/>
		</StackPanel>
	</Border>
	<Border Style="{DynamicResource Card}" Margin="0,12,0,0">
		<StackPanel>
			<TextBlock Text="Bulk" Style="{DynamicResource H3}"/>
			<Button x:Name="OpenTemplateBtn" Style="{DynamicResource BtnSecondary}" Content="Open Template" Margin="0,12,0,0"/>
			<Button x:Name="BulkContactsBtn" Style="{DynamicResource BtnPrimary}" Content="Add Contacts" Margin="0,8,0,0"/>
		</StackPanel>
	</Border>
</StackPanel>
'@
}

function Add-Contacts {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Add-Contacts.txt"
	Write-Host "Running Add-Contacts script..."
	UpdateProgressBar(10)
	$addContactsMode = New-Object PSObject -Property @{ Value = 0 }
	function OnAddContactButtonClick {
		Write-Host "AddContact button clicked."
		UpdateProgressBar(10)
		if ($addContactsMode.Value -eq 0) {
			$displayName = $nameInputBox.Text
			$splitName = $displayName -Split ' '
			$firstName = $splitName[0]
			$lastName = $splitName[1]
			$externalEmailAddress = $emailInputBox.Text
			UpdateProgressBar(50)
			New-MailContact -Name $displayName -DisplayName $displayName -ExternalEmailAddress $externalEmailAddress -FirstName $firstName -LastName $lastName
			UpdateProgressBar(90)
		} elseif ($addContactsMode.Value -eq 1) {
			$externalEmailAddress = $emailInputBox.Text
			UpdateProgressBar(50)
			New-MailContact -Name $externalEmailAddress -ExternalEmailAddress $externalEmailAddress
			UpdateProgressBar(90)
		}
		CheckForErrors
		OperationComplete
	}
	function OnBulkContactsButtonClick {
		Write-Host "AddContactsBulk button clicked."
		$progressBar1.Value = 5
		if ($addContactsMode.Value -eq 0) {
			Import-Csv ".\Templates\Add-Contacts.csv" | ForEach-Object {
				$displayName = $_.DisplayName
				$splitName = $displayName -Split ' '
				$firstName = $splitName[0]
				$lastName = $splitName[1]
				$externalEmailAddress = $_.EmailAddress
				UpdateProgressBar(40)
				New-MailContact -Name $displayName -DisplayName $displayName -ExternalEmailAddress $externalEmailAddress -FirstName $firstName -LastName $lastName
				UpdateProgressBar(70)
			}
		} elseif ($addContactsMode.Value -eq 1) {
			Get-Content ".\Templates\Add-Contacts.txt" | ForEach-Object {
				UpdateProgressBar(10)
				New-MailContact -Name $_ -ExternalEmailAddress $_
				UpdateProgressBar(70)
			}
		}
		CheckForErrors
		OperationComplete
	}
	function OnOpenTemplateButtonClick {
		Write-Host "OpenTemplate button clicked."
		UpdateProgressBar(10)
		if ($addContactsMode.Value -eq 0) {
			Invoke-Item ".\Templates\Add-Contacts.csv"
		} elseif ($addContactsMode.Value -eq 1) {
			Invoke-Item ".\Templates\Add-Contacts.txt"
		}
		UpdateProgressBar(80)
		CheckForErrors
		UpdateProgressBar(0)
	}
	function OnRadioButtonSelect {
		if ($allInfoRadioButton.IsChecked -eq $true) {
			$addContactsMode.Value = 0
			$nameInputBox.IsEnabled = $true
		} elseif ($justEmailRadioButton.IsChecked -eq $true) {
			$addContactsMode.Value = 1
			$nameInputBox.IsEnabled = $false
		}
		Write-Host "Mode = $($addContactsMode.Value)"
		CheckForErrors
	}

	$scriptForm10 = New-AddContactsDialog
	$allInfoRadioButton = $scriptForm10.FindName('AllInfoChip')
	$justEmailRadioButton = $scriptForm10.FindName('JustEmailChip')
	$nameInputBox = $scriptForm10.FindName('NameInput')
	$emailInputBox = $scriptForm10.FindName('EmailInput')
	$allInfoRadioButton.Add_Checked({ OnRadioButtonSelect })
	$justEmailRadioButton.Add_Checked({ OnRadioButtonSelect })
	$scriptForm10.FindName('AddContactBtn').Add_Click({ OnAddContactButtonClick })
	$scriptForm10.FindName('OpenTemplateBtn').Add_Click({ OnOpenTemplateButtonClick })
	$scriptForm10.FindName('BulkContactsBtn').Add_Click({ OnBulkContactsButtonClick })

	Write-Host "Loaded ScriptForm10."
	UpdateProgressBar(0)

	[void]$scriptForm10.ShowDialog()

	Stop-Transcript
}

# ---------------------------------------------------------------------------
function Add-DistributionListMember {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Add-DistributionListMember.txt"
	Write-Host "Running Add-DistributionListMember script..."
	$progressBar1.Value = 10
	function OnAddMemberButtonClick {
		Write-Host "AddMemberButton clicked."
		$progressBar1.Value = 20
		$member = $memberInputBox.Text
		$group = $groupInputBox.Text
		$progressBar1.Value = 40
		Invoke-SingleMemberChange -Target $group -Member $member -Expected 'DistributionList' -Action 'add'
	}
	function OnOpenTemplateButtonClick {
		Write-Host "OpenTemplateButton clicked."
		$progressBar1.Value = 10
		Invoke-Item ".\Templates\Add-DistributionListMember.csv"
		$progressBar1.Value = 100
		CheckForErrors
		$progressBar1.Value = 0
	}
	function OnAddBulkMembersButtonClick {
		Write-Host "AddBulkMembersButton clicked."
		$progressBar1.Value = 10
		$typeCache = @{}
		$corrected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
		$counts = @{ done = 0; noop = 0; failed = 0; skipped = 0 }
		Import-Csv ".\Templates\Add-DistributionListMember.csv" | ForEach-Object {
			$progressBar1.Value = 20
			$member = $_.Member
			$group = $_.Group
			switch (Invoke-BulkMemberRow -Target $group -Member $member -Expected 'DistributionList' -Action 'add' -Cache $typeCache -Corrected $corrected) {
				'done'    { $counts.done++ }
				'noop'    { $counts.noop++ }
				'failed'  { $counts.failed++ }
				'unknown' { $counts.skipped++ }
			}
		}
		Show-BulkSummary $counts 'add' $corrected
	}

	$scriptForm8 = New-MemberGroupDialog -Title 'Add-DistributionListMember' -ActionText 'Add Member' -BulkText 'Add Members' -WithPaste
	$memberInputBox = $scriptForm8.FindName('MemberInput')
	$groupInputBox = $scriptForm8.FindName('GroupInput')
	$scriptForm8.FindName('ActionBtn').Add_Click({ OnAddMemberButtonClick })
	$scriptForm8.FindName('OpenTemplateBtn').Add_Click({ OnOpenTemplateButtonClick })
	$scriptForm8.FindName('BulkBtn').Add_Click({ OnAddBulkMembersButtonClick })
	$scriptForm8.FindName('PasteBtn').Add_Click({ Show-PasteMembersDialog -TargetPrefill $groupInputBox.Text })

	Write-Host "Loaded ScriptForm8."
	$progressBar1.Value = 0

	[void]$scriptForm8.ShowDialog()

	Stop-Transcript
}

# ---------------------------------------------------------------------------
# Add one alias to a mailbox. $AsPrimary promotes it to the PRIMARY address (the old primary
# becomes a secondary alias); otherwise it's added as a secondary alias. Pre-checks the alias
# domain is an accepted tenant domain so you get a friendly message instead of a raw Exchange
# error. Returns @{ Status='done'|'noop'|'failed'|'skipped'; Message }.
function Add-OneAlias([string]$Mailbox, [string]$Alias, [bool]$AsPrimary, $Accepted) {
	$res = @{ Status = 'failed'; Message = '' }
	$Mailbox = "$Mailbox".Trim(); $Alias = "$Alias".Trim()
	if (-not $Mailbox -or -not $Alias) { $res.Status = 'skipped'; $res.Message = 'blank mailbox or alias'; return $res }
	if ($Accepted -and (Test-IsExternalAddress $Alias $Accepted)) {
		$dom = $Alias.Substring($Alias.LastIndexOf('@') + 1)
		$res.Status = 'skipped'; $res.Message = "the domain '$dom' isn't an accepted domain in this tenant"; return $res
	}
	try {
		if ($AsPrimary) { Set-Mailbox -Identity $Mailbox -WindowsEmailAddress $Alias -ErrorAction Stop }
		else { Set-Mailbox -Identity $Mailbox -EmailAddresses @{Add = $Alias} -ErrorAction Stop }
		$res.Status = 'done'; return $res
	} catch {
		$msg = "$($_.Exception.Message)".Trim()
		if ($msg -match 'already|proxy|in use|ProxyAddress|must be unique|duplicate') { $res.Status = 'noop'; $res.Message = 'already assigned as an address' }
		else { $res.Status = 'failed'; $res.Message = $msg }
		return $res
	}
}

function New-EmailAliasDialog {
	param([string]$Title = 'Add-EmailAlias', [string]$ActionText = 'Add Alias', [string]$BulkText = 'Add Aliases', [string]$CheckText = 'Create Incremental Aliases', [switch]$WithPrimary)
	$primaryChk = if ($WithPrimary) { '<CheckBox x:Name="PrimaryCheck" Content="Set as primary address (single only)" Margin="0,10,0,0"/>' } else { '' }
	$previewChk = if ($WithPrimary) { '<CheckBox x:Name="PreviewCheck" Content="Preview only" Margin="0,10,0,0"/>' } else { '' }
	New-StyledDialog -Title $Title -Icon '&#xEBBC;' -BodyXaml @"
<StackPanel Margin="16" Orientation="Horizontal">
	<StackPanel Width="330">
		<Border Style="{DynamicResource Card}">
			<StackPanel>
				<TextBlock Text="Single" Style="{DynamicResource H3}"/>
				<Grid Margin="0,12,0,0">
					<Grid.ColumnDefinitions>
						<ColumnDefinition Width="70"/><ColumnDefinition Width="*"/>
					</Grid.ColumnDefinitions>
					<Grid.RowDefinitions>
						<RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
					</Grid.RowDefinitions>
					<TextBlock Text="Mailbox" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
					<TextBox x:Name="MailboxInput" Grid.Column="1"/>
					<TextBlock Text="Alias" Style="{DynamicResource Dim}" Grid.Row="1" VerticalAlignment="Center" Margin="0,8,0,0"/>
					<TextBox x:Name="AliasInput" Grid.Row="1" Grid.Column="1" Margin="0,8,0,0"/>
				</Grid>
				<Grid Margin="0,12,0,0">
					<Grid.ColumnDefinitions>
						<ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
					</Grid.ColumnDefinitions>
					<CheckBox x:Name="IncrementalCheck" Content="$CheckText" VerticalAlignment="Center"/>
					<TextBox x:Name="CountBox" Grid.Column="1" Width="64" Text="0" IsEnabled="False"
							 HorizontalContentAlignment="Center"/>
				</Grid>
				$primaryChk
				<Button x:Name="ActionBtn" Style="{DynamicResource BtnPrimary}" Content="$ActionText" Margin="0,14,0,0"/>
			</StackPanel>
		</Border>
		<Border Style="{DynamicResource Card}" Margin="0,12,0,0">
			<StackPanel>
				<TextBlock Text="Bulk" Style="{DynamicResource H3}"/>
				<Button x:Name="OpenTemplateBtn" Style="{DynamicResource BtnSecondary}" Content="Open Template" Margin="0,12,0,0"/>
				$previewChk
				<Button x:Name="BulkBtn" Style="{DynamicResource BtnPrimary}" Content="$BulkText" Margin="0,8,0,0"/>
			</StackPanel>
		</Border>
	</StackPanel>
	<Border Style="{DynamicResource Card}" Width="300" Margin="12,0,0,0" VerticalAlignment="Stretch">
		<StackPanel>
			<TextBlock Text="Info" Style="{DynamicResource H3}"/>
			<Button x:Name="GetAliasBtn" Style="{DynamicResource BtnSecondary}" Content="Get Current Aliases" Margin="0,12,0,0"/>
			<TextBox x:Name="InfoBox" Style="{DynamicResource TextArea}" Height="190" Margin="0,10,0,0" IsReadOnly="True"/>
			<Button x:Name="CopyBtn" Style="{DynamicResource BtnGhost}" Content="Copy to Clipboard" Margin="0,10,0,0"/>
		</StackPanel>
	</Border>
</StackPanel>
"@
}

function Add-EmailAlias {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Add-EmailAlias.txt"
	Write-Host "Running Add-EmailAlias script..."
	$progressBar1.Value = 10

	function OnAddAliasButtonClick {
		Write-Host "AddAliasButton clicked."
		$mailbox = $mailboxTextBox.Text
		$alias = $aliasTextBox.Text
		$accepted = Get-AcceptedDomainList
		if ($incrementalCheckBox.IsChecked -eq $true) {
			Write-Host "Creating incremental aliases..."
			$progressBar1.Value = 20
			$splitAlias = $alias -split '\@'
			$aliasName = $splitAlias[0]; $aliasDomain = $splitAlias[1]
			$created = [System.Collections.Generic.List[string]]::new()
			$failed  = [System.Collections.Generic.List[string]]::new()
			for ($i = 0; $i -lt $numericUpDown1.Value; $i++) {
				$completeAlias = "$aliasName$i@$aliasDomain"
				$r = Add-OneAlias $mailbox $completeAlias $false $accepted
				if ($r.Status -eq 'done') { $created.Add($completeAlias) }
				elseif ($r.Status -eq 'noop') { $failed.Add("$completeAlias - already assigned") }
				else { $failed.Add("$completeAlias - $($r.Message)") }
			}
			Show-AccountResults "Add aliases to $mailbox" $created $failed
		} else {
			Write-Host "Creating single alias..."
			$progressBar1.Value = 40
			$asPrimary = ($primaryCheckBox.IsChecked -eq $true)
			$r = Add-OneAlias $mailbox $alias $asPrimary $accepted
			switch ($r.Status) {
				'done'    { $verb = if ($asPrimary) { "set as the primary address on" } else { "added to" }; Write-Host "$alias $verb $mailbox." -ForegroundColor Cyan; Show-Notice 'Alias added' "'$alias' was $verb `"$mailbox`"." 'Info' }
				'noop'    { Write-Host "$alias already assigned." -ForegroundColor Yellow; Show-Notice 'Already an alias' "'$alias' is already assigned as an address (on this or another recipient)." 'Info' }
				'skipped' { Write-Host "Skipped '$alias': $($r.Message)" -ForegroundColor Yellow; Show-Notice "Can't add that alias" "Couldn't add '$alias' - $($r.Message)." 'Warn' }
				'failed'  { Write-Host "Failed to add '$alias': $($r.Message)" -ForegroundColor Red; Show-Notice 'Add alias failed' "Couldn't add '$alias' to `"$mailbox`":`n`n$($r.Message)" 'Error' }
			}
			$progressBar1.Value = 0
		}
	}
	function OnOpenTemplateButtonClick {
		$progressBar1.Value = 10
		Invoke-Item ".\Templates\Add-EmailAlias.csv"
		$progressBar1.Value = 100
		CheckForErrors
		$progressBar1.Value = 0
	}
	function OnAddAliasBulkButtonClick {
		$accepted = Get-AcceptedDomainList
		$preview = ($previewCheckBox.IsChecked -eq $true)
		$created = [System.Collections.Generic.List[string]]::new()
		$failed  = [System.Collections.Generic.List[string]]::new()
		Import-Csv ".\Templates\Add-EmailAlias.csv" | ForEach-Object {
			$progressBar1.Value = 40
			$mailbox = "$($_.Mailbox)".Trim(); $alias = "$($_.Alias)".Trim()
			$label = "$alias -> $mailbox"
			if ($preview) {
				if (-not $mailbox -or -not $alias) { $failed.Add("$label - blank mailbox or alias") }
				elseif ($accepted -and (Test-IsExternalAddress $alias $accepted)) { $failed.Add("$label - domain not accepted") }
				else { $created.Add($label) }
				return
			}
			$r = Add-OneAlias $mailbox $alias $false $accepted
			if ($r.Status -eq 'done') { $created.Add($label) }
			elseif ($r.Status -eq 'noop') { $failed.Add("$label - already assigned") }
			else { $failed.Add("$label - $($r.Message)") }
		}
		Show-AccountResults 'Add email aliases' $created $failed -Preview:$preview
	}
	function OnIncrementalCheckBoxChecked {
		if ($incrementalCheckBox.IsChecked -eq $true) {
			$numericUpDown1.Enabled = $true
			$addAliasButton.Content = "Add Aliases"
		} elseif ($incrementalCheckBox.IsChecked -eq $false) {
			$numericUpDown1.Enabled = $false
			$addAliasButton.Content = "Add Alias"
		}
	}
	function OnGetAliasButtonClick {
		Write-Host "GetAliasButton clicked."
		$progressBar1.Value = 10
		$infoTextBox.Text = Get-Mailbox $mailboxTextBox.Text | Select-Object -ExpandProperty emailaddresses
		$progressBar1.Value = 80
		CheckForErrors
		$progressBar1.Value = 0
	}
	function OnCopyButtonClick {
		Write-Host "CopyButton clicked."
		$progressBar1.Value = 10
		Get-Mailbox $mailboxTextBox.Text | Select-Object -ExpandProperty emailaddresses | Set-Clipboard
		$progressBar1.Value = 80
		CheckForErrors
		OperationComplete
	}

	$emailAliasForm = New-EmailAliasDialog -WithPrimary
	$mailboxTextBox = $emailAliasForm.FindName('MailboxInput')
	$aliasTextBox = $emailAliasForm.FindName('AliasInput')
	$incrementalCheckBox = $emailAliasForm.FindName('IncrementalCheck')
	$primaryCheckBox = $emailAliasForm.FindName('PrimaryCheck')
	$previewCheckBox = $emailAliasForm.FindName('PreviewCheck')
	$addAliasButton = $emailAliasForm.FindName('ActionBtn')
	$infoTextBox = $emailAliasForm.FindName('InfoBox')
	$numericUpDown1 = New-NumericProxy ($emailAliasForm.FindName('CountBox')) 1000
	$incrementalCheckBox.Add_Checked({ OnIncrementalCheckBoxChecked })
	$incrementalCheckBox.Add_Unchecked({ OnIncrementalCheckBoxChecked })
	$addAliasButton.Add_Click({ OnAddAliasButtonClick })
	$emailAliasForm.FindName('OpenTemplateBtn').Add_Click({ OnOpenTemplateButtonClick })
	$emailAliasForm.FindName('BulkBtn').Add_Click({ OnAddAliasBulkButtonClick })
	$emailAliasForm.FindName('GetAliasBtn').Add_Click({ OnGetAliasButtonClick })
	$emailAliasForm.FindName('CopyBtn').Add_Click({ OnCopyButtonClick })

	Write-Host "Loaded EmailAliasForm."
	$progressBar1.Value = 0

	[void]$emailAliasForm.ShowDialog()

	Stop-Transcript
}

# ---------------------------------------------------------------------------
function New-MailboxMemberDialog {
	New-StyledDialog -Title 'Add-MailboxMember' -Icon '&#xED93;' -BodyXaml @'
<StackPanel Margin="16" Width="360">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<Grid>
				<Grid.ColumnDefinitions>
					<ColumnDefinition Width="70"/><ColumnDefinition Width="*"/>
				</Grid.ColumnDefinitions>
				<Grid.RowDefinitions>
					<RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
				</Grid.RowDefinitions>
				<TextBlock Text="Member" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
				<TextBox x:Name="MemberInput" Grid.Column="1"/>
				<TextBlock Text="Mailbox" Style="{DynamicResource Dim}" Grid.Row="1" VerticalAlignment="Center" Margin="0,8,0,0"/>
				<TextBox x:Name="MailboxInput" Grid.Row="1" Grid.Column="1" Margin="0,8,0,0"/>
			</Grid>
			<StackPanel Orientation="Horizontal" Margin="0,12,0,0">
				<RadioButton x:Name="AddMemberChip" Style="{DynamicResource Chip}" GroupName="MailboxMode" Content="Add Member"/>
				<RadioButton x:Name="RemoveMemberChip" Style="{DynamicResource Chip}" GroupName="MailboxMode" Content="Remove Member" Margin="8,0,0,0"/>
			</StackPanel>
			<Button x:Name="MemberBtn" Style="{DynamicResource BtnPrimary}" Content="Add Member" Margin="0,14,0,0"/>
			<TextBlock Text="Only apply a single permission:" Style="{DynamicResource Small}" Margin="0,12,0,4"/>
			<Grid>
				<Grid.ColumnDefinitions>
					<ColumnDefinition Width="*"/><ColumnDefinition Width="8"/>
					<ColumnDefinition Width="*"/><ColumnDefinition Width="8"/>
					<ColumnDefinition Width="*"/>
				</Grid.ColumnDefinitions>
				<Button x:Name="FullAccessBtn" Style="{DynamicResource BtnSecondary}" Content="FullAccess" Padding="6,7"/>
				<Button x:Name="SendOnBehalfBtn" Style="{DynamicResource BtnSecondary}" Content="SendOnBehalf" Grid.Column="2" Padding="6,7"/>
				<Button x:Name="SendAsBtn" Style="{DynamicResource BtnSecondary}" Content="SendAs" Grid.Column="4" Padding="6,7"/>
			</Grid>
		</StackPanel>
	</Border>
	<Border Style="{DynamicResource Card}" Margin="0,12,0,0">
		<StackPanel>
			<TextBlock Text="Bulk" Style="{DynamicResource H3}"/>
			<Button x:Name="OpenTemplateBtn" Style="{DynamicResource BtnSecondary}" Content="Open Template" Margin="0,12,0,0"/>
			<Button x:Name="BulkMembersBtn" Style="{DynamicResource BtnPrimary}" Content="Add Members" Margin="0,8,0,0"/>
			<Button x:Name="PasteBtn" Style="{DynamicResource BtnSecondary}" Content="Paste List..." Margin="0,8,0,0"/>
		</StackPanel>
	</Border>
</StackPanel>
'@
}

function Add-MailboxMember {
	$progressBar1.Value = 10
	$Script:mailboxMemberMode = 0
	if ($selectedScript -eq "Add-MailboxMember") {
		Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Add-MailboxMember.txt"
		Write-Host "Running Add-MailboxMember script..."
		$Script:mailboxMemberMode = 0
	} elseif ($selectedScript -eq "Remove-MailboxMember") {
		Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Remove-MailboxMember.txt"
		Write-Host "Running Remove-MailboxMember script..."
		$Script:mailboxMemberMode = 1
	}
	$progressBar1.Value = 20
	function OnRadioButtonSelect {
		if ($addMemberRadioButton.IsChecked -eq $true) {
			Set-DialogTitle $scriptForm1 "Add-MailboxMember"
			$memberButton.Content = "Add Member"
			$bulkMembersButton.Content = "Add Members"
			$Script:mailboxMemberMode = 0
		}
		elseif ($removeMemberRadioButton.IsChecked -eq $true) {
			Set-DialogTitle $scriptForm1 "Remove-MailboxMember"
			$memberButton.Content = "Remove Member"
			$bulkMembersButton.Content = "Remove Members"
			$Script:mailboxMemberMode = 1
		}
		Write-Host "Mode = $mailboxMemberMode"
		CheckForErrors
	}
	# All four mailbox buttons auto-route: if the "mailbox" is really a distribution list or
	# Teams / M365 group, the person is added to / removed from it as a member (mailbox-only
	# rights like Send As fall back to plain membership), and the summary says so afterward.
	function OnMemberButtonClick {
		$act = if ($mailboxMemberMode -eq 0) { 'add' } else { 'remove' }
		Invoke-SingleMemberChange -Target $mailboxInputBox.Text -Member $memberInputBox.Text -Expected 'Mailbox' -Action $act -MailboxRight 'FullAndSendAs'
		CheckForErrors
	}
	function OnFullAccessButtonClick {
		$act = if ($mailboxMemberMode -eq 0) { 'add' } else { 'remove' }
		Invoke-SingleMemberChange -Target $mailboxInputBox.Text -Member $memberInputBox.Text -Expected 'Mailbox' -Action $act -MailboxRight 'FullAccess'
		CheckForErrors
	}
	function OnSendOnBehalfButtonClick {
		$act = if ($mailboxMemberMode -eq 0) { 'add' } else { 'remove' }
		Invoke-SingleMemberChange -Target $mailboxInputBox.Text -Member $memberInputBox.Text -Expected 'Mailbox' -Action $act -MailboxRight 'SendOnBehalf'
		CheckForErrors
	}
	function OnSendAsButtonClick {
		$act = if ($mailboxMemberMode -eq 0) { 'add' } else { 'remove' }
		Invoke-SingleMemberChange -Target $mailboxInputBox.Text -Member $memberInputBox.Text -Expected 'Mailbox' -Action $act -MailboxRight 'SendAs'
		CheckForErrors
	}
	function OnOpenTemplateButtonClick {
		if ($mailboxMemberMode -eq 0) {
			Write-Host "Open template button clicked."
			$progressBar1.Value = 10
			Invoke-Item ".\Templates\Add-MailboxMember.csv"
			$progressBar1.Value = 0
		} elseif ($mailboxMemberMode -eq 1) {
			Write-Host "Open template button clicked."
			$progressBar1.Value = 10
			Invoke-Item ".\Templates\Remove-MailboxMember.csv"
			$progressBar1.Value = 0
		}
		CheckForErrors
	}
	function OnBulkMembersButtonClick {
		$progressBar1.Value = 10
		$typeCache = @{}
		$corrected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
		$counts = @{ done = 0; noop = 0; failed = 0; skipped = 0 }
		$act = if ($mailboxMemberMode -eq 0) { 'add' } else { 'remove' }
		$csv = if ($mailboxMemberMode -eq 0) { ".\Templates\Add-MailboxMember.csv" } else { ".\Templates\Remove-MailboxMember.csv" }
		Import-Csv $csv | ForEach-Object {
			$member = $_.Member
			$mailbox = $_.Mailbox
			$progressBar1.Value = 40
			switch (Invoke-BulkMemberRow -Target $mailbox -Member $member -Expected 'Mailbox' -Action $act -Cache $typeCache -Corrected $corrected -MailboxRight 'FullAndSendAs') {
				'done'    { $counts.done++ }
				'noop'    { $counts.noop++ }
				'failed'  { $counts.failed++ }
				'unknown' { $counts.skipped++ }
			}
		}
		Show-BulkSummary $counts $act $corrected
	}

	$scriptForm1 = New-MailboxMemberDialog
	$memberInputBox = $scriptForm1.FindName('MemberInput')
	$mailboxInputBox = $scriptForm1.FindName('MailboxInput')
	$addMemberRadioButton = $scriptForm1.FindName('AddMemberChip')
	$removeMemberRadioButton = $scriptForm1.FindName('RemoveMemberChip')
	$memberButton = $scriptForm1.FindName('MemberBtn')
	$bulkMembersButton = $scriptForm1.FindName('BulkMembersBtn')
	$addMemberRadioButton.Add_Checked({ OnRadioButtonSelect })
	$removeMemberRadioButton.Add_Checked({ OnRadioButtonSelect })
	$memberButton.Add_Click({ OnMemberButtonClick })
	$scriptForm1.FindName('FullAccessBtn').Add_Click({ OnFullAccessButtonClick })
	$scriptForm1.FindName('SendOnBehalfBtn').Add_Click({ OnSendOnBehalfButtonClick })
	$scriptForm1.FindName('SendAsBtn').Add_Click({ OnSendAsButtonClick })
	$scriptForm1.FindName('OpenTemplateBtn').Add_Click({ OnOpenTemplateButtonClick })
	$bulkMembersButton.Add_Click({ OnBulkMembersButtonClick })
	$scriptForm1.FindName('PasteBtn').Add_Click({ Show-PasteMembersDialog -TargetPrefill $mailboxInputBox.Text -Action $(if ($mailboxMemberMode -eq 0) { 'add' } else { 'remove' }) })

	if ($mailboxMemberMode -eq 0) {
		Set-DialogTitle $scriptForm1 "Add-MailboxMember"
		$memberButton.Content = "Add Member"
		$bulkMembersButton.Content = "Add Members"
		$addMemberRadioButton.IsChecked = $true
	} elseif ($mailboxMemberMode -eq 1) {
		Set-DialogTitle $scriptForm1 "Remove-MailboxMember"
		$memberButton.Content = "Remove Member"
		$bulkMembersButton.Content = "Remove Members"
		$removeMemberRadioButton.IsChecked = $true
	}

	Write-Host "Loaded ScriptForm1."
	$progressBar1.Value = 0

	[void]$scriptForm1.ShowDialog()

	Stop-Transcript
}

# ---------------------------------------------------------------------------
function New-TrustedSenderDialog {
	New-StyledDialog -Title 'Add-TrustedSender' -Icon '&#xF039;' -BodyXaml @'
<StackPanel Margin="16" Width="360">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<Grid>
				<Grid.ColumnDefinitions>
					<ColumnDefinition Width="110"/><ColumnDefinition Width="*"/>
				</Grid.ColumnDefinitions>
				<TextBlock Text="Email or Domain" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
				<TextBox x:Name="TrustedSenderInput" Grid.Column="1"/>
			</Grid>
			<TextBlock Style="{DynamicResource Small}" Margin="0,10,0,0"
					   Text="Adds the address or domain to the trusted senders list of every mailbox in the tenant. This can take a while on big tenants."/>
			<Button x:Name="TrustedSenderBtn" Style="{DynamicResource BtnPrimary}" Content="Add Trusted Sender" Margin="0,14,0,0" IsDefault="True"/>
		</StackPanel>
	</Border>
</StackPanel>
'@
}

function Add-TrustedSender {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Add-TrustedSender.txt"
	Write-Host "Running Add-TrustedSender script..."
	$progressBar1.Value = 10
	function OnTrustedSenderButtonClick {
		$trustedSender = $trustedSenderInputBox.Text
		$progressBar1.Value = 10
		Get-Mailbox -RecipientTypeDetails UserMailbox -ResultSize Unlimited | ForEach-Object {
			$progressBar1.Value = 30
			Set-MailboxJunkEmailConfiguration $_.Name -TrustedSendersAndDomains @{Add=$trustedSender}
			$progressBar1.Value = 80
			Write-Host "Configured " + $_.Name
		}
		Write-Host "Finished configuring mailboxes."
		CheckForErrors
		OperationComplete
	}

	$ScriptForm5 = New-TrustedSenderDialog
	$trustedSenderInputBox = $ScriptForm5.FindName('TrustedSenderInput')
	$ScriptForm5.FindName('TrustedSenderBtn').Add_Click({ OnTrustedSenderButtonClick })

	Write-Host "Loaded ScriptForm5"
	$progressBar1.Value = 0

	[void]$ScriptForm5.ShowDialog()

	Stop-Transcript
}

# ---------------------------------------------------------------------------
function Add-UnifiedGroupMember {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Add-UnifiedGroupMember.txt"
	Write-Host "Running Add-UnifiedGroupMember script..."
	$progressBar1.Value = 10
	function OnAddMemberButtonClick {
		Write-Host "AddMember button clicked."
		$progressBar1.Value = 20
		$member = $memberInputBox.Text
		$group = $groupInputBox.Text
		$progressBar1.Value = 30
		Invoke-SingleMemberChange -Target $group -Member $member -Expected 'UnifiedGroup' -Action 'add'
	}
	function OnOpenTemplateButtonClick {
		Write-Host "OpenTemplate button clicked."
		$progressBar1.Value = 10
		Invoke-Item ".\Templates\Add-UnifiedGroupMember.csv"
		$progressBar1.Value = 100
		CheckForErrors
		$progressBar1.Value = 0
	}
	function OnAddBulkMembersButtonClick {
		Write-Host "AddBulkMembers button clicked."
		$progressBar1.Value = 10
		$typeCache = @{}
		$corrected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
		$counts = @{ done = 0; noop = 0; failed = 0; skipped = 0 }
		Import-Csv ".\Templates\Add-UnifiedGroupMember.csv" | ForEach-Object {
			$progressBar1.Value = 30
			$member = $_.Member
			$group = $_.Group
			switch (Invoke-BulkMemberRow -Target $group -Member $member -Expected 'UnifiedGroup' -Action 'add' -Cache $typeCache -Corrected $corrected) {
				'done'    { $counts.done++ }
				'noop'    { $counts.noop++ }
				'failed'  { $counts.failed++ }
				'unknown' { $counts.skipped++ }
			}
		}
		Show-BulkSummary $counts 'add' $corrected
	}

	$scriptForm8 = New-MemberGroupDialog -Title 'Add-UnifiedGroupMember' -ActionText 'Add Member' -BulkText 'Add Members' -WithPaste
	$memberInputBox = $scriptForm8.FindName('MemberInput')
	$groupInputBox = $scriptForm8.FindName('GroupInput')
	$scriptForm8.FindName('ActionBtn').Add_Click({ OnAddMemberButtonClick })
	$scriptForm8.FindName('OpenTemplateBtn').Add_Click({ OnOpenTemplateButtonClick })
	$scriptForm8.FindName('BulkBtn').Add_Click({ OnAddBulkMembersButtonClick })
	$scriptForm8.FindName('PasteBtn').Add_Click({ Show-PasteMembersDialog -TargetPrefill $groupInputBox.Text })

	Write-Host "Loaded ScriptForm8."
	$progressBar1.Value = 0

	[void]$scriptForm8.ShowDialog()

	Stop-Transcript
}
