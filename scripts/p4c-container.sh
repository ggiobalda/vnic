#!/usr/bin/env bash
# p4c-container.sh - esegue p4c-ebpf dentro un container (podman o docker)
#
# Sostituto di p4c-ebpf per chi non ha il compilatore installato: accetta gli
# stessi argomenti e li passa a p4c-ebpf nell'immagine ufficiale p4lang/p4c.
# vnic.sh lo usa in automatico se p4c-ebpf non è installato.

# stop su errori (-e), variabili non definite (-u) o errori nelle pipe (-o pipefail)
set -euo pipefail

# immagine del compilatore
IMAGE="${P4C_IMAGE:-docker.io/p4lang/p4c:latest}"

# motore dei container: podman se c'è, altrimenti docker
if command -v podman &>/dev/null; then
    ENGINE=podman
elif command -v docker &>/dev/null; then
    ENGINE=docker
    # a differenza di podman, docker funziona solo se il demone dockerd è attivo
    if ! docker info &>/dev/null; then
        echo "[p4c-container] errore: demone docker non raggiungibile, avvialo con 'sudo systemctl start docker' (oppure installa podman)" >&2
        exit 1
    fi
else
    echo "[p4c-container] errore: serve podman o docker" >&2
    exit 1
fi

# cartella corrente e quella  di ogni argomento che è un file passate al containe,
# allo stesso percorso, così i path passati a p4c-ebpf restano validi anche dentro il container
MOUNTS=(-v "$PWD:$PWD")
declare -A seen=(["$PWD"]=1)
for arg in "$@"; do
    [[ "$arg" == -* ]] && continue
    dir="$(dirname "$arg")"
    [[ -d "$dir" ]] || continue
    dir="$(realpath "$dir")"
    # salto / e le cartelle già montate (podman non accetta mount duplicati)
    [[ "$dir" == / || -n "${seen[$dir]:-}" ]] && continue
    seen[$dir]=1
    MOUNTS+=(-v "$dir:$dir")
done

# --rm: il container viene rimosso alla fine
# label=disable: senza, SELinux impedisce al container di leggere le cartelle montate
# se l'immagine non c'è, viene scaricata automaticamente al primo avvio
exec "$ENGINE" run --rm --security-opt label=disable \
    "${MOUNTS[@]}" -w "$PWD" \
    "$IMAGE" p4c-ebpf "$@"
