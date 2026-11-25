# syntax=docker/dockerfile:1
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Pinned for reproducible builds. CI bumps this automatically when a new
# runner release appears (see .github/workflows/docker-publish.yml).
ARG RUNNER_VERSION=2.338.2
# Install the Docker CLI (+ buildx/compose plugins) so workflows can talk to
# a Docker daemon when one is provided (host socket or DinD). Set to "false"
# for a smaller image.
ARG INSTALL_DOCKER_CLI=true
# Provided automatically by BuildKit/buildx (amd64, arm64).
ARG TARGETARCH

LABEL org.opencontainers.image.title="github-runner" \
      org.opencontainers.image.description="GitHub Actions self-hosted runner on Ubuntu 24.04" \
      org.opencontainers.image.version="${RUNNER_VERSION}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl git gnupg gzip jq tar unzip zip \
    && if [ "$INSTALL_DOCKER_CLI" = "true" ]; then \
        install -m 0755 -d /etc/apt/keyrings \
        && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
        && chmod a+r /etc/apt/keyrings/docker.asc \
        && . /etc/os-release \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
            > /etc/apt/sources.list.d/docker.list \
        && apt-get update \
        && apt-get install -y --no-install-recommends \
            docker-ce-cli docker-buildx-plugin docker-compose-plugin; \
    fi \
    && rm -rf /var/lib/apt/lists/*

# UID/GID are pinned: existing /runner volumes are owned by 1001:1001, and a
# rebuild that picked different IDs would lock the runner out of its own
# registration. /runner is pre-created with that owner so a fresh named
# volume inherits it (Docker copies the mount point's ownership).
RUN groupadd -g 1001 runner \
    && useradd -m -u 1001 -g 1001 -s /bin/bash runner \
    && install -d -o 1001 -g 1001 /runner

WORKDIR /opt/runner-dist

# Download the runner for the target architecture and install its native
# dependencies (installdependencies.sh runs its own apt-get update).
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
        amd64) RUNNER_ARCH=x64 ;; \
        arm64) RUNNER_ARCH=arm64 ;; \
        arm)   RUNNER_ARCH=arm ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"; \
    tar xzf runner.tar.gz; \
    rm runner.tar.gz; \
    ./bin/installdependencies.sh; \
    rm -rf /var/lib/apt/lists/*; \
    echo "${RUNNER_VERSION}" > .image-runner-version; \
    chown -R runner:runner /opt/runner-dist

COPY --chmod=0755 entrypoint.sh /entrypoint.sh

VOLUME ["/runner"]

# The whole container runs unprivileged, including the entrypoint and the
# init process. Nothing in /runner is ever written as root.
USER runner

ENTRYPOINT ["/entrypoint.sh"]
CMD ["run"]
