# HORIZON observability

The runtime metrics endpoint is intentionally `LOCAL_ONLY`. Do not widen its bind address to make Prometheus scraping convenient.

The Grafana dashboard in this directory consumes only the aggregate `horizon_runtime_*` metrics emitted by `RuntimeEventServer`. It contains no transcripts, translations, session IDs, device/account identifiers or credentials.

A collector must reach the runtime through an explicitly authorized local/private bridge (for Android validation, the existing ADB-forward workflow is the intended transport). If no runtime is reachable, Grafana must show `NO DATA`; do not substitute fixture telemetry.

Grafana Cloud authentication is operational configuration and must remain outside this repository. A Cloud exporter returning 401 is `CONTROL_UNAVAILABLE`, not a product PASS.
