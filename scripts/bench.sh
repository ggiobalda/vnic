#!/usr/bin/env bash
# bench.sh - misura latenza e throughput da ns0 a ns1 con una veth pair diretta e con vnic
# (senza programma, con il filtro drop-udp in eBPF e in P4). Ogni configurazione viene misurata 3 volte.
#
# Uso: sudo scripts/bench.sh

set -euo pipefail

VNIC="$(dirname "$0")/vnic.sh"
EXAMPLE="$(dirname "$0")/../examples/drop-udp"
DST=192.168.100.2
# file inviato per il throughput creato in RAM così la velocità del disco non influisce sulla misura
FILE=/dev/shm/vnic-bench

up() {
    case "$1" in
        veth)
            # stessi namespace e indirizzi di vnic, ma collegati direttamente
            ip netns add ns0
            ip netns add ns1
            ip link add veth0 netns ns0 type veth peer name veth1 netns ns1
            ip -n ns0 addr add 192.168.100.1/24 dev veth0
            ip -n ns1 addr add $DST/24 dev veth1
            ip -n ns0 link set veth0 up
            ip -n ns1 link set veth1 up
            ;;
        noprog) "$VNIC" up bench ;;
        ebpf)   "$VNIC" up bench --attach-ebpf "$EXAMPLE/drop_udp.c" ;;
        p4)     "$VNIC" up bench --attach-p4 "$EXAMPLE/drop_udp.p4" ;;
    esac
}

down() {
    if [[ "$1" == veth ]]; then
        ip netns del ns0
        ip netns del ns1
    else
        "$VNIC" down bench
    fi
}

# rimuove il file alla fine, anche se lo script si interrompe per un errore
trap 'rm -f "$FILE"' EXIT
# legge 1GiB di dati da /dev/urandom (randomici) e mette in FILE
head -c 1G /dev/urandom > "$FILE"

for round in 1 2 3; do
    for config in veth noprog ebpf p4; do
        echo "== round $round: $config"
        up "$config" > /dev/null

        # test latenza: 20 ping di riscaldamento, poi 1000 ping ogni 5 ms
        ip netns exec ns0 ping -c 20 -i 0.05 -q $DST > /dev/null
        ip netns exec ns0 ping -c 1000 -i 0.005 -q $DST | tail -1

        # test throughput: 5 invii del file da ns0 a ns1
        for i in {1..5}; do
            ip netns exec ns1 socat -u TCP-LISTEN:5001,reuseaddr /dev/null &
            sleep 0.5   # attende che socat sia in ascolto
            start=$(date +%s.%N)
            ip netns exec ns0 socat -u "$FILE" TCP:$DST:5001
            wait
            end=$(date +%s.%N)
            # 1 GiB = 8.59 Gbit
            awk -v s="$start" -v e="$end" 'BEGIN { printf "throughput %.2f Gbit/s\n", 8.59 / (e - s) }'
        done

        down "$config" > /dev/null
    done
done

rm -f "$FILE"
