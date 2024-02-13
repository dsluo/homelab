FROM debian:bookworm

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

RUN \
    DEBIAN_FRONTEND=noninteractive \
    apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y \
    locales man-db vim gpg \
    curl git openssh-client bash-completion \
    python3 python-is-python3 pipx \
    # kubectl
    kubernetes-client \
    # helm
    apt-transport-https \
    && curl https://baltocdn.com/helm/signing.asc | gpg --dearmor > /usr/share/keyrings/helm.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" > /etc/apt/sources.list.d/helm-stable-debian.list \
    && apt-get update \
    && apt-get install helm \
    # k9s
    && curl -Lo /tmp/k9s.deb https://github.com/derailed/k9s/releases/download/v0.31.8/k9s_linux_amd64.deb \
    && dpkg -i /tmp/k9s.deb \
    && apt-get install -f \
    # set proper locale
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen \
    # cleanup
    && rm -rf /var/lib/apt/lists/* /tmp/*

ARG USERNAME=debian

RUN useradd --create-home --shell /bin/bash ${USERNAME}
USER ${USERNAME}
ENV HOME=/home/${USERNAME}
WORKDIR ${HOME}

SHELL [ "/bin/bash", "-c" ]

ENV ANSIBLE_VERSION=8.7.0

RUN \
    pipx ensurepath \
    && pipx install --include-deps ansible==${ANSIBLE_VERSION} \
    && pipx inject --include-apps ansible ansible-lint argcomplete

ENV AUTOCOMPLETE_DIR=${HOME}/.local/share/bash-completion/completions
RUN \
    mkdir -p ${AUTOCOMPLETE_DIR} \
    && echo 'eval "$(register-python-argcomplete pipx)"' >> ${AUTOCOMPLETE_DIR}/pipx \
    && echo 'eval "$(register-python-argcomplete ansible)"' >> ${AUTOCOMPLETE_DIR}/ansible

VOLUME "${HOME}/.ssh"
