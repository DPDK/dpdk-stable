#!/usr/bin/env bash
#
# Wrapper: functional verify, performance sweep, or both.
#
# Usage:
#   ./qdma_run_tests.sh              # verify only (default)
#   ./qdma_run_tests.sh --verify
#   ./qdma_run_tests.sh --perf
#   ./qdma_run_tests.sh --all

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Show effective EAL options (must be before "--" in the testapp command line).
echo "EAL_OPTS=${EAL_OPTS:--l 0-3 -n 4}"
echo "PKT_BUFF_SIZE=${PKT_BUFF_SIZE:-4096}  SIZE=${SIZE:-10240}  CARD_ADDR=${CARD_ADDR:-0}"
echo "Tip: export EAL_OPTS=\"-l 0-7 -n 4 -a 0000:bb:00.0\"  and use: sudo -E ./qdma_run_tests.sh ..."
echo ""

DO_VERIFY=0
DO_PERF=0

if [[ $# -eq 0 ]]; then
	DO_VERIFY=1
fi

while [[ $# -gt 0 ]]; do
	case "$1" in
	--verify)
		DO_VERIFY=1
		;;
	--perf)
		DO_PERF=1
		;;
	--all)
		DO_VERIFY=1
		DO_PERF=1
		;;
	-h|--help)
		echo "Usage: $0 [--verify] [--perf] [--all]"
		exit 0
		;;
	*)
		echo "Unknown option: $1" >&2
		exit 1
		;;
	esac
	shift
done

export WORK_DIR="${WORK_DIR:-$(mktemp -d /tmp/qdma_run.XXXXXX)}"
export KEEP_WORK_DIR="${KEEP_WORK_DIR:-1}"

RC=0

if [[ ${DO_VERIFY} -eq 1 ]]; then
	echo "################ verify ################"
	"${SCRIPT_DIR}/qdma_st_mm_verify.sh" || RC=$?
fi

if [[ ${DO_PERF} -eq 1 ]]; then
	echo ""
	echo "################ perf ################"
	"${SCRIPT_DIR}/qdma_perf.sh" || RC=$?
fi

exit "${RC}"
