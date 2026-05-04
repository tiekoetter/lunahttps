# Luna-HTTP/S

Custom-built NGINX with enhanced performance, modern protocol support, Docker image builds, and security-focused features.

Luna-HTTP/S is based on NGINX mainline and adds a curated build configuration with OpenSSL 3.5.x, TLS 1.3, post-quantum cryptography support, HTTP/2, HTTP/3 / QUIC, Brotli, GeoIP2, advanced header manipulation, and response body substitution support.

---

## ✨ Features

- **Based on NGINX mainline**
- **OpenSSL with TLS 1.3 + kTLS** for modern transport security and improved performance
- **Post-quantum cryptography capable out of the box** through OpenSSL 3.5.x, including support for ML-KEM, ML-DSA, and SLH-DSA
- **HTTP/2 support**
- **HTTP/3 / QUIC support** for reduced latency and faster connections
- **Brotli compression** for reduced bandwidth usage and faster page loads
- **ngx_http_geoip2_module** for GeoIP-based request handling
- **headers-more-nginx-module** for advanced header control
- **ngx_http_substitutions_filter_module** for RegEx-based response body filtering and substitution
- **Docker image builds** published through GitHub Container Registry
- **Custom Luna branding** for generated server headers and error pages

---

## 📦 Build Information

This build is tailored for high-performance environments and is compiled with additional modules and experimental protocol support.

**Included modules:**

- [ngx_brotli](https://github.com/google/ngx_brotli)
- [ngx_http_geoip2_module](https://github.com/leev/ngx_http_geoip2_module)
- [headers-more-nginx-module](https://github.com/openresty/headers-more-nginx-module)
- [ngx_http_substitutions_filter_module](https://github.com/yaoweibin/ngx_http_substitutions_filter_module)

The build uses the repository submodules under:

```text
luna/modules/
```

OpenSSL is downloaded and prepared by:

```text
luna/openssl-downloader.sh
```
## 🔐 Post-Quantum Cryptography

Luna-HTTP/S is built with OpenSSL 3.5.x, which includes support for post-quantum cryptography algorithms such as ML-KEM, ML-DSA, and SLH-DSA.

This makes the build post-quantum capable out of the box and suitable for testing hybrid TLS key exchange and future-facing cryptographic deployments.

Actual post-quantum behavior depends on client support, TLS group configuration, OpenSSL defaults, and interoperability with the connecting peer.

---

## 🏷️ Luna-HTTP/S server branding

With `server_tokens off;`:

```text
Server: luna-http/s
```

With `server_tokens on;`:

```text
Server: luna-http/s+<nginx-version>
```

The branding patch is applied to HTTP/1.x, HTTP/2, HTTP/3, and generated NGINX error pages using:

```text
luna/branding-patch.sh
```

---

## 🐳 Docker Image

The Docker image is published to GitHub Container Registry:

```bash
docker pull ghcr.io/tiekoetter/lunahttps:latest
```

Example `docker-compose.yml`:

```yaml
services:
  lunahttps:
    image: ghcr.io/tiekoetter/lunahttps:latest
    container_name: lunahttps
    restart: unless-stopped
    ports:
      - "80:80/tcp"
      - "443:443/tcp"
      - "443:443/udp"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./certs:/etc/nginx/certs:ro
      - ./html:/usr/share/nginx/html:ro
      - ./logs:/var/log/nginx
```

For HTTP/3 / QUIC, make sure UDP 443 is exposed and allowed through the firewall.

Example HTTPS server block with HTTP/2 and HTTP/3:

```nginx
server {
    listen 443 ssl;
    listen [::]:443 ssl;

    listen 443 quic reuseport;
    listen [::]:443 quic reuseport;

    http2 on;

    server_name example.com;

    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;

    ssl_protocols TLSv1.3;

    add_header Alt-Svc 'h3=":443"; ma=86400' always;

    root /usr/share/nginx/html;
    index index.html;
}
```

For a non-standard public HTTPS port, adjust the `Alt-Svc` port accordingly, for example:

```nginx
add_header Alt-Svc 'h3=":8443"; ma=86400' always;
```

---

## 🔧 Building from Source

You can build Luna-HTTP/S directly on a host using the provided build script.

### Build steps

```bash
git clone --recurse-submodules https://github.com/tiekoetter/lunahttps.git
cd lunahttps
sudo ./build.sh
```

If the repository was cloned without submodules, initialize them first:

```bash
git submodule update --init --recursive
```

The build script will:

1. download and prepare OpenSSL,
2. download the configured NGINX mainline version,
3. apply Luna source and branding patches,
4. configure NGINX with the selected modules,
5. build and install NGINX,
6. validate the installed configuration,
7. restart the system NGINX service.

The current NGINX version is configured in:

```bash
readonly NGINX_VERSION="..."
```

inside:

```text
build.sh
```

---

## 🧪 Testing

After installation or container startup, check the compiled features:

```bash
nginx -V
```

or inside Docker:

```bash
docker exec lunahttps nginx -V
```

Validate the active configuration:

```bash
nginx -t
```

or:

```bash
docker exec lunahttps nginx -t
```

Test HTTP/1.1, HTTP/2, and HTTP/3 branding:

```bash
curl -I --http1.1 http://example.com/
curl -k -I --http1.1 https://example.com/
curl -k -I --http2 https://example.com/
curl -k -I --http3-only https://example.com/
```

Expected with `server_tokens off;`:

```text
Server: luna-http/s
```

For HTTP/2 and HTTP/3, header names are usually lowercase:

```text
server: luna-http/s
```

---

## ⚙️ CI/CD

The repository uses GitHub Actions for CI and Docker image publishing.

CI validates:

- shell scripts with ShellCheck,
- required submodules,
- Docker image build,
- compiled NGINX modules,
- runtime HTTP/1.1 and HTTP/2 branding,
- generated error page branding,
- HTTP/3 branding when the GitHub Actions runner curl supports HTTP/3.

Docker image publishing runs only after CI succeeds on the main branch. Scheduled rebuilds are used to pick up Debian package/security updates.

Additional maintenance workflows may open PRs for:

- NGINX mainline version bumps,
- Debian base image codename updates,
- submodule updates.

---

## 📁 Repository Layout

```text
.
├── build.sh
├── Dockerfile
├── luna
│   ├── branding-patch.sh
│   ├── openssl-downloader.sh
│   ├── nginx-internals
│   └── modules
└── .github
    └── workflows
```

Important paths:

```text
build.sh                     Host build/install script
Dockerfile                   Container image build
luna/branding-patch.sh       Luna server/error-page branding patch
luna/openssl-downloader.sh   OpenSSL download/preparation script
luna/modules/                NGINX third-party modules as submodules
luna/nginx-internals/        Additional internal NGINX source patches
```

---

## ⚠️ Notes

HTTP/3 / QUIC requires:

- NGINX built with `--with-http_v3_module`,
- a QUIC-capable TLS stack,
- TLS 1.3,
- UDP port 443 exposed and reachable,
- a `listen ... quic` directive in the HTTPS server block.

For Docker deployments, publishing TCP 443 alone is not enough. UDP 443 must also be published:

```yaml
ports:
  - "443:443/tcp"
  - "443:443/udp"
```

---

## 📜 License

The Luna-HTTP/S build scripts, Dockerfile, CI workflows, and Luna-specific patches in this repository are licensed under the BSD 2-Clause License.

NGINX, OpenSSL, and bundled third-party modules remain subject to their respective upstream licenses.
