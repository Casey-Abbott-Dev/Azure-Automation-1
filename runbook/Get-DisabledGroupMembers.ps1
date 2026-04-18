<#
    .SYNOPSIS
        Reports disabled Entra ID accounts found in a specified security group.
        Runs under the Automation Account's System-assigned Managed Identity.

    CONFIGURATION
        One Automation Variable is required (non-sensitive):
            KeyVaultName  - Name of the Azure Key Vault holding all secrets

        All sensitive values are read from Key Vault at runtime:
            group-object-id   - Object ID of the Entra ID security group to audit
            sender-mailbox    - UPN of the M365 mailbox used to send the report
            recipient-email   - Email address to receive the report
            tenant-id         - Azure AD tenant ID
#>

param()

#region --- Helpers ---

function Get-ManagedIdentityToken {
    param([string]$Resource)
    $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$Resource"
    $response = Invoke-RestMethod -Uri $uri -Headers @{ Metadata = 'true' } -Method Get
    return $response.access_token
}

function Get-KeyVaultSecret {
    param(
        [string]$VaultName,
        [string]$SecretName,
        [string]$Token
    )
    $uri = "https://$VaultName.vault.azure.net/secrets/$SecretName`?api-version=7.4"
    $response = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $Token" } -Method Get
    return $response.value
}

#endregion

#region --- Auth via Managed Identity ---

Write-Output "Acquiring tokens via Managed Identity..."
$kvToken    = Get-ManagedIdentityToken -Resource 'https://vault.azure.net'
$graphToken = Get-ManagedIdentityToken -Resource 'https://graph.microsoft.com'

$graphHeaders = @{ Authorization = "Bearer $graphToken"; 'Content-Type' = 'application/json' }

#endregion

#region --- Load Secrets from Key Vault ---

Write-Output "Reading configuration from Key Vault..."
$kvName = Get-AutomationVariable -Name 'KeyVaultName'

$groupObjectId  = Get-KeyVaultSecret -VaultName $kvName -SecretName 'group-object-id'  -Token $kvToken
$senderMailbox  = Get-KeyVaultSecret -VaultName $kvName -SecretName 'sender-mailbox'   -Token $kvToken
$recipientEmail = Get-KeyVaultSecret -VaultName $kvName -SecretName 'recipient-email'  -Token $kvToken

#endregion

#region --- Get Group Members (paged) ---

Write-Output "Querying group members..."
$disabledMembers = [System.Collections.Generic.List[PSCustomObject]]::new()
$nextLink = "https://graph.microsoft.com/v1.0/groups/$groupObjectId/members?`$select=id,displayName,userPrincipalName,accountEnabled&`$top=999"

do {
    $response = Invoke-RestMethod -Uri $nextLink -Headers $graphHeaders -Method Get
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

$runDate = (Get-Date).ToString('yyyy-MM-dd HH:mm UTC')
$count   = $disabledMembers.Count

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

Write-Output "Sending report email..."
Invoke-RestMethod `
    -Uri "https://graph.microsoft.com/v1.0/users/$senderMailbox/sendMail" `
    -Headers $graphHeaders `
    -Method Post `
    -Body $mailBody

Write-Output "Report sent. Disabled accounts found: $count"

#endregion
