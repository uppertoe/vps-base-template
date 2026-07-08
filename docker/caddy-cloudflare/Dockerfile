# syntax=docker/dockerfile:1
# Caddy + the Cloudflare DNS-01 plugin, published as ghcr.io/uppertoe/vps-caddy
# by .github/workflows/publish-caddy.yml.
#
# Why a custom image: serving ANYTHING (even a themed 404) on an unknown
# subdomain under a wildcard DNS record needs a wildcard certificate, and
# wildcard issuance requires the ACME DNS-01 challenge — which stock Caddy
# cannot do without a DNS-provider plugin. Both stages are pinned by digest
# (Renovate maintains them); the runtime stage is the SAME caddy:2-alpine
# base the scaffold has always pinned, with only the binary swapped, so the
# CIS §5 hardening in caddy.base.yml carries over unchanged.

FROM caddy:builder-alpine@sha256:fd207488ae94421fe6a802e34006a50a6409e32fc0f68f5e779f26a45540d6a9 AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare@v0.2.4

FROM caddy:2-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
