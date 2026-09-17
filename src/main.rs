//! `vnic` deliberately has a small surface area: it makes two veth pairs
//! and forwards Ethernet frames between their inner ends in userspace.

use anyhow::{Context, Result, bail};
use clap::{Args, Parser, Subcommand};
use pnet_datalink::{Channel, Config, DataLinkReceiver, DataLinkSender};
use signal_hook::consts::{SIGINT, SIGTERM};
use std::fs;
use std::path::PathBuf;
use std::process::Command as ProcessCommand;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use std::thread;
use std::time::Duration;

const RECEIVE_TIMEOUT: Duration = Duration::from_millis(100);

#[derive(Parser, Debug)]
#[command(
    name = "vnic",
    about = "Create a virtual Ethernet cable with a userspace forwarder",
    after_help = "Examples:\n  sudo vnic up demo\n  ip link show demo0\n  sudo vnic down demo\n\n\
Topology for `vnic up demo`:\n  demo0 -- demoi0 -- [forwarder] -- demoi1 -- demo1\n\n\
The outer interfaces (demo0 and demo1) are the two usable cable ends.\n\
Give them addresses yourself, or connect each to a namespace/container."
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Create the two veth pairs; does not start forwarding.
    Create(CreateArgs),
    /// Run the forwarder in the foreground for an existing cable.
    Run(RunArgs),
    /// Create the cable, then run the forwarder in the foreground.
    Up(UpArgs),
    /// Show whether all four interfaces exist.
    Status(NameArgs),
    /// Stop a forwarder started with the default or selected pid file.
    Stop(StopArgs),
    /// Delete both veth pairs (also stops their traffic immediately).
    Delete(NameArgs),
    /// Stop the forwarder, then delete both veth pairs.
    Down(StopArgs),
}

#[derive(Args, Debug)]
struct CreateArgs {
    #[command(flatten)]
    link: LinkArgs,
}

#[derive(Args, Debug)]
struct RunArgs {
    /// Cable name used to derive interface names.
    name: String,
    /// Where to record the forwarder's process id.
    #[arg(long)]
    pid_file: Option<PathBuf>,
    /// Optional eBPF source file attached
    #[arg(long, conflicts_with = "attach_p4")]
    attach_ebpf: Option<PathBuf>,
    /// Optional P4 source file attached
    #[arg(long, conflicts_with = "attach_ebpf")]
    attach_p4: Option<PathBuf>,
    // Up to one of the attachments at a time is possible
}

#[derive(Args, Debug)]
struct UpArgs {
    #[command(flatten)]
    link: LinkArgs,
    /// Where to record the forwarder's process id.
    #[arg(long)]
    pid_file: Option<PathBuf>,
    /// Optional eBPF source file attached
    #[arg(long, conflicts_with = "attach_p4")]
    attach_ebpf: Option<PathBuf>,
    /// Optional P4 source file attached
    #[arg(long, conflicts_with = "attach_ebpf")]
    attach_p4: Option<PathBuf>,
    // Up to one of the attachments at a time is possible
}

#[derive(Args, Debug)]
struct LinkArgs {
    /// Cable name. It produces NAME0, NAMEi0, NAMEi1, and NAME1.
    name: String,
    /// MTU used by all four interfaces.
    #[arg(long, default_value_t = 1500)]
    mtu: u16,
}

#[derive(Args, Debug)]
struct NameArgs {
    /// Cable name used to derive interface names.
    name: String,
}

#[derive(Args, Debug)]
struct StopArgs {
    /// Cable name used to derive interface names.
    name: String,
    /// The pid file supplied to `run` or `up`.
    #[arg(long)]
    pid_file: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Names {
    left: String,
    inner_left: String,
    inner_right: String,
    right: String,
}

impl Names {
    fn new(name: &str) -> Result<Self> {
        if name.is_empty()
            || name.len() > 12
            || !name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        {
            bail!("name must be 1–12 ASCII letters, digits, '_' or '-'");
        }
        // Linux has a 15-byte network interface-name limit. A 12-byte base
        // leaves space for the longest suffix, `i0`/`i1`.
        Ok(Self {
            left: format!("{name}0"),
            inner_left: format!("{name}i0"),
            inner_right: format!("{name}i1"),
            right: format!("{name}1"),
        })
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Create(args) => create(&args.link),
        Command::Run(args) => run(&args.name, args.pid_file, args.attach_ebpf, args.attach_p4),
        Command::Up(args) => {
            create(&args.link)?;
            run(&args.link.name, args.pid_file, args.attach_ebpf, args.attach_p4)
        }
        Command::Status(args) => status(&args.name),
        Command::Stop(args) => stop(&args.name, args.pid_file),
        Command::Delete(args) => delete(&args.name),
        Command::Down(args) => {
            // A missing/stale pid file is normal when a foreground `run`
            // has already been interrupted, so teardown remains useful.
            let _ = stop(&args.name, args.pid_file);
            delete(&args.name)
        }
    }
}

fn require_root(action: &str) -> Result<()> {
    // Creating veths needs CAP_NET_ADMIN and opening AF_PACKET needs
    // CAP_NET_RAW. Checking euid is simple and gives the normal invocation
    // a useful error; capabilities-only setups may still use `ip` directly.
    if unsafe { libc::geteuid() } != 0 {
        bail!("{action} needs root (or the required Linux capabilities); run with sudo");
    }
    Ok(())
}

fn ip(args: &[&str]) -> Result<()> {
    let output = ProcessCommand::new("ip")
        .args(args)
        .output()
        .context("could not start `ip`; install iproute2")?;
    if output.status.success() {
        return Ok(());
    }
    let error = String::from_utf8_lossy(&output.stderr).trim().to_owned();
    bail!("ip {}: {}", args.join(" "), error)
}

fn link_exists(name: &str) -> bool {
    ProcessCommand::new("ip")
        .args(["link", "show", "dev", name])
        .output()
        .is_ok_and(|output| output.status.success())
}

fn create(args: &LinkArgs) -> Result<()> {
    require_root("creating a virtual cable")?;
    let names = Names::new(&args.name)?;
    for iface in [
        &names.left,
        &names.inner_left,
        &names.inner_right,
        &names.right,
    ] {
        if link_exists(iface) {
            bail!(
                "interface '{iface}' already exists (use `vnic delete {}` first)",
                args.name
            );
        }
    }

    let mtu = args.mtu.to_string();
    // Delete the first pair if construction of the second one fails. `ip
    // link del` removes both ends of a veth pair, so this rollback is enough.
    ip(&[
        "link",
        "add",
        &names.left,
        "type",
        "veth",
        "peer",
        "name",
        &names.inner_left,
    ])?;
    let result = (|| -> Result<()> {
        ip(&[
            "link",
            "add",
            &names.inner_right,
            "type",
            "veth",
            "peer",
            "name",
            &names.right,
        ])?;
        for iface in [
            &names.left,
            &names.inner_left,
            &names.inner_right,
            &names.right,
        ] {
            ip(&["link", "set", "dev", iface, "mtu", &mtu])?;
            ip(&["link", "set", "dev", iface, "up"])?;
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = ip(&["link", "del", "dev", &names.left]);
        let _ = ip(&["link", "del", "dev", &names.inner_right]);
    }
    result?;

    println!(
        "created '{}': {} -- {} -- [forwarder] -- {} -- {}",
        args.name, names.left, names.inner_left, names.inner_right, names.right
    );
    Ok(())
}

fn status(name: &str) -> Result<()> {
    let names = Names::new(name)?;
    let interfaces = [
        &names.left,
        &names.inner_left,
        &names.inner_right,
        &names.right,
    ];
    let present: Vec<_> = interfaces
        .into_iter()
        .filter(|name| link_exists(name))
        .collect();
    if present.len() == 4 {
        println!("{}: ready (forwarder may or may not be running)", name);
    } else if present.is_empty() {
        println!("{}: absent", name);
    } else {
        println!(
            "{}: partial; present: {}",
            name,
            present
                .into_iter()
                .map(String::as_str)
                .collect::<Vec<_>>()
                .join(", ")
        );
    }
    Ok(())
}

fn delete(name: &str) -> Result<()> {
    require_root("deleting a virtual cable")?;
    let names = Names::new(name)?;
    // Either end deletes its whole pair. Prefer the outer end, but fall back
    // to the inner end: callers commonly move outer endpoints into network
    // namespaces after `create`, while the inner ends always stay here with
    // the forwarder.
    for (outer, inner) in [
        (&names.left, &names.inner_left),
        (&names.right, &names.inner_right),
    ] {
        let iface = if link_exists(outer) { outer } else { inner };
        if link_exists(iface) {
            ip(&["link", "del", "dev", iface])?;
        }
    }
    println!("deleted '{name}'");
    Ok(())
}

fn default_pid_file(name: &str) -> PathBuf {
    PathBuf::from(format!("/run/vnic-{name}.pid"))
}

fn stop(name: &str, pid_file: Option<PathBuf>) -> Result<()> {
    require_root("stopping a forwarder")?;
    let path = pid_file.unwrap_or_else(|| default_pid_file(name));
    let pid = match fs::read_to_string(&path) {
        Ok(contents) => contents.trim().parse::<i32>().context("invalid pid file")?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            println!("no pid file at {}; nothing to stop", path.display());
            return Ok(());
        }
        Err(error) => return Err(error.into()),
    };
    let result = unsafe { libc::kill(pid, SIGTERM) };
    if result == 0 {
        println!("sent SIGTERM to pid {pid}");
        Ok(())
    } else {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ESRCH) {
            let _ = fs::remove_file(&path);
            println!("removed stale pid file {}", path.display());
            Ok(())
        } else {
            Err(error.into())
        }
    }
}

fn open_channel(name: &str) -> Result<(Box<dyn DataLinkSender>, Box<dyn DataLinkReceiver>)> {
    let interface = pnet_datalink::interfaces()
        .into_iter()
        .find(|interface| interface.name == name)
        .with_context(|| format!("interface '{name}' does not exist"))?;
    // AF_PACKET normally reports packets sent by this same socket too. A
    // bidirectional forwarder would then receive its own output and bounce
    // it back forever. Ask Linux to deliver ingress packets only before
    // handing the socket to pnet for binding and I/O.
    let fd = unsafe { libc::socket(libc::AF_PACKET, libc::SOCK_RAW, libc::ETH_P_ALL.to_be()) };
    if fd == -1 {
        return Err(std::io::Error::last_os_error().into());
    }
    let enabled: libc::c_int = 1;
    let ignored = unsafe {
        libc::setsockopt(
            fd,
            libc::SOL_PACKET,
            libc::PACKET_IGNORE_OUTGOING,
            (&enabled as *const libc::c_int).cast(),
            std::mem::size_of_val(&enabled) as libc::socklen_t,
        )
    };
    if ignored == -1 {
        let error = std::io::Error::last_os_error();
        unsafe { libc::close(fd) };
        return Err(error).context("enabling PACKET_IGNORE_OUTGOING");
    }

    let config = Config {
        promiscuous: true,
        read_timeout: Some(RECEIVE_TIMEOUT),
        socket_fd: Some(fd),
        ..Config::default()
    };
    match pnet_datalink::channel(&interface, config)? {
        Channel::Ethernet(tx, rx) => Ok((tx, rx)),
        _ => bail!("'{name}' does not support Ethernet packet I/O"),
    }
}

fn forward(
    mut rx: Box<dyn DataLinkReceiver>,
    mut tx: Box<dyn DataLinkSender>,
    from: String,
    to: String,
    shutdown: Arc<AtomicBool>,
) -> Result<u64> {
    let mut forwarded = 0_u64;
    while !shutdown.load(Ordering::Relaxed) {
        match rx.next() {
            Ok(frame) => match tx.send_to(frame, None) {
                Some(Ok(())) => forwarded += 1,
                Some(Err(error)) => return Err(error.into()),
                None => bail!("send buffer on '{to}' is full"),
            },
            Err(error)
                if error.kind() == std::io::ErrorKind::TimedOut
                    || error.kind() == std::io::ErrorKind::WouldBlock
                    || error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error).with_context(|| format!("receiving from '{from}'")),
        }
    }
    Ok(forwarded)
}

fn run(
    name: &str,
    pid_file: Option<PathBuf>,
    attach_ebpf: Option<PathBuf>,
    attach_p4: Option<PathBuf>,
) -> Result<()> {
    require_root("running the packet forwarder")?;
    let names = Names::new(name)?;
    if !link_exists(&names.inner_left) || !link_exists(&names.inner_right) {
        bail!("cable '{name}' is not complete; run `vnic create {name}` first");
    }

    let is_emulation = attach_ebpf.is_some() || attach_p4.is_some();
    if is_emulation {
        ip(&["tuntap", "add", "dev", "tap0", "mode", "tap"])?;
        ip(&["link", "set", "dev", "tap0", "up"])?;
        ip(&["tuntap", "add", "dev", "tap1", "mode", "tap"])?;
        ip(&["link", "set", "dev", "tap1", "up"])?;
        println!("[DEV] create interfacce tap0 e tap1 per emulazione");
    }

    let (left_tx, left_rx) = open_channel(&names.inner_left)?;
    let (right_tx, right_rx) = open_channel(&names.inner_right)?;
    let pid_file = pid_file.unwrap_or_else(|| default_pid_file(name));
    fs::write(&pid_file, std::process::id().to_string())
        .with_context(|| format!("writing {}", pid_file.display()))?;

    let shutdown = Arc::new(AtomicBool::new(false));
    signal_hook::flag::register(SIGINT, Arc::clone(&shutdown))?;
    signal_hook::flag::register(SIGTERM, Arc::clone(&shutdown))?;
    println!(
        "forwarding '{}' ({} <-> {}); press Ctrl-C to stop",
        name, names.inner_left, names.inner_right
    );

    let to_right_shutdown = Arc::clone(&shutdown);
    let left_name = names.inner_left.clone();
    let right_name = names.inner_right.clone();
    let left_to_right =
        thread::spawn(move || forward(left_rx, right_tx, left_name, right_name, to_right_shutdown));
    let right_to_left = forward(
        right_rx,
        left_tx,
        names.inner_right.clone(),
        names.inner_left.clone(),
        shutdown,
    )?;
    let left_to_right = left_to_right
        .join()
        .map_err(|_| anyhow::anyhow!("left-to-right forwarding thread panicked"))??;

    let _ = fs::remove_file(&pid_file);
    println!(
        "stopped '{}': {} frames left-to-right, {} frames right-to-left",
        name, left_to_right, right_to_left
    );

    if is_emulation {
        ip(&["link", "del", "dev", "tap0"])?;
        ip(&["link", "del", "dev", "tap1"])?;
        println!("[DEV] rimosse interfacce tap0 e tap1");
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::Names;

    #[test]
    fn derives_short_linux_interface_names() {
        assert_eq!(Names::new("demo").unwrap().inner_left, "demoi0");
        assert!(Names::new("this-name-is-too-long").is_err());
        assert!(Names::new("not/a/name").is_err());
    }
}
