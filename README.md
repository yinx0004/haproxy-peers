# HAProxy-Peers

## Current HAProxy Problem
The current HAProxy configuration of backend servers on the main node is `*-pxc-0` and it's using `on-marked-up shutdown-backup-sessions` which means whenever HAProxy take the action of backend server failover, once the main node is recovered, it will take back the traffic, which means it will be two times of failover.

Further more, the 2nd failover is when the backup server is still running, haproxy will shutdown the sessions on the backup server, this could be troublesome, there might be onging transactions which can not be immediately interrupted.

For example
```
backend galera-nodes
  mode tcp
  option srvtcpka
  balance roundrobin
  option external-check
  external-check command /usr/local/bin/check_pxc.sh
  server test-pxc-db-pxc-0 test-pxc-db-pxc-0.test-pxc-db-pxc.pxc.svc.cluster.local:3306  check inter 10000 rise 1 fall 2 weight 1 on-marked-up shutdown-backup-sessions
  server test-pxc-db-pxc-2 test-pxc-db-pxc-2.test-pxc-db-pxc.pxc.svc.cluster.local:3306  check inter 10000 rise 1 fall 2 weight 1 backup
  server test-pxc-db-pxc-1 test-pxc-db-pxc-1.test-pxc-db-pxc.pxc.svc.cluster.local:3306  check inter 10000 rise 1 fall 2 weight 1 backup
```

## Improvement on the HAProxy Configuration
The main idea is let HAProxy stick on the new backend server once failover.

We can abandon `on-marked-up shutdown-backup-sessions`, use `on-marked-down shutdown-sessions` only on all backend servers, this allow HAproxy to close all existing connections to a backend when it goes down. Normally HAProxy allows existing connections to finish.

For example
```
backend galera-nodes
  mode tcp
  option srvtcpka
  balance roundrobin
  option external-check
  external-check command /usr/local/bin/check_pxc.sh
  server test-pxc-db-pxc-0 test-pxc-db-pxc-0.test-pxc-db-pxc.pxc.svc.cluster.local:3306  check inter 10000 rise 1 fall 2 weight 1 on-marked-down shutdown-sessions
  server test-pxc-db-pxc-2 test-pxc-db-pxc-2.test-pxc-db-pxc.pxc.svc.cluster.local:3306  check inter 10000 rise 1 fall 2 weight 1 backup on-marked-down shutdown-sessions
  server test-pxc-db-pxc-1 test-pxc-db-pxc-1.test-pxc-db-pxc.pxc.svc.cluster.local:3306  check inter 10000 rise 1 fall 2 weight 1 backup on-marked-down shutdown-sessions
```

**This require we make sure the active backend are the same among all HAProxy, because if one of HAProxy restarted, the active backend will always be the main node pxc-0, it might be different with other HAProxy if failover already happened earlier on.**

## Introducion of HAProxy Peers

### Peers
The peers section enables
1. Local peer will persist stick table data after a haproxy soft restart(eg: reload).
2. The replication of stick table data between two or more HAProxy instances.

### Stick Tables
Stick tables are storage spaces that run in memory inside the HAProxy process. They store data about traffic as it passes through. We can use it to persist a client to a particular server.

**Peers and stick tables can help us make sure all HAProxy always have the same active backend server**

For example
```
peers mypeers
  peer test-pxc-db-haproxy-0 test-pxc-db-haproxy-0.test-pxc-db-haproxy.pxc.svc.cluster.local:10000
  peer test-pxc-db-haproxy-1 test-pxc-db-haproxy-1.test-pxc-db-haproxy.pxc.svc.cluster.local:10000
  peer test-pxc-db-haproxy-2 test-pxc-db-haproxy-2.test-pxc-db-haproxy.pxc.svc.cluster.local:10000

backend galera-nodes
  mode tcp
  option srvtcpka
  balance roundrobin
  stick-table type integer size 1 peers mypeers # new added
  stick on int(1)  # new added
  option external-check
  external-check command /usr/local/bin/check_pxc.sh
  server test-pxc-db-pxc-0 test-pxc-db-pxc-0.test-pxc-db-pxc.pxc.svc.cluster.local:3306  check inter 10000 rise 1 fall 2 weight 1 on-marked-down shutdown-sessions
  server test-pxc-db-pxc-2 test-pxc-db-pxc-2.test-pxc-db-pxc.pxc.svc.cluster.local:3306  check inter 10000 rise 1 fall 2 weight 1 backup on-marked-down shutdown-sessions
  server test-pxc-db-pxc-1 test-pxc-db-pxc-1.test-pxc-db-pxc.pxc.svc.cluster.local:3306  check inter 10000 rise 1 fall 2 weight 1 backup on-marked-down shutdown-sessions
```

### Important notes
**We should alway keep the local peer in the HAProxy configuration file, or the local stick table record will be lost**

## Usage

### Build Image
```
docker build -t myhaproxy:1.10.0 .
```

or just pull the image from sealcloud CIR
```
docker pull yinx-test-1.instance.cir.sg-sin.sealcloud.com/pxc/myhaproxy:1.10.0
```

### Create HAProxy ENV Secret
This to store the number of haproxy instances
```
kubectl create -f haproxy-env-secret.yaml -n cloudsql
```

### Create PXC cluster
```
helm install test-pxc-db percona/pxc-db -f values.yaml -n cloudsql
```

## Verify the sticky-table
```
kubectl exec -it test-pxc-db-haproxy-0 -c haproxy -- bash

bash-4.4$ echo "show table galera-nodes" |socat stdio /etc/haproxy/pxc/haproxy.sock
# table: galera-nodes, type: integer, size:1, used:1
0x557cdf0d40b0: key=1 use=0 exp=0 server_id=1 server_name=test-pxc-db-pxc-0
```
