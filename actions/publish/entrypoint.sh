#!/bin/sh -l
script=$(readlink -f "$0")
scriptDir=$(dirname "$script")

# Name of the top-level folder in pages
projectName=${1}
# Local source path
source=${2}
# Remote file path in pages server
dest=${3}

# Create the kube config
mkdir -p $HOME/.kube
echo -n "$4" >$HOME/.kube/config

# A project-specific name for the intermediate tarball.
saltCmd=$(which md5 2>/dev/null || which md5sum 2>/dev/null)
runId=$(echo "${projectName}-${source}" | sed 's#[^a-zA-Z0-9]#-#g')

echo "Compressing files to /tmp/${runId}.tar.gz"
echo "Pushing files from ${source} into pages docroot/${projectName}/${dest}"
${scriptDir}/push-pages.sh ${runId} ${source} docroot/${projectName}/${dest}
