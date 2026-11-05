#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rust_version="$(sed -n 's/^channel = "\(.*\)"/\1/p' "$repo_root/server/rust-toolchain.toml")"
build_dir=/private/tmp/louie-pi-build
pi=louie@192.168.4.58
ssh_options=(-o BatchMode=yes -o HostKeyAlias=louie-pi.local)

if [[ -z "$rust_version" ]]; then
  echo 'Could not read the pinned Rust version' >&2
  exit 1
fi

mkdir -p "$build_dir"
docker run --rm --platform linux/arm64 \
  --mount "type=bind,source=$repo_root,target=/work,readonly" \
  --mount "type=bind,source=$build_dir,target=/target" \
  --workdir /work/server \
  --env CARGO_TARGET_DIR=/target \
  "rust:$rust_version-bookworm" \
  cargo build --release --locked --bins --examples

artifact_dir="$build_dir/release"

ssh "${ssh_options[@]}" "$pi" \
  'mkdir -p ~/.local/bin ~/.config/systemd/user && test -f ~/.config/louie/server.env'
scp "${ssh_options[@]}" "$artifact_dir/louie-server" \
  "$pi:/home/louie/.local/bin/louie-server.new"
scp "${ssh_options[@]}" "$artifact_dir/examples/check_linn" \
  "$pi:/home/louie/.local/bin/check_linn.new"
scp "${ssh_options[@]}" "$repo_root/server/deploy/louie.service" \
  "$pi:/home/louie/.config/systemd/user/louie.service.new"

local_sha="$(shasum -a 256 "$artifact_dir/louie-server" | cut -d ' ' -f 1)"
remote_sha="$(ssh "${ssh_options[@]}" "$pi" \
  'sha256sum ~/.local/bin/louie-server.new' | cut -d ' ' -f 1)"
if [[ "$local_sha" != "$remote_sha" ]]; then
  echo 'Copied binary checksum did not match' >&2
  exit 1
fi

ssh "${ssh_options[@]}" "$pi" '
  set -eu
  if test -f ~/.local/bin/louie-server; then
    cp -p ~/.local/bin/louie-server ~/.local/bin/louie-server.previous
  fi
  if test -f ~/.local/bin/check_linn; then
    cp -p ~/.local/bin/check_linn ~/.local/bin/check_linn.previous
  fi
  if test -f ~/.config/systemd/user/louie.service; then
    cp -p ~/.config/systemd/user/louie.service ~/.config/systemd/user/louie.service.previous
  fi
  mv ~/.local/bin/louie-server.new ~/.local/bin/louie-server
  chmod 755 ~/.local/bin/louie-server
  mv ~/.local/bin/check_linn.new ~/.local/bin/check_linn
  chmod 755 ~/.local/bin/check_linn
  mv ~/.config/systemd/user/louie.service.new ~/.config/systemd/user/louie.service
  systemctl --user daemon-reload
  systemctl --user enable louie.service
  systemctl --user restart louie.service
'

if ! ssh "${ssh_options[@]}" "$pi" '
  set -eu
  bind=$(sed -n "s/^LOUIE_GRPC_BIND=//p" ~/.config/louie/server.env | tail -n 1)
  bind=${bind#\"}
  bind=${bind%\"}
  if test -z "$bind"; then
    echo "LOUIE_GRPC_BIND is required" >&2
    exit 1
  fi
  host=${bind%:*}
  port=${bind##*:}
  case "$host" in
    0.0.0.0|"[::]"|"[::0]") host=127.0.0.1 ;;
  esac
  endpoint="http://$host:$port"
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if ~/.local/bin/check_linn "$endpoint" --probe-ack; then
      exit 0
    fi
    sleep 1
  done
  exit 1
'; then
  echo 'Smoke check failed; restoring the previous deployment' >&2
  ssh "${ssh_options[@]}" "$pi" '
    set -eu
    if test -f ~/.local/bin/louie-server.previous; then
      mv ~/.local/bin/louie-server.previous ~/.local/bin/louie-server
    fi
    if test -f ~/.local/bin/check_linn.previous; then
      mv ~/.local/bin/check_linn.previous ~/.local/bin/check_linn
    fi
    if test -f ~/.config/systemd/user/louie.service.previous; then
      mv ~/.config/systemd/user/louie.service.previous ~/.config/systemd/user/louie.service
    fi
    systemctl --user daemon-reload
    systemctl --user restart louie.service
  '
  exit 1
fi

ssh "${ssh_options[@]}" "$pi" 'systemctl --user --no-pager status louie.service'
