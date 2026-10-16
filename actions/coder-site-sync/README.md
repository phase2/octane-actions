# Coder Site Sync Action

Publishes a Phase2 Coder `static-site` workspace from CI. The workspace builds
the site itself from its source branch; this step asks it to fetch and build
now, waits for the result, and reports which source commit the site serves.

It stores no secrets, needs no repository admin rights, and pushes nothing:
there is no deploy branch and no `contents: write`. The site's side of the
contract is described in the design doc,
[`docs/static-site-ci-publishing.md`](https://github.com/phase2/phase2-coder-prototyping/blob/main/docs/static-site-ci-publishing.md)
in `phase2/phase2-coder-prototyping`. That doc lands with the companion
`static-site` template change, so the link resolves once that PR merges.

## What it does

1. Requests a GitHub Actions OIDC token whose audience is the site's origin
   (`https://<host>`), and masks it in the log.
2. POSTs it as a bearer token to `https://<host>/_hooks/deploy`.
3. The site verifies the token and runs its sync, the same one as the
   workspace's **Sync Now** app: it fetches its `git_branch`, runs its
   `build_command` if it has one, and serves `html_subdir` from the result.
   It waits up to 240 seconds for that, then answers with the source commit
   it now serves (or "still syncing").
4. The action compares that commit with `expected_commit` (by default the
   commit this workflow ran on) and reports the outcome as an annotation, a
   job summary line and the step outputs. If the build failed, the tail of
   its log appears in this step's log.

## Why it is built this way

The `static-site` template can already sync on a GitHub push webhook, but
that needs someone with admin rights on the repository to register the
webhook, and a shared secret stored on both sides. This action replaces both
with an OIDC token:

- **Nothing secret is stored.** GitHub mints the token for this job only. It
  expires within minutes, and it is useless anywhere but the one site named
  in its audience.
- **No repository admin, and nothing pushed.** Any workflow with
  `id-token: write` can request a token, and the site builds from the source
  branch it already tracks, so the workflow needs only `contents: read`.
- **A failed sync or build turns the run red, when it finishes within the
  site's wait.** The site waits up to 240 seconds for the sync and build and
  returns the served commit, instead of answering 202 and syncing later, so a
  build that breaks within that time fails the workflow (with its log tail)
  rather than going unnoticed. A slower build answers `syncing` and the step
  passes with a warning; its outcome then shows only in the workspace's
  **Build Log** app. The site keeps serving its previous version when a
  build fails.

## Trust model

The site checks, in order, and stops at the first failure:

1. Its `ci_trigger` parameter is on, and its `git_repo` is a GitHub URL.
2. The token's signature, against GitHub's published signing keys.
3. The issuer is `https://token.actions.githubusercontent.com`.
4. The token is within its validity times.
5. The audience is the site's own origin. A token minted for another site is
   refused.
6. The `repository` claim equals the repository in the site's `git_repo`
   (compared case-insensitively). A token from any other repository is
   refused.

The only repository allowed to trigger a sync is the one the site already
serves, chosen by the workspace owner, so the trigger grants no access the
owner had not already given.

## Site setup

The workspace owner sets these `static-site` parameters:

| Parameter | Set it to |
| --- | --- |
| `ci_trigger` | Ticked ("Let GitHub Actions in this repository trigger a sync") |
| `git_repo` | The GitHub URL of the repository, `https://github.com/<owner>/<name>` |
| `git_branch` | The source branch to publish, for example `main` |
| `build_command` | The command that builds the site, for example `npm ci && npm run build`. Empty means no build: the branch is served as is. |
| `html_subdir` | The directory to serve, relative to the repository root, for example `prototypes/dist` |

`auto_deploy` ("Update on push") can stay off: this action triggers the sync
instead of a webhook.

## Workflow requirements

- The calling job needs `permissions: id-token: write` (plus
  `contents: read` for checkout). Without `id-token: write` the runner
  provides no token and the step fails with `no_oidc_token`. Workflows
  triggered from forks never receive one.
- Run it on a `push` to the site's `git_branch`, or on `workflow_dispatch`
  from that branch. `expected_commit` defaults to `github.sha`, the commit the
  workflow ran on. On `pull_request` events `github.sha` is a merge commit the
  site never serves, so expect `commit_mismatch` there.
- The runner needs `bash`, `curl`, `jq`, `awk` and `od`, which
  `ubuntu-latest` and Phase2's self-hosted runners have.

## Usage

Pin the action to a commit SHA. This repository has no release tags, so a
branch reference such as `@main` changes under you.

```yaml
on:
  push:
    branches: [main]   # the site's git_branch
  workflow_dispatch:

jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      contents: read    # checkout
      id-token: write   # mint the OIDC token for the site
    steps:
      - uses: actions/checkout@v4

      # Optional gate: build in CI first, so a broken build fails here with
      # the full log, before the site is asked to build it.
      - name: Build
        run: npm ci && npm run build

      - name: Sync the Coder site
        id: sync
        uses: phase2/octane-actions/actions/coder-site-sync@<commit-sha>
        with:
          site_url: https://my-prototype.cloud.phase2.ai
```

To fall back when a site is not CI-enabled yet, test `enabled` in a later
step. A site with no trigger route (for example `ci_trigger` off) passes with
a warning, but one whose trigger is reachable while the workspace's running
configuration has it off (`not_enabled`) **fails** the step, and a failed
step skips the steps after it. Give the fallback step a status
function, or set `continue-on-error: true` on the sync step:

```yaml
      - name: Fall back to Sync Now
        if: ${{ !cancelled() && steps.sync.outputs.enabled == 'false' }}
        run: echo "Ask the workspace owner to press Sync Now."
```

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `site_url` | yes | | The site's public URL, `https://<host>`, with or without a trailing slash. No path or port. The token's audience is the lowercase origin. |
| `expected_commit` | no | `${{ github.sha }}` | Full 40-character SHA of the source commit the site should serve. An explicit empty value also falls back to `github.sha`. A different served commit warns (`commit_mismatch`) but passes. |
| `timeout_seconds` | no | `300` | Overall time limit for the sync request. The site waits up to 240 seconds for its fetch and build before answering `syncing`, so values below 255 can turn that answer into a `timeout` failure; the step warns when the value is below 255. |

## Outputs

| Output | Description |
| --- | --- |
| `enabled` | `true` when the site's sync trigger answered, `false` when the site is not CI-enabled, empty when the trigger could not be reached (bad input, missing tool, no token, timeout, unreachable, `site_unavailable`). |
| `commit` | The source commit the site serves, when it reported one. |
| `status` | One word for the outcome, from the tables below. |

## Responses

Responses from the site's trigger are always JSON with a known `status` or
`error` value for each HTTP status code. Anything else came from something in
front of the trigger, and the action tells the two apart by both the code and
the body.

| Site answers | `status` | Step result | `enabled` |
| --- | --- | --- | --- |
| 200 `synced`, commit equals `expected_commit` | `synced` | success (notice) | `true` |
| 200 `synced`, a different commit | `commit_mismatch` | success (warning) | `true` |
| 200 `synced` without a valid commit | `invalid_response` | **fails** | `true` |
| 202 `syncing` (the sync or build outlasted the site's 240 s wait) | `syncing` | success (warning) | `true` |
| 400 `bad_request` | `bad_request` | **fails** | `true` |
| 401 `invalid_token` | `invalid_token` | **fails** | `true` |
| 403 `wrong_audience` | `wrong_audience` | **fails** | `true` |
| 403 `wrong_repository` | `wrong_repository` | **fails** | `true` |
| 404 `not_enabled` (trigger reachable, but off in the workspace's running configuration) | `not_enabled` | **fails** | `false` |
| 405 `method_not_allowed` | `method_not_allowed` | **fails** | `true` |
| 500 `sync_failed` (fetch or checkout failed) | `sync_failed` | **fails** | `true` |
| 500 `build_failed` (build failed, timed out, or produced no `index.html`; the previous site is still served) | `build_failed` | **fails**, log tail in a collapsed group | `true` |
| 503 `jwks_unavailable` | `jwks_unavailable` | **fails** | `true` |
| Not the trigger's JSON, HTTP 502, 503 or 504 (the Coder gateway: workspace not running, or its trigger down or timed out) | `site_unavailable` | **fails** | empty |
| Not the trigger's JSON, any other code (a 3xx to the login page, an auth or nginx 401/403/404/405 page) | `not_ci_enabled` | success (warning) | `false` |

Failures before or instead of a response:

| Situation | `status` | Step result |
| --- | --- | --- |
| `curl`, `jq`, `awk` or `od` is not installed (for example in a slim container job) | `missing_tool` | **fails** |
| `site_url`, `expected_commit` (or `GITHUB_SHA`) or `timeout_seconds` is malformed | `invalid_input` | **fails** |
| No OIDC token (missing `id-token: write`, or the runtime refused) | `no_oidc_token` | **fails** |
| No answer within `timeout_seconds` (see that input for values below 255) | `timeout` | **fails** |
| Connection or DNS failure | `unreachable` | **fails** |

`bad_request` and `method_not_allowed` should never happen, since the action
always sends an empty POST; they point at a bug on one side.

## Troubleshooting

- **"Site not CI-enabled yet"** (`not_ci_enabled`). The request reached the
  site's access gate or web server instead of the sync trigger. Either the
  workspace was built from a template without the trigger (rebuild it), or
  `ci_trigger` is off or `git_repo` is not a GitHub URL, in which case the
  workspace says why. The step still passes so you can fall back: the owner
  can press **Sync Now**, or run `/var/www/bin/sync` over `coder ssh`.
- **Build failed** (`build_failed`). The site's `build_command` failed, timed
  out, or left no `index.html` in `html_subdir`; the site still serves its
  previous version. Expand the "Build log tail" group in this step's log for
  the last lines, and read the full build output in the workspace's
  **Build Log** app (**Sync Log** has only a one-line summary per build).
  Building in CI before this step catches most of these earlier.
- **Commit mismatch** (`commit_mismatch`). The site serves a different
  commit than this run's. Usually a newer push landed on the branch between
  checkout and sync (the site serves the newer one, and its own run will
  report it), the workflow ran on a branch other than the site's
  `git_branch`, or it ran on a `pull_request` merge commit. The message
  names the expected commit's source: `expected_commit`, or
  `expected_commit, default github.sha`.
- **Trigger off** (`not_enabled`). The trigger route answered, but the
  workspace's running configuration has it off. Check that `ci_trigger` is
  ticked and `git_repo` is this repository's GitHub URL, then restart or
  rebuild the workspace: changes to those parameters take effect only then.
- **Wrong repository** (`wrong_repository`). The site's `git_repo` names a
  different repository from the one running this workflow. Point `git_repo`
  at this repository, or run the workflow from the repository it names.
- **Wrong audience** (`wrong_audience`). `site_url` does not match the URL the
  site serves on. Use the site's public URL exactly, with no path.
- **Site unavailable** (`site_unavailable`). The Coder gateway answered 502,
  503 or 504 instead of the trigger: the workspace is not running, or it is
  but its sync trigger is down or did not answer in time. Check the
  workspace's **Sync Log** app; starting or restarting the workspace
  restarts the trigger. Then re-run the job.
- **Sync failed** (`sync_failed`). The site could not fetch or check out its
  branch. Open the workspace's **Sync Log** app.
- **Still syncing** (`syncing`). The fetch and build took longer than the
  site's 240-second wait. They continue in the background and the site
  switches over when the build finishes. Follow the build in the workspace's
  **Build Log** app, and check **Sync Log** if the content does not update.
- **`no_oidc_token`**. Add `permissions: id-token: write` to the job. A job
  level `permissions:` block replaces the workflow's, so include it there too.

## Design notes worth knowing before you change it

- **Redirects are never followed.** When the trigger route is absent, the
  site's access gate answers with a redirect to its login page. Following it
  would replay the bearer token to the redirect target and turn a clear "not
  CI-enabled" answer into an HTML 200. Outside tests the request is also held
  to https.
- **The token is never printed or put on a command line.** It is masked as
  soon as it is received. Both bearer tokens (the runtime's request token and
  the OIDC token) reach `curl` on stdin, not in its arguments, where other
  processes on a shared runner could read them.
- **A runner's `.curlrc` is ignored.** Both `curl` calls pass `-q` first, so
  a `.curlrc` cannot add `--location` (replaying the token on a redirect) or
  `--verbose` (printing the request headers).
- **Server text is escaped before it reaches an annotation or the summary.**
  The `detail` of a failure comes from the workspace. In the annotation its
  newlines are escaped, so it cannot issue workflow commands of its own; in
  the job summary control characters collapse to spaces and HTML and
  Markdown are escaped, so it shows literally.
- **The build log tail is printed as inert text.** It is whatever the
  project's build printed, so it could contain lines that look like workflow
  commands. It is printed inside `::stop-commands::` with a fresh 128-bit
  random token, which suspends all command processing until the token is
  repeated. Independently, every line carries a `| ` prefix so none starts
  with `::`, and `##[` (which the runner's legacy parser finds anywhere in a
  line) is shown as `## [`, so either guard alone keeps the tail inert. ANSI
  escape sequences and control characters are removed, and at most the last
  40 lines (4096 characters) are shown.
- **`expected_commit` defaults twice.** The input defaults to `github.sha`
  (as `require-checks` and `attest-check` default their `sha`), and the
  script falls back to the runner's `GITHUB_SHA` when the input arrives
  empty, for example from an unset step output.
- **The response contract is shared** with the site's handler. Change both
  sides together.

## Tests

```bash
bash actions/coder-site-sync/test-sync.sh
```

The test runs `sync.sh` unmodified against `test-stub-server.js`, a local
stub of both the Actions OIDC endpoint and a site, covering every response
above plus input validation, the `GITHUB_SHA` default, token handling,
redaction, and a hostile build log tail checked against a model of the
runner's command parsing. It also checks that `action.yml` wires every input
and output, and that this README documents every status. It needs `bash`,
`curl`, `jq`, `node` and `ruby`, and runs in the Static Tests workflow.

Because production requires https, `sync.sh` accepts plain http only for a
loopback host when `CODER_SITE_SYNC_TEST_ALLOW_LOOPBACK_HTTP=1` is set **and**
`GITHUB_ACTIONS` is not `true`. Inside any workflow run the flag has no
effect, and even outside one the token could only go back to the same
machine.
