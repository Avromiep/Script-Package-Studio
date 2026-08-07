# Script-Package - script dialogs (Remove-* .. Show-Information)

function Remove-DistributionListMember {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Remove-DistributionListMember.txt"
	Write-Host "Running Remove-DistributionListMember script..."
	$progressBar1.Value = 10
	function OnRemoveMemberButtonClick {
		Write-Host "RemoveMember button clicked."
		$progressBar1.Value = 10
		$member = $memberInputBox.Text
		$group = $groupInputBox.Text
		if (-not (Test-MemberTargetType $group 'DistributionList')) { $progressBar1.Value = 0; return }
		try {
			Remove-DistributionGroupMember -Identity $group -Member $member -Confirm:$false -ErrorAction Stop
			Write-Host "Removed $member from $group." -ForegroundColor Cyan
			$progressBar1.Value = 80
			OperationComplete
		} catch {
			Write-Host "Couldn't remove $member from '$group': $($_.Exception.Message)" -ForegroundColor Red
			$progressBar1.Value = 0
		}
	}
	function OnOpenTemplateButtonClick {
		Write-Host "OpenTemplate button clicked."
		$progressBar1.Value = 10
		Invoke-Item ".\Templates\Remove-DistributionListMember.csv"
		$progressBar1.Value = 80
		CheckForErrors
		$progressBar1.Value = 0
	}
	function OnRemoveBulkMembersButtonClick {
		Write-Host "RemoveBulkMembers button clicked."
		$progressBar1.Value = 10
		$typeCache = @{}
		Import-Csv ".\Templates\Remove-DistributionListMember.csv" | ForEach-Object {
			$progressBar1.Value = 20
			$member = $_.Member
			$group = $_.Group
			if (-not (Test-MemberTargetTypeCached $group 'DistributionList' $typeCache)) { return }
			try {
				Remove-DistributionGroupMember -Identity $group -Member $member -Confirm:$false -ErrorAction Stop
				Write-Host "Removed $member from $group."
				$progressBar1.Value = 80
			} catch {
				Write-Host "Couldn't remove $member from '$group': $($_.Exception.Message)" -ForegroundColor Red
			}
		}
		CheckForErrors
		OperationComplete
	}

	$scriptForm8 = New-MemberGroupDialog -Title 'Remove-DistributionListMember' -ActionText 'Remove Member' -BulkText 'Remove Members'
	$memberInputBox = $scriptForm8.FindName('MemberInput')
	$groupInputBox = $scriptForm8.FindName('GroupInput')
	$scriptForm8.FindName('ActionBtn').Add_Click({ OnRemoveMemberButtonClick })
	$scriptForm8.FindName('OpenTemplateBtn').Add_Click({ OnOpenTemplateButtonClick })
	$scriptForm8.FindName('BulkBtn').Add_Click({ OnRemoveBulkMembersButtonClick })

	Write-Host "Loaded ScriptForm8."
	$progressBar1.Value = 0

	[void]$scriptForm8.ShowDialog()

	Stop-Transcript
}

# ---------------------------------------------------------------------------
function Remove-EmailAlias {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Remove-EmailAlias.txt"
	Write-Host "Running Remove-EmailAlias script..."
	$progressBar1.Value = 10

	function OnRemoveAliasButtonClick {
		Write-Host "removeAliasButton clicked."
		switch ($incrementalCheckBox.IsChecked) {
			$true {
				Write-Host "Removing incremental aliases..."
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
					Set-Mailbox $mailbox -EmailAddresses @{Remove= $completeAlias}
					Write-Host "Removed $completeAlias from $mailbox."
					$progressBar1.Value = 90
				}
				$progressBar1.Value = 90
				CheckForErrors
				OperationComplete
			}
			$false {
				Write-Host "Removing single alias..."
				$progressBar1.Value = 10
				$mailbox = $mailboxTextBox.Text
				$alias = $aliasTextBox.Text
				$progressBar1.Value = 30
				Set-Mailbox $mailbox -EmailAddresses @{Remove= $alias}
				$progressBar1.Value = 50
				Write-Host "Removed $alias from $mailbox."
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
		Invoke-Item ".\Templates\Remove-EmailAlias.csv"
		$progressBar1.Value = 100
		CheckForErrors
		$progressBar1.Value = 0
	}
	function OnRemoveAliasBulkButtonClick {
		Import-Csv ".\Templates\Remove-EmailAlias.csv" | ForEach-Object {
			$progressBar1.Value = 20
			$mailbox = $_.Mailbox
			$alias = $_.Alias
			$progressBar1.Value = 50
			Set-Mailbox $mailbox -EmailAddresses @{Remove= $alias}
			Write-Host "Removed $alias from $mailbox."
			$progressBar1.Value = 80
		}
		CheckForErrors
		OperationComplete
	}
	function OnIncrementalCheckBoxChecked {
		if ($incrementalCheckBox.IsChecked -eq $true) {
			$numericUpDown1.Enabled = $true
			$removeAliasButton.Content = "Remove Aliases"
		} elseif ($incrementalCheckBox.IsChecked -eq $false) {
			$numericUpDown1.Enabled = $false
			$removeAliasButton.Content = "Remove Alias"
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

	$emailAliasForm = New-EmailAliasDialog -Title 'Remove-EmailAlias' -ActionText 'Remove Alias' -BulkText 'Remove Aliases' -CheckText 'Remove Incremental Aliases'
	$mailboxTextBox = $emailAliasForm.FindName('MailboxInput')
	$aliasTextBox = $emailAliasForm.FindName('AliasInput')
	$incrementalCheckBox = $emailAliasForm.FindName('IncrementalCheck')
	$removeAliasButton = $emailAliasForm.FindName('ActionBtn')
	$infoTextBox = $emailAliasForm.FindName('InfoBox')
	$numericUpDown1 = New-NumericProxy ($emailAliasForm.FindName('CountBox')) 100
	$incrementalCheckBox.Add_Checked({ OnIncrementalCheckBoxChecked })
	$incrementalCheckBox.Add_Unchecked({ OnIncrementalCheckBoxChecked })
	$removeAliasButton.Add_Click({ OnRemoveAliasButtonClick })
	$emailAliasForm.FindName('OpenTemplateBtn').Add_Click({ OnOpenTemplateButtonClick })
	$emailAliasForm.FindName('BulkBtn').Add_Click({ OnRemoveAliasBulkButtonClick })
	$emailAliasForm.FindName('GetAliasBtn').Add_Click({ OnGetAliasButtonClick })
	$emailAliasForm.FindName('CopyBtn').Add_Click({ OnCopyButtonClick })

	$progressBar1.Value = 100
	Write-Host "Loaded EmailAliasForm."
	$progressBar1.Value = 0

	[void]$emailAliasForm.ShowDialog()

	Stop-Transcript
}

# ---------------------------------------------------------------------------
function Remove-UnifiedGroupMember {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Remove-UnifiedGroupMember.txt"
	Write-Host "Running Remove-UnifiedGroupMember script..."
	$progressBar1.Value = 10
	function OnRemoveMemberButtonClick {
		Write-Host "RemoveMember button clicked."
		$progressBar1.Value = 10
		$member = $memberInputBox.Text
		$group = $groupInputBox.Text
		if (-not (Test-MemberTargetType $group 'UnifiedGroup')) { $progressBar1.Value = 0; return }
		try {
			Remove-UnifiedGroupLinks -Identity $group -LinkType Members -Links $member -Confirm:$false -ErrorAction Stop
			Write-Host "Removed $member from $group." -ForegroundColor Cyan
			$progressBar1.Value = 80
			OperationComplete
		} catch {
			Write-Host "Couldn't remove $member from '$group': $($_.Exception.Message)" -ForegroundColor Red
			$progressBar1.Value = 0
		}
	}
	function OnOpenTemplateButtonClick {
		Write-Host "OpenTemplate button clicked."
		$progressBar1.Value = 10
		Invoke-Item ".\Templates\Remove-UnifiedGroupMember.csv"
		$progressBar1.Value = 80
		CheckForErrors
		$progressBar1.Value = 0
	}
	function OnRemoveBulkMembersButtonClick {
		Write-Host "RemoveBulkMembers button clicked."
		$progressBar1.Value = 10
		$typeCache = @{}
		Import-Csv ".\Templates\Remove-UnifiedGroupMember.csv" | ForEach-Object {
			$progressBar1.Value = 20
			$member = $_.Member
			$group = $_.Group
			if (-not (Test-MemberTargetTypeCached $group 'UnifiedGroup' $typeCache)) { return }
			try {
				Remove-UnifiedGroupLinks -Identity $group -LinkType Members -Links $member -Confirm:$false -ErrorAction Stop
				Write-Host "Removed $member from $group."
				$progressBar1.Value = 80
			} catch {
				Write-Host "Couldn't remove $member from '$group': $($_.Exception.Message)" -ForegroundColor Red
			}
		}
		CheckForErrors
		OperationComplete
	}

	$scriptForm8 = New-MemberGroupDialog -Title 'Remove-UnifiedGroupMember' -ActionText 'Remove Member' -BulkText 'Remove Members'
	$memberInputBox = $scriptForm8.FindName('MemberInput')
	$groupInputBox = $scriptForm8.FindName('GroupInput')
	$scriptForm8.FindName('ActionBtn').Add_Click({ OnRemoveMemberButtonClick })
	$scriptForm8.FindName('OpenTemplateBtn').Add_Click({ OnOpenTemplateButtonClick })
	$scriptForm8.FindName('BulkBtn').Add_Click({ OnRemoveBulkMembersButtonClick })

	Write-Host "Loaded ScriptForm8."
	$progressBar1.Value = 0

	[void]$scriptForm8.ShowDialog()

	Stop-Transcript
}

# ---------------------------------------------------------------------------
function Revoke-AllSignInSessions {
	$userIds = Get-MgUser -All | Select-Object ID
	foreach($userId in $userIds) {
		Revoke-MgUserSignInSession -UserId $userId.Id
	}
}

# ---------------------------------------------------------------------------
# Launch a detached helper that waits for THIS instance to fully exit (so the
# updated files are unlocked and settings are saved), then starts the new app.
function Restart-App {
	$appRoot = Split-Path $script:SrcDir -Parent
	$bat     = Join-Path $appRoot 'Script-Package-Studio.bat'
	$mainPs1 = Join-Path $appRoot 'MainGUI.ps1'
	$pwshExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
	$logPath = Join-Path $appRoot 'Logs\Restart-App.txt'
	try { New-Item -ItemType Directory -Path (Split-Path $logPath) -Force | Out-Null } catch {}

	# The command the helper runs AFTER this instance exits. Prefer the .bat (the normal
	# launcher - same working dir + hidden window the user starts with) so the relaunched
	# app behaves exactly like a normal start; fall back to launching MainGUI.ps1 directly.
	if (Test-Path -LiteralPath $bat) {
		$relaunchCmd = "Start-Process -FilePath '$bat' -WorkingDirectory '$appRoot' -WindowStyle Hidden"
		$via = 'bat'
	} else {
		$relaunchCmd = "Start-Process -FilePath '$pwshExe' -WorkingDirectory '$appRoot' -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-File','$mainPs1')"
		$via = 'ps1'
	}

	# The helper waits for THIS instance to exit (up to 30s; relaunches anyway after),
	# then starts the updated app. Passed as base64 -EncodedCommand so paths with spaces
	# / quotes can't break the command line. It logs the outcome so a failed relaunch is
	# visible in Logs\Restart-App.txt instead of silently doing nothing.
	$helperBody = @"
try { Wait-Process -Id $PID -Timeout 30 -ErrorAction SilentlyContinue } catch {}
Start-Sleep -Milliseconds 400
try { $relaunchCmd; 'relaunch: started ok' | Out-File -LiteralPath '$logPath' -Append }
catch { "relaunch: FAILED - `$_" | Out-File -LiteralPath '$logPath' -Append }
"@
	$encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($helperBody))
	try {
		Start-Process -FilePath $pwshExe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) | Out-Null
		"[$(Get-Date -Format o)] helper spawned (pid=$PID exe=$pwshExe via=$via appRoot=$appRoot)" | Out-File -LiteralPath $logPath -Append
	} catch {
		"[$(Get-Date -Format o)] helper spawn FAILED - $($_ | Out-String)" | Out-File -LiteralPath $logPath -Append
	}
}

function Update-ScriptPackage {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Update-ScriptPackage.txt"
	Write-Host "Running Update-ScriptPackage script..."
	$restarting = $false
	$progressBar1.Value = 10
	$versionCheck = Invoke-WebRequest -Uri "https://github.com/Avromiep/Script-Package-Studio/releases/latest"
	$versionLink = $versionCheck.Links.href | Where-Object {
		$_ -Like "*/releases/tag/v*"
	}
	$splitLink = $versionLink -Split 'tag/'
	$remoteVersion = $splitLink[1]
	$progressBar1.Value = 30

	if ($remoteVersion -eq $version) {
		Write-Host "Latest version of Script-Package Studio already installed."
		$progressBar1.Value = 100
		CheckForErrors
		$progressBar1.Value = 0
		[void](New-UpdateCompleteDialog "Latest version already installed.").ShowDialog()
	} else {
		Write-Host "Downloading latest version of Script-Package Studio..."
		Remove-Item -Path "$env:TEMP\Script-Package-Studio-Setup.exe" -Force -ErrorAction Ignore
		Invoke-WebRequest -Uri "https://github.com/Avromiep/Script-Package-Studio/releases/latest/download/Script-Package-Studio-Setup.exe" -OutFile "$env:TEMP\Script-Package-Studio-Setup.exe"
		$progressBar1.Value = 50
		if (Test-Path "$env:TEMP\Script-Package-Studio-Setup.exe") {
			Write-Host "Launching downloaded file..."
			# Force the install into the folder the app is ACTUALLY running from. A silent
			# install inherits this (elevated) process's token, so without /DIR Inno's
			# {autopf} could resolve to a DIFFERENT location (e.g. Program Files vs. the
			# per-user Programs folder), updating a copy the relaunch never starts.
			$appRoot = Split-Path $script:SrcDir -Parent
			Start-Process "$env:TEMP\Script-Package-Studio-Setup.exe" -ArgumentList "/SP-", "/SILENT", "/DIR=`"$appRoot`"" -Wait
			$progressBar1.Value = 70
			CheckForErrors
			$progressBar1.Value = 100
			[void](New-UpdateCompleteDialog "Update installed. Script-Package Studio will now restart.").ShowDialog()
			Write-Host "Relaunching the updated app..."
			Restart-App
			$restarting = $true
		} else {
			Write-Host "Setup download failed - opening the releases page instead." -ForegroundColor Yellow
			Start-Process "https://github.com/Avromiep/Script-Package-Studio/releases/latest"
			CheckForErrors
			$progressBar1.Value = 0
		}
	}
	Stop-Transcript
	if ($restarting) { $script:Window.Close() }
}

# ---------------------------------------------------------------------------
function New-AclPermissionsDialog {
	param([string]$DomainName = '', [string[]]$UserGroupList = @())
	$win = New-StyledDialog -Title 'Set-ACLPermissions' -Icon '&#xEAA7;' -BodyXaml @'
<Grid Margin="16">
	<Grid.ColumnDefinitions>
		<ColumnDefinition Width="340"/><ColumnDefinition Width="12"/><ColumnDefinition Width="300"/>
	</Grid.ColumnDefinitions>
	<StackPanel Grid.Column="0">
		<Border Style="{DynamicResource Card}">
			<StackPanel>
				<TextBlock Text="File" Style="{DynamicResource H3}"/>
				<StackPanel Orientation="Horizontal" Margin="0,10,0,0">
					<RadioButton x:Name="SingleChip" Style="{DynamicResource Chip}" GroupName="AclFileMode" Content="Single" IsChecked="True"/>
					<RadioButton x:Name="MultipleChip" Style="{DynamicResource Chip}" GroupName="AclFileMode" Content="Multiple" Margin="8,0,0,0"/>
				</StackPanel>
				<Grid Margin="0,12,0,0">
					<Grid.ColumnDefinitions>
						<ColumnDefinition Width="60"/><ColumnDefinition Width="*"/>
					</Grid.ColumnDefinitions>
					<TextBlock Text="Path" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
					<TextBox x:Name="PathBox" Grid.Column="1"/>
				</Grid>
				<Button x:Name="OpenTemplateBtn" Style="{DynamicResource BtnSecondary}" Content="Open Template" Margin="0,10,0,0" IsEnabled="False"/>
			</StackPanel>
		</Border>
		<Border Style="{DynamicResource Card}" Margin="0,12,0,0">
			<StackPanel>
				<TextBlock Text="Identity" Style="{DynamicResource H3}"/>
				<Grid Margin="0,12,0,0">
					<Grid.ColumnDefinitions>
						<ColumnDefinition Width="80"/><ColumnDefinition Width="*"/>
					</Grid.ColumnDefinitions>
					<Grid.RowDefinitions>
						<RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
					</Grid.RowDefinitions>
					<TextBlock Text="Domain" Style="{DynamicResource Dim}" VerticalAlignment="Center"/>
					<TextBox x:Name="DomainBox" Grid.Column="1"/>
					<TextBlock Text="User/Group" Style="{DynamicResource Dim}" Grid.Row="1" VerticalAlignment="Center" Margin="0,8,0,0"/>
					<ComboBox x:Name="UserGroupCombo" Grid.Row="1" Grid.Column="1" Margin="0,8,0,0" IsEditable="True" IsTextSearchEnabled="True"/>
				</Grid>
			</StackPanel>
		</Border>
		<Border Style="{DynamicResource Card}" Margin="0,12,0,0">
			<StackPanel>
				<Grid>
					<TextBlock Text="Rights" Style="{DynamicResource H3}" VerticalAlignment="Center"/>
					<Button x:Name="RightsHelpBtn" Style="{DynamicResource BtnGhost}" Content="Help" Padding="8,3" HorizontalAlignment="Right"/>
				</Grid>
				<ScrollViewer Height="210" Margin="0,10,0,0" VerticalScrollBarVisibility="Auto">
					<StackPanel x:Name="RightsPanel"/>
				</ScrollViewer>
			</StackPanel>
		</Border>
	</StackPanel>
	<StackPanel Grid.Column="2">
		<Border Style="{DynamicResource Card}">
			<StackPanel>
				<TextBlock Text="Inheritance" Style="{DynamicResource H3}"/>
				<StackPanel x:Name="InheritancePanel" Margin="0,10,0,0"/>
			</StackPanel>
		</Border>
		<Border Style="{DynamicResource Card}" Margin="0,12,0,0">
			<StackPanel>
				<TextBlock Text="Propagation" Style="{DynamicResource H3}"/>
				<StackPanel x:Name="PropagationPanel" Margin="0,10,0,0"/>
			</StackPanel>
		</Border>
		<Border Style="{DynamicResource Card}" Margin="0,12,0,0">
			<StackPanel>
				<TextBlock Text="AccessControlType" Style="{DynamicResource H3}"/>
				<StackPanel Orientation="Horizontal" Margin="0,10,0,0">
					<RadioButton x:Name="AllowChip" Style="{DynamicResource Chip}" GroupName="AclAct" Content="Allow" IsChecked="True"/>
					<RadioButton x:Name="DenyChip" Style="{DynamicResource Chip}" GroupName="AclAct" Content="Deny" Margin="8,0,0,0"/>
				</StackPanel>
			</StackPanel>
		</Border>
		<ProgressBar x:Name="AclProgress" Height="6" Margin="0,16,0,0"/>
		<Button x:Name="SetPermissionsBtn" Style="{DynamicResource BtnPrimary}" Content="Add Permissions" Margin="0,14,0,0"/>
	</StackPanel>
</Grid>
'@
	$win.FindName('DomainBox').Text = $DomainName
	$combo = $win.FindName('UserGroupCombo')
	foreach ($u in $UserGroupList) { [void]$combo.Items.Add($u) }
	# checkbox lists (replace the old CheckedListBoxes)
	$rightsItems = @("AppendData","ChangePermissions","CreateDirectories","CreateFiles","Delete",
		"DeleteSubdirectoriesAndFiles","ExecuteFile","FullControl","ListDirectory","Modify","Read",
		"ReadAndExecute","ReadAttributes","ReadData","ReadExtendedAttributes","ReadPermissions",
		"Synchronize","TakeOwnership","Traverse","Write","WriteAttributes","WriteData","WriteExtendedAttributes")
	$rightsPanel = $win.FindName('RightsPanel')
	foreach ($r in $rightsItems) {
		$cb = [System.Windows.Controls.CheckBox]::new()
		$cb.Content = $r
		$cb.Margin = '0,0,0,6'
		[void]$rightsPanel.Children.Add($cb)
	}
	$inhPanel = $win.FindName('InheritancePanel')
	foreach ($i in @("ContainerInherit","None","ObjectInherit")) {
		$cb = [System.Windows.Controls.CheckBox]::new()
		$cb.Content = $i
		$cb.Margin = '0,0,0,6'
		if ($i -in @("ContainerInherit","ObjectInherit")) { $cb.IsChecked = $true }
		[void]$inhPanel.Children.Add($cb)
	}
	$propPanel = $win.FindName('PropagationPanel')
	foreach ($p in @("InheritOnly","None","NoPropagateInherit")) {
		$cb = [System.Windows.Controls.CheckBox]::new()
		$cb.Content = $p
		$cb.Margin = '0,0,0,6'
		if ($p -eq "None") { $cb.IsChecked = $true }
		[void]$propPanel.Children.Add($cb)
	}
	return $win
}

function Set-ACLPermissions {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Set-ACLPermissions.txt"
	Write-Host "Running Set-ACLPermissions script..."
	$progressBar1.Value = 10
	function ToggleSingleMultiple {
		if ($singleRadioButton.IsChecked) {
			Write-Host "singleRadioButton is checked."
			$pathTextBox.IsEnabled = $true
			$openTemplateButton.IsEnabled = $false
		} elseif ($multipleRadioButton.IsChecked) {
			Write-Host "multipleRadioButton is checked."
			$pathTextBox.IsEnabled = $false
			$openTemplateButton.IsEnabled = $true
		} else {
			Write-Host "Error, both radio buttons unchecked."
		}
	}
	function OnOpenTemplateButtonClick {
		Write-Host "openTemplateButton clicked."
		$continuousProgressBar.Value = 10
		Invoke-Item ".\Templates\Set-ACLPermissions.txt"
		$continuousProgressBar.Value = 100
		CheckForErrors
		$continuousProgressBar.Value = 0
	}
	function OnRightsHelpButtonClick {
		Write-Host "rightsHelpButton clicked."
		$continuousProgressBar.Value = 10
		Start-Process "https://learn.microsoft.com/en-us/dotnet/api/system.security.accesscontrol.filesystemrights?view=net-7.0"
		$continuousProgressBar.Value = 100
		CheckForErrors
		$continuousProgressBar.Value = 0
	}
	function OnSetPermissionsButtonClick {
		Write-Host "setPermissionsButton clicked."
		$continuousProgressBar.Value = 10

		if ($singleRadioButton.IsChecked) {
			$aclPath = $pathTextBox.Text
			$acl = Get-Acl $aclPath
			$identity = "$domainName\$($userGroupComboBox.Text)"
			$continuousProgressBar.Value = 20

			$rights = ""
			foreach ($item in ($rightsCheckBoxes | Where-Object { $_.IsChecked })) {
				$rights += [string]$item.Content + ","
			}
			$rights = $rights.TrimEnd(',')
			$continuousProgressBar.Value = 30

			$inheritanceFlags = ""
			foreach ($item in ($inheritanceCheckBoxes | Where-Object { $_.IsChecked })) {
				$inheritanceFlags += [string]$item.Content + ","
			}
			$inheritanceFlags = $inheritanceFlags.TrimEnd(',')
			$continuousProgressBar.Value = 40

			$propagationFlags = ""
			foreach ($item in ($propagationCheckBoxes | Where-Object { $_.IsChecked })) {
				$propagationFlags += [string]$item.Content + ","
			}
			$propagationFlags = $propagationFlags.TrimEnd(',')
			$continuousProgressBar.Value = 50

			if ($actAllowRadioButton) {
				Write-Host "actAllowRadioButton is checked."
				$accessControlType = "Allow"
			} elseif ($actDenyRadioButton) {
				Write-Host "actDenyRadioButton is checked."
				$accessControlType = "Deny"
			} else {
				Write-Host "Error, both radio buttons unchecked."
			}
			$continuousProgressBar.Value = 60

			$rule = New-Object System.Security.AccessControl.FileSystemAccessRule("$identity","$rights","$inheritanceFlags","$propagationFlags","$accessControlType")
			$acl.AddAccessRule($rule)
			Set-Acl $aclPath $acl
			$continuousProgressBar.Value = 100
			$continuousProgressBar.Value = 0
		} elseif ($multipleRadioButton.IsChecked) {
			$identity = "$domainName\$($userGroupComboBox.Text)"
			$continuousProgressBar.Value = 10

			$rights = ""
			foreach ($item in ($rightsCheckBoxes | Where-Object { $_.IsChecked })) {
				$rights += [string]$item.Content + ","
			}
			$rights = $rights.TrimEnd(',')
			$continuousProgressBar.Value = 20

			$inheritanceFlags = ""
			foreach ($item in ($inheritanceCheckBoxes | Where-Object { $_.IsChecked })) {
				$inheritanceFlags += [string]$item.Content + ","
			}
			$inheritanceFlags = $inheritanceFlags.TrimEnd(',')
			$continuousProgressBar.Value = 30

			$propagationFlags = ""
			foreach ($item in ($propagationCheckBoxes | Where-Object { $_.IsChecked })) {
				$propagationFlags += [string]$item.Content + ","
			}
			$propagationFlags = $propagationFlags.TrimEnd(',')
			$continuousProgressBar.Value = 40

			if ($actAllowRadioButton) {
				Write-Host "actAllowRadioButton is checked."
				$accessControlType = "Allow"
			} elseif ($actDenyRadioButton) {
				Write-Host "actDenyRadioButton is checked."
				$accessControlType = "Deny"
			} else {
				Write-Host "Error, both radio buttons unchecked."
			}
			$continuousProgressBar.Value = 50
			Get-Content ".\Templates\Set-ACLPermissions.txt" | ForEach-Object {
				$continuousProgressBar.Value = 60
				$aclPath = $_
				$acl = Get-Acl $aclPath
				$rule = New-Object System.Security.AccessControl.FileSystemAccessRule("$identity","$rights","$inheritanceFlags","$propagationFlags","$accessControlType")
				$acl.AddAccessRule($rule)
				Set-Acl $aclPath $acl
				$continuousProgressBar.Value = 80
			}
			$continuousProgressBar.Value = 100
			$continuousProgressBar.Value = 0
		} else {
			Write-Host "Error, both radio buttons unchecked."
		}
		CheckForErrors
		OperationComplete
	}

	$domainName = (Get-ciminstance -Class Win32_UserAccount -Filter "Name='$env:USERNAME'").Domain

	$allUsers = Get-ADUser -Filter * -Properties SamAccountName | Sort-Object SamAccountName
	$allGroups = Get-ADGroup -Filter * -Properties Name | Sort-Object Name
	$fullList = $allUsers.SamAccountName + $allGroups.Name

	$setPermissionsForm = New-AclPermissionsDialog -DomainName $domainName -UserGroupList $fullList
	$singleRadioButton = $setPermissionsForm.FindName('SingleChip')
	$multipleRadioButton = $setPermissionsForm.FindName('MultipleChip')
	$pathTextBox = $setPermissionsForm.FindName('PathBox')
	$openTemplateButton = $setPermissionsForm.FindName('OpenTemplateBtn')
	$domainTextBox = $setPermissionsForm.FindName('DomainBox')
	$userGroupComboBox = $setPermissionsForm.FindName('UserGroupCombo')
	$actAllowRadioButton = $setPermissionsForm.FindName('AllowChip')
	$actDenyRadioButton = $setPermissionsForm.FindName('DenyChip')
	$continuousProgressBar = $setPermissionsForm.FindName('AclProgress')
	$rightsCheckBoxes = @($setPermissionsForm.FindName('RightsPanel').Children)
	$inheritanceCheckBoxes = @($setPermissionsForm.FindName('InheritancePanel').Children)
	$propagationCheckBoxes = @($setPermissionsForm.FindName('PropagationPanel').Children)

	$singleRadioButton.Add_Checked({ ToggleSingleMultiple })
	$multipleRadioButton.Add_Checked({ ToggleSingleMultiple })
	$setPermissionsForm.FindName('RightsHelpBtn').Add_Click({ OnRightsHelpButtonClick })
	$openTemplateButton.Add_Click({ OnOpenTemplateButtonClick })
	$setPermissionsForm.FindName('SetPermissionsBtn').Add_Click({ OnSetPermissionsButtonClick })

	Write-Host "Loaded setPermissionsForm."
	$progressBar1.Value = 0
	CheckForErrors

	[void]$setPermissionsForm.ShowDialog()

	Stop-Transcript
}

# ---------------------------------------------------------------------------
function Set-EmailForwarding {
	Set-Mailbox -Identity "Douglas Kohn" -DeliverToMailboxAndForward $true -ForwardingSMTPAddress "douglaskohn.parents@fineartschool.net"
	Set-Mailbox -Identity "Ken Sanchez" -ForwardingAddress "pilarp@contoso.com"
}

# ---------------------------------------------------------------------------
function New-SetNTPDialog {
	New-StyledDialog -Title 'Set-NTP' -Icon '&#xE508;' -BodyXaml @'
<StackPanel Margin="16" Width="340">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<Button x:Name="SetSourceBtn" Style="{DynamicResource BtnPrimary}" Content="Set time source to time.windows.com"/>
			<Button x:Name="CheckConfigBtn" Style="{DynamicResource BtnSecondary}" Content="Check current configuration" Margin="0,8,0,0"/>
			<Button x:Name="CheckSourceBtn" Style="{DynamicResource BtnSecondary}" Content="Check current time source" Margin="0,8,0,0"/>
			<Button x:Name="ForceResyncBtn" Style="{DynamicResource BtnSecondary}" Content="Force resync with time source" Margin="0,8,0,0"/>
			<TextBox x:Name="OutputBox" Style="{DynamicResource TextArea}" Height="180" Margin="0,12,0,0"
					 IsReadOnly="True" FontFamily="{DynamicResource MonoFont}" FontSize="12"/>
		</StackPanel>
	</Border>
</StackPanel>
'@
}

function Set-NTP {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Set-NTP.txt"
	Write-Host "Running Set-NTP script..."
	$progressBar1.Value = 10
	function OnSetSourceButtonClick {
		Write-Host "setSourceButton clicked."
		$progressBar1.Value = 10
		w32tm /config /syncfromflags:manual /manualpeerlist:time.windows.com,0x8 /reliable:yes /update
		# With IP address:
		# w32tm /config /syncfromflags:manual /manualpeerlist:168.61.215.74,0x8 /reliable:yes /update
		$progressBar1.Value = 50
		w32tm /config /update
		$progressBar1.Value = 80
		CheckForErrors
		OperationComplete
	}
	function OnCheckConfigButtonClick {
		Write-Host "checkConfigButton clicked."
		$progressBar1.Value = 10
		$outputTextBox.Text = (w32tm /query /configuration) -join "`r`n"
		$progressBar1.Value = 50
		CheckForErrors
		OperationComplete
	}
	function OnCheckSourceButtonClick {
		Write-Host "checkSourceButton clicked."
		$progressBar1.Value = 10
		$outputTextBox.Text = (w32tm /query /source) -join "`r`n"
		$progressBar1.Value = 50
		CheckForErrors
		OperationComplete
	}
	function OnForceResyncButtonClick {
		$progressBar1.Value = 10
		$outputTextBox.Text = (w32tm /resync /force) -join "`r`n"
		$progressBar1.Value = 50
		CheckForErrors
		OperationComplete
	}

	$scriptForm12 = New-SetNTPDialog
	$outputTextBox = $scriptForm12.FindName('OutputBox')
	$scriptForm12.FindName('SetSourceBtn').Add_Click({ OnSetSourceButtonClick })
	$scriptForm12.FindName('CheckConfigBtn').Add_Click({ OnCheckConfigButtonClick })
	$scriptForm12.FindName('CheckSourceBtn').Add_Click({ OnCheckSourceButtonClick })
	$scriptForm12.FindName('ForceResyncBtn').Add_Click({ OnForceResyncButtonClick })

	Write-Host "Loaded ScriptForm12."
	$progressBar1.Value = 0
	CheckForErrors

	[void]$scriptForm12.ShowDialog()

	Stop-Transcript
}

# ---------------------------------------------------------------------------
function New-InformationDialog {
	$win = New-StyledDialog -Title 'Information' -Icon '&#xEA88;' -BodyXaml @'
<StackPanel Margin="16" Width="360">
	<Border Style="{DynamicResource Card}">
		<StackPanel>
			<StackPanel Orientation="Horizontal">
				<Image x:Name="LogoImage" Width="46" Height="46"/>
				<StackPanel VerticalAlignment="Center" Margin="12,0,0,0">
					<TextBlock Text="Script-Package Studio" Style="{DynamicResource H2}"/>
					<TextBlock x:Name="InfoVersionText" Style="{DynamicResource Small}"/>
				</StackPanel>
			</StackPanel>
			<Border Style="{DynamicResource Divider}"/>
			<Button x:Name="OpenRepoBtn" Style="{DynamicResource BtnPrimary}" Content="Open GitHub Repository"/>
			<Button x:Name="OpenIssueBtn" Style="{DynamicResource BtnSecondary}" Content="Report an Issue or Make a Suggestion" Margin="0,8,0,0"/>
			<Button x:Name="ViewReleasesBtn" Style="{DynamicResource BtnSecondary}" Content="View All Releases" Margin="0,8,0,0"/>
			<Button x:Name="DownloadPortableBtn" Style="{DynamicResource BtnSecondary}" Content="Download Portable Version" Margin="0,8,0,0"/>
			<Button x:Name="ViewReadmeBtn" Style="{DynamicResource BtnSecondary}" Content="View README" Margin="0,8,0,0"/>
		</StackPanel>
	</Border>
</StackPanel>
'@
	$win.FindName('InfoVersionText').Text = $version
	try {
		$logoPath = Join-Path (Get-Location).Path 'Images\logo.png'
		if (Test-Path -LiteralPath $logoPath) {
			$win.FindName('LogoImage').Source = New-ImageSource $logoPath
		}
	} catch {}
	return $win
}

function Show-Information {
	Start-Transcript -IncludeInvocationHeader -Path ".\Logs\Show-Information.txt"
	Write-Host "Running Show-Information script..."
	$progressBar1.Value = 10
	function OnOpenRepoButtonClick {
		Start-Process "https://github.com/Avromiep/Script-Package-Studio"
	}
	function OnOpenIssueButtonClick {
		Start-Process "https://github.com/Avromiep/Script-Package-Studio/issues"
	}
	function OnViewReleasesButtonClick {
		Start-Process "https://github.com/Avromiep/Script-Package-Studio/releases"
	}
	function  OnDownloadPortableButtonClick {
		Start-Process "https://github.com/Avromiep/Script-Package-Studio/releases/latest/download/Script-Package-Studio.zip"
	}
	function OnViewReadmeButtonClick {
		Start-Process "https://github.com/Avromiep/Script-Package-Studio/blob/main/README.md"
	}

	$infoForm = New-InformationDialog
	$infoForm.FindName('OpenRepoBtn').Add_Click({ OnOpenRepoButtonClick })
	$infoForm.FindName('OpenIssueBtn').Add_Click({ OnOpenIssueButtonClick })
	$infoForm.FindName('ViewReleasesBtn').Add_Click({ OnViewReleasesButtonClick })
	$infoForm.FindName('DownloadPortableBtn').Add_Click({ OnDownloadPortableButtonClick })
	$infoForm.FindName('ViewReadmeBtn').Add_Click({ OnViewReadmeButtonClick })

	Write-Host "Loaded infoForm."
	$progressBar1.Value = 0

	[void]$infoForm.ShowDialog()

	Stop-Transcript
}
