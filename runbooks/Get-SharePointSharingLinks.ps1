#Requires -Version 7.0
<#
.SYNOPSIS
    Audits SharePoint Online sites for external sharing links and generates a CSV report.

.DESCRIPTION
    Security auditing tool designed for Azure Automation Runbooks that enumerates sharing
    permissions across SharePoint Online sites. Identifies external shares, anonymous
    links, and direct shares that may represent data-exfiltration risks.

    Workflow:
      1. Resolves the target tenant ID from the SharePoint hostname via OIDC discovery.
      2. Authenticates to Microsoft Graph using OAuth 2.0 client credentials.
      3. Enumerates all SharePoint sites (or a single site via -SiteUrl).
      4. For each site, retrieves every document library (drive).
      5. Recursively enumerates all drive items via folder traversal (does NOT rely on
         the search index, so newly uploaded files are always included).
      6. Inspects sharing permissions on each item.
      7. Reports external shares, anonymous links, and (optionally) internal links.
      8. Streams results to CSV incrementally to preserve progress on interruption.

    Credential resolution order:
      1. Explicit -ClientId / -ClientSecret parameters (local or testing use).
      2. Azure Automation encrypted variables 'SharePointReportClientId' and
         'SharePointReportClientSecret' (production Runbook use).

    Security controls:
      - TLS 1.2 enforced for all HTTPS connections.
      - Input validation on all URL and hostname parameters.
      - CSV formula-injection protection (OWASP) on every output field.
      - Access token and credentials cleared from memory after use.
      - Rate limiting to avoid Microsoft Graph throttling (HTTP 429).
      - Files are never overwritten — timestamped filenames ensure uniqueness.
      - Error messages are sanitised to prevent credential or token leakage.

.PARAMETER SharePointHostname
    SharePoint Online hostname for the target tenant (e.g. 'contoso.sharepoint.com').
    Must match the pattern '<prefix>.sharepoint.com'. Not required when -SiteUrl is
    provided — the hostname is extracted automatically.

.PARAMETER SiteUrl
    Optional. Restricts the scan to a single SharePoint site URL.
    Must be an HTTPS URL under a *.sharepoint.com domain.
    Example: 'https://contoso.sharepoint.com/sites/Finance'

.PARAMETER OutputPath
    Directory for the CSV report file. Defaults to the current directory.
    Created automatically if it does not exist. Resolved to an absolute path internally
    to prevent accidental writes outside the intended location.

.PARAMETER IncludeInternalLinks
    Switch. Also reports internal organisation-wide sharing links in addition to
    external and anonymous ones. Disabled by default.

.PARAMETER MaxItemsPerSite
    Hard cap on the number of drive items processed per document library. Default 500.
    Enumeration stops once this limit is reached per drive.

.PARAMETER PermissionRequestsPerMinute
    Maximum permission-check API calls per rolling 60-second window. Default 250.
    Prevents Graph API throttling. Valid range: 1-5000.

.PARAMETER CsvPath
    Optional explicit path for the CSV report. When the file already exists and -Resume
    is not set, the script exits with an error to prevent data loss.
    If omitted a timestamped filename is generated automatically.

.PARAMETER Resume
    Switch. Resumes a previously interrupted scan by loading existing rows from the CSV
    and skipping already-processed items. Requires -CsvPath pointing to the earlier file.

.PARAMETER ClientId
    Application (client) ID of the Entra app registration. Optional when running as an
    Azure Automation Runbook — resolved from the encrypted Automation Variable
    'SharePointReportClientId' if not provided.

.PARAMETER ClientSecret
    Client secret of the Entra app registration. Optional when running as an Azure
    Automation Runbook — resolved from the encrypted Automation Variable
    'SharePointReportClientSecret' if not provided.

.EXAMPLE
    # Azure Automation Runbook — credentials from Automation Variables
    .\Get-SharePointSharingLinks.ps1 -SharePointHostname 'contoso.sharepoint.com'

.EXAMPLE
    # Scan a specific site with explicit credentials
    .\Get-SharePointSharingLinks.ps1 `
        -SiteUrl 'https://contoso.sharepoint.com/sites/Finance' `
        -ClientId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -ClientSecret 'your-secret'

.EXAMPLE
    # Scan all sites including org-wide links, output to C:\Reports
    .\Get-SharePointSharingLinks.ps1 `
        -SharePointHostname 'contoso.sharepoint.com' `
        -OutputPath 'C:\Reports' `
        -IncludeInternalLinks `
        -ClientId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -ClientSecret 'your-secret'

.EXAMPLE
    # Resume a previously interrupted scan
    .\Get-SharePointSharingLinks.ps1 `
        -SharePointHostname 'contoso.sharepoint.com' `
        -CsvPath 'C:\Reports\SharePointSharing_contoso_20260922-143000.csv' `
        -Resume

.NOTES
    Version:      2.0.0
    Updated:      2026-09-22

    Required Permissions:
      - Entra app registration with Application permission: Sites.Read.All
      - Admin consent granted in the target tenant

    Azure Automation Setup:
      1. Create two encrypted Automation Variables:
            - SharePointReportClientId     -> your app client ID
            - SharePointReportClientSecret -> your app client secret
      2. Import this script as a Runbook (PowerShell 7.2+ runtime).
      3. Schedule or run on demand.

    Security Notes:
      - Only READ permissions are required (Sites.Read.All).
      - No data is modified, deleted, or uploaded.
      - Credentials are cleared from memory after token acquisition.
      - CSV output is sanitised against formula-injection attacks.
      - All HTTPS connections enforce TLS 1.2 or higher.
      - Error messages never expose secrets or tokens.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]*\.sharepoint\.com$',
        ErrorMessage = "SharePointHostname must match '<prefix>.sharepoint.com'.")]
    [string]$SharePointHostname,

    [Parameter()]
    [ValidateScript({
            if ($_ -and $_ -notmatch '^https://[a-zA-Z0-9][a-zA-Z0-9-]*\.sharepoint\.com(/|$)') {
                throw "SiteUrl must be a valid SharePoint Online HTTPS URL (https://<tenant>.sharepoint.com/...)."
            }
            return $true
        })]
    [string]$SiteUrl,

    [Parameter()]
    [string]$OutputPath = (Get-Location).Path,

    [Parameter()]
    [switch]$IncludeInternalLinks,

    [Parameter()]
    [ValidateRange(1, 50000)]
    [int]$MaxItemsPerSite = 500,

    [Parameter()]
    [ValidateRange(1, 5000)]
    [int]$PermissionRequestsPerMinute = 250,

    [Parameter()]
    [string]$CsvPath,

    [Parameter()]
    [switch]$Resume,

    [Parameter()]
    [string]$ClientId,

    [Parameter()]
    [string]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Security: enforce TLS 1.2+ for all outbound HTTPS connections ────────────
# PowerShell 7 defaults to TLS 1.2, but corporate proxies or older .NET runtimes
# can negotiate weaker protocols. login.microsoftonline.com and
# graph.microsoft.com both require TLS 1.2 as a minimum.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── Parameter validation ─────────────────────────────────────────────────────
if (-not $SharePointHostname -and -not $SiteUrl) {
    Write-Error "You must provide either -SharePointHostname or -SiteUrl."
    exit 1
}
if (-not $SharePointHostname) {
    $SharePointHostname = ([uri]$SiteUrl).Host
}

# ── Credential resolution ────────────────────────────────────────────────────
# Priority: explicit parameters > Azure Automation encrypted variables.
# This allows the same script to run interactively or as a Runbook.
if (-not $ClientId) {
    try {
        $ClientId = Get-AutomationVariable -Name 'SharePointReportClientId'
        Write-Host "  -> ClientId resolved from Automation Variable." -ForegroundColor Gray
    }
    catch {
        Write-Error ("ClientId not provided and could not be resolved from Automation " +
            "Variable 'SharePointReportClientId'. Provide -ClientId or create the variable.")
        exit 1
    }
}
if (-not $ClientSecret) {
    try {
        $ClientSecret = Get-AutomationVariable -Name 'SharePointReportClientSecret'
        Write-Host "  -> ClientSecret resolved from Automation Variable." -ForegroundColor Gray
    }
    catch {
        Write-Error ("ClientSecret not provided and could not be resolved from Automation " +
            "Variable 'SharePointReportClientSecret'. Provide -ClientSecret or create the variable.")
        exit 1
    }
}

# ── Output path validation ───────────────────────────────────────────────────
# Resolve to an absolute path to block accidental writes via relative traversal
# (e.g. '../../somewhere-unexpected').
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

if (-not (Test-Path -LiteralPath $OutputPath)) {
    try {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }
    catch {
        Write-Error "Failed to create output directory '$OutputPath': $($_.Exception.Message)"
        exit 1
    }
}

#region ── Helper functions ────────────────────────────────────────────────────

function Resolve-TenantId {
    <#
    .SYNOPSIS
        Resolves a tenant ID from a SharePoint hostname via the OIDC discovery endpoint.
    .DESCRIPTION
        SharePoint hostnames follow the pattern {prefix}.sharepoint.com. The corresponding
        Entra domain is {prefix}.onmicrosoft.com. This function queries the OpenID Connect
        well-known configuration endpoint for that domain and extracts the tenant GUID from
        the issuer claim.
    .PARAMETER Hostname
        A validated SharePoint hostname (e.g. 'contoso.sharepoint.com').
    .OUTPUTS
        [string] The tenant ID GUID.
    #>
    param([string]$Hostname)

    $prefix = $Hostname -replace '\.sharepoint\.com$', ''
    $oidcUrl = "https://login.microsoftonline.com/$prefix.onmicrosoft.com/v2.0/.well-known/openid-configuration"

    try {
        $doc = Invoke-RestMethod -Uri $oidcUrl -Method GET
        if ($doc.issuer -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
            return $Matches[1]
        }
        throw "Tenant ID GUID not found in issuer claim."
    }
    catch {
        # Sanitised error — do not expose raw response bodies
        throw "Failed to resolve tenant ID from '$Hostname'. Verify the hostname is correct. Error: $($_.Exception.Message)"
    }
}

function Get-GraphToken {
    <#
    .SYNOPSIS
        Acquires an app-only access token for Microsoft Graph via OAuth 2.0 client credentials.
    .DESCRIPTION
        Posts a client_credentials grant request to the Azure AD v2.0 token endpoint for
        the specified tenant. Returns the bearer access token string.
    .PARAMETER TenantId
        The target Azure AD tenant GUID.
    .PARAMETER ClientId
        Application (client) ID of the Entra app registration.
    .PARAMETER ClientSecret
        Client secret value.
    .OUTPUTS
        [string] A bearer access token for https://graph.microsoft.com.
    #>
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret
    )

    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = 'https://graph.microsoft.com/.default'
    }

    try {
        $response = Invoke-RestMethod `
            -Uri         "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -Method      POST `
            -Body        $body `
            -ContentType 'application/x-www-form-urlencoded'
        return $response.access_token
    }
    catch {
        # Sanitised — never include the raw error which could echo the client secret
        throw ("Authentication failed for tenant '$TenantId'. Verify ClientId, ClientSecret, " +
            "and that admin consent has been granted. HTTP error: $($_.Exception.Message)")
    }
}

function Invoke-GraphRequest {
    <#
    .SYNOPSIS
        Executes a Microsoft Graph GET request with automatic pagination and an optional
        result-count cap.
    .DESCRIPTION
        Follows @odata.nextLink headers to retrieve all pages of a collection response.
        When MaxResults is specified, pagination stops once the cap is reached and excess
        items are trimmed. Single-object responses (e.g. a specific site lookup) are
        returned as a one-element list.
    .PARAMETER Uri
        The full Graph API URI to call.
    .PARAMETER Token
        A valid bearer access token.
    .PARAMETER MaxResults
        Optional hard cap on the number of items returned. 0 = unlimited (default).
    .OUTPUTS
        [System.Collections.Generic.List[object]] Flat list of response objects.
    #>
    param(
        [string]$Uri,
        [string]$Token,
        [int]$MaxResults = 0
    )

    $headers = @{ Authorization = "Bearer $Token" }
    $results = [System.Collections.Generic.List[object]]::new()

    do {
        try {
            $response = Invoke-RestMethod -Uri $Uri -Headers $headers -Method GET
        }
        catch {
            $statusCode = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { 'N/A' }
            Write-Warning ("  [Graph] Request failed (HTTP {0}): {1}" -f $statusCode, $_.Exception.Message)
            return $results
        }

        # Collect items from collection responses ({ value: [...] })
        if ($response.PSObject.Properties.Name -contains 'value') {
            if ($response.value) { $results.AddRange([object[]]$response.value) }
        }
        # Single-object responses (e.g. /sites/{host}:/{path})
        elseif ($response.PSObject.Properties.Name -contains 'id') {
            $results.Add($response)
        }

        # Enforce result cap — stop paging once we have enough items
        if ($MaxResults -gt 0 -and $results.Count -ge $MaxResults) {
            if ($results.Count -gt $MaxResults) {
                $results.RemoveRange($MaxResults, $results.Count - $MaxResults)
            }
            break
        }

        $Uri = if ($response.PSObject.Properties.Name -contains '@odata.nextLink') {
            $response.'@odata.nextLink'
        }
        else { $null }
    } while ($Uri)

    return $results
}

function Get-AllDriveItems {
    <#
    .SYNOPSIS
        Enumerates all items in a SharePoint drive using breadth-first folder traversal.
    .DESCRIPTION
        Uses a queue to walk every folder and subfolder via the /children endpoint. This
        is more reliable than the search API (search(q='')) because it does not depend on
        the search index being up to date — newly uploaded or recently moved files are
        always included.

        Enumeration stops when MaxItems is reached or all folders have been visited.
    .PARAMETER GraphBaseUrl
        The Graph API base URL (e.g. 'https://graph.microsoft.com/v1.0').
    .PARAMETER DriveId
        The Microsoft Graph drive ID to enumerate.
    .PARAMETER Token
        A valid bearer access token with Sites.Read.All permission.
    .PARAMETER MaxItems
        Hard cap on the number of items returned. Default 500.
    .OUTPUTS
        [System.Collections.Generic.List[object]] Flat list of drive-item objects.
    #>
    param(
        [Parameter(Mandatory)][string]$GraphBaseUrl,
        [Parameter(Mandatory)][string]$DriveId,
        [Parameter(Mandatory)][string]$Token,
        [int]$MaxItems = 500
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $folderQueue = [System.Collections.Generic.Queue[string]]::new()
    $folderQueue.Enqueue('root')

    while ($folderQueue.Count -gt 0 -and $items.Count -lt $MaxItems) {
        $folderId = $folderQueue.Dequeue()
        $childrenUri = "$GraphBaseUrl/drives/$DriveId/items/$folderId/children" +
        "?`$select=id,name,webUrl,size,lastModifiedDateTime,file,folder&`$top=200"

        $remaining = $MaxItems - $items.Count
        $children = Invoke-GraphRequest -Uri $childrenUri -Token $Token -MaxResults $remaining

        foreach ($child in $children) {
            if ($items.Count -ge $MaxItems) { break }
            $items.Add($child)

            # Queue sub-folders for traversal on the next iteration
            if ($child.PSObject.Properties.Name -contains 'folder' -and $child.folder) {
                $folderQueue.Enqueue($child.id)
            }
        }
    }

    if ($items.Count -ge $MaxItems) {
        Write-Warning ("  Item cap reached ({0}). Some items in this library were not scanned." -f $MaxItems)
    }

    return $items
}

function Protect-CsvCell {
    <#
    .SYNOPSIS
        Sanitises a string to prevent CSV formula-injection attacks.
    .DESCRIPTION
        When CSV files are opened in spreadsheet applications (Excel, LibreOffice Calc),
        cell values starting with  =  +  -  @  TAB  CR  LF  can be interpreted as
        formulas or macros. A malicious SharePoint item name like  =CMD|'/C calc'!A0
        could trigger arbitrary command execution on the analyst's workstation.

        This function prefixes dangerous leading characters with a single-quote ('),
        which forces the cell to be treated as a text literal.

        Reference: https://owasp.org/www-community/attacks/CSV_Injection
    .PARAMETER Value
        The raw string value to sanitise.
    .OUTPUTS
        [string] The sanitised value, safe for CSV export.
    #>
    param([string]$Value)

    if ([string]::IsNullOrEmpty($Value)) { return $Value }

    switch ($Value[0]) {
        '=' { return "'$Value" }
        '+' { return "'$Value" }
        '-' { return "'$Value" }
        '@' { return "'$Value" }
        "`t" { return "'$Value" }
        "`r" { return "'$Value" }
        "`n" { return "'$Value" }
    }
    return $Value
}

function Get-SharingLinkType {
    <#
    .SYNOPSIS
        Extracts structured sharing-link metadata from a Graph permission object.
    .DESCRIPTION
        Parses the permission object returned by the Graph /permissions endpoint and
        returns a normalised PSCustomObject with link type, scope, role, expiry,
        recipient display name, and e-mail address.

        Handles both link-based shares (anonymous, organisation) and direct shares
        (grantedTo / grantedToV2).
    .PARAMETER Permission
        A single permission object from the Graph API.
    .OUTPUTS
        [PSCustomObject] with properties: LinkType, Scope, Role, ExpiryDateTime,
        SharedWith, Email.  Returns $null if the permission cannot be classified.
    #>
    param([object]$Permission)

    $props = $Permission.PSObject.Properties.Name

    # ── Link-based share (anonymous or organisation-wide) ────────────────────
    if ($props -contains 'link' -and $Permission.link) {
        $scope = if ($Permission.link.PSObject.Properties.Name -contains 'scope') { $Permission.link.scope } else { 'unknown' }
        $type = if ($Permission.link.PSObject.Properties.Name -contains 'type') { $Permission.link.type } else { 'unknown' }
        $exp = if ($props -contains 'expirationDateTime' -and $Permission.expirationDateTime) {
            $Permission.expirationDateTime
        }
        else { 'No expiry' }

        return [PSCustomObject]@{
            LinkType       = "$scope-$type"
            Scope          = $scope
            Role           = $type
            ExpiryDateTime = $exp
            SharedWith     = 'Link (no specific recipient)'
            Email          = ''
        }
    }

    # ── Direct share (specific user, group, or service principal) ────────────
    $grantee = $null
    if ($props -contains 'grantedToV2' -and $Permission.grantedToV2) { $grantee = $Permission.grantedToV2 }
    elseif ($props -contains 'grantedTo' -and $Permission.grantedTo) { $grantee = $Permission.grantedTo }

    if ($grantee) {
        $granteeProps = $grantee.PSObject.Properties.Name
        $user = if ($granteeProps -contains 'user' -and $grantee.user) { $grantee.user }
        elseif ($granteeProps -contains 'siteUser' -and $grantee.siteUser) { $grantee.siteUser }
        elseif ($granteeProps -contains 'group' -and $grantee.group) { $grantee.group }
        else { $null }

        $exp = if ($props -contains 'expirationDateTime' -and $Permission.expirationDateTime) { $Permission.expirationDateTime } else { 'No expiry' }
        $roles = if ($props -contains 'roles' -and $Permission.roles) { $Permission.roles -join ',' } else { '' }

        $displayName = if ($user -and $user.PSObject.Properties.Name -contains 'displayName') { $user.displayName } else { 'Unknown' }
        $email = if ($user) {
            if ($user.PSObject.Properties.Name -contains 'email' -and $user.email) { $user.email }
            elseif ($user.PSObject.Properties.Name -contains 'loginName' -and $user.loginName) { $user.loginName }
            else { '' }
        }
        else { '' }

        return [PSCustomObject]@{
            LinkType       = 'DirectShare'
            Scope          = 'specific'
            Role           = $roles
            ExpiryDateTime = $exp
            SharedWith     = $displayName
            Email          = $email
        }
    }

    # Permission could not be classified (e.g. inherited or system)
    return $null
}

function Test-IsExternalShare {
    <#
    .SYNOPSIS
        Determines whether a sharing permission represents an external (outside-org) share.
    .DESCRIPTION
        A share is considered external if:
          - It is an anonymous (anyone) link, OR
          - The recipient's e-mail domain does not match the tenant domain.
    .PARAMETER Permission
        A Graph permission object.
    .PARAMETER TenantDomain
        The tenant prefix (e.g. 'contoso') used to match against recipient e-mail domains.
    .OUTPUTS
        [bool] $true if the share is external, $false otherwise.
    #>
    param(
        [object]$Permission,
        [string]$TenantDomain
    )

    $props = $Permission.PSObject.Properties.Name

    # Anonymous links are always external by definition
    if ($props -contains 'link' -and $Permission.link -and
        $Permission.link.PSObject.Properties.Name -contains 'scope' -and
        $Permission.link.scope -eq 'anonymous') {
        return $true
    }

    # Check recipient e-mail domain against the tenant
    $grantee = $null
    if ($props -contains 'grantedToV2' -and $Permission.grantedToV2) { $grantee = $Permission.grantedToV2 }
    elseif ($props -contains 'grantedTo' -and $Permission.grantedTo) { $grantee = $Permission.grantedTo }

    if ($grantee) {
        $granteeProps = $grantee.PSObject.Properties.Name
        $email = ''
        if ($granteeProps -contains 'user' -and $grantee.user -and
            $grantee.user.PSObject.Properties.Name -contains 'email') {
            $email = $grantee.user.email
        }
        elseif ($granteeProps -contains 'siteUser' -and $grantee.siteUser -and
            $grantee.siteUser.PSObject.Properties.Name -contains 'loginName') {
            $email = $grantee.siteUser.loginName
        }
        if ($email -and $email -notmatch [regex]::Escape($TenantDomain)) {
            return $true
        }
    }

    return $false
}

function Wait-ForPermissionRateLimit {
    <#
    .SYNOPSIS
        Enforces a rolling-window rate limit on permission API requests.
    .DESCRIPTION
        Tracks timestamps of recent permission requests in a script-scoped queue. If the
        number of requests in the last 60 seconds reaches the configured maximum, the
        function pauses execution until the oldest request falls outside the window.
        This prevents Microsoft Graph from returning HTTP 429 (Too Many Requests).
    .PARAMETER MaxRequestsPerMinute
        The maximum number of permission requests allowed per rolling 60-second window.
    #>
    param([int]$MaxRequestsPerMinute)

    $now = Get-Date

    # Discard timestamps older than 60 seconds
    while ($script:PermissionRequestTimestamps.Count -gt 0 -and
        ($now - $script:PermissionRequestTimestamps.Peek()).TotalSeconds -ge 60) {
        [void]$script:PermissionRequestTimestamps.Dequeue()
    }

    # Pause if the window is full
    if ($script:PermissionRequestTimestamps.Count -ge $MaxRequestsPerMinute) {
        $oldest = $script:PermissionRequestTimestamps.Peek()
        $waitSeconds = [math]::Ceiling(60 - ($now - $oldest).TotalSeconds)
        if ($waitSeconds -lt 1) { $waitSeconds = 1 }

        $script:ThrottlePauseCount++
        Write-Host ("    -> Throttle guard: {0} requests/min reached. Pausing {1}s..." -f
            $MaxRequestsPerMinute, $waitSeconds) -ForegroundColor Yellow
        Start-Sleep -Seconds $waitSeconds

        # Re-clean after sleeping
        $now = Get-Date
        while ($script:PermissionRequestTimestamps.Count -gt 0 -and
            ($now - $script:PermissionRequestTimestamps.Peek()).TotalSeconds -ge 60) {
            [void]$script:PermissionRequestTimestamps.Dequeue()
        }
    }

    $script:PermissionRequestTimestamps.Enqueue((Get-Date))
}

function Write-ReportRow {
    <#
    .SYNOPSIS
        Appends a single report row to CSV with automatic formula-injection sanitisation.
    .DESCRIPTION
        Iterates every string property of the input object and applies Protect-CsvCell
        before writing. Rows are streamed incrementally so that partial results are
        preserved if the script is interrupted mid-run.
    .PARAMETER Row
        A PSCustomObject containing the report data.
    .PARAMETER CsvPath
        Absolute path to the output CSV file.
    #>
    param(
        [Parameter(Mandatory)][pscustomobject]$Row,
        [Parameter(Mandatory)][string]$CsvPath
    )

    # Build a sanitised copy — never modify the caller's object
    $safe = [ordered]@{}
    foreach ($prop in $Row.PSObject.Properties) {
        if ($prop.Value -is [string]) {
            $safe[$prop.Name] = Protect-CsvCell -Value $prop.Value
        }
        else {
            $safe[$prop.Name] = $prop.Value
        }
    }
    $safeRow = [PSCustomObject]$safe

    if (Test-Path -LiteralPath $CsvPath) {
        $safeRow | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -Append
    }
    else {
        $safeRow | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    }
}

#endregion

#region ── Startup ─────────────────────────────────────────────────────────────

Write-Host "SharePoint External Sharing Report" -ForegroundColor Green
Write-Host ("Run started: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor Gray

Write-Host "  -> Resolving tenant ID from '$SharePointHostname'..." -NoNewline
try {
    $tenantId = Resolve-TenantId -Hostname $SharePointHostname
    Write-Host (" $tenantId") -ForegroundColor Green
}
catch {
    Write-Error $_
    exit 1
}

$tenantDomain = $SharePointHostname -replace '\.sharepoint\.com$', ''

Write-Host "  -> Authenticating to Graph..." -NoNewline
$token = $null
try {
    $token = Get-GraphToken -TenantId $tenantId -ClientId $ClientId -ClientSecret $ClientSecret
    Write-Host " OK" -ForegroundColor Green
}
catch {
    Write-Error $_
    exit 1
}
finally {
    # Security: clear the client secret from memory immediately after token acquisition.
    # The token alone is sufficient for all subsequent API calls.
    $ClientSecret = $null
}

#endregion

#region ── Main scan ───────────────────────────────────────────────────────────

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$graphBase = 'https://graph.microsoft.com/v1.0'

# ── Determine CSV file path (F8: never overwrite existing files) ─────────────
if ($CsvPath) {
    if ([System.IO.Path]::IsPathRooted($CsvPath)) {
        $csvFile = $CsvPath
    }
    else {
        $csvFile = Join-Path $OutputPath $CsvPath
    }
    $csvFile = [System.IO.Path]::GetFullPath($csvFile)

    # Refuse to overwrite unless explicitly resuming
    if ((Test-Path -LiteralPath $csvFile) -and -not $Resume) {
        Write-Error ("CSV file already exists: '$csvFile'. Use -Resume to continue " +
            "from this file, or omit -CsvPath to generate a new timestamped file.")
        exit 1
    }
}
else {
    # Generate a unique timestamped filename — guarantees no overwrite
    $csvFile = Join-Path $OutputPath ("SharePointSharing_{0}_{1}.csv" -f $tenantDomain, $timestamp)
}

# ── Initialise script-scoped tracking variables ──────────────────────────────
$script:PermissionRequestTimestamps = [System.Collections.Generic.Queue[datetime]]::new()
$script:ThrottlePauseCount = 0

$processedPermissionKeys = [System.Collections.Generic.HashSet[string]]::new()
$processedSiteIds = [System.Collections.Generic.HashSet[string]]::new()

$rowsWritten = 0
$sharedRowsCount = 0
$externalCount = 0
$anonymousCount = 0

# ── Resume mode: reload state from an existing CSV ───────────────────────────
if ($Resume -and (Test-Path -LiteralPath $csvFile)) {
    Write-Host ("  -> Resume mode: loading existing rows from '{0}'" -f $csvFile) -ForegroundColor Yellow
    $existingRows = Import-Csv -Path $csvFile

    foreach ($existingRow in $existingRows) {
        $rowsWritten++

        if ($existingRow.ReportType -eq 'SiteSettings' -and $existingRow.SiteId) {
            [void]$processedSiteIds.Add([string]$existingRow.SiteId)
            continue
        }

        if ($existingRow.ReportType -eq 'SharedItem') {
            $sharedRowsCount++
            if ($existingRow.IsExternal -eq 'True') { $externalCount++ }
            if ($existingRow.Scope -eq 'anonymous') { $anonymousCount++ }

            $existingPermId = if ($existingRow.PSObject.Properties.Name -contains 'PermissionId') {
                [string]$existingRow.PermissionId
            }
            else { '' }
            $existingDriveId = if ($existingRow.PSObject.Properties.Name -contains 'DriveId') {
                [string]$existingRow.DriveId
            }
            else { '' }
            $existingKey = "{0}|{1}|{2}|{3}" -f [string]$existingRow.SiteId, $existingDriveId, [string]$existingRow.ItemId, $existingPermId
            [void]$processedPermissionKeys.Add($existingKey)
        }
    }

    Write-Host ("  -> Resume loaded: {0} existing row(s), {1} shared row(s)." -f $rowsWritten, $sharedRowsCount) -ForegroundColor Yellow
}
elseif ($Resume -and -not (Test-Path -LiteralPath $csvFile)) {
    Write-Host ("  -> Resume requested but file not found. Starting new CSV: '{0}'" -f $csvFile) -ForegroundColor Yellow
}

Write-Host ("  -> CSV: writing rows incrementally to '{0}'" -f $csvFile) -ForegroundColor Gray
Write-Host ("  -> Throttle guard: max {0} permission requests/min" -f $PermissionRequestsPerMinute) -ForegroundColor Gray

# ── 1. Enumerate sites ───────────────────────────────────────────────────────
Write-Host "  -> Retrieving SharePoint sites..." -NoNewline

if ($SiteUrl) {
    $spUri = [uri]$SiteUrl
    $spHost = $spUri.Host
    $spPath = $spUri.AbsolutePath.TrimStart('/')
    $sitesUri = "$graphBase/sites/${spHost}:/${spPath}?`$select=id,name,displayName,webUrl"
    $sites = @(Invoke-GraphRequest -Uri $sitesUri -Token $token)
}
else {
    $sitesUri = "$graphBase/sites/getAllSites?`$select=id,name,displayName,webUrl&`$top=200"
    $sites = @(Invoke-GraphRequest -Uri $sitesUri -Token $token)
}

Write-Host (" {0} site(s) found." -f $sites.Count) -ForegroundColor Cyan

if (-not $sites) {
    Write-Error "No sites returned. Verify admin consent for ClientId '$ClientId' in tenant '$tenantId'."
    exit 1
}

$siteTotal = $sites.Count

try {
    foreach ($site in $sites) {

        $siteIndex = [array]::IndexOf($sites, $site) + 1
        $siteName = if ($site.PSObject.Properties.Name -contains 'displayName' -and $site.displayName) { $site.displayName } else { $site.name }
        $siteWebUrl = $site.webUrl
        $siteId = $site.id

        Write-Host ("`n  [{0}/{1}] Site: {2}" -f $siteIndex, $siteTotal, $siteName) -ForegroundColor White

        # ── 2. Site-level settings row ────────────────────────────────────────
        $siteSettingsRow = [PSCustomObject]@{
            TenantDomain    = $tenantDomain
            TenantId        = $tenantId
            SiteName        = $siteName
            SiteUrl         = $siteWebUrl
            ReportType      = 'SiteSettings'
            DriveName       = ''
            DriveId         = ''
            ItemName        = ''
            ItemPath        = ''
            ItemType        = ''
            ItemSize_KB     = ''
            LastModified    = ''
            LinkType        = ''
            Scope           = ''
            Role            = ''
            ExpiryDateTime  = ''
            SharedWith      = ''
            SharedWithEmail = ''
            IsExternal      = ''
            SiteId          = $siteId
            ItemId          = ''
            PermissionId    = ''
        }

        if (-not $processedSiteIds.Contains([string]$siteId)) {
            Write-ReportRow -Row $siteSettingsRow -CsvPath $csvFile
            $rowsWritten++
            [void]$processedSiteIds.Add([string]$siteId)
        }

        # ── 3. Enumerate all document libraries (drives) for this site ────────
        $drivesUri = "$graphBase/sites/$siteId/drives?`$select=id,name"
        $drives = @(Invoke-GraphRequest -Uri $drivesUri -Token $token)

        if (-not $drives) {
            Write-Host "    -> No document libraries found." -ForegroundColor DarkGray
            continue
        }

        Write-Host ("    -> {0} document library/libraries found." -f $drives.Count) -ForegroundColor Gray

        foreach ($drive in $drives) {

            $driveId = $drive.id
            $driveName = if ($drive.PSObject.Properties.Name -contains 'name' -and $drive.name) { $drive.name } else { 'Unnamed' }

            Write-Host ("    -> Library: {0}" -f $driveName) -ForegroundColor Gray

            # ── 4. Enumerate drive items via recursive folder traversal ───────
            Write-Progress -Id 1 `
                -Activity ("Site {0}/{1}: {2}" -f $siteIndex, $siteTotal, $siteName) `
                -Status   ("Library '{0}' — retrieving items..." -f $driveName) `
                -PercentComplete 0

            $items = Get-AllDriveItems `
                -GraphBaseUrl $graphBase `
                -DriveId      $driveId `
                -Token        $token `
                -MaxItems     $MaxItemsPerSite

            if (-not $items) {
                Write-Host "      -> No items found." -ForegroundColor DarkGray
                Write-Progress -Id 1 `
                    -Activity ("Site {0}/{1}: {2}" -f $siteIndex, $siteTotal, $siteName) `
                    -Completed
                continue
            }

            $sharedCount = 0
            $itemIndex = 0
            $itemTotal = $items.Count

            Write-Host ("      -> {0} item(s). Checking permissions..." -f $itemTotal) -ForegroundColor Gray

            foreach ($item in $items) {

                $itemIndex++
                $itemPct = [math]::Round(($itemIndex / $itemTotal) * 100)

                Write-Progress -Id 1 `
                    -Activity ("Site {0}/{1}: {2}" -f $siteIndex, $siteTotal, $siteName) `
                    -Status   ("{0} — item {1}/{2}" -f $driveName, $itemIndex, $itemTotal) `
                    -PercentComplete $itemPct

                # ── 5. Get permissions for each item ──────────────────────────
                Wait-ForPermissionRateLimit -MaxRequestsPerMinute $PermissionRequestsPerMinute
                $permUri = "$graphBase/drives/$driveId/items/$($item.id)/permissions"
                $permissions = Invoke-GraphRequest -Uri $permUri -Token $token

                foreach ($perm in $permissions) {

                    $permProps = $perm.PSObject.Properties.Name
                    $hasLink = $permProps -contains 'link' -and $perm.link
                    $hasGrantedTo = $permProps -contains 'grantedToV2' -and $perm.grantedToV2
                    $hasRoles = $permProps -contains 'roles' -and $perm.roles

                    # Skip the owner entry — it is not a share
                    if ($hasRoles -and $perm.roles -contains 'owner' -and -not $hasLink -and -not $hasGrantedTo) {
                        continue
                    }

                    $shareDetail = Get-SharingLinkType -Permission $perm
                    if (-not $shareDetail) { continue }

                    $isExternal = Test-IsExternalShare -Permission $perm -TenantDomain $tenantDomain

                    # Unless -IncludeInternalLinks is set, skip internal shares
                    if (-not $IncludeInternalLinks -and -not $isExternal) { continue }

                    # Build a deduplication key (site + drive + item + permission)
                    $permissionId = if ($permProps -contains 'id' -and $perm.id) {
                        [string]$perm.id
                    }
                    else {
                        "fallback:{0}|{1}|{2}|{3}|{4}" -f
                        [string]$shareDetail.LinkType,
                        [string]$shareDetail.Scope,
                        [string]$shareDetail.Role,
                        [string]$shareDetail.Email,
                        [string]$shareDetail.ExpiryDateTime
                    }
                    $permissionKey = "{0}|{1}|{2}|{3}" -f [string]$siteId, [string]$driveId, [string]$item.id, $permissionId
                    if ($processedPermissionKeys.Contains($permissionKey)) { continue }

                    $sharedCount++
                    $row = [PSCustomObject]@{
                        TenantDomain    = $tenantDomain
                        TenantId        = $tenantId
                        SiteName        = $siteName
                        SiteUrl         = $siteWebUrl
                        ReportType      = 'SharedItem'
                        DriveName       = $driveName
                        DriveId         = $driveId
                        ItemName        = $item.name
                        ItemPath        = $item.webUrl
                        ItemType        = if ($item.PSObject.Properties.Name -contains 'file' -and $item.file) { 'File' }
                        elseif ($item.PSObject.Properties.Name -contains 'folder' -and $item.folder) { 'Folder' }
                        else { 'Unknown' }
                        ItemSize_KB     = if ($item.PSObject.Properties.Name -contains 'size' -and $item.size) { [math]::Round($item.size / 1KB, 1) } else { '' }
                        LastModified    = $item.lastModifiedDateTime
                        LinkType        = $shareDetail.LinkType
                        Scope           = $shareDetail.Scope
                        Role            = $shareDetail.Role
                        ExpiryDateTime  = $shareDetail.ExpiryDateTime
                        SharedWith      = $shareDetail.SharedWith
                        SharedWithEmail = $shareDetail.Email
                        IsExternal      = $isExternal
                        SiteId          = $siteId
                        ItemId          = $item.id
                        PermissionId    = $permissionId
                    }

                    Write-ReportRow -Row $row -CsvPath $csvFile
                    $rowsWritten++
                    $sharedRowsCount++
                    if ($isExternal) { $externalCount++ }
                    if ($shareDetail.Scope -eq 'anonymous') { $anonymousCount++ }
                    [void]$processedPermissionKeys.Add($permissionKey)
                }
            }

            Write-Progress -Id 1 `
                -Activity ("Site {0}/{1}: {2}" -f $siteIndex, $siteTotal, $siteName) `
                -Completed

            if ($sharedCount -gt 0) {
                Write-Host ("      -> {0} external/anonymous share(s) recorded." -f $sharedCount) -ForegroundColor Magenta
            }
            else {
                Write-Host "      -> No external/anonymous shares found." -ForegroundColor DarkGray
            }
        }
    }
}
finally {
    # Security: clear the access token from memory now that all API calls are complete.
    $token = $null
    [System.GC]::Collect()
}

#endregion

#region ── Summary ─────────────────────────────────────────────────────────────

Write-Host ("`nDone. Wrote {0} row(s) -> {1}" -f $rowsWritten, $csvFile) -ForegroundColor Green
Write-Host ("  Throttle pauses applied: {0}" -f $script:ThrottlePauseCount) -ForegroundColor Gray

Write-Host "`n-- Summary -------------------------------------------------------" -ForegroundColor Cyan

if ($sharedRowsCount -gt 0) {
    Write-Host ("  Tenant:          {0}  ({1})" -f $tenantDomain, $tenantId)
    Write-Host ("  Shared items:    {0}" -f $sharedRowsCount)
    Write-Host ("  External shares: {0}" -f $externalCount)
    Write-Host ("  Anonymous links: {0}" -f $anonymousCount)
}
else {
    Write-Host "  No external or anonymous sharing found." -ForegroundColor Green
}

Write-Host ("Run completed: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor Gray

#endregion