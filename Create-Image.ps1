##
## Create-Image
##
## This script is for creating image file for cloning new virtual machine with configured virtual machine neither stopping nor removing
##
## Only support vm on managed disk
## Doesn't support data disk
## Only Support Windows OS
##

Param(
    [string] [Parameter(Mandatory=$true)] $resourceGroup,
    [string] [Parameter(Mandatory=$true)] $vmName,
    [string] [Parameter(Mandatory=$true)] $imageName
)

function CreateTempResourceGroup()
{
    Param(
        [string] [Parameter(Mandatory=$true)] $location
    )
    
    Write-Host ('Creating Temporary Resource Group...')
    
    $newResourceGroupName = (New-Guid).ToString()
  
    $newResourceGroup = New-AzureRmResourceGroup -Name $newResourceGroupName -Location $location
    $newResourceGroup.ResourceGroupName
}

function RemoveResourceGroup()
{
    Param(
        [string] [Parameter(Mandatory=$true)] $resourceGroup,
        [bool] $nowait = $true
    )

    $ctx = Get-AzureRmContext 

    $job = Start-Job -ScriptBlock {
        Param($ctx, $r) 
        Remove-AzureRmResourceGroup -AzureRmContext $ctx -Name $r -Force 
    } -ArgumentList $ctx, $resourceGroup

    if (-not $nowait) {
        Wait-Job $job
    }

    $job
}

function CreateSnapshotFromVM()
{
    Param(
        [string] [Parameter(Mandatory=$true)] $resourceGroup,
        [string] [Parameter(Mandatory=$true)] $VMName,
        [string] [Parameter(Mandatory=$true)] $tempResourceGroup
    )

    Write-Host 'Creating OS Disk Snapshot...'

    $VM = Get-AzureRmVM -ResourceGroupName $resourceGroup -Name $VMName
    $osDisk = Get-AzureRmDisk -ResourceGroupName $resourceGroup -DiskName $VM.StorageProfile.OsDisk.Name

    $snapshotConfig = New-AzureRmSnapshotConfig -SourceUri $osDisk.Id -CreateOption Copy -Location $VM.Location
    $snapshotName = 'OSDisk-snapshot'
    $snapShot = New-AzureRmSnapshot -Snapshot $snapshotConfig -SnapshotName $snapshotName -ResourceGroupName $tempResourceGroup 

    $snapShot
}

function CreateOSDiskFromSnapshot()
{
    Param(
        [Parameter(Mandatory=$true)] $snapshot
    )

    Write-Host 'Creating OS Disk...'
            
    $newOsDiskConfig = New-AzureRmDiskConfig -SourceResourceId $snapshot.Id -CreateOption Copy -Location $snapshot.Location
    # required better way to create unique name
    $osDiskName = "OSDisk"

    New-AzureRmDisk -Disk $newOsDiskConfig -ResourceGroupName $snapshot.ResourceGroupName -DiskName $osDiskName
}

# caution : this function could fall into infinite loop
function WaitForVMShutdown()
{
    Param(
        [Parameter(Mandatory=$true)] $VM
    )
        
    while ( ((get-azurermvm -ResourceGroupName $VM.ResourceGroupName -name $VM.Name -Status).Statuses | where { $_.Code -eq 'PowerState/stopped' }) -eq $null) { 
        Write-Host "Waiting for VM Shutdown..."
        Start-Sleep -Seconds 5
    }
}

function CreateVMWithOSDisk()
{
    Param(
        [Parameter(Mandatory=$true)] $osDisk,
        [Parameter(Mandatory=$true)] $srcVM,
        [bool] $isWindows = $true
    )

    Write-Host 'Creating Virtual Machine...'
    
    # create new virtual network
    $vnetName = 'vnet'
    $subnetConfig = New-AzureRmVirtualNetworkSubnetConfig -name subnet1 -AddressPrefix "192.168.0.0/24"
    
    #temp
    $pip = New-AzureRmPublicIpAddress -Name 'pip' -ResourceGroupName $osDisk.ResourceGroupName -Location $osDisk.Location -AllocationMethod Dynamic
    #temp

    $vnet = New-AzureRmVirtualNetwork -Name $vnetName -ResourceGroupName $osDisk.ResourceGroupName -Location $osDisk.Location -AddressPrefix "192.168.0.0/24" -Subnet $subnetConfig 

    # create new network card
    $nicName = 'nic'
    $nic = New-AzureRmNetworkInterface -Name $nicName -ResourceGroupName $osDisk.ResourceGroupName -Location $osDisk.Location -SubnetId $vnet.Subnets[0].id -PublicIpAddressId $pip.Id

    # create new virtual machine
    $VMName = $srcVM.Name
    $VMConfig = New-AzureRmVMConfig -VMName $VMName -VMSize $srcVM.HardwareProfile.VmSize 
    
    $VMConfig = Set-AzureRmVMOSDisk -VM $VMConfig -ManagedDiskId $osDisk.Id -CreateOption Attach -Windows
    $VMConfig = Set-AzureRmVMBootDiagnostics -VM $VMConfig -Disable
    $VMConfig = Add-AzureRmVMNetworkInterface -VM $VMConfig -NetworkInterface $nic 

    # craete virtual machine
    New-AzureRmVM -VM $VMConfig -ResourceGroupName $osDisk.ResourceGroupName -Location $osDisk.Location
}

## This step has somewhat problem when sysprep-ing on vm. it shows unplanned shut-down dialog box when VM created from this image, 
## Should find out the better way to do that

function GeneralizeVM()
{
    Param(
        [Parameter(Mandatory=$true)] $VM
    )
    
    Write-Host 'Generalizing Virtual Machine...'
    
    #New-Item script.ps1 -ItemType file -Value 'cmd.exe /C"c:\windows\system32\sysprep\sysprep.exe /generalize /oobe /quit /quiet && exit 0"' -Force
    New-Item -Name script.ps1 -ItemType file -Value 'Start-Process -FilePath "c:\windows\system32\sysprep\sysprep.exe" -ArgumentList "/oobe /generalize /quiet /shutdown"' -Force
    Invoke-AzureRmVMRunCommand -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name -CommandId RunPowerShellScript -ScriptPath "script.ps1" 
    Remove-Item "script.ps1"

    WaitForVMShutdown $VM

    Write-Host 'Deprovisioning Virtual Machine...'

    Stop-AzureRmVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -Force
    Set-AzureRMVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -Generalized
}

function CreateImage()
{
    Param(
        [Parameter(Mandatory=$true)] $imageName,
        [Parameter(Mandatory=$true)] $srcVM,
        [Parameter(Mandatory=$true)] $tempVM
    )

    Write-Host 'Creating Image...'

    $diskID = $tempVM.StorageProfile.OsDisk.ManagedDisk.Id

    $imageConfig = New-AzureRmImageConfig -Location $srcVM.Location
    $imageConfig = Set-AzureRmImageOsDisk -Image $imageConfig -OsState Generalized -OsType Windows -ManagedDiskId $diskID

    $image = New-AzureRmImage -ImageName $imageName -ResourceGroupName $srcVM.ResourceGroupName -Image $imageConfig

    $image
}

#
# Entry Point
#

# uncomment below line regarding execution environment
# Login-AzureRmAccount

#
# execution step
#
# 1. Create temporary resource group for avoiding complex clearup step
# 2. Create snapshot from source virtual machine
# 3. Create OS Disk form snapshot
# 4. Create VM using OS Disk created previously
# 5. Sysprep-ing using custom script extension
# 6. Turn off VM & Tag vm as generalized
# 7. Create Image with generialized vm
#

$srcVM = Get-AzureRmVM -ResourceGroupName $resourceGroup -Name $vmName

$tempResourceGroup = CreateTempResourceGroup -location $srcVM.Location
$snapShot = CreateSnapshotFromVM -resourceGroup $resourceGroup -VMName $vmName -tempResourceGroup $tempResourceGroup
$osDisk = CreateOSDiskFromSnapshot -snapshot $snapShot
CreateVMWithOSDisk -osDisk $osDisk -srcVM $srcVM -isWindows $true

$tempVM = Get-AzureRMVm -ResourceGroupName $tempResourceGroup -Name $vmName
GeneralizeVM -VM $tempVM
$image = CreateImage -imageName $imageName -srcVM $srcVM -tempVM $tempVM

# remove temporary resource group asynchronously
RemoveResourceGroup -resourceGroup $tempResourceGroup 
 
