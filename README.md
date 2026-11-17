# github-runner-docker

A Docker image and Compose stack for running **GitHub Actions self-hosted runners** in containers.

- Ubuntu 24.04 with the official [actions/runner](https://github.com/actions/runner) binaries
- Multi-arch images (`linux/amd64`, `linux/arm64`)
- Workflows run as a non-root `runner` user. The container has `no-new-privileges` set and exposes no ports.
- Registration and the work directory persist in a Docker volume, so the runner survives restarts and reboots
- The one-time registration token is never written to disk
- Optional extras: access to the host Docker daemon, ephemeral runners, automatic PAT-based registration
- A weekly CI rebuild keeps the runner version current. GitHub stops sending jobs to outdated runners.

> **Using an AI coding agent?** Point it at [AGENTS.md](AGENTS.md). It is a step-by-step runbook for setting up a runner on a new machine.

## Quick start

Requirements: Docker Engine (or Docker Desktop) with the Compose v2 plugin.

```bash
git clone <this-repo-url> github-runner-docker
cd github-runner-docker
cp .env.example .env        # edit RUNNER_NAME / RUNNER_LABELS / RUNNER_IMAGE
./setup.sh                  # prompts for the repo URL and a registration token
```

To get a registration token (valid for about 1 hour), open **Repository → Settings → Actions → Runners → New self-hosted runner** and copy the token from the `--token` argument shown there. You don't need to run any of the other commands on that page. For an organization-wide runner, use **Org → Settings → Actions → Runners → New runner** and pass `https://github.com/<org>` as the URL.

`setup.sh` builds the image (or pulls it, if `RUNNER_IMAGE` is set), registers the runner in a one-off container, then starts it with `docker compose up -d`.

Verify:

```bash
docker compose logs -f github-runner   # expect "Connected to GitHub" / "Listening for Jobs"
```

The runner should also show as **Idle** under *Settings → Actions → Runners*.

Non-interactive setup:

```bash
RUNNER_URL=https://github.com/<owner>/<repo> RUNNER_TOKEN=<token> ./setup.sh
```

## Using it in a workflow

```yaml
jobs:
  test:
    runs-on: [self-hosted, linux, docker]
    steps:
      - uses: actions/checkout@v4
      - run: uname -a && whoami
```

## Configuration (`.env`)

| Variable           | Default                     | Purpose                                                        |
| ------------------ | --------------------------- | -------------------------------------------------------------- |
| `RUNNER_IMAGE`     | `github-runner:local`       | Image to run. Set to `<dockerhub-user>/github-runner:latest` to pull instead of build. |
| `RUNNER_NAME`      | `home-server-runner`        | Runner name shown in GitHub (must be unique)                   |
| `RUNNER_LABELS`    | `docker,self-hosted,linux`  | Comma-separated labels for `runs-on`                           |
| `RUNNER_EPHEMERAL` | `false`                     | Register with `--ephemeral` (one job per registration)         |
| `RUNNER_URL`       | —                           | Needed only for automatic registration                         |
| `ACCESS_TOKEN`     | —                           | PAT used to fetch registration tokens automatically (see below) |
| `COMPOSE_FILE`     | —                           | Set to `docker-compose.yml:docker-compose.docker-socket.yml` to enable Docker access |

Variables the entrypoint also accepts: `RUNNER_GROUP` (org runner group), `RUNNER_WORKDIR`, `RUNNER_DISABLE_UPDATE`, `GITHUB_API_URL` (GHES).

## Day-to-day commands

| Operation       | Command                                  |
| --------------- | ---------------------------------------- |
| Start / stop    | `docker compose up -d` / `docker compose stop` |
| Logs            | `docker compose logs -f`                 |
| Status          | `docker compose ps`                      |
| Runner version  | `docker compose run --rm github-runner version` |
| Update (pulled) | `docker compose pull && docker compose up -d` |
| Update (built)  | `docker compose build --pull && docker compose up -d` |

On start, the entrypoint copies the runner binaries from the image into the volume, but only when the image's version is newer than the one in the volume. Registration and `_work` are left alone. The runner can also update itself.

## Running Docker commands in workflows (optional)

The image includes the Docker CLI with the buildx and compose plugins, but no daemon. To let workflows use the **host** Docker daemon, add this to `.env`:

```
COMPOSE_FILE=docker-compose.yml:docker-compose.docker-socket.yml
```

then `docker compose up -d`. At startup the entrypoint finds the socket's group ID and gives the `runner` user access to it.

> ⚠️ Mounting `/var/run/docker.sock` gives every workflow **root-equivalent control of the host**. Only do this for private repositories you fully control. A safer but more complex alternative is a separate Docker-in-Docker sidecar.

## Multiple runners

Give each runner its own Compose project. Each project gets its own volume.

```bash
RUNNER_NAME=runner-2 ./setup.sh -p runner2
docker compose -p runner2 logs -f
```

## Automatic registration and ephemeral runners

If you set `RUNNER_URL` and `ACCESS_TOKEN` (a fine-grained PAT) in `.env`, the container registers itself on first start, so `setup.sh` isn't needed.

- Repository runner: the PAT needs **Administration: Read and write** on that repo.
- Organization runner: the PAT needs **Self-hosted runners: Read and write** on the org.

With `RUNNER_EPHEMERAL=true`, the runner deregisters after one job. The container then restarts and registers again using the PAT. The `/runner` volume still persists between jobs. For strict isolation, recreate the container and volume between jobs instead.

Keeping a PAT on disk is a trade-off. For a single long-lived runner, the one-time `setup.sh` flow is safer.

## Removing a runner

```bash
docker compose stop
# Removal token: Settings → Actions → Runners → <runner> → Remove
RUNNER_TOKEN=<removal-token> docker compose run --rm -e RUNNER_TOKEN github-runner remove
docker compose down -v      # deletes the volume
```

If you delete the volume without unregistering, GitHub keeps an offline runner entry. You can remove it in the UI.

## Security notes

- GitHub [advises against](https://docs.github.com/en/actions/reference/security/secure-use) self-hosted runners for **public** repositories. Pull requests from forks can run arbitrary code on your machine.
- Prefer repository-scoped runners and only trusted repos.
- `no-new-privileges` is enabled, so `sudo` is not available inside jobs. To get extra tools, extend the image (`FROM <image>` plus `RUN apt-get install ...`) instead of installing them at job time.
- Don't mount host application directories or secrets into the runner.

## Publishing the image (maintainers)

`.github/workflows/docker-publish.yml` builds multi-arch images, pushing on `main`, on `v*` tags, and on a weekly schedule. Pull requests are built but not pushed. Configure the repository with:

- **Variable** `DOCKERHUB_USERNAME`: your Docker Hub namespace
- **Variable** `IMAGE_REPO` (optional): defaults to `github-runner`
- **Secret** `DOCKERHUB_TOKEN`: a Docker Hub access token with Read & Write scope

Tags: `latest`, `<runner-version>` (e.g. `2.338.2`), `sha-<commit>`, and `<semver>` for `v*` git tags. Each build uses whichever is newer: the latest runner release or `ARG RUNNER_VERSION` in the `Dockerfile`. That way a push never moves `latest` back to an older runner. If the build is ahead of the pin, it logs a warning so you know to bump the pin. Edits to Markdown files alone don't trigger a build.

Manual build and push:

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -t <dockerhub-user>/github-runner:latest --push .
```
