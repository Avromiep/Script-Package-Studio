# Script-Package - script dialogs (Block-User .. New-*)

function New-BlockUserDialog {
	New-StyledDialog -Title 'Block-User' -Icon '&#xE72E;' -BodyXaml @'
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
	New-StyledDialog -Title 'Add members to the blocked mailbox' -Icon '&#xE8FA;' -BodyXaml @'
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
	$win = New-StyledDialog -Title 'Add Auto-Reply' -Icon '&#xE715;' -BodyXaml @'
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
			Set-MgUserLicense -UserId $user -RemoveLicenses $license.SkuId -AddLicenses @{}
			Write-Host "Removed licenses from $user" -ForegroundColor Cyan
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
	New-StyledDialog -Title 'Clear-RecycleBin' -Icon '&#xE74D;' -BodyXaml @'
<StackPanel Margin="16" Width="320">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<StackPanel Orientation="Horizontal">
				<TextBlock Text="&#xE7BA;" Style="{DynamicResource Icon}" Foreground="{DynamicResource WarnBrush}" VerticalAlignment="Top" Margin="0,2,0,0"/>
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
	New-StyledDialog -Title 'Convert-UnifiedGroupToDistributionList' -Icon '&#xE8F1;' -BodyXaml @'
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
	New-StyledDialog -Title 'Enable-Archive' -Icon '&#xE7B8;' -BodyXaml @'
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
	$win = New-StyledDialog -Title 'New-ADAccounts' -Icon '&#xE7EE;' -BodyXaml @'
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
		Import-Csv -Path ".\Templates\New-ADAccounts.csv" | ForEach-Object {
			if ($_.SamAccountName.Length -gt 20) {
				Write-Host "$($_.SamAccountName) is over 20 characters, requesting user confirmation." -ForegroundColor Red
				$getUserConfirmation = ShowWarningForm -warningText "One or more SamAccountNames are over 20 characters - this may cause issues.`nPlease confirm if you'd like to proceed anyways."
				if ($getUserConfirmation -eq $true) {
					Write-Host "User confirmed to continue, running script..."
					CreateADAccounts
				} else {
					Write-Host "User closed confirmation window, cancelling action..."
				}
				break
			}
		}
		Write-Host "All SamAccountNames are within 20 characters."
		CreateADAccounts
	}
	function CreateADAccounts {
		Write-Host "Importing template csv..."
		$progressBar1.Value = 10
		$csvFile = Import-Csv -Path ".\Templates\New-ADAccounts.csv"
		$progressBar1.Value = 20
		CheckForErrors

		foreach ($row in $csvFile) {
			Write-Host "Gathering info..."

			$sourceUser = Get-ADUser -Identity $row.SourceUser -Properties *

			if ($null -eq $sourceUser) {
				Write-Host "Source user '$($row.SourceUser)' not found. Skipping user creation for '$($row.SamAccountName)'."
				continue
			}

			$ouPath = $sourceUser.DistinguishedName -replace "CN=[^,]+,", ""
			$ou = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouPath'"

			if ($null -eq $ou) {
				Write-Host "OU '$ouPath' not found. Skipping user creation for '$($row.SamAccountName)'."
				continue
			}

			$forest = $adDomainInput.Text
			$displayName = $row.GivenName + " " + $row.Surname
			$userPrincipalName = $row.SamAccountName + "@$forest"
			$samAccountName = $row.SamAccountName
			$progressBar1.Value = 30

			Write-Host "Creating new user $samAccountName..."
			New-ADUser -SamAccountName $samAccountName -Name $displayName -UserPrincipalName $userPrincipalName -DisplayName $displayName -AccountPassword (ConvertTo-SecureString $row.Password -AsPlainText -Force) -Enabled $true -Path $ou.DistinguishedName -GivenName $row.GivenName -Surname $row.Surname
			$progressBar1.Value = 40

			$newUser = Get-ADUser -Filter "SamAccountName -eq '$($row.SamAccountName)'"

			Write-Host "Copying attributes from source user $($sourceUser.SamAccountName) to new user $($newUser.SamAccountName)..."
			# Copy additional attributes from the source user
			Set-ADUser $newUser -ProfilePath $sourceUser.ProfilePath
			Set-ADUser $newUser -ScriptPath $sourceUser.ScriptPath
			Set-ADUser $newUser -PasswordNeverExpires $sourceUser.PasswordNeverExpires
			Set-ADUser $newUser -CannotChangePassword $sourceUser.CannotChangePassword
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
				Set-ADUser $newUser -HomeDrive $sourceUser.HomeDrive
				Set-ADUser $newUser -HomeDirectory $homeDirectory
			} else {
				Write-Host "Source user $($sourceUser.SamAccountName) does not have a HomeDirectory. Skipping HomeDirectory creation for the new user $($newUser.SamAccountName)."
			}
			$progressBar1.Value = 70

			Write-Host "Copying group membership from source user $($sourceUser.SamAccountName) to new user $($newUser.SamAccountName)..."
			# Copy security group memberships
			$sourceGroups = Get-ADPrincipalGroupMembership -Identity $sourceUser
			foreach ($group in $sourceGroups) {
				# Check if the new user is already a member of the group
				$isMember = Get-ADGroupMember -Identity $group -Recursive | Where-Object { $_.SamAccountName -eq $newUser.SamAccountName }
				if ($null -eq $isMember) {
					# Add the new user to the group if they are not already a member
					Add-ADGroupMember -Identity $group -Members $newUser
				}
			}
			Write-Host "Finished creating new user $($newuser.SamAccountName)."
		}
		CheckForErrors
		OperationComplete
	}

	$scriptForm9 = New-ADAccountsDialog -ForestName $domain.forest
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

function New-ADAndEmailAccountsDialog {
	param([string]$ForestName = '')
	$win = New-StyledDialog -Title 'New-ADAndEmailAccounts' -Icon '&#xE7EE;' -BodyXaml @'
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
		Import-Csv -Path ".\Templates\New-ADAndEmailAccounts.csv" | ForEach-Object {
			if ($_.SamAccountName.Length -gt 20) {
				Write-Host "$($_.SamAccountName) is over 20 characters, requesting user confirmation." -ForegroundColor Red
				$getUserConfirmation = ShowWarningForm -warningText "One or more SamAccountNames are over 20 characters - this may cause issues.`nPlease confirm if you'd like to proceed anyways."
				if ($getUserConfirmation -eq $true) {
					Write-Host "User confirmed to continue, running script..."
					CreateAccounts
				} else {
					Write-Host "User closed confirmation window, cancelling action..."
				}
				break
			}
		}
		Write-Host "All SamAccountNames are within 20 characters."
		CreateAccounts
	}
	function CreateAccounts {
		Write-Host "Importing template csv..."
		$progressBar1.Value = 10
		$csvFile = Import-Csv -Path ".\Templates\New-ADAndEmailAccounts.csv"
		$progressBar1.Value = 30
		CheckForErrors
		foreach ($row in $csvFile) {
			Write-Host "Gathering info..."

			$sourceUser = Get-ADUser -Identity $row.SourceUser -Properties *

			if ($null -eq $sourceUser) {
				Write-Host "Source user '$($row.SourceUser)' not found. Skipping user creation for '$($row.SamAccountName)'."
				continue
			}

			$ouPath = $sourceUser.DistinguishedName -replace "CN=[^,]+,", ""
			$ou = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouPath'"

			if ($null -eq $ou) {
				Write-Host "OU '$ouPath' not found. Skipping user creation for '$($row.SamAccountName)'."
				continue
			}

			$forest = $adDomainInput.Text
			$domain = $emailDomainInput.Text -split '\.'
			$emailDomain = $domain[0]
			$topLevelDomain = $domain[1]
			$displayName = $row.GivenName + " " + $row.Surname
			$samAccountName = $row.SamAccountName
			$userPrincipalName = $row.SamAccountName + "@$forest"
			$emailAddress = $row.SamAccountName + "@$emailDomain.$topLevelDomain"
			# $aliasAddress = $row.SamAccountName + "@$emailDomain.onmicrosoft.com"
			$progressBar1.Value = 30

			Write-Host "Creating new user $samAccountName..."
			New-ADUser -SamAccountName $row.SamAccountName -Name $displayName -UserPrincipalName $userPrincipalName -DisplayName $displayName -AccountPassword (ConvertTo-SecureString $row.Password -AsPlainText -Force) -Enabled $true -Path $ou.DistinguishedName -GivenName $row.GivenName -Surname $row.Surname
			$progressBar1.Value = 40

			$newUser = Get-ADUser -Filter "SamAccountName -eq '$($row.SamAccountName)'"

			Write-Host "Copying attributes from source user $($sourceUser.SamAccountName) to new user $($newUser.SamAccountName)..."
			# Copy additional attributes from the source user
			Set-ADUser $newUser -ProfilePath $sourceUser.ProfilePath
			Set-ADUser $newUser -ScriptPath $sourceUser.ScriptPath
			Set-ADUser $newUser -PasswordNeverExpires $sourceUser.PasswordNeverExpires
			Set-ADUser $newUser -CannotChangePassword $sourceUser.CannotChangePassword
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
				Set-ADUser $newUser -HomeDrive $sourceUser.HomeDrive
				Set-ADUser $newUser -HomeDirectory $homeDirectory
			} else {
				Write-Host "Source user $($sourceUser.SamAccountName) does not have a HomeDirectory. Skipping HomeDirectory creation for the new user $($newUser.SamAccountName)."
			}
			$progressBar1.Value = 70

			Write-Host "Copying group membership from source user $($sourceUser.SamAccountName) to new user $($newUser.SamAccountName)..."
			# Copy security group memberships
			$sourceGroups = Get-ADPrincipalGroupMembership -Identity $sourceUser
			foreach ($group in $sourceGroups) {
				# Check if the new user is already a member of the group
				$isMember = Get-ADGroupMember -Identity $group -Recursive | Where-Object { $_.SamAccountName -eq $newUser.SamAccountName }
				if ($null -eq $isMember) {
					# Add the new user to the group if they are not already a member
					Add-ADGroupMember -Identity $group -Members $newUser
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
					Set-MgUserLicense -UserId $emailAddress -AddLicenses @{SkuId = "4b9405b0-7788-4568-add1-99614e613b69"} -RemoveLicenses @()
				}
				"Exchange Online (Plan 2)" {
					Write-Host "Assigning Exchange Online (Plan 2) license..."
					Set-MgUserLicense -UserId $emailAddress -AddLicenses @{SkuId = "19ec0d23-8335-4cbd-94ac-6050e30712fa"} -RemoveLicenses @()
				}
				"Microsoft 365 Business Basic" {
					Write-Host "Assigning Microsoft 365 Business Basic license..."
					Set-MgUserLicense -UserId $emailAddress -AddLicenses @{SkuId = "3b555118-da6a-4418-894f-7df1e2096870"} -RemoveLicenses @()
				}
				"Microsoft 365 Business Standard" {
					Write-Host "Assigning Microsoft 365 Business Standard license..."
					Set-MgUserLicense -UserId $emailAddress -AddLicenses @{SkuId = "f245ecc8-75af-4f8e-b61f-27d8114de5f3"} -RemoveLicenses @()
				}
				"Microsoft 365 Business Premium" {
					Write-Host "Assigning Microsoft 365 Business Premium license..."
					Set-MgUserLicense -UserId $emailAddress -AddLicenses @{SkuId = "cbdc14ab-d96c-4c30-b9f4-6ada7cdc1d46"} -RemoveLicenses @()
				}
				"Microsoft 365 E3" {
					Write-Host "Assigning Microsoft 365 E3 license..."
					Set-MgUserLicense -UserId $emailAddress -AddLicenses @{SkuId = "05e9a617-0261-4cee-bb44-138d3ef5d965"} -RemoveLicenses @()
				}
				"Microsoft 365 E5" {
					Write-Host "Assigning Microsoft 365 E5 license..."
					Set-MgUserLicense -UserId $emailAddress -AddLicenses @{SkuId = "06ebc4ee-1bb5-47dd-8120-11324bc54e06"} -RemoveLicenses @()
				}
				Default { Write-Host "No license selected or invalid entry." }
			}
		}
		CheckForErrors
		OperationComplete
	}

	$scriptForm9 = New-ADAndEmailAccountsDialog -ForestName $domain.forest
	$adDomainInput = $scriptForm9.FindName('AdDomainInput')
	$emailDomainInput = $scriptForm9.FindName('EmailDomainInput')
	$licenseComboBox = $scriptForm9.FindName('LicenseCombo')
	$scriptForm9.FindName('OpenTemplateBtn').Add_Click({ OnOpenTemplateButtonClick })
	$scriptForm9.FindName('CreateAccountsBtn').Add_Click({ OnCreateAccountsButtonClick })

	Write-Host "Loaded ScriptForm9."
	$progressBar1.Value = 0

	[void]$scriptForm9.ShowDialog()

	Stop-Transcript
}

# ---------------------------------------------------------------------------
function New-EmailAccountsDialog {
	$win = New-StyledDialog -Title 'New-EmailAccounts' -Icon '&#xE715;' -BodyXaml @'
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
		Import-Csv ".\Templates\New-EmailAccounts.csv" | ForEach-Object {
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

			New-MgUser -AccountEnabled -PasswordProfile $passwordProfile -DisplayName $displayName -GivenName $firstName -Surname $lastName -UserPrincipalName $emailAddress -MailNickname $mailNickname -UsageLocation US
			$progressBar1.Value = 60

			# Set license
			switch ($licenseComboBox.Text) {
				"Exchange Online (Plan 1)" {
					Write-Host "Assigning Exchange Online (Plan 1) license..."
					Set-MgUserLicense -UserId $emailAddress -AddLicenses @{SkuId = "4b9405b0-7788-4568-add1-99614e613b69"} -RemoveLicenses @()
				}
				"Exchange Online (Plan 2)" {
					Write-Host "Assigning Exchange Online (Plan 2) license..."
					Set-MgUserLicense -UserId $emailAddress -AddLicenses @{SkuId = "19ec0d23-8335-4cbd-94ac-6050e30712fa"} -RemoveLicenses @()
				}
				"Microsoft 365 Business Basic" {
					Write-Host "Assigning Microsoft 365 Business Basic license..."
					Set-MgUserLicense -UserId $emailAddress -AddLicenses @{SkuId = "3b555118-da6a-4418-894f-7df1e2096870"} -RemoveLicenses @()
				}
				"Microsoft 365 Business Standard" {
					Write-Host "Assigning Microsoft 365 Business Standard license..."
					Set-MgUserLicense -UserId $emailAddress -AddLicenses @{SkuId = "f245ecc8-75af-4f8e-b61f-27d8114de5f3"} -RemoveLicenses @()
				}
				"Microsoft 365 Business Premium" {
					Write-Host "Assigning Microsoft 365 Business Premium license..."
					Set-MgUserLicense -UserId $emailAddress -AddLicenses @{SkuId = "cbdc14ab-d96c-4c30-b9f4-6ada7cdc1d46"} -RemoveLicenses @()
				}
				"Microsoft 365 E3" {
					Write-Host "Assigning Microsoft 365 E3 license..."
					Set-MgUserLicense -UserId $emailAddress -AddLicenses @{SkuId = "05e9a617-0261-4cee-bb44-138d3ef5d965"} -RemoveLicenses @()
				}
				"Microsoft 365 E5" {
					Write-Host "Assigning Microsoft 365 E5 license..."
					Set-MgUserLicense -UserId $emailAddress -AddLicenses @{SkuId = "06ebc4ee-1bb5-47dd-8120-11324bc54e06"} -RemoveLicenses @()
				}
				Default { Write-Host "No license selected or invalid entry." }
			}
			$progressBar1.Value = 90
		}
		CheckForErrors
		OperationComplete
	}

	$addEmailAccountsForm = New-EmailAccountsDialog
	$licenseComboBox = $addEmailAccountsForm.FindName('LicenseCombo')
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
function New-InboxRule-SP {
	New-InboxRule -Name ForwardMail -Mailbox example@contoso.com -From example@contoso.com -ForwardTo example@contoso.com -MarkAsRead $true -MoveToFolder example@contoso.com:\Completed
}
