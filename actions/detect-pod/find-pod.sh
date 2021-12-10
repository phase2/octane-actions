#!/usr/bin/env bash
# Determine if a pod for a release is running
# Usage: find-pod.sh release-name
# Returns: "true" if pod is running

releaseName="$1"
namespace=${KUBE_NAMESPACE:-${PROJECT_NAME}}

if [ -z "$releaseName" ]; then
  currentBranch="$(git symbolic-ref HEAD 2>/dev/null)"
  currentBranch=${currentBranch##refs/heads/}
  releaseName="${PROJECT_NAME}-${currentBranch}"
fi

# Determine the name of the webcontainer pod for this namespace.
podName=$(kubectl get pods -n ${namespace} -l release=$releaseName,webcontainer=true -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}')
echo -n "$podName" | tr '[:upper:]' '[:lower:]'
