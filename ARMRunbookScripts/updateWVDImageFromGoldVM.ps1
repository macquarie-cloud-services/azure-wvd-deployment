### Author: Raymond Phoon
### Description: Script to upload Gold VM as new Shared Gallery Image to update WVD Host Pool
### Steps:
###     1. Shut down Gold VM.
###     2. Take snapshot of VM.
###     3. Power On VM and run sysprep.
###     4. Set VM status as Generalized and capture image from VM.
###     5. Copy managed image to Shared Image Gallery incrementing image version
###     6. Delete and recreate Gold VM from disk snapshot.

param(
    [Parameter(Mandatory = $true)]
    [string] $vmName
)

# Initializing variables from automation account
$SubscriptionId = Get-AutomationVariable -Name 'subscriptionid'
$ResourceGroupName = Get-AutomationVariable -Name 'ResourceGroupName'
$location = Get-AutomationVariable -Name 'location'
$sigGalleryName = Get-AutomationVariable -Name 'sigGalleryName'
$galleryImageDef = Get-AutomationVariable -Name 'galleryImageDef' -ErrorAction "SilentlyContinue"
$galleryImageVersion = Get-AutomationVariable -Name 'galleryImageVersion' -ErrorAction "SilentlyContinue"
$fileURI = Get-AutomationVariable -Name 'fileURI'

# Download files required for this script from github ARMRunbookScripts/static folder
$FileName = "AzureModules.zip"
Invoke-WebRequest -Uri "$fileURI/ARMRunbookScripts/static/$Filename" -OutFile "C:\$Filename"
Expand-Archive "C:\AzureModules.zip" -DestinationPath 'C:\Modules\Global' -ErrorAction SilentlyContinue

# Install required Az modules and AzureAD
Import-Module Az.Accounts -Global
Import-Module Az.Resources -Global
Import-Module Az.Automation -Global
Import-Module Az.Compute -Global

Set-ExecutionPolicy -ExecutionPolicy Undefined -Scope Process -Force -Confirm:$false
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine -Force -Confirm:$false
Get-ExecutionPolicy -List

#The name of the Automation Credential Asset this runbook will use to authenticate to Azure.
$AzCredentialsAsset = 'AzureCredentials'

#Authenticate Azure
#Get the credential with the above name from the Automation Asset store
$AzCredentials = Get-AutomationPSCredential -Name $AzCredentialsAsset
$AzCredentials.password.MakeReadOnly()
Connect-AzAccount -Environment 'AzureCloud' -Credential $AzCredentials -ErrorAction Stop
Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop

# Take disk snapshot
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

# Sysprep only stops the VM. Deallocate VM to continue.
Write-Output "`nVM stopped. Deallocating VM."
Stop-AzVM -Name $vmName -Resourcegroup $vmRG -Force
$vmStatus = (Get-AzVM -Name $vmName -Resourcegroup $vmRG -Status).Statuses[1].Code
while ($vmStatus -notmatch "deallocated") {
    Write-Output "`nWaiting 30 seconds for VM to be deallocated."
    Start-Sleep 30
    $vmStatus = (Get-AzVM -Name $vmName -Resourcegroup $vmRG -Status).Statuses[1].Code
}

# Set status of VM to Generalized
Write-Output "`nVM deallocated. Now setting VM status to Generalized for image capture."
Set-AzVm -ResourceGroupName $vmRG -Name $vmName -Generalized

# Create Managed Image from Gold VM
$imageName = $osDiskName + "_syspreped_" + (Get-Date -UFormat %Y%m%d%R | ForEach-Object { $_ -replace ":", "" })
$image = New-AzImageConfig -Location $vmLocation -SourceVirtualMachineId $vm.Id 
Write-Output "`nCreating image $imageName based on $vmName"
New-AzImage -Image $image -ImageName $imageName -Resourcegroupname $vmRG
$managedImage = Get-AzImage -ImageName $imageName -Resourcegroupname $vmRG
Write-Output $managedImage

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

$regionName = (Get-AzLocation | where {$_.Location -eq $location} | Select DisplayName).DisplayName
Write-Output "`nConverting region name to display name..."
$region1 = @{Name=$regionName;ReplicaCount=1}
$targetRegions = @($region1)

$imgExpiry = Get-Date -date $(Get-Date).AddDays(365) -UFormat %Y-%m-%d
Write-Output "`nCopying image to $sigGalleryName/$galleryImageDef as version $galleryImageVersion ..."
$job = $imageVersion = New-AzGalleryImageVersion `
   -GalleryImageDefinitionName $galleryImageDef `
   -GalleryImageVersionName $galleryImageVersion `
   -GalleryName $sigGalleryName `
   -ResourceGroupName $ResourceGroupName `
   -Location $vmLocation `
   -TargetRegion $targetRegions `
   -SourceImageId $managedImage.Id.ToString() `
   -PublishingProfileEndOfLifeDate $imgExpiry.ToString() `
   -AsJob

Write-Output $job | fl

While ($job.State -eq "running") {
    Write-Output "`nJob still running. Checking status every 5 minutes..."
    Start-Sleep 300
}

If ($job.State -eq "failed") {
    Write-Error "`nCopy of managed image to $sigGalleryName failed."
    Write-Error $job | fl
}

If ($job.State -eq "Completed") {
    Write-Output "`nImage copy to $sigGalleryName completed successfully. Writing image version back to Automation Account variable."
    Set-AutomationVariable -Name 'galleryImageVersion' -Value $galleryImageVersion
}

### Recreate gold VM from snapshot

Write-Output "`nThe Generalized Gold VM can no longer be used. Recreating VM from snapshot taken..."

Write-Output "...Removing Generalized VM and syspreped OS disk..."
Remove-AzVM -ResourceGroupName $vmRG -Name $vmName -Force
Remove-AzDisk -ResourceGroupName $vmRG -DiskName $osDiskName -Force

# Take a record of all tags on the VM
If ($vm.tags) {
    $vmTags = $vm.tags
}
$diskConfig = New-AzDiskConfig -Location $vmLocation -SourceResourceId $diskSnapshot.Id -CreateOption Copy -SkuName "Premium_LRS" -ErrorAction Stop
Write-Output "`nCreating new disk from snapshot..."
$OSdisk = New-AzDisk -Disk $diskConfig -ResourceGroupName $vmRG -DiskName $osDiskName -ErrorAction Stop

Write-Output "Creating new VM config and attaching new disk..."
$newVMConf = New-AzVMConfig -VMName $vmName -VMSize $vm.HardwareProfile.VmSize -ErrorAction Stop
Set-AzVMOSDisk -VM $newVMConf -CreateOption Attach -ManagedDiskId $OSdisk.Id -Name $OSdisk.Name -Windows -ErrorAction Stop

Foreach ($nic in $vm.NetworkProfile.NetworkInterfaces) {	
	If ($nic.Primary -eq "True") {
        Write-Output "Attaching original NIC $($nic.Id) to new VM..."
    	Add-AzVMNetworkInterface -VM $newVMConf -Id $nic.Id -Primary -ErrorAction Stop
    }
    Else {
        Write-Output "Attaching original NIC $($nic.Id) to new VM..."
       	Add-AzVMNetworkInterface -VM $newVMConf -Id $nic.Id -ErrorAction Stop
    }
}

Write-Output "Creating new VM from config..."
$newVM = New-AzVM -ResourceGroupName $vmRG -Location $vmLocation -VM $newVMConf -DisableBginfoExtension -ErrorAction Stop
If ($vmTags) {
    Write-Output "Setting the same tags as that of the original VM..."
    Set-AzResource -ResourceId $newVM.Id -Tag $vmTags -Force
}

Write-Output "`nPlease check that new VM is working as expected and shut down the VM to save on costs."

Write-Output "`n--- Script Completed ---"
