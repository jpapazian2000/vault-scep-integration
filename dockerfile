FROM debian:bullseye

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    git \
    build-essential \
    autoconf \
    automake \
    libtool \
    pkg-config \
    libssl-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt

RUN git clone https://github.com/certnanny/sscep.git

WORKDIR /opt/sscep

RUN autoreconf -i \
    && ./configure \
    && make \
    && make install

WORKDIR /data

ENTRYPOINT ["sscep"]
