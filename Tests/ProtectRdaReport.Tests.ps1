#Requires -Version 7.0
# Protect-RdaReport.ps1: mask a finished plain report offline the way a live
# -Obfuscate run masks it. The proof here: the field rules cover every field a
# collector masks; the pieces it reads back (JSON, run summary, diagnostics log)
# come back as written; on the synthetic estate the offline mask of the plain run
# equals the live -Obfuscate run, value for value once each side is turned back
# with its own dictionary, with the same token shapes; Reveal maps it back; and
# it refuses an already-masked report, a cut-off file, a file it does not know
# and a real value left in the output.

BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:Pwsh = (Get-Process -Id $PID).Path
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/ResourceInventory.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/OfflineObfuscation.Functions.ps1')
    foreach ($Block in (Get-RdaLiveMaskFunction -RepoRoot $script:RepoRoot)) { . $Block }

    function script:Invoke-Protect([string]$Path, [string]$Out)
    {
        $Text = & $script:Pwsh -NoProfile -NonInteractive -File (Join-Path $script:RepoRoot 'Protect-RdaReport.ps1') -Path $Path -OutputDirectory $Out 2>&1 | ForEach-Object { [string]$_ }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = @($Text) }
    }

    function script:Read-Zip([string]$Zip)
    {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Zip)
        try
        {
            $Out = [ordered]@{}
            foreach ($E in $Archive.Entries)
            {
                $Reader = [System.IO.StreamReader]::new($E.Open())
                try { $Out[$E.FullName] = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
            }
            return $Out
        }
        finally { $Archive.Dispose() }
    }

    # A masked report turned back with its own dictionary, value by value, into
    # a form two masked runs of the same data share: each token or masked id
    # becomes the real value it stands for (a name token its resource id), and
    # keeps its prefix and hint, so a different prefix or hint shows too.
    function script:ConvertTo-Unmasked($Value, $Dict)
    {
        if ($Value -is [string])
        {
            $Shape = if ($Value -match '^((?:non)?prod_(?:databricks_|aks_|vmss_)?)[0-9a-f]{8}-') { $Matches[1] } else { '' }
            foreach ($Map in 'ResourceIdMap', 'ResourceNameMap', 'TagMap', 'FreeTextMap', 'SubscriptionNameMap')
            {
                if ($null -ne $Dict.$Map -and $Dict.$Map.ContainsKey($Value)) { return ('{0}:{1}:{2}' -f $Map, $Shape, $Dict.$Map[$Value]) }
            }
            if ($null -ne $Dict.ResourceGroupMap -and $Dict.ResourceGroupMap.ContainsKey($Value) -and $Dict.ResourceGroupMap[$Value] -match '(?i)/resourcegroups/([^/]+)') { return ('rg:{0}:{1}' -f $Shape, $Matches[1].ToLowerInvariant()) }
            if ($null -ne $Dict.SubscriptionMap -and $Dict.SubscriptionMap.ContainsKey($Value) -and $Dict.SubscriptionMap[$Value] -match '(?i)^/subscriptions/([^/]+)') { return ('sub:{0}:{1}' -f $Shape, $Matches[1]) }
            # Free-text tokens inside a text masked part by part (an app's siteProperties).
            if ($null -ne $Dict.FreeTextMap)
            {
                $Map = $Dict.FreeTextMap
                return [regex]::Replace($Value, '(?:non)?prod_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', { param($M) if ($Map.ContainsKey($M.Value)) { '<{0}{1}>' -f ($M.Value -replace '_.*$', ''), $Map[$M.Value] } else { $M.Value } })
            }
            return $Value
        }
        if ($Value -is [hashtable])
        {
            $Out = @{}
            foreach ($K in $Value.Keys) { $Out[$K] = script:ConvertTo-Unmasked $Value[$K] $Dict }
            return $Out
        }
        if ($Value -is [array]) { return , @($Value | ForEach-Object { script:ConvertTo-Unmasked $_ $Dict }) }
        return $Value
    }

    # A plain or revealed report (no dictionary) is read the same way, its values as they are.
    function script:Get-UnmaskedReportFromPlain([string]$Zip) { script:Get-UnmaskedReport $Zip $null }

    function script:Get-UnmaskedReport([string]$Zip, [string]$DictPath)
    {
        $Dict = if ($DictPath) { Read-RdaJsonFile -Path $DictPath } else { @{} }
        $Members = script:Read-Zip $Zip
        $Out = [ordered]@{}
        foreach ($Name in $Members.Keys)
        {
            $Kind = ($Name -split '_')[0]
            if ($Name -like '*.json')
            {
                $Data = ConvertFrom-RdaJsonText -Text $Members[$Name]
                $Out[$Kind + ($Name -replace '^.*?(__\d+)?\.json$', '$1')] = script:ConvertTo-Unmasked $Data $Dict
            }
            elseif ($Name -like 'Consumption_*.csv')
            {
                $Rows = @($Members[$Name] | ConvertFrom-Csv)
                $Out['Consumption'] = @($Rows | ForEach-Object {
                        $R = @{}
                        foreach ($P in $_.PSObject.Properties) { $R[$P.Name] = if ($P.Name -eq 'InstanceData') { script:ConvertTo-Unmasked (ConvertFrom-RdaJsonText -Text $P.Value) $Dict } else { script:ConvertTo-Unmasked $P.Value $Dict } }
                        $R
                    })
            }
        }
        return $Out
    }

    # JSON with every object's keys sorted, so two equal values give the same text
    # whatever order their hashtables enumerate in.
    function script:ConvertTo-SortedJson($Value)
    {
        $Sort = {
            param($V)
            if ($V -is [System.Collections.IDictionary]) { $O = [ordered]@{}; foreach ($K in @($V.Keys | Sort-Object)) { $O[$K] = & $Sort $V[$K] }; return $O }
            if ($V -is [array]) { return , @($V | ForEach-Object { & $Sort $_ }) }
            return $V
        }
        ConvertTo-Json -InputObject (& $Sort $Value) -Depth 20 -Compress
    }

    # The differences between two unmasked reports, by section and field (never a value).
    function script:Compare-Unmasked($A, $B, [string[]]$SkipField = @())
    {
        $Diff = [System.Collections.Generic.List[string]]::new()
        foreach ($Kind in @($A.Keys + $B.Keys | Select-Object -Unique))
        {
            $X = $A[$Kind]; $Y = $B[$Kind]
            if ($Kind -eq 'Inventory')
            {
                foreach ($S in @($X.Keys + $Y.Keys | Select-Object -Unique))
                {
                    if ($S -eq 'Version') { if ($X[$S] -ne $Y[$S]) { $Diff.Add('Version') }; continue }
                    $Rx = @($X[$S]); $Ry = @($Y[$S])
                    if ($Rx.Count -ne $Ry.Count) { $Diff.Add("$S rows"); continue }
                    for ($i = 0; $i -lt $Rx.Count; $i++)
                    {
                        foreach ($F in @($Rx[$i].Keys + $Ry[$i].Keys | Select-Object -Unique))
                        {
                            if ($SkipField -contains "$S.$F") { continue }
                            $Vx = $Rx[$i][$F]; $Vy = $Ry[$i][$F]
                            if ($F -eq 'Tags') { $Vx = @($Vx | Sort-Object { $_.Name }); $Vy = @($Vy | Sort-Object { $_.Name }) }
                            if ((script:ConvertTo-SortedJson $Vx) -cne (script:ConvertTo-SortedJson $Vy)) { $Diff.Add("$S.$F") }
                        }
                    }
                }
                continue
            }
            $Sx = @($X | ForEach-Object { script:ConvertTo-SortedJson $_ } | Sort-Object)
            $Sy = @($Y | ForEach-Object { script:ConvertTo-SortedJson $_ } | Sort-Object)
            if ($Kind -like 'Metrics*') { $Sx = @($X.Metrics | ForEach-Object { script:ConvertTo-SortedJson $_ } | Sort-Object); $Sy = @($Y.Metrics | ForEach-Object { script:ConvertTo-SortedJson $_ } | Sort-Object) }
            if (($Sx -join "`n") -cne ($Sy -join "`n")) { $Diff.Add($Kind) }
        }
        return @($Diff | Select-Object -Unique)
    }
}

Describe 'The offline field rules name every field a collector masks' {
    It 'finds, in each collector, every output field whose value depends on the obfuscation dictionaries, and the rules name exactly those' {
        $Markers = '\$ResourceIdDictionary|\$Global:ResourceNameDictionary|Protect-FreeTextValue|Protect-SitePropertiesValue'
        $Masked = [System.Collections.Generic.List[string]]::new()
        foreach ($File in Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'Services') -Recurse -Filter '*.ps1')
        {
            $Ast = [System.Management.Automation.Language.Parser]::ParseFile($File.FullName, [ref]$null, [ref]$null)
            # A variable is tainted when one of its assignments reads a marker or a tainted variable.
            $Assignments = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))
            $Tainted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            do
            {
                $Grew = $false
                foreach ($A in $Assignments)
                {
                    $Name = $A.Left.VariablePath.UserPath
                    if ($Tainted.Contains($Name)) { continue }
                    $Right = $A.Right.Extent.Text
                    $Reads = @($A.Right.FindAll({ param($N) $N -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.VariablePath.UserPath })
                    if ($Right -match $Markers -or @($Reads | Where-Object { $Tainted.Contains($_) }).Count -gt 0) { [void]$Tainted.Add($Name); $Grew = $true }
                }
            } while ($Grew)
            # The dictionary itself and the collector's own parameters are not output values.
            [void]$Tainted.Remove('ResourceIdDictionary')
            foreach ($H in $Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.HashtableAst] }, $true))
            {
                foreach ($Pair in $H.KeyValuePairs)
                {
                    $Key = $Pair.Item1.Extent.Text.Trim("'", '"')
                    if ($Key -in 'ID', 'Name', 'Subscription', 'ResourceGroup', 'Tags') { continue }
                    $ValueText = $Pair.Item2.Extent.Text
                    $Reads = @($Pair.Item2.FindAll({ param($N) $N -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.VariablePath.UserPath })
                    if ($ValueText -match $Markers -or @($Reads | Where-Object { $Tainted.Contains($_) }).Count -gt 0) { $Masked.Add(('{0}.{1}' -f $File.BaseName, $Key)) }
                }
            }
        }
        $Ruled = @(Get-RdaOfflineFieldRule | ForEach-Object { '{0}.{1}' -f $_.Section, $_.Field } | Sort-Object -Unique)
        @($Masked | Sort-Object -Unique) | Should -Be $Ruled
    }
}

Describe 'Test-RdaMaskedOutputLeak' {
    It 'finds a real value as each kind of file writes it, and not a value the plain report holds where no one masks' {
        $Dir = Join-Path ([IO.Path]::GetTempPath()) ('RdaLeak_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Dir | Out-Null
        try
        {
            $Real = 'Ops "blue" & team-01'
            $Files = @{
                'a.json' = (ConvertTo-Json -InputObject @{ D = $Real } -Compress)
                'b.csv'  = ('"x","{0}"' -f $Real.Replace('"', '""'))
                'c.html' = [System.Net.WebUtility]::HtmlEncode($Real)
                'd.txt'  = 'location eastus2 only'
            }
            foreach ($K in $Files.Keys) { Set-Content -LiteralPath (Join-Path $Dir $K) -Value $Files[$K] -NoNewline }
            foreach ($K in 'a.json', 'b.csv', 'c.html') { @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir $K) -RealValue @($Real)).Count | Should -Be 1 -Because $K }
            # A real value of digits only (a tag value '4500123') is still looked for.
            Set-Content -LiteralPath (Join-Path $Dir 'e.csv') -Value '"Tag"\n"4500123"' -NoNewline
            @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir 'e.csv') -RealValue @('4500123')).Count | Should -Be 1
            # ...but not inside Azure's own numbers (a quantity '0.4500123', '1,4500123.5').
            Set-Content -LiteralPath (Join-Path $Dir 'q.csv') -Value '"Quantity"\n"0.4500123"\n"1,4500123.5"\n"4500123.25"' -NoNewline
            @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir 'q.csv') -RealValue @('4500123')).Count | Should -Be 0
            Add-Content -LiteralPath (Join-Path $Dir 'q.csv') -Value '\n"4500123"' -NoNewline
            @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir 'q.csv') -RealValue @('4500123')).Count | Should -Be 1
            # A capital letter outside the Basic Multilingual Plane (Adlam) reads as the file holds it.
            $Adlam = [char]::ConvertFromUtf32(0x1E900) + 'team-77'
            Set-Content -LiteralPath (Join-Path $Dir 'w.txt') -Value ('x ' + $Adlam + ' y') -NoNewline -Encoding utf8
            @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir 'w.txt') -RealValue @($Adlam)).Count | Should -Be 1
            # A real part right after a URL escape (%2F, %252F) is a whole word.
            foreach ($Esc in '%2F', '%252F', '%2f', '%25252F', '%2525252f')
            {
                Set-Content -LiteralPath (Join-Path $Dir 'u.txt') -Value ('https://h/x?id=' + $Esc + 'resourcegroups' + $Esc + 'rg-foreign-77' + $Esc + 'providers') -NoNewline
                @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir 'u.txt') -RealValue @('rg-foreign-77')).Count | Should -Be 1 -Because $Esc
            }
            # A UTF-8 character escaped (in either case), a real value after a '%' that is text, and a value holding a literal escape.
            foreach ($Case in @(@('caf%C3%A9-01', [string]('caf' + [char]0xE9 + '-01')), @('caf%c3%a9-01', [string]('caf' + [char]0xE9 + '-01')), @('cpu 90%1a-web01', '1a-web01'), @('x%42web-01 y', '42web-01'), @('x %2541beta1 y', '%2541beta1'), @('caf%25C3%25A9-01', [string]('caf' + [char]0xE9 + '-01')), @('caf%C3%25A9-01', [string]('caf' + [char]0xE9 + '-01'))))
            {
                Set-Content -LiteralPath (Join-Path $Dir 'u5.txt') -Value $Case[0] -NoNewline -Encoding utf8
                @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir 'u5.txt') -RealValue @($Case[1])).Count | Should -Be 1 -Because $Case[0]
            }
            # A value that reads plain at one level only (after a literal '%', in text encoded once) is found.
            Set-Content -LiteralPath (Join-Path $Dir 'u9.txt') -Value 'cpu%2090%251a-web01%20high x team-%2541 y' -NoNewline
            @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir 'u9.txt') -RealValue @('1a-web01')).Count | Should -Be 1
            @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir 'u9.txt') -RealValue @('team-a')).Count | Should -Be 1
            # A new level starts from the run as it stood before the escape: a number run with a letter is still
            # found, and a word or Azure number cut by no replay is not a false hit.
            Initialize-RdaOfflineType
            $Lv = [RdaOfflineLeakScan]::new([string[]]@('4500123', 'team-a'))
            $Lv.CountText('a' + ('1.' * 100) + '1%252E4500123.5') | Should -BeGreaterThan 0
            $Lv.CountText('abcteam-a  x%2541') | Should -Be 0
            $Lv.CountText('0.4500123  x%2541') | Should -Be 0
            $Lv.CountText('x %zz team-a %4z') | Should -BeGreaterThan 0
            # A literal '%' early in a large text does not make every later character go through every level.
            Initialize-RdaOfflineType
            $Scan = [RdaOfflineLeakScan]::new([string[]]@('rg-secret-01'))
            $Watch = [System.Diagnostics.Stopwatch]::StartNew()
            $null = $Scan.CountText('90% ' + ('"vm","1.25","eastus" ' * 100000))
            $Watch.Elapsed.TotalSeconds | Should -BeLessThan 4
            # A space written as '+'; a value with a line break as ConvertTo-Json writes it.
            Set-Content -LiteralPath (Join-Path $Dir 'u7.txt') -Value 'x team+alpha-2 y' -NoNewline
            @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir 'u7.txt') -RealValue @('team alpha-2')).Count | Should -Be 1
            $Multi = "owner team-a1`nline two"
            Set-Content -LiteralPath (Join-Path $Dir 'u8.json') -Value (ConvertTo-Json -InputObject @{ x = $Multi } -Compress) -NoNewline
            @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir 'u8.json') -RealValue @($Multi)).Count | Should -Be 1
            # A malformed UTF-8 escape (overlong) stays as written: it is not read as U+FFFD.
            Set-Content -LiteralPath (Join-Path $Dir 'u6.txt') -Value 'foo%E0%80%80-01' -NoNewline
            $Bad = 'foo' + [string][char]0xFFFD + [char]0xFFFD + [char]0xFFFD + '-01'
            @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir 'u6.txt') -RealValue @($Bad)).Count | Should -Be 0
            # A URL-encoded name with parentheses, and a value next to a symbol outside the Basic Multilingual Plane.
            Set-Content -LiteralPath (Join-Path $Dir 'u3.txt') -Value 'id=%2Fresourcegroups%2Frg%281%29%2Fproviders' -NoNewline
            @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir 'u3.txt') -RealValue @('rg(1)')).Count | Should -Be 1
            $Smile = [char]::ConvertFromUtf32(0x1F600)
            foreach ($Near in ('x team-alpha' + $Smile + ' y'), ('x ' + $Smile + 'team-alpha y'))
            {
                Set-Content -LiteralPath (Join-Path $Dir 'u4.txt') -Value $Near -NoNewline -Encoding utf8
                @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir 'u4.txt') -RealValue @('team-alpha')).Count | Should -Be 1 -Because $Near
            }
            # A letter outside the Basic Multilingual Plane is a letter: the digits after it are not Azure's number.
            Set-Content -LiteralPath (Join-Path $Dir 'u2.txt') -Value ('x ' + [char]::ConvertFromUtf32(0x10428) + '1.4500123 y') -NoNewline -Encoding utf8
            @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir 'u2.txt') -RealValue @('4500123')).Count | Should -Be 1
            # ...and in any case: as written, lower-cased and upper-cased as a whole string.
            $Deseret = [char]::ConvertFromUtf32(0x10400) + 'teamalphabeta'
            foreach ($Form in $Deseret, $Deseret.ToLowerInvariant(), $Deseret.ToUpperInvariant())
            {
                Set-Content -LiteralPath (Join-Path $Dir 'w2.txt') -Value ('x ' + $Form + ' y') -NoNewline -Encoding utf8
                @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir 'w2.txt') -RealValue @($Deseret)).Count | Should -Be 1 -Because $Form
                @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir 'w2.txt') -RealValue @($Deseret.ToLowerInvariant())).Count | Should -Be 1 -Because $Form
            }
            # Beside a '.' or ',' that is not part of a number it is found.
            foreach ($Near in '4500123.blob.core.windows.net', 'account 4500123, failed', 'ended 4500123.', 'x.4500123', 'storage1.4500123.blob.core.windows.net', '4500123.25abc', 'v1.4500123', '0.4500123.a')
            {
                Set-Content -LiteralPath (Join-Path $Dir 'n.txt') -Value $Near -NoNewline
                @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir 'n.txt') -RealValue @('4500123')).Count | Should -Be 1 -Because $Near
            }
            $Exempt = [System.Collections.Generic.HashSet[string]]::new([string[]]@('eastus2'), [System.StringComparer]::OrdinalIgnoreCase)
            @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir 'd.txt') -RealValue @('eastus2') -Exempt $Exempt).Count | Should -Be 0
            @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir 'd.txt') -RealValue @('eastus2')).Count | Should -Be 1
            # Only a whole word counts: a short real name is not found inside a GUID.
            Set-Content -LiteralPath (Join-Path $Dir 'e.txt') -Value ((1..4000 | ForEach-Object { [guid]::NewGuid().ToString() }) -join ' ') -NoNewline
            Add-Content -LiteralPath (Join-Path $Dir 'e.txt') -Value ' 0a1dc-01b2c3-dd-ee' -NoNewline
            @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir 'e.txt') -RealValue @('dc-01', 'db-01', 'ad-02', 'fe-01')).Count | Should -Be 0
            Add-Content -LiteralPath (Join-Path $Dir 'e.txt') -Value ' host dc-01.' -NoNewline
            @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir 'e.txt') -RealValue @('dc-01')).Count | Should -Be 1
            # A real value inside an Azure word the plain report holds where no one masks is Azure's there.
            Set-Content -LiteralPath (Join-Path $Dir 'f.txt') -Value 'image sql2019-ws2019' -NoNewline
            $Words = [System.Collections.Generic.HashSet[string]]::new([string[]]@('sql2019-ws2019'), [System.StringComparer]::OrdinalIgnoreCase)
            @(Test-RdaMaskedOutputLeak -Path (Join-Path $Dir 'f.txt') -RealValue @('ws2019') -Exempt $Words).Count | Should -Be 0
        }
        finally { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'The masked-field check, the real values and the exempt words' {
    It 'finds a real part of a shape-kept name in a masked field, and passes a masked id' {
        $Real = [System.Collections.Generic.HashSet[string]]::new([string[]]@('contoso', 'rg-app-01'), [System.StringComparer]::OrdinalIgnoreCase)
        $Tok = 'prod_11111111-1111-1111-1111-111111111111'
        Test-RdaMaskedSlot -Row @{ Name = "aks-contoso-$Tok-vmss" } -Field 'Name' -RealValue $Real | Should -Be @('Name')
        Test-RdaMaskedSlot -Row @{ Name = "aks-$Tok-$Tok-vmss" } -Field 'Name' -RealValue $Real | Should -BeNullOrEmpty
        Test-RdaMaskedSlot -Row @{ ID = "/subscriptions/$Tok/resourcegroups/$Tok/providers/microsoft.compute/virtualmachines/$Tok/extensions/$Tok" } -Field 'ID' -RealValue $Real | Should -BeNullOrEmpty
        Test-RdaMaskedSlot -Row @{ ID = "/subscriptions/$Tok/resourcegroups/rg-app-01/providers/microsoft.compute/virtualmachines/$Tok" } -Field 'ID' -RealValue $Real | Should -Be @('ID')
    }

    # An extension id has a second 'providers': its namespace (microsoft.insights) is
    # Azure's word, read from that 'providers' as Get-RdaRealValueSet reads it, so a
    # report whose real group or name is 'insights' does not refuse the masked id.
    It 'reads the namespace after the second providers of an extension id as Azure''s word, and still finds a real name after it' {
        $Real = [System.Collections.Generic.HashSet[string]]::new([string[]]@('insights'), [System.StringComparer]::OrdinalIgnoreCase)
        $Tok = 'prod_11111111-1111-1111-1111-111111111111'
        $Ext = "/subscriptions/$Tok/resourcegroups/$Tok/providers/microsoft.compute/virtualmachines/$Tok/providers/microsoft.insights/diagnosticsettings"
        Test-RdaMaskedSlot -Row @{ ID = "$Ext/$Tok" } -Field 'ID' -RealValue $Real | Should -BeNullOrEmpty -Because 'every name part is a token'
        Test-RdaMaskedSlot -Row @{ ID = "$Ext/insights" } -Field 'ID' -RealValue $Real | Should -Be @('ID') -Because 'the name after the second providers is still read'
        Test-RdaMaskedSlot -Row @{ ID = "/subscriptions/$Tok/resourcegroups/$Tok/providers/microsoft.compute/virtualmachines/insights/providers/microsoft.insights/diagnosticsettings/$Tok" } -Field 'ID' -RealValue $Real | Should -Be @('ID') -Because 'the name before the second providers is still read'
    }

    It 'takes the subscription, group and name parts of a full id given as a real value' {
        $Global:ResourceIdDictionary = $null; $Global:ResourceNameDictionary = $null; $Global:ResourceSubscriptionDictionary = $null; $Global:ResourceResourceGroupDictionary = $null
        $Global:ObfuscationSubscriptionTokens = $null; $Global:ObfuscationResourceGroupTokens = $null; $Global:TagValueDictionary = $null; $Global:FreeTextDictionary = $null
        $Set = Get-RdaRealValueSet -ExtraValue '/subscriptions/33333333-3333-3333-3333-333333333333/resourcegroups/rg-far-01/providers/microsoft.web/serverfarms/plan-far-01'
        foreach ($V in '33333333-3333-3333-3333-333333333333', 'rg-far-01', 'plan-far-01') { $Set.Contains($V) | Should -BeTrue -Because $V }
        $Set.Contains('serverfarms') | Should -BeFalse
    }

    It 'takes a usage row''s masked id only as a run writes it: <Case>' -ForEach @(
        @{ Case = 'every name a token'; Plain = '/subscriptions/{s}/resourcegroups/rg-bus/providers/microsoft.servicebus/namespaces/$system/topics/orders'; Masked = '/subscriptions/{t}/resourcegroups/{t}/providers/microsoft.servicebus/namespaces/{t}/topics/{t}'; Ok = $true }
        @{ Case = 'the fixed name $system kept'; Plain = '/subscriptions/{s}/resourcegroups/rg-bus/providers/microsoft.servicebus/namespaces/$system'; Masked = '/subscriptions/{t}/resourcegroups/{t}/providers/microsoft.servicebus/namespaces/$system'; Ok = $false }
        @{ Case = '$system kept as a parent'; Plain = '/subscriptions/{s}/resourcegroups/rg-bus/providers/microsoft.servicebus/namespaces/$SYSTEM/topics/orders'; Masked = '/subscriptions/{t}/resourcegroups/{t}/providers/microsoft.servicebus/namespaces/$SYSTEM/topics/{t}'; Ok = $false }
        @{ Case = 'a short name of letters kept'; Plain = '/subscriptions/{s}/resourcegroups/rg-bus/providers/microsoft.servicebus/namespaces/sbbilling/queues/orders'; Masked = '/subscriptions/{t}/resourcegroups/{t}/providers/microsoft.servicebus/namespaces/{t}/queues/orders'; Ok = $false }
        @{ Case = 'the group kept'; Plain = '/subscriptions/{s}/resourcegroups/rg/providers/microsoft.compute/disks/d1'; Masked = '/subscriptions/{t}/resourcegroups/rg/providers/microsoft.compute/disks/{t}'; Ok = $false }
        @{ Case = 'a tenant-scope id with every name a token'; Plain = '/providers/microsoft.capacity/reservationorders/{s}/reservations/{s}'; Masked = '/providers/microsoft.capacity/reservationorders/{t}/reservations/{t}'; Ok = $true }
        @{ Case = 'a tenant-scope id with a name kept'; Plain = '/providers/microsoft.capacity/reservationorders/{s}/reservations/{s}'; Masked = '/providers/microsoft.capacity/reservationorders/{t}/reservations/{s}'; Ok = $false }
        @{ Case = 'a tenant-scope $system id as one flat token (not changed here)'; Plain = '/providers/microsoft.servicebus/namespaces/$system'; Masked = '{t}'; Ok = $true }
        @{ Case = 'an id that is not an ARM path as one flat token'; Plain = 'marketplace-charge'; Masked = '{t}'; Ok = $true }
        @{ Case = 'an id that is not an ARM path left as written'; Plain = 'marketplace-charge'; Masked = 'marketplace-charge'; Ok = $false }
        @{ Case = 'an empty id as obfuscated'; Plain = ''; Masked = 'obfuscated'; Ok = $true }
        @{ Case = 'a flat token for an id a run masks part by part'; Plain = '/subscriptions/{s}/resourcegroups/rg/providers/microsoft.compute/disks/d1'; Masked = '{t}'; Ok = $false }
        @{ Case = 'a plain id in Azure''s casing, its masked id in lower-case words'; Plain = '/subscriptions/{s}/resourceGroups/RG-Bus/providers/Microsoft.ServiceBus/namespaces/$system/topics/Orders'; Masked = '/subscriptions/{t}/resourcegroups/{t}/providers/microsoft.servicebus/namespaces/{t}/topics/{t}'; Ok = $true }
        @{ Case = 'a plain id in Azure''s casing, a name kept in another case'; Plain = '/subscriptions/{s}/resourceGroups/RG-Bus/providers/Microsoft.ServiceBus/namespaces/SbBilling/queues/Orders'; Masked = '/subscriptions/{t}/resourcegroups/{t}/providers/microsoft.servicebus/namespaces/{t}/queues/orders'; Ok = $false }
    ) {
        $S = '33333333-3333-3333-3333-333333333333'; $T = 'prod_11111111-1111-1111-1111-111111111111'
        Test-RdaMaskedUsageId -PlainId $Plain.Replace('{s}', $S) -MaskedId $Masked.Replace('{t}', $T).Replace('{s}', $S) | Should -Be $Ok
    }

    # The run's shape check mirrors its masking, so a change that keeps a name in both
    # passes it. Each case puts such a change into the shape check, as written in
    # ResourceInventory.ps1, for this test only: the check on each name slot still
    # refuses the id, and still takes one whose every name is a token.
    It 'refuses a usage row''s masked id that keeps a name, also when the shape check is changed to keep it: <Case>' -ForEach @(
        @{
            Case = 'the fixed name $system, as an older build''s shape check kept it'
            Find = 'if ($R[$i] -ieq ''providers'' -or [string]::IsNullOrEmpty($Next))'; Put = 'if ($R[$i] -ieq ''providers'' -or [string]::IsNullOrEmpty($Next) -or $Next -eq ''$system'')'
            Plain = '/subscriptions/{s}/resourcegroups/rg-bus/providers/microsoft.servicebus/namespaces/$system'; Masked = '/subscriptions/{t}/resourcegroups/{t}/providers/microsoft.servicebus/namespaces/$system'
        }
        @{
            Case = 'a short name of letters kept as written'
            Find = 'elseif ($M[$i + 1] -cnotmatch $Token -or $M[$i + 1] -ieq $Next) { return $false }'; Put = 'elseif ($M[$i + 1] -cnotmatch $Token -and $M[$i + 1] -ine $Next) { return $false }'
            Plain = '/subscriptions/{s}/resourcegroups/rg-bus/providers/microsoft.servicebus/namespaces/sbbilling/queues/orders'; Masked = '/subscriptions/{t}/resourcegroups/{t}/providers/microsoft.servicebus/namespaces/{t}/queues/ORDERS'
        }
        @{
            Case = 'a tenant-scope name kept as written'
            Find = 'elseif ($M[$i + 1] -cnotmatch $Token -or $M[$i + 1] -ieq $Next) { return $false }'; Put = 'elseif ($M[$i + 1] -cnotmatch $Token -and $M[$i + 1] -ine $Next) { return $false }'
            Plain = '/providers/microsoft.capacity/reservationorders/{s}/reservations/{s}'; Masked = '/providers/microsoft.capacity/reservationorders/{t}/reservations/{s}'
        }
        @{
            Case = 'the group kept as written'
            Find = 'if ($M[$i + 1] -cnotmatch $RgToken -or $M[$i + 1] -ieq $Next) { return $false }'; Put = 'if ($M[$i + 1] -cnotmatch $RgToken -and $M[$i + 1] -ine $Next) { return $false }'
            Plain = '/subscriptions/{s}/resourcegroups/rg/providers/microsoft.compute/disks/d1'; Masked = '/subscriptions/{t}/resourcegroups/rg/providers/microsoft.compute/disks/{t}'
        }
        @{
            Case = 'the subscription kept as written'
            Find = '$M[2] -cnotmatch $SubToken -or $M[2] -ieq $R[2]'; Put = '($M[2] -cnotmatch $SubToken -and $M[2] -ine $R[2])'
            Plain = '/subscriptions/{s}/resourcegroups/rg/providers/microsoft.compute/disks/d1'; Masked = '/subscriptions/{s}/resourcegroups/{t}/providers/microsoft.compute/disks/{t}'
        }
    ) {
        $S = '33333333-3333-3333-3333-333333333333'; $T = 'prod_11111111-1111-1111-1111-111111111111'
        $PlainId = $Plain.Replace('{s}', $S)
        $MaskedId = $Masked.Replace('{t}', $T).Replace('{s}', $S)
        # Every name slot a token: the walk gives each pair's value a token, the namespace kept.
        $Parts = $PlainId.Split('/')
        for ($i = 1; $i + 1 -lt $Parts.Count; $i += 2) { if ($Parts[$i] -ine 'providers') { $Parts[$i + 1] = $T } }
        $Good = $Parts -join '/'
        Test-RdaMaskedUsageId -PlainId $PlainId -MaskedId $Good | Should -BeTrue -Because 'an id whose every name is a token is the one a run writes'
        $Real = ${function:Test-ObfuscatedIdShape}.ToString()
        $Real.Contains($Find) | Should -BeTrue -Because 'the change is put into the shape check as it is written'
        . ([scriptblock]::Create("function Test-ObfuscatedIdShape {`n" + $Real.Replace($Find, $Put) + "`n}"))
        Test-ObfuscatedIdShape -RealId $PlainId -MaskedId $MaskedId | Should -BeTrue -Because 'the changed shape check takes the id that keeps a name'
        Test-RdaMaskedUsageId -PlainId $PlainId -MaskedId $MaskedId | Should -BeFalse
    }

    # A token ends where its slot ends: a line feed after it (a regex '$' also matches before a
    # last line feed) is no part of a token a run writes, so the offline mask refuses such a
    # masked usage id, through the run's own shape check.
    It 'refuses, as the masked id of a usage row, an id whose <Slot> token ends in a line feed, and takes it without' -ForEach @(
        @{ Slot = 'subscription'; Plain = '/subscriptions/{s}/resourceGroups/rg-a/providers/Microsoft.Compute/virtualMachines/vm-a'; Index = 2 }
        @{ Slot = 'resource group'; Plain = '/subscriptions/{s}/resourceGroups/rg-a/providers/Microsoft.Compute/virtualMachines/vm-a'; Index = 4 }
        @{ Slot = 'name'; Plain = '/subscriptions/{s}/resourceGroups/rg-a/providers/Microsoft.Compute/virtualMachines/vm-a'; Index = 8 }
        @{ Slot = 'tenant-scope name'; Plain = '/providers/Microsoft.Capacity/reservationOrders/ro-a'; Index = 4 }
        @{ Slot = 'flat'; Plain = 'marketplace-charge-a'; Index = -1 }
    ) {
        $PlainId = $Plain.Replace('{s}', '33333333-3333-3333-3333-333333333333')
        $Parts = $PlainId.Split('/')
        if ($Index -lt 0) { $Parts = @('prod_' + [guid]::NewGuid().ToString()) }
        else { for ($i = 1; $i + 1 -lt $Parts.Count; $i += 2) { if ($Parts[$i] -ine 'providers') { $Parts[$i + 1] = 'prod_' + [guid]::NewGuid().ToString() } } }
        $Good = $Parts -join '/'
        Test-RdaMaskedUsageId -PlainId $PlainId -MaskedId $Good | Should -BeTrue -Because 'the token as a run writes it is taken'
        $Parts[[math]::Max($Index, 0)] += "`n"
        Test-RdaMaskedUsageId -PlainId $PlainId -MaskedId ($Parts -join '/') | Should -BeFalse -Because 'a line feed is no part of a token'
    }

    It 'takes a $system name part from <Source> as a real value, so an inventory row or metric record that kept it stops the slot check' -ForEach @(
        @{ Source = 'the run''s dictionaries' }
        @{ Source = 'a full id passed in' }
    ) {
        $Saved = @{}
        foreach ($N in 'ResourceIdDictionary', 'ResourceNameDictionary', 'ResourceSubscriptionDictionary', 'ResourceResourceGroupDictionary', 'ObfuscationSubscriptionTokens', 'ObfuscationResourceGroupTokens', 'TagValueDictionary', 'FreeTextDictionary') { $Saved[$N] = Get-Variable -Scope Global -Name $N -ValueOnly -ErrorAction SilentlyContinue; Set-Variable -Scope Global -Name $N -Value $null }
        try
        {
            # A Service Bus namespace named '$system' in a group of another name, so
            # only the name part can bring '$system' into the set.
            $Real = '/subscriptions/33333333-3333-3333-3333-333333333333/resourcegroups/rg-bus-01/providers/microsoft.servicebus/namespaces/$system'
            if ($Source -like '*dictionaries')
            {
                $Ids = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
                $Ids[$Real] = 'masked'
                Set-Variable -Scope Global -Name ResourceIdDictionary -Value $Ids
                $Set = Get-RdaRealValueSet
            }
            else { $Set = Get-RdaRealValueSet -ExtraValue $Real }
            $Tok = 'prod_11111111-1111-1111-1111-111111111111'
            $Kept = "/subscriptions/$Tok/resourcegroups/$Tok/providers/microsoft.servicebus/namespaces/`$system"
            $Row = @{ ID = $Kept; Name = $Tok; ResourceGroup = $Tok; Subscription = $Tok }
            Test-RdaMaskedSlot -Row $Row -Field 'ID', 'Name', 'ResourceGroup', 'Subscription', 'Tags' -RealValue $Set | Should -Be @('ID') -Because 'an inventory row whose id kept $system'
            $Rec = @{ ID = "$Kept/topics/$Tok"; Name = $Tok; ResourceGroup = $Tok; Subscription = $Tok }
            Test-RdaMaskedSlot -Row $Rec -Field 'ID', 'Name', 'ResourceGroup', 'Subscription' -RealValue $Set | Should -Be @('ID') -Because 'a metric record whose id kept $system as a parent name'
            Test-RdaMaskedSlot -Row @{ ID = "/subscriptions/$Tok/resourcegroups/$Tok/providers/microsoft.servicebus/namespaces/$Tok/topics/$Tok"; Name = $Tok } -Field 'ID', 'Name' -RealValue $Set | Should -BeNullOrEmpty -Because 'the masked id holds tokens only'
            $Set.Contains('$system') | Should -BeTrue -Because 'a masked report leaves no name part as written, $system included'
        }
        finally { foreach ($N in $Saved.Keys) { Set-Variable -Scope Global -Name $N -Value $Saved[$N] } }
    }

    It 'takes the name parts of a tenant-scope id (no subscription) from <Source> as real values, so a masked id that kept one stops the slot check' -ForEach @(
        @{ Source = 'the run''s dictionaries' }
        @{ Source = 'a full id passed in' }
    ) {
        $Saved = @{}
        foreach ($N in 'ResourceIdDictionary', 'ResourceNameDictionary', 'ResourceSubscriptionDictionary', 'ResourceResourceGroupDictionary', 'ObfuscationSubscriptionTokens', 'ObfuscationResourceGroupTokens', 'TagValueDictionary', 'FreeTextDictionary') { $Saved[$N] = Get-Variable -Scope Global -Name $N -ValueOnly -ErrorAction SilentlyContinue; Set-Variable -Scope Global -Name $N -Value $null }
        try
        {
            # A reservation and a management group: '/providers/<namespace>/<type>/<name>...',
            # the path a run keeps for such an id, its names masked.
            $OrderGuid = '44444444-4444-4444-4444-444444444444'; $ResGuid = '55555555-5555-5555-5555-555555555555'
            $Res = "/providers/Microsoft.Capacity/reservationOrders/$OrderGuid/reservations/$ResGuid"
            $Mg = '/providers/Microsoft.Management/managementGroups/mg-contoso-01'
            if ($Source -like '*dictionaries')
            {
                $Ids = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
                $Ids[$Res] = 'masked'; $Ids[$Mg] = 'masked'
                Set-Variable -Scope Global -Name ResourceIdDictionary -Value $Ids
                $Set = Get-RdaRealValueSet
            }
            else { $Set = Get-RdaRealValueSet -ExtraValue $Res, $Mg }
            $Tok = 'prod_11111111-1111-1111-1111-111111111111'
            Test-RdaMaskedSlot -Row @{ ID = "/providers/Microsoft.Capacity/reservationOrders/$Tok/reservations/$ResGuid" } -Field 'ID' -RealValue $Set | Should -Be @('ID') -Because 'the reservation''s own name was left'
            Test-RdaMaskedSlot -Row @{ ID = "/providers/Microsoft.Capacity/reservationOrders/$OrderGuid/reservations/$Tok" } -Field 'ID' -RealValue $Set | Should -Be @('ID') -Because 'the order''s name was left as a parent'
            Test-RdaMaskedSlot -Row @{ ID = "/providers/Microsoft.Capacity/reservationOrders/$Tok/reservations/$Tok" } -Field 'ID' -RealValue $Set | Should -BeNullOrEmpty -Because 'the masked id holds tokens only'
            foreach ($V in $OrderGuid, $ResGuid, 'mg-contoso-01', $Res, $Mg) { $Set.Contains($V) | Should -BeTrue -Because $V }
            foreach ($W in 'providers', 'Microsoft.Capacity', 'reservationOrders', 'reservations', 'Microsoft.Management', 'managementGroups') { $Set.Contains($W) | Should -BeFalse -Because "$W is Azure's word" }
        }
        finally { foreach ($N in $Saved.Keys) { Set-Variable -Scope Global -Name $N -Value $Saved[$N] } }
    }

    # A name can be the word 'providers' (a storage account named so). A path pairs a word with
    # a value from segment 1 on, as Get-ObfuscatedResourceId pairs it, so only a 'providers' in a
    # word place starts the count of namespace, type and name words again; one in a name place
    # is a name, and so are the names after it.
    It 'reads a resource named providers, and the names after it, as names, from <Source>, so a masked id that kept one stops the slot check' -ForEach @(
        @{ Source = 'the run''s dictionaries' }
        @{ Source = 'a full id passed in' }
    ) {
        $Saved = @{}
        foreach ($N in 'ResourceIdDictionary', 'ResourceNameDictionary', 'ResourceSubscriptionDictionary', 'ResourceResourceGroupDictionary', 'ObfuscationSubscriptionTokens', 'ObfuscationResourceGroupTokens', 'TagValueDictionary', 'FreeTextDictionary') { $Saved[$N] = Get-Variable -Scope Global -Name $N -ValueOnly -ErrorAction SilentlyContinue; Set-Variable -Scope Global -Name $N -Value $null }
        try
        {
            $Real = '/subscriptions/33333333-3333-3333-3333-333333333333/resourcegroups/rg-st-01/providers/microsoft.storage/storageaccounts/providers/blobservices/default'
            if ($Source -like '*dictionaries')
            {
                $Ids = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
                $Ids[$Real] = 'masked'
                Set-Variable -Scope Global -Name ResourceIdDictionary -Value $Ids
                $Set = Get-RdaRealValueSet
            }
            else { $Set = Get-RdaRealValueSet -ExtraValue $Real }
            foreach ($V in 'providers', 'default', 'rg-st-01') { $Set.Contains($V) | Should -BeTrue -Because "$V is a name in that id" }
            foreach ($W in 'microsoft.storage', 'storageaccounts', 'blobservices') { $Set.Contains($W) | Should -BeFalse -Because "$W is Azure's word" }
            $Tok = 'prod_11111111-1111-1111-1111-111111111111'
            $Base = "/subscriptions/$Tok/resourcegroups/$Tok/providers/microsoft.storage/storageaccounts"
            Test-RdaMaskedSlot -Row @{ ID = "$Base/$Tok/blobservices/$Tok" } -Field 'ID' -RealValue $Set | Should -BeNullOrEmpty -Because 'the masked id holds tokens only'
            Test-RdaMaskedSlot -Row @{ ID = "$Base/providers/blobservices/$Tok" } -Field 'ID' -RealValue $Set | Should -Be @('ID') -Because 'the account''s name was left'
            Test-RdaMaskedSlot -Row @{ ID = "$Base/$Tok/blobservices/default" } -Field 'ID' -RealValue $Set | Should -Be @('ID') -Because 'the name after it was left'
            Test-RdaMaskedSlot -Row @{ ID = "$Base/providers/blobservices/default" } -Field 'ID' -RealValue $Set | Should -Be @('ID') -Because 'both names were left'
            # A 'providers' in a word place still starts the count again: an extension id's
            # namespace and type after it are Azure's words.
            Test-RdaMaskedSlot -Row @{ ID = "$Base/$Tok/providers/microsoft.insights/diagnosticsettings/$Tok" } -Field 'ID' -RealValue $Set | Should -BeNullOrEmpty
            # A name can be the word 'subscriptions' or 'resourcegroups' too (a storage account may be
            # named so). Only a 'subscriptions' at segment 1 and a 'resourcegroups' at segment 3 of a
            # subscription id are the path's own words, as the run reads them; one in a name place is a name.
            foreach ($Word in 'subscriptions', 'resourcegroups')
            {
                $WordReal = "/subscriptions/33333333-3333-3333-3333-333333333333/resourcegroups/rg-st-01/providers/microsoft.storage/storageaccounts/$Word/blobservices/default"
                if ($Source -like '*dictionaries')
                {
                    $WordIds = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
                    $WordIds[$WordReal] = 'masked'
                    Set-Variable -Scope Global -Name ResourceIdDictionary -Value $WordIds
                    $WordSet = Get-RdaRealValueSet
                }
                else { $WordSet = Get-RdaRealValueSet -ExtraValue $WordReal }
                $WordSet.Contains($Word) | Should -BeTrue -Because "$Word is a name in that id"
                Test-RdaMaskedSlot -Row @{ ID = "$Base/$Tok/blobservices/$Tok" } -Field 'ID' -RealValue $WordSet | Should -BeNullOrEmpty -Because "the masked id holds tokens only, and its own $Word word is in its place"
                Test-RdaMaskedSlot -Row @{ ID = "$Base/$Word/blobservices/$Tok" } -Field 'ID' -RealValue $WordSet | Should -Be @('ID') -Because "the account's name $Word was left"
                Test-RdaMaskedSlot -Row @{ ID = "$Base/$Tok/blobservices/default" } -Field 'ID' -RealValue $WordSet | Should -Be @('ID') -Because 'the name after it was left'
                Test-RdaMaskedSlot -Row @{ ID = "$Base/$Word/blobservices/default" } -Field 'ID' -RealValue $WordSet | Should -Be @('ID') -Because 'both names were left'
                # In a tenant-scope id the same word after a namespace is a type word.
                Test-RdaMaskedSlot -Row @{ ID = "/providers/microsoft.example/$Word/$Tok" } -Field 'ID' -RealValue $WordSet | Should -BeNullOrEmpty -Because "$Word is a type word there"
            }
        }
        finally { foreach ($N in $Saved.Keys) { Set-Variable -Scope Global -Name $N -Value $Saved[$N] } }
    }

    It 'reads a masked id''s name slot that holds the word providers as a name in the slot check, and the words after it by their place' {
        $Real = [System.Collections.Generic.HashSet[string]]::new([string[]]@('providers', 'contoso'), [System.StringComparer]::OrdinalIgnoreCase)
        $Tok = 'prod_11111111-1111-1111-1111-111111111111'
        $Base = "/subscriptions/$Tok/resourcegroups/$Tok/providers/microsoft.storage/storageaccounts"
        Test-RdaMaskedSlot -Row @{ ID = "$Base/providers/blobservices/$Tok" } -Field 'ID' -RealValue $Real | Should -Be @('ID') -Because 'the name providers was left'
        # Read from the 'providers' in a word place: 'blobservices' is a type word, 'contoso' a name.
        Test-RdaMaskedSlot -Row @{ ID = "$Base/$Tok/blobservices/contoso" } -Field 'ID' -RealValue $Real | Should -Be @('ID')
        Test-RdaMaskedSlot -Row @{ ID = "$Base/$Tok/blobservices/$Tok" } -Field 'ID' -RealValue $Real | Should -BeNullOrEmpty -Because 'Azure''s words in their places are not names'
    }

    It 'takes no value of a list a rule masks inside (a cloud service''s Roles) as an Azure word' {
        $Exempt = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Rows = @{ CloudServices = @(@{ ID = 'x'; Name = 'n'; Location = 'eastus'; Roles = @(@{ RoleName = 'contoso-api-web'; SkuName = 'standard_d2' }) }) }
        Add-RdaExemptValue -Rows $Rows -Metrics @() -Rules @(Get-RdaOfflineFieldRule) -Exempt $Exempt
        $Exempt.Contains('contoso-api-web') | Should -BeFalse
        $Exempt.Contains('standard_d2') | Should -BeFalse
        $Exempt.Contains('eastus') | Should -BeTrue
    }

    It 'takes no value of a plain list as an Azure word, so a real name in one is still looked for' {
        $Exempt = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Rows = @{ VirtualMachines = @(@{ ID = 'x'; Name = 'vm-app-01'; Location = 'eastus'; Size = @('vm-app-01') }) }
        Add-RdaExemptValue -Rows $Rows -Metrics @() -Rules @(Get-RdaOfflineFieldRule) -Exempt $Exempt
        $Exempt.Contains('vm-app-01') | Should -BeFalse
        $Exempt.Contains('eastus') | Should -BeTrue
    }

    It 'takes no value of an object as Azure gave it as an Azure word' {
        $Exempt = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Rows = @{ AppServices = @(@{ ID = 'x'; Name = 'app-web-01'; Location = 'eastus'; SiteProperties = @{ properties = @(@{ name = 'LinuxFxVersion'; value = 'docker|app-web-01:1' }) } }) }
        Add-RdaExemptValue -Rows $Rows -Metrics @() -Rules @(Get-RdaOfflineFieldRule) -Exempt $Exempt
        $Exempt.Contains('docker|app-web-01:1') | Should -BeFalse
        $Exempt.Contains('LinuxFxVersion') | Should -BeFalse
    }
}

Describe 'ConvertFrom-RdaDiagnosticsText reads only what the writer writes' {
    It 'writes no message text, so no free-text value or number of it reaches the shareable log' {
        $Dir = Join-Path ([IO.Path]::GetTempPath()) ('RdaDiagNum_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Dir | Out-Null
        $Saved = @{ F = $Global:FreeTextDictionary; C = $Global:CollectorFailures; M = $Global:MetricsFailedSubs; U = $Global:ConsumptionFailedSubs }
        try
        {
            $Global:FreeTextDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
            $Global:FreeTextDictionary['1'] = 'prod_88888888-0000-0000-0000-000000000001'
            $Global:FreeTextDictionary['450012'] = 'prod_88888888-0000-0000-0000-000000000003'
            $Global:FreeTextDictionary['secret-77'] = 'prod_88888888-0000-0000-0000-000000000002'
            $Global:CollectorFailures = @([pscustomobject]@{ Id = '11111111-2222-3333-4444-555555555555'; Module = 'VMSS'; Message = 'HTTP 410 on secret-77 account 450012' })
            $Global:MetricsFailedSubs = @(); $Global:ConsumptionFailedSubs = @()
            Write-RdaShareableDiagnosticsLog -DefaultPath ($Dir + '/') -ReportName 'P' -RunDateTime '1' -Version '3.2.3' -PhaseTimings ([ordered]@{}) -Obfuscated *> $null
            $Text = Get-Content -Raw -LiteralPath (@(Get-ChildItem -LiteralPath $Dir -Filter 'Diagnostics_*.log')[0].FullName)
            # The message is not written at all: no number, free-text value or word of it.
            $Text | Should -Match '(?m)^  \[sub <guid>\] VMSS: \(message not kept\)\r?$'
            $Text | Should -Not -Match 'secret-77|450012|HTTP|410'
        }
        finally
        {
            $Global:FreeTextDictionary = $Saved.F; $Global:CollectorFailures = $Saved.C; $Global:MetricsFailedSubs = $Saved.M; $Global:ConsumptionFailedSubs = $Saved.U
            Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'refuses a head line or a subscription label the writer does not write there' {
        $Dir = Join-Path ([IO.Path]::GetTempPath()) ('RdaDiag_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Dir | Out-Null
        try
        {
            $Global:CollectorFailures = @([pscustomobject]@{ Id = '11111111-2222-3333-4444-555555555555'; Module = 'VMSS'; Message = 'x' })
            $Global:MetricsFailedSubs = @([pscustomobject]@{ Id = '(unknown)'; Message = 'a' }, [pscustomobject]@{ Id = '11111111-2222-3333-4444-555555555555'; Message = 'b'; Complete = $false })
            $Global:ConsumptionFailedSubs = @([pscustomobject]@{ Id = '(auth)'; Message = 'c' })
            $Saved = [cultureinfo]::CurrentCulture
            # Written on a host whose culture writes the time with '.'.
            try { [cultureinfo]::CurrentCulture = 'fi-FI'; Write-RdaShareableDiagnosticsLog -DefaultPath ($Dir + '/') -ReportName 'P' -RunDateTime '1' -Version '3.2.3' -PhaseTimings ([ordered]@{}) *> $null }
            finally { [cultureinfo]::CurrentCulture = $Saved }
            $File = @(Get-ChildItem -LiteralPath $Dir -Filter 'Diagnostics_*.log')[0].FullName
            $Lines = @(Get-Content -LiteralPath $File)
            { ConvertFrom-RdaDiagnosticsText -Lines $Lines -ReportFolder 'f' } | Should -Not -Throw
            # A head line added, or the time line taken out.
            $At = [array]::IndexOf($Lines, ($Lines | Where-Object { $_ -like 'Tool version*' } | Select-Object -First 1))
            { ConvertFrom-RdaDiagnosticsText -Lines @($Lines[0..$At] + 'Operator        : contoso-secret' + $Lines[($At + 1)..($Lines.Count - 1)]) -ReportFolder 'f' } | Should -Throw '*head*'
            { ConvertFrom-RdaDiagnosticsText -Lines @($Lines | Where-Object { $_ -notlike 'Generated (UTC)*' }) -ReportFolder 'f' } | Should -Throw '*head*'
            # A label in a section whose writers do not give it.
            { ConvertFrom-RdaDiagnosticsText -Lines @($Lines -replace '^  \[sub <guid>\] VMSS', '  [sub (auth)] VMSS') -ReportFolder 'f' } | Should -Throw '*names a subscription*'
            # The first line under a section's header, given another label.
            $Relabel = { param([string]$Header, [string]$Label) $Copy = @($Lines); $Copy[[array]::IndexOf($Lines, $Header) + 1] = '  [sub ' + $Label + '] (message not kept)'; , $Copy }
            { ConvertFrom-RdaDiagnosticsText -Lines (& $Relabel 'Metrics incomplete subscriptions: 1' '(unknown)') -ReportFolder 'f' } | Should -Throw '*names a subscription*'
            { ConvertFrom-RdaDiagnosticsText -Lines (& $Relabel 'Consumption failed/incomplete subscriptions: 1' '(unknown)') -ReportFolder 'f' } | Should -Throw '*names a subscription*'
            # The phase block as the writer writes it: '(none recorded)' alone, each phase once, seconds 00-59.
            $None = [array]::IndexOf($Lines, '  (none recorded)')
            $None | Should -BeGreaterThan 0
            $Row = '  Metrics collection (Azure Monitor): 0min 02 sec'
            { ConvertFrom-RdaDiagnosticsText -Lines @($Lines[0..$None] + $Row + $Lines[($None + 1)..($Lines.Count - 1)]) -ReportFolder 'f' } | Should -Throw '*phase time line*'
            $Two = @($Lines[0..($None - 1)] + $Row + $Row + $Lines[($None + 1)..($Lines.Count - 1)])
            { ConvertFrom-RdaDiagnosticsText -Lines $Two -ReportFolder 'f' } | Should -Throw '*phase time line*'
            { ConvertFrom-RdaDiagnosticsText -Lines @($Lines[0..($None - 1)] + '  Metrics collection (Azure Monitor): 0min 75 sec' + $Lines[($None + 1)..($Lines.Count - 1)]) -ReportFolder 'f' } | Should -Throw '*phase time line*'
            { ConvertFrom-RdaDiagnosticsText -Lines @($Lines[0..($None - 1)] + $Row + $Lines[($None + 1)..($Lines.Count - 1)]) -ReportFolder 'f' } | Should -Not -Throw
        }
        finally
        {
            $Global:CollectorFailures = $null; $Global:MetricsFailedSubs = $null; $Global:ConsumptionFailedSubs = $null
            Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Names and types are kept as a run writes them' {
    BeforeAll { $script:Shape = Get-RdaReportShape -RepoRoot $script:RepoRoot }

    It 'refuses a section, field, tag key, nested key or metric key in another case, and an id, name or SKU not as text' {
        $Id = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-a/providers/microsoft.compute/virtualmachines/vm-a'
        $Good = @{ VirtualMachines = @(@{ ID = $Id; Name = 'vm-a'; Tags = @(@{ Name = 'env'; Value = 'x' }) }) }
        Get-RdaUnknownInventoryShape -Rows $Good -Shape $script:Shape | Should -BeNullOrEmpty
        Get-RdaUnknownInventoryShape -Rows @{ VirtualMachines = @(@{ ID = '' }) } -Shape $script:Shape | Should -Match 'an id'
        Get-RdaUnknownInventoryShape -Rows @{ VirtualMachines = @(@{ ID = $null; Name = 'x' }) } -Shape $script:Shape | Should -Match 'an id'
        Get-RdaUnknownInventoryShape -Rows @{ VirtualMachines = @(@{ Name = 'x' }) } -Shape $script:Shape | Should -Match 'an id'
        Get-RdaUnknownInventoryShape -Rows @{ virtualmachines = @(@{ ID = $Id }) } -Shape $script:Shape | Should -Not -BeNullOrEmpty
        Get-RdaUnknownInventoryShape -Rows @{ VirtualMachines = @(@{ id = $Id }) } -Shape $script:Shape | Should -Not -BeNullOrEmpty
        Get-RdaUnknownInventoryShape -Rows @{ VirtualMachines = @(@{ ID = $Id; Tags = @(@{ name = 'env'; Value = 'x' }) }) } -Shape $script:Shape | Should -Not -BeNullOrEmpty
        $Role = @($script:Shape.Nested['CloudServices']['Roles'])[0]
        $Role | Should -Not -BeNullOrEmpty
        Get-RdaUnknownInventoryShape -Rows @{ CloudServices = @(@{ ID = $Id; Roles = @(@{ $Role = 'x' }) }) } -Shape $script:Shape | Should -BeNullOrEmpty
        Get-RdaUnknownInventoryShape -Rows @{ CloudServices = @(@{ ID = $Id; Roles = @(@{ $Role.ToLowerInvariant() = 'x' }) }) } -Shape $script:Shape | Should -Not -BeNullOrEmpty
        # A field the collector adds records to holds records only: not plain text, nor a list of it.
        Get-RdaUnknownInventoryShape -Rows @{ CloudServices = @(@{ ID = $Id; Roles = @('contoso-secret') }) } -Shape $script:Shape | Should -Match 'nested field'
        Get-RdaUnknownInventoryShape -Rows @{ CloudServices = @(@{ ID = $Id; Roles = 'contoso-secret' }) } -Shape $script:Shape | Should -Match 'nested field'
        Get-RdaUnknownInventoryShape -Rows @{ CloudServices = @(@{ ID = $Id; Roles = @() }) } -Shape $script:Shape | Should -BeNullOrEmpty
        # Any other field holds one value; a list only of numbers (a SQL server's zones), never in a field that holds one value.
        Get-RdaUnknownInventoryShape -Rows @{ VirtualMachines = @(@{ ID = $Id; CPU = @([long]1, [long]2) }) } -Shape $script:Shape | Should -Match 'a list in a field'
        Get-RdaUnknownInventoryShape -Rows @{ VirtualMachines = @(@{ ID = $Id; Size = @('contoso-secret') }) } -Shape $script:Shape | Should -Match 'a list in a field'
        $SqlField = @($script:Shape.Sections['SQLSERVER'] | Where-Object { $_ -ceq 'ZoneRedundant' })[0]
        $SqlField | Should -Be 'ZoneRedundant'
        Get-RdaUnknownInventoryShape -Rows @{ SQLSERVER = @(@{ ID = $Id; ZoneRedundant = @('1', '2') }) } -Shape $script:Shape | Should -BeNullOrEmpty
        Get-RdaUnknownInventoryShape -Rows @{ SQLSERVER = @(@{ ID = $Id; ZoneRedundant = @([long]1, [long]2) }) } -Shape $script:Shape | Should -BeNullOrEmpty
        Get-RdaUnknownInventoryShape -Rows @{ SQLSERVER = @(@{ ID = $Id; ZoneRedundant = @(('{0}' -f [char]0x0661)) }) } -Shape $script:Shape | Should -Match 'a list in a field' -Because 'zones are ASCII digits'
        Get-RdaUnknownInventoryShape -Rows @{ SQLSERVER = @(@{ ID = $Id; ZoneRedundant = @('contoso-secret') }) } -Shape $script:Shape | Should -Match 'a list in a field'
        $Other = @($script:Shape.Sections['VirtualMachines'] | Where-Object { $_ -cnotin 'ID', 'Name', 'ResourceGroup', 'Subscription', 'SKU', 'Location', 'Tags', 'CPU', 'Size' } | Sort-Object)[0]
        Get-RdaUnknownInventoryShape -Rows @{ VirtualMachines = @(@{ ID = $Id; $Other = @([long]1) }) } -Shape $script:Shape | Should -Match 'a list in a field' -Because $Other
        # An object as Azure gave it, where the collector copies the field straight from Azure (an app's siteProperties).
        $Site = @{ metadata = $null; properties = @(@{ name = 'LinuxFxVersion'; value = 'DOTNETCORE|8.0' }, @{ name = 'WindowsFxVersion'; value = $null }); appSettings = $null }
        Get-RdaUnknownInventoryShape -Rows @{ AppServices = @(@{ ID = $Id; SiteProperties = $Site }) } -Shape $script:Shape | Should -BeNullOrEmpty
        Get-RdaUnknownInventoryShape -Rows @{ AppServices = @(@{ ID = $Id; State = $Site }) } -Shape $script:Shape | Should -Match 'nested field' -Because 'State holds one value'
        Get-RdaUnknownInventoryShape -Rows @{ AppServices = @(@{ ID = $Id; ServerFarmId = $Site }) } -Shape $script:Shape | Should -Match 'nested field' -Because 'the collector builds ServerFarmId itself'
        # A deeper path from Azure ($Data.storageProfile.osDisk.osType) is a leaf value, never an object.
        Get-RdaUnknownInventoryShape -Rows @{ VirtualMachines = @(@{ ID = $Id; OSType = $Site }) } -Shape $script:Shape | Should -Match 'nested field' -Because 'Azure gives OSType as text'
        Get-RdaUnknownInventoryShape -Rows @{ VirtualMachines = @(@{ ID = 5 }) } -Shape $script:Shape | Should -Match 'that is not text'
        Get-RdaUnknownInventoryShape -Rows @{ VirtualMachines = @(@{ ID = $Id; Name = 7 }) } -Shape $script:Shape | Should -Match 'that is not text'
        Get-RdaUnknownInventoryShape -Rows @{ VMDisk = @(@{ ID = $Id; SKU = 3 }) } -Shape $script:Shape | Should -Match 'that is not text'
        Get-RdaUnknownInventoryShape -Rows @{ VirtualMachines = @(@{ ID = 'vm-a' }) } -Shape $script:Shape | Should -Match 'not an Azure resource id'
        # A row the pull kept as Azure wrote it (its lower-cased text did not parse) keeps Azure's case.
        Get-RdaUnknownInventoryShape -Rows @{ VirtualMachines = @(@{ ID = '/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/RG-A/providers/Microsoft.Compute/virtualMachines/VM-A' }) } -Shape $script:Shape | Should -BeNullOrEmpty
        Get-RdaUnknownInventoryShape -Rows @{ VirtualMachines = @(@{ ID = '/subscriptions/12345678-1234-1234-1234-123456789012/vm-a' }) } -Shape $script:Shape | Should -Match 'not an Azure resource id'
        # A segment past a name would be kept by the id masking as a type word.
        Get-RdaUnknownInventoryShape -Rows @{ VirtualMachines = @(@{ ID = ($Id + '/contoso-secret-01') }) } -Shape $script:Shape | Should -Match 'not an Azure resource id'
        Get-RdaUnknownInventoryShape -Rows @{ VirtualMachines = @(@{ ID = ($Id + '/extensions/ext-a') }) } -Shape $script:Shape | Should -BeNullOrEmpty
        # Provider and type words are kept by the id masking: only words in Azure's form.
        Get-RdaUnknownInventoryShape -Rows @{ VirtualMachines = @(@{ ID = '/subscriptions/s/resourcegroups/g/providers/contoso-secret-01/virtualmachines/vm-a' }) } -Shape $script:Shape | Should -Match 'not an Azure resource id'
        Get-RdaUnknownInventoryShape -Rows @{ VirtualMachines = @(@{ ID = '/subscriptions/s/resourcegroups/g/providers/microsoft.compute/contoso-secret/vm-a' }) } -Shape $script:Shape | Should -Match 'not an Azure resource id'
        Test-RdaIdPathWord '/subscriptions/s/resourcegroups/g/providers/Microsoft.Compute/virtualMachines/vm-a/providers/Microsoft.Insights/diagnosticSettings/d-1' | Should -BeTrue
        Test-RdaIdPathWord '/subscriptions/s/resourcegroups/g/providers/microsoft.compute/virtualmachines/vm-a/providers/contoso_secret/x/y' | Should -BeFalse
        Test-RdaIdPathWord '/providers/microsoft.capacity/reservationorders/r-1/reservations/r-2' | Should -BeTrue
        # The words the id masking keeps, counted as it counts them: from index 3, each odd segment.
        Test-RdaIdPathWord '/subscriptions/s/resourcegroups/g/real-word/providers/microsoft.compute/t/n' | Should -BeFalse
        Test-RdaIdPathWord '/subscriptions/s/real-word/x' | Should -BeFalse
        Test-RdaIdPathWord '/subscriptions/s/resourcegroups/g/providers/microsoft.compute/virtualmachines/vm-a/contoso-secret' | Should -BeFalse
        # A group named providers, and a namespace that starts with a digit, are Azure's.
        Test-RdaIdPathWord '/subscriptions/s/resourcegroups/providers/providers/microsoft.compute/virtualmachines/v' | Should -BeTrue
        Test-RdaIdPathWord '/subscriptions/s/resourcegroups/g/providers/84codes.CloudAMQP/servers/x' | Should -BeTrue
        # A key twice, in any case, is refused, not merged.
        { ConvertFrom-RdaJsonText -Text '{"VirtualMachines":[{"Name":"a","name":"b"}]}' } | Should -Throw '*key twice*'
        { ConvertFrom-RdaJsonText -Text '{"VirtualMachines":[],"virtualmachines":[]}' -OrderedRoot } | Should -Throw '*key twice*'
        { ConvertFrom-RdaJsonText -Text '{"A":{"b":1,"B":2}}' -AsObject } | Should -Throw '*key twice*'
        { ConvertFrom-RdaJsonText -Text '{"VirtualMachines":[{"Name":"a","Name":"b"}]}' } | Should -Throw
        { ConvertFrom-RdaJsonText -Text '{"Metrics":[],"Metrics":[]}' -OrderedRoot } | Should -Throw
        # Only strict JSON, as ConvertTo-Json writes it.
        foreach ($Loose in '{"A":NaN}', '{"A":Infinity}', '{"A":1 /* x */}', '{"A":1} // x', "{'A':1}", '{A:1}', '{"A":[1,],}')
        {
            { ConvertFrom-RdaJsonText -Text $Loose } | Should -Throw -Because $Loose
        }
        (ConvertFrom-RdaJsonText -Text '{"A":[1,2.5,"x",null,true]}')['A'].Count | Should -Be 5
        $Rec = @{}; foreach ($K in $script:Shape.MetricFields) { $Rec[$K] = $null }
        foreach ($K in 'MetricCount', 'MetricValue', 'MetricPercentile', 'MetricTotalCount', 'MetricSeries') { $Rec[$K] = [long]0 }
        $Rec['MetricError'] = $false
        $Rec['ID'] = $Id
        Test-RdaMetricRecordShape -Record $Rec -Shape $script:Shape | Should -BeTrue
        # A metric id that is not a pulled resource's ARM id (empty, a name, a short path) is not a run's.
        foreach ($BadId in $null, '', 'vm-a', '/subscriptions/12345678-1234-1234-1234-123456789012/vm-a', ($Id + '/contoso-secret-01'), $Id.Replace('microsoft.compute', 'contoso-secret-01'))
        {
            $Copy = $Rec.Clone(); $Copy['ID'] = $BadId
            Test-RdaMetricRecordShape -Record $Copy -Shape $script:Shape | Should -BeFalse -Because ([string]$BadId)
        }
        $Copy = $Rec.Clone(); $Copy['ID'] = $Id.Replace('resourcegroups', 'resourceGroups')
        Test-RdaMetricRecordShape -Record $Copy -Shape $script:Shape | Should -BeTrue -Because 'the pull may keep Azure''s case'
        $Bad = @{}; foreach ($K in $Rec.Keys) { $Bad[$(if ($K -eq 'MetricCount') { 'metriccount' } else { $K })] = $Rec[$K] }
        Test-RdaMetricRecordShape -Record $Bad -Shape $script:Shape | Should -BeFalse
    }

    # An id that ends on '$system' with no name after it ('.../namespaces/<name>/$system') is
    # a form this tool does not support: no fixture or captured billing row shows it, and
    # downstream reads the last segment as the name. So the path word check refuses it, as
    # it refuses '$system' with a name after it and any other '$' word.
    It 'refuses a last segment $system with no name after it, and every other $ word' {
        Test-RdaIdPathWord '/subscriptions/s/resourcegroups/g/providers/microsoft.servicebus/namespaces/ns-a/$system' | Should -BeFalse
        Test-RdaIdPathWord '/subscriptions/s/resourcegroups/g/providers/microsoft.servicebus/namespaces/ns-a/$SYSTEM' | Should -BeFalse
        Test-RdaIdPathWord '/subscriptions/s/resourcegroups/g/providers/microsoft.servicebus/namespaces/ns-a/$system/x' | Should -BeFalse
        Test-RdaIdPathWord '/subscriptions/s/resourcegroups/g/providers/microsoft.servicebus/namespaces/ns-a/$systemx' | Should -BeFalse
        Test-RdaIdPathWord '/subscriptions/s/resourcegroups/g/providers/microsoft.servicebus/namespaces/ns-a/$other' | Should -BeFalse
        Test-RdaIdPathWord '/subscriptions/s/resourcegroups/g/providers/microsoft.servicebus/namespaces/ns-a/topics' | Should -BeTrue -Because 'a last type word of Azure''s form is still taken'
    }

    # A run keeps the path of a tenant-scope id that Test-RdaTenantScopeIdMaskable takes
    # ('/providers/<namespace>/<type>/<name>...'), with its namespace and type words as
    # written, so the path word check reads those words too, from segment 1 on.
    It 'reads the namespace and type words of a tenant-scope id a run masks part by part, from segment 1 on: <Id>' -ForEach @(
        @{ Id = '/providers/Microsoft.Capacity/Contoso-Secret-Word/r-1'; Want = $false }
        @{ Id = '/providers/microsoft.capacity/reservationorders/r-1/contoso-secret/r-2'; Want = $false }
        @{ Id = '/providers/contoso-secret/reservationorders/r-1'; Want = $false }
        @{ Id = '/providers/microsoft.capacity/reservationorders/r-1/providers/contoso_secret/x/y'; Want = $false }
        @{ Id = '/providers/Microsoft.Management/managementGroups/mg-1'; Want = $true }
        @{ Id = '/providers/microsoft.capacity/reservationorders/r-1/reservations/r-2'; Want = $true }
        @{ Id = '/providers/Microsoft.Authorization/roleDefinitions/r-1/providers/Microsoft.Insights/diagnosticSettings/d-1'; Want = $true }
        @{ Id = '/providers/microsoft.capacity/reservationorders/providers/reservations/r-2'; Want = $true }
        @{ Id = '/providers/Microsoft.Capacity/Contoso-Secret-Word'; Want = $true }
    ) {
        Test-RdaIdPathWord $Id | Should -Be $Want -Because $(if (-not (Test-RdaTenantScopeIdMaskable -ResourceId $Id)) { 'a run writes this id as one flat token, which keeps none of its words' } elseif ($Want) { 'every namespace and type word is of Azure''s form' } else { 'a run would keep a word that is not of Azure''s form as written' })
    }

    It 'reads an id as ending on the word $system only when that is its last segment with no name after it: <Id>' -ForEach @(
        @{ Id = '/subscriptions/s/resourcegroups/g/providers/microsoft.servicebus/namespaces/ns-a/$system'; Want = $true }
        @{ Id = '/subscriptions/prod_x/resourcegroups/prod_y/providers/microsoft.servicebus/namespaces/prod_z/$SYSTEM'; Want = $true }
        @{ Id = '/providers/microsoft.capacity/reservationorders/r-1/$system'; Want = $true }
        @{ Id = '/subscriptions/s/resourcegroups/g/providers/microsoft.servicebus/namespaces/$system'; Want = $false }
        @{ Id = '/subscriptions/s/resourcegroups/g/providers/microsoft.servicebus/namespaces/ns-a/topics/$system'; Want = $false }
        @{ Id = '/subscriptions/s/resourcegroups/g/providers/microsoft.servicebus/namespaces/ns-a/$systemx'; Want = $false }
        @{ Id = 'prod_$system'; Want = $false }
        @{ Id = ''; Want = $false }
    ) {
        Test-RdaTrailingSystemTypeId $Id | Should -Be $Want
    }

    It 'refuses, as the masked id of a usage row, an id that ends on the word $system with no name after it' {
        $Tok = 'prod_{0}' -f [guid]::NewGuid()
        $Plain = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers/microsoft.servicebus/namespaces/sbdemo01/$system'
        Test-RdaMaskedUsageId -PlainId $Plain -MaskedId ('/subscriptions/{0}/resourcegroups/{0}/providers/microsoft.servicebus/namespaces/{0}/$system' -f $Tok) | Should -BeFalse
        Test-RdaMaskedUsageId -PlainId $Plain.Replace('/$system', '') -MaskedId ('/subscriptions/{0}/resourcegroups/{0}/providers/microsoft.servicebus/namespaces/{0}' -f $Tok) | Should -BeTrue -Because 'the namespace''s own id is taken'
    }

    # A subscription id pairs a word with a value from segment 1 on, so one with an even number
    # of segments ends on a word with no value after it ('.../namespaces/<name>/topics').
    # Downstream reads the last segment as the name, so the offline mask refuses that form too.
    It 'reads a subscription id as ending on a type word with no name after it only when its last segment is a word: <Id>' -ForEach @(
        @{ Id = '/subscriptions/s/resourcegroups/g/providers/microsoft.servicebus/namespaces/ns-a/topics'; Want = $true }
        @{ Id = '/subscriptions/prod_x/resourcegroups/prod_y/providers/microsoft.storage/storageaccounts/prod_z/blobservices'; Want = $true }
        @{ Id = '/subscriptions/s/resourcegroups/g/providers'; Want = $true }
        @{ Id = '/subscriptions/s/resourcegroups/g/providers/microsoft.servicebus/namespaces/ns-a/$system'; Want = $true }
        @{ Id = '/subscriptions/s/resourcegroups/g/providers/microsoft.servicebus/namespaces/ns-a'; Want = $false }
        @{ Id = '/subscriptions/s/resourcegroups/g/providers/microsoft.servicebus/namespaces/ns-a/topics/t-1'; Want = $false }
        @{ Id = '/subscriptions/s/resourcegroups/g'; Want = $false }
        @{ Id = '/subscriptions/s/resourcegroups/g/providers/microsoft.servicebus/namespaces/ns-a/'; Want = $false }
        @{ Id = '/providers/microsoft.capacity/reservationorders/r-1/reservations'; Want = $false }
        @{ Id = 'prod_x'; Want = $false }
        @{ Id = ''; Want = $false }
    ) {
        Test-RdaTrailingTypeWordId $Id | Should -Be $Want
    }

    # A subscription id with an odd number of segments ends on a value. When the segment before
    # it is a providers in a word place, that value is a namespace with no type or name after it
    # ('.../providers/Microsoft.Compute'), and downstream would read the namespace as the name.
    It 'reads a subscription id as ending on a provider namespace with no type or name after it only when its last segment follows a providers in a word place: <Id>' -ForEach @(
        @{ Id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute'; Want = $true }
        @{ Id = '/subscriptions/s/providers/Microsoft.Compute'; Want = $true }
        @{ Id = '/subscriptions/prod_x/resourcegroups/prod_y/providers/microsoft.compute/virtualmachines/prod_z/providers/Microsoft.Insights'; Want = $true }
        @{ Id = '/subscriptions/s/resourcegroups/providers/providers/microsoft.compute'; Want = $true }
        @{ Id = '/subscriptions/s/resourcegroups/providers'; Want = $false }
        @{ Id = '/subscriptions/s/resourcegroups/g/providers/microsoft.storage/storageaccounts/providers'; Want = $false }
        @{ Id = '/subscriptions/s/resourcegroups/g/providers/Microsoft.Compute/virtualMachines/vm-a'; Want = $false }
        @{ Id = '/subscriptions/s/resourcegroups/g/providers/'; Want = $false }
        @{ Id = '/providers/Microsoft.Capacity'; Want = $false }
    ) {
        Test-RdaTrailingTypeWordId $Id | Should -Be $Want
    }

    # A run masks a tenant-scope id part by part only when Test-RdaTenantScopeIdMaskable takes it
    # (an odd number of segments, every part set). Such an id that ends on a provider namespace
    # ('.../providers/Microsoft.Authorization') keeps that namespace as its last segment, which
    # downstream would read as the name, so it is counted as the subscription form is. A
    # tenant-scope id of any other form is one flat token and is not counted.
    It 'reads a tenant-scope id whose path a run keeps as ending on a provider namespace with no type or name after it only when its last segment follows a providers in a word place: <Id>' -ForEach @(
        @{ Id = '/providers/Microsoft.Management/managementGroups/mg-platform/providers/Microsoft.Authorization'; Want = $true }
        @{ Id = '/providers/microsoft.management/managementgroups/prod_11111111-2222-3333-4444-555555555555/PROVIDERS/Microsoft.Authorization'; Want = $true }
        @{ Id = '/providers/Microsoft.Capacity/reservationOrders/r-1/reservations/r-2/providers/Microsoft.Insights'; Want = $true }
        @{ Id = '/providers/Microsoft.Management/managementGroups/providers'; Want = $false }
        @{ Id = '/providers/Microsoft.Capacity/reservationOrders/r-1'; Want = $false }
        @{ Id = '/providers/Microsoft.Authorization/roleDefinitions/r-1/providers/Microsoft.Insights/diagnosticSettings/d-1'; Want = $false }
        @{ Id = '/providers/Microsoft.Management/managementGroups/mg-platform/providers'; Want = $false }
        @{ Id = '/providers/Microsoft.Management/managementGroups/$system/providers/Microsoft.Authorization'; Want = $false }
    ) {
        Test-RdaTrailingTypeWordId $Id | Should -Be $Want -Because $(if (-not (Test-RdaTenantScopeIdMaskable -ResourceId $Id)) { 'a run writes this id as one flat token, which keeps no word' } elseif ($Want) { 'a run keeps the namespace as the last segment' } else { 'the last segment is a name' })
    }

    It 'refuses, as the masked id of a usage row, a tenant-scope id that ends on a provider namespace with no type or name after it' {
        $Tok = 'prod_{0}' -f [guid]::NewGuid()
        $Plain = '/providers/Microsoft.Management/managementGroups/mg-platform/providers/Microsoft.Authorization'
        Test-RdaMaskedUsageId -PlainId $Plain -MaskedId ('/providers/Microsoft.Management/managementGroups/{0}/providers/Microsoft.Authorization' -f $Tok) | Should -BeFalse
        Test-RdaMaskedUsageId -PlainId '/providers/Microsoft.Management/managementGroups/mg-platform' -MaskedId ('/providers/Microsoft.Management/managementGroups/{0}' -f $Tok) | Should -BeTrue -Because 'the management group''s own id is taken'
    }

    It 'refuses, as the masked id of a usage row, an id that ends on a provider namespace with no type or name after it' {
        $Tok = 'prod_{0}' -f [guid]::NewGuid()
        $Plain = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers/Microsoft.Compute'
        Test-RdaMaskedUsageId -PlainId $Plain -MaskedId ('/subscriptions/{0}/resourcegroups/{0}/providers/Microsoft.Compute' -f $Tok) | Should -BeFalse
        Test-RdaMaskedUsageId -PlainId ($Plain + '/virtualMachines/vm-a') -MaskedId ('/subscriptions/{0}/resourcegroups/{0}/providers/Microsoft.Compute/virtualMachines/{0}' -f $Tok) | Should -BeTrue -Because 'a virtual machine''s own id is taken'
    }

    It 'refuses, as the masked id of a usage row, an id that ends on a type word with no name after it' {
        $Tok = 'prod_{0}' -f [guid]::NewGuid()
        $Plain = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers/microsoft.servicebus/namespaces/sbdemo01/topics'
        Test-RdaMaskedUsageId -PlainId $Plain -MaskedId ('/subscriptions/{0}/resourcegroups/{0}/providers/microsoft.servicebus/namespaces/{0}/topics' -f $Tok) | Should -BeFalse
        Test-RdaMaskedUsageId -PlainId ($Plain + '/topic-01') -MaskedId ('/subscriptions/{0}/resourcegroups/{0}/providers/microsoft.servicebus/namespaces/{0}/topics/{0}' -f $Tok) | Should -BeTrue -Because 'a topic''s own id is taken'
    }

    # No fixture or captured billing row shows Azure billing '.../namespaces/<namespace>/$system',
    # so the code and the doc say the offline mask refuses that form and leave it to the owner.
    It 'says, in its code and its doc, that it refuses an id that ends on the word $system with no name after it, and that the form is with the owner' {
        $Root = Split-Path $PSScriptRoot -Parent
        foreach ($File in 'Functions/OfflineObfuscation.Functions.ps1', 'docs/offline-obfuscate.md')
        {
            $Text = ([System.IO.File]::ReadAllText((Join-Path $Root $File)) -replace '(?m)^\s*#\s?', ' ' -replace '\s+', ' ') -replace '[`'']', ''
            $Text | Should -Match ([regex]::Escape('is refused like any other word that is not of that form: it is an id form this tool does not support')) -Because "$File says the form is refused"
            $Text | Should -Match ([regex]::Escape('so how to mask it is with the owner')) -Because "$File leaves the form to the owner"
            $Text | Should -Not -Match 'the offline mask accepts it to match' -Because "$File no longer takes that form"
        }
    }

    # Test-RdaTrailingTypeWordId counts subscription ids, and a tenant-scope id a run masks part by
    # part that ends on a provider namespace: a run writes a tenant-scope id of any other such form
    # as one flat token, so the doc says which ids the stop covers.
    It 'says, in its doc, that it stops a usage row whose subscription id ends on another word with no value after it, or whose tenant-scope id a run keeps ends on a provider namespace, and not a tenant-scope id that ends on a word other than $system' {
        $Text = ([System.IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'docs/offline-obfuscate.md')) -replace '\s+', ' ') -replace '[`'']', ''
        $Text | Should -Match ([regex]::Escape('A usage row whose subscription id (/subscriptions/...) ends on any other type word with no name after it'))
        $Text | Should -Match ([regex]::Escape('on the word providers or resourceGroups with no value after it'))
        $Text | Should -Match ([regex]::Escape('So is a tenant-scope id whose path a run keeps that ends on a provider namespace (/providers/<namespace>/<type>/<name>/providers/Microsoft.Authorization).'))
        $Text | Should -Match ([regex]::Escape('A tenant-scope id (/providers/...) that ends on a word other than $system with no value after it is not stopped: a run writes it as one flat token, which keeps no word.'))
        $Text | Should -Not -Match ([regex]::Escape('A tenant-scope id (/providers/...) of that form is not stopped')) -Because 'a tenant-scope id a run keeps that ends on a provider namespace is stopped'
    }
}

Describe 'Publish-RdaOfflineOutput' {
    It 'moves each item and records it, and on a name already there stops and removes nothing it did not move' {
        $Dir = Join-Path ([IO.Path]::GetTempPath()) ('RdaPub_' + [guid]::NewGuid().ToString('N'))
        try
        {
            $From = Join-Path $Dir 'work'; $To = Join-Path $Dir 'out'
            New-Item -ItemType Directory -Path $From, $To | Out-Null
            'a' | Set-Content -LiteralPath (Join-Path $From 'a.zip'); 'b' | Set-Content -LiteralPath (Join-Path $From 'b.zip')
            function Stop-RdaOfflineMask([string]$Message) { throw $Message }
            $Published = [System.Collections.Generic.List[string]]::new()
            Publish-RdaOfflineOutput -From $From -To $To -Published $Published
            @($Published | ForEach-Object { Split-Path -Leaf $_ } | Sort-Object) | Should -Be @('a.zip', 'b.zip')
            # Another process made the same name meanwhile.
            'c' | Set-Content -LiteralPath (Join-Path $From 'c.zip'); 'theirs' | Set-Content -LiteralPath (Join-Path $To 'c.zip')
            $Published.Clear()
            { Publish-RdaOfflineOutput -From $From -To $To -Published $Published } | Should -Throw '*written to while the mask ran*'
            $Published.Count | Should -Be 0
            Get-Content -LiteralPath (Join-Path $To 'c.zip') | Should -Be 'theirs'
            # A move that fails is not recorded.
            Remove-Item -LiteralPath (Join-Path $To 'c.zip')
            Mock Move-Item { throw 'move failed' }
            { Publish-RdaOfflineOutput -From $From -To $To -Published $Published } | Should -Throw '*move failed*'
            $Published.Count | Should -Be 0
        }
        finally { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Protect-SitePropertiesValue masks the real parts and keeps the shape' {
    It 'keeps keys, nulls, numbers, separators and fixed words, gives each real part one token, and leaves the object as is when not masking' {
        $Saved = $Global:FreeTextDictionary
        try
        {
            $Global:FreeTextDictionary = $null
            $Plain = [pscustomobject][ordered]@{ metadata = $null; properties = @([pscustomobject]@{ name = 'LinuxFxVersion'; value = 'DOCKER|myreg.azurecr.io/web:2' }) }
            (Protect-SitePropertiesValue $Plain) | ConvertTo-Json -Depth 5 -Compress | Should -Be ($Plain | ConvertTo-Json -Depth 5 -Compress)
            $Global:FreeTextDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
            $Value = [pscustomobject][ordered]@{
                metadata    = @([pscustomobject]@{ name = 'CURRENT_STACK'; value = 'dotnet' })
                properties  = @([pscustomobject]@{ name = 'LinuxFxVersion'; value = 'DOCKER|myreg.azurecr.io/web:2' }, [pscustomobject]@{ name = 'LinuxFxVersion'; value = 'JAVA|17-java17' }, [pscustomobject]@{ name = 'note'; value = 'myreg 11111111-2222-3333-4444-555555555555' })
                appSettings = $null
                count       = 3
            }
            $Masked = Protect-SitePropertiesValue $Value
            @($Masked.PSObject.Properties.Name) | Should -Be @('metadata', 'properties', 'appSettings', 'count')
            $Masked.metadata[0].value | Should -Be 'dotnet'
            $Masked.metadata[0].name | Should -Be 'CURRENT_STACK'
            $Masked.properties[1].value | Should -Be 'JAVA|17-java17'
            $Reg = $Global:FreeTextDictionary['myreg']
            $Masked.properties[0].value | Should -Be ('DOCKER|{0}.azurecr.io/{1}:2' -f $Reg, $Global:FreeTextDictionary['web'])
            $Masked.properties[2].name | Should -Be $Global:FreeTextDictionary['note']
            $Masked.properties[2].value | Should -Be ('{0} {1}' -f $Reg, $Global:FreeTextDictionary['11111111-2222-3333-4444-555555555555'])
            $Masked.properties.Count | Should -Be 3
            $Masked.appSettings | Should -BeNullOrEmpty
            $Masked.count | Should -Be 3
            Test-RdaSitePropertiesMasked $Masked | Should -BeTrue
            Test-RdaSitePropertiesMasked $Value | Should -BeFalse
            # A list of one stays a list; a hashtable (as the offline mask reads it) is walked the same way.
            (Protect-SitePropertiesValue @{ properties = @(@{ value = 'web' }) })['properties'].GetType().IsArray | Should -BeTrue
            # An Azure word kept only in its place: a real name equal to one is masked elsewhere.
            $T = '(?:non)?prod_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
            Protect-SitePropertiesValue 'DOCKER|private.azurecr.io/custom123' | Should -Match ('^DOCKER\|{0}\.azurecr\.io/{0}$' -f $T)
            Protect-SitePropertiesValue 'DOCKER|r.azurecr.io/node:latest' | Should -Match ('^DOCKER\|{0}\.azurecr\.io/{0}:latest$' -f $T)
            Protect-SitePropertiesValue 'DOCKER|r.azurecr.io/web:v2-prod' | Should -Match ('^DOCKER\|{0}\.azurecr\.io/{0}:{0}-{0}$' -f $T)
            Protect-SitePropertiesValue 'NODE|18-lts' | Should -Be 'NODE|18-lts'
            Protect-SitePropertiesValue 'custom' | Should -Match ('^{0}$' -f $T)
            # Letters of any script are a real part.
            $Name = -join [char[]](0x9867, 0x5BA2, 0x540D)
            $Out = Protect-SitePropertiesValue ('DOTNETCORE|8.0 ' + $Name)
            $Out.Contains($Name) | Should -BeFalse
            Test-RdaSitePropertiesMasked $Out | Should -BeTrue
            Test-RdaSitePropertiesMasked ('DOTNETCORE|8.0 ' + $Name) | Should -BeFalse
            Test-RdaSitePropertiesMasked 'DOCKER|private.azurecr.io/custom123' | Should -BeFalse
            # A leak check of a real value's digits reads the text outside the tokens, since a token's
            # random GUID can hold those digits; a real value left in is still outside them.
            # A long number (an account id) is masked; a GUID run into letters is one part, not a GUID and a word.
            ((Protect-SitePropertiesValue 'DOCKER|123456789012.dkr.ecr.eu-west-1.amazonaws.com/web:1') -replace $T, '') | Should -Not -Match '123456789012'
            $Glued = Protect-SitePropertiesValue 'x 11111111-2222-3333-4444-555555555555ab'
            Test-RdaSitePropertiesMasked $Glued | Should -BeTrue
            ($Glued -replace $T, '') | Should -Not -Match '555555555555ab|2222|3333|4444'
            # The real GUID does not come back as a token's GUID either.
            $Glued | Should -Not -Match '11111111-2222-3333-4444-555555555555'
            # A time is kept as it is.
            Protect-SitePropertiesValue '2026-11-15T09:00:00Z' | Should -Be '2026-11-15T09:00:00Z'
            # A time only when it is a real time.
            Protect-SitePropertiesValue '9999-99-99T99:99:99Z' | Should -Not -Be '9999-99-99T99:99:99Z'
            Test-RdaSitePropertiesMasked '9999-99-99T99:99:99Z' | Should -BeFalse
            # A registry host's numbers (an IP) are masked; its port stays.
            $Ip = Protect-SitePropertiesValue 'DOCKER|10.23.45.67:5000/team/image:1'
            $Ip | Should -Not -Match '\b(10|23|45|67)\b'
            $Ip | Should -Match (':5000/{0}/{0}:1$' -f $T)
            # A character outside the Basic Multilingual Plane is a real part, not a separator.
            $Wide = [char]::ConvertFromUtf32(0x1D41A) + [char]::ConvertFromUtf32(0x1D429)
            (Protect-SitePropertiesValue ('DOTNETCORE|8.0 ' + $Wide)).Contains($Wide) | Should -BeFalse
            Test-RdaSitePropertiesMasked ('DOTNETCORE|8.0 ' + $Wide) | Should -BeFalse
            # The masked check reads parts by their place: a list word out of its place fails it.
            Test-RdaSitePropertiesMasked 'DOCKER|r.azurecr.io/node/python' | Should -BeFalse
            Test-RdaSitePropertiesMasked (Protect-SitePropertiesValue 'DOCKER|r.azurecr.io/node:latest') | Should -BeTrue
            Test-RdaSitePropertiesMasked 'go' | Should -BeTrue
            Test-RdaSitePropertiesMasked 'NODE|18-io' | Should -BeFalse
            # An IP is one real part anywhere; a bracketed IPv6 registry host is masked, its port kept.
            Protect-SitePropertiesValue 'note 10.1.2.3 end' | Should -Not -Match '10\.1\.2\.3|\b(10|1|2|3)\b'
            $V6 = Protect-SitePropertiesValue 'DOCKER|[1234:5678:9012:3456:7890:1234:5678:9012]:5000/team/image:1'
            ($V6 -replace $T, '') | Should -Not -Match '5678|9012'
            $V6 | Should -Match (':5000/{0}/{0}:1$' -f $T)
            # A bare IPv6 address, and an IP run into letters, are one real part too.
            Protect-SitePropertiesValue 'conn 2001:db8::8a2e:370:7334 ok' | Should -Match ('^{0} {0} {0}$' -f $T)
            Protect-SitePropertiesValue 'host10.20.30.40 x' | Should -Match ('^{0} {0}$' -f $T)
            Protect-SitePropertiesValue 'at 10.1.2.3abc' | Should -Match ('^{0} {0}$' -f $T)
            # An IPv6 address with an IPv4 tail, or run into letters, is one part too.
            Protect-SitePropertiesValue 'a ::ffff:192.0.2.128 b' | Should -Match ('^{0} {0} {0}$' -f $T)
            Protect-SitePropertiesValue 'host2001:db8::1 x' | Should -Match ('^{0} {0}$' -f $T)
            Test-RdaSitePropertiesMasked 'DOTNETCORE|8.0 x::ffff:192.0.2.128' | Should -BeFalse
            # However many letters run into it.
            Protect-SitePropertiesValue (('q' * 300) + 'fd00:1234:5678::1') | Should -Match ('^{0}$' -f $T)
            # A long run of hex letters costs one pass (no IPv6 search from every place in it).
            $Watch = [System.Diagnostics.Stopwatch]::StartNew()
            $null = Protect-SitePropertiesValue ('abcde12345' * 3200)
            $Watch.Elapsed.TotalSeconds | Should -BeLessThan 2
            # A separator run that starts with '[' stays a separator.
            Protect-SitePropertiesValue '[Prod] a' | Should -Match ('^\[{0}\] {0}$' -f $T)
            Protect-SitePropertiesValue 'Foo :: Bar' | Should -Match ('^{0} :: {0}$' -f $T)
            # Brackets around a word or a number are separators, not an IPv6 address.
            Protect-SitePropertiesValue '[dead] a' | Should -Match ('^\[{0}\] {0}$' -f $T)
            Protect-SitePropertiesValue '[1234]' | Should -Match ('^\[{0}\]$' -f $T)
            # A number is kept only where Azure writes one (a version, a tag, a port), not in an app setting's value.
            $Setting = Protect-SitePropertiesValue @{ name = 'CustomerAccountCode'; value = '450012' }
            $Setting['value'] | Should -Match ('^{0}$' -f $T)
            Test-RdaSitePropertiesMasked @{ name = 'CustomerAccountCode'; value = '450012' } | Should -BeFalse
            Protect-SitePropertiesValue 'DOCKER|r.azurecr.io:5000/team2/web:42' | Should -Match ('^DOCKER\|{0}\.azurecr\.io:5000/{0}/{0}:42$' -f $T)
            Protect-SitePropertiesValue 'DOTNETCORE|8.0' | Should -Be 'DOTNETCORE|8.0'
            # A value with a '|' whose head is no stack word is the customer's, version and all.
            Protect-SitePropertiesValue 'acct|450012' | Should -Match ('^{0}\|{0}$' -f $T)
            Protect-SitePropertiesValue 'CustomerCode|450012-77' | Should -Match ('^{0}\|{0}-{0}$' -f $T)
            # Azure's words stay only as the value of a setting Azure names, not in another object.
            $Secret = Protect-SitePropertiesValue @{ name = 'CustomerSecret'; value = 'docker' }
            $Secret['value'] | Should -Match ('^{0}$' -f $T)
            $Secret['name'] | Should -Match ('^{0}$' -f $T)
            Test-RdaSitePropertiesMasked @{ name = 'CustomerSecret'; value = 'docker' } | Should -BeFalse
            $Fx = Protect-SitePropertiesValue @{ name = 'LinuxFxVersion'; value = 'NODE|18-lts' }
            $Fx['name'] | Should -Be 'LinuxFxVersion'
            $Fx['value'] | Should -Be 'NODE|18-lts'
            (Protect-SitePropertiesValue @{ other = 'LinuxFxVersion' })['other'] | Should -Match ('^{0}$' -f $T)
            # A setting only in the 'properties' or 'metadata' list Azure writes; elsewhere (an app setting) it is
            # the customer's, and so are an app setting dictionary's keys.
            $Nested = Protect-SitePropertiesValue @{ appSettings = @(@{ name = 'LinuxFxVersion'; value = 'PYTHON|450012' }); properties = @(@{ name = 'LinuxFxVersion'; value = 'PYTHON|3.11' }) }
            ((ConvertTo-Json -InputObject $Nested['appSettings'] -Compress -Depth 5) -replace $T, '') | Should -Not -Match '450012|LinuxFxVersion|PYTHON'
            $Nested['properties'][0]['value'] | Should -Be 'PYTHON|3.11'
            $Keys = Protect-SitePropertiesValue @{ appSettings = @{ CustomerKey = 'v1' } }
            @($Keys['appSettings'].Keys) | Should -Match ('^{0}$' -f $T)
            Test-RdaSitePropertiesMasked $Keys | Should -BeTrue
            Test-RdaSitePropertiesMasked @{ appSettings = @{ CustomerKey = 'v1' } } | Should -BeFalse
            # Two masked keys of one object are two entries: a plain value under either is found.
            $Two = Protect-SitePropertiesValue @{ appSettings = @(@{ name = 'CustomerSecret'; value = 'acme-payroll' }) }
            $Item = $Two['appSettings'][0]
            foreach ($K in @($Item.Keys))
            {
                $Planted = @{ appSettings = @(@{}) }
                foreach ($K2 in @($Item.Keys)) { $Planted['appSettings'][0][$K2] = $(if ($K2 -eq $K) { 'acmepayroll' } else { $Item[$K2] }) }
                Test-RdaSitePropertiesMasked $Planted | Should -BeFalse -Because $K
            }
            Test-RdaSitePropertiesMasked $Two | Should -BeTrue
            # Plain letters glued to a token are not a mark word.
            $Tok = $Global:FreeTextDictionary['custom']
            Test-RdaSitePropertiesMasked ('DOTNETCORE|8.0 ' + $Tok + 'jazz') | Should -BeFalse
            Test-RdaSitePropertiesMasked @{ other = @{ ($Tok + 'buzz') = $Tok } } | Should -BeFalse
            # A plain value can never equal a mark word: the marks are made for each value checked.
            Test-RdaSitePropertiesMasked @{ appSettings = @{ $Tok = 'zzrdatokenmarkazz'; $Global:FreeTextDictionary['web'] = 'zzrdatokenmarkzz' } } | Should -BeFalse
            # Two tokens that touch still read as masked.
            Test-RdaSitePropertiesMasked ('DOTNETCORE|8.0 ' + $Global:FreeTextDictionary['custom'] + $Global:FreeTextDictionary['custom']) | Should -BeTrue
            # A time as the pull writes it, lower-cased, is a time.
            Protect-SitePropertiesValue '2026-11-15t09:00:00z' | Should -Be '2026-11-15t09:00:00z'
            # A masked number alone is not a real value the leak scan looks for; a masked word is.
            $Global:FreeTextDictionary['1234567'] = 'prod_00000000-0000-0000-0000-000000000001'
            $Set = Get-RdaRealValueSet
            $Set.Contains('1234567') | Should -BeFalse
            $Set.Contains('myreg') | Should -BeTrue
            # An isolated Functions stack is Azure's word.
            Protect-SitePropertiesValue 'DOTNET-ISOLATED|8.0' | Should -Be 'DOTNET-ISOLATED|8.0'
        }
        finally { $Global:FreeTextDictionary = $Saved }
    }
}

Describe 'Get-RdaPageFailedCollector' {
    It 'reads the collectors a page names, and refuses a cut page or a banner that lists fewer than it counts' {
        $Banner = '<div class="coverage-banner"><span class="coverage-icon">&#9888;</span><div><b>Incomplete collection:</b> 2 resource type(s) could not be collected and are MISSING from this report - not empty because there are none, but because the collector errored: <code>VMSS</code>, <code>(unnamed collector)</code>. See the Diagnostics log in this bundle for the underlying error, then re-run.</div></div>'
        $Page = "<html><body>$Banner<p>x</p><script>`n</script>`n</body>`n</html>`n"
        @(Get-RdaPageFailedCollector -Html $Page) | Should -Be @('VMSS', '(unnamed collector)')
        @(Get-RdaPageFailedCollector -Html ($Page -replace [regex]::Escape($Banner), '')).Count | Should -Be 0
        { Get-RdaPageFailedCollector -Html $Page.Substring(0, $Page.IndexOf('<p>')) } | Should -Throw '*cut off*'
        { Get-RdaPageFailedCollector -Html ($Page -replace '<code>VMSS</code>, ', '') } | Should -Throw '*fewer*'
        { Get-RdaPageFailedCollector -Html ($Page -replace '\. See the Diagnostics.*?</div></div>', '') } | Should -Throw '*banner is cut off*'
    }
}

Describe 'ConvertFrom-RdaRunSummaryText detail lists' {
    BeforeAll {
        # As the wrapper writes it (Out-File) and the mask reads it (Get-Content): a message
        # over several lines is several lines.
        function script:Get-RoundTrip([string[]]$Lines)
        {
            $F = Join-Path ([IO.Path]::GetTempPath()) ('RdaRs_' + [guid]::NewGuid().ToString('N') + '.log')
            try { $Lines | Out-File -FilePath $F -Encoding utf8; return @(Get-Content -LiteralPath $F) }
            finally { Remove-Item -LiteralPath $F -Force -ErrorAction SilentlyContinue }
        }
        $script:RsArgs = @{ InvocationParameters = ([ordered]@{}); Version = '3.2.3'; StartTime = ([datetime]'2026-11-13 08:00:00'); EndTime = ([datetime]'2026-11-13 09:00:00'); Visible = 3; Eligible = 3; Processed = 3 }
        # The splat with its own -InvocationParameters (PowerShell 7.0 refuses a parameter both splatted and named).
        function script:Get-RsArgs($Invocation) { $A = @{} + $script:RsArgs; $A['InvocationParameters'] = $Invocation; $A }
        $script:Guid = '12345678-1234-1234-1234-123456789012'
    }

    It 'reads messages and reasons that run over lines, and still counts each list' {
        $Coverage = @('3 subscription(s) in this run (3 visible to the tenant), 1 report(s) in this zip.', '2 subscription(s) without a report in this zip:', ("  - Sub B ($script:Guid): collection failed: Operation returned an invalid status code 'Forbidden'`nPlease provide below info when asking for support: x`n`n  more: not collected by this run"), "  - Sub C ($script:Guid): not collected by this run (for example an interrupted run; the next run collects it)")
        $Failures = @([pscustomobject]@{ Id = $script:Guid; Module = 'VMSS'; Message = "line one`nPlease provide below info when asking for support:`nHealth:" }, [pscustomobject]@{ Id = $script:Guid; Module = 'AKS'; Message = 'x' })
        $Lines = script:Get-RoundTrip @(Get-RunSummaryLogContent @script:RsArgs -CoverageLines $Coverage -CollectorFailures $Failures)
        $S = ConvertFrom-RdaRunSummaryText -Lines $Lines
        @($S.CoverageLines) | Should -Be @('3 subscription(s) in this run (3 visible to the tenant), 1 report(s) in this zip.', '2 subscription(s) without a report in this zip:', '  - 1 collection failed', '  - 1 not collected')
        @($S.Arguments.CollectorFailures).Count | Should -Be 2
    }

    It 'refuses a run summary cut before or inside a detail list a count above 0 adds' {
        $Cases = @(
            @{ CollectorFailures = @([pscustomobject]@{ Id = $script:Guid; Module = 'VMSS'; Message = "a`nb" }, [pscustomobject]@{ Id = $script:Guid; Module = 'AKS'; Message = 'x' }) }
            @{ RetryLimited = @([pscustomobject]@{ Name = 'Sub B'; Id = $script:Guid; Attempts = 3; Reason = 'x' }) }
            @{ EmptyNoAccess = @([pscustomobject]@{ Name = 'Sub C'; Id = $script:Guid }) }
            @{ FailedSubscriptions = @('Sub D (stream-1: x)') }
            @{ MetricsFailedSubs = @([pscustomobject]@{ Name = 'Sub E'; Id = $script:Guid; Message = 'auth' }) }
            @{ MetricsFailedSubs = @([pscustomobject]@{ Name = 'Sub F'; Id = $script:Guid; Message = 'x'; Complete = $false }) }
            @{ ConsumptionFailedSubs = @([pscustomobject]@{ Name = 'Sub G'; Id = $script:Guid; Message = 'x' }) }
            @{ RetryLimited = @([pscustomobject]@{ Name = 'Sub H'; Id = $script:Guid; Attempts = 3; Reason = 'x' }); MissingReports = @([pscustomobject]@{ Name = 'Sub H'; Id = $script:Guid }); MissingReportCount = 1 }
        )
        foreach ($Case in $Cases)
        {
            $Lines = script:Get-RoundTrip @(Get-RunSummaryLogContent @script:RsArgs @Case)
            { ConvertFrom-RdaRunSummaryText -Lines $Lines } | Should -Not -Throw -Because ($Case.Keys -join ',')
            $Health = [array]::IndexOf($Lines, 'Health:')
            # Cut right after the last Health line (the line before the blank that ends the section).
            $HealthLast = $Health; while ($HealthLast + 1 -lt $Lines.Count -and $Lines[$HealthLast + 1] -ne '') { $HealthLast++ }
            { ConvertFrom-RdaRunSummaryText -Lines $Lines[0..$HealthLast] } | Should -Throw '*detail list*' -Because ($Case.Keys -join ',')
            { ConvertFrom-RdaRunSummaryText -Lines $Lines[0..($Lines.Count - 2)] } | Should -Throw '*detail list*' -Because ($Case.Keys -join ',')
        }
    }

    It 'keeps a reason''s own bullet line in its entry, and refuses a reason line that reads as a section, or a coverage line not as the run writes it' {
        $Head = '2 subscription(s) in this run (2 visible to the tenant), 1 report(s) in this zip.'
        $Bullet = script:Get-RoundTrip @(Get-RunSummaryLogContent @script:RsArgs -CoverageLines @($Head, '1 subscription(s) without a report in this zip:', "  - Sub B ($script:Guid): collection failed: Forbidden`n    - check the role`n    - then retry"))
        @((ConvertFrom-RdaRunSummaryText -Lines $Bullet).CoverageLines) | Should -Be @($Head, '1 subscription(s) without a report in this zip:', '  - 1 collection failed')
        $Section = script:Get-RoundTrip @(Get-RunSummaryLogContent @script:RsArgs -CoverageLines @($Head, '1 subscription(s) without a report in this zip:', "  - Sub B ($script:Guid): collection failed: x`nSubscriptions:`n  Failed    : 0"))
        { ConvertFrom-RdaRunSummaryText -Lines $Section } | Should -Throw '*out of order*'
        # A header seen first but later than the writer writes it.
        $Late = script:Get-RoundTrip @(Get-RunSummaryLogContent @script:RsArgs -HostVCpu 4)
        $HostAt = [array]::IndexOf($Late, 'Host / parallelism:')
        $SubAt = [array]::IndexOf($Late, 'Subscriptions:')
        $Moved = @($Late[0..($HostAt - 1)]) + @($Late[$SubAt..($Late.Count - 1)] | Select-Object -First 1) + @('  Visible   : 2') + @('', 'Host / parallelism:', '  Host vCPU         : 4')
        { ConvertFrom-RdaRunSummaryText -Lines $Moved } | Should -Throw '*out of order*'
        # The coverage section without its count line, or entries without their heading.
        $Full = script:Get-RoundTrip @(Get-RunSummaryLogContent @script:RsArgs -CoverageLines @($Head, '1 subscription(s) without a report in this zip:', "  - Sub B ($script:Guid): not collected by this run (x)"))
        { ConvertFrom-RdaRunSummaryText -Lines $Full } | Should -Not -Throw
        { ConvertFrom-RdaRunSummaryText -Lines @($Full | Where-Object { $_ -ne "  $Head" }) } | Should -Throw
        { ConvertFrom-RdaRunSummaryText -Lines @($Full | Where-Object { $_ -ne '  1 subscription(s) without a report in this zip:' }) } | Should -Throw '*coverage line*'
        $NoCount = @($Full | Where-Object { $_ -ne "  $Head" -and $_ -ne '  1 subscription(s) without a report in this zip:' -and $_ -notlike '    - Sub B*' })
        { ConvertFrom-RdaRunSummaryText -Lines $NoCount } | Should -Throw '*no count line*'
        # Copied-on text only in the writer's forms: a parameter of the wrapper, the tuning
        # numbers as numbers, the tool version's three numbers, a source word of the wrapper.
        # The splat with its own -InvocationParameters (PowerShell 7.0 refuses a parameter both splatted and named).
        $WithStreams = @{} + $script:RsArgs
        $WithStreams['InvocationParameters'] = [ordered]@{ ParallelStreams = 2 }
        $Plain = script:Get-RoundTrip @(Get-RunSummaryLogContent @WithStreams -HostVCpu 4 -Streams 2 -StreamsSource 'auto')
        { ConvertFrom-RdaRunSummaryText -Lines $Plain } | Should -Not -Throw
        { ConvertFrom-RdaRunSummaryText -Lines @($Plain -replace '^  -ParallelStreams 2$', '  -ContosoSecret 2') } | Should -Throw '*parameter the wrapper does not have*'
        { ConvertFrom-RdaRunSummaryText -Lines @($Plain -replace '^  -ParallelStreams 2$', '  -ParallelStreams contoso-secret') } | Should -Throw '*not a number*'
        { ConvertFrom-RdaRunSummaryText -Lines @($Plain -replace '^Tool version    : 3\.2\.3$', 'Tool version    : contoso-secret') } | Should -Throw '*head of the run summary*'
        { ConvertFrom-RdaRunSummaryText -Lines @($Plain -replace '\(auto\)$', '(contoso-secret)') } | Should -Throw
        # The tool version once; no -WhatIf (the wrapper does not support ShouldProcess).
        { ConvertFrom-RdaRunSummaryText -Lines @($Plain | Where-Object { $_ -notlike 'Tool version*' }) } | Should -Throw '*head of the run summary*'
        { ConvertFrom-RdaRunSummaryText -Lines @($Plain | ForEach-Object { $_; if ($_ -like 'Tool version*') { $_ } }) } | Should -Throw '*head of the run summary*'
        # The head holds the writer's lines only, each once.
        $Timed = script:Get-RoundTrip @(Get-RunSummaryLogContent @script:RsArgs)
        { ConvertFrom-RdaRunSummaryText -Lines $Timed } | Should -Not -Throw
        { ConvertFrom-RdaRunSummaryText -Lines @($Timed | ForEach-Object { $_; if ($_ -like 'Run started*') { $_ } }) } | Should -Throw '*head of the run summary*'
        # In the writer's order, Generated required, the duration only from both times and equal to them.
        { ConvertFrom-RdaRunSummaryText -Lines @($Timed | Where-Object { $_ -notlike 'Generated*' }) } | Should -Throw '*head of the run summary*'
        { ConvertFrom-RdaRunSummaryText -Lines @($Timed | Where-Object { $_ -notlike 'Run started*' }) } | Should -Throw '*head of the run summary*'
        { ConvertFrom-RdaRunSummaryText -Lines @($Timed -replace '^Total duration  : .*$', 'Total duration  : 9m 00s') } | Should -Throw '*head of the run summary*'
        # The writer takes the duration from the full times, the printed ones cut to the second.
        { ConvertFrom-RdaRunSummaryText -Lines @($Timed -replace '^Total duration  : .*$', 'Total duration  : 59m 59s') } | Should -Not -Throw
        $Started = [array]::IndexOf($Timed, ($Timed | Where-Object { $_ -like 'Run started*' } | Select-Object -First 1))
        $Swapped = @($Timed); $Swapped[$Started], $Swapped[$Started + 1] = $Swapped[$Started + 1], $Swapped[$Started]
        { ConvertFrom-RdaRunSummaryText -Lines $Swapped } | Should -Throw '*head of the run summary*'
        { ConvertFrom-RdaRunSummaryText -Lines @($Timed | ForEach-Object { if ($_ -like 'Parameters:') { '' }; $_ }) } | Should -Throw '*head of the run summary*'
        # A host whose culture writes the time with '.' (fi-FI, da-DK), and a 7.4 run's -ProgressAction.
        $Saved = [cultureinfo]::CurrentCulture
        $Sp = script:Get-RsArgs ([ordered]@{ ProgressAction = 'SilentlyContinue' })
        try { [cultureinfo]::CurrentCulture = 'fi-FI'; $Finnish = script:Get-RoundTrip @(Get-RunSummaryLogContent @Sp) }
        finally { [cultureinfo]::CurrentCulture = $Saved }
        @($Finnish | Where-Object { $_ -like 'Run started*' })[0] | Should -Match '\d{2}\.\d{2}\.\d{2}$'
        (ConvertFrom-RdaRunSummaryText -Lines $Finnish).Arguments.StartTime | Should -Be ([datetime]'2026-11-13 08:00:00')
        # A host whose calendar is not Gregorian (fa-IR), over a month end of that calendar.
        $Persian = @{} + $script:RsArgs; $Persian.HostRamGB = 15.6; $Persian.StartTime = [datetime]'2026-09-22 20:00:00'; $Persian.EndTime = [datetime]'2026-09-23 04:30:00'
        try { [cultureinfo]::CurrentCulture = 'fa-IR'; $FaLines = script:Get-RoundTrip @(Get-RunSummaryLogContent @Persian) }
        finally { [cultureinfo]::CurrentCulture = $Saved }
        # The date as this runtime's fa-IR writes it (.NET 5+: the Persian calendar, 1405-06-31; .NET Core 3.1: Gregorian).
        $FaDate = $Persian.StartTime.ToString('yyyy-MM-dd', [cultureinfo]'fa-IR')
        @($FaLines | Where-Object { $_ -like 'Run started*' })[0] | Should -Match ('^Run started     : ' + [regex]::Escape($FaDate))
        $FaBack = (ConvertFrom-RdaRunSummaryText -Lines $FaLines).Arguments
        $FaBack.StartTime | Should -Be $Persian.StartTime
        $FaBack.EndTime | Should -Be $Persian.EndTime
        # fa-IR writes the RAM figure with its own decimal mark (U+066B).
        @($FaLines | Where-Object { $_ -like '  Host RAM*' })[0] | Should -Match ('15[{0}/]6$' -f [char]0x066B) -Because 'ICU writes U+066B, Windows NLS writes /'
        $FaBack.HostRamGB | Should -Be 15.6
        # Inside one Persian month its dates are Gregorian dates too: a mask on the fa-IR host reads them as written.
        $InMonth = @{} + $script:RsArgs; $InMonth.StartTime = [datetime]'2026-09-06 08:00:00'; $InMonth.EndTime = [datetime]'2026-09-06 09:00:00'
        try
        {
            [cultureinfo]::CurrentCulture = 'fa-IR'
            $InLines = script:Get-RoundTrip @(Get-RunSummaryLogContent @InMonth)
            $InBack = (ConvertFrom-RdaRunSummaryText -Lines $InLines).Arguments
        }
        finally { [cultureinfo]::CurrentCulture = $Saved }
        $InBack.StartTime | Should -Be $InMonth.StartTime
        $InBack.EndTime | Should -Be $InMonth.EndTime
        # A Thai host whose user chose the Gregorian calendar writes Gregorian dates: read as written.
        $ThaiGregorian = ([cultureinfo]'th-TH').Clone(); $ThaiGregorian.DateTimeFormat.Calendar = [System.Globalization.GregorianCalendar]::new()
        try
        {
            [cultureinfo]::CurrentCulture = $ThaiGregorian
            $ThLines = script:Get-RoundTrip @(Get-RunSummaryLogContent @InMonth)
            $ThBack = (ConvertFrom-RdaRunSummaryText -Lines $ThLines).Arguments
        }
        finally { [cultureinfo]::CurrentCulture = $Saved }
        @($ThLines | Where-Object { $_ -like 'Run started*' })[0] | Should -Match '^Run started     : 2026-09-06'
        $ThBack.StartTime | Should -Be $InMonth.StartTime
        $ThBack.EndTime | Should -Be $InMonth.EndTime
        # A host in invariant globalization mode builds none of the other cultures: it still reads a run summary.
        $Pwsh = (Get-Process -Id $PID).Path
        $Script = ". '{0}'; . '{1}'; . '{2}'; `$L = @(Get-RunSummaryLogContent -InvocationParameters @{{}} -Version '3.2.3' -Visible 1 -Eligible 1 -Processed 1 -StartTime ([datetime]'2026-11-13 08:00:00') -EndTime ([datetime]'2026-11-13 09:00:00')); (ConvertFrom-RdaRunSummaryText -Lines `$L).Arguments.StartTime.ToString('s')" -f (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1'), (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1'), (Join-Path $script:RepoRoot 'Functions/OfflineObfuscation.Functions.ps1')
        $SavedInvariant = $Env:DOTNET_SYSTEM_GLOBALIZATION_INVARIANT
        $Env:DOTNET_SYSTEM_GLOBALIZATION_INVARIANT = '1'
        try { $Out = & $Pwsh -NoProfile -NonInteractive -Command $Script 2>&1 } finally { $Env:DOTNET_SYSTEM_GLOBALIZATION_INVARIANT = $SavedInvariant }
        ($Out | Select-Object -Last 1) | Should -Be '2026-11-13T08:00:00'
        # One culture wrote the generated time and both run times: one separator.
        { ConvertFrom-RdaRunSummaryText -Lines @($Timed -replace '^(Generated \(UTC\) : \S+T\d{2}):(\d{2}):(\d{2})Z$', '$1.$2.$3Z') } | Should -Throw '*head of the run summary*'
        { ConvertFrom-RdaRunSummaryText -Lines @($Finnish -replace '^(Generated \(UTC\) : \S+T\d{2})\.(\d{2})\.(\d{2})Z$', '$1:$2:$3Z') } | Should -Throw '*head of the run summary*'
        { ConvertFrom-RdaRunSummaryText -Lines @($Timed -replace '^(Run finished    : \S+ \d{2}):(\d{2}):(\d{2})$', '$1.$2.$3') } | Should -Throw '*head of the run summary*'
        # The duration only in the writer's form, and one time separator through a time.
        foreach ($Off in '60m 00s', '0h 05m 00s', '1h 00m 60s', '059m 59s')
        {
            { ConvertFrom-RdaRunSummaryText -Lines @($Timed -replace '^Total duration  : .*$', ('Total duration  : ' + $Off)) } | Should -Throw '*head of the run summary*' -Because $Off
        }
        { ConvertFrom-RdaRunSummaryText -Lines @($Timed -replace '^(Run started     : \S+ \d{2}):(\d{2}):', '$1:$2.') } | Should -Throw '*head of the run summary*'
        { ConvertFrom-RdaRunSummaryText -Lines @($Timed | ForEach-Object { $_; if ($_ -like 'Tool version*') { 'Operator  : contoso-secret' } }) } | Should -Throw '*head of the run summary*'
        { ConvertFrom-RdaRunSummaryText -Lines @($Plain -replace '^  -ParallelStreams 2$', '  -WhatIf') } | Should -Throw '*parameter the wrapper does not have*'
        # Each section line for line as the writer writes it: a line twice, out of order, a value
        # on a switch, a switch with no value, a word or tail the writer does not write.
        $Sp = script:Get-RsArgs ([ordered]@{ ConcurrencyLimit = 4; ParallelStreams = 2; SkipMetrics = [switch]::Present })
        $Many = script:Get-RoundTrip @(Get-RunSummaryLogContent @Sp -HostVCpu 4)
        { ConvertFrom-RdaRunSummaryText -Lines $Many } | Should -Not -Throw
        $SectionCases = @(
            @($Many | ForEach-Object { $_; if ($_ -eq '  -ParallelStreams 2') { $_ } })
            @($Many | ForEach-Object { if ($_ -eq '  -ConcurrencyLimit 4') { '  -ParallelStreams 2' } elseif ($_ -eq '  -ParallelStreams 2') { '  -ConcurrencyLimit 4' } else { $_ } })
            @($Many -replace '^  -SkipMetrics$', '  -SkipMetrics yes')
            @($Many -replace '^  -ParallelStreams 2$', '  -ParallelStreams')
            @($Many | ForEach-Object { $_; if ($_ -like '  Host vCPU*') { $_ } })
            @($Many -replace '^(  Excluded  : 0) \(non-Enabled\)$', '$1 (contoso-secret)')
            @($Many | ForEach-Object { $_; if ($_ -like '  Collector failures*') { '  Operator failures             : 0' } })
            @($Many | ForEach-Object { $_; if ($_ -eq '  -ConcurrencyLimit 4') { '  (defaults - no switches or values passed)' } })
        )
        $Ram = script:Get-RoundTrip @(Get-RunSummaryLogContent @script:RsArgs -HostVCpu 4 -HostRamGB 15.6)
        { ConvertFrom-RdaRunSummaryText -Lines $Ram } | Should -Not -Throw
        $SectionCases += , @($Ram | ForEach-Object { $_; if ($_ -like '  Host RAM*') { $_ } })
        foreach ($Case in $SectionCases)
        {
            { ConvertFrom-RdaRunSummaryText -Lines $Case } | Should -Throw
        }
        # The unnamed-missing line only in the writer's words; only its count is kept.
        $Unnamed = script:Get-RoundTrip @(Get-RunSummaryLogContent @script:RsArgs -CoverageLines @('3 subscription(s) in this run (3 visible to the tenant), 1 report(s) in this zip.', '2 subscription(s) without a report in this zip:', '  - 2 report missing that could not be named (see Per-subscription output verification on the console)') -MissingReportCount 2)
        (ConvertFrom-RdaRunSummaryText -Lines $Unnamed).CoverageLines[-1] | Should -Be '  - 2 report missing that could not be named (see Per-subscription output verification on the console)'
        { ConvertFrom-RdaRunSummaryText -Lines @($Unnamed -replace '\(see Per-subscription output verification on the console\)$', '(contoso)') } | Should -Throw '*coverage line*'
        # PowerShell's common parameters are in $PSBoundParameters too, and the writer lists them.
        $Sp = script:Get-RsArgs ([ordered]@{ Debug = [switch]::Present; ErrorAction = 'Stop' })
        $Common = @(Get-RunSummaryLogContent @Sp)
        $Back = (ConvertFrom-RdaRunSummaryText -Lines (script:Get-RoundTrip $Common)).Arguments
        $Again = @(Get-RunSummaryLogContent @Back -Obfuscated | Where-Object { $_ -notlike 'Generated*' })
        $Sp = script:Get-RsArgs ([ordered]@{ Debug = [switch]::Present; ErrorAction = 'Stop'; Obfuscate = [switch]::Present })
        $Live = @(Get-RunSummaryLogContent @Sp -Obfuscated | Where-Object { $_ -notlike 'Generated*' })
        $Again | Should -Be $Live
        $Text = script:Get-RoundTrip @(Get-RunSummaryLogContent @script:RsArgs -CoverageLines @('contoso-secret'))
        { ConvertFrom-RdaRunSummaryText -Lines $Text } | Should -Throw '*coverage line*'
        $Twice = script:Get-RoundTrip @(Get-RunSummaryLogContent @script:RsArgs -CoverageLines @($Head, '1 subscription(s) without a report in this zip:', "  - Sub ($script:Guid): not collected by this run ($script:Guid): collection failed: x"))
        { ConvertFrom-RdaRunSummaryText -Lines $Twice } | Should -Throw '*more than one way*'
    }
}

Describe 'ConvertFrom-RdaMainSummaryMark' {
    It 'reads back the counts and row marks of a plain main summary, so the -Obfuscated one shows the same' {
        $Dir = Join-Path ([IO.Path]::GetTempPath()) ('RdaMain_' + [guid]::NewGuid().ToString('N'))
        try
        {
            $Folders = foreach ($S in '20261113080000000aaaa', '20261113080000000bbbb', '20261113080000000cccc')
            {
                $F = Join-Path $Dir ('ResourcesReport' + $S); New-Item -ItemType Directory -Path $F -Force | Out-Null
                '{"VirtualMachines":[],"Version":"3.2.3"}' | Set-Content -LiteralPath (Join-Path $F "Inventory_ResourcesReport_$S.json")
                '<html></html>' | Set-Content -LiteralPath (Join-Path $F "ResourcesReport_$S.html")
                'ResourcesReport' + $S
            }
            $Consumption = @([pscustomobject]@{ Name = 'Sub A'; Id = 'id-a'; Message = 'x'; ReportFolder = $Folders[0] }, [pscustomobject]@{ Name = 'Sub B'; Id = '(auth)'; Message = 'x'; ReportFolder = $Folders[1] })
            $Metrics = @([pscustomobject]@{ Name = 'Sub C'; Id = 'id-c'; Message = 'x'; ReportFolder = $Folders[2] }, [pscustomobject]@{ Name = 'Sub A'; Id = 'id-a'; Message = 'x'; Complete = $false; ReportFolder = $Folders[0] })
            $Html = { param($C, $M, [switch]$Obf) $Out = Join-Path $Dir ([guid]::NewGuid().ToString('N') + '.html'); New-RdaAllSubHtmlSummary -RunOutputDirectory $Dir -HtmlFile $Out -ReportFolders $Folders -ConsumptionFailedSubs $C -MetricsFailedSubs $M -Obfuscated:$Obf *> $null; (Get-Content -LiteralPath $Out -Raw) -replace '<b>Generated:</b>[^<]*', '' }
            $Marks = ConvertFrom-RdaMainSummaryMark -Html (& $Html $Consumption $Metrics)
            (& $Html $Marks.ConsumptionFailedSubs $Marks.MetricsFailedSubs -Obf) | Should -Be (& $Html $Consumption $Metrics -Obf)
        }
        finally { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'counts distinct incomplete entries, keeps a row a repeated entry marks, and reads a Windows link' {
        $Dir = Join-Path ([IO.Path]::GetTempPath()) ('RdaMain_' + [guid]::NewGuid().ToString('N'))
        try
        {
            $Folders = foreach ($S in '20261113080000000aaaa', '20261113080000000bbbb', '20261113080000000cccc', '20261113080000000dddd')
            {
                $F = Join-Path $Dir ('ResourcesReport' + $S); New-Item -ItemType Directory -Path $F -Force | Out-Null
                '{"VirtualMachines":[],"Version":"3.2.3"}' | Set-Content -LiteralPath (Join-Path $F "Inventory_ResourcesReport_$S.json")
                '<html></html>' | Set-Content -LiteralPath (Join-Path $F "ResourcesReport_$S.html")
                'ResourcesReport' + $S
            }
            # One sign-in skip, two incomplete subscriptions, and the first of them again on another row.
            $Metrics = @(
                [pscustomobject]@{ Name = 'Sub C'; Id = 'id-c'; Message = 'x'; ReportFolder = $Folders[2] },
                [pscustomobject]@{ Name = 'Sub A'; Id = 'id-a'; Message = 'x'; Complete = $false; ReportFolder = $Folders[0] },
                [pscustomobject]@{ Name = 'Sub B'; Id = 'id-b'; Message = 'x'; Complete = $false; ReportFolder = $Folders[1] },
                [pscustomobject]@{ Name = 'Sub A'; Id = 'id-a'; Message = 'x'; Complete = $false; ReportFolder = $Folders[3] })
            $Html = { param($M, [switch]$Obf) $Out = Join-Path $Dir ([guid]::NewGuid().ToString('N') + '.html'); New-RdaAllSubHtmlSummary -RunOutputDirectory $Dir -HtmlFile $Out -ReportFolders $Folders -MetricsFailedSubs $M -Obfuscated:$Obf *> $null; (Get-Content -LiteralPath $Out -Raw) -replace '<b>Generated:</b>[^<]*', '' }
            $Plain = & $Html $Metrics
            $Plain | Should -Match 'Metrics incomplete: 2 subscription'
            # Join-Path writes the link with '\' on Windows.
            $WindowsPlain = $Plain -replace '(href="ResourcesReport[^/"]+)/', '$1\'
            $Marks = ConvertFrom-RdaMainSummaryMark -Html $WindowsPlain
            (& $Html $Marks.MetricsFailedSubs -Obf) | Should -Be (& $Html $Metrics -Obf)
        }
        finally { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses a cut-off page, and one that shows more or fewer failures than the run summary counts' {
        $Dir = Join-Path ([IO.Path]::GetTempPath()) ('RdaMain_' + [guid]::NewGuid().ToString('N'))
        try
        {
            $S = '20261113080000000aaaa'
            $F = Join-Path $Dir ('ResourcesReport' + $S); New-Item -ItemType Directory -Path $F -Force | Out-Null
            '{"VirtualMachines":[],"Version":"3.2.3"}' | Set-Content -LiteralPath (Join-Path $F "Inventory_ResourcesReport_$S.json")
            '<html></html>' | Set-Content -LiteralPath (Join-Path $F "ResourcesReport_$S.html")
            $Consumption = @([pscustomobject]@{ Name = 'Sub A'; Id = 'id-a'; Message = 'x'; ReportFolder = 'ResourcesReport' + $S })
            $Out = Join-Path $Dir 'main.html'
            New-RdaAllSubHtmlSummary -RunOutputDirectory $Dir -HtmlFile $Out -ReportFolders @('ResourcesReport' + $S) -ConsumptionFailedSubs $Consumption *> $null
            $Plain = Get-Content -LiteralPath $Out -Raw
            # A count of 0 is read back from a run summary as $null.
            $Run = [pscustomobject]@{ ConsumptionFailedSubs = @('x'); MetricsFailedSubs = $null }
            { ConvertFrom-RdaMainSummaryMark -Html $Plain -RunSummary $Run } | Should -Not -Throw
            { ConvertFrom-RdaMainSummaryMark -Html ($Plain.Substring(0, $Plain.IndexOf('</tbody>'))) } | Should -Throw '*cut off*'
            { ConvertFrom-RdaMainSummaryMark -Html $Plain -RunSummary ([pscustomobject]@{ ConsumptionFailedSubs = @(); MetricsFailedSubs = @() }) } | Should -Throw '*run summary*'
            { ConvertFrom-RdaMainSummaryMark -Html $Plain -RunSummary ([pscustomobject]@{ ConsumptionFailedSubs = @('x'); MetricsFailedSubs = @('y') }) } | Should -Throw '*run summary*'
            # Cut before the table's first row.
            { ConvertFrom-RdaMainSummaryMark -Html ($Plain.Substring(0, $Plain.IndexOf('<tbody>'))) } | Should -Throw '*cut off*'
            # A consumption sign-in skip the run summary counts and the page neither counts nor marks.
            $NoConsump = Join-Path $Dir 'none.html'
            New-RdaAllSubHtmlSummary -RunOutputDirectory $Dir -HtmlFile $NoConsump -ReportFolders @('ResourcesReport' + $S) *> $null
            { ConvertFrom-RdaMainSummaryMark -Html (Get-Content -LiteralPath $NoConsump -Raw) -RunSummary ([pscustomobject]@{ ConsumptionFailedSubs = @('(auth)'); MetricsFailedSubs = $null }) } | Should -Not -Throw
            # Metrics: each kind must be the run summary's (a sign-in skip on the page, an incomplete one in the run summary).
            $Auth = Join-Path $Dir 'auth.html'
            New-RdaAllSubHtmlSummary -RunOutputDirectory $Dir -HtmlFile $Auth -ReportFolders @('ResourcesReport' + $S) -MetricsFailedSubs @([pscustomobject]@{ Name = 'Sub A'; Id = 'id-a'; Message = 'x'; ReportFolder = 'ResourcesReport' + $S }) *> $null
            $AuthHtml = Get-Content -LiteralPath $Auth -Raw
            { ConvertFrom-RdaMainSummaryMark -Html $AuthHtml -RunSummary ([pscustomobject]@{ ConsumptionFailedSubs = $null; MetricsFailedSubs = @([pscustomobject]@{ Name = 'e'; Id = 'm-0' }) }) } | Should -Not -Throw
            { ConvertFrom-RdaMainSummaryMark -Html $AuthHtml -RunSummary ([pscustomobject]@{ ConsumptionFailedSubs = $null; MetricsFailedSubs = @([pscustomobject]@{ Name = 'e'; Id = 'm-0'; Complete = $false }) }) } | Should -Throw '*run summary*'
            # A metrics row marked with no metrics count on the page.
            { ConvertFrom-RdaMainSummaryMark -Html ($AuthHtml -replace '<b>Metrics auth-skipped: 1 subscription\(s\)\.</b>', '') } | Should -Throw '*marks more metrics rows*'
        }
        finally { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Read-RdaJsonFile keeps the text a run wrote' {
    It 'keeps date strings as text, whole numbers whole, other numbers as numbers and a list of one a list' {
        $V = ConvertFrom-RdaJsonText -Text '{"A":"2026-11-13T11:42:18.0000000Z","B":3,"C":3.0,"D":[{"x":1}],"E":null,"F":true}'
        $V['A'] | Should -BeOfType [string]
        $V['A'] | Should -BeExactly '2026-11-13T11:42:18.0000000Z'
        $V['B'] | Should -BeOfType [long]
        $V['C'] | Should -BeOfType [double]
        $V['D'].GetType().IsArray | Should -BeTrue
        @($V['D']).Count | Should -Be 1
        $V['E'] | Should -BeNullOrEmpty
        (ConvertTo-Json -InputObject $V['C'] -Compress) | Should -Be '3.0'
    }

    It 'refuses a cut-off file' {
        { ConvertFrom-RdaJsonText -Text '{"VirtualMachines":[{"ID":"/subscriptions/s"' } | Should -Throw
        { ConvertFrom-RdaJsonText -Text '{"A":1} {"B":2}' } | Should -Throw
    }
}

Describe 'Protect-RdaOfflineField masks a collector field from its plain value' {
    BeforeEach {
        $Global:ResourceIdDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceNameDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:FreeTextDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $script:Vm1 = '/subscriptions/s1/resourcegroups/rg-a/providers/microsoft.compute/virtualmachines/vm1'
        $script:Vm1b = '/subscriptions/s1/resourcegroups/rg-b/providers/microsoft.compute/virtualmachines/vm1'
        $Global:ResourceIdDictionary[$script:Vm1] = 'masked-vm1-a'
        $Global:ResourceIdDictionary[$script:Vm1b] = 'masked-vm1-b'
        $Global:ResourceNameDictionary[$script:Vm1] = 'name-vm1-a'
        $Global:ResourceIdDictionary['/subscriptions/s1/resourcegroups/rg-a/providers/microsoft.sql/servers/srv'] = 'masked-srv'
        $Global:ResourceIdDictionary['/subscriptions/s1/resourcegroups/rg-a/providers/microsoft.sql/servers/srv/elasticpools/pool1'] = 'masked-pool'
        $Global:ResourceIdDictionary['/subscriptions/s1/resourcegroups/rg-d/providers/microsoft.compute/virtualmachines/vm2'] = 'masked-vm2'
        $Global:ResourceIdDictionary['/subscriptions/s1/resourcegroups/rg-a/providers/microsoft.compute/virtualmachines/set1'] = 'masked-set1-vm'
        $Inventory = @{
            VirtualMachines = @(
                @{ ID = $script:Vm1; Name = 'vm1'; Subscription = 'Sub One'; ResourceGroup = 'rg-a' }
                @{ ID = $script:Vm1b; Name = 'vm1'; Subscription = 'Sub One'; ResourceGroup = 'rg-b' }
                @{ ID = '/subscriptions/s1/resourcegroups/rg-d/providers/microsoft.compute/virtualmachines/vm2'; Name = 'vm2'; Subscription = 'Sub One'; ResourceGroup = 'rg-d' }
                @{ ID = '/subscriptions/s1/resourcegroups/rg-a/providers/microsoft.compute/virtualmachines/set1'; Name = 'set1'; Subscription = 'Sub One'; ResourceGroup = 'rg-a' }
            )
            VMSS = @(@{ ID = '/subscriptions/s1/resourcegroups/rg-a/providers/microsoft.compute/virtualmachinescalesets/set1'; Name = 'set1'; Subscription = 'Sub One'; ResourceGroup = 'rg-a' })
        }
        $VmIndex = New-RdaNameIndex -Inventory $Inventory -Sections 'VirtualMachines'
        $script:Indexes = @{ 'VMSS.AKS' = $VmIndex; 'MachineLearning.StorageAccount' = @{}; 'VMDisk.AssociatedResource' = $VmIndex; 'VMDisk.AssociatedResource.also' = (New-RdaNameIndex -Inventory $Inventory -Sections 'VMSS'); 'AvSet.VirtualMachines' = $VmIndex; 'PublicIP.AssociatedResource' = @{} }
        $script:Rules = @(Get-RdaOfflineFieldRule)
        $script:Mask = { param([string]$Section, [hashtable]$Row) Protect-RdaOfflineField -Row $Row -Rules @($script:Rules | Where-Object { $_.Section -eq $Section }) -NameIndexes $script:Indexes; $Row }
    }

    It 'links a disk to the one VM of its name in its subscription; two of that name, or a scale set of that name, is obfuscated' {
        # Two VMs named vm1 (groups rg-a and rg-b): a disk may sit in another group than its VM, so neither is taken.
        (& $script:Mask 'VMDisk' @{ ID = '/subscriptions/s1/resourcegroups/rg-b/providers/microsoft.compute/disks/d1'; Subscription = 'Sub One'; ResourceGroup = 'rg-b'; AssociatedResource = 'vm1' }).AssociatedResource | Should -Be 'obfuscated'
        (& $script:Mask 'VMDisk' @{ ID = '/subscriptions/s1/resourcegroups/rg-c/providers/microsoft.compute/disks/d1'; Subscription = 'Sub One'; ResourceGroup = 'rg-c'; AssociatedResource = 'vm1' }).AssociatedResource | Should -Be 'obfuscated'
        (& $script:Mask 'VMDisk' @{ ID = '/subscriptions/s1/resourcegroups/rg-c/providers/microsoft.compute/disks/d1'; Subscription = 'Sub One'; ResourceGroup = 'rg-c'; AssociatedResource = 'vm2' }).AssociatedResource | Should -Be 'masked-vm2'
        # A scale set instance's disk holds the set's name: a VM of that name is not its owner.
        (& $script:Mask 'VMDisk' @{ ID = '/subscriptions/s1/resourcegroups/rg-a/providers/microsoft.compute/disks/d1'; Subscription = 'Sub One'; ResourceGroup = 'rg-a'; AssociatedResource = 'set1' }).AssociatedResource | Should -Be 'obfuscated'
        # An availability set's VMs are in its group (Azure's rule), so the group decides there.
        (& $script:Mask 'AvSet' @{ ID = '/subscriptions/s1/resourcegroups/rg-b/providers/microsoft.compute/availabilitysets/as1'; Subscription = 'Sub One'; ResourceGroup = 'rg-b'; VirtualMachines = 'vm1' }).VirtualMachines | Should -Be 'masked-vm1-b'
        (& $script:Mask 'VMDisk' @{ ID = '/subscriptions/s2/resourcegroups/rg-a/providers/microsoft.compute/disks/d1'; Subscription = 'Sub One'; ResourceGroup = 'rg-a'; AssociatedResource = 'vm1' }).AssociatedResource | Should -Be 'obfuscated'
        # Two subscriptions can share a display name: the scope is the subscription id of the row's own id.
        (& $script:Mask 'VMDisk' @{ ID = '/subscriptions/s2/resourcegroups/rg-d/providers/microsoft.compute/disks/d2'; Subscription = 'Sub One'; ResourceGroup = 'rg-d'; AssociatedResource = 'vm2' }).AssociatedResource | Should -Be 'obfuscated'
        (& $script:Mask 'VMDisk' @{ ID = '/subscriptions/s1/resourcegroups/rg-a/providers/microsoft.compute/disks/d1'; Subscription = 'Sub One'; ResourceGroup = 'rg-a'; AssociatedResource = $null }).AssociatedResource | Should -BeNullOrEmpty
    }

    It 'masks a full id it knows and writes obfuscated for one it does not; an empty one stays' {
        (& $script:Mask 'VirtualMachines' @{ ID = 'x'; Set = $script:Vm1 }).Set | Should -Be 'masked-vm1-a'
        (& $script:Mask 'VirtualMachines' @{ ID = 'x'; Set = '/subscriptions/s1/resourcegroups/rg-a/providers/microsoft.compute/virtualmachinescalesets/gone' }).Set | Should -Be 'obfuscated'
        (& $script:Mask 'VirtualMachines' @{ ID = 'x'; Set = $null }).Set | Should -BeNullOrEmpty
        (& $script:Mask 'SQLVM' @{ ID = 'x'; ParentVirtualMachine = 'None' }).ParentVirtualMachine | Should -Be 'obfuscated'
    }

    It 'gives a database its server and pool from its own id; None stays None' {
        $Db = '/subscriptions/s1/resourcegroups/rg-a/providers/microsoft.sql/servers/srv/databases/db1'
        $R = & $script:Mask 'SQLDB' @{ ID = $Db; DatabaseServer = 'srv'; ElasticPoolID = 'pool1' }
        $R.DatabaseServer | Should -Be 'masked-srv'
        $R.ElasticPoolID | Should -Be 'masked-pool'
        (& $script:Mask 'SQLDB' @{ ID = $Db; DatabaseServer = 'srv'; ElasticPoolID = 'None' }).ElasticPoolID | Should -Be 'None'
        (& $script:Mask 'SQLDB' @{ ID = $Db; DatabaseServer = 'srv'; ElasticPoolID = 'pool9' }).ElasticPoolID | Should -Be 'obfuscated'
    }

    It 'masks each role name of a cloud service, inside its Roles list' {
        $R = & $script:Mask 'CloudServices' @{ ID = 'x'; Roles = @(@{ RoleName = 'web-role-01'; SkuName = 'Standard_D2' }, @{ RoleName = 'worker-role-01'; SkuName = 'Standard_D2' }) }
        foreach ($Role in $R.Roles) { $Role.RoleName | Should -Match '^(non)?prod_[0-9a-f-]{36}$'; $Role.SkuName | Should -Be 'Standard_D2' }
        $Shape = Get-RdaReportShape -RepoRoot $script:RepoRoot
        Get-RdaUnknownInventoryShape -Rows @{ CloudServices = @(@{ ID = '/subscriptions/s/resourcegroups/g/providers/microsoft.compute/cloudservices/n'; Name = 'n'; Subscription = 's'; ResourceGroup = 'g'; Location = 'l'; Roles = @(@{ RoleName = 'r'; SkuName = 'k'; SkuTier = 't'; SkuCapacity = 1 }) }) } -Shape $Shape | Should -BeNullOrEmpty
        Get-RdaUnknownInventoryShape -Rows @{ CloudServices = @(@{ ID = '/subscriptions/s/resourcegroups/g/providers/microsoft.compute/cloudservices/n'; Name = 'n'; Subscription = 's'; ResourceGroup = 'g'; Location = 'l'; Roles = @(@{ RoleName = 'r'; Owner = 'someone' }) }) } -Shape $Shape | Should -Be 'a nested field the CloudServices collector does not write'
        # A key the record itself has (Name) is no key of a role.
        Get-RdaUnknownInventoryShape -Rows @{ CloudServices = @(@{ ID = '/subscriptions/s/resourcegroups/g/providers/microsoft.compute/cloudservices/n'; Name = 'n'; Subscription = 's'; ResourceGroup = 'g'; Location = 'l'; Roles = @(@{ RoleName = 'r'; Name = 'web-01' }) }) } -Shape $Shape | Should -Be 'a nested field the CloudServices collector does not write'
        # A record in a field where the collector adds none.
        Get-RdaUnknownInventoryShape -Rows @{ VirtualMachines = @(@{ ID = '/subscriptions/s/resourcegroups/g/providers/microsoft.compute/virtualmachines/n'; Name = 'n'; Subscription = 's'; ResourceGroup = 'g'; Size = @{ Owner = 'someone' } }) } -Shape $Shape | Should -Be 'a nested field the VirtualMachines collector does not write'
    }

    It 'writes obfuscated for a host id or name it does not know, and for a workspace with no storage account' {
        $Gone = '/subscriptions/s1/resourcegroups/rg-a/providers/microsoft.compute/virtualmachines/gone'
        $R = & $script:Mask 'AVD' @{ ID = 'x'; HostId = $Gone; Hostname = 'gone' }
        $R.HostId | Should -Be 'obfuscated'
        $R.Hostname | Should -Be 'obfuscated'
        (& $script:Mask 'MachineLearning' @{ ID = 'x'; Subscription = 'Sub One'; ResourceGroup = 'rg-a'; StorageAccount = $null }).StorageAccount | Should -Be 'obfuscated'
        # An insights name does not prove which resource it is (unique only in its group).
        (& $script:Mask 'MachineLearning' @{ ID = 'x'; ApplicationInsight = 'insights-01' }).ApplicationInsight | Should -Be 'obfuscated'
        # A scale set outside an AKS node group names a Service Fabric cluster, not an AKS one.
        (& $script:Mask 'VMSS' @{ ID = '/subscriptions/s1/resourcegroups/rg-sf/providers/microsoft.compute/virtualmachinescalesets/nt1'; AKS = 'vm2' }).AKS | Should -Be 'obfuscated'
    }

    It 'names an AVD host by its VM''s name token, from the plain host id' {
        $R = & $script:Mask 'AVD' @{ ID = 'x'; HostId = $script:Vm1; Hostname = 'vm1' }
        $R.HostId | Should -Be 'masked-vm1-a'
        $R.Hostname | Should -Be 'name-vm1-a'
        $R = & $script:Mask 'AVD' @{ ID = 'x'; HostId = $null; Hostname = $null }
        $R.Hostname | Should -BeNullOrEmpty
    }

    It 'writes the fixed values, free text tokens, the Front Door policy list and a public IP''s link as a run does' {
        (& $script:Mask 'NetApp' @{ ID = 'x'; NetAppAccount = 'acct'; CapacityPool = 'pool'; Volume = 'vol' }).Volume | Should -Be 'obfuscated'
        (& $script:Mask 'DataExplorerCluster' @{ ID = 'x'; StateReason = 'why' }).StateReason | Should -BeNullOrEmpty
        $Token = (& $script:Mask 'AKS' @{ ID = 'x'; NodePoolName = 'pool-dev' }).NodePoolName
        $Token | Should -Match '^nonprod_[0-9a-f-]{36}$'
        (& $script:Mask 'AKS' @{ ID = 'y'; NodePoolName = 'pool-dev' }).NodePoolName | Should -Be $Token -Because 'one real value has one token'
        (& $script:Mask 'Frontdoor' @{ ID = 'x'; WebApplicationFirewall = 'waf-one, waf-two (1 of 3 endpoints without WAF)' }).WebApplicationFirewall | Should -Be 'obfuscated, obfuscated (1 of 3 endpoints without WAF)'
        (& $script:Mask 'Frontdoor' @{ ID = 'x'; WebApplicationFirewall = 'Unknown' }).WebApplicationFirewall | Should -Be 'Unknown'
        (& $script:Mask 'PublicIP' @{ ID = 'x'; AssociatedResource = 'nic-1'; AssociatedResourceType = 'networkinterfaces' }).AssociatedResource | Should -Be 'obfuscated'
        (& $script:Mask 'PublicIP' @{ ID = 'x'; AssociatedResource = 'None'; AssociatedResourceType = 'None' }).AssociatedResource | Should -Be 'None'
    }
}

Describe 'The run summary and the diagnostics log read back write what a -Obfuscate run writes' {
    It 'refuses a run summary with a line it does not know, a coverage list shorter than it states, or a Host RAM line in either decimal mark' {
        $Lines = Get-RunSummaryLogContent -InvocationParameters @{} -Version '3.2.3' -Visible 2 -Eligible 2 -Processed 2 -CoverageLines @('2 subscription(s) in this run (2 visible to the tenant), 1 report(s) in this zip.', '1 subscription(s) without a report in this zip:', '  - Sub Q (00000000-0000-0000-0000-000000000001): report missing (collected, but its report zip was not written or is gone; the next run collects it)') -HostRamGB 15.6
        $Back = (ConvertFrom-RdaRunSummaryText -Lines $Lines).Arguments
        $Back.HostRamGB | Should -Be 15.6
        (ConvertFrom-RdaRunSummaryText -Lines ($Lines -replace '^  Host RAM \(GB\)     : 15\.6$', '  Host RAM (GB)     : 15,6')).Arguments.HostRamGB | Should -Be 15.6
        { ConvertFrom-RdaRunSummaryText -Lines (@($Lines) + 'a line no run writes') } | Should -Throw
        # A name holding a reason's words: the reason at the end of the line decides the kind.
        $Odd = @($Lines -replace '^    - Sub Q \(00000000-0000-0000-0000-000000000001\): report missing', '    - Q: retry limit reached (x) (00000000-0000-0000-0000-000000000001): report missing')
        (ConvertFrom-RdaRunSummaryText -Lines $Odd).CoverageLines[-1] | Should -Be '  - 1 report missing'
        { ConvertFrom-RdaRunSummaryText -Lines @($Lines | Where-Object { $_ -notlike '    - Sub Q*' }) } | Should -Throw -ExpectedMessage '*fewer subscriptions than it states*'
        { ConvertFrom-RdaRunSummaryText -Lines @($Lines | Where-Object { $_ -notlike '  Metrics incomplete subs*' }) } | Should -Throw -ExpectedMessage '*cut off*'
        { ConvertFrom-RdaDiagnosticsText -Lines @() } | Should -Throw
    }

    It 'Get-RunSummaryLogContent: reads back the consumption sign-in skip count and the exit code section, and refuses an exit code line the wrapper does not write' {
        $RunArgs = @{
            InvocationParameters = [ordered]@{}
            Version = '3.2.3'; StartTime = [datetime]'2026-11-13 08:00:00'; EndTime = [datetime]'2026-11-13 09:00:00'
            Visible = 3; Eligible = 3; Processed = 3
            # Two sign-in skips of one subscription count once, and a billing failure of another.
            ConsumptionFailedSubs = @([pscustomobject]@{ Name = 'Sub C'; Id = 'id-cs'; Message = 'billing' }, [pscustomobject]@{ Name = 'Sub A'; Id = '(auth)'; SubscriptionId = 'id-a'; Message = 'auth' }, [pscustomobject]@{ Name = 'Sub A'; Id = '(auth)'; SubscriptionId = 'id-a'; Message = 'auth' }, [pscustomobject]@{ Name = 'Sub B'; Id = '(auth)'; SubscriptionId = 'id-b'; Message = 'auth' })
            ExitCodeLines = @(Get-WrapperExitCodeSummary -AuthSkipped $true -CollectorsFailed $false -SubscriptionsFailed $true -UnreadableStreams @([pscustomobject]@{ StreamId = 2; SubCount = 3; Reason = 'Missing' }) -OtherReasons @('a per-stream resume state file is kept (named above)') -ConsumptionFailed $true)
        }
        $Plain = @(Get-RunSummaryLogContent @RunArgs)
        $Plain | Should -Contain '  Consumption sign-in skipped   : 2 subscription(s)'
        $Plain | Should -Contain 'Exit code:'
        $RunArgs.InvocationParameters['Obfuscate'] = [switch]::Present
        # A -Obfuscate run's guide commands carry -Obfuscate.
        $RunArgs.CommandSettings = Get-RetryCommandSettings -Settings (Get-RunDataSettings -Obfuscate $true -SkipMetrics $false -SkipConsumption $false -IncludeDisabled $false -IncludeNetworkResources $false) -DeviceLogin $false -SubscriptionID ''
        $Expected = Get-RunSummaryLogContent @RunArgs -Obfuscated
        $Back = (ConvertFrom-RdaRunSummaryText -Lines $Plain).Arguments
        $Again = Get-RunSummaryLogContent @Back -Obfuscated
        @($Again | Where-Object { $_ -notlike 'Generated (UTC)*' }) | Should -Be @($Expected | Where-Object { $_ -notlike 'Generated (UTC)*' })
        ($Again -join "`n") | Should -Not -Match 'Sub |id-'
        # An exit code line holding text the wrapper does not write, or a sign-in line not as the run writes it, is refused.
        $ExitAt = [array]::IndexOf([string[]]$Plain, 'Exit code:')
        $Odd = @($Plain[0..$ExitAt]) + '  Exit code 2: Contoso failed.' + @($Plain[($ExitAt + 1)..($Plain.Count - 1)])
        { ConvertFrom-RdaRunSummaryText -Lines $Odd } | Should -Throw '*exit code section*'
        { ConvertFrom-RdaRunSummaryText -Lines @($Plain -replace '^  Consumption sign-in skipped   : 2 subscription\(s\)$', '  Consumption sign-in skipped   : 2') } | Should -Throw '*not as the run writes it*'
    }

    It 'Get-RunSummaryLogContent: the plain log read back gives the -Obfuscated log of the same run' {
        $Without = @(
            [pscustomobject]@{ Name = 'Sub L'; Id = '00000000-0000-0000-0000-000000000002'; Kind = 'retry limit reached'; Reason = 'retry limit reached (failed 3 runs in a row; to try it again, start a new run with -Fresh)' }
            [pscustomobject]@{ Name = 'Sub R'; Id = '00000000-0000-0000-0000-000000000003'; Kind = 'report missing'; Reason = 'report missing (collected, but its report zip was not written or is gone; the next run collects it)' }
            [pscustomobject]@{ Name = 'Sub X: (odd)'; Id = '00000000-0000-0000-0000-000000000004'; Kind = 'not enabled or excluded'; Reason = 'not enabled or excluded (state: Disabled)' }
        )
        $RunArgs = @{
            InvocationParameters = [ordered]@{ ParallelStreams = 4; UseMetricsBatch = [switch]::Present; ResumeMaxAgeDays = 'Contoso'; SkipMetrics = [switch]::Present; DeviceLogin = [switch]::Present; SubscriptionID = '00000000-0000-0000-0000-00000000000f' }
            Version = '3.2.3'; StartTime = [datetime]'2026-11-13 08:00:00'; EndTime = [datetime]'2026-11-13 16:05:09'
            Visible = 5; Excluded = 1; Eligible = 4; Processed = 4; Skipped = 0
            EmptyNoAccess = @([pscustomobject]@{ Name = 'Sub NA'; Id = 'id-na' }); EmptyGenuinelyEmpty = @(); EmptyUndetermined = @()
            FailedSubscriptions = @('Sub F (stream-2: boom)')
            CollectorFailures = @([pscustomobject]@{ Id = 'id-c'; Module = 'VMSS'; Message = 'boom on vm-x' })
            MetricsFailedSubs = @([pscustomobject]@{ Name = 'Sub M'; Id = 'id-m'; Message = 'auth' }, [pscustomobject]@{ Name = 'Sub I'; Id = 'id-i'; Message = 'throttled'; Complete = $false })
            ConsumptionFailedSubs = @([pscustomobject]@{ Name = 'Sub C'; Id = 'id-cs'; Message = 'billing' })
            RetryLimited = @([pscustomobject]@{ Name = 'Sub L'; Id = '00000000-0000-0000-0000-000000000002'; Attempts = 3; Reason = 'x' })
            MissingReportCount = 2; MissingReports = @([pscustomobject]@{ Name = 'Sub L'; Id = '00000000-0000-0000-0000-000000000002' }, [pscustomobject]@{ Name = 'Sub R'; Id = '00000000-0000-0000-0000-000000000003' })
            CoverageLines = @(Get-RunReportCoverageLines -Coverage ([pscustomobject]@{ InRun = 4; Visible = 5; ReportsInZip = 2; UnnamedMissing = 1; WithoutReport = $Without }))
            ConsumptionRecordCount = 701; HostVCpu = 32; HostRamGB = 61.4; Streams = 6; StreamsSource = 'auto'; Concurrency = 16; ConcurrencySource = 'auto'
        }
        # The guide's commands carry the run's switches (-SkipMetrics, -DeviceLogin) and, with -Obfuscate, -Obfuscate: the same settings, as a run holds them.
        $RunArgs.CommandSettings = Get-RetryCommandSettings -Settings (Get-RunDataSettings -Obfuscate $false -SkipMetrics $true -SkipConsumption $false -IncludeDisabled $false -IncludeNetworkResources $false) -DeviceLogin $true -SubscriptionID '00000000-0000-0000-0000-00000000000f'
        $RunArgs.CommandSettings['UseMetricsBatch'] = $true
        $Plain = Get-RunSummaryLogContent @RunArgs
        $Plain | Should -Contain 'Which flag to use (this run is not complete):'
        $Kinds = @($Without | ForEach-Object { [pscustomobject]@{ Kind = $_.Kind } })
        $RunArgs.CoverageLines = @(Get-RunReportCoverageLines -Coverage ([pscustomobject]@{ InRun = 4; Visible = 5; ReportsInZip = 2; UnnamedMissing = 1; WithoutReport = $Kinds }) -Obfuscated)
        $RunArgs.InvocationParameters['Obfuscate'] = [switch]::Present
        $RunArgs.CommandSettings = Get-RetryCommandSettings -Settings (Get-RunDataSettings -Obfuscate $true -SkipMetrics $true -SkipConsumption $false -IncludeDisabled $false -IncludeNetworkResources $false) -DeviceLogin $true -SubscriptionID '00000000-0000-0000-0000-00000000000f'
        $RunArgs.CommandSettings['UseMetricsBatch'] = $true
        $Expected = Get-RunSummaryLogContent @RunArgs -Obfuscated
        $Back = (ConvertFrom-RdaRunSummaryText -Lines $Plain).Arguments
        $Again = Get-RunSummaryLogContent @Back -Obfuscated
        @($Again | Where-Object { $_ -notlike 'Generated (UTC)*' }) | Should -Be @($Expected | Where-Object { $_ -notlike 'Generated (UTC)*' })
        ($Again -join "`n") | Should -Not -Match 'Sub |id-|Contoso|boom'
        # The guide is read back as the run writes it, with the placeholders and the switches; a changed guide is refused.
        ($Again -join "`n") | Should -Match '-TenantID <tenant id> -SubscriptionID <subscription id> -Resume -Obfuscate -SkipMetrics -DeviceLogin -UseMetricsBatch'
        ($Again -join "`n") | Should -Not -Match '00000000-0000-0000-0000-00000000000f'
        { ConvertFrom-RdaRunSummaryText -Lines @($Plain -replace '-Resume -SkipMetrics -DeviceLogin -UseMetricsBatch \(it continues', '-Resume -DeviceLogin -SkipMetrics -UseMetricsBatch (it continues') } | Should -Throw
        # A switch of the guide the run was not given, or one it was given that the guide leaves out, is refused.
        { ConvertFrom-RdaRunSummaryText -Lines @($Plain -replace '-Resume -SkipMetrics -DeviceLogin -UseMetricsBatch \(it continues', '-Resume -SkipMetrics -DeviceLogin (it continues') } | Should -Throw '*does not carry the switches*'
        { ConvertFrom-RdaRunSummaryText -Lines @($Plain -replace '-Resume -SkipMetrics -DeviceLogin -UseMetricsBatch \(it continues', '-Resume -DeviceLogin -UseMetricsBatch (it continues') } | Should -Throw '*does not carry the switches*'
        { ConvertFrom-RdaRunSummaryText -Lines @($Plain -replace '-Resume -SkipMetrics -DeviceLogin -UseMetricsBatch \(it continues', '-Resume -SkipMetrics -SkipConsumption -DeviceLogin -UseMetricsBatch (it continues') } | Should -Throw '*does not carry the switches*'
        # A line of a failure message that equals a list header does not start the list over (it would drop the entries counted so far).
        $HeaderAt = [array]::IndexOf([string[]]@($Plain), 'Collector failures (detail):')
        $HeaderAt | Should -BeGreaterThan 0
        $Echo = @($Plain[0..($HeaderAt + 1)]) + 'Collector failures (detail):' + @($Plain[($HeaderAt + 2)..($Plain.Count - 1)])
        { ConvertFrom-RdaRunSummaryText -Lines $Echo } | Should -Not -Throw
        # A message line that is an earlier list's header, or a header in another case, is a message line too.
        foreach ($Fake in 'Failed subscriptions (detail):', 'collector failures (DETAIL):')
        {
            $Mixed = @($Plain[0..$HeaderAt]) + $Fake + @($Plain[($HeaderAt + 1)..($Plain.Count - 1)])
            { ConvertFrom-RdaRunSummaryText -Lines $Mixed } | Should -Not -Throw -Because $Fake
        }
        # A message line equal to a LATER list's header cannot be told from the header: the log is refused (never read wrong), by the count check.
        $LaterAt = [array]::IndexOf([string[]]@($Plain), 'Collector failures (detail):')
        $Later = @($Plain[0..$LaterAt]) + 'Consumption failed subscriptions (detail):' + @($Plain[($LaterAt + 1)..($Plain.Count - 1)])
        { ConvertFrom-RdaRunSummaryText -Lines $Later } | Should -Throw '*cut off*'
        # -Obfuscate in a plain log's guide is refused (a plain run's commands never carry it).
        { ConvertFrom-RdaRunSummaryText -Lines @($Plain -replace '-Resume -SkipMetrics -DeviceLogin -UseMetricsBatch \(it continues', '-Resume -Obfuscate -SkipMetrics -DeviceLogin -UseMetricsBatch (it continues') } | Should -Throw '*does not carry the switches*'
        # The guide is where the writer puts it: a copy of it inside a message below is not it. With the real guide cut out and a copy put in the detail lists, the log is refused.
        $GuideAt = [array]::IndexOf([string[]]@($Plain), 'Which flag to use (this run is not complete):')
        $GuideEnd = $GuideAt + 1; while ($Plain[$GuideEnd] -ne '') { $GuideEnd++ }
        $Copy = @($Plain[($GuideAt - 1)..($GuideEnd - 1)])
        $Cut = @($Plain[0..($GuideAt - 2)]) + @($Plain[$GuideEnd..($Plain.Count - 1)]) + $Copy
        { ConvertFrom-RdaRunSummaryText -Lines $Cut } | Should -Throw '*not as the run writes it*'
        { ConvertFrom-RdaRunSummaryText -Lines @($Plain -replace 'Past the retry limit \(3 failed runs in a row\)', 'Past the limit') } | Should -Throw '*not as the run writes it*'
    }

    It 'Write-RdaShareableDiagnosticsLog: the plain log read back gives the -Obfuscated log, with no failure text and the facts kept' {
        $Dir = Join-Path ([IO.Path]::GetTempPath()) ('RdaDiag_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Dir | Out-Null
        try
        {
            $Times = [ordered]@{ 'Metrics collection (Azure Monitor)' = [TimeSpan]::FromSeconds(125); 'Resource detail collection (service collectors)' = [TimeSpan]::FromSeconds(9) }
            $Global:ResourceIdDictionary = $null; $Global:ResourceNameDictionary = $null; $Global:ResourceSubscriptionDictionary = $null; $Global:ResourceResourceGroupDictionary = $null; $Global:TagValueDictionary = $null; $Global:FreeTextDictionary = $null
            $Sub = '11111111-2222-3333-4444-555555555555'
            $Global:CollectorFailures = @(
                [pscustomobject]@{ Id = $Sub; Module = 'VMSS'; Message = "boom on vm-secret-01`nsecond line"; Facts = 'exception=System.Net.WebException status=403 code=AuthorizationFailed' },
                [pscustomobject]@{ Id = $Sub; Module = 'AKS'; Message = "first`n`nafter a blank line" },
                [pscustomobject]@{ Id = $Sub; Module = 'SQL'; Message = "looks like a header:`nCollector failures: 0`nPhase timings:"; Facts = 'code=Contoso-Secret-Code' })
            $Global:MetricsFailedSubs = @([pscustomobject]@{ Id = $Sub; Message = 'auth on vm-secret-01' }, [pscustomobject]@{ Id = '(unknown)'; Message = 'no subscription' }, [pscustomobject]@{ Id = $Sub; Message = 'incomplete'; Complete = $false })
            $Global:ConsumptionFailedSubs = @([pscustomobject]@{ Id = $Sub; Message = 'billing'; PageAtFailure = 3; RecordsCollected = 1200; Facts = 'status=429' })
            $PlainFile = Write-RdaShareableDiagnosticsLog -DefaultPath ($Dir + '/') -ReportName 'P' -RunDateTime '1' -Version '3.2.3' -PhaseTimings $Times
            (Get-Content -LiteralPath $PlainFile -Raw) | Should -Not -Match 'vm-secret-01|boom|Contoso|looks like'
            $Parsed = ConvertFrom-RdaDiagnosticsText -Lines (Get-Content -LiteralPath $PlainFile) -ReportFolder 'ResourcesReport1'
            $Parsed.Obfuscated | Should -BeFalse
            $Parsed.CollectorFailures[0].Facts | Should -Be 'exception=System.Net.WebException status=403 code=AuthorizationFailed'
            $Parsed.CollectorFailures[1].Facts | Should -Be ''
            $Parsed.CollectorFailures[2].Facts | Should -Be ''
            $Parsed.ConsumptionFailedSubs[0].Facts | Should -Be 'status=429 page=3 records=1200'

            $ExpectedFile = Write-RdaShareableDiagnosticsLog -DefaultPath ($Dir + '/') -ReportName 'E' -RunDateTime '1' -Version '3.2.3' -PhaseTimings $Times -Obfuscated
            $Global:CollectorFailures = @($Parsed.CollectorFailures); $Global:MetricsFailedSubs = @($Parsed.MetricsFailedSubs); $Global:ConsumptionFailedSubs = @($Parsed.ConsumptionFailedSubs)
            $AgainFile = Write-RdaShareableDiagnosticsLog -DefaultPath ($Dir + '/') -ReportName 'A' -RunDateTime '1' -Version $Parsed.Version -PhaseTimings $Parsed.PhaseTimings -Obfuscated
            @(Get-Content -LiteralPath $AgainFile | Where-Object { $_ -notlike 'Generated (UTC)*' }) | Should -Be @(Get-Content -LiteralPath $ExpectedFile | Where-Object { $_ -notlike 'Generated (UTC)*' })
            (Get-Content -LiteralPath $AgainFile -Raw) | Should -Not -Match 'vm-secret-01|boom|Contoso'
            (ConvertFrom-RdaDiagnosticsText -Lines (Get-Content -LiteralPath $AgainFile)).Obfuscated | Should -BeTrue
        }
        finally
        {
            Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
            $Global:CollectorFailures = @(); $Global:MetricsFailedSubs = @(); $Global:ConsumptionFailedSubs = @(); $Global:FreeTextDictionary = $null
        }
    }

    It 'reads no facts from a log that holds message text, and none outside the closed grammar' {
        $Dir = Join-Path ([IO.Path]::GetTempPath()) ('RdaDiagOld_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Dir | Out-Null
        try
        {
            $Global:CollectorFailures = @([pscustomobject]@{ Id = '11111111-2222-3333-4444-555555555555'; Module = 'VMSS'; Message = 'x' })
            $Global:MetricsFailedSubs = @(); $Global:ConsumptionFailedSubs = @()
            $File = Write-RdaShareableDiagnosticsLog -DefaultPath ($Dir + '/') -ReportName 'P' -RunDateTime '1' -Version '3.2.3' -PhaseTimings ([ordered]@{}) *> $null
            $File = @(Get-ChildItem -LiteralPath $Dir -Filter 'Diagnostics_*.log')[0].FullName
            $Lines = @(Get-Content -LiteralPath $File)
            foreach ($Text in 'boom on vm-secret-01 status=403', '(message not kept: code=Contoso-Secret-Code)', '(message not kept: ops.admin@contoso-corp.com)', '(message not kept: )', '(message not kept:  status=403)', '(message not kept: page=1 records=2)', '(message not kept: status=403code=BadRequest)')
            {
                $Edited = @($Lines | ForEach-Object { if ($_ -like '  [[]sub*VMSS:*') { '  [sub <guid>] VMSS: ' + $Text } else { $_ } })
                $Back = ConvertFrom-RdaDiagnosticsText -Lines $Edited -ReportFolder 'f'
                $Back.CollectorFailures[0].Facts | Should -Be '' -Because $Text

            }
        }
        finally
        {
            Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
            $Global:CollectorFailures = @(); $Global:MetricsFailedSubs = @(); $Global:ConsumptionFailedSubs = @()
        }
    }

    It 'reads the diagnostics log case for case: a header, a section title or an entry marker in another case is refused' {
        $Dir = Join-Path ([IO.Path]::GetTempPath()) ('RdaDiagCase_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Dir | Out-Null
        try
        {
            $Global:CollectorFailures = @([pscustomobject]@{ Id = '11111111-2222-3333-4444-555555555555'; Module = 'VMSS'; Message = 'x' })
            $Global:MetricsFailedSubs = @(); $Global:ConsumptionFailedSubs = @()
            Write-RdaShareableDiagnosticsLog -DefaultPath ($Dir + '/') -ReportName 'P' -RunDateTime '1' -Version '3.2.3' -PhaseTimings ([ordered]@{}) *> $null
            $Lines = @(Get-Content -LiteralPath (@(Get-ChildItem -LiteralPath $Dir -Filter 'Diagnostics_*.log')[0].FullName))
            { ConvertFrom-RdaDiagnosticsText -Lines $Lines -ReportFolder 'f' } | Should -Not -Throw
            { ConvertFrom-RdaDiagnosticsText -Lines @($Lines[0].ToUpperInvariant()) + @($Lines[1..($Lines.Count - 1)]) -ReportFolder 'f' } | Should -Throw
            { ConvertFrom-RdaDiagnosticsText -Lines @($Lines | ForEach-Object { $_ -creplace '^Collector failures: ', 'collector failures: ' }) -ReportFolder 'f' } | Should -Throw
            { ConvertFrom-RdaDiagnosticsText -Lines @($Lines | ForEach-Object { $_ -creplace '^  \[sub ', '  [SUB ' }) -ReportFolder 'f' } | Should -Throw
            $Lines | Should -Contain '  (none recorded)'
            { ConvertFrom-RdaDiagnosticsText -Lines @($Lines | ForEach-Object { $_ -creplace '^  \(none recorded\)$', '  (None Recorded)' }) -ReportFolder 'f' } | Should -Throw
        }
        finally
        {
            Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
            $Global:CollectorFailures = @(); $Global:MetricsFailedSubs = @(); $Global:ConsumptionFailedSubs = @()
        }
    }

    It 'reads page and record counts from a consumption line only, not from the metrics sections' {
        $Dir = Join-Path ([IO.Path]::GetTempPath()) ('RdaDiagSec_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Dir | Out-Null
        try
        {
            $Sub = '11111111-2222-3333-4444-555555555555'
            $Global:CollectorFailures = @()
            $Global:MetricsFailedSubs = @([pscustomobject]@{ Id = '(unknown)'; Message = 'a' }, [pscustomobject]@{ Id = $Sub; Message = 'b'; Complete = $false })
            $Global:ConsumptionFailedSubs = @([pscustomobject]@{ Id = $Sub; Message = 'c'; PageAtFailure = 2; RecordsCollected = 9 })
            Write-RdaShareableDiagnosticsLog -DefaultPath ($Dir + '/') -ReportName 'P' -RunDateTime '1' -Version '3.2.3' -PhaseTimings ([ordered]@{}) *> $null
            $Lines = @(Get-Content -LiteralPath (@(Get-ChildItem -LiteralPath $Dir -Filter 'Diagnostics_*.log')[0].FullName))
            $Edited = @($Lines | ForEach-Object { if ($_ -like '  [[]sub*(message not kept)') { $_ -replace '\(message not kept\)', '(message not kept: page=1 records=2)' } else { $_ } })
            $Back = ConvertFrom-RdaDiagnosticsText -Lines $Edited -ReportFolder 'f'
            @($Back.MetricsFailedSubs | ForEach-Object { $_.Facts }) | Should -Be @('', '')
            $Back.ConsumptionFailedSubs[0].Facts | Should -Be 'page=2 records=9'
        }
        finally
        {
            Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
            $Global:CollectorFailures = @(); $Global:MetricsFailedSubs = @(); $Global:ConsumptionFailedSubs = @()
        }
    }

    It 'removes the output folder it made when its work folder cannot be made' {
        # A 240-character folder name is allowed (255 at most); its work folder's name, 18 characters longer, is not.
        $Parent = Join-Path ([IO.Path]::GetTempPath()) ('RdaLong_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $Parent | Out-Null
        try
        {
            $Out = Join-Path $Parent ('o' * 240)
            $Zip = Join-Path $Parent 'in.zip'
            [System.IO.File]::WriteAllBytes($Zip, [byte[]](80, 75, 5, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            # Skipped on a file system whose name limit is above 255 characters: there the long work folder can be made and nothing fails.
            $Probe = Join-Path $Parent (('o' * 240) + '.rda-work-00000000')
            $Allowed = $false
            try { New-Item -ItemType Directory -Path $Probe -ErrorAction Stop | Out-Null; Remove-Item -LiteralPath $Probe -Force; $Allowed = $true } catch { $Allowed = $false }
            if ($Allowed) { Set-ItResult -Skipped -Because 'this host allows the long work folder name'; return }
            $Run = Invoke-Protect -Path $Zip -Out $Out
            $Run.ExitCode | Should -Not -Be 0
            Test-Path -LiteralPath $Out | Should -BeFalse
            @(Get-ChildItem -LiteralPath $Parent -Force | Where-Object { $_.Name -ne 'in.zip' }).Count | Should -Be 0
        }
        finally { Remove-Item -LiteralPath $Parent -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Protect-RdaReport.ps1 on the synthetic estate' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Helpers/SyntheticReportZip.ps1')
        $script:PlainRun = New-RdaSyntheticReportZip -RepoRoot $script:RepoRoot -TestsRoot $PSScriptRoot -Plain
        $script:LiveRun = New-RdaSyntheticReportZip -RepoRoot $script:RepoRoot -TestsRoot $PSScriptRoot
        $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('RdaProtect_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Work | Out-Null
        $script:Out = Join-Path $script:Work 'masked'
        $script:Run = script:Invoke-Protect -Path $script:PlainRun.ZipPath -Out $script:Out
        $script:Folder = @(Get-ChildItem -LiteralPath $script:Out -Directory)[0]
        $script:MaskedZip = @(Get-ChildItem -LiteralPath $script:Folder.FullName -Filter 'ResourcesReport_*.zip')[0].FullName
        $script:MaskedDict = @(Get-ChildItem -LiteralPath $script:Folder.FullName -Filter 'ObfuscationDictionary_*.json')[0].FullName
    }
    AfterAll {
        Remove-RdaTestReportZip $script:PlainRun
        Remove-RdaTestReportZip $script:LiveRun
        if ($script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'exits 0 and writes the report zip with the plain report''s members, and its dictionary beside it' {
        $script:PlainRun.Exit | Should -Be 0
        $script:LiveRun.Exit | Should -Be 0
        $script:Run.ExitCode | Should -Be 0
        $script:Folder.Name | Should -Be ((Split-Path -Leaf $script:PlainRun.ZipPath) -replace '^ResourcesReport_(.+)\.zip$', 'ResourcesReport$1')
        @((script:Read-Zip $script:MaskedZip).Keys) | Should -Be @((script:Read-Zip $script:PlainRun.ZipPath).Keys)
        Test-Path -LiteralPath $script:MaskedDict | Should -BeTrue
    }

    It 'writes what the live -Obfuscate run of the same estate writes, value for value through each side''s own dictionary, token prefixes and hints included' {
        $Offline = script:Get-UnmaskedReport $script:MaskedZip $script:MaskedDict
        $Live = script:Get-UnmaskedReport $script:LiveRun.ZipPath $script:LiveRun.DictionaryPath
        # shortcut: the Front Door policy is named in the plain report only by its name, and the
        # policy is no inventory row, so offline writes 'obfuscated' (a run's value for an id it
        # does not know) where the live run writes the policy's token; nothing reads either.
        script:Compare-Unmasked $Live $Offline -SkipField 'Frontdoor.WebApplicationFirewall' | Should -BeNullOrEmpty
    }

    It 'masks every id, name, group, subscription and tag value, and leaves no real name of the estate in any file' {
        $Members = script:Read-Zip $script:MaskedZip
        $Inv = ConvertFrom-RdaJsonText -Text $Members[@($Members.Keys | Where-Object { $_ -like 'Inventory_*' })[0]]
        foreach ($S in @($Inv.Keys | Where-Object { $_ -ne 'Version' }))
        {
            foreach ($Row in @($Inv[$S]))
            {
                $Row.ID | Should -Match (Get-RdaObfuscatedIdPattern)
                foreach ($F in 'Name', 'ResourceGroup', 'Subscription') { $Row[$F] | Should -Match (Get-RdaTokenPattern) }
            }
        }
        $All = ($Members.Values -join "`n") + (Get-Content -LiteralPath (Join-Path $script:Folder.FullName ((Split-Path -Leaf $script:MaskedZip) -replace '\.zip$', '.html')) -Raw)
        foreach ($Real in 'rg-demo', 'rg-aks-demo', 'aks-demo', 'Demo Subscription', '12345678-1234-1234-1234-123456789012', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Microsoft.Compute/virtualMachines/')
        {
            $All.Contains($Real) | Should -BeFalse -Because "'$Real' is a real value of the plain report"
        }
    }

    It 'is mapped back by Reveal.ps1 to the plain values the live run maps back to' {
        $RevealOut = Join-Path $script:Work 'revealed.zip'
        & $script:Pwsh -NoProfile -NonInteractive -File (Join-Path $script:RepoRoot 'Reveal.ps1') -InputZip $script:MaskedZip -DictionaryPath $script:MaskedDict -All -OutputZip $RevealOut *> $null
        $LiveOut = Join-Path $script:Work 'live-revealed.zip'
        & $script:Pwsh -NoProfile -NonInteractive -File (Join-Path $script:RepoRoot 'Reveal.ps1') -InputZip $script:LiveRun.ZipPath -DictionaryPath $script:LiveRun.DictionaryPath -All -OutputZip $LiveOut *> $null
        $A = script:Get-UnmaskedReportFromPlain $RevealOut
        $B = script:Get-UnmaskedReportFromPlain $LiveOut
        script:Compare-Unmasked $B $A -SkipField 'Frontdoor.WebApplicationFirewall' | Should -BeNullOrEmpty
        $P = script:Get-UnmaskedReportFromPlain $script:PlainRun.ZipPath
        # The fields a rule masks hold a different form in the plain run (a name where the masked
        # run holds the masked id, a value a run writes 'obfuscated'); every other field comes back
        # as the plain run wrote it.
        $RuleFields = @(Get-RdaOfflineFieldRule | ForEach-Object { '{0}.{1}' -f $_.Section, $_.Field })
        script:Compare-Unmasked $P $A -SkipField $RuleFields | Should -BeNullOrEmpty
    }

    It 'masks the real parts of an App Service''s siteProperties in live and offline alike, keeps its shape, and Reveal gives it back' {
        $Site = {
            param([string]$Zip)
            $M = script:Read-Zip $Zip
            $Inv = ConvertFrom-RdaJsonText -Text $M[@($M.Keys | Where-Object { $_ -like 'Inventory_*' })[0]]
            @($Inv['AppServices'])[0]['SiteProperties']
        }
        $PlainSite = & $Site $script:PlainRun.ZipPath
        $PlainSite['properties'][0]['value'] | Should -Be 'DOCKER|contosoregdemo.azurecr.io/teamdemo-api/webdemo:1.2.3'
        foreach ($Zip in $script:LiveRun.ZipPath, $script:MaskedZip)
        {
            $Masked = & $Site $Zip
            $Value = $Masked['properties'][0]['value']
            $T = (Get-RdaTokenPattern).TrimStart('^').TrimEnd('$')
            $Value | Should -Match ('^DOCKER\|{0}\.azurecr\.io/{0}-{0}/{0}:1\.2\.3$' -f $T) -Because $Zip
            $Masked['properties'][0]['name'] | Should -Be 'LinuxFxVersion'
            $Masked['properties'][1]['value'] | Should -BeNullOrEmpty
            $Masked.ContainsKey('appSettings') | Should -BeTrue
            foreach ($Real in 'contosoregdemo', 'teamdemo', 'webdemo') { ((script:Read-Zip $Zip).Values -join "`n").Contains($Real) | Should -BeFalse -Because "'$Real' is a real part ($Zip)" }
        }
        # Offline and live: the same real part has the same token within each report, and each
        # side's dictionary gives the plain value back.
        foreach ($Pair in @(@($script:MaskedZip, $script:MaskedDict), @($script:LiveRun.ZipPath, $script:LiveRun.DictionaryPath)))
        {
            $Revealed = Join-Path $script:Work ([guid]::NewGuid().ToString('N') + '.zip')
            & $script:Pwsh -NoProfile -NonInteractive -File (Join-Path $script:RepoRoot 'Reveal.ps1') -InputZip $Pair[0] -DictionaryPath $Pair[1] -All -OutputZip $Revealed *> $null
            (& $Site $Revealed)['properties'][0]['value'] | Should -Be 'DOCKER|contosoregdemo.azurecr.io/teamdemo-api/webdemo:1.2.3' -Because $Pair[0]
        }
    }
}

Describe 'Protect-RdaReport.ps1 refuses what it cannot mask fully' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Helpers/SyntheticReportZip.ps1')
        $script:PlainRun = New-RdaSyntheticReportZip -RepoRoot $script:RepoRoot -TestsRoot $PSScriptRoot -Plain
        $script:LiveRun = New-RdaSyntheticReportZip -RepoRoot $script:RepoRoot -TestsRoot $PSScriptRoot
        $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('RdaProtectNo_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Work | Out-Null
        # A copy of the plain report with one member changed by $Change (its text in, its text out).
        $script:Planted = {
            param([string]$Like, [scriptblock]$Change, [string]$AddName)
            $Copy = Join-Path $script:Work ([guid]::NewGuid().ToString('N') + '.zip')
            Copy-Item -LiteralPath $script:PlainRun.ZipPath -Destination $Copy
            $Archive = [System.IO.Compression.ZipFile]::Open($Copy, 'Update')
            try
            {
                if ($AddName) { $E = $Archive.CreateEntry($AddName); $W = [IO.StreamWriter]::new($E.Open()); $W.Write('x'); $W.Dispose() }
                else
                {
                    $Entry = @($Archive.Entries | Where-Object { $_.Name -like $Like })[0]
                    $R = [IO.StreamReader]::new($Entry.Open()); $Text = $R.ReadToEnd(); $R.Dispose()
                    $Name = $Entry.FullName; $Entry.Delete()
                    $E = $Archive.CreateEntry($Name); $W = [IO.StreamWriter]::new($E.Open()); $W.Write((& $Change $Text)); $W.Dispose()
                }
            }
            finally { $Archive.Dispose() }
            return $Copy
        }
    }
    AfterAll {
        Remove-RdaTestReportZip $script:PlainRun
        Remove-RdaTestReportZip $script:LiveRun
        if ($script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses <Case>, exit 1, leaving no output folder' -ForEach @(
        @{ Case = 'a report that is already masked'; Kind = 'masked'; Says = 'already masked' }
        @{ Case = 'a cut-off inventory file'; Kind = 'cut-inventory'; Says = 'cannot be read whole' }
        @{ Case = 'a cut-off consumption row'; Kind = 'cut-consumption'; Says = 'cannot be read' }
        @{ Case = 'a real id planted in a field no rule masks'; Kind = 'planted'; Says = 'real name or id is still in' }
        @{ Case = 'an id no row holds planted in a field no rule masks'; Kind = 'planted-foreign'; Says = 'real name or id is still in' }
        @{ Case = 'an id no row holds planted in a metric record'; Kind = 'planted-foreign-metric'; Says = 'real name or id is still in' }
        @{ Case = 'an id no row holds, URL-encoded, in a field no rule masks'; Kind = 'planted-encoded'; Says = 'real name or id is still in' }
        @{ Case = 'an id no row holds, URL-encoded three times, with parentheses in its group'; Kind = 'planted-encoded3'; Says = 'real name or id is still in' }
        @{ Case = 'records whose subscription the report does not name'; Kind = 'no-sub-name'; Says = 'subscription the report does not name' }
        @{ Case = 'a file it does not know'; Kind = 'unknown'; Says = 'does not know how to mask' }
        @{ Case = 'a record field no collector writes'; Kind = 'field'; Says = 'a field the VirtualMachines collector does not write' }
        @{ Case = 'a damaged zip member'; Kind = 'crc'; Says = 'cut off or damaged' }
        @{ Case = 'a cut-off zip'; Kind = 'cut-zip'; Says = 'cut off or damaged' }
        @{ Case = 'a cut-off diagnostics log'; Kind = 'cut-diag'; Says = 'diagnostics log is cut off' }
        @{ Case = 'a consumption row cut after its first cells'; Kind = 'cut-row'; Says = 'is cut off' }
        @{ Case = 'a collector''s working field in a record'; Kind = 'ram'; Says = 'a field the VirtualMachines collector does not write' }
        @{ Case = 'a hidden file in the report zip'; Kind = 'hidden'; Says = 'does not know how to mask' }
        @{ Case = 'a report file in a subfolder of the report zip'; Kind = 'nested-member'; Says = 'does not know how to mask' }
        @{ Case = 'an empty section no collector writes'; Kind = 'null-section'; Says = 'a section no collector writes' }
        @{ Case = 'a metric record without one of its fields'; Kind = 'metric-key'; Says = 'is not the shape a run writes' }
        @{ Case = 'a metric record with MetricError as text'; Kind = 'metric-type'; Says = 'is not the shape a run writes' }
        @{ Case = 'a metric record with MetricSeries as text'; Kind = 'metric-series-text'; Says = 'is not the shape a run writes' }
        @{ Case = 'a metric record of a failed call with MetricSeries as text'; Kind = 'metric-series-text-failed'; Says = 'is not the shape a run writes' }
        @{ Case = 'a metric record of a failed call whose MetricSeries list holds a null'; Kind = 'metric-series-null-in-list'; Says = 'is not the shape a run writes' }
        @{ Case = 'a metric record with a null MetricSeries and MetricError false'; Kind = 'metric-series-null-no-error'; Says = 'is not the shape a run writes' }
        @{ Case = 'an InstanceData value without one of main''s 18 fields'; Kind = 'info-key'; Says = 'not the shape a run writes' }
        @{ Case = 'usage of a subscription the report does not name'; Kind = 'other-sub'; Says = 'subscription the report does not name' }
        @{ Case = 'a consumption header that writes MeterCategory with a quote in it written twice (the name is Meter"Category)'; Kind = 'head-quote'; Says = 'columns are not the ones a run writes' }
        @{ Case = 'a consumption header with text after the closing quote of a name'; Kind = 'head-after-quote'; Says = 'columns are not the ones a run writes' }
        @{ Case = 'a consumption header with a quote inside a plain name'; Kind = 'head-plain-quote'; Says = 'columns are not the ones a run writes' }
        @{ Case = 'a consumption header that names ResourceId twice'; Kind = 'head-twice'; Says = 'columns are not the ones a run writes' }
        @{ Case = 'a consumption header without MeterCategory'; Kind = 'head-missing'; Says = 'columns are not the ones a run writes' }
        @{ Case = 'a consumption header that holds two names in one quoted cell'; Kind = 'head-comma'; Says = 'columns are not the ones a run writes' }
    ) {
        $In = switch ($Kind)
        {
            'masked' { $script:LiveRun.ZipPath }
            'cut-inventory' { & $script:Planted 'Inventory_*.json' { param($T) $T.Substring(0, [int]($T.Length / 2)) } }
            'cut-consumption' { & $script:Planted 'Consumption_*.csv' { param($T) $Lines = $T -split "`n"; ($Lines[0..1] -join "`n") + "`n" + $Lines[2].Substring(0, 40) } }
            'planted' { & $script:Planted 'Inventory_*.json' { param($T) $T -replace '"OSDisk":"[^"]*"', '"OSDisk":"/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers/microsoft.compute/disks/vm-web-01-osdisk"' } }
            'planted-foreign' { & $script:Planted 'Inventory_*.json' { param($T) $T -replace '"OSDisk":"[^"]*"', '"OSDisk":"/subscriptions/0fa1c2d3-0000-4000-8000-00000000abcd/resourcegroups/rg-foreign-77/providers/microsoft.compute/disks/disk-foreign-77"' } }
            'planted-foreign-metric' { & $script:Planted 'Metrics_*.json' { param($T) $Mx = ConvertFrom-RdaJsonText -Text $T; $Mx['Metrics'][0]['Metric'] = 'see subscriptions/0fa1c2d3-0000-4000-8000-00000000abcd/resourcegroups/rg-foreign-78/providers/microsoft.compute/disks/disk-foreign-78?api-version=1'; ConvertTo-Json -InputObject ([pscustomobject]@{ Metrics = @($Mx['Metrics']) }) -Depth 10 -Compress } }
            'planted-encoded' { & $script:Planted 'Inventory_*.json' { param($T) $T -replace '"OSDisk":"[^"]*"', ('"OSDisk":"https://h/x?id=' + [uri]::EscapeDataString('/subscriptions/0fa1c2d3-0000-4000-8000-00000000abcd/resourcegroups/rg-foreign-79/providers/microsoft.compute/disks/disk-foreign-79') + '"') } }
            'planted-encoded3'
            {
                # Every character escaped, then encoded three times more, so no part (the GUID neither) is plain.
                & $script:Planted 'Inventory_*.json' { param($T) $E = -join ('/subscriptions/0fa1c2d3-0000-4000-8000-00000000abcd/resourcegroups/rg(80)/providers/microsoft.compute/disks/disk(80)'.ToCharArray() | ForEach-Object { '%{0:X2}' -f [int]$_ }); for ($k = 0; $k -lt 3; $k++) { $E = [uri]::EscapeDataString($E) }; $T -replace '"OSDisk":"[^"]*"', ('"OSDisk":"https://h/x?id=' + $E + '"') }
            }
            'no-sub-name'
            {
                # No record names its subscription, and the usage file holds no row to take it from the page.
                $First = & $script:Planted 'Inventory_*.json' { param($T) $T -replace '"Subscription":"[^"]*"', '"Subscription":""' }
                $Archive = [System.IO.Compression.ZipFile]::Open($First, 'Update')
                try
                {
                    foreach ($Like in 'Metrics_*.json', 'Consumption_*.csv')
                    {
                        $Entry = @($Archive.Entries | Where-Object { $_.Name -like $Like })[0]
                        $R = [IO.StreamReader]::new($Entry.Open()); $Text = $R.ReadToEnd(); $R.Dispose()
                        $Name = $Entry.FullName; $Entry.Delete()
                        $Text = if ($Like -like 'Metrics*') { $Text -replace '"Subscription":"[^"]*"', '"Subscription":""' } else { (@($Text -split "`r?`n")[0] -replace '"', '') + "`n" }
                        $E = $Archive.CreateEntry($Name); $W = [IO.StreamWriter]::new($E.Open()); $W.Write($Text); $W.Dispose()
                    }
                }
                finally { $Archive.Dispose() }
                $First
            }
            'unknown' { & $script:Planted '' {} 'notes.txt' }
            'hidden' { & $script:Planted '' {} '.notes' }
            'nested-member' { & $script:Planted '' {} 'sub/Inventory_ResourcesReport_20261113080000000abcd.json' }
            'field' { & $script:Planted 'Inventory_*.json' { param($T) $T -replace '"OSDisk":', '"OwnerAlias":"someone","OSDisk":' } }
            'cut-diag' { & $script:Planted 'Diagnostics_*.log' { param($T) ($T -split "`n")[0..8] -join "`n" } }
            'ram' { & $script:Planted 'Inventory_*.json' { param($T) $T -replace '"OSDisk":', '"RAM":"vm-web-01","OSDisk":' } }
            'null-section' { & $script:Planted 'Inventory_*.json' { param($T) $T -replace '^\{', '{"Notes":null,' } }
            'metric-key' { & $script:Planted 'Metrics_*.json' { param($T) $Mx = ConvertFrom-RdaJsonText -Text $T; $Mx['Metrics'][0].Remove('MetricTotalCount'); ConvertTo-Json -InputObject ([pscustomobject]@{ Metrics = @($Mx['Metrics']) }) -Depth 10 -Compress } }
            'metric-type' { & $script:Planted 'Metrics_*.json' { param($T) $Mx = ConvertFrom-RdaJsonText -Text $T; $Mx['Metrics'][0]['MetricError'] = 'false'; ConvertTo-Json -InputObject ([pscustomobject]@{ Metrics = @($Mx['Metrics']) }) -Depth 10 -Compress } }
            # Only a null series on a failed call is what a run writes; these stay refused.
            { $_ -like 'metric-series-*' }
            {
                $script:SeriesSet = @{ 'metric-series-text' = @($false, '1,2'); 'metric-series-text-failed' = @($true, '1,2'); 'metric-series-null-in-list' = @($true, @(1, $null)); 'metric-series-null-no-error' = @($false, $null) }[$Kind]
                & $script:Planted 'Metrics_*.json' { param($T) $Mx = ConvertFrom-RdaJsonText -Text $T; $Mx['Metrics'][0]['MetricError'] = $script:SeriesSet[0]; $Mx['Metrics'][0]['MetricSeries'] = $script:SeriesSet[1]; ConvertTo-Json -InputObject ([pscustomobject]@{ Metrics = @($Mx['Metrics']) }) -Depth 10 -Compress }
            }
            'info-key' { & $script:Planted 'Consumption_*.csv' { param($T) $T -replace '""AHB"":""[^"]*"",', '' } }
            'cut-row' { & $script:Planted 'Consumption_*.csv' { param($T) $L = @($T.TrimEnd() -split "`r?`n"); $L[-1] = $L[-1] -replace '(,[^,]*){3}$', ''; ($L -join "`n") + "`n" } }
            'other-sub' { & $script:Planted 'Consumption_*.csv' { param($T) $L = @($T.TrimEnd() -split "`r?`n"); $L[-1] = $L[-1] -replace '12345678-1234-1234-1234-123456789012', '99999999-9999-9999-9999-999999999999'; ($L -join "`n") + "`n" } }
            # The header only (its first line) is changed; each case checks that it was.
            { $_ -like 'head-*' }
            {
                $Swap = @{ 'head-quote' = @('"MeterCategory"', '"Meter""Category"'); 'head-after-quote' = @('"MeterName"', '"Meter"Name'); 'head-plain-quote' = @('"MeterId"', 'Meter"Id'); 'head-twice' = @('"Unit"', '"ResourceId"'); 'head-missing' = @('"MeterCategory",', ''); 'head-comma' = @('"MeterSubCategory","', '"MeterSubCategory,') }[$Kind]
                $script:HeadSwap = $Swap
                & $script:Planted 'Consumption_*.csv' { param($T) $L = $T -split "`n", 2; $New = $L[0].Replace($script:HeadSwap[0], $script:HeadSwap[1]); if ($New -ceq $L[0]) { throw 'the header was not changed' }; $New + "`n" + $L[1] }
            }
            { $_ -in 'crc', 'cut-zip' }
            {
                $Copy = Join-Path $script:Work ([guid]::NewGuid().ToString('N') + '.zip')
                $Bytes = [IO.File]::ReadAllBytes($script:PlainRun.ZipPath)
                if ($Kind -eq 'crc') { $At = [int]($Bytes.Length / 3); $Bytes[$At] = $Bytes[$At] -bxor 0xFF } else { $Bytes = $Bytes[0..([int]($Bytes.Length / 2))] }
                [IO.File]::WriteAllBytes($Copy, [byte[]]$Bytes)
                $Copy
            }
        }
        $Out = Join-Path $script:Work ('out-' + $Kind)
        $R = script:Invoke-Protect -Path $In -Out $Out
        $R.ExitCode | Should -Be 1
        ($R.Text -join "`n") | Should -Match ([regex]::Escape($Says))
        Test-Path -LiteralPath $Out | Should -BeFalse
        # An empty folder given as -OutputDirectory is left there, empty.
        $Given = Join-Path $script:Work ('given-' + $Kind)
        New-Item -ItemType Directory -Path $Given | Out-Null
        (script:Invoke-Protect -Path $In -Out $Given).ExitCode | Should -Be 1
        @(Get-ChildItem -LiteralPath $Given -Force).Count | Should -Be 0
        ($R.Text -join "`n") | Should -Not -Match 'rg-demo|vm-web-01|12345678-1234' -Because 'the message names no real value'
    }

    # A tenant-scope id ('/providers/<namespace>/<type>/<name>...': a management group, a
    # reservation) has no subscription: its name parts are real values all the same, and a
    # field or cell no one masks keeps them as written, so the report is refused.
    It 'refuses a tenant-scope id no row holds, <Case>, exit 1, leaving no output folder' -ForEach @(
        @{ Case = 'planted in a field no rule masks'; Kind = 'inventory'; Secret = 'mg-secret-77' }
        @{ Case = 'URL-encoded, in a field no rule masks'; Kind = 'inventory-encoded'; Secret = 'mg-secret-78' }
        @{ Case = 'without its first slash, in a URL in a field no rule masks'; Kind = 'inventory-url'; Secret = 'mg-secret-81' }
        @{ Case = 'of a reservation, planted in a metric record'; Kind = 'metric'; Secret = 'order-secret-79' }
        @{ Case = 'in a consumption cell no one masks'; Kind = 'usage'; Secret = 'mg-secret-80' }
        @{ Case = 'URL-encoded, in a consumption cell no one masks'; Kind = 'usage-encoded'; Secret = 'mg-secret-82' }
    ) {
        $Mg = "/providers/Microsoft.Management/managementGroups/$Secret"
        $script:TenantText = switch ($Kind)
        {
            'inventory' { $Mg }
            'inventory-encoded' { 'https://h/x?scope=' + [uri]::EscapeDataString($Mg) }
            'inventory-url' { "https://management.azure.com$($Mg)?api-version=2020-05-01" }
            'metric' { "see /providers/Microsoft.Capacity/reservationOrders/$Secret/reservations/res-secret-79 now" }
            'usage' { $Mg }
            'usage-encoded' { 'https://h/x?scope=' + [uri]::EscapeDataString($Mg) }
        }
        $In = if ($Kind -like 'inventory*') { & $script:Planted 'Inventory_*.json' { param($T) $New = $T -replace '"OSDisk":"[^"]*"', ('"OSDisk":"{0}"' -f $script:TenantText); if ($New -ceq $T) { throw 'no OSDisk was changed' }; $New } }
        elseif ($Kind -eq 'metric') { & $script:Planted 'Metrics_*.json' { param($T) $Mx = ConvertFrom-RdaJsonText -Text $T; $Mx['Metrics'][0]['Metric'] = $script:TenantText; ConvertTo-Json -InputObject ([pscustomobject]@{ Metrics = @($Mx['Metrics']) }) -Depth 10 -Compress } }
        else { & $script:Planted 'Consumption_*.csv' { param($T) $New = ([regex]'""ImageType"":""[^"]*""').Replace($T, ('""ImageType"":""{0}""' -f $script:TenantText), 1); if ($New -ceq $T) { throw 'no consumption cell was changed' }; $New } }
        $Out = Join-Path $script:Work ('out-tenant-' + $Kind)
        $R = script:Invoke-Protect -Path $In -Out $Out
        $R.ExitCode | Should -Be 1 -Because ($R.Text -join ' | ')
        ($R.Text -join "`n") | Should -Match ([regex]::Escape('real name or id is still in'))
        ($R.Text -join "`n") | Should -Not -Match $Secret -Because 'the message names no real value'
        Test-Path -LiteralPath $Out | Should -BeFalse
    }
}

Describe 'Protect-RdaReport.ps1 takes a consolidated zip, an unzipped one, and a report with no record' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Helpers/SyntheticReportZip.ps1')
        $script:PlainRun = New-RdaSyntheticReportZip -RepoRoot $script:RepoRoot -TestsRoot $PSScriptRoot -Plain
        $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('RdaProtectIn_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Work | Out-Null
        $Inner = Split-Path -Leaf $script:PlainRun.ZipPath
        $Stamp = $Inner -replace '^ResourcesReport_(.+)\.zip$', '$1'
        # A consolidated zip as the wrapper writes one: the report zip, its page under
        # HTML<stamp>/, a main summary and a plain run summary.
        $script:Bundle = Join-Path $script:Work 'bundle'
        New-Item -ItemType Directory -Path (Join-Path $script:Bundle "HTML$Stamp") -Force | Out-Null
        Copy-Item -LiteralPath $script:PlainRun.ZipPath -Destination $script:Bundle
        $Page = (script:Read-Zip $script:PlainRun.ZipPath)["ResourcesReport_$Stamp.html"]
        Set-Content -LiteralPath (Join-Path $script:Bundle "HTML$Stamp/ResourcesReport_$Stamp.html") -Value $Page
        # The main summary as the wrapper writes it, from a run folder of the report.
        $RunDir = Join-Path $script:Work 'run'
        New-Item -ItemType Directory -Path (Join-Path $RunDir "ResourcesReport$Stamp") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $RunDir "ResourcesReport$Stamp/ResourcesReport_$Stamp.html") -Value $Page
        (script:Read-Zip $script:PlainRun.ZipPath)["Inventory_ResourcesReport_$Stamp.json"] | Set-Content -LiteralPath (Join-Path $RunDir "ResourcesReport$Stamp/Inventory_ResourcesReport_$Stamp.json")
        New-RdaAllSubHtmlSummary -RunOutputDirectory $RunDir -HtmlFile (Join-Path $script:Bundle 'MainSummary.html') -ReportFolders @("ResourcesReport$Stamp") -MetricsFailedSubs @([pscustomobject]@{ Name = 'Demo Subscription'; Id = '12345678-1234-1234-1234-123456789012'; Message = 'auth'; ReportFolder = "ResourcesReport$Stamp" }) *> $null
        (Get-Content -LiteralPath (Join-Path $script:Bundle 'MainSummary.html') -Raw) -replace 'href="ResourcesReport', 'href="HTML' | Set-Content -LiteralPath (Join-Path $script:Bundle 'MainSummary.html') -NoNewline
        $Lines = Get-RunSummaryLogContent -InvocationParameters ([ordered]@{ ParallelStreams = 2 }) -Version '3.2.3' -StartTime ([datetime]'2026-11-13 08:00:00') -EndTime ([datetime]'2026-11-13 09:00:00') -Visible 1 -Eligible 1 -Processed 1 -CoverageLines @('1 subscription(s) in this run (1 visible to the tenant), 1 report(s) in this zip.') -ConsumptionRecordCount 7 -MetricsFailedSubs @([pscustomobject]@{ Name = 'Demo Subscription'; Id = '12345678-1234-1234-1234-123456789012'; Message = 'auth' })
        $Lines | Set-Content -LiteralPath (Join-Path $script:Bundle 'RunSummary.log')
        # Named the way someone could rename it, with a real word in the name.
        $script:Outer = Join-Path $script:Work 'DemoSubscription-report.zip'
        Compress-Archive -Path (Join-Path $script:Bundle '*') -DestinationPath $script:Outer
    }
    AfterAll {
        Remove-RdaTestReportZip $script:PlainRun
        if ($script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'masks a consolidated zip into the wrapper''s layout, under a name a run gives, with an obfuscated run summary' {
        $Out = Join-Path $script:Work 'out-bundle'
        $R = script:Invoke-Protect -Path $script:Outer -Out $Out
        $R.ExitCode | Should -Be 0
        $Zips = @(Get-ChildItem -LiteralPath $Out -Filter '*.zip' -File)
        $Zips.Count | Should -Be 1
        $Zips[0].Name | Should -Match '^AllSubscriptions_ResourcesReport_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.zip$' -Because 'a name someone gave the zip can hold real text'
        $Members = script:Read-Zip $Zips[0].FullName
        @($Members.Keys | Sort-Object) | Should -Be @(@((Split-Path -Leaf $script:PlainRun.ZipPath), 'MainSummary.html', 'RunSummary.log', ('HTML{0}/{1}' -f ((Split-Path -Leaf $script:PlainRun.ZipPath) -replace '^ResourcesReport_(.+)\.zip$', '$1'), ((Split-Path -Leaf $script:PlainRun.ZipPath) -replace '\.zip$', '.html'))) | Sort-Object)
        $Members['RunSummary.log'] | Should -Match 'Obfuscated run: subscription names/ids and raw error text are omitted'
        $Members['RunSummary.log'] | Should -Match '  -Obfuscate'
        $Members['MainSummary.html'] | Should -Match 'Metrics auth-skipped: 1 subscription'
        ($Members.Values -join "`n") | Should -Not -Match 'Demo Subscription|rg-demo'
    }

    It 'leaves nothing in -OutputDirectory when it is killed part-way' {
        $Out = Join-Path $script:Work 'out-killed'
        $Info = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        foreach ($A in '-NoProfile', '-NonInteractive', '-File', (Join-Path $script:RepoRoot 'Protect-RdaReport.ps1'), '-Path', $script:Outer, '-OutputDirectory', $Out) { $Info.ArgumentList.Add($A) }
        $Info.RedirectStandardOutput = $true
        $Proc = [System.Diagnostics.Process]::Start($Info)
        try
        {
            # Killed once the report is masked, before the last check and the move.
            while ($null -ne ($Line = $Proc.StandardOutput.ReadLine())) { if ($Line -like 'Masked ResourcesReport_*') { $Proc.Kill($true); break } }
            $Proc.WaitForExit()
        }
        finally { if (-not $Proc.HasExited) { $Proc.Kill($true) } }
        @(Get-ChildItem -LiteralPath $Out -Recurse -File -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
        Get-ChildItem -LiteralPath $script:Work -Directory -Filter 'out-killed.rda-work-*' | Remove-Item -Recurse -Force
    }

    It 'refuses a file system root as -OutputDirectory (exit 2)' {
        $Root = [IO.Path]::GetPathRoot($script:Work)
        $R = script:Invoke-Protect -Path $script:Outer -Out $Root
        $R.ExitCode | Should -Be 2
        ($R.Text -join "`n") | Should -Match 'root'
    }

    It 'writes the consolidated zip with the streaming writer (folder entries first) and counts a failed collector its page names, with no diagnostics log' {
        $Copy = Join-Path $script:Work 'no-diag'
        Copy-Item -LiteralPath $script:Bundle -Destination $Copy -Recurse
        $InnerZip = @(Get-ChildItem -LiteralPath $Copy -Filter 'ResourcesReport_*.zip')[0].FullName
        $Archive = [System.IO.Compression.ZipFile]::Open($InnerZip, 'Update')
        try
        {
            @($Archive.Entries | Where-Object { $_.Name -like 'Diagnostics_*' }) | ForEach-Object { $_.Delete() }
            $Page = @($Archive.Entries | Where-Object { $_.Name -like '*.html' })[0]
            $R = [IO.StreamReader]::new($Page.Open()); $T = $R.ReadToEnd(); $R.Dispose()
            $Name = $Page.FullName; $Page.Delete()
            $E = $Archive.CreateEntry($Name); $W = [IO.StreamWriter]::new($E.Open()); $W.Write(($T -replace '<body>', '<body><div class="coverage-banner"><span class="coverage-icon">&#9888;</span><div><b>Incomplete collection:</b> 1 resource type(s) could not be collected and are MISSING from this report - not empty because there are none, but because the collector errored: <code>VMSS</code>. See the Diagnostics log in this bundle for the underlying error, then re-run.</div></div>')); $W.Dispose()
        }
        finally { $Archive.Dispose() }
        $Out = Join-Path $script:Work 'out-no-diag'
        $Run = script:Invoke-Protect -Path $Copy -Out $Out
        $Run.ExitCode | Should -Be 0 -Because ($Run.Text -join ' | ')
        $Zip = @(Get-ChildItem -LiteralPath $Out -Filter 'AllSubscriptions_*.zip')[0].FullName
        $Read = [System.IO.Compression.ZipFile]::OpenRead($Zip)
        try { $Read.Entries[0].FullName | Should -BeLike 'HTML*/*' } finally { $Read.Dispose() }
        (script:Read-Zip $Zip)['MainSummary.html'] | Should -Match '1 collector failure'
    }

    It 'refuses an output folder that links into the report folder it masks (exit 2)' {
        $Link = Join-Path $script:Work 'out-link'
        New-Item -ItemType Directory -Path (Join-Path $script:Bundle 'inside') | Out-Null
        try
        {
            # A junction on Windows (no admin right needed), a symbolic link elsewhere.
            New-Item -ItemType $(if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }) -Path $Link -Target (Join-Path $script:Bundle 'inside') | Out-Null
            $R = script:Invoke-Protect -Path $script:Bundle -Out $Link
            $R.ExitCode | Should -Be 2
            ($R.Text -join "`n") | Should -Match 'inside -Path'
            @(Get-ChildItem -LiteralPath (Join-Path $script:Bundle 'inside') -Force).Count | Should -Be 0
            # A link to itself, past the hop limit: refused as a bad argument.
            $Loop = Join-Path $script:Work 'loop'
            if (-not $IsWindows)
            {
                New-Item -ItemType SymbolicLink -Path $Loop -Target $Loop | Out-Null
                $R = script:Invoke-Protect -Path $script:Bundle -Out (Join-Path $Loop 'out')
                $R.ExitCode | Should -Be 2
                ($R.Text -join "`n") | Should -Match 'too many links'
                Remove-Item -LiteralPath $Loop -Force
            }
        }
        finally
        {
            Remove-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $script:Bundle 'inside') -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'refuses an output folder inside the report folder it masks (exit 2)' {
        $R = script:Invoke-Protect -Path $script:Bundle -Out (Join-Path $script:Bundle 'masked')
        $R.ExitCode | Should -Be 2
        ($R.Text -join "`n") | Should -Match 'inside -Path'
        Test-Path -LiteralPath (Join-Path $script:Bundle 'masked') | Should -BeFalse
    }

    It 'masks an unzipped consolidated zip the same way' {
        $Out = Join-Path $script:Work 'out-folder'
        $R = script:Invoke-Protect -Path $script:Bundle -Out $Out
        $R.ExitCode | Should -Be 0
        @(Get-ChildItem -LiteralPath $Out -Filter 'AllSubscriptions_ResourcesReport_*.zip' -File).Count | Should -Be 1
    }

    It 'refuses a bundle file or report zip named in another case, and renames a consolidated zip named so' {
        foreach ($Pair in @(@('RunSummary.log', 'runsummary.log'), @('MainSummary.html', 'mainsummary.html')))
        {
            $Copy = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
            Copy-Item -LiteralPath $script:Bundle -Destination $Copy -Recurse
            Rename-Item -LiteralPath (Join-Path $Copy $Pair[0]) -NewName $Pair[1]
            $Out = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
            $R = script:Invoke-Protect -Path $Copy -Out $Out
            $R.ExitCode | Should -Be 1 -Because $Pair[1]
            ($R.Text -join "`n") | Should -Match 'does not know how to mask'
        }
        $Copy = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $script:Bundle -Destination $Copy -Recurse
        $Inner = @(Get-ChildItem -LiteralPath $Copy -Filter 'ResourcesReport_*.zip')[0]
        Rename-Item -LiteralPath $Inner.FullName -NewName ('r' + $Inner.Name.Substring(1))
        $R = script:Invoke-Protect -Path $Copy -Out (Join-Path $script:Work ([guid]::NewGuid().ToString('N')))
        $R.ExitCode | Should -Be 1 -Because 'a report zip named resourcesreport_'
        # A consolidated zip named in another case is renamed as a run names one.
        $Lower = Join-Path $script:Work 'allsubscriptions_resourcesreport_2026-11-13_08-00-00.zip'
        Copy-Item -LiteralPath $script:Outer -Destination $Lower
        $Out = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
        (script:Invoke-Protect -Path $Lower -Out $Out).ExitCode | Should -Be 0
        @(Get-ChildItem -LiteralPath $Out -File | ForEach-Object { $_.Name }) | Should -Not -Contain 'allsubscriptions_resourcesreport_2026-11-13_08-00-00.zip'
        @(Get-ChildItem -LiteralPath $Out -File | Where-Object { $_.Name -cmatch '^AllSubscriptions_ResourcesReport_' }).Count | Should -Be 1
    }

    It 'keeps the collecting host''s environment on the main summary, and refuses one holding a GUID' {
        foreach ($Os in 'Darwin 23.1.0 Darwin Kernel Version 23.1.0: Mon Oct  9 21:27:24 PDT 2023; root:xnu-10002.41.9~6/RELEASE_ARM64_T6000', 'Linux 6.5.0-1025-azure #26~22.04.1-Ubuntu SMP Thu Jul 11 22:33:04 UTC 2024')
        {
            $Copy = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
            Copy-Item -LiteralPath $script:Bundle -Destination $Copy -Recurse
            $Main = Join-Path $Copy 'MainSummary.html'
            (Get-Content -LiteralPath $Main -Raw) -replace '<body>', ('<body><div><b>Environment:</b> {0}</div>' -f [System.Net.WebUtility]::HtmlEncode($Os)) | Set-Content -LiteralPath $Main -NoNewline
            $Out = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
            $R = script:Invoke-Protect -Path $Copy -Out $Out
            $R.ExitCode | Should -Be 0 -Because ($R.Text -join ' | ')
            (script:Read-Zip @(Get-ChildItem -LiteralPath $Out -Filter 'AllSubscriptions_*.zip')[0].FullName)['MainSummary.html'] | Should -Match ([regex]::Escape(('<b>Environment:</b> {0}' -f [System.Net.WebUtility]::HtmlEncode($Os))))
        }
        $Copy = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $script:Bundle -Destination $Copy -Recurse
        $Main = Join-Path $Copy 'MainSummary.html'
        (Get-Content -LiteralPath $Main -Raw) -replace '<body>', '<body><div><b>Environment:</b> Linux 12345678-1234-1234-1234-123456789012</div>' | Set-Content -LiteralPath $Main -NoNewline
        $R = script:Invoke-Protect -Path $Copy -Out (Join-Path $script:Work ([guid]::NewGuid().ToString('N')))
        $R.ExitCode | Should -Be 1
        ($R.Text -join "`n") | Should -Match 'not an OS name'
        # Two lines are not one OS string.
        $Copy = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $script:Bundle -Destination $Copy -Recurse
        $Main = Join-Path $Copy 'MainSummary.html'
        (Get-Content -LiteralPath $Main -Raw) -replace '<body>', ('<body><div><b>Environment:</b> Linux 6' + "`n" + '</div>') | Set-Content -LiteralPath $Main -NoNewline
        $R = script:Invoke-Protect -Path $Copy -Out (Join-Path $script:Work ([guid]::NewGuid().ToString('N')))
        $R.ExitCode | Should -Be 1
        ($R.Text -join "`n") | Should -Match 'not an OS name'
    }

    It 'refuses a page in the consolidated zip that is not a report''s own page' {
        $Extra = Join-Path $script:Work 'extra-page'
        Copy-Item -LiteralPath $script:Bundle -Destination $Extra -Recurse
        $Html = @(Get-ChildItem -LiteralPath $Extra -Recurse -Filter 'ResourcesReport_*.html')[0]
        New-Item -ItemType Directory -Path (Join-Path $Extra 'HTMLother') | Out-Null
        Copy-Item -LiteralPath $Html.FullName -Destination (Join-Path $Extra 'HTMLother/notes.html')
        $Out = Join-Path $script:Work 'out-extra-page'
        $R = script:Invoke-Protect -Path $Extra -Out $Out
        $R.ExitCode | Should -Be 1
        ($R.Text -join "`n") | Should -Match 'does not know how to mask'
        Test-Path -LiteralPath $Out | Should -BeFalse
    }

    It 'refuses a cut-off run summary' {
        $Cut = Join-Path $script:Work 'cut-bundle'
        Copy-Item -LiteralPath $script:Bundle -Destination $Cut -Recurse
        (Get-Content -LiteralPath (Join-Path $Cut 'RunSummary.log'))[0..12] | Set-Content -LiteralPath (Join-Path $Cut 'RunSummary.log')
        $Out = Join-Path $script:Work 'out-cut'
        $R = script:Invoke-Protect -Path $Cut -Out $Out
        $R.ExitCode | Should -Be 1
        ($R.Text -join "`n") | Should -Match 'RunSummary.log is cut off'
        Test-Path -LiteralPath $Out | Should -BeFalse
    }

    It 'takes the subscription of a report with no record from its page, so its token gets the prefix the run gives it' {
        # A subscription with only resources no collector reports: no inventory or metric record, usage rows only.
        $Dir = Join-Path $script:Work 'empty'
        New-Item -ItemType Directory -Path $Dir | Out-Null
        $Stamp = '20261113080000000abcd'
        $Sub = '22222222-2222-2222-2222-222222222222'
        '{"VirtualMachines":[],"Version":"3.2.3"}' | Set-Content -LiteralPath (Join-Path $Dir "Inventory_ResourcesReport_$Stamp.json") -NoNewline
        '{"Metrics":[]}' | Set-Content -LiteralPath (Join-Path $Dir "Metrics_ResourcesReport_$Stamp.json") -NoNewline
        '<html><body><b>Subscription:</b> Team Dev Sandbox<br><div><b>Setup and resource discovery:</b> 4 Seconds</div><script></script></body></html>' | Set-Content -LiteralPath (Join-Path $Dir "ResourcesReport_$Stamp.html")
        $Uri = "/subscriptions/$Sub/resourcegroups/rg-net-01/providers/microsoft.network/virtualnetworks/vnet-hub-01"
        $Instance = [pscustomobject]@{ 'Microsoft.Resources' = [pscustomobject]@{ ResourceUri = $Uri; Location = 'eastus'; additionalInfo = [pscustomobject][ordered]@{ ConsumptionMeter = ''; ImageType = ''; AHB = ''; vCores = 0; VCPUs = 0; ServiceType = ''; ResourceCategory = ''; Edition = ''; LicenseType = ''; HostLicenseType = ''; OS = ''; IsVM = ''; NumberOfCores = 0; NumberOfLogicalProcessors = 0; SLO = ''; ServerSku = ''; ServerEdition = ''; IsHAEnabled = '' } } } | ConvertTo-Json -Compress -Depth 5
        [pscustomobject][ordered]@{ InstanceData = $Instance; MeterCategory = 'Virtual Network'; MeterId = '33333333-3333-3333-3333-333333333333'; MeterName = 'Peering'; MeterRegion = 'US East'; MeterSubCategory = ''; Quantity = '1'; Unit = '1 GB'; UsageStartTime = '11/1/2026 12:00:00 AM'; UsageEndTime = '11/2/2026 12:00:00 AM'; ResourceId = $Uri; ResourceLocation = 'eastus'; ConsumptionMeter = ''; ReservationId = ''; ReservationOrderId = '' } | Export-Csv -LiteralPath (Join-Path $Dir "Consumption_ResourcesReport_$Stamp.csv") -NoTypeInformation -Encoding utf8
        $Zip = Join-Path $script:Work "ResourcesReport_$Stamp.zip"
        Compress-Archive -Path (Join-Path $Dir '*') -DestinationPath $Zip
        $Out = Join-Path $script:Work 'out-empty'
        $R = script:Invoke-Protect -Path $Zip -Out $Out
        $R.ExitCode | Should -Be 0
        $Dict = Read-RdaJsonFile -Path @(Get-ChildItem -LiteralPath $Out -Recurse -Filter 'ObfuscationDictionary_*.json')[0].FullName
        @($Dict.SubscriptionNameMap.Keys).Count | Should -Be 1
        $Token = @($Dict.SubscriptionNameMap.Keys)[0]
        $Dict.SubscriptionNameMap[$Token] | Should -Be 'Team Dev Sandbox'
        $Token | Should -Match '^nonprod_' -Because 'the run takes the prefix from the subscription''s name, which holds dev'
        $Csv = @(Import-Csv -LiteralPath @(Get-ChildItem -LiteralPath $Out -Recurse -Filter 'Consumption_*.csv')[0].FullName)
        $Csv[0].ResourceId | Should -Match ('^/subscriptions/{0}/' -f [regex]::Escape($Token))
    }
}

Describe 'Protect-RdaReport.ps1 masks what a plain report holds only in part as a run does' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Helpers/SyntheticReportZip.ps1')
        $script:PlainRun = New-RdaSyntheticReportZip -RepoRoot $script:RepoRoot -TestsRoot $PSScriptRoot -Plain
        $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('RdaProtectPart_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Work | Out-Null
        # A copy of the plain report with members changed: name pattern -> change of its text.
        $script:Change = {
            param([hashtable]$Changes)
            $Copy = Join-Path $script:Work ([guid]::NewGuid().ToString('N') + '.zip')
            Copy-Item -LiteralPath $script:PlainRun.ZipPath -Destination $Copy
            $Archive = [System.IO.Compression.ZipFile]::Open($Copy, 'Update')
            try
            {
                foreach ($Like in $Changes.Keys)
                {
                    $Entry = @($Archive.Entries | Where-Object { $_.Name -like $Like })[0]
                    $R = [IO.StreamReader]::new($Entry.Open()); $Text = $R.ReadToEnd(); $R.Dispose()
                    $Name = $Entry.FullName; $Entry.Delete()
                    $E = $Archive.CreateEntry($Name); $W = [IO.StreamWriter]::new($E.Open()); $W.Write((& $Changes[$Like] $Text)); $W.Dispose()
                }
            }
            finally { $Archive.Dispose() }
            $Copy
        }
        $script:Masked = {
            param([string]$Zip)
            $Out = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
            $R = script:Invoke-Protect -Path $Zip -Out $Out
            $R.ExitCode | Should -Be 0 -Because ($R.Text -join ' | ')
            $Folder = @(Get-ChildItem -LiteralPath $Out -Directory)[0].FullName
            [pscustomobject]@{
                Members = script:Read-Zip @(Get-ChildItem -LiteralPath $Folder -Filter 'ResourcesReport_*.zip')[0].FullName
                Dict    = Read-RdaJsonFile -Path @(Get-ChildItem -LiteralPath $Folder -Filter 'ObfuscationDictionary_*.json')[0].FullName
            }
        }
        # Each masked metric record against the plain one, in order: the id maps back with
        # the dictionary, the name, group and subscription are the masked id's own segments,
        # and every other field is the plain one, value for value (JSON text with sorted keys).
        $script:AssertMaskedMetric = {
            param([string]$PlainZip, $M)
            $PlainMembers = script:Read-Zip $PlainZip
            $In = @((ConvertFrom-RdaJsonText -Text $PlainMembers[@($PlainMembers.Keys | Where-Object { $_ -like 'Metrics_*' })[0]])['Metrics'])
            $Out = @((ConvertFrom-RdaJsonText -Text $M.Members[@($M.Members.Keys | Where-Object { $_ -like 'Metrics_*' })[0]])['Metrics'])
            $Out.Count | Should -Be $In.Count
            for ($i = 0; $i -lt $In.Count; $i++)
            {
                $P = $In[$i]; $O = $Out[$i]
                $M.Dict.ResourceIdMap[$O['ID']] | Should -BeExactly $P['ID'] -Because "record $i's masked id maps back to its plain id"
                $Parts = $O['ID'].Split('/')
                $O['Name'] | Should -BeExactly $Parts[-1]
                $O['ResourceGroup'] | Should -BeExactly $Parts[4]
                $O['Subscription'] | Should -BeExactly $Parts[2]
                $Keep = $P.Clone(); $Back = $O.Clone()
                foreach ($K in 'ID', 'Name', 'ResourceGroup', 'Subscription') { $Keep.Remove($K); $Back.Remove($K) }
                (script:ConvertTo-SortedJson $Back) | Should -BeExactly (script:ConvertTo-SortedJson $Keep) -Because "record $i keeps every other field as written"
            }
            return , $Out
        }
    }
    AfterAll {
        Remove-RdaTestReportZip $script:PlainRun
        if ($script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'gives a metric record of a resource no inventory row holds the group token of its own id' {
        $Extra = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-extra-01/providers/microsoft.storage/storageaccounts/stextra01'
        $Zip = & $script:Change @{ 'Metrics_*.json' = { param($T) $T -replace '^\{"Metrics":\[', ('{{"Metrics":[{{"ID":"{0}","Subscription":"Demo Subscription","ResourceGroup":"rg-extra-01","Name":"stextra01","Location":"eastus","Service":"Storage","Metric":"UsedCapacity","MetricAggregate":"Average","MetricTimeGrain":"01:00:00","MetricMeasure":"Average","MetricPercentile":0,"MetricValue":0,"MetricCount":0,"MetricTotalCount":0,"MetricSeries":0,"MetricError":false}},' -f $Extra) } }
        $M = & $script:Masked $Zip
        $Records = (ConvertFrom-RdaJsonText -Text $M.Members[@($M.Members.Keys | Where-Object { $_ -like 'Metrics_*' })[0]])['Metrics']
        $Rec = @($Records | Where-Object { $M.Dict.ResourceIdMap[$_['ID']] -eq $Extra })
        $Rec.Count | Should -Be 1
        $Rec[0]['ResourceGroup'] | Should -Be ($Rec[0]['ID'].Split('/')[4]) -Because 'the record joins by name, group and subscription when ids do not match'
        $M.Dict.ResourceGroupMap[$Rec[0]['ResourceGroup']] | Should -Match '/resourcegroups/rg-extra-01(/|$)'
        $Rec[0]['Name'] | Should -Be ($Rec[0]['ID'].Split('/')[-1])
    }

    # A run writes a null MetricSeries on a call that failed (Extension/Metrics.ps1,
    # MetricError true). The offline mask passes it through as written, null kept.
    It 'passes a metric record of a failed call (MetricError true, MetricSeries null) through as a run writes it, with only its id and names masked' {
        $Zip = & $script:Change @{ 'Metrics_*.json' = {
                param($T)
                $Mx = ConvertFrom-RdaJsonText -Text $T
                if (@($Mx['Metrics']).Count -lt 2) { throw 'the plain metrics file has fewer than two records' }
                # As Add-MetricRecord's catch writes a failed call.
                $R = $Mx['Metrics'][0]
                $R['MetricError'] = $true; $R['MetricSeries'] = $null
                foreach ($K in 'MetricPercentile', 'MetricValue', 'MetricCount', 'MetricTotalCount') { $R[$K] = 0 }
                ConvertTo-Json -InputObject ([pscustomobject]@{ Metrics = @($Mx['Metrics']) }) -Depth 10 -Compress
            }
        }
        $M = & $script:Masked $Zip
        $M.Members[@($M.Members.Keys | Where-Object { $_ -like 'Metrics_*' })[0]] | Should -Match '"MetricSeries":null' -Because 'the null is kept as written'
        $Out = & $script:AssertMaskedMetric $Zip $M
        $Out[0].ContainsKey('MetricSeries') | Should -BeTrue
        $null -eq $Out[0]['MetricSeries'] | Should -BeTrue
        $Out[0]['MetricError'] | Should -BeTrue
    }

    It 'masks the metric records of a report whose records are all good as before: only ids and names change' {
        $M = & $script:Masked $script:PlainRun.ZipPath
        $Out = & $script:AssertMaskedMetric $script:PlainRun.ZipPath $M
        @($Out | Where-Object { $null -eq $_['MetricSeries'] }).Count | Should -Be 0 -Because 'no good record has a null series'
    }

    It 'masks a Service Bus namespace named $system and its topic in the inventory, metrics and consumption, with no $system left in any of them' {
        $Sys = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers/microsoft.servicebus/namespaces/$system'
        $SbRow = '{"ID":"' + $Sys + '","Subscription":"Demo Subscription","ResourceGroup":"rg-demo","Name":"$system","Location":"eastus","SKU":"Standard","Status":"Active","GeoRep":false,"ThroughputUnits":null,"CreatedTime":"2024-03-15 09:41"}'
        $SbMetric = '{"ID":"' + $Sys + '","Subscription":"Demo Subscription","ResourceGroup":"rg-demo","Name":"$system","Location":"eastus","Service":"Service Bus","Metric":"IncomingMessages","MetricAggregate":"Total","MetricTimeGrain":"01:00:00","MetricMeasure":"Total","MetricPercentile":0,"MetricValue":0,"MetricCount":0,"MetricTotalCount":0,"MetricSeries":0,"MetricError":false}'
        $Zip = & $script:Change @{
            'Inventory_*.json' = {
                param($T)
                foreach ($Empty in '"ServiceBUS":[]', '"ServiceBUS":null') { if ($T.Contains($Empty)) { return $T.Replace($Empty, '"ServiceBUS":[' + $SbRow + ']') } }
                throw 'the plain inventory has no empty ServiceBUS section to add the namespace to'
            }
            'Metrics_*.json'   = {
                param($T)
                if (-not $T.StartsWith('{"Metrics":[')) { throw 'the plain metrics file does not start as a run writes it' }
                $Rest = $T.Substring('{"Metrics":['.Length)
                '{"Metrics":[' + $SbMetric + $(if ($Rest.StartsWith(']')) { '' } else { ',' }) + $Rest
            }
            'Consumption_*.csv' = {
                param($T)
                $Lines = [System.Collections.Generic.List[string]]($T -split "`n")
                $Vm = @($Lines | Where-Object { $_.Contains('/microsoft.compute/virtualmachines/vm-demo"') })[0]
                if ($null -eq $Vm) { throw 'the plain consumption file has no vm-demo row to copy' }
                $Row = $Vm.Replace('microsoft.compute/virtualmachines/vm-demo', 'microsoft.servicebus/namespaces/$system').Replace('"Virtual Machines"', '"Service Bus"')
                $Lines.Insert(1, $Row)
                $Lines.Insert(2, $Row.Replace('namespaces/$system', 'namespaces/$system/topics/topic-demo'))
                $Lines -join "`n"
            }
        }
        $M = & $script:Masked $Zip
        foreach ($Member in @($M.Members.Keys | Where-Object { $_ -like 'Inventory_*' -or $_ -like 'Metrics_*' -or $_ -like 'Consumption_*' }))
        {
            $M.Members[$Member].IndexOf('$system', [System.StringComparison]::OrdinalIgnoreCase) | Should -Be -1 -Because "the masked $Member leaves no name part as written"
        }
        $MaskedSb = @($M.Dict.ResourceIdMap.Keys | Where-Object { $M.Dict.ResourceIdMap[$_] -eq $Sys })
        $MaskedSb.Count | Should -Be 1 -Because 'one masked id for the namespace, which Reveal maps back'
        $Inv = ConvertFrom-RdaJsonText -Text $M.Members[@($M.Members.Keys | Where-Object { $_ -like 'Inventory_*' })[0]]
        @($Inv['ServiceBUS'])[0]['ID'] | Should -BeExactly $MaskedSb[0] -Because 'the inventory id is the dictionary key'
        $Records = (ConvertFrom-RdaJsonText -Text $M.Members[@($M.Members.Keys | Where-Object { $_ -like 'Metrics_*' })[0]])['Metrics']
        @($Records | Where-Object { $_['ID'] -ceq $MaskedSb[0] }).Count | Should -Be 1 -Because 'the metric record joins the inventory row by id'
        $Usage = @($M.Members[@($M.Members.Keys | Where-Object { $_ -like 'Consumption_*' })[0]] | ConvertFrom-Csv)
        @($Usage | Where-Object { $_.ResourceId -ceq $MaskedSb[0] }).Count | Should -Be 1 -Because 'the consumption row joins the inventory row by id'
        @($Usage | Where-Object { $_.ResourceId.StartsWith($MaskedSb[0] + '/topics/') }).Count | Should -Be 1 -Because 'the topic holds its namespace''s masked path'
    }

    # A usage row of '.../namespaces/<namespace>/$system' (an id that ends on '$system' with
    # no name after it) is an id form this tool does not support: no captured billing row
    # shows it, and downstream would read '$system' as the name. The mask stops on it with
    # that reason, which masking again would not change, and writes nothing.
    It 'refuses a usage row whose id ends on the word $system with no name after it, as an id form this tool does not support, and writes nothing' {
        $Plain = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers/microsoft.servicebus/namespaces/sbdemo01/$system'
        $AddRow = {
            param([string]$T)
            $Lines = [System.Collections.Generic.List[string]]($T -split "`n")
            $Vm = @($Lines | Where-Object { $_.Contains('/microsoft.compute/virtualmachines/vm-demo"') })[0]
            if ($null -eq $Vm) { throw 'the plain consumption file has no vm-demo row to copy' }
            $Lines.Insert(1, $Vm.Replace('/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers/microsoft.compute/virtualmachines/vm-demo', $Plain).Replace('"Virtual Machines"', '"Service Bus"'))
            $Lines -join "`n"
        }.GetNewClosure()
        $Zip = & $script:Change @{ 'Consumption_*.csv' = $AddRow }
        $Out = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
        $R = script:Invoke-Protect -Path $Zip -Out $Out
        $R.ExitCode | Should -Be 1 -Because ($R.Text -join ' | ')
        ($R.Text -join ' ') | Should -Match ([regex]::Escape("consumption row 1 has an id that ends on the word '`$system' with no name after it ('.../<type>/<name>/`$system'). That is an id form this tool does not support")) -Because 'the stop gives its own reason'
        ($R.Text -join ' ') | Should -Match ([regex]::Escape('Ask the owner of this tool how to handle it. Nothing was written.'))
        ($R.Text -join ' ') | Should -Not -Match 'sbdemo01' -Because 'the stop names no id'
        @(Get-ChildItem -LiteralPath $Out -Recurse -File -ErrorAction SilentlyContinue).Count | Should -Be 0 -Because 'nothing was written'
    }

    # A storage account may be named 'providers'. A run masks each name by its place, that one too,
    # and the offline mask's checks read it as a name, so such a report is masked as a run masks it.
    It 'masks a usage row of a storage account named providers as a run masks it, every name a token' {
        $Plain = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers/microsoft.storage/storageaccounts/providers/blobservices/default'
        $AddRow = {
            param([string]$T)
            $Lines = [System.Collections.Generic.List[string]]($T -split "`n")
            $Vm = @($Lines | Where-Object { $_.Contains('/microsoft.compute/virtualmachines/vm-demo"') })[0]
            if ($null -eq $Vm) { throw 'the plain consumption file has no vm-demo row to copy' }
            $Lines.Insert(1, $Vm.Replace('/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers/microsoft.compute/virtualmachines/vm-demo', $Plain).Replace('"Virtual Machines"', '"Storage"'))
            $Lines -join "`n"
        }.GetNewClosure()
        $M = & $script:Masked (& $script:Change @{ 'Consumption_*.csv' = $AddRow })
        $Usage = @($M.Members[@($M.Members.Keys | Where-Object { $_ -like 'Consumption_*' })[0]] | ConvertFrom-Csv)
        $Row = @($Usage | Where-Object { $M.Dict.ResourceIdMap[$_.ResourceId] -ceq $Plain })
        $Row.Count | Should -Be 1 -Because 'the row is masked, and its masked id maps back to the plain id'
        $Tok = '(?:prod|nonprod)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        $Row[0].ResourceId | Should -Match ('^/subscriptions/{0}/resourcegroups/{0}/providers/microsoft\.storage/storageaccounts/{0}/blobservices/{0}\z' -f $Tok) -Because 'every name slot gets a token, the name providers too'
    }

    # A usage row whose id ends on a type word with no name after it ('.../namespaces/<namespace>/topics')
    # would be masked to '.../namespaces/<token>/topics', and downstream reads that last word as the
    # resource's name. No captured billing row shows such an id, so the mask stops on it with its own
    # reason, which masking again would not change, and writes nothing.
    It 'refuses a usage row whose id ends on a type word with no name after it (<Case>), as an id form this tool does not support, and writes nothing' -ForEach @(
        @{ Case = 'a Service Bus namespace''s topics'; Plain = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers/microsoft.servicebus/namespaces/sbdemo01/topics'; Category = 'Service Bus'; Name = 'sbdemo01' }
        @{ Case = 'a storage account''s blob services'; Plain = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers/microsoft.storage/storageaccounts/stdemo01/blobservices'; Category = 'Storage'; Name = 'stdemo01' }
    ) {
        $script:TrailingPlain = $Plain; $script:TrailingCategory = $Category
        $AddRow = {
            param([string]$T)
            $Lines = [System.Collections.Generic.List[string]]($T -split "`n")
            $Vm = @($Lines | Where-Object { $_.Contains('/microsoft.compute/virtualmachines/vm-demo"') })[0]
            if ($null -eq $Vm) { throw 'the plain consumption file has no vm-demo row to copy' }
            $Lines.Insert(1, $Vm.Replace('/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers/microsoft.compute/virtualmachines/vm-demo', $script:TrailingPlain).Replace('"Virtual Machines"', ('"{0}"' -f $script:TrailingCategory)))
            $Lines -join "`n"
        }
        $Zip = & $script:Change @{ 'Consumption_*.csv' = $AddRow }
        $Out = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
        $R = script:Invoke-Protect -Path $Zip -Out $Out
        $R.ExitCode | Should -Be 1 -Because ($R.Text -join ' | ')
        ($R.Text -join ' ') | Should -Match ([regex]::Escape("consumption row 1 has an id that ends on a type word with no name after it ('.../<type>/<name>/<type>'). That is an id form this tool does not support")) -Because 'the stop gives its own reason'
        ($R.Text -join ' ') | Should -Match ([regex]::Escape('Ask the owner of this tool how to handle it. Nothing was written.'))
        ($R.Text -join ' ') | Should -Not -Match $Name -Because 'the stop names no id'
        @(Get-ChildItem -LiteralPath $Out -Recurse -File -ErrorAction SilentlyContinue).Count | Should -Be 0 -Because 'nothing was written'
    }

    # A run keeps the namespace and type words of a tenant-scope id it masks part by part
    # ('/providers/<namespace>/<type>/<name>'). A usage row whose type word is not of Azure's
    # form would be shared with that word as written, so the mask stops on it and writes nothing.
    It 'refuses a usage row whose tenant-scope id has a type word that is not of Azure''s form, and writes nothing' {
        $script:TenantPlain = '/providers/Microsoft.Capacity/Contoso-Secret-Word/r-1'
        $AddRow = {
            param([string]$T)
            $Lines = [System.Collections.Generic.List[string]]($T -split "`n")
            $Vm = @($Lines | Where-Object { $_.Contains('/microsoft.compute/virtualmachines/vm-demo"') })[0]
            if ($null -eq $Vm) { throw 'the plain consumption file has no vm-demo row to copy' }
            $Lines.Insert(1, $Vm.Replace('/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers/microsoft.compute/virtualmachines/vm-demo', $script:TenantPlain).Replace('"Virtual Machines"', '"Reservations"'))
            $Lines -join "`n"
        }
        $Zip = & $script:Change @{ 'Consumption_*.csv' = $AddRow }
        $Out = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
        $R = script:Invoke-Protect -Path $Zip -Out $Out
        $R.ExitCode | Should -Be 1 -Because ($R.Text -join ' | ')
        ($R.Text -join ' ') | Should -Match ([regex]::Escape('consumption row 1 has an id whose provider or type is not as Azure writes one. Nothing was written.')) -Because 'the path word check stops on it'
        ($R.Text -join ' ') | Should -Not -Match 'Contoso-Secret-Word' -Because 'the stop names no id'
        @(Get-ChildItem -LiteralPath $Out -Recurse -File -ErrorAction SilentlyContinue).Count | Should -Be 0 -Because 'nothing was written'
    }

    # A usage row whose id ends on a provider namespace ('.../resourcegroups/<group>/providers/Microsoft.Compute')
    # would be masked to '.../resourcegroups/<token>/providers/Microsoft.Compute', and downstream reads that
    # namespace as the resource's name. No captured billing row shows such an id, so the mask stops on it
    # with its own reason, which masking again would not change, and writes nothing.
    It 'refuses a usage row whose id ends on a provider namespace with no type or name after it, as an id form this tool does not support, and writes nothing' {
        $AddRow = {
            param([string]$T)
            $Lines = [System.Collections.Generic.List[string]]($T -split "`n")
            $Vm = @($Lines | Where-Object { $_.Contains('/microsoft.compute/virtualmachines/vm-demo"') })[0]
            if ($null -eq $Vm) { throw 'the plain consumption file has no vm-demo row to copy' }
            $Lines.Insert(1, $Vm.Replace('/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers/microsoft.compute/virtualmachines/vm-demo', '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers/Microsoft.Compute'))
            $Lines -join "`n"
        }
        $Zip = & $script:Change @{ 'Consumption_*.csv' = $AddRow }
        $Out = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
        $R = script:Invoke-Protect -Path $Zip -Out $Out
        $R.ExitCode | Should -Be 1 -Because ($R.Text -join ' | ')
        ($R.Text -join ' ') | Should -Match ([regex]::Escape("consumption row 1 has an id that ends on a provider namespace with no type or name after it ('.../providers/<namespace>'). That is an id form this tool does not support")) -Because 'the stop gives its own reason'
        ($R.Text -join ' ') | Should -Match ([regex]::Escape('Ask the owner of this tool how to handle it. Nothing was written.'))
        ($R.Text -join ' ') | Should -Not -Match 'rg-demo' -Because 'the stop names no id'
        @(Get-ChildItem -LiteralPath $Out -Recurse -File -ErrorAction SilentlyContinue).Count | Should -Be 0 -Because 'nothing was written'
    }

    # A tenant-scope id a run masks part by part keeps a last provider namespace as written
    # ('/providers/<namespace>/<type>/<token>/providers/Microsoft.Authorization') too, so the mask
    # stops on it as it does on the subscription form, and writes nothing.
    It 'refuses a usage row whose tenant-scope id ends on a provider namespace with no type or name after it, as an id form this tool does not support, and writes nothing' {
        $AddRow = {
            param([string]$T)
            $Lines = [System.Collections.Generic.List[string]]($T -split "`n")
            $Vm = @($Lines | Where-Object { $_.Contains('/microsoft.compute/virtualmachines/vm-demo"') })[0]
            if ($null -eq $Vm) { throw 'the plain consumption file has no vm-demo row to copy' }
            $Lines.Insert(1, $Vm.Replace('/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers/microsoft.compute/virtualmachines/vm-demo', '/providers/Microsoft.Management/managementGroups/mg-platform/providers/Microsoft.Authorization').Replace('"Virtual Machines"', '"Reservations"'))
            $Lines -join "`n"
        }
        $Zip = & $script:Change @{ 'Consumption_*.csv' = $AddRow }
        $Out = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
        $R = script:Invoke-Protect -Path $Zip -Out $Out
        $R.ExitCode | Should -Be 1 -Because ($R.Text -join ' | ')
        ($R.Text -join ' ') | Should -Match ([regex]::Escape("consumption row 1 has an id that ends on a provider namespace with no type or name after it ('.../providers/<namespace>'). That is an id form this tool does not support")) -Because 'the stop gives its own reason'
        ($R.Text -join ' ') | Should -Match ([regex]::Escape('Ask the owner of this tool how to handle it. Nothing was written.'))
        ($R.Text -join ' ') | Should -Not -Match 'mg-platform' -Because 'the stop names no id'
        @(Get-ChildItem -LiteralPath $Out -Recurse -File -ErrorAction SilentlyContinue).Count | Should -Be 0 -Because 'nothing was written'
    }

    # An id that ends on the word providers ('/subscriptions/<id>/providers') or on the word
    # resourceGroups ('/subscriptions/<id>/resourceGroups') with no value after it is stopped the
    # same way, with a reason that names that word rather than a type word.
    It 'refuses a usage row whose id ends on <Case> with no value after it, names that word in its reason, and writes nothing' -ForEach @(
        @{ Case = 'the word providers (in a subscription id)'; Plain = '/subscriptions/12345678-1234-1234-1234-123456789012/providers'; Want = "consumption row 1 has an id that ends on the word 'providers' with no provider namespace after it ('.../providers'). That is an id form this tool does not support" }
        @{ Case = 'the word providers (in a group id)'; Plain = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers'; Want = "consumption row 1 has an id that ends on the word 'providers' with no provider namespace after it ('.../providers'). That is an id form this tool does not support" }
        @{ Case = 'the word resourceGroups'; Plain = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups'; Want = "consumption row 1 has an id that ends on the word 'resourceGroups' with no group name after it ('/subscriptions/<id>/resourceGroups'). That is an id form this tool does not support" }
    ) {
        $script:TrailingWordPlain = $Plain
        $AddRow = {
            param([string]$T)
            $Lines = [System.Collections.Generic.List[string]]($T -split "`n")
            $Vm = @($Lines | Where-Object { $_.Contains('/microsoft.compute/virtualmachines/vm-demo"') })[0]
            if ($null -eq $Vm) { throw 'the plain consumption file has no vm-demo row to copy' }
            $Lines.Insert(1, $Vm.Replace('/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers/microsoft.compute/virtualmachines/vm-demo', $script:TrailingWordPlain))
            $Lines -join "`n"
        }
        $Zip = & $script:Change @{ 'Consumption_*.csv' = $AddRow }
        $Out = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
        $R = script:Invoke-Protect -Path $Zip -Out $Out
        $R.ExitCode | Should -Be 1 -Because ($R.Text -join ' | ')
        ($R.Text -join ' ') | Should -Match ([regex]::Escape($Want)) -Because 'the stop names the word the id ends on'
        ($R.Text -join ' ') | Should -Not -Match 'a type word with no name after it' -Because 'that word is not a type word'
        ($R.Text -join ' ') | Should -Match ([regex]::Escape('Ask the owner of this tool how to handle it. Nothing was written.'))
        ($R.Text -join ' ') | Should -Not -Match '12345678-1234-1234-1234-123456789012|rg-demo' -Because 'the stop names no id'
        @(Get-ChildItem -LiteralPath $Out -Recurse -File -ErrorAction SilentlyContinue).Count | Should -Be 0 -Because 'nothing was written'
    }

    It 'refuses the report when the masking leaves the name <Kept> of a usage row''s id as written, which the last leak scan cannot find in a text' -ForEach @(
        @{ Kept = '$system'; Id = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers/microsoft.servicebus/namespaces/$system' }
        @{ Kept = 'orders'; Id = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers/microsoft.servicebus/namespaces/sbbilling/queues/orders' }
    ) {
        # Each name is billed only (no inventory row or metric record holds it), so the
        # inventory and metric slot checks never see it, and the last leak scan skips it
        # (a short value of letters, or '$system', is not looked for inside a text).
        $AddRow = {
            param([string]$T)
            $Lines = [System.Collections.Generic.List[string]]($T -split "`n")
            $Vm = @($Lines | Where-Object { $_.Contains('/microsoft.compute/virtualmachines/vm-demo"') })[0]
            if ($null -eq $Vm) { throw 'the plain consumption file has no vm-demo row to copy' }
            $Lines.Insert(1, $Vm.Replace('/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers/microsoft.compute/virtualmachines/vm-demo', $Id).Replace('"Virtual Machines"', '"Service Bus"'))
            $Lines -join "`n"
        }.GetNewClosure()
        $Zip = & $script:Change @{ 'Consumption_*.csv' = $AddRow }

        # Guard: this tool masks the row, and the check after the row masking takes it.
        $M = & $script:Masked $Zip
        $Csv = $M.Members[@($M.Members.Keys | Where-Object { $_ -like 'Consumption_*' })[0]]
        $Csv.IndexOf('/' + $Kept, [System.StringComparison]::Ordinal) | Should -Be -1 -Because 'the run gives the name a token'

        # A copy of this tool whose id masking leaves only this name as written (a fault
        # such as an older build's kept '$system'): the check after the row masking
        # must refuse what it writes, and leave nothing behind.
        $Tool = Join-Path $script:Work ('tool-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $Tool | Out-Null
        Get-ChildItem -LiteralPath $script:RepoRoot -Force | Where-Object { $_.Name -notin '.git', 'Tests' } | Copy-Item -Destination $Tool -Recurse
        $InvPath = Join-Path $Tool 'ResourceInventory.ps1'
        $NameLine = '$Masked.Add($ResourceNameDictionary[$UpToName])'
        $InvText = [System.IO.File]::ReadAllText($InvPath)
        ($InvText.Split($NameLine).Count - 1) | Should -Be 1 -Because 'the fault is put on the one line that writes a name token'
        [System.IO.File]::WriteAllText($InvPath, $InvText.Replace($NameLine, ('$Masked.Add($(if ($Next -ceq ''{0}'') {{ $Next }} else {{ $ResourceNameDictionary[$UpToName] }}))' -f $Kept)))
        $Out = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
        $Text = @(& $script:Pwsh -NoProfile -NonInteractive -File (Join-Path $Tool 'Protect-RdaReport.ps1') -Path $Zip -OutputDirectory $Out 2>&1 | ForEach-Object { [string]$_ })
        $LASTEXITCODE | Should -Be 1 -Because ('the masked usage id keeps {0} as written | {1}' -f $Kept, ($Text -join ' | '))
        ($Text -join "`n") | Should -Match ('consumption row \d+: ' + [regex]::Escape('its masked id is not the one a run writes (a name part left as written, or another shape). Nothing was written.'))
        ($Text -join "`n").IndexOf('/' + $Kept, [System.StringComparison]::Ordinal) | Should -Be -1 -Because 'the stop names no id'
        Test-Path -LiteralPath $Out | Should -BeFalse -Because 'nothing is written'
    }

    # The id check after the row masking reads the row's ResourceId. A run writes
    # the InstanceData's ResourceUri from the same value, so it must be that same
    # masked id, case for case. That check cannot fail with today's
    # Protect-RdaUsageRow: it guards a future change to it. Each case is a copy of
    # this tool whose Protect-RdaUsageRow writes the two cells from different
    # values, faults that no other check sees (another case, another token of the
    # right shape) or sees only later (a plain id left in one cell), and the check
    # must stop each one first.
    It 'refuses the report when, after the row masking, the id in a usage row''s InstanceData is not the row''s masked id: <Case>' -ForEach @(
        @{ Case = 'the ResourceUri written in upper case'; Find = '$InstanceObject.''Microsoft.Resources''.resourceUri = $ObfuscatedUri'; Put = '$InstanceObject.''Microsoft.Resources''.resourceUri = $ObfuscatedUri.ToUpperInvariant()' }
        @{ Case = 'the ResourceUri left as the plain id'; Find = '$InstanceObject.''Microsoft.Resources''.resourceUri = $ObfuscatedUri'; Put = '$InstanceObject.''Microsoft.Resources''.resourceUri = $RawUri' }
        @{ Case = 'the ResourceUri given another token of the right shape'; Find = '$InstanceObject.''Microsoft.Resources''.resourceUri = $ObfuscatedUri'; Put = '$InstanceObject.''Microsoft.Resources''.resourceUri = $ObfuscatedUri -replace ''[0-9a-f]{12}\z'', ''000000000000''' }
        @{ Case = 'the row''s ResourceId left as the plain id'; Find = '$Row.ResourceId = $ObfuscatedUri'; Put = '$Row.ResourceId = $RawUri' }
    ) {
        $Zip = & $script:Change @{}
        $Tool = Join-Path $script:Work ('tool-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $Tool | Out-Null
        Get-ChildItem -LiteralPath $script:RepoRoot -Force | Where-Object { $_.Name -notin '.git', 'Tests' } | Copy-Item -Destination $Tool -Recurse
        $InvPath = Join-Path $Tool 'ResourceInventory.ps1'
        $InvText = [System.IO.File]::ReadAllText($InvPath)
        ($InvText.Split($Find).Count - 1) | Should -Be 1 -Because 'the fault is put on the one line of Protect-RdaUsageRow that writes that cell'
        [System.IO.File]::WriteAllText($InvPath, $InvText.Replace($Find, $Put))
        $Out = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
        $Text = @(& $script:Pwsh -NoProfile -NonInteractive -File (Join-Path $Tool 'Protect-RdaReport.ps1') -Path $Zip -OutputDirectory $Out 2>&1 | ForEach-Object { [string]$_ })
        $LASTEXITCODE | Should -Be 1 -Because ('the InstanceData id differs from the row''s masked id | {0}' -f ($Text -join ' | '))
        ($Text -join "`n") | Should -Match ('consumption row \d+: ' + [regex]::Escape("the id in its InstanceData is not the row's masked id after masking (a run writes both from one value). Nothing was written."))
        ($Text -join "`n") | Should -Not -Match 'rg-demo|vm-demo|12345678-1234' -Because 'the stop names no real value'
        Test-Path -LiteralPath $Out | Should -BeFalse -Because 'nothing is written'
    }

    # A doc check: the comment of that check says why it is kept although it cannot fail today.
    It 'says, above the InstanceData id check, that it cannot fail today and guards a future change to Protect-RdaUsageRow' {
        $Lines = [System.IO.File]::ReadAllLines((Join-Path $script:RepoRoot 'Protect-RdaReport.ps1'))
        $At = @(for ($i = 0; $i -lt $Lines.Count; $i++) { if ($Lines[$i].Contains('if ([string]$Instance.''Microsoft.Resources''.ResourceUri -cne [string]$UsageRow.ResourceId)')) { $i } })
        $At.Count | Should -Be 1
        $Comment = @(for ($i = $At[0] - 1; $i -ge 0 -and $Lines[$i].TrimStart().StartsWith('#'); $i--) { $Lines[$i].Trim().TrimStart('#').Trim() })
        [array]::Reverse($Comment)
        $Text = $Comment -join ' '
        $Text | Should -Match 'cannot fail today'
        $Text | Should -Match 'guard against a future change to Protect-RdaUsageRow'
    }

    It 'masks a reservation''s tenant-scope usage row, and refuses the report when a name part of that id is left in a cell no one masks' {
        $OrderGuid = '44444444-4444-4444-4444-444444444444'
        $Reservation = "/providers/microsoft.capacity/reservationorders/$OrderGuid/reservations/55555555-5555-5555-5555-555555555555"
        $AddRow = {
            param([string]$T, [bool]$Plant)
            $Lines = [System.Collections.Generic.List[string]]($T -split "`n")
            $Vm = @($Lines | Where-Object { $_.Contains('/microsoft.compute/virtualmachines/vm-demo"') })[0]
            if ($null -eq $Vm) { throw 'the plain consumption file has no vm-demo row to copy' }
            $Row = $Vm.Replace('/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers/microsoft.compute/virtualmachines/vm-demo', $Reservation)
            # Only this usage row names the order; the report's pages do not.
            if ($Plant) { $Row = ([regex]'""ImageType"":""""').Replace($Row, ('""ImageType"":""{0}""' -f $OrderGuid), 1) }
            $Lines.Insert(1, $Row)
            $Lines -join "`n"
        }
        $Clean = & $script:Masked (& $script:Change @{ 'Consumption_*.csv' = { param($T) & $AddRow $T $false } })
        $Usage = @($Clean.Members[@($Clean.Members.Keys | Where-Object { $_ -like 'Consumption_*' })[0]] | ConvertFrom-Csv)
        $Masked = @($Usage | Where-Object { $Clean.Dict.ResourceIdMap[$_.ResourceId] -eq $Reservation })
        $Masked.Count | Should -Be 1
        $Masked[0].ResourceId | Should -Match '^/providers/microsoft\.capacity/reservationorders/(?:prod|nonprod)_[0-9a-f-]{36}/reservations/(?:prod|nonprod)_[0-9a-f-]{36}$'

        $Out = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
        $R = script:Invoke-Protect -Path (& $script:Change @{ 'Consumption_*.csv' = { param($T) & $AddRow $T $true } }) -Out $Out
        $R.ExitCode | Should -Be 1 -Because 'the order''s name is a real value the masked report must not hold'
        ($R.Text -join "`n") | Should -Match 'A real name or id is still in: Consumption_'
        ($R.Text -join "`n") | Should -Not -Match $OrderGuid -Because 'the message names no real value'
        Test-Path -LiteralPath $Out | Should -BeFalse
    }

    It 'labels the page of a report over several subscriptions with their count, as the run does' {
        $M = & $script:Masked (& $script:Change @{ 'ResourcesReport_*.html' = { param($T) $T -replace '<b>Subscription:</b> [^<]+', '<b>Subscription:</b> 2 subscriptions (consolidated)' } })
        $M.Members[@($M.Members.Keys | Where-Object { $_ -like '*.html' })[0]] | Should -Match '2 subscriptions \(consolidated\)'
    }

    It 'refuses a report whose logs, page or consumption hold text a run does not write there' {
        $Refused = {
            param([hashtable]$Changes, [string]$Why)
            $Out = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
            $R = script:Invoke-Protect -Path (& $script:Change $Changes) -Out $Out
            $R.ExitCode | Should -Be 1 -Because $Why
            ($R.Text -join "`n") | Should -Not -Match 'contoso-secret' -Because 'the message names no real value'
            Test-Path -LiteralPath $Out | Should -BeFalse
            $R
        }
        # A phase or collector name the code has not.
        $R = & $Refused @{ 'Diagnostics_*.log' = { param($T) $T -replace 'Resource detail collection \(service collectors\)', 'contoso-secret phase' } } 'a phase no run times'
        ($R.Text -join "`n") | Should -Match 'phase or collector'
        $R = & $Refused @{ 'ResourcesReport_*.html' = { param($T) $T -replace '<body>', '<body><div class="coverage-banner"><span class="coverage-icon">&#9888;</span><div><b>Incomplete collection:</b> 1 resource type(s) could not be collected and are MISSING from this report - not empty because there are none, but because the collector errored: <code>contoso-secret</code>. See the Diagnostics log in this bundle for the underlying error, then re-run.</div></div>' } } 'a collector no run has'
        ($R.Text -join "`n") | Should -Match 'collector this code does not have'
        # A full id in a field no run masks: its parts are real values.
        $Foreign = '/subscriptions/99999999-9999-9999-9999-999999999999/resourcegroups/rg-contoso-secret-77/providers/microsoft.compute/images/img-contoso-secret-77'
        $R = & $Refused @{ 'Consumption_*.csv' = { param($T) ([regex]'""ImageType"":""""').Replace($T, ('""ImageType"":""{0}""' -f $Foreign), 1) } } 'a foreign id in ImageType'
        ($R.Text -join "`n") | Should -Match 'real'
        # The same id fully escaped (no part plain), and with no first '/', in a consumption cell.
        $Escaped = -join ($Foreign.ToCharArray() | ForEach-Object { '%{0:X2}' -f [int]$_ })
        foreach ($Form in $Escaped, $Foreign.Substring(1))
        {
            $Plant = { param($T) ([regex]'""ImageType"":""""').Replace($T, ('""ImageType"":""{0}""' -f $Form), 1) }.GetNewClosure()
            $R = & $Refused @{ 'Consumption_*.csv' = $Plant } ('a foreign id in ImageType: ' + $Form.Substring(0, 6))
            ($R.Text -join "`n") | Should -Match 'real'
        }
        # A collector name the code has not, in the diagnostics log.
        $R = & $Refused @{ 'Diagnostics_*.log' = { param($T) $T -replace 'Collector failures: 0', ('Collector failures: 1' + "`n" + '  [sub <guid>] contoso-secret: boom') } } 'a collector no run has, in the log'
        ($R.Text -join "`n") | Should -Match 'phase or collector'
        # The row's id, location or meter not its InstanceData's.
        $R = & $Refused @{ 'Consumption_*.csv' = { param($T) $Lines = $T -split "`n"; $Lines[1] = $Lines[1] -replace '","eastus","meter-demo",', '","westus","meter-demo",'; $Lines -join "`n" } } 'a row location not its InstanceData location'
        ($R.Text -join "`n") | Should -Match 'row 1 has an id, location or meter'
        $R = & $Refused @{ 'Consumption_*.csv' = { param($T) $Lines = $T -split "`n"; $Lines[1] = $Lines[1] -replace '","eastus","meter-demo",', '","eastus","meter-other",'; $Lines -join "`n" } } 'a row meter not its InstanceData meter'
        ($R.Text -join "`n") | Should -Match 'row 1 has an id, location or meter'
        $R = & $Refused @{ 'Consumption_*.csv' = { param($T) $Lines = $T -split "`n"; $Lines[1] = $Lines[1] -replace '","(/subscriptions/[^"]+/virtualmachines/)vm-demo","eastus"', '","$1vm-other","eastus"'; $Lines -join "`n" } } 'a row id not its InstanceData id'
        ($R.Text -join "`n") | Should -Match 'row 1 has an id, location or meter'
        # A quantity or time that cannot be read (the whole file is then unusable).
        $R = & $Refused @{ 'Consumption_*.csv' = { param($T) ([regex]'","24","1 Hour","').Replace($T, '","2,4","1 Hour","', 1) } } 'a quantity with a comma'
        ($R.Text -join "`n") | Should -Match 'quantity or time'
        # A quantity too big for a number (it overflows a number parse) is refused too.
        $R = & $Refused @{ 'Consumption_*.csv' = { param($T) ([regex]'","24","1 Hour","').Replace($T, '","1e999999","1 Hour","', 1) } } 'a quantity that overflows'
        ($R.Text -join "`n") | Should -Match 'quantity or time'
        $R = & $Refused @{ 'Consumption_*.csv' = { param($T) ([regex]'"\d{1,2}/\d{1,2}/\d{4} \d{1,2}:\d{2}:\d{2} [AP]M"').Replace($T, '"contoso-secret"', 1) } } 'a time a run does not write'
        ($R.Text -join "`n") | Should -Match 'quantity or time'
        Test-RdaUsageTime '11/1/2026 12:00:00 AM' | Should -BeTrue
        Test-RdaUsageTime '2026-11-01T00:00:00Z' | Should -BeTrue
        Test-RdaUsageTime '01.11.2026 00:00' | Should -BeFalse
        # A record with a cell past the header's count (Import-Csv drops it).
        $R = & $Refused @{ 'Consumption_*.csv' = { param($T) $Lines = $T -split "`n"; $Lines[1] = $Lines[1].TrimEnd("`r") + ',"x"'; $Lines -join "`n" } } 'an extra cell'
        ($R.Text -join "`n") | Should -Match 'row 1 is cut off, or holds more cells'
    }

    It 'writes a row with a negative quantity or an empty MeterId unchanged, as a run does, and counts and names it' {
        # Such a row's usage is not counted; a run writes it as Azure gave it.
        $Zip = & $script:Change @{ 'Consumption_*.csv' = { param($T)
                $Lines = $T -split "`n"
                $Lines[1] = ([regex]'","24","1 Hour","').Replace($Lines[1], '","-24","1 Hour","', 1)
                $Lines[2] = ([regex]',"meter-demo","Hours",').Replace($Lines[2], ',"","Hours",', 1)
                $Lines -join "`n"
            }
        }
        $Out = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
        $R = script:Invoke-Protect -Path $Zip -Out $Out
        $R.ExitCode | Should -Be 0 -Because ($R.Text -join ' | ')
        $Line = @($R.Text | Where-Object { $_ -match 'the usage of these consumption rows is not counted' })
        $Line.Count | Should -Be 1 -Because 'the mask must not pass such rows in silence'
        $Line[0] | Should -Match '^In ResourcesReport_.+\.zip, '
        @($R.Text | Where-Object { $_ -match '^  1 row has a negative Quantity: row 1 \(/subscriptions/' }).Count | Should -Be 1 -Because ($R.Text -join ' | ')
        @($R.Text | Where-Object { $_ -match '^  1 row has an empty MeterId: row 2 \(/subscriptions/' }).Count | Should -Be 1 -Because ($R.Text -join ' | ')
        $Folder = @(Get-ChildItem -LiteralPath $Out -Directory)[0].FullName
        $Members = script:Read-Zip @(Get-ChildItem -LiteralPath $Folder -Filter 'ResourcesReport_*.zip')[0].FullName
        $Rows = @($Members[@($Members.Keys | Where-Object { $_ -like 'Consumption_*' })[0]] | ConvertFrom-Csv)
        $Rows[0].Quantity | Should -Be '-24' -Because 'a run writes the quantity Azure gave'
        $Rows[1].MeterId | Should -Be '' -Because 'a run writes the MeterId Azure gave'
        # A report with no such row prints no such line.
        $Clean = script:Invoke-Protect -Path $script:PlainRun.ZipPath -Out (Join-Path $script:Work ([guid]::NewGuid().ToString('N')))
        $Clean.ExitCode | Should -Be 0
        @($Clean.Text | Where-Object { $_ -match 'the usage of these consumption rows is not counted|negative Quantity|empty MeterId|empty ResourceId' }).Count | Should -Be 0
    }

    It 'counts the cells of each consumption record as Export-Csv writes them' {
        $F = Join-Path $script:Work 'cells.csv'
        Set-Content -LiteralPath $F -Value ('"A","B"' + "`r`n" + '"x, y","line one' + "`n" + 'line ""two"""' + "`r`n" + '"1","2"' + "`r`n") -NoNewline
        Initialize-RdaOfflineType
        [RdaCsvCheck]::FirstBadRecord($F, 2) | Should -Be 0
        Set-Content -LiteralPath $F -Value ('"A","B"' + "`r`n" + '"1","2"' + "`r`n" + '"1","2",""' + "`r`n") -NoNewline
        [RdaCsvCheck]::FirstBadRecord($F, 2) | Should -Be 2
        Set-Content -LiteralPath $F -Value ('"A","B"' + "`r`n" + '"1","2' + "`r`n") -NoNewline
        [RdaCsvCheck]::FirstBadRecord($F, 2) | Should -Be 1
        # A bare CR between records, a quote inside a cell, text after a closing quote.
        Set-Content -LiteralPath $F -Value ('"A","B"' + "`r`n" + '"1","2"' + "`r" + '"1","2"' + "`r`n") -NoNewline
        [RdaCsvCheck]::FirstBadRecord($F, 2) | Should -Be 1
        Set-Content -LiteralPath $F -Value ('"A","B"' + "`r`n" + '"1",a"b' + "`r`n") -NoNewline
        [RdaCsvCheck]::FirstBadRecord($F, 2) | Should -Be 1
        Set-Content -LiteralPath $F -Value ('"A","B"' + "`r`n" + '"1","2"x' + "`r`n") -NoNewline
        [RdaCsvCheck]::FirstBadRecord($F, 2) | Should -Be 1
        # A cell not in quotes (but an empty one, Export-Csv's null), and a blank line between records.
        Set-Content -LiteralPath $F -Value ('"A","B"' + "`r`n" + '"1",2' + "`r`n") -NoNewline
        [RdaCsvCheck]::FirstBadRecord($F, 2) | Should -Be 1
        Set-Content -LiteralPath $F -Value ('"A","B"' + "`r`n" + ',"2"' + "`r`n" + '"1",' + "`r`n") -NoNewline
        [RdaCsvCheck]::FirstBadRecord($F, 2) | Should -Be 0
        Set-Content -LiteralPath $F -Value ('"A","B"' + "`r`n" + '"1","2"' + "`r`n`r`n" + '"3","4"' + "`r`n") -NoNewline
        [RdaCsvCheck]::FirstBadRecord($F, 2) | Should -Be 2
        Set-Content -LiteralPath $F -Value ('"A","B"' + "`r`n" + '"1","two' + "`r`n" + 'lines"' + "`r`n`r`n" + '"3","4"' + "`r`n") -NoNewline
        [RdaCsvCheck]::FirstBadRecord($F, 2) | Should -Be 2
        # What Export-Csv writes, a null cell too, reads clean.
        @([pscustomobject]@{ A = $null; B = 'x' }, [pscustomobject]@{ A = '1'; B = "two`nlines" }) | Export-Csv -LiteralPath $F -NoTypeInformation -Encoding utf8
        [RdaCsvCheck]::FirstBadRecord($F, 2) | Should -Be 0
    }

    It 'marks the cells of each consumption record that are empty with no quotes, as Export-Csv writes a null' {
        $F = Join-Path $script:Work 'bare.csv'
        Initialize-RdaOfflineType
        # A quoted "" is an empty string, not marked; a bare empty cell is marked. The header is no record.
        Set-Content -LiteralPath $F -Value ('"A","B","C"' + "`r`n" + ',"","x"' + "`r`n" + '"1",,' + "`r`n") -NoNewline
        [RdaCsvCheck]::BareEmptyCells($F) | Should -Be @(1, 6)
        # A quoted cell that holds a comma, a newline and a quote is one cell, and its record one record.
        Set-Content -LiteralPath $F -Value ('"A","B","C"' + "`r`n" + '"x, y","line one' + "`n" + 'line ""two""",' + "`r`n" + ',"a,b",""' + "`r`n") -NoNewline
        [RdaCsvCheck]::BareEmptyCells($F) | Should -Be @(4, 1)
        # CRLF and LF line ends give the same marks.
        $Body = @('"A","B","C"', ',"","x"', '"1",,', ',,')
        Set-Content -LiteralPath $F -Value (($Body -join "`r`n") + "`r`n") -NoNewline
        [RdaCsvCheck]::BareEmptyCells($F) | Should -Be @(1, 6, 7)
        Set-Content -LiteralPath $F -Value (($Body -join "`n") + "`n") -NoNewline
        [RdaCsvCheck]::BareEmptyCells($F) | Should -Be @(1, 6, 7)
        # A last line with no line break is still a record.
        Set-Content -LiteralPath $F -Value ($Body -join "`r`n") -NoNewline
        [RdaCsvCheck]::BareEmptyCells($F) | Should -Be @(1, 6, 7)
        # A record of more than 31 cells: only the first 31 are marked, and a later bare cell
        # sets no bit (a shift past 31 would wrap onto the first cells).
        $Header = (1..33 | ForEach-Object { '"H{0}"' -f $_ }) -join ','
        $AllBare = ',' * 32
        $LateBare = ((1..31 | ForEach-Object { '"v"' }) -join ',') + ',,'
        Set-Content -LiteralPath $F -Value ($Header + "`r`n" + $AllBare + "`r`n" + $LateBare + "`r`n") -NoNewline
        [RdaCsvCheck]::BareEmptyCells($F) | Should -Be @(0x7FFFFFFF, 0)
        # What Export-Csv writes: a null cell is bare, an empty string is quoted.
        @([pscustomobject]@{ A = $null; B = ''; C = 'x' }, [pscustomobject]@{ A = '1'; B = "two`nlines"; C = $null }) | Export-Csv -LiteralPath $F -NoTypeInformation -Encoding utf8
        [RdaCsvCheck]::BareEmptyCells($F) | Should -Be @(1, 4)
    }

    It 'refuses a file whose name differs from the run''s only in case (files are found by their exact start)' {
        $Zip = & $script:Change @{}
        $Archive = [System.IO.Compression.ZipFile]::Open($Zip, 'Update')
        try
        {
            $Entry = @($Archive.Entries | Where-Object { $_.Name -like 'Metrics_*' })[0]
            $R = [IO.StreamReader]::new($Entry.Open()); $Text = $R.ReadToEnd(); $R.Dispose()
            $Name = 'm' + $Entry.FullName.Substring(1); $Entry.Delete()
            $E = $Archive.CreateEntry($Name); $W = [IO.StreamWriter]::new($E.Open()); $W.Write($Text); $W.Dispose()
        }
        finally { $Archive.Dispose() }
        $Out = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
        $Run = script:Invoke-Protect -Path $Zip -Out $Out
        $Run.ExitCode | Should -Be 1
        ($Run.Text -join "`n") | Should -Match 'does not know how to mask'
        Test-Path -LiteralPath $Out | Should -BeFalse
    }

    It 'refuses a report zip whose inventory file is named in another case' {
        $Zip = & $script:Change @{}
        $Archive = [System.IO.Compression.ZipFile]::Open($Zip, 'Update')
        try
        {
            $Entry = @($Archive.Entries | Where-Object { $_.Name -like 'Inventory_*' })[0]
            $R = [IO.StreamReader]::new($Entry.Open()); $Text = $R.ReadToEnd(); $R.Dispose()
            $Name = 'i' + $Entry.FullName.Substring(1); $Entry.Delete()
            $E = $Archive.CreateEntry($Name); $W = [IO.StreamWriter]::new($E.Open()); $W.Write($Text); $W.Dispose()
        }
        finally { $Archive.Dispose() }
        $Run = script:Invoke-Protect -Path $Zip -Out (Join-Path $script:Work ([guid]::NewGuid().ToString('N')))
        $Run.ExitCode | Should -Be 1
        ($Run.Text -join "`n") | Should -Match 'not named as a run names one'
    }

    It 'writes the setup time the plain page shows, and refuses one a run does not write' {
        $Plain = (script:Read-Zip $script:PlainRun.ZipPath)[@((script:Read-Zip $script:PlainRun.ZipPath).Keys | Where-Object { $_ -like '*.html' })[0]]
        $Plain -cmatch '<div><b>Setup and resource discovery:</b> [^<]*</div>' | Should -BeTrue
        $Line = $Matches[0]
        $M = & $script:Masked (& $script:Change @{})
        $M.Members[@($M.Members.Keys | Where-Object { $_ -like '*.html' })[0]] | Should -Match ([regex]::Escape($Line))
        $M = & $script:Masked (& $script:Change @{ 'ResourcesReport_*.html' = { param($T) $T -replace '<div><b>Setup and resource discovery:</b> [^<]*</div>', ('<div><b>Setup and resource discovery:</b> 12{0}5 Minutes</div>' -f [char]0x066B) } })
        $M.Members[@($M.Members.Keys | Where-Object { $_ -like '*.html' })[0]] | Should -Match '<div><b>Setup and resource discovery:</b> 12[.,]5 Minutes</div>'
        foreach ($Form in '3 Seconds', '12/5 Minutes', '12,05 Minutes')
        {
            $M = & $script:Masked (& $script:Change @{ 'ResourcesReport_*.html' = { param($T) $T -replace '<div><b>Setup and resource discovery:</b> [^<]*</div>', ('<div><b>Setup and resource discovery:</b> {0}</div>' -f $Form) }.GetNewClosure() })
            $M.Members[@($M.Members.Keys | Where-Object { $_ -like '*.html' })[0]] | Should -Match ('<div><b>Setup and resource discovery:</b> {0}</div>' -f ($Form -replace '[/,]', '[.,]')) -Because $Form
        }
        foreach ($Bad in '60 Seconds', '12.50 Minutes', '07 Seconds')
        {
            $R = script:Invoke-Protect -Path (& $script:Change @{ 'ResourcesReport_*.html' = { param($T) $T -replace '<div><b>Setup and resource discovery:</b> [^<]*</div>', ('<div><b>Setup and resource discovery:</b> {0}</div>' -f $Bad) }.GetNewClosure() }) -Out (Join-Path $script:Work ([guid]::NewGuid().ToString('N')))
            $R.ExitCode | Should -Be 1 -Because $Bad
        }
        $Out = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
        $R = script:Invoke-Protect -Path (& $script:Change @{ 'ResourcesReport_*.html' = { param($T) $T -replace '<div><b>Setup and resource discovery:</b> [^<]*</div>', '<div><b>Setup and resource discovery:</b> contoso-secret</div>' } }) -Out $Out
        $R.ExitCode | Should -Be 1
        ($R.Text -join "`n") | Should -Match 'run times are not as a run writes them'
        # A total of 60 Seconds (59.5 to 59.99, rounded) and one in minutes are written as the plain page writes them.
        foreach ($Form in '60 Seconds', '1.44 Minutes')
        {
            $M = & $script:Masked (& $script:Change @{ 'ResourcesReport_*.html' = { param($T) $T -replace '<div><b>Total collection \(all phases\):</b> [^<]*</div>', ('<div><b>Total collection (all phases):</b> {0}</div>' -f $Form) }.GetNewClosure() })
            $M.Members[@($M.Members.Keys | Where-Object { $_ -like '*.html' })[0]] | Should -Match ('<div><b>Total collection \(all phases\):</b> {0}</div>' -f ($Form -replace '\.', '[.,]')) -Because $Form
        }
        # The total collection time, when the page has it, is kept too.
        $Plain -cmatch '<div><b>Total collection \(all phases\):</b> [^<]*</div>' | Should -BeTrue
        $Total = $Matches[0]
        $M = & $script:Masked (& $script:Change @{})
        $M.Members[@($M.Members.Keys | Where-Object { $_ -like '*.html' })[0]] | Should -Match ([regex]::Escape($Total))
        # A run writes the setup time on every page; each time once, in its form.
        foreach ($Change in @( { param($T) $T -replace '<div><b>Setup and resource discovery:</b> [^<]*</div>', '' }, { param($T) $T -replace '(<div><b>Setup and resource discovery:</b> [^<]*</div>)', '$1$1' }, { param($T) $T -replace '<div><b>Total collection \(all phases\):</b> [^<]*</div>', '<div><b>Total collection (all phases):</b> 75 Seconds</div>' }))
        {
            $R = script:Invoke-Protect -Path (& $script:Change @{ 'ResourcesReport_*.html' = $Change }) -Out (Join-Path $script:Work ([guid]::NewGuid().ToString('N')))
            $R.ExitCode | Should -Be 1
            ($R.Text -join "`n") | Should -Match 'run times are not as a run writes them'
        }
        # A phase name only in the writer's case.
        $R = script:Invoke-Protect -Path (& $script:Change @{ 'Diagnostics_*.log' = { param($T) $T -replace 'Resource detail collection \(service collectors\)', 'resource detail collection (service collectors)' } }) -Out (Join-Path $script:Work ([guid]::NewGuid().ToString('N')))
        $R.ExitCode | Should -Be 1
        ($R.Text -join "`n") | Should -Match 'phase or collector'
    }

    It 'writes the environment the plain page shows, and refuses one a run does not write' {
        $Plain = (script:Read-Zip $script:PlainRun.ZipPath)[@((script:Read-Zip $script:PlainRun.ZipPath).Keys | Where-Object { $_ -like '*.html' })[0]]
        $Plain -match '<div><b>Environment:</b> ([^<]*)</div>' | Should -BeTrue
        $Env = $Matches[1]
        $M = & $script:Masked (& $script:Change @{ 'ResourcesReport_*.html' = { param($T) $T -replace '<div><b>Environment:</b> [^<]*</div>', '<div><b>Environment:</b> Azure CloudShell</div>' } })
        $M.Members[@($M.Members.Keys | Where-Object { $_ -like '*.html' })[0]] | Should -Match '<div><b>Environment:</b> Azure CloudShell</div>'
        $M = & $script:Masked (& $script:Change @{})
        $M.Members[@($M.Members.Keys | Where-Object { $_ -like '*.html' })[0]] | Should -Match ('<div><b>Environment:</b> {0}</div>' -f [regex]::Escape($Env))
        $Out = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
        $R = script:Invoke-Protect -Path (& $script:Change @{ 'ResourcesReport_*.html' = { param($T) $T -replace '<div><b>Environment:</b> [^<]*</div>', '<div><b>Environment:</b> contoso-secret</div>' } }) -Out $Out
        $R.ExitCode | Should -Be 1
        ($R.Text -join "`n") | Should -Match 'environment a run does not write'
    }

    It 'masks a row whose id the pull kept in Azure''s case, with an ARM-shaped masked id' {
        $Mixed = '/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-demo/providers/Microsoft.Compute/virtualMachines/vm-demo'
        $M = & $script:Masked (& $script:Change @{ 'Inventory_*.json' = { param($T) ([regex]'"ID":"/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-demo/providers/microsoft.compute/virtualmachines/vm-demo"').Replace($T, ('"ID":"{0}"' -f $Mixed), 1) } })
        $Inv = ConvertFrom-RdaJsonText -Text $M.Members[@($M.Members.Keys | Where-Object { $_ -like 'Inventory_*' })[0]]
        $Vm = @($Inv['VirtualMachines'] | Where-Object { $M.Dict.ResourceIdMap[$_['ID']] -ceq $Mixed })
        $Vm.Count | Should -Be 1 -Because 'the run token loop takes the id as pulled'
        $Vm[0]['ID'] | Should -Match '^/subscriptions/(prod|nonprod)_[^/]+/resourcegroups/(prod|nonprod)_[^/]+/providers/'
    }

    It 'refuses an inventory or diagnostics log tool version that is not a run''s three numbers' {
        # The version the synthetic run writes is this tree's (Version.json), and another one.
        $V = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Version.json') -Raw | ConvertFrom-Json
        $Ver = [regex]::Escape(('{0}.{1}.{2}' -f $V.MajorVersion, $V.MinorVersion, $V.BuildVersion))
        $OtherVer = '{0}.{1}.{2}' -f $V.MajorVersion, $V.MinorVersion, (1 + [int]$V.BuildVersion)
        foreach ($Change in @(@{ 'Inventory_*.json' = { param($T) $T -replace (',"Version":"' + $Ver + '"'), '' }.GetNewClosure() }, @{ 'Diagnostics_*.log' = { param($T) $T -replace ('Tool version    : ' + $Ver), ('Tool version    : ' + $OtherVer) }.GetNewClosure() }, @{ 'Diagnostics_*.log' = { param($T) $T -replace '(?m)^Metrics auth-skipped subscriptions: 0', ('Metrics auth-skipped subscriptions: 1' + "`n" + '  [sub contoso-secret-01] auth') } }, @{ 'Consumption_*.csv' = { param($T) $T -replace '/providers/microsoft\.compute/virtualmachines/vm-demo', '/providers/contoso-secret-01/virtualmachines/vm-demo' } }, @{ 'Inventory_*.json' = { param($T) $T -replace ('"Version":"' + $Ver + '"'), '"Version":"contoso-secret-01"' }.GetNewClosure() }, @{ 'Inventory_*.json' = { param($T) $T -replace ('"Version":"' + $Ver + '"'), '"Version":3' }.GetNewClosure() }, @{ 'Diagnostics_*.log' = { param($T) $T -replace ('Tool version    : ' + $Ver), 'Tool version    : contoso-secret-01' }.GetNewClosure() }))
        {
            # Each change must change the report, or the case tests nothing.
            $Like = @($Change.Keys)[0]
            $Before = script:Read-Zip $script:PlainRun.ZipPath
            $Name = @($Before.Keys | Where-Object { $_ -like $Like })[0]
            (& $Change[$Like] $Before[$Name]) | Should -Not -BeExactly $Before[$Name] -Because "the change to $Like applies"
            $Out = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
            $Run = script:Invoke-Protect -Path (& $script:Change $Change) -Out $Out
            $Run.ExitCode | Should -Be 1
            ($Run.Text -join "`n") | Should -Not -Match 'contoso-secret'
            Test-Path -LiteralPath $Out | Should -BeFalse
        }
    }

    It 'refuses a metrics file whose list is not a Metrics list as a run writes it' {
        foreach ($Bad in '{"metrics":[]}', '{"Metrics":{"ID":"x"}}')
        {
            $Run = script:Invoke-Protect -Path (& $script:Change @{ 'Metrics_*.json' = { param($T) $Bad }.GetNewClosure() }) -Out (Join-Path $script:Work ([guid]::NewGuid().ToString('N')))
            $Run.ExitCode | Should -Be 1 -Because $Bad
            ($Run.Text -join "`n") | Should -Match 'cannot be read whole, or is not the shape a run writes'
        }
    }

    It 'refuses a report zip with no metrics file, which every run writes' {
        $R = & $script:Change @{}
        $Archive = [System.IO.Compression.ZipFile]::Open($R, 'Update')
        try { @($Archive.Entries | Where-Object { $_.Name -like 'Metrics_*' }) | ForEach-Object { $_.Delete() } } finally { $Archive.Dispose() }
        $Out = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
        $Run = script:Invoke-Protect -Path $R -Out $Out
        $Run.ExitCode | Should -Be 1
        ($Run.Text -join "`n") | Should -Match 'no metrics file'
        Test-Path -LiteralPath $Out | Should -BeFalse
    }

    It 'checks UTF-8 in bounded chunks: a character cut by a chunk edge is valid, a bad sequence cut by one is not' {
        $File = Join-Path $script:Work ([guid]::NewGuid().ToString('N') + '.txt')
        # 'abc' + e-acute (C3 A9) + 'def': chunks of 4 bytes cut the character in two (C3 | A9 d e).
        [IO.File]::WriteAllBytes($File, [byte[]](0x61, 0x62, 0x63, 0xC3, 0xA9, 0x64, 0x65, 0x66))
        Test-RdaStrictUtf8File -Path $File -ChunkBytes 4 | Should -BeTrue
        Test-RdaStrictUtf8File -Path $File -ChunkBytes 1 | Should -BeTrue
        # C3 then 28 is not a character; C3 at the end of the file is a cut one.
        [IO.File]::WriteAllBytes($File, [byte[]](0x61, 0x62, 0x63, 0xC3, 0x28, 0x64))
        Test-RdaStrictUtf8File -Path $File -ChunkBytes 4 | Should -BeFalse
        [IO.File]::WriteAllBytes($File, [byte[]](0x61, 0xC3))
        Test-RdaStrictUtf8File -Path $File -ChunkBytes 1 | Should -BeFalse
        # A file of a few MB in the default chunks, a bad byte past the first chunk.
        $Big = [byte[]]::new(3MB); [Array]::Fill($Big, [byte]0x41); $Big[2MB + 5] = 0xFF
        [IO.File]::WriteAllBytes($File, $Big)
        Test-RdaStrictUtf8File -Path $File | Should -BeFalse
        $Big[2MB + 5] = 0x41; [IO.File]::WriteAllBytes($File, $Big)
        Test-RdaStrictUtf8File -Path $File | Should -BeTrue
        Remove-Item -LiteralPath $File -Force
    }

    It 'refuses an unzipped bundle whose outer RunSummary.log holds a byte that is not valid UTF-8' {
        $Folder = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Folder | Out-Null
        Copy-Item -LiteralPath $script:PlainRun.ZipPath -Destination $Folder
        [IO.File]::WriteAllBytes((Join-Path $Folder 'RunSummary.log'), [byte[]](0x52, 0xC3, 0x28))
        $Out = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
        $Run = script:Invoke-Protect -Path $Folder -Out $Out
        $Run.ExitCode | Should -Be 1
        ($Run.Text -join ' ') | Should -Match 'not valid UTF-8'
        Test-Path -LiteralPath $Out | Should -BeFalse
        { Test-RdaStrictUtf8File -Path (Join-Path $Folder 'RunSummary.log') -ChunkBytes 0 } | Should -Throw
        { Test-RdaStrictUtf8File -Path (Join-Path $Folder 'RunSummary.log') -ChunkBytes 67108865 } | Should -Throw
    }

    It 'refuses a report with a byte that is not valid UTF-8, in any text file, instead of rewriting it as U+FFFD' {
        foreach ($Like in 'Consumption_*.csv', 'Inventory_*.json', 'ResourcesReport_*.html')
        {
            $Copy = Join-Path $script:Work ([guid]::NewGuid().ToString('N') + '.zip')
            Copy-Item -LiteralPath $script:PlainRun.ZipPath -Destination $Copy
            $Archive = [System.IO.Compression.ZipFile]::Open($Copy, 'Update')
            try
            {
                $Entry = @($Archive.Entries | Where-Object { $_.Name -like $Like })[0]
                $Ms = [IO.MemoryStream]::new(); $In = $Entry.Open(); $In.CopyTo($Ms); $In.Dispose()
                $Bytes = $Ms.ToArray() + [byte[]](0xC3, 0x28)
                $Name = $Entry.FullName; $Entry.Delete()
                $Out = $Archive.CreateEntry($Name).Open(); $Out.Write($Bytes, 0, $Bytes.Length); $Out.Dispose()
            }
            finally { $Archive.Dispose() }
            $Run = script:Invoke-Protect -Path $Copy -Out (Join-Path $script:Work ([guid]::NewGuid().ToString('N')))
            $Run.ExitCode | Should -Be 1 -Because $Like
            ($Run.Text -join ' ') | Should -Match 'not valid UTF-8' -Because $Like
        }
    }

    It 'masks a report whose tag value is also an Azure word written in a field no run masks' {
        $M = & $script:Masked (& $script:Change @{ 'Inventory_*.json' = { param($T) $T -replace '"Value":"cc-demo"', '"Value":"standard_d2s_v3"' } })
        $Inv = ConvertFrom-RdaJsonText -Text $M.Members[@($M.Members.Keys | Where-Object { $_ -like 'Inventory_*' })[0]]
        @($Inv['VirtualMachines'] | ForEach-Object { $_['Size'] }) | Should -Contain 'standard_d2s_v3'
    }

    It 'links a VM to its scale set when the plain run''s scale set collector failed, as the run''s pull held the set' {
        $Zip = & $script:Change @{
            'ResourcesReport_*.html' = { param($T) $T -replace '<body>', '<body><div class="coverage-banner"><span class="coverage-icon">&#9888;</span><div><b>Incomplete collection:</b> 1 resource type(s) could not be collected and are MISSING from this report - not empty because there are none, but because the collector errored: <code>VMSS</code>. See the Diagnostics log in this bundle for the underlying error, then re-run.</div></div>' }
            'Inventory_*.json' = { param($T) $Inv = ConvertFrom-RdaJsonText -Text $T -OrderedRoot; $Inv['VMSS'] = @(); ConvertTo-Json -InputObject ([pscustomobject]$Inv) -Depth 99 -Compress }
            'Diagnostics_*.log' = { param($T) $T -replace 'Collector failures: 0', ("Collector failures: 3`n  [sub <guid>] VMSS: an earlier subscription's failure`n  [sub <guid>] AKS: another subscription's failure`n  [sub <guid>] VMSS: the collector stopped") }
        }
        $M = & $script:Masked $Zip
        $Inv = ConvertFrom-RdaJsonText -Text $M.Members[@($M.Members.Keys | Where-Object { $_ -like 'Inventory_*' })[0]]
        @($Inv['VMSS']).Count | Should -Be 0
        $Sets = @($Inv['VirtualMachines'] | Where-Object { $null -ne $_['Set'] } | ForEach-Object { $_['Set'] })
        $Sets.Count | Should -BeGreaterThan 0
        foreach ($Set in $Sets) { $Set | Should -Match (Get-RdaMaskedIdPattern); $M.Dict.ResourceIdMap[$Set] | Should -Match '/virtualmachinescalesets/' }
        $Diag = $M.Members[@($M.Members.Keys | Where-Object { $_ -like 'Diagnostics_*' })[0]]
        $Diag | Should -Match 'Collector failures: 3'
        $Diag | Should -Not -Match 'the collector stopped' -Because 'a failure message can name a resource the report does not hold'
        # The failure the page names is this subscription's (its token); the other one, from an
        # earlier subscription of the worker, stays <guid>, as a run writes a subscription it does not know.
        $SubToken = @($M.Dict.SubscriptionNameMap.Keys)[0]
        # The log lists the worker's earlier subscriptions first: the module's last entry is this one's.
        $VmssLines = @($Diag -split "`r?`n" | Where-Object { $_ -match '\] VMSS:' })
        $VmssLines[0] | Should -Match '\[sub <guid>\]'
        $VmssLines[1] | Should -Match ('\[sub {0}\]' -f [regex]::Escape($SubToken))
        $Diag | Should -Match '\[sub <guid>\] AKS:'
    }

    It 'does not take a failure its page does not name (a stream worker''s log lists other subscriptions'' failures too)' {
        $Zip = & $script:Change @{
            'Inventory_*.json' = { param($T) $Inv = ConvertFrom-RdaJsonText -Text $T -OrderedRoot; $Inv['VMSS'] = @(); ConvertTo-Json -InputObject ([pscustomobject]$Inv) -Depth 99 -Compress }
            'Diagnostics_*.log' = { param($T) $T -replace 'Collector failures: 0', ("Collector failures: 1`n  [sub <guid>] VMSS: stopped on vmss-other-01") }
            # Nor a metric of the set, which would show the run's pull held it.
            'Metrics_*.json' = { param($T) $Mx = ConvertFrom-RdaJsonText -Text $T; ConvertTo-Json -InputObject ([pscustomobject]@{ Metrics = @($Mx['Metrics'] | Where-Object { $_['ID'] -notmatch '/virtualmachinescalesets/' }) }) -Depth 10 -Compress }
        }
        $M = & $script:Masked $Zip
        $Inv = ConvertFrom-RdaJsonText -Text $M.Members[@($M.Members.Keys | Where-Object { $_ -like 'Inventory_*' })[0]]
        @($Inv['VirtualMachines'] | Where-Object { $null -ne $_['Set'] } | ForEach-Object { $_['Set'] }) | Should -Be @('obfuscated') -Because 'the set is no row of this report and its collector did not fail for this report'
        ($M.Members.Values -join "`n") | Should -Not -Match 'vmss-other-01'
    }
}

Describe 'Get-RdaFullIdInValue' {
    It 'finds a full id in any text inside a value, in each form, and walks a large metric list fast' {
        $Id = '/subscriptions/0fa1c2d3-0000-4000-8000-00000000abcd/resourcegroups/rg-x/providers/microsoft.compute/disks/disk-x'
        $Value = @{ A = "($Id)"; B = @("u=https://h$($Id)?api-version=1", 7, $null); C = @{ D = [uri]::EscapeDataString($Id) }; E = $Id.Substring(1) + '#frag' }
        $Found = @(Get-RdaFullIdInValue -Value $Value)
        $Found.Count | Should -Be 4
        @($Found | Sort-Object -Unique) | Should -Be @($Id)
        # A group name with parentheses, and an id encoded twice.
        $Paren = '/subscriptions/0fa1c2d3-0000-4000-8000-00000000abcd/resourcegroups/rg(1)/providers/microsoft.compute/disks/disk-y'
        @(Get-RdaFullIdInValue -Value @("see ($Paren) now")) | Should -Be @($Paren)
        @(Get-RdaFullIdInValue -Value @([uri]::EscapeDataString([uri]::EscapeDataString($Id)))) | Should -Contain $Id
        $Four = $Id; for ($k = 0; $k -lt 11; $k++) { $Four = [uri]::EscapeDataString($Four) }
        @(Get-RdaFullIdInValue -Value @($Four)) | Should -Contain $Id
        # An id used as a key.
        @(Get-RdaFullIdInValue -Value @{ Identities = @{ $Id = @{} } }) | Should -Contain $Id
        $Records = @(for ($i = 0; $i -lt 1000; $i++) { @{ ID = $Id; Metric = 'Percentage CPU'; MetricSeries = [object[]][double[]](1..720) } })
        $Watch = [System.Diagnostics.Stopwatch]::StartNew()
        @(Get-RdaFullIdInValue -Value $Records).Count | Should -Be 1000
        $Watch.Elapsed.TotalSeconds | Should -BeLessThan 5
    }

    # A tenant-scope id ('/providers/<namespace>/<type>/<name>...': a management group, a
    # reservation) has no subscription, so it is found by its own form, in the same forms.
    It 'finds a tenant-scope id in any text inside a value, in each form, and not the provider part of a subscription id again' {
        $Mg = '/providers/Microsoft.Management/managementGroups/mg-secret-01'
        $Res = '/providers/Microsoft.Capacity/reservationOrders/order-01/reservations/res-01'
        $Value = @{ A = "($Mg)"; B = @("u=https://management.azure.com$($Res)?api-version=1", 7, $null); C = @{ D = [uri]::EscapeDataString($Mg) }; E = $Res.Substring(1) + '#frag' }
        $Found = @(Get-RdaFullIdInValue -Value $Value)
        $Found.Count | Should -Be 4
        @($Found | Sort-Object -Unique) | Should -Be @($Res, $Mg)
        $Twice = $Mg; for ($k = 0; $k -lt 3; $k++) { $Twice = [uri]::EscapeDataString($Twice) }
        @(Get-RdaFullIdInValue -Value @($Twice)) | Should -Contain $Mg
        @(Get-RdaFullIdInValue -Value @{ Scopes = @{ $Mg = @{} } }) | Should -Contain $Mg -Because 'an id used as a key'
        # A subscription id is found once, whole: the '/providers/...' part inside it is not a second id.
        $Sub = '/subscriptions/0fa1c2d3-0000-4000-8000-00000000abcd/resourcegroups/rg(1)/providers/microsoft.compute/virtualmachines/vm-x/providers/microsoft.insights/diagnosticsettings/ds-x'
        @(Get-RdaFullIdInValue -Value @("see $Sub and $Mg")) | Should -Be @($Sub, $Mg)
        # A text with the word only, or a provider path with no name, holds no id.
        @(Get-RdaFullIdInValue -Value @('the providers/vendors list', '/providers/Microsoft.Insights/metricDefinitions', 'providers')).Count | Should -Be 0
    }
}

Describe 'Test-RdaAzureWordCandidate' {
    It 'takes no value that holds a tenant-scope id, in any form, as one of Azure''s words' {
        foreach ($V in '/providers/Microsoft.Management/managementGroups/mg-secret-01', ('https://h/x?scope=' + [uri]::EscapeDataString('/providers/Microsoft.Management/managementGroups/mg-secret-01')), 'https://management.azure.com/providers/Microsoft.Capacity/reservationOrders/order-01?api-version=1')
        {
            Test-RdaAzureWordCandidate $V | Should -BeFalse -Because $V
        }
        Test-RdaAzureWordCandidate 'Standard_D2s_v3' | Should -BeTrue -Because 'a SKU is Azure''s word'
        Test-RdaAzureWordCandidate '/providers/Microsoft.Insights/metricDefinitions' | Should -BeTrue -Because 'a provider path with no name holds no id'
    }
}

Describe 'Protect-RdaReport.ps1 writes the rows whose usage is not counted as a live -Obfuscate run writes them' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Helpers/SyntheticReportZip.ps1')
        # The same estate with one usage row of a negative quantity, one with an empty MeterId
        # and one with no InstanceData (an empty ResourceId).
        $script:PlainOdd = New-RdaSyntheticReportZip -RepoRoot $script:RepoRoot -TestsRoot $PSScriptRoot -Plain -DroppedRows
        $script:LiveOdd = New-RdaSyntheticReportZip -RepoRoot $script:RepoRoot -TestsRoot $PSScriptRoot -DroppedRows
        $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('RdaProtectOdd_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Work | Out-Null
        $script:OddOut = Join-Path $script:Work 'masked'
        $script:OddRun = script:Invoke-Protect -Path $script:PlainOdd.ZipPath -Out $script:OddOut
        $Folder = @(Get-ChildItem -LiteralPath $script:OddOut -Directory -ErrorAction SilentlyContinue)[0]
        $script:OddZip = if ($null -ne $Folder) { @(Get-ChildItem -LiteralPath $Folder.FullName -Filter 'ResourcesReport_*.zip')[0].FullName } else { $null }
        $script:OddDict = if ($null -ne $Folder) { @(Get-ChildItem -LiteralPath $Folder.FullName -Filter 'ObfuscationDictionary_*.json')[0].FullName } else { $null }
        # The consumption CSV text of a report zip.
        $script:CsvText = {
            param([string]$Zip)
            $M = script:Read-Zip $Zip
            $M[@($M.Keys | Where-Object { $_ -like 'Consumption_*.csv' })[0]]
        }
    }
    AfterAll {
        Remove-RdaTestReportZip $script:PlainOdd
        Remove-RdaTestReportZip $script:LiveOdd
        if ($script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'gives the same bytes for a row with <Label>, tokens aside, and the same values through each side''s dictionary' -ForEach @(
        @{ Label = 'a negative Quantity'; Pick = { param($R) $R.Quantity -eq '-24' } }
        @{ Label = 'an empty MeterId'; Pick = { param($R) $R.MeterId -eq '' } }
        @{ Label = 'an empty ResourceId'; Pick = { param($R) $R.ResourceLocation -eq '' } }
    ) {
        $script:PlainOdd.Exit | Should -Be 0 -Because $script:PlainOdd.Console
        $script:LiveOdd.Exit | Should -Be 0 -Because $script:LiveOdd.Console
        $script:OddRun.ExitCode | Should -Be 0 -Because ($script:OddRun.Text -join ' | ')
        $Lines = @{}
        $Index = @{}
        foreach ($Side in 'Live', 'Offline')
        {
            $Zip = if ($Side -eq 'Live') { $script:LiveOdd.ZipPath } else { $script:OddZip }
            $Text = & $script:CsvText $Zip
            $Lines[$Side] = @($Text -split "`r?`n" | Where-Object { $_ -ne '' })
            $Rows = @($Text | ConvertFrom-Csv)
            $Index[$Side] = @(for ($I = 0; $I -lt $Rows.Count; $I++) { if (& $Pick $Rows[$I]) { $I } })
            $Index[$Side].Count | Should -Be 1 -Because "the $Side report holds one row with $Label"
        }
        $Index['Offline'][0] | Should -Be $Index['Live'][0] -Because 'the row keeps its place'
        $Lines['Offline'][0] | Should -BeExactly $Lines['Live'][0] -Because 'the header is the run''s'
        # The same bytes, each token (the two sides' tokens differ by design) written as <t>.
        $T = (Get-RdaTokenPattern).TrimStart('^').TrimEnd('$')
        $Bytes = foreach ($Side in 'Live', 'Offline') { , [Text.Encoding]::UTF8.GetBytes(($Lines[$Side][$Index[$Side][0] + 1] -replace $T, '<t>')) }
        [Convert]::ToBase64String($Bytes[1]) | Should -BeExactly ([Convert]::ToBase64String($Bytes[0])) -Because ('offline = live for a row with ' + $Label)
        # Every other line too: the header and each row, the same bytes, tokens aside.
        $Lines['Offline'].Count | Should -Be $Lines['Live'].Count -Because 'both files hold the same rows'
        for ($L = 0; $L -lt $Lines['Live'].Count; $L++)
        {
            ($Lines['Offline'][$L] -replace $T, '<t>') | Should -BeExactly ($Lines['Live'][$L] -replace $T, '<t>') -Because ('offline = live on line {0} of the consumption file' -f ($L + 1))
        }
        # And through each side's own dictionary, the same values.
        $Live = script:Get-UnmaskedReport $script:LiveOdd.ZipPath $script:LiveOdd.DictionaryPath
        $Offline = script:Get-UnmaskedReport $script:OddZip $script:OddDict
        script:ConvertTo-SortedJson $Offline['Consumption'][$Index['Offline'][0]] | Should -BeExactly (script:ConvertTo-SortedJson $Live['Consumption'][$Index['Live'][0]])
    }

    It 'names each kind with its count, by row number and masked id only' {
        $Text = @($script:OddRun.Text)
        $Rows = @((& $script:CsvText $script:OddZip) | ConvertFrom-Csv)
        # The row with no InstanceData has no id: it is named "no id", never by the id the
        # mask writes for it.
        foreach ($Kind in @(@{ Text = 'a negative Quantity'; Row = 1 }, @{ Text = 'an empty MeterId'; Row = 2 }, @{ Text = 'an empty ResourceId'; Row = $Rows.Count; Id = 'no id' }))
        {
            $Line = @($Text | Where-Object { $_ -like ('  1 row has {0}: *' -f $Kind.Text) })
            $Line.Count | Should -Be 1 -Because ($Text -join ' | ')
            $Id = if ($Kind.Id) { $Kind.Id } else { $Rows[$Kind.Row - 1].ResourceId }
            $Line[0] | Should -BeExactly ('  1 row has {0}: row {1} ({2})' -f $Kind.Text, $Kind.Row, $Id)
        }
        $Rows[$Rows.Count - 1].ResourceLocation | Should -Be '' -Because 'the last row is the one with no InstanceData'
        $Named = ($Text | Where-Object { $_ -match 'row has|is not counted' }) -join "`n"
        foreach ($Real in 'rg-demo', '12345678-1234-1234-1234-123456789012', 'vm-demo', 'osdisk-vm-demo', 'Consumption_') { $Named.Contains($Real) | Should -BeFalse -Because "'$Real' is a real value or a file name" }
    }

    It 'has a live run, plain and masked, count and name those rows too, as it writes them unchanged' {
        foreach ($Run in $script:PlainOdd, $script:LiveOdd)
        {
            $Run.Console | Should -Match 'Consumption for [^\r\n]+: 1 written row\(s\) have a negative Quantity, 1 an empty MeterId and 1 an empty ResourceId\. They are written as Azure gave them, but their usage is not counted' -Because $Run.Console
        }
    }
}
