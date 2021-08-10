<### Powereshell script to clone vm from snapshot
##https://docs.microsoft.com/en-us/previous-versions/azure/virtual-machines/scripts/virtual-machines-windows-powershell-sample-create-vm-from-snapshot?toc=%2Fpowershell%2Fmodule%2Ftoc.json
## Adding Disk
## https://docs.microsoft.com/en-us/azure/virtual-machines/windows/attach-disk-ps
#>

## MIKECARS TESTING

$subscriptionId = '8f7d862b-5995-401f-a514-7f9f1f9ebae5'
$tenantId = 'a2760153-5887-4d08-9fa2-78013c75bd2c'
$rgname = 'fd-azm-rg1'
$azmproject = 'fd-azm-prj1'

# $SubscriptionId = '47ac6194-b9f2-45ef-a331-ccb12315355e'
# $tenantId = "c6b8c105-9da4-4b49-bf78-1702e449c632"
Login-AzAccount -Tenant $tenantId

#Existing virtual network where new virtual machine will be created
$virtualNetworkName = 'fd-azm-rg1-vnet'

#Resource group of the VM to be clonned from 
$resourceGroupName = 'fd-azm-rg1'
$nwResourceGroupName = 'fd-azm-rg1'

$destination_resourceGroupName = 'fd-azm-rg1'
#Region where managed disk will be created
$location = 'eastus'


#Names of source and target (new) VMs
$sourceVirtualMachineName = 'fd-rhat1'
#$targetVirtualMachineName = 'evl9700521'
$targetVirtualMachineName = 'fd-rhat2'

#Name of snapshot which will be created from the Managed Disk
$snapshotName = $sourceVirtualMachineName + '_OsDisk-snapshot'

#Name of the new Managed Disk
$osDiskName = $targetVirtualMachineName + '_OsDisk'

#Size of new Managed Disk in GB
$diskSize = 40

#Storage type for the new Managed Disk (Standard_LRS / Premium_LRS / StandardSSD_LRS)
$storageType = 'Premium_LRS'

#Size of the Virtual Machine (https://docs.microsoft.com/en-us/azure/virtual-machines/windows/sizes)
#Leave empty if same size as source vm
#$targetVirtualMachineSize = 'Standard_B2s'
$targetVirtualMachineSize = ''


#Set the context to the subscription Id where Managed Disk will be created
#Select-AzSubscription -SubscriptionId $SubscriptionId

$vm = Get-AzVM -ResourceGroupName $resourceGroupName -Name $sourceVirtualMachineName

if ($targetVirtualMachineSize -eq "") {
    $targetVirtualMachineSize = $vm.HardwareProfile.VmSize
}

# Get Existin Snapshot
#$snapshot = Get-AzSnapshot -ResourceGroupName $resourceGroupName -SnapshotName $snapshotName

$snapshotConfig = New-AzSnapshotConfig `
    -SourceUri $vm.StorageProfile.OsDisk.ManagedDisk.Id `
    -Location $location `
    -CreateOption copy

$snapshot = New-AzSnapshot `
    -Snapshot $snapshotConfig `
    -SnapshotName $snapshotName `
    -ResourceGroupName $resourceGroupName

#Disk Config and change Disk Size
#$diskConfig = New-AzDiskConfig -Location $snapshot.Location -DiskSizeGB $diskSize -SourceResourceId $snapshot.Id -CreateOption Copy
$diskConfig = New-AzDiskConfig -Location $snapshot.Location -SourceResourceId $snapshot.Id -CreateOption Copy -AccountType $storageType
#$disk = New-AzDisk -Disk $diskConfig -ResourceGroupName $resourceGroupName -DiskName $osDiskName 

## Send to Target RG
$disk = New-AzDisk -Disk $diskConfig -ResourceGroupName $destination_resourceGroupName  -DiskName $osDiskName 




#Initialize virtual machine configuration
$VirtualMachine = New-AzVMConfig -VMName $targetVirtualMachineName -VMSize $targetVirtualMachineSize 


#Use the Managed Disk Resource Id to attach it to the virtual machine. Please change the OS type to linux if OS disk has linux OS

if ($vm.OSProfile.WindowsConfiguration -eq $null) {
    $VirtualMachine = Set-AzVMOSDisk -VM $VirtualMachine -ManagedDiskId $disk.Id -CreateOption Attach -Linux
}
else {
    $VirtualMachine = Set-AzVMOSDisk -VM $VirtualMachine -ManagedDiskId $disk.Id -CreateOption Attach -Windows
}

$DataDiskList=@()
if ($vm.StorageProfile.DataDisks.count -gt 0){
    #$snapshotName = $sourceVirtualMachineName
    
    foreach ($datadisk in $vm.StorageProfile.DataDisks){
        $diskHashTable = @{}
        $lunid = $datadisk.Lun
        $diskHashTable."Lun" = $datadisk.Lun
        $diskHashTable."SnapshotName" = $datadisk.Name + "-snapshot"
        $diskHashTable."DataDiskName" = $targetVirtualMachineName + "_Disk" + $lunid
        $diskHashTable."Caching" = $datadisk.Caching

        $Disk = Get-AzDisk -ResourceGroupName $resourceGroupName -DiskName $DataDisk.Name
        #Create snapshot of data disk
        $DataDiskSnapshotConfig = New-AzSnapshotConfig `
            -SourceUri $Disk.Id `
            -Location $location `
            -CreateOption copy
        $DataDisksnapshotName = $diskHashTable."SnapshotName"
        $snapshot = New-AzSnapshot `
            -Snapshot $DataDiskSnapshotConfig `
            -SnapshotName $DataDisksnapshotName `
            -ResourceGroupName $resourceGroupName

        #Creates new datadisk from snapshot
        $DataDiskConfig = New-AzDiskConfig -Location $snapshot.Location -SourceResourceId $snapshot.Id -CreateOption Copy
        $DataDisk = New-AzDisk -Disk $DataDiskConfig -ResourceGroupName $resourceGroupName -DiskName $($diskHashTable."DataDiskName")
       
        $diskHashTable."DataDiskId" = $DataDisk.Id

        $DataDiskList += New-Object -TypeName PSObject -Property $diskHashTable
    }

}



#Add Data Disk if Any
if ($DataDiskList.count -gt 0){
    foreach ($datadisk in $DataDiskList){
      #$disk = Add-AzVMDataDisk -CreateOption Attach -Lun $datadisk.Lun   
      $VirtualMachine = Add-AzVMDataDisk -VM $VirtualMachine `
            -Name $($datadisk.DataDiskName) `
            -Lun $($datadisk.Lun) `
            -ManagedDiskId $($datadisk.DataDiskId) `
            -CreateOption Attach
    }
}

#Get the virtual network where virtual machine will be hosted
$vnet = Get-AzVirtualNetwork -Name $virtualNetworkName -ResourceGroupName $nwResourceGroupName

#Create a public IP for the VM
$publicIp = New-AzPublicIpAddress -Name ($targetVirtualMachineName.ToLower() + '_ip') -ResourceGroupName $resourceGroupName -Location $snapshot.Location -AllocationMethod Dynamic


# Create NIC in the first subnet of the virtual network
$nic = New-AzNetworkInterface -Name ($targetVirtualMachineName.ToLower() + '_nic1') `
            -ResourceGroupName $destination_resourceGroupName -Location $snapshot.Location `
            -SubnetId $vnet.Subnets[0].Id  -PublicIpAddressId $publicIp.Id `
            -Force

# Get Existing Virtual NIC
#$nicName = "evl9700521-i1"
#$nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $nwResourceGroupName


$VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine -Id $nic.Id

#Create the virtual machine with Managed Disk
New-AzVM -VM $VirtualMachine -ResourceGroupName $destination_resourceGroupName -Location $snapshot.Location


<#
Get-AzVM -ResourceGroupName $resourceGroupName -Name $targetVirtualMachineName | Remove-AzVm -Force
$nic | Remove-AzNetworkInterface -Force


#Remove the snapshot
Remove-AzSnapshot -ResourceGroupName $resourceGroupName -SnapshotName $snapshotName -Force

    
#Cleanup Manage Disk Snapshots
foreach ($itm in $DataDiskList){
    Remove-AzSnapshot -ResourceGroupName $resourceGroupName -SnapshotName $($itm.SnapshotName) -Force
}
    

#>

Disconnect-AzAccount
Logout-AzAccount