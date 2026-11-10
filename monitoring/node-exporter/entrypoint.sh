#!/bin/sh
# Keep the exporter on the private bridge; read host network counters through PID 1.
# /proc/net would otherwise describe this container's network namespace.
set -eu
mkdir -p /textfile
collect_network() {
  awk 'BEGIN {
    print "# HELP node_host_network_receive_bytes_total Host network receive bytes via /proc/1/net/dev."
    print "# TYPE node_host_network_receive_bytes_total counter"
    print "# HELP node_host_network_transmit_bytes_total Host network transmit bytes via /proc/1/net/dev."
    print "# TYPE node_host_network_transmit_bytes_total counter"
  }
  NR > 2 {
    device=$1
    sub(/:$/, "", device)
    gsub(/\\/, "\\\\", device)
    gsub(/"/, "\\\"", device)
    printf "node_host_network_receive_bytes_total{device=\"%s\"} %s\n", device, $2
    printf "node_host_network_transmit_bytes_total{device=\"%s\"} %s\n", device, $10
  }' /host/proc/1/net/dev > /textfile/host_network.prom.tmp
  mv /textfile/host_network.prom.tmp /textfile/host_network.prom
}
collect_network
(
  while sleep 5; do
    collect_network
  done
) &
exec /bin/node_exporter "$@"
