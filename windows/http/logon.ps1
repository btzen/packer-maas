<#
# Upstream Author:
#
#     Canonical Ltd.
#
# Copyright:
#
#     (c) 2014-2023 Canonical Ltd.
#
# Licence:
#
# If you have an executed agreement with a Canonical group company which
# includes a licence to this software, your use of this software is governed
# by that agreement.  Otherwise, the following applies:
#
# Canonical Ltd. hereby grants to you a world-wide, non-exclusive,
# non-transferable, revocable, perpetual (unless revoked) licence, to (i) use
# this software in connection with Canonical's MAAS software to install Windows
# in non-production environments and (ii) to make a reasonable number of copies
# of this software for backup and installation purposes.  You may not: use,
# copy, modify, disassemble, decompile, reverse engineer, or distribute the
# software except as expressly permitted in this licence; permit access to the
# software to any third party other than those acting on your behalf; or use
# this software in connection with a production environment.
#
# CANONICAL LTD. MAKES THIS SOFTWARE AVAILABLE "AS-IS".  CANONICAL  LTD. MAKES
# NO REPRESENTATIONS OR WARRANTIES OF ANY KIND, WHETHER ORAL OR WRITTEN,
# WHETHER EXPRESS, IMPLIED, OR ARISING BY STATUTE, CUSTOM, COURSE OF DEALING
# OR TRADE USAGE, WITH RESPECT TO THIS SOFTWARE.  CANONICAL LTD. SPECIFICALLY
# DISCLAIMS ANY AND ALL IMPLIED WARRANTIES OR CONDITIONS OF TITLE, SATISFACTORY
# QUALITY, MERCHANTABILITY, SATISFACTORINESS, FITNESS FOR A PARTICULAR PURPOSE
# AND NON-INFRINGEMENT.
#
# IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING WILL
# CANONICAL LTD. OR ANY OF ITS AFFILIATES, BE LIABLE TO YOU FOR DAMAGES,
# INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL OR CONSEQUENTIAL DAMAGES ARISING
# OUT OF THE USE OR INABILITY TO USE THIS SOFTWARE (INCLUDING BUT NOT LIMITED
# TO LOSS OF DATA OR DATA BEING RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU
# OR THIRD PARTIES OR A FAILURE OF THE PROGRAM TO OPERATE WITH ANY OTHER
# PROGRAMS), EVEN IF SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGES.
#>

param(
    [Parameter()]
    [switch]$RunPowershell,
    [bool]$DoGeneralize
)

$ErrorActionPreference = "Stop"

function Download-File {
    param($Url, $OutFile)
    curl.exe -L -o $OutFile $Url
    if ($LASTEXITCODE -ne 0) {
        throw "下载失败: $Url"
    }
}

try
{
    # Need to have network connection to continue, wait 30
    # seconds for the network to be active.
    start-sleep -s 30

        # Inject extra drivers if the infs directory is present on the attached iso
        if (Test-Path -Path "E:\infs")
        {
            # To install extra drivers the Windows Driver Kit is needed for dpinst.exe.
            # Sadly you cannot just download dpinst.exe. The whole driver kit must be
            # installed.
            # Download the WDK offline package (contains wdksetup.exe + Installers folder).
            $Host.UI.RawUI.WindowTitle = "Downloading Windows Driver Kit..."
            Download-File -Url "https://disk.bt.plus/sd/vCLqIdZA/packer-maas-down/WDK.zip" -OutFile "c:\WDK.zip"
            Expand-Archive -Path "c:\WDK.zip" -DestinationPath "c:\WDK" -Force

            # Run the installer from offline package.
            $Host.UI.RawUI.WindowTitle = "Installing Windows Driver Kit..."
            $p = Start-Process -PassThru -Wait -FilePath "c:\WDK\wdksetup.exe" -ArgumentList "/features OptionId.WindowsDriverKitComplete /q /ceip off /norestart"
            if ($p.ExitCode -ne 0)
            {
                throw "Installing wdksetup.exe failed."
            }

            # Run dpinst.exe with the path to the drivers.
            $Host.UI.RawUI.WindowTitle = "Injecting Windows drivers..."
            $dpinst = "$ENV:ProgramFiles (x86)\Windows Kits\8.1\redist\DIFx\dpinst\EngMui\x64\dpinst.exe"
            Start-Process -Wait -FilePath "$dpinst" -ArgumentList "/S /C /F /SA /Path E:\infs"

            # Uninstall the WDK
            $Host.UI.RawUI.WindowTitle = "Uninstalling Windows Driver Kit..."
            Start-Process -Wait -FilePath "c:\WDK\wdksetup.exe" -ArgumentList "/features + /q /uninstall /norestart"

            # Clean-up
            Remove-Item -Path "c:\WDK" -Recurse -Force
            Remove-Item -Path "c:\WDK.zip" -Force
        }

        $Host.UI.RawUI.WindowTitle = "Installing Cloudbase-Init..."
        Download-File -Url "https://disk.bt.plus/sd/vCLqIdZA/packer-maas-down/CloudbaseInitSetup_Stable_x64.msi" -OutFile "c:\cloudbase.msi"
        $cloudbaseInitLog = "$ENV:Temp\cloudbase_init.log"
        $serialPortName = @(Get-WmiObject Win32_SerialPort)[0].DeviceId
        $p = Start-Process -Wait -PassThru -FilePath msiexec -ArgumentList "/i c:\cloudbase.msi /qn /norestart /l*v $cloudbaseInitLog LOGGINGSERIALPORTNAME=$serialPortName"
        if ($p.ExitCode -ne 0)
        {
            throw "Installing $cloudbaseInitPath failed. Log: $cloudbaseInitLog"
        }

        # Configure cloudbase-init plugins (main config only)
        $cbConfDir = "$ENV:ProgramFiles\Cloudbase Solutions\Cloudbase-Init\conf"
        $cbConfigPath = "$cbConfDir\cloudbase-init.conf"

        $pluginsMain = "plugins=cloudbaseinit.plugins.common.mtu.MTUPlugin,cloudbaseinit.plugins.windows.ntpclient.NTPClientPlugin,cloudbaseinit.plugins.common.networkconfig.NetworkConfigPlugin,cloudbaseinit.plugins.common.userdata.UserDataPlugin,cloudbaseinit.plugins.common.localscripts.LocalScriptsPlugin"

        if (Test-Path $cbConfigPath) {
            $content = Get-Content $cbConfigPath -Encoding UTF8
            if ($content -match "^\s*plugins\s*=") {
                $content = $content -replace "^\s*plugins\s*=.*", $pluginsMain
            } else {
                $content = $content -replace "\[DEFAULT\]", "[DEFAULT]`r`n$pluginsMain"
            }
            Set-Content $cbConfigPath $content -Encoding UTF8
        }

        # We're done, remove LogonScript, disable AutoLogon
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name Unattend*
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name AutoLogonCount

        # Fix BUG #335 - Microsoft Edge Preventing the sysprep
        $pkg = Get-AppxPackage -Name "Microsoft.Edge.GameAssist" -AllUsers
        if ($pkg) {
            Reset-AppxPackage -Package $pkg.PackageFullName
        }

        $Host.UI.RawUI.WindowTitle = "Running SetSetupComplete..."
        & "$ENV:ProgramFiles\Cloudbase Solutions\Cloudbase-Init\bin\SetSetupComplete.cmd"

        if ((Get-Item -Path "A:\custom.ps1").Length -gt 0) {
            $Host.UI.RawUI.WindowTitle = "Copying custom Powershell script..."
            Copy-Item -Path "A:\custom.ps1" -Destination "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\LocalScripts\" -Force
        }

        # Download additional files to C:\
        $Host.UI.RawUI.WindowTitle = "Downloading AME-Beta..."
        Download-File -Url "https://disk.bt.plus/sd/vCLqIdZA/packer-maas-down/AME-Beta-v0.8.4.exe" -OutFile "C:\AME-Beta-v0.8.4.exe"

        $Host.UI.RawUI.WindowTitle = "Downloading Revi-PB..."
        Download-File -Url "https://disk.bt.plus/sd/vCLqIdZA/packer-maas-down/Revi-PB-25.10.apbx" -OutFile "C:\Revi-PB-25.10.apbx"

        $Host.UI.RawUI.WindowTitle = "Downloading Dism++..."
        Download-File -Url "https://disk.bt.plus/sd/vCLqIdZA/packer-maas-down/Dism++10.1.1002.1B.zip" -OutFile "C:\Dism++10.1.1002.1B.zip"
        Expand-Archive -Path "C:\Dism++10.1.1002.1B.zip" -DestinationPath "C:\Dism++10.1.1002.1B" -Force

        # ===== System registry modifications =====
        $Host.UI.RawUI.WindowTitle = "Configuring system registry..."

        # Disable firewall service
        $mpssvcPath = "HKLM:\SYSTEM\CurrentControlSet\Services\mpssvc"
        if (-not (Test-Path $mpssvcPath)) { New-Item -Path $mpssvcPath -Force | Out-Null }
        Set-ItemProperty -Path $mpssvcPath -Name "Start" -Value 4 -Type DWord

        # Disable UAC
        $uacPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
        if (-not (Test-Path $uacPath)) { New-Item -Path $uacPath -Force | Out-Null }
        Set-ItemProperty -Path $uacPath -Name "ConsentPromptBehaviorAdmin" -Value 0 -Type DWord
        Set-ItemProperty -Path $uacPath -Name "EnableLUA" -Value 0 -Type DWord
        Set-ItemProperty -Path $uacPath -Name "PromptOnSecureDesktop" -Value 0 -Type DWord

        # Disable SmartScreen filter
        $smartscreenPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"
        if (-not (Test-Path $smartscreenPath)) { New-Item -Path $smartscreenPath -Force | Out-Null }
        Set-ItemProperty -Path $smartscreenPath -Name "SmartScreenEnabled" -Value "off" -Type String

        # Hide 7 folders from This PC
        $clsidList = @(
            "{31C0DD25-9439-4F12-BF41-7FF4EDA38722}",  # 3D Objects
            "{7d83ee9b-2244-4e70-b1f5-5393042af1e4}",  # Downloads
            "{a0c69a99-21c8-4671-8703-7934162fcf1d}",  # Music
            "{0ddd015d-b06c-45d5-8c4c-f59713854639}",  # Pictures
            "{35286a68-3c57-41a1-bbb1-0eae73d76c95}",  # Videos
            "{f42ee2d3-909f-4907-8871-4c22fc0bf756}",  # Documents
            "{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}"   # Desktop
        )
        foreach ($clsid in $clsidList) {
            $propBagPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions\$clsid\PropertyBag"
            if (-not (Test-Path $propBagPath)) {
                New-Item -Path $propBagPath -Force | Out-Null
            }
            Set-ItemProperty -Path $propBagPath -Name "ThisPCPolicy" -Value "Hide" -Type String
        }

        # ===== User registry modifications (default user NTUSER.DAT) =====
        $Host.UI.RawUI.WindowTitle = "Configuring default user registry..."

        $tempHiveName = "TempDefaultUser"
        reg load "HKLM\$tempHiveName" "C:\Users\Default\NTUSER.DAT"
        if ($LASTEXITCODE -ne 0) { throw "Failed to load default user registry hive" }

        $userRoot = "HKLM:\$tempHiveName"

        # Hide taskbar search
        $searchPath = "$userRoot\SOFTWARE\Microsoft\Windows\CurrentVersion\Search"
        if (-not (Test-Path $searchPath)) { New-Item -Path $searchPath -Force | Out-Null }
        Set-ItemProperty -Path $searchPath -Name "SearchboxTaskbarMode" -Value 0 -Type DWord

        # Hide Task View / Never combine taskbar buttons / Open Explorer to This PC / Show file extensions
        $advPath = "$userRoot\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        if (-not (Test-Path $advPath)) { New-Item -Path $advPath -Force | Out-Null }
        Set-ItemProperty -Path $advPath -Name "ShowTaskViewButton" -Value 0 -Type DWord
        Set-ItemProperty -Path $advPath -Name "TaskbarGlomLevel" -Value 2 -Type DWord
        Set-ItemProperty -Path $advPath -Name "LaunchTo" -Value 1 -Type DWord
        Set-ItemProperty -Path $advPath -Name "HideFileExt" -Value 0 -Type DWord
        Set-ItemProperty -Path $advPath -Name "AutoCheckSelect" -Value 0 -Type DWord

        # Disable frequent/recent folders in Quick Access
        $explorerPath = "$userRoot\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"
        if (-not (Test-Path $explorerPath)) { New-Item -Path $explorerPath -Force | Out-Null }
        Set-ItemProperty -Path $explorerPath -Name "ShowFrequent" -Value 0 -Type DWord
        Set-ItemProperty -Path $explorerPath -Name "ShowRecent" -Value 0 -Type DWord

        # Disable "Open File - Security Warning" dialog
        $assocPath = "$userRoot\Software\Microsoft\Windows\CurrentVersion\Policies\Associations"
        if (-not (Test-Path $assocPath)) { New-Item -Path $assocPath -Force | Out-Null }
        Set-ItemProperty -Path $assocPath -Name "ModRiskFileTypes" -Value ".bat;.exe;.reg;.vbs;.chm;.msi;.js;.cmd" -Type String

        # Unload default user registry hive
        [GC]::Collect()
        reg unload "HKLM\$tempHiveName"
        if ($LASTEXITCODE -ne 0) { throw "Failed to unload default user registry hive" }

        if ($RunPowershell) {
            $Host.UI.RawUI.WindowTitle = "Paused, waiting for user to finish work in other terminal"
            Write-Host "Spawning another powershell for the user to complete any work..."
            Start-Process -Wait -PassThru -FilePath powershell
        }

        # Clean-up
        Remove-Item -Path c:\cloudbase.msi
}
catch
{
    $_ | Out-File c:\error_log.txt
}
