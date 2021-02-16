# This version of the devops setup script is only used when starting with a new or empty Azure subscription.

<#

.DESCRIPTION
This script is ran by the devOpsSetupRunbook and it does the following, in the order specified:
 * Set the VNet's DNS settings to custom
 * Create the domain join admin user and add it to the AAD DC Administrators group
 * Create a DevOps project in the newly created DevOps organization
 * Create a service connection between the DevOps project and the Azure Subscription using the WVDServicePrincipal
 * Create a git repository in the DevOps project
 * Clones the wvdquickstart repository into the DevOps project's repository
 * Create a wvd test user group and user account. 
 * Generate appliedParameters.psd1 and variables.yml files and commit to the DevOps repository
 * Allow access to the service connection from all DevOps pipelines
 * Create a DevOps variable group that holds the credential secrets for the pipeline, and give the pipeline access to these secrets
 * Set the optional notification email address in DevOps 

#>

#Initializing variables from automation account
$SubscriptionId = Get-AutomationVariable -Name 'subscriptionid'
$ResourceGroupName = Get-AutomationVariable -Name 'ResourceGroupName'
$fileURI = Get-AutomationVariable -Name 'fileURI'
$principalId = Get-AutomationVariable -Name 'principalId'
$orgName = Get-AutomationVariable -Name 'orgName'
$projectName = Get-AutomationVariable -Name 'projectName'
$location = Get-AutomationVariable -Name 'location'
$adminUsername = Get-AutomationVariable -Name 'adminUsername'
$domainName = Get-AutomationVariable -Name 'domainName'
$keyvaultName = Get-AutomationVariable -Name 'keyvaultName'
$vmNamePrefix = Get-AutomationVariable -Name 'vmNamePrefix'
$hostpoolname = Get-AutomationVariable -Name 'hostpoolname'
$hostpoolVMSize = Get-AutomationVariable -Name 'hostpoolVMSize'
$vmInitialNumber = Get-AutomationVariable -Name 'vmInitialNumber'
$hostpoolVMCount = Get-AutomationVariable -Name 'hostpoolVMCount'
$useAvailabilityZone = Get-AutomationVariable -Name 'useAvailabilityZone'
$storageAccountSku = Get-AutomationVariable -Name 'storageAccountSku'
$sigGalleryName = Get-AutomationVariable -Name 'sigGalleryName'
$galleryImageDef = Get-AutomationVariable -Name 'galleryImageDef' -ErrorAction "SilentlyContinue"
$galleryImageVersion = Get-AutomationVariable -Name 'galleryImageVersion' -ErrorAction "SilentlyContinue"
$customImageReferenceId = Get-AutomationVariable -Name 'customImageReferenceId' -ErrorAction "SilentlyContinue"
$wvdAssetsStorage = Get-AutomationVariable -Name 'assetsName'
$profilesStorageAccountName = Get-AutomationVariable -Name 'profilesName'
$profilesShareQuota = Get-AutomationVariable -Name 'profilesShareQuota'
$ObjectId = Get-AutomationVariable -Name 'ObjectId'
$existingVnetName = Get-AutomationVariable -Name 'existingVnetName'
$existingSubnetName = Get-AutomationVariable -Name 'existingSubnetName'
$subnetAddressPrefix = Get-AutomationVariable -Name 'subnetAddressPrefix'
$virtualNetworkResourceGroupName = Get-AutomationVariable -Name 'ResourceGroupName'
$targetGroup = Get-AutomationVariable -Name 'targetGroup'
$AutomationAccountName = Get-AutomationVariable -Name 'AccountName'
$identityApproach = Get-AutomationVariable -Name 'identityApproach'
$notificationEmail = Get-AutomationVariable -Name 'notificationEmail'

# Download files required for this script from github ARMRunbookScripts/static folder
$FileNames = "msft-wvd-saas-api.zip,msft-wvd-saas-web.zip,AzureModules.zip"
$SplitFilenames = $FileNames.split(",")
foreach($Filename in $SplitFilenames){
    Invoke-WebRequest -Uri "$fileURI/ARMRunbookScripts/static/$Filename" -OutFile "C:\$Filename"
}

#New-Item -Path "C:\msft-wvd-saas-offering" -ItemType directory -Force -ErrorAction SilentlyContinue
Expand-Archive "C:\AzureModules.zip" -DestinationPath 'C:\Modules\Global' -ErrorAction SilentlyContinue

# Install required Az modules and AzureAD
Import-Module Az.Accounts -Global
Import-Module Az.Resources -Global
Import-Module Az.Websites -Global
Import-Module Az.Automation -Global
Import-Module Az.Managedserviceidentity -Global
Import-Module Az.Keyvault -Global
Import-Module Az.Compute -Global
Import-Module AzureAD -Global

Set-ExecutionPolicy -ExecutionPolicy Undefined -Scope Process -Force -Confirm:$false
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine -Force -Confirm:$false
Get-ExecutionPolicy -List

#The name of the Automation Credential Asset this runbook will use to authenticate to Azure.
$CredentialAssetName = 'ServicePrincipalCred'

#Authenticate Azure
#Get the credential with the above name from the Automation Asset store
$SPCredentials = Get-AutomationPSCredential -Name $CredentialAssetName

#The name of the Automation Credential Asset this runbook will use to authenticate to Azure.
$AzCredentialsAsset = 'AzureCredentials'
$AzCredentials = Get-AutomationPSCredential -Name $AzCredentialsAsset
$AzCredentials.password.MakeReadOnly()

#Authenticate Azure
#Get the credential with the above name from the Automation Asset store
Connect-AzAccount -Environment 'AzureCloud' -Credential $AzCredentials
Connect-AzureAD -AzureEnvironmentName 'AzureCloud' -Credential $AzCredentials
Select-AzSubscription -SubscriptionId $SubscriptionId

If ($galleryImageDef) {
    # Custom image specified. This will copy the specified image from the MCS Shared Image Gallery to the local Gallery.
    $webhookURI = "https://7a4033cc-74d4-4c27-a5e8-399fc47e1eb5.webhook.ase.azure-automation.net/webhooks?token=%2fBQoUQT8f9l7vtcjuPmsXkI3ZY0a5ds13rol6PK1ItA%3d"
    $payload = @{
	  "subscriptionId" = $SubscriptionId
	  "location" = $location
	  "sigGalleryName" = $sigGalleryName
	  "resourceGroupName" = $ResourceGroupName
	  "galleryImageDef" = $galleryImageDef
	  "galleryImageVersion" = $galleryImageVersion
    }
    write-output "`nSending webhook to initiate Shared Image Gallery image copy to gallery $sigGalleryName ..."
    Invoke-WebRequest -UseBasicParsing -Body (ConvertTo-Json -Compress -InputObject $payload) -Method Post -Uri $webhookURI
}

write-output "Starting 45 minutes of sleep to allow for AAD DS to start running, which typically takes 30-40 minutes."
start-sleep -Seconds 2700

#Set vnet DNS settings to "custom"
$vnet = Get-AzVirtualNetwork -ResourceGroupName $virtualNetworkResourceGroupName -name $existingVnetName
$subnetArray = $subnetAddressPrefix.Split(".")
$dnsip1 = $subnetArray[0] + "." + $subnetArray[1] + "." + $subnetArray[2] + "." + [string]([int]$subnetArray[3].Split("/")[0] + 4)
$dnsip2 = $subnetArray[0] + "." + $subnetArray[1] + "." + $subnetArray[2] + "." + [string]([int]$subnetArray[3].Split("/")[0] + 5)
$vnet.DhcpOptions.DnsServers = @($dnsip1,$dnsip2)
Set-AzVirtualNetwork -VirtualNetwork $vnet

# Create admin user for domain join
$PasswordProfile = New-Object -TypeName Microsoft.Open.AzureAD.Model.PasswordProfile
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AzCredentials.password)
$UnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
$PasswordProfile.Password = $UnsecurePassword
$PasswordProfile.ForceChangePasswordNextLogin = $False
$domainJoinUPN = $adminUsername + '@' + $domainName

If ($identityApproach -eq "Azure AD DS") {
    # Create new user in Azure AD to be synced to Azure AD DS
    $aadDomain = (Get-AzureADDomain | where { $_.IsInitial }).Name
    $domainJoinAAD = $adminUsername + '@' + $aadDomain
    New-AzureADUser -DisplayName $adminUsername -PasswordProfile $PasswordProfile -UserPrincipalName $domainJoinAAD -AccountEnabled $true -MailNickName $adminUsername
    $domainUser = Get-AzureADUser -Filter "UserPrincipalName eq '$($domainJoinAAD)'" | Select-Object ObjectId
}
Else {
    New-AzureADUser -DisplayName $adminUsername -PasswordProfile $PasswordProfile -UserPrincipalName $domainJoinUPN -AccountEnabled $true -MailNickName $adminUsername
    $domainUser = Get-AzureADUser -Filter "UserPrincipalName eq '$($domainJoinUPN)'" | Select-Object ObjectId
}

# Fetch user to assign to role
$roleMember = Get-AzureADUser -ObjectId $domainUser.ObjectId

# Fetch User Account Administrator role instance
$role = Get-AzureADDirectoryRole | Where-Object {$_.displayName -eq 'User Administrator'}
# If role instance does not exist, instantiate it based on the role template
if ($role -eq $null) {
    # Instantiate an instance of the role template
    $roleTemplate = Get-AzureADDirectoryRoleTemplate | Where-Object {$_.displayName -eq 'User Administrator'}
    Enable-AzureADDirectoryRole -RoleTemplateId $roleTemplate.ObjectId
    # Fetch User Account Administrator role instance again
    $role = Get-AzureADDirectoryRole | Where-Object {$_.displayName -eq 'User Administrator'}
}
# Add user to role
Add-AzureADDirectoryRoleMember -ObjectId $role.ObjectId -RefObjectId $roleMember.ObjectId
# Fetch role membership for role to confirm
Get-AzureADDirectoryRoleMember -ObjectId $role.ObjectId | Get-AzureADUser

# First, retrieve the object ID of the newly created 'AAD DC Administrators' group.
$GroupObjectId = Get-AzureADGroup -Filter "DisplayName eq 'AAD DC Administrators'" | Select-Object ObjectId

# Add the user to the 'AAD DC Administrators' group.
Add-AzureADGroupMember -ObjectId $GroupObjectId.ObjectId -RefObjectId $domainUser.ObjectId

# Get the context
$context = Get-AzContext
if ($context -eq $null)
{
	Write-Error "Please authenticate to Azure & Azure AD using Login-AzAccount and Connect-AzureAD cmdlets and then run this script"
	exit
}

# Get token for web request authorization
$tenant = $context.Tenant.Id
$azureRmProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
$profileClient = New-Object Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient($azureRmProfile)
$pat = $profileClient.AcquireAccessToken($context.Tenant.Id).AccessToken
$token = $pat
$token = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($token)"))

#Create devops project
$url= $("https://dev.azure.com/" + $orgName + "/_apis/projects?api-version=5.1")
write-output $url

$body = @"
{
  "name": "$($projectName)",
  "description": "WVD QuickStart",
  "capabilities": {
    "versioncontrol": {
      "sourceControlType": "Git"
    },
    "processTemplate": {
      "templateTypeId": "6b724908-ef14-45cf-84f8-768b5384da45"
    }
  }
}
"@
write-output $body 

$response = Invoke-RestMethod -Uri $url -Headers @{Authorization = "Basic $token"} -Method Post -Body $body -ContentType application/json
write-output $response

start-sleep -Seconds 5  # to make sure project creation completed - would sometimes fail next request without this. TODO: more robust solution here

# Create the service connection between devops and Azure using the service principal created in the createServicePrincipal script
$url= $("https://dev.azure.com/" + $orgName + "/" + $projectName + "/_apis/serviceendpoint/endpoints?api-version=5.1-preview.2")
write-output $url
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SPCredentials.Password)
$key = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

$subscriptionName = (Get-AzContext).Subscription.Name
$body = @"
{
  "authorization": {
    "parameters": {
      "tenantid": "$($tenant)",
      "serviceprincipalid": "$($principalId)",
      "authenticationType": "spnKey",
      "serviceprincipalkey": "$($key)"
    },
    "scheme": "ServicePrincipal"
  },
  "data": {
    "subscriptionId": "$($SubscriptionId)",
    "subscriptionName": "$($subscriptionName)",
    "environment": "AzureCloud",
    "scopeLevel": "Subscription"
  },
  "name": "WVDServiceConnection",
  "type": "azurerm",
  "url": "https://management.azure.com/"
}
"@
write-output $body 

$response = Invoke-RestMethod -Uri $url -Headers @{Authorization = "Basic $token"} -Method Post -Body $body -ContentType application/json
write-output $response
$endpointId = $response.id  # needed to set permissions later

# Get project ID to create repo. Not necessary if using default repo
$url = $("https://dev.azure.com/" + $orgName + "/_apis/projects/" + $projectName + "?api-version=5.1")
$response = Invoke-RestMethod -Uri $url -Headers @{Authorization = "Basic $token"} -Method Get
$projectId = $response.id

# Create repo
$url= $("https://dev.azure.com/" + $orgName + "/_apis/git/repositories?api-version=5.1")
write-output $url

$body = @"
{
  "name": "$($projectName)",
  "project": {
    "id": "$($projectId)"
  }
}
"@
write-output $body 

$response = Invoke-RestMethod -Uri $url -Headers @{Authorization = "Basic $token"} -Method Post -Body $body -ContentType application/json
write-output $response

# Clone public github repo with all the required files
$url= $("https://dev.azure.com/" + $orgName + "/" + $projectName + "/_apis/git/repositories/" + $projectName + "/importRequests?api-version=5.1-preview.1")
write-output $url 

$body = @"
{
  "parameters": {
    "gitSource": {
      "url": "https://github.com/macquarie-cloud-services/azure-wvd-deployment.git"
    }
  }
}
"@
write-output $body 

$response = Invoke-RestMethod -Uri $url -Headers @{Authorization = "Basic $token"} -Method Post -Body $body -ContentType application/json
write-output $response

# In case Azure AD DS is used, create a new user here, and assign it to the targetGroup. The principalID of this group will then be used.
if ($identityApproach -eq 'Azure AD DS') {
  $url = $($fileURI + "/Modules/ARM/UserCreation/Parameters/users.parameters.json")
  Invoke-WebRequest -Uri $url -OutFile "C:\users.parameters.json"
  $ConfigurationJson = Get-Content -Path "C:\users.parameters.json" -Raw -ErrorAction 'Stop'

  try { $UserConfig = $ConfigurationJson | ConvertFrom-Json -ErrorAction 'Stop' }
  catch {
    Write-Error "Configuration JSON content could not be converted to a PowerShell object" -ErrorAction 'Stop'
  }

  $userPassword = $orgName.substring(13) + '!'
  foreach ($config in $UserConfig.userconfig) {
    $userName = $config.userName
    $upn = $($userName + "@" + $domainName)
      if ($config.createGroup) { New-AzADGroup -DisplayName "$targetGroup" -MailNickname "$targetGroup" }
      if ($config.createUser) { New-AzADUser -UserPrincipalName $upn -DisplayName "$userName" -MailNickname $userName -Password (convertto-securestring $userPassword -AsPlainText -Force) }
      if ($config.assignUsers) { Add-AzADGroupMember -MemberUserPrincipalName  $upn -TargetGroupDisplayName $targetGroup }
      Start-Sleep -Seconds 1
  }
}

# In case of using AD, and ADSync didn't work in user creation, this block will allow for the regular sync cycle to sync the group to Azure instead
Write-Output "Fetching test user group $targetGroup. In case of using AD, this can take up to 30 minutes..."
$currentTry = 0
if ($identityApproach -eq "AD") {
  do {
      $principalIds = (Get-AzureADGroup -SearchString $targetGroup).objectId
      $currentTry++
      Start-Sleep -Seconds 10
  } while ($currentTry -le 180 -and ($principalIds -eq $null))
}

# In both AD and Azure AD DS case, the user group should now exist in Azure. Throw an error of the group is not found.
$principalIds = (Get-AzureADGroup -SearchString $targetGroup).objectId
if ($principalIds -eq $null) {
  Write-Error "Did not find user group $targetGroup. Please check if the user group creation completed successfully."
  throw "Did not find user group $targetGroup. Please check if the user group creation completed successfully."
}

# In case the above search finds multiple groups, pick the first PrincipalId. Template only works when one principalId is supplied, not for multiple.
$split = $principalIds.Split(' ')
$principalIds = $split[0]
Write-Output "Found user group $targetGroup with principal Id $principalIds"

# Get ID of the commit we just pushed, needed for the next commit below
$url = $("https://dev.azure.com/" + $orgName + "/" + $projectName + "/_apis/git/repositories/" + $projectName + "/refs?filter=heads/master&api-version=5.1")
write-output $url

# It is possible at this point that the push has not completed yet. Logic below allows for 1 minute of waiting before timing out. 
$currentTry = 0
do {
    Start-Sleep -Seconds 2
    $response = Invoke-RestMethod -Uri $url -Headers @{Authorization = "Basic $token"} -Method Get
    write-output $response
    $currentTry++
} while ($currentTry -le 30 -and ($response.value.ObjectId -eq $null))

if ($response.value.ObjectId -eq $null) {
  throw "Pushing repository to DevOps timed out. Please try again later."
}

# Parse user input into the template variables file and the deployment parameter file and commit them to the devops repo
$url = $("https://dev.azure.com/" + $orgName + "/" + $projectName + "/_apis/git/repositories/" + $projectName + "/pushes?api-version=5.1")
write-output $url

$downloadUrl = $($fileUri + "/QS-WVD/variables.template.yml")
$content = (New-Object System.Net.WebClient).DownloadString($downloadUrl)

$content = $content.Replace("[location]", $location)
$content = $content.Replace("[adminUsername]", $adminUsername)
$content = $content.Replace("[domainName]", $domainName)
$content = $content.Replace("[keyVaultName]", $keyvaultName)
$content = $content.Replace("[hostpoolname]", $hostpoolname)
$content = $content.Replace("[vmInitialNumber]", $vmInitialNumber)
$content = $content.Replace("[hostpoolVMCount]", $hostpoolVMCount)
$content = $content.Replace("[useAvailabilityZone]", $useAvailabilityZone)
$content = $content.Replace("[customImageReferenceId]", $customImageReferenceId)
$content = $content.Replace("[wvdAssetsStorage]", $wvdAssetsStorage)
$content = $content.Replace("[resourceGroupName]", $ResourceGroupName)
$content = $content.Replace("[profilesStorageAccountName]", $profilesStorageAccountName)
$content = $content.Replace("[autoAccountName]", $AutomationAccountName)
$content = $content.Replace("[identityApproach]", $identityApproach)
$content = $content.Replace('"', '')
write-output $content

$downloadUrl = $($fileUri + "/QS-WVD/static/appliedParameters.template.psd1")
$parameters = (New-Object System.Net.WebClient).DownloadString($downloadUrl)

# $parameters = $parameters.Replace("[principalIds]", $location)
$parameters = $parameters.Replace("[existingSubnetName]", $existingSubnetName)
$parameters = $parameters.Replace("[virtualNetworkResourceGroupName]", $virtualNetworkResourceGroupName)
$parameters = $parameters.Replace("[existingVnetName]", $existingVnetName)
$parameters = $parameters.Replace("[existingDomainUsername]", $adminUsername)
$parameters = $parameters.Replace("[existingDomainName]", $domainName)
$parameters = $parameters.Replace("[DomainJoinAccountUPN]", $domainJoinUPN)
$parameters = $parameters.Replace("[objectId]", $ObjectId)
$parameters = $parameters.Replace("[tenantId]", $tenant)
$parameters = $parameters.Replace("[subscriptionId]", $subscriptionId)
$parameters = $parameters.Replace("[location]", $location)
$parameters = $parameters.Replace("[adminUsername]", $adminUsername)
$parameters = $parameters.Replace("[domainName]", $domainName)
$parameters = $parameters.Replace("[keyVaultName]", $keyvaultName)
$parameters = $parameters.Replace("[vmNamePrefix]", $vmNamePrefix)
$parameters = $parameters.Replace("[hostpoolname]", $hostpoolname)
$parameters = $parameters.Replace("[hostpoolVMSize]", $hostpoolVMSize)
$parameters = $parameters.Replace("[useAvailabilityZone]", $useAvailabilityZone)
$parameters = $parameters.Replace("[storageAccountSku]", $storageAccountSku)
$parameters = $parameters.Replace("[sigGalleryName]", $sigGalleryName)
$parameters = $parameters.Replace("[assetsName]", $wvdAssetsStorage)
$parameters = $parameters.Replace("[profilesName]", $profilesStorageAccountName)
$parameters = $parameters.Replace("[profilesShareQuota]", $profilesShareQuota)
$parameters = $parameters.Replace("[resourceGroupName]", $ResourceGroupName)
$parameters = $parameters.Replace("[principalIds]", $principalIds)
$parameters = $parameters.Replace("[targetGroup]", $targetGroup)
$parameters = $parameters.Replace("[identityApproach]", $identityApproach)
$parameters = $parameters.Replace('"', "'")
write-output $parameters

$body = @"
{
  "refUpdates": [
    {
      "name": "refs/heads/master",
      "oldObjectId": "$($response.value.objectId)"
    }
  ],
  "commits": [
    {
      "comment": "Initial commit.",
      "changes": [
        {
          "changeType": "add",
          "item": {
            "path": "QS-WVD/variables.yml"
          },
          "newContent": {
            "content": "$($content)",
            "contentType": "rawtext"
          }
        },
	{
	  "changeType": "add",
          "item": {
            "path": "QS-WVD/static/appliedParameters.psd1"
          },
          "newContent": {
            "content": "$($parameters)",
            "contentType": "rawtext"
          }
        }
      ]
    }
  ]
}
"@
write-output $body

$response = Invoke-RestMethod -Uri $url -Headers @{Authorization = "Basic $token"} -Method Post -Body $body -ContentType application/json
write-output $response

# Give service principal access to the keyvault
Set-AzKeyVaultAccessPolicy -VaultName $keyvaultName -ServicePrincipalName $principalId -PermissionsToSecrets Get,Set,List,Delete,Recover,Backup,Restore

# Give pipeline permission to access the newly created service connection
$url = $("https://dev.azure.com/" + $orgName + "/" + $projectName + "/_apis/pipelines/pipelinePermissions/endpoint/" + $endpointId + "?api-version=5.1-preview.1")
write-output $url

$body = @"
{
    "allPipelines": {
        "authorized": true,
        "authorizedBy": null,
        "authorizedOn": null
    },
    "pipelines": null,
    "resource": {
        "id": "$($endpointId)",
        "type": "endpoint"
    }
}
"@
write-output $body

$response = Invoke-RestMethod -Method PATCH -Uri $url -Headers @{Authorization = "Basic $token"} -Body $body -ContentType "application/json"
write-output $response

# Create variable group that holds the Azure Credentials as variables
$url = $("https://dev.azure.com/" + $orgName + "/" + $projectName + "/_apis/distributedtask/variablegroups?api-version=5.1-preview.1")
write-output $url

$SecurePassword = $AzCredentials.password

$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
$UnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

$DomainSecurePassword = $AzCredentials.password

$BSTR2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($DomainSecurePassword)
$DomainUnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR2)

$body = @"
{
  "variables": {
    "azureAdminUpn": {
      "value": "$($AzCredentials.username)"
    },
    "azureAdminPassword": {
      "value": "$($UnsecurePassword)",
      "isSecret": true
    },
    "domainJoinPassword": {
      "value": "$($DomainUnsecurePassword)",
      "isSecret": true
    }
  },
  "type": "Vsts",
  "name": "WVDSecrets",
  "description": "Azure credentials neede for DevOps pipeline"
}
"@
write-output "Request body for this request not printed to logs because it contains sensitive information."

$response = Invoke-RestMethod -Uri $url -Headers @{Authorization = "Basic $token"} -Method Post -Body $body -ContentType application/json
write-output $response
$variableGroupId = $response.id

# Give pipeline permission to access the newly created variable group
$url = $("https://dev.azure.com/" + $orgName + "/" + $projectName + "/_apis/pipelines/pipelinePermissions/variablegroup/" + $variableGroupId + "?api-version=5.1-preview.1")
write-output $url

$body = @"
{
    "allPipelines": {
        "authorized": true,
        "authorizedBy": null,
        "authorizedOn": null
    },
    "pipelines": null,
    "resource": {
        "id": "$($variableGroupId)",
        "type": "variablegroup"
    }
}
"@
write-output $body

$response = Invoke-RestMethod -Method PATCH -Uri $url -Headers @{Authorization = "Basic $token"} -Body $body -ContentType "application/json"
write-output $response

# Get Azure DevOps notification subscriber
$url = $("https://dev.azure.com/" + $orgName + "/_apis/notification/subscriptions?api-version=5.1")
write-output $url

$response = Invoke-RestMethod -Uri $url -Headers @{Authorization = "Basic $token"} -Method Get
write-output $response

$subId = ($response.value | where-Object { $_.description -eq "Build completes"}).subscriber.id

# Update subscriber's preferred email address to the specified notification email
$url = $("https://dev.azure.com/" + $orgName + "/_apis/notification/subscribers/" + $subId + "?api-version=5.1")
write-output $url

$body = @"
{
  "deliveryPreference": "preferredEmailAddress",
  "preferredEmailAddress": "$($notificationEmail)"
}
"@
write-output $body

$response = Invoke-RestMethod -Method PATCH -Uri $url -Headers @{Authorization = "Basic $token"} -Body $body -ContentType "application/json"
write-output $response
