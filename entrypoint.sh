#!/usr/bin/env bash
# Entrypoint for the GitHub Actions runner container.
#
# Commands:
#   run        (default) Start the runner. If it is not configured yet and
#              RUNNER_URL + (RUNNER_TOKEN or ACCESS_TOKEN) are set, register first.
#   configure  Register the runner with GitHub and exit.
#   remove     Unregister the runner (needs RUNNER_TOKEN = removal token,
#              or ACCESS_TOKEN) and exit.
#   version    Print the runner version and exit.
#   migrate    Copy a registration from the old /runner volume (mounted at
#              /runner) into the runner directory and exit.
#   <other>    Executed as-is (e.g. "bash" for debugging).
#
# Runs entirely as the unprivileged `runner` user (Dockerfile `USER runner`).
# It must never need root: `no-new-privileges` is set, so there is no sudo.
set -euo pipefail

# Runner directory: binaries, registration and the job work directory. It is a
# host bind mount at the SAME absolute path (docker-compose.yml), because jobs
# talk to the host Docker daemon, which resolves bind-mount paths on the host.
RUNNER_HOME="${RUNNER_ROOT:-/srv/github-runner}"
RUNNER_DIST="/opt/runner-dist"
# Directory used by images before the move to a same-path bind mount.
LEGACY_RUNNER_HOME="/runner"

log() { echo "[entrypoint] $*"; }

runner_version() {
    # Prints the version of the runner installed in $1 (empty if none).
    # Read from the deps manifest instead of running `Runner.Listener --version`:
    # every Runner.Listener invocation writes a log to $1/_diag, which used to
    # race with the real listener start (same-second log file name).
    local deps="$1/bin/Runner.Listener.deps.json"
    [ -f "$deps" ] || return 0
    grep -o -m1 '"Runner\.Listener/[0-9][^"]*"' "$deps" \
        | sed 's/^"Runner\.Listener\///; s/"$//' || true
}

# --- Initialise / refresh the persistent runner directory -------------------
# Binaries are copied from the image into the volume. They are refreshed when
# the image ships a newer runner than the volume holds (the runner's own
# self-update may already have moved the volume ahead, which is fine).
# Registration files (.runner, .credentials*) and _work are never touched.
sync_runner() {
    if [ ! -w "$RUNNER_HOME" ]; then
        echo "${RUNNER_HOME} is not writable by uid $(id -u)." >&2
        echo "Fix the directory ownership once with:" >&2
        echo "  docker compose run --rm --no-deps --user 0 --cap-add CHOWN --entrypoint chown github-runner -R 1001:1001 ${RUNNER_HOME}" >&2
        exit 1
    fi
    local image_ver installed_ver
    image_ver="$(cat "$RUNNER_DIST/.image-runner-version")"
    installed_ver="$(runner_version "$RUNNER_HOME")"

    if [ -z "$installed_ver" ]; then
        log "Installing runner ${image_ver} into ${RUNNER_HOME}"
        cp -a "$RUNNER_DIST/." "$RUNNER_HOME/"
    elif [ "$installed_ver" != "$image_ver" ] && \
         [ "$(printf '%s\n%s\n' "$installed_ver" "$image_ver" | sort -V | tail -n1)" = "$image_ver" ]; then
        log "Upgrading runner ${installed_ver} -> ${image_ver}"
        cp -a "$RUNNER_DIST/." "$RUNNER_HOME/"
    fi

    cleanup_foreign_diag
}

# Older images ran `Runner.Listener --version` as root, leaving root-owned
# logs in _diag; one of them can block the listener from opening its log.
# _diag itself is owned by the runner user, so those files can be deleted.
cleanup_foreign_diag() {
    local diag="$RUNNER_HOME/_diag"
    [ -d "$diag" ] || return 0
    find "$diag" -mindepth 1 -maxdepth 1 -type f ! -user "$(id -u)" -delete 2>/dev/null || true
    if [ -n "$(find "$diag" ! -user "$(id -u)" -print -quit 2>/dev/null)" ]; then
        log "Warning: ${diag} contains files not owned by uid $(id -u). If the runner"
        log "fails to start, fix ownership with:"
        log "  docker compose run --rm --no-deps --user 0 --cap-add CHOWN --entrypoint chown github-runner -R 1001:1001 ${RUNNER_HOME}"
    fi
}

# Copy a registration from the old named volume, mounted at /runner, into the
# runner directory. The job work directory is not copied (it is a cache).
migrate_legacy() {
    if [ ! -f "$LEGACY_RUNNER_HOME/.runner" ]; then
        echo "No registration found in ${LEGACY_RUNNER_HOME}. Mount the old volume there, e.g.:" >&2
        echo "  docker compose run --rm -v <project>_runner-data:${LEGACY_RUNNER_HOME} github-runner migrate" >&2
        exit 1
    fi
    if [ -f "$RUNNER_HOME/.runner" ]; then
        echo "${RUNNER_HOME} already holds a registration; not overwriting it." >&2
        exit 1
    fi
    sync_runner
    log "Copying registration from ${LEGACY_RUNNER_HOME} to ${RUNNER_HOME}"
    tar -C "$LEGACY_RUNNER_HOME" --exclude=./_work --exclude=./_diag -cf - . \
        | tar -C "$RUNNER_HOME" -xpf -
    # Refresh binaries if the image is newer than the copied ones.
    sync_runner
    log "Done. Start the runner with: docker compose up -d"
}

# Jobs bind-mount paths from the work directory into containers started on the
# host daemon, so it has to live inside the same-path runner directory.
check_workdir() {
    local dir="${RUNNER_WORKDIR:-_work}"
    case "$dir" in
        /*) ;;
        *) dir="$RUNNER_HOME/$dir" ;;
    esac
    case "$dir/" in
        "$RUNNER_HOME"/*) ;;
        *) log "Warning: RUNNER_WORKDIR (${dir}) is outside ${RUNNER_HOME}; bind mounts from jobs will not resolve on the host." ;;
    esac
}

# The runner refuses `services:` and `container:` jobs when /proc/1/cgroup
# shows a Docker cgroup path, which happens on cgroup v1 hosts (cgroup v2 with
# Docker's default private cgroup namespace shows "0::/").
check_cgroup() {
    if grep -qE ':/docker/|/docker-[0-9a-f]+\.scope' /proc/1/cgroup 2>/dev/null; then
        log "Warning: /proc/1/cgroup shows a Docker cgroup path; the runner will reject"
        log "service containers and container jobs. Use a cgroup v2 host"
        log "(docker info --format '{{.CgroupVersion}}' should print 2)."
    fi
}

# Each runner needs its own RUNNER_ROOT. Two compose projects sharing one
# directory would run the same registration twice.
check_registration_name() {
    local registered
    # The runner writes .runner with a UTF-8 BOM, which jq rejects.
    registered="$(sed '1s/^\xEF\xBB\xBF//' "$RUNNER_HOME/.runner" 2>/dev/null \
        | jq -r '.agentName // empty' 2>/dev/null || true)"
    if [ -n "$registered" ] && [ -n "${RUNNER_NAME:-}" ] && [ "$registered" != "$RUNNER_NAME" ]; then
        log "Warning: ${RUNNER_HOME} holds the registration of runner '${registered}', but"
        log "RUNNER_NAME is '${RUNNER_NAME}'. If another runner uses this directory, give"
        log "each runner its own RUNNER_ROOT (see 'Multiple runners' in README.md)."
    fi
}

# --- Docker socket access ----------------------------------------------------
# Docker is opt-in (docker-compose.docker-socket.yml). Access is granted by
# Compose `group_add: [DOCKER_GID]`; the container cannot change its own
# groups. This only reports the state so it is easy to diagnose.
check_docker_socket() {
    local sock="${DOCKER_SOCKET:-/var/run/docker.sock}"
    if [ ! -S "$sock" ]; then
        log "Docker: not available (no socket mounted). Jobs that need Docker,"
        log "services: or testcontainers must run on a different runner."
        return 0
    fi
    check_cgroup
    local gid
    gid="$(stat -c %g "$sock")"
    if [ -r "$sock" ] && [ -w "$sock" ]; then
        log "Docker socket detected (gid ${gid}); access OK"
    else
        log "Warning: no access to ${sock} (gid ${gid}; process groups: $(id -G))."
        log "Set DOCKER_GID=${gid} in .env and run: docker compose up -d --force-recreate"
    fi
}

# --- Registration token helpers ---------------------------------------------
# Derive the API path from RUNNER_URL: https://github.com/<owner>[/<repo>]
api_scope() {
    local path="${RUNNER_URL#https://github.com/}"
    path="${path%/}"
    if [[ "$path" == */* ]]; then
        echo "repos/${path}"
    else
        echo "orgs/${path}"
    fi
}

fetch_token() {
    # $1 = registration-token | remove-token
    local api="${GITHUB_API_URL:-https://api.github.com}"
    curl -fsSL -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${api}/$(api_scope)/actions/runners/$1" | jq -r '.token'
}

resolve_token() {
    # $1 = registration-token | remove-token
    if [ -n "${RUNNER_TOKEN:-}" ]; then
        printf '%s' "$RUNNER_TOKEN"
    elif [ -n "${ACCESS_TOKEN:-}" ]; then
        fetch_token "$1"
    else
        echo "RUNNER_TOKEN or ACCESS_TOKEN is required" >&2
        return 1
    fi
}

configure_runner() {
    : "${RUNNER_URL:?RUNNER_URL is required (https://github.com/<owner>[/<repo>])}"
    local token
    token="$(resolve_token registration-token)"

    local args=(
        --unattended
        --replace
        --url "$RUNNER_URL"
        --token "$token"
        --name "${RUNNER_NAME:-$(hostname)}"
        --labels "${RUNNER_LABELS:-self-hosted,linux}"
        --work "${RUNNER_WORKDIR:-_work}"
    )
    [ -n "${RUNNER_GROUP:-}" ] && args+=(--runnergroup "$RUNNER_GROUP")
    [ "${RUNNER_EPHEMERAL:-false}" = "true" ] && args+=(--ephemeral)
    [ "${RUNNER_DISABLE_UPDATE:-false}" = "true" ] && args+=(--disableupdate)

    log "Registering runner '${RUNNER_NAME:-$(hostname)}' at ${RUNNER_URL}"
    # Arguments are passed as an argv array: no shell interpolation of secrets.
    (cd "$RUNNER_HOME" && ./config.sh "${args[@]}")
}

remove_runner() {
    local token
    token="$(resolve_token remove-token)"
    (cd "$RUNNER_HOME" && ./config.sh remove --token "$token")
}

# --- Main --------------------------------------------------------------------
cmd="${1:-run}"

case "$cmd" in
    configure)
        sync_runner
        check_workdir
        configure_runner
        ;;

    run)
        sync_runner
        if [ ! -f "$RUNNER_HOME/.runner" ]; then
            if [ -n "${RUNNER_URL:-}" ] && { [ -n "${RUNNER_TOKEN:-}" ] || [ -n "${ACCESS_TOKEN:-}" ]; }; then
                configure_runner
            else
                echo "Runner is not configured."
                echo "Run ./setup.sh to register this runner, or set RUNNER_URL and ACCESS_TOKEN."
                exit 1
            fi
        fi
        check_registration_name
        check_docker_socket
        # Do not leak registration secrets into job environments.
        unset RUNNER_TOKEN ACCESS_TOKEN
        cd "$RUNNER_HOME"
        exec ./run.sh
        ;;

    remove)
        sync_runner
        remove_runner
        ;;

    migrate)
        migrate_legacy
        ;;

    version)
        echo "image: $(cat "$RUNNER_DIST/.image-runner-version")"
        echo "runner dir: $(runner_version "$RUNNER_HOME") ($RUNNER_HOME)"
        ;;

    *)
        exec "$@"
        ;;
esac
