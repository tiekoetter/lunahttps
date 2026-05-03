#!/usr/bin/env bash
set -euo pipefail

SERVER_OFF='luna-http/s'
ERROR_OFF='Luna-HTTP/S'

header_file="src/http/ngx_http_header_filter_module.c"
error_file="src/http/ngx_http_special_response.c"
h2_file="src/http/v2/ngx_http_v2_filter_module.c"
h3_file="src/http/v3/ngx_http_v3_filter_module.c"

require_file() {
  test -f "$1" || {
    echo "Required source file not found: $1" >&2
    exit 1
  }
}

require_pattern() {
  local pattern="$1"
  local file="$2"

  grep -qE "$pattern" "$file" || {
    echo "Expected pattern not found in $file:" >&2
    echo "$pattern" >&2
    exit 1
  }
}

patch_http1() {
  require_file "$header_file"

  require_pattern 'static u_char ngx_http_server_string\[\] = "Server: nginx" CRLF;' "$header_file"
  require_pattern 'static u_char ngx_http_server_full_string\[\] = "Server: " NGINX_VER CRLF;' "$header_file"
  require_pattern 'static u_char ngx_http_server_build_string\[\] = "Server: " NGINX_VER_BUILD CRLF;' "$header_file"

  sed -i -E \
    's|static u_char ngx_http_server_string\[\] = "Server: nginx" CRLF;|static u_char ngx_http_server_string[] = "Server: luna-http/s" CRLF;|' \
    "$header_file"

  sed -i -E \
    's|static u_char ngx_http_server_full_string\[\] = "Server: " NGINX_VER CRLF;|static u_char ngx_http_server_full_string[] = "Server: luna-http/s+" NGINX_VERSION CRLF;|' \
    "$header_file"

  sed -i -E \
    's|static u_char ngx_http_server_build_string\[\] = "Server: " NGINX_VER_BUILD CRLF;|static u_char ngx_http_server_build_string[] = "Server: luna-http/s+" NGINX_VERSION CRLF;|' \
    "$header_file"

  grep -q 'Server: luna-http/s' "$header_file"
  grep -q 'Server: luna-http/s+' "$header_file"
}

patch_error_pages() {
  require_file "$error_file"

  sed -i -E \
    's|"<hr><center>nginx</center>" CRLF|"<hr><center>Luna-HTTP/S</center>" CRLF|' \
    "$error_file"

  sed -i -E \
    's|"<hr><center>" NGINX_VER "</center>" CRLF|"<hr><center>Luna-HTTP/S+" NGINX_VERSION "</center>" CRLF|' \
    "$error_file"

  sed -i -E \
    's|"<hr><center>" NGINX_VER_BUILD "</center>" CRLF|"<hr><center>Luna-HTTP/S+" NGINX_VERSION "</center>" CRLF|' \
    "$error_file"

  grep -q '<hr><center>Luna-HTTP/S' "$error_file" || {
    echo "Error-page branding patch did not apply" >&2
    exit 1
  }
}

patch_http2() {
  if [ ! -f "$h2_file" ]; then
    echo "HTTP/2 source not found, skipping: $h2_file"
    return
  fi

  perl -0pi -e '
    s|    static const u_char nginx\[5\] = \{ 0x84, 0xaa, 0x63, 0x55, 0xe7 \};|    static size_t luna_len = ngx_http_v2_literal_size("luna-http/s");\n    static u_char luna[ngx_http_v2_literal_size("luna-http/s")];|s;

    s|    static size_t nginx_ver_len = ngx_http_v2_literal_size\(NGINX_VER\);\n    static u_char nginx_ver\[ngx_http_v2_literal_size\(NGINX_VER\)\];\n\n    static size_t nginx_ver_build_len =\n        ngx_http_v2_literal_size\(NGINX_VER_BUILD\);\n    static u_char nginx_ver_build\[ngx_http_v2_literal_size\(NGINX_VER_BUILD\)\];|    static size_t nginx_ver_len =\n        ngx_http_v2_literal_size("luna-http/s+" NGINX_VERSION);\n    static u_char nginx_ver[\n        ngx_http_v2_literal_size("luna-http/s+" NGINX_VERSION)];\n\n    static size_t nginx_ver_build_len =\n        ngx_http_v2_literal_size("luna-http/s+" NGINX_VERSION);\n    static u_char nginx_ver_build[\n        ngx_http_v2_literal_size("luna-http/s+" NGINX_VERSION)];|s;

    s|        \} else \{\n            len \+= 1 \+ sizeof\(nginx\);\n        \}|        } else {\n            len += 1 + luna_len;\n        }|s;

    s|"http2 output header: \\\\"server: nginx\\\\""|"http2 output header: \\\\"server: luna-http/s\\\\""|g;

    s|p = ngx_http_v2_write_value\(nginx_ver, \(u_char \*\) NGINX_VER,\n                                           sizeof\(NGINX_VER\) - 1, tmp\);|p = ngx_http_v2_write_value(nginx_ver,\n                                           (u_char *) "luna-http/s+" NGINX_VERSION,\n                                           sizeof("luna-http/s+" NGINX_VERSION) - 1,\n                                           tmp);|s;

    s|p = ngx_http_v2_write_value\(nginx_ver_build,\n                                           \(u_char \*\) NGINX_VER_BUILD,\n                                           sizeof\(NGINX_VER_BUILD\) - 1, tmp\);|p = ngx_http_v2_write_value(nginx_ver_build,\n                                           (u_char *) "luna-http/s+" NGINX_VERSION,\n                                           sizeof("luna-http/s+" NGINX_VERSION) - 1,\n                                           tmp);|s;

    s|        \} else \{\n            pos = ngx_cpymem\(pos, nginx, sizeof\(nginx\)\);\n        \}|        } else {\n            if (luna[0] == '\''\\0'\'') {\n                p = ngx_http_v2_write_value(luna, (u_char *) "luna-http/s",\n                                            sizeof("luna-http/s") - 1, tmp);\n                luna_len = p - luna;\n            }\n\n            pos = ngx_cpymem(pos, luna, luna_len);\n        }|s;
  ' "$h2_file"

  if grep -qE 'sizeof\(nginx\)|server: nginx' "$h2_file"; then
    echo "HTTP/2 branding patch incomplete" >&2
    grep -nE 'sizeof\(nginx\)|server: nginx|NGINX_VER|NGINX_VER_BUILD' "$h2_file" || true
    exit 1
  fi

  grep -q 'luna-http/s' "$h2_file" || {
    echo "HTTP/2 branding patch did not apply" >&2
    exit 1
  }
}

patch_http3() {
  if [ ! -f "$h3_file" ]; then
    echo "HTTP/3 source not found, skipping: $h3_file"
    return
  fi

  # HTTP/3/QPACK source layout changes more often than HTTP/1.
  # These replacements intentionally fail below if nginx branding remains.
  perl -0pi -e '
    s|"server: nginx"|"server: luna-http/s"|g;
    s|"nginx"|"luna-http/s"|g;
    s|NGINX_VER_BUILD|"luna-http/s+" NGINX_VERSION|g;
    s|NGINX_VER|"luna-http/s+" NGINX_VERSION|g;
  ' "$h3_file"

  if grep -qE 'server: nginx|"nginx"|NGINX_VER|NGINX_VER_BUILD' "$h3_file"; then
    echo "HTTP/3 branding patch incomplete" >&2
    grep -nE 'server: nginx|"nginx"|NGINX_VER|NGINX_VER_BUILD' "$h3_file" || true
    exit 1
  fi

  grep -q 'luna-http/s' "$h3_file" || {
    echo "HTTP/3 branding patch did not apply" >&2
    exit 1
  }
}

patch_http1
patch_error_pages
patch_http2
patch_http3

echo "Luna branding patch applied successfully"

grep -RIn 'luna-http/s\|Luna-HTTP/S' \
  "$header_file" \
  "$error_file" \
  "$h2_file" \
  "$h3_file" 2>/dev/null || true
