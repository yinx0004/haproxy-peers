FROM percona/percona-xtradb-cluster-operator:1.10.0-haproxy

COPY add_pxc_nodes.sh /usr/bin
COPY update_haproxy_peers.sh /usr/bin
