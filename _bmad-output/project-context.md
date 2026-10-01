# Project Context — Capacity Management for OpenShift Virtualization

## What This Repo Is

A standalone, kustomize-based collection of Prometheus recording rules, alerts, and Perses dashboards for capacity management on OpenShift Virtualization clusters. It was extracted from the `virtualization-migration-factory-reference-implementation` repo to be consumable in isolation.

## Key Architecture Decisions

### Functional area split
Rules and alerts are split into five self-contained kustomize folders: `memory/`, `cpu/`, `networking/`, `storage/`, `capacity/`. Each area is independently deployable. No cross-area dependencies exist between recording rules or alerts. Only the dashboards depend on `capacity/` recording rules.

### Recording rule naming convention
All recording rules use a strict 4-part, 3-colon naming scheme:

```
<level>:<functional_area>:<metric>:<unit>
```

- **level** — output label dimensions: `cluster` (scalar), `node`, `node_nic`, `node_hba`, `pod`, `container`, `vmi`
- **functional_area** — monitoring domain: `memory`, `cpu`, `network`, `io`, `fc`, `capacity`
- **metric** — descriptive measurement name with underscores
- **unit** — `bytes`, `ratio`, `cores`, `days`, `seconds`, `packets_per_second`, etc.

This is a project convention that extends the standard Prometheus `level:metric:operations` format by inserting a functional area. Never use fewer or more than 3 colons.

### Dashboard-as-service dual deploy
Dashboards are authored as CUE (Perses SDK) in `dashboards/dac/`, compiled by `percli dac build` to `dashboards/dac/built/`, and wrapped by kustomize into either `PersesDashboard` CRs (operator mode, default) or `ConfigMap` resources (unmanaged Perses).

### Cross-functional dashboards
Three dashboards — vm-capacity, capacity-exhaustion, vm-overcommit — combine memory and CPU data and are not assigned to any single functional area. They live in `dashboards/` and consume recording rules from `capacity/`.

### Pod-memory dashboard uses raw metrics intentionally
`pod-memory.cue` queries raw cAdvisor metrics directly instead of recording rules. This is deliberate — the dashboard aggregates across variable-filtered containers with `sum()`, and `sum(ratio)` ≠ `sum(numerator)/sum(denominator)`. Using the per-container recording rule `container:memory:working_set_utilization:ratio` would produce incorrect results when the "All" variable option is selected.

## Technical Constraints

- **OpenShift monitoring stack** — all rules deploy as `PrometheusRule` CRs in `openshift-monitoring` with labels `prometheus: k8s` and `role: alert-rules`.
- **cgroup v2 + PSI** — pressure rules (memory, CPU, I/O) require cgroup v2 with `psi=1` kernel boot parameter.
- **Node label** — capacity accounting rules filter on `kubevirt.io/schedulable=true` via kube-state-metrics label `label_kubevirt_io_schedulable`.
- **FC rules are safe no-ops** — Fibre Channel recording rules and alerts produce no series when the node_exporter fibrechannel collector is disabled or no FC HBAs are present.
- **deriv() and retention** — the 180d and 360d capacity exhaustion windows require matching Prometheus retention. On default 15-day retention they return NaN and cost nothing.
- **percli + CUE versions** — dashboard builds require `cue` >= 0.16.1 and `percli` >= 0.54.0.
- **BarChart limitation** — Cluster Observability Operator ships BarChart 0.11.1 which lacks stacking fields. Stacked columns use `TimeSeriesChart` with `visual.display: bar` and `visual.stack: all`.
- **ListVariable defaultValue** — percli emits `{singleValue, sliceValues}` but the Perses operator expects a plain string. Kustomize patches in `dashboards/kustomization.yaml` flatten these.

## Performance Profile

On a small cluster (8 nodes, 300 pods, 500 containers, 30 VMs): 73 recording rules produce ~3,820 output series. CPU cost is ~74 ms per 30s evaluation cycle (0.25%). Memory overhead is ~15 MB. Storage is ~16 MB/day. The per-pod and per-container rules (PSI, OOM proximity) dominate cardinality at `4P + 4C` series. On large clusters (>1000 pods), consider raising the evaluation interval for those groups.

## Pitfalls

- **Do not create per-container breakdown recording rules** (RSS, overhead, hot/cold file cache) for dashboard use. The cardinality cost (one series × metric × container) is too high and the pod-memory dashboard handles this correctly with raw queries.
- **Do not mix recording rule naming formats.** Everything must be `level:area:metric:unit` with exactly 3 colons. Legacy 2-colon or 4-colon names have been eliminated.
- **After editing a .cue file, always rebuild.** Run `percli dac build -f <file>.cue` in `dashboards/dac/` and commit the updated `built/` output. Stale built outputs will deploy the old dashboard.
- **kustomize path restrictions** — dashboard subdirectories cannot use `../` to reference `dac/built/` files. That's why the wrap patches and resources live directly under `dashboards/`, not in nested `operator/` or `configmap/` subdirs.
