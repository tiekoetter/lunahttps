# Luna-HTTP/S

Custom-built NGINX version with enhanced performance, modern protocol support, and security-focused features.

---

## ✨ Features

- **Based on NGINX** `mainline`
- **OpenSSL with TLS 1.3 + kTLS** for modern, post-quantum cryptography
- **HTTP/3 / QUIC (experimental)** for reduced latency and faster connections
- **Brotli compression** for reduced bandwidth usage and faster page loads
- **ngx_http_geoip2_module** for GeoIP-based request handling
- **headers-more-nginx-module** for more header control
- **ngx_http_substitutions_filter_module** for RegEx filtering in headers

---

## 📦 Build Information

This build is tailored for high-performance environments and is compiled with additional modules and experimental protocol support.

**Included Modules:**
- [ngx_brotli](https://github.com/google/ngx_brotli)
- [ngx_http_geoip2_module](https://github.com/leev/ngx_http_geoip2_module)
- [headers-more-nginx-module](https://github.com/openresty/headers-more-nginx-module)
- [ngx_http_substitutions_filter_module](https://github.com/yaoweibin/ngx_http_substitutions_filter_module)

---

## 🔧 Building from Source

You can build this custom NGINX version using the provided build scripts in this repository.


### Build Steps

```bash
git clone https://github.com/tiekoetter/lunahttps.git
cd lunahttps
./build.sh
