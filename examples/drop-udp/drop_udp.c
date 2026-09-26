#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>

SEC("xdp")
int drop_udp(struct xdp_md *ctx)
{
    void *data     = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    struct ethhdr *eth = data;
    struct iphdr *ip = data + sizeof(*eth);

    if ((void *)(eth + 1) > data_end ||
        (void *)(ip + 1) > data_end)
        return XDP_PASS;

    return eth->h_proto == __constant_htons(ETH_P_IP) &&
           ip->protocol == IPPROTO_UDP
           ? XDP_DROP
           : XDP_PASS;
}

char LICENSE[] SEC("license") = "GPL";