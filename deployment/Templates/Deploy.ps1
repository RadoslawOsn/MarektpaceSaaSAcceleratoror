﻿# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License. See LICENSE file in the project root for license information.

#
# Powershell script to deploy the resources - Customer portal, Publisher portal and the Azure SQL Database
#

Param(  
   [string][Parameter(Mandatory)]$WebAppNamePrefix, # Prefix used for creating web applications
   [string][Parameter()]$TenantID, # The value should match the value provided for Active Directory TenantID in the Technical Configuration of the Transactable Offer in Partner Center
   [string][Parameter()]$AzureSubscriptionID, # Subscription where the resources be deployed
   [string][Parameter()]$ADApplicationID, # The value should match the value provided for Active Directory Application ID in the Technical Configuration of the Transactable Offer in Partner Center
   [string][Parameter()]$ADApplicationSecret, # Secret key of the AD Application
   [string][Parameter()]$ADMTApplicationID, # The value should match the value provided for Multi-Tenant Active Directory Application ID in the Technical Configuration of the Transactable Offer in Partner Center
   [string][Parameter(Mandatory)]$SQLServerName, # Name of the database server (without database.windows.net)
   [string][Parameter(Mandatory)]$SQLAdminLogin, # SQL Admin login
   [string][Parameter(Mandatory)]$SQLAdminLoginPassword, # SQL Admin password
   [string][Parameter(Mandatory)]$PublisherAdminUsers, # Provide a list of email addresses (as comma-separated-values) that should be granted access to the Publisher Portal
   [string][Parameter()]$BacpacUrl, # The url to the blob storage where the SaaS DB bacpac is stored
   [string][Parameter(Mandatory)]$ResourceGroupForDeployment, # Name of the resource group to deploy the resources
   [string][Parameter(Mandatory)]$Location, # Location of the resource group
   [string][Parameter(Mandatory)]$PathToARMTemplate,  # Local Path to the ARM Template
   [string][Parameter()]$LogoURLpng,  # URL for Publisher .png logo
   [string][Parameter()]$LogoURLico,  # URL for Publisher .ico logo
   [string][Parameter()]$MeteredSchedulerSupport # set to NO to disable Metered Support
)

$ErrorActionPreference = "Stop"

# Checking SQL username
if($SQLAdminLogin.ToLower() -eq "admin") {
    Throw "🛑 SQLAdminLogin may not be 'admin'."
}

# Checking SQL password length
if($SQLAdminLogin.Length -lt 8) {
    Throw "🛑 SQLAdminLoginPassword must be at least 8 characters."
}

Write-Host "Starting SaaS Accelerator Deployment..."

# Record the current ADApps to reduce deployment instructions at the end
$IsADApplicationIDProvided = $ADApplicationIDProvided
$ISADMTApplicationIDProvided = $ADMTApplicationID
# Make sure to install Az Module before running this script
# Install-Module Az
# Install-Module -Name AzureAD

# Azure Login
if($env:ACC_CLOUD) {
    Write-Host "🔑  Authenticating using device..."
    #Connect-AzAccount -UseDeviceAuthentication
} else {
    Write-Host "🔑  Authenticating using AzAccount authentication..."
    Connect-AzAccount
}

Write-Host "🔑  Connecting to AzureAD..."
# Connect-AzureAD -Confirm   # TODO: Make this command works.  It fails when running from withing the script. 
Write-Host "🔑  All Authentications Connected."

$currentContext = get-AzureRMContext
$currentTenant = $currentContext.Account.ExtendedProperties.Tenants
$currentSubscription = $currentContext.Account.ExtendedProperties.Subscriptions
# Get TenantID if not set as argument
if(!($TenantID)) {    
    Get-AzTenant | Format-Table
    if (!($TenantID = Read-Host "⌨  Type your TenantID or press Enter to accept your current one [$currentTenant]")) { $TenantID = $currentTenant }    
}
else {
    Write-Host "🔑  TenantID provided: $TenantID"
}
                                                   
# Get Azure Subscription
if(!($AzureSubscriptionID)) {    
    Get-AzSubscription -TenantId $TenantID | Format-Table
    if (!($AzureSubscriptionID = Read-Host "⌨  Type your SubscriptionID or press Enter to accept your current one [$currentSubscription]")) { $AzureSubscriptionID = $currentSubscription }
}
else {
    Write-Host "🔑  AzureSubscriptionID provided: $AzureSubscriptionID"
}

Write-Host "🔑  Selecting Azure Subscription..."
Select-AzSubscription -SubscriptionId $AzureSubscriptionID
Write-Host "🔑  Azure Subscription selected."

# Create AAD App Registration

# AAD App Registration - Create Multi-Tenant App Registration Requst
if (!($ADApplicationID)) {   # AAD App Registration - Create Single Tenant App Registration
    Write-Host "🔑  Creating ADApplicationID..."
    $Guid = New-Guid
    $startDate = Get-Date
    $endDate = $startDate.AddYears(2)
    $ADApplicationSecret = ([System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(($Guid))))+"="

    try {    
        $ADApplication = New-AzureADApplication -DisplayName "$WebAppNamePrefix-FulfillmentApp"
        $ADObjectID = $ADApplication | %{ $_.ObjectId }
        $ADApplicationID = $ADApplication | %{ $_.AppId }
        Write-Host "🔑  AAD Single Tenant Object ID:" $ADObjectID    
        Write-Host "🔑  AAD Single Tenant Application ID:" $ADApplicationID  
        sleep 5 #this is to give time to AAD to register
        New-AzureADApplicationPasswordCredential -ObjectId $ADObjectID -StartDate $startDate -EndDate $endDate -Value $ADApplicationSecret -InformationVariable "SaaSAPI"
        Write-Host "🔑  ADApplicationID created."
        
    }
    catch [System.Net.WebException],[System.IO.IOException] {
        Write-Host "🚨🚨   $PSItem.Exception"
        break;
    }
}

$restbody = "" +`
"{ \`"displayName\`": \`"$WebAppNamePrefix-LandingpageAppReg\`"," +`
" \`"api\`":{\`"requestedAccessTokenVersion\`": 2}," +`
" \`"signInAudience\`" : \`"AzureADandPersonalMicrosoftAccount\`"," +`
" \`"web\`": " +`
"{ \`"redirectUris\`": " +`
"[" +`
"\`"https://$WebAppNamePrefix-portal.azurewebsites.net\`"," +`
"\`"https://$WebAppNamePrefix-portal.azurewebsites.net/\`"," +`
"\`"https://$WebAppNamePrefix-portal.azurewebsites.net/Home/Index\`"," +`
"\`"https://$WebAppNamePrefix-portal.azurewebsites.net/Home/Index/\`"," +`
"\`"https://$WebAppNamePrefix-admin.azurewebsites.net\`"," +`
"\`"https://$WebAppNamePrefix-admin.azurewebsites.net/\`"," +`
"\`"https://$WebAppNamePrefix-admin.azurewebsites.net/Home/Index\`"," +`
"\`"https://$WebAppNamePrefix-admin.azurewebsites.net/Home/Index/\`"" +`
"]," +`
" \`"logoutUrl\`": \`"https://$WebAppNamePrefix-portal.azurewebsites.net/logout\`"," +`
"\`"implicitGrantSettings\`": " +`
"{ \`"enableIdTokenIssuance\`": true }}," +`
" \`"requiredResourceAccess\`": " +`
" [{\`"resourceAppId\`": \`"00000003-0000-0000-c000-000000000000\`", " +`
" \`"resourceAccess\`": " +`
" [{ \`"id\`": \`"e1fe6dd8-ba31-4d61-89e7-88639da4683d\`"," +`
" \`"type\`": \`"Scope\`" }]}] }" 

Write-Host $restbody

if (!($ADMTApplicationID)) {   # AAD App Registration - Create Multi-Tenant App Registration Requst 
    Write-Host "🔑  Mapping Landing paged mapped to AppRegistration..."
    try {
        $landingpageLoginAppReg = $(az rest --method POST  --headers 'Content-Type=application/json' --uri https://graph.microsoft.com/v1.0/applications --body $restbody | jq '{lappID: .appId, publisherDomain: .publisherDomain, objectID: .id}')
        Write-Host "$landingpageLoginAppReg"
        $ADMTApplicationID = $landingpageLoginAppReg | jq .lappID | %{$_ -replace '"',''}
        Write-Host "🔑  Landing paged mapped to AppRegistration: $ADMTApplicationID"
        $ADMTObjectID = $landingpageLoginAppReg | jq .objectID | %{$_ -replace '"',''}
        Write-Host "🔑  Landing paged AppRegistration ObjectID: $ADMTObjectID"

        # Download Publisher's AppRegistration logo
        if($LogoURLpng) { 
            # Write-Host "📷  Downloading SSO AAD AppRegistration logo image..."
            # Invoke-WebRequest -Uri $LogoURLpng -OutFile "..\..\src\SaaS.SDK.CustomerProvisioning\wwwroot\applogo.png"
            # Write-Host "📷  SSO AAD AppRegistration logo image downloaded."    

            #Write-Host "🔑  Attaching Image to SSO AAD AppRegistration ObjectID: $ADMTObjectID ..."
            #$LogoURLpngPath = $(Resolve-Path "..\..\src\SaaS.SDK.CustomerProvisioning\wwwroot\applogo.png").Path

            #TODO: This is broken in PS CLI:  https://stackoverflow.microsoft.com/questions/276511
            # $LogoByteArray = [System.IO.File]::ReadAllBytes($LogoURLpngPath)
            # Set-AzureADApplicationLogo -ObjectId $ADMTObjectID -ImageByteArray $LogoByteArray 
            # Set-AzureADApplicationLogo -ObjectId $ADMTObjectID -FilePath $LogoURLpngPath
            #Write-Host "🔑  Image attached to SSO AAD AppRegistration."
        }
    }
    catch [System.Net.WebException],[System.IO.IOException] {
        Write-Host "🚨🚨   $PSItem.Exception"
        break;
    }
}

# Download Publisher's PNG logo
if($LogoURLpng) { 
    Write-Host "📷  Downloading PNG logo images..."
    Invoke-WebRequest -Uri $LogoURLpng -OutFile "..\..\src\SaaS.SDK.CustomerProvisioning\wwwroot\contoso-sales.png"
    Invoke-WebRequest -Uri $LogoURLpng -OutFile "..\..\src\SaaS.SDK.PublisherSolution\wwwroot\contoso-sales.png"
    Write-Host "📷  Logo images PNG downloaded."
}

# Download Publisher's FAVICON logo
if($LogoURLico) { 
    Write-Host "📷  Downloading ICO logo images..."
    Invoke-WebRequest -Uri $LogoURLico -OutFile "..\..\src\SaaS.SDK.CustomerProvisioning\wwwroot\favicon.ico"
    Invoke-WebRequest -Uri $LogoURLico -OutFile "..\..\src\SaaS.SDK.PublisherSolution\wwwroot\favicon.ico"
    Write-Host "📷  Logo images ICO downloaded."
}

Write-host "☁  Prepare publish files for the web application"

if (!($MeteredSchedulerSupport))
{
    $MeteredSchedulerSupport = "True"
}

if ($MeteredSchedulerSupport -ne "NO")
{ 
    Write-host "☁  Preparing the publish files for PublisherPortal"  
    dotnet publish ..\..\src\SaaS.SDK.PublisherSolution\SaaS.SDK.PublisherSolution.csproj -c debug -o ..\..\Publish\PublisherPortal

    mkdir -p ..\..\Publish\PublisherPortal\app_data\jobs\triggered\MeteredTriggerJob
    Write-host "☁  Preparing the publish files for Metered Scheduler to PublisherPortal"
    dotnet publish ..\..\src\SaaS.SDK.MeteredTriggerJob\SaaS.SDK.MeteredTriggerJob.csproj -c debug -o ..\..\Publish\PublisherPortal\app_data\jobs\triggered\MeteredTriggerJob  --runtime win-x64 --self-contained true 

    Compress-Archive -Path ..\..\Publish\PublisherPortal\* -DestinationPath ..\..\Publish\PublisherPortal.zip -Force

    $MeteredSchedulerSupport = "True"
}
else {
    Write-host "☁  Preparing the publish files for PublisherPortal"  
    dotnet publish ..\..\src\SaaS.SDK.PublisherSolution\SaaS.SDK.PublisherSolution.csproj -c debug -o ..\..\Publish\PublisherPortal 
    Compress-Archive -Path ..\..\Publish\PublisherPortal\* -DestinationPath ..\..\Publish\PublisherPortal.zip -Force
    $MeteredSchedulerSupport = "False"
}


Write-host "☁  Preparing the publish files for CustomerPortal"
dotnet publish ..\..\src\SaaS.SDK.CustomerProvisioning\SaaS.SDK.CustomerProvisioning.csproj -c debug -o ..\..\Publish\CustomerPortal
Compress-Archive -Path ..\..\Publish\CustomerPortal\* -DestinationPath ..\..\Publish\CustomerPortal.zip -Force


Write-host "☁ Path to web application packages $PathToWebApplicationPackages"

#Parameter for ARM template, Make sure to add values for parameters before running the script.
$ARMTemplateParams = @{
   webAppNamePrefix             = "$WebAppNamePrefix"
   TenantID                     = "$TenantID"
   ADApplicationID              = "$ADApplicationID"
   ADApplicationSecret          = "$ADApplicationSecret"
   ADMTApplicationID            = "$ADMTApplicationID"
   SQLServerName                = "$SQLServerName"
   SQLAdminLogin                = "$SQLAdminLogin"
   SQLAdminLoginPassword        = "$SQLAdminLoginPassword"
   bacpacUrl                    = "$URLToBacpacFromStorage"
   SAASKeyForbacpac             = ""
   PublisherAdminUsers          = "$PublisherAdminUsers"
   PathToWebApplicationPackages = "$PathToWebApplicationPackages"
   MeteredSchedulerSupport      = "$MeteredSchedulerSupport"
}


# Create RG if not exists
New-AzResourceGroup -Name $ResourceGroupForDeployment -Location $location -Force

Write-host "📜  Deploying the ARM template to set up resources"
# Deploy resources using ARM template

New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupForDeployment -TemplateFile $PathToARMTemplate -TemplateParameterObject $ARMTemplateParams


# Deploy Code and database schema
Write-host "📜  Deploying the database schema"
$ServerUri = $SQLServerName+".database.windows.net"
Invoke-Sqlcmd -ServerInstance $ServerUri -database "AMPSaaSDB" -Username $SQLAdminLogin -Password $SQLAdminLoginPassword  -InputFile "../Database/AMP-DB.sql"

Write-host "📜  Deploying the Publisher Code to publisher portal"
$WebAppName=$WebAppNamePrefix+"-admin"
Publish-AzWebApp -ResourceGroupName "$ResourceGroupForDeployment" -Name "$WebAppName"  -ArchivePath "./Commercial-Marketplace-SaaS-Accelerator/Publish/PublisherPortal.zip" -Force

Write-host "📜  Deploying the Customer Code to Customer portal"
$WebAppName=$WebAppNamePrefix+"-portal"
Publish-AzWebApp -ResourceGroupName "$ResourceGroupForDeployment" -Name "$WebAppName" -ArchivePath  "./Commercial-Marketplace-SaaS-Accelerator/Publish/CustomerPortal.zip" -Force

Write-host "🧹  Cleaning things up!"
# Cleanup : Delete the temporary storage account and the resource group created to host the bacpac file.
Remove-Item -path ["..\..\Publish"] -recurse -Force

Write-host "🏁  If the intallation completed without error complete the folllowing checklist:"
if ($ISADMTApplicationIDProvided) {  #If provided then show the user where to add the landing page in AAD, otherwise script did this already for the user.
Write-host "__ Add The following URLs to the multi-tenant AAD App Registration in Azure Portal:"
Write-host "   https://$WebAppNamePrefix-portal.azurewebsites.net"
Write-host "   https://$WebAppNamePrefix-portal.azurewebsites.net/"
Write-host "   https://$WebAppNamePrefix-portal.azurewebsites.net/Home/Index"
Write-host "   https://$WebAppNamePrefix-portal.azurewebsites.net/Home/Index/"
Write-host "   https://$WebAppNamePrefix-admin.azurewebsites.net"
Write-host "   https://$WebAppNamePrefix-admin.azurewebsites.net/"
Write-host "   https://$WebAppNamePrefix-admin.azurewebsites.net/Home/Index"
Write-host "   https://$WebAppNamePrefix-admin.azurewebsites.net/Home/Index/"
Write-host "__ Verify ID Tokens checkbox has been checked-out ✅"
}

Write-host "__ Add The following URL in PartnerCenter SaaS Technical Configuration->Landing Page section"
Write-host "   https://$WebAppNamePrefix-portal.azurewebsites.net/"
Write-host "__ Add The following URL in PartnerCenter SaaS Technical Configuration->Connection Webhook section"
Write-host "   https://$WebAppNamePrefix-portal.azurewebsites.net/api/AzureWebhook"
Write-host "__ Add The following TenantID in PartnerCenter SaaS Technical Configuration Tenant ID"
Write-host "   $TenantID"
Write-host "__ Add The following ApplicationID in PartnerCenter SaaS Technical Configuration->AAD Application ID section"
Write-host "   $ADApplicationID"
