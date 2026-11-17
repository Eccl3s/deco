FROM quay.io/podman/stable:latest

# REQUIRED: Install project-specific base packages when configured.
ARG ADDITIONAL_PACKAGES=""
RUN if test -n "${ADDITIONAL_PACKAGES}"; then \
        dnf -y install ${ADDITIONAL_PACKAGES} && dnf clean all; \
    fi

# REQUIRED when `[user].mode` is `keep-id` or `host-user`: Adapt the upstream
# `podman` account to Deco's configured non-root user and host identity.
ARG USER_NAME=podman
ARG USER_UID=1000
ARG USER_GID=1000
RUN set -eux; \
    if test "${USER_NAME}" != podman; then \
        groupmod --new-name "${USER_NAME}" podman; \
        usermod --login "${USER_NAME}" --home "/home/${USER_NAME}" --move-home podman; \
    fi; \
    groupmod --gid "${USER_GID}" "${USER_NAME}"; \
    usermod --uid "${USER_UID}" --gid "${USER_GID}" "${USER_NAME}"; \
    printf 'root:1:65535\n%s:1:%s\n%s:%s:%s\n' \
        "${USER_NAME}" "$((USER_UID - 1))" \
        "${USER_NAME}" "$((USER_UID + 1))" "$((65536 - USER_UID))" \
        > /etc/subuid; \
    printf 'root:1:65535\n%s:1:%s\n%s:%s:%s\n' \
        "${USER_NAME}" "$((USER_GID - 1))" \
        "${USER_NAME}" "$((USER_GID + 1))" "$((65536 - USER_GID))" \
        > /etc/subgid; \
    mkdir -p "/home/${USER_NAME}/.local/share/containers"; \
    chown -R "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}"; \
    chown "${USER_NAME}:${USER_NAME}" /var/lib/containers

# Preserve rootless storage when the configured user name differs from the
# upstream image's fixed `podman` account.
VOLUME /home/${USER_NAME}/.local/share/containers

# OPTIONAL, SECURITY-SENSITIVE: Install sudo and add a narrow sudoers rule only
# when the development workflow truly requires container-root access.
# RUN dnf -y install sudo && dnf clean all
# RUN printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${USER_NAME}" > "/etc/sudoers.d/deco-${USER_NAME}"; \
#    chmod 0440 "/etc/sudoers.d/deco-${USER_NAME}"

ENV HOME=/home/${USER_NAME}

# REQUIRED: Sets the project working directory. Keep this aligned with
# [container].workdir in .deco/config.toml.
WORKDIR /workspace

# REQUIRED: Keeps the development container running so deco can run actions and open shells.
USER ${USER_NAME}
CMD ["sleep", "infinity"]
