# Drupal Security Update Instructions

## Task
Update Drupal Composer dependencies that have security vulnerabilities.

## Execution Context
- Use `composer` command directly
- Non-interactive execution required
- DO NOT stage or commit changes - the workflow handles that

## Process

### 1. Identify Vulnerable Packages
Run `composer audit --format=json` to identify packages with security advisories.

### 2. Filter to Direct Dependencies Only

**CRITICAL**: You must ONLY update packages explicitly listed in `composer.json` under `require` or `require-dev`.

**Before updating ANY package**, run this check:
```bash
grep -E "\"vendor/package\"" composer.json
```

If the package is NOT found in composer.json, **DO NOT run composer update on it**.

#### What NOT to update (examples):
- `composer/composer` - Never update composer itself
- Any package pulled in by another package

#### Handling Transitive Dependency Vulnerabilities
If a vulnerable package is NOT in composer.json:

1. Find what requires it:
   ```bash
   composer depends vendor/vulnerable-package
   ```

2. Trace up to a direct dependency (one that IS in composer.json)

3. Update ONLY that direct dependency:
   ```bash
   composer update direct/dependency --with-dependencies
   ```

4. If the transitive vulnerability persists, document it in pr_body.md as "requires upstream fix"

### 3. Update Vulnerable Direct Dependencies
For each vulnerable package that IS in `composer.json` perform the minimal update necessary to
resolve the advisory, even if the constraints in composer.json allow for a bigger update. There
are multiple ways this may be achieved depending on the security update available.

Patch level only
```bash
composer update vendor/package --patch-only --with-dependencies
```

Specific version request
```bash
composer update --with vendor/package:1.0.1 --with-dependencies
```

**Reminder**: Never run `composer update` on a package unless you have confirmed it exists in composer.json.

### 4. Handle Patch Failures
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
2. If local patch is necessary and it was a snapshot of an issue, attempt to resolve as a remote patch first.
3. For patches which aren't resolved by previous steps, attempt to reroll patch against new package version
4. If reroll succeeds: update patch file
5. If reroll fails: document conflict for manual resolution

### 5. Validation
Run these commands and ensure exit code 0:
```bash
composer validate --strict
composer install --dry-run
```

### 6. Create PR Description
Save to `pr_body.md` with:
- Security advisory links for each updated package
- Any patch changes (updated URLs, removed patches, rerolled patches)
- Breaking changes from changelogs (if any)
- Conflicts requiring manual resolution (if any)
- Transitive dependency vulnerabilities that were NOT updated (list the vulnerable package and which direct dependency should be updated upstream to resolve it)

### 7. Create Commit Message
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

### 8. Complete

Ensure only the files required for the update, the pr_body.md file, and the commit_message.txt file remain in the workspace.

**CRITICAL**: DO NOT stage or commit changes - the workflow handles that automatically.

**CRITICAL**: DO NOT delete pr_body.md or commit_message.txt - they are read by the workflow.
