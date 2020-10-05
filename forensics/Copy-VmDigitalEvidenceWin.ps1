<#
.SYNOPSIS
    Performs a digitial evidence capture operation on a target VM 

.DESCRIPTION
    This is designed to be run from a Windows Hybrid Runbook Worker in response to a
    digitial evidence capture request for a target VM.  It will create disk snapshots
    for all disks, copying them to immutable SOC storage, and take a SHA-256 hash and
    storing the results in your SOC Key Vault.

    This script depends on Az.Accounts, Az.Compute, Az.Storage, and Az.KeyVault being 
    imported in your Azure Automation account.
    See: https://docs.microsoft.com/en-us/azure/automation/az-modules

.EXAMPLE
    Copy-VmDigitialEvidence -SubscriptionId ffeeddcc-bbaa-9988-7766-554433221100 -ResourceGroupName rg-finance-vms -VirtualMachineName vm-workstation-001

.LINK
    https://docs.microsoft.com/azure/architecture/example-scenario/forensics/
#>

param (
    # The ID of subscription in which the target Virtual Machine is stored
    [Parameter(Mandatory = $true)]
    [string]
    $SubscriptionId,

    # The Resource Group containing the Virtual Machine
    [Parameter(Mandatory = $true)]
    [string]
    $ResourceGroupName,

    # The name of the target Virtual Machine
    [Parameter(Mandatory = $true)]
    [string]
    $VirtualMachineName
)

$ErrorActionPreference = 'Stop'

######################################### SOC Constants #####################################
# SOC Team Evidence Resources
$destSubId = '00112233-4455-6677-8899-aabbccddeeff'   # The subscription containing the storage account being copied to
$destRGName = 'PLACEHOLDER'                           # The Resource Group containing the storage account being copied to
$destSAblob = 'PLACEHOLDER'                           # The name of the storage account for BLOB
$destSAfile = 'PLACEHOLDER'                           # The name of the storage account for FILE
$destTempShare = 'PLACEHOLDER'                        # The temporary file share mounted on the hybrid worker
$destSAContainer = 'PLACEHOLDER'                      # The name of the container within the storage account
$destKV = 'PLACEHOLDER'                               # The name of the keyvault to store a copy of the BEK in the dest subscription

$targetWindowsDir = "Z:\$destTempShare"               # The mapping path to the share that will contain the disk and its hash
$snapshotPrefix = (Get-Date).toString('yyyyMMddHHmm') # The prefix of the snapshot to be created

#############################################################################################
################################## Hybrid Worker Check ######################################
Write-Output "#################################"
Write-Output "Snapshot the OS Disk of target VM"
Write-Output "#################################"
$bios= Get-WmiObject -class Win32_BIOS
if ($bios) {   
    Write-Output "Running on Hybrid Worker"

    ################################## Mounting fileshare #######################################
    # The Storage account also hosts an Azure file share to use as a temporary repository for calculating the snapshot's SHA-256 hash value.
    # The following doc shows a possible way to mount the Azure file share on Z:\ :
    # https://docs.microsoft.com/en-us/azure/storage/files/storage-how-to-use-files-windows


    ################################## Login session ############################################
    # Connect to Azure (via Managed Identity or Azure Automation's RunAs Account)
    #
    # Feel free to adjust the following lines to invoke Connect-AzAccount via
    # whatever mechanism your Hybrid Runbook Workers are configured to use.
    #
    # Whatever service principal is used, it must have the following permissions
    #  - "Contributor" on the Resource Group of target Virtual Machine. This provide snapshot rights on Virtual Machine disks
    #  - "Storage Account Contributor" on the immutable SOC Storage Account
    #  - Access policy to Get Secret (for BEK key) and Get Key (for KEK key, if present) on the Key Vault used by target Virtual Machine
    #  - Access policy to Set Secret (for BEK key) and Create Key (for KEK key, if present) on the SOC Key Vault

    Add-AzAccount -Identity

    ############################# Snapshot the OS disk of target VM ##############################
    Write-Output "#################################"
    Write-Output "Snapshot the OS Disk of target VM"
    Write-Output "#################################"

    Get-AzSubscription -SubscriptionId $SubscriptionId | Set-AzContext
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VirtualMachineName

    $disk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $vm.StorageProfile.OsDisk.Name
    $snapshot = New-AzSnapshotConfig -SourceUri $disk.Id -CreateOption Copy -Location $vm.Location
    $snapshotName = $snapshotPrefix + "-" + $disk.name
    New-AzSnapshot -ResourceGroupName $ResourceGroupName -Snapshot $snapshot -SnapshotName $snapshotname


    ##################### Copy the OS snapshot from source to file share and blob container ########################
    Write-Output "#################################"
    Write-Output "Copy the OS snapshot from source to file share and blob container"
    Write-Output "#################################"

    $snapSasUrl = Grant-AzSnapshotAccess -ResourceGroupName $ResourceGroupName -SnapshotName $snapshotName -DurationInSecond 72000 -Access Read
    Get-AzSubscription -SubscriptionId $destSubId | Set-AzContext
    $targetStorageContextBlob = (Get-AzStorageAccount -ResourceGroupName $destRGName -Name $destSAblob).Context
    $targetStorageContextFile = (Get-AzStorageAccount -ResourceGroupName $destRGName -Name $destSAfile).Context

    Write-Output "Start Copying Blob $SnapshotName"
    Start-AzStorageBlobCopy -AbsoluteUri $snapSasUrl.AccessSAS -DestContainer $destSAContainer -DestContext $targetStorageContextBlob -DestBlob "$SnapshotName.vhd" -Force

    Write-Output "Start Copying Fileshare"
    Start-AzStorageFileCopy -AbsoluteUri $snapSasUrl.AccessSAS -DestShareName $destTempShare -DestContext $targetStorageContextFile -DestFilePath $SnapshotName -Force

    Write-Output "Waiting Fileshare Copy End"
    Get-AzStorageFileCopyState -Context $targetStorageContextFile -ShareName $destTempShare -FilePath $SnapshotName -WaitForComplete

    #Windows hash version if you use a Windows Hybrid Runbook Worker
    $diskpath = "$targetWindowsDir\$snapshotName"    
    Write-Output "Start Calculating HASH for $diskpath"
    Get-ChildItem "$diskpath" | Select-Object -Expand FullName | ForEach-Object{Write-Output $_}
    $hash = (Get-FileHash $diskpath -Algorithm SHA256).Hash
    Write-Output "Computed SHA-256: $hash"

    #################### Copy the OS BEK to the SOC Key Vault  ###################################
    $BEKurl = $disk.EncryptionSettingsCollection.EncryptionSettings.DiskEncryptionKey.SecretUrl
    Write-Output "#################################"
    Write-Output "OS Disk Encryption Secret URL: $BEKurl"
    Write-Output "#################################"
    if ($BEKurl) {
        $sourcekv = $BEKurl.Split("/")
        $BEK = Get-AzKeyVaultSecret -VaultName  $sourcekv[2].split(".")[0] -Name $sourcekv[4] -Version $sourcekv[5]
        Write-Output "Key value: $BEK"
        $BEK.Tags.Hash = $hash
        Get-AzSubscription -SubscriptionId $destSubId | Set-AzContext
        $secretName = $snapshotName.Replace("_","-")
        Set-AzKeyVaultSecret -VaultName $destKV -Name $secretName -SecretValue $BEK.SecretValue -ContentType "BEK" -Tag $BEK.Tags
    }


    ######## Copy the OS disk hash value in key vault and delete disk in file share ##################
    Write-Output "#################################"
    Write-Output "OS disk - Put hash value in Key Vault"
    Write-Output "#################################"
    $secret = ConvertTo-SecureString -String $hash -AsPlainText -Force
    Set-AzKeyVaultSecret -VaultName $destKV -Name "$SnapshotName-sha256" -SecretValue $secret -ContentType "HASH"
    Get-AzSubscription -SubscriptionId $destSubId | Set-AzContext
    $targetStorageContextFile = (Get-AzStorageAccount -ResourceGroupName $destRGShare -Name $destSAfile).Context
    Remove-AzStorageFile -ShareName $destTempShare -Path $SnapshotName -Context $targetStorageContextFile


    ############################ Snapshot the data disks, store hash and BEK #####################
    $dsnapshotList = @()

    foreach ($dataDisk in $vm.StorageProfile.DataDisks) {
        $ddisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $dataDisk.Name
        $dsnapshot = New-AzSnapshotConfig -SourceUri $ddisk.Id -CreateOption Copy -Location $vm.Location
        $dsnapshotName = $snapshotPrefix + "-" + $ddisk.name
        $dsnapshotList += $dsnapshotName
        Write-Output "Snapshot data disk name: $dsnapshotName"
        New-AzSnapshot -ResourceGroupName $ResourceGroupName -Snapshot $dsnapshot -SnapshotName $dsnapshotName
        
        Write-Output "#################################"
        Write-Output "Copy the Data Disk $dsnapshotName snapshot from source to blob container"
        Write-Output "#################################"

        $dsnapSasUrl = Grant-AzSnapshotAccess -ResourceGroupName $ResourceGroupName -SnapshotName $dsnapshotName -DurationInSecond 72000 -Access Read
        $targetStorageContextBlob = (Get-AzStorageAccount -ResourceGroupName $destRGName -Name $destSABlob).Context
        $targetStorageContextFile = (Get-AzStorageAccount -ResourceGroupName $destRGName -Name $destSAFile).Context

        Write-Output "Start Copying Blob $dsnapshotName"
        Start-AzStorageBlobCopy -AbsoluteUri $dsnapSasUrl.AccessSAS -DestContainer $destSAContainer -DestContext $targetStorageContextBlob -DestBlob "$dsnapshotName.vhd" -Force

        Write-Output "Start Copying Fileshare"
        Start-AzStorageFileCopy -AbsoluteUri $dsnapSasUrl.AccessSAS -DestShareName $destTempShare -DestContext $targetStorageContextFile -DestFilePath $dsnapshotName  -Force
        
        Write-Output "Waiting Fileshare Copy End"
        Get-AzStorageFileCopyState -Context $targetStorageContextFile -ShareName $destTempShare -FilePath $dsnapshotName -WaitForComplete
                
        $ddiskpath = "$targetWindowsDir\$dsnapshotName"
        Write-Output "Start Calculating HASH for $ddiskpath"
        Get-ChildItem "$ddiskpath" | Select-Object -Expand FullName | ForEach-Object{Write-Output $_}
        $hash = (Get-FileHash $diskpath -Algorithm SHA256).Hash
        Write-Output "Computed SHA-256: $dhash"

        
        
        $BEKurl = $ddisk.EncryptionSettingsCollection.EncryptionSettings.DiskEncryptionKey.SecretUrl
        Write-Output "#################################"
        Write-Output "Disk Encryption Secret URL: $BEKurl"
        Write-Output "#################################"
        if ($BEKurl) {
            $sourcekv = $BEKurl.Split("/")
            $BEK = Get-AzKeyVaultSecret -VaultName  $sourcekv[2].split(".")[0] -Name $sourcekv[4] -Version $sourcekv[5]
            Write-Output "Key value: $BEK"
            Write-Output "Secret name: $dsnapshotName"
            $BEK.Tags.Hash = $dhash
            $secretName = $dsnapshotName.Replace("_","-")
            Set-AzKeyVaultSecret -VaultName $destKV -Name $secretName -SecretValue $BEK.SecretValue -ContentType "BEK" -Tag $BEK.Tags
        }
        else {
            Write-Output "Disk not encrypted"
        }

        Write-Output "#################################"
        Write-Output "Data disk - Put hash value in Key Vault"
        Write-Output "#################################"
        $Secret = ConvertTo-SecureString -String $dhash -AsPlainText -Force
        Set-AzKeyVaultSecret -VaultName $destKV -Name "$dsnapshotName-sha256" -SecretValue $Secret -ContentType "HASH"
        Get-AzSubscription -SubscriptionId $destSubId | Set-AzContext
        $targetStorageContextFile = (Get-AzStorageAccount -ResourceGroupName $destRGShare -Name $destSAfile).Context
        Remove-AzStorageFile -ShareName $destTempShare -Path $dsnapshotName -Context $targetStorageContextFile
    }


    ################################## Delete all source snapshots ###############################
    Get-AzStorageBlobCopyState -Blob "$snapshotName.vhd" -Container $destSAContainer -Context $targetStorageContextBlob -WaitForComplete
    foreach ($dsnapshotName in $dsnapshotList) {
        Get-AzStorageBlobCopyState -Blob "$dsnapshotName.vhd" -Container $destSAContainer -Context $targetStorageContextBlob -WaitForComplete
    }

    Revoke-AzSnapshotAccess -ResourceGroupName $ResourceGroupName -SnapshotName $snapshotName
    Remove-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $snapshotname -Force
    foreach ($dsnapshotName in $dsnapshotList) {
        Revoke-AzSnapshotAccess -ResourceGroupName $ResourceGroupName -SnapshotName $dsnapshotName
        Remove-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $dsnapshotname -Force
    }
}
else {
    Write-Information "This runbook must Run on an Hybrid Worker. Please retry selecting the HybridWorker"
}
