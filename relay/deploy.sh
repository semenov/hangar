#!/bin/sh
# Builds the relay for Linux and installs it on its droplet (systemd unit hangar-relay, which
# terminates TLS itself with Let's Encrypt). Usage: ./deploy.sh [root@host]
set -eu
HOST=${1:-root@159.223.233.26}
cd "$(dirname "$0")"
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -ldflags "-s -w" -o /tmp/hangar-relay-linux .
scp -q /tmp/hangar-relay-linux "$HOST":/usr/local/bin/hangar-relay.new
ssh "$HOST" 'mv /usr/local/bin/hangar-relay.new /usr/local/bin/hangar-relay && systemctl restart hangar-relay && sleep 1 && systemctl is-active hangar-relay'
rm -f /tmp/hangar-relay-linux
