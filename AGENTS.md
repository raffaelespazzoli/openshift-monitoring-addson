# Agent Instructions

Rules for AI agents working in this repository.

## Recording Rule Naming Convention

All Prometheus recording rules follow a **4-part, 3-colon** naming scheme:

```
<level>:<functional_area>:<metric>:<unit>
```

| Part | Definition | Examples |
|------|-----------|---------|
| **level** | Output labels the rule aggregates to. Multiple label dimensions are joined with underscores. | `cluster` (scalar), `node`, `node_nic`, `node_hba`, `pod`, `container`, `vmi` |
| **functional_area** | The monitoring domain the rule belongs to. | `memory`, `cpu`, `network`, `io`, `fc`, `capacity` |
| **metric** | What is being measured. Use underscores, keep it descriptive. | `workloads_utilization`, `transmit_utilization`, `launcher_overhead_memory` |
| **unit** | Unit of the output value. | `bytes`, `ratio`, `cores`, `days`, `seconds`, `packets_per_second` |

### Functional area tokens

| Token | Covers | Directory |
|-------|--------|-----------|
| `memory` | Node memory breakdown, OOM proximity | `memory/` |
| `cpu` | CPU pressure (PSI), vCPU scheduling delay | `cpu/` |
| `network` | NIC utilization, VM network drops/errors/throughput | `networking/` |
| `io` | I/O pressure (PSI), VM storage latency/throughput | `storage/` |
| `fc` | Fibre Channel HBA utilization and errors | `storage/` |
| `capacity` | Capacity accounting, exhaustion projections, overcommit, launcher overhead | `capacity/` |

### Level tokens

| Token | Output labels | Meaning |
|-------|--------------|---------|
| `cluster` | none (scalar) | Cluster-wide aggregate |
| `node` | `{node}` | Per schedulable node |
| `node_nic` | `{instance, device}` | Per physical NIC per node |
| `node_hba` | `{instance, fc_host}` | Per Fibre Channel HBA per node |
| `pod` | `{namespace, pod}` | Per pod |
| `container` | `{namespace, pod, container}` | Per container |
| `vmi` | `{namespace, name, node}` | Per virtual machine instance |

### Examples

```
node:memory:workloads_utilization:ratio       ← per-node, memory domain, measures workloads utilization, unit is ratio
cluster:capacity:total_memory:bytes           ← cluster scalar, capacity domain, total memory, bytes
node_nic:network:transmit_utilization:ratio   ← per-NIC, network domain, transmit utilization, ratio
vmi:io:read_latency:seconds                   ← per-VM, I/O domain, read latency, seconds
```

**Never deviate from 3 colons.** If a name would have fewer or more, restructure the parts.

## Directory Structure

Each functional area is a self-contained kustomize folder with two files:

```
<area>/
├── kustomization.yaml      # references both files below
├── recording-rules.yaml    # PrometheusRule CR with recording rules
└── alerts.yaml             # PrometheusRule CR with alert rules
```

Areas are: `memory/`, `cpu/`, `networking/`, `storage/`, `capacity/`.

Rules:
- Recording rules and alerts within an area depend only on each other and on in-cluster metrics.
- No cross-area dependencies between recording rules or alerts.
- The `capacity/` area's recording rules feed the dashboards — deploy `capacity/` alongside `dashboards/` when using capacity planning dashboards.
- The root `kustomization.yaml` is the "deploy everything" entry point.

## PrometheusRule CRs

All `PrometheusRule` resources use:
- **namespace:** `openshift-monitoring`
- **labels:** `prometheus: k8s`, `role: alert-rules`
- **name pattern:** `capacity-management-<area>-rules` or `capacity-management-<area>-alerts`

## Dashboards

Dashboards are CUE source → `percli dac build` → kustomize wraps.

- CUE sources live in `dashboards/dac/*.cue` (single source of truth).
- Built outputs land in `dashboards/dac/built/*_output.yaml`.
- `dashboards/kustomization.yaml` wraps them as `PersesDashboard` CRs by default.
- `dashboards/wrap-configmap.yaml` is the alternative for unmanaged Perses.
- After editing a `.cue` file, run `percli dac build -f <file>.cue` in `dashboards/dac/` and then fix the `defaultValue` format before committing (see below).

### Post-build: fix `defaultValue` format

`percli dac build` emits `defaultValue` as a multi-line object that Perses cannot unmarshal:

```yaml
defaultValue:
  singleValue: "30d"
  sliceValues: []
```

After building, collapse these to plain strings so both kustomize consumers and direct-file consumers (e.g. ConfigMap provisioning) get valid dashboards:

```sh
cd dashboards/dac/built
sed -i -E '/defaultValue:$/{N;N;s/defaultValue:\n[[:space:]]+singleValue: (.*)\n[[:space:]]+sliceValues: \[\]/defaultValue: \1/}' *_output.yaml
```

The `dashboards/kustomization.yaml` JSON patches also fix this for the kustomize pipeline, but fixing the built files at source ensures all consumers work correctly.

## When Adding New Rules

1. Place the rule in the correct functional area directory.
2. Name it using the 4-part convention.
3. If the rule creates a new functional area token, document it in this file.
4. Add the rule to the README's collapsible table for that area.
5. Update the Performance Impact section if the rule adds significant cardinality (per-pod or per-container scope).
