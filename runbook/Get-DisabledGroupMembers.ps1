<#
    .SYNOPSIS
        Reports disabled Entra ID accounts found in a specified security group.
        Runs under the Automation Account's System-assigned Managed Identity.

    REQUIRED Automation Variables (encrypted where noted):
        GroupObjectId        - Object ID of the Entra ID security group to audit
        SenderMailbox        - UPN of the M365 mailbox used to send the report (e.g. alerts@contoso.com)
        RecipientEmail       - Email address to receive the report
        TenantId             - Azure AD tenant ID
#>

param()

#region --- Auth via Managed Identity ---

$resourceUrl = 'https://graph.microsoft.com'

$tokenResponse = Invoke-RestMethod `
    -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$resourceUrl" `
    -Headers @{ Metadata = 'true' } `
    -Method Get

$accessToken = $tokenResponse.access_token
$headers = @{ Authorization = "Bearer $accessToken"; 'Content-Type' = 'application/json' }

#endregion

#region --- Load Automation Variables ---

$groupObjectId   = Get-AutomationVariable -Name 'GroupObjectId'
$senderMailbox   = Get-AutomationVariable -Name 'SenderMailbox'
$recipientEmail  = Get-AutomationVariable -Name 'RecipientEmail'

#endregion

#region --- Get Group Members (paged) ---

$disabledMembers = [System.Collections.Generic.List[PSCustomObject]]::new()
$nextLink = "https://graph.microsoft.com/v1.0/groups/$groupObjectId/members?`$select=id,displayName,userPrincipalName,accountEnabled&`$top=999"

do {
    $response = Invoke-RestMethod -Uri $nextLink -Headers $headers -Method Get
    foreach ($member in $response.value) {
        if ($member.'@odata.type' -eq '#microsoft.graph.user' -and $member.accountEnabled -eq $false) {
            $disabledMembers.Add([PSCustomObject]@{
                DisplayName       = $member.displayName
                UserPrincipalName = $member.userPrincipalName
                ObjectId          = $member.id
            })
        }
    }
    $nextLink = $response.'@odata.nextLink'
} while ($nextLink)

#endregion

#region --- Build Email ---

$runDate   = (Get-Date).ToString('yyyy-MM-dd HH:mm UTC')
$count     = $disabledMembers.Count

if ($count -eq 0) {
    $bodyHtml = @"
<p>Audit run: <strong>$runDate</strong></p>
<p>No disabled accounts were found in the monitored security group.</p>
"@
    $subject = "[Azure Automation] Disabled Account Audit - No Issues Found ($runDate)"
} else {
    $rows = ($disabledMembers | ForEach-Object {
        "<tr><td style='padding:6px 12px;border:1px solid #ddd'>$($_.DisplayName)</td>" +
        "<td style='padding:6px 12px;border:1px solid #ddd'>$($_.UserPrincipalName)</td>" +
        "<td style='padding:6px 12px;border:1px solid #ddd'>$($_.ObjectId)</td></tr>"
    }) -join "`n"

    $bodyHtml = @"
<p>Audit run: <strong>$runDate</strong></p>
<p>The following <strong>$count</strong> disabled account(s) were found in the monitored security group:</p>
<table style='border-collapse:collapse;font-family:Segoe UI,Arial,sans-serif;font-size:14px'>
  <thead>
    <tr style='background:#0078d4;color:#fff'>
      <th style='padding:8px 12px;text-align:left'>Display Name</th>
      <th style='padding:8px 12px;text-align:left'>UPN</th>
      <th style='padding:8px 12px;text-align:left'>Object ID</th>
    </tr>
  </thead>
  <tbody>
$rows
  </tbody>
</table>
<p style='color:#666;font-size:12px;margin-top:24px'>Sent by Azure Automation — do not reply to this message.</p>
"@
    $subject = "[Azure Automation] Disabled Account Audit - $count Disabled User(s) Found ($runDate)"
}

$mailBody = @{
    message = @{
        subject      = $subject
        body         = @{ contentType = 'HTML'; content = $bodyHtml }
        toRecipients = @(@{ emailAddress = @{ address = $recipientEmail } })
    }
    saveToSentItems = $false
} | ConvertTo-Json -Depth 10

#endregion

#region --- Send Email ---

Invoke-RestMethod `
    -Uri "https://graph.microsoft.com/v1.0/users/$senderMailbox/sendMail" `
    -Headers $headers `
    -Method Post `
    -Body $mailBody

Write-Output "Report sent. Disabled accounts found: $count"

#endregion
