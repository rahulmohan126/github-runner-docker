# Agent instructions

This repo contains a Docker image and Compose stack for GitHub Actions self-hosted runners. Agents usually work on it for one of two reasons:

1. **Setting up a runner** on the user's machine. This is the most common case. Follow the runbook below.
2. **Changing the image or repo**. See "Working on this repo" at the end.

Background reading for both: [README.md](README.md).

---

## Runbook: set up a runner on this machine

Work through the steps in order and stop to ask the user wherever a step says to.

### 0. Ground rules

- **Never write a registration token, removal token or PAT to any file**, including `.env`, shell history files, notes and commit messages. Pass tokens only as environment variables on a single command. The exception is when the user explicitly chooses PAT mode (step 3b): the PAT then goes in `.env`, which is gitignored. Say clearly that it is stored on disk.
- Registration tokens expire about **1 hour** after they are generated. Ask for the token only when you are ready to run `setup.sh`, not earlier.
- `.env.example` enables host Docker socket access and host networking by default, because this deployment's CI needs them. Before keeping that default, explain that it gives workflows root-equivalent access to the host and get confirmation. If the user declines, comment out `COMPOSE_FILE` and `DOCKER_GID` in `.env`.
- Do not enable PAT mode or ephemeral mode unless the user asks for it or agrees after you explain the trade-offs.
- Do not use this runner for **public** repositories without warning the user. Fork PRs can run arbitrary code on their machine.

### 1. Check prerequisites

```bash
docker version            # the daemon must be reachable, not just the CLI
docker compose version    # Compose v2 plugin required
uname -m                  # x86_64 or aarch64/arm64; both are supported
```

- If Docker isn't installed or running, stop and tell the user. Don't install Docker yourself unless they ask.
- On Linux, if `docker` requires sudo, the user isn't in the `docker` group. Tell them rather than running everything with sudo.

### 2. Gather inputs from the user

Ask for:

1. **Runner scope URL**: either `https://github.com/<owner>/<repo>` (recommended) or `https://github.com/<org>` for an org-wide runner.
2. **Runner name** (default `home-server-runner`). It must be unique among the runners registered at that scope. If this machine already runs one, suggest something like `<hostname>-runner-2`.
3. **Labels** (default `docker,self-hosted,linux`). Suggest adding a project-specific label, such as the repo or org name, so workflows can target this runner.
4. **Runner directory** `RUNNER_ROOT` (default `/srv/github-runner`). It is bind-mounted at the same path inside the container and must be unique per runner, e.g. `/srv/github-runner-2` for a second one.
5. **Image source**:
   - *Pull* the published image `rahulmohan126/github-runner:latest` (from Docker Hub), or another image the user names.
   - *Build* locally (the default if they have no published image).
6. Confirm **Docker access** (on by default, see step 0). It mounts the host Docker socket, gives workflows root-equivalent access to the host, and puts the runner on the host network. Get explicit confirmation.

### 3. Configure `.env`

```bash
cp -n .env.example .env
```

Edit `.env` and set:

- `RUNNER_NAME=...`
- `RUNNER_LABELS=...`
- `RUNNER_ROOT=...` (absolute path; `setup.sh` creates it owned by 1001:1001)
- `RUNNER_IMAGE=...` (pull mode only; leave it commented out to build)
- `DOCKER_GID=<gid>` (required while `COMPOSE_FILE` includes `docker-compose.docker-socket.yml`; comment out both if Docker access was declined)

Find `DOCKER_GID` as the socket's group ID seen from inside a container. It is usually `0` on Docker Desktop and the `docker` group's GID on Linux:

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock busybox stat -c %g /var/run/docker.sock
```

#### 3b. Optional: PAT mode (automatic or ephemeral registration)

Use this only if the user wants zero-touch re-registration or `RUNNER_EPHEMERAL=true`. In `.env`, set `RUNNER_URL`, `ACCESS_TOKEN` (a fine-grained PAT) and optionally `RUNNER_EPHEMERAL=true`.

- Repo scope: the PAT needs **Administration: Read and write**.
- Org scope: the PAT needs **Self-hosted runners: Read and write**.

Then skip step 4. Create the runner directory first, because nothing else does in this mode, then start:

```bash
docker compose run --rm --no-deps --user 0 --entrypoint install github-runner -d -o 1001 -g 1001 -m 0755 "<RUNNER_ROOT>"
docker compose up -d       # add --build if building locally
```

### 4. Register and start

Ask the user to generate a registration token now:

- Repo: **Settings → Actions → Runners → New self-hosted runner**. Copy the value after `--token` from the configure command shown. They don't need to run any other command on that page.
- Org: **Org Settings → Actions → Runners → New runner**.

Then run the setup non-interactively. `setup.sh` uses `read` prompts, which an agent can't answer, so pass everything through the environment:

```bash
RUNNER_URL='<url>' RUNNER_TOKEN='<token>' ./setup.sh          # --pull or --build is inferred from RUNNER_IMAGE
# second runner on the same machine:
RUNNER_NAME='<name>-2' RUNNER_ROOT=/srv/github-runner-2 RUNNER_URL='<url>' RUNNER_TOKEN='<token>' ./setup.sh -p runner2
```

If the user would rather not paste the token into the agent, have them run it themselves in this session with `! ./setup.sh`. That runs the interactive prompts.

### 5. Verify

```bash
docker compose ps                          # add -p <project> if you used one
docker compose logs --tail 50 github-runner
```

Success looks like `Connected to GitHub` followed by `Listening for Jobs`. Ask the user to confirm the runner shows as **Idle** under *Settings → Actions → Runners* with the expected labels. For a full check, suggest copying [examples/runner-acceptance.yml](examples/runner-acceptance.yml) into the repo the runner is registered to and running it.

### 6. Troubleshooting

| Symptom | Cause / fix |
| ------- | ----------- |
| `Runner is not configured.` and the container restarts in a loop | Registration never succeeded. `docker compose stop`, then rerun step 4 with a new token. |
| `404 Not Found ... runner-registration` | The token is wrong or expired, or the URL scope doesn't match where the token was generated. Generate a new token. |
| `A runner exists with the same name` | Already handled: the entrypoint passes `--replace`. If it still fails, pick a different `RUNNER_NAME`. |
| `permission denied ... docker.sock` in a job | The socket override isn't active, or `DOCKER_GID` is wrong. The entrypoint logs the socket's actual GID at startup. Check `COMPOSE_FILE` and `DOCKER_GID` in `.env`, then `docker compose up -d --force-recreate`. |
| `<RUNNER_ROOT> is not writable by uid 1001` or files in `_diag` not owned by 1001 | The host directory was created or modified as root. Fix it once: `docker compose run --rm --user 0 --entrypoint chown github-runner -R 1001:1001 <RUNNER_ROOT>`. |
| `Runner is not configured.` after upgrading from the old `/runner` volume | The registration is still in the old volume. Re-register, or run `migrate`. See "Migrating from the `/runner` volume" in README.md. |
| A job can't reach `localhost:<port>` of a service container | Host networking is off: `COMPOSE_FILE` must include `docker-compose.docker-socket.yml`. |
| `docker run -v "$PWD/..."` in a job mounts an empty directory | The work directory isn't at the same path on the host. Check `RUNNER_ROOT`, and that `RUNNER_WORKDIR` is unset or inside it. |
| `Container feature is not supported when runner is already running inside container` | The host uses cgroup v1. Use a cgroup v2 host (`docker info --format '{{.CgroupVersion}}'` prints `2`). |
| `actions/checkout` fails with `EACCES` / permission denied while cleaning | A container wrote root-owned files into the workspace. Delete them with `docker run --rm -v "$RUNNER_ROOT/_work:/w" busybox rm -rf /w/<repo>`, and run such containers with `--user`. |
| Second runner on the host logs "holds the registration of runner ..." | Two compose projects share one `RUNNER_ROOT`. Give each runner its own. |
| `playwright install --with-deps` / `install-deps` fails (sudo or apt) | Expected. The libraries are in the image; use `npx playwright install chromium`. |
| `sudo: ... no new privileges` in a job | Expected, because `no-new-privileges` is on. Extend the image with the needed packages instead. |
| Runner offline in GitHub after an image update | Check `docker compose logs`, and use `docker compose run --rm github-runner version` to compare the image and runner-directory versions. |

### 7. Removing a runner

```bash
docker compose stop
RUNNER_TOKEN='<removal token from GitHub UI>' docker compose run --rm -e RUNNER_TOKEN github-runner remove
docker compose down
sudo rm -rf '<RUNNER_ROOT>'  # destructive: deletes the registration and _work. Confirm with the user first.
```

---

## Working on this repo

| File | Role |
| ---- | ---- |
| `Dockerfile` | Ubuntu 24.04, build tools, Chromium libraries (via a throwaway Node + `playwright install-deps`), runner binaries in `/opt/runner-dist`, Docker CLI (`INSTALL_DOCKER_CLI`), pinned `ARG RUNNER_VERSION`, `USER runner` (uid/gid pinned to 1001) |
| `entrypoint.sh` | Runs as `runner`, never root: syncs binaries into `RUNNER_ROOT` (default `/srv/github-runner`), removes stale foreign-owned `_diag` logs, checks socket access. Commands: `run`, `configure`, `remove`, `version`, `migrate` |
| `docker-compose.yml` | Single `github-runner` service with `RUNNER_ROOT` bind-mounted at the same path. Uses `image:` and `build:` so pull and build both work |
| `docker-compose.docker-socket.yml` | Host socket plus `network_mode: host`; enabled by default in `.env.example` |
| `examples/runner-acceptance.yml` | Acceptance workflow to copy into the repo the runner serves |
| `setup.sh` | Builds or pulls the image, registers in a one-off container, starts the stack |
| `.github/workflows/docker-publish.yml` | Multi-arch build. Pushes to Docker Hub on `main`, `v*` tags and a weekly schedule |

Conventions and constraints:

- Keep `CONTEXT.md` **untracked**. It is a local reference note and is gitignored. Do not delete it.
- Keep secrets out of the image, Compose files and `.env.example`.
- To bump the runner, change `ARG RUNNER_VERSION` in `Dockerfile`. Latest version: `curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name`.
- The whole container runs as the unprivileged `runner` user (uid/gid 1001, pinned in the `Dockerfile`), including the entrypoint and `docker-init`. Do not add root-only steps to `entrypoint.sh`: there is no root and no sudo (`no-new-privileges`). Root-only setup belongs at build time.
- Docker socket access comes from Compose `group_add: [DOCKER_GID]` in `docker-compose.docker-socket.yml`.
- The runner directory must be at the same absolute path on the host and in the container, because jobs' bind mounts are resolved by the host daemon. Don't reintroduce a named volume or a fixed in-container path.
- Jobs have no sudo or apt. System packages workflows need (e.g. Playwright's `--with-deps`) must be baked into the `Dockerfile`.
- Never execute `Runner.Listener` (even `--version`) from the entrypoint. Every invocation writes a log to `$RUNNER_ROOT/_diag`, and those names have one-second resolution, so the log can collide with the real listener's. Read the version from `bin/Runner.Listener.deps.json` instead.

Verify changes before committing:

```bash
bash -n entrypoint.sh setup.sh
docker compose config -q
export RUNNER_ROOT="$(mktemp -d)"   # any absolute path Docker can bind-mount (on macOS, under /private/tmp)
docker buildx build --platform linux/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') --load -t github-runner:local .
docker compose -p citest run --rm --no-deps --user 0 --entrypoint install github-runner -d -o 1001 -g 1001 -m 0755 "$RUNNER_ROOT"   # as setup.sh does
docker compose -p citest run --rm github-runner version    # prints image and runner-dir versions
docker compose -p citest run --rm github-runner            # expect "Runner is not configured." exit 1
docker compose -p citest run --rm github-runner bash -c 'id; find "$RUNNER_ROOT" -user 0'   # uid=1001, no output from find
docker compose -p citest run --rm --no-deps --user 0 --entrypoint find github-runner "$RUNNER_ROOT" -mindepth 1 -delete   # files are owned by 1001
docker compose -p citest down -v && rm -rf "$RUNNER_ROOT"
```

Do not register a real runner as part of testing unless the user provides a token for that purpose.
