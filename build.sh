#!/bin/bash
nginxver=1.29.0
LIGHTBLUE='\033[1;34m'
GREEN='\033[0;32m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color
echo -e "*******************************************************
          ${PURPLE}Tiekoetter.net Luna-HTTP/S Builder v2${NC}

 Working with NGINX Version ""\""${nginxver}"\"
 OpenSSL with TLS 1.3 Support + kTLS
 HTTP3 / QUIC (experimental)
 
 ngx_brotli
 ngx_http_geoip2_module
 headers-more-nginx-module
 ngx_http_substitutions_filter_module

 Copyright © 2018-2025 Léon Tiekötter <leon@tiekoetter.com>
*******************************************************

"
echo -e "
${LIGHTBLUE}Starting OpenSSL downloader...${NC}"
luna/openssl-downloader.sh

cd luna/nginx
rm -R nginx-${nginxver}.tar.*
rm -R nginx-${nginxver}/
echo -e "
${LIGHTBLUE}Updating NGINX...${NC}"
wget http://nginx.org/download/nginx-${nginxver}.tar.gz
tar -xvzf nginx-${nginxver}.tar.gz
cd luna/nginx/nginx-${nginxver}/
echo -e "
${LIGHTBLUE}Change NGINX to Luna-HTTP/S...${NC}"
cp luna/nginx-internals/ngx_http_header_filter_module.c luna/nginx/nginx-${nginxver}/src/http/
cp luna/nginx-internals/ngx_http_special_response.c luna/nginx/nginx-${nginxver}/src/http/
echo -e "${LIGHTBLUE}Configure Luna-HTTP/S...${NC}"
./configure \
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
    --with-pcre \
    --with-http_sub_module \
    --with-file-aio \
    --with-threads \
    --with-stream \
    --with-stream_ssl_module \
    --add-module=luna/modules/ngx_http_substitutions_filter_module \
    --add-module=luna/modules/headers-more-nginx-module \
    --add-module=luna/modules/ngx_http_geoip2_module \
    --add-module=luna/modules/ngx_brotli \
    --with-openssl=luna/openssl-lts \
    --with-openssl-opt=enable-ktls
echo -e "
${LIGHTBLUE}Build Luna-HTTP/S and push to production...${NC}"
make -k && make install && systemctl restart nginx
echo -e "
${GREEN}Done.${NC} Luna-HTTP/S is now active and online!"
