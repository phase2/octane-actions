# Octane CI Actions

This repository holds the public composite actions used within Octane projects.

---

## load-env
> Usage: 
* `phase2/octane-actions/actions/load-env@main`

> Example:
```
  jobname:
    name: Do something
    runs-on: self-hosted
    steps:
      - name: Load environment variables
        uses: phase2/octane-actions/actions/load-env@main

      ...do other stuff...
```

Loads the `.env` file into the environment variables and also sets several other
global environment variables: `CI_REGISTRY`, `CI_URL`, `CI_BRANCH`, `WEB_IMAGE`.
Also overrides the config/cache paths for tools like `helm` and `yarn` to prevent
projects in the same Github runner from colliding.

---

## detect-pod
> Usage: 
* `phase2/octane-actions/actions/detect-pod@main`
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

---

## add-pr-url
> Usage: 
* `phase2/octane-actions/actions/add-pr-url@main`
> Inputs: 
* `url`: the URL to add to the PR description

> Example:
```
  build:
    name: Do the build
    runs-on: self-hosted
    steps:

      ... Build stuff here ...

      - name: Set URL_ENV
        run: .octane-ci/scripts/release-name.sh
      - name: Add environment link to pull request comment
        uses: phase2/octane-actions/actions/add-pr-url@main
        if: ${{ env.URL_ENV }}
        with:
          url: ${{ env.URL_ENV }}
```

Adds a link to the specified URL to the end of the description text for the related pull request.

## publish
> Usage: 
* `phase2/octane-actions/actions/publish@main`
> Inputs: 
* `project_name`: the project name
* `source`: the source path to the content to publish
* `dest`: the destination path in the Pages server
* `kubeconfig`: the ${{ secrets.PAGES_KUBE }} kubernetes config

> Example:
```
- name: Publish content to Pages
  uses: phase2/octane-actions/actions/publish@main
  with:
    project_name: ${{ env.PROJECT_NAME }}
    source: SOURCE_PATH
    dest: DEST_PATH
    kubeconfig: ${{ secrets.PAGES_KUBE }}
```
Publish a folder of static content to the Phase2 Pages server,
where the `SOURCE_PATH` is the relative path from your project repo root to the files you want to publish and
`DEST_PATH` is the subfolder/path you want to make available on the Pages server.

The URL of your pages will be exported to the `PAGES_URL` environment variable.

**NOTE:** *Can only be called from with a private Phase2 repository.*

## remove-pages
> Usage: 
* `phase2/octane-actions/actions/remove-pages@main`
> Inputs: 
* `project_name`: the project name
* `dest`: the destination path in the Pages server
* `kubeconfig`: the ${{ secrets.PAGES_KUBE }} kubernetes config

> Example:
```
- name: Remove content from Pages
  uses: phase2/octane-actions/actions/remove-pages@main
  with:
    project_name: ${{ env.PROJECT_NAME }}
    dest: DEST_PATH
    kubeconfig: ${{ secrets.PAGES_KUBE }}
```
Remove content from the Pages server,
where `DEST_PATH` is the subfolder/path you want to remove for the given project.

**NOTE:** *Can only be called from with a private Phase2 repository.*
