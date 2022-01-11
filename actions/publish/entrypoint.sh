#!/bin/sh -l
script=$(readlink -f "$0")
scriptDir=$(dirname "$script")

# Local source path
source=${1}
# Remote file path in pages server
dest=${2}
# Name of the top-level folder in pages
projectName=${4:-PROJECT_NAME}

if [ -z "$projectName" ]; then
  echo "ERROR: Pages project_name cannot be empty."
  exit 1
fi
if [ "$projectName" == "/" ]; then
  echo "ERROR: Pages project_name cannot be root folder"
  exit 1
fi
if [ ! -z "$(echo $projectName | grep '\.')" ]; then
  echo "ERROR: Pages project_name cannot contain dots"
  exit 1
fi
if [ ! -d "$source" ]; then
  echo "ERROR: Pages source path must be a directory."
  exit 1
fi
if [ -z "$dest" ]; then
  echo "ERROR: Pages destination cannot be empty."
  exit 1
fi
if [ "$dest" == "/" ]; then
  echo "ERROR: Pages destination cannot be root folder"
  exit 1
fi
if [ ! -z "$(echo $dest | grep '\.')" ]; then
  echo "ERROR: Pages destination cannot contain dots"
  exit 1
fi

# Create the kube config
mkdir -p $HOME/.kube
echo -n "$3" >$HOME/.kube/config

# A project-specific name for the intermediate tarball.
saltCmd=$(which md5 2>/dev/null || which md5sum 2>/dev/null)
runId=$(echo "${projectName}-${source}" | sed 's#[^a-zA-Z0-9]#-#g')

echo "Compressing files to /tmp/${runId}.tar.gz"
echo "Pushing files from ${source} into pages docroot/${projectName}/${dest}"
${scriptDir}/push-pages.sh ${runId} ${source} docroot/${projectName}/${dest}
