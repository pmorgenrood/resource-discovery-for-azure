#Requires -Version 7.0
# =============================================================================
# ResourceInventory.Functions.ps1
#
# Shared helper functions for ResourceInventory.ps1. Dot-sourced from the top
# of that script so they load into its scope. Moved out of the main script to
# keep the orchestration flow (Variables / RunInventorySetup /
# ExecuteInventoryProcessing / FinalizeOutputs) readable. No top-level code
# lives here - definitions only.
#
# NOTE: Protect-FreeTextValue is defined Global: on purpose so it stays
# reachable from the Services/*/*.ps1 collectors, which the orchestrator
# invokes via '& $Module' (a call operator does NOT inherit the caller's
# non-Global function table). Keep the Global: scope modifier.
# =============================================================================
# Write-Log moved to Functions/Common.Functions.ps1 (defined Global: there) so a
# single logger is in scope for every entry script AND the Services/*/*.ps1
# collectors (reached via '& $Module', which only see Global functions).
# ResourceInventory.ps1 dot-sources Common.Functions.ps1 at startup, so Write-Log
# is available here exactly as before. Its default behavior is unchanged; it
# gained additive -NoConsole / -ToDebugLog switches. See that file for detail.
# Write-InventoryJson moved to Functions/InventoryJson.Functions.ps1, so
# Functions/RecoveryMerge.Functions.ps1 can load it without this file.

function GetLocalVersion()
{
    # Version.json sits next to ResourceInventory.ps1, one level above this file,
    # so the run does not depend on the folder it was started from.
    $VersionJsonPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Version.json'
    if (Test-Path -LiteralPath $VersionJsonPath -PathType Leaf)
    {
        $LocalVersionJson = Get-Content -LiteralPath $VersionJsonPath | ConvertFrom-Json
        return ('{0}.{1}.{2}' -f $LocalVersionJson.MajorVersion, $LocalVersionJson.MinorVersion, $LocalVersionJson.BuildVersion)
    }
    else
    {
        Write-Host ("Local Version.json not found at {0}. Clone the full repo and run the script from it. Exiting." -f $VersionJsonPath) -ForegroundColor Red
        exit 1
    }
}

# Deterministically tokenize a free-text / identity value into
# $Global:FreeTextDictionary and return the token, so collectors can replace
# free-form fields (Description, FriendlyName, CreatedBy, RoleName, container
# image, etc.) with a reversible token instead of dropping them. Same real value
# always yields the same prod_/nonprod_ token within a run. Null/empty input
# returns $null (preserving the previous "absent" shape); when obfuscation is off
# the dictionary is $null and the original value is returned unchanged. Defined
# Global so it is reachable from the collectors invoked via '& $Module'.
Function Global:Protect-FreeTextValue([string]$Value)
{
    if ([string]::IsNullOrEmpty($Value)) { return $null }
    if ($null -eq $Global:FreeTextDictionary) { return $Value }
    if (-not $Global:FreeTextDictionary.ContainsKey($Value))
    {
        $TfPrefix = if ($Value -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $Value -match '(^|-)([dts])-') { 'nonprod_' } else { 'prod_' }
        $Global:FreeTextDictionary[$Value] = $TfPrefix + [guid]::NewGuid().ToString()
    }
    return $Global:FreeTextDictionary[$Value]
}

# Azure's fixed words in an App Service's siteProperties, by where they stand. A word is kept
# only in its place, so a real name that is also one of these words elsewhere is masked.
#   SettingNames: a whole value that names a setting (LinuxFxVersion).
#   StackWords:   a whole value, or the part before '|' (DOCKER|..., DOTNETCORE|8.0).
#   HostWords:    the registry host of a container image (myreg.azurecr.io).
#   VersionWords: a word of a runtime version after '|' (18-lts, 17-java17, 3.x).
$Global:RdaSiteWords = @{
    SettingNames = [System.Collections.Generic.HashSet[string]]::new([string[]]@('linuxfxversion', 'windowsfxversion', 'current_stack'), [System.StringComparer]::OrdinalIgnoreCase)
    StackWords   = [System.Collections.Generic.HashSet[string]]::new([string[]]@('docker', 'compose', 'kube', 'sitecontainers', 'dotnet', 'dotnet-isolated', 'dotnetcore', 'aspnet', 'node', 'python', 'php', 'java', 'javase', 'tomcat', 'jboss', 'jbosseap', 'wildfly', 'ruby', 'go', 'powershell', 'static'), [System.StringComparer]::OrdinalIgnoreCase)
    HostWords    = [System.Collections.Generic.HashSet[string]]::new([string[]]@('azurecr', 'io', 'mcr', 'microsoft', 'com', 'docker'), [System.StringComparer]::OrdinalIgnoreCase)
    VersionWords = [System.Collections.Generic.HashSet[string]]::new([string[]]@('lts', 'x', 'latest', 'isolated', 'preview'), [System.StringComparer]::OrdinalIgnoreCase)
}

# One text of siteProperties masked: each run of letters or digits (any script) is kept when
# $Keep says so, else it is one free-text token; separator runs stay. A GUID or an IP
# address, with the letters or digits it runs into, is one token. So is a 4-part version
# (1.0.0.123), which reads as an IPv4 address.
function Global:Protect-RdaSiteText([string]$Text, [scriptblock]$Keep)
{
    $Out = [System.Text.StringBuilder]::new()
    # A run is letters, digits and marks of any script, and any character outside the
    # Basic Multilingual Plane (a surrogate pair), so none of them passes as a separator.
    # Group 'one' is one real part whatever its parts: a GUID, an IPv4 address, a bracketed
    # IPv6 one, each with the letters or digits it runs into (host10.20.30.40), and a bare
    # IPv6 one (with '::', or all 8 groups).
    $W = '[\p{L}\p{N}\p{M}\p{Cs}]'
    $One = $W + '*(?:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|(?<![0-9])[0-9]{1,3}(?:\.[0-9]{1,3}){3}(?![0-9])|\[(?=[0-9A-Fa-f.]*:[0-9A-Fa-f.]*:)[0-9A-Fa-f:.]+\])' + $W + '*'
    # A bare IPv6 address: with '::', or all 8 groups, or 6 groups and an IPv4 tail
    # (::ffff:192.0.2.128), with the letters or digits it runs into (host2001:db8::1).
    # Its lookaheads are bounded (an address is at most 45 characters), so a long run of
    # hex letters costs one short look per character. Words joined by '::' (std::string) are one
    # token too: more is masked, nothing leaks.
    $Bare6 = '(?<![\p{L}\p{N}\p{M}\p{Cs}:])' + $W + '*?(?=[0-9A-Fa-f:.]{0,45}[0-9A-Fa-f])(?=[0-9A-Fa-f:]{0,40}::|(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}:){6}[0-9]{1,3}\.)(?:[0-9A-Fa-f]{0,4}:){2,7}(?:[0-9]{1,3}(?:\.[0-9]{1,3}){3}(?![0-9])|[0-9A-Fa-f]{1,4})?' + $W + '*'
    # A ':' is a separator of its own, so a run of separators cannot take the '::' an IPv6 address starts with.
    $Pattern = '(?<one>' + $One + '|' + $Bare6 + ')|' + $W + '+|[^\p{L}\p{N}\p{M}\p{Cs}:]+|:'
    foreach ($M in [regex]::Matches($Text, $Pattern))
    {
        $Part = $M.Value
        $IsRun = $Part -match '^[\p{L}\p{N}\p{M}\p{Cs}]'
        $IsOne = $M.Groups['one'].Success
        $Out.Append($(if ($IsOne) { Protect-FreeTextValue $Part } elseif (-not $IsRun -or (& $Keep $Part)) { $Part } else { Protect-FreeTextValue $Part })) | Out-Null
    }
    $Out.ToString()
}

# True for an ISO time that is a real time (invariant): it holds no real text.
function Global:Test-RdaSiteTime([string]$Text)
{
    $D = [DateTimeOffset]::MinValue
    # The pull lower-cases Resource Graph's text, so a time can read 2026-11-15t09:00:00z.
    $Text -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt ][0-9]{2}:[0-9]{2}(?::[0-9]{2}(?:\.[0-9]{1,7})?)?(?:[Zz]|[+-][0-9]{2}:[0-9]{2})?\z' -and [DateTimeOffset]::TryParse($Text, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$D)
}

# The masked form of an App Service's siteProperties under -Obfuscate (an owner call,
# 2026-11-14, mask-keep-shape.md): keys, null and empty values, numbers and booleans are
# kept, and a time; in each text value only Azure's own words in their place and short ASCII
# numbers (up to 6 digits) where Azure writes one (a runtime version after '|', an image tag,
# a registry port; anywhere else, an app setting's value too, a number can be the customer's) are kept,
# every other run of letters or digits (any script) and every GUID is one free-text token
# (Protect-FreeTextValue: the same for the same real part in every file, so Reveal gives it
# back); separators stay. A text is a setting name, a stack word, 'STACK|version', or
# 'DOCKER|<image>' (registry host words kept, path and tag parts masked, a digit tag or
# 'latest' kept). One rule for the whole object, walked to its last value. Used by the
# AppServices collector and by Protect-RdaReport.ps1, so both mask it the same way.
# Returns the value as it is when obfuscation is off.
# $Context: 'Setting' for the siteProperties object itself and for the value of a setting
# Azure names ({name = LinuxFxVersion, WindowsFxVersion or CURRENT_STACK; value = ...} in its
# 'properties' or 'metadata' list, or a text given alone), where Azure's stack, host and
# version words stay; 'List' for those lists; 'Other' for every other value (an app
# setting's value or key, any other key), where only a time stays and every other part is
# a token.
Function Global:Protect-SitePropertiesValue($Value, [string]$Context = 'Setting')
{
    if ($null -eq $Global:FreeTextDictionary -or $null -eq $Value) { return $Value }
    $None = { param($P) $false }
    if ($Value -is [string] -and $Context -ne 'Setting')
    {
        if ($Value -eq '' -or (Test-RdaSiteTime $Value)) { return $Value }
        return (Protect-RdaSiteText $Value $None)
    }
    if ($Value -is [string])
    {
        # A time holds no real text (a [datetime] is kept below; a time's text here).
        if ($Value -eq '' -or $Global:RdaSiteWords.SettingNames.Contains($Value) -or $Global:RdaSiteWords.StackWords.Contains($Value) -or (Test-RdaSiteTime $Value)) { return $Value }
        # A number is kept only where Azure writes one: a runtime version, an image tag, a port.
        # Anywhere else (an app setting's value, an image path) it can be the customer's.
        $Bar = $Value.IndexOf('|')
        if ($Bar -lt 0) { return (Protect-RdaSiteText $Value $None) }
        $Stack = $Value.Substring(0, $Bar)
        $Rest = $Value.Substring($Bar + 1)
        # A head that is not a stack word: the whole value is the customer's, version and all.
        if (-not $Global:RdaSiteWords.StackWords.Contains($Stack)) { return ((Protect-RdaSiteText $Stack $None) + '|' + (Protect-RdaSiteText $Rest $None)) }
        $Head = $Stack
        if ($Stack -iin 'docker', 'compose', 'kube', 'sitecontainers')
        {
            # <host>/<path>[:<tag>]: the host's Azure words, a tag of digits or 'latest'.
            $Slash = $Rest.IndexOf('/')
            $HostPart = if ($Slash -gt 0 -and ($Rest.Substring(0, $Slash).Contains('.') -or $Rest.StartsWith('['))) { $Rest.Substring(0, $Slash) } else { '' }
            $PathPart = $Rest.Substring($HostPart.Length)
            $Colon = $PathPart.LastIndexOf(':')
            $Tag = if ($Colon -ge 0 -and $PathPart.IndexOf('/', $Colon) -lt 0) { $PathPart.Substring($Colon + 1) } else { $null }
            if ($null -ne $Tag) { $PathPart = $PathPart.Substring(0, $Colon) }
            # The host's labels are masked but Azure's (a numeric one too: an IP is real); a port stays.
            $Port = ''
            if ($HostPart -cmatch '^(.*)(:[0-9]{1,5})\z') { $HostPart = $Matches[1]; $Port = $Matches[2] }
            $Masked = (Protect-RdaSiteText $HostPart { param($P) $Global:RdaSiteWords.HostWords.Contains($P) }) + $Port + (Protect-RdaSiteText $PathPart $None)
            if ($null -ne $Tag) { $Masked += ':' + (Protect-RdaSiteText $Tag { param($P) $P -cmatch '^[0-9]{1,6}\z' -or $P -ieq 'latest' }) }
            return ($Head + '|' + $Masked)
        }
        # A runtime version (8.0, 18-lts, 17-java17).
        return ($Head + '|' + (Protect-RdaSiteText $Rest { param($P) $P -cmatch '^[0-9]{1,6}\z' -or $Global:RdaSiteWords.VersionWords.Contains($P) -or $P -cmatch '^(?:java|jre|jdk)[0-9]{1,3}\z' }))
    }
    # The object Azure writes ($Context 'Setting': the siteProperties object itself, or a
    # setting given alone) keeps its keys; its 'properties' and 'metadata' lists hold the
    # settings ('List'). An object {name, value} there (or given alone) whose name is a setting
    # Azure names keeps its name and its value is a setting's. Every other value is 'Other';
    # in an 'Other' object (an app setting's dictionary) the keys are the customer's too.
    $Pairs = $null
    if ($Value -is [System.Collections.IDictionary]) { $Pairs = @(foreach ($Key in @($Value.Keys)) { , @($Key, $Value[$Key]) }) }
    elseif ($Value -is [System.Management.Automation.PSCustomObject]) { $Pairs = @(foreach ($P in $Value.PSObject.Properties) { , @($P.Name, $P.Value) }) }
    if ($null -ne $Pairs)
    {
        $SettingName = $null
        if ($Context -ne 'Other') { foreach ($Pair in $Pairs) { if ([string]$Pair[0] -ieq 'name' -and $Pair[1] -is [string] -and $Global:RdaSiteWords.SettingNames.Contains($Pair[1])) { $SettingName = $Pair[1] } } }
        $Masked = if ($Value -is [System.Collections.Specialized.OrderedDictionary] -or $Value -is [System.Management.Automation.PSCustomObject]) { [ordered]@{} } else { @{} }
        foreach ($Pair in $Pairs)
        {
            $Key = [string]$Pair[0]
            $OutKey = if ($Context -eq 'Setting' -or ($Context -eq 'List' -and $Key -iin 'name', 'value') -or $Key -eq '') { $Pair[0] } else { Protect-RdaSiteText $Key { param($P) $false } }
            $Masked[$OutKey] = if ($null -ne $SettingName -and $Key -ieq 'name') { $Pair[1] }
            elseif ($null -ne $SettingName -and $Key -ieq 'value') { Protect-SitePropertiesValue $Pair[1] 'Setting' }
            elseif ($Context -eq 'Setting' -and $Key -iin 'properties', 'metadata') { Protect-SitePropertiesValue $Pair[1] 'List' }
            else { Protect-SitePropertiesValue $Pair[1] 'Other' }
        }
        if ($Value -is [System.Management.Automation.PSCustomObject]) { return [pscustomobject]$Masked }
        return $Masked
    }
    if ($Value -is [System.Collections.IEnumerable])
    {
        # The comma keeps a list of one (or none) a list.
        return , @(foreach ($Item in $Value) { , (Protect-SitePropertiesValue $Item $Context) })
    }
    return $Value
}

# The shareable diagnostics log keeps no failure message text. An error's text can name
# anything (a resource the report does not hold, a user, a host, a credential), and no
# scrub of free text can be proved complete, so none is attempted: a failure line holds
# its collector, its subscription token and only the closed-list facts read from the
# error OBJECT, never parsed out of its message: the .NET exception type name, the HTTP
# status number, and the Azure error code when it is in $Global:RdaDiagnosticErrorCodes.
# Anything else is dropped. A run and an offline mask write the same line from the same
# functions. The plain local log (the run's debug log) is not changed.
$Global:RdaDiagnosticErrorCodes = @(
    'AuthorizationFailed', 'AuthenticationFailed', 'InvalidAuthenticationToken', 'ExpiredAuthenticationToken',
    'LinkedAuthorizationFailed', 'TooManyRequests', 'Throttled', 'RateLimitExceeded', 'QuotaExceeded',
    'ResourceNotFound', 'ResourceGroupNotFound', 'SubscriptionNotFound', 'NotFound', 'Forbidden', 'BadRequest',
    'Conflict', 'RequestTimeout', 'GatewayTimeout', 'BadGateway', 'ServiceUnavailable', 'InternalServerError',
    'MissingSubscriptionRegistration', 'SubscriptionNotRegistered', 'NoRegisteredProviderFound',
    'InvalidResourceType', 'InvalidApiVersionParameter'
)

# The exception types a line may name: this exact list, nothing else (a type from a customer's
# own assembly, or any other name, is not kept).
$Global:RdaDiagnosticExceptionTypes = @(
    'System.Exception', 'System.AggregateException', 'System.ArgumentException', 'System.ArgumentNullException',
    'System.ArgumentOutOfRangeException', 'System.FormatException', 'System.InvalidCastException',
    'System.InvalidOperationException', 'System.NotSupportedException', 'System.NullReferenceException',
    'System.OperationCanceledException', 'System.OutOfMemoryException', 'System.TimeoutException',
    'System.UnauthorizedAccessException', 'System.Collections.Generic.KeyNotFoundException',
    'System.IO.DirectoryNotFoundException', 'System.IO.FileNotFoundException', 'System.IO.InvalidDataException',
    'System.IO.IOException', 'System.Net.WebException', 'System.Net.Http.HttpRequestException',
    'System.Net.Sockets.SocketException', 'System.Security.Authentication.AuthenticationException',
    'System.Threading.Tasks.TaskCanceledException', 'System.Text.Json.JsonException',
    'System.Management.Automation.CmdletInvocationException', 'System.Management.Automation.ItemNotFoundException',
    'System.Management.Automation.MethodInvocationException', 'System.Management.Automation.ParameterBindingException',
    'System.Management.Automation.PSInvalidOperationException', 'System.Management.Automation.RemoteException',
    'System.Management.Automation.RuntimeException', 'System.Management.Automation.ActionPreferenceStopException',
    'Microsoft.Azure.Commands.Common.Exceptions.AzPSException', 'Azure.RequestFailedException',
    'Azure.Identity.AuthenticationFailedException', 'Microsoft.Rest.Azure.CloudException',
    'Microsoft.Identity.Client.MsalClientException', 'Microsoft.Identity.Client.MsalServiceException',
    'Microsoft.Identity.Client.MsalUiRequiredException', 'Newtonsoft.Json.JsonReaderException',
    'Newtonsoft.Json.JsonSerializationException'
)

# The facts of an error object, as the text a log line holds: 'exception=<type> status=<n> code=<code>',
# each only when the object gives it and it is on the closed list; '' when none.
Function Global:Get-RdaErrorFacts($ErrorRecord)
{
    # Called in a catch block: whatever the object does (a throwing getter, a value that does not
    # fit), the failure being handled must go on, so any error here is 'no facts'.
    try
    {
        $Facts = [System.Collections.Generic.List[string]]::new()
        $Ex = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
        if ($null -eq $Ex) { return '' }
        $Read = { param($Object, [string[]]$Path)
            $Cur = $Object
            foreach ($Name in $Path)
            {
                if ($null -eq $Cur) { return $null }
                $Prop = $Cur.psobject.Properties[$Name]
                if ($null -eq $Prop) { return $null }
                try { $Cur = $Prop.Value } catch { return $null }
            }
            return $Cur
        }
        $TypeName = $Ex.GetType().FullName
        if ($TypeName -cin $Global:RdaDiagnosticExceptionTypes) { $Facts.Add('exception=' + $TypeName) }
        foreach ($Path in @(@('Response', 'StatusCode'), @('StatusCode'), @('Status')))
        {
            $Value = & $Read $Ex $Path
            if ($null -eq $Value -or -not ($Value -is [int] -or $Value -is [System.Enum])) { continue }
            $Number = 0L
            try { $Number = [Convert]::ToInt64($Value) } catch { continue }
            if ($Number -ge 100 -and $Number -le 599) { $Facts.Add('status=' + $Number); break }
        }
        foreach ($Path in @(@('Body', 'Code'), @('Error', 'Code'), @('ErrorCode'), @('Code')))
        {
            $Value = & $Read $Ex $Path
            if ($Value -is [string] -and $Value -cin $Global:RdaDiagnosticErrorCodes) { $Facts.Add('code=' + $Value); break }
        }
        return ($Facts -join ' ')
    }
    catch { return '' }
}

# Facts text as a log line may hold it: each token in the closed grammar, in order, else dropped.
Function Global:Test-RdaDiagnosticFacts([string]$Facts)
{
    # The writer's form only: single-space-separated tokens in this order, each at most once,
    # page and records together; canonical whole numbers; no leading or trailing space.
    if ([string]::IsNullOrEmpty($Facts)) { return $true }
    $Order = @('exception', 'status', 'code', 'page', 'records')
    $At = -1
    foreach ($Part in $Facts.Split(' '))
    {
        if ($Part -cnotmatch '^(exception|status|code|page|records)=(.+)\z') { return $false }
        $Name = $Matches[1]; $Value = $Matches[2]
        $Next = [array]::IndexOf($Order, $Name)
        if ($Next -le $At) { return $false }
        $Valid = switch ($Name)
        {
            'exception' { $Value -cin $Global:RdaDiagnosticExceptionTypes }
            'status' { $Value -cmatch '^[1-5][0-9]{2}\z' }
            'code' { $Value -cin $Global:RdaDiagnosticErrorCodes }
            'page' { $Value -cmatch '^(?:0|[1-9][0-9]{0,8})\z' }
            'records' { $Value -cmatch '^(?:0|[1-9][0-9]{0,11})\z' }
        }
        if (-not $Valid) { return $false }
        $At = $Next
    }
    # page and records come as a pair (the order above puts nothing between them).
    if (($Facts -cmatch '(?:^| )page=') -ne ($Facts -cmatch '(?:^| )records=')) { return $false }
    return $true
}

# What a failure entry prints where its message was: the text is never kept.
Function Global:Get-RdaDiagnosticMessage($Entry)
{
    $Facts = $null
    if ($null -ne $Entry -and $null -ne $Entry.psobject.Properties['Facts']) { $Facts = [string]$Entry.Facts }
    # Where a consumption pull stopped: two whole numbers of the entry, not text.
    if ($null -ne $Entry -and $Facts -cnotmatch 'page=' -and $null -ne $Entry.psobject.Properties['PageAtFailure'] -and $null -ne $Entry.psobject.Properties['RecordsCollected'])
    {
        $Page = 0; $Records = 0L
        if ([int]::TryParse([string]$Entry.PageAtFailure, [ref]$Page) -and [long]::TryParse([string]$Entry.RecordsCollected, [ref]$Records) -and $Page -ge 0 -and $Records -ge 0 -and $Page -le 999999999 -and $Records -le 999999999999)
        {
            $Facts = (($Facts + (' page={0} records={1}' -f $Page, $Records))).Trim()
        }
    }
    if ([string]::IsNullOrEmpty($Facts) -or -not (Test-RdaDiagnosticFacts $Facts)) { return '(message not kept)' }
    return ('(message not kept: {0})' -f $Facts)
}

# A failure entry's subscription as the log writes it: its token when the run has one,
# a label a writer gives ('(auth)', '(unknown)') or nothing, else '<guid>'.
Function Global:Get-RdaDiagnosticSubLabel([string]$Id, [System.Collections.IDictionary]$SubMap)
{
    if ($Id -ceq '(auth)' -or $Id -ceq '(unknown)' -or [string]::IsNullOrEmpty($Id)) { return $Id }
    if ($null -ne $SubMap -and $SubMap.Contains($Id.ToLowerInvariant())) { return [string]$SubMap[$Id.ToLowerInvariant()] }
    return '<guid>'
}

# Resource Graph (the inventory's data path) through Invoke-AzRestMethod, so
# the tool needs only the Az PowerShell modules it already loads: no Azure CLI
# and no Az.ResourceGraph. Invoke-AzRestMethod returns the raw response text,
# which keeps two things `az graph query` gave the callers: -Lowercase can
# lowercase the text before it is parsed (the collectors compare against
# lowercase strings), and a resource whose definition holds an empty-string
# property key ("": ..., user-authored Logic App / policy / template
# definitions) can still be returned. PowerShell 7's ConvertFrom-Json refuses
# such a key, so it is renamed to '_rda_emptykey' before parsing.

# Request one page of a Resource Graph query. Returns a result object instead
# of throwing, because the production $ErrorActionPreference of
# 'SilentlyContinue' suppresses a bare `throw`: { Ok; Content; PageSize;
# Attempts; Error }. Bounded: at most $MaxAttempts transient failures (408,
# 429, 5xx, a request that throws), waiting Retry-After (capped at
# $MaxRetryAfterSeconds) or an exponential backoff with jitter between them.
# 400/401/403/404 and any other non-2xx status fail at once. An answer too
# large for one page (ResponsePayloadTooLarge) is asked for again with half
# the page size, down to one row; the smaller size is returned so later
# pages keep it.
function Invoke-AzGraphPage
{
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $true)][string[]]$SubscriptionId,
        [int]$PageSize = 1000,
        [string]$SkipToken,
        [int]$MaxAttempts = 4,
        [int]$MaxRetryAfterSeconds = 60
    )

    $GraphPath = '/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01'
    $Transient = 0
    $Requests = 0
    $LastError = $null
    # Every transient attempt plus every halving of the page size down to one row.
    $RequestCap = $MaxAttempts + [int][math]::Ceiling([math]::Log([math]::Max($PageSize, 1), 2)) + 1

    for ($Try = 1; $Try -le $RequestCap; $Try++)
    {
        $Options = [ordered]@{ resultFormat = 'objectArray'; '$top' = $PageSize }
        if (-not [string]::IsNullOrEmpty($SkipToken)) { $Options['$skipToken'] = $SkipToken }
        $Body = [ordered]@{ subscriptions = @($SubscriptionId); query = $Query; options = $Options } | ConvertTo-Json -Depth 5 -Compress

        $Requests++
        $Response = $null
        $Thrown = $null
        try { $Response = Invoke-AzRestMethod -Method POST -Path $GraphPath -Payload $Body -ErrorAction Stop }
        catch { $Thrown = $_.Exception }

        $RetryAfter = $null
        $Throttled = $false
        if ($null -eq $Thrown -and $null -ne $Response)
        {
            $Status = [int]$Response.StatusCode
            if ($Status -ge 200 -and $Status -lt 300)
            {
                return [pscustomobject]@{ Ok = $true; Content = [string]$Response.Content; PageSize = $PageSize; Attempts = $Requests; Error = $null }
            }

            $Err = Get-AzGraphErrorInfo -Content ([string]$Response.Content)
            $Described = 'HTTP {0} {1}: {2}' -f $Status, $Err.Code, $Err.Message
            if ($Err.Codes -contains 'ResponsePayloadTooLarge')
            {
                if ($PageSize -le 1)
                {
                    return [pscustomobject]@{ Ok = $false; Content = $null; PageSize = $PageSize; Attempts = $Requests; Error = ('the answer is too large even one row per page (ResponsePayloadTooLarge) after {0} attempt(s): {1}' -f $Requests, $Described) }
                }
                $PageSize = [int][math]::Floor($PageSize / 2)
                continue
            }

            $IsTransient = $Status -eq 408 -or $Status -eq 429 -or $Status -ge 500
            if (-not $IsTransient)
            {
                return [pscustomobject]@{ Ok = $false; Content = $null; PageSize = $PageSize; Attempts = $Requests; Error = ('{0} after {1} attempt(s)' -f $Described, $Requests) }
            }
            $LastError = $Described
            $Throttled = $Status -eq 429
            $RetryAfter = Get-AzGraphRetryAfterSeconds -Headers $Response.Headers
        }
        else
        {
            $LastError = if ($null -ne $Thrown) { 'request failed: ' + $Thrown.Message } else { 'request returned no response' }
        }

        $Transient++
        if ($Transient -ge $MaxAttempts) { break }

        if ($null -ne $RetryAfter)
        {
            $Wait = [math]::Min([math]::Max([math]::Ceiling($RetryAfter), 1), $MaxRetryAfterSeconds)
        }
        else
        {
            # Exponential backoff (1, 2, 4 ...) plus jitter so a wave of
            # throttled calls does not retry in lockstep; throttled calls wait
            # twice as long.
            $Backoff = [math]::Min([math]::Pow(2, $Transient - 1), 30)
            if ($Throttled) { $Backoff = [math]::Min($Backoff * 2, $MaxRetryAfterSeconds) }
            $Wait = [math]::Round($Backoff + (Get-Random -Minimum 0 -Maximum 1000) / 1000.0, 2)
        }
        Start-Sleep -Seconds $Wait
    }

    return [pscustomobject]@{ Ok = $false; Content = $null; PageSize = $PageSize; Attempts = $Requests; Error = ('{0} after {1} attempt(s)' -f $LastError, $Requests) }
}

# The error code and message of a Resource Graph error answer
# ({ error: { code, message, details: [{ code, message }] } }), and every code
# in it (Codes), so a detail code such as ResponsePayloadTooLarge is seen.
function Get-AzGraphErrorInfo
{
    param([string]$Content)
    $Info = [pscustomobject]@{ Code = 'Unknown'; Message = ''; Codes = @() }
    if ([string]::IsNullOrWhiteSpace($Content)) { return $Info }
    try { $Parsed = ConvertFrom-Json -InputObject $Content -ErrorAction Stop }
    catch { $Info.Message = $Content; return $Info }
    $ErrorNode = $Parsed.error
    if ($null -eq $ErrorNode) { $Info.Message = $Content; return $Info }
    $Codes = [System.Collections.Generic.List[string]]::new()
    $Messages = [System.Collections.Generic.List[string]]::new()
    if ($ErrorNode.code) { $Codes.Add([string]$ErrorNode.code) }
    if ($ErrorNode.message) { $Messages.Add([string]$ErrorNode.message) }
    foreach ($Detail in @($ErrorNode.details))
    {
        if ($null -eq $Detail) { continue }
        if ($Detail.code) { $Codes.Add([string]$Detail.code) }
        if ($Detail.message) { $Messages.Add(('{0}: {1}' -f $Detail.code, $Detail.message)) }
    }
    if ($Codes.Count -gt 0) { $Info.Code = ($Codes -join '/') }
    $Info.Message = ($Messages -join ' | ')
    $Info.Codes = $Codes.ToArray()
    return $Info
}

# Best-effort extraction of a SERVER-DIRECTED retry delay (seconds) from a failed Azure cmdlet's error (consumption-retry-after header, else the standard Retry-After) so a throttled caller waits exactly as long as the service asks.
# Handles both RFC 7231 forms (delta-seconds and HTTP-date, parsed invariant/AssumeUniversal); returns >= 0, else 0 so the caller uses its own backoff. NEVER throws - a diagnostics aid must not break the retry loop.
function Get-RdaRetryAfterSeconds
{
    param(
        [Parameter(Mandatory = $true)]$ErrorRecord
    )

    # Priority order: the consumption/billing-specific header first (that is what
    # the Cost Management throttle emits), then the standard HTTP Retry-After.
    $HeaderNames = @('x-ms-ratelimit-microsoft.consumption-retry-after', 'Retry-After')

    try
    {
        # PowerShell may surface the CloudException directly as .Exception or nested
        # under one or more .InnerException levels; walk the chain (bounded).
        $Ex = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
        $Depth = 0
        while ($null -ne $Ex -and $Depth -lt 5)
        {
            $Headers = $null
            $ResponseProp = $Ex.PSObject.Properties['Response']
            if ($ResponseProp -and $null -ne $ResponseProp.Value)
            {
                $HeadersProp = $ResponseProp.Value.PSObject.Properties['Headers']
                if ($HeadersProp) { $Headers = $HeadersProp.Value }
            }

            if ($null -ne $Headers -and $Headers.Keys)
            {
                foreach ($Name in $HeaderNames)
                {
                    # Case-insensitive lookup: HTTP header names are
                    # case-insensitive, but the underlying dictionary is ordinal.
                    $Raw = $null
                    foreach ($Key in $Headers.Keys)
                    {
                        if ($Key -and $Key.Equals($Name, [System.StringComparison]::OrdinalIgnoreCase))
                        {
                            $Raw = @($Headers[$Key])[0]
                            break
                        }
                    }
                    if ([string]::IsNullOrWhiteSpace($Raw)) { continue }

                    $Raw = ([string]$Raw).Trim()

                    # delta-seconds form (what the consumption header uses).
                    $Seconds = 0
                    if ([int]::TryParse($Raw, [ref]$Seconds))
                    {
                        if ($Seconds -lt 0) { $Seconds = 0 }
                        return $Seconds
                    }

                    # HTTP-date form: wait until that instant. Parse with the
                    # invariant culture and AssumeUniversal - RFC 7231 HTTP-dates are
                    # English/GMT, so a non-English-culture host must not fail to parse
                    # them (which would silently degrade to blind backoff).
                    $When = [datetimeoffset]::MinValue
                    if ([datetimeoffset]::TryParse($Raw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$When))
                    {
                        $Delta = [int][math]::Ceiling(($When - [datetimeoffset]::UtcNow).TotalSeconds)
                        if ($Delta -lt 0) { $Delta = 0 }
                        return $Delta
                    }
                }
            }

            $Ex = $Ex.InnerException
            $Depth++
        }
    }
    catch
    {
        # Best-effort only - fall through to 0 so the caller uses its own backoff.
    }

    return 0
}

# Seconds Azure asks to wait before a retry, from Retry-After (seconds or an
# HTTP date) or Resource Graph's x-ms-user-quota-resets-after (hh:mm:ss);
# $null when neither is present. Accepts the HttpResponseHeaders of an
# Invoke-AzRestMethod answer or a dictionary.
function Get-AzGraphRetryAfterSeconds
{
    param($Headers)
    if ($null -eq $Headers) { return $null }
    if ($Headers -is [System.Net.Http.Headers.HttpResponseHeaders] -and $null -ne $Headers.RetryAfter)
    {
        if ($null -ne $Headers.RetryAfter.Delta) { return $Headers.RetryAfter.Delta.TotalSeconds }
        if ($null -ne $Headers.RetryAfter.Date) { return [math]::Max(0, ($Headers.RetryAfter.Date - [DateTimeOffset]::UtcNow).TotalSeconds) }
    }
    foreach ($Name in 'Retry-After', 'x-ms-user-quota-resets-after')
    {
        $Value = $null
        if ($Headers -is [System.Collections.IDictionary])
        {
            foreach ($Key in $Headers.Keys) { if ([string]$Key -ieq $Name) { $Value = @($Headers[$Key])[0] } }
        }
        elseif ($Headers -is [System.Net.Http.Headers.HttpHeaders])
        {
            $Values = $null
            if ($Headers.TryGetValues($Name, [ref]$Values)) { $Value = @($Values)[0] }
        }
        if ([string]::IsNullOrWhiteSpace([string]$Value)) { continue }
        $Text = ([string]$Value).Trim()
        $Seconds = 0.0
        if ([double]::TryParse($Text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$Seconds)) { return $Seconds }
        $Span = [timespan]::Zero
        if ([timespan]::TryParse($Text, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$Span)) { return $Span.TotalSeconds }
        $When = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($Text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$When)) { return [math]::Max(0, ($When - [DateTimeOffset]::UtcNow).TotalSeconds) }
    }
    return $null
}

# Rename every empty-string property KEY ("": ...) in JSON text to
# "_rda_emptykey". JSON strings are matched whole (escapes included), so an
# empty string value, or a "": inside a string, is left alone. When the text
# already holds that name (in any case, since -Lowercase lowercases the text
# afterwards), a numeric suffix is added until the name is unused, so the
# renamed key never collides with a real one and no value is dropped.
function Protect-AzGraphEmptyKey
{
    param([string]$Json)
    if ($Json -notmatch '""\s*:') { return $Json }
    $Sentinel = '_rda_emptykey'
    for ($Suffix = 1; $Json.IndexOf($Sentinel, [System.StringComparison]::OrdinalIgnoreCase) -ge 0; $Suffix++) { $Sentinel = '_rda_emptykey' + $Suffix }
    $Replacement = '"' + $Sentinel + '"'
    return [regex]::Replace($Json, '"(?:[^"\\]|\\.)*"(?=\s*:)', {
            param($Match)
            if ($Match.Value -eq '""') { return $Replacement }
            return $Match.Value
        })
}

# Parse a JSON array of rows (raw text) into PSCustomObjects, rows in order.
function ConvertFrom-AzGraphRowText
{
    param([string]$Json)
    return @(ConvertFrom-Json -InputObject $Json -NoEnumerate -Depth 1024 -ErrorAction Stop)
}

# Parse one Resource Graph answer: { Rows; SkipToken; Truncated }. The skip
# token is read from the untouched text (it is case-sensitive). -Lowercase
# lowercases the rows' text with invariant-culture rules before parsing, as
# the az CLI path did to its output; a row whose lowercased text does not
# parse is kept as returned.
function ConvertFrom-AzGraphPage
{
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content, [switch]$Lowercase)

    # Same nesting limit as ConvertFrom-Json (the JsonDocument default is 64).
    $DocumentOptions = [System.Text.Json.JsonDocumentOptions]::new()
    $DocumentOptions.MaxDepth = 1024
    $Document = [System.Text.Json.JsonDocument]::Parse($Content, $DocumentOptions)
    try
    {
        $Root = $Document.RootElement
        if ($Root.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw 'the answer is not a JSON object' }
        $Element = [System.Text.Json.JsonElement]::new()
        $SkipToken = $null
        if ($Root.TryGetProperty('$skipToken', [ref]$Element) -and $Element.ValueKind -eq [System.Text.Json.JsonValueKind]::String) { $SkipToken = $Element.GetString() }
        $Truncated = $false
        if ($Root.TryGetProperty('resultTruncated', [ref]$Element))
        {
            $Truncated = ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::True) -or ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::String -and $Element.GetString() -ieq 'true')
        }
        if (-not $Root.TryGetProperty('data', [ref]$Element) -or $Element.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) { throw 'the answer has no data array' }
        $RowTexts = @(foreach ($Row in $Element.EnumerateArray()) { $Row.GetRawText() })
    }
    finally
    {
        $Document.Dispose()
    }

    $Rows = $null
    $DataText = Protect-AzGraphEmptyKey -Json ('[' + ($RowTexts -join ',') + ']')
    if ($Lowercase)
    {
        try { $Rows = ConvertFrom-AzGraphRowText -Json $DataText.ToLowerInvariant() }
        catch
        {
            $Rows = @(foreach ($RowText in $RowTexts)
                {
                    $Safe = Protect-AzGraphEmptyKey -Json $RowText
                    try { ConvertFrom-Json -InputObject $Safe.ToLowerInvariant() -NoEnumerate -Depth 1024 -ErrorAction Stop }
                    catch { ConvertFrom-Json -InputObject $Safe -NoEnumerate -Depth 1024 -ErrorAction Stop }
                })
        }
    }
    else
    {
        $Rows = ConvertFrom-AzGraphRowText -Json $DataText
    }

    return [pscustomobject]@{ Rows = $Rows; SkipToken = $SkipToken; Truncated = $Truncated }
}

# Runs a Resource Graph query over the given subscriptions and returns every
# row, in the shape the inventory read from `az graph query`:
# { count; data; skip_token; total_records }, .data holding one PSCustomObject
# per row (none for an empty answer). The subscriptions are always named,
# in batches of at most 1000 (Resource Graph's limit per request); each batch
# is read page by page with the skip token, so the rows come back in the
# query's order within a batch and in batch order across batches. A
# subscription listed twice is queried once; with no subscription no request
# is made. A failure (see Invoke-AzGraphPage) or an answer that cannot be
# parsed throws with the status, the error code and message and the query, so
# the subscription fails loudly (see #22) and never continues with a partial
# or empty page; the throw stops the script even under the production
# 'SilentlyContinue' preference. -Lowercase lowercases each row's text before
# parsing, culture-invariantly (collectors compare against lowercase strings).
# A parse error quotes at most the first 500 characters of the page, and none
# of it with -HideRawOutput (the inventory passes it under -Obfuscate).
function Invoke-AzGraphQuerySafe
{
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$SubscriptionId,
        [switch]$Lowercase,
        [switch]$HideRawOutput,
        [ValidateRange(1, 1000)][int]$PageSize = 1000,
        [ValidateRange(1, 1000)][int]$BatchSize = 1000
    )

    # A throw here must not be suppressed by the caller's preference.
    $ErrorActionPreference = 'Stop'
    # How much of an unparseable page a parse error quotes.
    $RawOutputLimit = 500

    $Seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $Ids = @($SubscriptionId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $Seen.Add($_) })

    $All = [System.Collections.Generic.List[object]]::new()
    # Far above any real answer (10 million rows at 1000 a page); stops a
    # service that never stops handing out skip tokens.
    $MaxPages = 10000
    for ($Offset = 0; $Offset -lt $Ids.Count; $Offset += $BatchSize)
    {
        $Batch = @($Ids[$Offset..([math]::Min($Offset + $BatchSize, $Ids.Count) - 1)])
        $Size = $PageSize
        $Token = $null
        $UsedTokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        for ($PageNumber = 1; $PageNumber -le $MaxPages; $PageNumber++)
        {
            $Page = Invoke-AzGraphPage -Query $Query -SubscriptionId $Batch -PageSize $Size -SkipToken $Token
            if (-not $Page.Ok)
            {
                throw ("Resource Graph query failed: {0}`nQuery: {1}" -f $Page.Error, $Query)
            }
            $Size = $Page.PageSize

            try { $Parsed = ConvertFrom-AzGraphPage -Content $Page.Content -Lowercase:$Lowercase }
            catch
            {
                # The page goes to the log: only its start, and none of it
                # with -HideRawOutput, since it holds resource names and ids.
                # The JSON parser quotes the text it failed on, so its
                # message is shortened (or replaced by the position) too.
                $Raw = [string]$Page.Content
                $Cause = $_.Exception
                while ($null -ne $Cause.InnerException) { $Cause = $Cause.InnerException }
                if ($HideRawOutput)
                {
                    $Reason = if ($Cause -is [System.Text.Json.JsonException]) { 'invalid JSON at line {0}, byte {1}' -f $Cause.LineNumber, $Cause.BytePositionInLine }
                    elseif ($Cause.Message -like 'the answer *') { $Cause.Message }
                    else { $Cause.GetType().FullName }
                    $RawNote = '(not shown: obfuscated run)'
                }
                else
                {
                    $Reason = [string]$Cause.Message
                    if ($Reason.Length -gt $RawOutputLimit) { $Reason = $Reason.Substring(0, $RawOutputLimit) + '...' }
                    $RawNote = if ($Raw.Length -gt $RawOutputLimit) { '{0}... (first {1} of {2} characters)' -f $Raw.Substring(0, $RawOutputLimit), $RawOutputLimit, $Raw.Length } else { $Raw }
                }
                throw ("Resource Graph returned output that could not be parsed as JSON: {0}`nQuery: {1}`nRaw output: {2}" -f $Reason, $Query, $RawNote)
            }
            foreach ($Row in $Parsed.Rows) { $All.Add($Row) }

            if ([string]::IsNullOrEmpty($Parsed.SkipToken))
            {
                if ($Parsed.Truncated) { throw ("Resource Graph truncated the answer and gave no skip token to read the rest; refusing a partial result.`nQuery: {0}" -f $Query) }
                break
            }
            if (-not $UsedTokens.Add($Parsed.SkipToken)) { throw ("Resource Graph handed back a skip token it had already given; stopping instead of reading the same page forever.`nQuery: {0}" -f $Query) }
            $Token = $Parsed.SkipToken
            if ($PageNumber -eq $MaxPages) { throw ("Resource Graph answer is longer than {0} pages; stopping.`nQuery: {1}" -f $MaxPages, $Query) }
        }
    }

    return [pscustomobject]@{ count = $All.Count; data = $All.ToArray(); skip_token = $null; total_records = $All.Count }
}

# The total of a count probe (`... | summarize count()`) across every row of an
# Invoke-AzGraphQuerySafe result: one row per subscription batch. 0 for none.
# A row that is null, or whose count_ is missing, null or not a whole number of
# 0 or more, ends the function with an error, as a failure in
# Invoke-AzGraphQuerySafe does, instead of being read as 0 (or skipped, which
# counts too few), rounded or added as a negative number. An answer with no
# rows at all is still 0. 'Stop' here for the same reason as there: the
# inventory's SilentlyContinue would otherwise let the function go on past the
# throw.
function Get-AzGraphCount
{
    param([Parameter(Mandatory = $true)]$Result)
    $ErrorActionPreference = 'Stop'
    $Total = [long]0
    # Not `$Rows = if ...`: a statement's output is unrolled, so a lone null
    # row would come out as no rows at all.
    $Rows = @()
    if ($null -ne $Result.data) { $Rows = @($Result.data) }
    foreach ($Row in $Rows)
    {
        if ($null -eq $Row) { throw 'Resource Graph returned a count row that is null.' }
        $HasCount = if ($Row -is [System.Collections.IDictionary]) { $Row.Contains('count_') } else { $null -ne $Row.PSObject.Properties['count_'] }
        $Value = [long]0
        if (-not $HasCount -or $null -eq $Row.count_ -or -not [long]::TryParse([string]$Row.count_, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$Value) -or $Value -lt 0)
        {
            # Only the kind of value goes in the message, never the value.
            $Kind = if (-not $HasCount) { 'missing' } elseif ($null -eq $Row.count_) { 'null' } else { 'a {0}' -f $Row.count_.GetType().Name }
            throw ("Resource Graph returned a count (count_, {0}) that is not a whole number of 0 or more." -f $Kind)
        }
        $Total += $Value
    }
    return $Total
}

# The network resource types the Resource Graph pull leaves out. No collector
# reads them (Tests/SkipNetworkResources.Tests.ps1 fails if one ever does),
# they have no Inventory section, and network costs come from the consumption
# data, which is fetched apart from this pull. They are the bulk of the rows
# and of the memory on a large tenant: a virtual network carries every subnet
# with the ip configuration of every network interface in it.
# This is the one copy of the list. -IncludeNetworkResources turns the skip off.
function Get-RdaNetworkSkipList
{
    return @(
        'microsoft.network/virtualnetworks'
        'microsoft.network/networksecuritygroups'
        'microsoft.network/networkinterfaces'
        'microsoft.network/privateendpoints'
        'microsoft.network/privatednszones'
        'microsoft.network/privatednszones/virtualnetworklinks'
        'microsoft.network/routetables'
        'microsoft.network/networkwatchers'
        'microsoft.network/networkwatchers/flowlogs'
        'microsoft.network/applicationsecuritygroups'
        'microsoft.network/ddosprotectionplans'
        'microsoft.network/ipgroups'
        'microsoft.network/connections'
        'microsoft.network/localnetworkgateways'
        'microsoft.network/firewallpolicies'
        'microsoft.network/networkintentpolicies'
        'microsoft.network/privatelinkservices'
    )
}

# The skipped types as a KQL list: ('a', 'b', ...).
function Get-RdaSkippedNetworkTypeList
{
    return '(' + ((Get-RdaNetworkSkipList | ForEach-Object { "'$_'" }) -join ', ') + ')'
}

# The filter the count query and the page query both carry, so the paging
# stays in step with the count. Empty with -IncludeNetworkResources.
function Get-RdaNetworkSkipFilter
{
    param([switch]$IncludeNetworkResources)
    if ($IncludeNetworkResources) { return '' }
    return ' | where type !in~ ' + (Get-RdaSkippedNetworkTypeList)
}

# The fields of a resource the -Obfuscate token loop of ResourceInventory.ps1
# reads: the id (the name hint and the masked id, which Get-ObfuscatedResourceId
# builds from the id alone), the name (its prod_/nonprod_ prefix), the
# subscription id (the subscription name's token) and the resource group (its
# token). Nothing else, so the rows stay small.
function Get-RdaNetworkTokenField
{
    return @('id', 'name', 'resourceGroup', 'subscriptionId')
}

# The id query for the skipped types under -Obfuscate: the same where clause
# as the pull, the opposite type filter, so the pull and this query together
# hold every row the pull held before the skip; only the token loop's fields,
# sorted by the id in lower case like the pull, so the skip-token paging is
# stable. $Where is the scope's own where clause, without 'resources |'.
function Get-RdaNetworkTokenQuery
{
    param([Parameter(Mandatory = $true)][string]$Where)
    return ('resources | where {0} | where type in~ {1} | project {2} | order by tolower(id) asc' -f $Where, (Get-RdaSkippedNetworkTypeList), ((Get-RdaNetworkTokenField) -join ','))
}

# One cheap query: how many rows of each skipped type the scope holds. It only
# feeds the log, so a failure warns once and returns $null; it never fails the
# run and is never retried here (Invoke-AzGraphQuerySafe has its own capped
# retries). $Where is the scope's own where clause, without 'resources |'.
# $ExcludeSubscriptionId: the subscriptions the access check skipped, whose
# rows the pull drops after it is read, so they are not counted either.
# Returns { Total; ByType } with the types lowercase and summed across
# subscription batches.
function Get-RdaSkippedNetworkCount
{
    param(
        [Parameter(Mandatory = $true)][string]$Where,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$SubscriptionId,
        [AllowEmptyCollection()][string[]]$ExcludeSubscriptionId = @(),
        [switch]$HideRawOutput
    )

    $Query = 'resources | where {0} | where type in~ {1} | summarize count() by type, subscriptionId' -f $Where, (Get-RdaSkippedNetworkTypeList)
    try
    {
        $Result = Invoke-AzGraphQuerySafe -Query $Query -SubscriptionId $SubscriptionId -HideRawOutput:$HideRawOutput
    }
    catch
    {
        # The first line only: the rest repeats the query.
        $Reason = ([string]$_.Exception.Message -split "`r?`n")[0]
        Write-Log -Message ("Could not count the skipped network resources ({0}). The run carries on; the log just leaves the skipped count out." -f $Reason) -Severity 'Warning'
        return $null
    }

    $ByType = [ordered]@{}
    $Total = [long]0
    foreach ($Row in @($Result.data))
    {
        if ($null -eq $Row -or $null -eq $Row.count_ -or [string]::IsNullOrEmpty([string]$Row.type)) { continue }
        if (@($ExcludeSubscriptionId) -contains [string]$Row.subscriptionId) { continue }
        $Type = ([string]$Row.type).ToLowerInvariant()
        if (-not $ByType.Contains($Type)) { $ByType[$Type] = [long]0 }
        $ByType[$Type] += [long]$Row.count_
        $Total += [long]$Row.count_
    }
    return [pscustomobject]@{ Total = $Total; ByType = $ByType }
}

# The resource type an ARM id names, lowercase: the provider namespace after
# the last /providers/, then every type segment (the 1st, 3rd, ... segment
# after it). '.../providers/microsoft.network/privatednszones/z/virtualnetworklinks/l'
# gives 'microsoft.network/privatednszones/virtualnetworklinks'. $null when the
# id names no provider type.
function Get-RdaResourceTypeFromId
{
    param([AllowEmptyString()][AllowNull()][string]$Id)
    if ([string]::IsNullOrEmpty($Id)) { return $null }
    $Lower = $Id.ToLowerInvariant()
    $At = $Lower.LastIndexOf('/providers/')
    if ($At -lt 0) { return $null }
    $Parts = @($Lower.Substring($At + '/providers/'.Length).Trim('/') -split '/' | Where-Object { $_ })
    if ($Parts.Count -lt 3) { return $null }
    $Type = [System.Collections.Generic.List[string]]::new()
    $Type.Add($Parts[0])
    for ($i = 1; $i -lt $Parts.Count; $i += 2) { $Type.Add($Parts[$i]) }
    return ($Type -join '/')
}

# The skipped-network count from the id rows of the -Obfuscate id query, which
# already holds every skipped row of the scope: the same { Total; ByType } as
# Get-RdaSkippedNetworkCount, with no extra query. The type comes from the id.
# $ExcludeSubscriptionId: the subscriptions the access check skipped.
function Get-RdaSkippedNetworkCountFromRow
{
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Row,
        [AllowEmptyCollection()][string[]]$ExcludeSubscriptionId = @()
    )
    $ByType = [ordered]@{}
    $Total = [long]0
    foreach ($R in @($Row))
    {
        if ($null -eq $R) { continue }
        if (@($ExcludeSubscriptionId) -contains [string]$R.subscriptionId) { continue }
        $Type = Get-RdaResourceTypeFromId -Id ([string]$R.id)
        if ([string]::IsNullOrEmpty($Type)) { continue }
        if (-not $ByType.Contains($Type)) { $ByType[$Type] = [long]0 }
        $ByType[$Type] += 1
        $Total += 1
    }
    return [pscustomobject]@{ Total = $Total; ByType = $ByType }
}



# Build + write the shareable Diagnostics_*.log that ships INSIDE the per-sub
# report zip. Extracted from ResourceInventory.ps1's packaging section so it can
# run for BOTH obfuscated and default (non-obfuscated) runs - the operator asked
# for a diagnostic log on every run, not just obfuscated ones.
#
# No failure message text is written (see Get-RdaDiagnosticMessage): a line holds
# its collector, its subscription token and the closed-list facts of the error
# object. The subscription is its token in an obfuscated run, '<guid>' otherwise. Written as a HUMAN-READABLE .log (NOT .json) so the ingestion server
# does not table-ingest it; the caller adds it to the zip Path array explicitly.
#
# Wrapped in try/catch and returns the written file path on success or $null on
# failure: the diagnostics log is a troubleshooting aid, not the report, so a
# construction/write error must never break packaging of the actual inventory.
# Reads the health globals ($Global:CollectorFailures / $Global:MetricsFailedSubs
# / $Global:ConsumptionFailedSubs) and obfuscation dictionaries directly; the
# per-run scalars (report name, timestamp, version) and the phase-timing table
# are passed in so the function is self-contained and unit-testable.
function Write-RdaShareableDiagnosticsLog
{
    param(
        [string]$DefaultPath,
        [string]$ReportName,
        [string]$RunDateTime,
        [string]$Version,
        $PhaseTimings,
        [switch]$Obfuscated
    )

    try
    {
        # Subscription GUID -> token, for the entries' subscription label (no failure
        # text is written, so nothing else is looked up). Empty in a default run.
        $DiagSubMap = @{}
        if ($null -ne $Global:ResourceIdDictionary -and $null -ne $Global:ResourceSubscriptionDictionary)
        {
            foreach ($realId in $Global:ResourceIdDictionary.Keys)
            {
                if ($realId -match '(?i)/subscriptions/([^/]+)' -and $Global:ResourceSubscriptionDictionary.ContainsKey($realId) -and -not $DiagSubMap.ContainsKey($Matches[1].ToLowerInvariant()))
                {
                    $DiagSubMap[$Matches[1].ToLowerInvariant()] = $Global:ResourceSubscriptionDictionary[$realId]
                }
            }
        }

        # Phase durations rendered as "Nmin SS sec" (zero-padded seconds), e.g.
        # 245.3s -> "4min 05 sec". Kept as pre-formatted strings so the emit
        # below just prints them.
        $PhaseTimingsText = [ordered]@{}
        if ($null -ne $PhaseTimings)
        {
            foreach ($PhaseName in $PhaseTimings.Keys)
            {
                $PhaseTotalSec = [int][math]::Round(([TimeSpan]$PhaseTimings[$PhaseName]).TotalSeconds)
                $PhaseTimingsText[$PhaseName] = ('{0}min {1:D2} sec' -f [int][math]::Floor($PhaseTotalSec / 60), ($PhaseTotalSec % 60))
            }
        }

        # Health globals. Where-Object { $null -ne $_ } guards the standalone-run
        # case: these are only nil-initialized by the wrapper, so in a direct
        # ResourceInventory.ps1 run they can be $null, and @($null) is a ONE-element
        # array (the single $null) that would otherwise render a phantom "failure"
        # line. Filtering nulls yields a genuine "0" when there were none.
        $CollectorFails = @(@($Global:CollectorFailures) | Where-Object { $null -ne $_ })
        # Metrics skipped for the sign-in, and metrics left incomplete because Azure
        # Monitor kept failing (Complete = $false), each with its own count.
        $MetricsSkips = @(@($Global:MetricsFailedSubs) | Where-Object { $null -ne $_ -and -not (Test-MetricsIncompleteEntry -Entry $_) })
        $MetricsIncomplete = @(Get-MetricsIncompleteEntries -Entries $Global:MetricsFailedSubs)
        $ConsumpSkips = @(@($Global:ConsumptionFailedSubs) | Where-Object { $null -ne $_ })

        $DiagLines = [System.Collections.Generic.List[string]]::new()
        if ($Obfuscated)
        {
            $DiagLines.Add('Resource Discovery for Azure - shareable diagnostics (obfuscated run)')
            $DiagLines.Add('Safe to share: identifiers are obfuscated/masked. Human-readable')
            $DiagLines.Add('troubleshooting log - NOT report data, do not ingest into tables.')
        }
        else
        {
            $DiagLines.Add('Resource Discovery for Azure - diagnostics (default/non-obfuscated run)')
            $DiagLines.Add('NOTE: this bundle is NOT obfuscated - the report itself contains real')
            $DiagLines.Add('identifiers. This log masks GUIDs/emails but treat the whole bundle as')
            $DiagLines.Add('sensitive. Human-readable troubleshooting log - NOT report data, do not')
            $DiagLines.Add('ingest into tables.')
        }
        $DiagLines.Add(('Generated (UTC) : {0}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')))
        $DiagLines.Add(('Tool version    : {0}' -f [string]$Version))
        $DiagLines.Add('')
        $DiagLines.Add('Phase timings:')
        if ($PhaseTimingsText.Count -gt 0)
        {
            foreach ($PhaseName in $PhaseTimingsText.Keys) { $DiagLines.Add(('  {0}: {1}' -f $PhaseName, $PhaseTimingsText[$PhaseName])) }
        }
        else
        {
            $DiagLines.Add('  (none recorded)')
        }
        $DiagLines.Add('')
        $DiagLines.Add(('Collector failures: {0}' -f $CollectorFails.Count))
        foreach ($cfItem in $CollectorFails)
        {
            $DiagLines.Add(('  [sub {0}] {1}: {2}' -f (Get-RdaDiagnosticSubLabel ([string]$cfItem.Id) $DiagSubMap), [string]$cfItem.Module, (Get-RdaDiagnosticMessage $cfItem)))
        }
        $DiagLines.Add('')
        $DiagLines.Add(('Metrics auth-skipped subscriptions: {0}' -f $MetricsSkips.Count))
        foreach ($msItem in $MetricsSkips)
        {
            $DiagLines.Add(('  [sub {0}] {1}' -f (Get-RdaDiagnosticSubLabel ([string]$msItem.Id) $DiagSubMap), (Get-RdaDiagnosticMessage $msItem)))
        }
        $DiagLines.Add('')
        $DiagLines.Add(('Metrics incomplete subscriptions: {0}' -f $MetricsIncomplete.Count))
        foreach ($miItem in $MetricsIncomplete)
        {
            $DiagLines.Add(('  [sub {0}] {1}' -f (Get-RdaDiagnosticSubLabel ([string]$miItem.Id) $DiagSubMap), (Get-RdaDiagnosticMessage $miItem)))
        }
        $DiagLines.Add('')
        $DiagLines.Add(('Consumption failed/incomplete subscriptions: {0}' -f $ConsumpSkips.Count))
        foreach ($csItem in $ConsumpSkips)
        {
            $DiagLines.Add(('  [sub {0}] {1}' -f (Get-RdaDiagnosticSubLabel ([string]$csItem.Id) $DiagSubMap), (Get-RdaDiagnosticMessage $csItem)))
        }

        $DiagnosticsFile = ($DefaultPath + "Diagnostics_" + $ReportName + "_" + $RunDateTime + ".log")
        ($DiagLines -join [Environment]::NewLine) | Out-File -LiteralPath $DiagnosticsFile -Encoding utf8
        Write-Log -Message ('Shareable diagnostics log written: {0}' -f (Split-Path -Path $DiagnosticsFile -Leaf)) -Severity 'Info'
        return $DiagnosticsFile
    }
    catch
    {
        Write-Log -Message ('Could not build/write shareable diagnostics log: {0}' -f $_.Exception.Message) -Severity 'Warning'
        return $null
    }
}

# Zips the report files with the same entries Compress-Archive -Path produces
# (same path resolution, entry names and order), but streams each file into a
# NEW archive. Compress-Archive opens its archive in ZipArchiveMode.Update,
# which keeps every entry's uncompressed bytes in memory until the archive is
# closed, so a large set of metrics JSON files can exhaust memory.
# ZipArchiveMode.Create with CreateEntryFromFile copies each file from disk
# into the archive in chunks.
# The archive is built under a temporary name (.rda-<guid>.partial) in the
# destination folder and moved into place only once complete, so a failure
# never leaves a partial zip at the final name. The temporary name does not end
# in .zip, so the wrapper's *.zip sweep of the output folders never picks one
# up. Like Compress-Archive without -Force, an existing destination is an error
# and is left untouched.
function Compress-RdaReportArchive
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath,

        [ValidateSet('Optimal', 'NoCompression', 'Fastest')]
        [string]$CompressionLevel = 'Optimal'
    )

    # Any failure must reach the caller, whatever its own error preference.
    $ErrorActionPreference = 'Stop'
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.ZipFile

    $DestinationPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($DestinationPath)
    if (Test-Path -LiteralPath $DestinationPath -PathType Leaf)
    {
        throw [System.IO.IOException]::new(('The archive file {0} already exists.' -f $DestinationPath))
    }

    $SeenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Item in $Path)
    {
        if (-not $SeenPaths.Add($Item))
        {
            throw [System.IO.IOException]::new(("The input to the Path parameter contains a duplicate path '{0}'." -f $Item))
        }
    }

    # Wildcards are expanded by Resolve-Path, as in Compress-Archive, so hidden
    # files and matching directories are treated the same way.
    $SourceFiles = [System.Collections.Generic.List[string]]::new()
    $SourceDirs = [System.Collections.Generic.List[string]]::new()
    foreach ($Item in $Path)
    {
        foreach ($Resolved in @(Resolve-Path -Path $Item -ErrorAction Stop))
        {
            $FullPath = $Resolved.ProviderPath
            if (-not ([System.IO.File]::Exists($FullPath) -or [System.IO.Directory]::Exists($FullPath)))
            {
                throw [System.IO.IOException]::new(("The path '{0}' either does not exist or is not a valid file system path." -f $FullPath))
            }
            if (Test-Path -LiteralPath $FullPath -PathType Leaf) { $SourceFiles.Add($FullPath) } else { $SourceDirs.Add($FullPath) }
        }
    }

    # Directory contents come first, named relative to the directory's parent
    # exactly as Compress-Archive 1.2 names them, with empty folders as their
    # own entries; then the files, by file name.
    $Entries = [System.Collections.Generic.List[object]]::new()
    foreach ($SourceDir in $SourceDirs)
    {
        $ParentPath = ([System.IO.DirectoryInfo]::new($SourceDir)).Parent.FullName
        $Prefix = if ($ParentPath.Length -eq 3) { $ParentPath } else { $ParentPath + [System.IO.Path]::DirectorySeparatorChar }
        # -ErrorAction Stop: a folder it cannot list stops the zip, as in Compress-Archive,
        # so a zip is never made without that folder's files.
        foreach ($Child in @(Get-ChildItem -LiteralPath $SourceDir -Recurse -ErrorAction Stop))
        {
            $IsDirectory = $Child -is [System.IO.DirectoryInfo]
            if ($IsDirectory -and $Child.GetFiles().Count -ne 0) { continue }
            $ChildPath = if ($IsDirectory) { $Child.FullName + [System.IO.Path]::DirectorySeparatorChar } else { $Child.FullName }
            $Index = $ChildPath.IndexOf($Prefix, [System.StringComparison]::OrdinalIgnoreCase)
            $RelativePath = $ChildPath.Replace($ChildPath.Substring($Index, $Prefix.Length), '').Trim()
            $Entries.Add([pscustomobject]@{
                    Source      = $Child.FullName
                    Name        = $RelativePath.Replace([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
                    IsDirectory = $IsDirectory
                })
        }
    }
    foreach ($SourceFile in $SourceFiles)
    {
        $Entries.Add([pscustomobject]@{ Source = $SourceFile; Name = [System.IO.Path]::GetFileName($SourceFile); IsDirectory = $false })
    }

    $Level = [System.IO.Compression.CompressionLevel]$CompressionLevel
    # The temporary name has a fixed length (45 characters) that does not
    # depend on the destination name, so any final name the file system
    # accepts also works here.
    $TempName = '.rda-{0}.partial' -f [guid]::NewGuid().ToString('N')
    $TempPath = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($DestinationPath), $TempName)
    $ArchiveStream = $null
    $Archive = $null
    $Moved = $false
    try
    {
        $ArchiveStream = [System.IO.File]::Open($TempPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $Archive = [System.IO.Compression.ZipArchive]::new($ArchiveStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)

        foreach ($Entry in $Entries)
        {
            if ($Entry.IsDirectory)
            {
                $null = $Archive.CreateEntry($Entry.Name, $Level)
            }
            else
            {
                $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Archive, $Entry.Source, $Entry.Name, $Level)
            }
        }

        # Disposing the archive writes the central directory.
        $Archive.Dispose()
        $ArchiveStream.Dispose()

        # As with Compress-Archive, an archive with no entries is not kept.
        if ($Entries.Count -gt 0)
        {
            [System.IO.File]::Move($TempPath, $DestinationPath)
            # The last step that may fail: from here on nothing may fail the call.
            $Moved = $true
        }
    }
    finally
    {
        # Closing twice is harmless after success. After a failure the partial
        # archive is deleted, so an error while closing it must not replace the
        # original error.
        foreach ($Disposable in @($Archive, $ArchiveStream))
        {
            if ($null -eq $Disposable) { continue }
            try { $Disposable.Dispose() } catch { Write-Verbose ('Closing the partial archive failed: {0}' -f $_.Exception.Message) }
        }
        # After the move there is no temporary file to remove. Before it, a failed clean-up
        # only warns, so it never replaces the original error.
        if (-not $Moved)
        {
            try
            {
                if (Test-Path -LiteralPath $TempPath)
                {
                    Remove-Item -LiteralPath $TempPath -Force -ErrorAction SilentlyContinue
                    if (Test-Path -LiteralPath $TempPath) { Write-Warning ("Compress-RdaReportArchive: could not remove the temporary file '{0}'; delete it by hand." -f $TempPath) }
                }
            }
            catch
            {
                Write-Warning ("Compress-RdaReportArchive: could not check or remove the temporary file '{0}': {1}; delete it by hand if it is there." -f $TempPath, $_.Exception.Message)
            }
        }
    }
}
