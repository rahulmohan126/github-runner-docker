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
# written to disk.
set -euo pipefail

cd "$(dirname "$0")"

MODE=""
COMPOSE=(docker compose)

while [ $# -gt 0 ]; do
    case "$1" in
        --build) MODE=build ;;
        --pull)  MODE=pull ;;
        -p|--project-name) COMPOSE+=(-p "${2:?-p requires a project name}"); shift ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

# Load RUNNER_IMAGE etc. from .env so the build/pull default is correct.
if [ -f .env ]; then
    set -a; . ./.env; set +a
fi

if [ -z "$MODE" ]; then
    if [ -n "${RUNNER_IMAGE:-}" ]; then MODE=pull; else MODE=build; fi
fi
if [ "$MODE" = pull ] && [ -z "${RUNNER_IMAGE:-}" ]; then
    echo "--pull requires RUNNER_IMAGE (set it in .env, e.g. <dockerhub-user>/github-runner:latest)." >&2
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
