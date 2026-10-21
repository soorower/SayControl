#!/bin/bash
# Laptop side: forwards ws://127.0.0.1:8765 to the gateway on the RunPod pod,
# and reconnects if the link drops. Run in a terminal, or detached:
#   nohup gpu-server/tunnel.sh > /tmp/sayctrl-gpu-tunnel.log 2>&1 &
# Stop:  pkill -f tunnel.sh; pkill -f "8765:127.0.0.1:8765"   (the loop first, or it reconnects)
# The pod's public IP/port change if it is re-created: RunPod → Pods → Connect →
# "SSH over exposed TCP". Set POD_HOST / POD_PORT to what it shows.
POD_HOST=${POD_HOST:?set POD_HOST to the pod's SSH address}
POD_PORT=${POD_PORT:?set POD_PORT to the pod's SSH port}
while true; do
  ssh -N -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes \
    -o BatchMode=yes -i ~/.ssh/id_ed25519 -p "$POD_PORT" -L 8765:127.0.0.1:8765 root@"$POD_HOST"
  echo "$(date '+%H:%M:%S') tunnel dropped (exit $?); reconnecting in 3 s"
  sleep 3
done
