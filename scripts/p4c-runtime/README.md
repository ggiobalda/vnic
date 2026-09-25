# p4c-runtime
Header necessari per compilare il codice C generato da `p4c-ebpf`, usati da `vnic.sh` quando si carica un programma con `--attach-p4`.

## Perché servono
`p4c-ebpf` non produce direttamente un file oggetto eBPF, ma traduce il programma P4 in un file C che poi va compilato con `clang`, come per i filtri scritti a mano. Questo C però non è completo: usa delle macro (lettura di campi dal pacchetto, conversione dell'ordine dei byte, definizione delle tabelle) che non sono scritte nel file generato, ma in `ebpf_kernel.h` ed `ebpf_common.h`, inclusi all'inizio.

I due header fanno parte dei sorgenti di p4c (cartella `backends/ebpf/runtime/`), però non vengono installati insieme al compilatore, né col pacchetto né nell'immagine `p4lang/p4c`. Senza di loro `clang` si ferma subito perché non trova `ebpf_kernel.h`, per questo ne tengo una copia qui e `vnic.sh` la passa a `clang` con `-I`.

## Modifiche rispetto all'originale
`ebpf_kernel.h` a sua volta include gli header di libbpf e del kernel (`bpf_helpers.h`, `bpf_endian.h`, `linux/bpf.h`, ...) con percorsi che esistono solo dentro il repository di p4c, come `install/libbpf/include/bpf/...`. Nella copia questi include sono stati sostituiti con quelli di sistema (`<bpf/...>` e `<linux/...>`), che sono già presenti se è installato `libbpf`. È stato anche rimosso `<sys/types.h>`, che non viene usato e con `clang -target bpf` dà errore su alcune distribuzioni.

`ebpf_common.h` è invariato. Entrambi i file mantengono la licenza originale (Apache 2.0).

Sorgente: https://github.com/p4lang/p4c/tree/main/backends/ebpf/runtime
