# Runbook — Get-DisabledGroupMembers

This PowerShell runbook is the core logic of the audit solution. It runs inside Azure Automation, authenticates via the Automation Account's **System-assigned Managed Identity**, reads all sensitive configuration from **Azure Key Vault**, then queries Entra ID and sends a report email via Microsoft Graph.

---

## What the Runbook Does

```
Start
  │
  ├─ 1. Acquire two tokens via Managed Identity (IMDS)
  │       ├─ Token A: https://vault.azure.net     (Key Vault)
  │       └─ Token B: https://graph.microsoft.com (Graph API)
  │
  ├─ 2. Read KeyVaultName from the single Automation Variable
  │
  ├─ 3. Read four secrets from Key Vault
  │       ├─ group-object-id
  │       ├─ sender-mailbox
  │       ├─ recipient-email
  │       └─ tenant-id
  │
  ├─ 4. Page through all members of the target Entra ID group
  │       GET /v1.0/groups/{id}/members
  │       Handles @odata.nextLink pagination automatically
  │
  ├─ 5. Filter to members where accountEnabled = false
  │
  ├─ 6. Build HTML email
  │       ├─ If disabled count = 0  →  "No issues found" message
  │       └─ If disabled count > 0  →  HTML table (DisplayName / UPN / ObjectId)
  │
  └─ 7. Send email via Graph API
          POST /v1.0/users/{senderMailbox}/sendMail
```

---

## Configuration

### Automation Variable (non-sensitive)

Only one Automation Variable is needed — it tells the runbook where to find the Key Vault. It is not encrypted because a Key Vault name is not a secret.

| Variable Name | Type | Encrypted | Example Value |
|---|---|---|---|
| `KeyVaultName` | String | No | `kv-auto-audit-001` |

**Portal:** Automation Account → **Variables** → **Add a variable**

### Key Vault Secrets

All sensitive values live in Azure Key Vault. The runbook reads them at runtime using the Managed Identity token. Secret names use lowercase and hyphens (Key Vault naming requirement).

| Secret Name | Example Value | Purpose |
|---|---|---|
| `group-object-id` | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` | Entra ID group to audit |
| `sender-mailbox` | `alerts@contoso.com` | M365 mailbox that sends the report |
| `recipient-email` | `admin@contoso.com` | Address that receives the report |
| `tenant-id` | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` | Azure AD tenant ID |

**Portal:** Key Vault → **Secrets** → **Generate/Import**

To update a secret value via PowerShell:
```powershell
$newValue = ConvertTo-SecureString 'new-value-here' -AsPlainText -Force
Set-AzKeyVaultSecret -VaultName 'kv-auto-audit-001' -Name 'recipient-email' -SecretValue $newValue
```

---

## Required Permissions

### Managed Identity — Key Vault

| Role | Scope | Can it be narrowed further? |
|---|---|---|
| `Key Vault Secrets User` | This specific Key Vault only | **Already minimum.** Grants `Get` and `ReadMetadata` on secrets only — cannot create, update, or delete. Scoped to the vault resource, not the subscription. |

### Managed Identity — Microsoft Graph (Application permissions)

All three permissions are application-level (no signed-in user) and require **admin consent**.

| Permission | Why it is required | Can it be narrowed further? |
|---|---|---|
| `GroupMember.Read.All` | The runbook calls `GET /groups/{id}/members` to list group members. | **No.** Graph has no per-group application scope. `GroupMember.Read.All` is already narrower than `Group.Read.All` (which also exposes group settings and metadata) and far narrower than `Directory.Read.All`. |
| `User.Read.All` | The `accountEnabled` property is a user attribute. Graph requires this permission to return it, even when the user is fetched via the group members endpoint. | **No.** The alternatives (`Directory.Read.All`) are all broader. The runbook minimises exposure by using `$select=id,displayName,userPrincipalName,accountEnabled` — only four fields are ever returned. |
| `Mail.Send` | The runbook calls `POST /users/{sender}/sendMail` to deliver the report. | **Yes — see below.** As an application permission this grants the ability to send as *any* user in the tenant. An Exchange Online Application Access Policy restricts it to the sender mailbox only. |

### Restricting Mail.Send with an Application Access Policy

Without a policy, `Mail.Send` is tenant-wide. Apply the restriction once after deployment:

```powershell
# Requires Exchange Online admin rights
Install-Module ExchangeOnlineManagement -Scope CurrentUser
Connect-ExchangeOnline

# Create a distribution group containing only the sender mailbox
New-DistributionGroup -Name 'dl-automation-senders' -Members 'alerts@yourdomain.com'

# Lock the SAMI to that group only (use the App ID printed at end of deployment)
New-ApplicationAccessPolicy `
    -AppId              'YOUR_SAMI_APP_ID' `
    -PolicyScopeGroupId 'dl-automation-senders' `
    -AccessRight        RestrictAccess `
    -Description        'Restrict automation SAMI to sender mailbox only'

# Verify — should return: AccessCheckResult : Granted
Test-ApplicationAccessPolicy -AppId 'YOUR_SAMI_APP_ID' -Identity 'alerts@yourdomain.com'

# Verify a mailbox NOT in the group is blocked — should return: AccessCheckResult : Denied
Test-ApplicationAccessPolicy -AppId 'YOUR_SAMI_APP_ID' -Identity 'other.user@yourdomain.com'
```

> The deployment script (Step 10) prints the SAMI's AppId and these exact commands for you.

---

## Email Output Examples

**When disabled accounts are found:**

> Subject: `[Azure Automation] Disabled Account Audit - 3 Disabled User(s) Found (2026-04-17 07:00 UTC)`

An HTML table is included: Display Name, UPN, Object ID.

**When no disabled accounts are found:**

> Subject: `[Azure Automation] Disabled Account Audit - No Issues Found (2026-04-17 07:00 UTC)`

A confirmation is always sent so you know the job ran successfully.

---

## Modifying the Runbook

To edit and redeploy locally:
```powershell
# After editing Get-DisabledGroupMembers.ps1 locally:
Import-AzAutomationRunbook `
    -ResourceGroupName     'rg-automation-audit' `
    -AutomationAccountName 'aa-disabled-user-audit' `
    -Name                  'Get-DisabledGroupMembers' `
    -Path                  '.\runbook\Get-DisabledGroupMembers.ps1' `
    -Type                  PowerShell `
    -Force

Publish-AzAutomationRunbook `
    -ResourceGroupName     'rg-automation-audit' `
    -AutomationAccountName 'aa-disabled-user-audit' `
    -Name                  'Get-DisabledGroupMembers'
```

Or push to the `main` branch — GitHub Actions handles import and publish automatically.

> Changes only take effect after **Publish**. A saved-but-not-published runbook still runs the previous published version.

---

## Viewing Runbook Output

**Portal:** Automation Account → **Jobs** → select a job → **Output** tab

**PowerShell:**
```powershell
$job = Get-AzAutomationJob `
    -ResourceGroupName 'rg-automation-audit' `
    -AutomationAccountName 'aa-disabled-user-audit' `
    -RunbookName 'Get-DisabledGroupMembers' |
    Sort-Object StartTime -Descending |
    Select-Object -First 1

# Output stream
Get-AzAutomationJobOutput `
    -ResourceGroupName 'rg-automation-audit' `
    -AutomationAccountName 'aa-disabled-user-audit' `
    -Id $job.JobId -Stream Output

# Error stream (if job failed)
Get-AzAutomationJobOutput `
    -ResourceGroupName 'rg-automation-audit' `
    -AutomationAccountName 'aa-disabled-user-audit' `
    -Id $job.JobId -Stream Error
```
