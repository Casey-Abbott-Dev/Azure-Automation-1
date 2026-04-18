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

The Automation Account's Managed Identity needs the **Key Vault Secrets User** role on the Key Vault. This is scoped to the Key Vault resource only (not the whole subscription).

| Role | Scope | Purpose |
|---|---|---|
| `Key Vault Secrets User` | Key Vault resource | Read secrets at runtime |

### Managed Identity — Microsoft Graph (Application permissions)

| Permission | Purpose |
|---|---|
| `GroupMember.Read.All` | List all members of the target security group |
| `User.Read.All` | Read the `accountEnabled` property on each user |
| `Mail.Send` | Send email as the sender mailbox |

All three require **admin consent** — see root README Step 4.

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
