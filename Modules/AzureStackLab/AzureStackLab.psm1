﻿if (-not $scriptLog) {
    $scriptLog = "$env:SystemDrive\Logs-MASLAB\Script.$(Get-Date -Format yyyy-MM-dd.hh-mm-ss).log"
    $null = New-Item -Path $scriptLog -ItemType File -Force
}

function Write-VerboseLog {
    [CmdletBinding()]
    param ( 
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [String] $Message
    )

    $ErrorActionPreference = 'Stop'

    "Verbose: $Message" | Out-File $scriptLog -Append
    Write-Verbose $Message -Verbose
}

function Write-WarningLog {
    [CmdletBinding()]
    param ( 
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [String] $Message
    )

    $ErrorActionPreference = 'Stop'

    "Warning: $Message" | Out-File $scriptLog -Append
    Write-Warning $Message
}

function Write-TerminatingErrorLog {
    [CmdletBinding()] 
    param ( 
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [object] $Message
    )

    $ErrorActionPreference = 'Stop'

    # Write Error: line seperately otherwise out message will not contain stack trace
    "Error:" | Out-File $scriptLog -Append
    $Message | Out-File $scriptLog -Append

    throw $Message
}
function Write-LogMessage {
    <#
      .SYNOPSIS
      Writes a log message in the console.
      .DESCRIPTION
      See the Synopsis. It requires the Message parameter.
      .EXAMPLE
      Write-LogMessage -SystemName 'localhost' -Message "My message."
      This command writes "My Message" to the console output.
      .EXAMPLE
      Write-LogMessage -Message "My other message."
      This command writes "My other Message" to the console output.
  #>
    [cmdletbinding()]
    param
    (
        [string]$SystemName = $env:COMPUTERNAME,
        [object]$Message,
        $logPath = $scriptLog,
        [string]$MessageType
    )

    BEGIN {}
    PROCESS {
        Write-Verbose "Writing log message"
        #write-host (Get-Date).ToShortTimeString() -ForegroundColor Cyan -NoNewline
        #write-host ' - [' -ForegroundColor White -NoNewline
        #write-host $systemName -ForegroundColor Yellow -NoNewline
        #write-Host "]::$($message)" -ForegroundColor White
        switch ($MessageType) {
            "Error" {
                Write-TerminatingErrorLog -Message $Message
            }
            "Warning" {
                Write-WarningLog -Message $Message
            }
            "Verbose" {
                Write-VerboseLog -Message $Message
            }
            default {
                #Add-Content -Path $logPath "$((Get-Date).ToShortTimeString()) - [$SystemName]::$($Message)"
                Write-Output ('{0} - [{1}]::{2}' -f ((Get-Date).ToShortTimeString()), $systemName, $message)
            }
        }
    }
    END {}
}

function Reset-PhysicalNode {
    param(
        $iloIpAddress,
        [pscredential]$iloCred,
        [switch]$connectIloConsole
    )

    Write-LogMessage -Message "Stop server [$iloIpAddress]"
    Stop-PcsvDevice -TargetAddress $iloIpAddress -Credential $ilocred -ManagementProtocol IPMI -Confirm:$false
    Start-Sleep -Seconds 3
    Write-LogMessage -Message "Set PXE boot for next startup on server [$iloIpAddress]"
    Set-PcsvDeviceBootConfiguration -TargetAddress $iloIpAddress -Credential $ilocred -ManagementProtocol IPMI -OneTimeBootSource "CIM:Network:1"
    Start-Sleep -Seconds 3
    Write-LogMessage -Message "Start Server [$iloIpAddress]"
    Start-PcsvDevice -TargetAddress $iloIpAddress -Credential $ilocred -ManagementProtocol IPMI -Confirm:$false
    if ($connectIloConsole) {
        Start-Process "$PSScriptRoot\ILO\HPLOCONS.exe" -ArgumentList "-addr $iloIpAddress -name $($ilocred.UserName) -password $($ilocred.GetNetworkCredential().password)"
        Write-LogMessage -Message "Connected to ILO Console [$iloIpAddress]"
        Start-Sleep -Seconds 1
    }
}

function Wait-BaremetalDeployment {
    [cmdletbinding()]
    param(
        $serverIpAddress,
        [pscredential]$credential
    )
    $endTime = (Get-Date).AddMinutes(45)
    Write-LogMessage -Message "[$serverIpAddress] - Waiting for baremetal deployment to finish."
    do {
        if (Test-Connection $serverIpAddress -Quiet -Count 1) {
            $session = $null
            try {
                $session = New-PSSession -ComputerName $serverIpAddress -Credential $credential -ErrorAction SilentlyContinue
            }
            catch {
                if ($session) {
                    Write-LogMessage -Message "Caught exception after session to new OS was created: $_"
                    Remove-PSSession $session -ErrorAction SilentlyContinue
                    $session = $null
                }
                $global:error.RemoveAt(0)
            }

            if ($session) {
                $isNewDeployment = Invoke-Command -Session $session {
                    Test-Path "$env:SystemDrive\SetupComplete.txt"
                }

                if ($isNewDeployment) {
                    Write-LogMessage -Message "[$serverIpAddress] - Finished the OS deployment."
                }
            }
        }


        if ($isNewDeployment) { break }
        Write-LogMessage -Message "[$serverIpAddress] - Waiting till [$endTime] for baremetal deployment... Sleeping 60 seconds."
        Start-Sleep -Seconds 60

    } until ([DateTime]::Now -gt $endTime)

    if ($isNewDeployment) {
        Write-LogMessage -Message "[$serverIpAddress] - Bare metal deployment has completed."
    }
    else {
        Write-LogMessage -Message "[$serverIpAddress] - Bare metal deployment has completed." -MessageType "Error"
    }
}
function Start-InstallAzureStack {
    [cmdletbinding()]
    param(
        $serverIpAddress,
        [pscredential]$LocalAdminCredential,
        [pscredential]$AADAdminCredential,
        [pscredential]$AADDelegatedAdminCredential,
        [pscredential]$AADTenantCredential,
        $AADTenant,
        $DisconnectedMode
    )
    $ip = $serverIpAddress.Split('.')
    $Gateway = "$($ip[0]).$($ip[1]).$($ip[2]).1"
    Write-LogMessage -Message "[$serverIpAddress] - Prepare host for Azure Stack installation."
    Write-LogMessage -Message "[$serverIpAddress] - Start Azure Stack installation has been triggered."
    Invoke-Command -ScriptBlock {
        param($LocalAdminCredential, $AADAdminCredential, $AADDelegatedAdminCredential, $AADTenantCredential, $AADTenant, $serverIpAddress, $Gateway, $DisconnectedMode)
        $LocalAdminPassword = $LocalAdminCredential.GetNetworkCredential().Password
        $AADAdminUser = $AADAdminCredential.UserName
        $AADAdminPassword = $AADAdminCredential.GetNetworkCredential().Password
        $AADDelegatedAdminUser = $AADDelegatedAdminCredential.UserName
        $AADDelegatedAdminPassword = $AADDelegatedAdminCredential.GetNetworkCredential().Password
        $AADTenantUser = $AADTenantCredential.UserName
        $AADTenantPassword = $AADTenantCredential.GetNetworkCredential().Password
    
        $installscript = @'
cd C:\CloudDeployment\Setup
$adminpass = ConvertTo-SecureString '{0}' -AsPlainText -Force 
$aadpass = ConvertTo-SecureString '{1}' -AsPlainText -Force 
$aadcred = New-Object System.Management.Automation.PSCredential ('{2}', $aadpass)
$InfraAzureDirectoryTenantName = '{3}'

'@ -f $LocalAdminPassword, $AADAdminPassword, $AADAdminUser, $AADTenant
        if ($DisconnectedMode -eq "True") {
            $installscript += @'
.\InstallAzureStackPOC.ps1 -AdminPassword $adminpass -TimeServer '129.6.15.28' -UseADFS
'@ 
        }
        else {
            $installscript += @'
.\InstallAzureStackPOC.ps1 -AdminPassword $adminpass -InfraAzureDirectoryTenantAdminCredential $aadcred -InfraAzureDirectoryTenantName $InfraAzureDirectoryTenantName -TimeServer '129.6.15.28'
'@ 
        }
        $installscript | Out-File C:\CloudDeployment\InstallAzurestack.ps1 -Force
        if ($AADDelegatedAdminCredential) {
            $logininfo = @'
Service Administrator:
{0}
{1}

Delegated Serviceadministrator:
{4}
{5}

Tenant User:
{2}
{3}

'@ -f $AADAdminUser, $AADAdminPassword, $AADTenantUser, $AADTenantPassword, $AADDelegatedAdminUser, $AADDelegatedAdminPassword
        }
        else {
            $logininfo = @'
Service Administrator:
{0}
{1}

Tenant User:
{2}
{3}

'@ -f $AADAdminUser, $AADAdminPassword, $AADTenantUser, $AADTenantPassword
        }
        if ($DisconnectedMode -eq "True") {
            $logininfo = @'
AZURESTACK\CloudAdmin
<Password that you received in the email
'@ 
        }
        $logininfo | Out-File C:\Users\Public\Desktop\AzureStackLoginInfo.txt -Force
        $WinLogonRegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        Set-ItemProperty $WinLogonRegPath "DefaultUsername" -Value "Administrator"
        Set-ItemProperty $WinLogonRegPath "DefaultPassword" -Value "$LocalAdminPassword"
        Set-ItemProperty $WinLogonRegPath "AutoAdminLogon" -Value "1"
        Set-ItemProperty $WinLogonRegPath "AutoLogonCount" -Value "1"
        $RunOnceRegPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
        Set-ItemProperty $RunOnceRegPath "InstallAzureStack" -Value "powershell.exe -file C:\CloudDeployment\installazurestack.ps1 -WindowStyle Normal -NoLogo -NoProfile"
        Set-NetFirewallProfile -Profile Domain, Public, Private -Enabled False
        Get-NetAdapter | Where-Object {$_.Status -eq "Disconnected"} | Disable-NetAdapter -Confirm:$false
        Get-NetAdapter | Where-Object {$_.LinkSpeed -eq '1 Gbps'} | Disable-NetAdapter -Confirm:$false
        $firstAdapter = Get-NetIPAddress | Where-Object {$_.IPv4Address -eq $serverIpAddress} | Select-Object -ExpandProperty InterfaceIndex
        Get-NetAdapter | Where-Object InterfaceIndex -NotContains $firstAdapter | Disable-NetAdapter -Confirm:$false
        Get-NetAdapter -InterfaceIndex $firstAdapter | Rename-NetAdapter -NewName "MAS_Uplink"
        Remove-NetIPAddress -InterfaceAlias "MAS_Uplink" -Confirm:$false
        $null = New-NetIPAddress -InterfaceAlias "MAS_Uplink" -IPAddress $serverIpAddress -PrefixLength 24 -DefaultGateway $Gateway -AddressFamily IPv4 -Confirm:$false
        Set-DnsClientServerAddress -InterfaceAlias "MAS_Uplink" -ServerAddresses 8.8.8.8 -Confirm:$false
        Start-Sleep -Seconds 300
        Rename-Computer -NewName AZS-HVN01 -Restart
    } -ComputerName $serverIpAddress -Credential $LocalAdminCredential -ArgumentList $LocalAdminCredential, $AADAdminCredential, $AADDelegatedAdminCredential, $AADTenantCredential, $AADTenant, $serverIpAddress, $Gateway, $DisconnectedMode
}
function Watch-AzureStackInstall {
    [cmdletbinding()]
    param(
        $serverIpAddress,
        [pscredential]$credential
    )
    Write-LogMessage -Message "[$serverIpAddress] - Check Azure Stack installation."
    $endTime = (Get-Date).AddMinutes(300)
    do {
        if (Test-Connection $serverIpAddress -Quiet -Count 1) {
            $session = $null
            try {
                $session = New-PSSession -ComputerName $serverIpAddress -Credential $credential -ErrorAction SilentlyContinue
            }
            catch {
                if ($session) {
                    Write-LogMessage -Message " Caught exception after session to new OS was created: $_"
                    Remove-PSSession $session -ErrorAction SilentlyContinue
                    $session = $null
                }
                $global:error.RemoveAt(0)
            }

            if ($session) {
                $result = Invoke-Command -ScriptBlock {
                    $null = New-Item -ItemType Directory C:\CloudDeployment\Logs\Temp -Force -ErrorAction SilentlyContinue
                    Copy-Item -Path C:\CloudDeployment\Logs\* -Destination C:\CloudDeployment\Logs\Temp\ -Force -ErrorAction Stop
                    Write-Verbose "Searching for line: Action: Action plan 'Deployment' completed. "
                    $successsearch = Select-String -Path  C:\CloudDeployment\Logs\Temp\*.log -pattern "Action: Action plan 'Deployment' completed."
                    Write-Verbose "Searching for line: Action: Stopping invocation of action plan. "
                    $failedsearch = Select-String -Path  C:\CloudDeployment\Logs\Temp\*.log -pattern "Stopping invocation of action plan."
                    Remove-Item  C:\CloudDeployment\Logs\Temp\ -Force -Recurse
                    $AzureStackInstall = "Running"
                    if ($successsearch.Matches.success) {
                        $AzureStackInstall = "Installed"
                    }
                    if ($failedsearch.Matches.success) {
                        $AzureStackInstall = "Failed"
                    }
                    return $AzureStackInstall

                } -Session $session -ErrorAction Stop
                Write-LogMessage -Message "[$serverIpAddress] - The Azure Stack installation status is: $result"
                Remove-PSSession $session -Confirm:$false -ErrorAction SilentlyContinue
                if ($result -eq "Installed") {break; }
                if ($result -eq "Failed") {
                    #handle failed deployments
                    $failedDeployment = $true
                    Write-Error "[$serverIpAddress] - Error Installing Azure Stack"
                    break;
                }
                if ($result -eq "Running") {
                    Write-LogMessage -Message "[$serverIpAddress] - Waiting for AzureStack to be Installed ... Waiting 60 seconds"
                }
            }
        }       
        Start-Sleep -Seconds 60
    } until ([DateTime]::Now -gt $endTime)

    if ([DateTime]::Now -gt $endTime -or $failedDeployment) {
        Write-LogMessage -Message "[$serverIpAddress] - Deployment of Azure Stack failed." -MessageType "Error"
    }

    if ($result -eq "Installed") {
        Write-LogMessage -Message "[$serverIpAddress] - Deployment of Azure Stack succeeded."
    }
    return $result
}
function Start-AzureStackHostConfiguration {
    param(
        [ipaddress]$serverIpAddress,
        [pscredential]$LocalAdminCredential,
        [pscredential]$AADAdminCredential,
        [pscredential]$LABShareAdminCredential
    )

    Write-LogMessage -Message "[$serverIpAddress] - Configure Azure Stack host."
    Invoke-Command -ScriptBlock {
        param(
            [ipaddress]$serverIpAddress,
            [pscredential]$LocalAdminCredential,
            [pscredential]$AADAdminCredential,
            [pscredential]$LABShareAdminCredential
        )
        #region Uninstall Azure Powershell
        Start-Process msiexec.exe -ArgumentList '/x "{3E92648F-29FD-4832-89A1-243C6B770445}" /quiet' -Wait -ErrorAction SilentlyContinue                
        Start-Process msiexec.exe -ArgumentList '/x "{386C337F-8F89-4530-A231-0FFFBDAB410D}" /quiet' -Wait -ErrorAction SilentlyContinue
        Start-Process msiexec.exe -ArgumentList '/x "{358A58BE-7B5E-4C13-BB01-7E29F6823249}" /quiet' -Wait -ErrorAction SilentlyContinue
        Start-Process msiexec.exe -ArgumentList '/x "{3BA7CAA9-97BA-4528-B7E1-B640910BB149}" /quiet' -Wait -ErrorAction SilentlyContinue
        
        #endregion

        #region Cleanup Diskspace
        Remove-Item C:\CloudDeployment\Images -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item C:\CloudDeployment\NuGetStore -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item C:\CloudDeployment\SpecializedImages -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item C:\CloudDeployment\Monitoring -Recurse -Force -ErrorAction SilentlyContinue
        #endregion

        #region Set Power Plan to High Performance
        Try {
            $HighPerf = powercfg -l | ForEach-Object {if ($_.contains("High performance")) {$_.split()[3]}}
            $CurrPlan = $(powercfg -getactivescheme).split()[3]
            if ($CurrPlan -ne $HighPerf) {powercfg -setactive $HighPerf}
            #Write-LogMessage -Message "Power Plan set to High Performance." 
        }
        Catch {
            Write-Warning -Message "Unable to set power plan to high performance"
        }

        #endregion

        #region Set home page Azure Stack Admin Portal
        $path = 'HKCU:\Software\Microsoft\Internet Explorer\Main\'
        $name = 'start page'
        $value = 'https://portal.local.azurestack.external/'
        $null = Set-Itemproperty -Path $path -Name $name -Value $value
        #Write-LogMessage -Message "IE Homepage set to https://portal.local.azurestack.external/" 
        #endregion

        #region Set AD Password policy to 180 days
        Set-ADDefaultDomainPasswordPolicy -MaxPasswordAge 180.00:00:00 -Identity azurestack.local -Server AZS-DC01
        #endregion

        #region disable IE ESC and UAC
        function Disable-InternetExplorerESC {
            $AdminKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
            $UserKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"
            Set-ItemProperty -Path $AdminKey -Name "IsInstalled" -Value 0 -Force
            Set-ItemProperty -Path $UserKey -Name "IsInstalled" -Value 0 -Force
            Stop-Process -Name Explorer -Force
            #Write-LogMessage -Message "IE Enhanced Security Configuration (ESC) has been disabled." 
        }
        function Enable-InternetExplorerESC {
            $AdminKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
            $UserKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"
            Set-ItemProperty -Path $AdminKey -Name "IsInstalled" -Value 1 -Force
            Set-ItemProperty -Path $UserKey -Name "IsInstalled" -Value 1 -Force
            Stop-Process -Name Explorer
            #Write-LogMessage -Message "IE Enhanced Security Configuration (ESC) has been enabled." 
        }
        function Disable-UserAccessControl {
            Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "ConsentPromptBehaviorAdmin" -Value 00000000 -Force
            #Write-LogMessage -Message "User Access Control (UAC) has been disabled."     
        }
        Disable-UserAccessControl
        Disable-InternetExplorerESC
        #endregion

        #region Disable realtime scanning (Defender)
        Set-MpPreference -DisableRealtimeMonitoring $true -DisableBehaviorMonitoring $true -DisablePrivacyMode $true -DisableIntrusionPreventionSystem $true `
            -DisableScriptScanning $true -DisableArchiveScanning $true -DisableScanningMappedNetworkDrivesForFullScan $true -DisableIOAVProtection $true `
            -DisableEmailScanning $true -DisableScanningNetworkFiles $true -DisableBlockAtFirstSeen $true -DisableAutoExclusions $true
        #Write-LogMessage -Message "Realtime scanning has been disabled."  
        #endregion

        #region Copy files
        #Write-LogMessage -Message "Copying files to d:\"  

        $z = New-PSDrive -Name InstallShare -PSProvider FileSystem -Root '\\10.1.100.43\labshare' -Credential $LABShareAdminCredential
        Copy-Item -Path \\10.1.100.43\LabShare\Training\ -Destination D:\ -Recurse -ErrorAction SilentlyContinue
        Copy-Item -Path "\\10.1.100.43\LabShare\HPE Education\Labs" -Destination D:\ -Recurse -ErrorAction SilentlyContinue
        
        #Write-LogMessage -Message "Files have been copied."  
        #endregion

        #region Install Azure Stack Tools for RTM
        $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Install-Module -Name 'AzureRm.Bootstrapper' -Force
        Install-AzureRmProfile -profile '2018-03-01-hybrid' -Force 
        Install-Module -Name AzureStack -RequiredVersion 1.6.0 -Force
        Invoke-WebRequest -UseBasicParsing -Uri https://codeload.github.com/Azure/AzureStack-Tools/zip/master -OutFile "$env:TEMP\master.zip"
        Expand-Archive "$env:TEMP\master.zip" -DestinationPath C:\ -Force
        Remove-Item "$env:TEMP\master.zip"
        $Folder = New-Item -ItemType Directory -Path ~\Documents\WindowsPowerShell\Modules -Force
        Get-ChildItem -Path C:\AzureStack-Tools-master -Directory | ForEach-Object -Process {
            if (Get-ChildItem -Path $_.FullName -Filter *.psm1) {
                $PSM1 = Get-ChildItem -Path $_.FullName -Filter *.psm1
                Copy-Item -Path $_.FullName -Destination "$($Folder.FullName)\$($PSM1.BaseName)" -Recurse
                New-ModuleManifest -Path "$($Folder.FullName)\$($PSM1.BaseName)\$($PSM1.BaseName).psd1" -RootModule $PSM1.BaseName
            }
        } 
        #endregion

        #region Configure Azure Stack environment
        $tenantName = $AADAdminCredential.UserName.Split('@')[1]
        $azEnv = Add-AzureRmEnvironment -Name "AzureStackAdmin" -ArmEndpoint "https://adminmanagement.local.azurestack.external" 
        $AadTenant = Get-AzsDirectoryTenantID -AADTenantName $tenantName -EnvironmentName AzureStackAdmin
        $AdminArmEndpoint = $azEnv.ResourceManagerUrl
        $tenantArmEndpoint = "https://management.local.azurestack.external" #used in RP deployment

        #endregion

        #region Logon to Azure Stack RTM
        #$aadCredential = New-Object System.Management.Automation.PSCredential("aadadmin@tenant.onmicrosoft.com",(ConvertTo-SecureString -String "password" -AsPlainText -Force))
        Login-AzureRmAccount -EnvironmentName "AzureStackAdmin" -TenantId $AadTenant -Credential $AADAdminCredential
        #endregion 

        #region Register all RP's
        $null = Get-AzureRmResourceProvider -ListAvailable | Register-AzureRmResourceProvider
        #endregion

        #region Create Default Offer and Plan
        $PlanName = "Trial"
        $OfferName = "Trial"
        $RGName = "PlansandOffersRG"
        $Location = (Get-AzsLocation).Name
        $quotaIDs = @()
        $quotaIDs += (Get-AzsNetworkQuota).ID
        $quotaIDs += (Get-AzsComputeQuota).ID
        $quotaIDs += (Get-AzsStorageQuota).ID
        $quotaIDs += (Get-AzsKeyVaultQuota).ID
        
        New-AzureRmResourceGroup -Name $RGName -Location $Location -Force
        $plan = New-AzsPlan -Name $PlanName -DisplayName $PlanName -Location $Location -ResourceGroupName $RGName -QuotaIds $QuotaIDs
        New-AzsOffer -Name $OfferName -DisplayName $OfferName -State Public -BasePlanIds $plan.Id -ResourceGroupName $RGName -Location $Location
        #endregion

        #region Adding default image Windows Server 2016
        $VHDPath = "D:\Training\Images\WindowsServer2016DatacenterwithGUI1806.vhd"
        New-AzureRmResourceGroup -Name 'PlatformImages'-Location $Location -Force
        $storageAcct = New-AzureRmStorageAccount -ResourceGroupName 'PlatformImages' -Name 'platformimages' -Type Standard_LRS -Location $Location
        $blobUri = $storageAcct.PrimaryEndpoints.Blob.AbsoluteUri + "images/WindowsServer2016DatacenterwithGUI1806.vhd"
        $storageAcct | New-AzureStorageContainer -Name 'images' -Permission Blob -ErrorAction SilentlyContinue
        Add-AzureRmVhd -ResourceGroupName 'PlatformImages' -Destination $blobUri -LocalFilePath $VHDPath
        Add-AzsPlatformimage -publisher MicrosoftWindowsServer -offer WindowsServer -sku 2016-Datacenter -version 1.18.6 -OSType Windows -OSUri $blobUri

        $galleryItemUri = "https://github.com/mattmcspirit/azurestack/raw/master/deployment/packages/WindowsServer/Microsoft.WindowsServer2016Datacenter-ARM.1.0.0.azpkg"
        Add-AzsGalleryItem -GalleryItemUri $galleryItemUri -Force -Confirm:$false
        #endregion

        <#
        #region Install SQL RP
        Set-Location 'D:\Training\PaaS\SQL'
        $vmLocalAdminPass = ConvertTo-SecureString "<PASSWORD>" -AsPlainText -Force
        $vmLocalAdminCreds = New-Object System.Management.Automation.PSCredential ("sqlrpadmin", $vmLocalAdminPass)
        .\DeploySQLProvider.ps1 -DirectoryTenantID $AadTenant -AzCredential $AADAdminCredential -VMLocalCredential $vmLocalAdminCreds -ResourceGroupName "System.Sql" -VmName "SQLVM" -ArmEndpoint $AdminArmEndpoint -TenantArmEndpoint $tenantArmEndpoint

        #endregion

        #region Install App Service RP
        Set-Location 'D:\Training\PaaS\AppService'
        Set-ExecutionPolicy -ExecutionPolicy Bypass -Force
        .\Create-AppServiceCerts.ps1 -pfxPassword (ConvertTo-SecureString -AsPlainText -Force '<PASSWORD>') 

        #endregion

        #region Install MySQL RP
        Set-Location 'D:\Training\PaaS\MySQL'
        $vmLocalAdminPass = ConvertTo-SecureString "<PASSWORD>" -AsPlainText -Force
        $vmLocalAdminCreds = New-Object System.Management.Automation.PSCredential ("mysqlrpadmin", $vmLocalAdminPass)
        .\DeployMySQLProvider.ps1 -DirectoryTenantID $AadTenant -AzCredential $AADAdminCredential -VMLocalCredential $vmLocalAdminCreds -ResourceGroupName "System.MySql" -VmName "SystemMySqlRP" -ArmEndpoint $AdminArmEndpoint -TenantArmEndpoint $tenantArmEndpoint
        #endregion
        #>
    } -ComputerName $serverIpAddress -Credential $LocalAdminCredential -ArgumentList $serverIpAddress, $LocalAdminCredential, $AADAdminCredential, $LABShareAdminCredential
}

function ConfigureUser {
    [cmdletbinding()]
    param(
        $FirstName,
        $LastName,
        $Password,
        $emailAddress,
        $AmountOfDays
    )
    Write-Output "Retrieving AD credentals from SMA."
    $AdCred = Get-AutomationPSCredential -Name 'ADAdminCred'
    $UserName = ("$FirstName.$LastName").Replace(" ", "")
    Write-Output "Check if user exist."
    $aduser = Get-ADUser -filter "SAMAccountName -like ""$UserName"""
    if (!$aduser) {
        $userParams = @{
            AccountExpirationDate = ((Get-Date).AddDays($AmountOfDays + 1))
            Name                  = $username
            GivenName             = $FirstName
            SurName               = $LastName
            DisplayName           = "$FirstName $LastName"
            EmailAddress          = $emailAddress
            PasswordNeverExpires  = 1 
            cannotchangepassword  = 1 
            path                  = "OU=USR,OU=LAB,DC=AzureStack,DC=Lab" 
            enabled               = 1 
            AccountPassword       = (ConvertTo-SecureString -AsPlainText $Password -Force)
            Description           = "Azure Stack Lab Account"
            Credential            = $AdCred
        }
        Write-Output "Creating AD user [$UserName]"
        New-ADUser @userParams
        Write-Output "Adding user [$UserName] to the Remote Desktop Gateway Group."
        Add-ADGroupMember -Identity "RDG_Users" -Members $UserName -Credential $AdCred
        Write-Output "Finished - User [$UserName] Created and added to RD Gateway Group."
    }
    else {
        Write-Output "Reset password for user [$UserName]"
        $userParams = @{
            Identity    = $adUser.Name
            Credential  = $AdCred
            NewPassword = ConvertTo-SecureString -AsPlainText $Password -Force
            Reset       = $true
            Confirm     = $false
        }
        Set-ADAccountPassword @userParams
        $aduser | Set-ADUser -AccountExpirationDate ((Get-Date).AddDays($AmountOfDays + 1)) -Credential $AdCred
        Write-Output "Finished - Password for User [$UserName]"
    }
}

function Get-AlmostExpiredUsers {
    $allUsers = Get-ADUser -Filter * -SearchBase "OU=LAB,DC=AzureStack,DC=Lab" -Properties @('AccountExpirationDate', 'mail')
    $expiredUsers = @()
    $allUsers | ForEach-Object -Process {
        $currentDate = Get-Date
        $accountExpirationDate = $_.AccountExpirationDate
        if ((($currentDate.AddDays(5)) -ge $accountExpirationDate) -and ($accountExpirationDate -ne $null)) {
            $expiredUsers += $_
        }
    }
    return $expiredUsers
}

function Delete-ExpiredUsers {
    $allUsers = Get-ADUser -Filter * -SearchBase "OU=LAB,DC=AzureStack,DC=Lab" -Properties @('AccountExpirationDate', 'mail')
    $expiredUsers = @()
    $allUsers | ForEach-Object -Process {
        $currentDate = Get-Date
        $accountExpirationDate = $_.AccountExpirationDate
        if (($currentDate.Date -gt $accountExpirationDate.Date) -and ($accountExpirationDate -ne $null)) {
            $expiredUsers += $_
            Remove-ADUser $_.SamAccountName -Confirm:$false
        }
    }
    Write-Output $expiredUsers
}

function ResetServerPassword {
    [cmdletbinding()]
    param(
        $serverIpAddress,
        $newPassword,
        $serverCred
    )
    try {
        Write-Output "Reset server Administrator password on server [$serverIpAddress]"
        Invoke-Command -ScriptBlock {
            net user massupport Supp0rt17! /add
            WMIC USERACCOUNT WHERE "Name='massupport'" SET PasswordExpires=FALSE
            net localgroup Administrators massupport /add
            net user Administrator $using:newPassword
            Write-Host "Password successful reset"
        } -ComputerName $serverIpAddress -ArgumentList $newPassword -Credential $serverCred
    }
    catch {
        Write-Error $Error[0]
    }
}

function Invoke-SqlCmd {
    [cmdletbinding()]
    param(
        $SQLServer,
        $Database,
        $query,
        $username = 'sa',
        $password
    )
    if (!$SQLServer) {
        Write-Output "No SQLServer specified, retrieving it from SMA"
        $SQLServer = Get-AutomationVariable -Name "SQLServer"
        Write-Output "Using: $SQLServer"
    }
    if (!$password) {
        Write-Output "No password specified, using SMA SQL Admin"
        $sqluser = Get-AutomationPSCredential -Name 'SQLAdmin'
        $user = $sqluser.UserName
        $password = $sqluser.GetNetworkCredential().Password
    }

    $result = Invoke-Command -ScriptBlock {
        $table = Invoke-SqlCmd -Database $using:Database -Query $using:query -Username $using:username -Password $using:password
        return $table
    } -ComputerName $SQLServer #-Credential $cred
    return $result
}

$ascii = $NULL;
For ($a = 65; $a –le 90; $a++) {$ascii += , [char][byte]$a }
For ($a = 48; $a –le 57; $a++) {$ascii += , [char][byte]$a }
For ($a = 97; $a –le 122; $a++) {$ascii += , [char][byte]$a }
Function Get-RandomPassword {
    Param(
        [int]$length = 8,
        [string[]]$sourcedata = $ascii
    )

    For ($loop = 1; $loop –le $length; $loop++) {
        $TempPassword += ($sourcedata | GET-RANDOM)
    }
    return $TempPassword + '!'
}

Export-ModuleMember -Function Write-LogMessage, Reset-PhysicalNode, Wait-BaremetalDeployment, Start-InstallAzureStack, Watch-AzureStackInstall, Start-AzureStackHostConfiguration, Invoke-SqlCmd, ResetServerPassword, ConfigureUser, Get-RandomPassword, Get-AlmostExpiredUsers, Delete-ExpiredUsers