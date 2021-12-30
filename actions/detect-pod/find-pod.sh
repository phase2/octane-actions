#!/usr/bin/env bash
# Determine if a pod for a release is running
# Usage: find-pod.sh branch-name
#   branch-name: name of branch to use for release name
#     defaults to current branch
# Returns: "true" if pod is running

source $(dirname $0)/.functions.sh

if [[ -e ".env" ]]; then
  export $(grep -v '^#' ".env" | xargs)
fi
export PROJECT_NAME=${PROJECT_NAME:-$GENERATOR_PROJECT_NAME}

releaseName=$(release_name $1)

# Determine the name of the webcontainer pod for this namespace.
namespace=${KUBE_NAMESPACE:-$GENERATOR_NAMESPACE}
namespace=${namespace:-${PROJECT_NAME}}
podName=$(kubectl get pods -n ${namespace} -l release=$releaseName,webcontainer=true -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}')
echo -n "$podName" | tr '[:upper:]' '[:lower:]'
