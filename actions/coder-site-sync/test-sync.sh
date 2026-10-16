#!/usr/bin/env bash
# Tests for coder-site-sync: input validation, the OIDC token request, and the
# mapping of every response in the trigger contract to an exit code, an
# annotation and the step outputs.
#
# sync.sh runs unmodified against test-stub-server.js, which plays both the
# Actions OIDC endpoint and a Coder site on 127.0.0.1. Production requires
# https, so the script honours CODER_SITE_SYNC_TEST_ALLOW_LOOPBACK_HTTP only
# for a loopback host and only when GITHUB_ACTIONS is not "true"; every run
# here uses `env -i`, so GITHUB_ACTIONS is unset even inside a workflow. Two
# cases below prove the flag is ignored outside those conditions.
#
# A build_failed tail is untrusted text. A small model of the runner's
# command parsing (simulate_runner below) checks that none of the tail's
# lines would be processed as workflow commands.
#
# It also checks that action.yml wires every input to the script and every
# output to the step, and that README.md documents every status the script
# can report.
#
# Usage: bash actions/coder-site-sync/test-sync.sh
# Requires: bash, curl, jq, node, ruby (for YAML parsing). No network beyond
# loopback, no credentials. Exit code is non-zero if any check fails.

set -uo pipefail

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${scriptDir}/sync.sh"
actionYml="${scriptDir}/action.yml"
readme="${scriptDir}/README.md"

failures=0
checks=0
cases=0
fail() { printf '  [FAIL] %s\n' "$1"; failures=$((failures + 1)); checks=$((checks + 1)); }
pass() { checks=$((checks + 1)); [[ -n "${VERBOSE:-}" ]] && printf '  [ OK ] %s\n' "$1"; return 0; }
# check GOT WANT OK_LABEL FAIL_MESSAGE
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$4"; fi; }

for tool in curl jq node ruby; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'test-sync: %s is required\n' "$tool"
    exit 1
  fi
done

work="$(mktemp -d)"
stubPid=""
cleanup() {
  if [[ -n "$stubPid" ]]; then
    kill "$stubPid" 2>/dev/null
    wait "$stubPid" 2>/dev/null
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# Distinctive fake credentials, so a leak is unmistakable in the output.
REQUEST_TOKEN="reqtok-SHOULD-NEVER-APPEAR-7f3a9c"
ID_TOKEN="eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3QifQ.eyJ0ZXN0Ijoic2hvdWxkLW5ldmVyLWFwcGVhciJ9.c2lnLXNob3VsZC1uZXZlci1hcHBlYXI"
COMMIT="$(printf 'a%.0s' {1..40})"
OTHER="$(printf 'b%.0s' {1..40})"
REPO="phase2/example-prototypes"

STUB_REQUEST_TOKEN="$REQUEST_TOKEN" STUB_ID_TOKEN="$ID_TOKEN" \
  node "${scriptDir}/test-stub-server.js" >"${work}/port" 2>"${work}/stub.err" &
stubPid=$!
for _ in $(seq 1 50); do
  [[ -s "${work}/port" ]] && break
  sleep 0.1
done
port="$(head -n1 "${work}/port")"
if [[ -z "$port" ]]; then
  printf 'test-sync: stub server did not start: %s\n' "$(cat "${work}/stub.err")"
  exit 1
fi
stub="http://127.0.0.1:${port}"

# --max-time keeps a hung stub from hanging CI; -q ignores any .curlrc.
stub_ctl() { curl -q -sS --max-time 5 -X POST --data-binary "$2" "${stub}/__${1}" >/dev/null; }
stub_log() { curl -q -sS --max-time 5 "${stub}/__log"; }

# run_sync KEY=VALUE...: runs sync.sh in a clean environment. Defaults give it
# a working OIDC endpoint and the loopback test flag; arguments override them.
run_sync() {
  : >"${work}/output"
  : >"${work}/summary"
  rc=0
  env -i \
    PATH="$PATH" HOME="${HOME:-/tmp}" RUNNER_TEMP="$work" \
    GITHUB_OUTPUT="${work}/output" GITHUB_STEP_SUMMARY="${work}/summary" \
    GITHUB_REPOSITORY="$REPO" \
    ACTIONS_ID_TOKEN_REQUEST_URL="${stub}/oidc?api-version=2.0" \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN="$REQUEST_TOKEN" \
    CODER_SITE_SYNC_TEST_ALLOW_LOOPBACK_HTTP=1 \
    SITE_URL="$stub" EXPECTED_COMMIT="" TIMEOUT_SECONDS=300 \
    "$@" bash "$script" >"${work}/log" 2>&1 || rc=$?
}

output_of() {
  # Last value written for a name, as the runner would read it.
  grep -E "^$1=" "${work}/output" | tail -n1 | cut -d= -f2-
}

# expect NAME EXIT LEVEL STATUS ENABLED COMMIT MESSAGE_SUBSTRING
# Set WANT_ANNOTATIONS beforehand when a run also warns about its input; it
# resets to 1 after each case.
WANT_ANNOTATIONS=1
expect() {
  local name="$1" wantRc="$2" level="$3" status="$4" enabled="$5" commit="$6" msg="$7"
  cases=$((cases + 1))
  printf '== %s\n' "$name"

  if [[ "$rc" == "$wantRc" ]]; then pass "exit $rc"; else fail "$name: exit $rc, want $wantRc"; fi

  local annotations
  annotations="$(grep -cE '^::(error|warning|notice) ' "${work}/log" || true)"
  check "$annotations" "$WANT_ANNOTATIONS" "$WANT_ANNOTATIONS annotation(s)" \
    "$name: $annotations annotations, want $WANT_ANNOTATIONS: $(grep -E '^::(error|warning|notice) ' "${work}/log")"
  WANT_ANNOTATIONS=1
  if grep -qE "^::${level} title=coder-site-sync::" "${work}/log"; then
    pass "level $level"
  else
    fail "$name: no ::${level}:: annotation in: $(grep -E '^::' "${work}/log" | grep -v add-mask)"
  fi
  if grep -E "^::${level} " "${work}/log" | grep -qF -- "$msg"; then
    pass "message has '$msg'"
  else
    fail "$name: annotation lacks '$msg': $(grep -E "^::${level} " "${work}/log")"
  fi

  local got
  for pair in "status=$status" "enabled=$enabled" "commit=$commit"; do
    got="$(output_of "${pair%%=*}")"
    if [[ "$got" == "${pair#*=}" ]]; then pass "$pair"; else fail "$name: ${pair%%=*}='$got', want '${pair#*=}'"; fi
  done
  if [[ "$(wc -l <"${work}/output" | tr -d ' ')" == "3" ]]; then
    pass "three output lines"
  else
    fail "$name: output file is not exactly three lines: $(cat "${work}/output")"
  fi
  if grep -qF "\`${status}\`" "${work}/summary"; then pass "summary"; else fail "$name: summary lacks status: $(cat "${work}/summary")"; fi
  check "$(wc -l <"${work}/summary" | tr -d ' ')" "1" "summary is one line" \
    "$name: summary is not exactly one line: $(cat "${work}/summary")"

  # The ID token may appear only in its own ::add-mask:: line, which the
  # runner consumes rather than prints. The request token may never appear.
  if grep -vF "::add-mask::${ID_TOKEN}" "${work}/log" | grep -qF "$ID_TOKEN" \
     || grep -qF "$ID_TOKEN" "${work}/output" "${work}/summary"; then
    fail "$name: ID token leaked"
  else
    pass "ID token not printed"
  fi
  if grep -qF "$REQUEST_TOKEN" "${work}/log" "${work}/output" "${work}/summary"; then
    fail "$name: request token leaked"
  else
    pass "request token not printed"
  fi
}

# expect_request ORIGIN: the run minted a token for ORIGIN and POSTed exactly
# once to /_hooks/deploy with it, with an empty body, following no redirect.
expect_request() {
  local origin="$1" log
  log="$(stub_log)"
  if grep -qxF "::add-mask::${ID_TOKEN}" "${work}/log"; then
    pass "token masked"
  else
    fail "the OIDC token was never masked"
  fi
  local q
  q="$(jq -r '[.[] | select(.path == "/oidc")] | length' <<<"$log")"
  check "$q" "1" "one OIDC request" "OIDC requests: $q, want 1"
  q="$(jq -r '[.[] | select(.path == "/oidc")][0].query.audience // ""' <<<"$log")"
  check "$q" "$origin" "audience $origin" "audience '$q', want '$origin'"
  q="$(jq -r '[.[] | select(.path == "/oidc")][0].query["api-version"] // ""' <<<"$log")"
  check "$q" "2.0" "api-version kept" "api-version '$q', want 2.0"
  q="$(jq -r '[.[] | select(.path == "/_hooks/deploy")] | length' <<<"$log")"
  check "$q" "1" "one deploy request" "deploy requests: $q, want 1"
  q="$(jq -r '[.[] | select(.path == "/_hooks/deploy")][0] | "\(.method) \(.bodyLength) \(.authorization)"' <<<"$log")"
  check "$q" "POST 0 Bearer ${ID_TOKEN}" "POST with bearer" "deploy request was: ${q/$ID_TOKEN/<id token>}"
  q="$(jq -r '[.[] | select(.path != "/oidc" and .path != "/_hooks/deploy")] | length' <<<"$log")"
  check "$q" "0" "no other requests" "unexpected requests (redirect followed?): $(jq -c '[.[] | .path]' <<<"$log")"
}

expect_no_request() {
  local n
  n="$(stub_log | jq -r '[.[] | select(.path == "/_hooks/deploy")] | length')"
  check "$n" "0" "no deploy request" "a deploy request was made"
}

# ---------------------------------------------------------------------------
printf '#### action.yml wiring and README coverage\n'
cases=$((cases + 1))

# shellcheck disable=SC2016 # Ruby source, expanded by Ruby, not bash.
if wiring="$(ruby -ryaml -e '
  y = YAML.load_file(ARGV[0])
  errors = []
  inputs = y["inputs"] || {}
  outputs = y["outputs"] || {}
  steps = y["runs"]["steps"]
  errors << "not a composite action" unless y["runs"]["using"] == "composite"
  step = steps.find { |s| s["id"] == "sync" }
  if step.nil?
    errors << "no step with id: sync"
  else
    errors << "sync step must use bash" unless step["shell"] == "bash"
    errors << "sync step must run $GITHUB_ACTION_PATH/sync.sh" unless step["run"].to_s.include?("\"$GITHUB_ACTION_PATH/sync.sh\"")
    env = step["env"] || {}
    { "SITE_URL" => "site_url", "EXPECTED_COMMIT" => "expected_commit", "TIMEOUT_SECONDS" => "timeout_seconds" }.each do |var, input|
      errors << "input #{input} missing" unless inputs.key?(input)
      errors << "env #{var} is #{env[var].inspect}, want inputs.#{input}" unless env[var].to_s.gsub(/\s/, "") == "${{inputs.#{input}}}"
    end
    errors << "site_url must be required" unless inputs.dig("site_url", "required") == true
    errors << "timeout_seconds must default to 300 (the 240 s server wait plus margin)" unless inputs.dig("timeout_seconds", "default").to_s == "300"
    errors << "expected_commit must default to github.sha" unless inputs.dig("expected_commit", "default").to_s.gsub(/\s/, "") == "${{github.sha}}"
  end
  %w[enabled commit status].each do |o|
    v = outputs.dig(o, "value").to_s.gsub(/\s/, "")
    errors << "output #{o} is #{v.inspect}" unless v == "${{steps.sync.outputs.#{o}}}"
  end
  File.read(ARGV[0]).scan(/inputs\.([a-z_]+)/).flatten.uniq.each do |i|
    errors << "action.yml references undefined input #{i}" unless inputs.key?(i)
  end
  puts inputs.keys.join(" ")
  puts outputs.keys.join(" ")
  abort errors.join("\n") unless errors.empty?
' "$actionYml" 2>&1)"; then
  pass "action.yml wiring"
else
  fail "action.yml wiring: $wiring"
fi

# Environment names sync.sh reads must be the ones action.yml sets, or the
# runner/test environment. A typo here would silently read an empty input.
# shellcheck disable=SC2016 # Literal characters to delete.
for var in $(grep -oE '\$\{[A-Z_]+:-' "$script" | tr -d '${:-' | sort -u); do
  case "$var" in
    SITE_URL|EXPECTED_COMMIT|TIMEOUT_SECONDS|ACTIONS_ID_TOKEN_REQUEST_URL|ACTIONS_ID_TOKEN_REQUEST_TOKEN|GITHUB_OUTPUT|GITHUB_STEP_SUMMARY|GITHUB_REPOSITORY|GITHUB_SHA|GITHUB_ACTIONS|RUNNER_TEMP|TMPDIR|CODER_SITE_SYNC_TEST_ALLOW_LOOPBACK_HTTP)
      pass "env $var known" ;;
    *) fail "sync.sh reads unexpected env $var" ;;
  esac
done

# Every status word the script can emit must be documented, and every input
# and output name must appear in the action README.
statuses="$(grep -oE 'finish (error|warning|notice) [a-z_]+' "$script" | awk '{print $3}' | sort -u) bad_request method_not_allowed"
for s in $statuses; do
  if grep -qF "\`${s}\`" "$readme"; then pass "README documents $s"; else fail "README does not document status \`${s}\`"; fi
done
for n in $wiring; do
  if grep -qF "\`${n}\`" "$readme"; then pass "README documents $n"; else fail "README does not document \`${n}\`"; fi
done

# ---------------------------------------------------------------------------
printf '#### responses from the trigger contract\n'

# case NAME STUB_CASE EXIT LEVEL STATUS ENABLED COMMIT MESSAGE [EXPECTED_COMMIT]
response_case() {
  local name="$1" stubCase="$2" wantRc="$3" level="$4" status="$5" enabled="$6" commit="$7" msg="$8" expected="${9:-}"
  stub_ctl oidc ok
  stub_ctl case "$stubCase"
  stub_log >/dev/null
  run_sync EXPECTED_COMMIT="$expected"
  expect "$name" "$wantRc" "$level" "$status" "$enabled" "$commit" "$msg"
  expect_request "$stub"
}

response_case "200 matching commit" synced 0 notice synced true "$COMMIT" "as expected" "$COMMIT"
response_case "200 matching commit, expected given in uppercase" synced 0 notice synced true "$COMMIT" "as expected" "$(tr a-f A-F <<<"$COMMIT")"
response_case "200 uppercase commit from server" synced_upper 0 notice synced true "$COMMIT" "as expected" "$COMMIT"
response_case "200, no expected commit" synced 0 notice synced true "$COMMIT" "serves ${COMMIT}"
response_case "200 mismatching commit warns" mismatch 0 warning commit_mismatch true "$OTHER" "serves ${OTHER}, not ${COMMIT} (expected_commit)" "$COMMIT"
for cause in "a newer push landed" "a branch other than the site's git_branch" "a pull_request merge commit"; do
  if grep -E '^::warning ' "${work}/log" | grep -qF "$cause"; then pass "names: $cause"; else fail "commit_mismatch does not name: $cause"; fi
done
response_case "200 without a valid commit" synced_bad_commit 1 error invalid_response true "" "no valid commit" "$COMMIT"
response_case "202 still syncing" syncing 0 warning syncing true "" "still syncing" "$COMMIT"
response_case "JSON 400 bad_request" bad_request 1 error bad_request true "" "bad_request"
response_case "JSON 401 invalid_token" invalid_token 1 error invalid_token true "" "invalid_token"
response_case "JSON 403 wrong_audience" wrong_audience 1 error wrong_audience true "" "wrong_audience"
response_case "JSON 403 wrong_repository" wrong_repository 1 error wrong_repository true "" "points at ${REPO}"
response_case "JSON 404 not_enabled" not_enabled 1 error not_enabled false "" "then restart or rebuild the workspace"
response_case "JSON 405 method_not_allowed" method_not_allowed 1 error method_not_allowed true "" "method_not_allowed"
response_case "JSON 500 sync_failed" sync_failed 1 error sync_failed true "" "couldn't find remote ref prototypes-site 100%25"
response_case "JSON 503 jwks_unavailable" jwks_unavailable 1 error jwks_unavailable true "" "jwks_unavailable"
response_case "non-JSON 302 redirect" redirect_302 0 warning not_ci_enabled false "" "Site not CI-enabled yet"
response_case "non-JSON 302 to another host" redirect_302_cross_host 0 warning not_ci_enabled false "" "HTTP 302"
response_case "non-JSON 401 HTML" auth_401_html 0 warning not_ci_enabled false "" "HTTP 401"
response_case "non-JSON 403 HTML" auth_403_html 0 warning not_ci_enabled false "" "HTTP 403"
response_case "non-JSON 404 nginx" nginx_404_html 0 warning not_ci_enabled false "" "HTTP 404"
response_case "non-JSON 405 nginx" nginx_405_html 0 warning not_ci_enabled false "" "HTTP 405"
response_case "non-JSON 200 HTML" html_200 0 warning not_ci_enabled false "" "HTTP 200"
response_case "non-JSON 502 gateway" gateway_502 1 error site_unavailable "" "" "sync trigger is down or timed out"
response_case "non-JSON 503 gateway" gateway_503 1 error site_unavailable "" "" "sync trigger is down or timed out"
response_case "non-JSON 504 gateway" gateway_504 1 error site_unavailable "" "" "sync trigger is down or timed out"
response_case "foreign JSON 404" foreign_json_404 0 warning not_ci_enabled false "" "HTTP 404"
response_case "our error word on the wrong code" wrong_code_json 0 warning not_ci_enabled false "" "HTTP 500"
response_case "gateway 503 speaking JSON" gateway_503_json 1 error site_unavailable "" "" "Sync Log app (restarting the workspace"
response_case "JSON array body" json_array 0 warning not_ci_enabled false "" "HTTP 200"
response_case "truncated JSON body" json_broken 0 warning not_ci_enabled false "" "HTTP 200"

# A detail with newlines must not become extra workflow commands.
response_case "sync_failed detail cannot inject commands" sync_failed_inject 1 error sync_failed true "" "line one%0A::error::injected%0D%0A::add-mask::x"
if grep -qE '^::(error|add-mask)::(injected|x)' "${work}/log"; then fail "detail injected a workflow command"; else pass "no injected command"; fi
if grep -qE '^::' "${work}/summary"; then fail "detail put a raw line in the summary"; else pass "summary has no raw lines"; fi

# Markdown and HTML in a detail render literally in the job summary.
response_case "sync_failed detail is escaped in the summary" sync_failed_markdown 1 error sync_failed true "" "<img src=x onerror=alert(1)>"
# shellcheck disable=SC2016 # Literal backticks expected in the summary.
for want in '&lt;img src=x onerror=alert\(1\)&gt;' '\*\*bold\*\*' '\[link\]\(https://evil.example\)' '\`code\`'; do
  if grep -qF -- "$want" "${work}/summary"; then pass "summary has $want"; else fail "summary lacks $want: $(cat "${work}/summary")"; fi
done
if grep -qF '<img' "${work}/summary"; then fail "summary has a raw <img> tag"; else pass "no raw HTML in the summary"; fi

# A .curlrc on the runner must not change the request. First prove this
# .curlrc would follow the redirect for a plain curl call, so the case below
# is not vacuous, then run the action with it in HOME.
mkdir -p "${work}/curlhome"
printf 'location\nverbose\n' >"${work}/curlhome/.curlrc"
stub_ctl case redirect_302_cross_host
redirects="$(env -i PATH="$PATH" HOME="${work}/curlhome" curl -sS -o /dev/null -X POST \
  --max-time 5 -w '%{num_redirects}' "${stub}/_hooks/deploy" 2>/dev/null)"
check "$redirects" "1" ".curlrc in the test HOME takes effect for plain curl" \
  ".curlrc in the test HOME was not honoured (redirects: '$redirects'); the next case proves nothing"
stub_log >/dev/null
run_sync HOME="${work}/curlhome"
expect "a .curlrc with location and verbose is ignored" 0 warning not_ci_enabled false "" "HTTP 302"
expect_request "$stub"
if grep -qiE '^> |authorization' "${work}/log"; then fail ".curlrc verbose output reached the log"; else pass "no verbose output"; fi

# Site URL normalisation: uppercase host and a trailing slash give the
# lowercase origin as the audience.
stub_ctl case synced; stub_log >/dev/null
run_sync SITE_URL="  HTTP://LOCALHOST:${port}/ "
expect "uppercase URL with trailing slash" 0 notice synced true "$COMMIT" "serves ${COMMIT}"
expect_request "http://localhost:${port}"

# timeout_seconds below 255 warns but still runs; 255 does not warn (the
# default-run cases above pass 300). An empty value means the default, 300.
stub_ctl case synced; stub_log >/dev/null
run_sync TIMEOUT_SECONDS=254
WANT_ANNOTATIONS=2
expect "timeout_seconds 254 warns" 0 notice synced true "$COMMIT" "serves ${COMMIT}"
if grep -E '^::warning ' "${work}/log" | grep -qF "timeout_seconds is 254"; then pass "warned for 254"; else fail "no warning for timeout_seconds=254"; fi
stub_log >/dev/null
run_sync TIMEOUT_SECONDS=255
expect "timeout_seconds 255 does not warn" 0 notice synced true "$COMMIT" "serves ${COMMIT}"
stub_log >/dev/null
run_sync TIMEOUT_SECONDS=
expect "empty timeout_seconds means 300" 0 notice synced true "$COMMIT" "serves ${COMMIT}"
if grep -qF "waiting up to 300s" "${work}/log"; then pass "default 300"; else fail "default timeout is not 300: $(grep waiting "${work}/log")"; fi
stub_log >/dev/null

# ---------------------------------------------------------------------------
printf '#### expected commit defaults to GITHUB_SHA\n'

stub_ctl case synced; stub_log >/dev/null
run_sync GITHUB_SHA="$COMMIT"
expect "empty input, GITHUB_SHA matches" 0 notice synced true "$COMMIT" "as expected"
expect_request "$stub"

stub_ctl case synced; stub_log >/dev/null
run_sync GITHUB_SHA="$OTHER"
expect "empty input, GITHUB_SHA differs" 0 warning commit_mismatch true "$COMMIT" "not ${OTHER} (expected_commit, default github.sha)"
expect_request "$stub"

# action.yml's default arrives as an input equal to GITHUB_SHA.
stub_ctl case synced; stub_log >/dev/null
run_sync GITHUB_SHA="$OTHER" EXPECTED_COMMIT="$OTHER"
expect "defaulted input equal to GITHUB_SHA differs" 0 warning commit_mismatch true "$COMMIT" "not ${OTHER} (expected_commit, default github.sha)"
expect_request "$stub"

stub_ctl case synced; stub_log >/dev/null
run_sync GITHUB_SHA="$OTHER" EXPECTED_COMMIT="$COMMIT"
expect "input overrides GITHUB_SHA" 0 notice synced true "$COMMIT" "as expected"
expect_request "$stub"

stub_log >/dev/null
run_sync GITHUB_SHA="not-a-sha"
expect "malformed GITHUB_SHA" 1 error invalid_input "" "" "GITHUB_SHA must be a full 40-character commit SHA"
n="$(stub_log | jq 'length')"
check "$n" "0" "no requests" "malformed GITHUB_SHA: $n requests made"

# ---------------------------------------------------------------------------
printf '#### build_failed log tail is untrusted\n'

# A model of how the runner treats each output line: after trimming leading
# whitespace, a line starting with "::" is a command, and "##[" anywhere is a
# legacy command, unless ::stop-commands::<token> is in force, in which case
# only "::<token>::" is recognised (and resumes). Prints the commands that
# would be processed, one per line.
simulate_runner() {
  awk '
    { line = $0; sub(/^[ \t]+/, "", line) }
    stopped { if (line == "::" tok "::") { stopped = 0; print "resume" } next }
    line ~ /^::[A-Za-z-]+/ {
      cmd = line; sub(/^::/, "", cmd); sub(/[ :].*/, "", cmd); print cmd
      if (cmd == "stop-commands") { tok = line; sub(/^::stop-commands::/, "", tok); stopped = 1 }
      next
    }
    index(line, "##[") { print "legacy" }
  ' "$1"
}

stub_ctl case build_failed; stub_log >/dev/null
run_sync EXPECTED_COMMIT="$COMMIT"
expect "JSON 500 build_failed" 1 error build_failed true "" "Last log line: exit code 1 done"
if grep -E '^::error ' "${work}/log" | grep -qF "workspace's Build Log app"; then pass "points at Build Log"; else fail "build_failed does not point at the Build Log app"; fi
expect_request "$stub"
processed="$(simulate_runner "${work}/log" | tr '\n' ' ')"
check "$processed" "add-mask group stop-commands resume endgroup error " \
  "only the action's own commands are processed" \
  "processed commands are '${processed}', want the action's own six only"
# The second guard on its own: with no stop-commands in force, the tail
# lines still contain nothing the runner would process.
# (No {32} interval: mawk, Debian's default awk, does not support it.)
tail_block="$(awk '/^::stop-commands::/ { on = 1; next } /^::[0-9a-f]+::$/ { on = 0 } on' "${work}/log")"
check "$(grep -vc '^| ' <<<"$tail_block")" "0" "every tail line is prefixed" \
  "unprefixed tail lines: $(grep -v '^| ' <<<"$tail_block")"
printf '%s\n' "$tail_block" >"${work}/tail"
check "$(simulate_runner "${work}/tail" | tr '\n' ' ')" "" "tail is inert without stop-commands" \
  "tail lines would be processed without stop-commands: $(simulate_runner "${work}/tail" | tr '\n' ' ')"
for want in '| ::error::injected-from-build' '| ::add-mask::build-secret' '| ::stop-commands::fake-token' \
            '| ::warning::after-fake-stop' '| ## [error]legacy-command' '| Error: Cannot find module vite'; do
  if grep -qxF -- "$want" <<<"$tail_block"; then pass "tail shows $want"; else fail "tail lacks line '$want': $tail_block"; fi
done
if grep -q $'\x1b' "${work}/log" "${work}/summary"; then fail "ANSI escape reached the log"; else pass "no ANSI escapes"; fi
if grep -q $'\r' "${work}/log" "${work}/summary"; then fail "carriage return reached the log"; else pass "no carriage returns"; fi
if grep -qE '^::group::Build log tail' "${work}/log" && grep -qx '::endgroup::' "${work}/log"; then
  pass "tail is in a log group"
else
  fail "tail is not in a ::group::"
fi
if grep -qF 'injected-from-build' "${work}/summary"; then fail "summary carries the tail"; else pass "summary mentions only"; fi
tok1="$(grep -m1 '^::stop-commands::' "${work}/log")"

stub_ctl case build_failed; stub_log >/dev/null
run_sync
expect "build_failed again, fresh token" 1 error build_failed true "" "the site still serves its previous version"
tok2="$(grep -m1 '^::stop-commands::' "${work}/log")"
if [[ -n "$tok1" && "$tok1" != "$tok2" && "$tok1" =~ ^::stop-commands::[0-9a-f]{32}$ ]]; then
  pass "stop-commands token is 128 random bits, fresh per run"
else
  fail "stop-commands tokens: '$tok1' then '$tok2'"
fi

stub_ctl case build_failed_empty; stub_log >/dev/null
run_sync
expect "build_failed with an empty tail" 1 error build_failed true "" "Last log line: (none)"
stub_log >/dev/null

# ---------------------------------------------------------------------------
printf '#### transport failures\n'

stub_ctl case slow; stub_log >/dev/null
run_sync TIMEOUT_SECONDS=1
WANT_ANNOTATIONS=2
expect "request times out" 1 error timeout "" "" "No answer from"
if grep -E '^::warning ' "${work}/log" | grep -qF "below 255"; then pass "short timeout warned"; else fail "no warning for timeout_seconds=1"; fi

run_sync SITE_URL="http://127.0.0.1:1"
expect "connection refused" 1 error unreachable "" "" "Could not reach"
stub_log >/dev/null

# ---------------------------------------------------------------------------
printf '#### OIDC token\n'

run_sync ACTIONS_ID_TOKEN_REQUEST_URL="" ACTIONS_ID_TOKEN_REQUEST_TOKEN=""
expect "id-token env vars missing" 1 error no_oidc_token "" "" "permissions: id-token: write"
expect_no_request

run_sync ACTIONS_ID_TOKEN_REQUEST_TOKEN=""
expect "only the request URL set" 1 error no_oidc_token "" "" "permissions: id-token: write"
expect_no_request

stub_ctl oidc error
run_sync
expect "OIDC endpoint fails" 1 error no_oidc_token "" "" "HTTP 500"
expect_no_request

stub_ctl oidc notjwt
run_sync
expect "OIDC endpoint returns a non-JWT" 1 error no_oidc_token "" "" "not a JWT"
expect_no_request
stub_ctl oidc ok

run_sync ACTIONS_ID_TOKEN_REQUEST_TOKEN="wrong-request-token"
expect "runtime rejects the request token" 1 error no_oidc_token "" "" "HTTP 401"
expect_no_request

# ---------------------------------------------------------------------------
printf '#### missing tools\n'

# A PATH with everything sync.sh runs except one tool.
shim_path() {
  local dir="${work}/bin-no-$1" t
  mkdir -p "$dir"
  for t in bash mktemp rm tr sed head awk od curl jq; do
    [[ "$t" == "$1" ]] && continue
    ln -sf "$(command -v "$t")" "${dir}/${t}"
  done
  printf '%s' "$dir"
}
for tool in curl jq awk od; do
  stub_log >/dev/null
  run_sync PATH="$(shim_path "$tool")"
  expect "$tool missing" 1 error missing_tool "" "" "${tool} is not installed"
  n="$(stub_log | jq 'length')"
  check "$n" "0" "no requests" "$tool missing: $n requests made"
done

# ---------------------------------------------------------------------------
printf '#### input validation (nothing is requested)\n'

invalid_case() {
  local name="$1" msg="$2"; shift 2
  stub_log >/dev/null
  run_sync "$@"
  expect "$name" 1 error invalid_input "" "" "$msg"
  local n
  n="$(stub_log | jq 'length')"
  check "$n" "0" "no requests" "$name: $n requests made"
}

invalid_case "empty site_url" "site_url is required" SITE_URL="  "
invalid_case "http site_url" "must use https://" SITE_URL="http://example.cloud.phase2.ai"
invalid_case "no scheme" "must start with https://" SITE_URL="example.cloud.phase2.ai"
invalid_case "site_url with a path" "no path" SITE_URL="https://example.cloud.phase2.ai/docs/"
invalid_case "site_url with a query" "no path, query" SITE_URL="https://example.cloud.phase2.ai?x=1"
invalid_case "site_url with a port" "must not include a port" SITE_URL="https://example.cloud.phase2.ai:8443"
invalid_case "site_url with credentials" "must not contain credentials" SITE_URL="https://user@example.cloud.phase2.ai"
invalid_case "site_url with a bad host" "invalid host" SITE_URL="https://exa_mple.cloud.phase2.ai"
invalid_case "short expected_commit" "full 40-character" EXPECTED_COMMIT="abc1234"
invalid_case "zero timeout" "timeout_seconds" TIMEOUT_SECONDS=0
invalid_case "non-numeric timeout" "timeout_seconds" TIMEOUT_SECONDS=abc
invalid_case "test flag ignored when GITHUB_ACTIONS=true" "must use https://" GITHUB_ACTIONS=true
invalid_case "test flag ignored for a non-loopback host" "must use https://" SITE_URL="http://example.cloud.phase2.ai"
invalid_case "loopback over http without the flag" "must use https://" CODER_SITE_SYNC_TEST_ALLOW_LOOPBACK_HTTP=

# A valid production URL passes validation and stops at the token step, which
# shows normalisation accepts it (no network is used).
run_sync SITE_URL="HTTPS://Example.Cloud.Phase2.AI/" ACTIONS_ID_TOKEN_REQUEST_URL=""
expect "valid https URL reaches the token step" 1 error no_oidc_token "" "" "id-token: write"

printf '\n'
if [[ "$cases" -lt 60 ]]; then
  printf 'test-sync: only %d cases ran; the harness is broken.\n' "$cases"
  exit 1
fi
if [[ "$failures" -ne 0 ]]; then
  printf 'test-sync: %d of %d checks failed across %d cases.\n' "$failures" "$checks" "$cases"
  exit 1
fi
printf 'test-sync: all %d checks passed across %d cases.\n' "$checks" "$cases"
