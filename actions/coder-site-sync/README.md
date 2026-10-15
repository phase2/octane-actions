# Coder Site Sync Action

Publishes static build output to a Phase2 Coder `static-site` workspace from
CI. Your workflow pushes the built files to a deploy branch; this step asks
the site to pull that branch now, and fails the run unless the site then
serves the commit you pushed.

It stores no secrets and needs no repository admin rights. The site's
contract and handler are described in the design doc,
[`docs/static-site-ci-publishing.md`](https://github.com/phase2/phase2-coder-prototyping/blob/main/docs/static-site-ci-publishing.md)
in `phase2/phase2-coder-prototyping`. That doc lands with the companion
`static-site` template change, so the link resolves once that PR merges.

## What it does

1. Requests a GitHub Actions OIDC token whose audience is the site's origin
   (`https://<host>`), and masks it in the log.
2. POSTs it as a bearer token to `https://<host>/_hooks/deploy`.
3. The site verifies the token, runs its existing sync (the same one as the
   workspace's **Sync Now** app), waits up to 50 seconds for it, and answers
   with the commit it now serves.
4. The action compares that commit with `expected_commit` and reports the
   outcome as an annotation, a job summary line and the step outputs.

## Why it is built this way

The `static-site` template already syncs on a GitHub push webhook, but that
needs someone with admin rights on the repository to register the webhook,
and a shared secret stored on both sides. This action replaces both with an
OIDC token:

- **Nothing secret is stored.** GitHub mints the token for this job only. It
  expires within minutes, and it is useless anywhere but the one site named
  in its audience.
- **No repository admin.** Any workflow with `id-token: write` can request a
  token; nobody has to register a webhook.
- **A failed sync turns the run red.** The site waits for the sync and
  returns the served commit, instead of answering 202 and syncing later, so a
  sync that fails or serves the wrong branch fails the workflow rather than
  going unnoticed.

## Trust model

The site checks, in order, and stops at the first failure:

1. The token's signature, against GitHub's published signing keys.
2. The issuer is `https://token.actions.githubusercontent.com`.
3. The token is within its validity times.
4. The audience is the site's own origin. A token minted for another site is
   refused.
5. The `repository` claim equals the site's `deploy_repo` parameter. A token
   from any other repository is refused.

`deploy_repo` names the one repository allowed to trigger a sync. It is set
by the workspace owner, who already controls which repository the site
serves, so the trigger grants no access the owner had not already given.

## Site setup

The workspace owner sets these `static-site` parameters:

| Parameter | Set it to |
| --- | --- |
| `git_repo` | The repository the site serves from |
| `git_branch` | The deploy branch your workflow pushes to, for example `prototypes-site` |
| `html_subdir` | The directory within that branch to serve, if not its root |
| `deploy_repo` | The `owner/name` of the repository whose workflow runs this action |

`auto_deploy` ("Update on push") can stay off: this action triggers the sync
instead of a webhook.

## Workflow requirements

- The calling job needs `permissions: id-token: write`. Without it the
  runner provides no token and the step fails with `no_oidc_token`. Workflows
  triggered from forks never receive one.
- Push the built output to the deploy branch first, then pass that pushed
  commit as `expected_commit`. Do not pass `github.sha`: it is the source
  commit, not the deploy-branch commit, so it would never match.
- The runner needs `bash`, `curl` and `jq`, which `ubuntu-latest` and
  Phase2's self-hosted runners have.

## Usage

Pin the action to a commit SHA. This repository has no release tags, so a
branch reference such as `@main` changes under you.

```yaml
jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      contents: write   # push the deploy branch
      id-token: write   # mint the OIDC token for the site
    steps:
      - uses: actions/checkout@v4

      - name: Build
        run: npm ci && npm run build

      - name: Push dist/ to the deploy branch
        id: push
        env:
          GIT_AUTHOR_NAME: github-actions[bot]
          GIT_AUTHOR_EMAIL: 41898282+github-actions[bot]@users.noreply.github.com
          GIT_COMMITTER_NAME: github-actions[bot]
          GIT_COMMITTER_EMAIL: 41898282+github-actions[bot]@users.noreply.github.com
        run: |
          git add --force dist
          tree="$(git write-tree --prefix=dist/)"
          commit="$(git commit-tree "$tree" -m "Publish ${GITHUB_SHA}")"
          git push --force origin "${commit}:refs/heads/prototypes-site"
          echo "commit=${commit}" >> "$GITHUB_OUTPUT"

      - name: Sync the Coder site
        id: sync
        uses: phase2/octane-actions/actions/coder-site-sync@<commit-sha>
        with:
          site_url: https://my-prototype.cloud.phase2.ai
          expected_commit: ${{ steps.push.outputs.commit }}
```

Any way of pushing the deploy branch works; what matters is passing the
commit you pushed.

To fall back when a site is not CI-enabled yet, test `enabled` in a later
step. A site with no trigger route passes with a warning, but one whose
trigger is present with `deploy_repo` empty (`not_enabled`) **fails** the
step, and a failed step skips the steps after it. Give the fallback step a
status function, or set `continue-on-error: true` on the sync step:

```yaml
      - name: Fall back to Sync Now
        if: ${{ !cancelled() && steps.sync.outputs.enabled == 'false' }}
        run: echo "Ask the workspace owner to press Sync Now."
```

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `site_url` | yes | | The site's public URL, `https://<host>`, with or without a trailing slash. No path or port. The token's audience is the lowercase origin. |
| `expected_commit` | no | empty | Full 40-character SHA of the deploy-branch commit you pushed. When empty, any successful sync passes and the served commit is reported. |
| `timeout_seconds` | no | `60` | Overall time limit for the sync request. The site answers within about 50 seconds (with `syncing` if its sync is not done), so values below 55 can turn that answer into a `timeout` failure; the step warns when the value is below 55. |

## Outputs

| Output | Description |
| --- | --- |
| `enabled` | `true` when the site's sync trigger answered, `false` when the site is not CI-enabled, empty when the trigger could not be reached (bad input, missing tool, no token, timeout, unreachable, `site_unavailable`). |
| `commit` | The commit the site serves, when it reported one. |
| `status` | One word for the outcome, from the table below. |

## Responses

Responses from the site's trigger are always JSON with a known `status` or
`error` value for each HTTP status code. Anything else came from something in
front of the trigger, and the action tells the two apart by both the code and
the body.

| Site answers | `status` | Step result | `enabled` |
| --- | --- | --- | --- |
| 200 `synced`, commit equals `expected_commit` (or none expected) | `synced` | success (notice) | `true` |
| 200 `synced`, a different commit | `mismatch` | **fails** | `true` |
| 200 `synced` without a valid commit | `invalid_response` | **fails** | `true` |
| 202 `syncing` (the sync outlasted the site's wait) | `syncing` | success (warning) | `true` |
| 400 `bad_request` | `bad_request` | **fails** | `true` |
| 401 `invalid_token` | `invalid_token` | **fails** | `true` |
| 403 `wrong_audience` | `wrong_audience` | **fails** | `true` |
| 403 `wrong_repository` | `wrong_repository` | **fails** | `true` |
| 404 `not_enabled` (trigger present, `deploy_repo` empty) | `not_enabled` | **fails** | `false` |
| 405 `method_not_allowed` | `method_not_allowed` | **fails** | `true` |
| 500 `sync_failed` | `sync_failed` | **fails** | `true` |
| 503 `jwks_unavailable` | `jwks_unavailable` | **fails** | `true` |
| Not the trigger's JSON, HTTP 502, 503 or 504 (the Coder gateway: workspace not running, or its trigger down or timed out) | `site_unavailable` | **fails** | empty |
| Not the trigger's JSON, any other code (a 3xx to the login page, an auth or nginx 401/403/404/405 page) | `not_ci_enabled` | success (warning) | `false` |

Failures before or instead of a response:

| Situation | `status` | Step result |
| --- | --- | --- |
| `curl` or `jq` is not installed (for example in a slim container job) | `missing_tool` | **fails** |
| `site_url`, `expected_commit` or `timeout_seconds` is malformed | `invalid_input` | **fails** |
| No OIDC token (missing `id-token: write`, or the runtime refused) | `no_oidc_token` | **fails** |
| No answer within `timeout_seconds` (see that input for values below 55) | `timeout` | **fails** |
| Connection or DNS failure | `unreachable` | **fails** |

`bad_request` and `method_not_allowed` should never happen, since the action
always sends an empty POST; they point at a bug on one side.

## Troubleshooting

- **"Site not CI-enabled yet"** (`not_ci_enabled`). The request reached the
  site's access gate or web server instead of the sync trigger. Either the
  workspace was built from a template without the trigger (rebuild it), or
  `deploy_repo` is empty. The step still passes so you can fall back: the
  owner can press **Sync Now**, or run `/var/www/bin/sync` over `coder ssh`.
- **Wrong repository** (`wrong_repository`). `deploy_repo` on the workspace
  names a different repository. The owner sets it to the `owner/name` of the
  repository running this workflow (compared case-insensitively).
- **Wrong audience** (`wrong_audience`). `site_url` does not match the URL the
  site serves on. Use the site's public URL exactly, with no path.
- **Site unavailable** (`site_unavailable`). The Coder gateway answered 502,
  503 or 504 instead of the trigger: the workspace is not running, or it is
  but its sync trigger is down or did not answer in time. Check the
  workspace's **Sync Log** app; starting or restarting the workspace
  restarts the trigger. Then re-run the job.
- **Sync failed** (`sync_failed`) or **commit mismatch** (`mismatch`). Open the
  workspace's **Sync Log** app. A mismatch usually means `git_branch` is not
  the branch the workflow pushed, or a newer push landed in between.
- **Still syncing** (`syncing`). The sync took longer than the site's wait. It
  continues in the background; check **Sync Log** if the content does not
  update.
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
  The `detail` of a failed sync comes from the workspace's log. In the
  annotation its newlines are escaped, so it cannot issue workflow commands
  of its own; in the job summary control characters collapse to spaces and
  HTML and Markdown are escaped, so it shows literally.
- **The response contract is shared** with the site's handler. Change both
  sides together.

## Tests

```bash
bash actions/coder-site-sync/test-sync.sh
```

The test runs `sync.sh` unmodified against `test-stub-server.js`, a local
stub of both the Actions OIDC endpoint and a site, covering every response
above plus input validation, token handling and redaction. It also checks
that `action.yml` wires every input and output, and that this README
documents every status. It needs `bash`, `curl`, `jq`, `node` and `ruby`, and
runs in the Static Tests workflow.

Because production requires https, `sync.sh` accepts plain http only for a
loopback host when `CODER_SITE_SYNC_TEST_ALLOW_LOOPBACK_HTTP=1` is set **and**
`GITHUB_ACTIONS` is not `true`. Inside any workflow run the flag has no
effect, and even outside one the token could only go back to the same
machine.
