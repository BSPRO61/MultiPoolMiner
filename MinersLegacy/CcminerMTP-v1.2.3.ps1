﻿using module ..\Include.psm1

param(
    [PSCustomObject]$Pools,
    [PSCustomObject]$Stats,
    [PSCustomObject]$Config,
    [PSCustomObject[]]$Devices
)

$Name = "$(Get-Item $MyInvocation.MyCommand.Path | Select-Object -ExpandProperty BaseName)"
$Path = ".\Bin\$($Name)\ccminer.exe"
$HashSHA256 = "2FDD055D339154FA7C49FD7AC66EA7C0FFD50033DBECCFCB665C5404B79C4BD1"
$Uri = "https://github.com/zcoinofficial/ccminer/releases/download/1.2.3/ccminer.exe"
$ManualUri = "https://github.com/zcoinofficial/ccminer/releases"

$Miner_BaseName = $Name -split '-' | Select-Object -Index 0
$Miner_Version = $Name -split '-' | Select-Object -Index 1
$Miner_Config = $Config.MinersLegacy.$Miner_BaseName.$Miner_Version
if (-not $Miner_Config) { $Miner_Config = $Config.MinersLegacy.$Miner_BaseName."*" }

$Devices = @($Devices | Where-Object Type -EQ "GPU" | Where-Object Vendor -EQ "NVIDIA Corporation")

# Miner requires CUDA 10.1.00
$CUDAVersion = ($Devices.OpenCL.Platform.Version | Select-Object -Unique) -replace ".*CUDA ",""
$RequiredCUDAVersion = "10.1.00"
if ($CUDAVersion -and [System.Version]$CUDAVersion -lt [System.Version]$RequiredCUDAVersion) { 
    Write-Log -Level Warn "Miner ($($Name)) requires CUDA version $($RequiredCUDAVersion) or above (installed version is $($CUDAVersion)). Please update your Nvidia drivers. "
    return
}

$Commands = [PSCustomObject]@{ 
    "Mtp" = " -a mtp -i 21 -R 1"
}
#Commands from config file take precedence
if ($Miner_Config.Commands) { $Miner_Config.Commands | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | ForEach-Object { $Commands | Add-Member $_ $($Miner_Config.Commands.$_) -Force } }

#CommonCommands from config file take precedence
if ($Miner_Config.CommonCommands) { $CommonCommands = $Miner_Config.CommonCommands }
else { $CommonCommands = "" }

$Devices | Select-Object Model -Unique | ForEach-Object { 
    $Miner_Device = @($Devices | Where-Object Model -EQ $_.Model)
    $Miner_Port = $Config.APIPort + ($Miner_Device | Select-Object -First 1 -ExpandProperty Index) + 1

    $Commands | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | ForEach-Object { $Algorithm_Norm = Get-Algorithm $_; $_ } | Where-Object { $Pools.$Algorithm_Norm.Protocol -eq "stratum+tcp" <#temp fix#> } | ForEach-Object { 
        $Miner_Name = (@($Name) + @($Miner_Device.Model_Norm | Sort-Object -unique | ForEach-Object { $Model_Norm = $_; "$(@($Miner_Device | Where-Object Model_Norm -eq $Model_Norm).Count)x$Model_Norm" }) | Select-Object) -join '-'

        #Get commands for active miner devices
        $Command = Get-CommandPerDevice -Command $Commands.$_ -ExcludeParameters @("a", "algo") -DeviceIDs $Miner_Device.Type_Vendor_Index

        #Optionally disable dev fee mining
        if ($null -eq $Miner_Config) { $Miner_Config = [PSCustomObject]@{ DisableDevFeeMining = $Config.DisableDevFeeMining } }
        if ($Miner_Config.DisableDevFeeMining) { 
            $NoFee = " --no-donation"
            $Miner_Fees = [PSCustomObject]@{ $Algorithm_Norm = 0 }
        }
        else { 
            $NoFee = ""
            $Miner_Fees = [PSCustomObject]@{ $Algorithm_Norm = 1 / 400 }
        }
        [PSCustomObject]@{ 
            Name       = $Miner_Name
            BaseName   = $Miner_BaseName
            Version    = $Miner_Version
            DeviceName = $Miner_Device.Name
            Path       = $Path
            HashSHA256 = $HashSHA256
            Arguments  = ("$Command$CommonCommands -b 127.0.0.1:$($Miner_Port) -o $($Pools.$Algorithm_Norm.Protocol)://$($Pools.$Algorithm_Norm.Host):$($Pools.$Algorithm_Norm.Port) -u $($Pools.$Algorithm_Norm.User) -p $($Pools.$Algorithm_Norm.Pass) -d $(($Miner_Device | ForEach-Object { '{0:x}' -f ($_.Type_Vendor_Index) }) -join ',')" -replace "\s+", " ").trim()
            HashRates  = [PSCustomObject]@{ $Algorithm_Norm = $Stats."$($Miner_Name)_$($Algorithm_Norm)_HashRate".Week }
            API        = "Ccminer"
            Port       = $Miner_Port
            URI        = $Uri
            Fees       = $Miner_Fees
        }
    }
}
