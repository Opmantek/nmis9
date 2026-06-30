# collect_services optimisation (service-type SNMP process walk) — Design

Date: 2026-06-30
Branch: `collect-services-optimisation`, rooted from `origin/nmis9_dev` (`158e2c34`, includes merged PR #184)
Ticket: TBD

## Problem

A customer monitors many net-snmp nodes. The NMIS server load is high and several nodes have very long collect times, dominated by `collect_services`. On one representative node:

```
collect_intf_data_time:        1.41
collect_node_data_time:        1.03
collect_server_data_time:      13.78
collect_services_time:        108.89
collect_systemhealth_data_time: 9.94
handle_custom_alerts_time:      0.16
```

`collect_services` is ~109 s of a ~135 s collect. That node's service list is seven entries — Chrony, SSH, SNMP, sssd, Firewalld, Syslog, crond — all `Service_Type => 'service'` with empty `Service_Parameters`.

## Confirmed diagnosis (grounded in code + the customer's Services.nmis)

- All seven services use the in-memory match path (`lib/NMISNG/Node.pm:8694-8763`): they `grep` the already-gathered process list. No external commands. Their individual check cost is negligible.
- The cost is the per-node SNMP `hrSWRunTable` walk (`Node.pm:8236-8314`), done once whenever any `service`-type service is configured. It walks seven full columns of the host's entire running-process table — `hrSWRunName`, `hrSWRunPath`, `hrSWRunParameters`, `hrSWRunStatus`, `hrSWRunType`, `hrSWRunPerfCPU`, `hrSWRunPerfMem` (`Node.pm:8251-8254`) — with `getindex` retry/back-off on slow agents (`Node.pm:8248-8250`).
- `hrSWRunPerfCPU` (`.1.3.6.1.2.1.25.5.1.1.1`) and `hrSWRunPerfMem` (`.1.3.6.1.2.1.25.5.1.1.2`) require the agent to compute per-process CPU/memory across the whole table and are the most likely dominant cost. This is a hypothesis, confirmed per node by timing each column's `snmpbulkwalk` (see Diagnostics).
- For an up/down check only `hrSWRunName` + `hrSWRunStatus` are required. The other columns serve display and extras:
  - `hrSWRunPath`/`hrSWRunParameters` — used for matching only when a service sets `Service_Parameters` (none on this node), AND displayed as the **Parameters** column of the GUI "Running services" process table (`cgi-bin/network.pl:4048`), which is sourced from the `snmp_services` inventory timed data (`network.pl:4005-4013`).
  - `hrSWRunType` — displayed as the **Type** column (`network.pl:4049`).
  - `hrSWRunPerfCPU`/`hrSWRunPerfMem` — the **CPU Time**/**Memory** columns of that table, plus per-service `cpu`/`memory` RRD graphs (`Node.pm:8757-8758`).

## Goal and scope

Give operators a per-node-tunable knob to reduce the SNMP service walk to only the columns a node needs, defaulting to today's behaviour so nothing changes unless opted in.

In scope: the `service`-type SNMP walk inside `collect_services`.
Out of scope: the `port`/`dns`/`script`/`program` service types (this node uses none); walk-frequency gating (deferred, see Follow-ups).

## Design

### Config option (trinary)

`collect_services_process_detail`, three values:

| Level | Columns walked | `snmp_services` table saved | per-service cpu/mem | network_service_list page |
|---|---|---|---|---|
| `full` (default) | all 7 | yes, with cpu/mem | yes | unchanged — exactly today |
| `noperf` | Name, Path, Parameters, Status, Type (drops `PerfCPU`/`PerfMem`) | yes, without cpu/mem | no | Service / Parameters / Type / Status / PID shown; CPU Time + Memory blank |
| `minimal` | Name, Status (+ Path/Parameters only if a configured service matches on `Service_Parameters`) | no | no | process table empty; per-service up/down status only |

Resolution order (per-node override beats global): node `configuration->{collect_services_process_detail}` if set, else global `Config.nmis` value, else built-in default `full`. An unrecognised value falls back to `full` with a logged warning.

The global default value lives in `conf-default/Config.nmis`; the per-node override is read from the node's `configuration`. The option must also be registered in the GUI table-definition files so it is editable in the web UI rather than only hand-edited — see "Config registration" below.

(Config key and level value names are proposals, open to house style.)

### Column selection (`Node.pm` ~8251)

```perl
my @cols = ('hrSWRunName', 'hrSWRunStatus');                   # always — up/down
if ($detail eq 'minimal') {
    push @cols, ('hrSWRunPath', 'hrSWRunParameters') if $need_params;
} else {                                                       # noperf or full
    push @cols, ('hrSWRunPath', 'hrSWRunParameters', 'hrSWRunType');
    push @cols, ('hrSWRunPerfCPU', 'hrSWRunPerfMem') if ($detail eq 'full');
}
```

`$need_params` is true iff at least one `service`-type service configured on this node has a non-empty `Service_Parameters`. The configured set is `$self->configuration->{services}` intersected with the Services table `$ST`.

### Code touch points (`collect_services`, base `158e2c34`)

1. Resolve `$detail` near the top of `collect_services` (after `$C`, ~`8220`), with the per-node/global/default lookup and validation above.
2. Compute `$need_params` from the node's configured `service`-type services.
3. Replace the fixed column list (`8251-8254`) with the level-based `@cols`.
4. Gate the `snmp_services` timed-data save and its stale-process-event clearing (`8421-8454`) to run for `full`/`noperf`, skip for `minimal`.
5. Gate the per-service cpu/mem block (`8749-8761`, `gotMemCpu`) to run only for `full`.
6. No change to per-service up/down logic, Service Down/Degraded events, the `service`/`responsetime` RRD, or any other service type.

### Config registration (default value + GUI editors)

The option is registered in three files so it has a default and is editable in the NMIS GUI, not only by hand-editing config:

1. `conf-default/Config.nmis` — the global default **value**, in the `system` section:
   ```perl
   'collect_services_process_detail' => 'full',
   ```
2. `conf-default/Table-Config.nmis` — the global **Config editor** dropdown, in `Config` -> `system` (near `cbqos_cm_collect_all`):
   ```perl
   { 'collect_services_process_detail' => { display => 'popup', value => ["full", "noperf", "minimal"] }},
   ```
3. `conf-default/Table-Nodes.nmis` — the **per-node override** field, in the `Nodes` array near the `services` field. The first value is empty, meaning "inherit the global default":
   ```perl
   { collect_services_process_detail => { header => 'Service Process Detail',
       display => 'popup', value => ["", "full", "noperf", "minimal"] }},
   ```

(Note: the file is `Table-Nodes.nmis`, plural — there is no `Table-Node.nmis`.) The empty per-node value is what makes "node value set" an explicit override that otherwise falls through to the global default. The field name must match the config key the code reads, `$self->configuration->{collect_services_process_detail}`.

## Behaviour preservation

- `full` (default): the walk gathers the same seven columns and all downstream data (`snmp_services`, per-service cpu/mem) is produced exactly as today. Each column is fetched by an independent `getindex`, so the level-based list is functionally identical to the current fixed list; the implementation should preserve the existing column set for `full`.
- `noperf`: service up/down unchanged. The GUI process table still lists Service/Parameters/Type/Status/PID; only CPU Time + Memory are blank. Per-service cpu/mem graphs stop.
- `minimal`: service up/down unchanged (matching still correct — Path/Parameters fetched when a service needs them). The GUI "Running services" process table is empty for that node. Per-service cpu/mem graphs stop.

## Diagnostics: choosing the level per node

Time each column's walk on the node (SNMPv3 authPriv, SHA + AES, example):

```bash
AUTH=(-v3 -l authPriv -u '<username>' -a SHA -A '<authpass>' -x AES -X '<privpass>')
time snmpbulkwalk "${AUTH[@]}" '<host>' 1.3.6.1.2.1.25.4.2.1.2   # hrSWRunName    (cheap baseline)
time snmpbulkwalk "${AUTH[@]}" '<host>' 1.3.6.1.2.1.25.4.2.1.7   # hrSWRunStatus  (cheap)
time snmpbulkwalk "${AUTH[@]}" '<host>' 1.3.6.1.2.1.25.5.1.1.1   # hrSWRunPerfCPU (suspect)
time snmpbulkwalk "${AUTH[@]}" '<host>' 1.3.6.1.2.1.25.5.1.1.2   # hrSWRunPerfMem (suspect)
```

- If `PerfCPU`/`PerfMem` dominate, `noperf` should resolve it while keeping the process table and Parameters display.
- If `Name`/`Status` are also slow (the agent is slow on the whole table, not just the perf columns), set that node to `minimal`.

The trinary lets an operator dial `full` -> `noperf` -> `minimal` per node from this evidence, with no code change.

## Testing

`test/t_collect_services.pl`, driving `collect_services` with a `NMISNG::Snmp::Mock` over a small fake `hrSWRunTable` plus a couple of configured services:

- `full`: all 7 columns walked; `snmp_services` saved with cpu/mem; per-service cpu/mem DS present; result identical to today.
- `noperf`: `PerfCPU`/`PerfMem` not walked; `snmp_services` saved without cpu/mem; no cpu/mem DS; up/down correct.
- `minimal`: only `Name`/`Status` walked; `snmp_services` not saved; up/down correct.
- param-matching at `minimal`: a configured service with non-empty `Service_Parameters` causes Path/Parameters to be walked and still matches.
- per-node override: global `full` + node `minimal` resolves to `minimal` for that node; an empty per-node value falls through to the global default.
- GUI registration: the option appears as a dropdown in the global Config editor (`Table-Config.nmis`) and as a per-node field with an inherit/empty option in the node editor (`Table-Nodes.nmis`).

## Follow-ups (deferred)

- Walk-frequency gating (Approach B): skip the `hrSWRunTable` walk on collect cycles where no `service`-type service is actually due (respecting `Poll_Interval`), instead of walking every collect. Separate change; marginal once the walk is lean, and it interacts with the `snmp_services` process graphs.

## Open items

- Config key and level names (`collect_services_process_detail` / `full`|`noperf`|`minimal`) are proposals.
- The per-column timing confirms which level a given node needs; the design supports all three without code change.
