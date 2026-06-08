#!/usr/bin/env bash
# Shared helpers for qdma_testapp automation (verify + perf).
# Source from other scripts:  source "$(dirname "$0")/qdma_test_common.sh"

[[ -n "${_QDMA_TEST_COMMON_LOADED:-}" ]] && return 0
_QDMA_TEST_COMMON_LOADED=1

set -euo pipefail

QDMA_TESTAPP="${QDMA_TESTAPP:-}"
# EAL args ONLY (before "--"). Example: -l 0-7 -n 4 -a 0000:81:00.0
# Do NOT put "--" or --filename here.
EAL_OPTS="${EAL_OPTS:--l 0-3 -n 4}"
PORT_ID="${PORT_ID:-0}"
WORK_DIR="${WORK_DIR:-}"
CARD_ADDR="${CARD_ADDR:-0}"
# Total DMA bytes per queue (may span multiple descriptors).
SIZE="${SIZE:-10240}"
# Mbuf / descriptor buffer for port_init (must match QDMA C2H_BUF_SZ table, e.g. 4096).
PKT_BUFF_SIZE="${PKT_BUFF_SIZE:-4096}"
RING_DEPTH="${RING_DEPTH:-1024}"
ITERATIONS="${ITERATIONS:-0}"
PERF_ITERATIONS="${PERF_ITERATIONS:-10000}"
PERF_QUEUES="${PERF_QUEUES:-1 4 8 16}"
RUN_AS_ROOT="${RUN_AS_ROOT:-1}"
KEEP_WORK_DIR="${KEEP_WORK_DIR:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUDO=""
if [[ "${RUN_AS_ROOT}" != "0" ]] && [[ "$(id -u)" -ne 0 ]]; then
	# -E preserves EAL_OPTS / QDMA_TESTAPP when using sudo
	SUDO="sudo -E"
fi

qdma_eal_args() {
	# shellcheck disable=SC2206
	_eal=( ${EAL_OPTS} )
	echo "${_eal[@]}"
}

qdma_check_eal_opts() {
	if [[ "${EAL_OPTS}" == *"--filename"* ]]; then
		echo "ERROR: EAL_OPTS must not contain --filename (use testapp --filename= via script)." >&2
		return 1
	fi
	if [[ "${EAL_OPTS}" == *" -- "* ]] || [[ "${EAL_OPTS}" == "-- "* ]]; then
		echo "WARNING: EAL_OPTS should not include '--'; the script adds it before --filename." >&2
	fi
}

qdma_resolve_testapp() {
	if [[ -n "${QDMA_TESTAPP}" ]] && [[ -x "${QDMA_TESTAPP}" ]]; then
		return 0
	fi
	local candidate
	for candidate in \
		"${SCRIPT_DIR}/build/qdma_testapp" \
		"${SCRIPT_DIR}/build/qdma_testapp-shared" \
		"./build/qdma_testapp" \
		"./build/qdma_testapp-shared"; do
		if [[ -x "${candidate}" ]]; then
			QDMA_TESTAPP="$(cd "$(dirname "${candidate}")" && pwd)/$(basename "${candidate}")"
			return 0
		fi
	done
	echo "ERROR: qdma_testapp not found. Set QDMA_TESTAPP." >&2
	return 1
}

qdma_check_tools() {
	local tool
	for tool in dd cmp mktemp awk date; do
		if ! command -v "${tool}" >/dev/null 2>&1; then
			echo "ERROR: required command not found: ${tool}" >&2
			return 1
		fi
	done
}

qdma_setup_workdir() {
	if [[ -z "${WORK_DIR}" ]]; then
		WORK_DIR="$(mktemp -d /tmp/qdma_test.XXXXXX)"
		_WORK_DIR_CREATED=1
	fi
	mkdir -p "${WORK_DIR}"
	INPUT="${WORK_DIR}/test_10k.bin"
}

qdma_cleanup_workdir() {
	if [[ "${KEEP_WORK_DIR}" == "1" ]]; then
		return 0
	fi
	if [[ -n "${WORK_DIR:-}" ]] && [[ -d "${WORK_DIR}" ]] && [[ "${_WORK_DIR_CREATED:-0}" == "1" ]]; then
		rm -rf "${WORK_DIR}"
	fi
}

qdma_create_input_file() {
	echo "==> Creating ${SIZE}-byte test file: ${INPUT}"
	dd if=/dev/urandom of="${INPUT}" bs="${SIZE}" count=1 status=none
}

# Strip CR from cmd files (heredocs are LF; guard against Windows CRLF edits).
qdma_strip_cr() {
	local path="$1"
	if sed -i 's/\r$//' "${path}" 2>/dev/null; then
		return 0
	fi
	sed 's/\r$//' "${path}" >"${path}.tmp" && mv "${path}.tmp" "${path}"
}

# Return bound driver name for BDF (e.g. 0000:c4:00.0), or empty if none.
qdma_pci_bound_driver() {
	local bdf="$1"
	if [[ -L "/sys/bus/pci/devices/${bdf}/driver" ]]; then
		basename "$(readlink -f "/sys/bus/pci/devices/${bdf}/driver")"
	fi
}

# Unbind BDF from a specific driver if it is bound there (no-op otherwise).
qdma_pci_unbind_driver() {
	local bdf="$1"
	local drv="$2"
	local drv_sysfs="/sys/bus/pci/drivers/${drv}"
	local cur=""

	[[ -d "${drv_sysfs}" ]] || return 0
	cur="$(qdma_pci_bound_driver "${bdf}")"
	if [[ "${cur}" != "${drv}" ]]; then
		return 0
	fi
	echo "==> Unbinding ${bdf} from ${drv}"
	echo "${bdf}" | ${SUDO} tee "${drv_sysfs}/unbind" > /dev/null
}

# Unbind BDF from whichever driver currently owns it.
qdma_pci_unbind_current() {
	local bdf="$1"
	local cur=""

	cur="$(qdma_pci_bound_driver "${bdf}")"
	[[ -n "${cur}" ]] || return 0
	echo "==> Unbinding ${bdf} from ${cur}"
	echo "${bdf}" | ${SUDO} tee "/sys/bus/pci/drivers/${cur}/unbind" > /dev/null
}

# Before DPDK: release kernel QDMA drivers so EAL can use vfio-pci.
qdma_pci_prepare_for_dpdk() {
	local bdf="$1"
	qdma_pci_unbind_driver "${bdf}" "qdma-pf"
	qdma_pci_unbind_driver "${bdf}" "qdma-vf"
}

# Before kernel test_pf_vf.sh: release vfio/uio so qdma-pf can bind.
qdma_pci_prepare_for_kernel() {
	local bdf="$1"
	qdma_pci_unbind_driver "${bdf}" "vfio-pci"
	qdma_pci_unbind_driver "${bdf}" "uio_pci_generic"
	qdma_pci_unbind_driver "${bdf}" "igb_uio"
	# In case a previous kernel run left the device on qdma-pf
	qdma_pci_unbind_driver "${bdf}" "qdma-pf"
}

qdma_write_cmd_file() {
	local path="$1"
	local st_queues="$2"
	local out_file="$3"
	local num_queues="$4"
	local iterations="$5"
	cat >"${path}" <<EOF
port_init ${PORT_ID} ${num_queues} ${st_queues} ${RING_DEPTH} ${PKT_BUFF_SIZE}
dma_to_device ${PORT_ID} ${num_queues} ${INPUT} ${CARD_ADDR} ${SIZE} ${iterations}
dma_from_device ${PORT_ID} ${num_queues} ${out_file} ${CARD_ADDR} ${SIZE} ${iterations}
port_close ${PORT_ID}
EOF
	qdma_strip_cr "${path}"
}

# ST H2C only — use when user BAR / loopback is absent (no ST C2H path).
qdma_write_cmd_file_h2c_only() {
	local path="$1"
	local st_queues="$2"
	local num_queues="$3"
	local iterations="$4"
	cat >"${path}" <<EOF
port_init ${PORT_ID} ${num_queues} ${st_queues} ${RING_DEPTH} ${PKT_BUFF_SIZE}
dma_to_device ${PORT_ID} ${num_queues} ${INPUT} ${CARD_ADDR} ${SIZE} ${iterations}
port_close ${PORT_ID}
EOF
	qdma_strip_cr "${path}"
}

qdma_run_testapp() {
	local cmd_file="$1"
	local log_file="$2"
	local label="$3"
	local -a run_cmd

	qdma_check_eal_opts || return 1

	echo ""
	echo "==> qdma_testapp (${label})"
	echo "    ${QDMA_TESTAPP}"
	echo "    ${cmd_file}"

	# shellcheck disable=SC2206
	run_cmd=( "${QDMA_TESTAPP}" ${EAL_OPTS} -- "--filename=${cmd_file}" )
	echo "    cmd: ${SUDO} ${run_cmd[*]}"

	local start end elapsed
	start=$(date +%s.%N)
	set +e
	${SUDO} "${run_cmd[@]}" >"${log_file}" 2>&1
	local rc=$?
	set -e
	end=$(date +%s.%N)
	elapsed=$(awk -v s="${start}" -v e="${end}" 'BEGIN { printf "%.6f", e - s }')
	echo "${elapsed}" >"${log_file}.elapsed"
	echo "    exit=${rc}  wall_s=${elapsed}  log=${log_file}"
	if [[ ${rc} -ne 0 ]]; then
		echo "ERROR: qdma_testapp failed (${label})" >&2
		tail -n 50 "${log_file}" >&2 || true
		return "${rc}"
	fi
	return 0
}

qdma_compare_files() {
	local label="$1"
	local received="$2"
	echo ""
	echo "==> cmp (${label}): ${INPUT} vs ${received}"
	if [[ ! -f "${received}" ]]; then
		echo "ERROR: missing ${received}" >&2
		return 1
	fi
	local in_sz recv_sz
	in_sz=$(stat -c%s "${INPUT}" 2>/dev/null || stat -f%z "${INPUT}")
	recv_sz=$(stat -c%s "${received}" 2>/dev/null || stat -f%z "${received}")
	if [[ "${in_sz}" != "${SIZE}" ]] || [[ "${recv_sz}" != "${SIZE}" ]]; then
		echo "ERROR: size mismatch sent=${in_sz} recv=${recv_sz} expected=${SIZE}" >&2
		return 1
	fi
	if cmp -s "${INPUT}" "${received}"; then
		echo "PASS: files match (${label})"
		return 0
	fi
	echo "FAIL: files differ (${label})" >&2
	cmp -l "${INPUT}" "${received}" 2>&1 | head -n 20 >&2 || true
	return 1
}

qdma_calc_wall_gbps() {
	local log_elapsed_file="$1"
	local num_queues="$2"
	local iterations="$3"
	local elapsed
	elapsed=$(cat "${log_elapsed_file}")
	local total_bytes
	total_bytes=$((SIZE * (iterations > 0 ? iterations : 1) * num_queues * 2))
	awk -v b="${total_bytes}" -v t="${elapsed}" 'BEGIN {
		if (t <= 0) { print "0"; exit }
		printf "%.4f", (b * 8) / t / 1e9
	}'
}

qdma_parse_log_peak_gbps() {
	local log_file="$1"
	local peak
	peak=$(grep -E 'Throughput G[Bb]ps|Gbps' "${log_file}" 2>/dev/null \
		| grep -oE '[0-9]+\.[0-9]+' \
		| sort -g | tail -n 1 || true)
	if [[ -z "${peak}" ]]; then
		peak=$(awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+\.[0-9]+[[:space:]]+[0-9]+\.[0-9]+/ {
			if ($4 > max) max = $4
		} END { if (max > 0) printf "%.4f", max; }' "${log_file}" 2>/dev/null || true)
	fi
	echo "${peak:-}"
}

qdma_init_common() {
	qdma_resolve_testapp
	qdma_check_tools
	qdma_check_eal_opts
	if [[ "${PKT_BUFF_SIZE}" -gt 4096 ]] && [[ "${SIZE}" -gt "${PKT_BUFF_SIZE}" ]]; then
		echo "NOTE: DMA size ${SIZE} B uses multiple ${PKT_BUFF_SIZE} B descriptors per queue."
	fi
	qdma_setup_workdir
	trap qdma_cleanup_workdir EXIT
}
