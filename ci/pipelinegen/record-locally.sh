#!/usr/bin/env bash
# Makes the first recordings of a commit on your own machine, the way the
# pipeline's nightly run makes them: plan every slice, deal the batches, run
# each batch's script, and attach what each slice ran to the commit.
#
#   ci/pipelinegen/record-locally.sh <work dir> <commit> <suite>...
#
# The work dir needs:
#   tools/pipelinegen, tools/bazelisk     the tool and bazelisk
#   tools/plugins/<name>                  each plugin of pipelinegen.yaml
#   remote/<owner>/<name>.git             a bare clone of this repository,
#                                         standing in for its remote
#   stub                                  a stand-in for GitHub's API that
#                                         accepts every request (pipelinegen's
#                                         ci/proof/stub.go, built)
# Every write goes to the bare clone and the stand-in, never to GitHub.
# Afterwards `git fetch <work dir>/remote/<owner>/<name>.git
# 'refs/pipelinegen/*:refs/pipelinegen/*'` brings the lists into your clone.
set -u
work=$(cd "$1" && pwd); commit=$2; shift 2
repo=$(sed -n 's/^  repository: *//p' pipelinegen.yaml | head -1)

"$work/stub" "$work/stub.port" >"$work/stub.log" 2>&1 &
stub=$!
trap 'kill $stub 2>/dev/null' EXIT
for _ in $(seq 100); do [ -s "$work/stub.port" ] && break; sleep 0.1; done

export PIPELINEGEN_GIT_URL=file://$work/remote
export PIPELINEGEN_GITHUB_API=http://127.0.0.1:$(cat "$work/stub.port")
export GITHUB_TOKEN=stand-in
export PIPELINEGEN_CONCOURSE_URL=http://ci.invalid

run=$work/run-$commit
rm -rf "$run"; mkdir -p "$run"
git clone -q "$work/remote/$repo.git" "$run/source"
git -C "$run/source" checkout -q "$commit"
cp -r "$work/tools" "$run/tools"
cd "$run" || exit 1
export PIPELINEGEN_RUN=nightly PIPELINEGEN_CHANGE=$(git -C source rev-parse --abbrev-ref HEAD) PIPELINEGEN_COMMIT=$(git -C source rev-parse HEAD) PIPELINEGEN_PR=0
tools/pipelinegen plan --run nightly --trigger source --cache "$work/cache" || exit 1
for suite in "$@"; do
	export PIPELINEGEN_SUITE=$suite PIPELINEGEN_RECORD=true
	tools/pipelinegen batches --run nightly --suite "$suite" --trigger source --root source --out "batches-$suite" || exit 1
	for b in "batches-$suite"/*/; do
		n=$(basename "$b")
		d=$run/batch-$suite-$n
		mkdir -p "$d"
		cp -a "batches-$suite" "$d/batches"; cp -a tools "$d/tools"; ln -s "$run/source" "$d/source"
		# the suite's run_slice task file, and the script of the same name
		task=$(awk -v s="  $suite:" '$0 == s {in_s = 1; next} in_s && /^  [^ ]/ {in_s = 0} in_s && $1 == "run_slice:" {print $2; exit}' source/pipelinegen.yaml)
		script=source/${task%.yml}.sh
		case $task in *go-db-batch.yml) script=source/ci/pipelinegen/go-batch.sh ;; esac
		(cd "$d" && PIPELINEGEN_BATCH=$n GAVEL_BAZEL_ROOT=$work/bazel bash "$script" >batch.log 2>&1
			PIPELINEGEN_BATCH=$n tools/pipelinegen slice flush
			PIPELINEGEN_BATCH=$n tools/pipelinegen report batch-end --root source)
	done
	tools/pipelinegen report suite --root source
done
tools/pipelinegen lists attach --run nightly --change "$PIPELINEGEN_CHANGE" --commit "$PIPELINEGEN_COMMIT" --to "$PIPELINEGEN_COMMIT" --root source
tools/pipelinegen lists show --commit "$PIPELINEGEN_COMMIT" --root source
