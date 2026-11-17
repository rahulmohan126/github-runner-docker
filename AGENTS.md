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
- Do not enable Docker socket access, PAT mode or ephemeral mode unless the user asks for it or agrees after you explain the trade-offs.
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
3. **Labels** (default `docker,self-hosted,linux`).
4. **Image source**:
   - *Pull* the published image `rahulmohan126/github-runner:latest` (from Docker Hub), or another image the user names.
   - *Build* locally (the default if they have no published image).
5. Whether workflows need to **run Docker commands** (build or push images). If yes, explain that this mounts the host Docker socket and gives workflows root-equivalent access to the host, then get explicit confirmation.

### 3. Configure `.env`

```bash
cp -n .env.example .env
```

Edit `.env` and set:

- `RUNNER_NAME=...`
- `RUNNER_LABELS=...`
- `RUNNER_IMAGE=...` (pull mode only; leave it commented out to build)
- `COMPOSE_FILE=docker-compose.yml:docker-compose.docker-socket.yml` (only if Docker access was confirmed)

No `DOCKER_GID` is needed. The entrypoint detects the socket's group at runtime.

#### 3b. Optional: PAT mode (automatic or ephemeral registration)

Use this only if the user wants zero-touch re-registration or `RUNNER_EPHEMERAL=true`. In `.env`, set `RUNNER_URL`, `ACCESS_TOKEN` (a fine-grained PAT) and optionally `RUNNER_EPHEMERAL=true`.

- Repo scope: the PAT needs **Administration: Read and write**.
- Org scope: the PAT needs **Self-hosted runners: Read and write**.

Then skip step 4 and run `docker compose up -d` (adding `--build` if building locally).

### 4. Register and start

Ask the user to generate a registration token now:

- Repo: **Settings → Actions → Runners → New self-hosted runner**. Copy the value after `--token` from the configure command shown. They don't need to run any other command on that page.
- Org: **Org Settings → Actions → Runners → New runner**.

Then run the setup non-interactively. `setup.sh` uses `read` prompts, which an agent can't answer, so pass everything through the environment:

```bash
RUNNER_URL='<url>' RUNNER_TOKEN='<token>' ./setup.sh          # --pull or --build is inferred from RUNNER_IMAGE
# second runner on the same machine:
RUNNER_URL='<url>' RUNNER_TOKEN='<token>' ./setup.sh -p runner2
```

If the user would rather not paste the token into the agent, have them run it themselves in this session with `! ./setup.sh`. That runs the interactive prompts.

### 5. Verify

```bash
docker compose ps                          # add -p <project> if you used one
docker compose logs --tail 50 github-runner
```

Success looks like `Connected to GitHub` followed by `Listening for Jobs`. Ask the user to confirm the runner shows as **Idle** under *Settings → Actions → Runners*. If they want, suggest this test workflow:

```yaml
name: Self-hosted runner test
on: workflow_dispatch
jobs:
  test:
    runs-on: [self-hosted, linux, docker]
    steps:
      - uses: actions/checkout@v4
      - run: uname -a && whoami && (docker version || true)
```

### 6. Troubleshooting

| Symptom | Cause / fix |
| ------- | ----------- |
| `Runner is not configured.` and the container restarts in a loop | Registration never succeeded. `docker compose stop`, then rerun step 4 with a new token. |
| `404 Not Found ... runner-registration` | The token is wrong or expired, or the URL scope doesn't match where the token was generated. Generate a new token. |
| `A runner exists with the same name` | Already handled: the entrypoint passes `--replace`. If it still fails, pick a different `RUNNER_NAME`. |
| `permission denied ... docker.sock` in a job | The socket override isn't active. Check `COMPOSE_FILE` in `.env`, then `docker compose up -d --force-recreate`. |
| `sudo: ... no new privileges` in a job | Expected, because `no-new-privileges` is on. Extend the image with the needed packages instead. |
| Runner offline in GitHub after an image update | Check `docker compose logs`, and use `docker compose run --rm github-runner version` to compare image and volume versions. |

### 7. Removing a runner

```bash
docker compose stop
RUNNER_TOKEN='<removal token from GitHub UI>' docker compose run --rm -e RUNNER_TOKEN github-runner remove
docker compose down -v     # destructive: deletes the runner volume. Confirm with the user first.
```

---

## Working on this repo

| File | Role |
| ---- | ---- |
| `Dockerfile` | Ubuntu 24.04, runner binaries in `/opt/runner-dist`, Docker CLI (`INSTALL_DOCKER_CLI`), pinned `ARG RUNNER_VERSION` |
| `entrypoint.sh` | Root init: sync binaries into the `/runner` volume, fix ownership, grant socket group. Then `gosu runner`. Commands: `run`, `configure`, `remove`, `version` |
| `docker-compose.yml` | Single `github-runner` service plus a named volume. Uses `image:` and `build:` so pull and build both work |
| `docker-compose.docker-socket.yml` | Opt-in override that mounts the host socket |
| `setup.sh` | Builds or pulls the image, registers in a one-off container, starts the stack |
| `.github/workflows/docker-publish.yml` | Multi-arch build. Pushes to Docker Hub on `main`, `v*` tags and a weekly schedule |

Conventions and constraints:

- Keep `CONTEXT.md` **untracked**. It is a local reference note and is gitignored. Do not delete it.
- Keep secrets out of the image, Compose files and `.env.example`.
- To bump the runner, change `ARG RUNNER_VERSION` in `Dockerfile`. Latest version: `curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name`.
- Workflows run as the unprivileged `runner` user (uid 1001). Do not make the runner process run as root.
- `group_add` in Compose does **not** work for the runner user, because `gosu` resets supplementary groups. Socket access is granted in `entrypoint.sh` (`grant_docker_socket`).

Verify changes before committing:

```bash
bash -n entrypoint.sh setup.sh
docker compose config -q
docker buildx build --platform linux/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') --load -t github-runner:local .
docker compose -p citest run --rm github-runner version    # prints image/volume versions
docker compose -p citest run --rm github-runner            # expect "Runner is not configured." exit 1
docker compose -p citest down -v
```

Do not register a real runner as part of testing unless the user provides a token for that purpose.
