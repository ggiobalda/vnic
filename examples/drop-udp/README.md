# drop-udp

Filtro che scarta tutti i pacchetti **UDP su IPv4**.

## File

| File | Contenuto |
|---|---|
| `drop_udp.c` | filtro in C, compilato in eBPF e caricato come programma XDP |
| `drop_udp.p4` | stessa logica in P4 |
| `verify.sh` | avvia vnic con il filtro, genera traffico e verifica il risultato |

## Verifica automatica

```bash
sudo examples/drop-udp/verify.sh        # versione eBPF (default)
sudo examples/drop-udp/verify.sh p4     # versione P4
```

Lo script avvia vnic, cattura il traffico su `tap0` (ingresso VM) e `tap1` (uscita VM), invia 5 ping e un pacchetto UDP, poi controlla che:

- ICMP compaia su entrambe le tap (10 pacchetti: 5 richieste + 5 risposte);
- UDP compaia su `tap0` ma non su `tap1`, cioè sia stato scartato dentro la VM.

Esito atteso:

```
[verify] ICMP: tap0=10 tap1=10 | UDP: tap0=1 tap1=0
[verify] PASS: ICMP attraversa la VM, UDP viene scartato
```

Al termine l'istanza viene fermata; le catture restano in `/tmp/vnic-verify-drop-udp/` e possono essere lette col comando `tcpdump -r <file .pcap>`.