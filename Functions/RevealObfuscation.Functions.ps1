#Requires -Version 7.0
# =============================================================================
# RevealObfuscation.Functions.ps1
#
# Shared helper functions AND the single-report reveal engine (Invoke-RdaReveal)
# for the reveal feature. Dot-sourced by Reveal.ps1 (and by the child jobs it
# spawns for the multi-subscription path) so they load into that scope.
# Definitions only, but for two steps on load: it checks that
# Functions/DictionaryTimeText.Functions.ps1 and then
# Functions/IdText.Functions.ps1 are next to it (throws if not, and the throw
# stops the caller under any $ErrorActionPreference) and dot-sources them. The
# first defines Restore-DictionaryTimeText; the second (definitions only) gives
# the rule for where a whole id ends in a text (Get-RdaIdEndMark,
# Get-RdaIdBeforeCloseParen), which the offline mask reads ids by, so Reveal
# reads one id in a text as the offline mask does. Convert-RevealString references
# $Replacements / $tokenPattern / $script:fileHits which Invoke-RdaReveal (its
# caller) establishes before invoking it, so the parent-scope lookup is safe.
# =============================================================================
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'DictionaryTimeText.Functions.ps1') -PathType Leaf))
{
    # A plain throw is skipped when the caller runs with $ErrorActionPreference
    # 'SilentlyContinue' or 'Ignore'; thrown from a child scope set to Stop, it
    # stops the caller under any preference, and the caller's own is left as it was.
    & {
        $ErrorActionPreference = 'Stop'
        throw ("RevealObfuscation.Functions.ps1: required file not found: {0}. Keep the Functions folder together." -f (Join-Path $PSScriptRoot 'DictionaryTimeText.Functions.ps1'))
    }
}
. (Join-Path $PSScriptRoot 'DictionaryTimeText.Functions.ps1')
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'IdText.Functions.ps1') -PathType Leaf))
{
    # Thrown as above, so it stops the caller under any preference.
    & {
        $ErrorActionPreference = 'Stop'
        throw ("RevealObfuscation.Functions.ps1: required file not found: {0}. Keep the Functions folder together." -f (Join-Path $PSScriptRoot 'IdText.Functions.ps1'))
    }
}
. (Join-Path $PSScriptRoot 'IdText.Functions.ps1')

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

# The group of a subscription id ('/subscriptions/<id>/resourceGroups/<group>/...'),
# as the masking reads it. A tenant-scope id ('/providers/...') has none: a
# 'resourceGroups' segment there is a type word.
# Accepted gap: older builds of this fork read the segment after a segment 3
# 'resourceGroups' in a tenant-scope id ('/providers/<namespace>/resourceGroups/<x>') as a
# group slot and gave it the token of group <x>, so their ResourceIdMap holds that masked
# id, and ResourceGroupMap can map the token to that tenant-scope id (the writer keeps the
# last id it meets for a token). Reveal reads no group from such a ResourceGroupMap entry,
# so that token stays masked in ResourceGroup fields and in id paths; with -Fields
# ResourceId the tenant-scope id, and every other id ResourceIdMap holds, still comes back
# whole (Convert-RevealString). The slot check takes that token in that one name slot when
# its real value there is the group's (Get-RdaRevealSharedToken), and stops on any other
# use of a group's token as a name. This is accepted because no provider is known to bill
# such an id, and a run of this build no longer gives such an id a group's token, so its
# dictionary has no such entry.
function Get-RgNameFromResourceId
{
    param([string]$ResourceId)
    if ($ResourceId -match '(?i)^/subscriptions/[^/]+/resourceGroups/([^/]+)') { return $Matches[1] }
    return $null
}

function Get-SubGuidFromResourceId
{
    param([string]$ResourceId)
    if ($ResourceId -match '(?i)/subscriptions/([^/]+)') { return $Matches[1] }
    return $null
}

# The tokens a dictionary gives to more than one map, ignoring case, as Reveal looks a token
# up. Reveal puts a token's value wherever the token stands: in any field, and in a
# subscription, group or name segment of an id. So a token that two maps hold (a tag value's
# token that is also a resource name's: a dictionary changed or merged by hand) would write
# one map's value into the other's fields and ids, and -Fields would reveal a field it does
# not name. A run gives every subscription, group, name, flat id, tag value and free-text
# value a new token of its own. The one pair that holds the same tokens by design is
# SubscriptionMap and SubscriptionNameMap: both are keyed by a subscription's token (its id
# in one, its display name in the other), so they count as one map here. $Maps is map name ->
# lookup table; every map Reveal reads is passed, whatever -Fields selects. Returns one entry
# per shared token, with the maps that hold it, never a real value (InIds $false).
# A path-shaped ResourceIdMap key (a masked id, '/...') holds tokens of its own, so it is
# then read slot by slot against its real id: the subscription slot ('/subscriptions/<token>'),
# the group slot (only '/subscriptions/<id>/resourceGroups/<token>', as the masking reads it)
# and every other token, which is a name. A slot is of the kind of SubscriptionMap,
# ResourceGroupMap or ResourceNameMap, and its real value is the real id's part at its place.
# Reveal writes a token's path value in a slot and its map value in every field that holds it,
# so each token must stand for one kind of value and one real value, ignoring case, in every
# map and slot: a group's token as a resource's name in an id would reveal that resource's
# Name with -Fields ResourceGroup and write the group into the id. A map's value is the one
# Reveal writes in a slot (the subscription id of a SubscriptionMap id, the group of a
# ResourceGroupMap id, the last part of a ResourceNameMap id); a subscription's token in a
# subscription slot, a group's in a group slot and a name's in a name slot are its own. Values
# are compared only where the masked and the real id have as many parts. In a key whose parts
# do not line up, the real part at a token's place cannot be read, so a token a map holds there
# in its own kind of slot is returned with Why 'parts' (a run writes every masked id with as
# many parts as its real id, or as one flat token); a token no map holds is only kind-checked
# there, as Reveal writes no value for it. Each such token is returned once, with InIds $true,
# the two places (its map and the slot, for 'parts') and Why ('kind', 'value' or 'parts').
# One value clash is not a fault of the dictionary: older builds keyed a subscription's token
# by its display name (the upstream main branch, and this fork's builds before the token was
# keyed by the subscription id), so two subscriptions with one display name share one token,
# which their ids hold in the subscription slot for two subscription ids. Such a token, which
# SubscriptionMap and SubscriptionNameMap both hold, with a name, and which the subscription
# slots hold for two or more subscription ids (GUIDs) and nothing else, is returned with Why
# 'name' instead: its display name is right for every one of them, but no one subscription id
# is, so Reveal keeps it masked in an id path. Its kind is still checked in every slot. The
# same token with no display name (a dictionary from before SubscriptionNameMap existed) is
# returned with Why 'noname': no single value fits every place it stands, so Reveal stops on it,
# with a message that says so. Any other value clash in a subscription slot is returned as
# 'value', once every id is read.
# One kind clash is not a fault either: older builds of this fork gave the name after a
# segment 3 'resourceGroups' in a tenant-scope id the token of that group (see
# Get-RgNameFromResourceId). A token ResourceGroupMap holds is taken in that one name slot
# when its real value there is the group's; any other kind clash is returned.
function Get-RdaRevealSharedToken
{
    param([System.Collections.IDictionary]$Maps)

    $FirstMap = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $Shared = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($MapName in @($Maps.Keys))
    {
        $Table = $Maps[$MapName]
        if ($null -eq $Table) { continue }
        $Owner = if ($MapName -ceq 'SubscriptionNameMap') { 'SubscriptionMap' } else { [string]$MapName }
        foreach ($Token in $Table.Keys)
        {
            $Seen = $null
            if (-not $FirstMap.TryGetValue([string]$Token, [ref]$Seen)) { $FirstMap[[string]$Token] = [string]$MapName; continue }
            $SeenOwner = if ($Seen -ceq 'SubscriptionNameMap') { 'SubscriptionMap' } else { $Seen }
            if ($SeenOwner -ceq $Owner) { continue }
            $List = $null
            if (-not $Shared.TryGetValue([string]$Token, [ref]$List))
            {
                $List = [System.Collections.Generic.List[string]]::new()
                $List.Add($Seen)
                $Shared[[string]$Token] = $List
            }
            if (-not $List.Contains([string]$MapName)) { $List.Add([string]$MapName) }
        }
    }
    foreach ($Token in $Shared.Keys) { [pscustomobject]@{ Token = $Token; Maps = @($Shared[$Token]); InIds = $false; Why = 'map' } }

    # ---- The tokens inside the ids of ResourceIdMap ----
    $IdTable = $Maps['ResourceIdMap']
    if ($null -eq $IdTable) { return }
    $Ignore = [System.StringComparison]::OrdinalIgnoreCase
    $TokenRx = [regex]::new('^(?:prod|nonprod)_(?:[a-z0-9]+_)*[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z', 'IgnoreCase, CultureInvariant')
    $SlotPlace = @{ SubscriptionMap = 'the subscription slot of a ResourceIdMap id'; ResourceGroupMap = 'the group slot of a ResourceIdMap id'; ResourceNameMap = 'a name slot of a ResourceIdMap id' }
    # Token -> @(kind, place of the kind, real value or $null, place of the value), set at
    # the first slot that holds the token: the kind is its map's when a map holds it, else
    # that slot's, and the value its map's when the map gives one, else that slot's real part.
    # The kind is '' once the token is returned (or was, above), so it is not read again.
    $Of = [System.Collections.Generic.Dictionary[string, object[]]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $Clash = [System.Collections.Generic.List[object]]::new()
    # Subscription token -> the real values its subscription slots hold, and its first value
    # clash there (the two places), kept until every id is read (the older builds above).
    $SubSlots = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.HashSet[string]]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $SubClash = [System.Collections.Generic.Dictionary[string, string[]]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Entry in $IdTable.GetEnumerator())
    {
        $Masked = [string]$Entry.Key
        if (-not $Masked.StartsWith('/')) { continue }
        $M = $Masked.Split('/')
        $R = ([string]$Entry.Value).Split('/')
        $Aligned = $R.Count -eq $M.Count
        $InSub = $M.Count -gt 2 -and $M[1] -ieq 'subscriptions'
        for ($i = 1; $i -lt $M.Count; $i++)
        {
            $Tok = $M[$i]
            # The shortest token, 'prod_' and a GUID, has 41 characters. A part already met
            # as a token is not matched against the token form again.
            if ($Tok.Length -lt 41) { continue }
            $Known = $null
            $IsNew = -not $Of.TryGetValue($Tok, [ref]$Known)
            if ($IsNew -and -not $TokenRx.IsMatch($Tok)) { continue }
            $Kind = if ($InSub -and $i -eq 2) { 'SubscriptionMap' } elseif ($InSub -and $i -eq 4 -and $M[3] -ieq 'resourcegroups') { 'ResourceGroupMap' } else { 'ResourceNameMap' }
            $Place = $SlotPlace[$Kind]
            $Real = if ($Aligned) { $R[$i] } else { $null }
            if ($IsNew)
            {
                if ($Shared.ContainsKey($Tok)) { $Of[$Tok] = @('', $null, $null, $null); continue }
                $Known = @($Kind, $Place, $null, $null)
                $Seen = $null
                if ($FirstMap.TryGetValue($Tok, [ref]$Seen))
                {
                    $Known[0] = if ($Seen -ceq 'SubscriptionNameMap') { 'SubscriptionMap' } else { $Seen }
                    $Known[1] = $Seen
                    # The value from the token's own map, whatever slot meets it first.
                    $Own = [string]$Known[0]
                    $Table = $Maps[$Own]
                    if ($SlotPlace.ContainsKey($Own) -and $null -ne $Table -and $Table.ContainsKey($Tok))
                    {
                        $MapValue = if ($Own -ceq 'SubscriptionMap') { Get-SubGuidFromResourceId $Table[$Tok] } elseif ($Own -ceq 'ResourceGroupMap') { Get-RgNameFromResourceId $Table[$Tok] } else { ([string]$Table[$Tok] -split '/')[-1] }
                        if (-not [string]::IsNullOrEmpty($MapValue)) { $Known[2] = [string]$MapValue; $Known[3] = $Own }
                    }
                }
                $Of[$Tok] = $Known
            }
            if ($Known[0] -ceq '') { continue }
            # Older builds of this fork gave the name after a segment 3 'resourceGroups' in a
            # tenant-scope id ('/providers/<namespace>/resourceGroups/<x>') the token of group
            # <x>. That token, which ResourceGroupMap holds, is taken in that one name slot when
            # its real value there is the group's, ignoring case: Reveal then writes the same
            # value it stands for. A real value not known yet is taken from that slot, and the
            # token's group slots must then hold it too.
            if ($Kind -ceq 'ResourceNameMap' -and [string]$Known[1] -ceq 'ResourceGroupMap' -and $i -eq 4 -and $M[1] -ieq 'providers' -and $M[3] -ieq 'resourcegroups' -and $null -ne $Real -and ($null -eq $Known[2] -or [string]::Equals([string]$Known[2], $Real, $Ignore)))
            {
                if ($null -eq $Known[2]) { $Known[2] = $Real; $Known[3] = $Place }
                continue
            }
            if ($Known[0] -cne $Kind)
            {
                $Clash.Add([pscustomobject]@{ Token = $Tok; Maps = @([string]$Known[1], $Place); InIds = $true; Why = 'kind' })
                $Known[0] = ''
                $null = $SubClash.Remove($Tok)
            }
            elseif (-not $Aligned)
            {
                # The real part at this place cannot be read, so the value Reveal would write
                # here for a token a map holds cannot be checked. A token no map holds gets no
                # value from Reveal, in a slot or a field.
                if ($FirstMap.ContainsKey($Tok))
                {
                    $Clash.Add([pscustomobject]@{ Token = $Tok; Maps = @([string]$Known[1], $Place); InIds = $true; Why = 'parts' })
                    $Known[0] = ''
                    $null = $SubClash.Remove($Tok)
                }
            }
            elseif ($null -ne $Real)
            {
                if ($Kind -ceq 'SubscriptionMap')
                {
                    $Values = $null
                    if (-not $SubSlots.TryGetValue($Tok, [ref]$Values))
                    {
                        $Values = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                        $SubSlots[$Tok] = $Values
                    }
                    $null = $Values.Add($Real)
                }
                if ($null -eq $Known[2]) { $Known[2] = $Real; $Known[3] = $Place }
                elseif (-not [string]::Equals([string]$Known[2], $Real, $Ignore))
                {
                    if ($Kind -ceq 'SubscriptionMap')
                    {
                        if (-not $SubClash.ContainsKey($Tok)) { $SubClash[$Tok] = @([string]$Known[3], $Place) }
                    }
                    else
                    {
                        $Clash.Add([pscustomobject]@{ Token = $Tok; Maps = @([string]$Known[3], $Place); InIds = $true; Why = 'value' })
                        $Known[0] = ''
                    }
                }
            }
        }
    }
    # A subscription slot's value clash, now that every id is read: the older builds' shape
    # ('name') or a fault ('value').
    $SubTable = $Maps['SubscriptionMap']
    $SubNames = $Maps['SubscriptionNameMap']
    foreach ($Tok in @($SubClash.Keys))
    {
        $InSubMap = $null -ne $SubTable -and $SubTable.ContainsKey($Tok)
        $Named = $InSubMap -and $null -ne $SubNames -and $SubNames.ContainsKey($Tok) -and -not [string]::IsNullOrEmpty([string]$SubNames[$Tok])
        $Values = $SubSlots[$Tok]
        $SubIds = $Values.Count -ge 2
        foreach ($Value in $Values)
        {
            $Guid = [guid]::Empty
            if (-not [guid]::TryParseExact($Value, 'D', [ref]$Guid)) { $SubIds = $false; break }
        }
        # The older builds' shape with a display name ('name'), the same shape with none, as a
        # dictionary from before SubscriptionNameMap existed has it ('noname'), or a fault ('value').
        $Why = if (-not ($InSubMap -and $SubIds)) { 'value' } elseif ($Named) { 'name' } else { 'noname' }
        $Clash.Add([pscustomobject]@{ Token = $Tok; Maps = @($SubClash[$Tok]); InIds = $true; Why = $Why })
    }
    $Clash
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
#
# Inside a resource id a token stands for a path segment, so it is looked up
# in $PathReplacements first: a subscription token after '/subscriptions/'
# becomes the subscription id there, while elsewhere it is the display name.
# When the resource id dimension is revealed, a whole masked id found in
# $IdPathMap (masked id -> real id) is replaced as one value, in the same
# pass as the tokens, so the real id put in is not read again for tokens; this
# also restores ids whose segment tokens a dictionary does not hold one by one. A
# whole id is a subscription id ('/subscriptions/<token>...') or a tenant-scope
# id ('/providers/<namespace>/<type>/<token>...', a reservation order), each
# read as the offline mask reads an id in a text (-WholeIdPattern, built once
# by Invoke-RdaReveal from Get-RdaIdEndMark): up to whitespace, a quote or a
# mark no id holds (<>,;|[]{}?#&=), or the escape mark '\' of a JSON file, and
# without a ')' at its end that has no '(' of its own
# (Get-RdaIdBeforeCloseParen). So an id in prose, a URL or a page is found.
function Convert-RevealString
{
    param([string]$Text, [string]$EscapeMode = 'None', [string]$WholeIdPattern)
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
    $Escape = {
        param([string]$Val)
        switch ($EscapeMode)
        {
            'Json' { return (Get-JsonEscaped $Val) }
            'Html' { return [System.Net.WebUtility]::HtmlEncode($Val) }
            default { return $Val }
        }
    }
    $TokenOnly = '(?<pre>(?i:/subscriptions/)|/)?(?<tok>' + $TokenPattern + ')'
    # One callback for a whole id and for a token. A regex replace never reads the text it
    # has put in, so a real value written here is never read again for tokens: a real id
    # whose name is shaped like another value's token (a resource named 'prod_<guid>') comes
    # back as it is.
    $RevealMatch = {
        param($m)
        if ($m.Groups['whole'].Success)
        {
            # The ')' that closes the text around the id stays after the real id.
            $Id = $m.Value
            if ($Id.EndsWith(')')) { $Id = Get-RdaIdBeforeCloseParen $Id }
            if ($IdPathMap.ContainsKey($Id))
            {
                $script:FileHits++
                return (& $Escape $IdPathMap[$Id]) + $m.Value.Substring($Id.Length)
            }
            # Not a whole id the dictionary holds: its own tokens are revealed one by one,
            # in the text as written.
            return [regex]::Replace($m.Value, $TokenOnly, $RevealMatch)
        }
        $Tok = $m.Groups['tok'].Value
        $Pre = $m.Groups['pre'].Value
        $Val = $null
        # A token whose path value is $null (a subscription token older builds gave to two
        # subscription ids, Invoke-RdaReveal) stays as written in a path: it does not fall
        # back to its field value there.
        if ($m.Groups['pre'].Success -and $null -ne $PathReplacements -and $PathReplacements.ContainsKey($Tok)) { $Val = $PathReplacements[$Tok] }
        elseif ($Replacements.ContainsKey($Tok)) { $Val = $Replacements[$Tok] }
        if ($null -eq $Val) { return $m.Value }
        $script:FileHits++
        return $Pre + (& $Escape $Val)
    }
    if ($null -ne $IdPathMap -and $IdPathMap.Count -gt 0 -and -not [string]::IsNullOrEmpty($WholeIdPattern))
    {
        # The whole id comes first in the alternation, so at each place a whole id is read
        # before a token in it; the '(?i)' of -WholeIdPattern holds only inside its group.
        return [regex]::Replace($Text, ('(?<whole>' + $WholeIdPattern + ')|' + $TokenOnly), $RevealMatch)
    }
    return [regex]::Replace($Text, $TokenOnly, $RevealMatch)
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
    # Every path is used as written (-LiteralPath): a folder name can hold [ or ],
    # which -Path reads as a wildcard, so it would miss the file or find another.
    # Each path checked here is then made full against the pwsh location: .NET
    # (ZipFile, File.Move) reads a relative path against the process folder,
    # which Set-Location does not move, so it would open or write another file.
    if (-not (Test-Path -LiteralPath $InputZip -PathType Leaf))
    {
        throw "Input zip not found: $InputZip"
    }
    $InputZip = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InputZip)

    if ([string]::IsNullOrEmpty($DictionaryPath))
    {
        $DictionaryPath = Get-ChildItem -LiteralPath $SearchDirectory -Filter 'ObfuscationDictionary_*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ([string]::IsNullOrEmpty($DictionaryPath) -or -not (Test-Path -LiteralPath $DictionaryPath -PathType Leaf))
    {
        throw "No ObfuscationDictionary_*.json found. Pass -DictionaryPath, or run from the folder that holds it."
    }
    $DictionaryPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DictionaryPath)

    if ([string]::IsNullOrEmpty($OutputZip))
    {
        $InDir = Split-Path -Path $InputZip -Parent
        $InBase = [System.IO.Path]::GetFileNameWithoutExtension($InputZip)
        $OutputZip = Join-Path $InDir ($InBase + '_revealed.zip')
    }
    $OutputZip = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputZip)

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
    # ConvertFrom-Json reads a tag or free-text value that looks like a time
    # (ISO 8601, or '/Date(...)/') as a DateTime, which would be put back as
    # text in another form ('05/01/2023 08:00:00' for
    # '2023-05-01T10:00:00.123+02:00' on a host at UTC). Each such map value
    # gets back the text the file holds (Restore-DictionaryTimeText), so the
    # revealed value is the text the dictionary holds. The file is read once;
    # its text is read a second time only when it holds such a value.
    $DictText = Get-Content -LiteralPath $DictionaryPath -Raw
    $Dict = $DictText | ConvertFrom-Json
    if ($Dict -is [System.Management.Automation.PSCustomObject])
    {
        $Times = [System.Collections.Generic.List[object]]::new()
        foreach ($MapProp in $Dict.PSObject.Properties)
        {
            if ($MapProp.Value -isnot [System.Management.Automation.PSCustomObject]) { continue }
            foreach ($Entry in $MapProp.Value.PSObject.Properties)
            {
                if ($Entry.Value -is [datetime]) { $Times.Add([pscustomobject]@{ Map = $MapProp.Name; Entry = $Entry }) }
            }
        }
        if ($Times.Count -gt 0) { Restore-DictionaryTimeText -Text $DictText -Times $Times }
        $Times = $null
    }
    $DictText = $null

    $RgMap = ConvertTo-LookupTable $Dict.ResourceGroupMap
    $SubMap = ConvertTo-LookupTable $Dict.SubscriptionMap
    $SubNameMap = ConvertTo-LookupTable $Dict.SubscriptionNameMap
    $TagMap = ConvertTo-LookupTable $Dict.TagMap
    $IdMap = ConvertTo-LookupTable $Dict.ResourceIdMap
    $NameMap = ConvertTo-LookupTable $Dict.ResourceNameMap
    $FreeTextMap = ConvertTo-LookupTable $Dict.FreeTextMap

    # ---- One token, one map ------------------------------------------------
    # Checked over every map, whatever -Fields selects, before any value is
    # replaced (Get-RdaRevealSharedToken): a dictionary that gives one token to
    # two maps would reveal one map's value in the other's places, so nothing
    # is written. The same holds for a token that an id in ResourceIdMap holds
    # as another kind of value or for another real value, and for a token a map
    # holds in an id with another number of parts than its real id (Why
    # 'parts'), except a subscription token that older builds gave to two
    # subscription ids with one display name, which the dictionary gives (Why
    # 'name'): that one is kept masked in id paths below. With no display name
    # (Why 'noname') it stops too.
    $Found = @(Get-RdaRevealSharedToken -Maps ([ordered]@{
                ResourceGroupMap    = $RgMap
                SubscriptionMap     = $SubMap
                SubscriptionNameMap = $SubNameMap
                TagMap              = $TagMap
                ResourceNameMap     = $NameMap
                ResourceIdMap       = $IdMap
                FreeTextMap         = $FreeTextMap
            }))
    $SharedTokens = @($Found | Where-Object { -not $_.InIds })
    if ($SharedTokens.Count -gt 0)
    {
        throw ("The dictionary gives {0} token(s) to more than one map, ignoring case (the first: '{1}', in {2}). Reveal puts a token's value wherever the token stands, so it would write one map's value into another map's fields and ids. Nothing was written. A run of this build gives each value a token of its own: use the dictionary the run wrote with this report, not one changed or merged by hand." -f $SharedTokens.Count, $SharedTokens[0].Token, ($SharedTokens[0].Maps -join ' and '))
    }
    $IdTokens = @($Found | Where-Object { $_.InIds -and $_.Why -cne 'name' -and $_.Why -cne 'parts' -and $_.Why -cne 'noname' })
    if ($IdTokens.Count -gt 0)
    {
        $Why = if ($IdTokens[0].Why -ceq 'kind') { 'for two kinds of value' } else { 'for two real values' }
        throw ("The ids in the dictionary's ResourceIdMap hold {0} token(s) that do not stand for one kind of value and one real value, ignoring case (the first: '{1}', in {2} and in {3}, {4}). Reveal puts a token's value wherever the token stands, so it would write one value in the place of another in ids and fields. Nothing was written. A run of this build gives each value a token of its own: use the dictionary the run wrote with this report, not one changed or merged by hand." -f $IdTokens.Count, $IdTokens[0].Token, $IdTokens[0].Maps[0], $IdTokens[0].Maps[1], $Why)
    }
    # A token a map holds in an id whose masked and real forms do not have as many parts
    # (Why 'parts'): its real part there cannot be read, so its value cannot be checked.
    $PartTokens = @($Found | Where-Object { $_.Why -ceq 'parts' })
    if ($PartTokens.Count -gt 0)
    {
        throw ("The ids in the dictionary's ResourceIdMap hold {0} token(s) that a map holds, in a masked id with another number of parts than its real id (the first: '{1}', in {2} and in {3}). Reveal cannot tell which part of the real id such a token stands for, so it cannot check that the token stands for one real value, and it could write one value in the place of another in ids and fields. Nothing was written. A run of this build writes each masked id with as many parts as its real id: use the dictionary the run wrote with this report, not one changed or merged by hand." -f $PartTokens.Count, $PartTokens[0].Token, $PartTokens[0].Maps[0], $PartTokens[0].Maps[1])
    }
    $PartTokens = $null
    # A subscription token older builds gave to two or more subscription ids, in a dictionary
    # that gives it no display name (Why 'noname'): it was written by a run, not edited, but no
    # single value fits every place it stands.
    $NoNameTokens = @($Found | Where-Object { $_.Why -ceq 'noname' })
    if ($NoNameTokens.Count -gt 0)
    {
        throw ("The ids in the dictionary's ResourceIdMap hold {0} subscription token(s) for two or more subscription ids, and the dictionary gives that token no display name (the first: '{1}', in {2} and in {3}, for two real values). Older builds keyed a subscription's token by its display name, so two subscriptions with one display name share one token, and a dictionary from before SubscriptionNameMap existed holds no display name for it. No single value fits every place the token stands: no one subscription id fits both subscriptions, and there is no display name to write. Nothing was written. A run of this build gives each value a token of its own, so the report and dictionary of a new run can be revealed." -f $NoNameTokens.Count, $NoNameTokens[0].Token, $NoNameTokens[0].Maps[0], $NoNameTokens[0].Maps[1])
    }
    $NoNameTokens = $null
    # The subscription tokens older builds gave to two or more subscription ids whose
    # subscriptions share one display name (Get-RdaRevealSharedToken, Why 'name').
    $SubTokensByName = [System.Collections.Generic.List[string]]::new()
    foreach ($Entry in $Found) { if ($Entry.Why -ceq 'name') { $SubTokensByName.Add([string]$Entry.Token) } }
    $Found = $null
    $SharedTokens = $null
    $IdTokens = $null

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
            # A collector row with no id is filed under a stand-in path whose
            # last segment is <name>~<hash> (a '/' in the name is written '_'):
            # its name is the part before '~', and a row with no name has none.
            if ($NameMap[$token] -match '(?i)/providers/rda\.noid/' -and $Name -match '^(.+)~[0-9a-f]{8}(-\d+)?$')
            {
                $Name = if ($Matches[1] -eq '~noname') { '' } else { $Matches[1] }
            }
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

    # Inside a resource id each token stands for its path segment: the
    # subscription id (not the display name), the resource group, or the
    # resource name. Revealing the resource id reveals all three there.
    $PathReplacements = @{}
    if ($Fields -contains 'Subscription' -or $Fields -contains 'ResourceId')
    {
        foreach ($token in $SubMap.Keys)
        {
            $Guid = Get-SubGuidFromResourceId $SubMap[$token]
            if (-not [string]::IsNullOrEmpty($Guid)) { $PathReplacements[$token] = $Guid }
        }
        # A subscription token older builds gave to two or more subscription ids stands for
        # no one of them in an id path. Its path value is $null, so Convert-RevealString
        # leaves it masked there; its display name is still written in subscription fields,
        # and a whole id that ResourceIdMap holds still comes back as its real id.
        foreach ($token in $SubTokensByName) { $PathReplacements[$token] = $null }
        if ($SubTokensByName.Count -gt 0)
        {
            Write-Warning ("The dictionary gives {0} subscription token(s) to two or more subscription ids whose subscriptions share one display name, as older builds wrote it when they keyed a subscription's token by its display name (the first: '{1}'). Reveal writes that display name in subscription fields, and with -Fields ResourceId each whole id that ResourceIdMap holds, but leaves it masked in any other id path, as it cannot tell which subscription id the token stands for there." -f $SubTokensByName.Count, $SubTokensByName[0])
        }
    }
    if ($Fields -contains 'ResourceGroup' -or $Fields -contains 'ResourceId')
    {
        foreach ($token in $RgMap.Keys)
        {
            $RgName = Get-RgNameFromResourceId $RgMap[$token]
            if (-not [string]::IsNullOrEmpty($RgName)) { $PathReplacements[$token] = $RgName }
        }
    }
    if ($Fields -contains 'ResourceName' -or $Fields -contains 'ResourceId')
    {
        foreach ($token in $NameMap.Keys)
        {
            $Name = ($NameMap[$token] -split '/')[-1]
            if (-not [string]::IsNullOrEmpty($Name)) { $PathReplacements[$token] = $Name }
        }
    }

    # Whole masked ids (ResourceIdMap keys that are paths) -> real ids, each read in a text up
    # to a mark that ends an id for the offline mask (Get-RdaIdEndMark), or the escape mark '\'
    # of a JSON file, which Reveal reads as the file holds it (Convert-RevealString). Built
    # once here, not per cell.
    $WholeIdPattern = '(?i)(?:/subscriptions/(?:prod|nonprod)_|/providers/)[^' + (Get-RdaIdEndMark) + '\\]+'
    $IdPathMap = @{}
    if ($Fields -contains 'ResourceId')
    {
        foreach ($token in $IdMap.Keys)
        {
            if ($token.StartsWith('/') -and -not [string]::IsNullOrEmpty($IdMap[$token])) { $IdPathMap[$token] = $IdMap[$token] }
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
    # One or more hint words are allowed (prod_aks_<guid>, prod_rg_mc_<guid>).
    $TokenPattern = '(?:prod|nonprod)_(?:[a-z0-9]+_)*[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

    if ($Replacements.Count -eq 0 -and $PathReplacements.Count -eq 0)
    {
        # The report of a subscription with no resources carries no masked
        # values, and its dictionary is empty. It has nothing to reveal and is
        # not a failure: write an unchanged copy, so the revealed bundle keeps
        # every subscription. A report that does carry masked values with no
        # mapping for the selected fields is still an error (wrong dictionary
        # or wrong -Fields).
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $HasToken = $false
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($InputZip)
        try
        {
            foreach ($Entry in $Archive.Entries)
            {
                $Reader = [System.IO.StreamReader]::new($Entry.Open())
                try { $HasToken = [regex]::IsMatch($Reader.ReadToEnd(), $TokenPattern) }
                finally { $Reader.Dispose() }
                if ($HasToken) { break }
            }
        }
        finally
        {
            $Archive.Dispose()
        }

        if ($HasToken)
        {
            throw "Nothing to reveal: the selected field(s) [$($Fields -join ', ')] produced no token mappings from this dictionary."
        }

        # Same atomic swap as a revealed zip below: copy to .partial.zip, then move.
        $OutputZipPartial = ($OutputZip -replace '\.zip$', '') + '.partial.zip'
        [System.IO.File]::Copy($InputZip, $OutputZipPartial, $true)
        [System.IO.File]::Move($OutputZipPartial, $OutputZip, $true)
        Write-Host ""
        Write-Host "Nothing to reveal: this report carries no masked values (for example a subscription with no resources). Wrote an unchanged copy." -ForegroundColor Yellow
        Write-Host ("Output: {0}" -f $OutputZip) -ForegroundColor Green
        return
    }

    Write-Host ("Tokens to reveal: {0}" -f $Replacements.Count)

    # ---- Extract, rewrite, re-zip ------------------------------------------

    # The report's privacy banner says the report holds no real identifiers.
    # After a reveal it does, so the banner says what was restored instead.
    $RevealedBanner = '<div class="privacy-banner identifiable"><span class="privacy-icon">&#9888;</span><div><b>Revealed report.</b> Real values were restored from the obfuscation dictionary for: {0}. Treat as confidential and share only with the intended recipient.</div></div>' -f [System.Net.WebUtility]::HtmlEncode(($Fields -join ', '))

    $TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("Reveal_" + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $TmpRoot -Force | Out-Null

    try
    {
        # Phase progress (Expanding -> Scanning -> Compressing) so a single
        # report's reveal is not a black box while the opaque extract / compress
        # steps run. Uses the shared Write-RdaProgress when it is
        # loaded (single-report mode via Reveal.ps1, which dot-sources
        # Common.Functions); in the all-subscriptions child job the helper is
        # absent AND the job's output is hidden but for its warnings, so guard on its
        # presence and no-op there (the wrapper shows a per-folder heartbeat instead).
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
                                $prop.Value = Convert-RevealString -Text $prop.Value -EscapeMode 'None' -WholeIdPattern $WholeIdPattern
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
                $NewContent = Convert-RevealString -Text $Content -EscapeMode $EscapeMode -WholeIdPattern $WholeIdPattern
                $BannerReplaced = $false
                if ($EscapeMode -eq 'Html' -and $NewContent -match '<div class="privacy-banner obfuscated">')
                {
                    $NewContent = [regex]::Replace($NewContent, '<div class="privacy-banner obfuscated">.*?</div></div>', { param($m) $RevealedBanner }, [System.Text.RegularExpressions.RegexOptions]::Singleline)
                    $BannerReplaced = $true
                }

                if ($script:FileHits -gt 0 -or $BannerReplaced)
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

        # Atomic output: compress to a sibling *.partial.zip, then swap it into
        # place with File.Move(overwrite). A same-volume move is a rename, so a
        # hard kill (SIGKILL / shell timeout) DURING compression can never leave a
        # truncated zip at $OutputZip. This matters for the all-subscriptions
        # reveal (Reveal.ps1), whose -Resume trusts the presence of the output zip
        # to mean "this folder is done" and whose consolidation sweeps every *.zip
        # in staging: a partial file left at the FINAL name would be both skipped
        # on resume AND folded into the outer zip. The .partial.zip name is
        # excluded from that consolidation sweep, so only the completed archive
        # ever appears at $OutputZip. The Remove-Item below is required because
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
