﻿[cmdletbinding()]
param(
    $serverBMCIpAddress,
    $serverIPAddress,
    $FirstName,
    $LastName,
    $Email,
    $AmountOfDays,
    $InstallAzureStack,
    $DisconnectedMode
)
try {
    Write-Output "Start runbook Reset and assign server"
    $bmcCred = Get-AutomationPSCredential -Name 'BMCCred'
    $serverCred = Get-AutomationPSCredential -Name 'LocalAdminCred'

    $paramsResetMasHost = @{
        iloIpAddress = $serverBMCIpAddress
        iloCred      = $bmcCred
    }
    Reset-PhysicalNode @paramsResetMasHost

    $paramsWaitBareMetal = @{
        serverIpAddress = $serverIPAddress
        credential      = $serverCred
    }
    Wait-BaremetalDeployment @paramsWaitBareMetal

    $UserName = ("$FirstName.$LastName").Replace(" ", "")
    $password = Get-RandomPassword -length 8

    Write-Output "Configure user [$UserName]"
    $paramsNewUser = @{
        FirstName    = $FirstName
        LastName     = $LastName
        emailAddress = $Email
        Password     = $password
        AmountOfDays = $AmountOfDays
    }
    ConfigureUser @paramsNewUser

    Write-Output "Set password on server."
    $paramsResetPassword = @{
        serverIpAddress = $serverIPAddress
        newPassword     = $Password
        serverCred      = $serverCred
    }
    ResetServerPassword @paramsResetPassword 

    Write-Output "Send mail to user [$UserName]."

    $mailCred = Get-AutomationPSCredential -Name 'SendGridCred'
    $mailFrom = Get-AutomationVariable -Name "SendGridMailFrom"
    $mailServer = Get-AutomationVariable -Name "MailServer"
    $mailFromName = Get-AutomationVariable -Name "SendGridMailFromName"
    $rdGatewayUrl = Get-AutomationVariable -Name "RDGatewayURL"

    Write-Output "Generating tempory RDP file."
    $rdpFile = Get-Content C:\Install\Scripts\MASLABHOST.rdp
    $rdpFile = $rdpFile.Replace("[IPADDRESS]", $ServerIpAddress)
    $rdpFile = $rdpFile.Replace("[GATEWAYURI]", $rdGatewayUrl)
    Set-Content C:\Install\Scripts\MASLAB-$UserName.rdp -Value $rdpFile -Force
    Write-Output "Sending login information + RDP to user [$UserName]."
    $mailParams = @{
        To          = "$FirstName $LastName <$Email>"
        From        = "$mailFromName <$mailFrom>"
        Bcc         = "$mailFromName <$mailFrom>"
        SMTPServer  = $mailServer
        Credential  = $mailCred 
        Subject     = "Azure Stack Lab login"
        Attachments = "C:\Install\Scripts\MASLAB-$UserName.rdp"
        Body        = @"
Hi $FirstName,
<br><br>
Your account has been created / reset. You can use the attached RDP icon where the remote desktop gateway information is already supplied. Or if you use RDP tooling like RoyalTS or Devolutions RDM find here your information:
<br><br>
<h4>Remote Desktop Gateway:</h4>
Server: $rdGatewayUrl
<br>
Username: $env:USERDOMAIN\$UserName
<br>
Password: $Password
<br><br>
<h4>Your server login:</h4>
Username: Administrator (*1) 
<br>
Password: $Password
<br><br> 
Your account will expire after $AmountOfDays day(s). If you need more time on your lab please send a email.
<br><br>
Best regards,
<br>
$mailFromName
<br><br>
(*1)
If you checked the "Azure Stack Pre-installed" checkbox during your request then your username is: AZURESTACK\azurestackadmin. And wait for at least 60 minutes before login as the Azure Stack installer is running and will reboot couple times. Once you are logged in you can track the installation progress.)
<br>
If your RDP icon attached to this mail is blocked, please log in to the website and connect using the "connect" button in your server details pane.
"@
        BodyAsHtml  = $true
        UseSsl      = $true
    }
    Send-MailMessage @mailParams
    Write-Output "Finished. Removing temp RDP file."
    Remove-Item "C:\Install\Scripts\MASLAB-$UserName.rdp" -Force

    if ($InstallAzureStack -eq "True") {
        $serverUpdateQuery = @"
Declare @serverIp nvarchar(100) = '{0}'
SELECT Servers.IpAddress, Servers.Name, AzureADs.TenantName, AzureADs.ServiceAdminUser, AzureADs.ServiceAdminPassword ,AzureADs.TenantUser, AzureADs.TenantPassword
FROM Servers
INNER JOIN AzureADs
ON Servers.Name=AzureADs.ServerName
WHERE Servers.IpAddress=@serverIp
"@ -f $serverIPAddress
        $azuread = Invoke-SqlCmd -Database AzureStackLabDb -query $serverUpdateQuery
        if ($azuread) {
            Write-Output "Install AzureStack."
            $AadAdminCred = New-Object pscredential ($($azuread.ServiceAdminUser), (ConvertTo-SecureString -AsPlainText -Force $($azuread.ServiceAdminPassword)))
            $AadTenantCred = New-Object pscredential ($($azuread.TenantUser), (ConvertTo-SecureString -AsPlainText -Force $($azuread.TenantPassword)))
            $serverCred = New-Object pscredential ("Administrator", (ConvertTo-SecureString -AsPlainText -Force $password))
            $paramsMASInstall = @{
                serverIpAddress      = $serverIPAddress
                LocalAdminCredential = $serverCred
                AADAdminCredential   = $AadAdminCred
                AADTenantCredential  = $AadTenantCred
                AADTenant            = $azuread.TenantName
                DisconnectedMode     = $DisconnectedMode
            }
            Start-InstallAzureStack @paramsMASInstall

            $paramsWatchMASInstall = @{
                serverIpAddress = $serverIPAddress
                credential      = $serverCred
            }
            Watch-AzureStackInstall @paramsWatchMASInstall
        }
        else {
            Write-Error "Cannot obtain Azure AD information"
        }
    }
    Write-Output "Finished runbook Reset and assign server"
}
catch {
    Write-Error $Error[0]
}