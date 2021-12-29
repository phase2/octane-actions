#!/usr/bin/env bash
# Update config/cache environment variables.
# Prevents Github runners from sharing config/cache across projects

if [[ -e ".env" ]]; then
  export $(grep -v '^#' ".env" | xargs)
fi
export PROJECT_NAME=${PROJECT_NAME:-$GENERATOR_PROJECT_NAME}
export PROJECT_ROOT=${PROJECT_ROOT:-$(pwd)}

export CI_REGISTRY=ghcr.io
export CI_URL="devcloud.fayze2.com"
export WEB_IMAGE=${CI_REGISTRY}/${GITHUB_REPO}/${PROJECT_NAME}
export CI_BRANCH=${GITHUB_REF##refs/heads/}

# Override config/cache paths for various tools
export HELM_CONFIG_HOME=${PROJECT_ROOT}/.config/helm/config
export HELM_CACHE_HOME=${PROJECT_ROOT}/.config/helm/cache
export HELM_DATA_HOME=${PROJECT_ROOT}/.config/helm/data
mkdir -p ${HELM_CONFIG_HOME}
mkdir -p ${HELM_CACHE_HOME}
mkdir -p ${HELM_DATA_HOME}
export YARN_CACHE_FOLDER=${PROJECT_ROOT}/.config/yarn/cache
mkdir -p ${YARN_CACHE_FOLDER}

varList=(
  "CI_REGISTRY"
  "CI_URL"
  "CI_BRANCH"
  "WEB_IMAGE"
  "HELM_CONFIG_HOME"
  "HELM_CACHE_HOME"
  "HELM_DATA_HOME"
  "YARN_CACHE_FOLDER"
)
if [[ ! -z "$GITHUB_ENV" && -e "$GITHUB_ENV" ]]; then
  for varName in "${varList[@]}"; do
    varValue="${!varName:-}"
    echo "${varName}=${varValue}" >> $GITHUB_ENV
  done
fi
