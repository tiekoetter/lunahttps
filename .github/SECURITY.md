# Security Policy

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/tiekoetter/lunahttps/security/advisories/new).
Do not open a public issue for security problems.

## Scope

This policy covers what this repository adds on top of its upstream projects:

- the build scripts and Luna-specific patches,
- the Dockerfile and the published `ghcr.io/tiekoetter/lunahttps` image,
- the GitHub Actions workflows.

Vulnerabilities in NGINX, OpenSSL, or the bundled third-party modules should be
reported to the respective upstream project. Upstream fixes reach this
repository through the automated version and submodule update pull requests.

## Supported versions

Only the current `main` branch and the `latest` image are supported.
