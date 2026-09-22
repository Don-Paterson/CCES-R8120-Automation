# Manual steps the automation deliberately leaves to you

The scripts stop short of anything that is part of the teaching content of the lab, or that
needs a judgement call in SmartConsole.

## After Stage 1 (`Invoke-AEPM-FTW.ps1`), before the Jumbo

1. Launch **SmartConsole** from A-GUI and connect to **A-EPM (10.1.1.103)** as `cpadmin`.
2. Open the management object (`A-EPM`) and enable:
   * **Endpoint Policy Management**
   * **SmartEvent Server** / **SmartEvent Correlation Unit** as the lab guide directs
3. Configure **NAT** as per the lab guide so the endpoint clients can reach the server.
4. **Install the policy**, and let the server settle before running `Install-JumboT26.ps1`.

Why the order matters: enabling blades rewrites the installed product list, and doing it after
the Jumbo means the newly enabled blade binaries are the pre-Jumbo ones.

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
