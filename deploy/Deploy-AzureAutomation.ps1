<#
    .SYNOPSIS
        Deploys the disabled-account audit Azure Automation solution with Azure Key Vault.

    PREREQUISITES
        - Az PowerShell module        (Install-Module Az -Scope CurrentUser)
        - Microsoft.Graph module      (Install-Module Microsoft.Graph -Scope CurrentUser)
        - Connected to Azure          (Connect-AzAccount)
        - A Microsoft 365 mailbox for the sender UPN

    USAGE
        Edit the CONFIGURATION block below (non-sensitive values only), then run
        this script once. Sensitive values are prompted at runtime and never stored
        in this file or displayed in the console.
#>

#region --- CONFIGURATION — non-sensitive infrastructure values only ---

$subscriptionId        = 'YOUR_SUBSCRIPTION_ID'
$resourceGroupName     = 'rg-automation-audit'
$location              = 'eastus'
$automationAccountName = 'aa-disabled-user-audit'

# Key Vault name — must be globally unique, 3-24 chars, alphanumeric and hyphens only
$keyVaultName          = 'kv-auto-audit-001'

# Object ID of the GitHub Actions service principal (from the CI/CD setup)
# Set to $null to skip granting GitHub Actions access to Key Vault
$githubSpObjectId      = $null

# Schedule — runs weekly on Monday at 07:00 UTC
$scheduleStartTime     = (Get-Date).Date.AddDays((1 - (Get-Date).DayOfWeek.value__ + 7) % 7 + 7).AddHours(7)

$runbookPath           = Join-Path $PSScriptRoot '..\runbook\Get-DisabledGroupMembers.ps1'

#endregion

Set-AzContext -SubscriptionId $subscriptionId | Out-Null
$tenantId = (Get-AzContext).Tenant.Id

#region --- SENSITIVE INPUTS — prompted once, stored only in Key Vault ---

Write-Host "`nEnter sensitive values. Input is masked and never written to disk." -ForegroundColor Yellow
$secretInputs = [ordered]@{
    'group-object-id' = Read-Host -AsSecureString "  Entra ID Group Object ID  "
    'sender-mailbox'  = Read-Host -AsSecureString "  Sender mailbox UPN        "
    'recipient-email' = Read-Host -AsSecureString "  Recipient email address   "
    'tenant-id'       = ConvertTo-SecureString $tenantId -AsPlainText -Force
}
Write-Host ""

#endregion

#region STEP 1 — Resource Group

Write-Host "Creating resource group '$resourceGroupName'..." -ForegroundColor Cyan
New-AzResourceGroup -Name $resourceGroupName -Location $location -Force | Out-Null

#endregion

#region STEP 2 — Automation Account

Write-Host "Creating Automation Account '$automationAccountName'..." -ForegroundColor Cyan
$aa = New-AzAutomationAccount `
    -ResourceGroupName $resourceGroupName `
    -Name $automationAccountName `
    -Location $location `
    -AssignSystemIdentity

$principalId = $aa.Identity.PrincipalId
Write-Host "  Managed Identity principal ID: $principalId"

#endregion

#region STEP 3 — Key Vault

Write-Host "Creating Key Vault '$keyVaultName'..." -ForegroundColor Cyan

$kv = New-AzKeyVault `
    -Name              $keyVaultName `
    -ResourceGroupName $resourceGroupName `
    -Location          $location `
    -EnableRbacAuthorization $true   # use Azure RBAC instead of legacy access policies

Write-Host "  Key Vault URI: $($kv.VaultUri)"

#endregion

#region STEP 4 — Store Secrets in Key Vault

Write-Host "Writing secrets to Key Vault..." -ForegroundColor Cyan

# Grant the current user Secrets Officer so we can write secrets right now
$currentUserId = (Get-AzADUser -UserPrincipalName (Get-AzContext).Account.Id).Id
New-AzRoleAssignment `
    -ObjectId            $currentUserId `
    -RoleDefinitionName  'Key Vault Secrets Officer' `
    -Scope               $kv.ResourceId | Out-Null

Start-Sleep -Seconds 15   # allow RBAC propagation before writing

foreach ($entry in $secretInputs.GetEnumerator()) {
    Set-AzKeyVaultSecret -VaultName $keyVaultName -Name $entry.Key -SecretValue $entry.Value | Out-Null
    Write-Host "  Stored: $($entry.Key)"
}

#endregion

#region STEP 5 — Grant Managed Identity Read Access to Key Vault

Write-Host "Granting Managed Identity 'Key Vault Secrets User' role..." -ForegroundColor Cyan

New-AzRoleAssignment `
    -ObjectId            $principalId `
    -RoleDefinitionName  'Key Vault Secrets User' `
    -Scope               $kv.ResourceId | Out-Null

Write-Host "  Granted: Key Vault Secrets User → Managed Identity"

#endregion

#region STEP 6 — Grant GitHub Actions SP Access to Key Vault (optional)

if ($githubSpObjectId) {
    Write-Host "Granting GitHub Actions SP 'Key Vault Secrets Officer' role..." -ForegroundColor Cyan
    New-AzRoleAssignment `
        -ObjectId            $githubSpObjectId `
        -RoleDefinitionName  'Key Vault Secrets Officer' `
        -Scope               $kv.ResourceId | Out-Null
    Write-Host "  Granted: Key Vault Secrets Officer → GitHub Actions SP"
} else {
    Write-Host "Skipping GitHub Actions Key Vault role (githubSpObjectId not set)." -ForegroundColor Yellow
}

#endregion

#region STEP 7 — Automation Variable (Key Vault name only — not sensitive)

Write-Host "Setting Automation Variable (KeyVaultName)..." -ForegroundColor Cyan

New-AzAutomationVariable `
    -ResourceGroupName     $resourceGroupName `
    -AutomationAccountName $automationAccountName `
    -Name                  'KeyVaultName' `
    -Value                 $keyVaultName `
    -Encrypted             $false | Out-Null

#endregion

#region STEP 8 — Upload Runbook

Write-Host "Importing and publishing runbook..." -ForegroundColor Cyan

Import-AzAutomationRunbook `
    -ResourceGroupName     $resourceGroupName `
    -AutomationAccountName $automationAccountName `
    -Name                  'Get-DisabledGroupMembers' `
    -Path                  (Resolve-Path $runbookPath) `
    -Type                  PowerShell `
    -Force | Out-Null

Publish-AzAutomationRunbook `
    -ResourceGroupName     $resourceGroupName `
    -AutomationAccountName $automationAccountName `
    -Name                  'Get-DisabledGroupMembers'

#endregion

#region STEP 9 — Graph API Permissions for the Managed Identity

Write-Host "Assigning Microsoft Graph permissions to Managed Identity..." -ForegroundColor Cyan

Connect-MgGraph -Scopes 'AppRoleAssignment.ReadWrite.All', 'Application.Read.All' | Out-Null

$graphSp       = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$requiredRoles = @('GroupMember.Read.All', 'User.Read.All', 'Mail.Send')

foreach ($roleName in $requiredRoles) {
    $role = $graphSp.AppRoles | Where-Object { $_.Value -eq $roleName -and $_.AllowedMemberTypes -contains 'Application' }
    if (-not $role) { Write-Warning "Role $roleName not found"; continue }

    $existing = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $principalId |
                Where-Object { $_.AppRoleId -eq $role.Id }

    if (-not $existing) {
        New-MgServicePrincipalAppRoleAssignment `
            -ServicePrincipalId $principalId `
            -PrincipalId        $principalId `
            -ResourceId         $graphSp.Id `
            -AppRoleId          $role.Id | Out-Null
        Write-Host "  Granted: $roleName"
    } else {
        Write-Host "  Already assigned: $roleName"
    }
}

#endregion

#region STEP 10 — Restrict Mail.Send via Exchange Online Application Access Policy

# Mail.Send as an application permission allows sending as ANY user in the tenant.
# An Application Access Policy scopes it to the sender mailbox only.
# This step requires Exchange Online admin rights and a separate module — it outputs
# the exact commands to run rather than executing them automatically.

$miAppId = (Get-AzADServicePrincipal -ObjectId $principalId).AppId

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
Write-Host "  ACTION REQUIRED — Restrict Mail.Send to the sender mailbox" -ForegroundColor Yellow
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
Write-Host ""
Write-Host "  The Mail.Send permission currently allows this app to send as ANY"
Write-Host "  user in your tenant. Run the following in Exchange Online PowerShell"
Write-Host "  (requires Exchange Online admin) to lock it to one mailbox:"
Write-Host ""
Write-Host "    # 1. Install module if needed"
Write-Host "    Install-Module ExchangeOnlineManagement -Scope CurrentUser"
Write-Host ""
Write-Host "    # 2. Connect"
Write-Host "    Connect-ExchangeOnline"
Write-Host ""
Write-Host "    # 3. Create a distribution group containing only the sender mailbox"
Write-Host "    New-DistributionGroup -Name 'dl-automation-senders' -Members '<sender-mailbox-upn>'"
Write-Host ""
Write-Host "    # 4. Apply the restriction (SAMI App ID: $miAppId)"
Write-Host "    New-ApplicationAccessPolicy ``"
Write-Host "        -AppId             '$miAppId' ``"
Write-Host "        -PolicyScopeGroupId 'dl-automation-senders' ``"
Write-Host "        -AccessRight        RestrictAccess ``"
Write-Host "        -Description        'Restrict automation SAMI to sender mailbox only'"
Write-Host ""
Write-Host "    # 5. Verify"
Write-Host "    Test-ApplicationAccessPolicy -AppId '$miAppId' -Identity '<sender-mailbox-upn>'"
Write-Host "    # Expected: AccessCheckResult : Granted"
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
Write-Host ""

#endregion

#region STEP 11 — Schedule

Write-Host "Creating weekly schedule (Mondays 07:00 UTC)..." -ForegroundColor Cyan

New-AzAutomationSchedule `
    -ResourceGroupName     $resourceGroupName `
    -AutomationAccountName $automationAccountName `
    -Name                  'Weekly-Monday-0700' `
    -StartTime             $scheduleStartTime `
    -WeekInterval          1 `
    -DaysOfWeek            Monday `
    -TimeZone              'UTC' | Out-Null

Register-AzAutomationScheduledRunbook `
    -ResourceGroupName     $resourceGroupName `
    -AutomationAccountName $automationAccountName `
    -RunbookName           'Get-DisabledGroupMembers' `
    -ScheduleName          'Weekly-Monday-0700' | Out-Null

#endregion

Write-Host "`nDeployment complete." -ForegroundColor Green
Write-Host "Key Vault : https://portal.azure.com/#resource$($kv.ResourceId)"
Write-Host "Test run  : Start-AzAutomationRunbook -ResourceGroupName $resourceGroupName -AutomationAccountName $automationAccountName -Name 'Get-DisabledGroupMembers'"
