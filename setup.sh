#!/usr/bin/env bash
# Register a GitHub Actions runner and start it with Docker Compose.
#
# Usage: ./setup.sh [--build | --pull] [-p <project>]
#
#   --build        Build the image locally (default when RUNNER_IMAGE is unset)
#   --pull         Pull RUNNER_IMAGE from the registry (default when it is set)
#   -p <project>   Compose project name; use a different one per runner
#
# Non-interactive use: export RUNNER_URL and RUNNER_TOKEN before running.
# The token is passed only to a one-off registration container and is never
# written to disk. Variables set in the environment (RUNNER_NAME, RUNNER_ROOT,
# ...) take precedence over .env, as they do for docker compose.
set -euo pipefail

cd "$(dirname "$0")"

MODE=""
COMPOSE=(docker compose)

while [ $# -gt 0 ]; do
    case "$1" in
        --build) MODE=build ;;
        --pull)  MODE=pull ;;
        -p|--project-name) COMPOSE+=(-p "${2:?-p requires a project name}"); shift ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

# Read KEY from .env unless it is already set in the environment (the same
# precedence docker compose uses). .env is parsed, not sourced, and nothing is
# exported, so a PAT in .env never reaches this script's environment.
env_default() {
    local key="$1" line val
    if [ -n "${!key:-}" ]; then
        printf '%s' "${!key}"
        return
    fi
    [ -f .env ] || return 0
    line="$(grep -E "^[[:space:]]*${key}=" .env | tail -n1 || true)"
    [ -n "$line" ] || return 0
    val="${line#*=}"
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    printf '%s' "$val"
}

RUNNER_IMAGE="$(env_default RUNNER_IMAGE)"
RUNNER_URL="$(env_default RUNNER_URL)"
RUNNER_ROOT="$(env_default RUNNER_ROOT)"
RUNNER_ROOT="${RUNNER_ROOT:-/srv/github-runner}"
case "$RUNNER_ROOT" in
    /*) ;;
    *) echo "RUNNER_ROOT must be an absolute path (got: ${RUNNER_ROOT})." >&2; exit 1 ;;
esac

if [ -z "$MODE" ]; then
    if [ -n "${RUNNER_IMAGE:-}" ]; then MODE=pull; else MODE=build; fi
fi
if [ "$MODE" = pull ] && [ -z "${RUNNER_IMAGE:-}" ]; then
    echo "--pull requires RUNNER_IMAGE (set it in .env, e.g. rahulmohan126/github-runner:latest)." >&2
    exit 1
fi

command -v docker >/dev/null || { echo "docker is not installed." >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "Docker Compose v2 plugin is required." >&2; exit 1; }

echo "GitHub Actions Runner Setup"
echo "---------------------------"

if [ -z "${RUNNER_URL:-}" ]; then
    read -rp "GitHub repository or organization URL: " RUNNER_URL
fi
RUNNER_URL="${RUNNER_URL%/}"

if [[ ! "$RUNNER_URL" =~ ^https://github\.com/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?$ ]]; then
    echo "Invalid URL. Expected https://github.com/<owner>/<repo> or https://github.com/<org>." >&2
    exit 1
fi

if [ -z "${RUNNER_TOKEN:-}" ]; then
    echo
    echo "Generate a registration token (valid ~1 hour) from:"
    echo "  Repo: Settings -> Actions -> Runners -> New self-hosted runner"
    echo "  Org:  Settings -> Actions -> Runners -> New runner"
    echo
    read -rsp "Registration token: " RUNNER_TOKEN
    echo
fi

if [ -z "$RUNNER_TOKEN" ]; then
    echo "Registration token cannot be empty." >&2
    exit 1
fi

echo
if [ "$MODE" = pull ]; then
    echo "Pulling ${RUNNER_IMAGE}..."
    "${COMPOSE[@]}" pull github-runner
else
    echo "Building runner image..."
    "${COMPOSE[@]}" build
fi

# The runner directory is a host bind mount (same path inside the container)
# and must be owned by the runner user, uid/gid 1001. Docker creates a missing
# directory as root, so fix ownership of the top-level directory once, in a
# throwaway container with only the capabilities that needs. The runner
# itself never runs as root.
echo "Preparing runner directory ${RUNNER_ROOT}..."
if ! "${COMPOSE[@]}" run --rm --no-deps --entrypoint test github-runner -w "$RUNNER_ROOT" 2>/dev/null; then
    "${COMPOSE[@]}" run --rm --no-deps --user 0 --cap-add CHOWN --cap-add FOWNER \
        --entrypoint install github-runner \
        -d -o 1001 -g 1001 -m 0755 "$RUNNER_ROOT"
fi

echo "Registering runner..."
RUNNER_URL="$RUNNER_URL" RUNNER_TOKEN="$RUNNER_TOKEN" \
    "${COMPOSE[@]}" run --rm --no-deps \
        -e RUNNER_URL -e RUNNER_TOKEN \
        github-runner configure
unset RUNNER_TOKEN

echo "Starting runner..."
"${COMPOSE[@]}" up -d

echo
echo "Runner started. Follow the logs with: ${COMPOSE[*]} logs -f github-runner"
"${COMPOSE[@]}" ps
