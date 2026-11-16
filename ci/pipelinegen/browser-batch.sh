#!/usr/bin/env bash
# One batch of the browser suite: gavel's Playwright specs (apps/web/e2e)
# against the real server and PostgreSQL.
#
# Setup, once per batch: a PostgreSQL container, the web app built by Bazel,
# and the server built with Go's coverage (go build -cover), so that the
# server writes which Go code each spec reached. Then, per spec file: start
# the server with its own GOCOVERDIR in the spec's coverage directory, run
# the spec, stop the server (it writes its counters on exit), end the slice.
# In a recording run, apps/web/e2e/recording.ts adds react-correlator's
# fixture and the request log.
#
# Inputs: source, batches, tools (tools/react-correlator/playwright.mjs in a
# recording run). Outputs: result, coverage.
set -u

root=$PWD
# bazelisk comes with the pipeline's tools; `pipelinegen record` runs the task
# on your machine, where it is on the PATH
BAZELISK=$root/tools/bazelisk
[ -x "$BAZELISK" ] || BAZELISK=bazelisk
pg=$root/tools/pipelinegen
tree=$(cd source && pwd -P)
pg_port=${GAVEL_PG_PORT:-5433}
port=${E2E_SERVER_PORT:-3333}
container=gavel-e2e-postgres
export PATH=$tree/ci/pipelinegen/bin:$PATH E2E_SERVER_PORT=$port
bz() { (cd "$tree" && "$BAZELISK" --output_user_root="${GAVEL_BAZEL_ROOT:-$root/cache/bazel}" "$@"); }
mkdir -p result coverage

# PostgreSQL, as gavel's start-server.sh starts it, on the batch's port
docker rm -f "$container" >/dev/null 2>&1
docker run -d --name "$container" -e POSTGRES_USER=gavel -e POSTGRES_PASSWORD=gavel -e POSTGRES_DB=gaveltest \
	-p "127.0.0.1:$pg_port:5432" postgres:16-alpine >/dev/null || exit 1
trap 'docker rm -f "$container" >/dev/null 2>&1' EXIT
for _ in $(seq 60); do docker exec "$container" pg_isready -U gavel >/dev/null 2>&1 && break; sleep 1; done

# The web app: Bazel builds it (bundle and styles); in a recording run the
# bundle is built again with esbuild and the same settings as gavel's
# web_project macro, into apps/web/dist in the tree, because the macro's
# source map leaves out the sources' text, which react-correlator reads.
# The server finds the app through a runfiles directory, as under Bazel.
# The npm packages (Playwright, esbuild) come from Bazel's own install of
# apps/web/pnpm-lock.yaml, the one rules_js made for the build.
bz build //apps/web //apps/web:node_modules --jobs=4 --noshow_progress || exit 1
[ -e "$tree/apps/web/node_modules" ] || ln -s "$tree/bazel-bin/apps/web/node_modules" "$tree/apps/web/node_modules"
nm=$tree/apps/web/node_modules
dist=$tree/bazel-bin/apps/web/dist
if [ "${PIPELINEGEN_RECORD:-false}" = true ]; then
	dist=$tree/apps/web/dist
	rm -rf "$dist"; mkdir -p "$dist"
	cp "$tree/bazel-bin/apps/web/dist/index.html" "$tree/bazel-bin/apps/web/dist/styles.css" "$dist/"
	(cd "$tree/apps/web" && "$nm/esbuild/bin/esbuild" src/main.tsx --bundle --minify --sourcemap \
		--target=es2020 --platform=browser --jsx=automatic --loader:.css=empty \
		--define:import.meta.env.DEV=false --tsconfig=tsconfig.app.json --outfile=dist/bundle.js) || exit 1
fi
mkdir -p "$root/runfiles/_main/apps/web"
ln -sfn "$dist" "$root/runfiles/_main/apps/web/dist"

# the server, with Go's coverage in a recording run
cover=()
[ "${PIPELINEGEN_RECORD:-false}" = true ] && cover=(-cover -covermode=atomic -coverpkg=github.com/usegavel/gavel/...)
(cd "$tree" && go build "${cover[@]}" -o "$root/gavel-server" ./apps/server/cmd/gavel-server) || exit 1

serve() {
	GAVEL_DATABASE_URL="postgres://gavel:gavel@localhost:$pg_port/gaveltest?sslmode=disable" \
		GAVEL_ADDR="127.0.0.1:$port" GAVEL_DATA_DIR=$1 GAVEL_SECURE_COOKIES=false GAVEL_ADMIN_PASSWORD=changeme \
		RUNFILES_DIR=$root/runfiles exec "$root/gavel-server" serve
}
up() { for _ in $(seq 60); do curl -fs "http://127.0.0.1:$port/healthz" >/dev/null && return 0; sleep 1; done; return 1; }

data=$(mktemp -d "$root/data.XXXX")

# react-correlator's Playwright fixture, which a recording run's specs load.
# The pipeline fetches the plugins, not this companion file, so the batch
# fetches it from the plugin's release (pinned by REACT_FIXTURE_VERSION and
# REACT_FIXTURE_SHA256) unless REACT_CORRELATOR_FIXTURE names one already.
fixture=${REACT_CORRELATOR_FIXTURE:-$root/tools/react-correlator/playwright.mjs}
if [ "${PIPELINEGEN_RECORD:-false}" = true ] && [ ! -f "$fixture" ]; then
	[ -n "${GITHUB_TOKEN:-}" ] || { echo "a recording run needs react-correlator's playwright.mjs: set REACT_CORRELATOR_FIXTURE or give the batch GITHUB_TOKEN" >&2; exit 1; }
	mkdir -p "$(dirname "$fixture")"
	url=$(curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" \
		"https://api.github.com/repos/sideways-works/pipelinegen-correlator-react/releases/tags/$REACT_FIXTURE_VERSION" |
		node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const a=JSON.parse(s).assets.find(a=>a.name==="playwright.mjs");console.log(a?a.url:"")})')
	curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/octet-stream" -o "$fixture" "$url" || exit 1
	echo "$REACT_FIXTURE_SHA256  $fixture" | sha256sum -c - || exit 1
fi

"$pg" slice setup-end

"$pg" slice list | while IFS="$(printf '\t')" read -r name label target sources tests; do
	"$pg" slice start "$name"
	mkdir -p "result/$(dirname "$name")" "coverage/$name/gocoverdir"
	# each spec starts from an empty database, as on a first run: the server
	# migrates it and creates its first admin, and the spec's setup seeds it
	docker exec "$container" psql -q -U gavel -d gaveltest -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public" >/dev/null || exit 1
	GOCOVERDIR=$root/coverage/$name/gocoverdir serve "$data" >"result/$name.server.log" 2>&1 &
	server=$!
	up
	(cd "$tree/apps/web" && PIPELINEGEN_COVERAGE=$root/coverage PIPELINEGEN_TREE=$tree \
		REACT_CORRELATOR_FIXTURE=$fixture PLAYWRIGHT_JSON=$root/result/$name.playwright.json \
		node "$nm/@playwright/test/cli.js" test -c playwright.pipelinegen.config.ts "${name#apps/web/}") >"result/$name.log" 2>&1
	code=$?
	kill -TERM "$server"; wait "$server"
	n=$(grep -cE '^ +[✓✘-] ' "result/$name.log")
	if [ $code = 0 ]; then
		printf '{"passed": true, "tests": %d}\n' "${n:-0}" >"result/$name.json"
	else
		printf '{"passed": false, "tests": %d, "failures": [{"test": "playwright", "tail": "see the batch log"}]}\n' "${n:-0}" >"result/$name.json"
	fi
	"$pg" slice end "$name"
done
