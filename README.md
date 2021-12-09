# Octane CI Actions

This repository holds the public composite actions used within Octane projects.

## detect-pod
> Usage: 
* `phase2/octane-actions/actions/detect-pod@master`
> Inputs: 
* `kubeconfig`: the KUBE_CONFIG secret for accessing the Devcloud
* `release_name`: the release_name annotation of the pod, uses the current branch and project name by default.

> Example:
```
  detect:
    name: Detect pod is running
    runs-on: self-hosted
    outputs:
      pod: ${{ steps.detect-pod.outputs.pod-status }}
    steps:
      - name: Find Devcloud pod
        uses: phase2/octane-actions/actions/detect-pod@main
        id: detect-pod
        with:
          kubeconfig: ${{ secrets.KUBE_CONFIG }}

...

  deploy:
    name: Deploy site
    needs: [detect]
    if: ${{ needs.detect.outputs.pod != 'True' }}
    steps:
      ...do deploy stuff...
```

Determine if a pod is running in the Devcloud. Sets the output to "True" if the pod exists and has the status of "Running"
