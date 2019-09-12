FROM debian:stretch

RUN apt-get update && apt-get install -y \
    binfmt-support \
    debootstrap \
    fakeroot \
    git \
    lxc \
    make \
    qemu \
    qemu-user-static \
    ubuntu-archive-keyring \
&& apt-get clean \
&& rm -rf /var/lib/apt/lists/*

ENV PIONUX_WORKSPACE /var/pionux
RUN mkdir -p ${PIONUX_WORKSPACE}
WORKDIR ${PIONUX_WORKSPACE}

ENTRYPOINT ["./build.sh"]
