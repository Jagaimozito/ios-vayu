//! vayutool: Rust host tooling for the POCO X3 Pro (vayu) iOS 27.2 port.
//! Structured after akshaynexus/iOSPlus10 (op10tool) and akshaynexus/OneiOS (oneios-tool).

mod bootimg;

use anyhow::Result;
use clap::{Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "vayutool", version, about = "POCO X3 Pro (vayu) iOS 27.2 host tools")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Inspect an Android boot image (v2) header, section sizes/offsets, DTB magic, and SHA-256
    InspectBoot {
        /// Path to the Android boot image
        image: PathBuf,
    },
    /// Pack an ARM64 shim/kernel Image into an Android v2 boot.img reusing the stock DTB and addresses
    PackBoot {
        /// Path to the stock boot.img (provides DTB, load addresses, page size, OS version)
        #[arg(long)]
        stock: PathBuf,
        /// Path to the ARM64 kernel/shim Image
        #[arg(long)]
        kernel: PathBuf,
        /// Optional path to a ramdisk (cpio.gz or SWEETXNU payload); defaults to an empty cpio.gz
        #[arg(long)]
        ramdisk: Option<PathBuf>,
        /// Output boot.img path
        #[arg(long)]
        out: PathBuf,
        /// Kernel command line stored in the boot image header
        #[arg(long, default_value = "console=null")]
        cmdline: String,
    },
}

fn main() -> Result<()> {
    match Cli::parse().cmd {
        Cmd::InspectBoot { image } => bootimg::inspect(&image),
        Cmd::PackBoot {
            stock,
            kernel,
            ramdisk,
            out,
            cmdline,
        } => bootimg::pack(&stock, &kernel, ramdisk.as_deref(), &out, &cmdline),
    }
}
