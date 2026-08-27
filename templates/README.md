# Templates for App Repos

These files are **not used by the deployment server**. Copy them into your
backend / frontend repos so each app owns its own build, local-dev compose,
and CI workflow.

```
templates/
  backend/
    Dockerfile
    docker-compose.yml         # local dev stack (api + mysql)
    .env.example               # rename to .env locally
    .dockerignore
    .gitignore
    .github/workflows/deploy.yml
    .github/workflows/qa-branch-image.yml
  frontend/
    Dockerfile
    docker-compose.yml         # local dev stack (web)
    .env.example
    .dockerignore
    .gitignore
    .github/workflows/deploy.yml
    .github/workflows/qa-branch-image.yml
```

## How to install in an app repo

```bash
# From inside your backend repo:
cp -r ../deployment/templates/backend/. .
mv .env.example .env   # edit values
docker compose up      # local dev
```

## Branch → tag → deploy flow

Each app repo owns a committed `VERSION` file. The value must be strict SemVer
with a `v` prefix, for example `vX.X.X`. The starting version is `v0.0.1`.

| Source | Image tag | Deploy behavior |
|---|---|---|
| `VERSION` | `:vX.X.X` | Primary deploy tag. Re-running CI with the same version overwrites this tag. |
| commit SHA | `:<sha>` | Immutable reference for rollback/debug. |
| `dev` branch | `:dev` | Mutable development alias published by the regular deploy workflow. |

Backend and frontend must use the same `VERSION` value for a compatible release.
The dashboard deploys one selected version tag to both images.

The `qa-branch-image.yml` workflow builds same-repository pull requests for
Docker Hub and publishes a shared, sanitized branch tag (`pr-<branch>`) plus an
immutable `pr-<branch>-<short-sha>` tag. Fork pull requests do not receive
Docker Hub credentials. Because both app repos derive the tag from the branch
name, the dashboard can offer a paired tag only after both images exist.
Each image also carries its source commit as the non-secret `APP_COMMIT`
environment value and `org.opencontainers.image.revision` label.

The workflow fails if `VERSION` is lower than the latest GitHub Release tag in
that repo. Equal is allowed so a rebuild can overwrite the same Docker tag.

## Required GitHub secrets in each app repo

- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN`
- `WEBHOOK_URL_DEV`  *(optional — instant dev deploy)*
- `WEBHOOK_SECRET`   *(optional — must match `config.env` on the server)*

## Release notes

Keep release notes in GitHub Releases as the source of truth. Mirror the released
versions into the deployment dashboard release catalog when they are ready to
deploy. The dashboard marks a version broken from Dokku deployment state when an
app currently running that version is stopped, restarting, or otherwise not
running.
