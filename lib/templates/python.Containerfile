ARG PYTHON_VERSION=3.15
FROM ghcr.io/astral-sh/uv:python${PYTHON_VERSION}-trixie

# REQUIRED: Set up base system
ARG DEBIAN_FRONTEND=noninteractive
ARG ADDITIONAL_PACKAGES=""
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ${ADDITIONAL_PACKAGES} \
    && rm -rf /var/lib/apt/lists/*

# REQUIRED when `[user].mode` is `keep-id` or `host-user`: Create the configured non-root user
# for improved security.
ARG USER_NAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
RUN set -eux; \
    groupadd --gid "${USER_GID}" "${USER_NAME}"; \
    useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home --shell /bin/bash "${USER_NAME}"

ENV HOME=/home/${USER_NAME}

# OPTIONAL, SECURITY-SENSITIVE: Install sudo and add a narrow sudoers rule only
# when the development workflow truly requires container-root access.
# RUN apt-get update \
#    && apt-get install -y --no-install-recommends \
#        sudo \
#    && rm -rf /var/lib/apt/lists/*
# RUN printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${USER_NAME}" > "/etc/sudoers.d/deco-${USER_NAME}"; \
#    chmod 0440 "/etc/sudoers.d/deco-${USER_NAME}"

# OPTIONAL: Set LANG to enable UTF-8 support
ENV LANG=C.UTF-8

# REQUIRED: Sets the project working directory. Keep this aligned with
# [container].workdir in .deco/config.toml.
WORKDIR /workspace

# REQUIRED: Keeps the development container running so deco can run actions and open shells
USER ${USER_NAME}
CMD ["sleep", "infinity"]
