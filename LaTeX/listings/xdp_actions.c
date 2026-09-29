// xdp_actions.c - programma di prova: sceglie l'azione XDP in base alla porta UDP
// di destinazione, per osservare cosa fa la VM con ciascuna.
//   9000 -> XDP_ABORTED      9001 -> XDP_DROP     9002 -> XDP_PASS
//   9003 -> XDP_TX (MAC scambiati, torna verso ns0)
//   9004 -> XDP_REDIRECT verso ens4 (ifindex 3 nella VM)
// tutto il resto -> XDP_PASS
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/udp.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#define ENS4_IFINDEX 3

SEC("xdp")
int xdp_actions(struct xdp_md *ctx)
{
    void *data     = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;
    struct ethhdr *eth = data;
    struct iphdr *ip = (void *)(eth + 1);
    struct udphdr *udp = (void *)(ip + 1);   // assume IHL = 5 (niente opzioni IP)

    if ((void *)(udp + 1) > data_end)
        return XDP_PASS;
    if (eth->h_proto != bpf_htons(ETH_P_IP) || ip->protocol != IPPROTO_UDP)
        return XDP_PASS;

    switch (bpf_ntohs(udp->dest)) {
    case 9000: return XDP_ABORTED;
    case 9001: return XDP_DROP;
    case 9002: return XDP_PASS;
    case 9003: {
        unsigned char tmp[ETH_ALEN];
        __builtin_memcpy(tmp, eth->h_dest, ETH_ALEN);
        __builtin_memcpy(eth->h_dest, eth->h_source, ETH_ALEN);
        __builtin_memcpy(eth->h_source, tmp, ETH_ALEN);
        return XDP_TX;
    }
    case 9004: return bpf_redirect(ENS4_IFINDEX, 0);
    }
    return XDP_PASS;
}

char LICENSE[] SEC("license") = "GPL";
