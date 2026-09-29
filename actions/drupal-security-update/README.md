# Drupal Security Update Action

Automatically update Drupal Composer dependencies with security vulnerabilities using Claude AI.

## Features

- Runs `composer audit` to detect security vulnerabilities
- Only triggers updates when vulnerabilities are found
- Uses Claude AI to intelligently handle updates, including:
  - Updating vulnerable packages
  - Resolving patch conflicts by searching drupal.org issue queues
  - Rerolling local patches when needed
- Creates a PR with detailed description of changes
- Optionally deduplicates PRs by closing stale security update PRs before creating a new one (defaults to deduplication)
- Optionally sends Slack notification that an update is available

## Usage

Note usage examples demonstrate use of Phase2 organization level secrets for anthropic_api_key
and slack_bot_token.

You should not need to configure a project-level secret for these items for projects in the
Phase2 organization.

```yaml
name: Drupal Security Update Action

on:
  workflow_dispatch:
  repository_dispatch:
    types: [drupal-security-update-dispatch]

jobs:
  security-update:
    runs-on: self-hosted
    container:
      image: ghcr.io/phase2/docker-cli:php8.3
      options: --user 1000
    permissions:
      contents: write
      pull-requests: write
      issues: write
    steps:
      - uses: actions/checkout@v4
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          persist-credentials: false
      - name: Drupal Security Update
        uses: phase2/octane-actions/actions/drupal-security-update@main
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_DRUPAL_SECURITY_UPDATES_API_KEY }}
```

## Inputs

| Input | Description | Required | Default |
| --- | --- | --- | --- |
| `anthropic_api_key` | Anthropic API key for Claude | Yes | - |
| `github_token` | GitHub token for creating branches and PRs | No | `github.token` |
| `working_directory` | Directory containing composer.json | No | `.` |
| `base_branch` | Base branch for the PR | No | `main` |
| `dry_run` | Check for vulnerabilities without creating PR | No | `false` |
| `branch_prefix` | Prefix for the created branch name | No | `issue/` |
| `pr_reviewers` | Comma-separated list of GitHub usernames to request review from | No | - |
| `pr_label` | Label applied to PRs for deduplication. Set to empty string to disable labeling. | No | `drupal-security-update` |
| `deduplicate_prs` | If true, close existing open PRs with the same label before creating a new one. Requires pr_label not be disabled. | No | `true` |
| `slack_bot_token` | Slack bot OAuth token for posting notifications | No | - |
| `slack_channel_id` | Slack channel ID to post notification when PR is created | No | - |
| `slack_errors` | If true, fail the workflow when Slack notification fails | No | `false` |
| `package_wait_seconds` | Seconds to wait and retry if a fixed package version is not yet published | No | `300` |
| `pr_body_footer` | Markdown appended verbatim to the end of the generated PR description. See [Example: Explaining caller-specific CI behaviour](#example-explaining-caller-specific-ci-behaviour). | No | - |

## Outputs

| Output | Description |
| --- | --- |
| `has_vulnerabilities` | Whether security vulnerabilities were found |
| `pr_url` | URL of the created pull request (if any) |
| `vulnerabilities_found` | Number of vulnerabilities found |
| `pr_action` | Action taken for PR (`create` or `supersede`) |
| `superseded_pr` | PR number(s) that were superseded (comma-separated if multiple) |

## Example: Dry Run Check

```yaml
- name: Check for vulnerabilities
  id: check
  uses: phase2/octane-actions/actions/drupal-security-update@main
  with:
    anthropic_api_key: ${{ secrets.ANTHROPIC_DRUPAL_SECURITY_UPDATES_API_KEY }}
    dry_run: 'true'

- name: Report
  if: steps.check.outputs.has_vulnerabilities == 'true'
  run: echo "Found ${{ steps.check.outputs.vulnerabilities_found }} vulnerabilities"
```

## Example: With Custom Branch Prefix and PR Reviewers

```yaml
- name: Drupal Security Update
  uses: phase2/octane-actions/actions/drupal-security-update@main
  with:
    anthropic_api_key: ${{ secrets.ANTHROPIC_DRUPAL_SECURITY_UPDATES_API_KEY }}
    branch_prefix: 'security/'
    pr_reviewers: 'octocat,hubot'
```

This example:
- Creates branches with the prefix `security/` (e.g., `security/autoupdate-202601311200`)
- Requests review from users `octocat` and `hubot`

> **Downstream contract on the branch name.** The prefix is safe to change, but
> the `autoupdate-` segment is not just cosmetic: `phase2/octane-ci` matches it
> in its Devcloud CI build to decide whether to guard the build against a
> Drupal config export this action cannot perform (it has Composer but no
> containers, so it can never run `drush updb` or `drush cex`). Renaming that
> segment disables that guard with no error on either side. If it ever has to
> change, change `AUTOUPDATE_BRANCH_PATTERN` in octane-ci's Drupal consumers at
> the same time.
>
> Note also that a prefix no downstream repository triggers CI on will silently
> produce PRs that never build. `phase2/octane-ci` projects trigger on
> `issue/**`, which is why `issue/` is the default.

## Example: Explaining caller-specific CI behaviour

`pr_body_footer` is appended to the end of the PR description, after whatever
Claude wrote about the packages. Use it for anything the reviewer needs to know
that is true of the caller's pipeline rather than of the update itself.

```yaml
- name: Drupal Security Update
  uses: phase2/octane-actions/actions/drupal-security-update@main
  with:
    anthropic_api_key: ${{ secrets.ANTHROPIC_DRUPAL_SECURITY_UPDATES_API_KEY }}
    pr_body_footer: |
      ---
      **Note on database updates.** This PR was produced without a container
      suite, so no configuration was exported. If the update carries pending
      database updates, CI will apply them and stop before importing
      configuration rather than reverting what the update hooks wrote.
```

The value is passed through verbatim, and is read from the environment rather
than interpolated into the step's script, so markdown backticks, `$(...)`, and
quotes in the footer are treated as text. Leave it unset to append nothing: the
PR description is then byte for byte what it was before this input existed.

## Example: With Slack Notification

```yaml
- name: Drupal Security Update
  uses: phase2/octane-actions/actions/drupal-security-update@main
  with:
    anthropic_api_key: ${{ secrets.ANTHROPIC_DRUPAL_SECURITY_UPDATES_API_KEY }}
    slack_bot_token: ${{ vars.SLACK_DRUPAL_SECURITY_UPDATES_BOT_TOKEN }}
    slack_channel_id: ${{ secrets.SLACK_CHANNEL_ID }}
```

This example posts a Slack notification when a PR is created.

## Tests

`actions/drupal-security-update/test-pr-body.sh` covers the PR-body assembly in
the `Prepare PR metadata` step: footer append, the guaranteed trailing newline,
verbatim (non-executing) treatment of a hostile footer, and the `autoupdate-`
branch token. It extracts the shipped `run:` block out of `action.yml` rather
than re-implementing it, so it fails if that step drifts.

```bash
bash actions/drupal-security-update/test-pr-body.sh
```

Needs only `bash` and `ruby`. No network, no credentials, no side effects
outside a temp directory.

It runs in CI from `.github/workflows/static-tests.yml`, on every pull request
and on pushes to `main`. That is a separate workflow from `test.yml` on
purpose: `test.yml`'s jobs consume `phase2/octane-actions/actions/*@develop` in
order to exercise the published ref, so they fire only on pushes to `develop`
and `renovate/**`. A test that reads the checked-out tree would never run
there, because `develop` has been dormant since 2024 while pull requests target
`main`.

## Requirements

- PHP and Composer must be installed in the runner environment
- Composer 2.7.0 or newer (the `--minimal-changes` option used by the update commands)
- `jq` must be installed in the runner environment (used to parse audit output)
- The repository must have a `composer.json` file
- GitHub token must have the following permissions:
  - `contents: write` — creating branches, commits, and deleting branches during deduplication
  - `pull-requests: write` — creating and closing PRs, assigning reviewers
  - `issues: write` — applying labels to PRs (GitHub treats PRs as issues for labeling)

## How It Works

1. Runs `composer audit --format=json` to check for security vulnerabilities
2. If vulnerabilities are found:
   - Creates a new branch (using configured prefix, e.g., `issue/autoupdate-YYYYMMDDHHMM`)
   - Invokes Claude AI to perform the updates
   - Claude updates vulnerable packages and handles any patch conflicts
   - Commits changes and creates a pull request (labeled for future deduplication)
   - Requests review from specified users (if configured)
   - Closes any existing open PRs with the same label (if deduplication is enabled)
   - Sends a Slack notification (if configured)
