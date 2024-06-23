# Purpose
To assist with rapidly packaging and uploading Autodesk custom deployments and product updates to Intune as a Win32 app.

# Getting Started
### Supported Installers
* 2022+ Custom Installs in deployment mode from [manage.autodesk.com](https://manage.autodesk.com)
* 2022+ Product Updates


### Unsupported Installers
* Installers pre-dating the custom installers feature in manage.autodesk.com
* Custom installers in install mode
* SFX installers
* Autodesk Desktop Connector installer


### Pre-Requisites
* [7-zip](https://www.7-zip.org/download.html) installed. This is required to unpack the Autodesk installers.
* PowerShell Module [IntuneWin32Apps](https://github.com/MSEndpointMgr/IntuneWin32App) is installed. This is required to package and upload apps to Intune.
* An app registered in Microsoft Entra Id/Azure AD for the purpose of authentication. See [known issues](#d1ddf0e4-d672-4dae-b554-9d5bdfd93547).
* [Intune Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool) is required to package and upload apps to Intune.
* [Custom Deployments](https://www.autodesk.com/in/support/download-install/admins/account-deploy/deploy-from-autodesk-account) of type **Deploy** with **Deployment Image Path** set to a fixed local path. E.g. C:\Autodesk\AutoCAD-2024\

> [!TIP]
> Create your [Custom Deployments](https://www.autodesk.com/in/support/download-install/admins/account-deploy/deploy-from-autodesk-account) with a single base product. I.e. A deployment that doesn't include Revit + AutoCAD + ReCap

> [!WARNING]
> There is currently a known issue with authentication when using the IntuneWin32Apps module. See [known issues](#d1ddf0e4-d672-4dae-b554-9d5bdfd93547).


### Instructions
* Complete installation/creation of all pre-requisites.
* Download the latest release of Deploy-AutodeskApps.
* Create a folder and place all the custom deployments and/or product updates in it.
* Create a folder to act as temporary workspace for this tool. The folder must be empty.
```PowerShell
Set-Location -Path <path_to_deploy-autodeskapppackages.ps1_here>
.\Deploy-AutodeskAppPackages.ps1 -PackageSourcePath C:\Temp\Autodesk\source\ -WorkspacePath C:\Temp\Autodesk\workspace\ -TenantId 'domain.tld' -ClientId "00000000-0000-0000-0000-000000000000" -TestGroupId "00000000-0000-0000-0000-000000000000" -DeploymentNamePrefix "<optional-prefix-for-display-name>"
```

## Script Parameters
### PackageSourcePath
Mandatory parameter that specifies the directory containing all the custom deployments or product updates.
### WorkspacePath
Mandator parameter with specifies the directory to extract, stage, and package all installers. The directory must be empty.
### TenantId
Mandatory parameter that specifies the domain name for your Entra Id/Intune tenant.
### ClientId
Mandatory parameter that specifies the ClientId belonging to the app you registered in Entra Id/Azure Ad for use with IntuneWin32Apps.
### TestGroupId
Mandatory parameter that specifies the object id of the testing group. Apps will be assigned with available intent to this group.
### DeplymentNamePrefix
Optional parameter for specifying a prefix to the deployment name.
### Upload
Optional parameter the controls whether or not packages are uploaded to Intune.



# FAQ
### What happens when the script is run?
The script will iterate through all .exe files in PackageSourcePath and extract them with 7zip. It will collect meta information from setup.xml and collections.xml contained in the extracted files. It will then generate a PSADT deployment using that meta information, make the .intunewin file, and add them to Intune. The app's icon will be set to an icon contained within the icons folder matching the PLC value of the product. If no match occurs, it will be set to a generic Autodesk icon instead.
The workspace folder will not be cleaned up to support workflows such as copying the staged files and/or the .intunewin files to a file share/blob.


### What should I know about the packages it makes?
These packages are interactive via the use of PSAT and ServiceUI for both apps and updates.
The PSADT deployment will check for common Autodesk products and give the end-user some time to close those apps if they're open.
Custom Deployments will extract the deployment files to the local computer then execute the silent install command.

Updates will have a registry requirement for the base product to be installed.


### Why Custom Deployments instead of Custom Installs?
Custom installs effectively are deployments witha local deployment path. I.e. C:\Autodesk\<GUID>. Every time you make a new custom installer, it creates a new GUID. You can end up with a lot of space taken up in C:\Autodesk if end-users install/uninstall or change up packages with similar contents. The Custom Install also doesn't play nice with


### Where do I find the PLC value for an icon?
In setup.xml for the product under the key <PLC>


# Known Issues
### Apps are added to Intune but the .intunewin is never uploaded.
Review the output of the script and look at the entries regarding commits to Azure Blob Storage. If you see that it failed, and you're running the script in PowerShell 7.4+. You can run in PowerShell 5.1 as a workaround. This is a [known issue](https://github.com/MSEndpointMgr/IntuneWin32App/issues/163) with IntuneWin32App.


### I recieve error "*Application with identifier 'd1ddf0e4-d672-4dae-b554-9d5bdfd93547' was not found in the directory*" when attempting to authenticate.
<a id='d1ddf0e4-d672-4dae-b554-9d5bdfd93547'></a>
This is a known [authentication issue](https://github.com/MSEndpointMgr/IntuneWin32App/issues/156) with IntuneWin32App due to the removal of app 'd1ddf0e4-d672-4dae-b554-9d5bdfd93547' by Microsoft.
1. Create or use an existing Entra Id/Azure Ad App Registration for IntuneWin32Apps that has delegated Microsoft Graph API permissions of `DeviceManagementApps.ReadWrite.All` and `Groups.Read.All`
2. Set reply URL to MSAL.
