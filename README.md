# Luna-HTTP/S

Custom-built NGINX with enhanced performance, modern protocol support, Docker image builds, and security-focused features.

Luna-HTTP/S is based on NGINX mainline and adds a curated build configuration with the latest stable OpenSSL release, TLS 1.3, post-quantum cryptography support, HTTP/2, HTTP/3 / QUIC, Brotli, real client IP handling, GeoIP2, advanced header manipulation, and response body substitution support.

Project information is available at [lunahttps.tiekoetter.net](https://lunahttps.tiekoetter.net).

---

## ✨ Features

- **Based on NGINX mainline**
- **OpenSSL with TLS 1.3 + kTLS** for modern transport security and improved performance
- **Post-quantum cryptography capable out of the box** through OpenSSL, including support for ML-KEM, ML-DSA, and SLH-DSA
- **Encrypted ClientHello (ECH)** support, with a helper script for setup and key rotation
- **HTTP/2 support**
- **HTTP/3 / QUIC support** for reduced latency and faster connections
- **Brotli compression** for reduced bandwidth usage and faster page loads
- **ngx_http_realip_module** for preserving trusted proxy client addresses
- **ngx_http_geoip2_module** for GeoIP-based request handling
- **headers-more-nginx-module** for advanced header control
- **ngx_http_substitutions_filter_module** for RegEx-based response body filtering and substitution
- **Docker image builds** published through GitHub Container Registry
- **Custom Luna branding** for generated server headers and error pages

---

## 📦 Build Information

This build is tailored for high-performance environments and is compiled with additional modules and experimental protocol support.

**Included modules:**

- [ngx_http_realip_module](https://nginx.org/en/docs/http/ngx_http_realip_module.html)
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

The OpenSSL version and tarball SHA256 are pinned in:

```text
luna/openssl-version.env
```

The pin follows the latest stable OpenSSL release (no alpha or beta versions), not an LTS series.

## 🔐 Post-Quantum Cryptography

Luna-HTTP/S is built with the latest stable OpenSSL release, which includes support for post-quantum cryptography algorithms such as ML-KEM, ML-DSA, and SLH-DSA.

This makes the build post-quantum capable out of the box and suitable for testing hybrid TLS key exchange and future-facing cryptographic deployments.

Actual post-quantum behavior depends on client support, TLS group configuration, OpenSSL defaults, and interoperability with the connecting peer.

## 🕶️ Encrypted ClientHello (ECH)

Luna-HTTP/S supports TLS 1.3 Encrypted ClientHello ([RFC 9849](https://datatracker.ietf.org/doc/html/rfc9849)) through the NGINX `ssl_ech_file` directive. ECH encrypts the requested hostname in the TLS handshake, so an observer only sees a shared public name. It works for HTTP/1.1, HTTP/2, and HTTP/3.

On a host install, the helper script sets it up for all server blocks:

```bash
sudo ./luna/ech-helper.sh --public-name public.example.com
```

The public name is the hostname that stays visible. A server block with a valid certificate for it must exist, because clients fall back to it when ECH fails.

The script:

1. generates an ECH key in `/etc/nginx/ech/`,
2. writes one file, `luna-ech.conf`, into `/etc/nginx/sites-enabled/`. It is loaded at `http` level, so every server block inherits it and existing files are not edited,
3. archives the directory to `/etc/nginx/sites-enabled.ech-backup-<timestamp>.tar.gz` before changing it (symlinks are stored as links),
4. checks the result with NGINX, restores the previous state if the check fails, and reloads NGINX,
5. prints the `ECHConfigList` to publish in DNS.

Running it again changes only what is missing. Other common calls:

```bash
sudo ./luna/ech-helper.sh --rotate           # new key; the current one is kept as previous key
sudo ./luna/ech-helper.sh /etc/nginx/conf.d  # another directory included inside the http block
./luna/ech-helper.sh --help
```

Clients only use ECH once the printed value is published in the HTTPS DNS record of each protected hostname:

```text
example.com. 300 IN HTTPS 1 . alpn="h3,h2" ech="<ECHConfigList>"
```

After `--rotate`, update the DNS records. The previous key stays valid until the next rotation.

To see whether a connection used ECH, log `$ssl_ech_status` (for example `SUCCESS`, `GREASE`, or `NOT_TRIED`).

Notes:

- Generating keys needs the `openssl ech` command from OpenSSL 4.0 or newer. The script uses the binary that `build.sh` leaves in `luna/openssl/.openssl/bin/`, then `openssl` from `PATH`; `--openssl PATH` overrides both.
- Do not set `ssl_ech_file` inside individual server blocks. NGINX only uses the ECH keys of the default server of a listening socket.
- The Docker image does not include the helper. Generate the key elsewhere with `openssl ech` from OpenSSL 4.0 or newer, mount it, and add `ssl_ech_file` at `http` level.

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

The binary also identifies itself as a Luna-HTTP/S build on the command line:

```text
$ nginx -v
nginx version: nginx/<nginx-version> (luna-http/s)
```

The `nginx/<nginx-version>` prefix is unchanged, so tools that detect NGINX or parse its version keep working. The build name is set with NGINX's own `--build` option, the same mechanism distribution packages use.

---

## 🐳 Docker Image

The Docker image is published to GitHub Container Registry:

```bash
docker pull ghcr.io/tiekoetter/lunahttps:latest
```

Published images carry a signed build provenance attestation. To check that an image was built by this repository's workflow, use the GitHub CLI:

```bash
gh attestation verify oci://ghcr.io/tiekoetter/lunahttps:latest --repo tiekoetter/lunahttps
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

Docker builds also expect the submodules to be initialized in the build context.
The Dockerfile uses the same build script in Docker mode:

```bash
./build.sh --docker
```

That mode performs the shared download, verification, patch, configure, build, and install flow without validating or restarting a host system service.

In default host mode, the build script will:

1. download and verify the pinned OpenSSL release,
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
- compiled NGINX modules and build name,
- runtime HTTP/1.1 and HTTP/2 branding,
- generated error page branding,
- HTTP/3 connectivity and branding with a dedicated QUIC/HTTP/3 client.

Docker image publishing runs after CI succeeds on the main branch, and can also be started manually. Each published multi-arch image gets a signed build provenance attestation.

Additional maintenance workflows may open PRs for:

- NGINX mainline version bumps,
- OpenSSL version/hash bumps to the latest stable release, after verifying the release signature,
- Debian base image codename updates,
- submodule updates, listing the upstream commits.

GitHub Actions are referenced by exact version tag and updated through Dependabot pull requests.

To report a vulnerability, see the [security policy](.github/SECURITY.md).

---

## 📁 Repository Layout

```text
.
├── build.sh
├── Dockerfile
├── luna
│   ├── branding-patch.sh
│   ├── ech-helper.sh
│   ├── nginx-signing-keys.txt
│   ├── openssl-downloader.sh
│   ├── openssl-version.env
│   └── modules
└── .github
    ├── scripts
    └── workflows
```

Important paths:

```text
build.sh                     Host build/install script
Dockerfile                   Container image build
luna/branding-patch.sh       Luna server/error-page branding patch
luna/ech-helper.sh           Encrypted ClientHello setup and key rotation
luna/nginx-signing-keys.txt  Pinned NGINX source signing keys
luna/openssl-downloader.sh   OpenSSL download/preparation script
luna/openssl-version.env     Pinned OpenSSL version and SHA256
luna/modules/                NGINX third-party modules as submodules
.github/scripts/             Helper scripts used by the workflows
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
