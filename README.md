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

This repository holds the public artifacts for installing it: the Kubernetes
manifest and the install documentation. It is not the product source.

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

**VM** — on any Linux VM (amd64) with outbound 443, one script installs it.
Save the console's **runner.env** block on the VM, then:

```bash
curl -fsSLO https://raw.githubusercontent.com/blunox-public/blunox-data-runner/main/install-runner.sh
sudo bash install-runner.sh --env-file runner.env \
  --image ghcr.io/blunox-public/blunox-data-runner:<version>
```

Or run `sudo bash install-runner.sh --env-file -`, paste the block, and press
Ctrl-D. Before it starts anything, the script checks:

- the token is well formed, and the control plane answers over HTTP/2 from the VM;
- on Google Compute Engine, with `RUNNER_BYOC_SECRET_STORES=gcp`, the VM has a
  service account with the `cloud-platform` scope;
- Docker is installed. If it is missing on Debian or Ubuntu, the script installs
  it from the distribution's packages.

It then starts the runner and its SQL parser with a restart policy, so they come
back after a reboot, and waits until the runner reports `control channel
connected`. The token is kept in a root-only `0600` file under `/etc/blunox`
and is never passed on a command line.

| Flag | What it does |
|---|---|
| `--env-file FILE` | The console's runner.env block; `-` reads it from the terminal. |
| `--image REF` | The runner image (default `:stable`). |
| `--no-sql-parser` | Skip the SQL parser. BigQuery SQL is then refused; replication is unaffected. |
| `--upgrade --image REF` | Keep the configuration and change only the version. |
| `--status` | The runner, its containers and its key log lines. |
| `--uninstall` | Remove the containers and the stored token. Then revoke the runner in the console. |

Read the script before you run it: it is short, and it runs as root.

**Docker by hand** — the same thing without the script. Run it from the
directory holding `runner.env`, so the token stays in a file:

```bash
docker run -d --name blunox-runner --restart unless-stopped --stop-timeout 600 \
  --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
  --env-file runner.env \
  ghcr.io/blunox-public/blunox-data-runner:<version>
```

> **Do not run the runner on a scale-to-zero platform** (Cloud Run, Lambda,
> Container Apps). It holds a continuous replication stream and must stay
> resident.

## Configuration

| Variable | Required | What it is |
|---|---|---|
| `RUNNER_TOKEN` | yes | The credential from the console. Carries the runner's identity and the control-plane addresses. Shown once. |
| `RUNNER_NAME` | yes | Name shown in the console fleet view. |
| `RUNNER_PROJECT_ID` | yes | The single project this runner serves. |
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

## Image integrity

Images are **not signed**. What you get instead is immutable identity: every
release is published under a version tag that is never moved, and its digest is
listed in the release notes.

If you want the strongest guarantee available, pin the digest rather than the tag:

```
ghcr.io/blunox-public/blunox-data-runner@sha256:<digest-from-the-release-notes>
```

A digest is content-addressed, so a pinned deployment cannot be changed under you
— the image either matches those bytes or it does not pull at all. Kubernetes
accepts a digest anywhere a tag is accepted.

## Versions and upgrades

Images are published as immutable versions (`ghcr.io/blunox-public/blunox-data-runner:2026.08.0`)
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
