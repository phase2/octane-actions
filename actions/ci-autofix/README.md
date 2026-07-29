# Octane CI Auto-Remediation Action

Triages a failed Octane CI run with Claude and, when the cause is local code or
configuration, opens a review-ready fix PR.

Built as the failure-side counterpart to
[`drupal-security-update`](../drupal-security-update/README.md) and deliberately
shares its shape: Claude produces the changes plus `pr_body.md` and
`commit_message.txt` without committing, and
`peter-evans/create-pull-request` commits and opens the PR under a GitHub App
token.

## What it does

1. Resolves the failed run (an explicit `run_id`, or the most recent failed run
   of `workflow_name`).
2. Collects the failed job list and a **bounded** tail excerpt of each failed
   job's log.
3. Runs Claude against `instructions.md`, an Octane-aware runbook.
4. Claude **classifies before fixing**:
   - `code`: a local edit fixes it, so it produces a minimal fix.
   - `infra`: environmental (k8s, registry, network, secrets), so it makes no
     edits.
   - `unknown`: insufficient evidence, so it makes no edits.
5. Opens a fix PR only for a confident `code` classification that actually
   changed files, and only when the change set passes the sanity guard.
6. Deduplicates by **failure fingerprint**, not by label.
7. Notifies Slack on both the PR path and the no-PR path.

## Design notes worth knowing before you change it

### Triage is schema-enforced, not prose

The action passes `--json-schema` to `claude-code-action`, so the classification
arrives as a validated object on the `structured_output` output rather than as
text to be parsed. Downstream steps gate on it. If you add a field to the schema,
add it to `instructions.md` section 7 in the same commit; the two are a contract.

### Logs are fetched by the agent, not inlined

`additional_permissions: actions: read` exposes the `mcp__github_ci__*` tools, so
the agent pulls the logs it needs for the jobs that failed. The prompt carries
only a bounded excerpt (per-job line cap plus a 20k character total cap) as a
starting point. Octane's nightly streams a full remote `composer install`;
inlining that would be both a cost and a context-window problem.

### `allowed_bots: "*"` is mandatory here

In agent mode `claude-code-action` calls `checkHumanActor` unconditionally and
throws unless the actor is a real user or is allow-listed. On a `workflow_run`
trigger the actor is inherited from the triggering run, so a bot-initiated build
would hard-fail without this.

### Log content is untrusted

Build logs are attacker-influenceable in the general case. The prompt explicitly
frames the log excerpt as data, not instructions. Keep that framing if you edit
the prompt.

### Two independent guards stop a runaway run

- **Change-set sanity**: refuses to open a PR if the workspace was already dirty
  before the agent ran, if more than `max_changed_files` files changed, if the
  workspace is clean despite the agent reporting changes, or if generated
  `.github/workflows/` changed with no corresponding `actions/src|includes`
  change. The file count uses `git status --porcelain -uall`, because plain
  porcelain collapses an untracked directory to a single line and a generated
  project would otherwise score 1 against the limit.
- **Fingerprint dedup**: closes a prior PR only on an exact fingerprint-marker
  match. An empty or missing fingerprint closes nothing, ever.

### `conclusion` is not readable

`claude-code-action@v1` sets a `conclusion` output internally but does not
declare it in `action.yml`, so callers cannot read it. This action uses
`continue-on-error` plus the step's own `outcome` instead.

## Usage

The action reasons about, and edits, a checked-out working tree, so the calling
job must check the repository out first. It refuses to open a PR if that tree is
already dirty when the agent starts.

```yaml
- name: Check out the repo
  uses: actions/checkout@v6
  with:
    # Full history so create-pull-request can branch cleanly.
    fetch-depth: 0

- name: Generate GitHub App token
  id: app-token
  uses: actions/create-github-app-token@v3
  with:
    client-id: ${{ vars.DRUPAL_SECURITY_DISPATCH_APP_CLIENT_ID }}
    private-key: ${{ secrets.DRUPAL_SECURITY_DISPATCH_APP_PRIVATE_KEY }}

- name: Nightly auto-remediation
  uses: phase2/octane-actions/actions/ci-autofix@main
  with:
    anthropic_api_key: ${{ secrets.ANTHROPIC_DRUPAL_SECURITY_UPDATES_API_KEY }}
    github_token: ${{ steps.app-token.outputs.token }}
    run_id: ${{ github.event.workflow_run.id }}
    workflow_name: Build Nightly
    base_branch: ${{ github.event.repository.default_branch }}
    slack_bot_token: ${{ secrets.SLACK_DRUPAL_SECURITY_UPDATES_BOT_TOKEN }}
    slack_channel_id: ${{ vars.SLACK_CHANNEL_ID }}
```

The token **must** be a GitHub App token, not `GITHUB_TOKEN`, or the fix PR will
not trigger its own CI, which is the only real proof the fix works.

## Inputs

| Input | Default | Description |
|---|---|---|
| `anthropic_api_key` | *(required)* | Anthropic API key |
| `github_token` | `github.token` | Reads run logs and opens the PR. Use an App token. |
| `run_id` | `''` | Failed run to analyze. Empty means latest failed run of `workflow_name`. |
| `workflow_name` | `Build Nightly` | Workflow to search when `run_id` is empty |
| `working_directory` | `.` | Directory to operate in |
| `base_branch` | `main` | PR base branch |
| `dry_run` | `false` | Triage and report; never create, update or close a PR |
| `branch_prefix` | `issue/NT-autofix-` | Branch name prefix |
| `pr_reviewers` | `''` | Comma-separated reviewers |
| `pr_label` | `nightly-autofix` | Label scoping dedup. Empty disables labeling and dedup. |
| `deduplicate_prs` | `true` | Supersede a prior open PR with a matching fingerprint |
| `confidence_threshold` | `0.7` | Minimum triage confidence before a PR is opened |
| `model` | `claude-sonnet-4-6` | Claude model |
| `max_turns` | `60` | Agent turn cap |
| `log_excerpt_lines` | `150` | Tail lines kept per failed job for the prompt excerpt |
| `max_changed_files` | `25` | Refuse to open a PR above this many changed files |
| `slack_bot_token` | `''` | Slack bot token (needs `slack_channel_id`) |
| `slack_channel_id` | `''` | Slack channel (needs `slack_bot_token`) |
| `slack_errors` | `false` | Fail the workflow if Slack notification fails |

## Outputs

| Output | Description |
|---|---|
| `classification` | `code`, `infra`, `unknown`, or `error` if triage did not complete |
| `confidence` | Triage confidence, 0-1 |
| `fingerprint` | Stable failure fingerprint used for dedup |
| `summary` | One-line diagnosis |
| `analyzed_run_id` | Run that was analyzed |
| `pr_url` | Created PR URL, empty if none |
| `pr_action` | `create`, `supersede`, or empty |
| `superseded_pr` | Superseded PR number(s), comma-separated |
| `cost_usd` | Agent run cost when available |

## Required permissions

```yaml
permissions:
  contents: write
  pull-requests: write
  issues: write
  actions: read   # Required: run/job/log reads and the github_ci MCP tools.
```

## Testing it without waiting for a failure

`workflow_run` only ever runs the workflow file from the default branch, so give
the calling workflow a `workflow_dispatch` with `run_id` and `dry_run` inputs.
That is the only way to exercise triage, log access, cost and diagnosis quality
before merging, and it doubles as the permanent manual re-run handle.

A dry run classifies and reports, opens no PR, and closes nothing.

## Consumer of this action

`phase2/octane-ci` calls it from `.octane-ci/actions/src/nightly_autofix.yml`.
See `.octane-ci/docs/octane/nightly-autofix.md` in that repo for the operational
doc, and `.octane-ci/scripts/test-nightly-autofix.sh` for the static guard that
catches the silent-death failure mode (renaming the watched workflow).
