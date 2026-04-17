<#
    .SYNOPSIS
        Deploys the disabled-account audit Azure Automation solution.

    PREREQUISITES
        - Az PowerShell module  (Install-Module Az -Scope CurrentUser)
        - Connected to Azure    (Connect-AzAccount)
        - A Microsoft 365 mailbox for the sender (the Managed Identity needs Mail.Send
          on that specific mailbox — see STEP 5 comments)

    USAGE
        Edit the CONFIGURATION block below, then run this script once.
#>

#region --- CONFIGURATION --- edit these values before running ---

$subscriptionId     = 'YOUR_SUBSCRIPTION_ID'
$resourceGroupName  = 'rg-automation-audit'
$location           = 'eastus'                        # Azure region

$automationAccountName = 'aa-disabled-user-audit'

# Entra ID group to audit
$groupObjectId      = 'YOUR_GROUP_OBJECT_ID'

# M365 mailbox that will send the report (must have an Exchange Online license)
$senderMailbox      = 'automation-alerts@yourdomain.com'

# Where the report gets delivered
$recipientEmail     = 'caseyabbott.dev@outlook.com'

# Schedule — runs weekly on Monday at 07:00 UTC
$scheduleStartTime  = (Get-Date).Date.AddDays((1 - (Get-Date).DayOfWeek.value__ + 7) % 7 + 7).AddHours(7)

$runbookPath        = Join-Path $PSScriptRoot '..\runbook\Get-DisabledGroupMembers.ps1'

#endregion

Set-AzContext -SubscriptionId $subscriptionId | Out-Null

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
    -AssignSystemIdentity   # enables System-assigned Managed Identity

$principalId = $aa.Identity.PrincipalId
Write-Host "  Managed Identity principal ID: $principalId"

#endregion

#region STEP 3 — Automation Variables

Write-Host "Setting Automation Variables..." -ForegroundColor Cyan

$vars = @{
    GroupObjectId   = $groupObjectId
    SenderMailbox   = $senderMailbox
    RecipientEmail  = $recipientEmail
    TenantId        = (Get-AzContext).Tenant.Id
}

foreach ($kv in $vars.GetEnumerator()) {
    New-AzAutomationVariable `
        -ResourceGroupName $resourceGroupName `
        -AutomationAccountName $automationAccountName `
        -Name $kv.Key `
        -Value $kv.Value `
        -Encrypted $false | Out-Null
}

#endregion

#region STEP 4 — Upload Runbook

Write-Host "Importing runbook..." -ForegroundColor Cyan

Import-AzAutomationRunbook `
    -ResourceGroupName $resourceGroupName `
    -AutomationAccountName $automationAccountName `
    -Name 'Get-DisabledGroupMembers' `
    -Path (Resolve-Path $runbookPath) `
    -Type PowerShell `
    -Force | Out-Null

Publish-AzAutomationRunbook `
    -ResourceGroupName $resourceGroupName `
    -AutomationAccountName $automationAccountName `
    -Name 'Get-DisabledGroupMembers'

#endregion

#region STEP 5 — Graph API Permissions for the Managed Identity

Write-Host "Assigning Microsoft Graph permissions to Managed Identity..." -ForegroundColor Cyan
Write-Host "  (requires AzureAD or Microsoft.Graph module)" -ForegroundColor Yellow

# Permissions needed:
#   GroupMember.Read.All  — read group membership
#   User.Read.All         — read user accountEnabled property
#   Mail.Send             — send email as the sender mailbox
#
# Run the block below ONCE. It uses the Microsoft.Graph module.
# Install-Module Microsoft.Graph -Scope CurrentUser

Connect-MgGraph -Scopes 'AppRoleAssignment.ReadWrite.All', 'Application.Read.All' | Out-Null

$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"

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

#region STEP 6 — Schedule

Write-Host "Creating weekly schedule (Mondays 07:00 UTC)..." -ForegroundColor Cyan

$schedule = New-AzAutomationSchedule `
    -ResourceGroupName $resourceGroupName `
    -AutomationAccountName $automationAccountName `
    -Name 'Weekly-Monday-0700' `
    -StartTime $scheduleStartTime `
    -WeekInterval 1 `
    -DaysOfWeek Monday `
    -TimeZone 'UTC'

Register-AzAutomationScheduledRunbook `
    -ResourceGroupName $resourceGroupName `
    -AutomationAccountName $automationAccountName `
    -RunbookName 'Get-DisabledGroupMembers' `
    -ScheduleName 'Weekly-Monday-0700' | Out-Null

#endregion

Write-Host "`nDeployment complete." -ForegroundColor Green
Write-Host "Test the runbook: Start-AzAutomationRunbook -ResourceGroupName $resourceGroupName -AutomationAccountName $automationAccountName -Name 'Get-DisabledGroupMembers'"
