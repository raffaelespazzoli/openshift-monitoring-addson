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

#ratioChart: {
	kind: "TimeSeriesChart"
	spec: {
		legend: {position: "bottom", mode: "list"}
		visual: {display: "line", areaOpacity: 0, lineWidth: 2}
		yAxis: format: unit: "percent"
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

#bytesRateChart: {
	kind: "TimeSeriesChart"
	spec: {
		legend: {position: "bottom", mode: "list"}
		visual: {display: "line", areaOpacity: 0.3, lineWidth: 1.5}
		yAxis: format: unit: "bytes/sec"
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
// Common filter — applied to every container-level metric.
// ══════════════════════════════════════════════════════════════════════

_f: "namespace=~\"$namespace\", pod=~\"$pod\", container=~\"$container\", container!=\"POD\", container!=\"\""

// Pod-level filter (no container dimension — for network & I/O PSI).
_pf: "namespace=~\"$namespace\", pod=~\"$pod\""

// ══════════════════════════════════════════════════════════════════════
// MEMORY — PromQL fragments
// ══════════════════════════════════════════════════════════════════════

#rss: "sum(container_memory_rss{" + _f + "})"

#overhead: """
	sum(container_memory_usage_bytes{\( _f )})
	- sum(container_memory_rss{\( _f )})
	- sum(container_memory_cache{\( _f )})
	"""

#hotReclaim: """
	sum(container_memory_cache{\( _f )})
	- (
	  sum(container_memory_usage_bytes{\( _f )})
	  - sum(container_memory_working_set_bytes{\( _f )})
	)
	"""

#coldReclaim: """
	sum(container_memory_usage_bytes{\( _f )})
	- sum(container_memory_working_set_bytes{\( _f )})
	"""

#workingSet:  "sum(container_memory_working_set_bytes{" + _f + "})"
#memLimit:    "sum(kube_pod_container_resource_limits{resource=\"memory\", namespace=~\"$namespace\", pod=~\"$pod\", container=~\"$container\"})"
#memUtilization: """
	sum(container_memory_working_set_bytes{\( _f )})
	/
	sum(kube_pod_container_resource_limits{resource="memory", namespace=~"$namespace", pod=~"$pod", container=~"$container"})
	"""

// ══════════════════════════════════════════════════════════════════════
// CPU — PromQL fragments
// ══════════════════════════════════════════════════════════════════════

#cpuUsage: "sum(rate(container_cpu_usage_seconds_total{" + _f + "}[5m]))"
#cpuLimit: "sum(kube_pod_container_resource_limits{resource=\"cpu\", namespace=~\"$namespace\", pod=~\"$pod\", container=~\"$container\"})"
#cpuUtilization: """
	sum(rate(container_cpu_usage_seconds_total{\( _f )}[5m]))
	/
	sum(kube_pod_container_resource_limits{resource="cpu", namespace=~"$namespace", pod=~"$pod", container=~"$container"})
	"""

// ══════════════════════════════════════════════════════════════════════
// NETWORK — PromQL fragments (pod-level, container="" in cAdvisor)
// ══════════════════════════════════════════════════════════════════════

#netRxBytes: "sum(rate(container_network_receive_bytes_total{" + _pf + ", interface!=\"lo\"}[5m]))"
#netTxBytes: "sum(rate(container_network_transmit_bytes_total{" + _pf + ", interface!=\"lo\"}[5m]))"
#netDrops:   "sum(rate(container_network_receive_packets_dropped_total{" + _pf + "}[5m])) + sum(rate(container_network_transmit_packets_dropped_total{" + _pf + "}[5m]))"
#netErrors:  "sum(rate(container_network_receive_errors_total{" + _pf + "}[5m])) + sum(rate(container_network_transmit_errors_total{" + _pf + "}[5m]))"

// ══════════════════════════════════════════════════════════════════════
// STORAGE — I/O PSI (pod-level recording rules)
// ══════════════════════════════════════════════════════════════════════

#ioPSIWaiting: "pod:io:pressure_waiting:ratio{" + _pf + "}"
#ioPSIStalled: "pod:io:pressure_stalled:ratio{" + _pf + "}"

// ══════════════════════════════════════════════════════════════════════
// Dashboard
// ══════════════════════════════════════════════════════════════════════

dashboardBuilder & {
	#name:    "pod-resources"
	#project: "perses"
	#display: {
		name:        "Pod Resources"
		description: "Pod/container resource overview: memory decomposition, CPU utilization, network throughput, and I/O pressure."
	}
	#duration: "6h"

	#variables: {varGroupBuilder & {
		#input: [
			labelValuesVarBuilder & {
				#name:   "namespace"
				#display: name: "Namespace"
				#metric: "container_memory_working_set_bytes"
				#label:  "namespace"
				#allowAllValue: false
				#allowMultiple: false
			},
			labelValuesVarBuilder & {
				#name:   "pod"
				#display: name: "Pod"
				#label:  "pod"
				#query:  "container_memory_working_set_bytes{namespace=~\"$namespace\",container!=\"\",container!=\"POD\"}"
				#allowAllValue: true
				#allowMultiple: false
			},
			labelValuesVarBuilder & {
				#name:   "container"
				#display: name: "Container"
				#label:  "container"
				#query:  "container_memory_working_set_bytes{namespace=~\"$namespace\",pod=~\"$pod\",container!=\"\",container!=\"POD\"}"
				#allowAllValue: true
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
								name:        "Working Set"
								description: "Memory that cannot be freely reclaimed (usage minus inactive file cache). This is what the kubelet uses for eviction and OOM decisions."
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {unit: "bytes", decimalPlaces: 1}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {spec: query: #workingSet}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: name: "Memory Limit"
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {unit: "bytes", decimalPlaces: 1}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {spec: query: #memLimit}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "Utilization"
								description: "working_set / limit — how close to OOM"
							}
							plugin: #gaugeChart
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {spec: query: #memUtilization}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "RSS"
								description: "Anonymous memory (heap, stack). Cannot be reclaimed without swap — primary driver of OOM kills."
							}
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {unit: "bytes", decimalPlaces: 1}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {spec: query: #rss}
							}]
						}
					},
				]
			},

			// ── Memory decomposition chart ───────────────────
			{
				#title:  "Memory Decomposition"
				#cols:   1
				#height: 12
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "Memory Breakdown"
								description: "Stacked memory usage with limit threshold. Total height = container_memory_usage_bytes."
							}
							plugin: #stackedAreaChart & {
								spec: {
									visual: lineWidth: 2
									querySettings: [{
										queryIndex: 4
										colorMode:  "fixed-single"
										colorValue: "#FFFFFF"
										lineStyle:  "dotted"
										stack:      false
										areaOpacity: 0
									}]
								}
							}
							queries: [
								#tsQuery & {#format: "Non-reclaimable (anon/RSS)", #query: #rss},
								#tsQuery & {#format: "Kernel overhead", #query: #overhead},
								#tsQuery & {#format: "Reclaimable hot (active file)", #query: #hotReclaim},
								#tsQuery & {#format: "Reclaimable cold (inactive file)", #query: #coldReclaim},
								#tsQuery & {#format: "── Memory Limit", #query: #memLimit},
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
								name:        "CPU Usage"
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
							display: name: "CPU Limit"
							plugin: statChart & {
								spec: {
									calculation: "last-number"
									format: {unit: "decimal", decimalPlaces: 1}
								}
							}
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {spec: query: #cpuLimit}
							}]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "CPU Utilization"
								description: "CPU usage / limit"
							}
							plugin: #gaugeChart
							queries: [{
								kind: "TimeSeriesQuery"
								spec: plugin: promQuery & {spec: query: #cpuUtilization}
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
								description: "Network receive and transmit rate (excluding loopback)."
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
			// STORAGE (I/O Pressure via PSI)
			// ═══════════════════════════════════════════════════
			{
				#title:  "Storage"
				#cols:   2
				#height: 10
				#panels: [
					panelBuilder & {
						spec: {
							display: {
								name:        "I/O Pressure — Waiting (some)"
								description: "Fraction of wall-clock time at least one task in this pod was stalled on block I/O. Requires cgroupv2."
							}
							plugin: #ratioChart
							queries: [
								{#tsQuery & {#query: #ioPSIWaiting, #format: "{{pod}}"}},
							]
						}
					},
					panelBuilder & {
						spec: {
							display: {
								name:        "I/O Pressure — Stalled (full)"
								description: "Fraction of wall-clock time ALL tasks in this pod were stalled on I/O (zero progress)."
							}
							plugin: #ratioChart
							queries: [
								{#tsQuery & {#query: #ioPSIStalled, #format: "{{pod}}"}},
							]
						}
					},
				]
			},
		]
	}
}
