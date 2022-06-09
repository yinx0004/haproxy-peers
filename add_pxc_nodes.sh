#!/bin/bash

set -o errexit
set -o xtrace

function main() {
    echo "Running $0"

    ## added for haproxy peer ##

    LOCK_FILE="/etc/haproxy/pxc/haproxy.lock"
    trap "ls $LOCK_FILE |xargs rm" EXIT

    while [ -e $LOCK_FILE ]
    do
        echo "haproxy config file is locked! slepp 1..."
        sleep 1
    done
    touch $LOCK_FILE

    HAPROXY_NUM=${HAPROXY_NUM:-3}
    TIMEOUT=${LIVENESS_CHECK_TIMEOUT:-10}
    PEER_CONF="/etc/haproxy/pxc/haproxy.cfg"
    HOSTS_FILE="/etc/hosts"
    LINE=$(grep haproxy $HOSTS_FILE)
    HOST=$(echo $LINE |cut -d ' ' -f 2)
    DOMAIN=${HOST#*.}
    HAPROXY_NAME=${HOSTNAME%-*}
    HAPROXY_ID=${HOSTNAME##*-}
    PEER_PORT=10000

    NODE_LIST_HAPROXY_PEER=()
    for ((n=0;n<$HAPROXY_NUM;n++))
    do
      HAPROXY_PEER_HOSTNAME="$HAPROXY_NAME-$n"
      HAPROXY_PEER_DOMAIN="$HAPROXY_NAME-$n.$DOMAIN"
      if [[ $n -eq $HAPROXY_ID ]]; then
          NODE_LIST_HAPROXY_PEER+=( "peer $HAPROXY_PEER_HOSTNAME $HAPROXY_PEER_DOMAIN:$PEER_PORT")
      else
          if [[ -n $(echo 'show info' |socat stdio TCP4:$HAPROXY_PEER_DOMAIN:$PEER_PORT,connect-timeout=$TIMEOUT) ]]; then
                  NODE_LIST_HAPROXY_PEER+=( "peer $HAPROXY_PEER_HOSTNAME $HAPROXY_PEER_DOMAIN:$PEER_PORT")
          fi
      fi
    done

    if [[ "${#NODE_LIST_HAPROXY_PEER[@]}" -ne 0 ]]; then
        echo "    peers mypeers" > $PEER_CONF
        ( IFS=$'\n'; echo "${NODE_LIST_HAPROXY_PEER[*]}" ) >> $PEER_CONF
    fi

    ## added for haproxy peer ##

    NODE_LIST=()
    NODE_LIST_REPL=()
    NODE_LIST_MYSQLX=()
    NODE_LIST_ADMIN=()
    NODE_LIST_BACKUP=()
    firs_node=''
    firs_node_admin=''
    #main_node='' ## no more main node

    SERVER_OPTIONS=${HA_SERVER_OPTIONS:-'check inter 10000 rise 1 fall 2 weight 1'}
    send_proxy=''
    path_to_haproxy_cfg='/etc/haproxy/pxc'
    if [[ "${IS_PROXY_PROTOCOL}" = "yes" ]]; then
        send_proxy='send-proxy-v2'
        touch $path_to_haproxy_cfg/PROXY_PROTOCOL_ENABLED
    else
        rm -f $path_to_haproxy_cfg/PROXY_PROTOCOL_ENABLED
    fi

    while read pxc_host; do
        if [ -z "$pxc_host" ]; then
            echo "Could not find PEERS ..."
            exit 0
        fi

        node_name=$(echo "$pxc_host" | cut -d . -f -1)
        node_id=$(echo $node_name |  awk -F'-' '{print $NF}')
        NODE_LIST_REPL+=( "server $node_name $pxc_host:3306 $send_proxy $SERVER_OPTIONS" )
        if [ "x$node_id" == 'x0' ]; then
            #main_node="$pxc_host"
            firs_node="server $node_name $pxc_host:3306 $send_proxy $SERVER_OPTIONS on-marked-down shutdown-sessions"
            firs_node_admin="server $node_name $pxc_host:33062 $SERVER_OPTIONS on-marked-down shutdown-sessions"
            firs_node_mysqlx="server $node_name $pxc_host:33060 $SERVER_OPTIONS on-marked-down shutdown-sessions"
            continue
        fi
        NODE_LIST_BACKUP+=("galera-nodes/$node_name" "galera-admin-nodes/$node_name")
        NODE_LIST+=( "server $node_name $pxc_host:3306 $send_proxy $SERVER_OPTIONS backup on-marked-down shutdown-sessions" )
        NODE_LIST_ADMIN+=( "server $node_name $pxc_host:33062 $SERVER_OPTIONS backup on-marked-down shutdown-sessions" )
        NODE_LIST_MYSQLX+=( "server $node_name $pxc_host:33060 $send_proxy $SERVER_OPTIONS backup on-marked-down shutdown-sessions" )
    done

    if [ -n "$firs_node" ]; then
        if [[ "${#NODE_LIST[@]}" -ne 0 ]]; then
            NODE_LIST=( "$firs_node" "$(printf '%s\n' "${NODE_LIST[@]}" | sort --version-sort -r | uniq)" )
            NODE_LIST_ADMIN=( "$firs_node_admin" "$(printf '%s\n' "${NODE_LIST_ADMIN[@]}" | sort --version-sort -r | uniq)" )
            NODE_LIST_MYSQLX=( "$firs_node_mysqlx" "$(printf '%s\n' "${NODE_LIST_MYSQLX[@]}" | sort --version-sort -r | uniq)" )
        else
            NODE_LIST=( "$firs_node" )
            NODE_LIST_ADMIN=( "$firs_node_admin" )
            NODE_LIST_MYSQLX=( "$firs_node_mysqlx" )
        fi
    else
        if [[ "${#NODE_LIST[@]}" -ne 0 ]]; then
            NODE_LIST=( "$(printf '%s\n' "${NODE_LIST[@]}" | sort --version-sort -r | uniq)" )
            NODE_LIST_ADMIN=( "$(printf '%s\n' "${NODE_LIST_ADMIN[@]}" | sort --version-sort -r | uniq)" )
            NODE_LIST_MYSQLX=( "$(printf '%s\n' "${NODE_LIST_MYSQLX[@]}" | sort --version-sort -r | uniq)" )
        fi
    fi

cat <<-EOF >> "$path_to_haproxy_cfg/haproxy.cfg"
    backend galera-nodes
      mode tcp
      option srvtcpka
      balance roundrobin
      stick-table type string len 40 size 20000 peers mypeers
      stick on fe_name
      option external-check
      external-check command /usr/local/bin/check_pxc.sh
EOF

    echo "${#NODE_LIST_REPL[@]}" > $path_to_haproxy_cfg/AVAILABLE_NODES
    ( IFS=$'\n'; echo "${NODE_LIST[*]}" ) >> "$path_to_haproxy_cfg/haproxy.cfg"

cat <<-EOF >> "$path_to_haproxy_cfg/haproxy.cfg"
    backend galera-admin-nodes
      mode tcp
      option srvtcpka
      balance roundrobin
      stick-table type string len 40 size 20000 peers mypeers
      stick on fe_name
      option external-check
      external-check command /usr/local/bin/check_pxc.sh
EOF

    ( IFS=$'\n'; echo "${NODE_LIST_ADMIN[*]}" ) >> "$path_to_haproxy_cfg/haproxy.cfg"

cat <<-EOF >> "$path_to_haproxy_cfg/haproxy.cfg"
    backend galera-replica-nodes
      mode tcp
      option srvtcpka
      balance roundrobin
      option external-check
      external-check command /usr/local/bin/check_pxc.sh
EOF
    ( IFS=$'\n'; echo "${NODE_LIST_REPL[*]}" ) >> "$path_to_haproxy_cfg/haproxy.cfg"

cat <<-EOF >> "$path_to_haproxy_cfg/haproxy.cfg"
    backend galera-mysqlx-nodes
      mode tcp
      option srvtcpka
      balance roundrobin
      stick-table type string len 40 size 20000 peers mypeers
      stick on fe_name
      option external-check
      external-check command /usr/local/bin/check_pxc.sh
EOF
    ( IFS=$'\n'; echo "${NODE_LIST_MYSQLX[*]}" ) >> "$path_to_haproxy_cfg/haproxy.cfg"

    SOCKET='/etc/haproxy/pxc/haproxy.sock'
    path_to_custom_global_cnf='/etc/haproxy-custom'
    if [ -f "$path_to_custom_global_cnf/haproxy-global.cfg" ]; then
        haproxy -c -f "$path_to_custom_global_cnf/haproxy-global.cfg" -f $path_to_haproxy_cfg/haproxy.cfg || EC=$?
    fi

    if [ -f "$path_to_custom_global_cnf/haproxy-global.cfg" -a -z "$EC" ]; then
        SOCKET_CUSTOM=$(grep 'stats socket' "$path_to_custom_global_cnf/haproxy-global.cfg" | awk '{print $3}')
        if [ -S "$SOCKET_CUSTOM" ]; then
            SOCKET="$SOCKET_CUSTOM"
        fi
    else
        haproxy -c -f /etc/haproxy/haproxy-global.cfg -f $path_to_haproxy_cfg/haproxy.cfg
    fi

    ####comment because no more main node
    #if [ -n "$main_node" ]; then
    #     if /usr/local/bin/check_pxc.sh '' '' "$main_node"; then
    #         for backup_server in ${NODE_LIST_BACKUP[@]}; do
    #             echo "shutdown sessions server $backup_server" | socat stdio "${SOCKET}"
    #         done
    #     fi
    #fi
    ####comment because no more main node

    if [ -S "$path_to_haproxy_cfg/haproxy-main.sock" ]; then
        echo 'reload' | socat stdio "$path_to_haproxy_cfg/haproxy-main.sock"
    fi

}

main
exit 0
