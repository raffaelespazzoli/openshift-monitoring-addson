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

// Gauge chart — workload utilization ratio with color thresholds.
#gaugeChart: {
	kind: "GaugeChart"
	spec: {
		calculation: "last-number"
		format: {
			unit:          "percent"
			decimalPlaces: 1
		}
		thresholds: {
			steps: [
				{value: 0, color: "#32ac2d"},
				{value: 0.80, color: "#ed8128"},
				{value: 0.95, color: "#f53636"},
			]
		}
	}
}

// Compact time series — used inline in summary rows for system used
// and PSI pressure.  No legend (too small), thin lines.
#sparkBytes: {
	kind: "TimeSeriesChart"
	spec: {
		legend: {position: "bottom", mode: "list"}
		visual: {display: "line", areaOpacity: 0.3, lineWidth: 1.5}
		yAxis: format: unit: "bytes"
	}
}
#sparkRatio: {
	kind: "TimeSeriesChart"
	spec: {
		legend: {position: "bottom", mode: "list"}
		visual: {display: "line", areaOpacity: 0.3, lineWidth: 1.5}
		yAxis: format: unit: "percent"
	}
}
#sparkCores: {
	kind: "TimeSeriesChart"
	spec: {
		legend: {position: "bottom", mode: "list"}
		visual: {display: "line", areaOpacity: 0.3, lineWidth: 1.5}
		yAxis: format: unit: "decimal"
	}
}

// Line chart for ratios 0–1 displayed as percentages (PSI, utilization).
#ratioChart: {
	kind: "TimeSeriesChart"
	spec: {
		legend: {position: "bottom", mode: "list"}
		visual: {display: "line", areaOpacity: 0, lineWidth: 2}
		yAxis: format: unit: "percent"
	}
}

// Line chart for absolute rates (packets/s, frames/s).
#rateChart: {
	kind: "TimeSeriesChart"
	spec: {
		legend: {position: "bottom", mode: "list"}
		visual: {display: "line", areaOpacity: 0, lineWidth: 2}
		yAxis: format: unit: "decimal"
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

_wk: "{node=~\"$node\"}"
_sy: "{node=~\"$node\"}"

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
#cpuSystemUsed: "sum(rate(container_cpu_usage_seconds_total{id=\"/system.slice\", node=~\"$node\"}[5m]))"
#cpuPSI:        "node:cpu:pressure:ratio{node=~\"$node\"}"

// ══════════════════════════════════════════════════════════════════════
// NETWORKING — PromQL fragments
// ══════════════════════════════════════════════════════════════════════

_netFilter: "{instance=~\"$node\", device=~\"$nic\"}"
#netTxUtil:  "node_nic:network:transmit_utilization:ratio" + _netFilter
#netRxUtil:  "node_nic:network:receive_utilization:ratio" + _netFilter
#netDrops:   "node_nic:network:drop_rate:packets_per_second" + _netFilter
#netErrors:  "node_nic:network:error_rate:packets_per_second" + _netFilter

// ══════════════════════════════════════════════════════════════════════
// STORAGE — PromQL fragments
// ══════════════════════════════════════════════════════════════════════

#ioPSIWaiting: "node:io:pressure_waiting:ratio{node=~\"$node\"}"
#ioPSIStalled: "node:io:pressure_stalled:ratio{node=~\"$node\"}"

_fcFilter: "{instance=~\"$node\", fc_host=~\"$hba\"}"
#fcTxUtil:   "node_hba:fc:transmit_utilization:ratio" + _fcFilter
#fcRxUtil:   "node_hba:fc:receive_utilization:ratio" + _fcFilter
#fcErrors:   "node_hba:fc:error_rate:frames_per_second" + _fcFilter
#fcLinkLoss: "node_hba:fc:link_loss_rate:per_second" + _fcFilter

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
		description: "Per-node resource overview: memory utilization & PSI, CPU utilization & PSI, NIC saturation, I/O pressure, Fibre Channel, and multipath health."
	}
	#duration: "6h"

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

	#panelGroups: panelGroupsBuilder & {
		#input: [

			// ═══════════════════════════════════════════════════
			// MEMORY — single compact row: stats + gauge + graphs
			// ═══════════════════════════════════════════════════
			{
				#title:  "Memory"
				#cols:   6
				#height: 8
				#panels: [
					// 1. Capacity (stat)
					panelBuilder & {
						spec: {
							display: name: "Capacity"
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {unit: "bytes", decimalPlaces: 1}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {spec: query: #capacity}
							}]
						}
					},
					// 2. Allocatable (stat)
					panelBuilder & {
						spec: {
							display: name: "Allocatable"
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {unit: "bytes", decimalPlaces: 1}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {spec: query: #allocatable}
							}]
						}
					},
					// 3. Workload utilization (gauge)
					panelBuilder & {
						spec: {
							display: {
								name:        "Workload Utilization"
								description: "kubepods.slice working_set / allocatable — the kubelet eviction metric"
							}
							plugin: #gaugeChart
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {spec: query: #workloadUtilization}
							}]
						}
					},
					// 4. Reserved (stat)
					panelBuilder & {
						spec: {
							display: {
								name:        "Reserved"
								description: "system-reserved + kube-reserved + eviction-threshold"
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {unit: "bytes", decimalPlaces: 1}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {spec: query: #reserved}
							}]
						}
					},
					// 5. System used (time series graph)
					panelBuilder & {
						spec: {
							display: {
								name:        "System Used"
								description: "system.slice total memory (can exceed reserved via file cache)"
							}
							plugin: #sparkBytes
							queries: [
								{#tsQuery & {#query: #systemUsed, #format: "{{node}}"}},
							]
						}
					},
					// 6. Memory Pressure (time series graph — PSI)
					panelBuilder & {
						spec: {
							display: {
								name:        "Memory Pressure"
								description: "PSI — fraction of time processes stalled waiting for memory reclaim"
							}
							plugin: #sparkRatio
							queries: [
								{#tsQuery & {#query: #memoryPSI, #format: "{{node}}"}},
							]
						}
					},
				]
			},

			// ═══════════════════════════════════════════════════
			// CPU — single compact row: stats + gauge + graphs
			// ═══════════════════════════════════════════════════
			{
				#title:  "CPU"
				#cols:   5
				#height: 8
				#panels: [
					// 1. Capacity (stat)
					panelBuilder & {
						spec: {
							display: name: "Capacity"
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {unit: "decimal", decimalPlaces: 1}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {spec: query: #cpuCapacity}
							}]
						}
					},
					// 2. Allocatable (stat)
					panelBuilder & {
						spec: {
							display: name: "Allocatable"
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {unit: "decimal", decimalPlaces: 1}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {spec: query: #cpuAllocatable}
							}]
						}
					},
					// 3. Workload utilization (gauge)
					panelBuilder & {
						spec: {
							display: {
								name:        "Workload Utilization"
								description: "kubepods.slice CPU usage / allocatable"
							}
							plugin: #gaugeChart
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {spec: query: #cpuUtilization}
							}]
						}
					},
					// 4. System CPU used (time series graph)
					panelBuilder & {
						spec: {
							display: {
								name:        "System Used"
								description: "system.slice CPU usage (cores)"
							}
							plugin: #sparkCores
							queries: [
								{#tsQuery & {#query: #cpuSystemUsed, #format: "{{node}}"}},
							]
						}
					},
					// 5. CPU Pressure (time series graph — PSI)
					panelBuilder & {
						spec: {
							display: {
								name:        "CPU Pressure"
								description: "PSI — fraction of time runnable tasks waited for a CPU"
							}
							plugin: #sparkRatio
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
								description: "Transmit and receive utilization vs link speed for physical NICs."
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
								description: "Packet drops (ring buffer overflow) and errors (CRC failures). Normal rate is 0."
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
								description: "Fraction of wall-clock time at least one task was stalled waiting for block I/O."
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
								description: "Fraction of wall-clock time ALL tasks were stalled on I/O (zero CPU progress)."
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
			{
				#title:  "Storage — Fibre Channel"
				#cols:   2
				#height: 10
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "FC HBA Utilization"
								description: "Transmit and receive utilization vs port link speed."
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
								description: "CRC/frame errors and loss-of-signal/sync events. Normal value is 0."
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
									format: {unit: "decimal", decimalPlaces: 0}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {spec: query: #mpathDevices}
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
									format: {unit: "decimal", decimalPlaces: 0}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {spec: query: #mpathTotalPaths}
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
									format: {unit: "decimal", decimalPlaces: 0}
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
								spec: plugin: promQuery & {spec: query: #mpathFailedPaths}
							}]
						}
					},
				]
			},
		]
	}
}
