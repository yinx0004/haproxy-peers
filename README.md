# HAProxy-Peers



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
