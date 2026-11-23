# Consumption (billing/usage) data — how it works

This document explains how Resource Discovery for Azure (RDA) collects the
consumption data that lands in `Consumption_<ReportName>_<timestamp>.csv`, what
each column means, what is deliberately **not** included, how it is obfuscated,
and how to recover a subscription whose consumption pull failed partway through.

The consumption phase runs unless you pass `-SkipConsumption`.

## Where the data comes from

RDA calls the Azure Billing cmdlet **`Get-UsageAggregates`** (from the
`Az.Billing` module). This returns metered **usage quantities**, not billed
cost (see [What is NOT included](#what-is-not-included)).

Per subscription, the collector:

- Sets the time window to the **last 31 days, ending at the start of yesterday**
  (`ReportedStartTime = today − 31 days`, `ReportedEndTime = yesterday`, both
  floored to midnight).
- Requests **`Daily`** aggregation granularity with **`ShowDetails = $true`**
  (so per-resource instance data is included).
- Pages through the results using the API's **`ContinuationToken`** until there
  are no more pages.
- Writes each page to the CSV as it goes (`Export-Csv -Append`), so rows are
  flushed incrementally rather than held in memory to the end.

### Authentication pre-check

Before paging, the phase verifies a usable Azure context/token exists
(`Test-DataPlaneAuthReady`). `Get-UsageAggregates` silently returns **zero**
records when the token is missing, which would otherwise leave an empty
consumption sheet that looks like "this tenant has no billing data." If the
check fails, RDA attempts **one** reconnect; if that still fails it logs a loud
error, records the subscription in the run health, and skips only the
consumption phase (the rest of the inventory continues).

### Transient-failure retry

Each page request is wrapped in a bounded retry (**3 attempts, exponential
backoff**). A single transient HTTP error — e.g. `Error while copying content to
a stream`, a timeout, or 429/503 throttling — retries the **same** page (the
previous page's `ContinuationToken` is preserved), so no rows are duplicated or
skipped. A permanent error exhausts the retries and is handled by the
per-subscription failure path (see [Recovering from a consumption
crash](#recovering-from-a-consumption-crash)).

## The columns

The CSV has 15 columns. Ten come straight from each usage-aggregation record;
five are derived from the `InstanceData` JSON on each record.

| Column | Source | Meaning |
|--------|--------|---------|
| `InstanceData` | usage record (re-serialized) | JSON blob describing the resource the usage belongs to (`Microsoft.Resources.resourceUri`, `location`, `additionalInfo`). Under `-Obfuscate` this is the obfuscated form. |
| `MeterCategory` | usage record | Top-level meter grouping, e.g. `Virtual Machines`, `Storage`, `Stream Analytics`. |
| `MeterId` | usage record | Azure's global meter GUID. Same for every customer using that meter — **not** customer-specific. |
| `MeterName` | usage record | Specific meter, e.g. `Standard Streaming Unit`, `P10 Disks`. |
| `MeterRegion` | usage record | Region the meter applies to. |
| `MeterSubCategory` | usage record | Meter sub-grouping, e.g. `Dv2 Series`. |
| `Quantity` | usage record | **Amount of usage** in the meter's unit (not a cost). |
| `Unit` | usage record | Unit for `Quantity`, e.g. `1 Hour`, `10000 GB`. |
| `UsageStartTime` | usage record | Start of the aggregation interval. |
| `UsageEndTime` | usage record | End of the aggregation interval. |
| `ResourceId` | `InstanceData.Microsoft.Resources.resourceUri` | ARM resource URI the usage is attributed to. Under `-Obfuscate`, identifying segments are masked but the ARM path *structure* is preserved (see below). |
| `ResourceLocation` | `InstanceData.Microsoft.Resources.location` | Location of the resource. |
| `ConsumptionMeter` | `InstanceData.Microsoft.Resources.additionalInfo.ConsumptionMeter` | Meter identifier from the resource's additional info (may be empty). |
| `ReservationId` | `additionalInfo.ReservationId` | Reservation the usage was applied to, if any. Masked to `obfuscated` under `-Obfuscate`. |
| `ReservationOrderId` | `additionalInfo.ReservationOrderId` | Reservation order, if any. Masked to `obfuscated` under `-Obfuscate`. |

## What is NOT included

- **Cost / dollar amount.** `Get-UsageAggregates` returns *usage quantity*
  (`Quantity` + `Unit`), not billed cost. There is no price or spend column.
  Deriving spend requires the rate card / Cost Management APIs, which RDA does
  not call. Use `Quantity` × your negotiated rates, or Cost Management, for money
  figures.
- **A dedicated `Subscription` column.** The subscription is embedded in
  `ResourceId` (`/subscriptions/<id>/…`). In a multi-subscription run each
  subscription has its own folder/CSV, so the owning subscription is implicit.
- **Every `additionalInfo` key as its own column.** Only `ConsumptionMeter`,
  `ReservationId`, and `ReservationOrderId` are broken out. Any other
  `additionalInfo` keys remain inside the raw `InstanceData` JSON (column 1) —
  not lost, just not columnarised.

## Obfuscation of consumption data

When `-Obfuscate` is used, consumption is masked with a scheme **separate** from
the inventory obfuscation dictionary:

- `ResourceId` / `resourceUri` is rebuilt segment-by-segment. The subscription
  id, resource group name, and resource name segments are replaced with
  `prod_`/`nonprod_` tokens, but the **ARM path structure is preserved**
  (`/subscriptions/<tok>/resourcegroups/<tok>/providers/<rp>/<type>/<tok>`),
  including the resource provider and type and the `mc_` AKS-managed-RG marker.
  This lets the ingestion dashboard categorise rows (AKS, VMSS, etc.) without
  seeing real identifiers.
- The tokens use per-run caches keyed by the real value, so the same real
  sub/RG/name always maps to the same token **within a run** (deterministic).
- These caches are **independent of** the inventory `ObfuscationDictionary`.
  Consumption tokens are therefore internally consistent but do **not** equal the
  inventory tokens for the same resource — categorisation relies on the path
  structure, not an ID-to-inventory join.
- `ReservationId` and `ReservationOrderId` are flattened to `obfuscated`.

## Per-subscription health and failure-point reporting

Consumption is tracked per subscription. A subscription whose pull fails is
recorded (in `$Global:ConsumptionFailedSubs`) with:

- `Complete = $false`
- `PageAtFailure` — the paged `Get-UsageAggregates` call it stopped on
- `RecordsCollected` — how many rows were written before it stopped
- a message ending `… this subscription's consumption is INCOMPLETE`

On an obfuscated run this is surfaced in the shareable
`Diagnostics_<ReportName>_<timestamp>.log` under **"Consumption
failed/incomplete subscriptions"**, so a truncated billing sheet is obvious in
the shared bundle rather than something you have to infer from a suspiciously
round row count. Subscriptions **not** listed there collected consumption
cleanly (the loop exited because the `ContinuationToken` was exhausted).

## Recovering from a consumption crash

If a subscription's consumption is incomplete (see the diagnostics log, or a
`Complete = $false` health entry), you do not need to re-run the whole tenant.
The rows already written to the CSV up to the failed page are valid and kept —
you re-collect that subscription's consumption and splice the fresh copy back in.

**Step 1 — re-collect the subscription with consumption enabled.** Seed with the
original run's obfuscation dictionary so the recovered data lines up with the
rest of the bundle. (You can also narrow inventory with `-Service` to keep it
fast; the consumption phase runs for the whole subscription regardless of
`-Service`.)

```powershell
./ResourceInventory.ps1 `
    -TenantID <tenant> `
    -SubscriptionID <the-failed-subscription> `
    -Obfuscate `
    -ObfuscationDictionary "<original ObfuscationDictionary_*.json for that subscription>" `
    -SkipMetrics
```

On the current build the per-page retry makes the fresh pull far more likely to
complete through the transient that truncated the first attempt.

**Step 2 — splice the fresh consumption into the original bundle** with
`Merge-RecoveryData -RecoverConsumption`, which whole-file replaces the
(truncated) consumption CSV with the recovery run's copy:

```powershell
. ./Functions/RecoveryMerge.Functions.ps1
Merge-RecoveryData `
    -GapBundlePath      "<the original subscription's report folder>" `
    -RecoveryBundlePath "<the folder Step 1 produced>" `
    -OutputPath         "<a new empty folder>" `
    -RecoverConsumption
```

The rebuilt bundle has complete consumption; inventory and metrics are carried
over from the original run unchanged, the HTML report is regenerated, and a
fresh ZIP is written. `Merge-RecoveryData` returns `ConsumptionSource = recovery`
so you can confirm the replacement happened.

> Note: consumption uses the per-run token scheme described above, so the
> replaced consumption file is internally consistent and categorises correctly
> even though its tokens differ from the original run's — nothing downstream
> joins consumption tokens to inventory tokens.

See also: [Recovery and diagnostics features](recovery-and-diagnostics.md).

## Claude Marketplace file (`ClaudeMarketPlace_<ReportName>_<timestamp>.json`)

Claude models in Microsoft Foundry are sold by Anthropic through the Azure Marketplace and billed in
Claude Consumption Units (CCU). `Get-UsageAggregates`, which the Consumption file is built from, returns Azure's own meters, and on the
account checked so far these charges were not in it. On other agreement types they may be, which is why each
row says whether it is also in the Consumption file. A separate phase writes them, with the token counts Azure
Monitor keeps for the same models, to one new JSON file. The Inventory, Metrics and Consumption files are
written exactly as before; the new file is extra. The dictionary file changes only when this file masks
something the inventory did not hold (a subscription, group or resource id only the billing call saw): that
new token is added, so Reveal can undo it.

The file holds these lists and fields:

| Field | Content |
|-------|---------|
| `SchemaVersion` | `1`. |
| `Obfuscated` | `true` when the run used `-Obfuscate`. |
| `Reason` | Text that says what the file holds, or why it holds nothing or may be incomplete. |
| `RowsWindowStart`, `RowsWindowEnd` | The window of the Marketplace call, UTC. The end is the day after the last day wanted. |
| `TokenWindowStart`, `TokenWindowEnd` | The window of the token counts: whole UTC days, ending at 00:00 UTC today. |
| `ConsumptionRowsCompared` | How many Consumption rows of this run were read to compare with. |
| `OtherMarketplaceRowsSkipped` | Marketplace rows of other publishers, left out. |
| `NonClaudeTokenSeriesSkipped` | Token series of models that are not Claude, left out. |
| `Rows` | The Anthropic / Claude Marketplace rows. |
| `TokenUsage` | The Claude token counts, per account, model and metric. |
| `Errors` | Every subscription or account that could not be read. |

The file is always in the zip. With nothing to report the lists are empty and `Reason` says why:
`-SkipMarketplace` or `-SkipConsumption` was given, or the call answered with no Claude rows. An empty
answer does not show that no Claude charge exists: the endpoint serves only some agreement types and
bills some charges late.

### Rows

`Get-AzConsumptionMarketplace` (`Az.Billing`, no new module) is read per subscription. The run needs the
**Cost Management Reader** or **Billing Reader** access that the consumption phase needs. A row is kept
when its publisher starts with Anthropic. A row with no publisher at all is kept when its offer or plan holds the
word Anthropic or Claude. A row of any other publisher is left out, whatever its offer is called.

- The window is the calendar days the consumption phase read (local dates, passed as UTC dates). The usage call
  filters by when usage was reported and this call by when it happened, so a charge billed late can fall in one
  window and not the other. The cmdlet filters on usage start on or after the start date and usage end on or
  before the end date, as dates. The end date passed is the day after the last day wanted, so the last day is
  included whether a day row ends at 23:59:59 or at 00:00 of the next day. A UTC day that is still running is not asked for. The token window is always 31 whole UTC
  days, ending at 00:00 UTC today, whatever `-MetricsLookbackDays` is, and can differ from this window by a day. No `-Top` is passed because `-Top` caps the rows returned. With
  `-ResourceGroup` the cmdlet is asked for that group only.
- Fields: `PublisherName`, `OfferName`, `PlanName`, `ConsumedService`, `ConsumedQuantity`,
  `UnitOfMeasure`, `PretaxCost`, `Currency`, `IsEstimated`, `MeterId`, `UsageStart`, `UsageEnd`,
  `SubscriptionGuid`, `ResourceGroup`, `InstanceId`, `InstanceName`, `AlsoInConsumption`,
  `AlsoInConsumptionMatch`, `ResourceInConsumption`.
- `ConsumedQuantity` and `PretaxCost` are JSON numbers; a missing value is 0. `UsageStart` and `UsageEnd`
  are UTC, as `yyyy-MM-ddTHH:mm:ssZ`.
- A Claude subscription can have a row with no `MeterId` and an amount of 0 (a monthly row). It is kept.
- `AlsoInConsumption` is `true` when a row of the Consumption file of this run has the same meter id, the same
  usage day (UTC; the time written in the Consumption file is read as this machine's local time, and as UTC when that is not midnight), the same subscription and exactly the same quantity: the
  same charge. One Consumption row marks at most one Marketplace row. A Consumption row whose resource id has no
  subscription, or whose masked subscription token stands for more than one subscription, marks nothing and is
  counted as one that could not be compared. The meter id is taken to carry one unit, so the unit is not compared. `AlsoInConsumptionMatch` is then `MeterDayQuantity`,
  and otherwise `None`. The Consumption file is read once, after it is written. A row with no meter id (a
  monthly row) cannot be matched this way and reads `false`.
- `ResourceInConsumption` is `true` when any Consumption row has the same resource id. It is only a hint: a
  resource can hold its own Azure usage and a Marketplace charge, so it never sets `AlsoInConsumption`.
- Only one agreement type has been checked against a real account, where `Get-AzConsumptionUsageDetail` returned
  no Claude rows. The Consumption file is built from `Get-UsageAggregates`, which has not been checked on a Claude
  account. On other agreement types Marketplace charges may also come through the usage call. A reader that adds
  this file to the Consumption file should skip a row whose `AlsoInConsumption` is `true`. When
  `ConsumptionRowsCompared` is 0, or an `Errors` record has `Source` `Consumption`, a `false` may be wrong.
- The endpoint is deprecated and serves only some agreement types. Microsoft's
  [migration guidance](https://learn.microsoft.com/en-us/azure/cost-management-billing/automate/migrate-consumption-marketplaces-api)
  names the types it covers. For a subscription it does not serve, the call answers with an error that
  names the offer types it does serve. The run then says that Marketplace charges are not available for
  that agreement type, lists the subscription as incomplete, adds an `Errors` record and collects none for it.
- A call that fails with a 400, 401, 403 or 404 is not repeated. Any other failure is tried three more
  times. A subscription whose call fails is recorded as incomplete, and its rows are not written. The other
  subscriptions are not affected.
- `-Resume` and `-ResumeFailedOnly` do not collect the file again for a subscription that finished. Run
  that subscription again without them.

### Token counts

For each Foundry account (`Microsoft.CognitiveServices/accounts`) the run reads five Azure Monitor metrics
split by `ModelName`: `InputTokens`, `OutputTokens`, `cacheReadInputTokens`, `ephemeral5mInputTokens` and
`ephemeral1hInputTokens`. Daily totals, in whole UTC days.

- Only Claude models are written: a series is kept when its `ModelName` holds `claude`, case ignored.
  Models Microsoft sells itself are billed from their own Consumption meters, so their tokens are left out
  to avoid counting them twice. The number left out is in `NonClaudeTokenSeriesSkipped`.
- Only Foundry (`AIServices`) accounts are asked, because Claude models run there. The call asks for up to 1000 series, because
  Azure returns 10 by default. A series that is not split by model is not written; the account gets an `Errors` record.
- One record per account, model and metric: `ID`, `Subscription`, `ResourceGroup`, `Name`, `Location`,
  `ModelName`, `Metric`, `TimeGrain`, `StartTime`, `EndTime`, `Total` and `DailySeries`. `Total` and the
  daily values are whole numbers. The first daily value is the day that starts at `StartTime`. A day
  with no value is 0. A point that has no time stamp is taken in the order Azure gives it, and a point outside the
  window is left out and reported in `Errors`. A model with no tokens in the window has no record.
- The token counts are read when `-SkipMarketplace` and `-SkipConsumption` are both absent. `-SkipMetrics`
  does not skip them.
- An account Azure refuses gets one `Errors` record with `Source` `AzureMonitor`, and the run goes on.

### Under `-Obfuscate`

- `PublisherName`, `OfferName`, `PlanName` and `ModelName` stay readable. They name the product.
- `InstanceId` and a token record's `ID` are masked as resource ids, with the same subscription, group and
  name tokens as the same resource in the inventory and Consumption files. Azure writes a Marketplace
  `InstanceId` without its leading slash, and the masked id has it.
- `SubscriptionGuid` and `Subscription` get the token the other files use for that
  subscription, and `ResourceGroup` the token for that group.
- Every token made for this file that the inventory did not make is added to the dictionary file, so Reveal
  can undo it.
- An `Errors` message is a fixed sentence. The run log holds Azure's own text.

### Errors

Each `Errors` record has `Source` (`Marketplace`, `AzureMonitor`, `Consumption` for the comparison with the Consumption file, or `File` when the collection could not write the file and a file with empty lists was written instead), `Scope` (the
subscription or account) and `Message`. A failed subscription is also listed with `Marketplace` in the run
summary, the diagnostics log and the failure list printed at the end of a wrapper run.

The recovery merge carries this file from the bundle its consumption file comes from. A bundle without one
gives a merge warning. A carried file that is cut short or has a wrong field or type stops the merge, so a
broken file is not shipped.
