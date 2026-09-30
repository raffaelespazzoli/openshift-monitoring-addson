# Capacity Management for OpenShift Virtualization

Recording rules, alerts, and Perses dashboards that turn the built-in OpenShift monitoring stack (kube-state-metrics, kubelet cAdvisor, Prometheus) into a capacity-management solution for clusters running OpenShift Virtualization.

## Quick Start

### Deploy everything

```sh
# From a GitOps pipeline or command line:
oc apply -k .
```

### Deploy a single functional area

```sh
# Only CPU pressure monitoring:
oc apply -k cpu/

# Only memory monitoring (node breakdown + OOM proximity):
oc apply -k memory/
```

### Deploy dashboards separately

```sh
# PersesDashboard CRs (default — requires the Perses operator):
oc apply -k dashboards/

# For unmanaged Perses (ConfigMap mode), edit dashboards/kustomization.yaml
# and replace the last patch with wrap-configmap.yaml (see comments in file).
```

### Use as a remote kustomize base

```yaml
# In your kustomization.yaml:
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  # Everything:
  - github.com/rspazzol/openshift-monitoring-addson?ref=main
  # Or pick individual areas:
  - github.com/rspazzol/openshift-monitoring-addson//cpu?ref=main
  - github.com/rspazzol/openshift-monitoring-addson//memory?ref=main
  - github.com/rspazzol/openshift-monitoring-addson//dashboards/operator?ref=main
```

## Repository Structure

```
.
├── kustomization.yaml              # Deploy everything
├── memory/                         # Node memory breakdown + OOM proximity
│   ├── kustomization.yaml
│   ├── recording-rules.yaml        # 16 recording rules
│   └── alerts.yaml                 # 5 alerts
├── cpu/                            # CPU pressure (PSI) + vCPU scheduling delay
│   ├── kustomization.yaml
│   ├── recording-rules.yaml        # 4 recording rules
│   └── alerts.yaml                 # 3 alerts
├── networking/                     # NIC utilization + VM network drops/errors
│   ├── kustomization.yaml
│   ├── recording-rules.yaml        # 7 recording rules
│   └── alerts.yaml                 # 2 alerts
├── storage/                        # I/O pressure (PSI) + Fibre Channel
│   ├── kustomization.yaml
│   ├── recording-rules.yaml        # 14 recording rules
│   └── alerts.yaml                 # 4 alerts
├── capacity/                       # Capacity accounting, exhaustion, overcommit, overhead
│   ├── kustomization.yaml
│   ├── recording-rules.yaml        # 32 recording rules
│   └── alerts.yaml                 # 1 alert
├── dashboards/
│   ├── kustomization.yaml          # Defaults to PersesDashboard CRs (operator mode)
│   ├── wrap-perses-dashboard.yaml  # JSON patch: Dashboard → PersesDashboard CR
│   ├── wrap-configmap.yaml         # JSON patch: Dashboard → ConfigMap (alternative)
│   └── dac/                        # CUE sources (dashboard-as-code)
└── docs/images/                    # Dashboard screenshots
```

Each functional area is self-contained: recording rules and alerts within an area depend only on each other and on the in-cluster monitoring stack (kube-state-metrics, kubelet cAdvisor). You can deploy any combination of areas without cross-area dependencies.

**Exception:** The dashboards in `capacity/` and `dashboards/` consume recording rules from the `capacity/` area. Deploy `capacity/` alongside `dashboards/` if you use the capacity planning dashboards.

## Dependencies

- OpenShift Container Platform 4.x with Cluster Monitoring Operator
- OpenShift Virtualization (for VM-specific rules and dashboards)
- cgroup v2 with PSI enabled (`psi=1` kernel boot parameter) — required for pressure rules
- Cluster Observability Operator with Perses (for dashboards)
- Node label `kubevirt.io/schedulable=true` on nodes that host VMs

All recording rules and alerts deploy as `PrometheusRule` CRs in `openshift-monitoring` with labels `prometheus: k8s` and `role: alert-rules`, matching the platform Prometheus rule selector.

---

## Memory

Node-level memory decomposition, memory pressure (PSI), and OOM proximity detection at the container and pod level.

### Recording Rules

<details>
<summary>16 recording rules — click to expand</summary>

| Rule | Expression (abbreviated) | Description |
|------|--------------------------|-------------|
| `cluster:node:memory:workloads_utilization:ratio` | `sum by (node)(working_set{kubepods.slice}) / allocatable{memory}` | Fraction of allocatable memory occupied by workload working set — the kubelet eviction metric |
| `cluster:node:memory:pressure:ratio` | `rate(pressure_memory_waiting{id="/"}[5m])` | Fraction of wall-clock time at least one process was stalled waiting for memory (PSI "some") |
| `cluster:node:memory:workloads_used:bytes` | `sum by (node)(usage{kubepods.slice})` | Total memory charged to all pods (memory.current) |
| `cluster:node:memory:workloads_non_reclaimable:bytes` | `sum by (node)(rss{kubepods.slice})` | Anonymous memory (heap, stack) — NOT reclaimable without swap |
| `cluster:node:memory:workloads_cold:bytes` | `sum by (node)(inactive_file{kubepods.slice})` | Inactive file cache — coldest pages, reclaimed first |
| `cluster:node:memory:workloads_hot_reclaimable:bytes` | `sum by (node)(active_file{kubepods.slice})` | Active file cache — reclaimable under pressure at a performance cost |
| `cluster:node:memory:workloads_overhead:bytes` | `used - rss - inactive_file - active_file` | Kernel overhead (slab, kernel_stack, sock, pagetables) |
| `cluster:node:memory:workloads_swap:bytes` | `sum by (node)(swap{kubepods.slice})` | Swap used by workloads |
| `cluster:node:memory:system_used:bytes` | `sum by (node)(usage{system.slice})` | Total memory charged to system.slice |
| `cluster:node:memory:system_non_reclaimable:bytes` | `sum by (node)(rss{system.slice})` | Anonymous memory in system.slice |
| `cluster:node:memory:system_cold:bytes` | `sum by (node)(inactive_file{system.slice})` | Inactive file cache in system.slice |
| `cluster:node:memory:system_hot_reclaimable:bytes` | `sum by (node)(active_file{system.slice})` | Active file cache in system.slice |
| `cluster:node:memory:system_overhead:bytes` | `used - rss - inactive_file - active_file` | Kernel overhead in system.slice |
| `cluster:node:memory:system_swap:bytes` | `sum by (node)(swap{system.slice})` | Swap used by system services |
| `container:memory:working_set_utilization:ratio` | `working_set / kube_pod_container_resource_limits{memory}` | Per-container working_set / limit — OOM proximity |
| `pod:memory:working_set_utilization:ratio` | `working_set{pod cgroup} / memory.max{pod cgroup}` | Per-pod working_set / pod cgroup limit — OOM proximity |

</details>

### Alerts

<details>
<summary>5 alerts — click to expand</summary>

| Alert | Expression (abbreviated) | Severity | For | Description |
|-------|--------------------------|----------|-----|-------------|
| `NodeWorkloadMemoryApproachingEviction` | `workloads_utilization:ratio > 0.95` | warning | 5m | Workload memory exceeds 95% of allocatable — kubelet eviction imminent |
| `NodeMemoryPressureHigh` | `pressure:ratio > 0.05` | warning | 5m | >5% wall-clock time stalled on memory — kernel actively reclaiming pages |
| `NodeMemoryPressureCritical` | `pressure:ratio > 0.20` | critical | 5m | >20% wall-clock time stalled — severe reclaim pressure, OOM likely |
| `ContainerMemoryApproachingOOM` | `working_set_utilization:ratio > 0.95` | warning | 5m | Container working_set exceeds 95% of its memory limit |
| `PodMemoryApproachingOOM` | `pod working_set_utilization:ratio > 0.95` | warning | 5m | Pod total working_set exceeds 95% of pod-level memory limit |

</details>

### Dashboards

| Dashboard | Description |
|-----------|-------------|
| **Node Memory** | Runtime memory decomposition per node: non-reclaimable, hot-reclaimable, cold-reclaimable, kernel overhead, and free. Three stacked area charts: full node, workloads (kubepods.slice), and system (system.slice). |
| **Pod Memory** | Container-level memory decomposition with limit threshold line. Summary stats: working set, limit, utilization, RSS. |
| **VM Memory** | Guest memory decomposition (kernel reserved, non-reclaimable, reclaimable, free) and launcher overhead: estimated vs actual. |

<!-- Dashboard screenshots — add images to docs/images/ and uncomment:
![Node Memory](docs/images/node-memory.png)
![Pod Memory](docs/images/pod-memory.png)
![VM Memory](docs/images/vm-memory.png)
-->

---

## CPU

CPU pressure (PSI) at the node, pod, and container level, plus VM vCPU host-scheduling delay.

### Recording Rules

<details>
<summary>4 recording rules — click to expand</summary>

| Rule | Expression (abbreviated) | Description |
|------|--------------------------|-------------|
| `cluster:node:cpu:pressure:ratio` | `rate(pressure_cpu_waiting{id="/"}[5m])` | Fraction of wall-clock time at least one runnable task waited for a CPU (PSI "some") |
| `pod:cpu:pressure:ratio` | `rate(pressure_cpu_waiting{container="", pod!=""}[5m])` | Per-pod CPU pressure from pod-level cgroups |
| `container:cpu:pressure:ratio` | `rate(pressure_cpu_waiting{container!=""}[5m])` | Per-container CPU pressure |
| `vmi:cpu:vcpu_delay:ratio` | `sum by (ns, name, node)(rate(vcpu_delay_seconds_total[5m]))` | Per-VM vCPU host-scheduling delay — time vCPUs spent in the host scheduler queue |

</details>

### Alerts

<details>
<summary>3 alerts — click to expand</summary>

| Alert | Expression (abbreviated) | Severity | For | Description |
|-------|--------------------------|----------|-----|-------------|
| `NodeCPUPressureHigh` | `cpu:pressure:ratio > 0.15` | warning | 5m | >15% wall-clock time with runnable tasks waiting for CPUs |
| `NodeCPUPressureCritical` | `cpu:pressure:ratio > 0.50` | critical | 5m | >50% wall-clock time — severe CPU starvation |
| `VMvCPUDelayHigh` | `vcpu_delay:ratio > 0.5` | warning | 5m | VM vCPU spending >0.5 vCPU-seconds/s waiting in host scheduler queue |

</details>

---

## Networking

Per-NIC bandwidth utilization vs link speed, packet drop/error rates, and per-VM network throughput.

### Recording Rules

<details>
<summary>7 recording rules — click to expand</summary>

| Rule | Expression (abbreviated) | Description |
|------|--------------------------|-------------|
| `cluster:node:nic:transmit_utilization:ratio` | `rate(tx_bytes[5m]) / speed_bytes` | Per-NIC transmit utilization vs link speed (physical NICs only) |
| `cluster:node:nic:receive_utilization:ratio` | `rate(rx_bytes[5m]) / speed_bytes` | Per-NIC receive utilization vs link speed |
| `cluster:node:nic:drop_rate:packets_per_second` | `rate(rx_drop + tx_drop[5m])` | Per-NIC packet drop rate (ring buffer overflow, queue full) |
| `cluster:node:nic:error_rate:packets_per_second` | `rate(rx_errs + tx_errs[5m])` | Per-NIC packet error rate (CRC failures, runt/giant frames) |
| `vmi:network:drop_rate:packets_per_second` | `sum by (ns, name, node)(rate(vmi rx+tx dropped[5m]))` | Per-VM network packet drops |
| `vmi:network:error_rate:packets_per_second` | `sum by (ns, name, node)(rate(vmi rx+tx errors[5m]))` | Per-VM network packet errors |
| `vmi:network:throughput:bytes_per_second` | `sum by (ns, name, node)(rate(vmi rx+tx bytes[5m]))` | Per-VM network throughput (rx + tx) |

</details>

### Alerts

<details>
<summary>2 alerts — click to expand</summary>

| Alert | Expression (abbreviated) | Severity | For | Description |
|-------|--------------------------|----------|-----|-------------|
| `NodeNICSaturationWarning` | `transmit_utilization > 0.70 or receive_utilization > 0.70` | warning | 5m | NIC sustained >70% bandwidth — TCP congestion likely |
| `NodeNICSaturationCritical` | `transmit_utilization > 0.85 or receive_utilization > 0.85` | critical | 5m | NIC sustained >85% bandwidth — near saturation, packet drops likely |

</details>

---

## Storage

I/O pressure (PSI) at all scopes, Fibre Channel HBA monitoring, and per-VM storage latency/throughput.

### Recording Rules

<details>
<summary>14 recording rules — click to expand</summary>

| Rule | Expression (abbreviated) | Description |
|------|--------------------------|-------------|
| `cluster:node:io:pressure_waiting:ratio` | `rate(io_waiting{id="/"}[5m])` | Node-wide I/O pressure — "some" (at least one task waiting) |
| `cluster:node:io:pressure_stalled:ratio` | `rate(io_stalled{id="/"}[5m])` | Node-wide I/O pressure — "full" (ALL tasks stalled) |
| `pod:io:pressure_waiting:ratio` | `rate(io_waiting{pod cgroup}[5m])` | Per-pod I/O pressure — "some" |
| `pod:io:pressure_stalled:ratio` | `rate(io_stalled{pod cgroup}[5m])` | Per-pod I/O pressure — "full" |
| `container:io:pressure_waiting:ratio` | `rate(io_waiting{container cgroup}[5m])` | Per-container I/O pressure — "some" |
| `container:io:pressure_stalled:ratio` | `rate(io_stalled{container cgroup}[5m])` | Per-container I/O pressure — "full" |
| `vmi:storage:read_latency:seconds` | `rate(read_times[5m]) / rate(iops_read[5m])` | Per-VM per-drive storage read latency (seconds per op) |
| `vmi:storage:write_latency:seconds` | `rate(write_times[5m]) / rate(iops_write[5m])` | Per-VM per-drive storage write latency (seconds per op) |
| `vmi:storage:throughput:bytes_per_second` | `sum by (ns,name,node)(rate(read+write traffic[5m]))` | Per-VM total storage throughput |
| `cluster:node:fc:port_speed:bytes_per_second` | `node_fibrechannel_info{speed} → bytes/sec` | FC port speed label converted to numeric gauge |
| `cluster:node:fc:transmit_utilization:ratio` | `rate(tx_words * 4[5m]) / port_speed` | Per-FC-HBA transmit utilization vs link speed |
| `cluster:node:fc:receive_utilization:ratio` | `rate(rx_words * 4[5m]) / port_speed` | Per-FC-HBA receive utilization vs link speed |
| `cluster:node:fc:error_rate:frames_per_second` | `rate(error_frames + invalid_crc[5m])` | FC error frame rate (bad SFP, cable, ISL congestion) |
| `cluster:node:fc:link_loss_rate:per_second` | `rate(loss_of_signal + loss_of_sync[5m])` | FC physical layer problems (cable fault, failing SFP) |

</details>

### Alerts

<details>
<summary>4 alerts — click to expand</summary>

| Alert | Expression (abbreviated) | Severity | For | Description |
|-------|--------------------------|----------|-----|-------------|
| `NodeIOPressureWarning` | `io:pressure_waiting:ratio > 0.50` | warning | 10m | >50% wall-clock time with at least one task waiting on block I/O |
| `NodeIOPressureCritical` | `io:pressure_stalled:ratio > 0.15` | critical | 5m | >15% wall-clock time with ALL tasks stalled on I/O — zero progress |
| `NodeFCHBASaturationWarning` | `fc transmit/receive utilization > 0.70` | warning | 5m | FC HBA sustained >70% bandwidth — credit starvation possible |
| `NodeFCHBASaturationCritical` | `fc transmit/receive utilization > 0.85` | critical | 5m | FC HBA sustained >85% bandwidth — near saturation |

> **Note:** FC alerts are a safe no-op on clusters without Fibre Channel storage. They only fire when the node_exporter fibrechannel collector is enabled and FC HBAs are present.

</details>

---

## Capacity Planning

Cross-functional capacity accounting, time-to-exhaustion projections, VM overcommit statistical analysis, and virt-launcher overhead tracking. These rules combine memory and CPU and do not belong to a single functional area.

### Recording Rules

<details>
<summary>32 recording rules — click to expand</summary>

**Capacity accounting (18 rules)**

| Rule | Expression (abbreviated) | Description |
|------|--------------------------|-------------|
| `capacity:nodes_down:count` | `vector(1)` | HA reserve — how many largest nodes to hold back from total capacity |
| `cluster:total_capacity_memory:bytes` | `sum(allocatable{schedulable}) - max(allocatable) × nodes_down` | Schedulable memory minus the HA reserve |
| `cluster:used_capacity_memory:bytes` | `sum(pod_resource_request{memory, schedulable})` | Memory requests on schedulable nodes |
| `cluster:available_capacity_memory:bytes` | `total - used` | Available memory capacity |
| `cluster:vm_used_capacity_memory:bytes` | `sum(request{memory, virt-launcher-.*})` | Memory requests of virt-launcher pods |
| `cluster:non_vm_used_capacity_memory:bytes` | `sum(request{memory, !virt-launcher})` | Memory requests of every other pod |
| `cluster:total_capacity_cpu:cores` | `sum(allocatable{cpu, schedulable}) - max × nodes_down` | Schedulable CPU minus the HA reserve |
| `cluster:used_capacity_cpu:cores` | `sum(pod_resource_request{cpu, schedulable})` | CPU requests on schedulable nodes |
| `cluster:available_capacity_cpu:cores` | `total - used` | Available CPU capacity |
| `cluster:vm_used_capacity_cpu:cores` | `sum(request{cpu, virt-launcher-.*})` | CPU requests of virt-launcher pods |
| `cluster:non_vm_used_capacity_cpu:cores` | `sum(request{cpu, !virt-launcher})` | CPU requests of every other pod |
| `cluster:memory_cpu_ratio:gib_per_core` | `used_memory_GiB / used_cpu_cores` | Memory-to-CPU ratio — ideal node shape for workload |
| `cluster:vm_memory_usage:bytes` | `sum(working_set{virt-launcher})` | Actual memory usage of VM containers |
| `cluster:non_vm_memory_usage:bytes` | `sum(working_set{!virt-launcher})` | Actual memory usage of non-VM containers |
| `cluster:vm_cpu_usage:cores` | `sum(rate(cpu_usage{virt-launcher}[5m]))` | Actual CPU usage of VM containers |
| `cluster:non_vm_cpu_usage:cores` | `sum(rate(cpu_usage{!virt-launcher}[5m]))` | Actual CPU usage of non-VM containers |
| `cluster:vm_memory_actual_used:bytes` | `sum(kubevirt_vmi_memory_used_bytes)` | Aggregate VM memory usage (guest-level) |
| `cluster:vm_cpu_actual_used:cores` | `sum(rate(kubevirt_vmi_cpu_usage_seconds_total[5m]))` | Aggregate VM CPU usage (guest-level) |

**Virt-launcher overhead (2 rules)**

| Rule | Expression (abbreviated) | Description |
|------|--------------------------|-------------|
| `vmi:virt_launcher_overhead_memory:bytes` | `pod_working_set - guest_resident_bytes` | Per-VM memory overhead (QEMU structures, virtio buffers, etc.) |
| `vmi:virt_launcher_overhead_cpu:cores` | `pod_cpu_rate - guest_cpu_rate` | Per-VM CPU overhead |

**Time-to-exhaustion (12 rules)**

| Rule | Window | Description |
|------|--------|-------------|
| `cluster:days_to_exhaustion_memory_<W>:days` | 7d, 30d, 180d, 360d | Days until memory capacity runs out (deriv-based projection) |
| `cluster:days_to_exhaustion_cpu_<W>:days` | 7d, 30d, 180d, 360d | Days until CPU capacity runs out |
| `cluster:days_to_exhaustion_<W>:days` | 7d, 30d, 180d, 360d | Days until whichever resource exhausts first |

> **Note:** The 180d and 360d windows require matching Prometheus retention. On clusters with the default 15-day retention, these rules return no data and cost nothing.

</details>

### Alerts

<details>
<summary>1 alert — click to expand</summary>

| Alert | Expression (abbreviated) | Severity | For | Description |
|-------|--------------------------|----------|-----|-------------|
| `VirtLauncherOverheadExceedsEstimate` | `actual_overhead > estimated_overhead` | warning | 15m | Virt-launcher pod using more memory than KubeVirt's overhead model predicted — relying on burstable QoS headroom |

</details>

### Dashboards

These dashboards are cross-functional (memory + CPU) and do not belong to any single functional area.

| Dashboard | Description |
|-----------|-------------|
| **How many VMs fit** (`vm-capacity`) | How many more VMs of a chosen shape fit in remaining capacity. Variables: VM memory, VM CPU, memory overcommit, CPU overcommit. Stacked bar charts show non-VM used, VM used, and available for memory and CPU. |
| **Time to Capacity Exhaustion** (`capacity-exhaustion`) | Days until the cluster runs out of capacity. Gauge capped at 365 with red/orange/green thresholds. Trend chart shows how the estimate has changed over time. Variable: observation period (7d–360d). |
| **VM Overcommit** (`vm-overcommit`) | Statistical overcommit analysis: Normal (bell-curve assumption) and Chebyshev (distribution-free) approaches. Variables: observation period, confidence level. Shows suggested overcommit ratios for memory and CPU with trend charts. |

<!-- Dashboard screenshots — add images to docs/images/ and uncomment:
![How many VMs fit](docs/images/vm-capacity.png)
![Time to Capacity Exhaustion](docs/images/capacity-exhaustion.png)
![VM Overcommit](docs/images/vm-overcommit.png)
-->

---

## Dashboard Deployment

Dashboards are written with the [Perses CUE SDK](https://perses.dev/) in `dashboards/dac/`. The CUE sources are the single source of truth; `percli dac build` compiles them to Perses `Dashboard` YAML in `dashboards/dac/built/`.

Two deployment modes wrap the same built output:

| Mode | Patch file | Output kind | Use when |
|------|------------|-------------|----------|
| **Operator** (default) | `wrap-perses-dashboard.yaml` | `PersesDashboard` | Cluster Observability Operator with Perses operator is installed |
| **ConfigMap** | `wrap-configmap.yaml` | `ConfigMap` | Perses runs standalone without the operator |

The `dashboards/kustomization.yaml` defaults to operator mode. To switch to ConfigMap mode, change the last patch entry in that file from `wrap-perses-dashboard.yaml` to `wrap-configmap.yaml` (see the comments in the file).

### Rebuilding dashboards after CUE changes

```sh
cd dashboards/dac
cue mod tidy
percli dac build -f vm-capacity.cue
percli dac build -f capacity-exhaustion.cue
percli dac build -f vm-overcommit.cue
percli dac build -f node-memory.cue
percli dac build -f pod-memory.cue
percli dac build -f vm-memory.cue
```

Requires `cue` >= 0.16.1 and `percli` >= 0.54.0.

---

## Performance Impact

These rules are designed to be lightweight. Below are reference measurements from a small lab cluster, followed by a scaling model and PromQL queries to measure the actual impact on your cluster.

> **Reference cluster (etl7):** 8 schedulable nodes · 300 pods · 500 containers with limits · 30 VMs · 2 NICs/node · 2 drives/VM · no FC HBAs.
> Evaluation interval: 30s · Retention: 15d.

### Summary

| Metric | Estimated | Notes |
|--------|-----------|-------|
| Recording rules | 73 | Across all functional areas |
| Alert rules | 15 | Fire only — zero stored series when healthy |
| Output time series | **~3,820** | Per evaluation cycle |
| CPU per evaluation | ~74 ms | 0.25% of the 30s evaluation budget |
| Memory overhead | ~14.9 MB | TSDB head block (in-memory active series) |
| Storage per day | ~15.7 MB/day | At 1.5 bytes/sample after TSDB compression |
| Storage at 15d retention | ~236 MB | On a typical 50–200 GB Prometheus PV |

**Verdict: low impact.** The CPU cost is under 0.3% of the evaluation budget. Memory overhead is a fraction of a percent of typical Prometheus RSS (4–12 GB). Storage adds ~236 MB over 15 days on PVs that are typically 50–200 GB.

### How It Scales

The 73 recording rules produce time series at different scopes. Some are constant regardless of cluster size; others scale with the number of entities:

| Scope | Rules | Series formula | etl7 series |
|-------|-------|----------------|-------------|
| Cluster (scalar) | 30 | 30 | 30 |
| Per node (×N) | 17 | 17 × N | 136 |
| Per NIC (×N×NICs) | 4 | 4 × N × NICs | 64 |
| Per pod (×P) | 4 | 4 × P | 1,200 |
| Per container (×C) | 4 | 4 × C | 2,000 |
| Per VM (×V) | 9 | 9 × V | 270 |
| Per VM drive (×V×D) | 2 | 2 × V × D | 120 |
| Per FC HBA (×FC) | 5 | 5 × FC | 0 |
| Alert rules | 15 | ~0 (fire only) | 0 |
| **Total** | **90** | | **3,820** |

**The dominant cost is per-pod and per-container rules** (PSI and OOM proximity). On a cluster with P pods and C containers-with-limits, they produce `4P + 4C` series. On a 3,000-pod / 5,000-container production cluster, that's 32,000 series from those rules alone — still manageable, but consider raising the evaluation interval for the PSI groups from 30s to 60s or 120s on very large clusters.

**`deriv()` and long lookback windows:** The 12 capacity-exhaustion rules are cluster-scalar (cheap in cardinality), but `deriv()` over a 360-day window requires Prometheus to read 360 days of samples at evaluation time. This is a query cost, not a storage cost. It only matters if retention is ≥ 360 days. On the default 15-day retention, the 180d and 360d windows return `NaN` — they're free but produce no data.

### Measure the Impact on Your Cluster

Run these in the OpenShift web console (**Observe → Metrics**) or via the Thanos Querier API. They use Prometheus self-instrumentation metrics to give you the real numbers — before and after deploying these rules.

<details>
<summary><strong>CPU — evaluation cost</strong></summary>

**Per-group evaluation duration (seconds)**
How long each rule group takes to evaluate. Compare with the 30s interval.
```promql
prometheus_rule_group_last_duration_seconds{rule_group=~".*capacity.*"}
```

**Missed evaluations**
Non-zero means rule evaluation is taking longer than the interval — rules are being skipped.
```promql
increase(prometheus_rule_group_iterations_missed_total{rule_group=~".*capacity.*"}[1h])
```

**Rule evaluation CPU time**
Fraction of total CPU spent evaluating rules. Quantifies the incremental CPU cost.
```promql
sum(rate(prometheus_rule_evaluation_duration_seconds_sum[5m]))
```

**Prometheus pod CPU usage**
Direct CPU consumption. Compare the 7-day trend to see the uplift from your rules.
```promql
sum by (pod) (rate(container_cpu_usage_seconds_total{
  namespace="openshift-monitoring",
  pod=~"prometheus-k8s-.*",
  container="prometheus"
}[5m]))
```

</details>

<details>
<summary><strong>Cardinality — memory impact</strong></summary>

**Samples produced per evaluation**
Direct measure of output cardinality — how many time series each group writes per tick.
```promql
prometheus_rule_group_last_evaluation_samples{rule_group=~".*capacity.*"}
```

**Total head series**
Track this over the week you deployed rules. The delta is the series your rules added.
```promql
prometheus_tsdb_head_series
```

**Prometheus pod memory (RSS)**
Direct memory consumption. Each new series adds ~4 KB to the in-memory head block.
```promql
sum by (pod) (container_memory_rss{
  namespace="openshift-monitoring",
  pod=~"prometheus-k8s-.*",
  container="prometheus"
})
```

</details>

<details>
<summary><strong>Storage — disk impact</strong></summary>

**Ingestion rate (samples/sec)**
Compare rate before and after rule deployment to see the differential ingestion load.
```promql
rate(prometheus_tsdb_head_samples_appended_total[5m])
```

**TSDB disk usage**
Actual on-disk storage consumed by the TSDB.
```promql
prometheus_tsdb_storage_blocks_bytes + prometheus_tsdb_head_chunks_storage_size_bytes
```

**Bytes per sample (actual compression ratio)**
Validates the 1–2 bytes/sample estimate used in the storage calculation.
```promql
rate(prometheus_tsdb_compaction_chunk_size_bytes_sum[1h])
/ rate(prometheus_tsdb_compaction_chunk_samples_sum[1h])
```

</details>

---

## Customization Points

| What | Where | Default |
|------|-------|---------|
| HA reserve (nodes held back) | `capacity/recording-rules.yaml` → `capacity:nodes_down:count` | `vector(1)` — one node |
| VM shape / overcommit | Dashboard variables (query-time, not rules) | 8 GiB / 4 vCPU / 1× |
| Alert thresholds | Each area's `alerts.yaml` | See tables above |
| PSI evaluation interval | Per-group `interval` field in recording rules | 30s (OpenShift default) |
| Dashboard namespace | `dashboards/wrap-perses-dashboard.yaml` | `openshift-operators` |
| ConfigMap namespace | `dashboards/wrap-configmap.yaml` | `perses` |
