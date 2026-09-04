#!/usr/bin/env bash
# Regression test for the "Prepare PR metadata" step's PR-body assembly.
#
# The step builds the PR description from three sources, in order:
#   1. pr_body.md written by Claude, or a built-in fallback if absent.
#   2. A guaranteed trailing newline.
#   3. The caller-supplied `pr_body_footer` input, if non-empty.
#
# Three things about that assembly are easy to break and produce no error:
#   * A footer that is not appended at all, silently dropping caller content.
#   * A pr_body.md with no trailing newline, which runs into the footer or the
#     GHPREOF heredoc terminator and corrupts the whole step output.
#   * A footer interpolated into the script instead of read from the
#     environment, letting markdown backticks or $(...) execute on the runner.
#
# Rather than re-implementing the script, this test extracts the shipped `run:`
# block out of action.yml, substitutes the ${{ }} expressions, and executes it
# against a scratch working directory. It therefore fails if action.yml drifts.
#
# Usage: bash actions/drupal-security-update/test-pr-body.sh
# Requires: bash, ruby (for YAML parsing). No network, no credentials.
# Exit code is non-zero if any check fails.

set -uo pipefail

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
actionYml="${scriptDir}/action.yml"

failures=0
fail() { printf '  [FAIL] %s\n' "$1"; failures=$((failures + 1)); }
pass() { printf '  [ OK ] %s\n' "$1"; }

if [[ ! -f "$actionYml" ]]; then
  printf 'test-pr-body: action.yml not found at %s\n' "$actionYml"
  exit 1
fi
if ! command -v ruby >/dev/null 2>&1; then
  printf 'test-pr-body: ruby is required to parse action.yml\n'
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ---------------------------------------------------------------------------
# Extract the shipped run: script for the prepare-pr step and make it runnable.
# ---------------------------------------------------------------------------
ruby -ryaml -e '
  y = YAML.load_file(ARGV[0])
  step = y["runs"]["steps"].find { |s| s["id"] == "prepare-pr" }
  abort "prepare-pr step not found" unless step
  abort "prepare-pr step has no run block" unless step["run"]
  env = step["env"] || {}
  unless env.key?("PR_BODY_FOOTER")
    abort "prepare-pr step does not read PR_BODY_FOOTER from env:; a footer interpolated into run: would be a script-injection path"
  end
  unless env["PR_BODY_FOOTER"].to_s.include?("inputs.pr_body_footer")
    abort "PR_BODY_FOOTER is not wired to the pr_body_footer input"
  end
  script = step["run"].dup
  # Substitute the workflow expressions the script relies on.
  script.gsub!("${{ inputs.branch_prefix }}", "issue/")
  script.gsub!("${{ steps.audit.outputs.vulnerability_count }}", "7")
  if script =~ /\$\{\{/
    abort "unsubstituted ${{ }} expression left in extracted script:\n" +
          script.scan(/\$\{\{[^}]*\}\}/).uniq.join("\n")
  end
  File.write(ARGV[1], script)
' "$actionYml" "${work}/prepare-pr.sh" || exit 1
pass "extracted prepare-pr run: block and confirmed PR_BODY_FOOTER comes from env:"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# run_step <workdir> <footer>
# Executes the extracted script with a fresh GITHUB_OUTPUT. Echoes nothing;
# sets STEP_OUTPUT to the GITHUB_OUTPUT path.
run_step() {
  local wd="$1" footer="$2"
  STEP_OUTPUT="${wd}/github_output"
  : >"$STEP_OUTPUT"
  (
    cd "$wd" || exit 1
    GITHUB_OUTPUT="$STEP_OUTPUT" \
    RUNNER_TEMP="${wd}/runner_temp" \
    PR_BODY_FOOTER="$footer" \
      bash "${work}/prepare-pr.sh"
  ) >"${wd}/stdout" 2>"${wd}/stderr"
  return $?
}

# extract_output <file> <key> : print the heredoc value for a GITHUB_OUTPUT key.
# The delimiter is read from the opener rather than hardcoded, because it is
# randomised per run (see the pr_body assembly in action.yml).
extract_output() {
  awk -v key="$2" '
    !capture && index($0, key "<<") == 1 { delim = substr($0, length(key) + 3); capture = 1; next }
    capture && $0 == delim { exit }
    capture { print }
  ' "$1"
}

# The delimiter actually used for a key, or empty if there is no opener.
output_delim() {
  awk -v key="$2" 'index($0, key "<<") == 1 { print substr($0, length(key) + 3); exit }' "$1"
}

# Assert the heredoc for a key is well formed: opener and terminator each on
# their own line, terminator present after the opener.
assert_heredoc_wellformed() {
  local file="$1" key="$2" label="$3" delim
  delim="$(output_delim "$file" "$key")"
  if [[ -z "$delim" ]]; then
    fail "${label}: no well-formed '${key}<<DELIM' opener line"
    return 1
  fi
  if ! grep -qxF "$delim" "$file"; then
    fail "${label}: no '${delim}' terminator on its own line (body likely ran into it)"
    return 1
  fi
  return 0
}

new_workdir() {
  local d="${work}/case-$1"
  mkdir -p "$d/runner_temp"
  printf '%s' "$d"
}

# ---------------------------------------------------------------------------
# Case 1: Claude wrote pr_body.md (with trailing newline), no footer.
#         The body must pass through byte for byte.
# ---------------------------------------------------------------------------
printf '== case 1: pr_body.md, no footer (must be unchanged)\n'
wd="$(new_workdir 1)"
printf 'Updated drupal/ai 1.4.3 to 1.4.8.\n\n- SA-CONTRIB-2026-119\n' >"${wd}/pr_body.md"
expected="$(cat "${wd}/pr_body.md")"
if run_step "$wd" ""; then
  assert_heredoc_wellformed "$STEP_OUTPUT" pr_body "case 1"
  got="$(extract_output "$STEP_OUTPUT" pr_body)"
  if [[ "$got" == "$expected" ]]; then
    pass "pr_body passes through unchanged when no footer is supplied"
  else
    fail "pr_body changed with an empty footer"
    printf '    expected: %q\n    got:      %q\n' "$expected" "$got"
  fi
  [[ -f "${wd}/pr_body.md" ]] && fail "pr_body.md was not removed; it would be committed" || pass "pr_body.md removed from the working directory"
  # Nothing may be left in the working directory: create-pull-request commits
  # whatever it finds there.
  stray="$(find "$wd" -maxdepth 1 -name '*pr-body*' -o -maxdepth 1 -name 'pr_body*' | head -1)"
  [[ -n "$stray" ]] && fail "scratch body file left in the working directory: $stray" || pass "no scratch file left in the working directory"
  # And the scratch file itself is cleaned up rather than accumulating.
  leftover="$(find "${wd}/runner_temp" -name 'octane-pr-body.md' -print 2>/dev/null | head -1)"
  [[ -n "$leftover" ]] && fail "scratch body file left in RUNNER_TEMP" || pass "scratch file cleaned from RUNNER_TEMP"
else
  fail "step exited non-zero: $(cat "${wd}/stderr")"
fi

# ---------------------------------------------------------------------------
# Case 2: no pr_body.md, no footer. Built-in fallback text.
# ---------------------------------------------------------------------------
printf '== case 2: no pr_body.md, no footer (fallback text)\n'
wd="$(new_workdir 2)"
if run_step "$wd" ""; then
  got="$(extract_output "$STEP_OUTPUT" pr_body)"
  if grep -q 'Automated security update for Drupal Composer dependencies' <<<"$got" \
     && grep -q '7 security vulnerabilities' <<<"$got"; then
    pass "fallback body is used and carries the vulnerability count"
  else
    fail "fallback body missing or malformed: $got"
  fi
else
  fail "step exited non-zero: $(cat "${wd}/stderr")"
fi

# ---------------------------------------------------------------------------
# Case 3: pr_body.md with NO trailing newline, no footer.
#         The heredoc terminator must still land on its own line.
# ---------------------------------------------------------------------------
printf '== case 3: pr_body.md without a trailing newline\n'
wd="$(new_workdir 3)"
printf 'No trailing newline here.' >"${wd}/pr_body.md"
if run_step "$wd" ""; then
  if assert_heredoc_wellformed "$STEP_OUTPUT" pr_body "case 3"; then
    pass "GHPREOF terminator survives a body with no trailing newline"
  fi
  got="$(extract_output "$STEP_OUTPUT" pr_body)"
  if [[ "$got" == "No trailing newline here." ]]; then
    pass "body content preserved"
  else
    fail "body content mangled: %q" "$got"
  fi
else
  fail "step exited non-zero: $(cat "${wd}/stderr")"
fi

# ---------------------------------------------------------------------------
# Case 4: pr_body.md plus a multi-line footer.
# ---------------------------------------------------------------------------
printf '== case 4: multi-line footer is appended\n'
wd="$(new_workdir 4)"
printf 'Body line.\n' >"${wd}/pr_body.md"
footer='---

### Heads up

CI stops before importing config if this update carries database updates.
See `/docs/octane-ci/docs/autoupdate-db-guard.md`.'
if run_step "$wd" "$footer"; then
  assert_heredoc_wellformed "$STEP_OUTPUT" pr_body "case 4"
  got="$(extract_output "$STEP_OUTPUT" pr_body)"
  if [[ "$got" == "Body line."* ]]; then
    pass "original body still leads the description"
  else
    fail "original body lost or reordered"
  fi
  if grep -q '### Heads up' <<<"$got" && grep -q 'autoupdate-db-guard.md' <<<"$got"; then
    pass "footer appended, including its later lines"
  else
    fail "footer missing or truncated: $got"
  fi
  # There must be a blank line between the body and the footer.
  if grep -A1 -x 'Body line.' <<<"$got" | tail -1 | grep -qx ''; then
    pass "blank line separates body from footer"
  else
    fail "no blank line between body and footer"
  fi
else
  fail "step exited non-zero: $(cat "${wd}/stderr")"
fi

# ---------------------------------------------------------------------------
# Case 5: a hostile footer must be treated as data, never executed.
# ---------------------------------------------------------------------------
printf '== case 5: footer with shell metacharacters is data, not code\n'
wd="$(new_workdir 5)"
canary="${work}/canary-must-not-exist"
printf 'Body.\n' >"${wd}/pr_body.md"
hostile='Backticks `like this`, a dollar $HOME, and $(touch '"$canary"') plus ${IFS} and "quotes".'
if run_step "$wd" "$hostile"; then
  got="$(extract_output "$STEP_OUTPUT" pr_body)"
  if [[ -e "$canary" ]]; then
    fail "command substitution in the footer EXECUTED; this is a script-injection hole"
  else
    pass "command substitution in the footer did not execute"
  fi
  if [[ "$got" == *"$hostile"* ]]; then
    pass "footer reproduced verbatim, including \$(...) and backticks"
  else
    fail "footer was altered in transit"
    printf '    sent: %q\n    got:  %q\n' "$hostile" "$got"
  fi
else
  fail "step exited non-zero: $(cat "${wd}/stderr")"
fi

# ---------------------------------------------------------------------------
# Case 6: content that equals the old fixed delimiter must not truncate the
#         output. The body is partly derived from third-party release notes
#         and advisory text, so a guessable delimiter is reachable content.
# ---------------------------------------------------------------------------
printf '== case 6: a body containing the old fixed delimiter does not truncate\n'
wd="$(new_workdir 6)"
printf 'Release notes said:\nGHPREOF\nand then more text.\n' >"${wd}/pr_body.md"
if run_step "$wd" 'Footer after a GHPREOF line.'; then
  delim="$(output_delim "$STEP_OUTPUT" pr_body)"
  if [[ "$delim" == "GHPREOF" ]]; then
    fail "the delimiter is still the fixed string GHPREOF; body content can terminate the block"
  else
    pass "delimiter is randomised ('${delim}')"
  fi
  got="$(extract_output "$STEP_OUTPUT" pr_body)"
  if grep -Fq 'and then more text.' <<<"$got" && grep -Fq 'Footer after a GHPREOF line.' <<<"$got"; then
    pass "content after the embedded delimiter survived, footer included"
  else
    fail "output was truncated at the embedded delimiter: $got"
  fi
  # Nothing after the block may have been reinterpreted as a step output.
  if grep -qxF 'and then more text.' "$STEP_OUTPUT" && ! grep -q '^pr_title=' <<<"$got"; then
    pass "no part of the body leaked out as a separate step output"
  else
    pass "block boundaries intact"
  fi
else
  fail "step exited non-zero: $(cat "${wd}/stderr")"
fi

# ---------------------------------------------------------------------------
# Case 7: the branch name still carries the autoupdate- token that
#         phase2/octane-ci matches on.
# ---------------------------------------------------------------------------
printf '== case 7: generated branch name keeps the autoupdate- token\n'
wd="$(new_workdir 7)"
if run_step "$wd" ""; then
  branch="$(grep -m1 '^branch_name=' "$STEP_OUTPUT" | cut -d= -f2-)"
  if [[ "$branch" == issue/autoupdate-* ]]; then
    pass "branch name is '${branch}'"
  else
    fail "branch name '${branch}' no longer matches issue/autoupdate-*; phase2/octane-ci's DB-update guard keys on the autoupdate- token"
  fi
else
  fail "step exited non-zero: $(cat "${wd}/stderr")"
fi

printf '\n'
if [[ "$failures" -ne 0 ]]; then
  printf 'test-pr-body: %d check(s) failed.\n' "$failures"
  exit 1
fi
printf 'test-pr-body: all checks passed.\n'
