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

## Usage

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

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `anthropic_api_key` | Anthropic API key for Claude | Yes | - |
| `github_token` | GitHub token for creating branches and PRs | No | `github.token` |
| `working_directory` | Directory containing composer.json | No | `.` |
| `base_branch` | Base branch for the PR | No | `main` |
| `dry_run` | Check for vulnerabilities without creating PR | No | `false` |

## Outputs

| Output | Description |
|--------|-------------|
| `has_vulnerabilities` | Whether security vulnerabilities were found |
| `pr_url` | URL of the created pull request (if any) |
| `vulnerabilities_found` | Number of vulnerabilities found |

## Example: Dry Run Check

```yaml
- name: Check for vulnerabilities
  id: check
  uses: phase2/drupal-security-update-action@v1
  with:
    anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
    dry_run: 'true'

- name: Report
  if: steps.check.outputs.has_vulnerabilities == 'true'
  run: echo "Found ${{ steps.check.outputs.vulnerabilities_found }} vulnerabilities"
```

## Requirements

- PHP and Composer must be installed in the runner environment
- The repository must have a `composer.json` file
- GitHub token must have permissions to create branches and pull requests

## How It Works

1. Runs `composer audit --format=json` to check for security vulnerabilities
2. If vulnerabilities are found:
   - Creates a new branch (`issue/autoupdate-YYYYMMDDHHMM`)
   - Invokes Claude AI to perform the updates
   - Claude updates vulnerable packages and handles any patch conflicts
   - Commits changes and creates a pull request
