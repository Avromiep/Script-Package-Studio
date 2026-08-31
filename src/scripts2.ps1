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
	Show-Notice $title ($parts -join "`n`n") $kind
	$progressBar1.Value = 0
}

# Refuse to create over an existing account. These throw a clear "already exists" message
# (caught by the per-row handler, recorded in the summary) BEFORE any New-ADUser / New-MgUser
# runs, so an existing user is never overwritten / re-provisioned / password-reset.
function Assert-ADUserNotExists([string]$SamAccountName, [string]$UserPrincipalName) {
	$existing = $null
	try { $existing = Get-ADUser -Filter "SamAccountName -eq '$SamAccountName'" -ErrorAction Stop | Select-Object -First 1 } catch { $existing = $null }
	if ($existing) { throw "an AD account named '$SamAccountName' already exists - skipped so it isn't overwritten" }
	if ($UserPrincipalName) {
		$byUpn = $null
		try { $byUpn = Get-ADUser -Filter "UserPrincipalName -eq '$UserPrincipalName'" -ErrorAction Stop | Select-Object -First 1 } catch { $byUpn = $null }
		if ($byUpn) { throw "an AD account with sign-in name '$UserPrincipalName' already exists - skipped so it isn't overwritten" }
	}
}
function Assert-MgUserNotExists([string]$UserPrincipalName) {
	$u = $null
	try { $u = Get-MgUser -Filter "userPrincipalName eq '$UserPrincipalName'" -ErrorAction Stop | Select-Object -First 1 } catch { $u = $null }
	if (-not $u) { try { $u = Get-MgUser -Filter "mail eq '$UserPrincipalName'" -ErrorAction Stop | Select-Object -First 1 } catch { $u = $null } }
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
	New-StyledDialog -Title 'Add members to the blocked mailbox' -Icon '&#xEDBB;' -BodyXaml @'
<StackPanel Margin="16" Width="320">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<Grid>
				<Grid.ColumnDefinitions>
					<ColumnDefinition Width="70"/><ColumnDefinition Width="*"/>
				</Grid.ColumnDefinitions>
				<TextBlock Text="Member" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
				<TextBox x:Name="AddMemberBox" Grid.Column="1"/>
			</Grid>
			<Button x:Name="AddMemberBtn" Style="{DynamicResource BtnPrimary}" Content="Add" Margin="0,14,0,0" IsDefault="True"/>
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
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Block-User.txt"
	Write-Host "Running Block-User script..."
	$progressBar1.Value = 10
	function OnBlockButtonClick {
		Write-Host "Block button clicked."
		$progressBar1.Value = 10
		if ($adCheckBox.IsChecked -eq $true) {
			Import-Module ActiveDirectory
			$user = $adNameInputBox.Text
			$progressBar1.Value = 20
			$samAccountName = $adNameInputBox.Text
			Disable-ADAccount -Identity $samAccountName
			Write-Host "Disabled $samAccountName. If there are any erros on this point then $samAccountName may not exist."
			$progressBar1.Value = 30
			CheckForErrors
		}
		if ($emailCheckBox.IsChecked -eq $true) {
			$user = $emailInputBox.Text
			Set-Mailbox -Identity $user -Type Shared
			Write-Host "`nConverted $user to shared mailbox" -ForegroundColor Cyan
			$progressBar1.Value = 40
			$passwordMethod = Get-MgUserAuthenticationPasswordMethod -UserId $user
			Reset-MgUserAuthenticationMethodPassword -UserId $user -AuthenticationMethodId $passwordMethod.Id
			Write-Host "Reset password for $user" -ForegroundColor Cyan
			$progressBar1.Value = 50
			Revoke-MgUserSignInSession -UserId $user
			Write-Host "Revoked $user's sessions."
			Update-MgUser -UserId $user -AccountEnabled:$false
			Write-Host "Disabled $user account" -ForegroundColor Cyan -NoNewline
			$progressBar1.Value = 60
			$license = Get-MgUserLicenseDetail -UserId $user
			if ($license) {
				Set-MgUserLicense -UserId $user -RemoveLicenses @($license.SkuId) -AddLicenses @()
				Write-Host "Removed licenses from $user" -ForegroundColor Cyan
			} else {
				Write-Host "$user has no licenses to remove." -ForegroundColor Cyan
			}
			$progressBar1.Value = 70
			$phoneMethod = Get-MgUserAuthenticationPhoneMethod -UserId $user
			if ($null -eq $phoneMethod) {
				Write-Host "$user doesn't have a 2FA phone number" -ForegroundColor Cyan
			} else {
				Remove-MgUserAuthenticationPhoneMethod -UserId $user -PhoneAuthenticationMethodId $phoneMethod.Id
				Write-Host "Removed 2FA phone number from $user" -ForegroundColor Cyan
			}
			$progressBar1.Value = 80
			CheckForErrors
			if ($addMembersCheckBox.IsChecked -eq $true) {
				Write-Host "addMembersCheckBox is checked, loading AddMember form..."
				function OnAddMemberButtonClick {
					$addUser = $addMemberBox.Text
					Add-MailboxPermission -Identity $user -User $addUser -AccessRights FullAccess -InheritanceType All -AutoMapping $true
					Add-RecipientPermission -Identity $user -Trustee $addUser -AccessRights SendAs -Confirm:$false
					Write-Host "Added $addUser to $user" -ForegroundColor Cyan
					$addMemberBox.Text = ""
					CheckForErrors
					OperationComplete
				}

				$AddMemberForm = New-BlockAddMemberDialog
				$addMemberBox = $AddMemberForm.FindName('AddMemberBox')
				$AddMemberForm.FindName('AddMemberBtn').Add_Click({ OnAddMemberButtonClick })
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
	$adNameInputBox = $ScriptForm2.FindName('AdNameInput')
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
function New-ConvertGroupDialog {
	New-StyledDialog -Title 'Convert-UnifiedGroupToDistributionList' -Icon '&#xE16F;' -BodyXaml @'
<StackPanel Margin="16" Width="360">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<StackPanel Orientation="Horizontal">
				<RadioButton x:Name="SingleChip" Style="{DynamicResource Chip}" GroupName="ConvertMode" Content="Single" IsChecked="True"/>
				<RadioButton x:Name="BulkChip" Style="{DynamicResource Chip}" GroupName="ConvertMode" Content="Bulk" Margin="8,0,0,0"/>
			</StackPanel>
			<StackPanel x:Name="SinglePanel" Margin="0,14,0,0">
				<Grid>
					<Grid.ColumnDefinitions>
						<ColumnDefinition Width="100"/><ColumnDefinition Width="*"/>
					</Grid.ColumnDefinitions>
					<TextBlock Text="Source address" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
					<TextBox x:Name="SourceInput" Grid.Column="1"/>
				</Grid>
				<Button x:Name="CreateBtn" Style="{DynamicResource BtnPrimary}" Content="Create" Margin="0,14,0,0"/>
			</StackPanel>
			<StackPanel x:Name="BulkPanel" Margin="0,14,0,0" Visibility="Collapsed">
				<Button x:Name="TemplateOpenBtn" Style="{DynamicResource BtnSecondary}" Content="Open Bulk txt File"/>
				<Button x:Name="CreateBulkBtn" Style="{DynamicResource BtnPrimary}" Content="Create" Margin="0,8,0,0"/>
			</StackPanel>
		</StackPanel>
	</Border>
</StackPanel>
'@
}

function Convert-UnifiedGroupToDistributionGroup {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Convert-UnifiedGroupToDistributionGroup.txt"
	Write-Host "Running Convert-UnifiedGroupToDistributionList script..."
	$progressBar1.Value = 10
	function OnCreateButtonClick {
		Write-Host "Create button clicked."
		$progressBar1.Value = 5
		$M365GroupName = $sourceInputBox.Text
		$OldGroupName = $sourceInputBox.Text -Split "@"
		$DistGroupName = $OldGroupName[0] + "-New"
		New-DistributionGroup -Name $DistGroupName
		Write-Host "Created $DistGroupName"
		$progressBar1.Value = 10
		$M365GroupMembers = Get-UnifiedGroup -Identity $M365GroupName | Get-UnifiedGroupLinks -LinkType Member | Select-Object -expandproperty PrimarySmtpAddress
		Foreach ($member in $M365GroupMembers) {
		Write-Host "Adding $member..."
		$progressBar1.Value = 20
		Add-DistributionGroupMember -Identity $DistGroupName -Member $member
		$progressBar1.Value = 80
		}
		CheckForErrors
		OperationComplete
	}

	function OnTemplateButtonClick {
		Write-Host "Open template button clicked."
		$progressBar1.Value = 10
		Invoke-Item ".\Templates\Convert-UnifiedGroupToDistributionList.txt"
		$progressBar1.Value = 0
		CheckForErrors
	}

	function OnCreateBulkButtonClick {
		Write-Host "Create bulk button clicked."
		$progressBar1.Value = 2
		Get-Content ".\Templates\Convert-UnifiedGroupToDistributionList.txt" | ForEach-Object {
			$progressBar1.Value = 5
			$OldGroupName = $_ -Split "@"
			$DistGroupName = $OldGroupName[0] + "-New"
			New-DistributionGroup -Name $DistGroupName
			Write-Host "Created $DistGroupName"
			$progressBar1.Value = 10
			$M365GroupMembers = Get-UnifiedGroup -Identity $_ | Get-UnifiedGroupLinks -LinkType Member | Select-Object -expandproperty PrimarySmtpAddress
			Foreach ($member in $M365GroupMembers) {
				Write-Host "Adding $member..."
				$progressBar1.Value = 20
				Add-DistributionGroupMember -Identity $DistGroupName -Member $member
				$progressBar1.Value = 80
			}
		}
		Write-Host "Done cycling through text file."
		CheckForErrors
		OperationComplete
	}

	$ScriptForm6 = New-ConvertGroupDialog
	$sourceInputBox = $ScriptForm6.FindName('SourceInput')
	$singlePanel = $ScriptForm6.FindName('SinglePanel')
	$bulkPanel = $ScriptForm6.FindName('BulkPanel')
	$ScriptForm6.FindName('SingleChip').Add_Checked({
		$singlePanel.Visibility = 'Visible'
		$bulkPanel.Visibility = 'Collapsed'
	})
	$ScriptForm6.FindName('BulkChip').Add_Checked({
		$singlePanel.Visibility = 'Collapsed'
		$bulkPanel.Visibility = 'Visible'
	})
	$ScriptForm6.FindName('CreateBtn').Add_Click({ OnCreateButtonClick })
	$ScriptForm6.FindName('TemplateOpenBtn').Add_Click({ OnTemplateButtonClick })
	$ScriptForm6.FindName('CreateBulkBtn').Add_Click({ OnCreateBulkButtonClick })

	Write-Host "Loaded ScriptForm6."
	$progressBar1.Value = 0

	[void]$ScriptForm6.ShowDialog()

	Stop-Transcript
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
	Install-Module -Name Microsoft.Graph -Force -AllowClobber
	$progressBar1.Value = 50
	Install-Module -Name ExchangeOnlineManagement -Force -AllowClobber
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
		$csvFile = Import-Csv -Path ".\Templates\New-ADAccounts.csv"
		$progressBar1.Value = 20
		CheckForErrors

		$created = [System.Collections.Generic.List[string]]::new()
		$failed  = [System.Collections.Generic.List[string]]::new()
		foreach ($row in $csvFile) {
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
			$progressBar1.Value = 30

			Write-Host "Creating new user $samAccountName..."
			Assert-ADUserNotExists $samAccountName $userPrincipalName
			if ($preview) { $created.Add($who); continue }
			New-ADUser -SamAccountName $samAccountName -Name $displayName -UserPrincipalName $userPrincipalName -DisplayName $displayName -AccountPassword (ConvertTo-SecureString $row.Password -AsPlainText -Force) -Enabled $true -Path $ou.DistinguishedName -GivenName $row.GivenName -Surname $row.Surname
			$progressBar1.Value = 40

			$newUser = Get-ADUser -Filter "SamAccountName -eq '$($row.SamAccountName)'"

			Write-Host "Copying attributes from source user $($sourceUser.SamAccountName) to new user $($newUser.SamAccountName)..."
			# Copy additional attributes from the source user
			Set-ADUser -Identity $row.SamAccountName -ProfilePath $sourceUser.ProfilePath
			Set-ADUser -Identity $row.SamAccountName -ScriptPath $sourceUser.ScriptPath
			Set-ADUser -Identity $row.SamAccountName -PasswordNeverExpires $sourceUser.PasswordNeverExpires
			Set-ADUser -Identity $row.SamAccountName -CannotChangePassword $sourceUser.CannotChangePassword
			$progressBar1.Value = 50

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
				$progressBar1.Value = 60

				# Add HomeDirectory and HomeDrive
				Set-ADUser -Identity $row.SamAccountName -HomeDrive $sourceUser.HomeDrive
				Set-ADUser -Identity $row.SamAccountName -HomeDirectory $homeDirectory
			} else {
				Write-Host "Source user $($sourceUser.SamAccountName) does not have a HomeDirectory. Skipping HomeDirectory creation for the new user $($newUser.SamAccountName)."
			}
			$progressBar1.Value = 70

			Write-Host "Copying group membership from source user $($sourceUser.SamAccountName) to new user $($newUser.SamAccountName)..."
			# Copy security group memberships
			$sourceGroups = Get-ADPrincipalGroupMembership -Identity $sourceUser.DistinguishedName
			foreach ($group in $sourceGroups) {
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
		$csvFile = Import-Csv -Path ".\Templates\New-ADAndEmailAccounts.csv"
		$progressBar1.Value = 30
		CheckForErrors
		$created = [System.Collections.Generic.List[string]]::new()
		$failed  = [System.Collections.Generic.List[string]]::new()
		foreach ($row in $csvFile) {
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
			$progressBar1.Value = 30

			Write-Host "Creating new user $samAccountName..."
			Assert-ADUserNotExists $row.SamAccountName $userPrincipalName
			Assert-MgUserNotExists $emailAddress
			if ($preview) { $created.Add($who); continue }
			New-ADUser -SamAccountName $row.SamAccountName -Name $displayName -UserPrincipalName $userPrincipalName -DisplayName $displayName -AccountPassword (ConvertTo-SecureString $row.Password -AsPlainText -Force) -Enabled $true -Path $ou.DistinguishedName -GivenName $row.GivenName -Surname $row.Surname
			$progressBar1.Value = 40

			$newUser = Get-ADUser -Filter "SamAccountName -eq '$($row.SamAccountName)'"

			Write-Host "Copying attributes from source user $($sourceUser.SamAccountName) to new user $($newUser.SamAccountName)..."
			# Copy additional attributes from the source user
			Set-ADUser -Identity $row.SamAccountName -ProfilePath $sourceUser.ProfilePath
			Set-ADUser -Identity $row.SamAccountName -ScriptPath $sourceUser.ScriptPath
			Set-ADUser -Identity $row.SamAccountName -PasswordNeverExpires $sourceUser.PasswordNeverExpires
			Set-ADUser -Identity $row.SamAccountName -CannotChangePassword $sourceUser.CannotChangePassword
			$progressBar1.Value = 50

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
				$progressBar1.Value = 60

				# Add HomeDirectory and HomeDrive
				Set-ADUser -Identity $row.SamAccountName -HomeDrive $sourceUser.HomeDrive
				Set-ADUser -Identity $row.SamAccountName -HomeDirectory $homeDirectory
			} else {
				Write-Host "Source user $($sourceUser.SamAccountName) does not have a HomeDirectory. Skipping HomeDirectory creation for the new user $($newUser.SamAccountName)."
			}
			$progressBar1.Value = 70

			Write-Host "Copying group membership from source user $($sourceUser.SamAccountName) to new user $($newUser.SamAccountName)..."
			# Copy security group memberships
			$sourceGroups = Get-ADPrincipalGroupMembership -Identity $sourceUser.DistinguishedName
			foreach ($group in $sourceGroups) {
				# Check if the new user is already a member of the group
				$isMember = Get-ADGroupMember -Identity $group.DistinguishedName -Recursive | Where-Object { $_.SamAccountName -eq $row.SamAccountName }
				if ($null -eq $isMember) {
					# Add the new user to the group if they are not already a member
					Add-ADGroupMember -Identity $group.DistinguishedName -Members $row.SamAccountName
				}
			}
			$progressBar1.Value = 80

			# Create mailbox
			$passwordProfile = @{
				ForceChangePasswordNextSignIn = $false
				Password = $row.Password
			}

			New-MgUser -AccountEnabled -PasswordProfile $passwordProfile -DisplayName $displayName -GivenName $row.GivenName -Surname $row.Surname -UserPrincipalName $emailAddress -MailNickname $row.SamAccountName -UsageLocation US
			$progressBar1.Value = 90

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
		Import-Csv ".\Templates\New-EmailAccounts.csv" | ForEach-Object {
			$who = if ($_.EmailAddress) { "$($_.EmailAddress)" } else { '(blank row)' }
			try {
			$progressBar1.Value = 10
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

			$progressBar1.Value = 30

			Assert-MgUserNotExists $emailAddress
			if ($preview) { $created.Add($who); return }
			New-MgUser -AccountEnabled -PasswordProfile $passwordProfile -DisplayName $displayName -GivenName $firstName -Surname $lastName -UserPrincipalName $emailAddress -MailNickname $mailNickname -UsageLocation US
			$progressBar1.Value = 60

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
			$progressBar1.Value = 90
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

	# Remove every re-registerable auth method (leaves the password), optionally revoke sessions.
	# Returns the count removed; throws only if the user can't be read at all.
	function Clear-MfaFor([string]$u) {
		$methods = Get-MgUserAuthenticationMethod -UserId $u -ErrorAction Stop
		$removed = 0
		foreach ($m in $methods) {
			$type = "$($m.AdditionalProperties['@odata.type'])"
			try {
				switch -Wildcard ($type) {
					'*phoneAuthenticationMethod'                  { Remove-MgUserAuthenticationPhoneMethod -UserId $u -PhoneAuthenticationMethodId $m.Id -ErrorAction Stop; $removed++ }
					'*microsoftAuthenticatorAuthenticationMethod' { Remove-MgUserAuthenticationMicrosoftAuthenticatorMethod -UserId $u -MicrosoftAuthenticatorAuthenticationMethodId $m.Id -ErrorAction Stop; $removed++ }
					'*softwareOathAuthenticationMethod'           { Remove-MgUserAuthenticationSoftwareOathMethod -UserId $u -SoftwareOathAuthenticationMethodId $m.Id -ErrorAction Stop; $removed++ }
					'*fido2AuthenticationMethod'                  { Remove-MgUserAuthenticationFido2Method -UserId $u -Fido2AuthenticationMethodId $m.Id -ErrorAction Stop; $removed++ }
					'*windowsHelloForBusinessAuthenticationMethod'{ Remove-MgUserAuthenticationWindowsHelloForBusinessMethod -UserId $u -WindowsHelloForBusinessAuthenticationMethodId $m.Id -ErrorAction Stop; $removed++ }
					'*emailAuthenticationMethod'                  { Remove-MgUserAuthenticationEmailMethod -UserId $u -EmailAuthenticationMethodId $m.Id -ErrorAction Stop; $removed++ }
					'*temporaryAccessPassAuthenticationMethod'    { Remove-MgUserAuthenticationTemporaryAccessPassMethod -UserId $u -TemporaryAccessPassAuthenticationMethodId $m.Id -ErrorAction Stop; $removed++ }
					default { }   # passwordAuthenticationMethod / anything unknown: leave alone
				}
			} catch { Write-Host "  couldn't remove $type for $u`: $($_.Exception.Message)" -ForegroundColor Yellow }
		}
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
		$progressBar1.Value = 10
		$created = [System.Collections.Generic.List[string]]::new()
		$failed  = [System.Collections.Generic.List[string]]::new()
		Import-Csv ".\Templates\Reset-MFA.csv" | ForEach-Object {
			$u = "$($_.Email)".Trim()
			if (-not $u) { return }
			try { $n = Clear-MfaFor $u; $created.Add("$u ($n cleared)") }
			catch { Write-Host "Failed on $u`: $($_.Exception.Message)" -ForegroundColor Red; $failed.Add("$u - $($_.Exception.Message)") }
		}
		Show-AccountResults 'Reset MFA' $created $failed -DoneWord 'Reset' -FailWord 'Failed'
	}

	$form = New-ResetMfaDialog
	$emailInput = $form.FindName('EmailInput')
	$revokeCheck = $form.FindName('RevokeCheck')
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
			<Button x:Name="ApplyBtn" Style="{DynamicResource BtnPrimary}" Content="Apply" Margin="0,14,0,0"/>
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
	}
	function OnApplyButtonClick {
		$u = $userInput.Text.Trim()
		if (-not $u) { Show-Notice 'Missing info' 'Enter a user email first.' 'Warn'; return }
		$mode = Get-Mode; $skus = Resolve-Skus $mode
		if ($mode -eq 'Swap' -and $skus.Add -eq $skus.Remove) { Show-Notice 'Nothing to do' 'The two licenses are the same - pick different ones to swap.' 'Warn'; return }
		$progressBar1.Value = 40
		try { Set-OneLicense $u $skus.Add $skus.Remove; Write-Host "$mode license for $u." -ForegroundColor Cyan; Show-Notice 'License updated' "$mode complete for `"$u`"." 'Info' }
		catch { Show-Notice 'License change failed' "Couldn't update licenses for `"$u`":`n`n$($_.Exception.Message)" 'Error' }
		$progressBar1.Value = 0
	}
	function OnOpenTemplateButtonClick { $progressBar1.Value = 10; Invoke-Item ".\Templates\Set-License.csv"; $progressBar1.Value = 0; CheckForErrors }
	function OnBulkButtonClick {
		$mode = Get-Mode; $skus = Resolve-Skus $mode
		$preview = ($previewCheck.IsChecked -eq $true)
		$progressBar1.Value = 10
		$created = [System.Collections.Generic.List[string]]::new()
		$failed  = [System.Collections.Generic.List[string]]::new()
		Import-Csv ".\Templates\Set-License.csv" | ForEach-Object {
			$u = "$($_.Email)".Trim()
			if (-not $u) { return }
			if ($preview) { $created.Add("$u ($mode)"); return }
			try { Set-OneLicense $u $skus.Add $skus.Remove; $created.Add("$u ($mode)") }
			catch { Write-Host "Failed on $u`: $($_.Exception.Message)" -ForegroundColor Red; $failed.Add("$u - $($_.Exception.Message)") }
		}
		Show-AccountResults "Set-License ($mode)" $created $failed -Preview:$preview -DoneWord 'Updated' -FailWord 'Failed'
	}

	$form = New-SetLicenseDialog
	$userInput = $form.FindName('UserInput')
	$assignChip = $form.FindName('AssignChip'); $removeChip = $form.FindName('RemoveChip'); $swapChip = $form.FindName('SwapChip')
	$fromLabel = $form.FindName('FromLabel'); $fromCombo = $form.FindName('FromCombo')
	$toLabel = $form.FindName('ToLabel'); $toCombo = $form.FindName('ToCombo')
	$applyButton = $form.FindName('ApplyBtn'); $bulkButton = $form.FindName('BulkBtn')
	$previewCheck = $form.FindName('PreviewCheck')
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
	New-StyledDialog -Title 'Disable-ADAndEmailAccounts' -Icon '&#xEEE3;' -BodyXaml @'
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
					<CheckBox x:Name="AddMembersCheck" Content="Grant a delegate Full Access + Send As" IsChecked="True" Margin="0,8,0,0"/>
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

# Sub-dialog: optionally grant one delegate Full Access + Send As. Returns @{ Skip; Member }.
function New-TermAddMemberDialog([string]$Email) {
	$win = New-StyledDialog -Title "Grant access - $Email" -Icon '&#xED93;' -BodyXaml @"
<StackPanel Margin="16" Width="360">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<TextBlock Text="Give someone Full Access + Send As on this mailbox, or skip." Style="{DynamicResource Dim}" TextWrapping="Wrap"/>
			<Grid Margin="0,10,0,0">
				<Grid.ColumnDefinitions><ColumnDefinition Width="70"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
				<TextBlock Text="Member" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
				<TextBox x:Name="MemberInput" Grid.Column="1"/>
			</Grid>
			<Grid Margin="0,14,0,0">
				<Button x:Name="SkipBtn" Style="{DynamicResource BtnGhost}" Content="Skip" HorizontalAlignment="Left" MinWidth="100"/>
				<Button x:Name="AddBtn" Style="{DynamicResource BtnPrimary}" Content="Add" HorizontalAlignment="Right" MinWidth="120" IsDefault="True"/>
			</Grid>
		</StackPanel>
	</Border>
</StackPanel>
"@
	$win.Tag = @{ Skip = $true; Member = '' }
	$win.FindName('AddBtn').Add_Click({ param($s, $e) $w = [System.Windows.Window]::GetWindow($s); $w.Tag = @{ Skip = $false; Member = $w.FindName('MemberInput').Text.Trim() }; $w.Close() })
	$win.FindName('SkipBtn').Add_Click({ param($s, $e) [System.Windows.Window]::GetWindow($s).Close() })
	return $win
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
		$win.Tag = @{ Skip = $false; Internal = $internal.Text; External = $external.Text; UseSchedule = ($useSched.IsChecked -eq $true); Start = $startP.SelectedDate; End = $endP.SelectedDate }
		$win.Close()
	}.GetNewClosure())
	$win.FindName('SkipBtn').Add_Click({ $win.Close() }.GetNewClosure())
	return $win
}

function Disable-ADAndEmailAccounts {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Disable-ADAndEmailAccounts.txt"
	Write-Host "Running Disable-ADAndEmailAccounts script..."
	$progressBar1.Value = 10

	# Disable one on-prem AD account (idempotent - reports if already disabled).
	function Disable-OneAd([string]$username) {
		Import-Module ActiveDirectory
		$adUser = Get-ADUser -Identity $username -Properties Enabled -ErrorAction Stop
		if ($adUser.Enabled -eq $false) { Write-Host "$username is already disabled in AD." -ForegroundColor Yellow; return }
		Disable-ADAccount -Identity $username -ErrorAction Stop
		Write-Host "Disabled AD account $username." -ForegroundColor Cyan
	}

	# The full email offboarding for one mailbox. Throws if the mailbox can't be found; the
	# individual cloud steps tolerate their own failures so one hiccup doesn't stop the rest.
	function Disable-OneEmail([string]$email) {
		$mailbox = Get-Mailbox -Identity $email -ErrorAction Stop
		Set-Mailbox -Identity $email -Type Shared -ErrorAction Stop
		Write-Host "Converted $email to a shared mailbox." -ForegroundColor Cyan
		try { $pm = Get-MgUserAuthenticationPasswordMethod -UserId $email -ErrorAction Stop; Reset-MgUserAuthenticationMethodPassword -UserId $email -AuthenticationMethodId $pm.Id -ErrorAction Stop | Out-Null; Write-Host "  reset password." } catch { Write-Host "  couldn't reset password: $($_.Exception.Message)" -ForegroundColor Yellow }
		try { Revoke-MgUserSignInSession -UserId $email -ErrorAction Stop | Out-Null; Write-Host "  revoked sessions." } catch { Write-Host "  couldn't revoke sessions: $($_.Exception.Message)" -ForegroundColor Yellow }
		try { Update-MgUser -UserId $email -AccountEnabled:$false -ErrorAction Stop; Write-Host "  disabled the cloud account." } catch { Write-Host "  couldn't disable cloud account: $($_.Exception.Message)" -ForegroundColor Yellow }
		try { $lic = Get-MgUserLicenseDetail -UserId $email -ErrorAction Stop; if ($lic) { Set-MgUserLicense -UserId $email -RemoveLicenses @($lic.SkuId) -AddLicenses @() -ErrorAction Stop | Out-Null; Write-Host "  removed licenses." } else { Write-Host "  no licenses to remove." } } catch { Write-Host "  couldn't remove licenses: $($_.Exception.Message)" -ForegroundColor Yellow }
		try { $ph = Get-MgUserAuthenticationPhoneMethod -UserId $email -ErrorAction SilentlyContinue; if ($ph) { Remove-MgUserAuthenticationPhoneMethod -UserId $email -PhoneAuthenticationMethodId $ph.Id -ErrorAction Stop; Write-Host "  removed 2FA phone." } else { Write-Host "  no 2FA phone." } } catch { Write-Host "  couldn't remove 2FA phone: $($_.Exception.Message)" -ForegroundColor Yellow }
	}

	function Invoke-AddMemberPrompt([string]$email) {
		$d = New-TermAddMemberDialog $email
		[void]$d.ShowDialog()
		$r = $d.Tag
		if (-not $r.Skip -and $r.Member) {
			try {
				Add-MailboxPermission -Identity $email -User $r.Member -AccessRights FullAccess -InheritanceType All -AutoMapping $true -ErrorAction Stop | Out-Null
				Add-RecipientPermission -Identity $email -Trustee $r.Member -AccessRights SendAs -Confirm:$false -ErrorAction Stop | Out-Null
				Write-Host "  granted $($r.Member) Full Access + Send As on $email." -ForegroundColor Cyan
			} catch { Write-Host "  couldn't grant access to $($r.Member): $($_.Exception.Message)" -ForegroundColor Yellow }
		}
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

	function OnBlockButtonClick {
		$email = $emailInput.Text.Trim(); $adUser = $adUserInput.Text.Trim()
		$blockEmail = ($blockEmailCheck.IsChecked -eq $true); $blockAd = ($blockAdCheck.IsChecked -eq $true)
		if (-not ($blockEmail -or $blockAd)) { Show-Notice 'Nothing selected' 'Tick Block email and/or Block AD first.' 'Warn'; return }
		if ($blockEmail -and -not $email) { Show-Notice 'Missing info' 'Enter the email to block.' 'Warn'; return }
		if ($blockAd -and -not $adUser) { Show-Notice 'Missing info' 'Enter the AD username to block.' 'Warn'; return }
		if ($blockEmail -and -not (Get-MgContext)) { Show-Notice 'Not connected' "Connect to the tenant first (top bar) to block email." 'Warn'; return }
		$progressBar1.Value = 20
		$errors = @()
		if ($blockAd) { try { Disable-OneAd $adUser } catch { Write-Host "AD error for $adUser`: $($_.Exception.Message)" -ForegroundColor Red; $errors += "AD ($adUser): $($_.Exception.Message)" } }
		$progressBar1.Value = 50
		if ($blockEmail) {
			try {
				Disable-OneEmail $email
				if ($addMembersCheck.IsChecked -eq $true) { Invoke-AddMemberPrompt $email }
				if ($addAutoReplyCheck.IsChecked -eq $true) { Invoke-AutoReplyPrompt $email }
				Write-Host "Finished blocking $email." -ForegroundColor Cyan
			} catch { Write-Host "Email error for $email`: $($_.Exception.Message)" -ForegroundColor Red; $errors += "Email ($email): $($_.Exception.Message)" }
		}
		$progressBar1.Value = 0
		$who = @($email, $adUser | Where-Object { $_ }) -join ' / '
		if ($errors.Count) { Show-Notice 'Finished with errors' ("Blocked $who, but:`n`n" + ($errors -join "`n")) 'Warn' }
		else { Show-Notice 'Done' "Blocked $who." 'Info' }
	}
	function OnOpenTemplateButtonClick {
		$progressBar1.Value = 10
		$csv = ".\Templates\Disable-ADAndEmailAccounts.csv"
		if (-not (Test-Path $csv)) { "Username,Email" | Out-File $csv -Encoding UTF8 }
		Invoke-Item $csv
		$progressBar1.Value = 0
		CheckForErrors
	}
	function OnDisableBulkButtonClick {
		$csv = ".\Templates\Disable-ADAndEmailAccounts.csv"
		if (-not (Test-Path $csv)) { Show-Notice 'No template' 'Use Open Template to create the CSV first.' 'Warn'; return }
		$rows = @(Import-Csv $csv)
		if (-not $rows.Count) { Show-Notice 'Empty template' 'The template has no rows.' 'Warn'; return }
		$blockEmail = ($blockEmailCheck.IsChecked -eq $true); $blockAd = ($blockAdCheck.IsChecked -eq $true)
		if (-not ($blockEmail -or $blockAd)) { Show-Notice 'Nothing selected' 'Tick Block email and/or Block AD first.' 'Warn'; return }
		if ($blockEmail -and -not (Get-MgContext)) { Show-Notice 'Not connected' "Connect to the tenant first (top bar) to block email." 'Warn'; return }
		$progressBar1.Value = 10
		$done = [System.Collections.Generic.List[string]]::new()
		$failed = [System.Collections.Generic.List[string]]::new()
		foreach ($row in $rows) {
			$u = "$($row.Username)".Trim(); $e = "$($row.Email)".Trim()
			$who = if ($e) { $e } elseif ($u) { $u } else { '(blank row)' }
			Write-Host "Processing $who..."
			try {
				if ($blockAd -and $u) { Disable-OneAd $u }
				if ($blockEmail -and $e) {
					Disable-OneEmail $e
					if ($addMembersCheck.IsChecked -eq $true) { Invoke-AddMemberPrompt $e }
					if ($addAutoReplyCheck.IsChecked -eq $true) { Invoke-AutoReplyPrompt $e }
				}
				$done.Add($who)
			} catch { Write-Host "Failed $who`: $($_.Exception.Message)" -ForegroundColor Red; $failed.Add("$who - $($_.Exception.Message)") }
		}
		Show-AccountResults 'Disable AD & Email accounts' $done $failed -DoneWord 'Disabled' -FailWord 'Failed'
	}

	$form = New-DisableAccountsDialog
	$emailInput = $form.FindName('EmailInput')
	$adUserInput = $form.FindName('AdUserInput')
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

# ---------------------------------------------------------------------------
function New-InboxRule-SP {
	New-InboxRule -Name ForwardMail -Mailbox example@contoso.com -From example@contoso.com -ForwardTo example@contoso.com -MarkAsRead $true -MoveToFolder example@contoso.com:\Completed
}
