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

#stackedAreaChart: {
	kind: "TimeSeriesChart"
	spec: {
		legend: {position: "bottom", mode: "list"}
		visual: {display: "line", areaOpacity: 0.7, stack: "all", ...}
		yAxis: format: unit: "bytes"
		...
	}
}

#lineChart: {
	kind: "TimeSeriesChart"
	spec: {
		legend: {position: "bottom", mode: "list"}
		visual: {display: "line", areaOpacity: 0, lineWidth: 2}
		yAxis: format: unit: "bytes"
		...
	}
}

#gaugeChart: {
	kind: "GaugeChart"
	spec: {
		calculation: "last-number"
		format: {unit: "percent", decimalPlaces: 1}
		thresholds: steps: [
			{value: 0, color: "#32ac2d"},
			{value: 0.80, color: "#ed8128"},
			{value: 0.95, color: "#f53636"},
		]
	}
}

#latencyChart: {
	kind: "TimeSeriesChart"
	spec: {
		legend: {position: "bottom", mode: "list"}
		visual: {display: "line", areaOpacity: 0, lineWidth: 2}
		yAxis: format: unit: "seconds"
	}
}

#bytesRateChart: {
	kind: "TimeSeriesChart"
	spec: {
		legend: {position: "bottom", mode: "list"}
		visual: {display: "line", areaOpacity: 0.3, lineWidth: 1.5}
		yAxis: format: unit: "bytes/sec"
	}
}

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
		spec: {query: #query, seriesNameFormat: #format}
	}
}

// ══════════════════════════════════════════════════════════════════════
// Common filter
// ══════════════════════════════════════════════════════════════════════

_f: "name=~\"$vm\", namespace=~\"$namespace\""

// ══════════════════════════════════════════════════════════════════════
// MEMORY — PromQL fragments
// ══════════════════════════════════════════════════════════════════════

// Guest memory decomposition (4 stacked layers summing to domain):
//   domain = kernel_reserved + used + reclaimable + free
#kernelReserved: """
	kubevirt_vmi_memory_domain_bytes{\( _f )}
	- kubevirt_vmi_memory_available_bytes{\( _f )}
	"""
#used:        "kubevirt_vmi_memory_used_bytes{" + _f + "}"
#reclaimable: "kubevirt_vmi_memory_usable_bytes{" + _f + "} - kubevirt_vmi_memory_unused_bytes{" + _f + "}"
#free:        "kubevirt_vmi_memory_unused_bytes{" + _f + "}"
#domain:      "kubevirt_vmi_memory_domain_bytes{" + _f + "}"
#available:   "kubevirt_vmi_memory_available_bytes{" + _f + "}"

#memUtilization: """
	kubevirt_vmi_memory_used_bytes{\( _f )}
	/ kubevirt_vmi_memory_available_bytes{\( _f )}
	"""

// Launcher overhead: estimated vs actual.
#overheadEstimated: "kubevirt_vmi_launcher_memory_overhead_bytes{" + _f + "}"
#overheadActual:    "vmi:capacity:launcher_overhead_memory:bytes{" + _f + "}"

// ══════════════════════════════════════════════════════════════════════
// CPU — PromQL fragments
// ══════════════════════════════════════════════════════════════════════

#cpuUsage:    "sum(rate(kubevirt_vmi_cpu_usage_seconds_total{" + _f + "}[5m]))"
#vcpuCount:   "count(kubevirt_vmi_vcpu_delay_seconds_total{" + _f + "}) or vector(0)"
#vcpuDelay:   "vmi:cpu:vcpu_delay:ratio{" + _f + "}"

// ══════════════════════════════════════════════════════════════════════
// NETWORK — PromQL fragments (per-interface, summed across interfaces)
// ══════════════════════════════════════════════════════════════════════

#netRxBytes: "sum(rate(kubevirt_vmi_network_receive_bytes_total{" + _f + "}[5m]))"
#netTxBytes: "sum(rate(kubevirt_vmi_network_transmit_bytes_total{" + _f + "}[5m]))"
#netDrops:   "vmi:network:drop_rate:packets_per_second{" + _f + "}"
#netErrors:  "vmi:network:error_rate:packets_per_second{" + _f + "}"

// ══════════════════════════════════════════════════════════════════════
// STORAGE — PromQL fragments (recording rules)
// ══════════════════════════════════════════════════════════════════════

#ioReadLatency:  "vmi:io:read_latency:seconds{" + _f + "}"
#ioWriteLatency: "vmi:io:write_latency:seconds{" + _f + "}"
#ioThroughput:   "vmi:io:throughput:bytes_per_second{" + _f + "}"

// ══════════════════════════════════════════════════════════════════════
// Dashboard
// ══════════════════════════════════════════════════════════════════════

dashboardBuilder & {
	#name:    "vm-resources"
	#project: "perses"
	#display: {
		name:        "VM Resources"
		description: "Per-VM resource overview: guest memory decomposition, vCPU usage & scheduling delay, network throughput, and storage I/O latency."
	}
	#duration: "6h"

	#variables: {varGroupBuilder & {
		#input: [
			labelValuesVarBuilder & {
				#name:     "namespace"
				#display:  name: "Namespace"
				#metric:   "kubevirt_vmi_memory_available_bytes"
				#label:    "namespace"
				#allowAllValue: false
				#allowMultiple: false
			},
			labelValuesVarBuilder & {
				#name:     "vm"
				#display:  name: "VM"
				#label:    "name"
				#query:    "kubevirt_vmi_memory_available_bytes{namespace=~\"$namespace\"}"
				#allowAllValue: false
				#allowMultiple: false
			},
		]
	}}.variables

	#panelGroups: panelGroupsBuilder & {
		#input: [

			// ═══════════════════════════════════════════════════
			// MEMORY
			// ═══════════════════════════════════════════════════

			// ── Memory stats ─────────────────────────────────
			{
				#title: "Memory"
				#cols:  4
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "Domain"
								description: "Total memory allocated to the QEMU domain — the VM's configured size."
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {unit: "bytes", decimalPlaces: 1}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {spec: query: #domain}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Available (MemTotal)"
								description: "Usable memory inside the guest — domain minus kernel reserved."
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {unit: "bytes", decimalPlaces: 1}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {spec: query: #available}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Used (non-reclaimable)"
								description: "Memory actively in use — cannot be freed without swap or OOM."
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {unit: "bytes", decimalPlaces: 1}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {spec: query: #used}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Utilization"
								description: "used / available — how close to guest OOM."
							}
							plugin: #gaugeChart
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {spec: query: #memUtilization}
							}]
						}
					},
				]
			},

			// ── Memory decomposition + launcher overhead ─────
			{
				#title:  "Memory Decomposition & Launcher Overhead"
				#cols:   2
				#height: 12
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "Guest Memory Decomposition"
								description: "Four layers summing to domain: kernel reserved + non-reclaimable + reclaimable + free."
							}
							plugin: #stackedAreaChart & {
								spec: {
									visual: lineWidth: 2
									querySettings: [{
										queryIndex:  4
										colorMode:   "fixed-single"
										colorValue:  "#FFFFFF"
										lineStyle:   "dotted"
										stack:       false
										areaOpacity: 0
									}]
								}
							}
							queries: [
								#tsQuery & {#query: #kernelReserved, #format: "Kernel reserved"},
								#tsQuery & {#query: #used, #format: "Non-reclaimable (used)"},
								#tsQuery & {#query: #reclaimable, #format: "Reclaimable"},
								#tsQuery & {#query: #free, #format: "Free"},
								#tsQuery & {#query: #domain, #format: "── Domain (configured)"},
							]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Launcher Overhead: Estimated vs Actual"
								description: "Estimated = virt-controller prediction. Actual = pod working_set minus guest RSS. When actual exceeds estimated, the overhead budget is too tight."
							}
							plugin: #lineChart & {
								spec: {
									querySettings: [
										{queryIndex: 0, colorMode: "fixed-single", colorValue: "#32ac2d", lineStyle: "dotted"},
										{queryIndex: 1, colorMode: "fixed-single", colorValue: "#2E79B5"},
									]
								}
							}
							queries: [
								#tsQuery & {#query: #overheadEstimated, #format: "Estimated overhead"},
								#tsQuery & {#query: #overheadActual, #format: "Actual overhead"},
							]
						}
					},
				]
			},

			// ═══════════════════════════════════════════════════
			// CPU
			// ═══════════════════════════════════════════════════
			{
				#title: "CPU"
				#cols:  3
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "vCPU Usage"
								description: "Actual CPU consumption (cores)."
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {unit: "decimal", decimalPlaces: 2}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {spec: query: #cpuUsage}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "vCPU Count"
								description: "Number of virtual CPUs assigned to the VM."
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {unit: "decimal", decimalPlaces: 0}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {spec: query: #vcpuCount}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "vCPU Scheduling Delay"
								description: "Time vCPUs spend in the host scheduler queue — how much CPU the VM wants but cannot get."
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {unit: "decimal", decimalPlaces: 3}
									thresholds: steps: [
										{value: 0, color: "#32ac2d"},
										{value: 0.1, color: "#ed8128"},
										{value: 0.5, color: "#f53636"},
									]
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {spec: query: #vcpuDelay}
							}]
						}
					},
				]
			},

			// ═══════════════════════════════════════════════════
			// NETWORK
			// ═══════════════════════════════════════════════════
			{
				#title:  "Network"
				#cols:   2
				#height: 10
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "Throughput"
								description: "Network receive and transmit rate across all VM interfaces."
							}
							plugin: #bytesRateChart
							queries: [
								{#tsQuery & {#query: #netRxBytes, #format: "RX"}},
								{#tsQuery & {#query: #netTxBytes, #format: "TX"}},
							]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Drops & Errors"
								description: "Network packet drops and errors. Normal value is 0."
							}
							plugin: #rateChart
							queries: [
								{#tsQuery & {#query: #netDrops, #format: "Drops"}},
								{#tsQuery & {#query: #netErrors, #format: "Errors"}},
							]
						}
					},
				]
			},

			// ═══════════════════════════════════════════════════
			// STORAGE
			// ═══════════════════════════════════════════════════
			{
				#title:  "Storage"
				#cols:   2
				#height: 10
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "I/O Latency"
								description: "Storage read and write latency (seconds per operation). Higher latency = storage saturation."
							}
							plugin: #latencyChart
							queries: [
								{#tsQuery & {#query: #ioReadLatency, #format: "Read latency"}},
								{#tsQuery & {#query: #ioWriteLatency, #format: "Write latency"}},
							]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "I/O Throughput"
								description: "Total storage throughput (read + write) across all drives."
							}
							plugin: #bytesRateChart
							queries: [
								{#tsQuery & {#query: #ioThroughput, #format: "Throughput"}},
							]
						}
					},
				]
			},
		]
	}
}
