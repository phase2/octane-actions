#!/usr/bin/env bash
# Ask a Coder static-site workspace to sync (fetch, and build if it has a
# build_command) its source branch, authenticated by a GitHub Actions OIDC
# token, and report what the site now serves.
#
# The site's trigger route (POST /_hooks/deploy) verifies the token's
# signature, issuer, times, audience (its own origin) and repository (the
# GitHub repository in its git_repo parameter, when its ci_trigger parameter
# is on), runs its sync, and answers with the source commit it serves.
# Nothing secret is stored anywhere: the token is minted for this job, bound
# to this site's origin, and expires within minutes.
#
# Inputs arrive as environment variables set by action.yml:
#   SITE_URL         Site URL, https://<host> with an optional trailing slash.
#   EXPECTED_COMMIT  Source commit the workflow ran on. Empty means
#                    $GITHUB_SHA, which the runner sets for every step.
#   TIMEOUT_SECONDS  Overall time limit for the sync request.
# The runner provides ACTIONS_ID_TOKEN_REQUEST_URL and
# ACTIONS_ID_TOKEN_REQUEST_TOKEN when the job has `id-token: write`.
#
# Outputs (written to $GITHUB_OUTPUT):
#   enabled  true when the site's sync trigger answered, false when it is
#            absent or not enabled, empty when the site was never asked.
#   commit   The commit the site serves, when it said so.
#   status   One word describing the outcome; see README.md.
#
# The response contract this implements is shared with the static-site
# handler in phase2/phase2-coder-prototyping. Change both together.

set -euo pipefail

# Every curl call starts with -q, which must be its first argument, so that a
# .curlrc on the runner cannot add --location (following a redirect with the
# token), --verbose (printing headers) or anything else to these requests.
#
# Tokens never pass through argv (visible in `ps` on shared runners) or
# through any echo other than ::add-mask::. Request headers are fed to curl
# on stdin, and nothing here prints them.

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/coder-site-sync.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# --- reporting helpers ------------------------------------------------------

# Workflow commands end at a newline, so any text that came from elsewhere
# (the server's `detail`, curl's error text) is escaped before it is placed
# in an annotation. Without this a crafted value could start a new line and
# issue its own workflow command.
escape_data() {
  local s="$1"
  s="${s//'%'/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  printf '%s' "$s"
}

# Every value written here is drawn from a fixed set, or validated as hex
# first, so it cannot carry a newline into $GITHUB_OUTPUT.
set_output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  fi
}

# The job summary is Markdown, rendered on the run page, and the message can
# carry text from elsewhere (the server's `detail`, curl's error, the inputs).
# Control characters, newlines included, collapse to single spaces so the
# entry stays one line, and HTML and Markdown syntax is escaped so that text
# shows literally instead of rendering as links, images or formatting.
summary_text() {
  printf '%s' "$1" \
    | LC_ALL=C tr '\000-\037\177' ' ' \
    | tr -s ' ' \
    | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
          -e 's/[][\\`*_{}()#+!|~]/\\&/g'
}

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$1" >>"$GITHUB_STEP_SUMMARY"
  fi
}

# finish <level> <status> <enabled> <commit> <message>
# Prints one annotation, records the outputs and a summary line, and exits
# non-zero only for `error`.
finish() {
  local level="$1" status="$2" enabled="$3" commit="$4" message="$5"
  printf '::%s title=coder-site-sync::%s\n' "$level" "$(escape_data "$message")"
  set_output status "$status"
  set_output enabled "$enabled"
  set_output commit "$commit"
  summary "**coder-site-sync** \`${status}\`: $(summary_text "$message")"
  if [[ "$level" == "error" ]]; then
    exit 1
  fi
  exit 0
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_commit() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

# --- tools ------------------------------------------------------------------

# All are on ubuntu-latest and Phase2's self-hosted runners, but a container
# job brings its own image. Failing here names the tool and still sets the
# outputs, instead of a bare "command not found" halfway through.
for tool in curl jq awk od; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    finish error missing_tool "" "" \
      "${tool} is not installed on this runner or in this job's container; coder-site-sync needs bash, curl, jq, awk and od."
  fi
done

# --- inputs -----------------------------------------------------------------

site_url="$(trim "${SITE_URL:-}")"
# The site serves the head of its source branch, so the commit to expect is
# the one this workflow ran on. action.yml defaults the input to github.sha;
# this fallback also covers an input passed explicitly but empty, such as an
# unset step output.
# expected_from names the source in messages: the input's default and the
# fallback are both github.sha, and the input cannot tell us whether it was
# defaulted, so a value equal to GITHUB_SHA is reported as the default.
expected="$(lower "$(trim "${EXPECTED_COMMIT:-}")")"
github_sha="$(lower "$(trim "${GITHUB_SHA:-}")")"
expected_label="expected_commit"
expected_from="expected_commit"
if [[ -z "$expected" ]]; then
  expected="$github_sha"
  expected_from="GITHUB_SHA"
fi
if [[ -n "$expected" && "$expected" == "$github_sha" ]]; then
  expected_label="expected_commit, default github.sha"
fi
timeout_seconds="$(trim "${TIMEOUT_SECONDS:-300}")"

if [[ -z "$site_url" ]]; then
  finish error invalid_input "" "" "site_url is required."
fi
if [[ -n "$expected" ]] && ! is_commit "$expected"; then
  finish error invalid_input "" "" \
    "${expected_from} must be a full 40-character commit SHA, got '${expected}'."
fi
if ! [[ "$timeout_seconds" =~ ^[1-9][0-9]{0,3}$ ]]; then
  finish error invalid_input "" "" \
    "timeout_seconds must be a whole number of seconds from 1 to 9999, got '${timeout_seconds}'."
fi

# The token's audience must equal the site's origin exactly, as the server
# derives it: lowercase https://<host>, no port, no path, no trailing slash.
# Anything else would mint a token the site refuses, so reject it here with
# a clearer message. One trailing slash is accepted and dropped.
url="$(lower "$site_url")"
url="${url%/}"
scheme="https"
proto="=https"
case "$url" in
  https://*) rest="${url#https://}" ;;
  http://*) scheme="http"; rest="${url#http://}" ;;
  *) finish error invalid_input "" "" \
       "site_url must start with https://, got '${site_url}'." ;;
esac
host="$rest"
port=""
if [[ "$host" == *:* ]]; then
  port="${host##*:}"
  host="${host%:*}"
fi

# TEST-ONLY: test-sync.sh runs this script against a plain-http stub server
# on the loopback interface. The relaxation applies only when all three hold:
# the flag is set, GITHUB_ACTIONS is not "true" (so it can never take effect
# inside a workflow, whatever the job's env says), and the host is loopback
# (so a token could only ever go back to the machine that minted it).
test_loopback=false
if [[ "${CODER_SITE_SYNC_TEST_ALLOW_LOOPBACK_HTTP:-}" == "1" \
   && "${GITHUB_ACTIONS:-}" != "true" \
   && ( "$host" == "127.0.0.1" || "$host" == "localhost" ) ]]; then
  test_loopback=true
  proto="=http"
fi

if [[ "$scheme" != "https" && "$test_loopback" != "true" ]]; then
  finish error invalid_input "" "" \
    "site_url must use https://, got '${site_url}'."
fi
if [[ "$rest" == */* || "$rest" == *\?* || "$rest" == *#* ]]; then
  finish error invalid_input "" "" \
    "site_url must be the site's origin with no path, query or fragment (https://<host>), got '${site_url}'."
fi
if [[ "$host" == *@* ]]; then
  finish error invalid_input "" "" \
    "site_url must not contain credentials, got a URL with '@'."
fi
if [[ -n "$port" && "$test_loopback" != "true" ]]; then
  finish error invalid_input "" "" \
    "site_url must not include a port (the token audience is https://<host>), got '${site_url}'."
fi
if [[ -n "$port" && ! "$port" =~ ^[0-9]{1,5}$ ]]; then
  finish error invalid_input "" "" "site_url has an invalid port, got '${site_url}'."
fi
if ! [[ "$host" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
  finish error invalid_input "" "" \
    "site_url has an invalid host, got '${site_url}'."
fi

# The site waits up to 240 seconds from the request's arrival for its fetch
# and build, then answers 202 if they are still running. A client limit
# below about 255 can give up first and turn that harmless 202 into a
# timeout failure.
if (( timeout_seconds < 255 )); then
  printf '::warning title=coder-site-sync::%s\n' \
    "timeout_seconds is ${timeout_seconds}. The site waits up to 240s for its build before answering, so values below 255 can turn a \"still syncing\" answer into a timeout failure."
fi

origin="${scheme}://${host}${port:+:$port}"
audience="$origin"
endpoint="${origin}/_hooks/deploy"

# --- OIDC token ---------------------------------------------------------------

if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" || -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
  finish error no_oidc_token "" "" \
    "No GitHub OIDC token is available to this job. Add 'permissions: id-token: write' to the calling job (workflows triggered from forks never receive one)."
fi

# The runtime URL already carries a query string (api-version); the audience
# is appended as one more parameter, URL-encoded.
audience_q="$(jq -rn --arg a "$audience" '$a | @uri')"
oidc_url="$ACTIONS_ID_TOKEN_REQUEST_URL"
if [[ "$oidc_url" == *\?* ]]; then
  oidc_url="${oidc_url}&audience=${audience_q}"
else
  oidc_url="${oidc_url}?audience=${audience_q}"
fi

oidc_code=""
if ! oidc_code="$(printf 'Authorization: Bearer %s\n' "$ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    | curl -q --silent --show-error --max-time 30 \
        --header @- --header 'Accept: application/json' \
        --output "$work/oidc.json" --write-out '%{http_code}' \
        "$oidc_url" 2>"$work/oidc.err")"; then
  finish error no_oidc_token "" "" \
    "Could not request an OIDC token from the Actions runtime: $(head -c 300 "$work/oidc.err")"
fi
if [[ "$oidc_code" != "200" ]]; then
  finish error no_oidc_token "" "" \
    "The Actions runtime refused the OIDC token request (HTTP ${oidc_code}). Check that the calling job has 'permissions: id-token: write'."
fi

token="$(jq -r '.value // empty' "$work/oidc.json" 2>/dev/null || true)"
rm -f "$work/oidc.json"
if [[ -z "$token" ]]; then
  finish error no_oidc_token "" "" \
    "The Actions runtime answered without a token value."
fi
# A JWT is three base64url segments. Checking the shape before masking means
# the mask covers the whole value (a newline would end the mask command) and
# the token cannot inject a second header line into the request below.
if ! [[ "$token" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
  finish error no_oidc_token "" "" \
    "The Actions runtime answered with a value that is not a JWT."
fi
# Masking first means that if anything below ever did print the token, the
# runner would redact it in the log. Nothing below prints it.
printf '::add-mask::%s\n' "$token"

# --- sync request -------------------------------------------------------------

# Redirects are never followed. On a site whose trigger route is absent, the
# request falls through to the Site Access gate and gets a 3xx to the login
# page; following it would replay the bearer token to wherever the redirect
# points and turn a clear "not CI-enabled" answer into an HTML 200. The
# --proto restriction also keeps the request on https outside tests.
echo "Requesting a sync of ${origin} (waiting up to ${timeout_seconds}s)."
rc=0
meta="$(printf 'Authorization: Bearer %s\n' "$token" \
  | curl -q --silent --show-error --request POST --data-binary '' \
      --proto "$proto" --max-time "$timeout_seconds" --connect-timeout 15 \
      --header @- --header 'Accept: application/json' \
      --output "$work/body" --write-out '%{http_code} %{content_type}' \
      "$endpoint" 2>"$work/curl.err")" || rc=$?
unset token

if [[ "$rc" -ne 0 ]]; then
  err="$(head -c 300 "$work/curl.err")"
  if [[ "$rc" -eq 28 ]]; then
    finish error timeout "" "" \
      "No answer from ${origin} within ${timeout_seconds}s. The site answers within about 240s (202 if the sync or build is still running), so check the workspace's Sync Log app (and its Build Log app for build output), and keep timeout_seconds at 255 or more. ${err}"
  fi
  finish error unreachable "" "" \
    "Could not reach ${origin} (curl exit ${rc}). ${err}"
fi

http_code="${meta%% *}"
content_type="$(lower "${meta#* }")"

# --- classify the response ----------------------------------------------------

# The trigger always answers application/json with a known `status` or
# `error` for each status code. Anything else came from something in front of
# it: the Site Access gate or auth service (route absent), nginx (auth off,
# route absent), or the Coder gateway (workspace stopped). Matching both the
# code AND the body keeps a gateway that happens to speak JSON from being
# mistaken for the trigger.
ours=false
field=""
detail=""
served=""
# Reads one string field of a JSON object body; empty for anything else,
# including a body that is not JSON at all.
body_field() {
  head -c 65536 "$work/body" \
    | jq -r --arg k "$1" 'if type == "object" then (.[$k] // "" | tostring) else "" end' \
      2>/dev/null || true
}
if [[ "$content_type" == application/json* ]]; then
  field="$(body_field status)"
  if [[ -z "$field" ]]; then
    field="$(body_field error)"
  fi
  if [[ -n "$field" ]]; then
    served="$(body_field commit)"
    detail="$(body_field detail)"
    case "${http_code}:${field}" in
      200:synced|202:syncing|400:bad_request|401:invalid_token|403:wrong_audience|403:wrong_repository|404:not_enabled|405:method_not_allowed|500:sync_failed|500:build_failed|503:jwks_unavailable)
        ours=true ;;
    esac
  fi
fi

repo="${GITHUB_REPOSITORY:-this repository}"
synclog="Check the workspace's Sync Log app."

# Prints the build log tail the site returned with build_failed, inside a
# collapsed log group. The tail is untrusted: it is whatever the project's
# build printed, so it could contain lines that look like workflow commands.
# Two independent guards keep them inert:
#   1. ::stop-commands:: with a fresh random token suspends ALL workflow
#      command processing until ::<token>:: is printed. The token is 128
#      random bits generated after the tail arrived, so the tail cannot
#      contain it.
#   2. Every tail line is printed behind a "| " prefix, so no line of it
#      starts with "::", and "##[" (which the runner's legacy parser looks
#      for anywhere in a line) is shown as "## [". Either guard alone keeps
#      the tail inert.
# ANSI escape sequences and other control characters are removed too, so the
# tail cannot recolour or rewrite the surrounding log. The site already caps
# the tail at 20 lines and 2 KiB; this keeps at most the last 4096
# characters (as bash counts them in the runner's locale) and 40 lines in
# case it does not.
clean_tail() {
  local t="$1"
  if (( ${#t} > 4096 )); then
    t="${t: -4096}"
  fi
  printf '%s\n' "$t" \
    | LC_ALL=C sed -e $'s#\x1b\\[[0-9;?]*[ -/]*[@-~]##g' -e $'s#\x1b\\][^\x07]*\x07##g' \
    | LC_ALL=C tr -d '\000-\010\013-\037\177'
}

print_build_tail() {
  local tok
  tok="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
  printf '::group::Build log tail from %s (untrusted, shown literally)\n' "$origin"
  printf '::stop-commands::%s\n' "$tok"
  # The last 40 lines up to the last non-blank one, each behind "| ".
  clean_tail "$1" \
    | sed 's/##\[/## [/g' \
    | awk '{ l[NR] = $0 } NF { last = NR }
           END { for (i = (last > 40 ? last - 39 : 1); i <= last; i++) print "| " l[i] }'
  printf '::%s::\n' "$tok"
  printf '::endgroup::\n'
}

# The last non-empty line of the tail, cleaned as above, for the one-line
# annotation. finish escapes it.
last_tail_line() {
  clean_tail "$1" | awk 'NF { last = $0 } END { print substr(last, 1, 300) }'
}

if [[ "$ours" == "true" ]]; then
  case "$field" in
    synced)
      served="$(lower "$served")"
      if ! is_commit "$served"; then
        finish error invalid_response true "" \
          "${origin} reported a sync but no valid commit."
      fi
      if [[ -z "$expected" ]]; then
        finish notice synced true "$served" \
          "${origin} synced and serves ${served}."
      fi
      if [[ "$served" == "$expected" ]]; then
        finish notice synced true "$served" \
          "${origin} synced and serves ${served}, as expected."
      fi
      # Not a failure: the site serves its branch head, which moves on its
      # own. A newer push between checkout and sync is the common case.
      finish warning commit_mismatch true "$served" \
        "${origin} synced but serves ${served}, not ${expected} (${expected_label}). Most likely a newer push landed on the site's branch between checkout and sync, this workflow ran on a branch other than the site's git_branch, or this ran on a pull_request merge commit."
      ;;
    syncing)
      finish warning syncing true "" \
        "${origin} is still syncing after its wait expired; the new content should appear shortly. ${synclog} Build progress is in its Build Log app."
      ;;
    invalid_token)
      finish error invalid_token true "" \
        "${origin} rejected the OIDC token (invalid_token): its signature, issuer or validity times did not verify. Re-run the job; if it persists, check the runner clock."
      ;;
    wrong_audience)
      finish error wrong_audience true "" \
        "${origin} rejected the token's audience (wrong_audience). site_url must be exactly the site's public URL, https://<host>."
      ;;
    wrong_repository)
      finish error wrong_repository true "" \
        "${origin} does not accept syncs from ${repo} (wrong_repository). The site only accepts the GitHub repository in its git_repo parameter; check that it points at ${repo}."
      ;;
    not_enabled)
      finish error not_enabled false "" \
        "${origin} has its sync trigger turned off in the workspace's running configuration (not_enabled). The workspace owner should check that ci_trigger is ticked and git_repo is the GitHub URL of ${repo}, then restart or rebuild the workspace, since changes to those parameters take effect only then."
      ;;
    sync_failed)
      detail="$(printf '%s' "$detail" | head -c 500)"
      finish error sync_failed true "" \
        "The sync on ${origin} failed to fetch or check out: ${detail:-no detail}. ${synclog}"
      ;;
    build_failed)
      print_build_tail "$detail"
      last="$(last_tail_line "$detail")"
      finish error build_failed true "" \
        "The build on ${origin} failed; the site still serves its previous version. Last log line: ${last:-(none)}. The build log tail is in this step's log; the full build output is in the workspace's Build Log app."
      ;;
    jwks_unavailable)
      finish error jwks_unavailable true "" \
        "${origin} could not fetch GitHub's token signing keys (jwks_unavailable). Re-run the job shortly."
      ;;
    bad_request|method_not_allowed)
      finish error "$field" true "" \
        "${origin} rejected the request (${field}, HTTP ${http_code}). This points at a bug in the action or the site's trigger."
      ;;
  esac
fi

# Not the trigger's JSON. A 502-504 comes from the Coder gateway (or its
# proxy) in front of the site: the workspace is not running, or it is but the
# trigger process is down or did not answer in time. Either way nothing is
# known to have synced, so it fails. Every
# other answer means the trigger route is absent, which is expected before the
# site is set up for CI, so it warns and reports enabled=false for the caller
# to fall back on (for example, Sync Now).
case "$http_code" in
  502|503|504)
    finish error site_unavailable "" "" \
      "${origin} answered HTTP ${http_code} from the gateway, not from the sync trigger: the workspace is not running, or its sync trigger is down or timed out. Check the workspace's Sync Log app (restarting the workspace restarts the trigger), then re-run."
    ;;
esac
finish warning not_ci_enabled false "" \
  "Site not CI-enabled yet: ${origin} answered HTTP ${http_code} without the sync trigger's response. Ask the workspace owner to tick the site's ci_trigger parameter (git_repo must be the GitHub URL of ${repo}), or press Sync Now on the workspace."
