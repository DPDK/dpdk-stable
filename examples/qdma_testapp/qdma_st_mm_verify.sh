#!/usr/bin/env bash
#
# Functional check: ST then MM — H2C, C2H, cmp (10 KiB).
#
# Usage:
#   ./qdma_st_mm_verify.sh
#   EAL_OPTS="-l 0-7 -n 4 -a 0000:xx:00.0" sudo -E ./qdma_st_mm_verify.sh
#
# ST C2H requires user BAR + loopback or user logic. On minimal bitstreams use:
#   ST_H2C_ONLY=1 ./qdma_st_mm_verify.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=qdma_test_common.sh
source "${SCRIPT_DIR}/qdma_test_common.sh"

qdma_init_common

OUT_ST="${WORK_DIR}/recv_st_10k.bin"
OUT_MM="${WORK_DIR}/recv_mm_10k.bin"
CMD_ST="${WORK_DIR}/cmds_st.txt"
CMD_MM="${WORK_DIR}/cmds_mm.txt"
LOG_ST="${WORK_DIR}/qdma_st.log"
LOG_MM="${WORK_DIR}/qdma_mm.log"

NUM_QUEUES=1
ST_H2C_ONLY="${ST_H2C_ONLY:-0}"

qdma_create_input_file

echo ""
echo "========== Phase 1: Streaming =========="
if [[ "${ST_H2C_ONLY}" == "1" ]]; then
	echo "ST_H2C_ONLY=1: H2C transmit only (skip ST C2H/cmp — no user BAR/loopback)"
	qdma_write_cmd_file_h2c_only "${CMD_ST}" 1 "${NUM_QUEUES}" "${ITERATIONS}"
else
	qdma_write_cmd_file "${CMD_ST}" 1 "${OUT_ST}" "${NUM_QUEUES}" "${ITERATIONS}"
fi
cat "${CMD_ST}"
ST_APP_RC=0
ST_CMP_RC=0
qdma_run_testapp "${CMD_ST}" "${LOG_ST}" "streaming" || ST_APP_RC=$?
if [[ "${ST_H2C_ONLY}" == "1" ]]; then
	if [[ ${ST_APP_RC} -eq 0 ]]; then
		echo "ST H2C: PASS (C2H/cmp skipped)"
		ST_CMP_RC=0
	else
		ST_CMP_RC=1
	fi
elif [[ ${ST_APP_RC} -eq 0 ]]; then
	qdma_compare_files "streaming" "${OUT_ST}" || ST_CMP_RC=$?
else
	ST_CMP_RC=1
fi

echo ""
echo "========== Phase 2: Memory mapped =========="
rm -f "${OUT_MM}"
qdma_write_cmd_file "${CMD_MM}" 0 "${OUT_MM}" "${NUM_QUEUES}" "${ITERATIONS}"
cat "${CMD_MM}"
MM_APP_RC=0
MM_CMP_RC=0
qdma_run_testapp "${CMD_MM}" "${LOG_MM}" "memory-mapped" || MM_APP_RC=$?
if [[ ${MM_APP_RC} -eq 0 ]]; then
	qdma_compare_files "memory-mapped" "${OUT_MM}" || MM_CMP_RC=$?
else
	MM_CMP_RC=1
fi

echo ""
echo "========== Summary =========="
echo "  ST  app=${ST_APP_RC}  cmp=${ST_CMP_RC}  (ST_H2C_ONLY=${ST_H2C_ONLY})"
echo "  MM  app=${MM_APP_RC}  cmp=${MM_CMP_RC}"
echo "  WORK_DIR=${WORK_DIR}  (KEEP_WORK_DIR=1 to keep)"

FINAL=0
[[ ${ST_APP_RC} -ne 0 || ${ST_CMP_RC} -ne 0 ]] && FINAL=1
[[ ${MM_APP_RC} -ne 0 || ${MM_CMP_RC} -ne 0 ]] && FINAL=1
[[ ${FINAL} -eq 0 ]] && echo "Overall: PASS" && exit 0
echo "Overall: FAIL"
exit 1
