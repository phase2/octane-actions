# Drupal Security Update Instructions

## Task
Update Drupal Composer dependencies that have security vulnerabilities.

## Execution Context
- Use `composer` command directly
- Non-interactive execution required
- Commit changes when complete

## Process

### 1. Identify Vulnerable Packages
Run `composer audit --format=json` to identify packages with security advisories.

### 2. Update Vulnerable Packages
For each package with an advisory:
```bash
composer update vendor/package --with-dependencies
```

### 3. Handle Patch Failures
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

### 4. Validation
Run these commands and ensure exit code 0:
```bash
composer validate --strict
composer install --dry-run
```

### 5. Create PR Description
Save to `pr_body.md` with:
- Security advisory links for each updated package
- Any patch changes (updated URLs, removed patches, rerolled patches)
- Breaking changes from changelogs (if any)
- Conflicts requiring manual resolution (if any)

### 6. Stage Changes
Stage all modified files:
- composer.json
- composer.lock
- Any modified patch files
- pr_body.md

DO NOT commit - the workflow handles that.
