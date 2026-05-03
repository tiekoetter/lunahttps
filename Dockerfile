# syntax=docker/dockerfile:1.7

ARG DEBIAN_VERSION=trixie
ARG NGINX_VERSION=1.29.8

FROM debian:${DEBIAN_VERSION} AS builder

ARG NGINX_VERSION

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
    git \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY . .

# Get submodules.
RUN git submodule update --init --recursive

# OpenSSL downloader populates luna/openssl-lts.
RUN bash luna/openssl-downloader.sh

RUN mkdir -p /src/luna/build \
 && cd /src/luna/build \
 && wget -O "nginx-${NGINX_VERSION}.tar.gz" "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" \
 && tar -xzf "nginx-${NGINX_VERSION}.tar.gz"

WORKDIR /src/luna/build/nginx-${NGINX_VERSION}

RUN set -eux; \
    header_file="src/http/ngx_http_header_filter_module.c"; \
    error_file="src/http/ngx_http_special_response.c"; \
    \
    grep -nE 'ngx_http_server_(string|full_string|build_string)|NGINX_VER|NGINX_VER_BUILD' "$header_file"; \
    grep -nE 'NGINX_VER|NGINX_VER_BUILD|<hr><center>' "$error_file"; \
    \
    sed -i -E \
      's|static u_char ngx_http_server_string\[\] = "Server: nginx" CRLF;|static u_char ngx_http_server_string[] = "Server: Luna-HTTP/S" CRLF;|' \
      "$header_file"; \
    \
    sed -i -E \
      's|static u_char ngx_http_server_full_string\[\] = "Server: " NGINX_VER CRLF;|static u_char ngx_http_server_full_string[] = "Server: Luna-HTTP/S+" NGINX_VERSION CRLF;|' \
      "$header_file"; \
    \
    sed -i -E \
      's|static u_char ngx_http_server_build_string\[\] = "Server: " NGINX_VER_BUILD CRLF;|static u_char ngx_http_server_build_string[] = "Server: Luna-HTTP/S+" NGINX_VERSION CRLF;|' \
      "$header_file"; \
    \
    sed -i -E \
      's|"<hr><center>nginx</center>" CRLF|"<hr><center>Luna-HTTP/S</center>" CRLF|' \
      "$error_file"; \
    \
    sed -i -E \
      's|"<hr><center>" NGINX_VER "</center>" CRLF|"<hr><center>Luna-HTTP/S+" NGINX_VERSION "</center>" CRLF|' \
      "$error_file"; \
    \
    sed -i -E \
      's|"<hr><center>" NGINX_VER_BUILD "</center>" CRLF|"<hr><center>Luna-HTTP/S+" NGINX_VERSION "</center>" CRLF|' \
      "$error_file"; \
    \
    grep -q 'Server: Luna-HTTP/S' "$header_file"; \
    grep -q 'Server: Luna-HTTP/S+' "$header_file"; \
    grep -q '<hr><center>Luna-HTTP/S' "$error_file"; \
    \
    grep -nE 'Luna-HTTP/S|ngx_http_server_(string|full_string|build_string)' "$header_file"; \
    grep -nE 'Luna-HTTP/S|<hr><center>' "$error_file"

RUN ./configure \
    --prefix=/usr/share/nginx \
    --sbin-path=/usr/sbin/nginx \
    --conf-path=/etc/nginx/nginx.conf \
    --pid-path=/var/run/nginx.pid \
    --lock-path=/var/lock/nginx.lock \
    --error-log-path=/var/log/nginx/error.log \
    --http-log-path=/var/log/nginx/access.log \
    --user=www-data \
    --group=www-data \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_v3_module \
    --with-http_stub_status_module \
    --with-http_gzip_static_module \
    --with-http_sub_module \
    --with-file-aio \
    --with-threads \
    --with-stream \
    --with-stream_ssl_module \
    --with-pcre \
    --add-module=/src/luna/modules/ngx_http_substitutions_filter_module \
    --add-module=/src/luna/modules/headers-more-nginx-module \
    --add-module=/src/luna/modules/ngx_http_geoip2_module \
    --add-module=/src/luna/modules/ngx_brotli \
    --with-openssl=/src/luna/openssl-lts \
    --with-openssl-opt=enable-ktls

RUN make -j"$(nproc)" \
 && make install

FROM debian:${DEBIAN_VERSION} AS runtime

LABEL org.opencontainers.image.title="Luna-HTTP/S"
LABEL org.opencontainers.image.description="Custom NGINX build with OpenSSL LTS, HTTP/3, Brotli, GeoIP2, headers-more and substitutions filter"
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
