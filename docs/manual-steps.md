# Manual steps the automation deliberately leaves to you

The scripts stop short of anything that is part of the teaching content of the lab, or that
needs a judgement call in SmartConsole.

## After Stage 1 (`Invoke-AEPM-FTW.ps1`), before the Jumbo

This is **Lab 2A, "Deploy an Endpoint Security Management Server", pages 149 to 174** of
the CCES R81.20 lab guide (Kortext). The automation has already done Task 2A-1's licences
and contracts; work through the rest by hand:

1. Launch **SmartConsole** from A-GUI and connect to **A-EPM (10.1.1.103)** as `cpadmin`.
2. Open the management object (`A-EPM`) and enable:
   * **Endpoint Policy Management**
   * **SmartEvent Server** / **SmartEvent Correlation Unit** as the lab guide directs
3. Configure **NAT** as per the lab guide so the endpoint clients can reach the server.
4. **Install the policy**, and let the server settle.

**The script picks up again at page 175** - Task 2A-3, Install the Jumbo Hotfix
Accumulator - which is menu option 4, or `.\Install-JumboT26.ps1`.

### Where the automation overlaps the lab guide

**Pages 161-164 have the student install the licence by hand.** `Invoke-AEPM-FTW.ps1`
has already done it with `cplic put -l`, so those pages are a no-op for a student working
on an automated build - the steps still work, they simply find the licence already there.

One consequence worth knowing before a student asks: the licence does **not** attach to
the object in SmartConsole / SmartUpdate on its own. Right-click the machine and choose
**Get Licenses** to pull it into the management repository.

**Contracts behave the same way.** `cplic contract put -o` installs the contract on
A-EPM itself, and `cplic print -x` on the box then shows the Contract Coverage table.
SmartUpdate's *License and Contract Repository* is a separate, management-side view and
can still report "Has Contracts: No" / "No contracts found" until the contract is added
there too. Verify on the box with `cplic print -x` before concluding the contract
did not install.

Why the order matters: enabling blades rewrites the installed product list, and doing it
after the Jumbo means the newly enabled blade binaries are the pre-Jumbo ones.

> **Note on Task 2A-3.1**: the lab guide asks you to verify `DeploymentAgent_000002325_1.tgz`
> is present, but the lab image ships `DeploymentAgent_000002337_1.tgz` - a newer build.
> The automation uses whatever `DeploymentAgent` is named in `config\lab-settings.psd1`,
> and skips the install when the agent already on the box is the same build or newer.

## Before Stage 3 (`Invoke-AEPM02-FTW.ps1`)

In SmartConsole on **A-EPM**:

1. **New > Server > Secondary Security Management Server** (or *More object types >
   Network Object > Gateways and Servers*).
2. Name `A-EPM-02`, IPv4 address `10.1.1.104`.
3. Set the **one-time password** for SIC — this must match `-SicKey` / `SicKey` in
   `config\lab-settings.psd1` (`ftw_sic_key` in the answer file).
4. **Publish**.

Then run the script. Afterwards, back in SmartConsole:

5. Open the `A-EPM-02` object and confirm SIC trust is established.
6. **Menu > Management High Availability** — synchronise the peers.

## Service contract

`cplic contract put -o <file>` is automated, but if it is refused, the contract can be added
by hand:

* SmartConsole: **Menu > Manage licenses and packages**, then add the `ServiceContract.xml`
* or on the box: `cplic contract put -o /var/log/ServiceContract.xml`

Verify with `cplic print -x` and `contract_util print`.

## Endpoint clients

Deployment of the E87.50 client packages from `Desktop\Check Point Tools` is lab content and is
not automated here.
