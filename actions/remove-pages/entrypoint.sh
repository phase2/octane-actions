#!/bin/sh -l
script=$(readlink -f "$0")
scriptDir=$(dirname "$script")

# Name of the top-level folder in pages
projectName=${1}
# Remote file path in pages server
dest=${2}

# Create the kube config
mkdir -p $HOME/.kube
echo -n "$3" >$HOME/.kube/config

echo "Removing files from ${projectName}/${dest}"
${scriptDir}/remove-pages.sh ${projectName}/${dest}
