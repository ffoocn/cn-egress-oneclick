FROM debian:bookworm-slim
RUN env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy apt-get update \
 && env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy apt-get install -y --no-install-recommends ca-certificates curl openssl unzip zip \
 && rm -rf /var/lib/apt/lists/*
