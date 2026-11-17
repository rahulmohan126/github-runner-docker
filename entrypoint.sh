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
#   <other>    Executed as-is (e.g. "bash" for debugging).
set -euo pipefail

RUNNER_HOME="/runner"
RUNNER_DIST="/opt/runner-dist"

log() { echo "[entrypoint] $*"; }

runner_version() {
    # Prints the version of the runner installed in $1 (empty if none).
    if [ -x "$1/bin/Runner.Listener" ]; then
        "$1/bin/Runner.Listener" --version 2>/dev/null | tr -d '[:space:]' || true
    fi
}

# --- Initialise / refresh the persistent runner directory -------------------
# Binaries are copied from the image into the volume. They are refreshed when
# the image ships a newer runner than the volume holds (the runner's own
# self-update may already have moved the volume ahead, which is fine).
# Registration files (.runner, .credentials*) and _work are never touched.
sync_runner() {
    mkdir -p "$RUNNER_HOME"
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

    # Only fix ownership of top-level entries that are wrong, so a large
    # _work directory does not get re-chowned on every start.
    if [ "$(stat -c %u "$RUNNER_HOME")" != "$(id -u runner)" ]; then
        chown runner:runner "$RUNNER_HOME"
    fi
    find "$RUNNER_HOME" -mindepth 1 -maxdepth 1 ! -user runner -exec chown -R runner:runner {} +
}

# --- Docker socket access ----------------------------------------------------
# If a Docker socket is mounted, add the runner user to a group matching the
# socket's GID. (Compose `group_add` alone does not work: gosu resets
# supplementary groups from /etc/group when switching user.)
grant_docker_socket() {
    local sock="${DOCKER_SOCKET:-/var/run/docker.sock}"
    [ -S "$sock" ] || return 0
    local gid group
    gid="$(stat -c %g "$sock")"
    group="$(getent group "$gid" | cut -d: -f1 || true)"
    if [ -z "$group" ]; then
        group="docker-host"
        groupadd -g "$gid" "$group"
    fi
    if ! id -nG runner | tr ' ' '\n' | grep -qx "$group"; then
        usermod -aG "$group" runner
    fi
    log "Docker socket detected (gid ${gid}); runner added to group '${group}'"
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
        --labels "${RUNNER_LABELS:-docker,self-hosted,linux}"
        --work "${RUNNER_WORKDIR:-_work}"
    )
    [ -n "${RUNNER_GROUP:-}" ] && args+=(--runnergroup "$RUNNER_GROUP")
    [ "${RUNNER_EPHEMERAL:-false}" = "true" ] && args+=(--ephemeral)
    [ "${RUNNER_DISABLE_UPDATE:-false}" = "true" ] && args+=(--disableupdate)

    log "Registering runner '${RUNNER_NAME:-$(hostname)}' at ${RUNNER_URL}"
    # Arguments are passed as an argv array: no shell interpolation of secrets.
    (cd "$RUNNER_HOME" && gosu runner ./config.sh "${args[@]}")
}

remove_runner() {
    local token
    token="$(resolve_token remove-token)"
    (cd "$RUNNER_HOME" && gosu runner ./config.sh remove --token "$token")
}

# --- Main --------------------------------------------------------------------
cmd="${1:-run}"

case "$cmd" in
    configure)
        sync_runner
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
        grant_docker_socket
        # Do not leak registration secrets into job environments.
        unset RUNNER_TOKEN ACCESS_TOKEN
        cd "$RUNNER_HOME"
        exec gosu runner ./run.sh
        ;;

    remove)
        sync_runner
        remove_runner
        ;;

    version)
        echo "image: $(cat "$RUNNER_DIST/.image-runner-version")"
        echo "volume: $(runner_version "$RUNNER_HOME")"
        ;;

    *)
        exec "$@"
        ;;
esac
