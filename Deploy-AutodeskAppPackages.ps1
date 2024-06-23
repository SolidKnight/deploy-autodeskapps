#requires -Modules @{ ModuleName = 'IntuneWin32App' ; ModuleVersion = '1.4.4' }

# This script will prepare and upload Autodesk Custom Deployment or Update installers to Intune
# Requirements:
# * PSADT Templates customized specifically for this script
# * ServiceUI.exe bundled into PSADT Template
# * IntuneWin32App PowerShell Module
# * Custom App Registered in Entra Id (Azure AD) with Microsoft Graph delegated permissions DeviceManagementApp.ReadWrite.All and Groups.ReadAll
# * Premade and pre-made icons include a generic for unknown product types
# Assumptions:
# * Custom Install of type deployment from the Autodesk Management portal
# * Custom Install contains only one product. I.e., Is not a bundle of AutoCAD + Revit + C3D
# * Custom Install executable will be copied to the target machine then extracted locally
# * Custom Install is for 2022 or later
# * Product update is for 2022 or later
# * Icons are named with the PLC and are of type PNG
# Example:
# Deploy-AutodeskAppPackages.ps1 -PackageSourcePath C:\Temp\Autodesk\source\ -WorkspacePath C:\Temp\Autodesk\workspace\ -TenantId 'domain.tld' -ClientId "00000000-0000-0000-0000-000000000000" -TestGroupId "00000000-0000-0000-0000-000000000000"

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateScript({
            if (Test-Path -Path $_ -PathType Container) {
                $items = Get-ChildItem -Path $_ -Filter "*.exe"
                if ($items.Count -gt 0) {
                    $true
                }
                else {
                    throw "PackageSourcePath $_ does not contain any .exe files."
                }
            }
            else {
                throw "PackageSourcePath $_ does not exist."
            }
        })]
    $PackageSourcePath, # Folder containing all the installers to package
    [Parameter(Mandatory = $true)]
    [ValidateScript({
            if (Test-Path -Path $_ -PathType Container) {
                $items = Get-ChildItem -Path $_
                if ($items.Count -eq 0) {
                    $true
                }
                else {
                    throw "WorkspacePath $_ is not empty."
                }
            }
            else {
                throw "WorkspacePath $_ does not exist."
            }
        })]
    $WorkspacePath, # Empty folder to stage all the files in
    [Parameter(Mandatory = $true)]
    $TenantId, # Enter your TenantID (i.e. - domain.com or domain.onmicrosoft.com)
    [Parameter(Mandatory = $true)]
    $ClientId, # Enter the client id for the app you registered for IntuneWin32App,
    [Parameter(Mandatory = $true)]
    $TestGroupId, # Enter the id of the group for testing
    [Parameter(Mandatory = $false)]
    $DisplayNamePrefix = "",
    [Parameter(Mandatory = $false)]
    [switch]$Upload
)
    
$StagedFilesPath = Join-Path -Path $WorkspacePath -ChildPath "StagedFiles" # Whatever is in this folder will get packed by IntuneWinAppUtil
$PackagedFilesPath = Join-Path -Path $WorkspacePath -ChildPath "PackagedFiles" # This is where .intunewin files will end up
$ExtractedFilesPath = Join-Path -Path $WorkspacePath -ChildPath "ExtractedFiles" # This is where the deployment executables will get extracted to to get the product codes
$PSADTAppTemplatePath = Join-Path -Path $PSScriptRoot -ChildPath "resources\PSADTAppTemplate"
$PSADTAppUpdateTemplatePath = Join-Path -Path $PSScriptRoot -ChildPath "resources\PSADTAppUpdateTemplate"
$IconsPath = Join-Path -Path $PSScriptRoot -ChildPath "resources\icons"

# Connect to Graph API
Connect-MSIntuneGraph -TenantID $TenantId -ClientID $ClientId -Interactive | Out-Null

###################################################################################################
# Functions
###################################################################################################

# This function parses XML files
function Get-MetaFromXml {
    param(
        $Path,
        $Tags
    )

    # Load the XML from a file
    [xml]$xml = (Get-Content -Path $Path)

    # Create an XmlNamespaceManager and add the namespace dynamically
    $ns = New-Object Xml.XmlNamespaceManager $xml.NameTable
    $ns.AddNamespace('ns', $xml.DocumentElement.NamespaceURI)

    # Initialize an empty hashtable to store the results
    $result = @{}

    # Loop through each tag and add its value to the result hashtable
    foreach ($tag in $Tags) {
        $result[$tag] = $xml.SelectSingleNode("//ns:$tag", $ns).'#text'
    }

    return $result
}

# This function will gather all the required information from the collection and setup xml files
function Get-AutodeskAppMetaInformation {
    param(
        $Path
    )
    $SetupXmlPath = (Join-Path -Path $Path -ChildPath "setup.xml")
    $CollectionXmlPath = (Join-Path -Path $Path -ChildPath "collection.xml")

    $CollectionMetaInformation = @{}
    $SetupMetaInformation = @{}

    if (Test-Path -Path $CollectionXmlPath) {
        $CollectionMetaInformation = Get-MetaFromXml -Path $CollectionXmlPath -Tags @('Name', 'DeploymentImagePath', 'BundleID')
        $SetupXmlPath = (Join-Path $Path -ChildPath "$($CollectionMetaInformation.BundleID)\setup.xml")
    }

    if (Test-Path -Path $SetupXmlPath) {
        $SetupMetaInformation = Get-MetaFromXml -Path $SetupXmlPath -Tags @('Publisher', 'DisplayName', 'Release', 'BuildNumber', 'UPI2', 'PLC', 'Type')
    }

    return $SetupMetaInformation += $CollectionMetaInformation
}

# Stage files and create .intunewin file
function Build-IntuneWin32AppPackage {
    param (
        $File,
        $StageToPath,
        $ProductMetaInformation
    )

    if ($ProductMetaInformation.Type -eq "UPD") {
        # Copy PSADT App Update Template
        Copy-Item -Path "$PSADTAppUpdateTemplatePath\*" -Destination $StageToPath -Recurse -Force


        # Modify Deploy-Application.ps1
        $FileContent = Get-Content -Path "$StageToPath\Deploy-Application.ps1"
        $UpdatedContent = $FileContent -replace "{{InstallerName}}", $File.Name
        $UpdatedContent = $UpdatedContent -replace "{{VendorName}}", $ProductMetaInformation.Publisher
        $UpdatedContent = $UpdatedContent -replace "{{AppName}}", ((($ProductMetaInformation.DisplayName).TrimStart('Autodesk ')).TrimEnd(' Update'))
        $UpdatedContent = $UpdatedContent -replace "{{AppVersion}}", $ProductMetaInformation.BuildNumber
        Set-Content -Path "$StageToPath\Deploy-Application.ps1" -Value $UpdatedContent
    }

    if ($ProductMetaInformation.Type -eq "PRD") {
        # Copy PSADT Deployment Template
        Copy-Item -Path "$PSADTAppTemplatePath\*" -Destination $StageToPath -Recurse -Force

        # Modify Deploy-Application.ps1
        $FileContent = Get-Content -Path "$StageToPath\Deploy-Application.ps1"
        $UpdatedContent = $FileContent -replace "{{DeploymentImagePath}}", $ProductMetaInformation.DeploymentImagePath
        $UpdatedContent = $UpdatedContent -replace "{{DeploymentPackageName}}", $File.Name
        $UpdatedContent = $UpdatedContent -replace "{{VendorName}}", $ProductMetaInformation.Publisher
        $UpdatedContent = $UpdatedContent -replace "{{AppName}}", $ProductMetaInformation.Name
        $UpdatedContent = $UpdatedContent -replace "{{AppVersion}}", $ProductMetaInformation.BuildNumber
        Set-Content -Path "$StageToPath\Deploy-Application.ps1" -Value $UpdatedContent
    }

    # Copy Deployment Files
    Copy-Item -Path $File.FullName -Destination (Join-Path -Path $StageToPath -ChildPath "Files")

    # Package App for Intune
    return New-IntuneWin32AppPackage -SourceFolder $StageFilesToPath -SetupFile "Deploy-Application.exe" -OutputFolder $PackagedFilesPath -Force
}

###################################################################################################
# Main
###################################################################################################

# Create Folder Structure
New-Item -Path $StagedFilesPath -ItemType Directory | Out-Null
New-Item -Path $PackagedFilesPath -ItemType Directory | Out-Null
New-Item -Path $ExtractedFilesPath -ItemType Directory | Out-Null

# Get all the installers
$Products = Get-ChildItem -Path $PackageSourcePath -Filter *.exe # Folder containing all the installers to package

# Build a package for each installer and add it to Intune
foreach ($product in $Products) {
    Write-Verbose "Working on $product..."
    # Create Folders
    $StageFilesToPath = (Join-Path -Path $StagedFilesPath -ChildPath $product.BaseName)
    New-Item -Path $StageFilesToPath -ItemType Directory | Out-Null

    # Extract Installers
    try {
        & 'C:\Program Files\7-Zip\7z.exe' x $product.FullName -o"$(Join-Path -Path $ExtractedFilesPath -ChildPath $product.BaseName)" > $null
    }
    catch {
        Write-Error "Failed to extract [$($product.FullName)]"
    }

    # Get Product Meta
    $productMetaInformation = Get-AutodeskAppMetaInformation -Path (Join-Path -Path $ExtractedFilesPath -ChildPath $product.BaseName)
    
    # Only proceed if product is of expected type
    if ($productMetaInformation.Type -match "UPD|PRD") {
        # Create copy and create all resources and then create the .intunewin
        $productPackage = Build-IntuneWin32AppPackage -File $product -StageToPath $StageFilesToPath -ProductMetaInformation $productMetaInformation

        # Set IconPath
        $iconPath = Get-Item -Path (Join-Path -Path $IconsPath -ChildPath "autodesk.png")

        if (Test-Path -Path "$IconsPath\$($productMetaInformation.PLC).png") { 
            $iconPath = Get-Item -Path "$IconsPath\$($productMetaInformation.PLC).png"
        }
        else {
            Write-Warning "Could not find $($productMetaInformation.PLC).png"
        }

        $IntuneWin32AppParams = @{
            FilePath             = $productPackage.Path
            DisplayName          = "" # Changes based on type
            Description          = "" # Changes based on type
            Publisher            = $productMetaInformation.Publisher 
            AppVersion           = $productMetaInformation.BuildNumber
            CategoryName         = "" # Changes based on type
            Icon                 = New-IntuneWin32AppIcon -FilePath $iconPath.FullName
            InstallExperience    = "system"
            RestartBehavior      = "suppress" 
            InstallCommandLine   = "ServiceUI.exe -Process:explorer.exe Deploy-Application.exe -DeploymentType 'Install'"
            UninstallCommandLine = "" # Changes based on type
            DetectionRule        = "" # Changes based on type
            RequirementRule      = New-IntuneWin32AppRequirementRule -Architecture "x64" -MinimumSupportedWindowsRelease "W10_1607"
        }

        if ($productMetaInformation.Type -eq "UPD") {
            $IntuneWin32AppParams.DisplayName = "$DisplayNamePrefix$($productMetaInformation.DisplayName)"
            $IntuneWin32AppParams.Description = "Applies $($productMetaInformation.DisplayName) to base product"
            $IntuneWin32AppParams.CategoryName = 'Updates'
            $IntuneWin32AppParams.UninstallCommandLine = "cmd /c echo 'Uninstall note supported'"
            $IntuneWin32AppParams.DetectionRule = New-IntuneWin32AppDetectionRuleRegistry -VersionComparison -KeyPath "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$($productMetaInformation.UPI2)" -ValueName "DisplayVersion" -VersionComparisonOperator "equal" -VersionComparisonValue $productMetaInformation.BuildNumber
            $IntuneWin32AppParams.Add('AdditionalRequirementRule', (New-IntuneWin32AppRequirementRuleRegistry -VersionComparison -KeyPath "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$($productMetaInformation.UPI2)" -ValueName "DisplayVersion" -VersionComparisonOperator "lessThan" -VersionComparisonValue $productMetaInformation.BuildNumber))
        }

        if ($productMetaInformation.Type -eq "PRD") {
            $IntuneWin32AppParams.DisplayName = "$DisplayNamePrefix$($productMetaInformation.Name)"
            $IntuneWin32AppParams.Description = "Installs $($ProductMetaInformation.Name)"
            $IntuneWin32AppParams.CategoryName = 'Development & Design'
            $IntuneWin32AppParams.UninstallCommandLine = "`"$($ProductMetaInformation.DeploymentImagePath)\image\Installer.exe`" -i uninstall -q --manifest `"$($productMetaInformation.DeploymentImagePath)\image\$($productMetaInformation.BundleId)\setup.xml`" --extension_manifest `"$($productMetaInformation.DeploymentImagePath)\image\$($productMetaInformation.BundleId)\setup_ext.xml`"" # Changes
            $IntuneWin32AppParams.DetectionRule = New-IntuneWin32AppDetectionRuleRegistry -Existence -KeyPath "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$($productMetaInformation.UPI2)" -Check32BitOn64System $false -DetectionType "exists"
            $IntuneWin32AppParams.Add('AllowAvailableUninstall', $true)
        }

        if ($Upload) {
            Write-Verbose "Uploading [$($IntuneWin32AppParams.DisplayName)]..."
            $Win32App = Add-IntuneWin32App @IntuneWin32AppParams
            Add-IntuneWin32AppAssignmentGroup -ID $Win32App.Id -GroupID $TestGroupId -Intent "available" -Notification showAll -Include -Verbose
        }
    }
    else {
        Write-Error "Product is of unexpected type check setup.xml Bundle.Identity.Type for value. Only type UPD or PRD is supported"
    }
}
