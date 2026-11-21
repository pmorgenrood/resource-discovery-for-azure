# Mask a finished plain report offline (`Protect-RdaReport.ps1`)

A run without `-Obfuscate` writes real names and ids. To share such a report masked, you do not
need to collect again: `Protect-RdaReport.ps1` masks the finished report on your machine. It needs no
Azure sign-in and makes no Azure call.

```powershell
./Protect-RdaReport.ps1 -Path ~/InventoryReports/AllSubscriptions_ResourcesReport_<timestamp>.zip
```

`-Path` takes the consolidated `AllSubscriptions_ResourcesReport_*.zip`, one
`ResourcesReport_*.zip`, or a folder that holds `ResourcesReport_*.zip` files (an unzipped
consolidated zip). `-OutputDirectory` is a new or empty folder; by default it is next to `-Path`,
named `<name of -Path>_masked`.

## What it writes

The same layout a `-Obfuscate` run leaves in its inventory folder:

| File | Share it? |
|---|---|
| `<OutputDirectory>/AllSubscriptions_ResourcesReport_<timestamp>.zip` (the name of `-Path` when it is the name a run gives one, else a new one with the time of the mask) | Yes: this is the masked report |
| `<OutputDirectory>/ResourcesReport<stamp>/ResourcesReport_<stamp>.zip` | Yes (it is also inside the consolidated zip) |
| `<OutputDirectory>/ResourcesReport<stamp>/ObfuscationDictionary_ResourcesReport_<stamp>.json` | No: it maps the tokens back to the real values |

Every report keeps its file names and members. The masking is the `-Obfuscate` run's own code
(`Add-RdaObfuscationToken`, `Protect-RdaCollectorRow`, `Protect-RdaMetricRecord`,
`Protect-RdaUsageRow` and `Get-RdaObfuscationDictionary`, loaded from `ResourceInventory.ps1` and
`Extension/Metrics.ps1`), so ids keep their ARM shape, one real value gets one token in every file
of a report, links between rows hold, and the prod/nonprod prefixes come from the same words. As in a
`-Obfuscate` run, each subscription's report has its own tokens and its own dictionary, and the tokens
are new each time. The consumption `InstanceData` column changes only its `ResourceUri`.

The collector fields that a `-Obfuscate` run writes from Azure's data (a cross-reference to another
resource, a free-text field, a field written as `obfuscated`) are listed in
`Get-RdaOfflineFieldRule` (`Functions/OfflineObfuscation.Functions.ps1`), each from its plain value.
A test reads every collector and fails when a collector masks a field that list does not name.

To map the masked report back: `./Reveal.ps1 -InventoryRoot <OutputDirectory>`.

## When it stops

It stops with exit code `1` and leaves nothing behind when:

- the report is already masked (an id, name or log of it is masked);
- a file cannot be read whole (a cut-off inventory, metrics or consumption file, report page, run summary,
  diagnostics log or main summary), or the main summary's failure counts do not fit the run summary's;
- the report holds a file it does not know how to mask, or text a run does not write where it is (a
  phase or collector name the code has not, a line of a summary not in the writer's form);
- a masked field, or any file it wrote, still holds a real name or id of the report;
- a consumption row's masked id is not the one a run writes: every name part of it (the subscription, the group and
  each name) must be a token, as a run's own shape check reads it, or one flat token for an id that is not an ARM
  path. Each name part must also differ, in any case, from the plain id's part in that place, which does not rest on
  the shape check. This is checked for each row's id after the row is masked, because the leak scan does not look for a short
  name of letters only, or Azure's fixed name `$system`, inside a text.

Its messages print no value from the report. Exit code `2` means `-Path` was not found, a script file
the mask needs is missing, `-OutputDirectory` is not empty, is a drive or share root, or is inside a folder given
as `-Path` (or holds it).

The mask writes into a work folder beside the output folder, `<OutputDirectory>.rda-work-<id>`, and
moves the result into `-OutputDirectory` only once every check has passed; it removes the work folder
when it ends. A mask that is killed (the process ended from outside) cannot remove it: that folder then
holds plain copies of the report, so delete it.

## How it differs from a `-Obfuscate` run

- An App Service's `SiteProperties` is masked part by part by the same function a `-Obfuscate` run uses (see
  docs/obfuscation-and-unmask.md); its keys can come out in another order, as the plain report is read without
  their order. Nothing reads the field or the order.
- Like a `-Obfuscate` run, it copies the words Azure writes in fields no run masks (a size, a region, an id's
  provider and type words such as `microsoft.compute/virtualmachines`). It checks those words have Azure's form.
  An id whose last segment is the word `$system` with no name after it (`.../namespaces/<namespace>/$system`)
  is refused like any other word that is not of that form: it is an id form this tool does not support. No
  fixture or captured billing row shows Azure billing it, and downstream reads an id's last segment as the
  resource's name, so how to mask it is with the owner; the mask stops on such a usage row and says so. Its leak scan
  finds one that is a name, group or subscription of the report of at least 5 characters that is 12 or
  more long or holds a digit, and is not equal to or inside a value of a field no run masks. A shorter or letters-only one (a group
  `rg1` or `finance` written as a type word) is not found: no offline check can tell a word of Azure's form from
  Azure's own.
- The leak scan finds a value only as a whole word. A value of digits only is also not found inside a number:
  next to a `.` or `,` that has a digit on its far side, with no letter in the run of letters, digits, `.` and `,`
  around it (`0.4500123`, `4500123.25`), as Azure writes quantities. Otherwise (`4500123.blob.core.windows.net`,
  `storage1.4500123.blob`, `4500123.25abc`, `4500123, failed`) it is found.
- The leak scan reads each file twice: as written, and with its URL escapes decoded level by level, up to 32 levels,
  as `[uri]::UnescapeDataString` decodes one (`%2F`, `%252F`, `%28`, and a UTF-8 character's escapes such as
  `%C3%A9`, nested or not), so a real value inside an encoded URL is found as if written plain. The full-id search
  decodes a field the same way. A value is also looked for as ConvertTo-Json writes it (`\n`; its `\uXXXX` covers
  control characters only, so `caf\u00e9` written by another tool is not read as the letter) and with a space written
  as `+`. Each level of decoding is read on its own, so a value that reads plain at one level only is found. Limit: an escape of a byte that is no UTF-8 character (`%A0`, a Latin-1 form) stays as written,
  so a value glued to it is not found in that reading; Azure writes UTF-8.
- Any full id (`/subscriptions/...`, with or without its first `/`, or URL-encoded) in any field of the plain report,
  a field no rule masks too, is a real value:
  its subscription, group and name parts must not be in the masked report, or it is refused.
- A record of a subscription the report names nowhere (no display name on any record, and none on the page) is
  refused: the run's token loop would not give its id a token, so the id could not keep its ARM shape.
- A `-Obfuscate` run times one more phase, the network id query for masked ids; a plain run does not,
  so the masked diagnostics log and report page list one phase fewer than a `-Obfuscate` run's.
- One rule covers every reference the plain report cannot tie to exactly one resource it holds: it is
  written `obfuscated`, the value a `-Obfuscate` run writes for a resource it does not know. Where the
  run's Azure pull held that resource, the run would have written its token instead. The cases:
  - a field that names a resource by its name only, when the report holds no row of that name, or
    several (a disk's VM, an availability set's VMs, a Machine Learning workspace's storage account,
    key vault, insights or registry, a scale set's container cluster). One of these is read:
    a disk's `AssociatedResource`, matched to its VM's id, so such a disk is not linked to its VM;
  - a Front Door's WAF policies, always (no report section holds them; the field is a label);
  - an id field that points at a resource the report holds no row of (a deleted disk, a resource of a
    type no collector reports). When the page of the plain report names the collector of that
    resource as failed, the ids are masked as the run masks them, since the run's pull held them.

  The script prints how many references it wrote `obfuscated` per field.
- The dictionary holds the report's resources only, not every resource the run read from Azure.
- The report pages and logs are written again from the masked data: the report HTML by
  `Extension/Summary.ps1`, the diagnostics log by `Write-RdaShareableDiagnosticsLog`, and the
  consolidated zip's `RunSummary.log` and `MainSummary.html` by the wrapper's own functions, from the
  counts the plain files hold. They show no run time a plain report does not hold, and an obfuscated
  run's network id query time is not there. A run time in minutes on a report page is written in this machine's
  decimal mark, which can differ from the collecting machine's (`1.44` or `1,44`). A failure's message in the diagnostics log is never kept, by a run or by this script
  (it can name a resource the report does not hold, or carry a credential); the log keeps the collector, the subscription token, the count and
  closed-list facts of the error object only: its .NET exception type (only from an exact list of common types), an HTTP status number, an Azure error code on a fixed list
  (`$Global:RdaDiagnosticErrorCodes`) and, for a consumption pull, the page and record count where it stopped. A plain log written before
  this change has the message text; its text is dropped and no facts are read from it.
