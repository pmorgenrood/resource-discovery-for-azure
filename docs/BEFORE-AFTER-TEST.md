# Before and After test for Resource Discovery for Azure

This test runs the tool twice on one test subscription:

- **Before**: the current release, from github.com/awslabs/resource-discovery-for-azure (branch `main`).
- **After**: the new fixes, from github.com/pmorgenrood/resource-discovery-for-azure (branch `all-fixes-optimized`).

You send back the files in `share/`: two report zips and `ab-summary.json` (with `-Obfuscate`, maybe only the After zip and the summary, see below). We use them to check that the new fixes lose no data.

Both runs only read from Azure. They change nothing in your subscription. The script sends nothing anywhere: you send the files yourself. If it signs you in to Az PowerShell, that sign-in becomes your saved default. It changes the Azure CLI's active subscription only if you say yes when it asks. The current release (Before) may set your default Az PowerShell subscription to the test subscription, and may add the Azure CLI extension `resource-graph` by itself (that needs internet access).

## What you need

- Git, to get the script.
- PowerShell 7.2 or newer (Windows, macOS, Linux or Azure Cloud Shell).
- These Az PowerShell modules: Az.Accounts 5.5.4 or newer, Az.Compute, Az.Monitor, Az.Billing.
- The Azure CLI (`az`), signed in to your tenant. The Before version still uses it. The After version does not.
- Reader on the test subscription (the same access the tool always needs).

The script checks all of this first:

- **PowerShell too old**: it stops and shows how to install PowerShell 7 for your system.
- **Az modules missing or too old**: it lists them and asks `Install/update them now for your user only? [Y/N]`. Say Y and it installs them from the PowerShell Gallery into your own user folder. No admin rights are needed. Say N and it stops and shows the exact commands. PowerShell may then ask once more if you trust the PowerShell Gallery: answer Y.
- **Azure CLI missing**: it stops and shows how to install it. It does not install it for you.
- **Azure CLI not signed in**: it asks `Sign in to the Azure CLI now? [Y/N]`. Say Y and it runs `az login --tenant <tenant id>`. Cloud Shell is signed in already, so it skips this.
- **Test subscription not in the Azure CLI's list**: the CLI refreshes its list only when you sign in. The Before version collects billing only for subscriptions in that list. So the script asks `Sign in to the Azure CLI now? [Y/N]` again.
- **Azure CLI on another tenant**: the Before version would sign the Azure CLI out of every account and ask again. So the script asks `Switch the Azure CLI to this subscription now? [Y/N]`. Say Y and it runs `az account set --subscription <id>`. Say N and it stops and shows that command.
- **Az PowerShell default on another tenant**: the Before version would ask you to sign in again. The script stops and shows `Set-AzContext -Tenant <tenant id> -Subscription <id>`, which makes this tenant your default. Run it, then run the script again.
- **Reader**: after you sign in, it checks that you can read the subscription. For the Before version it also checks the Azure CLI's own sign-in, which can be another account. If you clearly cannot, it stops and tells you to ask for the Reader role. It never gives or changes roles.

If PowerShell cannot ask questions (for example when started with `-NonInteractive`), it does not ask. It stops and shows the commands to run.

## Run it

Open PowerShell 7 and run:

```powershell
git clone -b all-fixes-optimized https://github.com/pmorgenrood/resource-discovery-for-azure.git
cd resource-discovery-for-azure
pwsh ./Invoke-RdaBeforeAfter.ps1 -TenantID <tenant id> -SubscriptionID <test subscription id>
```

To mask names and ids in the reports, add `-Obfuscate`:

```powershell
pwsh ./Invoke-RdaBeforeAfter.ps1 -TenantID <tenant id> -SubscriptionID <test subscription id> -Obfuscate
```

To check everything first without starting the runs, add `-PreflightOnly`. It ends with "Every check passed" when the real run is ready.

The script downloads both versions from GitHub itself. It does not run the code in the folder you cloned.

It uses your current Az PowerShell sign-in. If there is none, it asks you to sign in once. Add `-DeviceLogin` to sign in with a code instead of a browser window. The two runs then use a code too, if they have to sign in.

Each run takes about as long as one normal run of the tool on that subscription. The runs go one after the other.

## What comes back

A new folder `rda-before-after-<date and time>`, in the folder you ran it from, holds:

| Folder | What | Send it? |
|---|---|---|
| `share/` | `RDA-Before_...zip`, `RDA-After_...zip`, `ab-summary.json` | **Yes** (see the `-Obfuscate` note below) |
| `private/` | each run's full report folder and logs | No, keep it |

- The two zips are the tool's own report zips, renamed to show which version made them.
- `ab-summary.json` holds counts, timings and versions only: no names, no ids.
- **Without `-Obfuscate`**, the zips hold your real resource names and ids, the same as the tool's normal report.
- **With `-Obfuscate`, check the Before zip before you send it.** The current release still leaves the real name of an Azure SQL server inside the masked ids of its databases. The new fixes mask it. If that name is private, send the After zip and `ab-summary.json` only, and tell us.
- **With `-Obfuscate`**, each run makes its own dictionary (the key that turns the masks back into real names). The dictionaries stay in `private/`. Keep them, and do not send them. The two runs use different masks, so we compare counts, not names.

## Differences you should expect

- The current release (Before) reads Azure Virtual Desktop resources from every subscription its Azure CLI sign-in can see, not only the test subscription. The new fixes read only the test subscription. So Before can hold extra Azure Virtual Desktop rows from other subscriptions. That is a fix, not lost data. With `-Obfuscate` those rows are masked like the rest.

## Options

| Option | Use |
|---|---|
| `-OutputDirectory <folder>` | Put the results in this folder (it must be new or empty). |
| `-PreflightOnly` | Do the checks only, and stop before the runs. |
| `-AfterBranch <branch>` | Test another After branch. Use `all-fixes-2026-11-02` if the default is not found. |
| `-KeepCode` | Keep the downloaded code after the runs. It is deleted by default. |
| `-DeviceLogin` | Sign in with a code instead of a browser window, here and in both runs. |
| `-BeforeCodePath <folder or zip>` | Use this code for Before instead of downloading awslabs main. Most people do not need this. |
| `-AfterCodePath <folder or zip>` | The same, for After. |

## If something goes wrong

The script ends with exit code 0 when both runs wrote their report zip and every file in them could be read, and 1 when a check or a run failed. A run of the new version can end with exit 3, 4 or 5: its report was written, with some data missing (see the exit-code table in README.md). The script then still ends with 0 and prints that run's exit code. It prints what to do. If a run failed, send the files anyway: they show what went wrong.
