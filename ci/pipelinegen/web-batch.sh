#!/usr/bin/env bash
# One batch of the web suite: each slice is a tagged filegroup whose
# pipelinegen-run tag names the Bazel test target that runs it (the web
# app's type check and lint, which the web_project macro generates).
set -u

root=$PWD
# bazelisk comes with the pipeline's tools; `pipelinegen record` runs the task
# on your machine, where it is on the PATH
BAZELISK=$root/tools/bazelisk
[ -x "$BAZELISK" ] || BAZELISK=bazelisk
pg=$root/tools/pipelinegen
bz() { (cd "$root/source" && "$BAZELISK" --output_user_root="${GAVEL_BAZEL_ROOT:-$root/cache/bazel}" "$@"); }

"$pg" slice setup-end

"$pg" slice list | while IFS="$(printf '\t')" read -r name label target sources tests; do
	"$pg" slice start "$name"
	mkdir -p "result/$(dirname "$name")"
	if bz test "$target" --jobs=4 --noshow_progress --test_output=errors >"result/$name.log" 2>&1; then
		echo '{"passed": true, "tests": 1}' >"result/$name.json"
	else
		echo '{"passed": false, "tests": 1, "failures": [{"test": "bazel test", "tail": "see the batch log"}]}' >"result/$name.json"
	fi
	"$pg" slice end "$name"
done
