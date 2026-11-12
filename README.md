# Azure Resource Discovery Tool

## Overview

The Azure Resource Discovery Tool is a PowerShell script that generates comprehensive inventory reports of your Azure environment. This AWS-provided script creates detailed reports including resource metrics, usage statistics, and performance data from the previous 31 days.

This tool leverages read-only integrations with Azure APIs and Azure Monitor. Our goal is to deliver a reliable and efficient solution for Azure environment reporting, empowering you with comprehensive insights into your cloud resources and their utilization.

**Key Features:**
- Read-only Azure API integration
- Automated self-contained HTML and JSON report generation (no Excel/ImportExcel dependency)
- 31-day historical metrics collection
- Parallel processing for improved performance
- Support for [Azure Cloud Shell](https://shell.azure.com "Open Azure Cloud Shell") and local PowerShell environments

## Quick Start

For most users, this is everything you need.

**1. Open Azure Cloud Shell** at [shell.azure.com](https://shell.azure.com), or run a local PowerShell 7 prompt with the [prerequisites](#prerequisites) installed.

The tool needs Az PowerShell only: PowerShell 7 and the four Az submodules `Az.Accounts`, `Az.Compute`, `Az.Monitor` and `Az.Billing`. The Azure CLI is not needed and is not used. On a local machine, sign in with `Connect-AzAccount -Tenant <tenant>` first, or let the script sign you in.

**2. Download the script:**

```powershell
git clone https://github.com/awslabs/resource-discovery-for-azure.git
cd resource-discovery-for-azure
```

**3. Run it:**

```powershell
./Run-AllSubscriptions.ps1 -TenantID "contoso.onmicrosoft.com"
```

This:
- Inventories every enabled subscription in the tenant.
- Produces a full-fidelity report with real resource names and IDs. If you need to share it externally (e.g. with the AWS team), add `-Obfuscate` to mask identifying details first — see [Obfuscation Mode](#obfuscation-mode).
- Automatically tunes how many subscriptions run in parallel to the machine's CPU and memory: small boxes (e.g. 2 vCPU) run one subscription at a time, larger boxes scale up. Add `-ParallelStreams <N>` (and/or `-ConcurrencyLimit <N>`) only if you want to override the auto-detected values.

The script tracks progress automatically as it goes. You don't need `-Resume` on the first run. Only if a run is interrupted (network drop, Cloud Shell session timeout, accidental Ctrl+C), re-run the same command with `-Resume` added — it skips the subscriptions that already finished and picks up the rest. See [Resuming an interrupted run](#resuming-an-interrupted-run) for details.

You'll find the consolidated report at `InventoryReports/AllSubscriptions_ResourcesReport_<timestamp>.zip`. This report contains real resource names and IDs. Before sharing it externally (e.g. with the AWS team), re-run with `-Obfuscate` to mask identifying details — see [Obfuscation Mode](#obfuscation-mode). You can also selectively un-mask an obfuscated report with `Reveal.ps1` if the recipient needs specific fields.

For larger tenants (100+ subscriptions), see [Choosing where to run](#choosing-where-to-run-for-large-tenants-cloud-shell-vs-local) for sizing guidance. For all available options, see the [Run-AllSubscriptions Wrapper Parameters](#run-allsubscriptions-wrapper-parameters).

## Table of Contents

- [Quick Start](#quick-start)
- [Prerequisites](#prerequisites)
- [Getting Started](#getting-started)
- [Usage](#usage)
- [Output Files](#output-files)
- [Parameters Reference](#parameters-reference)
- [Troubleshooting](#troubleshooting)

## Prerequisites

### Required Azure Roles

Before running the script, ensure your Azure user account has the following roles assigned:

- **✅ Reader Role** - Access to view Azure resources
- **✅ Billing Reader Role** - Access to billing data
- **✅ Monitoring Reader Role** - Access to Azure Monitor metrics

Reader (or any role that can read every resource type) is needed **on each subscription, or above it**. A custom role that leaves out reading some resource types (for example `*/read` with the not-action `Microsoft.Compute/*/read`) is not enough on its own and stops the run. Reader on only some resource groups stops a whole-subscription run; for one resource group, run `ResourceInventory.ps1` with `-SubscriptionID` and `-ResourceGroup` (see [Targeting a single subscription or resource group](#targeting-a-single-subscription-or-resource-group)).

Consumption (usage) data needs the permission `Microsoft.Commerce/UsageAggregates/read` on every subscription in the run, granted at the subscription or above (a role on a resource group does not return usage). The built-in **Reader** and **Billing Reader** roles include it. **Cost Management Reader does not**, so it is not enough for consumption data on its own.

Before any other work, the run checks the signed-in identity's roles on every subscription, then (when consumption is requested) that usage values come back, and stops with exit code 1 if either fails (see [Subscription access check](#subscription-access-check-up-front) and [Consumption data check](#consumption-data-check-up-front)).

### Environment Options

The script runs in either Azure Cloud Shell or a local PowerShell 7 install. Pick based on the size of the tenant you're inventorying:

| Tenant size | Use | Why |
|---|---|---|
| Up to ~30 subscriptions | **Cloud Shell** | Fastest to start. No setup, pre-authenticated, all dependencies included. |
| 30–100+ subscriptions | **Either**, with `-ParallelStreams 2 -Resume` on Cloud Shell | Cloud Shell still works, but session timeouts and the 3.5 GB RAM cap start to matter. `-Resume` lets a timed-out session pick up where it left off. |
| 100+ subscriptions, or metric-heavy tenants | **Local PowerShell 7** | Cloud Shell caps at `-ParallelStreams 2` (only 3.5 GB RAM / 2 vCPU). A local 16 GB / 8-core machine runs at `-ParallelStreams 6`, about 3× faster. Microsoft also warns that long-running parallel work in Cloud Shell can trigger anti-abuse blocking. See [Choosing where to run](#choosing-where-to-run-for-large-tenants-cloud-shell-vs-local) below for the full details. |

#### Option 1: Azure Cloud Shell

- Browser-based, no setup
- Pre-authenticated to your Azure tenant
- `Az` module pre-installed by Microsoft
- Access at [Azure Cloud Shell](https://shell.azure.com "Open Azure Cloud Shell")
- Sessions are ephemeral by default. Mount a storage account (Cloud Shell Settings > Reset User Settings > Mount storage account) if you need outputs to persist across sessions or want to use `-Resume` on a follow-up session.

#### Option 2: Local Environment
- **[Git](https://git-scm.com/downloads)** — required first. The recommended way to get the script is `git clone`, which also avoids Windows' Mark-of-the-Web / execution-policy friction. On a fresh Windows box without Git, install it before anything else (see [Step 2: Get the Script](#step-2-get-the-script) for the BITS-based silent install).
- [PowerShell 7 or later](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell)
- **Az PowerShell module** — only four submodules are needed: `Az.Accounts` **5.5.4 or newer**, `Az.Compute`, `Az.Monitor` and `Az.Billing` (install before running — see below). The Azure CLI is not needed, and neither is `Az.ResourceGraph`: Resource Graph is queried through `Invoke-AzRestMethod` from `Az.Accounts`.

> **On Windows with only Windows PowerShell 5.1?** The tool requires PowerShell 7. If you launch `Run-AllSubscriptions.ps1` from Windows PowerShell 5.1, it detects the old version and automatically re-launches itself under PowerShell 7, forwarding your arguments. If PowerShell 7 isn't installed, it offers to install it first (official Microsoft MSI) when run interactively. Nothing extra to do — just run the same command:
> ```powershell
> .\Run-AllSubscriptions.ps1 -TenantID "contoso.onmicrosoft.com" 
> ```

##### Installing the required PowerShell modules

> **Cloud Shell users:** `Az` is pre-installed by Microsoft. Skip this section entirely.

**You normally don't need to install anything by hand.** When you run `Run-AllSubscriptions.ps1`, its pre-flight bootstrap checks for the four Az submodules it needs (`Az.Accounts`, `Az.Compute`, `Az.Monitor`, `Az.Billing`) and, if any are missing, offers to install just those for you on interactive runs. It does this **before** any Az call — not mid-run — and then **verifies the module actually loads** (by importing `Az.Accounts`) before proceeding, so a broken/partial install is caught up front with a clear repair message instead of failing much later with confusing errors like "no consumption records". The tool needs only those four submodules, not the full ~80-submodule `Az` rollup (the full rollup works too — it loads only the four it needs). The report is a self-contained HTML file with no Excel/ImportExcel dependency, so there is nothing else to install.

**Optional — install by hand.** Do this only if you want to skip the prompt, are running **non-interactively** (the bootstrap won't prompt then, it fails loud with this same command), or are calling `ResourceInventory.ps1` **directly** — the inner script does *not* auto-install (by design, to avoid half-installed modules); if one of the four is missing or does not load, a direct run says which and stops with exit code `1` before it signs in. From a **PowerShell 7** prompt (`pwsh`); `-Scope CurrentUser` needs no administrator elevation:

```powershell
Install-Module -Name Az.Accounts,Az.Compute,Az.Monitor,Az.Billing -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck -Scope CurrentUser
```

**Az.Accounts 5.5.4 or newer is required.** Both scripts check this before any Azure call. If the newest installed `Az.Accounts` is older (or missing), the run prints the version it found, the version it needs and this command, then stops with exit code `1` (the wrapper offers to run it for you on interactive runs):

```powershell
Install-Module -Name Az.Accounts -MinimumVersion 5.5.4 -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck
```

If an older `Az.Accounts` is already loaded in your PowerShell session, it cannot be replaced while the session runs: the run stops and asks you to open a new PowerShell session (use `pwsh -NoProfile` if your profile loads `Az.Accounts`). In that new session, sign in first (`Connect-AzAccount`, or `Connect-AzAccount -Identity` on an Azure VM), then run again.

If a previous run left a broken `Az` install behind, remove it and reinstall:

```powershell
Get-Module Az* -ListAvailable | Uninstall-Module -Force
Install-Module -Name Az.Accounts,Az.Compute,Az.Monitor,Az.Billing -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck -Scope CurrentUser
```
  


## Getting Started

### Step 1: Access Your Environment

**For Azure Cloud Shell:**
1. Navigate to [Azure Cloud Shell](https://shell.azure.com "Open Azure Cloud Shell")
2. Ensure you're in PowerShell mode (not Bash)
3. You're automatically authenticated

![CloudShell](./docs/cloudshell.png)

**For Local Environment:**
1. Open PowerShell 7 as Administrator
2. Ensure the four Az PowerShell submodules are installed (see [Installing the required PowerShell modules](#installing-the-required-powershell-modules))
3. Sign in with Az PowerShell (`Connect-AzAccount -Tenant <tenant>`), or let the script sign you in. The Azure CLI is not needed.

### Step 2: Get the Script

**Recommended — Git clone.** This is the smoothest path and sidesteps Windows' security friction entirely. Files created by `git clone` are written locally, so Windows does **not** tag them with the "Mark of the Web," and the scripts run under the default execution policy with **no unblocking and no execution-policy changes**.

```bash
git clone https://github.com/awslabs/resource-discovery-for-azure.git
```

> **Fresh Windows box without Git?** Install Git for Windows first, then clone. Downloading the installer with BITS is much faster than `Invoke-WebRequest`:
> ```powershell
> # Check https://github.com/git-for-windows/git/releases for the current version.
> Start-BitsTransfer -Source "https://github.com/git-for-windows/git/releases/download/v2.45.2.windows.1/Git-2.45.2-64-bit.exe" -Destination C:\git-setup.exe
> Start-Process C:\git-setup.exe -ArgumentList '/VERYSILENT /NORESTART' -Wait
> # Reopen PowerShell so Git is on PATH, then run the git clone above.
> ```

**Alternative — Download ZIP.** Works, but every file inside a GitHub ZIP is flagged by Windows as downloaded-from-the-internet (Mark of the Web), so PowerShell refuses to run the scripts until you unblock them or relax the execution policy — an extra step on each new machine.

1. Click the green **Code** button on this repository
2. Select **Download ZIP**
3. Extract to your desired directory
4. Unblock the files before running:
   ```powershell
   Get-ChildItem -Path . -Recurse | Unblock-File
   # or, session-only: Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   ```

![Zip](./docs/zip_download.png)

**Bottom line: prefer `git clone`** — it "just works" and avoids the execution-policy/unblock dance on every new desktop. See [Troubleshooting](#common-issues) if you must use the ZIP.

Put it in a folder whose path has no `[`, `]`, `*` or `?`: PowerShell reads them as wildcards, so `Run-AllSubscriptions.ps1` stops at once (exit 1) when its folder's path holds one, before it offers or installs anything.

## Usage

### Authentication Notes

- **Azure Cloud Shell:** Cloud Shell's own sign-in is used when it can still get a token for the tenant (rule 2 below), so usually there is no prompt. `-Appid`, `-UseManagedIdentity`, `-DeviceLogin` and `-TenantID` work in Cloud Shell as anywhere else.
- **Local PowerShell:** The tool signs in with Az PowerShell only (`Connect-AzAccount`); the Azure CLI is not used. You can sign in beforehand with `Connect-AzAccount -Tenant <tenant>` or let the script do it. If you plan to scan all subscriptions in a tenant, use `Run-AllSubscriptions.ps1`, which signs in once and then reuses the session for every subscription.

Sign-in follows three rules, in this order:

1. **Service principal:** `-Appid`, `-Secret` and `-TenantID` always sign in as the service principal (`Connect-AzAccount -ServicePrincipal`, the secret kept as a SecureString), even when a user is already signed in; `-Appid` without the other two stops with exit code `1`. If the service principal sign-in fails, or Az PowerShell is then not signed in as that service principal, the run stops with exit code `1`; it never continues as a user who was already signed in. `-UseManagedIdentity` works the same way with the identity of the Azure VM or service the script runs on.
2. **Existing sign-in:** otherwise an Az PowerShell sign-in that is on the target tenant and can still get a token without a prompt is reused, with no prompt. When that sign-in is on another tenant but can get a token for `-TenantID` without a prompt, the script's process is switched to `-TenantID` (`Set-AzContext -Scope Process`) instead of signing in again. Without `-TenantID` the target tenant is the one that sign-in is on, and only that tenant's subscriptions are collected (listed with `Get-AzSubscription -TenantId`, so subscriptions delegated to the tenant are included).
3. **One sign-in attempt:** otherwise the script signs in once (`Connect-AzAccount`; `-DeviceLogin` uses the device-code flow, `-UseManagedIdentity` the identity of the Azure VM or service it runs on) and checks the token. If the sign-in fails, or still gives no token without a prompt (for example because of MFA or Conditional Access), the run stops with exit code `1` and says which command to run yourself; it does not prompt again or continue with an empty inventory. With no usable sign-in and no `-TenantID`, the sign-in is made without a tenant and you pick the tenant afterwards (the first one in a non-interactive session); the list holds the tenants your subscriptions are accessed through, so a tenant that manages subscriptions with Azure Lighthouse is offered. A number outside the list is asked for once more, then the run stops. In a session with no console (CI, a scheduled task), the script does not open a browser: it stops with exit code `1` unless `-DeviceLogin`, a service principal or `-UseManagedIdentity` is given.

The run goes on only when Az PowerShell is signed in to the target tenant and that tenant lists at least one subscription for the sign-in; otherwise it stops with exit code `1` instead of writing an empty or wrong-tenant report.

A usable sign-in is never signed out; switching to the chosen tenant applies to the script's own process only (`Set-AzContext -Scope Process`). Service principal and managed identity sign-ins are kept to the script's process too (`Connect-AzAccount -Scope Process`), so a later run without `-Appid` or `-UseManagedIdentity` does not reuse them. If the token is lost later in the run, metrics and consumption reconnect at most once per run, with the same identity: the service principal, the managed identity (never a user sign-in), or, for a user, a switch back to the run's tenant when that needs no prompt, or one sign-in on the run's tenant if the run has not prompted yet. Otherwise that phase is skipped with an error and the rest of the inventory continues.

A run asks you to sign in at most once: the parallel collectors and the `Run-AllSubscriptions.ps1` streams use that one sign-in.

### Basic Execution

1. **Navigate to the script directory:**
   ```powershell
   cd resource-discovery-for-azure
   ```

2. **Run the script with your organization name:**
   ```powershell
   ./ResourceInventory.ps1 -ReportName "YourCompanyName" -ConcurrencyLimit 6
   ```

### Advanced Usage Examples

For most runs, use the `Run-AllSubscriptions.ps1` wrapper (recommended) — it inventories the whole tenant and forwards the common options (`-SkipConsumption`, `-SkipMetrics`, `-ConcurrencyLimit`, `-Obfuscate`, `-DeviceLogin`), so they behave exactly as they would on the inner script:

**Skip consumption (billing) data:**
```powershell
./Run-AllSubscriptions.ps1 -TenantID "contoso.onmicrosoft.com" -SkipConsumption
```

**Skip metrics:**
```powershell
./Run-AllSubscriptions.ps1 -TenantID "contoso.onmicrosoft.com" -SkipMetrics
```

**Tune the metrics throttle:**
```powershell
./Run-AllSubscriptions.ps1 -TenantID "contoso.onmicrosoft.com" -ConcurrencyLimit 8
```

To mask identifying details before sharing externally, add `-Obfuscate` — see [Obfuscation Mode](#obfuscation-mode).

#### Targeting a single subscription or resource group

The wrapper always covers the whole tenant. To scope a run to **one** subscription or a **single** resource group (producing one consolidated report), call `ResourceInventory.ps1` directly — the wrapper does not expose `-SubscriptionID` or `-ResourceGroup`. It accepts the same `-SkipConsumption`, `-SkipMetrics`, and `-Obfuscate` switches.

**Scan a specific subscription:**
```powershell
./ResourceInventory.ps1 -ReportName "CompanyName" -SubscriptionID "12345678-1234-1234-1234-123456789012"
```

**Scan a specific resource group** (`-ResourceGroup` needs `-SubscriptionID`):
```powershell
./ResourceInventory.ps1 -ReportName "CompanyName" -SubscriptionID "12345678-1234-1234-1234-123456789012" -ResourceGroup "MyResourceGroup"
```

Direct runs check Reader access up front too (see [Subscription access check](#subscription-access-check-up-front)). With `-ResourceGroup`, Reader on that one resource group is enough, and the [consumption data check](#consumption-data-check-up-front) looks for usage values of that resource group.

### Running Across All Subscriptions

Use `Run-AllSubscriptions.ps1` to generate a separate inventory report for each subscription in a tenant, instead of the default single consolidated report. The wrapper prompts you to sign in once, then invokes `ResourceInventory.ps1` for each subscription. By default subscriptions are processed sequentially (one at a time); use `-ParallelStreams` to process several concurrently.

```powershell
./Run-AllSubscriptions.ps1 -TenantID "12345678-1234-1234-1234-123456789012"
```

`-TenantID` accepts either a tenant GUID or a verified domain. When a domain is passed (for example `contoso.onmicrosoft.com`), the wrapper resolves it to the GUID via Microsoft's anonymous OIDC discovery endpoint before doing anything else, so this also works:

```powershell
./Run-AllSubscriptions.ps1 -TenantID "contoso.onmicrosoft.com"
```

Each subscription produces its own set of timestamped reports in `InventoryReports/`. After all subscriptions are processed, the wrapper bundles the per-subscription ZIPs into a single `AllSubscriptions_ResourcesReport_<timestamp>.zip` in the same folder for easy delivery. Run one wrapper at a time per inventory folder: the zip takes every per-subscription report zip written in that folder since the run started, so a second run in the same folder at the same time (another tenant included) would mix its reports into this run's zip. Names made from the time to the second (the wrapper transcript, this zip and `MainSummary_<time>.html`) still never write over a file that is already there: the run takes the next free name (`<name>-2`, `-3`, up to `-100`). The consolidated zip is built and checked under a private name (`rda-build-<id>.partial` in the same folder) and takes its name only after its last check, so no file under that name is a zip that was not checked. A run stopped or killed while or after the zip was built can leave that `.partial` file: it may be incomplete or never have passed its checks, and it holds copies of that run's reports (with real names unless the run used `-Obfuscate`). The next run in the folder that builds a consolidated zip names each one it finds in a warning and leaves it in place. Delete it and do not share it; only a file the run said it kept after its checks (the banner names it) can be renamed to a `.zip` name and used.

#### Subscription state filter

By default, `Run-AllSubscriptions.ps1` only inventories subscriptions whose `State` is `Enabled`. Subscriptions in any other state (`Disabled`, `Warned`, `PastDue`, `Deleted`) are skipped because they return little or no data from Resource Graph and most ARM data-plane calls, so processing them produces near-empty reports while still costing wall-clock time.

To include every subscription regardless of state, pass `-IncludeDisabled`:

```powershell
./Run-AllSubscriptions.ps1 -TenantID "12345678-1234-1234-1234-123456789012" -IncludeDisabled
```

The wrapper prints the count of excluded subscriptions and a per-state breakdown so the filter is transparent.

#### Subscription access check (up-front)

Before doing any inventory work, `Run-AllSubscriptions.ps1` and a direct run of `ResourceInventory.ps1` check that the signed-in identity's roles let it read every in-scope subscription. This matters because Azure Resource Graph returns **zero rows rather than an authorization error** for a subscription the identity cannot read — so a missing Reader assignment is otherwise invisible until the finished report turns out to be silently missing subscriptions.

For each subscription the check uses two answers: the identity's own role assignments (including roles given through groups) with their role definitions, and Azure's report of the identity's effective permissions there. A subscription passes when both show read access, or when the identity cannot see its role assignments (it has no `Microsoft.Authorization` read) and Azure reports read access. With any other result the subscription is not readable, including when the two answers disagree: role changes can take a few minutes to reach every Azure service, so after changing roles wait about 5 minutes before re-running. A direct run with `-SubscriptionID` and `-ResourceGroup` checks that resource group instead, so Reader on that resource group is enough. The check runs with or without `-SkipConsumption`; when consumption is requested it also prints whether the roles include the usage permission, which the [consumption data check](#consumption-data-check-up-front) uses for subscriptions that return no usage values.

A subscription that is not readable is **skipped**: right after the check the run lists each one (name, id, the roles it found, and the reason) with the fix, and collects the other subscriptions. The skipped subscriptions are listed again at the end of the run, because the report does not contain them. Skipping does not change the exit code. This applies to `Run-AllSubscriptions.ps1` and to a direct run of `ResourceInventory.ps1` over every visible subscription. When **no** checked subscription is readable, for example the one a direct run names with `-SubscriptionID`, the run lists them with the fix and **stops before doing any work** with exit code 1 (for `-Resume`, see below).

`-AllowPartialAccess` is still accepted, so existing command lines keep working, but skipping is now the default and the switch changes nothing.

On `-Resume`, only the subscriptions that still need processing are checked. When none of them is readable but the resume state records other subscriptions in the run as completed, `-Resume` does not stop: it skips and lists the unreadable ones as above and finishes the run with nothing left to collect. That run uses one stream whatever `-ParallelStreams` is, so the completed subscriptions are skipped, not collected again; its `Parallelism:` line says so. When it clears the resume state it also deletes the per-stream state files an interrupted parallel run left, so the next `-Resume` starts fresh. When no subscription in the run is recorded as completed, `-Resume` stops like any other run, and the fix ends in running `-Resume` again: a run without `-Resume` checks the same subscriptions, and when the identity has no read role on them it stops the same way. A run without `-Resume` stops whenever none of the subscriptions it checks is readable. A subscription skipped because its check could not finish, or because the two answers disagree (usually right after a role change), stays on the retry list (`FailedAttempts`) as a failed run, also when the run stops: the resume state is kept, `-Resume` and `-ResumeFailedOnly` check it again, and like any failed subscription it stays there, with its run count and reason, until a later run collects it. One skipped because the identity has no read role is not put on the retry list. If a skipped subscription is on the retry list, the end-of-run `Pending Retries` lines name it with its reason and the fix to apply before `-ResumeFailedOnly` can retry it. The check runs once, before subscriptions are split across parallel streams, so it applies to both sequential and parallel runs. Role assignments at a management group or the tenant root count.

Read access means one role that can read **every** resource type. Azure Resource Graph leaves out, without an error, the resources of any type the identity cannot read, so a role whose not-actions remove reads of some resource types (a not-action that, with `*` standing for any characters, can match an action ending in `/read`, such as `*/read`, `Microsoft.Compute/*`, `Microsoft.Comp*`, `Microsoft.Compute/*/r*` or `Microsoft.Compute/virtualMachines/read`, but not `Microsoft.Compute/*/delete` or `*/write`) does not count, and the subscription is not readable, with a reason such as `role 'Custom reader' at subscription excludes 'Microsoft.Compute/*/read'; the inventory would miss those resources`. Not-actions confined to `Microsoft.Authorization`, `Microsoft.Commerce`, `Microsoft.Consumption` or `Microsoft.Billing` are allowed, because the inventory reads no resources of those namespaces; the text before the first `*` must name the namespace and a `/`, so `Microsoft.Authorization/*` is allowed but `Microsoft.Auth*`, which can also match other namespaces, is not. Each role is judged on its own, as Azure does, so Reader next to such a custom role passes. Two narrower roles that only together cover every resource type do not count either; add Reader instead. Such a subscription is skipped like any other that is not readable.

The list says what to do for each cause: grant Reader (no read access, or a resource group that is not found), re-run (the check could not finish, for example persistent throttling or a role assignment list longer than 1000 pages), or wait 5 minutes and re-run (the two answers disagree, usually right after a role change).

#### Consumption data check (up-front)

Consumption (usage) data is what prices the business case: it shows whether a machine ran 4 hours or 400. Azure's usage API returns **no error and zero rows** to an identity that lacks `Microsoft.Commerce/UsageAggregates/read`, so without a check a missing permission only shows up as an empty consumption sheet in the finished report.

Whenever consumption is requested (`-SkipConsumption` not passed), `Run-AllSubscriptions.ps1` and a direct run of `ResourceInventory.ps1` both check every subscription the run will process (the readable ones; skipped subscriptions are not checked), before any inventory or metrics work. A subscription passes when the same query the consumption phase runs (daily usage for the last 31 days, ending at the start of yesterday in UTC) returns at least one usage row with a quantity above zero. The window is worked out once per run and the consumption phase collects that same window, even for a subscription collected after midnight. A direct run with `-ResourceGroup` checks that resource group: only usage rows whose resource is in it count (the rows its consumption sheet keeps), and the resource group is not checked when Resource Graph shows no resources in it. Throttling, timeouts and server errors are retried with a short backoff; a permission error or a rejected request is not retried.

A subscription that holds resources but returns no usage above zero (no rows, or only zero quantities) **passes with a yellow warning** (outcome `NoUsage`) when the role check confirmed `Microsoft.Commerce/UsageAggregates/read` for it at the subscription or above by both of its answers: the identity's role assignments and Azure's effective permissions. The warning names the role and scope, the window, the typical causes (a new subscription, only free resources such as virtual networks or network security groups, or paused resources), and that the subscription's consumption sheet will be empty. These subscriptions are listed again at the end of the run. The exit code is not changed.

The run lists every failing subscription (name, id, outcome and the window queried) with the fix, and **stops with exit code 1**, when any subscription:

- returns no usage above zero and the usage permission was not confirmed by both answers (for example role assignments not visible to the identity, the two answers disagreeing, or the permission granted only on a resource group);
- returns a permission error (`Denied`), or an error that persists after the retries (`Error`).

To inventory without consumption data, re-run with `-SkipConsumption`. The check reads at most 50 pages of usage per subscription; if none of them has a quantity above zero it is treated as only zero quantities, and the output says only the first 50 pages were read. When that subscription passes as `NoUsage`, the warning says only that the first 50 pages held no usage above zero, not that its consumption sheet will be empty: the consumption phase reads every page.

A subscription with no resources at all in Resource Graph is not checked, because there is nothing to price, and the output says so.

On `-Resume` and `-ResumeFailedOnly`, only the subscriptions the run will process are checked. When `Run-AllSubscriptions.ps1` runs `ResourceInventory.ps1` for each subscription, the check is not repeated.

Both up-front checks run up to 8 subscriptions at a time and print one line per subscription, in subscription order. Every Azure call names its subscription, so the checks never switch the Azure context. Per subscription, the role check makes 2 Azure calls (the role assignment list and Azure's effective permissions; a `-ResourceGroup` run with consumption also asks for the subscription's permissions), and each role definition is read once per run. The consumption data check calls the usage API that the consumption phase's `Get-UsageAggregates` wraps, with the same window and options, once per page until a usage value above zero comes back (usually one call), plus one Resource Graph query per 1,000 subscriptions for the resource counts.

#### Resuming an interrupted run

For tenants with many subscriptions, the run can be cut short by environment-level limits — for example, an Azure Cloud Shell session that ends when a Conditional Access policy enforces a maximum session lifetime. The wrapper supports resuming:

```powershell
./Run-AllSubscriptions.ps1 -TenantID "12345678-1234-1234-1234-123456789012" -Resume
```

After each subscription is fully processed (its per-subscription ZIP has been written), the wrapper records the subscription ID in a state file at `InventoryReports/.resume-state-<TenantID>.json`, together with the path of that ZIP and whether the run used `-Obfuscate`. Re-running with `-Resume` reads that file and skips subscriptions that are already complete; the partially processed subscription (the one that was running when the session ended) is re-run from the start. The consolidated `AllSubscriptions_ResourcesReport_<timestamp>.zip` of the `-Resume` run still covers the skipped subscriptions: it carries the ZIP the earlier run recorded for each one, provided that ZIP is still on disk, opens as a ZIP and was written with the same `-Obfuscate` setting as this run. A skipped subscription whose ZIP cannot be carried is named under a `FAILED (earlier report not carried)` banner and the run exits with code `2`; re-run without `-Resume`, or collect that subscription on its own with `./ResourceInventory.ps1 -TenantID <tenant> -SubscriptionID <id>`. The state file is cleared automatically after a clean run with no failures.

After an interrupted run, `-ResumeFailedOnly` retries only the subscriptions in the retry list, so one the interrupted run never reached is not collected by it. While such a subscription remains, the `-ResumeFailedOnly` run names it under `Not Collected` at the end and keeps the state file, so a later `-Resume` collects it and still skips the completed ones. When the retry list is empty, `-ResumeFailedOnly` prints `Nothing to retry`, names those subscriptions the same way, and exits `2` without collecting anything (`0` when none is left), so a repeated `-ResumeFailedOnly` is never reported as a success while work remains. A retry-list entry for a subscription the signed-in identity no longer sees at all (deleted, or moved to another tenant) is dropped from the list by the next run, with or without `-Resume`, with a line naming it, since no run could retry it (when that drop can be neither saved nor the state file removed, the `-ResumeFailedOnly` run says so and exits `2`); a disabled subscription is still listed by Azure and keeps its entry. When `Get-AzSubscription` returned warnings or errors, no entry is dropped, since the list may be incomplete: a line names the entries kept and prints the warnings and errors, and the first run after `Get-AzSubscription -TenantId <tenant>` lists the tenant without them drops the entries of subscriptions that are gone. A `-ResumeFailedOnly` run whose drop leaves nothing owed removes the state file, as a clean run does. A subscription the up-front access check skipped as not readable is recorded in the state file and is not named under `Not Collected`: the run that skipped it lists it, and a later run checks it again.

A subscription that fails 3 runs in a row is not retried by `-Resume` or `-ResumeFailedOnly`. The state file counts the failed runs of each subscription on the retry list, for sequential and parallel runs alike. The count is raised and saved before a subscription is collected, and only a run that completes it and saves that result takes it off the list, so a run that is cut off, or cannot save what it collected, still counts as a failed run. If that first save cannot be made, the subscription is not collected: a sequential run stops there (exit `2`), and a parallel stream names it and goes on with the next. Once the count reaches 3, a `-Resume` or `-ResumeFailedOnly` run skips that subscription and says so before the work starts: `Not retried: <name> (<id>) failed 3 runs in a row; last reason: <reason>`. It stays on the retry list, so the summary at the end (`Retry Limit Reached`) and `RunSummary.log` list it as incomplete with its count and last reason; the run ends with exit `2`, since its report is missing from the consolidated ZIP. To try it again, start a run without `-Resume` or `-ResumeFailedOnly`, which collects every subscription and goes on counting. When only such subscriptions are left on the retry list, `-ResumeFailedOnly` says `nothing left to retry`, names them and exits `2` without changing the state file. A subscription past the limit keeps the state file, so its count is never forgotten: every later `-Resume` or `-ResumeFailedOnly` run skips it again and ends with exit `2` until a run without either collects it. A subscription past the limit that is not Enabled is left out of every run without `-IncludeDisabled`; while it is on the retry list, every run ends with exit `2`, and the summary says to add `-IncludeDisabled`. One that the up-front access check skips as not readable (under `-AllowPartialAccess`) stays on the retry list too: the run ends with exit `2` (exit `1` when the check leaves no subscription to collect at all, as for any run), and the summary points to the reason and fix the check printed, then says to start a run without `-Resume` or `-ResumeFailedOnly` once the check can read it. A subscription past the limit that never succeeds keeps every run at exit `2`; to start over with an empty retry list, delete `.resume-state-<TenantID>.json` and any `.resume-state-<TenantID>-stream-*.json` in the inventory folder, and the next run collects every subscription. One that is no longer listed at all is dropped by the next run (see above) and ends no run with exit `2`, unless the listing came back with warnings or errors: then it is kept, every run ends with exit `2` (exit `1` when the listing holds no subscription at all, as for any run), and the summary says to fix the listing and run again. Running `ResourceInventory.ps1` on its own for that subscription does not end the skip: it writes a separate report and does not read or change the state file.

`-Resume` is opt-in. Without it, the wrapper processes every subscription returned by `Get-AzSubscription` and still updates the state file as it goes: a subscription that writes its ZIP is recorded as completed with that ZIP, replacing any earlier record, and one that fails or leaves no ZIP is not completed, so a later `-Resume` collects it again (it also counts as one more failed run for `-ResumeFailedOnly` and the retry limit). Before it collects a subscription, such a run also takes the earlier completion of that subscription out of the state file, so a run cut off part way never leaves an older result for a later `-Resume` to skip on. As with `-Resume`, a clean run with no failures deletes the state file.

A subscription whose ZIP was written but whose metrics or consumption were skipped or left incomplete (for example when the sign-in stops working part-way through a run; see the `FAILED (auth)` banner) is not recorded as completed either. It goes into the retry list with a reason that starts `Metrics incomplete:`, `Consumption incomplete:` or `Metrics and Consumption incomplete:`, so both `-Resume` and `-ResumeFailedOnly` collect it again, and the state file is kept until it has been collected in full. It is not counted as a failed subscription.

#### Parallel subscription processing

For large tenants, the slowest part of the run is collecting metrics. Each call to Azure Monitor takes 200–500 ms over the network, and a typical subscription with VMs, SQL DBs, and storage accounts produces thousands of these calls. Done one subscription at a time, that adds up to many hours.

Pass `-ParallelStreams N` to process N subscriptions concurrently in separate `pwsh` background processes:

```powershell
./Run-AllSubscriptions.ps1 -TenantID "12345678-1234-1234-1234-123456789012" -ParallelStreams 6
```

Each stream is a separate background process. They don't share state with each other. Each has its own Azure session, its own progress tracking file, and its own output folder. The wrapper splits your subscription list across the streams in round-robin order so the workload stays balanced even when subscriptions vary in size.

When `-ParallelStreams` is not given, the wrapper sizes it from the host's CPU and RAM (see the `Parallelism:` line it prints); `-ParallelStreams 1` is the sequential behavior, fully preserved. Pick a value based on the environment you're running in. See the table in [Choosing where to run for large tenants](#choosing-where-to-run-for-large-tenants-cloud-shell-vs-local) below.

`-ParallelStreams` and `-ConcurrencyLimit` compose. `-ConcurrencyLimit` throttles the metrics-collection runspace pool *within* one subscription; `-ParallelStreams` is the count of subscriptions running concurrently. Useful combinations:

| ParallelStreams | ConcurrencyLimit | Concurrent ARM calls (in flight at once) | Verdict |
|---|---|---|---|
| 1 | 6 | 6 | Sequential (`-ParallelStreams 1`). |
| 6 | 6 | 36 | Recommended for metric-heavy estates on a 16 GB / 8-core local machine. |
| 8 | 6 | 48 | Watch for HTTP 429s in per-stream logs. |
| 6 | 12 | 72 | Aggressive. Expect retry-backoff to eat the gain. |

When you run with `-ParallelStreams`, several things change in the output:

- The wrapper's own narration (which subscription a stream is starting, which one it finished) is prefixed with `[stream-N]`. The inner script's `Write-Host` and `Write-Log` output is **not** prefixed and will interleave across streams in the transcript. Use the per-stream summary at the end of the run, or the per-stream failures log, to disambiguate.
- Each stream writes its own failure log to `InventoryReports/RunAllSubscriptions_failures_<timestamp>_stream-<N>.log`. At the end of the run, the wrapper merges those into a single combined failure log so you only have one file to read.
- Each stream tracks its own progress in a separate resume-state file. When the run finishes, those are merged into the main resume-state file. This means `-Resume` works the same way regardless of whether the previous run was sequential or parallel — but only if the previous run reached the post-aggregation step. If you Ctrl+C a parallel run mid-stream, the per-stream resume files are still on disk; running `-Resume` on the next attempt will read them and skip the subs each stream had already completed. A per-stream file that cannot be read (for example one cut short when the session ended) is not used: the run prints a warning naming it, renames it in place to `<name>.unreadable-<UTC time>`, with `-2`, `-3` and so on added when that name is taken (kept for inspection; no later run reads it, and neither the wrapper's zips nor a zip step that takes `*.json` files picks it up), collects the subscriptions it listed again (under `-ResumeFailedOnly`, which retries only the retry list, a later `-Resume` collects them), and, when the run reaches its end, says whether the resume state was cleared or kept instead of `Resume state cleared (clean run).` The end-of-run merge of a parallel run does the same with a per-stream file it cannot read; as which subscriptions its records held is not known, none of that run's subscriptions counts as completed, and the resume state is kept, so a later `-Resume` collects them all again. A file that cannot be moved aside is left alone and named with the command that removes it: at the start the run stops there with exit 1, before it collects anything; found by the end-of-run merge, the run ends with exit 1 in place of 0 and 3-5 (exit 2 keeps its code). If a resume state file cannot be removed at the end of a run that clears the state, the run names it in a warning and does not print `Resume state cleared (clean run).`; when a per-stream state file is left, the main resume state file is kept as well, so the next `-Resume` reads the same state again.

Authentication only happens once. The wrapper saves the parent process's Az PowerShell context to a file and each stream loads it, so you don't get prompted to sign in again for each parallel worker. The wrapper deletes that snapshot file when the run ends, including if you cancel with Ctrl+C or a stream crashes during startup.

#### Choosing where to run for large tenants: Cloud Shell vs local

Three things constrain how many parallel streams you can usefully run:

- **Azure Resource Manager (ARM) request quota.** ARM is Azure's control-plane API that the script calls to read resource details and metrics. Each subscription is rate-limited to roughly 12,000 read requests per hour. The script's `-ConcurrencyLimit` and `-ParallelStreams` together control how many ARM requests are in flight at once. Stay under about 50 concurrent requests per tenant, or you'll start seeing HTTP 429 ("Too Many Requests") in the per-stream logs and the script will spend more time backing off than working.
- **CPU cores.** The script is mostly waiting on network responses, not crunching numbers, so it doesn't need many cores. Roughly one core per stream is plenty. Running more streams than cores doesn't make the script faster, the CPU just spends time switching between tasks.
- **RAM.** Each stream loads the Azure PowerShell modules and holds resource and metric data in memory before writing the output files. Plan for around 500-700 MB peak per stream. Running more streams than your RAM can hold makes the OS swap to disk and slows everything down.

For small to medium tenants (up to a few dozen subscriptions), Cloud Shell is the easiest place to run. For large tenants the resource ceilings on Cloud Shell start to matter.

Verified Cloud Shell limits (measured 2026-05; Microsoft can change these silently):

| Resource | Cloud Shell | Notes |
|---|---|---|
| RAM | ~3.5 GB total, ~2.7 GB usable at idle | Each `pwsh` worker peaks at ~500–700 MB during the metrics phase |
| CPU | 2 vCPUs (Intel Xeon Platinum @ 2.8 GHz) | Shared, so effective throughput is lower under load |
| Storage | ~50 GB overlay filesystem | Ephemeral by default. See below. |
| Idle timeout | 20 minutes | Sessions are terminated without warning when this elapses |
| Concurrent sessions per tenant | 20 | Tenant-wide cap |
| Sudo / elevation | Not available | Module installs must use `-Scope CurrentUser` |

References: [Cloud Shell features](https://learn.microsoft.com/en-us/azure/cloud-shell/features), [Cloud Shell FAQ](https://learn.microsoft.com/en-us/azure/cloud-shell/faq-troubleshooting).

Recommended `-ParallelStreams` per environment:

| Environment | Recommended | Why |
|---|---|---|
| Cloud Shell (ephemeral or with mounted storage) | **2** | Saturates both vCPUs without OOM-killing workers on the 3.5 GB RAM cap |
| Local PowerShell 7, 8 GB RAM | **2** | RAM is the bottleneck |
| Local PowerShell 7, 16 GB RAM, 8+ cores | **6** | Recommended for metric-heavy estates |
| Local PowerShell 7, 32 GB RAM, 12+ cores | **8** | Watch HTTP 429s in per-stream logs. |

**Persistence in Cloud Shell:** Cloud Shell sessions are ephemeral by default. When your session ends, anything in your home directory is deleted, including the script's output and the resume-state file. The wrapper detects this at startup and warns you. To keep outputs across sessions (and to make `-Resume` work after a session times out), attach a storage account: in Cloud Shell, click Settings (the gear icon) > Reset User Settings > Mount storage account.

**Cloud Shell anti-abuse limits:** Microsoft warns that Cloud Shell is "not a general purpose computing platform" and that excessive usage can result in your tenant being blocked from Cloud Shell ([source](https://learn.microsoft.com/en-us/azure/cloud-shell/faq-troubleshooting#terminal-output---sorry-your-cloud-shell-failed-to-provision-codetenantdisabled-)). Long parallel runs against large tenants can trigger this. If you're running RDA across many subscriptions for a few hours at a time, use a local PowerShell 7 install instead. It avoids the risk and is usually faster anyway.

#### Run transcript and failure diagnostics

Every time you run `Run-AllSubscriptions.ps1`, it writes a transcript of the whole run to `InventoryReports/RunAllSubscriptions_transcript_<timestamp>.txt`. This is different from the per-subscription transcripts that the inner script `ResourceInventory.ps1` writes inside each subscription folder. The wrapper transcript covers the run end-to-end: which tenant was resolved, how authentication was handled, any resume-state messages, which subscription is being processed at each step, the final consolidation, and the run summary. You get this file every run, whether you process one subscription or many.

If a subscription fails, the wrapper also writes a structured failure log to `InventoryReports/RunAllSubscriptions_failures_<timestamp>.log`. This file captures the full exception type, the error message, up to five levels of inner exceptions, the script line number, the stack trace, and a snapshot of how much memory and free disk space the machine had when the failure happened. The final summary points at both files when failures occur.

Inside each subscription's report folder, the inner script also writes a consolidated **local debug log**, `DebugLog_<ReportName>_<timestamp>.log` — the per-collector heartbeat (each collector's start/finish/failure) plus the metrics-phase diagnostics that used to scroll past on the terminal. It stays **local** and is never added to the shared ZIP: it can contain real service/resource names and raw exception text, so keep it for your own troubleshooting.

Obfuscated runs (`-Obfuscate`) additionally produce a **shareable diagnostics log**, `Diagnostics_<ReportName>_<timestamp>.log`, which **is** included in the report ZIP. It is human-readable and scrubbed — subscriptions appear as their obfuscated tokens and other identifiers are masked — and it summarises phase timings plus one-line health entries for any collector failures, metrics auth-skips, and consumption failures (including exactly where a consumption pull stopped, so a truncated billing sheet is obvious rather than something you have to infer). Because it is safe to share, it can go to the AWS team alongside the report to explain any gaps without exposing real names. It is a plain `.log` on purpose so the ingestion pipeline treats it as an attachment, not as report data.

When reporting an issue, attach the wrapper transcript and the failure log (and, for obfuscated runs, the in-ZIP diagnostics log). The local `DebugLog_*.log` carries the most detail — share it too if you've confirmed it doesn't expose sensitive names. Together they contain enough context to diagnose most failures without a follow-up round trip.

## Output Files

Upon completion, the script generates reports in the `InventoryReports` folder:

### Generated Files

| File | Description |
|------|-------------|
| `Consumption_ResourcesReport_(date).csv` | Cost and billing data |
| `Inventory_ResourcesReport_(date).json` | Complete resource inventory |
| `Metrics_ResourcesReport_(date).json` | Performance metrics data |
| `ResourcesReport_(date).html` | Self-contained HTML report (open in any browser; no Excel required) |
| `Transcript_Log_<ReportName>_(date).txt` | Plaintext transcript of script activity (excluded from the zip when `-Obfuscate` is used) |
| `DebugLog_<ReportName>_(date).log` | Consolidated **local** debug log — per-collector heartbeat + metrics diagnostics. Never added to the zip (may contain real names/exception text) |
| `Diagnostics_<ReportName>_(date).log` | Shareable, scrubbed diagnostics summary (phase timings + collector/metrics/consumption health). **Included in the zip on `-Obfuscate` runs only** |
| `ResourcesReport_(date).zip` | All files compressed |

### File Delivery

1. **Locate the output:** Check the `InventoryReports` folder
2. **Rename the ZIP file:** Include your company name (e.g., `CompanyName_ResourcesReport_2024-01-15.zip`)
3. **Deliver to AWS team:** Send the renamed ZIP file for analysis

### Obfuscation Mode

Obfuscation is **opt-in** (off by default). Add `-Obfuscate` to mask identifying details so the report can be shared externally — it works on both entry points:

```powershell
# Whole tenant (per-subscription reports):
./Run-AllSubscriptions.ps1 -TenantID "contoso.onmicrosoft.com" -Obfuscate

# Single consolidated report:
./ResourceInventory.ps1 -ReportName "CompanyName" -Obfuscate
```

When using `-Obfuscate`, the following data is masked in all output files:

| Category | What is masked | Masked Format |
|----------|---------------|---------------|
| Resource ID | All resource IDs across inventory, metrics, and consumption: every name segment (subscription, resource group, each resource name, a parent's included) | ARM-shaped path of `prod_<guid>` / `nonprod_<guid>` tokens |
| Resource Name | All resource names | `prod_<guid>` or `nonprod_<guid>` |
| Subscription | Subscription names (deterministic — same real sub always maps to the same value) | `prod_<guid>` or `nonprod_<guid>` |
| Resource Group | Resource group names (deterministic — same real RG always maps to the same value) | `prod_<guid>` or `nonprod_<guid>` |
| Tags | Tag **keys** kept verbatim; tag **values** tokenized deterministically (same value maps to the same token) | `prod_<guid>` or `nonprod_<guid>` |
| Cross-references | Fields that reference other resources by name or ID (e.g. DatabaseServer, ManagedInstance, HostId, StorageAccount, KeyVault, WAF policy) | Dictionary lookup or `obfuscated` |
| Consumption IDs | ReservationId and ReservationOrderId in billing data | `obfuscated` |
| Free-text / identity | Free-form fields that can carry PII (Description, FriendlyName, CreatedBy, RoleName, container image/name, IoT host/endpoint, automation account/runbook names) — tokenized deterministically, not dropped | `prod_<guid>` or `nonprod_<guid>` |

Resources with names matching dev/test/qa patterns (including short prefixes like `d-`, `t-`, `s-`) get a `nonprod_` prefix; all others get `prod_`. This preserves environment classification without exposing real names.

**Deterministic mapping:** The same real subscription or resource group always maps to the same obfuscated value within a run. This means pivot tables, grouping, and cross-referencing all work correctly in the obfuscated output.

**Reverse-lookup dictionary:** A local `ObfuscationDictionary_*.json` file maps every obfuscated value back to the real value. This file stays with the customer and is never included in the ZIP. Use `Reveal.ps1` locally to produce a NEW ingestible ZIP (same structure as `-Obfuscate`) with only the dimensions you choose un-masked — `-Fields ResourceGroup,Subscription,Tag,ResourceName,ResourceId,FreeText` for a selective reveal, or `-All` for a full un-obfuscate. See [docs/obfuscation-and-unmask.md](docs/obfuscation-and-unmask.md) for details.

**What is preserved:** Location, SKU, VM size, OS type, disk type, metrics values, consumption quantities, and all technical configuration data needed for analysis.

**What is excluded from the ZIP:**
- Transcript log (contains raw console output with emails, subscription IDs, file paths)
- Obfuscation dictionary (contains the real-to-obfuscated mapping)

### Manual Compression (If Needed)

If automatic compression fails, zip the run's shareable files from its report folder (`InventoryReports/<ReportName><timestamp>`, or your `-OutputDirectory`). Replace `<timestamp>` with the part of the file names after the report name, for example `Inventory_<ReportName>_<timestamp>.json`. The command leaves out the files that stay on your machine (`ObfuscationDictionary_*`, `Transcript_Log_*`, `DebugLog_*`, `ErrorLog_*`, `Full_*`) and the files of other runs in the same folder:
```powershell
cd InventoryReports/<ReportName><timestamp>
Get-ChildItem -File -Path ./* -Include *.html, Consumption_*.csv, Inventory_*.json, Metrics_*.json, Diagnostics_*.log |
    Where-Object Name -like '*_<timestamp>*' |
    Compress-Archive -DestinationPath "CompanyName_ResourcesReport_$(Get-Date -Format 'yyyy-MM-dd').zip"
```
## Parameters Reference

### Core Parameters

| Parameter | Type | Description | Example |
|-----------|------|-------------|----------|
| `ReportName` | String | **Required.** Company/customer name for file naming | `-ReportName "AcmeCorp"` |
| `TenantID` | String | Target specific Azure tenant | `-TenantID "12345678-1234-1234-1234-123456789012"` |
| `SubscriptionID` | String | Scan single subscription only | `-SubscriptionID "12345678-1234-1234-1234-123456789012"` |
| `ResourceGroup` | String | Scan specific resource group only | `-ResourceGroup "Production-RG"` |
| `OutputDirectory` | String | Full path to write reports to. Defaults to `~/InventoryReports` (or `C:\InventoryReports` on Windows). Must be the full path. | `-OutputDirectory "/data/rda-out"` |

### Performance Parameters

| Parameter | Type | Description | Default | Example |
|-----------|------|-------------|---------|----------|
| `ConcurrencyLimit` | Integer | Parallel execution limit | 6 | `-ConcurrencyLimit 8` |
| `SkipConsumption` | Switch | Skip cost/billing data collection and the up-front [consumption data check](#consumption-data-check-up-front) | False | `-SkipConsumption` |
| `SkipMetrics` | Switch | Skip Azure Monitor metrics collection | False | `-SkipMetrics` |
| `MetricsLookbackDays` | Integer | Days of metric history to collect for the trend metrics. Lower values reduce run time and memory use. | 31 | `-MetricsLookbackDays 14` |

### Metrics Lookback Window

`MetricsLookbackDays` shortens the history window for the **trend / utilization**
metrics only. Lowering it (e.g. 31 → 14 or 7) reduces both run time and memory
use, which helps on large estates that time out or hit out-of-memory errors
during the metrics phase. It does **not** change which resources are found, and
it does **not** affect cost/consumption data (that phase uses its own fixed
window).

The tradeoff is right-sizing accuracy: a shorter window samples fewer
peaks/cycles, so utilization-based sizing is based on a smaller sample. For
migration assessments prefer **14 over 7** so at least one full weekly cycle is
captured.

**Group A — bound to the lookback window. These DO shrink when you go 31 → 7/14:**

| Metric | Resource | Granularity |
|--------|----------|-------------|
| Percentage CPU | VMs, VMSS | 15-min (VM) / 1-hr (VMSS) |
| Available Memory Bytes | VMs, VMSS | 15-min / 1-hr |
| cpu_percent, memory_percent | SQL, MariaDB, MySQL(+Flexible), PostgreSQL(+Flexible) | 30-min / 1-hr |
| cpu_used, dtu_used | SQL DB | 30-min |
| physical_data_read_percent, log_write_percent | SQL DB | 1-hr |
| FunctionExecutionCount/Units | Functions | daily |

Capacity and point-in-time metrics (storage used, limits, CosmosDB throughput,
ACR storage, serverless SQL `app_cpu_billed`) use a fixed 1-day window and are
**not** affected by this setting.

### Privacy & Obfuscation Parameters

| Parameter | Type | Description | Example |
|-----------|------|-------------|----------|
| `Obfuscate` | Switch | Replace resource IDs, names, subscriptions, resource groups, and tags with masked values. A reverse-lookup dictionary is saved locally. Reports can be safely shared externally without exposing sensitive Azure environment details. | `-Obfuscate` |

### Authentication Parameters

| Parameter | Type | Description | Example |
|-----------|------|-------------|----------|
| `Appid` | String | Service Principal application ID | `-Appid "app-id-here"` |
| `Secret` | SecureString | Service Principal client secret, as a SecureString (a plain string is refused) | `-Secret (Read-Host -Prompt 'Client secret' -AsSecureString)` |
| `DeviceLogin` | Switch | Use device code authentication | `-DeviceLogin` |
| `UseManagedIdentity` | Switch | Sign in Az PowerShell (`Connect-AzAccount -Identity`, with `-Tenant` when `-TenantID` is given) with the managed identity of the Azure VM or service the script runs on. Direct runs of `ResourceInventory.ps1` only. | `-UseManagedIdentity` |

### Debugging Parameters

| Parameter | Type | Description | Example |
|-----------|------|-------------|----------|
| `Debug` | Switch | Enable debug mode output | `-Debug` |

### Run-AllSubscriptions Wrapper Parameters

These are the parameters specific to `Run-AllSubscriptions.ps1`. The wrapper forwards `-DeviceLogin`, 
`-Obfuscate`, `-SkipMetrics`, `-SkipConsumption`, and `-ConcurrencyLimit` to the inner `ResourceInventory.ps1`, so they behave the same in both contexts.

| Parameter | Type | Description | Default | Example |
|-----------|------|-------------|---------|---------|
| `TenantID` | String | **Required.** Azure tenant GUID or verified domain. The wrapper resolves a domain to its GUID via OIDC discovery before authenticating. | — | `-TenantID "contoso.onmicrosoft.com"` |
| `Resume` | Switch | Skip subscriptions already completed in a prior run. Reads from `InventoryReports/.resume-state-<TenantID>.json`. State is cleared automatically after a clean run. | False | `-Resume` |
| `ResumeFailedOnly` | Switch | Retry **only** the subscriptions in the retry list from a prior run: those that failed, and those whose metrics or consumption were left incomplete (see [Resuming an interrupted run](#resuming-an-interrupted-run)). Already-completed and never-attempted ones are skipped. Use this after a run finishes with a handful of failures (e.g. transient throttling) to re-run just those instead of walking the whole tenant again. `-Resume` continues an interrupted run (retry list **and** not-yet-attempted subs); `-ResumeFailedOnly` targets the retry list only. | False | `-ResumeFailedOnly` |
| `IncludeDisabled` | Switch | Include subscriptions whose state is not `Enabled` (e.g. `Disabled`, `Warned`, `PastDue`). By default these are skipped because they return little or no data. | False | `-IncludeDisabled` |
| `AllowPartialAccess` | Switch | Accepted so existing command lines keep working; it changes nothing. Skipping unreadable subscriptions (listed at the start and the end of the run) and collecting the rest is now the default (see [Subscription access check](#subscription-access-check-up-front)). | False | `-AllowPartialAccess` |
| `ParallelStreams` | Integer | Number of subscriptions to process concurrently. `1` (default) is the existing sequential behavior. See [Parallel subscription processing](#parallel-subscription-processing) for sizing guidance. | 1 | `-ParallelStreams 6` |
| `ConcurrencyLimit` | Integer | Forwarded to the inner script's metrics-collection throttle. Controls how many `Get-AzMetric` calls run in parallel within one subscription. | 6 | `-ConcurrencyLimit 12` |
| `Obfuscate` | Switch | Forwarded. Replace resource IDs, names, subscriptions, resource groups, and tags with masked values. | False | `-Obfuscate` |
| `SkipMetrics` | Switch | Forwarded. Skip Azure Monitor metrics collection. | False | `-SkipMetrics` |
| `SkipConsumption` | Switch | Forwarded. Skip cost/billing data collection and the up-front [consumption data check](#consumption-data-check-up-front). | False | `-SkipConsumption` |
| `DeviceLogin` | Switch | Forwarded. Use device-code authentication (browser flow with a code). | False | `-DeviceLogin` |

## Troubleshooting

### Common Issues

**Downloaded ZIP File:**
- If you download the ZIP file, Windows may mark the files as blocked for security reasons which is a known issue from GitHub
- Run the following PowerShell command to unblock all files in Resource Discovery in Azure folder  
   `Get-ChildItem -Path . -Recurse | Unblock-File`
- After unblocking, you can execute the script from the folder

**Authentication Errors:**
- Ensure you have the required Azure roles assigned
- For local environments, run `Connect-AzAccount -Tenant <tenant>` before executing the script, or let the script sign you in
- A run prompts at most once. If it stops with "did not give a usable token", run the `Connect-AzAccount` command it prints yourself, complete any MFA or Conditional Access prompt, then re-run
- "Get-AzSubscription returned no subscriptions" — usually a Conditional Access / MFA gate. Re-run with `-DeviceLogin` to use the browser-based device-code flow.
- Tenant-domain-style `-TenantID` (e.g. `contoso.onmicrosoft.com`) is resolved via Microsoft's public OIDC discovery endpoint, no sign-in needed. Pass the tenant GUID directly if discovery fails.

**Subscription returned 0 resources:**
- Both scripts stop up front when the identity's roles do not let it read a subscription (see [Subscription access check](#subscription-access-check-up-front)), so a subscription that passed that check and returned 0 resources is genuinely empty; the wrapper labels it that way at the end of the run.
- Failed subs are listed at the end of the wrapper transcript and in `InventoryReports/RunAllSubscriptions_failures_<timestamp>.log`.

**"subscription(s) are NOT readable by the signed-in identity" (those subscriptions are skipped; the run stops only when none is readable):**
- `no role grants read access (roles visible: ...)`: none of the listed roles can read resources at the subscription (for example Reader on one resource group only, or Billing Reader only). Grant Reader at the subscription, or for one resource group run `ResourceInventory.ps1 -SubscriptionID ... -ResourceGroup ...`.
- `no read access (role assignments not visible to this identity)`: the identity cannot see its role assignments and Azure reports no read access. Grant Reader at the subscription.
- `role assignments show ..., but Azure reports ...`: the two answers disagree, usually right after a role change. Wait about 5 minutes and re-run.
- `role check inconclusive after retries`: throttling or a network error persisted, or the identity's role assignment list was longer than 1000 pages; re-run.
- `role '...' at ... excludes '...'; the inventory would miss those resources`: the role reads resources except some resource types, which Resource Graph would leave out without an error. Grant Reader at the subscription (Reader beside the custom role is enough).

**Run stops immediately with "Consumption data was requested (no -SkipConsumption), but ... returned no usage values":**
- Whenever consumption is requested, `Run-AllSubscriptions.ps1` and a direct run of `ResourceInventory.ps1` check that every subscription in the run returns usage values before doing any other work (see [Consumption data check](#consumption-data-check-up-front)). If one does not, the run lists each failing subscription and **stops with exit code 1** rather than producing a report without consumption data.
- Each failing subscription shows one of these outcomes: `NoRows` (the query succeeded but returned no usage rows; for a `-ResourceGroup` run, none for that resource group), `NoPositiveQuantity` (rows came back, none with a quantity above zero, or none in the first 50 pages), `Denied` (the query was refused for lack of permission), or `Error` (any other failure that persisted after retries).
- `NoRows` and `NoPositiveQuantity` stop the run only when the role check did not confirm the usage permission by both of its answers. A subscription whose roles and Azure's effective permissions both include it passes with a yellow `NoUsage` warning instead (see [Consumption data check](#consumption-data-check-up-front)): typically a new subscription, one with only free resources, or one whose resources are paused. Its consumption sheet is empty.
- Fix: give the signed-in identity `Microsoft.Commerce/UsageAggregates/read` on each listed subscription, at the subscription or above. The built-in **Reader** and **Billing Reader** roles include it; **Cost Management Reader does not**. Under "Usage permission found by the role check" the run says per subscription whether its roles include it.
- If the identity already has it, the subscription may be partner-managed (CSP) without cost visibility for this identity, or on an offer the legacy usage API (`Get-UsageAggregates`) does not serve.
- Or re-run with `-SkipConsumption` to inventory without consumption data.

**Consumption sheet empty across many subs:**
- Usually a broken `Az` PowerShell module install (manifest present, bundled MSAL/Azure.Core assemblies missing or version-mismatched).
- The wrapper surfaces this loudly at end-of-run if the consumption-record count is 0 or many subs failed in the consumption phase.
- Reinstall: `Get-Module Az* -ListAvailable | Uninstall-Module -Force; Install-Module -Name Az.Accounts,Az.Compute,Az.Monitor,Az.Billing -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck -Scope CurrentUser`

**Cloud Shell session ended mid-run:**
- Cloud Shell terminates inactive sessions after 20 minutes; long parallel runs can hit the same wall.
- If you mounted storage (Settings > Mount storage account), the resume-state file persists. Re-launch a Cloud Shell and run with `-Resume` to skip already-completed subs.
- Without mounted storage, all output is lost on session end. Move to a local PowerShell 7 install for runs that may exceed the timeout.

**Performance Issues:**
- Reduce `ConcurrencyLimit` if experiencing timeouts
- Use `SkipConsumption` to speed up execution. This is not recommended, as it greatly reduces the usefulness of the report.
- Consider targeting specific subscriptions or resource groups
- For tenants with many subscriptions, use `-ParallelStreams` (see the Cloud Shell sizing table above).

**VM `OSName` shows the image name (or is based on OS type):**
- `OSName`/`OSVersion` come from the in-guest VM agent, exposed by Azure via `properties.extended.instanceView`. Azure frequently returns these as null — always for stopped/deallocated VMs, and often even for running VMs with a healthy agent (a documented Azure platform limitation, [azure-cli#9284](https://github.com/Azure/azure-cli/issues/9284) / [azure-powershell#9470](https://github.com/Azure/azure-powershell/issues/9470)). A live per-VM instance-view call returns the same nulls, so it is not a reliable source.
- To keep the column meaningful, when the agent value is absent the report falls back to the VM's source image identity (image offer + SKU, e.g. `WindowsServer 2025-datacenter-azure-edition`), and finally to the OS type (`Windows`/`Linux`). Both of these are always populated by Resource Graph and require no extra calls.
- `OSVersion` still comes straight from the agent and may be blank when the agent does not report it; the image build is available separately in the `ImageVersion` column.

**HTML Report:**
- The report is a single self-contained `.html` file — open it in any browser. No Excel or ImportExcel module is required.
- It works the same in Azure Cloud Shell and locally; nothing extra to install.
- For a PDF, open the report and use your browser's Print > Save as PDF (the report has a print-friendly layout that expands every section).

**Missing resource types in the report ("Collector Failures"):**
- If a specific resource type (e.g. AKS, VMSS) is unexpectedly absent from a subscription's report even though that resource type exists in Azure, check the run's console output for a `Collector FAILED:` line and the end-of-run "Collector Failures" summary.
- This means the corresponding `Services/*/*.ps1` collector threw for that subscription — the resource type is **missing because the collector errored**, not because there are genuinely none of that type. The rest of the inventory still completes and the report is still produced.
- Re-run to retry. If the same collector keeps failing, investigate the error message shown (it is not swallowed).
- If 5 or more collectors fail back-to-back for the same subscription, the run stops early for that subscription — this pattern almost always means something systemic broke mid-run (auth dropped, network lost, a broken `Az` module), not a bug in one specific collector.

### Exit Codes (Run-AllSubscriptions.ps1)

The wrapper script sets a process exit code so automation/CI can detect problems without parsing console output:

| Code | Meaning |
|---|---|
| `0` | Clean run — no failures of any kind. |
| `1` | Hard failure during pre-flight, authentication, or setup (most of these stop the run before it collects anything). This includes, with `-ParallelStreams`, something already at one of this run's stream summary paths (their names hold the run's own id) that could not be removed: the run stops before any stream starts, so nothing is collected; remove it by hand and run again. It also includes a resume state file or a stream resume state file that is there but cannot be opened (locked, no access): it may hold failures still to retry, so the run stops before it merges it into the resume state. That is at the start, before any subscription and before the resume state is written, except for a stream resume state file that cannot be opened when the streams are done (it may have been readable at the start): then the stop comes after them, their reports are kept, their records are kept in the stream resume state files (and in the resume state, for a stream that could not start or write its own; when the resume state cannot be written either, those records go to a stream resume state file of their own, `.resume-state-<TenantID>-stream-summary-<run id>.json`, which the next run reads at its start, so its `-ResumeFailedOnly` retries them; only when that file cannot be written too, the stop names each subscription whose record is therefore in no file, by name and id, and keeps the stream summaries that hold them, which no run reads: `-ResumeFailedOnly` does not retry those subscriptions, so once the file can be opened, run again without `-Resume` and `-ResumeFailedOnly`, as a plain run runs every subscription, then remove the kept stream summaries), the file that could not be opened is kept, and no consolidated zip is made; the next run stops at its start until that file can be opened. Fix its permissions and run again, or move it away to drop its records. It also includes the consumption data check stopping the run because a subscription returned no usage values (see [Consumption data check](#consumption-data-check-up-front)), and a per-stream resume state file that cannot be read and cannot be moved aside: at the start of `-Resume` or `-ResumeFailedOnly` the run stops before it collects anything, and found by the end-of-run merge the run ends with exit 1 in place of 0 and 3-5. It is also given when a per-stream resume state file of an earlier run could not be removed, or its records could not be saved into the resume state file (it is named, with what to do), and when a stream summary file an earlier parallel run left (`.rda-stream-<N>-summary.json`) cannot be removed before the streams start; the run stops there, before it collects anything. Found at the end of a run, a per-stream resume state file that cannot be read or moved aside gives exit 1 too (below). |
| `2` | A subscription's report is missing from the consolidated zip, or cannot be confirmed. Either one or more subscriptions failed (they are listed under `Subscriptions Failed`): the consolidated zip is still made and holds the reports of the subscriptions that worked, or no zip is made when none worked. Or a per-subscription output verification gap (a subscription reported success but its output zip is missing, also when the whole inventory folder is gone): the run stops before consolidation, so no zip is made. Or, with `-ParallelStreams`, a stream's summary file is missing or could not be read (a summary that is not a JSON object, is from another run, names another stream, has no row for a subscription the stream ran, or holds in a field the wrapper reads a value the stream never writes, such as a success row with no Count, a Count that is not a whole number of 0 or more, a Zip that is not a path, or a ConsumptionRecords that is not a whole number, counts as one that could not be read): that stream's subscriptions are not confirmed (they are not counted as failed, and their reports may well be in the consolidated zip), so check the zip, if one was made; the console prints `Stream Summary Missing` or `Stream Summary Unreadable` for it. When every stream summary is read, the consolidated zip holds only the zips this run's subscriptions named, so a zip another run writes under the same inventory root at the same time is left out. Takes precedence over `3`–`5`. The last console lines (`Exit code 2: ...`) say which case it is and name any condition `2` hides (Metrics/Consumption skipped for sign-in, collector failures). For a failed subscription, or a missing or unreadable stream summary, the "FAILED (auth)" and "FAILED (collectors)" banners also print, and when a consolidated zip is made its `RunSummary.log` holds the same lines under `Exit code:`. For a verification gap, the run stops right after the "Per-subscription output verification failed" block: it prints the failed-subscription count (if any) and the `Exit code 2: ...` lines, but no Summary block, no FAILED banners and no `RunSummary.log`. It is also given when a per-stream resume state file could not be removed at the end of the run (it is named in a warning: remove it before the next run), a subscription on the retry list is not in the run's subscription set (`Not In This Run`: for example disabled without `-IncludeDisabled`; fix that, or delete the resume state files to start over), a `-ResumeFailedOnly` run found none of the subscriptions on the retry list in the current subscription set, a per-subscription output verification gap (a subscription reported success but its output zip is missing, or the whole inventory folder is gone at the end of the run), the consolidated `AllSubscriptions_ResourcesReport_<timestamp>.zip` could not be built or was lost while the run summary was added to it, for example because the disk is full, or passed its checks but found every name taken (it is then kept as `rda-build-<id>.partial`, named in the banner) (see the "FAILED (consolidated zip)" banner; except when the inventory folder itself is gone, the per-subscription report zips are still on disk under it), or a `-Resume` run could not carry the report of a subscription it skipped as already completed (see the "FAILED (earlier report not carried)" banner). Also when a save of the resume state failed and the file is still there (see the "FAILED (resume state not saved)" banner: run again without `-Resume` or `-ResumeFailedOnly`), and when the end-of-run merge keeps per-stream resume state files because the saved resume state does not hold their records (the state is kept for the next run). Also when a `-Resume` or `-ResumeFailedOnly` run skipped a subscription that failed 3 runs in a row, or a run left out such a subscription because it is not in its subscription set (both named under `Retry Limit Reached`; see [Resuming an interrupted run](#resuming-an-interrupted-run)), when a `-ResumeFailedOnly` run found only such subscriptions on the retry list (`nothing left to retry`), when a `-ResumeFailedOnly` run found the retry list empty while subscriptions that no run has completed remain (`Not Collected`), and when the failed-run count of a subscription could not be saved before collecting it, so it was not collected (free disk space or fix the folder, then run again). |
| `3` | Completed, but a requested data phase (Metrics and/or Consumption) was skipped for one or more subscriptions due to an authentication problem — see the "FAILED (auth)" banner. |
| `4` | Completed, but one or more `Services/*/*.ps1` collectors failed for one or more subscriptions — see the "FAILED (collectors)" banner and "Collector Failures" summary. Affected resource types are missing (not empty) from those subscriptions' reports. |
| `5` | Both `3` and `4` occurred in the same run. |

A direct run of `ResourceInventory.ps1` (without `-RunAllSubs`) exits `1` and writes no report when Resource Graph discovery fails, for example when a page of results cannot be read or a query still fails after 4 attempts; the console shows `Resource discovery failed` followed by the Resource Graph error. Under `-RunAllSubs` that subscription is listed as failed instead, and `-ResumeFailedOnly` retries it.

Codes `3`–`5` still mean the report was produced — they flag that it is **incomplete** in a specific, diagnosable way, rather than silently looking like a clean/empty result. Code `2` can come with a consolidated zip too (see above), so check for the `AllSubscriptions_ResourcesReport_*.zip` file, or the `Exit code:` lines, rather than reading `2` as "no report".

A direct run of `ResourceInventory.ps1` also ends with exit code `1` when the consumption data check stops it.

### Exit Codes (ResourceInventory.ps1, direct run)

A direct `ResourceInventory.ps1` run (without `-RunAllSubs`) also sets an exit code:

| Code | Meaning |
|---|---|
| `0` | Completed; the report and zip were written and no collector failed. |
| `1` | The run stopped during setup, before it collected anything, and the red error line printed before it gives the cause: for example a pre-flight check (`-Service` matched no collector, or the `-ObfuscationDictionary` file is missing or not valid JSON), the output folder cannot be written, the Azure CLI is not installed, a service principal sign-in has no `-Secret`, or `-ResourceGroup` is given without `-SubscriptionID`. |
| `2` | The run ended without writing its report zip, and its last console line says `No report was written`. This happens, for example, when 5 collectors failed in a row and collection stopped, or when the HTML report or the zip could not be written; the errors printed before that line give the cause. |
| `4` | Completed and the report and zip were written, but one or more `Services/*/*.ps1` collectors failed. Those resource types are missing (not empty) from the report; its "Incomplete collection" banner names them. |

Under `-RunAllSubs`, which is how `Run-AllSubscriptions.ps1` calls it, the script does not exit `2` or `4`; the wrapper's codes above apply, and a run that stops during setup counts as a failed subscription.
### Important Notes

- The script does not upgrade existing PowerShell modules
- All operations are read-only and safe to execute
- Historical data covers the previous 31 days

