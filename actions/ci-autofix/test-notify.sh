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

  # A positive check on three known ids is an allowlist, not a guard: a NEW step
  # wired to inputs.github_token and calling an Actions endpoint would pass it
  # and 403 in production exactly as run 35185235459 did. Pin the whole set.
  expected_writers = %w[create-pr dedup]
  writers = steps.select { |st|
    (st["with"] || {}).values.any? { |v| v.to_s.include?("inputs.github_token") }
  }.map { |st| st["id"] }
  unless writers.sort == expected_writers.sort
    errors << "steps holding inputs.github_token are #{writers.inspect}, expected " \
              "#{expected_writers.inspect}. A new step on the write token that reads " \
              "the Actions API will 403; one moved off it stops working."
  end

  abort errors.join("\n") unless errors.empty?
' "$actionYml" && pass "reads use actions_read_token; only create-pr and dedup hold the write token" || fail "token split is broken (see above)"

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
# The agent transcript echoes build-log content, which this action treats as
# untrusted. It must stay off unless a caller deliberately asks for it, and the
# wiring must go through the input rather than a hardcoded literal: a stray
# `show_full_output: true` would print every run transcript forever and nothing
# else would notice.
printf '== the agent transcript stays off by default\n'

ruby -ryaml -e '
  y = YAML.load_file(ARGV[0])
  inputs = y["inputs"] || {}
  errors = []

  dbg = inputs["debug_output"]
  if dbg.nil?
    errors << "input debug_output is missing"
  elsif dbg["default"].to_s != "false"
    errors << "debug_output defaults to #{dbg["default"].inspect}, not \"false\"; " \
              "the transcript would print on every run"
  end

  triage = y["runs"]["steps"].find { |st| st["id"] == "triage" }
  if triage.nil?
    errors << "no step with id: triage"
  else
    val = (triage["with"] || {})["show_full_output"].to_s
    if val.empty?
      errors << "the Claude step does not set show_full_output at all"
    elsif !val.include?("inputs.debug_output")
      errors << "show_full_output is #{val.strip.inspect} rather than the " \
                "debug_output input; a hardcoded value cannot be turned off by a caller"
    end
  end

  abort errors.join("\n") unless errors.empty?
' "$actionYml" && pass "debug_output defaults to false and drives show_full_output" || fail "transcript wiring is wrong (see above)"

# ---------------------------------------------------------------------------
printf '== both Slack payloads carry the mention\n'

ruby -ryaml -e '
  y = YAML.load_file(ARGV[0])
  steps = y["runs"]["steps"]
  slack = steps.select { |s| (s["uses"] || "").include?("slack-github-action") }
  abort "expected 2 Slack steps, found #{slack.size}" unless slack.size == 2
  # Match mention_prefix EXACTLY. The bare substring "outputs.mention" also
  # matches "outputs.mention_prefix", so it would pass on a payload switched to
  # the unprefixed value, which renders with no space before the message.
  token = "steps.notify.outputs.mention_prefix"
  slack.each do |s|
    payload = (s["with"] || {})["payload"].to_s
    name    = s["name"]

    # The top-level text: is the least-indented one. Finding "the first text:"
    # instead breaks the moment text: is written below blocks:, and silently
    # inspects a header block text: rather than the fallback.
    text_lines = payload.lines.select { |l| l =~ /^(\s*)text:\s*"/ }
    abort "#{name.inspect} payload has no text: scalar" if text_lines.empty?
    indent = text_lines.map { |l| l[/^\s*/].length }.min
    top    = text_lines.select { |l| l[/^\s*/].length == indent }
    block  = text_lines - top

    unless top.any? { |l| l.include?(token) }
      abort "#{name.inspect} does not interpolate #{token} in its top-level " \
            "text: fallback, which is the notification preview"
    end
    # Slack drives the notification from block content when blocks are present,
    # while text: supplies the preview. A mention in only one under-delivers.
    unless block.any? { |l| l.include?(token) }
      abort "#{name.inspect} has the mention in text: but in no block; counting " \
            "total occurrences would pass on two hits in text: alone"
    end

    # The gating that makes any of this reachable. A bare `if:` gets an implicit
    # success(), so both notifiers skip on precisely the runs that need them.
    cond = s["if"].to_s
    unless cond.include?("!cancelled()")
      abort "#{name.inspect} is gated on #{cond.inspect} with no !cancelled(); " \
            "an implicit success() skips it after any earlier step fails"
    end
  end
' "$actionYml" && pass "both notifications carry the mention in text: and a block, and survive a failure" || fail "Slack payload mention wiring is wrong (see above)"

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
  # The runner executes `shell: bash` as `bash --noprofile --norc -eo pipefail`.
  # Running it as plain bash leaves `-e` off, so a future edit that returns
  # non-zero on some input would pass here and abort the step in production.
  # notify is step 1 with no `if:`, so that abort skips EVERY later step,
  # including both Slack notifiers. Match the runner exactly.
  GITHUB_OUTPUT="$OUT" RAW_MENTION="$raw" \
    bash --noprofile --norc -eo pipefail "${work}/notify.sh" \
    >"${OUT}.stdout" 2>"${OUT}.stderr"
  return $?
}

out_value() { grep -m1 "^$2=" "$1" | cut -d= -f2-; }

# Every line must assign one of the two keys this step is allowed to write.
# An ALLOWLIST, not a shape test: the injection being guarded against is
# `should_pr=true`, which is itself a well-formed key=value line, so a pattern
# like '^[A-Za-z_][A-Za-z0-9_]*=' matches it and reports the file clean while
# the injected output sits in it.
assert_only_assignments() {
  local bad
  bad="$(grep -vE '^(mention|mention_prefix)=' "$1" | grep -v '^[[:space:]]*$' || true)"
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

# ---------------------------------------------------------------------------
# The trim was the one line in this step no case exercised: deleting it left
# the whole suite green.
printf '== case 7: surrounding whitespace is trimmed\n'
if run_notify '   <@U1>   '; then
  if [[ "$(out_value "$OUT" mention)" == '<@U1>' ]]; then
    pass "leading and trailing whitespace removed"
  else
    fail "mention is $(printf '%q' "$(out_value "$OUT" mention)"), expected <@U1>"
  fi
  if [[ "$(out_value "$OUT" mention_prefix)" == '<@U1> ' ]]; then
    pass "mention_prefix carries exactly one trailing space"
  else
    fail "mention_prefix is $(printf '%q' "$(out_value "$OUT" mention_prefix)")"
  fi
else
  fail "step exited non-zero: $(cat "${OUT}.stderr")"
fi

if run_notify '     '; then
  if [[ -z "$(out_value "$OUT" mention)" && -z "$(out_value "$OUT" mention_prefix)" ]]; then
    pass "an all-whitespace mention collapses to empty"
  else
    fail "whitespace-only mention produced $(printf '%q' "$(out_value "$OUT" mention_prefix)")"
  fi
else
  fail "step exited non-zero: $(cat "${OUT}.stderr")"
fi

# ---------------------------------------------------------------------------
# The payload interpolates this into a double-quoted YAML scalar, where a
# backslash opens an escape sequence. An unknown escape is a hard parse error
# in slack-github-action, and a parse error is NOT gated by slack_errors, so
# both notifications are lost. Backslashes must survive as data, doubled.
printf '== case 8: a backslash cannot break the payload, and is not lost\n'
if run_notify 'Drupal\Core\Entity'; then
  got="$(out_value "$OUT" mention)"
  if [[ "$got" == 'Drupal\\Core\\Entity' ]]; then
    pass "backslashes doubled, so the YAML scalar stays valid"
  else
    fail "expected doubled backslashes, got $(printf '%q' "$got")"
  fi
  if command -v ruby >/dev/null 2>&1; then
    printf 'text: "%s"\n' "$(out_value "$OUT" mention_prefix)ok" >"${work}/p.yml"
    if ruby -ryaml -e 'v = YAML.safe_load(File.read(ARGV[0]))["text"]
                       abort "round-trip lost the backslashes: #{v.inspect}" unless v.include?("Drupal\\Core\\Entity")' "${work}/p.yml"; then
      pass "payload parses and round-trips the original text"
    else
      fail "payload does not parse, or the text did not survive"
    fi
  fi
else
  fail "step exited non-zero: $(cat "${OUT}.stderr")"
fi

printf '== case 9: control characters are stripped\n'
if run_notify "$(printf '<@U1>\033[0m\007x')"; then
  got="$(out_value "$OUT" mention)"
  if [[ "$got" == '<@U1>[0mx' ]]; then
    pass "ESC and BEL removed, printable text kept"
  else
    fail "expected control characters stripped, got $(printf '%q' "$got")"
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
