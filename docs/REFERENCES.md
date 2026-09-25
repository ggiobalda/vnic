## Riferimenti e Documentazione

Durante lo sviluppo sono state consultate le seguenti fonti ufficiali:

+ **[Virtual Ethernet Interfaces (veth)](https://man7.org/linux/man-pages/man4/veth.4.html)**: Pagina del manuale del kernel relativa alle interfacce veth.
+ **[TUN/TAP Device Driver (ip-tuntap)](https://www.kernel.org/doc/html/latest/networking/tuntap.html)**: Documentazione del kernel per le interfacce virtuali di tunnelling.
+ **[Debian Cloud Images](https://cloud.debian.org/images/cloud/)**: Repository Debian da cui è stata presa l'immagine di base.
+ **[libguestfs / virt-customize](https://libguestfs.org/virt-customize.1.html)**: Tool utilizzato per l'ispezione e la modifica offline dell'immagine guest.
+ **[GNU xorriso](https://www.gnu.org/software/xorriso/)**: Tool impiegato per la creazione del disco seed.iso.
+ **[QEMU Virtio Networking](https://wiki.qemu.org/Documentation/Networking)**: Wiki di QEMU per la sintassi del backend di rete.
+ **[Linux Network Namespaces (ip-netns)](https://man7.org/linux/man-pages/man8/ip-netns.8.html)**: Pagina del manuale relativa alle funzionalità del kernel per creare le copie isolate dello stack di rete.
+ **[Cloud-init per QEMU](https://docs.cloud-init.io/en/latest/tutorial/qemu.html)**: Meccanismo utilizzato per configurare il boot della VM, preinstallato nell'immagine base.
+ **[P4 Compiler (p4c)](https://p4lang.github.io/p4c/ebpf_backend.html)**: Compiler utilizzato per tradurre i programmi scritti in P4 in bytecode equivalente eBPF.
+ **[Runtime eBPF di p4c](https://github.com/p4lang/p4c/tree/main/backends/ebpf/runtime)**: Sorgente degli header `ebpf_kernel.h` ed `ebpf_common.h` copiati in `scripts/p4c-runtime/`, necessari per compilare il C generato da `p4c-ebpf`.
+ **[Immagine Docker p4lang/p4c](https://hub.docker.com/r/p4lang/p4c)**: Immagine ufficiale del compilatore, usata con podman per avere `p4c-ebpf` su distribuzioni senza pacchetto.
+ **[Cilium BPF e XDP Reference Guide](https://docs.cilium.io/en/stable/reference-guides/bpf/toolchain/#iproute2)**: Risorsa utilizzata per comprendere le corrette opzioni del comando `iproute2` per caricare i programmi eBPF sulle interfacce di rete.
