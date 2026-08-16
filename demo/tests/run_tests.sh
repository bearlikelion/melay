#!/usr/bin/env bash
# End-to-end check: build and start the relay, then run two headless Godot
# instances that share a room and exchange RPCs over it.
#
# Usage:
#   tests/run_tests.sh                 # builds and starts its own relay
#   MELAY_URL=ws://host:8890 tests/run_tests.sh   # uses a relay you already run

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The Godot project lives at demo/; the relay source is at the repo root.
REPO_ROOT="$(cd "${PROJECT_DIR}/.." && pwd)"
GODOT="${GODOT:-godot}"
PORT="${MELAY_TEST_PORT:-18899}"
URL="${MELAY_URL:-ws://127.0.0.1:${PORT}}"

WORK_DIR="$(mktemp -d)"
CODE_FILE="${WORK_DIR}/room_code"
SERVER_PID=""

cleanup() {
	if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" 2>/dev/null; then
		kill "${SERVER_PID}" 2>/dev/null
		wait "${SERVER_PID}" 2>/dev/null
	fi
	rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

if [[ -z "${MELAY_URL:-}" ]]; then
	echo "==> building the relay"
	if ! (cd "${REPO_ROOT}/server" && go build -o "${WORK_DIR}/melay" ./cmd/melay); then
		echo "relay build failed"
		exit 1
	fi

	echo "==> starting the relay on :${PORT}"
	(
		cd "${WORK_DIR}" || exit 1
		MELAY_ADDR=":${PORT}" MELAY_DATABASE_URL="file:${WORK_DIR}/test.db" \
			"${WORK_DIR}/melay" --config /nonexistent.yaml
	) >"${WORK_DIR}/server.log" 2>&1 &
	SERVER_PID=$!

	for _ in $(seq 1 50); do
		if curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
			break
		fi
		sleep 0.1
	done
	if ! curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
		echo "relay did not come up"
		cat "${WORK_DIR}/server.log"
		exit 1
	fi
fi

run_instance() {
	local scene="$1" role="$2" tag="$3"
	"${GODOT}" --headless --path "${PROJECT_DIR}" "${scene}" -- \
		"--role=${role}" "--code-file=${CODE_FILE}" "--url=${URL}" \
		>"${WORK_DIR}/${tag}.log" 2>&1
	echo "$?" >"${WORK_DIR}/${tag}.status"
}

# Runs one host/guest pair against a scene and reports whether both passed.
run_pair() {
	local scene="$1" label="$2"
	rm -f "${CODE_FILE}" "${CODE_FILE}.guest-done"

	echo "==> ${label}"
	run_instance "${scene}" host "${label}-host" &
	local host_job=$!
	# Staggered so the host publishes its room code before the guest starts polling.
	sleep 1
	run_instance "${scene}" guest "${label}-guest" &
	local guest_job=$!

	wait "${host_job}"
	wait "${guest_job}"

	local host_status guest_status
	host_status="$(cat "${WORK_DIR}/${label}-host.status" 2>/dev/null || echo 1)"
	guest_status="$(cat "${WORK_DIR}/${label}-guest.status" 2>/dev/null || echo 1)"

	echo
	echo "----- ${label} host -----"
	grep -E '^\[|FAIL|PASSED|SCRIPT ERROR' "${WORK_DIR}/${label}-host.log" \
		|| tail -20 "${WORK_DIR}/${label}-host.log"
	echo "----- ${label} guest -----"
	grep -E '^\[|FAIL|PASSED|SCRIPT ERROR' "${WORK_DIR}/${label}-guest.log" \
		|| tail -20 "${WORK_DIR}/${label}-guest.log"
	echo

	[[ "${host_status}" == "0" && "${guest_status}" == "0" ]]
}

FAILED=0

# Local physics checks need no relay, so they run first and fail fast.
echo "==> arena physics"
if "${GODOT}" --headless --path "${PROJECT_DIR}" res://tests/ball_test.tscn \
	>"${WORK_DIR}/ball.log" 2>&1; then
	grep -E '^\[ball\]' "${WORK_DIR}/ball.log"
else
	grep -E '^\[ball\]|SCRIPT ERROR' "${WORK_DIR}/ball.log" || tail -20 "${WORK_DIR}/ball.log"
	FAILED=1
fi
echo

run_pair res://tests/melay_test.tscn peer || FAILED=1
run_pair res://tests/demo_drive.tscn demo || FAILED=1

if [[ -f "${WORK_DIR}/server.log" ]]; then
	echo "===== relay ====="
	tail -20 "${WORK_DIR}/server.log"
	echo
fi

if [[ "${FAILED}" == "0" ]]; then
	echo "PASS"
	exit 0
fi

echo "FAIL"
exit 1
