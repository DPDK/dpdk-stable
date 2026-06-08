#!/usr/bin/env bash
#
# DPDK replication of linux-kernel test_pf_vf.sh (PF ST loopback, 10 KiB).
# Prints the same "size=... Average BW = ... MB/sec" lines as dma-to/from-device
# for apples-to-apples comparison with qdma-pf.
#
# Prerequisites:
#   - Rebuild qdma_testapp after enabling BW timing in commands.c
#   - Script unbinds qdma-pf before DPDK and vfio-pci before kernel (RUN_KERNEL_COMPARE=1)
#
# Usage:
#   export EAL_OPTS="-l 0-7 -n 4 -a 0000:c4:00.0"
#   sudo -E ./qdma_compare_pf_vf.sh
#   sudo -E ./qdma_compare_pf_vf.sh c4:00.0
#
# Optional: run kernel test_pf_vf.sh PF section and merge results:
#   export RUN_KERNEL_COMPARE=1
#   export LINUX_QDMA_DIR=/path/to/QDMA/linux-kernel
#   sudo -E ./qdma_compare_pf_vf.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=qdma_test_common.sh
source "${SCRIPT_DIR}/qdma_test_common.sh"

PF_BDF="${1:-${PF_BDF:-c4:00.0}}"
PF_BDF="${PF_BDF#0000:}"
PF_FULL="0000:${PF_BDF}"
SIZE="${SIZE:-10240}"
PKT_BUFF_SIZE="${PKT_BUFF_SIZE:-4096}"
# dma-ctl default ring size in test_pf_vf.sh log
RING_DEPTH="${RING_DEPTH:-2048}"
LOOPBACK_DELAY="${LOOPBACK_DELAY:-2}"
PORT_ID="${PORT_ID:-0}"
NUM_QUEUES=1
ST_QUEUES=1
CARD_ADDR="${CARD_ADDR:-0}"
ITERATIONS=0
RUN_KERNEL_COMPARE="${RUN_KERNEL_COMPARE:-0}"
LINUX_QDMA_DIR="${LINUX_QDMA_DIR:-${SCRIPT_DIR}/../../../../dma_ip_drivers/QDMA/linux-kernel}"
KEEP_WORK_DIR="${KEEP_WORK_DIR:-1}"

qdma_init_common

OUT="${WORK_DIR}/received_pf_10k.bin"
CMD="${WORK_DIR}/cmds_pf_vf_st.txt"
LOG="${WORK_DIR}/qdma_pf_vf_dpdk.log"
SUMMARY="${WORK_DIR}/compare_summary.txt"

qdma_check_dpdk_binding() {
	local drv=""
	if [[ ! -e "/sys/bus/pci/devices/${PF_FULL}" ]]; then
		echo "ERROR: PCI device ${PF_FULL} not found" >&2
		return 1
	fi
	drv="$(qdma_pci_bound_driver "${PF_FULL}")"
	case "${drv}" in
	qdma-pf|qdma-vf)
		echo "ERROR: ${PF_FULL} still bound to '${drv}' after unbind." >&2
		return 1
		;;
	"")
		echo "NOTE: ${PF_FULL} has no driver bound; EAL (-a ${PF_FULL}) will bind vfio-pci." >&2
		;;
	vfio-pci|uio_pci_generic|igb_uio)
		echo "NOTE: ${PF_FULL} bound to ${drv} (OK for DPDK)." >&2
		;;
	*)
		echo "WARNING: ${PF_FULL} bound to '${drv}' — ensure DPDK can use this driver." >&2
		;;
	esac
	return 0
}

qdma_write_pf_vf_cmd_file() {
	local path="$1"
	local out_file="$2"
	cat >"${path}" <<EOF
port_init ${PORT_ID} ${NUM_QUEUES} ${ST_QUEUES} ${RING_DEPTH} ${PKT_BUFF_SIZE}
dma_to_device ${PORT_ID} ${NUM_QUEUES} ${INPUT} ${CARD_ADDR} ${SIZE} ${ITERATIONS}
delay ${LOOPBACK_DELAY}
dma_from_device ${PORT_ID} ${NUM_QUEUES} ${out_file} ${CARD_ADDR} ${SIZE} ${ITERATIONS}
port_close ${PORT_ID}
EOF
	qdma_strip_cr "${path}"
}

qdma_parse_bw_lines() {
	local log="$1"
	local label="$2"
	awk -v lbl="${label}" '
		/size=[0-9]+ Average BW = / {
			if (!h2c) { h2c=$0; next }
			if (!c2h) { c2h=$0; next }
		}
		END {
			print lbl "|H2C|" (h2c ? h2c : "n/a")
			print lbl "|C2H|" (c2h ? c2h : "n/a")
		}
	' "${log}"
}

qdma_extract_mb_sec() {
	# Input line: size=10240 Average BW = 304.671232 MB/sec
	echo "$1" | awk '{
		for (i = 1; i <= NF; i++)
			if ($i == "BW" && $(i+2) ~ /^[0-9]/)
				print $(i+2)
	}'
}

echo "=========================================="
echo "  QDMA ST Loopback Compare (DPDK)"
echo "  Mirrors test_pf_vf.sh PF section"
echo "  Test Size: ${SIZE} B (10 KiB, 3 x 4K descriptors)"
echo "  PF BDF:    ${PF_BDF}"
echo "  Ring depth: ${RING_DEPTH}  mbuf: ${PKT_BUFF_SIZE}  delay: ${LOOPBACK_DELAY}s"
echo "=========================================="

echo ""
echo "=== PCI: prepare for DPDK (unbind qdma-pf / qdma-vf) ==="
qdma_pci_prepare_for_dpdk "${PF_FULL}"
qdma_check_dpdk_binding

echo ""
echo "Creating ${SIZE}-byte test file (dd bs=10K count=1)..."
dd if=/dev/urandom of="${INPUT}" bs=10K count=1 status=none 2>/dev/null \
	|| dd if=/dev/urandom of="${INPUT}" bs="${SIZE}" count=1 status=none

echo ""
echo "=== DPDK PF Test (${PF_BDF}) ==="
qdma_write_pf_vf_cmd_file "${CMD}" "${OUT}"
echo "Command file:"
cat "${CMD}"

DPDK_RC=0
CMP_RC=0
qdma_run_testapp "${CMD}" "${LOG}" "pf-vf-st" || DPDK_RC=$?

echo ""
echo "--- DPDK bandwidth (same metric as dma-to/from-device) ---"
qdma_parse_bw_lines "${LOG}" "DPDK" | while IFS='|' read -r _ dir line; do
	echo "  ${dir}: ${line}"
done

if [[ ${DPDK_RC} -eq 0 ]]; then
	qdma_compare_files "DPDK PF" "${OUT}" || CMP_RC=$?
else
	CMP_RC=1
	echo "DPDK testapp failed — see ${LOG}" >&2
fi

H2C_LINE=$(grep -m1 'size=.*Average BW' "${LOG}" 2>/dev/null || true)
C2H_LINE=$(grep 'size=.*Average BW' "${LOG}" 2>/dev/null | sed -n '2p' || true)
H2C_MB=$(qdma_extract_mb_sec "${H2C_LINE:-}")
C2H_MB=$(qdma_extract_mb_sec "${C2H_LINE:-}")

{
	echo "driver,bdf,size_bytes,h2c_mb_sec,c2h_mb_sec,cmp_pass,app_rc,log"
	echo "dpdk,${PF_BDF},${SIZE},${H2C_MB:-n/a},${C2H_MB:-n/a},$([[ ${CMP_RC} -eq 0 ]] && echo 1 || echo 0),${DPDK_RC},${LOG}"
} >"${SUMMARY}"

KERNEL_H2C=""
KERNEL_C2H=""
KERNEL_CMP=""
if [[ "${RUN_KERNEL_COMPARE}" == "1" ]] && [[ -x "${LINUX_QDMA_DIR}/test_pf_vf.sh" ]]; then
	echo ""
	echo "=== PCI: prepare for kernel (unbind vfio-pci / uio, then qdma-pf if needed) ==="
	qdma_pci_prepare_for_kernel "${PF_FULL}"
	echo ""
	echo "=== Kernel PF Test (test_pf_vf.sh) ==="
	echo "NOTE: test_pf_vf.sh reloads qdma-pf and binds ${PF_FULL} via driver_override."
	KLOG="${WORK_DIR}/kernel_pf_vf.log"
	set +e
	"${LINUX_QDMA_DIR}/test_pf_vf.sh" "${PF_BDF}" 2>&1 | tee "${KLOG}"
	KRC=${PIPESTATUS[0]}
	set -e
	KERNEL_H2C=$(grep -m1 'size=.*Average BW' "${KLOG}" 2>/dev/null || true)
	KERNEL_C2H=$(grep 'size=.*Average BW' "${KLOG}" 2>/dev/null | sed -n '2p' || true)
	if grep -q 'PF TEST PASSED' "${KLOG}" 2>/dev/null; then
		KERNEL_CMP=1
	else
		KERNEL_CMP=0
	fi
	echo "driver,bdf,size_bytes,h2c_mb_sec,c2h_mb_sec,cmp_pass,app_rc,log" >>"${SUMMARY}"
	echo "qdma-pf,${PF_BDF},${SIZE},$(qdma_extract_mb_sec "${KERNEL_H2C:-}"),$(qdma_extract_mb_sec "${KERNEL_C2H:-}"),${KERNEL_CMP},${KRC},${KLOG}" >>"${SUMMARY}"
fi

echo ""
echo "=========================================="
echo "  Summary"
echo "=========================================="
printf "  DPDK   H2C: %s\n" "${H2C_LINE:-n/a}"
printf "  DPDK   C2H: %s\n" "${C2H_LINE:-n/a}"
printf "  DPDK   cmp: %s\n" "$([[ ${CMP_RC} -eq 0 ]] && echo PASS || echo FAIL)"
if [[ -n "${KERNEL_H2C}" ]]; then
	printf "  Kernel H2C: %s\n" "${KERNEL_H2C}"
	printf "  Kernel C2H: %s\n" "${KERNEL_C2H}"
	printf "  Kernel cmp: %s\n" "$([[ ${KERNEL_CMP} == 1 ]] && echo PASS || echo FAIL)"
fi
echo ""
echo "CSV: ${SUMMARY}"
echo "WORK_DIR=${WORK_DIR}"

FINAL=0
[[ ${DPDK_RC} -ne 0 || ${CMP_RC} -ne 0 ]] && FINAL=1
exit "${FINAL}"
