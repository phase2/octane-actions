# Octane CI Actions

This repository holds the public composite actions used within Octane projects.

---

## load-env
> Usage: 
* `phase2/octane-actions/actions/load-env@main`

> Example:
```
  jobname:
    name: Do something
    runs-on: self-hosted
    steps:
      - name: Load environment variables
        uses: phase2/octane-actions/actions/load-env@main

      ...do other stuff...
```

Loads the `.env` file into the environment variables and also sets several other
global environment variables: `CI_REGISTRY`, `CI_URL`, `CI_BRANCH`, `WEB_IMAGE`.
Also overrides the config/cache paths for tools like `helm` and `yarn` to prevent
projects in the same Github runner from colliding.

---

## detect-pod
> Usage: 
* `phase2/octane-actions/actions/detect-pod@main`
> Inputs: 
* `kubeconfig`: the KUBE_CONFIG secret for accessing the Devcloud
* `release_name`: the release_name annotation of the pod, uses the current branch and project name by default.

> Example:
```
  detect:
    name: Detect pod is running
    runs-on: self-hosted
    outputs:
      pod: ${{ steps.detect-pod.outputs.pod-status }}
    steps:
      - name: Find Devcloud pod
        uses: phase2/octane-actions/actions/detect-pod@main
        id: detect-pod
        with:
          kubeconfig: ${{ secrets.KUBE_CONFIG }}

...

  deploy:
    name: Deploy site
    needs: [detect]
    if: ${{ needs.detect.outputs.pod != 'True' }}
    steps:
      ...do deploy stuff...
```

Determine if a pod is running in the Devcloud. Sets the output to "True" if the pod exists and has the status of "Running"

---

## add-pr-url
> Usage: 
* `phase2/octane-actions/actions/add-pr-url@main`
> Inputs: 
* `url`: the URL to add to the PR description
* `caption`: Optional caption for the link.  Defaults to using the URL as the caption.

> Example:
```
  build:
    name: Do the build
    runs-on: self-hosted
    steps:

      ... Build stuff here ...

      - name: Set URL_ENV
        run: .octane-ci/scripts/release-name.sh
      - name: Add environment link to pull request comment
        uses: phase2/octane-actions/actions/add-pr-url@main
        if: ${{ env.URL_ENV }}
        with:
          url: ${{ env.URL_ENV }}
          caption: View Drupal site
```

Adds a link to the specified URL to the end of the description text for the related pull request.

## publish
> Usage: 
* `phase2/octane-actions/actions/publish@main`
> Inputs: 
* `project_name`: the project name
* `source`: the source path to the content to publish
* `dest`: the destination path in the Pages server
* `kubeconfig`: the ${{ secrets.PAGES_KUBE }} kubernetes config

> Example:
```
- name: Publish content to Pages
  uses: phase2/octane-actions/actions/publish@main
  with:
    project_name: ${{ env.PROJECT_NAME }}
    source: SOURCE_PATH
    dest: DEST_PATH
    kubeconfig: ${{ secrets.PAGES_KUBE }}
```
Publish a folder of static content to the Phase2 Pages server,
where the `SOURCE_PATH` is the relative path from your project repo root to the files you want to publish and
`DEST_PATH` is the subfolder/path you want to make available on the Pages server.

The URL of your pages will be exported to the `PAGES_URL` environment variable.

**NOTE:** *Can only be called from with a private Phase2 repository.*

## remove-pages
> Usage: 
* `phase2/octane-actions/actions/remove-pages@main`
> Inputs: 
* `project_name`: the project name
* `dest`: the destination path in the Pages server
* `kubeconfig`: the ${{ secrets.PAGES_KUBE }} kubernetes config

> Example:
```
- name: Remove content from Pages
  uses: phase2/octane-actions/actions/remove-pages@main
  with:
    project_name: ${{ env.PROJECT_NAME }}
    dest: DEST_PATH
    kubeconfig: ${{ secrets.PAGES_KUBE }}
```
Remove content from the Pages server,
where `DEST_PATH` is the subfolder/path you want to remove for the given project.

**NOTE:** *Can only be called from with a private Phase2 repository.*

## reset-workspace-owner
> Usage:
* `phase2/octane-actions/actions/reset-workspace-owner@main`
> Inputs:
* `user_id`: optional user ID to set file ownership.  Defaults to 1000.

This action is used to clean up file ownership in the Github runner workspace and home folder.
Some containers that run as root can leave behind files owned by root that can cause
errors when checking out code.

---

## drupal-security-update
> Usage:
* `phase2/octane-actions/actions/drupal-security-update@main`
> Inputs:
* `anthropic_api_key`: (required) Anthropic API key for Claude
* `github_token`: GitHub token for creating branches and PRs. Defaults to `github.token`
* `working_directory`: Directory containing composer.json. Defaults to `.`
* `base_branch`: Base branch for the PR. Defaults to `main`
* `dry_run`: Check for vulnerabilities without creating PR. Defaults to `false`
* `branch_prefix`: Prefix for the created branch name. Defaults to `issue/`
* `pr_reviewers`: Comma-separated list of GitHub usernames to request review from
* `pr_label`: Label applied to PRs for deduplication. Set to empty string to disable. Defaults to `drupal-security-update`
* `deduplicate_prs`: If true, close existing open PRs with the same label before creating a new one. Defaults to `true`. Requires pr_label not be disabled.
* `slack_bot_token`: Slack bot OAuth token for posting notifications
* `slack_channel_id`: Slack channel ID to post notification when PR is created
* `slack_errors`: If true, fail the workflow when Slack notification fails. Defaults to `false`

> Outputs:
* `has_vulnerabilities`: Whether security vulnerabilities were found
* `pr_url`: URL of the created pull request (if any)
* `vulnerabilities_found`: Number of vulnerabilities found
* `pr_action`: Action taken for PR (`create` or `supersede`)
* `superseded_pr`: PR number(s) that were superseded (comma-separated if multiple)

Automatically updates Drupal Composer dependencies with security vulnerabilities.
Runs `composer audit` to detect vulnerabilities, then uses Claude to intelligently update
only direct dependencies listed in `composer.json`, handle patch conflicts by searching
drupal.org issue queues, and create a PR with a detailed description of changes.

See [action README](actions/drupal-security-update/README.md) for an example and
required tools expected in runner environment.

---

## require-checks
> Usage:
* `phase2/octane-actions/actions/require-checks@main`
> Inputs:
* `requirements`: (required) Requirement groups, one per line, as `<group>: <check> | <check> | ...`. A group is satisfied when any of its checks concluded `success` for the commit. Prefix a check with a GitHub App id (`<app_id>/<check>`) to accept it only from that app; the gate's summary lists the app id of each check it considered.
* `sha`: Commit to evaluate. Defaults to `github.sha`
* `github_token`: Token to read check runs and write the gate check. Defaults to `github.token`
* `waiver_name_prefix`: Checks with this prefix satisfy a group but are reported as WAIVED. Defaults to `waiver-`
* `gate_check_name`: Name of the check run recording the decision. Empty skips it (and the need for `checks:write`). Defaults to `deployment-gate`

> Outputs:
* `satisfied`: `'true'` when every group was satisfied or waived
* `waived_requirements`: Comma-separated groups that passed only by waiver

> Example:
```
- name: Verify every requirement for this commit
  uses: phase2/octane-actions/actions/require-checks@main
  with:
    requirements: |
      testing: run-tests | manual-test-evidence | waiver-testing
      vulnerability: dependency-audit | waiver-vulnerability
```

Gates a deployment on check runs already recorded against the commit, rather than re-running them. Fails the step when any group is unsatisfied or pending. Requires `checks: write` unless `gate_check_name` is empty.

---

## attest-check
> Usage:
* `phase2/octane-actions/actions/attest-check@main`
> Inputs:
* `check_name`: (required) Name of the check run to create. `waiver-<group>` is treated by `require-checks` as an accepted exception by default.
* `statement`: (required) What is being asserted, or why the exception is acceptable
* `evidence_url`: Link to supporting evidence
* `evidence_label`: Link text for `evidence_url`. Defaults to `Evidence`
* `sha`: Commit the attestation binds to. Defaults to `github.sha`
* `github_token`: Token with `checks:write`. Defaults to `github.token`

> Outputs:
* `check_run_id`: Id of the created check run
* `check_run_url`: URL of the created check run

> Example:
```
- uses: phase2/octane-actions/actions/attest-check@main
  with:
    check_name: manual-test-evidence
    statement: ${{ inputs.statement }}
    evidence_url: ${{ inputs.evidence_url }}
    evidence_label: Test results
```

Records a manual attestation or waiver as a successful check run, including who triggered it, so it can satisfy a `require-checks` group.

---

## Contributing to this repository

When making updates to this repository, be sure to make changes to a local `develop` branch
rather than the `main` branch.  Create a PR for the change. 
Automated test actions will run against the `develop` branch.
