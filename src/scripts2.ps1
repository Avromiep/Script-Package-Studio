# Script-Package - script dialogs (Block-User .. New-*)

# Assign one license SKU to a just-created user, retrying ONLY on the transient
# "user doesn't exist yet / not replicated" error that can follow New-MgUser. Real errors
# (invalid SKU, no seats available, user not licensable, bad UsageLocation) are thrown right
# away without retrying. Returns nothing on success; throws if it ultimately can't assign.
function Assign-MgLicenseWithRetry([string]$UserId, [string]$SkuId) {
	$delays = @(2, 5, 10)   # seconds between attempts; total added wait only happens on failure
	for ($i = 0; $i -le $delays.Count; $i++) {
		try {
			Set-MgUserLicense -UserId $UserId -AddLicenses @(@{SkuId = $SkuId}) -RemoveLicenses @() -ErrorAction Stop
			return
		} catch {
			$msg = "$($_.Exception.Message)"
			# Transient = the user object isn't visible to Graph yet after New-MgUser.
			$transient = ($msg -match 'does not exist|not found|ResourceNotFound|Request_ResourceNotExists|could not be found|being provisioned|replicat')
			if ($i -lt $delays.Count -and $transient) {
				Write-Host "License assign for '$UserId' not ready yet (attempt $($i + 1)): $msg. Retrying in $($delays[$i])s..." -ForegroundColor Yellow
				Start-Sleep -Seconds $delays[$i]
				continue
			}
			throw
		}
	}
}

# Remove a user's licenses. Handles BOTH directly-assigned licenses (Set-MgUserLicense) and
# licenses that come from GROUP-BASED LICENSING - which Graph refuses to remove from the user
# directly ("license is inherited from a group membership"), so the only way to drop them is to
# remove the user from the assigning group. Reads LicenseAssignmentStates to tell which is which.
# Writes progress; never throws (logs per item). Reused by the termination and Block-User scripts.
function Remove-UserLicenses([string]$User) {
	$u = $null
	try { $u = Get-MgUser -UserId $User -Property 'Id,LicenseAssignmentStates' -ErrorAction Stop } catch { Write-Host "  couldn't read license state: $($_.Exception.Message)" -ForegroundColor Yellow; return }
	$states = @($u.LicenseAssignmentStates)
	if (-not $states.Count) { Write-Host "  no licenses to remove."; return }
	$directSkus = @($states | Where-Object { -not $_.AssignedByGroup } | Select-Object -ExpandProperty SkuId -Unique)
	$groupIds   = @($states | Where-Object { $_.AssignedByGroup } | Select-Object -ExpandProperty AssignedByGroup -Unique)
	if ($directSkus.Count) {
		try { Set-MgUserLicense -UserId $User -RemoveLicenses @($directSkus) -AddLicenses @() -ErrorAction Stop | Out-Null; Write-Host "  removed $($directSkus.Count) directly-assigned license(s)." -ForegroundColor Cyan }
		catch { Write-Host "  couldn't remove directly-assigned licenses: $($_.Exception.Message)" -ForegroundColor Yellow }
	}
	foreach ($gid in $groupIds) {
		$gname = $gid
		try { $gname = (Get-MgGroup -GroupId $gid -Property DisplayName -ErrorAction Stop).DisplayName } catch {}
		try { Remove-MgGroupMemberByRef -GroupId $gid -DirectoryObjectId $u.Id -ErrorAction Stop; Write-Host "  removed from licensing group '$gname' to drop its group-assigned license(s)." -ForegroundColor Cyan }
		catch { Write-Host "  note: the license from '$gname' comes from that group's membership (not a direct assignment), so it can't be removed here. This is usually fine: that's a rule-based (dynamic) group - e.g. 'account enabled & licensed' - and now that the account is DISABLED the rule drops the user automatically, so the license comes off on its own within a few minutes (that's why it looks removed when you check). Only if that group isn't dynamic do you need to remove/exclude the user from it in the admin center. ($($_.Exception.Message))" -ForegroundColor Yellow }
	}
}

# Remove EVERY re-registerable auth method for a user - phone, Microsoft Authenticator,
# software OATH, FIDO2, Windows Hello, email, temporary access pass - leaving only the password.
# Loops so a user with several methods (or several phone numbers) is fully cleared, and a
# per-method failure is logged and skipped rather than stopping the rest. Returns the count
# removed; throws only if the user's method list can't be read at all. Shared by Reset-MFA and
# the termination script. Needs the Graph scope UserAuthenticationMethod.ReadWrite.All.
# Remove ONE authentication method (any type) by its @odata.type + id. Used by the Add-2FA
# "Show current" list so the user can remove any single 2FA method (phone, alternate phone,
# Microsoft Authenticator, security key, email, TAP, etc.). Throws for the password / unknown types.
# Remove a Windows Hello for Business method. Graph 1.x spells the cmdlet "...WindowHello..."
# (no 's'); 2.x spells it "...WindowsHello...". Use whichever the loaded module provides. Called
# only after sign-in, when the pinned modules are already loaded.
function Remove-WinHelloMethod([string]$User, [string]$Id) {
	if (Get-Command Remove-MgUserAuthenticationWindowsHelloForBusinessMethod -ErrorAction Ignore) {
		Remove-MgUserAuthenticationWindowsHelloForBusinessMethod -UserId $User -WindowsHelloForBusinessAuthenticationMethodId $Id -ErrorAction Stop
	} else {
		Remove-MgUserAuthenticationWindowHelloForBusinessMethod -UserId $User -WindowsHelloForBusinessAuthenticationMethodId $Id -ErrorAction Stop
	}
}
function Remove-OneAuthMethod([string]$User, [string]$Type, [string]$Id) {
	switch -Wildcard ($Type) {
		'*phoneAuthenticationMethod'                  { Remove-MgUserAuthenticationPhoneMethod -UserId $User -PhoneAuthenticationMethodId $Id -ErrorAction Stop }
		'*microsoftAuthenticatorAuthenticationMethod' { Remove-MgUserAuthenticationMicrosoftAuthenticatorMethod -UserId $User -MicrosoftAuthenticatorAuthenticationMethodId $Id -ErrorAction Stop }
		'*softwareOathAuthenticationMethod'           { Remove-MgUserAuthenticationSoftwareOathMethod -UserId $User -SoftwareOathAuthenticationMethodId $Id -ErrorAction Stop }
		'*fido2AuthenticationMethod'                  { Remove-MgUserAuthenticationFido2Method -UserId $User -Fido2AuthenticationMethodId $Id -ErrorAction Stop }
		'*windowsHelloForBusinessAuthenticationMethod'{ Remove-WinHelloMethod $User $Id }
		'*emailAuthenticationMethod'                  { Remove-MgUserAuthenticationEmailMethod -UserId $User -EmailAuthenticationMethodId $Id -ErrorAction Stop }
		'*temporaryAccessPassAuthenticationMethod'    { Remove-MgUserAuthenticationTemporaryAccessPassMethod -UserId $User -TemporaryAccessPassAuthenticationMethodId $Id -ErrorAction Stop }
		'*platformCredentialAuthenticationMethod'     {
			if (Get-Command Remove-MgUserAuthenticationPlatformCredentialMethod -ErrorAction Ignore) { Remove-MgUserAuthenticationPlatformCredentialMethod -UserId $User -PlatformCredentialAuthenticationMethodId $Id -ErrorAction Stop }
			else { throw "Removing a platform credential needs a newer Microsoft Graph module than the pinned one - remove it in the Entra admin center instead." }
		}
		default { throw "this kind of sign-in method can't be removed here." }
	}
}
function Clear-UserAuthMethods([string]$User) {
	$methods = Get-MgUserAuthenticationMethod -UserId $User -ErrorAction Stop
	$removed = 0
	foreach ($m in $methods) {
		$type = "$($m.AdditionalProperties['@odata.type'])"
		try {
			switch -Wildcard ($type) {
				'*phoneAuthenticationMethod'                  { Remove-MgUserAuthenticationPhoneMethod -UserId $User -PhoneAuthenticationMethodId $m.Id -ErrorAction Stop; $removed++ }
				'*microsoftAuthenticatorAuthenticationMethod' { Remove-MgUserAuthenticationMicrosoftAuthenticatorMethod -UserId $User -MicrosoftAuthenticatorAuthenticationMethodId $m.Id -ErrorAction Stop; $removed++ }
				'*softwareOathAuthenticationMethod'           { Remove-MgUserAuthenticationSoftwareOathMethod -UserId $User -SoftwareOathAuthenticationMethodId $m.Id -ErrorAction Stop; $removed++ }
				'*fido2AuthenticationMethod'                  { Remove-MgUserAuthenticationFido2Method -UserId $User -Fido2AuthenticationMethodId $m.Id -ErrorAction Stop; $removed++ }
				'*windowsHelloForBusinessAuthenticationMethod'{ Remove-WinHelloMethod $User $m.Id; $removed++ }
				'*emailAuthenticationMethod'                  { Remove-MgUserAuthenticationEmailMethod -UserId $User -EmailAuthenticationMethodId $m.Id -ErrorAction Stop; $removed++ }
				'*temporaryAccessPassAuthenticationMethod'    { Remove-MgUserAuthenticationTemporaryAccessPassMethod -UserId $User -TemporaryAccessPassAuthenticationMethodId $m.Id -ErrorAction Stop; $removed++ }
				default { }   # passwordAuthenticationMethod / anything unknown: leave alone
			}
		} catch { Write-Host "  couldn't remove $type for $User`: $($_.Exception.Message)" -ForegroundColor Yellow }
	}
	return $removed
}

# Summarize a bulk account-creation run: what was created vs what failed (with reason), by
# name, so it's clear which rows to re-check. $Created / $Failed are string lists. One bad row
# no longer aborts the batch - it's caught, recorded here, and the run continues.
function Show-AccountResults([string]$What, $Created, $Failed, [switch]$Preview, [string]$DoneWord = 'Created', [string]$FailWord = 'Failed') {
	$c = @($Created); $f = @($Failed)
	$doneLabel = if ($Preview) { 'Would ' + $DoneWord.ToLower() } else { $DoneWord }
	$failLabel = if ($Preview) { 'Would skip / fail' } else { $FailWord }
	$parts = @()
	if ($c.Count) { $parts += "$doneLabel ($($c.Count)):`n  " + ($c -join "`n  ") }
	if ($f.Count) { $parts += "$failLabel ($($f.Count)):`n  " + ($f -join "`n  ") }
	if (-not $parts.Count) { $parts += 'Nothing to do - the template had no rows.' }
	# Export the summary to a CSV in Logs so it can be kept / reviewed.
	$csvPath = ''
	try {
		if (-not (Test-Path '.\Logs')) { New-Item -ItemType Directory -Path '.\Logs' | Out-Null }
		$rows = @()
		foreach ($n in $c) { $rows += [pscustomobject]@{ Name = $n; Result = $doneLabel; Detail = '' } }
		foreach ($n in $f) {
			$name = $n; $detail = ''
			$dash = $n.IndexOf(' - ')
			if ($dash -ge 0) { $name = $n.Substring(0, $dash); $detail = $n.Substring($dash + 3) }
			$rows += [pscustomobject]@{ Name = $name; Result = $failLabel; Detail = $detail }
		}
		if ($rows.Count) {
			$safe = ($What -replace '[^A-Za-z0-9]+', '-').Trim('-')
			$csvPath = ".\Logs\$safe-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
			$rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
		}
	} catch { $csvPath = '' }
	if ($csvPath) { $parts += "Saved a copy to:`n  $csvPath" }
	$title = if ($Preview) { "$What - preview" } else { "$What complete" }
	Write-Host "${title}: done/would=$($c.Count) failed/skip=$($f.Count). CSV: $csvPath" -ForegroundColor Cyan
	$kind = if ($f.Count) { 'Warn' } else { 'Info' }
	$progressBar1.Value = 100
	Show-Notice $title ($parts -join "`n`n") $kind
	$progressBar1.Value = 0
	# Every per-row failure is already in this summary. Bulk handlers catch their rows (which still lands
	# the error in the automatic $Error), so clear it here - otherwise the NEXT action's CheckForErrors
	# would pop a dialog full of this run's already-reported errors.
	$Error.Clear()
}

# Refuse to create over an existing account. These throw a clear "already exists" message
# (caught by the per-row handler, recorded in the summary) BEFORE any New-ADUser / New-MgUser
# runs, so an existing user is never overwritten / re-provisioned / password-reset.
function Assert-ADUserNotExists([string]$SamAccountName, [string]$UserPrincipalName) {
	$existing = $null
	try { $existing = Get-ADUser -Filter "SamAccountName -eq '$($SamAccountName -replace "'", "''")'" -ErrorAction Stop | Select-Object -First 1 } catch { $existing = $null }
	if ($existing) { throw "an AD account named '$SamAccountName' already exists - skipped so it isn't overwritten" }
	if ($UserPrincipalName) {
		$byUpn = $null
		try { $byUpn = Get-ADUser -Filter "UserPrincipalName -eq '$($UserPrincipalName -replace "'", "''")'" -ErrorAction Stop | Select-Object -First 1 } catch { $byUpn = $null }
		if ($byUpn) { throw "an AD account with sign-in name '$UserPrincipalName' already exists - skipped so it isn't overwritten" }
	}
}
function Assert-MgUserNotExists([string]$UserPrincipalName) {
	$u = $null
	try { $u = Get-MgUser -Filter "userPrincipalName eq '$($UserPrincipalName -replace "'", "''")'" -ErrorAction Stop | Select-Object -First 1 } catch { $u = $null }
	if (-not $u) { try { $u = Get-MgUser -Filter "mail eq '$($UserPrincipalName -replace "'", "''")'" -ErrorAction Stop | Select-Object -First 1 } catch { $u = $null } }
	if ($u) { throw "an account with the email '$UserPrincipalName' already exists in the tenant - skipped so it isn't overwritten" }
}

function New-BlockUserDialog {
	New-StyledDialog -Title 'Block-User' -Icon '&#xEEE3;' -BodyXaml @'
<StackPanel Margin="16" Width="360">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<TextBlock Text="User" Style="{DynamicResource H3}"/>
			<Grid Margin="0,12,0,0">
				<Grid.ColumnDefinitions>
					<ColumnDefinition Width="100"/><ColumnDefinition Width="*"/>
				</Grid.ColumnDefinitions>
				<Grid.RowDefinitions>
					<RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
				</Grid.RowDefinitions>
				<TextBlock Text="Email" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
				<TextBox x:Name="EmailInput" Grid.Column="1"/>
				<TextBlock Text="AD Username" Style="{DynamicResource Dim}" Grid.Row="1" VerticalAlignment="Center" Margin="0,8,0,0"/>
				<TextBox x:Name="AdNameInput" Grid.Row="1" Grid.Column="1" Margin="0,8,0,0"/>
			</Grid>
		</StackPanel>
	</Border>
	<Border Style="{DynamicResource Card}" Margin="0,12,0,0">
		<StackPanel>
			<TextBlock Text="Options" Style="{DynamicResource H3}"/>
			<CheckBox x:Name="EmailCheck" Content="Block Email" IsChecked="True" Margin="0,12,0,0"/>
			<StackPanel x:Name="EmailOptionsPanel" Margin="24,8,0,0">
				<CheckBox x:Name="AddMembersCheck" Content="Add Members" IsChecked="True"/>
				<CheckBox x:Name="AddAutoReplyCheck" Content="Add Auto-Reply" Margin="0,6,0,0"/>
			</StackPanel>
			<CheckBox x:Name="AdCheck" Content="Block AD" IsChecked="True" Margin="0,10,0,0"/>
		</StackPanel>
	</Border>
	<Button x:Name="BlockBtn" Style="{DynamicResource BtnDanger}" Content="Block" Margin="0,14,0,0"/>
</StackPanel>
'@
}

function New-BlockAddMemberDialog {
	New-StyledDialog -Title 'Give someone access to the mailbox' -Icon '&#xEDBB;' -BodyXaml @'
<StackPanel Margin="16" Width="360">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<TextBlock x:Name="AddMemberHint" Style="{DynamicResource Small}" TextWrapping="Wrap" Margin="0,0,0,10" Text="Add a person who should get Full Access + Send As to this mailbox, then click Add - the box clears and asks again for the next one, showing who's been added so far. Click Done / Skip when you're finished (or if you don't want to add anyone)."/>
			<Grid>
				<Grid.ColumnDefinitions>
					<ColumnDefinition Width="70"/><ColumnDefinition Width="*"/>
				</Grid.ColumnDefinitions>
				<TextBlock Text="Member" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
				<TextBox x:Name="AddMemberBox" Grid.Column="1"/>
			</Grid>
			<Grid Margin="0,14,0,0">
				<Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
				<Button x:Name="AddMemberDoneBtn" Style="{DynamicResource BtnSecondary}" Content="Done / Skip"/>
				<Button x:Name="AddMemberBtn" Style="{DynamicResource BtnPrimary}" Content="Add" Grid.Column="2" IsDefault="True"/>
			</Grid>
		</StackPanel>
	</Border>
</StackPanel>
'@
}

function New-BlockAutoReplyDialog {
	$win = New-StyledDialog -Title 'Add Auto-Reply' -Icon '&#xEBBC;' -BodyXaml @'
<StackPanel Margin="16" Width="480">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<Grid>
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

function Block-User {
	# Don't gate the whole dialog on AD: you can block EMAIL only (no AD tools needed). AD availability
	# is checked below, only when "Block AD" is actually ticked.
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Block-User.txt"
	Write-Host "Running Block-User script..."
	$progressBar1.Value = 10
	function OnBlockButtonClick {
		Write-Host "Block button clicked."
		$progressBar1.Value = 10
		if ($adCheckBox.IsChecked -eq $true) {
			if (Test-ADModule) {
				$progressBar1.Value = 20
				$samAccountName = $adNameInputBox.Text
				Disable-ADAccount -Identity $samAccountName
				Write-Host "Disabled $samAccountName. If there are any errors on this point then $samAccountName may not exist."
				$progressBar1.Value = 30
				CheckForErrors
			} else {
				Show-Notice 'Active Directory not available' $script:ADMissingMsg 'Warn'
			}
		}
		if ($emailCheckBox.IsChecked -eq $true) {
			$user = $emailInputBox.Text
			Set-Mailbox -Identity $user -Type Shared
			Write-Host "`nConverted $user to shared mailbox" -ForegroundColor Cyan
			$progressBar1.Value = 40
			$passwordMethod = Get-MgUserAuthenticationPasswordMethod -UserId $user
			Reset-MgUserAuthenticationMethodPassword -UserId $user -AuthenticationMethodId $passwordMethod.Id | Out-Null
			Write-Host "Reset password for $user" -ForegroundColor Cyan
			$progressBar1.Value = 50
			Revoke-MgUserSignInSession -UserId $user | Out-Null
			Write-Host "Revoked $user's sessions."
			Update-MgUser -UserId $user -AccountEnabled:$false
			Write-Host "Disabled $user account" -ForegroundColor Cyan
			$progressBar1.Value = 60
			Remove-UserLicenses $user
			$progressBar1.Value = 70
			try {
				$cleared = Clear-UserAuthMethods $user
				if ($cleared -gt 0) { Write-Host "Removed $cleared MFA method(s) from $user" -ForegroundColor Cyan } else { Write-Host "$user has no MFA methods to remove" -ForegroundColor Cyan }
			} catch { Write-Host "Couldn't clear MFA methods for $user`: $($_.Exception.Message)" -ForegroundColor Yellow }
			$progressBar1.Value = 80
			CheckForErrors
			if ($addMembersCheckBox.IsChecked -eq $true) {
				Write-Host "addMembersCheckBox is checked, loading AddMember form..."
				function OnAddMemberButtonClick {
					$names = @($addMemberBox.Text -split '[;,\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
					if (-not $names.Count) { return }
					foreach ($who in $names) {
						try {
							Add-MailboxPermission -Identity $user -User $who -AccessRights FullAccess -InheritanceType All -AutoMapping $true -ErrorAction Stop | Out-Null
							Add-RecipientPermission -Identity $user -Trustee $who -AccessRights SendAs -Confirm:$false -ErrorAction Stop | Out-Null
							Write-Host "Gave $who access (FullAccess + SendAs) to $user." -ForegroundColor Cyan
							if (-not ($addedAll -contains $who)) { [void]$addedAll.Add($who) }
						} catch { Write-Host "Couldn't give $who access to $user`: $($_.Exception.Message)" -ForegroundColor Yellow }
					}
					$addMemberBox.Text = ""
					if ($addedAll.Count) { $addMemberHint.Text = "Added so far ($($addedAll.Count)): $($addedAll -join ', ').`nAdd the next person below, or click Done when you're finished." }
					try { $addMemberBox.Focus() } catch {}
				}

				$addedAll = [System.Collections.Generic.List[string]]::new()
				$AddMemberForm = New-BlockAddMemberDialog
				$addMemberBox = $AddMemberForm.FindName('AddMemberBox')
				$addMemberHint = $AddMemberForm.FindName('AddMemberHint')
				Enable-RecipientAutocomplete $addMemberBox 'User'
				Set-FieldWatermark $addMemberBox 'Email address'
				$AddMemberForm.FindName('AddMemberBtn').Add_Click({ OnAddMemberButtonClick })
				$AddMemberForm.FindName('AddMemberDoneBtn').Add_Click({ $AddMemberForm.Close() })
				Write-Host "Loaded AddMemberForm."
				[void]$AddMemberForm.ShowDialog()
			}
			if ($addAutoReplyCheckBox.IsChecked -eq $true) {
				Write-Host "addAutoReplyCheckBox is checked, loading AddAutoReply form..."

				function OnConfirmAutoReplyButtonClick {
					Write-Host "ConfirmAutoReplyButton clicked, adding auto-replies..."
					$internalMessage = $internalReplyTextBox.Text
					$externalMessage = $externalReplyTextBox.Text

					if ($useScheduleCheckBox.IsChecked -eq $true) {
						Write-Host "Use schedule is checked, creating auto-reply with schedule..."
						$startTime = $startDatePicker.SelectedDate
						$endTime = $endDatePicker.SelectedDate
						$schedErr = Test-AutoReplySchedule $startTime $endTime
						if ($schedErr) { Show-Notice 'Check the dates' $schedErr 'Warn'; return }
						Set-MailboxAutoReplyConfiguration -Identity $user -AutoReplyState Scheduled -StartTime $startTime -EndTime $endTime -InternalMessage $internalMessage -ExternalMessage $externalMessage -ExternalAudience All -Confirm:$false
					}
					else {
						Write-Host "Use schedule isn't checked, creating auto-reply..."
						Set-MailboxAutoReplyConfiguration -Identity $user -AutoReplyState Enabled -InternalMessage $internalMessage -ExternalMessage $externalMessage -ExternalAudience All -Confirm:$false
					}
					CheckForErrors
					OperationComplete
					$addAutoReplyForm.Close()
				}

				$addAutoReplyForm = New-BlockAutoReplyDialog
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
				$addAutoReplyForm.FindName('ConfirmBtn').Add_Click({ OnConfirmAutoReplyButtonClick })

				[void]$addAutoReplyForm.ShowDialog()
			}
		}
		$emailInputBox.Text = ""
		$adNameInputBox.Text = ""
		Write-Host "`nFinished blocking $user." -ForegroundColor Cyan
		CheckForErrors
		OperationComplete
	}

	$ScriptForm2 = New-BlockUserDialog
	$emailInputBox = $ScriptForm2.FindName('EmailInput')
	Enable-RecipientAutocomplete $emailInputBox 'Mailbox'
	$adNameInputBox = $ScriptForm2.FindName('AdNameInput')
	Enable-ADUserAutocomplete $adNameInputBox
	$emailCheckBox = $ScriptForm2.FindName('EmailCheck')
	$adCheckBox = $ScriptForm2.FindName('AdCheck')
	$emailOptionsPanel = $ScriptForm2.FindName('EmailOptionsPanel')
	$addMembersCheckBox = $ScriptForm2.FindName('AddMembersCheck')
	$addAutoReplyCheckBox = $ScriptForm2.FindName('AddAutoReplyCheck')

	$emailInputBox.Add_TextChanged({
		$email = $emailInputBox.Text
		$splitEmail = $email -split "@"
		$adNameInputBox.Text = $splitEmail[0]
	})
	$onEmailCheck = {
		if ($emailCheckBox.IsChecked -eq $true) {
			$emailInputBox.IsEnabled = $true
			$emailOptionsPanel.IsEnabled = $true
			$addMembersCheckBox.IsEnabled = $true
			$addAutoReplyCheckBox.IsEnabled = $true
		} elseif ($emailCheckBox.IsChecked -eq $false) {
			$emailInputBox.IsEnabled = $false
			$emailOptionsPanel.IsEnabled = $false
			$addMembersCheckBox.IsEnabled = $false
			$addAutoReplyCheckBox.IsEnabled = $false
		}
	}
	$emailCheckBox.Add_Checked($onEmailCheck)
	$emailCheckBox.Add_Unchecked($onEmailCheck)
	$onAdCheck = {
		if ($adCheckBox.IsChecked -eq $true) {
			$adNameInputBox.IsEnabled = $true
		} elseif ($adCheckBox.IsChecked -eq $false) {
			$adNameInputBox.IsEnabled = $false
		}
	}
	$adCheckBox.Add_Checked($onAdCheck)
	$adCheckBox.Add_Unchecked($onAdCheck)
	$ScriptForm2.FindName('BlockBtn').Add_Click({ OnBlockButtonClick })

	$progressBar1.Value = 0
	Write-Host "Loaded ScriptForm2."
	CheckForErrors

	[void]$ScriptForm2.ShowDialog()

	Stop-Transcript
}

# ---------------------------------------------------------------------------
function New-ClearRecycleBinDialog {
	New-StyledDialog -Title 'Clear-RecycleBin' -Icon '&#xE66D;' -BodyXaml @'
<StackPanel Margin="16" Width="320">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<StackPanel Orientation="Horizontal">
				<TextBlock Text="&#xF561;" Style="{DynamicResource Icon}" Foreground="{DynamicResource WarnBrush}" VerticalAlignment="Top" Margin="0,2,0,0"/>
				<TextBlock Style="{DynamicResource Body}" Margin="10,0,0,0" MaxWidth="240"
						   Text="Clears all contents of all recycle bins on this computer."
						   ToolTip="On a terminal server this will empty everyone's recycle bins."/>
			</StackPanel>
			<Border Style="{DynamicResource Divider}"/>
			<CheckBox x:Name="ConfirmationCheck" Content="I understand what this does."/>
			<Button x:Name="ClearBinsBtn" Style="{DynamicResource BtnDanger}" Content="Clear Recycle Bins"
					Margin="0,14,0,0" IsEnabled="False"/>
		</StackPanel>
	</Border>
</StackPanel>
'@
}

function Clear-RecycleBin {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Clear-RecycleBin.txt"
	Write-Host "Running Clear-RecycleBin script..."
	$progressBar1.Value = 10

	$scriptForm11 = New-ClearRecycleBinDialog
	$confirmationCheckBox = $scriptForm11.FindName('ConfirmationCheck')
	$clearBinsButton = $scriptForm11.FindName('ClearBinsBtn')
	$clearBinsButton.Add_Click({
		$progressBar1.Value = 30
		Remove-Item -Path "C:\`$Recycle.Bin\*" -Recurse -Force
		$progressBar1.Value = 90
		CheckForErrors
		OperationComplete
	})
	$onConfirm = {
		if ($confirmationCheckBox.IsChecked) {
			Write-Host "Confirmation box checked."
			$clearBinsButton.IsEnabled = $true
		} else {
			Write-Host "Confirmation box unchecked."
			$clearBinsButton.IsEnabled = $false
		}
	}
	$confirmationCheckBox.Add_Checked($onConfirm)
	$confirmationCheckBox.Add_Unchecked($onConfirm)

	Write-Host "Loaded ScriptForm11."
	$progressBar1.Value = 0

	[void]$scriptForm11.ShowDialog()

	Stop-Transcript
}

# ---------------------------------------------------------------------------
# Convert between a Microsoft 365 group, a distribution list and a shared mailbox.
# User-facing type names are ALWAYS the full names below - never abbreviations -
# and these same strings are the From/To values and the CSV column values.
$script:ConvNote = ''

# Which "To" types are valid for a given "From" type.
function Get-ConvTargets([string]$From) {
	switch ($From) {
		'Microsoft 365 group' { ,@('distribution list') }
		'distribution list'   { ,@('Microsoft 365 group', 'shared mailbox') }
		'shared mailbox'      { ,@('distribution list') }
		default               { ,@() }
	}
}

# One plain-English summary plus "what stays" / "what's lost" for a From -> To pair.
function Get-ConvPairInfo([string]$From, [string]$To) {
	if ($From -eq 'Microsoft 365 group' -and $To -eq 'distribution list') {
		return @{
			Summary = 'Rebuilds this Microsoft 365 group as a plain distribution list with the same members and owners, so email still reaches everyone.'
			Stays   = @('The members and owners', 'The email address (when you move it)')
			Lost    = @('Group conversations and the shared inbox', "The group's files and SharePoint site", 'Planner plans', 'Any connected Team')
		}
	}
	if ($From -eq 'shared mailbox' -and $To -eq 'distribution list') {
		return @{
			Summary = 'Creates a distribution list whose members are the people who can use this shared mailbox today, so email is delivered straight to their own inboxes.'
			Stays   = @('Everyone with Full Access or Send As becomes a member', 'The email address (when you move it)')
			Lost    = @('The existing mail, calendar and contacts are NOT copied - they stay in the old renamed mailbox, so export them first if you need them', 'A single shared inbox everyone opens (a distribution list only forwards email)', 'People with Send on behalf only')
		}
	}
	if ($From -eq 'distribution list' -and $To -eq 'Microsoft 365 group') {
		return @{
			Summary = 'Turns this distribution list into a Microsoft 365 group, which adds a shared inbox, calendar and files on top of the mailing-list behaviour.'
			Stays   = @('The members and owners', 'The email address (when you move it)', 'Everyone still gets email in their own inbox')
			Lost    = @('Moderation and delivery restrictions', 'Send on behalf permissions', 'Nested lists - the people inside them are added individually')
		}
	}
	if ($From -eq 'distribution list' -and $To -eq 'shared mailbox') {
		return @{
			Summary = 'Creates a shared mailbox and gives everyone in this distribution list access to it, so they share one inbox instead of each getting their own copy.'
			Stays   = @('The members get Full Access (and Send As when you choose it)', 'The email address (when you move it)')
			Lost    = @('Past emails - a distribution list keeps no copy to move', 'Moderation and delivery restrictions', "Contacts and guests in the list (they can't open a mailbox)")
		}
	}
	return $null
}

# True when the recipient's real type matches the chosen "From" type.
function Test-ConvSourceType($Rec, [string]$From) {
	$rtd = "$($Rec.RecipientTypeDetails)"
	switch ($From) {
		'Microsoft 365 group' { return ($rtd -eq 'GroupMailbox') }
		'shared mailbox'      { return ($rtd -eq 'SharedMailbox') }
		'distribution list'   { return ($rtd -match 'MailUniversalDistributionGroup|MailUniversalSecurityGroup|MailNonUniversalGroup|RoomList|DynamicDistributionGroup') }
		default               { return $false }
	}
}

# The signed-in admin's address, used as a fallback owner when a list has none.
function Get-ConvAdminUpn {
	try { $c = Get-ConnectionInformation -ErrorAction Stop | Select-Object -First 1; if ($c) { return "$($c.UserPrincipalName)" } } catch {}
	try { if ($script:ActiveTenant -and $script:ActiveTenant.account) { return "$($script:ActiveTenant.account)" } } catch {}
	return $null
}

# Undo Move-ConvAddressAway. Identified by the object's immutable Guid so a half-renamed item is
# still found. Returns $true only when the original address/name are fully back in place.
function Restore-ConvAddress($R) {
	if (-not $R) { return $true }
	try {
		$guid = $R.Guid
		switch ($R.From) {
			'Microsoft 365 group' {
				try { Set-UnifiedGroup -Identity $guid -EmailAddresses @{ Add = $R.Addr } -ErrorAction Stop } catch {}
				Set-UnifiedGroup -Identity $guid -PrimarySmtpAddress $R.Addr -ErrorAction Stop
				Set-UnifiedGroup -Identity $guid -EmailAddresses @{ Remove = $R.OldAddr } -HiddenFromAddressListsEnabled $false -DisplayName $R.Display -Alias $R.OrigAlias -ErrorAction Stop
			}
			'distribution list' {
				try { Set-DistributionGroup -Identity $guid -EmailAddresses @{ Add = $R.Addr } -ErrorAction Stop } catch {}
				Set-DistributionGroup -Identity $guid -PrimarySmtpAddress $R.Addr -ErrorAction Stop
				Set-DistributionGroup -Identity $guid -EmailAddresses @{ Remove = $R.OldAddr } -HiddenFromAddressListsEnabled $false -DisplayName $R.Display -Name $R.OrigName -Alias $R.OrigAlias -ErrorAction Stop
			}
			'shared mailbox' {
				try { Set-Mailbox -Identity $guid -EmailAddresses @{ Add = $R.Addr } -ErrorAction Stop } catch {}
				Set-Mailbox -Identity $guid -PrimarySmtpAddress $R.Addr -ErrorAction Stop
				Set-Mailbox -Identity $guid -EmailAddresses @{ Remove = $R.OldAddr } -HiddenFromAddressListsEnabled $false -DisplayName $R.Display -Name $R.OrigName -Alias $R.OrigAlias -ErrorAction Stop
			}
		}
		Write-Host "Put things back the way they were for $($R.Addr)." -ForegroundColor Yellow
		return $true
	} catch {
		Write-Host "Couldn't fully undo the address move for $($R.Addr): $($_.Exception.Message)" -ForegroundColor Red
		return $false
	}
}

# Move the real email address off the OLD item onto a renamed, hidden "-old" item, so the NEW item
# can take the real address, name and alias. $RenameBase is the local-part/alias the old item is
# renamed to. Every step after the first is wrapped: on failure the move is rolled back, then it
# rethrows (or rethrows a plain "ADDRESS NOT RESTORED" message if the rollback itself failed).
function Move-ConvAddressAway($Rec, [string]$From, [string]$RenameBase) {
	$addr = "$($Rec.PrimarySmtpAddress)"
	$parts = $addr -split '@', 2
	$base = if ("$RenameBase".Trim()) { "$RenameBase".Trim() } else { $parts[0] + '-old' }
	$oldAddr = "$base@$($parts[1])"
	$display = "$($Rec.DisplayName)"
	$guid = "$($Rec.ExchangeObjectId)"; if (-not $guid) { $guid = "$($Rec.Guid)" }
	$record = @{ From = $From; Addr = $addr; OldAddr = $oldAddr; Display = $display; Guid = $guid; OrigName = "$($Rec.Name)"; OrigAlias = "$($Rec.Alias)" }
	# Step 1 - add the new alias. If this fails nothing has changed, so just let it throw.
	switch ($From) {
		'Microsoft 365 group' { Set-UnifiedGroup -Identity $guid -EmailAddresses @{ Add = $oldAddr } -ErrorAction Stop }
		'distribution list'   { Set-DistributionGroup -Identity $guid -EmailAddresses @{ Add = $oldAddr } -ErrorAction Stop }
		'shared mailbox'      { Set-Mailbox -Identity $guid -EmailAddresses @{ Add = $oldAddr } -ErrorAction Stop }
	}
	try {
		switch ($From) {
			'Microsoft 365 group' {
				Set-UnifiedGroup -Identity $guid -PrimarySmtpAddress $oldAddr -ErrorAction Stop
				Set-UnifiedGroup -Identity $guid -EmailAddresses @{ Remove = $addr } -HiddenFromAddressListsEnabled $true -DisplayName "$display (old)" -Alias $base -ErrorAction Stop
			}
			'distribution list' {
				Set-DistributionGroup -Identity $guid -PrimarySmtpAddress $oldAddr -ErrorAction Stop
				Set-DistributionGroup -Identity $guid -EmailAddresses @{ Remove = $addr } -HiddenFromAddressListsEnabled $true -DisplayName "$display (old)" -Name $base -Alias $base -ErrorAction Stop
			}
			'shared mailbox' {
				Set-Mailbox -Identity $guid -PrimarySmtpAddress $oldAddr -ErrorAction Stop
				Set-Mailbox -Identity $guid -EmailAddresses @{ Remove = $addr } -HiddenFromAddressListsEnabled $true -DisplayName "$display (old)" -Name $base -Alias $base -ErrorAction Stop
			}
		}
	} catch {
		$orig = "$($_.Exception.Message)"
		$restored = Restore-ConvAddress $record
		if (-not $restored) { throw "ADDRESS NOT RESTORED - $addr may now be on neither item; check $oldAddr in the admin center." }
		throw $orig
	}
	return $record
}

# Create the new item, retrying when Exchange hasn't yet freed the moved address (up to 6 tries,
# 10 s apart). Only retries errors that mention the address/alias/proxy being in use or the object
# not being found yet; repaints "Waiting for Exchange to free <address>..." before each wait.
function Invoke-ConvCreate([scriptblock]$Create, [string]$Address) {
	for ($try = 1; $try -le 6; $try++) {
		try { return (& $Create) }
		catch {
			$m = "$($_.Exception.Message)"
			if ($try -lt 6 -and ($m -match 'address|proxy|alias|already|in use|not found|could not be found|couldn''t be found')) {
				Set-ItemStatus "Waiting for Exchange to free $Address... (try $try of 6)"
				Update-UiNow $true
				Start-Sleep -Seconds 10
			} else { throw }
		}
	}
}

# Give the new item the old item's LegacyExchangeDN as an X500 address, so replies from cached
# Outlook addresses still work. Logs and carries on if it fails. $Type is the NEW item's type.
function Add-ConvX500([string]$Type, $NewIdentity, [string]$LegacyDn) {
	if (-not "$LegacyDn".Trim()) { return }
	try {
		switch ($Type) {
			'distribution list'   { Set-DistributionGroup -Identity $NewIdentity -EmailAddresses @{ Add = "X500:$LegacyDn" } -ErrorAction Stop }
			'Microsoft 365 group' { Set-UnifiedGroup -Identity $NewIdentity -EmailAddresses @{ Add = "X500:$LegacyDn" } -ErrorAction Stop }
			'shared mailbox'      { Set-Mailbox -Identity $NewIdentity -EmailAddresses @{ Add = "X500:$LegacyDn" } -ErrorAction Stop }
		}
	} catch { Write-Host "  couldn't add the old X500 address to the new item: $($_.Exception.Message)" -ForegroundColor Yellow }
}

# Expand a distribution list's members to individual people (recursing into nested lists).
function Expand-ConvListMembers([string]$Address) {
	$out = [System.Collections.Generic.List[object]]::new()
	$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	function Walk([string]$a) {
		$rows = @(Get-DistributionGroupMember -Identity $a -ResultSize Unlimited -ErrorAction SilentlyContinue)
		foreach ($r in $rows) {
			$rtd = "$($r.RecipientTypeDetails)"
			if ($rtd -match 'DistributionGroup|MailUniversalSecurityGroup|MailNonUniversalGroup') {
				Walk "$($r.PrimarySmtpAddress)"
			} else {
				$key = "$($r.PrimarySmtpAddress)"
				if ($key -and $seen.Add($key)) { [void]$out.Add($r) }
			}
		}
	}
	Walk $Address
	return $out
}

# ---- the four conversions (each returns how many member/permission/owner copies failed) ----
function Convert-M365ToDistList($Rec, [bool]$MoveAddr, [string]$RenameBase) {
	$addr = "$($Rec.PrimarySmtpAddress)"
	$alias = ($addr -split '@')[0]
	$legacy = "$($Rec.LegacyExchangeDN)"
	$members = @(Get-UnifiedGroupLinks -Identity $addr -LinkType Members -ResultSize Unlimited -ErrorAction Stop | Select-Object -ExpandProperty PrimarySmtpAddress)
	$owners  = @(Get-UnifiedGroupLinks -Identity $addr -LinkType Owners -ResultSize Unlimited -ErrorAction Stop | Select-Object -ExpandProperty PrimarySmtpAddress)
	$fails = 0
	if ($MoveAddr) {
		$restore = Move-ConvAddressAway $Rec 'Microsoft 365 group' $RenameBase
		try { $new = Invoke-ConvCreate { New-DistributionGroup -Name "$($Rec.DisplayName)" -DisplayName "$($Rec.DisplayName)" -Alias $alias -PrimarySmtpAddress $addr -ErrorAction Stop } $addr }
		catch { $orig = "$($_.Exception.Message)"; if (-not (Restore-ConvAddress $restore)) { throw "ADDRESS NOT RESTORED - $($restore.Addr) may now be on neither item; check $($restore.OldAddr) in the admin center. (Create error: $orig)" }; throw $orig }
		Add-ConvX500 'distribution list' $new.Identity $legacy
	} else {
		$new = New-DistributionGroup -Name "$alias-New" -ErrorAction Stop
	}
	foreach ($m in $members) { try { Add-DistributionGroupMember -Identity $new.Identity -Member $m -ErrorAction Stop } catch { $fails++; Write-Host "  couldn't add $m : $($_.Exception.Message)" -ForegroundColor Yellow } }
	if ($owners.Count) { try { Set-DistributionGroup -Identity $new.Identity -ManagedBy $owners -ErrorAction Stop } catch { $fails++; Write-Host "  couldn't set owners: $($_.Exception.Message)" -ForegroundColor Yellow } }
	return $fails
}

function Convert-SharedToDistList($Rec, [bool]$MoveAddr, [string]$RenameBase) {
	$addr = "$($Rec.PrimarySmtpAddress)"
	$alias = ($addr -split '@')[0]
	$legacy = "$($Rec.LegacyExchangeDN)"
	$fa = @(Get-MailboxPermission -Identity $addr -ErrorAction Stop | Where-Object { -not $_.IsInherited -and $_.User -notlike 'NT AUTHORITY*' -and $_.User -notlike 'S-1-5*' -and $_.AccessRights -contains 'FullAccess' } | Select-Object -ExpandProperty User)
	$sa = @(Get-RecipientPermission -Identity $addr -ErrorAction Stop | Where-Object { $_.AccessRights -contains 'SendAs' -and $_.Trustee -notlike 'NT AUTHORITY*' } | Select-Object -ExpandProperty Trustee)
	$people = @(@($fa) + @($sa) | Where-Object { "$_".Trim() } | Select-Object -Unique)
	$fails = 0
	if ($MoveAddr) {
		$restore = Move-ConvAddressAway $Rec 'shared mailbox' $RenameBase
		try { $new = Invoke-ConvCreate { New-DistributionGroup -Name "$($Rec.DisplayName)" -DisplayName "$($Rec.DisplayName)" -Alias $alias -PrimarySmtpAddress $addr -ErrorAction Stop } $addr }
		catch { $orig = "$($_.Exception.Message)"; if (-not (Restore-ConvAddress $restore)) { throw "ADDRESS NOT RESTORED - $($restore.Addr) may now be on neither item; check $($restore.OldAddr) in the admin center. (Create error: $orig)" }; throw $orig }
		Add-ConvX500 'distribution list' $new.Identity $legacy
	} else {
		$new = New-DistributionGroup -Name "$alias-New" -ErrorAction Stop
	}
	foreach ($p in $people) { try { Add-DistributionGroupMember -Identity $new.Identity -Member $p -ErrorAction Stop } catch { $fails++; Write-Host "  couldn't add $p : $($_.Exception.Message)" -ForegroundColor Yellow } }
	return $fails
}

function Convert-DistListToM365($Rec, [bool]$MoveAddr, [string]$RenameBase) {
	$addr = "$($Rec.PrimarySmtpAddress)"
	$alias = ($addr -split '@')[0]
	$legacy = "$($Rec.LegacyExchangeDN)"
	$dl = Get-DistributionGroup -Identity $addr -ErrorAction Stop
	$owners = @($dl.ManagedBy)
	$people = @(Expand-ConvListMembers $addr | Select-Object -ExpandProperty PrimarySmtpAddress | Where-Object { "$_".Trim() } | Select-Object -Unique)
	$ownerAddrs = @($owners | ForEach-Object { try { (Get-Recipient -Identity $_ -ErrorAction Stop | Select-Object -First 1).PrimarySmtpAddress } catch {} } | Where-Object { "$_".Trim() })
	$usedAdmin = $false
	if (-not $ownerAddrs.Count) { $me = Get-ConvAdminUpn; if ($me) { $ownerAddrs = @($me); $usedAdmin = $true } }
	$fails = 0
	if ($MoveAddr) {
		$restore = Move-ConvAddressAway $Rec 'distribution list' $RenameBase
		try { $new = Invoke-ConvCreate { New-UnifiedGroup -DisplayName "$($Rec.DisplayName)" -Alias $alias -PrimarySmtpAddress $addr -AccessType Private -ErrorAction Stop } $addr }
		catch { $orig = "$($_.Exception.Message)"; if (-not (Restore-ConvAddress $restore)) { throw "ADDRESS NOT RESTORED - $($restore.Addr) may now be on neither item; check $($restore.OldAddr) in the admin center. (Create error: $orig)" }; throw $orig }
		$newId = $addr
		Add-ConvX500 'Microsoft 365 group' $newId $legacy
	} else {
		$new = New-UnifiedGroup -DisplayName "$($Rec.DisplayName)" -Alias "$alias-New" -AccessType Private -ErrorAction Stop
		$newId = "$($new.PrimarySmtpAddress)"
	}
	foreach ($m in $people) { try { Add-UnifiedGroupLinks -Identity $newId -LinkType Members -Links $m -ErrorAction Stop } catch { $fails++; Write-Host "  couldn't add $m : $($_.Exception.Message)" -ForegroundColor Yellow } }
	foreach ($o in $ownerAddrs) { try { Add-UnifiedGroupLinks -Identity $newId -LinkType Owners -Links $o -ErrorAction Stop } catch { $fails++; Write-Host "  couldn't set owner $o : $($_.Exception.Message)" -ForegroundColor Yellow } }
	try { Set-UnifiedGroup -Identity $newId -AutoSubscribeNewMembers:$true -ErrorAction Stop } catch {}
	foreach ($m in $people) { try { Add-UnifiedGroupLinks -Identity $newId -LinkType Subscribers -Links $m -ErrorAction SilentlyContinue } catch {} }
	if ($usedAdmin) { $script:ConvNote = "The old list had no owner, so you were set as the owner of $addr." }
	return $fails
}

function Convert-DistListToShared($Rec, [bool]$MoveAddr, [bool]$SendAs, [string]$RenameBase) {
	$addr = "$($Rec.PrimarySmtpAddress)"
	$alias = ($addr -split '@')[0]
	$legacy = "$($Rec.LegacyExchangeDN)"
	$members = @(Expand-ConvListMembers $addr)
	$fails = 0
	if ($MoveAddr) {
		$restore = Move-ConvAddressAway $Rec 'distribution list' $RenameBase
		try { $new = Invoke-ConvCreate { New-Mailbox -Shared -Name "$($Rec.DisplayName)" -DisplayName "$($Rec.DisplayName)" -Alias $alias -PrimarySmtpAddress $addr -ErrorAction Stop } $addr }
		catch { $orig = "$($_.Exception.Message)"; if (-not (Restore-ConvAddress $restore)) { throw "ADDRESS NOT RESTORED - $($restore.Addr) may now be on neither item; check $($restore.OldAddr) in the admin center. (Create error: $orig)" }; throw $orig }
		Add-ConvX500 'shared mailbox' $new.Identity $legacy
	} else {
		$new = New-Mailbox -Shared -Name "$alias-New" -DisplayName "$($Rec.DisplayName)" -Alias "$alias-New" -ErrorAction Stop
	}
	# Wait for the new mailbox to show up before granting access.
	$mbx = $null; $deadline = (Get-Date).AddMinutes(2)
	while ((Get-Date) -lt $deadline) {
		try { $mbx = Get-Mailbox -Identity $new.Identity -ErrorAction Stop; if ($mbx) { break } } catch {}
		Set-ItemStatus "Waiting for Exchange to create the shared mailbox..."
		Update-UiNow $true
		Start-Sleep -Seconds 5
	}
	$target = if ($mbx) { "$($mbx.Identity)" } else { "$($new.Identity)" }
	foreach ($m in $members) {
		$rtd = "$($m.RecipientTypeDetails)"
		$who = "$($m.PrimarySmtpAddress)"
		if ($rtd -match 'Mailbox') {
			try {
				Add-MailboxPermission -Identity $target -User $who -AccessRights FullAccess -InheritanceType All -AutoMapping $true -ErrorAction Stop
				if ($SendAs) { Add-RecipientPermission -Identity $target -Trustee $who -AccessRights SendAs -Confirm:$false -ErrorAction Stop }
			} catch { $fails++; Write-Host "  couldn't give $who access: $($_.Exception.Message)" -ForegroundColor Yellow }
		} else {
			Write-Host "  skipped $who - a $(Get-RecipientTypeName $rtd) can't open a mailbox." -ForegroundColor Yellow
		}
	}
	return $fails
}

# Validate one source and run the right conversion. Returns Status + Reason.
function Convert-ConvOne([string]$Address, [string]$From, [string]$To, [bool]$MoveAddr, [bool]$SendAs, [string]$RenameBase) {
	$rec = $null
	try { $rec = Get-Recipient -Identity $Address -ErrorAction Stop | Select-Object -First 1 } catch {}
	if (-not $rec) { return @{ Status = 'skipped'; Reason = "couldn't find that address." } }
	if (-not (Test-ConvSourceType $rec $From)) {
		$actual = Get-RecipientTypeName "$($rec.RecipientTypeDetails) $($rec.RecipientType)"
		return @{ Status = 'skipped'; Reason = "that address is a $actual, not a $From." }
	}
	$rtd = "$($rec.RecipientTypeDetails)"
	# A dynamic distribution list's membership is rule-based, so it can't be converted - any direction.
	if ($rtd -match 'Dynamic') { return @{ Status = 'skipped'; Reason = "this is a dynamic distribution list, whose membership is set by a rule, so it can't be converted." } }
	if ($From -eq 'distribution list' -and $To -eq 'Microsoft 365 group') {
		if ($rtd -eq 'MailUniversalSecurityGroup') { return @{ Status = 'skipped'; Reason = "this distribution list is also a security group that may control access to files or apps, so it can't safely become a Microsoft 365 group." } }
		if ($rec.IsDirSynced) { return @{ Status = 'skipped'; Reason = "this list is managed from your on-premises server." } }
	}
	# When moving the address, make sure the renamed "-old" item's name/address isn't already taken.
	if ($MoveAddr) {
		$src = "$($rec.PrimarySmtpAddress)"; $p = $src -split '@', 2
		$base = if ("$RenameBase".Trim()) { "$RenameBase".Trim() } else { $p[0] + '-old' }
		if ($base -notmatch '^[A-Za-z0-9._-]{1,64}$') { return @{ Status = 'skipped'; Reason = "the rename '$base' isn't a valid address name - use letters, numbers, dots, dashes or underscores." } }
		$oldAddr = "$base@$($p[1])"
		$taken = $null
		try { $taken = Get-Recipient -Identity $oldAddr -ErrorAction Stop | Select-Object -First 1 } catch {}
		if (-not $taken) { try { $taken = Get-Recipient -Identity $base -ErrorAction Stop | Select-Object -First 1 } catch {} }
		if ($taken -and ("$($taken.ExchangeObjectId)" -ne "$($rec.ExchangeObjectId)")) { return @{ Status = 'skipped'; Reason = "an item named $base already exists." } }
	}
	try {
		$fails = switch ("$From|$To") {
			'Microsoft 365 group|distribution list' { Convert-M365ToDistList $rec $MoveAddr $RenameBase }
			'shared mailbox|distribution list'      { Convert-SharedToDistList $rec $MoveAddr $RenameBase }
			'distribution list|Microsoft 365 group' { Convert-DistListToM365 $rec $MoveAddr $RenameBase }
			'distribution list|shared mailbox'      { Convert-DistListToShared $rec $MoveAddr $SendAs $RenameBase }
			default { return @{ Status = 'skipped'; Reason = "can't convert a $From to a $To." } }
		}
		$fails = [int]($fails | Select-Object -Last 1)
		if ($fails -gt 0) { return @{ Status = 'done'; Reason = "converted, but $fails member(s)/permission(s) couldn't be copied (see log)" } }
		return @{ Status = 'done'; Reason = '' }
	} catch {
		return @{ Status = 'failed'; Reason = "$($_.Exception.Message)".Trim() }
	}
}

# ---------------------------------------------------------------------------
function New-ConvertMailboxOrGroupDialog {
	New-StyledDialog -Title 'Convert mailbox or group' -Icon '&#xE16F;' -BodyXaml @'
<StackPanel Margin="16" Width="420">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<TextBlock Text="Convert from" Style="{DynamicResource Dim}"/>
			<StackPanel Orientation="Horizontal" Margin="0,4,0,0">
				<RadioButton x:Name="FromM365" Style="{DynamicResource Chip}" GroupName="ConvFrom" Content="Microsoft 365 group" IsChecked="True"/>
				<RadioButton x:Name="FromDL" Style="{DynamicResource Chip}" GroupName="ConvFrom" Content="distribution list" Margin="8,0,0,0"/>
				<RadioButton x:Name="FromShared" Style="{DynamicResource Chip}" GroupName="ConvFrom" Content="shared mailbox" Margin="8,0,0,0"/>
			</StackPanel>
			<TextBlock Text="Convert to" Style="{DynamicResource Dim}" Margin="0,12,0,0"/>
			<StackPanel Orientation="Horizontal" Margin="0,4,0,0">
				<RadioButton x:Name="ToDL" Style="{DynamicResource Chip}" GroupName="ConvTo" Content="distribution list"/>
				<RadioButton x:Name="ToM365" Style="{DynamicResource Chip}" GroupName="ConvTo" Content="Microsoft 365 group" Margin="8,0,0,0"/>
				<RadioButton x:Name="ToShared" Style="{DynamicResource Chip}" GroupName="ConvTo" Content="shared mailbox" Margin="8,0,0,0"/>
			</StackPanel>
			<TextBlock x:Name="SummaryText" Style="{DynamicResource Dim}" TextWrapping="Wrap" Margin="0,12,0,0"/>
			<Border Style="{DynamicResource Card}" Margin="0,10,0,0">
				<StackPanel>
					<TextBlock x:Name="StaysText" Style="{DynamicResource Dim}" TextWrapping="Wrap"/>
					<TextBlock x:Name="LostText" Style="{DynamicResource Dim}" TextWrapping="Wrap" Margin="0,8,0,0"/>
				</StackPanel>
			</Border>
			<CheckBox x:Name="MoveAddrCheck" Content="Give the new item this email address" Margin="0,12,0,0"/>
			<TextBlock Text="The new item takes over the address; the old one is kept, renamed, and hidden from the address book. Untick to leave the old one as it is and give the new one a '-New' address. Members are copied either way." Style="{DynamicResource Dim}" TextWrapping="Wrap" Margin="0,4,0,0"/>
			<StackPanel x:Name="RenamePanel" Margin="0,8,0,0" Visibility="Collapsed">
				<TextBlock Text="Rename the old item to" Style="{DynamicResource Dim}"/>
				<TextBox x:Name="RenameOldInput" Margin="0,4,0,0"/>
			</StackPanel>
			<CheckBox x:Name="SendAsCheck" Content="Also give Send As" IsChecked="True" Visibility="Collapsed" Margin="0,6,0,0"/>
			<Border Style="{DynamicResource Divider}"/>
			<StackPanel Orientation="Horizontal">
				<RadioButton x:Name="SingleChip" Style="{DynamicResource Chip}" GroupName="ConvertMode" Content="Single" IsChecked="True"/>
				<RadioButton x:Name="BulkChip" Style="{DynamicResource Chip}" GroupName="ConvertMode" Content="Bulk" Margin="8,0,0,0"/>
			</StackPanel>
			<StackPanel x:Name="SinglePanel" Margin="0,14,0,0">
				<Grid>
					<Grid.ColumnDefinitions>
						<ColumnDefinition Width="100"/><ColumnDefinition Width="*"/>
					</Grid.ColumnDefinitions>
					<TextBlock Text="Address" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
					<TextBox x:Name="SourceInput" Grid.Column="1"/>
				</Grid>
				<Button x:Name="ConvertBtn" Style="{DynamicResource BtnPrimary}" Content="Convert" Margin="0,14,0,0"/>
			</StackPanel>
			<StackPanel x:Name="BulkPanel" Margin="0,14,0,0" Visibility="Collapsed">
				<Button x:Name="TemplateOpenBtn" Style="{DynamicResource BtnSecondary}" Content="Open template"/>
				<Button x:Name="PasteBtn" Style="{DynamicResource BtnSecondary}" Content="Paste list" Margin="0,8,0,0"/>
				<Button x:Name="ConvertBulkBtn" Style="{DynamicResource BtnPrimary}" Content="Convert all" Margin="0,8,0,0"/>
			</StackPanel>
		</StackPanel>
	</Border>
</StackPanel>
'@
}

function Convert-MailboxOrGroup {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Convert-MailboxOrGroup.txt"
	Write-Host "Running Convert-MailboxOrGroup script..."
	$progressBar1.Value = 10
	$script:ConvNote = ''
	$script:ConvSync = $false
	$script:ConvRenameEdited = $false
	$script:ConvRenameLastDefault = ''

	function Get-ConvFrom {
		if ($fromDL.IsChecked) { 'distribution list' } elseif ($fromShared.IsChecked) { 'shared mailbox' } else { 'Microsoft 365 group' }
	}
	function Get-ConvTo {
		if ($toM365.IsChecked) { 'Microsoft 365 group' } elseif ($toShared.IsChecked) { 'shared mailbox' } elseif ($toDL.IsChecked) { 'distribution list' } else { $null }
	}
	# The local-part/alias the old item will be renamed to for the typed address (default "<name>-old").
	function Get-ConvRenameBase {
		$edited = "$($renameOldInput.Text)".Trim()
		if ($edited) { return $edited }
		# No usable local-part until the address has an '@' - return '' so Convert-ConvOne builds the
		# default ("<name>-old") from the resolved PrimarySmtpAddress instead.
		$a = "$($sourceInputBox.Text)".Trim()
		if ($a -match '@') { return (($a -split '@')[0] + '-old') }
		return ''
	}
	function Set-ConvRenameDefault {
		$a = "$($sourceInputBox.Text)".Trim()
		$def = if ($a -match '@') { ($a -split '@')[0] + '-old' } else { '' }
		$script:ConvRenameLastDefault = $def
		$script:ConvRenameEdited = $false
		$renameOldInput.Text = $def
	}

	# Show only the valid targets for the chosen From, auto-select one, and refresh the text.
	function Update-ConvUi {
		if ($script:ConvSync) { return }
		$script:ConvSync = $true
		try {
			$from = Get-ConvFrom
			$targets = @(Get-ConvTargets $from)
			$toDL.Visibility     = if ($targets -contains 'distribution list')   { 'Visible' } else { 'Collapsed' }
			$toM365.Visibility   = if ($targets -contains 'Microsoft 365 group')  { 'Visible' } else { 'Collapsed' }
			$toShared.Visibility = if ($targets -contains 'shared mailbox')       { 'Visible' } else { 'Collapsed' }
			$to = Get-ConvTo
			if (-not $to -or ($targets -notcontains $to)) {
				$to = $targets[0]
				$toDL.IsChecked     = ($to -eq 'distribution list')
				$toM365.IsChecked   = ($to -eq 'Microsoft 365 group')
				$toShared.IsChecked = ($to -eq 'shared mailbox')
			}
			$info = Get-ConvPairInfo $from $to
			if ($info) {
				$summaryText.Text = $info.Summary
				$staysText.Text = "What stays:`n" + (($info.Stays | ForEach-Object { "  - $_" }) -join "`n")
				$lostText.Text  = "What's lost:`n" + (($info.Lost  | ForEach-Object { "  - $_" }) -join "`n")
			}
			# Keep the old "-New" behaviour for Microsoft 365 group -> distribution list (off by default);
			# move the address by default for the other pairs.
			$moveAddrCheck.IsChecked = ($from -ne 'Microsoft 365 group')
			$renamePanel.Visibility = if ($moveAddrCheck.IsChecked) { 'Visible' } else { 'Collapsed' }
			if ($moveAddrCheck.IsChecked) { Set-ConvRenameDefault }
			$sendAsCheck.Visibility = if ($to -eq 'shared mailbox') { 'Visible' } else { 'Collapsed' }
		} finally { $script:ConvSync = $false }
	}

	function Show-ConvSummary($Counts, $Lines) {
		$body = "Converted $($Counts.done).  Skipped $($Counts.skipped).  Failed $($Counts.failed)."
		if ($Lines.Count) { $body += "`n`n" + ($Lines -join "`n") }
		if ($script:ConvNote) { $body += "`n`n$($script:ConvNote)"; $script:ConvNote = '' }
		$kind = if ($Counts.failed) { 'Warn' } else { 'Info' }
		Show-Notice 'Conversion complete' $body $kind
		$progressBar1.Value = 0
		$Error.Clear()
	}

	# The "what happens to the old item" sentence, matching whether the address is being moved.
	function Get-ConvMoveSentence([string]$From) {
		if ($moveAddrCheck.IsChecked -eq $true) {
			$rb = Get-ConvRenameBase
			if (-not $rb) { $rb = '<name>-old' }
			return "The old $From is renamed to '$rb' and hidden from the address book. Nothing is deleted."
		}
		return "The old $From is left as it is; the new one gets a '-New' name and address."
	}

	function Run-ConvBatch($Items) {
		$list = @($Items | Where-Object { "$($_.Address)".Trim() })
		$tot = $list.Count
		if (-not $tot) { Show-Notice 'Nothing to convert' 'There were no addresses to convert.' 'Warn'; return }
		if ($moveAddrCheck.IsChecked -eq $true) { $tail = "Each old item is renamed (its address gets your rename, ending in -old by default) and hidden from the address book. Nothing is deleted." }
		else { $tail = "Each old item is left as it is; the new one gets a '-New' name and address." }
		if (-not (Confirm-YesNo 'Convert these items?' "About to convert $tot item(s).`n`n$tail`n`nContinue?" '&#xF561;')) { return }
		Reset-Throughput
		Lock-ScriptWindow $scriptForm6
		$counts = @{ done = 0; skipped = 0; failed = 0 }
		$lines = [System.Collections.Generic.List[string]]::new()
		$i = 0
		foreach ($it in $list) {
			$i++
			$addr = "$($it.Address)".Trim()
			$from = if ("$($it.From)".Trim()) { "$($it.From)".Trim() } else { Get-ConvFrom }
			$to   = if ("$($it.To)".Trim())   { "$($it.To)".Trim() }   else { Get-ConvTo }
			Step-Progress "Converting $addr to a $to..." $i $tot
			if (-not (Get-ConvPairInfo $from $to)) { $counts.skipped++; $lines.Add("$addr - skipped: can't convert a $from to a $to."); continue }
			$r = Convert-ConvOne $addr $from $to ($moveAddrCheck.IsChecked -eq $true) ($sendAsCheck.IsChecked -eq $true) ''
			switch ($r.Status) {
				'done'    { $counts.done++;    $lines.Add($(if ($r.Reason) { "$addr - $($r.Reason)" } else { "$addr - converted to a $to." })) }
				'skipped' { $counts.skipped++; $lines.Add("$addr - skipped: $($r.Reason)") }
				'failed'  { $counts.failed++;  $lines.Add("$addr - failed: $($r.Reason)") }
			}
		}
		Unlock-ScriptWindow
		Show-ConvSummary $counts $lines
		CheckForErrors
		OperationComplete
	}

	function OnConvertButtonClick {
		$addr = "$($sourceInputBox.Text)".Trim()
		if (-not $addr) { Show-Notice 'Missing address' 'Type an address to convert first.' 'Warn'; return }
		$from = Get-ConvFrom; $to = Get-ConvTo
		$info = Get-ConvPairInfo $from $to
		if (-not $info) { Show-Notice "Can't convert that" "Can't convert a $from to a $to." 'Warn'; return }
		$warn = "$($info.Summary)`n`nWhat's lost:`n" + (($info.Lost | ForEach-Object { "  - $_" }) -join "`n") + "`n`n$(Get-ConvMoveSentence $from)`n`nConvert now?"
		if (-not (Confirm-YesNo 'Convert now?' $warn '&#xF561;')) { return }
		Reset-Throughput
		Lock-ScriptWindow $scriptForm6
		$progressBar1.Value = 20
		Set-ItemStatus "Converting $addr to a $to..."
		Update-UiNow $true
		$r = Convert-ConvOne $addr $from $to ($moveAddrCheck.IsChecked -eq $true) ($sendAsCheck.IsChecked -eq $true) (Get-ConvRenameBase)
		$progressBar1.Value = 100
		Unlock-ScriptWindow
		$counts = @{ done = 0; skipped = 0; failed = 0 }
		$lines = [System.Collections.Generic.List[string]]::new()
		switch ($r.Status) {
			'done'    { $counts.done = 1;    $lines.Add($(if ($r.Reason) { "$addr - $($r.Reason)" } else { "$addr - converted to a $to." })) }
			'skipped' { $counts.skipped = 1; $lines.Add("$addr - skipped: $($r.Reason)") }
			'failed'  { $counts.failed = 1;  $lines.Add("$addr - failed: $($r.Reason)") }
		}
		Show-ConvSummary $counts $lines
		CheckForErrors
		OperationComplete
	}

	function OnTemplateButtonClick {
		Write-Host "Open template button clicked."
		$csv = ".\Templates\Convert-MailboxOrGroup.csv"
		if (-not (Test-Path $csv)) { "Source address,From,To" | Out-File $csv -Encoding UTF8 }
		Invoke-Item $csv
		$progressBar1.Value = 0
		CheckForErrors
	}

	function OnConvertBulkButtonClick {
		Write-Host "Convert all (template) button clicked."
		$csv = ".\Templates\Convert-MailboxOrGroup.csv"
		if (-not (Test-Path $csv)) { Show-Notice 'No template' 'Use Open template to create the CSV first.' 'Warn'; return }
		$rows = @(Import-Csv $csv | Where-Object { "$($_.'Source address')".Trim() })
		if (-not $rows.Count) { Show-Notice 'Empty template' 'The template has no rows.' 'Warn'; return }
		$items = @($rows | ForEach-Object { @{ Address = "$($_.'Source address')".Trim(); From = "$($_.From)".Trim(); To = "$($_.To)".Trim() } })
		Run-ConvBatch $items
	}

	function OnPasteButtonClick {
		$pwin = New-StyledDialog -Title 'Paste a list of addresses' -Icon '&#xED75;' -BodyXaml @'
<StackPanel Margin="16" Width="380">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<TextBlock Text="One address per line. They'll all be converted using the From and To you picked above." Style="{DynamicResource Dim}" TextWrapping="Wrap" Margin="0,0,0,6"/>
			<TextBox x:Name="PasteBox" Style="{DynamicResource TextArea}" Height="150" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"/>
			<Grid Margin="0,12,0,0">
				<Button x:Name="PasteCancel" Style="{DynamicResource BtnGhost}" Content="Cancel" HorizontalAlignment="Left" MinWidth="90"/>
				<Button x:Name="PasteGo" Style="{DynamicResource BtnPrimary}" Content="Convert all" HorizontalAlignment="Right" MinWidth="120"/>
			</Grid>
		</StackPanel>
	</Border>
</StackPanel>
'@
		$box = $pwin.FindName('PasteBox')
		$pwin.FindName('PasteCancel').Add_Click({ $pwin.Close() })
		$pwin.FindName('PasteGo').Add_Click({
			$addrs = @(Get-EmailsFromText $box.Text)
			if (-not $addrs.Count) { $addrs = @($box.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique) }
			$pwin.Close()
			$from = Get-ConvFrom; $to = Get-ConvTo
			$items = @($addrs | ForEach-Object { @{ Address = $_; From = $from; To = $to } })
			Run-ConvBatch $items
		})
		[void]$pwin.ShowDialog()
	}

	$scriptForm6 = New-ConvertMailboxOrGroupDialog
	$fromM365 = $scriptForm6.FindName('FromM365'); $fromDL = $scriptForm6.FindName('FromDL'); $fromShared = $scriptForm6.FindName('FromShared')
	$toDL = $scriptForm6.FindName('ToDL'); $toM365 = $scriptForm6.FindName('ToM365'); $toShared = $scriptForm6.FindName('ToShared')
	$summaryText = $scriptForm6.FindName('SummaryText'); $staysText = $scriptForm6.FindName('StaysText'); $lostText = $scriptForm6.FindName('LostText')
	$moveAddrCheck = $scriptForm6.FindName('MoveAddrCheck'); $sendAsCheck = $scriptForm6.FindName('SendAsCheck')
	$renamePanel = $scriptForm6.FindName('RenamePanel'); $renameOldInput = $scriptForm6.FindName('RenameOldInput')
	$sourceInputBox = $scriptForm6.FindName('SourceInput')
	Enable-RecipientAutocomplete $sourceInputBox 'Any'
	$singlePanel = $scriptForm6.FindName('SinglePanel'); $bulkPanel = $scriptForm6.FindName('BulkPanel')
	foreach ($r in @($fromM365, $fromDL, $fromShared, $toDL, $toM365, $toShared)) { $r.Add_Checked({ Update-ConvUi }) }
	$moveAddrCheck.Add_Checked({ $renamePanel.Visibility = 'Visible'; Set-ConvRenameDefault })
	$moveAddrCheck.Add_Unchecked({ $renamePanel.Visibility = 'Collapsed' })
	$renameOldInput.Add_TextChanged({ if ("$($renameOldInput.Text)".Trim() -ne $script:ConvRenameLastDefault) { $script:ConvRenameEdited = $true } })
	$sourceInputBox.Add_TextChanged({ if ($moveAddrCheck.IsChecked -eq $true -and -not $script:ConvRenameEdited) { Set-ConvRenameDefault } })
	$scriptForm6.FindName('SingleChip').Add_Checked({ $singlePanel.Visibility = 'Visible'; $bulkPanel.Visibility = 'Collapsed' })
	$scriptForm6.FindName('BulkChip').Add_Checked({ $singlePanel.Visibility = 'Collapsed'; $bulkPanel.Visibility = 'Visible' })
	$scriptForm6.FindName('ConvertBtn').Add_Click({ OnConvertButtonClick })
	$scriptForm6.FindName('TemplateOpenBtn').Add_Click({ OnTemplateButtonClick })
	$scriptForm6.FindName('PasteBtn').Add_Click({ OnPasteButtonClick })
	$scriptForm6.FindName('ConvertBulkBtn').Add_Click({ OnConvertBulkButtonClick })

	Update-ConvUi
	Write-Host "Loaded Convert mailbox or group dialog."
	$progressBar1.Value = 0

	[void]$scriptForm6.ShowDialog()

	Stop-Transcript
}

# Back-compat: anything still calling the old name gets Microsoft 365 group -> distribution list.
function Convert-UnifiedGroupToDistributionGroup {
	Convert-MailboxOrGroup
}

# ---------------------------------------------------------------------------
function New-EnableArchiveDialog {
	New-StyledDialog -Title 'Enable-Archive' -Icon '&#xE085;' -BodyXaml @'
<StackPanel Margin="16" Width="340">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<Grid>
				<Grid.ColumnDefinitions>
					<ColumnDefinition Width="70"/><ColumnDefinition Width="*"/>
				</Grid.ColumnDefinitions>
				<TextBlock Text="Mailbox" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
				<TextBox x:Name="ArchiveInput" Grid.Column="1"/>
			</Grid>
			<Button x:Name="ArchiveBtn" Style="{DynamicResource BtnPrimary}" Content="Enable Archive" Margin="0,14,0,0" IsDefault="True"/>
			<Grid Margin="0,8,0,0">
				<Grid.ColumnDefinitions>
					<ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/>
				</Grid.ColumnDefinitions>
				<Button x:Name="JumpstartBtn" Style="{DynamicResource BtnSecondary}" Content="Jumpstart Archive"/>
				<Button x:Name="ExpandBtn" Style="{DynamicResource BtnSecondary}" Content="Auto Expand Archive" Grid.Column="2"/>
			</Grid>
		</StackPanel>
	</Border>
</StackPanel>
'@
}

function Enable-Archive {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Enable-Archive.txt"
	Write-Host "Running Enable-Archive script..."
	$progressBar1.Value = 10
	function OnArchiveButtonClick {
		$mailbox = $archiveInputBox.Text
		$progressBar1.Value = 20
		Enable-Mailbox -Identity $mailbox -Archive
		$progressBar1.Value = 80
		CheckForErrors
		OperationComplete
	}

	function OnJumpstartButtonClick {
		$mailbox = $archiveInputBox.Text
		$progressBar1.Value = 20
		Start-ManagedFolderAssistant -Identity $mailbox
		$progressBar1.Value = 80
		CheckForErrors
		OperationComplete
	}

	function OnExpandButtonClick {
		$getUserConfirmation = ShowWarningForm "Turning on AutoExpandingArchive is irreversible - are you sure you'd like to continue?"
		if ($getUserConfirmation -eq $true) {
			Write-Host "User confirmed operation."
			$mailbox = $archiveInputBox.Text
			$progressBar1.Value = 20
			Enable-Mailbox -Identity $mailbox -AutoExpandingArchive
			Write-Host "Enabled auto expanding archive for $mailbox."
			$progressBar1.Value = 80
			CheckForErrors
			OperationComplete
		} elseif ($getUserConfirmation -eq $false) {
			Write-Host "User cancelled operation."
		} else {
			Write-Host "Error, can't determine if user confirmed or cancelled."
		}
	}

	$ScriptForm3 = New-EnableArchiveDialog
	$archiveInputBox = $ScriptForm3.FindName('ArchiveInput')
	Enable-RecipientAutocomplete $archiveInputBox 'Mailbox'
	$ScriptForm3.FindName('ArchiveBtn').Add_Click({ OnArchiveButtonClick })
	$ScriptForm3.FindName('JumpstartBtn').Add_Click({ OnJumpstartButtonClick })
	$ScriptForm3.FindName('ExpandBtn').Add_Click({ OnExpandButtonClick })

	Write-Host "Loaded ScriptForm3."
	$progressBar1.Value = 0

	[void]$ScriptForm3.ShowDialog()

	Stop-Transcript
}

# ---------------------------------------------------------------------------
function Install-RequiredModules {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Install-RequiredModules.txt"
	Write-Host "Running Install-RequiredModules script..."
	$progressBar1.Value = 10
	# Install the exact PINNED versions (CurrentUser scope, no admin), then load them. If a different
	# Microsoft Graph version is already loaded in this window, the pinned one can't load until the app
	# restarts - so offer the switch (which restarts).
	$ok = Install-PinnedModules
	$progressBar1.Value = 60
	if ($ok) {
		if (-not (Import-PinnedModules)) {
			Write-Host "Installed. Restart Script Package Studio to finish." -ForegroundColor Yellow
			Show-GraphPinPrompt 'after-install-required'
		}
	}
	$progressBar1.Value = 80
	CheckForErrors
	OperationComplete
	Stop-Transcript
}

# ---------------------------------------------------------------------------
function New-ADAccountsDialog {
	param([string]$ForestName = '')
	$win = New-StyledDialog -Title 'New-ADAccounts' -Icon '&#xEDBB;' -BodyXaml @'
<StackPanel Margin="16" Width="340">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<Grid>
				<Grid.ColumnDefinitions>
					<ColumnDefinition Width="90"/><ColumnDefinition Width="*"/>
				</Grid.ColumnDefinitions>
				<TextBlock Text="AD Domain" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
				<TextBox x:Name="AdDomainInput" Grid.Column="1"/>
			</Grid>
			<Button x:Name="OpenTemplateBtn" Style="{DynamicResource BtnSecondary}" Content="Open Template" Margin="0,14,0,0"/>
			<CheckBox x:Name="PreviewCheck" Content="Preview only (don't create)" Margin="0,12,0,0"/>
			<Button x:Name="CreateAccountsBtn" Style="{DynamicResource BtnPrimary}" Content="Create Accounts" Margin="0,8,0,0"/>
		</StackPanel>
	</Border>
</StackPanel>
'@
	$win.FindName('AdDomainInput').Text = $ForestName
	return $win
}

function New-ADAccounts {
	if (-not (Confirm-ADAvailable)) { return }
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\New-ADAccounts.txt"
	Write-Host "Running New-ADAccounts script..."
	$progressBar1.Value = 10
	Write-Host "Importing ActiveDirectory Module..."
	Import-Module ActiveDirectory
	CheckForErrors
	$progressBar1.Value = 30
	Write-Host "Getting domain info..."
	$domain = Get-ADDomain
	CheckForErrors
	$progressBar1.Value = 40

	function OnOpenTemplateButtonClick {
		Write-Host "Open template button clicked."
		$progressBar1.Value = 10
		Invoke-Item ".\Templates\New-ADAccounts.csv"
		$progressBar1.Value = 100
		CheckForErrors
		$progressBar1.Value = 0
	}
	function OnCreateAccountsButtonClick {
		Write-Host "Checking if any SamAccountNames are over 20 characters."
		$tooLong = @(Import-Csv -Path ".\Templates\New-ADAccounts.csv" | Where-Object { $_.SamAccountName.Length -gt 20 })
		if ($tooLong.Count -gt 0) {
			Write-Host "$($tooLong.Count) SamAccountName(s) over 20 characters, requesting user confirmation." -ForegroundColor Red
			$getUserConfirmation = ShowWarningForm -warningText "One or more SamAccountNames are over 20 characters - this may cause issues.`nPlease confirm if you'd like to proceed anyways."
			if ($getUserConfirmation -ne $true) { Write-Host "User closed confirmation window, cancelling action..."; return }
			Write-Host "User confirmed to continue, running script..."
		} else {
			Write-Host "All SamAccountNames are within 20 characters."
		}
		CreateADAccounts
	}
	function CreateADAccounts {
		Write-Host "Importing template csv..."
		$progressBar1.Value = 10
		$preview = ($previewCheck.IsChecked -eq $true)
		$csvFile = @(Import-Csv -Path ".\Templates\New-ADAccounts.csv" | Where-Object { "$($_.SamAccountName)".Trim() })
		$progressBar1.Value = 20
		CheckForErrors

		$created = [System.Collections.Generic.List[string]]::new()
		$failed  = [System.Collections.Generic.List[string]]::new()
		$tot = $csvFile.Count; $i = 0
		foreach ($row in $csvFile) {
			$i++; Step-Progress "Creating $($row.SamAccountName)..." $i $tot
			$who = if ($row.SamAccountName) { "$($row.SamAccountName)" } else { '(blank row)' }
			try {
			Write-Host "Gathering info..."

			$sourceUser = Get-ADUser -Identity $row.SourceUser -Properties *

			if ($null -eq $sourceUser) {
				throw "source user '$($row.SourceUser)' not found"
			}

			$ouPath = $sourceUser.DistinguishedName -replace "CN=[^,]+,", ""
			$ou = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouPath'"

			if ($null -eq $ou) {
				throw "the source user's OU ('$ouPath') was not found, so the new user has nowhere to go"
			}

			$forest = $adDomainInput.Text
			$displayName = $row.GivenName + " " + $row.Surname
			$userPrincipalName = $row.SamAccountName + "@$forest"
			$samAccountName = $row.SamAccountName

			Write-Host "Creating new user $samAccountName..."
			Assert-ADUserNotExists $samAccountName $userPrincipalName
			if ($preview) { $created.Add($who); continue }
			New-ADUser -SamAccountName $samAccountName -Name $displayName -UserPrincipalName $userPrincipalName -DisplayName $displayName -AccountPassword (ConvertTo-SecureString $row.Password -AsPlainText -Force) -Enabled $true -Path $ou.DistinguishedName -GivenName $row.GivenName -Surname $row.Surname

			$newUser = Get-ADUser -Filter "SamAccountName -eq '$($row.SamAccountName -replace "'", "''")'"

			Write-Host "Copying attributes from source user $($sourceUser.SamAccountName) to new user $($newUser.SamAccountName)..."
			# Copy additional attributes from the source user
			Set-ADUser -Identity $row.SamAccountName -ProfilePath $sourceUser.ProfilePath
			Set-ADUser -Identity $row.SamAccountName -ScriptPath $sourceUser.ScriptPath
			Set-ADUser -Identity $row.SamAccountName -PasswordNeverExpires $sourceUser.PasswordNeverExpires
			Set-ADUser -Identity $row.SamAccountName -CannotChangePassword $sourceUser.CannotChangePassword

			Write-Host "Checking if source user $($sourceUser.SamAccountName) has a Home Directory..."
			# Check if the source user has a HomeDirectory
			if ($sourceUser.HomeDirectory) {
				Write-Host "Source user $($sourceUser.SamAccountName) has a Home Directory, copying to new user $($newUser.SamAccountName)..."
				# Construct HomeDirectory path
				$originalPath = $sourceUser.HomeDirectory
				$parentPath = Split-Path $originalPath -Parent
				$homeDirectory = Join-Path $parentPath $row.SamAccountName

				# Create HomeDirectory and HomeDrive
				New-Item -Path $homeDirectory -ItemType Directory
				$aclPath = $homeDirectory
				$acl = Get-Acl $aclPath

				$identity = "$forest\$samAccountName"
				$rights = "Modify"
				$inheritanceFlags = "ContainerInherit, ObjectInherit"
				$propagationFlags = "None"
				$accessControlType = "Allow"
				$rule = New-Object System.Security.AccessControl.FileSystemAccessRule("$identity","$rights","$inheritanceFlags","$propagationFlags","$accessControlType")
				$acl.AddAccessRule($rule)
				Set-Acl $aclPath $acl

				# Add HomeDirectory and HomeDrive
				Set-ADUser -Identity $row.SamAccountName -HomeDrive $sourceUser.HomeDrive
				Set-ADUser -Identity $row.SamAccountName -HomeDirectory $homeDirectory
			} else {
				Write-Host "Source user $($sourceUser.SamAccountName) does not have a HomeDirectory. Skipping HomeDirectory creation for the new user $($newUser.SamAccountName)."
			}

			Write-Host "Copying group membership from source user $($sourceUser.SamAccountName) to new user $($newUser.SamAccountName)..."
			# Copy security group memberships
			$sourceGroups = Get-ADPrincipalGroupMembership -Identity $sourceUser.DistinguishedName
			foreach ($group in $sourceGroups) {
				Set-ItemStatus "Copying groups for $($row.SamAccountName): $($group.Name)..."
				# Check if the new user is already a member of the group
				$isMember = Get-ADGroupMember -Identity $group.DistinguishedName -Recursive | Where-Object { $_.SamAccountName -eq $row.SamAccountName }
				if ($null -eq $isMember) {
					# Add the new user to the group if they are not already a member
					Add-ADGroupMember -Identity $group.DistinguishedName -Members $row.SamAccountName
				}
			}
			$created.Add($who)
			Write-Host "Finished creating new user $who."
			} catch {
				$msg = "$($_.Exception.Message)".Trim()
				Write-Host "Failed to create '$who': $msg" -ForegroundColor Red
				$failed.Add("$who - $msg")
			}
		}
		Show-AccountResults 'Create AD accounts' $created $failed -Preview:$preview
		CheckForErrors
	}

	$scriptForm9 = New-ADAccountsDialog -ForestName $domain.forest
	$previewCheck = $scriptForm9.FindName('PreviewCheck')
	$adDomainInput = $scriptForm9.FindName('AdDomainInput')
	$scriptForm9.FindName('OpenTemplateBtn').Add_Click({ OnOpenTemplateButtonClick })
	$scriptForm9.FindName('CreateAccountsBtn').Add_Click({ OnCreateAccountsButtonClick })

	Write-Host "Loaded ScriptForm9."
	$progressBar1.Value = 0

	[void]$scriptForm9.ShowDialog()

	Stop-Transcript
}

# ---------------------------------------------------------------------------
$script:EmailLicenseList = @(
	"Exchange Online (Plan 1)",
	"Exchange Online (Plan 2)",
	"Microsoft 365 Business Basic",
	"Microsoft 365 Business Standard",
	"Microsoft 365 Business Premium",
	"Microsoft 365 E3",
	"Microsoft 365 E5"
)

# Friendly license name -> SKU GUID. Single source of truth shared by the account creators and
# Set-License. (Same GUIDs previously inline in the create scripts' switch statements.)
$script:LicenseSkuMap = [ordered]@{
	"Exchange Online (Plan 1)"        = "4b9405b0-7788-4568-add1-99614e613b69"
	"Exchange Online (Plan 2)"        = "19ec0d23-8335-4cbd-94ac-6050e30712fa"
	"Microsoft 365 Business Basic"    = "3b555118-da6a-4418-894f-7df1e2096870"
	"Microsoft 365 Business Standard" = "f245ecc8-75af-4f8e-b61f-27d8114de5f3"
	"Microsoft 365 Business Premium"  = "cbdc14ab-d96c-4c30-b9f4-6ada7cdc1d46"
	"Microsoft 365 E3"                = "05e9a617-0261-4cee-bb44-138d3ef5d965"
	"Microsoft 365 E5"                = "06ebc4ee-1bb5-47dd-8120-11324bc54e06"
}
# Reverse lookup (SKU GUID -> friendly name) for showing a user's current licenses.
$script:LicenseNameBySku = @{}
foreach ($k in $script:LicenseSkuMap.Keys) { $script:LicenseNameBySku[$script:LicenseSkuMap[$k]] = $k }

function New-ADAndEmailAccountsDialog {
	param([string]$ForestName = '')
	$win = New-StyledDialog -Title 'New-ADAndEmailAccounts' -Icon '&#xEDBB;' -BodyXaml @'
<StackPanel Margin="16" Width="360">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<Grid>
				<Grid.ColumnDefinitions>
					<ColumnDefinition Width="100"/><ColumnDefinition Width="*"/>
				</Grid.ColumnDefinitions>
				<Grid.RowDefinitions>
					<RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
				</Grid.RowDefinitions>
				<TextBlock Text="AD Domain" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
				<TextBox x:Name="AdDomainInput" Grid.Column="1"/>
				<TextBlock Text="Email Domain" Style="{DynamicResource Dim}" Grid.Row="1" VerticalAlignment="Center" Margin="0,8,0,0"/>
				<TextBox x:Name="EmailDomainInput" Grid.Row="1" Grid.Column="1" Margin="0,8,0,0" ToolTip="Example: contoso.com"/>
				<TextBlock Text="Email License" Style="{DynamicResource Dim}" Grid.Row="2" VerticalAlignment="Center" Margin="0,8,0,0"/>
				<ComboBox x:Name="LicenseCombo" Grid.Row="2" Grid.Column="1" Margin="0,8,0,0"/>
			</Grid>
			<TextBlock Text="Email domain example: contoso.com" Style="{DynamicResource Small}" Margin="100,6,0,0"/>
			<Button x:Name="OpenTemplateBtn" Style="{DynamicResource BtnSecondary}" Content="Open Template" Margin="0,14,0,0"/>
			<CheckBox x:Name="PreviewCheck" Content="Preview only (don't create)" Margin="0,12,0,0"/>
			<Button x:Name="CreateAccountsBtn" Style="{DynamicResource BtnPrimary}" Content="Create Accounts" Margin="0,8,0,0"/>
		</StackPanel>
	</Border>
</StackPanel>
'@
	$win.FindName('AdDomainInput').Text = $ForestName
	$combo = $win.FindName('LicenseCombo')
	foreach ($l in $script:EmailLicenseList) { [void]$combo.Items.Add($l) }
	return $win
}

function New-ADAndEmailAccounts {
	if (-not (Confirm-ADAvailable)) { return }
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\New-ADAndEmailAccounts.txt"
	Write-Host "Running New-ADAndEmailAccounts script..."
	$progressBar1.Value = 10
	Write-Host "Importing ActiveDirectory Module..."
	Import-Module ActiveDirectory
	CheckForErrors
	$progressBar1.Value = 30
	Write-Host "Getting domain info..."
	$domain = Get-ADDomain
	CheckForErrors
	$progressBar1.Value = 40

	function OnOpenTemplateButtonClick {
		Write-Host "Open template button clicked."
		$progressBar1.Value = 10
		Invoke-Item ".\Templates\New-ADAndEmailAccounts.csv"
		$progressBar1.Value = 100
		CheckForErrors
		$progressBar1.Value = 0
	}
	function OnCreateAccountsButtonClick {
		Write-Host "Checking if any SamAccountNames are over 20 characters."
		$tooLong = @(Import-Csv -Path ".\Templates\New-ADAndEmailAccounts.csv" | Where-Object { $_.SamAccountName.Length -gt 20 })
		if ($tooLong.Count -gt 0) {
			Write-Host "$($tooLong.Count) SamAccountName(s) over 20 characters, requesting user confirmation." -ForegroundColor Red
			$getUserConfirmation = ShowWarningForm -warningText "One or more SamAccountNames are over 20 characters - this may cause issues.`nPlease confirm if you'd like to proceed anyways."
			if ($getUserConfirmation -ne $true) { Write-Host "User closed confirmation window, cancelling action..."; return }
			Write-Host "User confirmed to continue, running script..."
		} else {
			Write-Host "All SamAccountNames are within 20 characters."
		}
		CreateAccounts
	}
	function CreateAccounts {
		Write-Host "Importing template csv..."
		$progressBar1.Value = 10
		$preview = ($previewCheck.IsChecked -eq $true)
		$csvFile = @(Import-Csv -Path ".\Templates\New-ADAndEmailAccounts.csv" | Where-Object { "$($_.SamAccountName)".Trim() })
		$progressBar1.Value = 30
		CheckForErrors
		$created = [System.Collections.Generic.List[string]]::new()
		$failed  = [System.Collections.Generic.List[string]]::new()
		$tot = $csvFile.Count; $i = 0
		foreach ($row in $csvFile) {
			$i++; Step-Progress "Creating $($row.SamAccountName)..." $i $tot
			$who = if ($row.SamAccountName) { "$($row.SamAccountName)" } else { '(blank row)' }
			try {
			Write-Host "Gathering info..."

			$sourceUser = Get-ADUser -Identity $row.SourceUser -Properties *

			if ($null -eq $sourceUser) {
				throw "source user '$($row.SourceUser)' not found"
			}

			$ouPath = $sourceUser.DistinguishedName -replace "CN=[^,]+,", ""
			$ou = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouPath'"

			if ($null -eq $ou) {
				throw "the source user's OU ('$ouPath') was not found, so the new user has nowhere to go"
			}

			$forest = $adDomainInput.Text
			$displayName = $row.GivenName + " " + $row.Surname
			$samAccountName = $row.SamAccountName
			$userPrincipalName = $row.SamAccountName + "@$forest"
			$emailAddress = $row.SamAccountName + "@" + ($emailDomainInput.Text.Trim())

			Write-Host "Creating new user $samAccountName..."
			Assert-ADUserNotExists $row.SamAccountName $userPrincipalName
			Assert-MgUserNotExists $emailAddress
			if ($preview) { $created.Add($who); continue }
			New-ADUser -SamAccountName $row.SamAccountName -Name $displayName -UserPrincipalName $userPrincipalName -DisplayName $displayName -AccountPassword (ConvertTo-SecureString $row.Password -AsPlainText -Force) -Enabled $true -Path $ou.DistinguishedName -GivenName $row.GivenName -Surname $row.Surname

			$newUser = Get-ADUser -Filter "SamAccountName -eq '$($row.SamAccountName -replace "'", "''")'"

			Write-Host "Copying attributes from source user $($sourceUser.SamAccountName) to new user $($newUser.SamAccountName)..."
			# Copy additional attributes from the source user
			Set-ADUser -Identity $row.SamAccountName -ProfilePath $sourceUser.ProfilePath
			Set-ADUser -Identity $row.SamAccountName -ScriptPath $sourceUser.ScriptPath
			Set-ADUser -Identity $row.SamAccountName -PasswordNeverExpires $sourceUser.PasswordNeverExpires
			Set-ADUser -Identity $row.SamAccountName -CannotChangePassword $sourceUser.CannotChangePassword

			Write-Host "Checking if source user $($sourceUser.SamAccountName) has a Home Directory..."
			# Check if the source user has a HomeDirectory
			if ($sourceUser.HomeDirectory) {
				Write-Host "Source user $($sourceUser.SamAccountName) has a Home Directory, copying to new user $($newUser.SamAccountName)..."
				# Construct HomeDirectory path
				$originalPath = $sourceUser.HomeDirectory
				$parentPath = Split-Path $originalPath -Parent
				$homeDirectory = Join-Path $parentPath $row.SamAccountName

				# Create HomeDirectory and HomeDrive
				New-Item -Path $homeDirectory -ItemType Directory
				$aclPath = $homeDirectory
				$acl = Get-Acl $aclPath

				$identity = "$forest\$samAccountName"
				$rights = "Modify"
				$inheritanceFlags = "ContainerInherit, ObjectInherit"
				$propagationFlags = "None"
				$accessControlType = "Allow"
				$rule = New-Object System.Security.AccessControl.FileSystemAccessRule("$identity","$rights","$inheritanceFlags","$propagationFlags","$accessControlType")
				$acl.AddAccessRule($rule)
				Set-Acl $aclPath $acl

				# Add HomeDirectory and HomeDrive
				Set-ADUser -Identity $row.SamAccountName -HomeDrive $sourceUser.HomeDrive
				Set-ADUser -Identity $row.SamAccountName -HomeDirectory $homeDirectory
			} else {
				Write-Host "Source user $($sourceUser.SamAccountName) does not have a HomeDirectory. Skipping HomeDirectory creation for the new user $($newUser.SamAccountName)."
			}

			Write-Host "Copying group membership from source user $($sourceUser.SamAccountName) to new user $($newUser.SamAccountName)..."
			# Copy security group memberships
			$sourceGroups = Get-ADPrincipalGroupMembership -Identity $sourceUser.DistinguishedName
			foreach ($group in $sourceGroups) {
				Set-ItemStatus "Copying groups for $($row.SamAccountName): $($group.Name)..."
				# Check if the new user is already a member of the group
				$isMember = Get-ADGroupMember -Identity $group.DistinguishedName -Recursive | Where-Object { $_.SamAccountName -eq $row.SamAccountName }
				if ($null -eq $isMember) {
					# Add the new user to the group if they are not already a member
					Add-ADGroupMember -Identity $group.DistinguishedName -Members $row.SamAccountName
				}
			}

			# Create mailbox
			$passwordProfile = @{
				ForceChangePasswordNextSignIn = $false
				Password = $row.Password
			}

			New-MgUser -AccountEnabled -PasswordProfile $passwordProfile -DisplayName $displayName -GivenName $row.GivenName -Surname $row.Surname -UserPrincipalName $emailAddress -MailNickname $row.SamAccountName -UsageLocation $(if ("$($row.UsageLocation)".Trim()) { "$($row.UsageLocation)".Trim() } else { 'US' })

			# Set license
			switch ($licenseComboBox.Text) {
				"Exchange Online (Plan 1)" {
					Write-Host "Assigning Exchange Online (Plan 1) license..."
					Assign-MgLicenseWithRetry $emailAddress "4b9405b0-7788-4568-add1-99614e613b69"
				}
				"Exchange Online (Plan 2)" {
					Write-Host "Assigning Exchange Online (Plan 2) license..."
					Assign-MgLicenseWithRetry $emailAddress "19ec0d23-8335-4cbd-94ac-6050e30712fa"
				}
				"Microsoft 365 Business Basic" {
					Write-Host "Assigning Microsoft 365 Business Basic license..."
					Assign-MgLicenseWithRetry $emailAddress "3b555118-da6a-4418-894f-7df1e2096870"
				}
				"Microsoft 365 Business Standard" {
					Write-Host "Assigning Microsoft 365 Business Standard license..."
					Assign-MgLicenseWithRetry $emailAddress "f245ecc8-75af-4f8e-b61f-27d8114de5f3"
				}
				"Microsoft 365 Business Premium" {
					Write-Host "Assigning Microsoft 365 Business Premium license..."
					Assign-MgLicenseWithRetry $emailAddress "cbdc14ab-d96c-4c30-b9f4-6ada7cdc1d46"
				}
				"Microsoft 365 E3" {
					Write-Host "Assigning Microsoft 365 E3 license..."
					Assign-MgLicenseWithRetry $emailAddress "05e9a617-0261-4cee-bb44-138d3ef5d965"
				}
				"Microsoft 365 E5" {
					Write-Host "Assigning Microsoft 365 E5 license..."
					Assign-MgLicenseWithRetry $emailAddress "06ebc4ee-1bb5-47dd-8120-11324bc54e06"
				}
				Default { Write-Host "No license selected or invalid entry." }
			}
			$created.Add($who)
			Write-Host "Finished creating $who." -ForegroundColor Cyan
			} catch {
				$msg = "$($_.Exception.Message)".Trim()
				Write-Host "Failed to create '$who': $msg" -ForegroundColor Red
				$failed.Add("$who - $msg")
			}
		}
		Show-AccountResults 'Create AD & Email accounts' $created $failed -Preview:$preview
		CheckForErrors
	}

	$scriptForm9 = New-ADAndEmailAccountsDialog -ForestName $domain.forest
	$adDomainInput = $scriptForm9.FindName('AdDomainInput')
	$emailDomainInput = $scriptForm9.FindName('EmailDomainInput')
	$licenseComboBox = $scriptForm9.FindName('LicenseCombo')
	$previewCheck = $scriptForm9.FindName('PreviewCheck')
	$scriptForm9.FindName('OpenTemplateBtn').Add_Click({ OnOpenTemplateButtonClick })
	$scriptForm9.FindName('CreateAccountsBtn').Add_Click({ OnCreateAccountsButtonClick })

	Write-Host "Loaded ScriptForm9."
	$progressBar1.Value = 0

	[void]$scriptForm9.ShowDialog()

	Stop-Transcript
}

# ---------------------------------------------------------------------------
function New-EmailAccountsDialog {
	$win = New-StyledDialog -Title 'New-EmailAccounts' -Icon '&#xEBBC;' -BodyXaml @'
<StackPanel Margin="16" Width="340">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<Grid>
				<Grid.ColumnDefinitions>
					<ColumnDefinition Width="100"/><ColumnDefinition Width="*"/>
				</Grid.ColumnDefinitions>
				<TextBlock Text="Email License" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
				<ComboBox x:Name="LicenseCombo" Grid.Column="1"/>
			</Grid>
			<Button x:Name="OpenTemplateBtn" Style="{DynamicResource BtnSecondary}" Content="Open Template" Margin="0,14,0,0"/>
			<CheckBox x:Name="PreviewCheck" Content="Preview only (don't create)" Margin="0,12,0,0"/>
			<Button x:Name="CreateAccountsBtn" Style="{DynamicResource BtnPrimary}" Content="Create Accounts" Margin="0,8,0,0"/>
		</StackPanel>
	</Border>
</StackPanel>
'@
	$combo = $win.FindName('LicenseCombo')
	foreach ($l in $script:EmailLicenseList) { [void]$combo.Items.Add($l) }
	return $win
}

function New-EmailAccounts {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\New-EmailAccounts.txt"
	Write-Host "Running New-EmailAccounts script..."
	$progressBar1.Value = 10

	function OnOpenTemplateButtonClick {
		Write-Host "Open template button clicked."
		$progressBar1.Value = 10
		Invoke-Item ".\Templates\New-EmailAccounts.csv"
		$progressBar1.Value = 100
		CheckForErrors
		$progressBar1.Value = 0
	}
	function OnCreateAccountsButtonClick {
		Write-Host "createAccountsButton clicked."
		$progressBar1.Value = 10
		$created = [System.Collections.Generic.List[string]]::new()
		$failed  = [System.Collections.Generic.List[string]]::new()
		$preview = ($previewCheck.IsChecked -eq $true)
		$rows = @(Import-Csv ".\Templates\New-EmailAccounts.csv" | Where-Object { "$($_.EmailAddress)".Trim() })
		$tot = $rows.Count; $i = 0
		$rows | ForEach-Object {
			$i++; Step-Progress "Creating $($_.EmailAddress)..." $i $tot
			$who = if ($_.EmailAddress) { "$($_.EmailAddress)" } else { '(blank row)' }
			try {
			$firstName = $_.FirstName
			$lastName = $_.LastName
			$displayName = $firstName + " " + $lastName
			$emailAddress = $_.EmailAddress
			$splitEmail = $emailAddress -split "\@"
			$mailNickname = $splitEmail[0]
			$password = $_.Password

			$passwordProfile = @{
				ForceChangePasswordNextSignIn = $false
				Password = $password
			}


			Assert-MgUserNotExists $emailAddress
			if ($preview) { $created.Add($who); return }
			New-MgUser -AccountEnabled -PasswordProfile $passwordProfile -DisplayName $displayName -GivenName $firstName -Surname $lastName -UserPrincipalName $emailAddress -MailNickname $mailNickname -UsageLocation $(if ("$($_.UsageLocation)".Trim()) { "$($_.UsageLocation)".Trim() } else { 'US' })

			# Set license
			switch ($licenseComboBox.Text) {
				"Exchange Online (Plan 1)" {
					Write-Host "Assigning Exchange Online (Plan 1) license..."
					Assign-MgLicenseWithRetry $emailAddress "4b9405b0-7788-4568-add1-99614e613b69"
				}
				"Exchange Online (Plan 2)" {
					Write-Host "Assigning Exchange Online (Plan 2) license..."
					Assign-MgLicenseWithRetry $emailAddress "19ec0d23-8335-4cbd-94ac-6050e30712fa"
				}
				"Microsoft 365 Business Basic" {
					Write-Host "Assigning Microsoft 365 Business Basic license..."
					Assign-MgLicenseWithRetry $emailAddress "3b555118-da6a-4418-894f-7df1e2096870"
				}
				"Microsoft 365 Business Standard" {
					Write-Host "Assigning Microsoft 365 Business Standard license..."
					Assign-MgLicenseWithRetry $emailAddress "f245ecc8-75af-4f8e-b61f-27d8114de5f3"
				}
				"Microsoft 365 Business Premium" {
					Write-Host "Assigning Microsoft 365 Business Premium license..."
					Assign-MgLicenseWithRetry $emailAddress "cbdc14ab-d96c-4c30-b9f4-6ada7cdc1d46"
				}
				"Microsoft 365 E3" {
					Write-Host "Assigning Microsoft 365 E3 license..."
					Assign-MgLicenseWithRetry $emailAddress "05e9a617-0261-4cee-bb44-138d3ef5d965"
				}
				"Microsoft 365 E5" {
					Write-Host "Assigning Microsoft 365 E5 license..."
					Assign-MgLicenseWithRetry $emailAddress "06ebc4ee-1bb5-47dd-8120-11324bc54e06"
				}
				Default { Write-Host "No license selected or invalid entry." }
			}
			$created.Add($who)
			} catch {
				$msg = "$($_.Exception.Message)".Trim()
				Write-Host "Failed to create '$who': $msg" -ForegroundColor Red
				$failed.Add("$who - $msg")
			}
		}
		Show-AccountResults 'Create email accounts' $created $failed -Preview:$preview
		CheckForErrors
	}

	$addEmailAccountsForm = New-EmailAccountsDialog
	$licenseComboBox = $addEmailAccountsForm.FindName('LicenseCombo')
	$previewCheck = $addEmailAccountsForm.FindName('PreviewCheck')
	$addEmailAccountsForm.FindName('OpenTemplateBtn').Add_Click({ OnOpenTemplateButtonClick })
	$addEmailAccountsForm.FindName('CreateAccountsBtn').Add_Click({ OnCreateAccountsButtonClick })

	Write-Host "Loaded addEmailAccountsForm."
	$progressBar1.Value = 100
	CheckForErrors
	$progressBar1.Value = 0

	[void]$addEmailAccountsForm.ShowDialog()

	Stop-Transcript
}

# ---------------------------------------------------------------------------
function New-ResetMfaDialog {
	New-StyledDialog -Title 'Reset-MFA' -Icon '&#xE72E;' -BodyXaml @'
<StackPanel Margin="16" Width="340">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<TextBlock Text="Single" Style="{DynamicResource H3}"/>
			<Grid Margin="0,12,0,0">
				<Grid.ColumnDefinitions><ColumnDefinition Width="70"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
				<TextBlock Text="User" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
				<TextBox x:Name="EmailInput" Grid.Column="1"/>
			</Grid>
			<CheckBox x:Name="RevokeCheck" Content="Also sign the user out everywhere" IsChecked="True" Margin="0,12,0,0"/>
			<Button x:Name="ResetBtn" Style="{DynamicResource BtnPrimary}" Content="Reset MFA" Margin="0,14,0,0"/>
		</StackPanel>
	</Border>
	<Border Style="{DynamicResource Card}" Margin="0,12,0,0">
		<StackPanel>
			<TextBlock Text="Bulk" Style="{DynamicResource H3}"/>
			<Button x:Name="OpenTemplateBtn" Style="{DynamicResource BtnSecondary}" Content="Open Template" Margin="0,12,0,0"/>
			<Button x:Name="BulkBtn" Style="{DynamicResource BtnPrimary}" Content="Reset MFA (bulk)" Margin="0,8,0,0"/>
		</StackPanel>
	</Border>
</StackPanel>
'@
}

function Reset-MFA {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Reset-MFA.txt"
	Write-Host "Running Reset-MFA script..."
	$progressBar1.Value = 10

	# Clear all re-registerable methods (shared helper), then optionally revoke sessions.
	function Clear-MfaFor([string]$u) {
		$removed = Clear-UserAuthMethods $u
		if ($revokeCheck.IsChecked -eq $true) { Revoke-MgUserSignInSession -UserId $u -ErrorAction Stop | Out-Null }
		return $removed
	}
	function OnResetButtonClick {
		$u = $emailInput.Text.Trim()
		if (-not $u) { Show-Notice 'Missing info' 'Enter a user email first.' 'Warn'; return }
		$progressBar1.Value = 40
		try {
			$n = Clear-MfaFor $u
			$extra = if ($revokeCheck.IsChecked -eq $true) { ' Signed them out everywhere.' } else { '' }
			Write-Host "Cleared $n method(s) for $u." -ForegroundColor Cyan
			Show-Notice 'MFA reset' "Cleared $n registered method(s) for `"$u`".$extra`n`nThey'll be asked to re-register at next sign-in (if MFA is required)." 'Info'
		} catch { Show-Notice 'Reset MFA failed' "Couldn't reset MFA for `"$u`":`n`n$($_.Exception.Message)" 'Error' }
		$progressBar1.Value = 0
	}
	function OnOpenTemplateButtonClick { $progressBar1.Value = 10; Invoke-Item ".\Templates\Reset-MFA.csv"; $progressBar1.Value = 0; CheckForErrors }
	function OnBulkButtonClick {
		$created = [System.Collections.Generic.List[string]]::new()
		$failed  = [System.Collections.Generic.List[string]]::new()
		$rows = @(Import-Csv ".\Templates\Reset-MFA.csv" | Where-Object { "$($_.Email)".Trim() })
		$tot = $rows.Count; $i = 0
		Lock-ScriptWindow $form
		$rows | ForEach-Object {
			$i++; $u = "$($_.Email)".Trim()
			Step-Progress "Resetting MFA for $u..." $i $tot
			try { $n = Clear-MfaFor $u; $created.Add("$u ($n cleared)") }
			catch { Write-Host "Failed on $u`: $($_.Exception.Message)" -ForegroundColor Red; $failed.Add("$u - $($_.Exception.Message)") }
		}
		Show-AccountResults 'Reset MFA' $created $failed -DoneWord 'Reset' -FailWord 'Failed'
		Unlock-ScriptWindow
	}

	$form = New-ResetMfaDialog
	$emailInput = $form.FindName('EmailInput')
	$revokeCheck = $form.FindName('RevokeCheck')
	Enable-RecipientAutocomplete $emailInput 'User'
	$form.FindName('ResetBtn').Add_Click({ OnResetButtonClick })
	$form.FindName('OpenTemplateBtn').Add_Click({ OnOpenTemplateButtonClick })
	$form.FindName('BulkBtn').Add_Click({ OnBulkButtonClick })
	Write-Host "Loaded ResetMfaForm."
	$progressBar1.Value = 0
	[void]$form.ShowDialog()
	Stop-Transcript
}

# ---------------------------------------------------------------------------
function New-SetLicenseDialog {
	$win = New-StyledDialog -Title 'Set-License' -Icon '&#xE8FC;' -BodyXaml @'
<StackPanel Margin="16" Width="360">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<TextBlock Text="Single" Style="{DynamicResource H3}"/>
			<StackPanel Orientation="Horizontal" Margin="0,10,0,4">
				<RadioButton x:Name="AssignChip" Style="{DynamicResource Chip}" GroupName="LicMode" Content="Assign" IsChecked="True"/>
				<RadioButton x:Name="RemoveChip" Style="{DynamicResource Chip}" GroupName="LicMode" Content="Remove" Margin="8,0,0,0"/>
				<RadioButton x:Name="SwapChip" Style="{DynamicResource Chip}" GroupName="LicMode" Content="Swap" Margin="8,0,0,0"/>
			</StackPanel>
			<Grid Margin="0,8,0,0">
				<Grid.ColumnDefinitions><ColumnDefinition Width="120"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
				<Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
				<TextBlock Text="User email" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
				<TextBox x:Name="UserInput" Grid.Column="1"/>
				<TextBlock x:Name="FromLabel" Text="Remove license" Style="{DynamicResource Dim}" Grid.Row="1" VerticalAlignment="Center" Margin="0,8,0,0" Visibility="Collapsed"/>
				<ComboBox x:Name="FromCombo" Grid.Row="1" Grid.Column="1" Margin="0,8,0,0" Visibility="Collapsed"/>
				<TextBlock x:Name="ToLabel" Text="License to add" Style="{DynamicResource Dim}" Grid.Row="2" VerticalAlignment="Center" Margin="0,8,0,0"/>
				<ComboBox x:Name="ToCombo" Grid.Row="2" Grid.Column="1" Margin="0,8,0,0"/>
			</Grid>
			<TextBlock x:Name="CurrentLicText" Style="{DynamicResource Small}" TextWrapping="Wrap" Margin="0,8,0,0"/>
			<Button x:Name="ApplyBtn" Style="{DynamicResource BtnPrimary}" Content="Apply" Margin="0,10,0,0"/>
		</StackPanel>
	</Border>
	<Border Style="{DynamicResource Card}" Margin="0,12,0,0">
		<StackPanel>
			<TextBlock Text="Bulk" Style="{DynamicResource H3}"/>
			<TextBlock Text="Applies the mode and license chosen above to every email in the CSV." Style="{DynamicResource Small}" TextWrapping="Wrap" Margin="0,4,0,0"/>
			<Button x:Name="OpenTemplateBtn" Style="{DynamicResource BtnSecondary}" Content="Open Template" Margin="0,10,0,0"/>
			<CheckBox x:Name="PreviewCheck" Content="Preview only" Margin="0,10,0,0"/>
			<Button x:Name="BulkBtn" Style="{DynamicResource BtnPrimary}" Content="Apply to List" Margin="0,8,0,0"/>
		</StackPanel>
	</Border>
</StackPanel>
'@
	$to = $win.FindName('ToCombo'); $from = $win.FindName('FromCombo')
	foreach ($l in $script:LicenseSkuMap.Keys) { [void]$to.Items.Add($l); [void]$from.Items.Add($l) }
	$to.SelectedIndex = 0; $from.SelectedIndex = 0
	return $win
}

function Set-License {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Set-License.txt"
	Write-Host "Running Set-License script..."
	$progressBar1.Value = 10

	function Get-Mode { if ($assignChip.IsChecked -eq $true) { 'Assign' } elseif ($removeChip.IsChecked -eq $true) { 'Remove' } else { 'Swap' } }
	# Apply one license change to one user by the current mode. Assign uses the replication-aware
	# retry; remove/swap go straight through.
	function Set-OneLicense([string]$User, [string]$AddSku, [string]$RemoveSku) {
		if ($AddSku -and $RemoveSku) { Set-MgUserLicense -UserId $User -AddLicenses @(@{SkuId = $AddSku}) -RemoveLicenses @($RemoveSku) -ErrorAction Stop | Out-Null }
		elseif ($AddSku)    { Assign-MgLicenseWithRetry $User $AddSku }
		elseif ($RemoveSku) { Set-MgUserLicense -UserId $User -AddLicenses @() -RemoveLicenses @($RemoveSku) -ErrorAction Stop | Out-Null }
	}
	# Given the mode + combo selections, return @{ Add; Remove } SKU GUIDs (either may be $null).
	function Resolve-Skus([string]$Mode) {
		$toSku   = $script:LicenseSkuMap[[string]$toCombo.SelectedItem]
		$fromSku = $script:LicenseSkuMap[[string]$fromCombo.SelectedItem]
		switch ($Mode) {
			'Assign' { @{ Add = $toSku; Remove = $null } }
			'Remove' { @{ Add = $null;  Remove = $toSku } }
			'Swap'   { @{ Add = $toSku; Remove = $fromSku } }
		}
	}
	function OnModeChange {
		$mode = Get-Mode
		$swap = ($mode -eq 'Swap')
		$fromLabel.Visibility = if ($swap) { 'Visible' } else { 'Collapsed' }
		$fromCombo.Visibility = if ($swap) { 'Visible' } else { 'Collapsed' }
		$toLabel.Text = switch ($mode) { 'Assign' { 'License to add' } 'Remove' { 'License to remove' } 'Swap' { 'License to add' } }
		$applyButton.Content = "$mode"
		$bulkButton.Content = "$mode for List"
		Load-CurrentLicenses
	}
	# Read the user's current licenses, show them, and (in Swap mode) preselect the 'from' license.
	function Load-CurrentLicenses {
		$u = $userInput.Text.Trim()
		if (-not $u) { $currentLicText.Text = ''; return }
		try {
			$det = @(Get-MgUserLicenseDetail -UserId $u -ErrorAction Stop)
			if (-not $det.Count) { $currentLicText.Text = "Current licenses: none."; return }
			$names = foreach ($d in $det) { $n = $script:LicenseNameBySku["$($d.SkuId)"]; if ($n) { $n } else { "$($d.SkuPartNumber)" } }
			$currentLicText.Text = "Current licenses: " + ($names -join ', ')
			if ((Get-Mode) -eq 'Swap') {
				$known = $det | Where-Object { $script:LicenseNameBySku["$($_.SkuId)"] } | Select-Object -First 1
				if ($known) { $fromCombo.SelectedItem = $script:LicenseNameBySku["$($known.SkuId)"] }
			}
		} catch { $currentLicText.Text = "Couldn't read current licenses for $u`: $($_.Exception.Message)" }
	}
	# Turn a raw Graph license error into a plain-language message; flags the "no seats" case.
	function Format-LicenseError([string]$msg) {
		if ($msg -match 'not enough|no available|available unit|available licen|enough unit|exceed|counterfeit|assign.*license.*because') {
			return "There are no available seats for that license in the tenant.`n`nBuy more (month-to-month is fine) in the Microsoft 365 admin center - Billing > Purchase services - then run this again.`n`nNote: licenses can't be purchased from PowerShell, only assigned once you own them."
		}
		return $msg
	}
	function OnApplyButtonClick {
		$u = $userInput.Text.Trim()
		if (-not $u) { Show-Notice 'Missing info' 'Enter a user email first.' 'Warn'; return }
		$mode = Get-Mode; $skus = Resolve-Skus $mode
		if ($mode -eq 'Swap' -and $skus.Add -eq $skus.Remove) { Show-Notice 'Nothing to do' 'The two licenses are the same - pick different ones to swap.' 'Warn'; return }
		$progressBar1.Value = 40
		try { Set-OneLicense $u $skus.Add $skus.Remove; Write-Host "$mode license for $u." -ForegroundColor Cyan; Show-Notice 'License updated' "$mode complete for `"$u`"." 'Info'; Load-CurrentLicenses }
		catch { Show-Notice 'License change failed' "Couldn't update licenses for `"$u`":`n`n$(Format-LicenseError "$($_.Exception.Message)")" 'Error' }
		$progressBar1.Value = 0
	}
	function OnOpenTemplateButtonClick { $progressBar1.Value = 10; Invoke-Item ".\Templates\Set-License.csv"; $progressBar1.Value = 0; CheckForErrors }
	function OnBulkButtonClick {
		$mode = Get-Mode; $skus = Resolve-Skus $mode
		$preview = ($previewCheck.IsChecked -eq $true)
		$created = [System.Collections.Generic.List[string]]::new()
		$failed  = [System.Collections.Generic.List[string]]::new()
		$rows = @(Import-Csv ".\Templates\Set-License.csv" | Where-Object { "$($_.Email)".Trim() })
		$tot = $rows.Count; $i = 0
		Lock-ScriptWindow $form
		$rows | ForEach-Object {
			$i++; $u = "$($_.Email)".Trim()
			Step-Progress "Updating license for $u..." $i $tot
			if ($preview) { $created.Add("$u ($mode)") }
			else {
				try { Set-OneLicense $u $skus.Add $skus.Remove; $created.Add("$u ($mode)") }
				catch { $fe = Format-LicenseError "$($_.Exception.Message)"; Write-Host "Failed on $u`: $fe" -ForegroundColor Red; $failed.Add("$u - $fe") }
			}
		}
		Show-AccountResults "Set-License ($mode)" $created $failed -Preview:$preview -DoneWord 'Updated' -FailWord 'Failed'
		Unlock-ScriptWindow
	}

	$form = New-SetLicenseDialog
	$userInput = $form.FindName('UserInput')
	Enable-RecipientAutocomplete $userInput 'User'
	$assignChip = $form.FindName('AssignChip'); $removeChip = $form.FindName('RemoveChip'); $swapChip = $form.FindName('SwapChip')
	$fromLabel = $form.FindName('FromLabel'); $fromCombo = $form.FindName('FromCombo')
	$toLabel = $form.FindName('ToLabel'); $toCombo = $form.FindName('ToCombo')
	$applyButton = $form.FindName('ApplyBtn'); $bulkButton = $form.FindName('BulkBtn')
	$previewCheck = $form.FindName('PreviewCheck')
	$currentLicText = $form.FindName('CurrentLicText')
	$userInput.Add_LostKeyboardFocus({ Load-CurrentLicenses })
	$assignChip.Add_Checked({ OnModeChange }); $removeChip.Add_Checked({ OnModeChange }); $swapChip.Add_Checked({ OnModeChange })
	$applyButton.Add_Click({ OnApplyButtonClick })
	$form.FindName('OpenTemplateBtn').Add_Click({ OnOpenTemplateButtonClick })
	$bulkButton.Add_Click({ OnBulkButtonClick })
	Write-Host "Loaded SetLicenseForm."
	$progressBar1.Value = 0
	[void]$form.ShowDialog()
	Stop-Transcript
}

# ---------------------------------------------------------------------------
# Termination / offboarding: disable an AD account and/or convert the mailbox to shared, reset
# password, revoke sessions, disable the cloud account, strip licenses + 2FA - with optional
# "grant a delegate access" and "set an auto-reply" prompts. Ported from a standalone WinForms
# tool; the module-install / Connect-MgGraph / Connect-ExchangeOnline / sign-in-out plumbing is
# dropped because Script-Package Studio manages the tenant connection centrally.
function New-DisableAccountsDialog {
	New-StyledDialog -Title 'Terminate-Disable-ADAndEmailAccounts' -Icon '&#xEEE3;' -BodyXaml @'
<StackPanel Margin="16" Width="380">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<TextBlock Text="Single" Style="{DynamicResource H3}"/>
			<Grid Margin="0,12,0,0">
				<Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
				<Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
				<TextBlock Text="Email" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
				<TextBox x:Name="EmailInput" Grid.Column="1"/>
				<TextBlock Text="AD user" Style="{DynamicResource Dim}" Grid.Row="1" VerticalAlignment="Center" Margin="0,8,0,0"/>
				<TextBox x:Name="AdUserInput" Grid.Row="1" Grid.Column="1" Margin="0,8,0,0"/>
			</Grid>
			<StackPanel Orientation="Horizontal" Margin="0,12,0,0">
				<CheckBox x:Name="BlockEmailCheck" Content="Block email" IsChecked="True"/>
				<CheckBox x:Name="BlockAdCheck" Content="Block AD" IsChecked="True" Margin="18,0,0,0"/>
			</StackPanel>
			<Border Style="{DynamicResource Card}" Margin="0,12,0,0">
				<StackPanel>
					<TextBlock Text="Email options" Style="{DynamicResource Dim}"/>
					<CheckBox x:Name="AddMembersCheck" Content="Add mailbox members" IsChecked="True" Margin="0,8,0,0"/>
					<CheckBox x:Name="AddAutoReplyCheck" Content="Set an auto-reply" Margin="0,8,0,0"/>
				</StackPanel>
			</Border>
			<Button x:Name="BlockBtn" Style="{DynamicResource BtnPrimary}" Content="Block" Margin="0,14,0,0"/>
		</StackPanel>
	</Border>
	<Border Style="{DynamicResource Card}" Margin="0,12,0,0">
		<StackPanel>
			<TextBlock Text="Bulk" Style="{DynamicResource H3}"/>
			<Button x:Name="OpenTemplateBtn" Style="{DynamicResource BtnSecondary}" Content="Open Template" Margin="0,12,0,0"/>
			<Button x:Name="DisableBulkBtn" Style="{DynamicResource BtnPrimary}" Content="Disable Bulk Accounts" Margin="0,8,0,0"/>
		</StackPanel>
	</Border>
</StackPanel>
'@
}

# Sub-dialog: compose an auto-reply. Returns @{ Skip; Internal; External; UseSchedule; Start; End }.
function New-TermAutoReplyDialog([string]$Email) {
	$win = New-StyledDialog -Title "Auto-reply - $Email" -Icon '&#xEBBC;' -BodyXaml @"
<StackPanel Margin="16" Width="520">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<Grid>
				<Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
				<StackPanel Grid.Column="0">
					<TextBlock Text="Internal Auto-Reply" Style="{DynamicResource Dim}"/>
					<TextBox x:Name="InternalReplyBox" Style="{DynamicResource TextArea}" Height="150" Margin="0,6,0,0"/>
				</StackPanel>
				<StackPanel Grid.Column="2">
					<TextBlock Text="External Auto-Reply" Style="{DynamicResource Dim}"/>
					<TextBox x:Name="ExternalReplyBox" Style="{DynamicResource TextArea}" Height="150" Margin="0,6,0,0"/>
				</StackPanel>
			</Grid>
			<CheckBox x:Name="MatchRepliesCheck" Content="Match Replies" IsChecked="True" Margin="0,12,0,0"/>
			<Border Style="{DynamicResource Divider}"/>
			<CheckBox x:Name="UseScheduleCheck" Content="Use Start and End Date"/>
			<Grid Margin="0,10,0,0">
				<Grid.ColumnDefinitions><ColumnDefinition Width="70"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
				<Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
				<TextBlock Text="Start" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
				<DatePicker x:Name="StartDatePicker" Grid.Column="1" IsEnabled="False"/>
				<TextBlock Text="End" Style="{DynamicResource Dim}" Grid.Row="1" VerticalAlignment="Center" Margin="0,8,0,0"/>
				<DatePicker x:Name="EndDatePicker" Grid.Row="1" Grid.Column="1" IsEnabled="False" Margin="0,8,0,0"/>
			</Grid>
			<Grid Margin="0,16,0,0">
				<Button x:Name="SkipBtn" Style="{DynamicResource BtnGhost}" Content="Skip" HorizontalAlignment="Left" MinWidth="120"/>
				<Button x:Name="ConfirmBtn" Style="{DynamicResource BtnPrimary}" Content="Confirm" HorizontalAlignment="Right" MinWidth="160" IsDefault="True"/>
			</Grid>
		</StackPanel>
	</Border>
</StackPanel>
"@
	$internal = $win.FindName('InternalReplyBox'); $external = $win.FindName('ExternalReplyBox')
	$match = $win.FindName('MatchRepliesCheck'); $useSched = $win.FindName('UseScheduleCheck')
	$startP = $win.FindName('StartDatePicker'); $endP = $win.FindName('EndDatePicker')
	$startP.SelectedDate = [DateTime]::Now; $endP.SelectedDate = [DateTime]::Now
	$internal.Add_TextChanged({ if ($match.IsChecked -eq $true) { $external.Text = $internal.Text } }.GetNewClosure())
	$external.Add_TextChanged({ if ($match.IsChecked -eq $true) { $internal.Text = $external.Text } }.GetNewClosure())
	$useSched.Add_Checked({ $startP.IsEnabled = $true; $endP.IsEnabled = $true }.GetNewClosure())
	$useSched.Add_Unchecked({ $startP.IsEnabled = $false; $endP.IsEnabled = $false }.GetNewClosure())
	$win.Tag = @{ Skip = $true }
	$win.FindName('ConfirmBtn').Add_Click({
		if ($useSched.IsChecked -eq $true) {
			$schedErr = Test-AutoReplySchedule $startP.SelectedDate $endP.SelectedDate
			if ($schedErr) { Show-Notice 'Check the dates' $schedErr 'Warn'; return }
		}
		$win.Tag = @{ Skip = $false; Internal = $internal.Text; External = $external.Text; UseSchedule = ($useSched.IsChecked -eq $true); Start = $startP.SelectedDate; End = $endP.SelectedDate }
		$win.Close()
	}.GetNewClosure())
	$win.FindName('SkipBtn').Add_Click({ $win.Close() }.GetNewClosure())
	return $win
}

function Terminate-Disable-ADAndEmailAccounts {
	# Don't gate the whole dialog on AD: you can terminate EMAIL only (no AD tools needed). AD
	# availability is checked below, only when "Block AD" is actually ticked.
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Terminate-Disable-ADAndEmailAccounts.txt"
	Write-Host "Running Terminate-Disable-ADAndEmailAccounts script..."
	$progressBar1.Value = 10

	# Disable one on-prem AD account (idempotent - reports if already disabled).
	function Disable-OneAd([string]$username) {
		Import-Module ActiveDirectory
		$adUser = Get-ADUser -Identity $username -Properties Enabled -ErrorAction Stop
		if ($adUser.Enabled -eq $false) { Write-Host "$username is already disabled in AD." -ForegroundColor Yellow; return }
		Disable-ADAccount -Identity $username -ErrorAction Stop
		Write-Host "Disabled AD account $username." -ForegroundColor Cyan
	}

	# The full email offboarding for one mailbox. Throws if the mailbox can't be found. All steps are
	# attempted (so licenses/MFA still get cleaned up even if an earlier one hiccups), but the three that
	# actually LOCK THE PERSON OUT - reset password, revoke sessions, disable the cloud account - are
	# tracked, and if any of them failed the function THROWS at the end. That way a row never reports
	# "Disabled" while the account is really still usable (the fired-employee risk).
	function Disable-OneEmail([string]$email) {
		$mailbox = Get-Mailbox -Identity $email -ErrorAction Stop
		Set-Mailbox -Identity $email -Type Shared -ErrorAction Stop
		Write-Host "Converted $email to a shared mailbox." -ForegroundColor Cyan
		$critical = @()
		try { $pm = Get-MgUserAuthenticationPasswordMethod -UserId $email -ErrorAction Stop; Reset-MgUserAuthenticationMethodPassword -UserId $email -AuthenticationMethodId $pm.Id -ErrorAction Stop | Out-Null; Write-Host "  reset password." } catch { Write-Host "  couldn't reset password: $($_.Exception.Message)" -ForegroundColor Yellow; $critical += "reset the password ($($_.Exception.Message))" }
		try { Revoke-MgUserSignInSession -UserId $email -ErrorAction Stop | Out-Null; Write-Host "  revoked sessions." } catch { Write-Host "  couldn't revoke sessions: $($_.Exception.Message)" -ForegroundColor Yellow; $critical += "revoke sessions ($($_.Exception.Message))" }
		try { Update-MgUser -UserId $email -AccountEnabled:$false -ErrorAction Stop; Write-Host "  disabled the cloud account." } catch { Write-Host "  couldn't disable cloud account: $($_.Exception.Message)" -ForegroundColor Yellow; $critical += "disable the cloud account ($($_.Exception.Message))" }
		Remove-UserLicenses $email
		try { $n = Clear-UserAuthMethods $email; if ($n -gt 0) { Write-Host "  removed $n MFA method(s)." } else { Write-Host "  no MFA methods to remove." } } catch { Write-Host "  couldn't clear MFA methods: $($_.Exception.Message)" -ForegroundColor Yellow }
		if ($critical.Count) { throw "the account may NOT be fully blocked - couldn't " + ($critical -join '; ') + ". Check it in the admin center." }
	}

	function Invoke-AutoReplyPrompt([string]$email) {
		$d = New-TermAutoReplyDialog $email
		[void]$d.ShowDialog()
		$r = $d.Tag
		if (-not $r.Skip) {
			try {
				if ($r.UseSchedule) { Set-MailboxAutoReplyConfiguration -Identity $email -AutoReplyState Scheduled -StartTime $r.Start -EndTime $r.End -InternalMessage $r.Internal -ExternalMessage $r.External -ExternalAudience All -Confirm:$false -ErrorAction Stop }
				else { Set-MailboxAutoReplyConfiguration -Identity $email -AutoReplyState Enabled -InternalMessage $r.Internal -ExternalMessage $r.External -ExternalAudience All -Confirm:$false -ErrorAction Stop }
				Write-Host "  set auto-reply for $email." -ForegroundColor Cyan
			} catch { Write-Host "  couldn't set auto-reply: $($_.Exception.Message)" -ForegroundColor Yellow }
		}
	}

	# Focused prompt (owned by this dialog) to give someone access to the offboarded mailbox -
	# grants FullAccess + SendAs, same as Block-User. Replaces reusing the whole Add-MailboxMember
	# window (which opened behind this dialog and could be missed). Add several, then Done/close.
	function Invoke-AddMemberPrompt([string]$email) {
		# Add people ONE AT A TIME: type an address, click Add, and it re-asks for the next one while
		# listing everyone added so far, until you click Done / Skip. (Pasting several at once still
		# works, but the flow is one-at-a-time.) $addedAll is a List so the nested handler can append.
		$addedAll = [System.Collections.Generic.List[string]]::new()
		function OnTermAddMemberClick {
			$names = @($addMemberBox.Text -split '[;,\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
			if (-not $names.Count) { return }
			foreach ($who in $names) {
				try {
					Add-MailboxPermission -Identity $email -User $who -AccessRights FullAccess -InheritanceType All -AutoMapping $true -ErrorAction Stop | Out-Null
					Add-RecipientPermission -Identity $email -Trustee $who -AccessRights SendAs -Confirm:$false -ErrorAction Stop | Out-Null
					Write-Host "  gave $who access (FullAccess + SendAs) to $email." -ForegroundColor Cyan
					if (-not ($addedAll -contains $who)) { [void]$addedAll.Add($who) }
				} catch { Write-Host "  couldn't give $who access to $email`: $($_.Exception.Message)" -ForegroundColor Yellow }
			}
			$addMemberBox.Text = ''
			if ($addedAll.Count) { $addMemberHint.Text = "Added so far ($($addedAll.Count)): $($addedAll -join ', ').`nAdd the next person below, or click Done when you're finished." }
			try { $addMemberBox.Focus() } catch {}
		}
		$d = New-BlockAddMemberDialog
		try { $d.Owner = $form } catch {}
		$addMemberBox = $d.FindName('AddMemberBox')
		$addMemberHint = $d.FindName('AddMemberHint')
		Enable-RecipientAutocomplete $addMemberBox 'User'
		Set-FieldWatermark $addMemberBox 'Email address'
		$d.FindName('AddMemberBtn').Add_Click({ OnTermAddMemberClick })
		$d.FindName('AddMemberDoneBtn').Add_Click({ $d.Close() })
		[void]$d.ShowDialog()
	}

	function OnBlockButtonClick {
		$email = $emailInput.Text.Trim(); $adUser = $adUserInput.Text.Trim()
		$blockEmail = ($blockEmailCheck.IsChecked -eq $true); $blockAd = ($blockAdCheck.IsChecked -eq $true)
		if (-not ($blockEmail -or $blockAd)) { Show-Notice 'Nothing selected' 'Tick Block email and/or Block AD first.' 'Warn'; return }
		if ($blockEmail -and -not $email) { Show-Notice 'Missing info' 'Enter the email to block.' 'Warn'; return }
		if ($blockAd -and -not $adUser) { Show-Notice 'Missing info' 'Enter the AD username to block.' 'Warn'; return }
		if ($blockEmail -and -not (Test-SignedIn)) { Show-Notice 'Not connected' "Connect to the tenant first (top bar) to block email." 'Warn'; return }
		$adSkipped = $false
		if ($blockAd -and -not (Test-ADModule)) {
			# Only AD selected but no AD module: one clear message, nothing to do.
			if (-not $blockEmail) { Show-Notice 'Active Directory not available' $script:ADMissingMsg 'Warn'; $progressBar1.Value = 0; return }
			$blockAd = $false; $adSkipped = $true   # do the email part; note the skip in the summary
		}
		$progressBar1.Value = 20
		$errors = @()
		$didEmail = $false; $didAd = $false
		if ($adSkipped) { $errors += "AD ($adUser): skipped - the Active Directory module isn't available on this computer." }
		if ($blockAd) { try { Disable-OneAd $adUser; $didAd = $true } catch { Write-Host "AD error for $adUser`: $($_.Exception.Message)" -ForegroundColor Red; $errors += "AD ($adUser): $($_.Exception.Message)" } }
		$progressBar1.Value = 50
		if ($blockEmail) {
			try {
				Disable-OneEmail $email
				if ($addMembersCheck.IsChecked -eq $true) { Invoke-AddMemberPrompt $email }
				if ($addAutoReplyCheck.IsChecked -eq $true) { Invoke-AutoReplyPrompt $email }
				Write-Host "Finished blocking $email." -ForegroundColor Cyan
				$didEmail = $true
			} catch { Write-Host "Email error for $email`: $($_.Exception.Message)" -ForegroundColor Red; $errors += "Email ($email): $($_.Exception.Message)" }
		}
		$progressBar1.Value = 0
		# Report only what ACTUALLY succeeded, so a failed/skipped step never reads as "Blocked".
		$doneParts = @()
		if ($didEmail) { $doneParts += $email }
		if ($didAd) { $doneParts += $adUser }
		$done = @($doneParts | Where-Object { $_ }) -join ' / '
		if ($done -and $errors.Count) { Show-Notice 'Finished with some errors' ("Blocked $done.`n`nBut:`n`n" + ($errors -join "`n")) 'Warn' }
		elseif ($done) { Show-Notice 'Done' "Blocked $done." 'Info' }
		elseif ($errors.Count) { Show-Notice "Couldn't block" ("Nothing was blocked:`n`n" + ($errors -join "`n")) 'Error' }
		else { Show-Notice 'Nothing done' 'Nothing to block.' 'Warn' }
	}
	function OnOpenTemplateButtonClick {
		$progressBar1.Value = 10
		$csv = ".\Templates\Terminate-Disable-ADAndEmailAccounts.csv"
		if (-not (Test-Path $csv)) { "Username,Email" | Out-File $csv -Encoding UTF8 }
		Invoke-Item $csv
		$progressBar1.Value = 0
		CheckForErrors
	}
	function OnDisableBulkButtonClick {
		$csv = ".\Templates\Terminate-Disable-ADAndEmailAccounts.csv"
		if (-not (Test-Path $csv)) { Show-Notice 'No template' 'Use Open Template to create the CSV first.' 'Warn'; return }
		$rows = @(Import-Csv $csv)
		if (-not $rows.Count) { Show-Notice 'Empty template' 'The template has no rows.' 'Warn'; return }
		$blockEmail = ($blockEmailCheck.IsChecked -eq $true); $blockAd = ($blockAdCheck.IsChecked -eq $true)
		if (-not ($blockEmail -or $blockAd)) { Show-Notice 'Nothing selected' 'Tick Block email and/or Block AD first.' 'Warn'; return }
		if ($blockEmail -and -not (Test-SignedIn)) { Show-Notice 'Not connected' "Connect to the tenant first (top bar) to block email." 'Warn'; return }
		if ($blockAd -and -not (Test-ADModule)) {
			if (-not $blockEmail) { Show-Notice 'Active Directory not available' $script:ADMissingMsg 'Warn'; return }
			Show-Notice 'Active Directory not available' ($script:ADMissingMsg + "`n`nContinuing with the email part only.") 'Warn'; $blockAd = $false
		}
		$done = [System.Collections.Generic.List[string]]::new()
		$failed = [System.Collections.Generic.List[string]]::new()
		$skippedRows = 0
		$tot = $rows.Count; $i = 0
		Lock-ScriptWindow $form
		foreach ($row in $rows) {
			$i++
			$u = "$($row.Username)".Trim(); $e = "$($row.Email)".Trim()
			if (-not $u -and -not $e) { $skippedRows++; continue }   # blank row - don't count it as disabled
			$who = if ($e) { $e } elseif ($u) { $u }
			Step-Progress "Disabling $who..." $i $tot
			Write-Host "Processing $who..."
			try {
				# Track whether this row actually DID anything, so a row with nothing to do (e.g. only a
				# username but Block AD is off/unavailable) isn't reported as "Disabled".
				$ran = $false
				if ($blockAd -and $u) { Disable-OneAd $u; $ran = $true }
				if ($blockEmail -and $e) {
					Disable-OneEmail $e
					if ($addMembersCheck.IsChecked -eq $true) { Invoke-AddMemberPrompt $e }
					if ($addAutoReplyCheck.IsChecked -eq $true) { Invoke-AutoReplyPrompt $e }
					$ran = $true
				}
				if ($ran) { $done.Add($who) }
				else { $skippedRows++; Write-Host "  skipped $who - nothing selected applied to this row." -ForegroundColor Yellow }
			} catch { Write-Host "Failed $who`: $($_.Exception.Message)" -ForegroundColor Red; $failed.Add("$who - $($_.Exception.Message)") }
		}
		if ($skippedRows) { Write-Host "Skipped $skippedRows row(s) with nothing to do." -ForegroundColor Yellow }
		Show-AccountResults 'Disable AD & Email accounts' $done $failed -DoneWord 'Disabled' -FailWord 'Failed'
		Unlock-ScriptWindow
	}

	$form = New-DisableAccountsDialog
	$emailInput = $form.FindName('EmailInput')
	$adUserInput = $form.FindName('AdUserInput')
	Enable-ADUserAutocomplete $adUserInput
	Enable-RecipientAutocomplete $emailInput 'Mailbox'
	$blockEmailCheck = $form.FindName('BlockEmailCheck')
	$blockAdCheck = $form.FindName('BlockAdCheck')
	$addMembersCheck = $form.FindName('AddMembersCheck')
	$addAutoReplyCheck = $form.FindName('AddAutoReplyCheck')
	# Enable/disable the email + AD inputs with their checkboxes.
	$blockEmailCheck.Add_Checked({ $emailInput.IsEnabled = $true; $addMembersCheck.IsEnabled = $true; $addAutoReplyCheck.IsEnabled = $true })
	$blockEmailCheck.Add_Unchecked({ $emailInput.IsEnabled = $false; $addMembersCheck.IsEnabled = $false; $addAutoReplyCheck.IsEnabled = $false })
	$blockAdCheck.Add_Checked({ $adUserInput.IsEnabled = $true })
	$blockAdCheck.Add_Unchecked({ $adUserInput.IsEnabled = $false })
	$form.FindName('BlockBtn').Add_Click({ OnBlockButtonClick })
	$form.FindName('OpenTemplateBtn').Add_Click({ OnOpenTemplateButtonClick })
	$form.FindName('DisableBulkBtn').Add_Click({ OnDisableBulkButtonClick })
	Write-Host "Loaded DisableAccountsForm."
	$progressBar1.Value = 0
	[void]$form.ShowDialog()
	Stop-Transcript
}

