#!/usr/bin/env bash
# Ask a Coder static-site workspace to sync its deploy branch, authenticated by
# a GitHub Actions OIDC token, and report what the site now serves.
#
# The site's trigger route (POST /_hooks/deploy) verifies the token's
# signature, issuer, times, audience (its own origin) and repository (its
# deploy_repo parameter), runs its existing sync, and answers with the commit
# it serves. Nothing secret is stored anywhere: the token is minted for this
# job, bound to this site's origin, and expires within minutes.
#
# Inputs arrive as environment variables set by action.yml:
#   SITE_URL         Site URL, https://<host> with an optional trailing slash.
#   EXPECTED_COMMIT  Deploy-branch commit the caller just pushed. Optional.
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

# Both are on ubuntu-latest and Phase2's self-hosted runners, but a container
# job brings its own image. Failing here names the tool and still sets the
# outputs, instead of a bare "command not found" halfway through.
for tool in curl jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    finish error missing_tool "" "" \
      "${tool} is not installed on this runner or in this job's container; coder-site-sync needs bash, curl and jq."
  fi
done

# --- inputs -----------------------------------------------------------------

site_url="$(trim "${SITE_URL:-}")"
expected="$(lower "$(trim "${EXPECTED_COMMIT:-}")")"
timeout_seconds="$(trim "${TIMEOUT_SECONDS:-60}")"

if [[ -z "$site_url" ]]; then
  finish error invalid_input "" "" "site_url is required."
fi
if [[ -n "$expected" ]] && ! is_commit "$expected"; then
  finish error invalid_input "" "" \
    "expected_commit must be a full 40-character commit SHA, got '${expected}'."
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

# The site answers within about 50 seconds of receiving the request, with 202
# if its sync is still running. A shorter client limit can give up first and
# turn that harmless 202 into a timeout failure.
if (( timeout_seconds < 55 )); then
  printf '::warning title=coder-site-sync::%s\n' \
    "timeout_seconds is ${timeout_seconds}. The site can take about 50s to answer, so values below 55 can turn a \"still syncing\" answer into a timeout failure."
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
      "No answer from ${origin} within ${timeout_seconds}s. The site answers within about 50s (202 if the sync is still running), so check the workspace's Sync Log app, and keep timeout_seconds at 55 or more. ${err}"
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
      200:synced|202:syncing|400:bad_request|401:invalid_token|403:wrong_audience|403:wrong_repository|404:not_enabled|405:method_not_allowed|500:sync_failed|503:jwks_unavailable)
        ours=true ;;
    esac
  fi
fi

repo="${GITHUB_REPOSITORY:-this repository}"
synclog="Check the workspace's Sync Log app."

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
      finish error mismatch true "$served" \
        "Site serves ${served}, expected ${expected}. ${synclog} Check that the site's git_branch is the branch you pushed."
      ;;
    syncing)
      finish warning syncing true "" \
        "${origin} is still syncing after its wait expired; the new content should appear shortly. ${synclog}"
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
        "${origin} does not accept syncs from ${repo} (wrong_repository). The workspace owner must set the site's deploy_repo parameter to ${repo}."
      ;;
    not_enabled)
      finish error not_enabled false "" \
        "${origin} has its sync trigger turned off (not_enabled). The workspace owner must set the site's deploy_repo parameter to ${repo}."
      ;;
    sync_failed)
      detail="$(printf '%s' "$detail" | head -c 500)"
      finish error sync_failed true "" \
        "The sync on ${origin} failed: ${detail:-no detail}. ${synclog}"
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
  "Site not CI-enabled yet: ${origin} answered HTTP ${http_code} without the sync trigger's response. Ask the workspace owner to set the site's deploy_repo parameter to ${repo}, or press Sync Now on the workspace."
