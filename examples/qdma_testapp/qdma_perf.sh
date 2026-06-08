#!/usr/bin/env bash
#
# Performance sweep: ST and MM, queue counts in PERF_QUEUES, H2C+C2H per run.
#
# Build testapp with PERF_BENCHMARK for per-burst Gbps in log:
#   Makefile:  CFLAGS += -DPERF_BENCHMARK
# Optional PMD:  meson.build:  cflags += ['-DTHROUGHPUT_MEASUREMENT']
#
# Usage:
#   ./qdma_perf.sh
#   PERF_QUEUES="1 8 16" PERF_ITERATIONS=5000 ./qdma_perf.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=qdma_test_common.sh
source "${SCRIPT_DIR}/qdma_test_common.sh"

qdma_init_common

SUMMARY_CSV="${WORK_DIR}/perf_summary.csv"
mkdir -p "${WORK_DIR}/logs"

qdma_create_input_file

echo "mode,queues,iterations,app_rc,wall_sec,wall_gbps,peak_log_gbps,log_file" >"${SUMMARY_CSV}"

run_perf_case() {
	local mode_label="$1"
	local st_queues="$2"
	local num_queues="$3"
	local tag="${mode_label}_q${num_queues}"
	local out_file="${WORK_DIR}/recv_${tag}.bin"
	local cmd_file="${WORK_DIR}/cmds_${tag}.txt"
	local log_file="${WORK_DIR}/logs/${tag}.log"

	rm -f "${out_file}"
	qdma_write_cmd_file "${cmd_file}" "${st_queues}" "${out_file}" \
		"${num_queues}" "${PERF_ITERATIONS}"

	local app_rc=0
	qdma_run_testapp "${cmd_file}" "${log_file}" "${tag}" || app_rc=$?

	local elapsed peak wall_gbps
	elapsed="$(cat "${log_file}.elapsed" 2>/dev/null || echo 0)"
	wall_gbps="$(qdma_calc_wall_gbps "${log_file}.elapsed" "${num_queues}" "${PERF_ITERATIONS}")"
	peak="$(qdma_parse_log_peak_gbps "${log_file}")"
	[[ -z "${peak}" ]] && peak="n/a"

	echo "${mode_label},${num_queues},${PERF_ITERATIONS},${app_rc},${elapsed},${wall_gbps},${peak},${log_file}" \
		>>"${SUMMARY_CSV}"

	printf "  %-6s queues=%-4s  app=%s  wall=%ss  wall_Gbps=%s  peak_log_Gbps=%s\n" \
		"${mode_label}" "${num_queues}" "${app_rc}" "${elapsed}" "${wall_gbps}" "${peak}"
}

echo ""
echo "========== Performance: Streaming (ST) =========="
echo "  PERF_ITERATIONS=${PERF_ITERATIONS}  PERF_QUEUES=${PERF_QUEUES}"
for nq in ${PERF_QUEUES}; do
	[[ "${nq}" -lt 1 ]] && continue
	run_perf_case "ST" "${nq}" "${nq}"
done

echo ""
echo "========== Performance: Memory mapped (MM) =========="
for nq in ${PERF_QUEUES}; do
	[[ "${nq}" -lt 1 ]] && continue
	run_perf_case "MM" "0" "${nq}"
done

echo ""
echo "========== Results =========="
column -t -s, "${SUMMARY_CSV}" 2>/dev/null || cat "${SUMMARY_CSV}"
echo ""
echo "CSV: ${SUMMARY_CSV}"
echo "WORK_DIR=${WORK_DIR}  (KEEP_WORK_DIR=1 to keep logs)"
