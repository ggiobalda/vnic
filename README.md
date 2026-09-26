# vnic
vnic è un tool che emula una SmartNIC usando una VM QEMU posizionata tra due network namespace. Nella VM si può caricare un programma eBPF (oppure P4, che viene tradotto in eBPF) eseguito come XDP sull'interfaccia di ingresso. In questo modo è possibile scrivere e testare logiche di rete come filtri, drop o inoltro anche senza avere a disposizione una SmartNIC fisica.

Il progetto fa parte della mia tesi di laurea triennale in Ingegneria Informatica all'Università di Pisa (A.A. 2025/2026).

## Come funziona
Il comando `sudo scripts/vnic.sh up <nome_istanza>` crea l'infrastruttura di rete, visualizzabile tramite un grafico di flusso in [`docs/smartnic_packet_path.svg`](docs/smartnic_packet_path.svg), formata da:
- due **network namespace** (`ns0` e `ns1`), che simulano due host distinti. Il primo trasmette, il secondo riceve.
- due **veth pair**, ogni coppia fa da cavo ethernet virtuale fra un namespace e l'host.
- due **bridge** sull'host (`br0` e `br1`), collegano le veth ai TAP.
- due **TAP** (`tap0` e `tap1`), sono il punto di aggancio di QEMU per comunicare con la VM.
- due **interfacce di rete** nella VM (`ens3` ingresso, `ens4` uscita), unite dal bridge `brVM`.

Se è presente un programma eBPF, questo viene agganciato come XDP su `ens3`, quindi ogni pacchetto che va da `ns0` a `ns1` passa prima da lì.

La VM è una Debian 12 cloud che viene configurata al boot con cloud-init. Durante `up` lo script:
1. compila il codice in un file oggetto eBPF con `clang` (solo se è un `.c`). Se è un `.p4` prima lo traduce in C con `p4c-ebpf`, poi lo compila allo stesso modo
2. genera i file cloud-init (`meta-data`, `network-config`, `user-data`) e li mette in un `seed.iso` con `xorriso`. Il file oggetto viene inserito direttamente nello `user-data` in base64, insieme ai comandi per creare `brVM` e fare l'attach XDP
3. crea un overlay qcow2 dell'immagine base, così quella originale non viene mai modificata
4. avvia QEMU in background e legge il suo log finché cloud-init non ha finito, cioè finché la VM non è pronta

vnic si occupa solo dell'infrastruttura e del caricamento del programma, la generazione del traffico e la verifica del comportamento del filtro sono lasciate all'utente. Per questo motivo c'è uno script separato per il traffico (`scripts/traffic.sh`) e degli esempi con la relativa verifica (`examples/`).

## Struttura
- `scripts/vnic.sh`: il tool vero e proprio, crea e rimuove infrastruttura e VM e carica il filtro
- `scripts/traffic.sh`: genera traffico di prova da `ns0` verso `ns1` usando `nping`
- `scripts/p4c-runtime/`: header di p4c necessari per compilare il C generato da `p4c-ebpf` (il perché è spiegato nel README della cartella)
- `scripts/vm-test.sh`: prima automatizzazione del test manuale, da cui è nato `vnic.sh`
- `examples/`: filtri di prova, ognuno con il suo README e uno script `verify.sh`
- `docs/`: procedura manuale passo passo, schema e riferimenti
- `testbed/`: immagine base e file generati a runtime (non versionata)

## Requisiti
### Pacchetti
Servono i privilegi di root, dato che `up` e `down` vanno lanciati con `sudo`. I tool necessari sono `iproute2`, `qemu-system-x86_64`, `qemu-img`, `xorriso` e `wget`, più `clang` e `libbpf` per compilare filtri in C. Per `traffic.sh` serve `nping` (pacchetto `nmap`), mentre per gli esempi serve `tcpdump`.
```bash
sudo *** install qemu-x86 qemu-tools xorriso wget clang libbpf-devel nmap tcpdump
# *** = apt, zypper, dnf, ....
```
I nomi dei pacchetti cambiano a seconda della distribuzione, comunque `vnic.sh` controlla prima di partire che ci siano tutti i comandi necessari e dice quale manca.

### VM
Serve Linux con KVM abilitato e l'immagine `debian-12-generic-amd64.qcow2` (circa 400MB) deve trovarsi in `testbed/`. Se manca, al primo `up` lo script propone di scaricarla da cloud.debian.org (con `-y` non chiede conferma).

### P4
Per `--attach-p4` serve anche `p4c-ebpf`, il compilatore da P4 a eBPF, che va installato a parte perché non si trova nei repository della maggior parte delle distribuzioni. Chi usa solo programmi in eBPF non ne ha bisogno. Ci sono due modi per averlo:
+ su Ubuntu, il pacchetto `p4lang-p4c` dal repository OBS di p4lang ([istruzioni](https://github.com/p4lang/p4c#installing-packaged-versions-of-p4c))
+ su qualsiasi distribuzione, con `podman` (o `docker`) e l'immagine ufficiale `p4lang/p4c`, creando uno script `/usr/local/bin/p4c-ebpf` che lancia il compilatore dentro il container
```bash
sudo podman pull docker.io/p4lang/p4c:latest
sudo tee /usr/local/bin/p4c-ebpf <<'EOF'
#!/bin/sh
exec podman run --rm --security-opt label=disable \
    -v /home:/home -v /tmp:/tmp -w "$PWD" \
    docker.io/p4lang/p4c:latest p4c-ebpf "$@"
EOF
sudo chmod +x /usr/local/bin/p4c-ebpf
sudo p4c-ebpf --version
```
L'immagine va scaricata con `sudo` perché vnic gira come root, e podman tiene immagini separate per ogni utente. Le opzioni `-v` rendono visibili al container i file in `/home` e `/tmp`, se il progetto si trova altrove va aggiunta anche la sua cartella. Se `sudo p4c-ebpf --version` non trova il comando vuol dire che sudo non cerca in `/usr/local/bin`, e basta un link: `sudo ln -s /usr/local/bin/p4c-ebpf /usr/bin/p4c-ebpf`.

## Uso
```text
sudo scripts/vnic.sh up <nome> [--attach-ebpf <file.c|file.o> | --attach-p4 <file.p4>] [-y]
sudo scripts/vnic.sh down <nome>
sudo scripts/vnic.sh status
scripts/vnic.sh help
```
Opzioni di `up`:
+ `--attach-ebpf <file>`, carica un programma eBPF, sia sorgente `.c` (compilato da vnic) che oggetto `.o` già compilato
+ `--attach-p4 <file>`, carica un programma P4, tradotto in eBPF con `p4c-ebpf`
+ `-y`, `--yes`, non chiede conferma per il download dell'immagine base

`--attach-ebpf` e `--attach-p4` non possono essere usati insieme. Se non viene usato nessuno dei due la VM inoltra tutti i frame senza filtrarli, come se fosse un cavo.

Il programma eBPF deve avere la funzione nella sezione `SEC("xdp")`, perché l'attach nella VM viene fatto con `ip link set ens3 xdp obj ... sec xdp`. Per i programmi P4 non serve fare niente: `p4c-ebpf` mette il programma nella sezione `tc` anche quando genera codice XDP, e vnic in quel caso fa l'attach con `sec tc`. Il nome della sezione serve solo a trovare il programma nel file oggetto, il tipo (XDP) lo decide il comando `ip link`.

#### Esempio
```bash
# avvio con un filtro che scarta l'UDP
sudo scripts/vnic.sh up demo --attach-ebpf examples/drop-udp/drop_udp.c

# stato di VM, namespace e interfacce
sudo scripts/vnic.sh status

# il ping passa attraverso la VM
sudo ip netns exec ns0 ping -c 3 192.168.100.2

# in altri terminali si può vedere cosa entra ed esce dalla VM
sudo tcpdump -i tap0 -n
sudo tcpdump -i tap1 -n

# fermo la VM e rimuovo tutto
sudo scripts/vnic.sh down demo
```
Gli indirizzi sono `192.168.100.1` per `ns0` (`veth0`) e `192.168.100.2` per `ns1` (`veth1`).

Può essere attiva una sola istanza alla volta, quindi prima di un nuovo `up` bisogna fare `down`. Se il boot fallisce o va in timeout conviene guardare il log di QEMU (console seriale della VM) in `testbed/vnic-<nome>.log`. Per entrare nella VM l'utente è `debian` e la password `smartnic`.

## Generare traffico
`scripts/traffic.sh` invia pacchetti da `ns0` verso `ns1` usando `nping`, e permette di scegliere i campi principali degli header senza dover scrivere il comando a mano.
```text
sudo scripts/traffic.sh <icmp|udp|tcp|arp> [opzioni]
```
Opzioni:
+ `--src-ip`, `--src-mac`, `--dst-mac`, indirizzi nell'header del pacchetto
+ `--src-port`, `--dst-port`, porte (solo udp e tcp)
+ `--flags`, flag TCP separati da virgola, es. `syn,ack`
+ `--ttl`, TTL dell'header IP
+ `--payload`, contenuto del pacchetto
+ `--count`, numero di pacchetti (default 5)

```bash
sudo scripts/traffic.sh icmp
sudo scripts/traffic.sh udp --dst-port 9999 --payload "ciao"
sudo scripts/traffic.sh tcp --dst-port 8080 --flags syn --count 3
```
Attenzione che se `--dst-mac` è diverso dal MAC di `veth1` (o da broadcast) il pacchetto viene scartato da `ns1`.

Lo script non dà un verdetto: `nping` stampa i pacchetti inviati (SENT) e le risposte ricevute (RCVD), il risultato va interpretato in base al programma caricato, eventualmente usando anche `tcpdump` su `tap0` e `tap1`.

## Esempi
- [`drop-udp`](examples/drop-udp/): scarta tutti i pacchetti UDP su IPv4
- [`tcp-port-filter`](examples/tcp-port-filter/): scarta i pacchetti TCP diretti alla porta 8080

Ogni esempio contiene la stessa logica scritta sia in C che in P4, più uno script `verify.sh` che avvia vnic con il filtro, genera traffico, cattura su `tap0` (ingresso VM) e `tap1` (uscita VM) e confronta i pacchetti. Se un pacchetto viene scartato dal filtro compare su `tap0` ma non su `tap1`.
```bash
sudo examples/drop-udp/verify.sh          # versione eBPF (default)
sudo examples/drop-udp/verify.sh p4       # versione P4
```
L'esito è `PASS` o `FAIL`. Alla fine l'istanza viene fermata e le catture restano in `/tmp/vnic-verify-<esempio>/`. Per i dettagli vedi il README di ogni esempio.

## Documentazione
- [`docs/VM-test.md`](docs/VM-test.md): costruzione manuale, comando per comando, di infrastruttura, VM e filtro. È la procedura che `vnic.sh` automatizza, utile per capire cosa succede dietro ogni passaggio.
- [`docs/REFERENCES.md`](docs/REFERENCES.md): documentazione ufficiale dei tool usati (veth, TUN/TAP, cloud-init, QEMU, p4c, XDP).
