# Octane CI Auto-Remediation Instructions

## Task

A scheduled "Build Nightly" run in the **octane-ci** repository failed. Diagnose
it, classify it, and where the cause is local code or configuration, produce a
minimal fix for human review.

You are never merging anything. Your output is a diagnosis plus, when
appropriate, a small reviewable diff.

## Execution Context

- The checked-out repository is **octane-ci itself**: Phase2's Drupal/Design
  System starter kit, not a generated project.
- Non-interactive execution. No Docksal, no DDEV, no cluster access.
- **DO NOT stage or commit changes.** The workflow handles that.
- **DO NOT** run `.octane-ci/scripts/generate.sh`, `test-build.sh` or
  `test-update.sh`. They are slow, need a local runtime, and will pollute the
  workspace with a generated project that would end up in the commit.
- Reason statically: read sources, compare against upstream, reason about the
  build. You cannot reproduce the build here.

## The single most important thing to understand

**The nightly fails inside a generated project, but the fix belongs in octane-ci
source.**

"Build Nightly" generates a fresh Drupal consumer project (`drupal-consumer`),
deploys it to the DevCloud cluster, and runs `composer install` inside the
cluster CLI pod against the latest dependencies, with no committed
`composer.lock`. That is deliberate: the nightly is Octane's early warning for
upstream drift.

So a traceback naming, say, `/var/www/composer.json` is pointing at a file that
was **generated from a template** in this repo. Fixing the generated artifact is
meaningless; it does not exist after the run. You must map the failure back to
the template that produced it, which is almost always under:

```
.octane-ci/consumers/<consumer>/sync/
```

### Worked example (the motivating failure)

Drupal core 11.4.0 added `symfony/runtime` as a direct dependency. Its Composer
plugin was not in the `allow-plugins` list, so the nightly's `composer install`
failed inside the generated project.

The correct fix was **two** edits in octane-ci source:

- `.octane-ci/consumers/drupal/sync/composer.json`
- `.octane-ci/consumers/drupal-ddev/sync/composer.json`

adding `"symfony/runtime": true` to `config.allow-plugins`.

An agent that patched only one of those files would have shipped a half-fix that
silently leaves the other consumer broken. See "Consumer parity" below.

## Process

### 1. Research before diagnosing

Read, in this order:

1. `docs/kb/index.json`, then any KB doc or ADR whose topic matches the failure.
   The KB records prior decisions; do not re-litigate them or reintroduce a
   pattern an ADR rejected.
2. `AGENTS.md` at the repo root, and the nearest `AGENTS.md` to any file you
   intend to change (`.octane-ci/AGENTS.md`, `.octane-ci/actions/AGENTS.md`,
   `.octane-ci/consumers/AGENTS.md`, and so on).
3. `CLAUDE.md` for repository conventions.

If a `.claude/skills/octane-*/SKILL.md` file covers the area you are touching
(`octane-overview`, `octane-consumers`, `octane-actions`,
`octane-fin-commands`, `octane-sync-templates`, `octane-devcloud`,
`octane-generator`), read it before editing.

### 2. Gather the failure evidence

The prompt gives you the failed run URL, the failed job list, and a bounded
error excerpt. That excerpt is a starting point, not the whole story.

Pull the detail you need with the CI tools available to you:

- `mcp__github_ci__get_workflow_run_details` for the run's job/step structure.
- `mcp__github_ci__download_job_log` for a specific failed job's log.

Fetch logs only for jobs that actually failed, and read the earliest genuine
error rather than the last line of output. Cascading failures are common: the
`build` job failing usually makes `test` fail too, and only `build` matters.

### 3. Classify the failure

This classification drives everything downstream, and it is reported as
structured output (see section 7). Be conservative: a wrong `code` call wastes a
human's review cycle, while a wrong `infra` call merely means the failure gets
reported instead of fixed.

**`code`** means the cause is in this repository's code or configuration and a
local edit fixes it:

- Composer dependency drift (a new transitive dependency, a changed constraint).
- A Composer plugin missing from `allow-plugins`.
- A version constraint that no longer resolves.
- A patch that no longer applies and needs a reroll or removal.
- A renamed or removed upstream package, module, or system package.
- A broken template, script, or workflow source in this repo.

**`infra`** means the cause is environmental and no edit here would fix it:

- Kubernetes or DevCloud errors: pod scheduling, evictions, timeouts, quota,
  `ImagePullBackOff`.
- Registry authentication or rate limiting (ghcr.io, Docker Hub, Packagist).
- Network failures, DNS failures, TLS failures, upstream 5xx.
- Runner problems: disk exhaustion, a lost self-hosted runner, a cancelled job.
- An expired or rotated secret.

**`unknown`** means you genuinely cannot tell, or the logs are insufficient.
Prefer `unknown` over a low-confidence guess.

Set `confidence` honestly. It gates whether a PR is opened at all.

### 4. Compute the failure fingerprint

The fingerprint deduplicates PRs across nights: the same root cause failing
again must supersede its earlier PR, while a different cause must get its own.

Build it as `<failed-job>:<root-cause-slug>`, lowercase kebab-case, no run IDs,
no timestamps, no version numbers that will drift:

```
build:composer-allow-plugins-symfony-runtime
build:composer-constraint-unresolvable-drupal-core
deploy:helm-timeout
```

It must be **stable**: the same root cause on two different nights must produce
the identical string. Derive it from the cause, never from the run.

If you cannot characterize the root cause well enough for a stable slug, return
an empty `fingerprint`. An empty fingerprint is handled safely: nothing will be
superseded or closed.

### 5. Fix, if and only if the classification is `code`

If the classification is `infra` or `unknown`, **make no edits at all**. Report
and stop. Leave the workspace clean.

For a `code` failure:

#### Find the right layer

Octane has three tiers: `.octane-ci/` (core), `.octane-ci/consumers/<type>/`
(consumer), and `project/` (per-project, absent in this repo). Fix at the layer
that owns the problem.

| Symptom | Almost always lives in |
|---|---|
| `composer install` / `composer` resolution failure | `.octane-ci/consumers/<consumer>/sync/composer.json` |
| Node/npm build failure in the generated project | `.octane-ci/consumers/<consumer>/sync/package.json` |
| A patch that no longer applies | the `patches` entry in `sync/composer.json`, plus any local patch file |
| Generated project file wrong on disk | the corresponding `sync/` template |
| CI wiring or workflow logic | `.octane-ci/actions/src/` or `.octane-ci/actions/includes/` |
| A `fin`/`ddev` command | `.octane-ci/commands/` or `.octane-ci/consumers/<consumer>/commands/` |
| Helm/deploy behavior | `.octane-ci/consumers/drupal/charts/` or `.octane-ci/scripts/` |

#### Consumer parity is mandatory

`drupal` (Docksal) and `drupal-ddev` (DDEV) are parallel consumers. Several
files are **duplicated, not symlinked**, most importantly
`sync/composer.json`, which is byte-identical between the two by convention.

Before finishing any consumer-layer edit, check whether the file you changed has
a counterpart:

```bash
ls -la .octane-ci/consumers/drupal/sync/<path> \
       .octane-ci/consumers/drupal-ddev/sync/<path>
```

If both exist as real files, **apply the same change to both**. If one is a
symlink to the other, edit the real file only. Note in `pr_body.md` which
consumers you touched and why.

The nightly builds only the `drupal` consumer, so a `drupal`-only fix will make
the nightly pass while leaving `drupal-ddev` broken. Passing CI is not proof of
a complete fix here.

#### Never edit generated output

`.bin/` and `.github/workflows/` are **generated**. They carry a DO-NOT-EDIT
banner. Editing them directly is always wrong; the change would be reverted on
the next regeneration.

If you change anything under any `actions/` directory, regenerate afterwards and
include the regenerated output in your changes:

```bash
.octane-ci/scripts/build-actions.sh
```

Git hooks do not run in this workflow, so regeneration will not happen for you.
Do not run `makebin.sh` unless you changed a command under a `commands/`
directory.

#### Keep the fix minimal

Make the smallest change that addresses the root cause. Do not opportunistically
upgrade dependencies, reformat files, fix unrelated issues, or "tidy" anything.
A reviewer must be able to see the whole fix at a glance and connect it to the
failure.

Match the surrounding style exactly: indentation (2 spaces, 4 in
`composer.json`), key ordering (`allow-plugins` entries are alphabetical), and
comment conventions.

### 6. Validate what you can

You cannot run the build. Do what is checkable:

- JSON files parse:
  ```bash
  jq -e . .octane-ci/consumers/drupal/sync/composer.json >/dev/null
  ```
- Shell scripts parse: `bash -n <script>`.
- YAML parses:
  ```bash
  python3 -c "import sys,yaml;yaml.safe_load(open(sys.argv[1]))" <file>
  ```
- If you touched `actions/`, `build-actions.sh` ran cleanly and the regenerated
  workflow still parses.
- If the repo has a relevant guard script (`.octane-ci/scripts/test-*.sh`), run
  it.
- Parity holds: the two consumers' counterpart files still match where they are
  supposed to.

State in `pr_body.md` exactly what you validated and what you could not, and be
explicit that the real proof is the fix PR's own CI run.

### 7. Report structured output

Your final response must satisfy the JSON schema supplied to you. Fields:

| Field | Meaning |
|---|---|
| `classification` | `code`, `infra`, or `unknown` (section 3) |
| `confidence` | 0.0-1.0, your honest confidence in the classification |
| `fingerprint` | Stable root-cause signature, or `""` (section 4) |
| `summary` | One or two sentences: what broke and why |
| `failed_jobs` | Names of the jobs that genuinely failed, excluding cascades |
| `changes_made` | `true` only if you edited files in the workspace |

`changes_made` must be `false` whenever `classification` is not `code`.

### 8. Create the PR description (only when you made changes)

Save `pr_body.md` in the repository root:

- **What broke**, with a link to the failed run.
- **Root cause**, in plain terms.
- **The fix**, file by file, and why it is the right layer.
- **Consumer parity**: which consumers were touched, or why only one was.
- **Validation**: what you checked, and what only CI can prove.
- **Regeneration**: whether you ran `build-actions.sh` and why.
- **Anything a reviewer must verify by hand**, called out prominently.

If you are less than confident in the fix, open with an attention-grabbing line
saying so, for example:

```
WARNING: low-confidence fix. The root cause is consistent with the logs but
could not be validated without a build. Please verify before merging.
```

### 9. Create the commit message (only when you made changes)

Save `commit_message.txt` in the repository root, following the repo convention
of an `NT: ` prefix for non-Jira work:

```text
NT: <concise summary of the fix>

<why it was needed, referencing the nightly failure>
<one line per file changed, if more than one>
```

Example:

```text
NT: Allow symfony/runtime Composer plugin for Drupal 11.4

Drupal core 11.4.0 added symfony/runtime as a direct dependency whose
Composer plugin was blocked by allow-plugins, breaking the nightly
build's composer install. Add it to the allow-plugins list in both the
drupal and drupal-ddev consumer composer.json templates, matching
upstream Drupal 11.4.
```

Keep the subject under 72 characters. Do not include "Co-Authored-By" or
"Generated with Claude Code" lines; this repository forbids both.

### 10. Complete

- Only the files required for the fix, plus `pr_body.md` and
  `commit_message.txt`, may remain modified or added in the workspace.
- Remove any scratch files, downloaded logs, or temporary output you created.
- **CRITICAL:** DO NOT stage or commit. The workflow does that.
- **CRITICAL:** DO NOT delete `pr_body.md` or `commit_message.txt`. The workflow
  reads them.
- If the classification was `infra` or `unknown`, the workspace must be clean and
  neither file should exist.
