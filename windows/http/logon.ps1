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
            # Download the WDK installer.
            $Host.UI.RawUI.WindowTitle = "Downloading Windows Driver Kit..."
            Download-File -Url "https://disk.bt.plus/sd/vCLqIdZA/packer-maas-down/wdksetup.exe" -OutFile "c:\wdksetup.exe"

            # Run the installer.
            $Host.UI.RawUI.WindowTitle = "Installing Windows Driver Kit..."
            $p = Start-Process -PassThru -Wait -FilePath "c:\wdksetup.exe" -ArgumentList "/features OptionId.WindowsDriverKitComplete /q /ceip off /norestart"
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
            Start-Process -Wait -FilePath "c:\wdksetup.exe" -ArgumentList "/features + /q /uninstall /norestart"

            # Clean-up
            Remove-Item -Path c:\wdksetup.exe
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

        # --- NEW SECTION: CONFIGURE ADMINISTRATOR & UNATTEND.XML ---
        $cbConfigPath = "$ENV:ProgramFiles\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf"
        $xmlPath = "$ENV:ProgramFiles\Cloudbase Solutions\Cloudbase-Init\conf\Unattend.xml"

        # 1. Update cloudbase-init.conf to target Administrator instead of Admin
        if (Test-Path $cbConfigPath) {
            $content = Get-Content $cbConfigPath
            # Replaces the default username to prevent creation of a new 'Admin' account
            $content = $content -replace "username=Admin", "username=Administrator"
            Set-Content $cbConfigPath $content
        }

        # 2. Update Unattend.xml to enable the built-in Administrator account natively
        if (Test-Path $xmlPath) {
            [xml]$xml = Get-Content $xmlPath
            $ns = "urn:schemas-microsoft-com:unattend"
            $nsMgr = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
            # Define the namespace used in the Unattend XML
            $nsMgr.AddNamespace("u", $ns)

            # Locate the Shell-Setup component in the oobeSystem pass
            $shellSetupPath = "//u:settings[@pass='oobeSystem']/u:component[@name='Microsoft-Windows-Shell-Setup']"
            $shellSetupNode = $xml.SelectSingleNode($shellSetupPath, $nsMgr)

            if ($shellSetupNode -and -not $shellSetupNode.SelectSingleNode("u:UserAccounts", $nsMgr)) {
                # Use the namespace explicitly during creation to ensure proper inheritance
                $userAccounts = $xml.CreateElement("UserAccounts", $ns)
                $adminPw = $xml.CreateElement("AdministratorPassword", $ns)
                $value = $xml.CreateElement("Value", $ns)
                $plainText = $xml.CreateElement("PlainText", $ns)

                # Setting an empty value for the password triggers the 'Enabled' state
                $value.InnerText = ""
                $plainText.InnerText = "true"

                $adminPw.AppendChild($value) | Out-Null
                $adminPw.AppendChild($plainText) | Out-Null
                $userAccounts.AppendChild($adminPw) | Out-Null
                $shellSetupNode.AppendChild($userAccounts) | Out-Null

                $xml.Save($xmlPath)
            }
        }
        # --- END OF NEW SECTION ---

        # Install virtio drivers
        $Host.UI.RawUI.WindowTitle = "Installing Virtio Drivers..."
        certutil -addstore "TrustedPublisher" A:\rh.cer
        Download-File -Url "https://disk.bt.plus/sd/vCLqIdZA/packer-maas-down/virtio-win-gt-x64.msi" -OutFile "c:\virtio.msi"
        Download-File -Url "https://disk.bt.plus/sd/vCLqIdZA/packer-maas-down/virtio-win-guest-tools.exe" -OutFile "c:\virtio.exe"
        $virtioLog = "$ENV:Temp\virtio.log"
        $serialPortName = @(Get-WmiObject Win32_SerialPort)[0].DeviceId
        $p = Start-Process -Wait -PassThru -FilePath msiexec -ArgumentList "/a c:\virtio.msi /qn /norestart /l*v $virtioLog LOGGINGSERIALPORTNAME=$serialPortName"
        $p = Start-Process -Wait -PassThru -FilePath c:\virtio.exe -Argument "/silent"

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

        $Host.UI.RawUI.WindowTitle = "Downloading AtlasPlaybook..."
        Download-File -Url "https://disk.bt.plus/sd/vCLqIdZA/packer-maas-down/AtlasPlaybook_v0.5.0-hotfix.apbx" -OutFile "C:\AtlasPlaybook_v0.5.0-hotfix.apbx"

        $Host.UI.RawUI.WindowTitle = "Downloading Dism++..."
        Download-File -Url "https://disk.bt.plus/sd/vCLqIdZA/packer-maas-down/Dism++10.1.1002.1B.zip" -OutFile "C:\Dism++10.1.1002.1B.zip"
        Expand-Archive -Path "C:\Dism++10.1.1002.1B.zip" -DestinationPath "C:\Dism++10.1.1002.1B" -Force

        if ($RunPowershell) {
            $Host.UI.RawUI.WindowTitle = "Paused, waiting for user to finish work in other terminal"
            Write-Host "Spawning another powershell for the user to complete any work..."
            Start-Process -Wait -PassThru -FilePath powershell
        }

        # Clean-up
        Remove-Item -Path c:\cloudbase.msi
        Remove-Item -Path c:\virtio.msi
        Remove-Item -Path c:\virtio.exe
}
catch
{
    $_ | Out-File c:\error_log.txt
}
