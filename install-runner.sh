#!/usr/bin/env bash
# install-runner.sh — install, upgrade or remove the Blunox BYOC runner on a
# Linux VM in one command.
#
# Published as-is at
# https://raw.githubusercontent.com/blunox-public/blunox-data-runner/main/install-runner.sh
# so everything in this file is world-readable: no internal decision IDs, repo
# paths or service names (the public repository's scrub job, and this file's
# test, refuse them).
#
# Run it ON THE VM, as root. It takes the runner.env block the console printed
# (Runners → Create runner → Docker) and does what the console's "Run it" block
# does, plus the checks an operator otherwise runs by hand:
#
#   - the token is well formed and its gateway answers over HTTP/2 from here;
#   - on Compute Engine, the VM's service account and its scope, when the runner
#     reads connection secrets from GCP Secret Manager;
#   - Docker is installed (from the distribution's own packages if it is not);
#   - the runner (and its GoogleSQL parser) run with a restart policy, so they
#     come back after a reboot, and the runner is given 600s to quiesce on stop;
#   - it waits until the runner logs `control channel connected`.
#
# Usage:
#   sudo bash install-runner.sh --env-file runner.env [--image REF] [--no-sql-parser]
#   sudo bash install-runner.sh --env-file - ...     # paste runner.env, then Ctrl-D
#   sudo bash install-runner.sh --upgrade --image REF
#   sudo bash install-runner.sh --status
#   sudo bash install-runner.sh --uninstall
#
# Run again with a new --env-file to replace the configuration (a rotated token),
# or with --upgrade to change only the image. Both replace a runner started by
# hand with the console's commands, since the container names are the same.
#
# THE TOKEN. runner.env holds RUNNER_TOKEN, a credential. It is copied to
# $CONFIG_DIR/runner.env (root, 0600) and handed to Docker with --env-file, so it
# is never on a command line and never printed. The env file is parsed, never
# sourced. The runner's own logs never carry it, which is why a failed install
# prints them.
#
# Env knobs:
#   BLUNOX_CONFIG_DIR  where the installed runner.env lives (default /etc/blunox;
#                      /var/lib/blunox on Container-Optimized OS, whose /etc does
#                      not survive a reboot).
#   CONNECT_TIMEOUT    seconds to wait for the control channel (default 120).
set -euo pipefail

DEFAULT_IMAGE="ghcr.io/blunox-public/blunox-data-runner:stable"
# Tagged by the GoogleSQL commit the runner's parser protocol was vendored from:
# the tag IS the wire contract, so it is pinned, never a channel.
GOOGLESQL_IMAGE="${GOOGLESQL_IMAGE:-ghcr.io/blunox-public/googlesql-local-service:d82db99a923a46571f543a13899dc791a7b6f743}"
GOOGLESQL_ADDR="http://blunox-googlesql:50051"
RUNNER=blunox-runner
PARSER=blunox-googlesql
NETWORK=blunox-runner
METADATA="${METADATA_URL:-http://metadata.google.internal/computeMetadata/v1}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-120}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }
step() { printf '==> %s\n' "$*"; }

usage() {
	sed -n '/^# Usage:/,/^# Run again/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
	exit "${1:-0}"
}

default_config_dir() {
	if grep -qs '^ID=cos$' /etc/os-release; then echo /var/lib/blunox; else echo /etc/blunox; fi
}
CONFIG_DIR="${BLUNOX_CONFIG_DIR:-$(default_config_dir)}"
CONFIG="$CONFIG_DIR/runner.env"

# env_get FILE KEY — the last value of KEY, as docker --env-file reads it.
env_get() { grep -E "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true; }

# env_set FILE KEY VALUE — set (or with an empty VALUE, drop) KEY, in place.
env_set() {
	local tmp
	tmp="$(mktemp "$1.XXXXXX")"
	grep -vE "^$2=" "$1" >"$tmp" || true
	[ -z "$3" ] || printf '%s=%s\n' "$2" "$3" >>"$tmp"
	chmod 600 "$tmp"
	mv -f "$tmp" "$1"
}

# check_env FILE — refuse a runner.env the runner would refuse, before it runs.
check_env() {
	local f="$1" line n=0 tok
	while IFS= read -r line || [ -n "$line" ]; do
		n=$((n + 1))
		case "$line" in '' | '#'*) continue ;; esac
		[[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] ||
			die "runner.env line $n is not KEY=value (was the \"Run it\" block pasted into it?)"
	done <"$f"
	grep -q 'REPLACE_' "$f" && die "runner.env still holds REPLACE_ placeholders; use the block the console printed"
	tok="$(env_get "$f" RUNNER_TOKEN)"
	[ -n "$tok" ] || die "runner.env has no RUNNER_TOKEN"
	case "$tok" in
	\"* | \'*) die "RUNNER_TOKEN is quoted; docker --env-file keeps quotes, so remove them" ;;
	bnxr_v1_?*) ;;
	*) die "RUNNER_TOKEN is not a runner token (it starts bnxr_v1_); copy it again from the console" ;;
	esac
	[ -n "$(env_get "$f" RUNNER_PROJECT_ID)" ] || die "runner.env has no RUNNER_PROJECT_ID"
	[ -n "$(env_get "$f" RUNNER_NAME)" ] || die "runner.env has no RUNNER_NAME"
}

# gateway_url FILE — the gateway origin RUNNER_TOKEN routes to. The token is
# bnxr_v1_<base64url(JSON)>; only its gateway_url is read, and nothing else from
# it reaches the screen.
gateway_url() {
	local b64
	b64="$(env_get "$1" RUNNER_TOKEN)"
	b64="${b64#bnxr_v1_}"
	b64="$(printf '%s' "$b64" | tr '_-' '/+')"
	while [ $(( ${#b64} % 4 )) -ne 0 ]; do b64="$b64="; done
	printf '%s' "$b64" | base64 -d 2>/dev/null |
		grep -o '"gateway_url":"[^"]*"' | head -1 | cut -d'"' -f4 || true
}

check_gateway() {
	local gw out code version
	gw="$(gateway_url "$1")"
	[ -n "$gw" ] || die "RUNNER_TOKEN carries no gateway address; copy it again from the console"
	step "Checking the gateway at $gw"
	out="$(curl -sS -o /dev/null --max-time 15 -w '%{http_code} %{http_version}' "${gw%/}/readyz" 2>&1)" ||
		die "cannot reach $gw from this VM ($out). The runner needs outbound TCP 443 to it: check the firewall, NAT or proxy."
	code="${out%% *}" version="${out##* }"
	if [ "$version" != 2 ]; then
		warn "$gw answered over HTTP/$version, not HTTP/2. The runner's control channel is gRPC and needs HTTP/2 end to end; a proxy that downgrades it breaks the runner."
	fi
	echo "    reachable (HTTP $code over HTTP/$version)"
}

# check_identity FILE — the VM's Google identity, when the runner needs one.
check_identity() {
	local stores email scopes
	stores="$(env_get "$1" RUNNER_BYOC_SECRET_STORES)"
	email="$(curl -sf --max-time 3 -H 'Metadata-Flavor: Google' "$METADATA/instance/service-accounts/default/email" 2>/dev/null || true)"
	if [ -z "$email" ]; then
		[[ ",$stores," == *",gcp,"* ]] &&
			die "RUNNER_BYOC_SECRET_STORES=gcp, but this VM has no Google service account attached (or is not on Compute Engine). Attach one with --scopes=cloud-platform, or remove that line to use Blunox-managed credentials only."
		return 0
	fi
	step "Checking the VM's Google identity"
	echo "    service account: $email"
	scopes="$(curl -sf --max-time 3 -H 'Metadata-Flavor: Google' "$METADATA/instance/service-accounts/default/scopes" 2>/dev/null || true)"
	if [[ ",$stores," == *",gcp,"* ]]; then
		grep -q 'auth/cloud-platform$' <<<"$scopes" ||
			die "the VM's access scopes do not include cloud-platform, which blocks Secret Manager whatever IAM grants. Stop the VM and run: gcloud compute instances set-service-account <vm> --service-account $email --scopes cloud-platform"
		echo "    reads connection secrets from GCP Secret Manager (needs roles/secretmanager.secretAccessor on them)"
	fi
	case "$email" in
	*-compute@developer.gserviceaccount.com)
		warn "the VM runs as the Compute Engine default service account, which often holds Editor on the whole project. Prefer a dedicated service account holding only the roles the runner needs." ;;
	esac
}

ensure_docker() {
	if command -v docker >/dev/null 2>&1; then return 0; fi
	if command -v apt-get >/dev/null 2>&1; then
		step "Installing Docker from the distribution's packages"
		DEBIAN_FRONTEND=noninteractive apt-get update -q
		DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker.io
		systemctl enable --now docker
	else
		die "Docker is not installed and this is not a Debian or Ubuntu VM; install Docker, then run this again"
	fi
}

container_exists() { docker container inspect "$1" >/dev/null 2>&1; }

# stop_container NAME — stop it with time to quiesce (the runner flushes sinks and
# reaches a checkpoint boundary), then remove it.
stop_container() {
	container_exists "$1" || return 0
	docker stop --time 600 "$1" >/dev/null 2>&1 || true
	docker rm -f "$1" >/dev/null
}

run_parser() {
	docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK" >/dev/null
	stop_container "$PARSER"
	docker run -d --name "$PARSER" --network "$NETWORK" --restart unless-stopped \
		--read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges --memory 2g \
		"$GOOGLESQL_IMAGE" --listen=0.0.0.0:50051 >/dev/null
}

remove_parser() {
	stop_container "$PARSER"
	docker network rm "$NETWORK" >/dev/null 2>&1 || true
}

run_runner() {
	local image="$1" parser="$2" net=()
	[ "$parser" = 1 ] && net=(--network "$NETWORK")
	stop_container "$RUNNER"
	docker run -d --name "$RUNNER" ${net[@]+"${net[@]}"} --restart unless-stopped --stop-timeout 600 \
		--read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
		--env-file "$CONFIG" "$image" >/dev/null
}

# wait_connected — until the runner logs `control channel connected`, or fails.
wait_connected() {
	local waited=0 state
	step "Waiting for the runner to connect (up to ${CONNECT_TIMEOUT}s)"
	while :; do
		if docker logs "$RUNNER" 2>&1 | grep -q 'control channel connected'; then
			echo "    connected"
			return 0
		fi
		state="$(docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$RUNNER" 2>/dev/null || echo missing)"
		case "$state" in
		running\ 0) ;;
		*) printf 'error: the runner is not running (%s). Its last log lines:\n' "$state" >&2
			docker logs --tail 30 "$RUNNER" >&2 2>&1 || true
			exit 1 ;;
		esac
		if [ "$waited" -ge "$CONNECT_TIMEOUT" ]; then
			printf 'error: no control channel after %ss. Its last log lines:\n' "$CONNECT_TIMEOUT" >&2
			docker logs --tail 30 "$RUNNER" >&2 2>&1 || true
			exit 1
		fi
		sleep 2
		waited=$((waited + 2))
	done
}

show_status() {
	[ -f "$CONFIG" ] || die "no runner is installed by this script ($CONFIG is missing)"
	echo "config:  $CONFIG"
	echo "name:    $(env_get "$CONFIG" RUNNER_NAME)"
	echo "project: $(env_get "$CONFIG" RUNNER_PROJECT_ID)"
	echo "image:   $(env_get "$CONFIG" RUNNER_IMAGE)"
	echo
	docker ps -a --filter "name=^blunox-" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
	echo
	docker logs "$RUNNER" 2>&1 | grep -E 'runner credential|sql parsers|control channel|"severity":"error"' | tail -10 || true
}

uninstall() {
	step "Stopping the runner (it is given up to 600s to reach a checkpoint)"
	stop_container "$RUNNER"
	remove_parser
	rm -f "$CONFIG"
	echo "Removed. Revoke the runner in the console (Runners) so no further tokens are issued for it."
}

install() {
	local src="$1" image="$2" no_parser="$3" upgrade="$4" tmp parser=0

	[ "$(uname -m)" = x86_64 ] || die "the runner image is published for amd64 only; this VM is $(uname -m)"
	umask 077
	mkdir -p "$CONFIG_DIR"
	chmod 700 "$CONFIG_DIR"
	tmp="$(mktemp "$CONFIG_DIR/runner.env.new.XXXXXX")"
	trap 'rm -f "$tmp"' EXIT

	if [ "$upgrade" = 1 ]; then
		[ -f "$CONFIG" ] || die "--upgrade needs an installed runner ($CONFIG is missing); install with --env-file first"
		cp "$CONFIG" "$tmp"
	elif [ "$src" = - ]; then
		[ -t 0 ] && echo "Paste the console's runner.env block, then press Ctrl-D:"
		cat >"$tmp"
	else
		[ -f "$src" ] || die "env file not found: $src"
		cat "$src" >"$tmp"
	fi
	# A block copied from a browser on Windows carries CRLF, which docker would keep.
	sed -i.bak 's/\r$//' "$tmp" && rm -f "$tmp.bak"
	check_env "$tmp"

	image="${image:-$(env_get "$tmp" RUNNER_IMAGE)}"
	image="${image:-$DEFAULT_IMAGE}"
	env_set "$tmp" RUNNER_IMAGE "$image"
	[ "$no_parser" = 1 ] && env_set "$tmp" RUNNER_GOOGLESQL_ADDR ""
	[ -n "$(env_get "$tmp" RUNNER_GOOGLESQL_ADDR)" ] && parser=1
	if [ "$parser" = 1 ] && [ "$(env_get "$tmp" RUNNER_GOOGLESQL_ADDR)" != "$GOOGLESQL_ADDR" ]; then
		warn "RUNNER_GOOGLESQL_ADDR is $(env_get "$tmp" RUNNER_GOOGLESQL_ADDR); the parser this script runs listens at $GOOGLESQL_ADDR"
	fi

	check_gateway "$tmp"
	check_identity "$tmp"
	ensure_docker

	step "Pulling $image"
	docker pull -q "$image" >/dev/null
	if [ "$parser" = 1 ]; then
		step "Pulling the GoogleSQL parser"
		docker pull -q "$GOOGLESQL_IMAGE" >/dev/null
	fi

	mv -f "$tmp" "$CONFIG"
	trap - EXIT

	if container_exists "$RUNNER"; then
		step "Replacing the running runner (it is given up to 600s to reach a checkpoint)"
	else
		step "Starting the runner"
	fi
	if [ "$parser" = 1 ]; then run_parser; else remove_parser; fi
	run_runner "$image" "$parser"
	wait_connected

	cat <<EOF

The runner "$(env_get "$CONFIG" RUNNER_NAME)" is connected. It should show as online
under Runners in the console within a few seconds.

  config     $CONFIG (root only; holds RUNNER_TOKEN)
  image      $image
  parser     $([ "$parser" = 1 ] && echo "$PARSER (BigQuery statements allowed)" || echo "none (BigQuery statements are refused)")
  restarts   with Docker, after a crash or a reboot

  status     sudo bash $0 --status
  upgrade    sudo bash $0 --upgrade --image ghcr.io/blunox-public/blunox-data-runner:<version>
  remove     sudo bash $0 --uninstall
EOF
	if [ "$upgrade" != 1 ] && [ "$src" != - ]; then
		printf '\nThe token is now in %s. Delete your copy: rm %s\n' "$CONFIG" "$src"
	fi
}

main() {
	local mode=install src="" image="" no_parser=0 args="$*"
	while [ $# -gt 0 ]; do
		case "$1" in
		--env-file) src="${2:?--env-file needs a path, or - for stdin}"; shift 2 ;;
		--image) image="${2:?--image needs an image reference}"; shift 2 ;;
		--no-sql-parser) no_parser=1; shift ;;
		--upgrade) mode=upgrade; shift ;;
		--status) mode=status; shift ;;
		--uninstall) mode=uninstall; shift ;;
		-h | --help) usage 0 ;;
		*) printf 'unknown argument: %s\n\n' "$1" >&2; usage 2 ;;
		esac
	done
	[ "$(id -u)" -eq 0 ] || die "run it as root: sudo bash $0 $args"

	case "$mode" in
	status) show_status ;;
	uninstall) uninstall ;;
	upgrade)
		[ -z "$src" ] || die "--upgrade reuses the installed runner.env; to replace it, run with --env-file and no --upgrade"
		install "" "$image" "$no_parser" 1 ;;
	install)
		[ -n "$src" ] || die "--env-file is required: the runner.env block the console printed (or - to paste it)"
		install "$src" "$image" "$no_parser" 0 ;;
	esac
}

main "$@"
