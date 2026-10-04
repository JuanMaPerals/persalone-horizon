# Cloudflare edge for HORIZON

## Current classification

Cloudflare Tunnel and the Zero Trust client are present on the host, but HORIZON is **not** currently an ingress of the persistent tunnel. Existing PersalOne hostnames belong to other services and must not be repurposed implicitly.

## Required HORIZON pattern

- Keep runtime `/metrics`, Prometheus and Grafana `LOCAL_ONLY` or private by default.
- Do not publish raw Prometheus, Grafana admin, runtime SSE, ADB-forwarded ports or control-plane endpoints through a quick tunnel.
- If a browser-facing HORIZON service later needs remote access, expose only that narrow service behind a named Cloudflare Tunnel hostname with Cloudflare Access authentication and explicit authorization.
- Prefer a separate HORIZON ingress/service identity and hostname rather than extending unrelated application routes.
- Keep tunnel credentials outside this repository. Never place Access service tokens, tunnel credentials or origin credentials in browser code, Git history, dashboard JSON or logs.
- Preserve the existing persistent tunnel configuration until a separately authorized edge change has target identity, rollback and post-change verification.

## Verification contract

A future Cloudflare cutover is not `PASS` until all are observed on the exact hostname: authenticated edge policy, unauthorized request denied, authorized request succeeds, origin remains non-public, audit evidence exists, and rollback is verified.
