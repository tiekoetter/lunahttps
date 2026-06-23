# syntax=docker/dockerfile:1.7

ARG DEBIAN_VERSION=trixie

FROM debian:${DEBIAN_VERSION} AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    gnupg \
    build-essential \
    make \
    gcc \
    libc6-dev \
    libpcre2-dev \
    zlib1g-dev \
    libmaxminddb-dev \
    libgd-dev \
    libxml2-dev \
    libxslt1-dev \
    perl \
    tar \
    xz-utils \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY . .

# The build context must already include initialized submodules.
RUN test -f luna/modules/ngx_http_substitutions_filter_module/config \
 && test -f luna/modules/headers-more-nginx-module/config \
 && test -f luna/modules/ngx_http_geoip2_module/config \
 && test -f luna/modules/ngx_brotli/config \
 && test -f luna/modules/ngx_brotli/deps/brotli/c/include/brotli/encode.h

RUN bash ./build.sh --docker

FROM debian:${DEBIAN_VERSION} AS runtime

LABEL org.opencontainers.image.title="Luna-HTTP/S"
LABEL org.opencontainers.image.description="Custom NGINX build with OpenSSL LTS, HTTP/3, Brotli, GeoIP2, headers-more and substitutions filter"
LABEL org.opencontainers.image.url="https://lunahttps.tiekoetter.net"
LABEL org.opencontainers.image.source="https://github.com/tiekoetter/lunahttps"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libpcre2-8-0 \
    zlib1g \
    libmaxminddb0 \
    libgd3 \
    libxml2 \
    libxslt1.1 \
    tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && addgroup --system www-data || true \
 && adduser --system --no-create-home --ingroup www-data www-data || true \
 && mkdir -p /var/log/nginx /var/cache/nginx /var/run /var/lock/nginx

COPY --from=builder /usr/sbin/nginx /usr/sbin/nginx
COPY --from=builder /usr/share/nginx /usr/share/nginx
COPY --from=builder /etc/nginx /etc/nginx

EXPOSE 80 443/tcp 443/udp

STOPSIGNAL SIGQUIT

CMD ["/usr/sbin/nginx", "-g", "daemon off;"]
