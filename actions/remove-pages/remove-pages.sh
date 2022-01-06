#!/bin/sh
# Remove files from the remote "pages" environment.
# Usage: remove-pages.sh [dest-path]
#   dest-path: the name of the remote path to remove.

set -ex

RELEASE_NAME="pages-main"
namespace="pages"

if [ -z "$1" ]; then
  echo "Usage: remove-pages.sh dest-path"
  exit 1
fi
if [ "$1" == "/" ]; then
  echo "Cannot remove root folder"
  exit 1
fi
if [ ! -z "$(echo $1 | grep '\.')" ]; then
  echo "Path cannot contain dots"
  exit 1
fi
destPath="docroot/$1"

# Determine the name of the webcontainer pod for this namespace.
podName=$(kubectl get pods -o name -n ${namespace} -l release=$RELEASE_NAME,webcontainer=true --field-selector status.phase=Running | cut -f2 -d/)

if [ ! -z "${podName}" ]; then
  echo "Removing remote files in ${destPath} via kubectl exec..."
  kubectl exec -n ${namespace} -c web ${podName} -- rm -rf ${destPath}
else
  echo 'Could not determine pod to remove files.'
  exit 1
fi
