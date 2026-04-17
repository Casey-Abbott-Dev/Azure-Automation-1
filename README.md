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
$subscriptionId     = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
$groupObjectId      = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'   # Entra ID Group Object ID
$senderMailbox      = 'alerts@yourdomain.com'                  # M365 licensed mailbox
$recipientEmail     = 'you@yourdomain.com'                     # where the report is sent
```

> **Finding your Group Object ID:**
> Azure Portal → Entra ID → Groups → select your group → copy **Object ID** from the Overview blade.

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
| Runbook | `Get-DisabledGroupMembers` | PowerShell 5.1, published and ready |
| Schedule | `Weekly-Monday-0700` | Every Monday at 07:00 UTC |
| Automation Variables | 4 variables | GroupObjectId, SenderMailbox, RecipientEmail, TenantId |
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

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Job fails with `401 Unauthorized` | Admin consent not granted | Complete Step 4 above |
| Job fails with `Resource not found` | Wrong Group Object ID | Check `GroupObjectId` Automation Variable |
| Email not received | Sender mailbox has no Exchange Online license | Assign an M365 license to the sender UPN |
| Job fails with `Variable not found` | Automation Variables missing | Re-run the deployment script or add manually in the Portal |
| No output in job logs | Runbook not published | Publish via Portal or re-run deployment |
