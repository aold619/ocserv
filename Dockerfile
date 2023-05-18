FROM ubuntu:rolling
LABEL maintainer="Hu Xiaohong <xiaohong@duckduck.io>"

ENV URL="https://www.infradead.org/ocserv/download/"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY docker-entrypoint.sh /entrypoint.sh
COPY --from=ghcr.io/ufoscout/docker-compose-wait:latest /wait /wait

RUN set -x \
  && apt-get update && apt-get install -y wget make gcc \
  && apt-get install --no-install-recommends -y \
    xz-utils gawk pkg-config nettle-dev gnutls-bin \
    libgnutls28-dev libprotobuf-c-dev libev-dev \
    libreadline-dev liblz4-dev libseccomp-dev liboath-dev \
    libnl-3-dev libtalloc-dev libhttp-parser-dev \
    libradcli-dev libpam0g-dev libkrb5-dev \
    certbot python3-certbot-dns-cloudflare cron iptables \
  && wget -qO- "${URL}" | \
    grep -oE 'ocserv-([0-9]{1,}\.)+[0-9]{1,}\.tar\.xz' | \
    sort -V | tail -n1 | \
    xargs -I {} wget -q "${URL}{}" -O ocserv.tar.xz \
  && tar xf ocserv.tar.xz && cd ocserv-* \
  && ./configure \
  && make && make install && make clean \
  && cd .. && rm -rf ocserv-* ocserv.tar.xz \
  && apt-get -y remove --auto-remove --purge wget make gcc \
  && rm -rf /var/lib/apt/lists/* \
  && rm -rf /etc/ocserv/ocserv.conf \
  && chmod +x /entrypoint.sh

WORKDIR /etc/ocserv

ENTRYPOINT ["/entrypoint.sh"]

EXPOSE 443
CMD ["ocserv", "-c", "/etc/ocserv/ocserv.conf", "-f"]
