FROM debian:bookworm

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

RUN \
    DEBIAN_FRONTEND=noninteractive \
    apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y \
    locales man-db vim \
    curl git openssh-client bash-completion \
    python3 python-is-python3 pipx \
    kubernetes-client \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

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
