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
For each vulnerable package that IS in `composer.json`:
```bash
composer update vendor/package --with-dependencies
```

**Reminder**: Never run `composer update` on a package unless you have confirmed it exists in composer.json.

### 4. Handle Patch Failures
When a package update causes a patch to fail:

#### Remote Patches (from drupal.org)
Format in composer.json: `"ISSUE_NUMBER - Description": "URL"`

1. Extract issue number from patch description
2. Check issue queue: `https://www.drupal.org/node/$ISSUE_NUMBER`
3. Find latest patch for target package version with positive test results
4. Update patch URL in composer.json
5. If issue marked fixed in target version: remove patch

#### Local Patches
Path: `patches/*.patch` or `project/patches/*.patch`

1. Attempt to reroll patch against new package version
2. If reroll succeeds: update patch file
3. If reroll fails: document conflict for manual resolution

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
```
Security update: <brief summary of packages updated>

<details about what was updated, one line per package>
```

Example:
```
Security update: drupal/core, drupal/contrib_module

- drupal/core: 10.2.0 -> 10.2.1 (SA-CORE-2024-001)
- drupal/contrib_module: 2.0.0 -> 2.0.1 (SA-CONTRIB-2024-001)
- Updated patch for issue #12345
```

### 8. Complete
**CRITICAL**: DO NOT stage or commit changes - the workflow handles that automatically.

**CRITICAL**: DO NOT delete pr_body.md or commit_message.txt - they are read by the workflow.
