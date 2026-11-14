#!/usr/bin/env bash
# One batch of a Go suite. Each slice is one _test.go file; its tests run
# under Bazel exactly as `bazel test //...` runs them, filtered to the
# file's own test functions. In a recording run the same command runs as
# `bazel coverage` with Go's own coverprofile format, and the profile goes
# into the slice's coverage directory, where go-correlator reads it.
#
# Inputs (Concourse): source, batches, tools. Outputs: result, coverage.
# GAVEL_DOCKER=true starts a Docker daemon first, for the suites whose
# tests start PostgreSQL through testcontainers.
set -u

root=$PWD
# bazelisk comes with the pipeline's tools; `pipelinegen record` runs the task
# on your machine, where it is on the PATH
BAZELISK=$root/tools/bazelisk
[ -x "$BAZELISK" ] || BAZELISK=bazelisk
pg=$root/tools/pipelinegen
bazel_root=${GAVEL_BAZEL_ROOT:-$root/cache/bazel}
bz() { (cd "$root/source" && "$BAZELISK" --output_user_root="$bazel_root" "$@"); }

if [ "${GAVEL_DOCKER:-}" = true ]; then
	dockerd >"$root/dockerd.log" 2>&1 &
	for _ in $(seq 60); do docker info >/dev/null 2>&1 && break; sleep 1; done
	docker info >/dev/null 2>&1 || { echo "the Docker daemon did not start" >&2; tail -20 "$root/dockerd.log" >&2; exit 1; }
fi

common=(--jobs="${GAVEL_BAZEL_JOBS:-4}" --noshow_progress --test_output=errors --test_arg=-test.v)
if [ "${PIPELINEGEN_RECORD:-false}" = true ]; then
	verb=coverage
	common+=(--@rules_go//go/config:cover_format=go_cover --instrumentation_filter='^//' --combined_report=none)
else
	verb=test
fi
if [ "${GAVEL_DOCKER:-}" != true ]; then
	# without a daemon the database tests skip, so make sure none is reachable
	common+=(--test_env=DOCKER_HOST=unix:///nonexistent/docker.sock)
fi

"$pg" slice setup-end

# json_string prints its argument as a JSON string.
json_string() {
	printf '"'
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r//g' | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'
	printf '"'
}

"$pg" slice list | while IFS="$(printf '\t')" read -r name label target sources tests; do
	"$pg" slice start "$name"
	mkdir -p "result/$(dirname "$name")" "coverage/$name"
	pkg=$(dirname "$name")
	file=$(basename "$name")
	# the go_test targets whose srcs hold the file (a file can sit in two)
	targets=$(bz query "kind(go_test, rdeps(//$pkg:all, //$pkg:$file, 1))" 2>/dev/null)
	log=result/$name.log
	if [ -z "$targets" ]; then
		printf '{"passed": false, "failures": [{"test": "bazel query", "tail": %s}]}\n' \
			"$(json_string "no go_test target holds $name")" >"result/$name.json"
		"$pg" slice end "$name"
		continue
	fi
	filter="^($(printf '%s' "$tests" | tr ',' '|'))\$"
	# shellcheck disable=SC2086 # one target per word
	bz "$verb" $targets "${common[@]}" --test_filter="$filter" >"$log" 2>&1
	code=$?
	count=0
	for t in $targets; do
		dir=$root/source/bazel-testlogs/${t#//}
		dir=${dir/://}
		# top-level tests only; subtests are indented
		n=$(grep -cE '^--- (PASS|FAIL|SKIP):' "$dir/test.log" 2>/dev/null)
		count=$((count + ${n:-0}))
		if [ -f "$dir/coverage.dat" ]; then
			cp "$dir/coverage.dat" "coverage/$name/$(basename "${dir}").coverprofile"
		fi
	done
	case $code in
	0) printf '{"passed": true, "tests": %d}\n' "$count" >"result/$name.json" ;;
	*)
		failed=$(grep -ho -- '--- FAIL: [^ ]*' "$log" | head -10 | sed 's/--- FAIL: //')
		printf '{"passed": false, "tests": %d, "failures": [{"test": %s, "tail": %s}]}\n' "$count" \
			"$(json_string "${failed:-bazel $verb exited $code}")" "$(json_string "$(tail -15 "$log")")" >"result/$name.json"
		;;
	esac
	"$pg" slice end "$name"
done
