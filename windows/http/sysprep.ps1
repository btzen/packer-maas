<#
# Sysprep Script
#
# This script runs Sysprep to prepare the Windows image for deployment.
#>

$ErrorActionPreference = "Stop"

$Host.UI.RawUI.WindowTitle = "Running Sysprep..."
$unattendedXmlPath = "$ENV:ProgramFiles\Cloudbase Solutions\Cloudbase-Init\conf\Unattend.xml"
& "$ENV:SystemRoot\System32\Sysprep\Sysprep.exe" `/generalize `/oobe `/shutdown `/unattend:"$unattendedXmlPath"
