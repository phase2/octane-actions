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

#### Packages installed via a metapackage (e.g. Drupal core)
Some advisories target a package installed transitively through a metapackage
rather than required directly. The common case is `drupal/core`: projects
require `drupal/core-recommended` (and usually `drupal/core-composer-scaffold`
and `drupal/core-project-message`) but NOT `drupal/core` itself.

When `composer audit` reports an advisory against `drupal/core`, do NOT skip it
because `drupal/core` is absent from `composer.json`. Treat the `drupal/core-*`
metapackages that ARE present as the update target (see step 3).

### 3. Update Vulnerable Direct Dependencies
For each vulnerable package that IS in `composer.json` perform the minimal update necessary to
resolve the advisory, even if the constraints in composer.json allow for a bigger update. There
are multiple ways this may be achieved depending on the security update available. You should
not run a blanket `composer update vendor/package`.

Patch level only
```bash
composer update vendor/package --patch-only --with-dependencies
```

Specific version request
```bash
composer update vendor/package --with vendor/package:1.0.1 --with-dependencies
```

**Reminder**: Never run `composer update` on a package unless you have confirmed it exists in composer.json.

#### Drupal core
Drupal core is a special case. Confirm which core metapackages are present:
```bash
grep -E "\"drupal/core-" composer.json
```
Then update them together, using `--with-all-dependencies` so Composer can move
`drupal/core` (pinned transitively by `drupal/core-recommended`) to the secure
release:
```bash
composer update "drupal/core-*" --with-all-dependencies
```
This is the update method documented in the Drupal core release notes. Quote the
pattern so the shell does not expand it. Updating the `drupal/core-*`
metapackages alone with `--with-dependencies` will leave `drupal/core` behind,
because core-recommended pins exact versions; `--with-all-dependencies` is
required so those pinned dependencies can move.

To hold core to the exact fixed version and avoid a larger minor bump, pin
core-recommended explicitly:
```bash
composer update "drupal/core-*" --with drupal/core-recommended:10.6.11 --with-all-dependencies
```

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
   This will update it to the latest version allowed by the parent package's constraints without modifying composer.json.

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
