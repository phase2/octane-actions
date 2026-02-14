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
* `slack_bot_token`: Slack bot OAuth token for posting notifications
* `slack_channel_id`: Slack channel ID to post notification when PR is created

> Outputs:
* `has_vulnerabilities`: Whether security vulnerabilities were found
* `pr_url`: URL of the created pull request (if any)
* `vulnerabilities_found`: Number of vulnerabilities found

Automatically updates Drupal Composer dependencies with security vulnerabilities.
Runs `composer audit` to detect vulnerabilities, then uses Claude to intelligently update
only direct dependencies listed in `composer.json`, handle patch conflicts by searching
drupal.org issue queues, and create a PR with a detailed description of changes.

See [action README](actions/drupal-security-update/README.md) for an example and
required tools expected in runner environment.

---

## Contributing to this repository

When making updates to this repository, be sure to make changes to a local `develop` branch
rather than the `main` branch.  Create a PR for the change. 
Automated test actions will run against the `develop` branch.
