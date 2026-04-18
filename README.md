# Azure Automation — Disabled Entra ID User Audit

Automatically reports disabled Azure AD (Entra ID) accounts found inside a specified security group. Runs on a weekly schedule and delivers an HTML email report using Microsoft Graph API — no third-party services required.

---

## How It Works

```
Azure Automation (Weekly Schedule)
        │
        ▼
  PowerShell Runbook
        │
        ├─► Graph API: GET /groups/{id}/members
        │         Filter: accountEnabled = false
        │
        └─► Graph API: POST /users/{sender}/sendMail
                  Delivers HTML report to recipient
```

1. The runbook authenticates using the Automation Account's **System-assigned Managed Identity** — no passwords or secrets to manage.
2. It pages through all members of the target Entra ID security group.
3. Any member whose `accountEnabled` property is `false` is flagged.
4. An HTML email is sent via the Microsoft Graph `/sendMail` endpoint.
5. If no disabled accounts are found, a clean-bill-of-health email is still sent.

---

## Project Structure

```
AzureAutomation-1/
├── README.md                              ← you are here
├── runbook/
│   ├── Get-DisabledGroupMembers.ps1       ← the Automation runbook
│   └── README.md                          ← runbook internals & variables
└── deploy/
    ├── Deploy-AzureAutomation.ps1         ← one-shot deployment script
    └── README.md                          ← deployment walkthrough
```

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Azure subscription | Contributor access on the target subscription |
| Az PowerShell module | `Install-Module Az -Scope CurrentUser` |
| Microsoft.Graph module | `Install-Module Microsoft.Graph -Scope CurrentUser` |
| Microsoft 365 mailbox | A UPN with an Exchange Online license used as the sender |
| Entra ID security group | Note the **Object ID** from Entra ID > Groups |

---

## Quick Start

### Step 1 — Clone / download this repo

```powershell
cd C:\code\AzureAutomation-1
```

### Step 2 — Edit the configuration block

Open `deploy/Deploy-AzureAutomation.ps1` and fill in the `CONFIGURATION` section at the top:

```powershell
$subscriptionId = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
$keyVaultName   = 'kv-auto-audit-001'   # must be globally unique
```

Sensitive values (`groupObjectId`, `senderMailbox`, `recipientEmail`) are **not in the file** — the script will prompt for them at runtime with masked input and write them directly to Key Vault as SecureStrings.

> **Key Vault name:** Must be globally unique across Azure (3–24 chars, alphanumeric + hyphens). If the name is taken, add a short suffix like your initials (e.g. `kv-auto-audit-cab`).

### Step 3 — Connect to Azure and run the deployment

```powershell
# Connect to Azure
Connect-AzAccount

# Run the deployment (takes ~2 minutes)
.\deploy\Deploy-AzureAutomation.ps1
```

The script will output progress at each step and print a test command when done.

### Step 4 — Approve the Graph API permissions

After the script runs, a Global Administrator must **grant admin consent** for the Graph API permissions assigned to the Managed Identity:

1. Azure Portal → **Entra ID** → **Enterprise Applications**
2. Search for your Automation Account name
3. Go to **Permissions** → **Grant admin consent for {tenant}**

> This step is required before the runbook can query users or send mail.

---

## What Gets Deployed

| Resource | Name | Notes |
|---|---|---|
| Resource Group | `rg-automation-audit` | Created in the region you specify |
| Automation Account | `aa-disabled-user-audit` | System-assigned Managed Identity enabled |
| Key Vault | `kv-auto-audit-001` | RBAC-mode; holds all sensitive config |
| Key Vault Secrets | 4 secrets | group-object-id, sender-mailbox, recipient-email, tenant-id |
| Runbook | `Get-DisabledGroupMembers` | PowerShell 5.1, published and ready |
| Schedule | `Weekly-Monday-0700` | Every Monday at 07:00 UTC |
| Automation Variable | 1 variable | `KeyVaultName` only (not sensitive) |
| Graph API Permissions | 3 app roles | GroupMember.Read.All, User.Read.All, Mail.Send |

---

## Triggering the Runbook Manually (Testing)

### Option A — Azure Portal

1. Go to **Azure Portal** → **Automation Accounts** → `aa-disabled-user-audit`
2. Click **Runbooks** in the left menu
3. Click **Get-DisabledGroupMembers**
4. Click **Start** at the top
5. Click **Start** again on the parameters blade (no parameters needed)
6. You will be redirected to the **Job** page — click **Output** to see logs

### Option B — PowerShell

```powershell
Connect-AzAccount

$job = Start-AzAutomationRunbook `
    -ResourceGroupName     'rg-automation-audit' `
    -AutomationAccountName 'aa-disabled-user-audit' `
    -Name                  'Get-DisabledGroupMembers'

# Wait for completion and show output
do { Start-Sleep 5; $status = (Get-AzAutomationJob -ResourceGroupName 'rg-automation-audit' -AutomationAccountName 'aa-disabled-user-audit' -Id $job.JobId).Status }
while ($status -notin 'Completed','Failed','Stopped')

Get-AzAutomationJobOutput `
    -ResourceGroupName     'rg-automation-audit' `
    -AutomationAccountName 'aa-disabled-user-audit' `
    -Id                    $job.JobId `
    -Stream                Output
```

### Option C — Azure CLI

```bash
az automation runbook start \
  --resource-group rg-automation-audit \
  --automation-account-name aa-disabled-user-audit \
  --name Get-DisabledGroupMembers
```

---

## Viewing Job History

**Portal:** Automation Account → **Jobs** — shows every run with status, start time, and duration.

**PowerShell:**
```powershell
Get-AzAutomationJob `
    -ResourceGroupName     'rg-automation-audit' `
    -AutomationAccountName 'aa-disabled-user-audit' `
    -RunbookName           'Get-DisabledGroupMembers' |
    Sort-Object StartTime -Descending |
    Select-Object -First 10 JobId, Status, StartTime, EndTime
```

---

## Changing the Schedule

The default schedule is **every Monday at 07:00 UTC**. To change it:

**Portal:** Automation Account → **Schedules** → `Weekly-Monday-0700` → edit start time / recurrence.

**PowerShell (replace with a daily 8am UTC schedule):**
```powershell
# Remove the existing schedule link
Unregister-AzAutomationScheduledRunbook `
    -ResourceGroupName 'rg-automation-audit' `
    -AutomationAccountName 'aa-disabled-user-audit' `
    -RunbookName 'Get-DisabledGroupMembers' `
    -ScheduleName 'Weekly-Monday-0700' -Force

# Create a new daily schedule
New-AzAutomationSchedule `
    -ResourceGroupName 'rg-automation-audit' `
    -AutomationAccountName 'aa-disabled-user-audit' `
    -Name 'Daily-0800' `
    -StartTime ((Get-Date).Date.AddDays(1).AddHours(8)) `
    -DayInterval 1 `
    -TimeZone 'UTC'

# Link it to the runbook
Register-AzAutomationScheduledRunbook `
    -ResourceGroupName 'rg-automation-audit' `
    -AutomationAccountName 'aa-disabled-user-audit' `
    -RunbookName 'Get-DisabledGroupMembers' `
    -ScheduleName 'Daily-0800'
```

---

## Cost Estimate

| Service | Free tier | Expected usage | Monthly cost |
|---|---|---|---|
| Azure Automation | 500 job-minutes/month free | ~1 min/week = ~4 min/month | **$0.00** |
| Microsoft Graph API | Always free | Read + send calls | **$0.00** |
| Exchange Online mailbox | Existing M365 license | Re-uses existing mailbox | **$0.00** |

**Total estimated cost: $0.00/month** (assuming an existing M365 subscription).

---

## CI/CD — GitHub to Azure Automation

The workflow at `.github/workflows/deploy-runbook.yml` automatically deploys your runbook to Azure Automation whenever you push changes to `runbook/*.ps1` on `main`. It uses **OIDC (Workload Identity Federation)** — no client secrets stored in GitHub.

```
Push to main
     │
     ▼
GitHub Actions Workflow
     │
     ├─ azure/login (OIDC — no secrets)
     ├─ az automation runbook replace-content
     ├─ az automation runbook publish
     └─ Verify state = Published
```

### One-Time Setup

#### 1. Create an App Registration in Entra ID

```powershell
Connect-AzAccount

# Create the app registration
$app = New-AzADApplication -DisplayName 'github-automation-deployer'
$sp  = New-AzADServicePrincipal -ApplicationId $app.AppId

# Grant Contributor on the resource group (scoped — not whole subscription)
New-AzRoleAssignment `
    -ObjectId            $sp.Id `
    -RoleDefinitionName  'Contributor' `
    -ResourceGroupName   'rg-automation-audit'

Write-Host "Client ID : $($app.AppId)"
Write-Host "Tenant ID : $((Get-AzContext).Tenant.Id)"
Write-Host "Sub ID    : $((Get-AzContext).Subscription.Id)"
```

#### 2. Add a Federated Credential (OIDC — no secrets needed)

```powershell
$params = @{
    ApplicationObjectId = $app.Id
    Audience            = @('api://AzureADTokenExchange')
    Issuer              = 'https://token.actions.githubusercontent.com'
    Subject             = 'repo:YOUR_GITHUB_USERNAME/AzureAutomation-1:ref:refs/heads/main'
    Name                = 'github-main-branch'
}
New-AzADAppFederatedCredential @params
```

> Replace `YOUR_GITHUB_USERNAME` with your actual GitHub username or org name.

#### 3. Add GitHub Repository Secrets

In your GitHub repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**:

| Secret name | Value |
|---|---|
| `AZURE_CLIENT_ID` | App Registration **Application (client) ID** |
| `AZURE_TENANT_ID` | Your **Tenant ID** |
| `AZURE_SUBSCRIPTION_ID` | Your **Subscription ID** |

#### 4. Push a change to trigger the workflow

Edit anything in `runbook/Get-DisabledGroupMembers.ps1`, commit, and push to `main`. The workflow runs automatically.

To watch it: **GitHub repo** → **Actions** tab → select the running workflow.

### Triggering the Workflow Manually (without a code change)

**GitHub UI:**
1. Go to your repo → **Actions** tab
2. Click **Deploy Runbook to Azure Automation** in the left list
3. Click **Run workflow** → select branch `main` → click **Run workflow**

**GitHub CLI:**
```bash
gh workflow run deploy-runbook.yml --ref main
gh run watch   # stream live output
```

---

## Managing Key Vault Secrets

All sensitive configuration lives in Azure Key Vault. The Automation runbook reads secrets at runtime using its Managed Identity — no credentials are stored in the Automation Account or in code.

### Secret names and what they hold

| Secret Name | Purpose |
|---|---|
| `group-object-id` | Object ID of the Entra ID security group to audit |
| `sender-mailbox` | UPN of the M365 mailbox that sends the report |
| `recipient-email` | Email address that receives the report |
| `tenant-id` | Azure AD tenant ID |

### Viewing secrets (Portal)

1. **Azure Portal** → **Key Vaults** → `kv-auto-audit-001`
2. Click **Secrets** in the left menu
3. Click any secret name to see its versions and current value

### Updating a secret value

**Portal:** Key Vault → Secrets → click the secret → **New Version** → enter new value → **Create**

**PowerShell:**
```powershell
Connect-AzAccount
$newValue = ConvertTo-SecureString 'new@example.com' -AsPlainText -Force
Set-AzKeyVaultSecret -VaultName 'kv-auto-audit-001' -Name 'recipient-email' -SecretValue $newValue
```

The runbook always reads the **latest enabled version** of each secret, so changes take effect on the next job run with no redeployment needed.

### Who can read/write secrets

| Identity | Role | Granted by |
|---|---|---|
| Automation Account Managed Identity | `Key Vault Secrets User` (read-only) | Deployment script Step 5 |
| You (deployment user) | `Key Vault Secrets Officer` (read/write) | Deployment script Step 4 |
| GitHub Actions SP (optional) | `Key Vault Secrets Officer` (read/write) | Deployment script Step 6 |

To grant another user read access:
```powershell
New-AzRoleAssignment `
    -SignInName         'colleague@yourdomain.com' `
    -RoleDefinitionName 'Key Vault Secrets User' `
    -Scope              (Get-AzKeyVault -VaultName 'kv-auto-audit-001').ResourceId
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Job fails with `401 Unauthorized` on Graph | Admin consent not granted | Complete Step 4 above |
| Job fails with `401 Unauthorized` on Key Vault | Managed Identity missing KV role | Re-run Step 5 of the deployment script |
| Job fails with `Secret not found` | Secret name typo or missing secret | Check Key Vault → Secrets; names must match exactly |
| Job fails with `Resource not found` | Wrong Group Object ID | Update `group-object-id` secret in Key Vault |
| Job fails with `Variable not found` | `KeyVaultName` Automation Variable missing | Re-run the deployment script or add it manually |
| Email not received | Sender mailbox has no Exchange Online license | Assign an M365 license to the sender UPN |
| No output in job logs | Runbook not published | Push a change to trigger GitHub Actions, or publish via Portal |
