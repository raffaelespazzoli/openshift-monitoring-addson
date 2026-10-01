package dac

import (
	dashboardBuilder "github.com/perses/perses/cue/dac-utils/dashboard"
	panelGroupsBuilder "github.com/perses/perses/cue/dac-utils/panelgroups"
	varGroupBuilder "github.com/perses/perses/cue/dac-utils/variable/group"
	panelBuilder "github.com/perses/plugins/prometheus/sdk/cue/panel"
	promQuery "github.com/perses/plugins/prometheus/schemas/prometheus-time-series-query:model"
	statChart "github.com/perses/plugins/statchart/schemas:model"
	labelValuesVarBuilder "github.com/perses/plugins/prometheus/sdk/cue/variable/labelvalues"
)

// ══════════════════════════════════════════════════════════════════════
// Chart templates
// ══════════════════════════════════════════════════════════════════════

// Stacked area chart — memory decomposition panels.
#stackedAreaChart: {
	kind: "TimeSeriesChart"
	spec: {
		legend: {
			position: "bottom"
			mode:     "list"
		}
		visual: {
			display:     "line"
			areaOpacity: 0.7
			stack:       "all"
			...
		}
		yAxis: format: unit: "bytes"
		...
	}
}

// Line chart for ratios 0–1 displayed as percentages (PSI, utilization).
#ratioChart: {
	kind: "TimeSeriesChart"
	spec: {
		legend: {
			position: "bottom"
			mode:     "list"
		}
		visual: {
			display:     "line"
			areaOpacity: 0
			lineWidth:   2
			...
		}
		yAxis: format: unit: "percent"
		...
	}
}

// Line chart for absolute rates (packets/s, frames/s).
#rateChart: {
	kind: "TimeSeriesChart"
	spec: {
		legend: {
			position: "bottom"
			mode:     "list"
		}
		visual: {
			display:     "line"
			areaOpacity: 0
			lineWidth:   2
			...
		}
		yAxis: format: unit: "decimal"
		...
	}
}

// ══════════════════════════════════════════════════════════════════════
// Query helpers
// ══════════════════════════════════════════════════════════════════════

#tsQuery: {
	#query:  string
	#format: string
	kind:    "TimeSeriesQuery"
	spec: plugin: promQuery & {
		spec: {
			query:            #query
			seriesNameFormat: #format
		}
	}
}

// ══════════════════════════════════════════════════════════════════════
// MEMORY — PromQL fragments
// ══════════════════════════════════════════════════════════════════════

// Per-node vs all-nodes aggregation: when $node is ".*" (all nodes),
// sum() aggregates across nodes so charts show a single stacked area.
// All queries reference recording rules from the memory area which
// pre-aggregate cAdvisor metrics by node.

_wk: "{node=~\"$node\"}"
_sy: "{node=~\"$node\"}"

// Panel 1: Full node — stacks: non-reclaimable, overhead, hot, cold, free.
#p1_nonReclaim:  "sum(node:memory:workloads_non_reclaimable:bytes" + _wk + ") + sum(node:memory:system_non_reclaimable:bytes" + _sy + ")"
#p1_overhead:    "sum(node:memory:workloads_overhead:bytes" + _wk + ") + sum(node:memory:system_overhead:bytes" + _sy + ")"
#p1_hotReclaim:  "sum(node:memory:workloads_hot_reclaimable:bytes" + _wk + ") + sum(node:memory:system_hot_reclaimable:bytes" + _sy + ")"
#p1_coldReclaim: "sum(node:memory:workloads_cold:bytes" + _wk + ") + sum(node:memory:system_cold:bytes" + _sy + ")"
#p1_free: """
	sum(kube_node_status_capacity{resource="memory", node=~"$node"})
	- sum(node:memory:workloads_used:bytes\( _wk ))
	- sum(node:memory:system_used:bytes\( _sy ))
	"""

// Panel 2: Workloads (kubepods.slice) — total = allocatable.
#p2_nonReclaim:  "sum(node:memory:workloads_non_reclaimable:bytes" + _wk + ")"
#p2_overhead:    "sum(node:memory:workloads_overhead:bytes" + _wk + ")"
#p2_hotReclaim:  "sum(node:memory:workloads_hot_reclaimable:bytes" + _wk + ")"
#p2_coldReclaim: "sum(node:memory:workloads_cold:bytes" + _wk + ")"
#p2_free: """
	sum(kube_node_status_allocatable{resource="memory", node=~"$node"})
	- sum(node:memory:workloads_used:bytes\( _wk ))
	"""

// Panel 3: System (system.slice) — no cap.
#p3_nonReclaim:  "sum(node:memory:system_non_reclaimable:bytes" + _sy + ")"
#p3_overhead:    "sum(node:memory:system_overhead:bytes" + _sy + ")"
#p3_hotReclaim:  "sum(node:memory:system_hot_reclaimable:bytes" + _sy + ")"
#p3_coldReclaim: "sum(node:memory:system_cold:bytes" + _sy + ")"

// Summary stats.
#allocatable:         "sum(kube_node_status_allocatable{resource=\"memory\", node=~\"$node\"})"
#reserved: """
	sum(kube_node_status_capacity{resource="memory", node=~"$node"})
	- sum(kube_node_status_allocatable{resource="memory", node=~"$node"})
	"""
#capacity:            "sum(kube_node_status_capacity{resource=\"memory\", node=~\"$node\"})"
#workloadUtilization: "sum(node:memory:workloads_utilization:ratio" + _wk + ")"
#systemUsed:          "sum(node:memory:system_used:bytes" + _sy + ")"
#memoryPSI:           "node:memory:pressure:ratio{node=~\"$node\"}"

// ══════════════════════════════════════════════════════════════════════
// CPU — PromQL fragments
// ══════════════════════════════════════════════════════════════════════

#cpuCapacity:    "sum(kube_node_status_capacity{resource=\"cpu\", node=~\"$node\"})"
#cpuAllocatable: "sum(kube_node_status_allocatable{resource=\"cpu\", node=~\"$node\"})"
#cpuUtilization: """
	sum(rate(container_cpu_usage_seconds_total{id="/kubepods.slice", node=~"$node"}[5m]))
	/ sum(kube_node_status_allocatable{resource="cpu", node=~"$node"})
	"""
#cpuPSI: "node:cpu:pressure:ratio{node=~\"$node\"}"

// ══════════════════════════════════════════════════════════════════════
// NETWORKING — PromQL fragments
// ══════════════════════════════════════════════════════════════════════

// node_exporter metrics carry {instance} (= node hostname) but NOT
// {node}.  cAdvisor metrics carry {node} but instance is IP:port.
// The $node variable matches both: kube-state node names equal the
// node_exporter instance hostnames in OpenShift.
_netFilter: "{instance=~\"$node\", device=~\"$nic\"}"
#netTxUtil:  "node_nic:network:transmit_utilization:ratio" + _netFilter
#netRxUtil:  "node_nic:network:receive_utilization:ratio" + _netFilter
#netDrops:   "node_nic:network:drop_rate:packets_per_second" + _netFilter
#netErrors:  "node_nic:network:error_rate:packets_per_second" + _netFilter

// ══════════════════════════════════════════════════════════════════════
// STORAGE — PromQL fragments
// ══════════════════════════════════════════════════════════════════════

// I/O PSI from cAdvisor root cgroup — already carries {node}.
#ioPSIWaiting: "node:io:pressure_waiting:ratio{node=~\"$node\"}"
#ioPSIStalled: "node:io:pressure_stalled:ratio{node=~\"$node\"}"

// FC HBA recording rules use node_exporter — match via {instance}.
_fcFilter: "{instance=~\"$node\", fc_host=~\"$hba\"}"
#fcTxUtil:   "node_hba:fc:transmit_utilization:ratio" + _fcFilter
#fcRxUtil:   "node_hba:fc:receive_utilization:ratio" + _fcFilter
#fcErrors:   "node_hba:fc:error_rate:frames_per_second" + _fcFilter
#fcLinkLoss: "node_hba:fc:link_loss_rate:per_second" + _fcFilter

// DM-multipath raw node_exporter metrics — match via {instance}.
// No-op on clusters without the dmmultipath collector enabled.
#mpathDevices:     "count(node_dmmultipath_device_active{instance=~\"$node\"})"
#mpathTotalPaths:  "sum(node_dmmultipath_device_paths{instance=~\"$node\"})"
#mpathFailedPaths: "sum(node_dmmultipath_device_paths_failed{instance=~\"$node\"})"

// ══════════════════════════════════════════════════════════════════════
// Dashboard
// ══════════════════════════════════════════════════════════════════════

dashboardBuilder & {
	#name:    "node-resources"
	#project: "perses"
	#display: {
		name:        "Node Resources"
		description: "Per-node resource overview: memory decomposition & PSI, CPU utilization & PSI, NIC saturation, I/O pressure, Fibre Channel, and multipath health."
	}
	#duration: "6h"

	// ── Variables ────────────────────────────────────────────────
	// Perses does not support section-level variables; all appear
	// at dashboard level.  NIC and HBA are chained from $node so
	// they only list devices present on the selected node.
	#variables: {varGroupBuilder & {
		#input: [
			labelValuesVarBuilder & {
				#name:   "node"
				#display: name: "Node"
				#metric: "kube_node_status_capacity"
				#label:  "node"
				#allowAllValue: true
				#allowMultiple: false
			},
			labelValuesVarBuilder & {
				#name:   "nic"
				#display: name: "NIC"
				#label:  "device"
				#query:  "node_nic:network:transmit_utilization:ratio{instance=~\"$node\"}"
				#allowAllValue: true
				#allowMultiple: false
			},
			labelValuesVarBuilder & {
				#name:   "hba"
				#display: name: "HBA"
				#label:  "fc_host"
				#query:  "node_hba:fc:transmit_utilization:ratio{instance=~\"$node\"}"
				#allowAllValue: true
				#allowMultiple: false
			},
		]
	}}.variables

	// ── Panel groups ────────────────────────────────────────────
	#panelGroups: panelGroupsBuilder & {
		#input: [

			// ═══════════════════════════════════════════════════
			// MEMORY
			// ═══════════════════════════════════════════════════

			// ── Memory Summary (stats) ───────────────────────
			{
				#title: "Memory Summary"
				#cols:  5
				#panels: [
					panelBuilder & {
						spec: {
							display: name: "Capacity"
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {
										unit:          "bytes"
										decimalPlaces: 1
									}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {
									spec: query: #capacity
								}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: name: "Allocatable"
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {
										unit:          "bytes"
										decimalPlaces: 1
									}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {
									spec: query: #allocatable
								}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Workload utilization"
								description: "kubepods.slice working_set / allocatable (kubelet eviction metric)"
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {
										unit:          "percent"
										decimalPlaces: 1
									}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {
									spec: query: #workloadUtilization
								}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Reserved"
								description: "system-reserved + kube-reserved + eviction-threshold"
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {
										unit:          "bytes"
										decimalPlaces: 1
									}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {
									spec: query: #reserved
								}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "System used"
								description: "system.slice total usage (can exceed reserved via file cache)"
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {
										unit:          "bytes"
										decimalPlaces: 1
									}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {
									spec: query: #systemUsed
								}
							}]
						}
					},
				]
			},

			// ── Memory Saturation (PSI) ──────────────────────
			{
				#title:  "Memory Saturation (PSI)"
				#cols:   1
				#height: 10
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "Memory Pressure"
								description: "Fraction of wall-clock time at least one process was stalled waiting for memory reclaim. Root cgroup (node-wide). Requires cgroup v2."
							}
							plugin: #ratioChart
							queries: [
								{#tsQuery & {#query: #memoryPSI, #format: "{{node}}"}},
							]
						}
					},
				]
			},

			// ── Memory Decomposition ─────────────────────────
			{
				#title:  "Memory Decomposition"
				#cols:   3
				#height: 14
				#panels: [
					// Panel 1: Full Node
					panelBuilder & {
						spec: {
							display: {
								name:        "Node Total"
								description: "Full node memory: system + workloads. Total height = node capacity."
							}
							plugin: #stackedAreaChart & {
								spec: {
									visual: lineWidth: 2
									querySettings: [{
										queryIndex: 5
										colorMode:  "fixed-single"
										colorValue: "#FFFFFF"
										lineStyle:  "dotted"
										stack:      false
										areaOpacity: 0
									}]
								}
							}
							queries: [
								#tsQuery & {
									#format: "Non-reclaimable (anon)"
									#query:  #p1_nonReclaim
								},
								#tsQuery & {
									#format: "Kernel overhead"
									#query:  #p1_overhead
								},
								#tsQuery & {
									#format: "Reclaimable hot (active file)"
									#query:  #p1_hotReclaim
								},
								#tsQuery & {
									#format: "Reclaimable cold (inactive file)"
									#query:  #p1_coldReclaim
								},
								#tsQuery & {
									#format: "Free"
									#query:  #p1_free
								},
								#tsQuery & {
									#format: "── Allocatable"
									#query:  #allocatable
								},
							]
						}
					},

					// Panel 2: Workloads (kubepods.slice)
					panelBuilder & {
						spec: {
							display: {
								name:        "Workloads (kubepods.slice)"
								description: "Pod memory only. Total height = node allocatable."
							}
							plugin: #stackedAreaChart
							queries: [
								#tsQuery & {
									#format: "Non-reclaimable (anon)"
									#query:  #p2_nonReclaim
								},
								#tsQuery & {
									#format: "Kernel overhead"
									#query:  #p2_overhead
								},
								#tsQuery & {
									#format: "Reclaimable hot (active file)"
									#query:  #p2_hotReclaim
								},
								#tsQuery & {
									#format: "Reclaimable cold (inactive file)"
									#query:  #p2_coldReclaim
								},
								#tsQuery & {
									#format: "Free"
									#query:  #p2_free
								},
							]
						}
					},

					// Panel 3: System (system.slice)
					panelBuilder & {
						spec: {
							display: {
								name:        "System (system.slice)"
								description: "OS and Kubernetes system services. Compare with Reserved stat above — system usage commonly exceeds reservation due to file cache."
							}
							plugin: #stackedAreaChart & {
								spec: {
									visual: lineWidth: 2
									querySettings: [{
										queryIndex: 4
										colorMode:  "fixed-single"
										colorValue: "#FF8C00"
										lineStyle:  "dotted"
										stack:      false
										areaOpacity: 0
									}]
								}
							}
							queries: [
								#tsQuery & {
									#format: "Non-reclaimable (anon)"
									#query:  #p3_nonReclaim
								},
								#tsQuery & {
									#format: "Kernel overhead"
									#query:  #p3_overhead
								},
								#tsQuery & {
									#format: "Reclaimable hot (active file)"
									#query:  #p3_hotReclaim
								},
								#tsQuery & {
									#format: "Reclaimable cold (inactive file)"
									#query:  #p3_coldReclaim
								},
								#tsQuery & {
									#format: "── Reserved"
									#query:  #reserved
								},
							]
						}
					},
				]
			},

			// ═══════════════════════════════════════════════════
			// CPU
			// ═══════════════════════════════════════════════════

			// ── CPU Summary (stats) ──────────────────────────
			{
				#title: "CPU Summary"
				#cols:  3
				#panels: [
					panelBuilder & {
						spec: {
							display: name: "Capacity"
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {
										unit:          "decimal"
										decimalPlaces: 1
									}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {
									spec: query: #cpuCapacity
								}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: name: "Allocatable"
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {
										unit:          "decimal"
										decimalPlaces: 1
									}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {
									spec: query: #cpuAllocatable
								}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Workload utilization"
								description: "kubepods.slice CPU usage / allocatable"
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {
										unit:          "percent"
										decimalPlaces: 1
									}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {
									spec: query: #cpuUtilization
								}
							}]
						}
					},
				]
			},

			// ── CPU Saturation (PSI) ─────────────────────────
			{
				#title:  "CPU Saturation (PSI)"
				#cols:   1
				#height: 10
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "CPU Pressure"
								description: "Fraction of wall-clock time at least one runnable task was waiting for CPU. Root cgroup (node-wide). CPU PSI only has a \"some\" flavor — there is no \"full\" because there is always at least one task running."
							}
							plugin: #ratioChart
							queries: [
								{#tsQuery & {#query: #cpuPSI, #format: "{{node}}"}},
							]
						}
					},
				]
			},

			// ═══════════════════════════════════════════════════
			// NETWORKING
			// ═══════════════════════════════════════════════════

			{
				#title:  "Networking"
				#cols:   2
				#height: 10
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "NIC Utilization"
								description: "Transmit and receive utilization vs link speed for physical NICs. Filtered by $nic variable."
							}
							plugin: #ratioChart
							queries: [
								{#tsQuery & {#query: #netTxUtil, #format: "TX {{device}}"}},
								{#tsQuery & {#query: #netRxUtil, #format: "RX {{device}}"}},
							]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "NIC Drops & Errors"
								description: "Packet drops (software stack — ring buffer overflow, queue full) and errors (physical layer — CRC failures, runt frames). Normal error rate is 0."
							}
							plugin: #rateChart
							queries: [
								{#tsQuery & {#query: #netDrops, #format: "Drops {{device}}"}},
								{#tsQuery & {#query: #netErrors, #format: "Errors {{device}}"}},
							]
						}
					},
				]
			},

			// ═══════════════════════════════════════════════════
			// STORAGE
			// ═══════════════════════════════════════════════════

			// ── I/O Pressure (PSI) ───────────────────────────
			{
				#title:  "Storage — I/O Pressure"
				#cols:   2
				#height: 10
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "I/O Pressure — Waiting (some)"
								description: "Fraction of wall-clock time at least one task was stalled waiting for block I/O. Root cgroup (node-wide)."
							}
							plugin: #ratioChart
							queries: [
								{#tsQuery & {#query: #ioPSIWaiting, #format: "{{node}}"}},
							]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "I/O Pressure — Stalled (full)"
								description: "Fraction of wall-clock time ALL tasks were stalled on I/O (zero CPU progress). Much more severe than 'some'."
							}
							plugin: #ratioChart
							queries: [
								{#tsQuery & {#query: #ioPSIStalled, #format: "{{node}}"}},
							]
						}
					},
				]
			},

			// ── Fibre Channel ────────────────────────────────
			// No-op on clusters without FC storage — panels
			// show "no data" and the HBA variable is empty.
			{
				#title:  "Storage — Fibre Channel"
				#cols:   2
				#height: 10
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "FC HBA Utilization"
								description: "Transmit and receive utilization vs port link speed. Filtered by $hba variable."
							}
							plugin: #ratioChart
							queries: [
								{#tsQuery & {#query: #fcTxUtil, #format: "TX {{fc_host}}"}},
								{#tsQuery & {#query: #fcRxUtil, #format: "RX {{fc_host}}"}},
							]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "FC Errors & Link Loss"
								description: "CRC/frame errors and loss-of-signal/sync events. Normal value is 0 — any sustained rate indicates a physical layer problem."
							}
							plugin: #rateChart
							queries: [
								{#tsQuery & {#query: #fcErrors, #format: "Errors {{fc_host}}"}},
								{#tsQuery & {#query: #fcLinkLoss, #format: "Link loss {{fc_host}}"}},
							]
						}
					},
				]
			},

			// ── Multipath Health ─────────────────────────────
			// Requires the dmmultipath node_exporter collector
			// (disabled by default in OpenShift).  No-op when
			// disabled or no multipath devices exist.
			{
				#title: "Storage — Multipath Health"
				#cols:  3
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "Devices"
								description: "Number of DM-multipath devices on the node."
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {
										unit:          "decimal"
										decimalPlaces: 0
									}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {
									spec: query: #mpathDevices
								}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Total Paths"
								description: "Sum of all I/O paths across all multipath devices."
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {
										unit:          "decimal"
										decimalPlaces: 0
									}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {
									spec: query: #mpathTotalPaths
								}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Failed Paths"
								description: "Paths in a non-active state. Any value > 0 means degraded redundancy."
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {
										unit:          "decimal"
										decimalPlaces: 0
									}
									thresholds: {
										steps: [
											{value: 0, color: "#32ac2d"},
											{value: 1, color: "#f53636"},
										]
									}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {
									spec: query: #mpathFailedPaths
								}
							}]
						}
					},
				]
			},
		]
	}
}
