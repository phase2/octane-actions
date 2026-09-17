#!/usr/bin/env bash
# Regression test for ci-autofix's token split and its Slack mention handling.
#
# Two properties of this action fail SILENTLY, and both have already cost a
# production night:
#
#   * TOKEN SPLIT. Every Actions read (run details, job list, job logs, and the
#     github_ci MCP tools handed to the agent) must use actions_read_token, while
#     the PR steps must keep github_token. Collapsing the two back into one input
#     reintroduces one of two failures depending on which way it collapses: a 403
#     "Resource not accessible by integration" when a GitHub App token with no
#     actions:read reaches the read path, or a fix PR that never triggers its own
#     CI when the default GITHUB_TOKEN reaches create-pull-request. Neither is
#     visible in review; the first killed phase2/octane-ci run 35185235459.
#
#   * MENTION NORMALISATION, AND WHERE IT HAPPENS. The mention is normalised in a
#     step that must run BEFORE anything that can fail. A composite step with no
#     `if:` is skipped once an earlier step has failed, and the notification steps
#     run on always()/!cancelled(), so normalising the mention alongside the triage
#     result would leave it empty on exactly the runs where a human most needs
#     paging. A newline in the value would also close the step-output line and let
#     further outputs be injected; a double quote would break the YAML payload that
#     slack-github-action parses at runtime.
#
# Rather than re-implementing the logic, this test extracts the shipped `run:`
# block out of action.yml and executes it, so it fails if action.yml drifts.
#
# Usage: bash actions/ci-autofix/test-notify.sh
# Requires: bash, ruby (for YAML parsing). No network, no credentials.
# Exit code is non-zero if any check fails.

set -uo pipefail

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
actionYml="${scriptDir}/action.yml"

failures=0
fail() { printf '  [FAIL] %s\n' "$1"; failures=$((failures + 1)); }
pass() { printf '  [ OK ] %s\n' "$1"; }

if [[ ! -f "$actionYml" ]]; then
  printf 'test-notify: action.yml not found at %s\n' "$actionYml"
  exit 1
fi
if ! command -v ruby >/dev/null 2>&1; then
  printf 'test-notify: ruby is required to parse action.yml\n'
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ---------------------------------------------------------------------------
printf '== token split (read path vs PR path)\n'

ruby -ryaml -e '
  y = YAML.load_file(ARGV[0])
  inputs = y["inputs"] || {}
  steps  = y["runs"]["steps"]
  errors = []

  %w[github_token actions_read_token].each do |name|
    errors << "input #{name} is missing" unless inputs.key?(name)
  end

  def step_by(steps, key, value)
    steps.find { |s| s[key] == value }
  end

  # The two read sites.
  ctx = step_by(steps, "id", "context")
  errors << "no step with id: context" unless ctx
  if ctx
    tok = (ctx["with"] || {})["github-token"].to_s
    unless tok.include?("inputs.actions_read_token")
      errors << "Collect failure context uses #{tok.strip.empty? ? "(nothing)" : tok.strip} " \
                "instead of inputs.actions_read_token; a GitHub App token without " \
                "actions:read 403s on GET /actions/runs/{id}"
    end
  end

  triage = step_by(steps, "id", "triage")
  errors << "no step with id: triage" unless triage
  if triage
    tok = (triage["with"] || {})["github_token"].to_s
    unless tok.include?("inputs.actions_read_token")
      errors << "the Claude step uses #{tok.strip.empty? ? "(nothing)" : tok.strip} " \
                "instead of inputs.actions_read_token; its additional_permissions " \
                "exposes the github_ci MCP log tools, which hit the same endpoints"
    end
  end

  # The PR site must keep the write-scoped token, or the fix PR stops triggering
  # its own CI, which is the only real proof a fix works.
  pr = step_by(steps, "id", "create-pr")
  errors << "no step with id: create-pr" unless pr
  if pr
    tok = (pr["with"] || {})["token"].to_s
    unless tok.include?("inputs.github_token")
      errors << "create-pr uses #{tok.strip.empty? ? "(nothing)" : tok.strip} instead of " \
                "inputs.github_token; a PR opened under GITHUB_TOKEN does not trigger CI"
    end
  end

  abort errors.join("\n") unless errors.empty?
' "$actionYml" && pass "reads use actions_read_token, create-pr keeps github_token" || fail "token split is broken (see above)"

# ---------------------------------------------------------------------------
printf '== the notify step runs before anything that can fail\n'

ruby -ryaml -e '
  y = YAML.load_file(ARGV[0])
  steps = y["runs"]["steps"]
  idx = steps.index { |s| s["id"] == "notify" }
  abort "no step with id: notify" if idx.nil?
  unless idx.zero?
    abort "the notify step is at position #{idx + 1}, not first. A composite step " \
          "with no if: is skipped once an earlier step has failed, so the mention " \
          "would be empty on precisely the runs that need a human paged."
  end
  step = steps[idx]
  abort "the notify step has no run: block" unless step["run"]
  env = step["env"] || {}
  unless env.values.any? { |v| v.to_s.include?("inputs.slack_mention") }
    abort "the notify step does not read inputs.slack_mention from env:; a mention " \
          "interpolated into run: would be a script-injection path"
  end
' "$actionYml" && pass "notify is the first step and reads slack_mention from env:" || fail "notify step placement or wiring is wrong (see above)"

# ---------------------------------------------------------------------------
printf '== both Slack payloads carry the mention\n'

ruby -ryaml -e '
  y = YAML.load_file(ARGV[0])
  steps = y["runs"]["steps"]
  slack = steps.select { |s| (s["uses"] || "").include?("slack-github-action") }
  abort "expected 2 Slack steps, found #{slack.size}" unless slack.size == 2
  slack.each do |s|
    payload = (s["with"] || {})["payload"].to_s
    name    = s["name"]
    unless payload.include?("steps.notify.outputs.mention")
      abort "#{name.inspect} payload does not interpolate the normalised mention"
    end
    # Slack drives the notification from block content when blocks are present,
    # while text: supplies the preview. A mention in only one under-delivers.
    text_line = payload.lines.find { |l| l =~ /^\s*text:\s*"/ }
    abort "#{name.inspect} payload has no top-level text: fallback" unless text_line
    unless text_line.include?("steps.notify.outputs.mention")
      abort "#{name.inspect} has the mention in blocks but not in the text: fallback"
    end
    unless payload.scan("steps.notify.outputs.mention").size >= 2
      abort "#{name.inspect} mentions the user only once; it must appear in both " \
            "the text: fallback and a block"
    end
  end
' "$actionYml" && pass "both notifications carry the mention in text: and in a block" || fail "Slack payload mention wiring is wrong (see above)"

# ---------------------------------------------------------------------------
# Extract the shipped notify run: block and make it runnable.
# ---------------------------------------------------------------------------
ruby -ryaml -e '
  y = YAML.load_file(ARGV[0])
  step = y["runs"]["steps"].find { |s| s["id"] == "notify" }
  abort "notify step not found" unless step
  script = step["run"].dup
  if script =~ /\$\{\{/
    abort "unsubstituted ${{ }} expression left in extracted script:\n" +
          script.scan(/\$\{\{[^}]*\}\}/).uniq.join("\n")
  end
  File.write(ARGV[1], script)
' "$actionYml" "${work}/notify.sh" || exit 1

# run_notify <raw mention> : sets OUT to the GITHUB_OUTPUT path.
run_notify() {
  local raw="$1"
  OUT="${work}/out-$$-${RANDOM}"
  : >"$OUT"
  GITHUB_OUTPUT="$OUT" RAW_MENTION="$raw" bash "${work}/notify.sh" \
    >"${OUT}.stdout" 2>"${OUT}.stderr"
  return $?
}

out_value() { grep -m1 "^$2=" "$1" | cut -d= -f2-; }

# Every line must be a plain key=value assignment. Anything else means content
# escaped into the file command, which is the injection this guards against.
assert_only_assignments() {
  local bad
  bad="$(grep -vE '^[A-Za-z_][A-Za-z0-9_]*=' "$1" | grep -v '^$' || true)"
  if [[ -n "$bad" ]]; then
    printf '        orphan line(s):\n%s\n' "$bad"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
printf '== case 1: an ordinary mention passes through\n'
if run_notify '<@U02C60X0DLN>'; then
  if [[ "$(out_value "$OUT" mention)" == '<@U02C60X0DLN>' ]]; then
    pass "mention preserved verbatim"
  else
    fail "mention altered: $(out_value "$OUT" mention)"
  fi
  if [[ "$(out_value "$OUT" mention_prefix)" == '<@U02C60X0DLN> ' ]]; then
    pass "mention_prefix carries exactly one trailing space"
  else
    fail "mention_prefix is $(printf '%q' "$(out_value "$OUT" mention_prefix)")"
  fi
else
  fail "step exited non-zero: $(cat "${OUT}.stderr")"
fi

# ---------------------------------------------------------------------------
printf '== case 2: an empty mention leaves no stray whitespace\n'
if run_notify ''; then
  if [[ -z "$(out_value "$OUT" mention)" && -z "$(out_value "$OUT" mention_prefix)" ]]; then
    pass "both outputs empty, so an unconfigured mention renders cleanly"
  else
    fail "empty mention produced $(printf '%q' "$(out_value "$OUT" mention_prefix)")"
  fi
  assert_only_assignments "$OUT" && pass "no orphan lines" || fail "orphan lines in GITHUB_OUTPUT"
else
  fail "step exited non-zero: $(cat "${OUT}.stderr")"
fi

# ---------------------------------------------------------------------------
printf '== case 3: a double quote cannot break the YAML payload\n'
if run_notify '<@U1> say "hi"'; then
  if [[ "$(out_value "$OUT" mention)" == *'"'* ]]; then
    fail "double quote survived; it would break the Slack payload YAML"
  else
    pass "double quotes stripped"
  fi
else
  fail "step exited non-zero: $(cat "${OUT}.stderr")"
fi

# ---------------------------------------------------------------------------
printf '== case 4: a newline cannot inject further step outputs\n'
if run_notify '<@U1>
should_pr=true'; then
  if grep -qx 'should_pr=true' "$OUT"; then
    fail "a newline in the mention injected an extra step output; should_pr can gate PR creation"
  else
    pass "newline neutralised, no injected output"
  fi
  assert_only_assignments "$OUT" && pass "every line is a plain assignment" || fail "content escaped into GITHUB_OUTPUT"
  lines="$(wc -l <"$OUT" | tr -d ' ')"
  [[ "$lines" -eq 2 ]] && pass "exactly the two expected outputs were written" \
                       || fail "expected 2 output lines, got ${lines}"
else
  fail "step exited non-zero: $(cat "${OUT}.stderr")"
fi

# ---------------------------------------------------------------------------
printf '== case 5: shell metacharacters are data, not code\n'
canary="${work}/canary-must-not-exist"
if run_notify '<@U1> $(touch '"$canary"') `id` ${IFS}'; then
  if [[ -e "$canary" ]]; then
    fail "command substitution in the mention EXECUTED; this is a script-injection hole"
  else
    pass "command substitution did not execute"
  fi
else
  fail "step exited non-zero: $(cat "${OUT}.stderr")"
fi

# ---------------------------------------------------------------------------
printf '== case 6: an overlong mention is bounded\n'
if run_notify "$(printf '<@U1>%.0s' $(seq 1 200))"; then
  len=$(printf '%s' "$(out_value "$OUT" mention)" | wc -c | tr -d ' ')
  if [[ "$len" -le 200 ]]; then
    pass "mention bounded to ${len} characters"
  else
    fail "mention is ${len} characters; it is not bounded"
  fi
else
  fail "step exited non-zero: $(cat "${OUT}.stderr")"
fi

printf '\n'
if [[ "$failures" -ne 0 ]]; then
  printf 'test-notify: %d check(s) failed.\n' "$failures"
  exit 1
fi
printf 'test-notify: all checks passed.\n'
