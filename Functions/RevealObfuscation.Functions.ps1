#Requires -Version 7.0
# =============================================================================
# RevealObfuscation.Functions.ps1
#
# Shared helper functions AND the single-report reveal engine (Invoke-RdaReveal)
# for the reveal feature. Dot-sourced by Reveal.ps1 (and by the child jobs it
# spawns for the multi-subscription path) so they load into that scope.
# Definitions only - no top-level code. Convert-RevealString references
# $Replacements / $tokenPattern / $script:fileHits which Invoke-RdaReveal (its
# caller) establishes before invoking it, so the parent-scope lookup is safe.
# =============================================================================
function ConvertTo-LookupTable
{
    param($MapObject)
    $Table = @{}
    if ($null -ne $MapObject)
    {
        foreach ($Property in $MapObject.PSObject.Properties)
        {
            $Table[$Property.Name] = $Property.Value
        }
    }
    return $Table
}

function Get-RgNameFromResourceId
{
    param([string]$ResourceId)
    if ($ResourceId -match '(?i)/resourceGroups/([^/]+)') { return $Matches[1] }
    return $null
}

function Get-SubGuidFromResourceId
{
    param([string]$ResourceId)
    if ($ResourceId -match '(?i)/subscriptions/([^/]+)') { return $Matches[1] }
    return $null
}

# A folder path in one form for comparing: full, with no trailing separator
# (a root such as '/' or 'C:\' keeps its own). 'root/' and 'root' compare equal.
function ConvertTo-RevealComparablePath
{
    param([string]$Path)
    $Full = [System.IO.Path]::GetFullPath($Path)
    $Trimmed = $Full.TrimEnd('\', '/')
    if ($Trimmed.Length -eq 0 -or $Trimmed -match '^[A-Za-z]:$') { return $Full }
    return $Trimmed
}

# Make a folder readable and writable by its owner only: mode 0700 on Unix,
# and on Windows a protected ACL (no inherited rules) that gives only the
# current user full control. Reveal's staging folder holds real names and ids,
# so it must not stay open to other users of the machine. Throws when the
# folder cannot be set, or does not read back as owner-only.
function Set-RevealOwnerOnlyDirectory
{
    param([Parameter(Mandatory = $true)] [string] $Path)
    if ($IsWindows)
    {
        $User = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $Security = [System.Security.AccessControl.DirectorySecurity]::new()
        $Security.SetAccessRuleProtection($true, $false)
        $Rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $User,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $Security.AddAccessRule($Rule)
        $Directory = [System.IO.DirectoryInfo]::new($Path)
        [System.IO.FileSystemAclExtensions]::SetAccessControl($Directory, $Security)

        $Check = [System.IO.FileSystemAclExtensions]::GetAccessControl($Directory)
        $Rules = @($Check.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        $Others = @($Rules | Where-Object { $_.IdentityReference.Value -ne $User.Value })
        if (-not $Check.AreAccessRulesProtected -or $Rules.Count -eq 0 -or $Others.Count -gt 0)
        {
            throw "Could not make $Path readable by its owner only."
        }
        return
    }

    $ModeType = 'System.IO.UnixFileMode' -as [type]
    if ($null -ne $ModeType -and $null -ne [System.IO.File].GetMethod('SetUnixFileMode', [type[]]@([string], $ModeType)))
    {
        [System.IO.File]::SetUnixFileMode($Path, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
        $Mode = [int][System.IO.File]::GetUnixFileMode($Path)
    }
    else
    {
        # .NET before 7 has no Unix mode calls; use chmod and stat instead.
        & chmod 700 -- $Path
        if ($LASTEXITCODE -ne 0) { throw "Could not make $Path readable by its owner only (chmod ended with $LASTEXITCODE)." }
        $Mode = [Convert]::ToInt32((& stat -c '%a' -- $Path), 8)
    }
    if (($Mode -band 0x1FF) -ne 0x1C0)
    {
        throw ("Could not make {0} readable by its owner only: its mode is {1}." -f $Path, [Convert]::ToString($Mode -band 0x1FF, 8))
    }
}

function Get-JsonEscaped
{
    # Return the input string escaped for placement INSIDE a JSON string literal
    # (ConvertTo-Json wraps + escapes; strip the surrounding quotes).
    param([string]$Text)
    $Json = $Text | ConvertTo-Json -Compress
    return $Json.Substring(1, $Json.Length - 2)
}

# Reveal selected tokens inside a single string. The replacement value is
# escaped to match the destination format so a revealed value containing
# special characters (e.g. a subscription display name with '&', or a
# free-text tag value) stays valid in that file:
#   Json -> escaped for a JSON string literal
#   Html -> HTML-entity encoded (the report encodes every rendered value)
#   None -> raw (CSV field values are re-quoted by Export-Csv instead)
# Tokens not in $Replacements are returned unchanged, so unselected
# dimensions stay masked. Increments $script:fileHits per substituted token.
function Convert-RevealString
{
    param([string]$Text, [string]$EscapeMode = 'None')
    # Fast path: every obfuscation token starts with the literal 'prod_' or
    # 'nonprod_' prefix (plain or type-hinted, e.g. prod_<guid> / prod_aks_<guid>),
    # so text containing neither substring cannot contain a token - return it
    # unchanged and skip the comparatively expensive regex scan. This is the hot
    # path for the large Consumption CSV, whose cells are overwhelmingly dates,
    # numbers and meter names with no token: it turns a per-cell regex sweep over
    # 100k+ rows (minutes) into a substring test. Correctness is unchanged - the
    # regex callback only ever substitutes tokens found in $Replacements, and any
    # skipped text provably has no token to substitute.
    if (-not ($Text.Contains('prod_') -or $Text.Contains('nonprod_')))
    {
        return $Text
    }
    return [regex]::Replace($Text, $TokenPattern, {
            param($m)
            $Tok = $m.Value
            if ($Replacements.ContainsKey($Tok))
            {
                $script:FileHits++
                $Val = $Replacements[$Tok]
                switch ($EscapeMode)
                {
                    'Json' { return (Get-JsonEscaped $Val) }
                    'Html' { return [System.Net.WebUtility]::HtmlEncode($Val) }
                    default { return $Val }
                }
            }
            return $Tok
        })
}

# Whether one scan window of a .json or .csv member holds the sentinel as a
# WHOLE value: a JSON string value exactly equal to it, or a CSV cell exactly
# equal to it (quoted or not). The bare word in other text (a longer string,
# a JSON key, part of a quoted CSV cell) does not count.
#   $AtStart      - the window starts at the start of the member
#   $AtEnd        - the window ends at the end of the member
#   $QuotesBefore - CSV only: the number of '"' in the member before the window
# A match that touches the start or end of a window that is not the member's
# start or end is skipped: the scan carries the end of each window into the
# next one, so such a match is checked there with the characters around it.
function Test-RevealSentinelInText
{
    param(
        [string] $Text,
        [ValidateSet('Json', 'Csv')]
        [string] $Kind,
        [bool]   $AtStart,
        [bool]   $AtEnd,
        [long]   $QuotesBefore = 0
    )
    if (-not $Text.Contains('obfuscated')) { return $false }

    # The value -Obfuscate writes for an id or name it could not mask: the word
    # 'obfuscated', or 'obfuscated_' + a GUID. It has no dictionary entry.
    $Sentinel = 'obfuscated(?:_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})?'

    if ($Kind -eq 'Json')
    {
        # A string value: an opening quote that is not escaped, the sentinel, a
        # closing quote, then (after any white space) the ',' ']' or '}' that
        # ends a value. A key is followed by ':' instead.
        $Pattern = '(?<!\\)"' + $Sentinel + '"(?=\s*[,\]}])'
        foreach ($M in [regex]::Matches($Text, $Pattern))
        {
            if ($M.Index -eq 0 -and -not $AtStart) { continue }
            return $true
        }
        return $false
    }

    # CSV: the cell must start at the start of a line or after ',', end at ','
    # or the end of a line, and lie outside a quoted field (an even number of
    # '"' before it in the member; an escaped '""' keeps the count even).
    $Pattern = '(?<q>"?)' + $Sentinel + '\k<q>'
    $Counted = 0
    $Quotes = $QuotesBefore
    foreach ($M in [regex]::Matches($Text, $Pattern))
    {
        $Start = $M.Index
        $End = $M.Index + $M.Length
        if ($Start -eq 0)
        {
            if (-not $AtStart) { continue }
        }
        elseif (@(',', "`n", "`r") -notcontains [string]$Text[$Start - 1]) { continue }
        if ($End -eq $Text.Length)
        {
            if (-not $AtEnd) { continue }
        }
        elseif (@(',', "`n", "`r") -notcontains [string]$Text[$End]) { continue }

        $Between = $Text.Substring($Counted, $Start - $Counted)
        $Quotes += $Between.Length - $Between.Replace('"', '').Length
        $Counted = $Start
        if ($Quotes % 2 -eq 0) { return $true }
    }
    return $false
}

# Whether a report zip holds any masked value: a prod_/nonprod_ token in any
# member, or the 'obfuscated' sentinel as a whole value in a .json or .csv
# member (see Test-RevealSentinelInText). Used when the dictionary gives
# nothing to reveal, to tell a report with no masked values (a subscription
# with no resources) from one revealed with the wrong dictionary or -Fields.
function Test-RevealZipHasMaskedValue
{
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $TokenPattern
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try
    {
        # Each entry is read in fixed chunks of 64 KB characters, not line by
        # line: Inventory_*.json and Metrics_*.json are written on one line, so a
        # line can be the whole entry. Each chunk is scanned with the last
        # ($MaxTokenLength - 1) characters of the previous chunk in front of it,
        # so a value split across two chunks is still found. $MaxTokenLength
        # (128) covers 'nonprod_' + a type hint of up to 83 characters + '_' + a
        # GUID; the longest hint the tool writes is 'databricks'. The quoted
        # sentinel with a GUID is 49 characters. The scan stops at the first
        # masked value, so at most one chunk plus the carry-over is held in memory.
        $ChunkLength = 65536
        $MaxTokenLength = 128
        $CarryLength = $MaxTokenLength - 1
        $Buffer = [char[]]::new($CarryLength + $ChunkLength)
        foreach ($Entry in $Archive.Entries)
        {
            $Kind = switch ([System.IO.Path]::GetExtension($Entry.FullName).ToLowerInvariant())
            {
                '.json' { 'Json' }
                '.csv' { 'Csv' }
                default { $null }
            }
            $Reader = [System.IO.StreamReader]::new($Entry.Open())
            try
            {
                $Kept = 0
                $AtStart = $true
                $QuotesBefore = [long]0
                while ($true)
                {
                    $Read = $Reader.ReadBlock($Buffer, $Kept, $ChunkLength)
                    $Filled = $Kept + $Read
                    if ($Filled -eq 0) { break }
                    # ReadBlock returns less than asked only at the end of the
                    # stream. A full read is followed by one more, so a stream
                    # that ends on a chunk boundary rescans its carry-over with
                    # $AtEnd set.
                    $AtEnd = $Read -lt $ChunkLength
                    $Text = [string]::new($Buffer, 0, $Filled)
                    if ([regex]::IsMatch($Text, $TokenPattern)) { return $true }
                    if ($null -ne $Kind -and (Test-RevealSentinelInText -Text $Text -Kind $Kind -AtStart $AtStart -AtEnd $AtEnd -QuotesBefore $QuotesBefore))
                    {
                        return $true
                    }
                    if ($AtEnd) { break }
                    $Kept = [Math]::Min($CarryLength, $Filled)
                    if ($Kind -eq 'Csv')
                    {
                        $Dropped = $Text.Substring(0, $Filled - $Kept)
                        $QuotesBefore += $Dropped.Length - $Dropped.Replace('"', '').Length
                    }
                    [Array]::Copy($Buffer, $Filled - $Kept, $Buffer, 0, $Kept)
                    $AtStart = $false
                }
            }
            finally { $Reader.Dispose() }
        }
    }
    finally
    {
        $Archive.Dispose()
    }
    return $false
}


# Every token a dictionary knows: the keys of all its maps, whichever fields
# are selected. A report whose masked values include one of these belongs to
# that dictionary.
function Get-RevealDictionaryTokenSet
{
    param($Dictionary)
    $Tokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($MapName in @('ResourceGroupMap', 'SubscriptionMap', 'SubscriptionNameMap', 'TagMap', 'ResourceIdMap', 'ResourceNameMap', 'FreeTextMap'))
    {
        $Map = $Dictionary.$MapName
        if ($null -eq $Map) { continue }
        foreach ($Property in $Map.PSObject.Properties) { $null = $Tokens.Add([string]$Property.Name) }
    }
    return , $Tokens
}

# Whether a report zip holds at least one prod_/nonprod_ token that is in
# $KnownTokens (see Get-RevealDictionaryTokenSet). Read in the same fixed-size
# chunks as Test-RevealZipHasMaskedValue, with the end of each chunk carried
# into the next, and stops at the first known token.
function Test-RevealZipHasKnownToken
{
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $TokenPattern,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [System.Collections.Generic.HashSet[string]] $KnownTokens
    )
    if ($KnownTokens.Count -eq 0) { return $false }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try
    {
        $ChunkLength = 65536
        $CarryLength = 127
        $Buffer = [char[]]::new($CarryLength + $ChunkLength)
        foreach ($Entry in $Archive.Entries)
        {
            $Reader = [System.IO.StreamReader]::new($Entry.Open())
            try
            {
                $Kept = 0
                while ($true)
                {
                    $Read = $Reader.ReadBlock($Buffer, $Kept, $ChunkLength)
                    $Filled = $Kept + $Read
                    if ($Filled -eq 0) { break }
                    $Text = [string]::new($Buffer, 0, $Filled)
                    foreach ($M in [regex]::Matches($Text, $TokenPattern))
                    {
                        if ($KnownTokens.Contains($M.Value)) { return $true }
                    }
                    if ($Read -lt $ChunkLength) { break }
                    $Kept = [Math]::Min($CarryLength, $Filled)
                    [Array]::Copy($Buffer, $Filled - $Kept, $Buffer, 0, $Kept)
                }
            }
            finally { $Reader.Dispose() }
        }
    }
    finally
    {
        $Archive.Dispose()
    }
    return $false
}

# Whether the dictionary holds any value for the selected fields. When it does
# not, the selection has nothing to reveal in this report.
function Test-RevealDictionaryHasSelectedValue
{
    param($Dictionary, [string[]] $Fields)
    $MapOfField = @{
        ResourceGroup = 'ResourceGroupMap'
        Subscription  = 'SubscriptionMap'
        Tag           = 'TagMap'
        ResourceName  = 'ResourceNameMap'
        ResourceId    = 'ResourceIdMap'
        FreeText      = 'FreeTextMap'
    }
    foreach ($Field in $Fields)
    {
        $Map = $Dictionary.($MapOfField[$Field])
        if ($null -eq $Map) { continue }
        foreach ($Property in $Map.PSObject.Properties)
        {
            if (-not [string]::IsNullOrEmpty([string]$Property.Value)) { return $true }
        }
    }
    return $false
}

# One report of an all-subscriptions reveal (Reveal.ps1 runs this in a child
# job for each folder). The -Fields choice applies to every subscription, and
# one of them may have no value for a selected field (for example -Fields Tag
# and a subscription with no tags). When the report's own dictionary has no
# value for the selected fields, but the report's masked values are in that
# dictionary (so it is the right dictionary), there is nothing to reveal and
# the report is written unchanged. Every other case goes to Invoke-RdaReveal,
# which still fails a report revealed with a dictionary it has no entry in.
function Invoke-RdaRevealFolder
{
    param(
        [Parameter(Mandatory = $true)] [string]   $InputZip,
        [Parameter(Mandatory = $true)] [string]   $DictionaryPath,
        [Parameter(Mandatory = $true)] [string[]] $Fields,
        [Parameter(Mandatory = $true)] [string]   $OutputZip
    )
    $ErrorActionPreference = 'Stop'
    $Dict = Get-Content -LiteralPath $DictionaryPath -Raw | ConvertFrom-Json
    if (-not (Test-RevealDictionaryHasSelectedValue -Dictionary $Dict -Fields $Fields))
    {
        $TokenPattern = Get-RevealTokenPattern
        if ((Test-RevealZipHasMaskedValue -Path $InputZip -TokenPattern $TokenPattern) -and
            (Test-RevealZipHasKnownToken -Path $InputZip -TokenPattern $TokenPattern -KnownTokens (Get-RevealDictionaryTokenSet $Dict)))
        {
            Copy-RevealZipUnchanged -InputZip $InputZip -OutputZip $OutputZip
            Write-Host ("Nothing to reveal: this report's dictionary has no value for the selected field(s) [{0}]. Wrote an unchanged copy." -f ($Fields -join ', ')) -ForegroundColor Yellow
            return
        }
    }
    Invoke-RdaReveal -InputZip $InputZip -DictionaryPath $DictionaryPath -Fields $Fields -OutputZip $OutputZip
}

# The prod_/nonprod_ token shapes: plain prod_/nonprod_<guid> and type-hinted
# name tokens (prod_aks_<guid>, etc.).
function Get-RevealTokenPattern
{
    return '(?:prod|nonprod)_(?:[a-z0-9]+_)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
}

# Write an unchanged copy of a report: copy to a sibling .partial.zip, then
# move it into place, the same atomic swap a revealed zip gets.
function Copy-RevealZipUnchanged
{
    param([string] $InputZip, [string] $OutputZip)
    $OutputZipPartial = ($OutputZip -replace '\.zip$', '') + '.partial.zip'
    [System.IO.File]::Copy($InputZip, $OutputZipPartial, $true)
    [System.IO.File]::Move($OutputZipPartial, $OutputZip, $true)
}

# =============================================================================
# Invoke-RdaReveal
#
# The single-report reveal ENGINE, moved here from the former standalone
# Reveal-Obfuscation.ps1 so the whole reveal feature lives in ONE entry script
# (Reveal.ps1) that handles both a single report and a whole multi-subscription
# tree. Takes one obfuscated report zip + its dictionary, rewrites ONLY the
# selected dimensions' tokens back to real values, and re-zips with the same
# structure.
#
# Scope note: this function sets $Replacements and $tokenPattern as LOCALS and
# calls Convert-RevealString, which reads them via PowerShell's parent-scope
# (dynamic) variable lookup, and increments $script:fileHits (the dot-sourcing
# entry script's script scope). That is the same contract the old top-level
# script provided - just nested one function deep - so the helpers behave
# identically. Raises terminating errors via throw (never exit) so a caller /
# Start-Job can catch them.
# =============================================================================
function Invoke-RdaReveal
{
    [CmdletBinding()]
    # $TokenPattern is assigned below and read by Convert-RevealString via
    # PowerShell parent-scope (dynamic) variable lookup, which PSScriptAnalyzer
    # cannot follow across the function boundary - so it false-positives
    # PSUseDeclaredVarsMoreThanAssignments. Suppress that one finding here.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'TokenPattern',
        Justification = 'Read cross-scope by Convert-RevealString via parent-scope dynamic lookup.')]
    param(
        [Parameter(Mandatory = $true)]
        [string]   $InputZip,

        [string]   $DictionaryPath,
        [string]   $SearchDirectory = '.',

        [ValidateSet('ResourceGroup', 'Subscription', 'Tag', 'ResourceName', 'ResourceId', 'FreeText')]
        [string[]] $Fields = @('ResourceGroup', 'Subscription'),

        [switch]   $All,

        [string]   $OutputZip
    )

    $ErrorActionPreference = 'Stop'

    # ---- Resolve inputs ----------------------------------------------------
    # Every exact path below goes to -LiteralPath: -Path reads '[' and ']' as a
    # wildcard, so 'report[1]' would match a neighbour named 'report1'.
    # Split-Path -Parent (which takes only -Path) and New-Item -Path work on
    # the text of the path and do not expand wildcards, so they stay as they are.
    # The .NET zip and file calls below resolve a relative path against the
    # process folder, not the PowerShell location, so make both zip paths
    # full paths against the PowerShell location once, here.
    $InputZip = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InputZip)
    if (-not [string]::IsNullOrEmpty($OutputZip))
    {
        $OutputZip = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputZip)
    }

    if (-not (Test-Path -LiteralPath $InputZip -PathType Leaf))
    {
        throw "Input zip not found: $InputZip"
    }

    if ([string]::IsNullOrEmpty($DictionaryPath))
    {
        $DictionaryPath = Get-ChildItem -LiteralPath $SearchDirectory -Filter 'ObfuscationDictionary_*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ([string]::IsNullOrEmpty($DictionaryPath) -or -not (Test-Path -LiteralPath $DictionaryPath -PathType Leaf))
    {
        throw "No ObfuscationDictionary_*.json found. Pass -DictionaryPath, or run from the folder that holds it."
    }

    if ([string]::IsNullOrEmpty($OutputZip))
    {
        $InDir = Split-Path -Path $InputZip -Parent
        $InBase = [System.IO.Path]::GetFileNameWithoutExtension($InputZip)
        $OutputZip = Join-Path $InDir ($InBase + '_revealed.zip')
    }

    # -All is a convenience for a full reveal: expand to every dimension the
    # dictionary can reverse (overriding -Fields). NOTE this is NOT a perfect
    # undo of -Obfuscate: fields that were nulled or stamped with the lossy
    # 'obfuscated' sentinel are destroyed at obfuscation time. Everything stored
    # in the dictionary comes back.
    if ($All)
    {
        $Fields = @('ResourceGroup', 'Subscription', 'Tag', 'ResourceName', 'ResourceId', 'FreeText')
    }

    Write-Host ("Input zip   : {0}" -f $InputZip)
    Write-Host ("Dictionary  : {0}" -f $DictionaryPath)
    Write-Host ("Reveal      : {0}{1}" -f ($Fields -join ', '), $(if ($All) { ' (-All: full reveal)' } else { '' }))
    Write-Host ("Output zip  : {0}" -f $OutputZip)

    # ---- Load dictionary ---------------------------------------------------
    $Dict = Get-Content -LiteralPath $DictionaryPath -Raw | ConvertFrom-Json

    $RgMap = ConvertTo-LookupTable $Dict.ResourceGroupMap
    $SubMap = ConvertTo-LookupTable $Dict.SubscriptionMap
    $SubNameMap = ConvertTo-LookupTable $Dict.SubscriptionNameMap
    $TagMap = ConvertTo-LookupTable $Dict.TagMap
    $IdMap = ConvertTo-LookupTable $Dict.ResourceIdMap
    $NameMap = ConvertTo-LookupTable $Dict.ResourceNameMap
    $FreeTextMap = ConvertTo-LookupTable $Dict.FreeTextMap

    # ---- Build token -> real-value replacement map for selected fields -----
    $Replacements = @{}
    $Skipped = @{}

    if ($Fields -contains 'ResourceGroup')
    {
        foreach ($token in $RgMap.Keys)
        {
            $RgName = Get-RgNameFromResourceId $RgMap[$token]
            if (-not [string]::IsNullOrEmpty($RgName)) { $Replacements[$token] = $RgName }
        }
    }

    if ($Fields -contains 'Subscription')
    {
        foreach ($token in $SubMap.Keys)
        {
            $Real = $null
            if ($SubNameMap.ContainsKey($token) -and -not [string]::IsNullOrEmpty($SubNameMap[$token]))
            {
                $Real = $SubNameMap[$token]
            }
            else
            {
                $Real = Get-SubGuidFromResourceId $SubMap[$token]
                if (-not [string]::IsNullOrEmpty($Real)) { $Skipped['SubscriptionName'] = $true }
            }
            if (-not [string]::IsNullOrEmpty($Real)) { $Replacements[$token] = $Real }
        }
    }

    if ($Fields -contains 'Tag')
    {
        if ($TagMap.Count -eq 0)
        {
            Write-Warning "Tag reveal requested but the dictionary has no TagMap (tags were not obfuscated in this run). Skipping Tag."
        }
        foreach ($token in $TagMap.Keys)
        {
            if (-not [string]::IsNullOrEmpty($TagMap[$token])) { $Replacements[$token] = $TagMap[$token] }
        }
    }

    if ($Fields -contains 'ResourceName')
    {
        # ResourceNameMap stores token -> real resource Id; the short name is the
        # last '/'-delimited segment of that Id.
        foreach ($token in $NameMap.Keys)
        {
            $Name = ($NameMap[$token] -split '/')[-1]
            if (-not [string]::IsNullOrEmpty($Name)) { $Replacements[$token] = $Name }
        }
    }

    if ($Fields -contains 'ResourceId')
    {
        # ResourceIdMap stores token -> the full real ARM resource Id. Revealing
        # this also exposes the subscription GUID and resource group name in the
        # path - inherent to revealing the Id and the caller's choice.
        foreach ($token in $IdMap.Keys)
        {
            if (-not [string]::IsNullOrEmpty($IdMap[$token])) { $Replacements[$token] = $IdMap[$token] }
        }
    }

    if ($Fields -contains 'FreeText')
    {
        # FreeTextMap stores token -> the real free-form value (Description,
        # FriendlyName, CreatedBy, RoleName, container image, etc.).
        foreach ($token in $FreeTextMap.Keys)
        {
            if (-not [string]::IsNullOrEmpty($FreeTextMap[$token])) { $Replacements[$token] = $FreeTextMap[$token] }
        }
    }

    if ($Skipped.ContainsKey('SubscriptionName'))
    {
        Write-Warning "One or more subscriptions had no friendly name in the dictionary (older -Obfuscate run); revealed the subscription GUID instead. Re-run the inventory with a current version to capture SubscriptionNameMap."
    }

    # Token shapes: plain prod_/nonprod_<guid> and type-hinted name tokens
    # (prod_aks_<guid>, etc.) - the regex matches both; the callback only
    # substitutes tokens present in $Replacements, so non-selected dimensions
    # are left masked.
    $TokenPattern = Get-RevealTokenPattern

    if ($Replacements.Count -eq 0)
    {
        # The report of a subscription with no resources carries no masked
        # values, and its dictionary is empty. It has nothing to reveal and is
        # not a failure: write an unchanged copy, so the revealed bundle keeps
        # every subscription. A report that does carry masked values with no
        # mapping for the selected fields is still an error (wrong dictionary
        # or wrong -Fields).
        $HasToken = Test-RevealZipHasMaskedValue -Path $InputZip -TokenPattern $TokenPattern

        if ($HasToken)
        {
            throw "Nothing to reveal: the selected field(s) [$($Fields -join ', ')] produced no token mappings from this dictionary."
        }

        # Same atomic swap as a revealed zip below: copy to .partial.zip, then move.
        Copy-RevealZipUnchanged -InputZip $InputZip -OutputZip $OutputZip
        Write-Host ""
        Write-Host "Nothing to reveal: this report carries no masked values (for example a subscription with no resources). Wrote an unchanged copy." -ForegroundColor Yellow
        Write-Host ("Output: {0}" -f $OutputZip) -ForegroundColor Green
        return
    }

    Write-Host ("Tokens to reveal: {0}" -f $Replacements.Count)

    # ---- Extract, rewrite, re-zip ------------------------------------------

    $TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("Reveal_" + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $TmpRoot -Force | Out-Null

    try
    {
        # Phase progress (Expanding -> Scanning -> Compressing) so a single
        # report's reveal is not a black box while the opaque extract / compress
        # steps run. Uses the shared Write-RdaProgress when it is
        # loaded (single-report mode via Reveal.ps1, which dot-sources
        # Common.Functions); in the all-subscriptions child job the helper is
        # absent AND the job's output is suppressed, so guard on its presence and
        # no-op there (the wrapper shows a per-folder heartbeat instead).
        $EmitProgress = [bool](Get-Command -Name Write-RdaProgress -ErrorAction SilentlyContinue)
        if ($EmitProgress) { Write-RdaProgress -Activity 'Revealing report' -CurrentItem 'Expanding archive' -Index 1 -Total 3 }
        # Use System.IO.Compression directly instead of Expand-Archive /
        # Compress-Archive: the cmdlets are markedly slower (a multi-MB report can
        # take minutes to re-zip), whereas ZipFile.ExtractToDirectory /
        # CreateFromDirectory do the same work in a fraction of the time and
        # produce the same flat archive layout. $TmpRoot was just created empty,
        # so extraction has nothing to overwrite.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($InputZip, $TmpRoot)

        $TotalHits = 0
        $Files = Get-ChildItem -LiteralPath $TmpRoot -Recurse -File
        if ($EmitProgress) { Write-RdaProgress -Activity 'Revealing report' -CurrentItem ('Scanning {0} member file(s)' -f @($Files).Count) -Index 2 -Total 3 }
        foreach ($file in $Files)
        {
            $script:FileHits = 0
            $Ext = $file.Extension.ToLowerInvariant()

            if ($Ext -eq '.csv')
            {
                # Field-aware reveal: re-export through the CSV writer so a
                # revealed value containing a comma/quote is correctly quoted and
                # cannot break the column structure a raw text replace could.
                $Rows = @(Import-Csv -LiteralPath $file.FullName)
                if ($Rows.Count -gt 0)
                {
                    foreach ($row in $Rows)
                    {
                        foreach ($prop in $row.PSObject.Properties)
                        {
                            if ($null -ne $prop.Value -and $prop.Value -is [string] -and $prop.Value.Length -gt 0)
                            {
                                $prop.Value = Convert-RevealString -Text $prop.Value -EscapeMode 'None'
                            }
                        }
                    }
                    if ($script:FileHits -gt 0)
                    {
                        $Rows | Export-Csv -LiteralPath $file.FullName -NoTypeInformation -Encoding utf8
                    }
                }
            }
            else
            {
                $Content = Get-Content -LiteralPath $file.FullName -Raw
                if ([string]::IsNullOrEmpty($Content)) { continue }

                $EscapeMode = switch ($Ext)
                {
                    '.json' { 'Json' }
                    '.html' { 'Html' }
                    '.htm' { 'Html' }
                    default { 'None' }
                }
                $NewContent = Convert-RevealString -Text $Content -EscapeMode $EscapeMode

                if ($script:FileHits -gt 0)
                {
                    Set-Content -LiteralPath $file.FullName -Value $NewContent -Encoding utf8 -NoNewline
                }
            }

            if ($script:FileHits -gt 0)
            {
                $TotalHits += $script:FileHits
                Write-Host ("  {0}: revealed {1} token occurrence(s)" -f $file.Name, $script:FileHits)
            }
        }

        # The selected fields have entries, but none of them was found in the
        # report. If the report still holds masked values and none of them is
        # in any map of this dictionary, the dictionary belongs to another
        # report: fail instead of writing the still masked report as revealed.
        # When some masked value is in the dictionary, it is this report's own
        # dictionary and the selected fields simply have nothing in this
        # report, so the (unchanged) report is written. A report with no masked
        # value at all is written unchanged, as above.
        if ($TotalHits -eq 0 -and
            (Test-RevealZipHasMaskedValue -Path $InputZip -TokenPattern $TokenPattern) -and
            -not (Test-RevealZipHasKnownToken -Path $InputZip -TokenPattern $TokenPattern -KnownTokens (Get-RevealDictionaryTokenSet $Dict)))
        {
            if ($EmitProgress) { Write-RdaProgress -Activity 'Revealing report' -Completed }
            throw "Nothing to reveal: the report holds masked values, but the selected field(s) [$($Fields -join ', ')] have no mapping in this dictionary for any of them. Check that the dictionary belongs to this report."
        }

        # Atomic output: compress to a sibling *.partial.zip, then swap it into
        # place with File.Move(overwrite). A same-volume move is a rename, so a
        # hard kill (SIGKILL / shell timeout) DURING compression can never leave a
        # truncated zip at $OutputZip. This matters for the all-subscriptions
        # reveal (Reveal.ps1), which records each output zip once it is complete,
        # puts in the outer zip only the outputs on its own list for the run
        # (never every *.zip in staging), and on -Resume checks a staged zip
        # against that record: a partial file left at the FINAL name would look
        # like a finished output. The .partial.zip name is never on that list,
        # so only the completed archive ever appears at $OutputZip. The
        # Remove-Item below is required because
        # ZipFile.CreateFromDirectory throws if the destination already exists.
        if ($EmitProgress) { Write-RdaProgress -Activity 'Revealing report' -CurrentItem 'Compressing output' -Index 3 -Total 3 }
        $OutputZipPartial = ($OutputZip -replace '\.zip$', '') + '.partial.zip'
        if (Test-Path -LiteralPath $OutputZipPartial) { Remove-Item -LiteralPath $OutputZipPartial -Force }
        # includeBaseDirectory = $false so the archive entries sit at the root
        # (the members of $TmpRoot), matching the previous
        # Compress-Archive -Path "$TmpRoot\*" layout the ingestion server expects.
        [System.IO.Compression.ZipFile]::CreateFromDirectory($TmpRoot, $OutputZipPartial, [System.IO.Compression.CompressionLevel]::Optimal, $false)
        [System.IO.File]::Move($OutputZipPartial, $OutputZip, $true)
        if ($EmitProgress) { Write-RdaProgress -Activity 'Revealing report' -Completed }

        Write-Host ""
        Write-Host ("Done. Revealed {0} token occurrence(s) across {1} member file(s)." -f $TotalHits, @($Files).Count) -ForegroundColor Green
        Write-Host ("Output: {0}" -f $OutputZip) -ForegroundColor Green
        if ($All)
        {
            Write-Host "Full reveal: all dictionary-backed dimensions restored. Fields nulled at obfuscation time (e.g. Description) or marked 'obfuscated' are lossy and remain so." -ForegroundColor Yellow
        }
        Write-Host "This zip contains the real values you chose to reveal - share only with the intended ingestion party."
    }
    finally
    {
        if (Test-Path -LiteralPath $TmpRoot) { Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
