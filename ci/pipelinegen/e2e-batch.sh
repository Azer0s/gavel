#!/usr/bin/env bash
# One batch of the e2e suite: gavel's end-to-end tests, Go files behind the
# build tag e2e that drive the built CLI and server binaries. They have no
# Bazel test target, so the batch builds the binaries with Bazel once and
# runs each file's tests with go test, as the project's run.sh scripts do.
# The server tests start PostgreSQL through testcontainers, so the batch
# starts a Docker daemon first; the CLI tests run Bazel themselves.
set -u

root=$PWD
pg=$root/tools/pipelinegen
bazel_root=$root/cache/bazel
ln -sf "$root/tools/bazelisk" /usr/local/bin/bazel
bz() { (cd "$root/source" && bazel --output_user_root="$bazel_root" "$@"); }

dockerd >"$root/dockerd.log" 2>&1 &
for _ in $(seq 60); do docker info >/dev/null 2>&1 && break; sleep 1; done

bz build //apps/cli/cmd/gavel //apps/server/cmd/gavel-server --jobs=4 --noshow_progress || exit 1
GAVEL_BINARY=$root/source/$(bz cquery //apps/cli/cmd/gavel --output=files 2>/dev/null | tail -1)
GAVEL_SERVER_BINARY=$root/source/$(bz cquery //apps/server/cmd/gavel-server --output=files 2>/dev/null | tail -1)
export GAVEL_BINARY GAVEL_SERVER_BINARY BUILD_WORKSPACE_DIRECTORY=$root/source

"$pg" slice setup-end

"$pg" slice list | while IFS="$(printf '\t')" read -r name label target sources tests; do
	"$pg" slice start "$name"
	mkdir -p "result/$(dirname "$name")"
	filter="^($(printf '%s' "$tests" | tr ',' '|'))\$"
	if (cd source && go test -count=1 -tags e2e -timeout 900s -run "$filter" "./$(dirname "$name")") >"result/$name.log" 2>&1; then
		echo '{"passed": true}' >"result/$name.json"
	else
		echo '{"passed": false, "failures": [{"test": "go test -tags e2e", "tail": "see the batch log"}]}' >"result/$name.json"
	fi
	"$pg" slice end "$name"
done
