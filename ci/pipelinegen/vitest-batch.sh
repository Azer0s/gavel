#!/usr/bin/env bash
# One batch of the vitest suite: each slice is one test file of the web app,
# run by vitest on its own. The npm packages come from Bazel's install of
# apps/web/pnpm-lock.yaml (rules_js), as the build's do.
set -u
root=$PWD
pg=$root/tools/pipelinegen
tree=$(cd source && pwd -P)
(cd "$tree" && "$root/tools/bazelisk" --output_user_root="${GAVEL_BAZEL_ROOT:-$root/cache/bazel}" \
	build //apps/web:node_modules --jobs=4 --noshow_progress) || exit 1
[ -e "$tree/apps/web/node_modules" ] || ln -s "$tree/bazel-bin/apps/web/node_modules" "$tree/apps/web/node_modules"
"$pg" slice setup-end
"$pg" slice list | while IFS="$(printf '\t')" read -r name label target sources tests; do
	"$pg" slice start "$name"
	mkdir -p "result/$(dirname "$name")"
	if (cd "$tree/apps/web" && node node_modules/vitest/vitest.mjs run "${name#apps/web/}") >"result/$name.log" 2>&1; then
		echo '{"passed": true}' >"result/$name.json"
	else
		echo '{"passed": false, "failures": [{"test": "vitest", "tail": "see the batch log"}]}' >"result/$name.json"
	fi
	"$pg" slice end "$name"
done
