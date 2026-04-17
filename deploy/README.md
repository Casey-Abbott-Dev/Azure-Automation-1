# Deployment — Deploy-AzureAutomation.ps1

This script provisions the entire solution in your Azure subscription in a single run. It is safe to run more than once — existing resources are updated rather than duplicated (except Graph role assignments, which are skipped if already present).

---

## What the Script Deploys (in order)

| Step | What happens |
|---|---|
| 1 | Creates the **Resource Group** `rg-automation-audit` |
| 2 | Creates the **Automation Account** `aa-disabled-user-audit` with a System-assigned Managed Identity |
| 3 | Creates four **Automation Variables** (GroupObjectId, SenderMailbox, RecipientEmail, TenantId) |
| 4 | Imports and **publishes the runbook** from `../runbook/Get-DisabledGroupMembers.ps1` |
| 5 | Assigns three **Graph API application permissions** to the Managed Identity |
| 6 | Creates a **weekly schedule** (Mondays 07:00 UTC) and links it to the runbook |

---

## Before You Run

### 1. Install required PowerShell modules

```powershell
Install-Module Az                -Scope CurrentUser -Force
Install-Module Microsoft.Graph   -Scope CurrentUser -Force
```

### 2. Fill in the CONFIGURATION block

Open `Deploy-AzureAutomation.ps1` and update these lines near the top:

```powershell
$subscriptionId     = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'   # Azure Subscription ID
$groupObjectId      = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'   # Entra ID Group Object ID
$senderMailbox      = 'alerts@yourdomain.com'                  # M365 licensed sender mailbox
$recipientEmail     = 'you@yourdomain.com'                     # Report recipient
$location           = 'eastus'                                  # Azure region
```

**Where to find each value:**

| Value | Where to find it |
|---|---|
| `$subscriptionId` | Azure Portal → Subscriptions → copy **Subscription ID** |
| `$groupObjectId` | Entra ID → Groups → select group → copy **Object ID** |
| `$senderMailbox` | Any UPN in your tenant that has an Exchange Online mailbox |
| `$recipientEmail` | The email address that should receive the audit reports |

---

## Running the Script

```powershell
# 1. Sign in to Azure
Connect-AzAccount

# 2. (Optional) Confirm you're on the right subscription
Get-AzContext | Select-Object Name, Account, Subscription

# 3. Run the deployment
cd C:\code\AzureAutomation-1
.\deploy\Deploy-AzureAutomation.ps1
```

Expected output:
```
Creating resource group 'rg-automation-audit'...
Creating Automation Account 'aa-disabled-user-audit'...
  Managed Identity principal ID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
Setting Automation Variables...
Importing runbook...
Assigning Microsoft Graph permissions to Managed Identity...
  Granted: GroupMember.Read.All
  Granted: User.Read.All
  Granted: Mail.Send
Creating weekly schedule (Mondays 07:00 UTC)...

Deployment complete.
Test the runbook: Start-AzAutomationRunbook ...
```

---

## Post-Deployment: Grant Admin Consent

The Graph API permissions are assigned programmatically, but a **Global Administrator** must grant admin consent before they activate:

1. **Azure Portal** → **Entra ID** → **Enterprise Applications**
2. Set filter to **All Applications** and search for `aa-disabled-user-audit`
3. Click the app → **Permissions** (left menu)
4. Click **Grant admin consent for {your tenant name}**
5. Confirm in the dialog

> Without this step the runbook will fail with `401 Unauthorized` on the first Graph API call.

---

## Verifying the Deployment

```powershell
# Check Automation Account exists
Get-AzAutomationAccount -ResourceGroupName 'rg-automation-audit' -Name 'aa-disabled-user-audit'

# Check Automation Variables were created
Get-AzAutomationVariable -ResourceGroupName 'rg-automation-audit' -AutomationAccountName 'aa-disabled-user-audit'

# Check runbook is published
Get-AzAutomationRunbook -ResourceGroupName 'rg-automation-audit' -AutomationAccountName 'aa-disabled-user-audit' -Name 'Get-DisabledGroupMembers'
# State should show: Published

# Check schedule is linked
Get-AzAutomationScheduledRunbook -ResourceGroupName 'rg-automation-audit' -AutomationAccountName 'aa-disabled-user-audit' -RunbookName 'Get-DisabledGroupMembers'
```

---

## Tearing Down the Deployment

To remove everything this script created:

```powershell
Remove-AzResourceGroup -Name 'rg-automation-audit' -Force
```

> This permanently deletes the Automation Account, all runbooks, variables, schedules, and job history. The Managed Identity's Graph permissions will also be removed automatically.
