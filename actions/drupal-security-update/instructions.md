# Drupal Security Update Instructions

## Task
Update Drupal Composer dependencies that have security vulnerabilities.

## Execution Context
- Use `composer` command directly
- Non-interactive execution required
- DO NOT stage or commit changes - the workflow handles that

## Process

### 1. Identify Vulnerable Packages
Run `composer audit --no-cache --format=json` to identify packages with security advisories.

### 2. Filter to Direct Dependencies Only

**CRITICAL**: You must ONLY update packages explicitly listed in `composer.json` under `require` or `require-dev`.

**Before updating ANY package**, run this check:
```bash
grep -E "\"vendor/package\"" composer.json
```

If the package is NOT found in composer.json, **DO NOT run composer update on it**.

#### What NOT to update in this step:
- Any package not explicitly listed in `composer.json` under `require` or `require-dev`

Transitive dependencies (packages pulled in by other packages) are handled separately in step 4 after direct dependencies are updated.

### 3. Update Vulnerable Direct Dependencies
For each vulnerable package that IS in `composer.json` perform the minimal update necessary to
resolve the advisory, even if the constraints in composer.json allow for a bigger update. There
are multiple ways this may be achieved depending on the security update available. You should
not run a blanket `composer update vendor/package`.

Patch level only
```bash
composer update vendor/package --patch-only --with-dependencies --minimal-changes
```

Specific version request
```bash
composer update vendor/package --with vendor/package:1.0.1 --with-dependencies --minimal-changes
```

`--minimal-changes` (`-m`) is required on every update command in this step and must not be
dropped. Drupal projects require `drupal/core-recommended` rather than `drupal/core`, so
`drupal/core` is not a root requirement. Because `--with-dependencies` updates everything
except root requirements, without `-m` these commands walk into core's entire dependency
tree and bump unrelated packages (symfony/*, guzzle, pear/archive_tar) that have no
advisory. Those belong in a planned core/dependency update pass, not a security PR.

When Drupal core updates are required, ensure all related core packages are updated. List
them by name; do **not** use a `"drupal/core-*"` pattern. Take the names from
`composer.json` — commonly:
```bash
composer update drupal/core-recommended drupal/core-composer-scaffold drupal/core-project-message drupal/core-dev --with-all-dependencies --minimal-changes
```
Include only the ones `composer.json` actually requires, plus `drupal/core` itself if it is
required directly. Naming `drupal/core-recommended` is enough to carry `drupal/core` with
it. Do not add `--patch-only` here: the fixed core releases require newer minor versions of
their own dependencies, which `--patch-only` forbids, making the update unresolvable.

If a named package is not present, Composer prints
`Package "vendor/name" listed for update is not locked.` and carries on with the rest. That
line is informational, not a failure — do not abort or treat the update as unsuccessful
because of it.

`-m` performs only the changes needed to satisfy constraints, with one exception: packages
named explicitly in the command are always eligible to move. A pattern like
`"drupal/core-*"` does **not** count as naming them — `-m` treats pattern-matched packages
as transitive and refuses to move them, so the pattern form reports "Nothing to modify in
lock file" and silently leaves core at the vulnerable version. That is why the core
packages must be listed individually. If a targeted package still does not move, name the
fixed version with the "Specific version request" form above rather than dropping `-m`; the
re-audit in step 4 will catch a package that failed to move.

**Reminder**: Never run `composer update` on a package unless you have confirmed it exists in composer.json.

#### Handle Unpublished Fixed Versions
If the fixed version is not yet available in the package repository (i.e., `composer update` succeeds but the package version does not change, and the vulnerability persists in re-audit):

1. Wait for the number of seconds specified as "Package wait seconds" in the workflow prompt, then retry the update once.
2. If still unavailable, document in pr_body.md with an attention grabbing opening line like "❌ IMPORTANT: fixed version not yet published. This workflow must be re-run once fixed version is released to resolve the vulnerability."

### 4. Re-check Transitive Dependency Vulnerabilities
After updating direct dependencies, re-run `composer audit --no-cache --format=json` to check if transitive vulnerabilities were resolved as a side effect.

For any transitive vulnerability that persists:

1. Find what requires it:
   ```bash
   composer why vendor/vulnerable-package
   ```

2. If the vulnerability can be resolved by updating the package which requires it, update the the requiring package. Otherwise, move to the next step.

3. Try updating the transitive package directly:
   ```bash
   composer update vendor/vulnerable-package
   ```
   This will update it to the latest version allowed by the parent package's constraints without modifying composer.json. `-m` is not needed here: it only affects partial updates that use `-w`/`-W`.

4. If the update succeeds and resolves the vulnerability, include it in the PR description.

5. If the update fails due to constraint conflicts (the parent package doesn't allow the fixed version), document it in pr_body.md as "requires upstream fix" and note which direct dependency needs to release an update.

#### New Vulnerabilities Found in Re-audit
If the re-audit surfaces an advisory that was **not** present in the original audit JSON provided at the start of this run:

1. Perform one resolution loop using the same process as steps 2–4 for the new vulnerability.
2. If resolved, include it in the PR description.
3. If not resolved, document it in pr_body.md as "Additional advisory found during re-audit — not addressed in this PR" with the advisory details and reason it could not be resolved.

### 5. Handle Patch Failures
When a package update causes a patch to fail:

#### Remote Patches (from drupal.org)
Format in composer.json: `"ISSUE_NUMBER - Description": "URL"`

1. Extract issue number from patch description
2. Check issue queue: `https://www.drupal.org/node/$ISSUE_NUMBER`
3. Find latest patch for target package version with positive test results
4. If latest positive patch is a patch or diff from git.drupalcode.org, download it and store it locally as
those can change over time as merge requests are updated. Use the naming convention:
module_name-issue_number-comment_number.patch
5. Update patch URL in composer.json
6. If issue marked fixed in target version: remove patch

#### Local Patches
Path: `patches/*.patch` or `project/patches/*.patch`

Local patches are sometimes used for changes which aren't appropriate as filed issues for a module
and sometimes to capture available patches that aren't guaranteed to be stable from issues.

1. Attempt to determine if the local patch is still necessary. If not, remove patch and document reasoning.
2. If local patch is necessary and it was a snapshot of a remote patch, attempt to resolve as a remote patch first.
3. For patches which aren't resolved by previous steps, attempt to reroll patch against new package version
4. If reroll succeeds: update patch file
5. If reroll fails: document conflict for manual resolution

### 6. Validation
Run these commands and ensure exit code 0:
```bash
composer validate --strict
composer install --dry-run
```

### 7. Create PR Description
Save to `pr_body.md` with:
- Security advisory links for each updated package
- Any patch changes (updated URLs, removed patches, rerolled patches)
- Breaking changes from changelogs (if any)
- Conflicts requiring manual resolution (if any)
- Transitive dependency vulnerabilities that were NOT updated. List the vulnerable package and which direct dependency should be updated upstream to resolve it.
- Any other package whose version changed in `composer.lock` without having an advisory. Run `git diff -- composer.lock` and list every remaining difference, so reviewers do not have to diff the lock by hand. If there are none, say so. Compare the working tree against HEAD rather than a remote ref: nothing is staged or committed at this point, so HEAD is still the base branch, and fetching the base ref fails in checkouts that use `persist-credentials: false`.

### 8. Create Commit Message
Save to `commit_message.txt` with a concise commit message following this format:
```text
Security update: <brief summary of packages updated>

<details about what was updated, one line per package>
```

Example:
```text
Security update: drupal/core, drupal/contrib_module

- drupal/core: 10.2.0 -> 10.2.1 (SA-CORE-2024-001)
- drupal/contrib_module: 2.0.0 -> 2.0.1 (SA-CONTRIB-2024-001)
- Updated patch for issue #12345
```

### 9. Complete

Ensure only the files required for the update, the pr_body.md file, and the commit_message.txt file remain in the workspace.

**CRITICAL**: DO NOT stage or commit changes - the workflow handles that automatically.

**CRITICAL**: DO NOT delete pr_body.md or commit_message.txt - they are read by the workflow.
