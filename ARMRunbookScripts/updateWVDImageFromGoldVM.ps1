#Initializing variables from automation account
$SubscriptionId = Get-AutomationVariable -Name 'subscriptionid'
$ResourceGroupName = Get-AutomationVariable -Name 'ResourceGroupName'
$location = Get-AutomationVariable -Name 'location'
$adminUsername = Get-AutomationVariable -Name 'adminUsername'
$keyvaultName = Get-AutomationVariable -Name 'keyvaultName'
$sigGalleryName = Get-AutomationVariable -Name 'sigGalleryName'
$galleryImageDef = Get-AutomationVariable -Name 'galleryImageDef' -ErrorAction "SilentlyContinue"
$galleryImageVersion = Get-AutomationVariable -Name 'galleryImageVersion' -ErrorAction "SilentlyContinue"
$fileURI = Get-AutomationVariable -Name 'fileURI'

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

#Authenticate Azure
#Get the credential with the above name from the Automation Asset store
$AzCredentials = Get-AutomationPSCredential -Name $AzCredentialsAsset
$AzCredentials.password.MakeReadOnly()
Connect-AzAccount -Environment 'AzureCloud' -Credential $AzCredentials
Select-AzSubscription -SubscriptionId $SubscriptionId

# Get the context
$context = Get-AzContext
if ($context -eq $null)
{
	Write-Error "Please authenticate to Azure & Azure AD using Connect-AzAccount cmdlets and then run this script"
	exit
}

# Take disk snapshot of the wvd-gold-vm001 disk
$vmName = 'wvd-gold-vm001'
$vm = Get-AzVM -Name $vmName -ErrorAction Stop
$vmRG = $vm.ResourceGroupName
$vmLocation = $vm.Location
$osDiskName = $vm.StorageProfile.OsDisk.Name

# Snapshot name max length is 80 chars
If ($osDiskName.Length -gt 56) {
    $osDiskName = $osDiskName.SubString(0,56)
}
$snapshotName = $osDiskName + "_presysprep_" + (Get-Date -UFormat %Y%m%d%R | ForEach-Object { $_ -replace ":", "" })

# Shut down VM prior to snapshot but do not deallocate the VM
$vmStatus = (Get-AzVM -Name $vmName -Resourcegroup $vmRG -Status).Statuses[1].Code
If ($vmStatus -notmatch "stopped") {
    Write-Output "`nStopping VM $vmName to take disk snapshot..."
    Stop-AzVM -Name $vmName -Resourcegroup $vmRG -Force -StayProvisioned        
    while ($vmStatus -notmatch "stopped") {
        Write-Output "`nWaiting 30 seconds for VM to be stopped."
        Start-Sleep 30
        $vmStatus = (Get-AzVM -Name $vmName -Resourcegroup $vmRG -Status).Statuses[1].Code
    }
}

Write-Output "`nCreating new disk snapshot $snapshotName ..."
$snapshotConf =  New-AzSnapshotConfig -SourceUri $vm.StorageProfile.OsDisk.ManagedDisk.Id -Location $vmLocation -CreateOption copy
$diskSnapshot = New-AzSnapshot -Snapshot $snapshotConf -SnapshotName $snapshotName -ResourceGroupName $vmRG
If ($diskSnapshot.ProvisioningState -eq "Succeeded") {
    Write-Output "OS Disk Snapshot successfully created for VM $vmName"
}
Else {
    # Using "Throw" should stop the patch deployment if the snapshot fails
    Throw "OS Disk Snapshot creation FAILED for VM $vmName"
    Exit
}

# Start VM after disk snapshot created to run sysprep on VM
Write-Output "`nStarting VM $vmName to perform sysprep..."
Start-AzVM -Name $vmName -Resourcegroup $vmRG
while ($vmStatus -notmatch "running") {
    Write-Output "`nWaiting 60 seconds for VM to start."
    Start-Sleep 60
    $vmStatus = (Get-AzVM -Name $vmName -Resourcegroup $vmRG -Status).Statuses[1].Code
}

# Run sysprep on the Gold VM
$scriptURI = 'https://raw.githubusercontent.com/macquarie-cloud-services/azure-wvd-deployment/master/ARMRunbookScripts/sysprep.ps1'
Write-Output "`nRunning sysprep command on $vmName via Custom Script Extension, now waiting until the vm is stopped."
Set-AzVMCustomScriptExtension `
    -FileUri $ScriptURI `
    -ResourceGroupName $vmRG `
    -VMName $vmName `
    -Name "runSysprep" `
    -Location $vmLocation `
    -run './sysprep.ps1' `
    -Argument '-runSysprep'
$vm | Update-AzVM

$vmStatus = (Get-AzVM -Name $vmName -Resourcegroup $vmRG -Status).Statuses[1].Code
while ($vmStatus -notmatch "stopped") {
    Write-Output "`nWaiting 60 seconds for VM to be stopped."
    Start-Sleep 60
    $vmStatus = (Get-AzVM -Name $vmName -Resourcegroup $vmRG -Status).Statuses[1].Code
}

# Create Managed Image from Gold VM
$imageName = $osDiskName + "_syspreped_" + (Get-Date -UFormat %Y%m%d%R | ForEach-Object { $_ -replace ":", "" })
$image = New-AzImageConfig -Location $vmLocation -SourceVirtualMachineId $vm.Id 
Write-Output "nCreating image $imageName based on $vmName"
New-AzImage -Image $image -ImageName $imageName -Resourcegroupname $vmRG
$managedImage = Get-AzImage -ImageName $imageName -Resourcegroupname $vmRG

# Copy managed image to Shared Image Gallery
$galleryVer = $galleryImageVersion.Split('.')
If ($galleryVer[0] -ne "1") {
    # If SIG version < 1.0.0 then this is still the original base image
    # Set version to 1.0.0
    $galleryImageVersion = "1.0.0"
}

If ($galleryVer[0] -eq "1") {
    # If SIG version is 1.0.x then it has been customised with customer apps
    # Increment minor version between releases
    $galleryImageVersion = $galleryVer[0] + "." + $galleryVer[1] + "." + ([int]$galleryVer[2]+1)
}

Write-Output "Capturing VM $vmName to $sigGalleryName ..."
$region = @{Name=$location;ReplicaCount=1}
$imgExpiry = Get-Date -date $(Get-Date).AddDays(365) -UFormat %Y-%m-%d
$imageDefinition = Get-AzGalleryImageDefinition -ResourceGroupName $ResourceGroupName -GalleryName $sigGalleryName -Name $galleryImageDef
$job = $imageVersion = New-AzGalleryImageVersion `
   -GalleryImageDefinitionName $imageDefinition.Name `
   -GalleryImageVersionName $galleryImageVersion `
   -GalleryName $sigGalleryName `
   -ResourceGroupName $ResourceGroupName `
   -Location $location `
   -TargetRegion $region  `
   -SourceImageId $managedImage.Id.ToString() `
   -PublishingProfileEndOfLifeDate $imgExpiry `  
   -asJob

While ($job.State -eq "running") {
    Write-Output $($job.State)
    Start-Sleep 300
}

If ($job.State -eq "Completed") {
    Write-Output "`nImage copy to $sigGalleryName completed successfully. Writing image version back to Automation Account variable."
    Set-AutomationVariable -Name 'galleryImageVersion' -Value $galleryImageVersion
}

Write-Output "`n--- Script Completed ---"
