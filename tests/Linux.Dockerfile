FROM debian:bookworm-slim
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    bash ca-certificates curl openssl iproute2 procps nftables iptables \
    wireguard-tools dnsmasq-base dnsutils util-linux openssh-client gcc make libc6-dev systemd \
    && rm -rf /var/lib/apt/lists/*
CMD ["sleep", "infinity"]
