# github-runner-docker

A Docker image and Compose stack for running **GitHub Actions self-hosted runners** in containers.

- Ubuntu 24.04 with the official [actions/runner](https://github.com/actions/runner) binaries
- Multi-arch images (`linux/amd64`, `linux/arm64`)
- The whole container runs as a non-root `runner` user (uid/gid 1001), with no root step at startup, `no-new-privileges` and all capabilities dropped
- **No Docker access by default.** Jobs cannot reach the host's Docker daemon, so a workflow cannot become root on the host. Jobs that need Docker go to a different runner (see [What runs without Docker](#what-runs-without-docker)).
- Build tools for typical CI: gcc and `build-essential` (cgo, `go test -race`), and Chromium's system libraries for headless Playwright. Language toolchains come per job from your setup actions (e.g. `jdx/mise-action`).
- Registration and the work directory live in a host directory (`/srv/github-runner` by default), so the runner survives restarts and reboots
- The one-time registration token is never written to disk
- Optional extras: host Docker access (opt-in, root-equivalent), ephemeral runners, automatic PAT-based registration, several runners on one host
- A weekly CI rebuild keeps the runner version current. GitHub stops sending jobs to outdated runners.

> **Using an AI coding agent?** Point it at [AGENTS.md](AGENTS.md). It is a step-by-step runbook for setting up a runner on a new machine.

## Quick start

Requirements: Docker Engine (or Docker Desktop) with the Compose v2 plugin.

```bash
git clone https://github.com/rahulmohan126/github-runner-docker.git
cd github-runner-docker
cp .env.example .env        # set RUNNER_NAME / RUNNER_LABELS, optionally RUNNER_IMAGE
./setup.sh                  # prompts for the repo URL and a registration token
```

To get a registration token (valid for about 1 hour), open **Repository → Settings → Actions → Runners → New self-hosted runner** and copy the token from the `--token` argument shown there. You don't need to run any of the other commands on that page. For an organization-wide runner, use **Org → Settings → Actions → Runners → New runner** and pass `https://github.com/<org>` as the URL.

`setup.sh` builds the image (or pulls it, if `RUNNER_IMAGE` is set), creates the runner directory (`RUNNER_ROOT`, default `/srv/github-runner`) owned by uid/gid 1001 if needed, registers the runner in a one-off container, then starts it with `docker compose up -d`.

Verify:

```bash
docker compose logs -f github-runner   # expect "Connected to GitHub" / "Listening for Jobs"
```

The runner should also show as **Idle** under *Settings → Actions → Runners*, with your labels. To check everything a CI job needs, run the [acceptance workflow](#acceptance-checks).

Non-interactive setup:

```bash
RUNNER_URL=https://github.com/<owner>/<repo> RUNNER_TOKEN=<token> ./setup.sh
```

Variables given on the command line take precedence over `.env`, in `setup.sh` as in `docker compose`.

## Using it in a workflow

```yaml
jobs:
  test:
    runs-on: [self-hosted, linux, my-project]    # a label from RUNNER_LABELS
    steps:
      - uses: actions/checkout@v7
      - run: uname -a && whoami
```

### What runs without Docker

By default the runner has no Docker daemon. Route jobs accordingly:

| Works on this runner | Needs a runner with Docker (e.g. GitHub's `ubuntu-latest`) |
|---|---|
| `go test -race` and other cgo builds (gcc) | Actions `services:` (Postgres, Redis, ...). The runner starts these through Docker. |
| Headless Playwright Chromium | testcontainers |
| Toolchains from `jdx/mise-action` and other setup actions | `docker build`, `docker run`, `docker compose` |
| Lint, unit tests, builds | `container:` jobs and Docker-based actions (`uses: docker://...`) |

The Docker CLI is in the image but has nothing to talk to; the entrypoint logs `Docker: not available` at startup. To allow Docker on a particular runner anyway, see [Host Docker access (opt-in)](#host-docker-access-opt-in).

### Differences from `ubuntu-latest`

- **No sudo, no apt at job time.** Jobs run as `runner` with `no-new-privileges`. Anything that needs system packages must be baked into the image (extend it with `FROM <image>` and `RUN apt-get install ...`).
- **Playwright: drop `--with-deps`.** Chromium's system libraries and fonts are already in the image (installed at build time by `playwright install-deps chromium`). Use `npx playwright install chromium`, not `--with-deps` or `install-deps`, which call apt and fail without sudo. Passwordless sudo for apt-get was rejected on purpose. It would mean dropping `no-new-privileges`, and `sudo apt-get` is root in practice. Firefox and WebKit libraries are not included.
- **Toolchains are not preinstalled.** Go, Node, pnpm and so on come from your setup actions, e.g. `jdx/mise-action`. The image provides `build-essential` (gcc, make), `python3`, `xz-utils`, `procps`, `iproute2`, `netcat-openbsd`, `postgresql-client` (`pg_isready`, `psql`), `git`, `curl`, `jq`, `zip`/`unzip`, and the Docker CLI with buildx and compose.
- **No Docker** unless the opt-in override is enabled (above).

## Configuration (`.env`)

| Variable           | Default (`.env.example`)    | Purpose                                                        |
| ------------------ | --------------------------- | -------------------------------------------------------------- |
| `RUNNER_IMAGE`     | `github-runner:local`       | Image to run. Set to `rahulmohan126/github-runner:latest` to pull instead of build. |
| `RUNNER_NAME`      | `home-server-runner`        | Runner name shown in GitHub (must be unique)                   |
| `RUNNER_LABELS`    | `self-hosted,linux`         | Comma-separated labels for `runs-on`; add a project-specific one, and `docker` only with Docker access. Applied at registration only. |
| `RUNNER_ROOT`      | `/srv/github-runner`        | Host directory for binaries, registration and `_work`, mounted at the same path in the container. One per runner. |
| `COMPOSE_FILE`     | — (commented out)           | Set to `docker-compose.yml:docker-compose.docker-socket.yml` for [host Docker access](#host-docker-access-opt-in) (root-equivalent) |
| `DOCKER_GID`       | —                           | Required with the Docker override: the socket's group ID inside a container |
| `RUNNER_EPHEMERAL` | `false`                     | Register with `--ephemeral` (one job per registration)         |
| `RUNNER_URL`       | —                           | Needed only for automatic registration                         |
| `ACCESS_TOKEN`     | —                           | PAT used to fetch registration tokens automatically (see below) |

Variables the entrypoint also accepts: `RUNNER_GROUP` (org runner group), `RUNNER_WORKDIR` (default `$RUNNER_ROOT/_work`; must stay inside `RUNNER_ROOT`), `RUNNER_DISABLE_UPDATE`, `GITHUB_API_URL` (GHES).

Changing `RUNNER_LABELS` after registration has no effect on an existing runner. Either edit the labels in the GitHub UI (*Settings → Actions → Runners → runner*), or register again. `config.sh` refuses to configure over an existing registration, so delete the local registration files first. `--replace` then takes over the runner's name on GitHub:

```bash
docker compose stop
docker compose run --rm --no-deps --entrypoint bash github-runner \
  -c 'rm -f "$RUNNER_ROOT"/.runner "$RUNNER_ROOT"/.credentials "$RUNNER_ROOT"/.credentials_rsaparams'
./setup.sh                                 # new registration token
```

## Day-to-day commands

| Operation       | Command                                  |
| --------------- | ---------------------------------------- |
| Start / stop    | `docker compose up -d` / `docker compose stop` |
| Logs            | `docker compose logs -f`                 |
| Status          | `docker compose ps`                      |
| Runner version  | `docker compose run --rm github-runner version` |
| Update (pulled) | `docker compose pull && docker compose up -d` |
| Update (built)  | `docker compose build --pull && docker compose up -d` |

On start, the entrypoint copies the runner binaries from the image into `RUNNER_ROOT`, but only when the image's version is newer than the one already there. Registration and `_work` are left alone. The runner can also update itself.

## Host Docker access (opt-in)

> ⚠️ **Off by default, and root-equivalent when on.** Mounting the host's `/var/run/docker.sock` lets every workflow on this runner become **root on the host** (for example `docker run --privileged -v /:/host ...`). It can also control every other container on the machine, including other runners' jobs, and read their runner directories and credentials. The runner's non-root user, `no-new-privileges` and dropped capabilities do not limit containers that a job asks the host daemon to start. Only enable this on a machine where that is acceptable. Otherwise send Docker jobs to a different runner.

`docker-compose.docker-socket.yml` makes Docker jobs work as they do on `ubuntu-latest`. To enable it, add to `.env`:

```
COMPOSE_FILE=docker-compose.yml:docker-compose.docker-socket.yml
DOCKER_GID=<gid>
```

`DOCKER_GID` is the socket's group ID as seen inside a container. It is usually `0` on Docker Desktop and the `docker` group's GID on Linux:

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock busybox stat -c %g /var/run/docker.sock
```

Also add a `docker` label to `RUNNER_LABELS` before registering, so Docker jobs can target this runner with `runs-on: [self-hosted, docker]`. Then run `docker compose up -d --force-recreate`.

The override provides three things:

1. **Docker daemon.** The socket is mounted and its group is added to the `runner` user with Compose `group_add`. `docker build/run/compose` and testcontainers talk to the host daemon. If the GID is wrong, the entrypoint logs the socket's actual GID at startup.
2. **Service containers on `localhost`.** Containers started on the host daemon publish their ports on the host. The runner uses `network_mode: host`, so `localhost:5432` in a step reaches a service with `ports: ["5432:5432"]`. As a side effect, anything a job listens on listens on the host, and jobs can reach every service bound to the host's `localhost`.
3. **Bind mounts from the workspace.** The host daemon resolves bind-mount sources on the host. That is why `RUNNER_ROOT` is mounted at the same absolute path on both sides, so `docker run -v "$PWD/file:/x"` and compose `./nginx/templates` volumes see the checked-out files.

Caveats with the override:

- **Only paths under `RUNNER_ROOT` exist on the host.** The workspace, `$RUNNER_TEMP` and `$RUNNER_TOOL_CACHE` work as bind-mount sources. `/tmp`, `$HOME` and anything else inside the runner container do not.
- **Files written as root by containers stay root-owned.** The runner (no sudo) can't delete them, and the next `actions/checkout` fails. Run such containers with `--user "$(id -u):$(id -g)"` (compose: `user:`).
- **The host must use cgroup v2** (`docker info --format '{{.CgroupVersion}}'` prints `2`). On cgroup v1 the runner decides it is inside a container and rejects `services:` and `container:` jobs. The entrypoint warns at startup when that is the case.
- **Concurrent jobs share the host daemon and network.** See the collisions under [Multiple runners](#multiple-runners-concurrency).

> Upgrading from an image older than the non-root change? The entrypoint no longer edits `/etc/group` at startup, so add `DOCKER_GID` to `.env` and update `docker-compose.docker-socket.yml` from this repo.

## Multiple runners (concurrency)

One runner runs one job at a time. To run N jobs in parallel, run N runners. Each needs its own Compose project, `RUNNER_NAME` and `RUNNER_ROOT`. One registration token can register several runners within its hour:

```bash
read -rs RUNNER_TOKEN && export RUNNER_TOKEN      # paste the token; not echoed or saved
export RUNNER_URL=https://github.com/<owner>/<repo>
for i in 2 3 4 5 6 7; do
  RUNNER_NAME="home-server-runner-$i" RUNNER_ROOT="/srv/github-runner-$i" ./setup.sh -p "runner$i"
done
unset RUNNER_TOKEN
docker compose -p runner3 logs -f
```

Every later `docker compose` command for one of these runners needs the same `-p`, `RUNNER_NAME` and `RUNNER_ROOT`, e.g. `RUNNER_NAME=home-server-runner-3 RUNNER_ROOT=/srv/github-runner-3 docker compose -p runner3 up -d`. Alternatively keep a separate checkout or `.env` per runner.

Several runners can also be services in one compose file. Each needs its own `RUNNER_NAME`, and its own `RUNNER_ROOT` mounted at the same path:

```yaml
x-runner: &runner
  image: rahulmohan126/github-runner:latest
  restart: unless-stopped
  init: true
  security_opt: ["no-new-privileges:true"]
  cap_drop: [ALL]
  stop_grace_period: 2m

services:
  app-runner-1:
    <<: *runner
    environment: { RUNNER_NAME: host-app-1, RUNNER_LABELS: "self-hosted,linux,app", RUNNER_ROOT: /srv/github-runners/app-1 }
    volumes:
      - /srv/github-runners/app-1:/srv/github-runners/app-1
```

Register each one once with `RUNNER_URL=... RUNNER_TOKEN=... docker compose run --rm --no-deps -e RUNNER_URL -e RUNNER_TOKEN app-runner-1 configure`, after creating its directory as shown under [Migrating](#migrating-from-the-runner-volume).

`docker compose up --scale github-runner=N` does **not** work: replicas would share one runner directory, and therefore one registration and one name.

With the [Docker override](#host-docker-access-opt-in), all runners share the host's daemon and network, so the **CI workflows** have to avoid two kinds of collision:

- **Fixed host ports.** Two concurrent jobs with `ports: ["5432:5432"]` cannot both bind host port 5432, and the second job's service fails to start. Use a random host port (`ports: ["5432"]`) and read it from `${{ job.services.postgres.ports['5432'] }}`, as testcontainers already does.
- **Compose project names.** `docker compose` names a project after the directory, so the same repo checked out on two runners gives two projects with the same name, and they stop each other's containers. Set a unique `COMPOSE_PROJECT_NAME` per job, e.g. `${{ github.job }}-${{ github.run_id }}-${{ github.run_attempt }}`.

Fixed container names (`container_name:`, `docker run --name`) collide the same way.

## Acceptance checks

[`examples/runner-acceptance.yml`](examples/runner-acceptance.yml) is a `workflow_dispatch` workflow. Copy it into the repository the runner is registered to, set `runs-on` to your label, and run it from the Actions tab.

The `acceptance` job runs on every runner and checks:

- the job is picked up by `runs-on: [self-hosted, linux, <your-label>]`, which shows the runner is online with that label
- `gcc --version`, and `go test -race` on a trivial package after installing Go with `jdx/mise-action`
- `npx playwright install chromium` (no `--with-deps`) followed by a headless Chromium launch
- that Docker is **not** reachable (unless the `docker` input is ticked)

The `docker` job runs only when you tick the `docker` input, and only on a runner with the [Docker override](#host-docker-access-opt-in) and a `docker` label. It checks `docker run`, a Postgres service reached with `pg_isready -h localhost`, a Redis service on a random port, a same-path bind mount from the checkout, `docker compose` with a `./nginx/templates` mount, and `docker build`.

## Migrating from the `/runner` volume

Older versions of this stack kept everything in a named volume (`<project>_runner-data`, mounted at `/runner`). The new compose file no longer mounts it. Pick one of these:

**Re-register (recommended).** This also applies the new labels.

```bash
docker compose stop
git pull                                   # new compose files; update .env from .env.example
./setup.sh                                 # new registration token; --replace keeps the same name
docker volume rm <project>_runner-data     # once the runner is Idle in GitHub
```

**Keep the existing registration.** Copy it out of the old volume. `_work` and `_diag` are not copied.

```bash
docker compose stop
git pull                                   # update .env from .env.example
docker compose build                       # or: docker compose pull
docker compose run --rm --no-deps --user 0 --cap-add CHOWN --cap-add FOWNER \
  --entrypoint install github-runner -d -o 1001 -g 1001 -m 0755 /srv/github-runner   # your RUNNER_ROOT
docker compose run --rm -v <project>_runner-data:/runner github-runner migrate
docker compose up -d
docker volume rm <project>_runner-data     # once the runner works
```

The labels of a migrated registration don't change. Edit them in the GitHub UI under *Settings → Actions → Runners → runner*. In particular, older defaults included `docker`. Remove it from runners without the Docker override, or Docker jobs will be sent to a runner that can't run them. `<project>` is the Compose project name, which is the checkout's directory name unless you used `-p` (`docker volume ls | grep runner-data`).

## Automatic registration and ephemeral runners

If you set `RUNNER_URL` and `ACCESS_TOKEN` (a fine-grained PAT) in `.env`, the container registers itself on first start, so `setup.sh` isn't needed. The runner directory must still exist and be owned by 1001:1001; see the `install` command under [Migrating](#migrating-from-the-runner-volume).

- Repository runner: the PAT needs **Administration: Read and write** on that repo.
- Organization runner: the PAT needs **Self-hosted runners: Read and write** on the org.

With `RUNNER_EPHEMERAL=true`, the runner deregisters after one job. The container then restarts and registers again using the PAT. The runner directory, including `_work`, persists between jobs. For strict isolation, recreate the container and clear the directory between jobs instead.

Keeping a PAT on disk is a trade-off. For a single long-lived runner, the one-time `setup.sh` flow is safer.

## Removing a runner

```bash
docker compose stop
# Removal token: Settings → Actions → Runners → <runner> → Remove
RUNNER_TOKEN=<removal-token> docker compose run --rm -e RUNNER_TOKEN github-runner remove
docker compose down
sudo rm -rf /srv/github-runner   # your RUNNER_ROOT: binaries, registration, _work
```

If you delete the directory without unregistering, GitHub keeps an offline runner entry. You can remove it in the UI.

## Security notes

- GitHub [advises against](https://docs.github.com/en/actions/reference/security/secure-use) self-hosted runners for **public** repositories. Pull requests from forks can run arbitrary code on your machine. With the opt-in Docker override, that code is root on the host.
- Prefer repository-scoped runners and only trusted repos.
- By default a job has no route to root on the host: it runs as uid 1001 with `no-new-privileges`, no capabilities and no Docker socket. What remains is the general risk of a kernel or container-runtime escape bug, so keep the host patched.
- `no-new-privileges` is enabled, so `sudo` is not available inside jobs. To get extra tools, extend the image (`FROM <image>` plus `RUN apt-get install ...`) instead of installing them at job time.
- Don't mount host application directories or secrets into the runner.

## Publishing the image (maintainers)

`.github/workflows/docker-publish.yml` builds multi-arch images, pushing on `main`, on `v*` tags, and on a weekly schedule. Pull requests are built but not pushed. Configure the repository with:

- **Variable** `DOCKERHUB_USERNAME`: your Docker Hub namespace
- **Variable** `IMAGE_REPO` (optional): defaults to `github-runner`
- **Secret** `DOCKERHUB_TOKEN`: a Docker Hub access token with Read & Write scope

Tags: `latest`, `<runner-version>` (e.g. `2.338.2`), `sha-<commit>`, and `<semver>` for `v*` git tags. Each build uses whichever is newer: the latest runner release or `ARG RUNNER_VERSION` in the `Dockerfile`. That way a push never moves `latest` back to an older runner. If the build is ahead of the pin, it logs a warning so you know to bump the pin. Edits to Markdown files alone don't trigger a build.

The Chromium libraries come from `playwright@${PLAYWRIGHT_VERSION}` (build arg, default `latest`) using a throwaway Node (`BUILD_NODE_VERSION`), so the weekly rebuild follows Playwright's dependency list.

Manual build and push:

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -t rahulmohan126/github-runner:latest --push .
```
