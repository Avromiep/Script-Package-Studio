# Script-Package - script dialogs (Add-*)
# Every function keeps its original logic and cmdlet calls; only the UI layer
# changed from WinForms to WPF windows styled by the merged design dictionary.

# Shared shape used by Add/Remove DistributionListMember and UnifiedGroupMember
function New-MemberGroupDialog {
	param([string]$Title, [string]$ActionText, [string]$BulkText, [string]$Icon = '&#xE716;')
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
		</StackPanel>
	</Border>
</StackPanel>
"@
}

# ---------------------------------------------------------------------------
function New-AuthenticationPhoneDialog {
	New-StyledDialog -Title 'Add-AuthenticationPhoneMethod' -Icon '&#xE717;' -BodyXaml @'
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
function New-AutoReplyDialog {
	$win = New-StyledDialog -Title 'Add-AutoReply' -Icon '&#xE715;' -BodyXaml @'
<StackPanel Margin="16" Width="520">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<Grid>
				<Grid.ColumnDefinitions>
					<ColumnDefinition Width="70"/><ColumnDefinition Width="*"/>
				</Grid.ColumnDefinitions>
				<TextBlock Text="Mailbox" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
				<TextBox x:Name="EmailInputBox" Grid.Column="1"/>
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
	$addAutoReplyForm.FindName('ConfirmBtn').Add_Click({ OnConfirmAutoReplyButtonClick })

	[void]$addAutoReplyForm.ShowDialog()

	Stop-Transcript
}

# ---------------------------------------------------------------------------
function New-AddContactsDialog {
	New-StyledDialog -Title 'Add-Contacts' -Icon '&#xE77B;' -BodyXaml @'
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
		Add-DistributionGroupMember -Identity $group -Member $member
		Write-Host "Adding $member..."
		$progressBar1.Value = 80
		CheckForErrors
		OperationComplete
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
		Import-Csv ".\Templates\Add-DistributionListMember.csv" | ForEach-Object {
			$progressBar1.Value = 20
			$member = $_.Member
			$group = $_.Group
			Add-DistributionGroupMember -Identity $group -Member $member
			Write-Host "Adding $member ..."
			$progressBar1.Value = 80
		}
		CheckForErrors
		OperationComplete
	}

	$scriptForm8 = New-MemberGroupDialog -Title 'Add-DistributionListMember' -ActionText 'Add Member' -BulkText 'Add Members'
	$memberInputBox = $scriptForm8.FindName('MemberInput')
	$groupInputBox = $scriptForm8.FindName('GroupInput')
	$scriptForm8.FindName('ActionBtn').Add_Click({ OnAddMemberButtonClick })
	$scriptForm8.FindName('OpenTemplateBtn').Add_Click({ OnOpenTemplateButtonClick })
	$scriptForm8.FindName('BulkBtn').Add_Click({ OnAddBulkMembersButtonClick })

	Write-Host "Loaded ScriptForm8."
	$progressBar1.Value = 0

	[void]$scriptForm8.ShowDialog()

	Stop-Transcript
}

# ---------------------------------------------------------------------------
function New-EmailAliasDialog {
	param([string]$Title = 'Add-EmailAlias', [string]$ActionText = 'Add Alias', [string]$BulkText = 'Add Aliases', [string]$CheckText = 'Create Incremental Aliases')
	New-StyledDialog -Title $Title -Icon '&#xE715;' -BodyXaml @"
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
				<Button x:Name="ActionBtn" Style="{DynamicResource BtnPrimary}" Content="$ActionText" Margin="0,14,0,0"/>
			</StackPanel>
		</Border>
		<Border Style="{DynamicResource Card}" Margin="0,12,0,0">
			<StackPanel>
				<TextBlock Text="Bulk" Style="{DynamicResource H3}"/>
				<Button x:Name="OpenTemplateBtn" Style="{DynamicResource BtnSecondary}" Content="Open Template" Margin="0,12,0,0"/>
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
		switch ($incrementalCheckBox.IsChecked) {
			$true {
				Write-Host "Creating incremental aliases..."
				$progressBar1.Value = 10
				$mailbox = $mailboxTextBox.Text
				$alias = $aliasTextBox.Text
				$splitAlias = $alias -split '\@'
				$aliasName = $splitAlias[0]
				$aliasDomain = $splitAlias[1]
				$progressBar1.Value = 30
				for ($i = 0; $i -lt $numericUpDown1.Value; $i++) {
					$progressBar1.Value = 10
					$completeAlias = $aliasName + [string]$i + "@" + $aliasDomain
					Set-Mailbox $mailbox -EmailAddresses @{Add= $completeAlias}
					Write-Host "Added $completeAlias to $mailbox."
					$progressBar1.Value = 90
				}
				$progressBar1.Value = 90
				CheckForErrors
				OperationComplete
			}
			$false {
				Write-Host "Creating single alias..."
				$progressBar1.Value = 10
				$mailbox = $mailboxTextBox.Text
				$alias = $aliasTextBox.Text
				$progressBar1.Value = 30
				Set-Mailbox $mailbox -EmailAddresses @{Add= $alias}
				$progressBar1.Value = 50
				Write-Host "Added $alias to $mailbox."
				$progressBar1.Value = 80
				CheckForErrors
				OperationComplete
			}
			Default {
				Write-Host "An error seems to have occurred."
				CheckForErrors
			}
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
		Import-Csv ".\Templates\Add-EmailAlias.csv" | ForEach-Object {
			$progressBar1.Value = 20
			$mailbox = $_.Mailbox
			$alias = $_.Alias
			$progressBar1.Value = 50
			Set-Mailbox $mailbox -EmailAddresses @{Add= $alias}
			Write-Host "Added $alias to $mailbox."
			$progressBar1.Value = 80
		}
		CheckForErrors
		OperationComplete
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

	$emailAliasForm = New-EmailAliasDialog
	$mailboxTextBox = $emailAliasForm.FindName('MailboxInput')
	$aliasTextBox = $emailAliasForm.FindName('AliasInput')
	$incrementalCheckBox = $emailAliasForm.FindName('IncrementalCheck')
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
	New-StyledDialog -Title 'Add-MailboxMember' -Icon '&#xE779;' -BodyXaml @'
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
	function OnMemberButtonClick {
		if ($mailboxMemberMode -eq 0) {
			$mailbox = $mailboxInputBox.Text
			$member = $memberInputBox.Text
			$progressBar1.Value = 10
			Add-MailboxPermission -Identity $mailbox -User $member -AccessRights FullAccess -InheritanceType All -AutoMapping $true
			$progressBar1.Value = 50
			Add-RecipientPermission -Identity $mailbox -Trustee $member -AccessRights SendAs -Confirm:$false
			$progressBar1.Value = 80
			Write-Host "Added $member to $mailbox." -ForegroundColor Cyan
		} elseif ($mailboxMemberMode -eq 1) {
			$mailbox = $mailboxInputBox.Text
			$member = $memberInputBox.Text
			$progressBar1.Value = 10
			Remove-MailboxPermission -Identity $mailbox -User $member -AccessRights FullAccess -InheritanceType All -Confirm:$false
			$progressBar1.Value = 50
			Remove-RecipientPermission -Identity $mailbox -Trustee $member -AccessRights SendAs -Confirm:$false
			$progressBar1.Value = 90
			Write-Host "Removed $member from $mailbox." -ForegroundColor Cyan
		}
		CheckForErrors
		OperationComplete
	}
	function OnFullAccessButtonClick {
		if ($mailboxMemberMode -eq 0) {
			$mailbox = $mailboxInputBox.Text
			$member = $memberInputBox.Text
			$progressBar1.Value = 10
			Add-MailboxPermission -Identity $mailbox -User $member -AccessRights FullAccess -InheritanceType All -AutoMapping $true
			$progressBar1.Value = 50
			Write-Host "Added Read and Manage permission for $member to $mailbox." -ForegroundColor Cyan
		} elseif ($mailboxMemberMode -eq 1) {
			$mailbox = $mailboxInputBox.Text
			$member = $memberInputBox.Text
			$progressBar1.Value = 10
			Remove-MailboxPermission -Identity $mailbox -User $member -AccessRights FullAccess -InheritanceType All -Confirm:$false
			$progressBar1.Value = 50
			Write-Host "Removed FullAccess permission for $member from $mailbox." -ForegroundColor Cyan
		}
		CheckForErrors
		OperationComplete
	}
	function OnSendOnBehalfButtonClick {
		if ($mailboxMemberMode -eq 0) {
			$mailbox = $mailboxInputBox.Text
			$member = $memberInputBox.Text
			$progressBar1.Value = 10
			Set-Mailbox -Identity $mailbox -GrantSendOnBehalfTo @{Add=$member}
			$progressBar1.Value = 50
			Write-Host "Added SendOnBehalf permission for $member to $mailbox" -ForegroundColor Cyan
		} elseif ($mailboxMemberMode -eq 1) {
			$mailbox = $mailboxInputBox.Text
			$member = $memberInputBox.Text
			$progressBar1.Value = 10
			Set-Mailbox -Identity $mailbox -GrantSendOnBehalfTo @{Remove=$member}
			$progressBar1.Value = 50
			Write-Host "Removed SendOnBehalf permission for $member from $mailbox." -ForegroundColor Cyan
		}
		CheckForErrors
		OperationComplete
	}
	function OnSendAsButtonClick {
		if ($mailboxMemberMode -eq 0) {
			$mailbox = $mailboxInputBox.Text
			$member = $memberInputBox.Text
			$progressBar1.Value = 10
			Add-RecipientPermission -Identity $mailbox -Trustee $member -AccessRights SendAs -Confirm:$false
			$progressBar1.Value = 50
			Write-Host "Added SendAs permission for $member to $mailbox." -ForegroundColor Cyan
		} elseif ($mailboxMemberMode -eq 1) {
			$mailbox = $mailboxInputBox.Text
			$member = $memberInputBox.Text
			$progressBar1.Value = 10
			Remove-RecipientPermission -Identity $mailbox -Trustee $member -AccessRights SendAs -Confirm:$false
			$progressBar1.Value = 50
			Write-Host "Removed SendAs permission for $member from $mailbox." -ForegroundColor Cyan
		}
		CheckForErrors
		OperationComplete
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
		if ($mailboxMemberMode -eq 0) {
			Import-Csv ".\Templates\Add-MailboxMember.csv" | ForEach-Object {
				$member = $_.Member
				$mailbox = $_.Mailbox
				$progressBar1.Value = 20
				Add-MailboxPermission -Identity $mailbox -User $member -AccessRights FullAccess -InheritanceType All -AutoMapping $true
				$progressBar1.Value = 50
				Add-RecipientPermission -Identity $mailbox -Trustee $member -AccessRights SendAs -Confirm:$false
				$progressBar1.Value = 80
				Write-Host "Added $member to $mailbox." -ForegroundColor Cyan
			}
		} elseif ($mailboxMemberMode -eq 1) {
			Import-Csv ".\Templates\Remove-MailboxMember.csv" | ForEach-Object {
				$member = $_.Member
				$mailbox = $_.Mailbox
				$progressBar1.Value = 20
				Remove-MailboxPermission -Identity $mailbox -User $member -AccessRights FullAccess -InheritanceType All -Confirm:$false
				$progressBar1.Value = 50
				Remove-RecipientPermission -Identity $mailbox -Trustee $member -AccessRights SendAs -Confirm:$false
				$progressBar1.Value = 80
				Write-Host "Removed $member from $mailbox." -ForegroundColor Cyan
			}
		}
		CheckForErrors
		OperationComplete
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
	New-StyledDialog -Title 'Add-TrustedSender' -Icon '&#xE8F8;' -BodyXaml @'
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
		Add-UnifiedGroupLinks -Identity $group -LinkType Members -Links $member
		Write-Host "Adding $member..."
		$progressBar1.Value = 80
		CheckForErrors
		OperationComplete
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
		Import-Csv ".\Templates\Add-UnifiedGroupMember.csv" | ForEach-Object {
			$progressBar1.Value = 30
			$member = $_.Member
			$group = $_.Group
			Add-UnifiedGroupLinks -Identity $group -LinkType Members -Links $member
			Write-Host "Adding $member ..."
			$progressBar1.Value = 80
		}
		CheckForErrors
		OperationComplete
	}

	$scriptForm8 = New-MemberGroupDialog -Title 'Add-UnifiedGroupMember' -ActionText 'Add Member' -BulkText 'Add Members'
	$memberInputBox = $scriptForm8.FindName('MemberInput')
	$groupInputBox = $scriptForm8.FindName('GroupInput')
	$scriptForm8.FindName('ActionBtn').Add_Click({ OnAddMemberButtonClick })
	$scriptForm8.FindName('OpenTemplateBtn').Add_Click({ OnOpenTemplateButtonClick })
	$scriptForm8.FindName('BulkBtn').Add_Click({ OnAddBulkMembersButtonClick })

	Write-Host "Loaded ScriptForm8."
	$progressBar1.Value = 0

	[void]$scriptForm8.ShowDialog()

	Stop-Transcript
}
