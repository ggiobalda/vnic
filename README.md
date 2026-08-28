# vnic

`vnic` is a deliberately small Rust utility that makes a virtual Ethernet
cable with a userspace forwarding point in the middle. It is the stripped-down
networking core of the parent `vnicpipe` project: no packet-programming
language, namespaces, configuration files, or HEX descriptors.

For a cable named `demo`, it creates this topology in the current network
namespace:

```text
demo0 -- demoi0 -- [ vnic forwarder ] -- demoi1 -- demo1
```

`demo0` and `demo1` are the usable endpoints. `demoi0` and `demoi1` are only
the forwarder's raw-packet attachment points. The forwarder copies each
Ethernet frame in both directions, so the outer interfaces behave like the
ends of a normal veth connection while leaving a simple place to add packet
handling later.

## Build

```bash
cd vnic
cargo build --release
```

The utility requires Linux, `ip` from iproute2, and root (or equivalent
`CAP_NET_ADMIN` and `CAP_NET_RAW` capabilities).

## Usage

Start a cable and its foreground forwarder:

```bash
sudo ./target/release/vnic up demo
```

For a realistic two-host demo, create the cable first, place its outer ends
in two namespaces, and then run the forwarder:

```bash
sudo vnic create demo
sudo ip netns add left
sudo ip netns add right
sudo ip link set demo0 netns left
sudo ip link set demo1 netns right
sudo ip -n left addr add 192.0.2.1/24 dev demo0
sudo ip -n right addr add 192.0.2.2/24 dev demo1
sudo ip -n left link set demo0 up
sudo ip -n right link set demo1 up
sudo vnic run demo
# in another terminal: sudo ip netns exec left ping 192.0.2.2
```

For independent lifecycle control:

```bash
sudo vnic create demo --mtu 1500
sudo vnic run demo                 # foreground; Ctrl-C stops only the forwarder
sudo vnic status demo
sudo vnic down demo                # stop forwarder and remove both veth pairs
```

The name must be 1–12 ASCII letters, digits, `_`, or `-`; this keeps all
generated interface names inside Linux's 15-character limit.

`up` leaves the topology in place when stopped, which makes inspection and
manual testing convenient. Use `down` (or `delete` when no forwarder is
running) to remove it.

## `rawnc`: a raw-socket netcat-like example

`rawnc.c` is a tiny C program for sending bytes directly as Ethernet payloads
over an interface. It uses a private EtherType (`0x88b5`) and broadcast frames
by default, so no MAC-address lookup is required. It is not TCP: frames are
not retried, ordered, or reassembled.

Build it with:

```bash
make rawnc
```

With the `left`/`right` namespace setup above and `vnic run demo` active:

```bash
# Terminal 1: print every received rawnc payload
sudo ip netns exec left /path/to/vnic/rawnc -l demo0

# Terminal 2: send stdin as Ethernet payload frames
printf 'hello over vnic\n' | sudo ip netns exec right /path/to/vnic/rawnc demo1
```

Use `-d aa:bb:cc:dd:ee:ff` instead of broadcast when you want a specific
destination MAC. Raw sockets require root or `CAP_NET_RAW` in each namespace.
