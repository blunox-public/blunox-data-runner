# Blunox runner

The **Blunox runner** is the data-plane binary that executes replication and query
work in **your** cloud. You run it; Blunox runs the control plane.

- **Egress-only.** One outbound gRPC stream on TCP 443. No inbound ports, no
  public IP, nothing dials in.
- **Your credentials stay yours.** The runner reads your database and warehouse
  credentials from your own secret store using its ambient cloud identity. They
  never reach Blunox.
- **Your data stays yours.** Rows move from your source to your sink. Only
  metadata — status, checkpoints, lineage — reaches the control plane.
- **Stateless.** No database, no volumes. Replacing the runner loses nothing.

This repository holds the public artifacts for installing it: the manifest, the
admission policy, and the image-signing details. It is not the product source.

## Install

Create a runner in the Blunox console (**Runners → Create runner**). It returns a
`RUNNER_TOKEN`, shown once, and prints a complete install command for the shape
you choose. The token carries both the runner's credential and the addresses it
needs, so there is nothing else to configure.

**Kubernetes** — apply the manifest the console generated, or start from
[`k8s/runner.yaml`](k8s/runner.yaml):

```bash
kubectl apply -f - <<'YAML'
# ...the console's output, already filled in...
YAML
```

**Docker / VM** — the runner must stay resident, so run it as a long-lived
service:

```bash
docker run -d --name blunox-runner --restart unless-stopped \
  --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
  -e RUNNER_TOKEN=bnxr_v1_... \
  -e RUNNER_NAME=my-runner \
  -e RUNNER_ENVIRONMENT=prod \
  -e RUNNER_CAPABILITIES=pulse.cdc.postgres \
  -e RUNNER_BYOC_SECRET_STORES=gcp \
  ghcr.io/blunox-org/runner:<version>
```

> **Do not run the runner on a scale-to-zero platform** (Cloud Run, Lambda,
> Container Apps). It holds a continuous replication stream and must stay
> resident.

## Configuration

| Variable | Required | What it is |
|---|---|---|
| `RUNNER_TOKEN` | yes | The credential from the console. Carries the runner's identity and the control-plane addresses. Shown once. |
| `RUNNER_NAME` | yes | Name shown in the console fleet view. |
| `RUNNER_ENVIRONMENT` | yes | The single environment this runner serves. |
| `RUNNER_CAPABILITIES` | yes | Comma-separated work types this runner accepts. |
| `RUNNER_BYOC_SECRET_STORES` | yes | Where to read your credentials from (`gcp` today). |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | no | Your own collector. Unset disables telemetry export entirely. |

`RUNNER_TOKEN` is a credential. Keep it in a Secret or a `chmod 600` env file, and
never commit it.

## Network requirements

Outbound TCP 443 only. Nothing inbound.

| Destination | Why | When |
|---|---|---|
| your Blunox gateway host | control stream + registration | always |
| your Blunox auth host | token exchange and refresh | always¹ |
| `ghcr.io` and its CDN | pulling the runner image | install and upgrade |
| your cloud's secret API and metadata server | reading your credentials | always |
| your own databases and warehouses | the actual work | always |

¹ Where your cell fronts the token endpoint at the gateway, these are the same
host and the whole rule is one hostname.

Two things worth checking in a locked-down network:

- **HTTP/2 must survive end to end.** The control channel is gRPC over HTTP/2,
  not WebSocket. An SSL-inspection appliance that downgrades to HTTP/1.1 breaks it
  with `505 HTTP Version Not Supported`. If yours re-signs TLS, its root
  certificate must be trusted inside the container.
- **No keepalive tuning is needed.** The runner sends heartbeats every 15s, which
  hold the connection open through NAT.

Nothing needs to stay reachable for a *running* runner except the control plane
and your own systems — all capabilities are built into the single image, so no
registry is contacted at runtime.

## Verifying the image

See [SIGNING.md](SIGNING.md). Verification is optional at install and stronger
enforced at admission control — [`policy/kyverno-verify-runner.yaml`](policy/kyverno-verify-runner.yaml).

## Versions and upgrades

Images are published as immutable versions (`ghcr.io/blunox-org/runner:2026.08.0`)
and as moving channel aliases (`:stable`, `:lts`).

**Pin the version, not the channel, on any install running more than one replica.**
Kubernetes pulls with `IfNotPresent`, so a moving tag can leave a node serving
bytes it cached earlier while a new node pulls something newer — and two runner
versions working the same sync will corrupt its checkpoints. The console resolves
your chosen channel to a version for exactly this reason. A single-container
Docker host has no such risk and may follow a channel.

To upgrade: change the version and re-apply. The runner finishes in-flight work
and reaches a checkpoint before exiting, so replication resumes rather than
replays.

## Support

Issues with the runner can be filed here. For anything account-, billing-, or
data-specific, use your normal Blunox support channel — please do not put
credentials, connection strings or customer data in a public issue.
