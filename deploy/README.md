# Deployment — Deploy-AzureAutomation.ps1

This script provisions the entire solution — including Azure Key Vault — in a single run. It is safe to run more than once; existing resources are updated rather than duplicated.

---

## What Gets Deployed (in order)

| Step | What happens |
|---|---|
| 1 | Creates the **Resource Group** `rg-automation-audit` |
| 2 | Creates the **Automation Account** with a System-assigned Managed Identity |
| 3 | Creates the **Azure Key Vault** with RBAC authorization enabled |
| 4 | Writes all sensitive config as **Key Vault Secrets** |
| 5 | Grants the Managed Identity **Key Vault Secrets User** on the vault |
| 6 | Optionally grants the GitHub Actions SP **Key Vault Secrets Officer** |
| 7 | Creates one **Automation Variable** (`KeyVaultName` — not sensitive) |
| 8 | Imports and **publishes the runbook** |
| 9 | Assigns three **Graph API permissions** to the Managed Identity |
| 10 | Creates a **weekly schedule** (Mondays 07:00 UTC) and links it to the runbook |

---

## Before You Run

### 1. Install required PowerShell modules

```powershell
Install-Module Az              -Scope CurrentUser -Force
Install-Module Microsoft.Graph -Scope CurrentUser -Force
```

### 2. Fill in the CONFIGURATION block (non-sensitive values only)

Open `Deploy-AzureAutomation.ps1` and update the top section. **Only infrastructure values live here** — sensitive values are never stored in the file.

```powershell
$subscriptionId        = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
$keyVaultName          = 'kv-auto-audit-001'    # must be globally unique
$location              = 'eastus'
$githubSpObjectId      = $null                  # optional — see note below
```

**Where to find each value:**

| Value | Where to find it |
|---|---|
| `$subscriptionId` | Azure Portal → Subscriptions → **Subscription ID** |
| `$keyVaultName` | Choose a unique name (3–24 chars, alphanumeric + hyphens) |
| `$githubSpObjectId` | Entra ID → App Registrations → your CI app → **Object ID** (leave `$null` to skip) |

> **Key Vault naming:** Names must be globally unique across all Azure customers. If `kv-auto-audit-001` is taken, try adding your initials or a random suffix (e.g. `kv-auto-audit-cab`).

### 3. Sensitive values — entered at runtime, never stored in the file

When the script runs it will pause and prompt for three values. Input is masked (`Read-Host -AsSecureString`) and passed directly to Key Vault as SecureStrings — the values are never written to disk or visible in the console.

```
Enter sensitive values. Input is masked and never written to disk.
  Entra ID Group Object ID  : ************
  Sender mailbox UPN        : ************
  Recipient email address   : ************
```

**Have these values ready before running:**

| Prompt | What to enter | Where to find it |
|---|---|---|
| Entra ID Group Object ID | GUID of the security group | Entra ID → Groups → select group → **Object ID** |
| Sender mailbox UPN | `alerts@yourdomain.com` | Any UPN with an Exchange Online license |
| Recipient email address | `you@yourdomain.com` | Where you want reports delivered |

---

## Running the Script

```powershell
# 1. Sign in
Connect-AzAccount

# 2. Confirm you're on the right subscription
Get-AzContext | Select-Object Name, Account, Subscription

# 3. Run — the script will prompt for sensitive values before doing anything in Azure
cd C:\code\AzureAutomation-1
.\deploy\Deploy-AzureAutomation.ps1
```

Expected output:
```
Creating resource group 'rg-automation-audit'...
Creating Automation Account 'aa-disabled-user-audit'...
  Managed Identity principal ID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
Creating Key Vault 'kv-auto-audit-001'...
  Key Vault URI: https://kv-auto-audit-001.vault.azure.net/
Writing secrets to Key Vault...
  Stored: group-object-id
  Stored: sender-mailbox
  Stored: recipient-email
  Stored: tenant-id
Granting Managed Identity 'Key Vault Secrets User' role...
  Granted: Key Vault Secrets User → Managed Identity
Setting Automation Variable (KeyVaultName)...
Importing and publishing runbook...
Assigning Microsoft Graph permissions to Managed Identity...
  Granted: GroupMember.Read.All
  Granted: User.Read.All
  Granted: Mail.Send
Creating weekly schedule (Mondays 07:00 UTC)...

Deployment complete.
```

---

## Post-Deployment: Grant Admin Consent

A **Global Administrator** must grant admin consent for the Graph API permissions:

1. **Azure Portal** → **Entra ID** → **Enterprise Applications**
2. Filter to **All Applications**, search for `aa-disabled-user-audit`
3. Click the app → **Permissions** → **Grant admin consent for {tenant}**
4. Confirm in the dialog

> Without this step the runbook fails with `401 Unauthorized` on the first Graph API call.

---

## Key Vault Secrets Reference

All secrets are stored with lowercase, hyphen-separated names:

| Secret Name | Holds |
|---|---|
| `group-object-id` | Entra ID security group Object ID |
| `sender-mailbox` | UPN of the M365 mailbox that sends reports |
| `recipient-email` | Email address that receives reports |
| `tenant-id` | Azure AD tenant ID |

### Updating a Secret After Deployment

```powershell
Connect-AzAccount
$newValue = ConvertTo-SecureString 'new@example.com' -AsPlainText -Force
Set-AzKeyVaultSecret -VaultName 'kv-auto-audit-001' -Name 'recipient-email' -SecretValue $newValue
```

**Portal:** Key Vault → **Secrets** → click the secret → **New Version**

---

## Verifying the Deployment

```powershell
# Automation Account
Get-AzAutomationAccount -ResourceGroupName 'rg-automation-audit' -Name 'aa-disabled-user-audit'

# Key Vault exists and has secrets
Get-AzKeyVaultSecret -VaultName 'kv-auto-audit-001' | Select-Object Name, Enabled

# Automation Variable
Get-AzAutomationVariable -ResourceGroupName 'rg-automation-audit' -AutomationAccountName 'aa-disabled-user-audit'

# Runbook is Published
Get-AzAutomationRunbook -ResourceGroupName 'rg-automation-audit' -AutomationAccountName 'aa-disabled-user-audit' -Name 'Get-DisabledGroupMembers'

# Schedule is linked
Get-AzAutomationScheduledRunbook -ResourceGroupName 'rg-automation-audit' -AutomationAccountName 'aa-disabled-user-audit' -RunbookName 'Get-DisabledGroupMembers'
```

---

## Tearing Down

```powershell
# Soft-delete Key Vault secrets are retained for 90 days by default.
# Purge first if you want to reuse the same vault name immediately.
Remove-AzKeyVault -VaultName 'kv-auto-audit-001' -ResourceGroupName 'rg-automation-audit' -Force
Remove-AzKeyVault -VaultName 'kv-auto-audit-001' -InRemovedState -Location 'eastus' -Force

# Then remove everything else
Remove-AzResourceGroup -Name 'rg-automation-audit' -Force
```
