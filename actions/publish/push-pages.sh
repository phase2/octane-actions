#!/bin/sh
# Push files from a local folder to the remote "pages" environment.
# Usage: push-pages.sh [tarball-name] [source-path] [dest-path]
#   tarball-name: the filename of the tarball (.tar.gz added by default)
#   source-path: the name of the local path containing the files to push.
#   dest-path: the name of the remote path to contain the files.

set -ex

RELEASE_NAME="pages-main"
namespace="pages"

tarFile="$1"
localPath="$2"
destPath="$3"
tarPath="/tmp/${tarFile}.tar.gz"

# Create the tarball
cd ${localPath}
tar -cvzhf ${tarPath} .
cd -

# Determine the name of the webcontainer pod for this namespace.
podName=$(kubectl get pods -o name -n ${namespace} -l release=$RELEASE_NAME,webcontainer=true --field-selector status.phase=Running | cut -f2 -d/)

if [ ! -z "${podName}" ]; then
  # Copy the tarball into the same /tmp path in remote environment.
  echo "Copying file ${tarPath} into ${podName} for release ${RELEASE_NAME}"
  kubectl cp -c web ${tarPath} "${namespace}/${podName}:${tarPath}"

  # Remote script to execute on pages server to unpack files.
  echo "Triggering remote unpack via kubectl exec..."
  command="/var/www/.octane-ci/scripts/files-pull.sh -u 1000 ${tarFile} ${destPath}"
  kubectl exec -n ${namespace} -c web ${podName} -- ${command}
else
  echo 'Could not determine pod to copy files.'
  exit 1
fi

export PAGES_URL="https://pages.${CI_URL}/${destPath}"
if [[ ! -z "$GITHUB_ENV" && -e "$GITHUB_ENV" ]]; then
  echo "PAGES_URL=${PAGES_URL}" >> $GITHUB_ENV
fi

rm -rf ${tarPath}
