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
- **RSS Feed Monitoring**: Optionally check Drupal security RSS feeds for new advisories before running
- **PR Deduplication**: Automatically detects and handles existing security PRs via the `drupal-security-update` label (skip identical, supersede safely)
- **Notifications**: Assign PR reviewers and send Slack notifications when PRs are created

## Usage

Note usage examples demonstrate use of Phase2 organization level secret for anthropic_api_key.
You should not need to configure a project-level key for projects in the Phase2 organization.

### Basic Usage

```yaml
name: Drupal Security Update Action

on:
  schedule:
    - cron: '0 17 * * 3'  # Every Wednesday in the security update window
  workflow_dispatch:

jobs:
  security-update:
    runs-on: self-hosted
    container:
      image: ghcr.io/phase2/docker-cli:php8.3
      options: --user 1000
    permissions:
      contents: write
      pull-requests: write
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

### With RSS Feed Checking and Notifications

This example uses frequent polling during the Drupal security release window (Wednesdays 16:00-22:00 UTC) with stateful RSS monitoring to detect new advisories:

```yaml
name: Drupal Security Update Action

on:
  schedule:
    # Every 15 minutes during Wednesday security window (16:00-22:00 UTC)
    - cron: '*/15 16-21 * * 3'
  workflow_dispatch:

jobs:
  security-update:
    runs-on: self-hosted
    container:
      image: ghcr.io/phase2/docker-cli:php8.3
      options: --user 1000
    permissions:
      contents: write
      pull-requests: write
      actions: write  # Required for RSS state variable
    steps:
      - uses: actions/checkout@v4
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          persist-credentials: false
      - name: Drupal Security Update
        uses: phase2/octane-actions/actions/drupal-security-update@main
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_DRUPAL_SECURITY_UPDATES_API_KEY }}
          check_rss_first: 'true'
          assign_admin_reviewers: 'true'
          slack_webhook: ${{ secrets.SLACK_WEBHOOK }}
          slack_channel: 'drupal-security'
```

### With Additional Reviewers

```yaml
- name: Drupal Security Update
  uses: phase2/octane-actions/actions/drupal-security-update@main
  with:
    anthropic_api_key: ${{ secrets.ANTHROPIC_DRUPAL_SECURITY_UPDATES_API_KEY }}
    assign_admin_reviewers: 'true'
    additional_reviewers: 'lead-dev,security-team-lead'
    slack_webhook: ${{ secrets.SLACK_WEBHOOK }}
    slack_channel: 'security-alerts'
```

## Inputs

### Core Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `anthropic_api_key` | Anthropic API key for Claude | Yes | - |
| `github_token` | GitHub token for creating branches and PRs | No | `github.token` |
| `working_directory` | Directory containing composer.json | No | `.` |
| `base_branch` | Base branch for the PR | No | `main` |
| `dry_run` | Check for vulnerabilities without creating PR | No | `false` |

### RSS Feed Checking Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `check_rss_first` | Check Drupal security RSS feeds before running | No | `false` |
| `rss_feeds` | Comma-separated RSS feed URLs to check | No | Core and contrib feeds |
| `rss_state_variable` | Name of repo variable to store RSS state | No | `DRUPAL_SECURITY_RSS_STATE` |

### Notification Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `slack_webhook` | Slack webhook URL for notifications | No | - |
| `slack_channel` | Slack channel name (without #) | No | - |
| `assign_admin_reviewers` | Assign repository admins as PR reviewers | No | `false` |
| `additional_reviewers` | Comma-separated list of GitHub usernames | No | - |

## Outputs

### Core Outputs

| Output | Description |
|--------|-------------|
| `has_vulnerabilities` | Whether security vulnerabilities were found |
| `pr_url` | URL of the created pull request (if any) |
| `vulnerabilities_found` | Number of vulnerabilities found |

### RSS Check Outputs

| Output | Description |
|--------|-------------|
| `new_advisories_found` | Whether new security advisories were found in RSS feeds |
| `skipped_no_advisories` | Whether the action was skipped due to no new advisories |

### PR Deduplication Outputs

| Output | Description |
|--------|-------------|
| `pr_action` | Action taken for PR (create, skip, supersede) |
| `superseded_pr` | PR number that was superseded (if any) |

### Notification Outputs

| Output | Description |
|--------|-------------|
| `reviewers_assigned` | Comma-separated list of reviewers assigned to the PR |
| `slack_notification_sent` | Whether Slack notification was sent successfully |

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

## Requirements

- PHP and Composer must be installed in the runner environment
- The repository must have a `composer.json` file
- GitHub token must have permissions to create branches and pull requests

### Permissions

The workflow using this action needs these permissions:

```yaml
permissions:
  contents: write       # For creating branches and commits
  pull-requests: write  # For creating PRs and assigning reviewers
  issues: write         # For applying/creating labels (PRs are issues)
  actions: write        # Only if using RSS state tracking (check_rss_first: 'true')
```

## How It Works

1. **RSS Check (optional)**: If `check_rss_first` is enabled, checks Drupal security RSS feeds for new advisories. Uses a GitHub repository variable to track previously seen advisory IDs, ensuring the action only runs when new advisories are published.

2. **Vulnerability Detection**: Runs `composer audit --format=json` to check for security vulnerabilities.

3. **AI-Powered Updates**: If vulnerabilities are found:
   - Creates a new branch (`issue/autoupdate-YYYYMMDDHHMM`)
   - Invokes Claude AI to perform the updates
   - Claude updates vulnerable packages and handles any patch conflicts

4. **PR Deduplication**: Before creating a PR, checks for existing security update PRs:
   - Identifies candidates by the `drupal-security-update` label (fork PRs are ignored)
   - **Skip**: If an identical PR already exists
   - **Supersede (safe)**: If the new PR includes all the files from an existing PR **and** the diffs for those overlapping files are identical (then closes the old PR with a comment)
   - **Create**: If the changes are different from existing PRs

5. **Notifications**: After creating a PR:
   - Assigns repository admins and/or specified reviewers (triggers GitHub email notifications)
   - Sends a Slack notification to the configured channel

## Drupal Security Release Schedule

Drupal security advisories are released on a predictable schedule:
- **Drupal Core**: Third Wednesday of each month
- **Contributed Projects**: Every Wednesday
- **Time Window**: 16:00-22:00 UTC (12:00-18:00 Eastern)

For near real-time response, use the RSS checking feature with frequent polling during the Wednesday security window.
