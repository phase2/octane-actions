#!/bin/bash
## Helper functions take from Octane CI
#

# Helper to return the top level git directory for project.
git_root() {
  printf "$(git rev-parse --show-toplevel 2>/dev/null)"
}

# Generate a slug.
#   lowercase, removes refs/heads|tags, replaces non alphanum with hyphen.
#   trims to 63 chars and removes any trailing hyphen.
#   $1 is string to convert
#   $2 is length to trim (default 63)
generate_slug() {
  local sanatizedSlug=$(echo -n "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's@^refs/(heads|tags)/@@g' | sed 's@[^0-9a-z]@-@g' | sed -E 's@-+@-@g')
  echo -n "${sanatizedSlug:0:${2:-63}}" | sed 's/[-_.]$//'
}

# Returns the current branch.
current_branch() {
  if [ ! -z "$OCTANE_BRANCH_REF" ]; then
    # In CI, get current branch from CI variable.
    currentBranch="$OCTANE_BRANCH_REF"
  else
    currentBranch="$(git symbolic-ref HEAD 2>/dev/null)"
    currentBranch=${currentBranch##refs/heads/}
  fi
  printf "${currentBranch}"
}

# Helper to extract the issue number from the branch name.
# Pass the branch name as the argument.
# If no issue number is found, return "NT"
# Handles both "issue/123-TITLE" and "issue-123-TITLE".
issue_num() {
  if [[ "$1" =~ ^[A-Za-z]+[\/-]([A-Z]+[-])?([0-9]+) ]]; then
    printf "${BASH_REMATCH[2]}"
  else
    printf "NT"
  fi
}

# Helper function to convert name (branch or env) to kubernetes name.
kube_name() {
  echo -n $(generate_slug "$1" 32)
}

# Helper function to convert branch name into environment name.
# For example, "issue/123-TITLE" becomes "issue-123".
# If argument is not given, or is "." then use current branch name.
env_name() {
  branch=${1:-.}
  if [ "$branch" == "." ]; then
    # Ensure current branch is taken from git root to handle submodules.
    # since Kube environment always comes from main project repo.
    branch=$(
      cd $(git_root)
      current_branch
    )
  fi
  issueNum=$(issue_num $branch)
  if [ "$issueNum" != "NT" ]; then
    printf "issue-${issueNum}"
  else
    printf "$(generate_slug $branch)"
  fi
}

# Combination of env_name and generate_slug to return a Kubernetes release name.
# $1 is the branch/environment name
# $2 is the project name (defaults to $PROJECT_NAME)
release_name() {
  envName=$(env_name $1)
  printf "${2:-$PROJECT_NAME}-$(kube_name $envName)"
}

