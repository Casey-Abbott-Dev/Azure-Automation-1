# Runbook — Get-DisabledGroupMembers

This PowerShell runbook is the core logic of the audit solution. It runs inside Azure Automation and has no interactive parameters — all configuration is read from **Automation Variables** at runtime.

---

## What the Runbook Does

```
Start
  │
  ├─ 1. Authenticate via Managed Identity (IMDS token endpoint)
  │
  ├─ 2. Read four Automation Variables
  │
  ├─ 3. Page through all members of the target Entra ID group
  │       GET /v1.0/groups/{id}/members?$select=id,displayName,userPrincipalName,accountEnabled
  │       Handles @odata.nextLink pagination automatically
  │
  ├─ 4. Filter to members where accountEnabled = false
  │
  ├─ 5. Build HTML email
  │       ├─ If disabled count = 0  →  "No issues found" message
  │       └─ If disabled count > 0  →  HTML table with DisplayName / UPN / ObjectId
  │
  └─ 6. Send email via Graph API
          POST /v1.0/users/{senderMailbox}/sendMail
```

---

## Required Automation Variables

These must exist in the Automation Account before the runbook runs. The deployment script creates them automatically. You can also set them manually via:

**Portal:** Automation Account → **Variables** → **Add a variable**

| Variable Name | Type | Encrypted | Example Value |
|---|---|---|---|
| `GroupObjectId` | String | No | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `SenderMailbox` | String | No | `alerts@contoso.com` |
| `RecipientEmail` | String | No | `admin@contoso.com` |
| `TenantId` | String | No | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |

> **Tip:** If your sender mailbox UPN is sensitive, change `Encrypted` to `$true` in the deployment script. The runbook reads it the same way either way.

---

## Required Graph API Permissions (Application)

These are granted to the Automation Account's **Managed Identity** (not a user):

| Permission | Purpose |
|---|---|
| `GroupMember.Read.All` | List all members of the target security group |
| `User.Read.All` | Read the `accountEnabled` property on each user |
| `Mail.Send` | Send email as the sender mailbox |

> All three are **application permissions** (no signed-in user required). They require **admin consent** — see the root README Step 4.

---

## Email Output Examples

**When disabled accounts are found:**

> Subject: `[Azure Automation] Disabled Account Audit - 3 Disabled User(s) Found (2026-04-17 07:00 UTC)`

An HTML table is included with columns: Display Name, UPN, Object ID.

**When no disabled accounts are found:**

> Subject: `[Azure Automation] Disabled Account Audit - No Issues Found (2026-04-17 07:00 UTC)`

A short confirmation message is sent so you always know the job ran successfully.

---

## Modifying the Runbook

To edit the runbook after deployment:

**Portal:**
1. Automation Account → **Runbooks** → `Get-DisabledGroupMembers`
2. Click **Edit**
3. Make your changes → click **Save** → click **Publish**

**PowerShell (re-import after editing locally):**
```powershell
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

> Changes only take effect after **Publish**. A saved-but-not-published runbook still runs the previous published version.

---

## Viewing Runbook Output

**Portal:** Automation Account → **Jobs** → select a job → **Output** tab

**PowerShell:**
```powershell
# Get the most recent job ID
$job = Get-AzAutomationJob `
    -ResourceGroupName 'rg-automation-audit' `
    -AutomationAccountName 'aa-disabled-user-audit' `
    -RunbookName 'Get-DisabledGroupMembers' |
    Sort-Object StartTime -Descending |
    Select-Object -First 1

# Show output
Get-AzAutomationJobOutput `
    -ResourceGroupName 'rg-automation-audit' `
    -AutomationAccountName 'aa-disabled-user-audit' `
    -Id $job.JobId -Stream Output

# Show errors (if job failed)
Get-AzAutomationJobOutput `
    -ResourceGroupName 'rg-automation-audit' `
    -AutomationAccountName 'aa-disabled-user-audit' `
    -Id $job.JobId -Stream Error
```
