#!/bin/bash

set -o errexit
set -o xtrace

## find haproxy peers for syncing stick table cluster wide ##

function main() {
    while true
    do

        LOCK_FILE="/etc/haproxy/pxc/haproxy.lock"
        trap "ls $LOCK_FILE |xargs rm" EXIT

        while [ -e $LOCK_FILE ]
        do
            echo "haproxy config file is locked! slepp 1..."
            sleep 1
        done
        touch $LOCK_FILE

        HAPROXY_NUM_ENV="/etc/mysql/haproxy-env-secret/HAPROXY_NUM"
        if [[ -e "$HAPROXY_NUM_ENV" ]]; then
            HAPROXY_NUM=$(/bin/cat /etc/mysql/haproxy-env-secret/HAPROXY_NUM)
        fi
        HAPROXY_NUM=${HAPROXY_NUM:-3}
        path_to_haproxy_cfg='/etc/haproxy/pxc'
        PEER_CONF='haproxy.cfg'
        HAPROXY_ENTRIES=$(grep -w peer $path_to_haproxy_cfg/$PEER_CONF |wc -l)
        if [[ "$HAPROXY_ENTRIES" -gt "$HAPROXY_NUM" ]]; then
            echo "More entries than expected!"
            exit 1
        fi
        if [[ "$HAPROXY_ENTRIES" -eq "$HAPROXY_NUM" ]]; then
            echo "All haproxy peers found, OK"
        else
            update_haproxy_peers
        fi
        ls $LOCK_FILE |xargs rm
        sleep 10
    done
}

function update_haproxy_peers() {
    TIMEOUT=${LIVENESS_CHECK_TIMEOUT:-10}

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
      #if [[ $n -eq $HAPROXY_ID ]]; then
      #    NODE_LIST_HAPROXY_PEER+=( "peer $HAPROXY_PEER_HOSTNAME $HAPROXY_PEER_DOMAIN:$PEER_PORT##added by sidecar")
      #else
          if [[ -n $(echo 'show info' |socat stdio TCP4:$HAPROXY_PEER_DOMAIN:$PEER_PORT,connect-timeout=$TIMEOUT) ]]; then
                  NODE_LIST_HAPROXY_PEER+=( "peer $HAPROXY_PEER_HOSTNAME $HAPROXY_PEER_DOMAIN:$PEER_PORT")
          fi
      #fi
    done

    if [[ "${#NODE_LIST_HAPROXY_PEER[@]}" -eq 0 || ! "${NODE_LIST_HAPROXY_PEER[*]}" =~ "$HOST" ]]; then
        echo "haproxy not ready, try later"
        return 0 
    fi

    # delete and insert peers
    INSERT_AT=$(awk '/^\s*peers mypeers/{print NR}' $path_to_haproxy_cfg/$PEER_CONF)
    if [[ -n "$INSERT_AT" ]]; then
        let INSERT_AT=INSERT_AT+1
    else
        echo "No peers section found! Try later..."
        return 0 
    fi

    # delete peers
    LINES=($(awk '/^peer /{print NR}' $path_to_haproxy_cfg/$PEER_CONF))
    if [[ "${#LINES[@]}" -ne 0 ]]; then
        RANGE="${LINES[0]},${LINES[${#LINES[@]} - 1]}"
        sed -i -e "${RANGE}d" $path_to_haproxy_cfg/$PEER_CONF
    fi
    # insert peers
    PEERS=$(printf '%s\\n' "${NODE_LIST_HAPROXY_PEER[@]}" | sed -z '$ s/\\n$//')
    sed -i -e "${INSERT_AT}i$PEERS" $path_to_haproxy_cfg/$PEER_CONF

    # reload haproxy
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

    if [ -S "$path_to_haproxy_cfg/haproxy-main.sock" ]; then
        echo 'reload' | socat stdio "$path_to_haproxy_cfg/haproxy-main.sock"
    fi
}

main
