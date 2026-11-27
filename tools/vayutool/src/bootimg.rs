use anyhow::{bail, Context, Result};
use flate2::{write::GzEncoder, Compression};
use sha1::{Digest as Sha1Digest, Sha1};
use sha2::Sha256;
use std::fs;
use std::io::Write;
use std::path::Path;

const BOOT_MAGIC: &[u8; 8] = b"ANDROID!";
const HDR_V2_SIZE: usize = 1660;
const FDT_MAGIC: [u8; 4] = [0xd0, 0x0d, 0xfe, 0xed];
const ARM64_MAGIC: &[u8; 4] = b"ARM\x64";

#[derive(Debug, Clone)]
pub struct BootHeaderV2 {
    pub kernel_size: u32,
    pub kernel_addr: u32,
    pub ramdisk_size: u32,
    pub ramdisk_addr: u32,
    pub second_size: u32,
    pub second_addr: u32,
    pub tags_addr: u32,
    pub page_size: u32,
    pub header_version: u32,
    pub os_version: u32,
    pub name: [u8; 16],
    pub cmdline: [u8; 512],
    pub id: [u8; 32],
    pub extra_cmdline: [u8; 1024],
    pub recovery_dtbo_size: u32,
    pub recovery_dtbo_offset: u64,
    pub header_size: u32,
    pub dtb_size: u32,
    pub dtb_addr: u64,
}

fn read_u32(b: &[u8], off: usize) -> u32 {
    u32::from_le_bytes(b[off..off + 4].try_into().unwrap())
}

fn read_u64(b: &[u8], off: usize) -> u64 {
    u64::from_le_bytes(b[off..off + 8].try_into().unwrap())
}

fn pages(bytes: usize, page: usize) -> usize {
    (bytes + page - 1) / page
}

fn pad_to_page(buf: &mut Vec<u8>, page: usize) {
    let rem = buf.len() % page;
    if rem != 0 {
        buf.resize(buf.len() + (page - rem), 0);
    }
}

fn cstr(bytes: &[u8]) -> String {
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

pub fn parse_v2(data: &[u8]) -> Result<(BootHeaderV2, Vec<u8>)> {
    if data.len() < HDR_V2_SIZE {
        bail!("image too small ({} bytes < {})", data.len(), HDR_V2_SIZE);
    }
    if &data[0..8] != BOOT_MAGIC {
        bail!("missing ANDROID! magic");
    }
    let header_version = read_u32(data, 40);
    if header_version != 2 {
        bail!("expected header_version 2, got {}", header_version);
    }
    let page_size = read_u32(data, 36);
    if page_size == 0 || !page_size.is_power_of_two() {
        bail!("invalid page_size {}", page_size);
    }

    let mut name = [0u8; 16];
    name.copy_from_slice(&data[48..64]);
    let mut cmdline = [0u8; 512];
    cmdline.copy_from_slice(&data[64..576]);
    let mut id = [0u8; 32];
    id.copy_from_slice(&data[576..608]);
    let mut extra_cmdline = [0u8; 1024];
    extra_cmdline.copy_from_slice(&data[608..1632]);

    let hdr = BootHeaderV2 {
        kernel_size: read_u32(data, 8),
        kernel_addr: read_u32(data, 12),
        ramdisk_size: read_u32(data, 16),
        ramdisk_addr: read_u32(data, 20),
        second_size: read_u32(data, 24),
        second_addr: read_u32(data, 28),
        tags_addr: read_u32(data, 32),
        page_size,
        header_version,
        os_version: read_u32(data, 44),
        name,
        cmdline,
        id,
        extra_cmdline,
        recovery_dtbo_size: read_u32(data, 1632),
        recovery_dtbo_offset: read_u64(data, 1636),
        header_size: read_u32(data, 1644),
        dtb_size: read_u32(data, 1648),
        dtb_addr: read_u64(data, 1652),
    };

    let p = page_size as usize;
    let dtb_off = p
        * (1 + pages(hdr.kernel_size as usize, p)
            + pages(hdr.ramdisk_size as usize, p)
            + pages(hdr.second_size as usize, p)
            + pages(hdr.recovery_dtbo_size as usize, p));
    let dtb_end = dtb_off + hdr.dtb_size as usize;
    if hdr.dtb_size == 0 || dtb_end > data.len() {
        bail!(
            "DTB out of bounds (off={}, size={}, file_len={})",
            dtb_off,
            hdr.dtb_size,
            data.len()
        );
    }
    let dtb = data[dtb_off..dtb_end].to_vec();
    if dtb.len() < 4 || dtb[0..4] != FDT_MAGIC {
        bail!("DTB section missing FDT magic 0xd00dfeed");
    }
    Ok((hdr, dtb))
}

fn empty_cpio_gz() -> Result<Vec<u8>> {
    // Minimal newc cpio archive containing only the TRAILER!!! entry.
    let trailer = b"07070100000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000b00000000TRAILER!!!\0\0\0\0";
    let mut enc = GzEncoder::new(Vec::new(), Compression::best());
    enc.write_all(trailer)?;
    Ok(enc.finish()?)
}

fn encode_header_v2(hdr: &BootHeaderV2) -> Vec<u8> {
    let mut out = Vec::with_capacity(HDR_V2_SIZE);
    out.extend_from_slice(BOOT_MAGIC);
    out.extend_from_slice(&hdr.kernel_size.to_le_bytes());
    out.extend_from_slice(&hdr.kernel_addr.to_le_bytes());
    out.extend_from_slice(&hdr.ramdisk_size.to_le_bytes());
    out.extend_from_slice(&hdr.ramdisk_addr.to_le_bytes());
    out.extend_from_slice(&hdr.second_size.to_le_bytes());
    out.extend_from_slice(&hdr.second_addr.to_le_bytes());
    out.extend_from_slice(&hdr.tags_addr.to_le_bytes());
    out.extend_from_slice(&hdr.page_size.to_le_bytes());
    out.extend_from_slice(&hdr.header_version.to_le_bytes());
    out.extend_from_slice(&hdr.os_version.to_le_bytes());
    out.extend_from_slice(&hdr.name);
    out.extend_from_slice(&hdr.cmdline);
    out.extend_from_slice(&hdr.id);
    out.extend_from_slice(&hdr.extra_cmdline);
    out.extend_from_slice(&hdr.recovery_dtbo_size.to_le_bytes());
    out.extend_from_slice(&hdr.recovery_dtbo_offset.to_le_bytes());
    out.extend_from_slice(&hdr.header_size.to_le_bytes());
    out.extend_from_slice(&hdr.dtb_size.to_le_bytes());
    out.extend_from_slice(&hdr.dtb_addr.to_le_bytes());
    debug_assert_eq!(out.len(), HDR_V2_SIZE);
    out
}

pub fn build_boot_v2(
    stock_bytes: &[u8],
    kernel: &[u8],
    ramdisk: &[u8],
    cmdline_str: &str,
) -> Result<Vec<u8>> {
    if kernel.len() < 60 || &kernel[56..60] != ARM64_MAGIC {
        bail!("kernel image lacks ARM64 Image header magic (ARM\\x64 at offset 56)");
    }
    let (st, dtb) = parse_v2(stock_bytes)?;
    let page = st.page_size as usize;

    let mut sha1 = Sha1::new();
    for blob in [kernel, ramdisk, &[][..], &[][..], &dtb[..]] {
        sha1.update(blob);
        sha1.update(&(blob.len() as u32).to_le_bytes());
    }
    let digest = sha1.finalize();
    let mut id = [0u8; 32];
    id[..20].copy_from_slice(&digest);

    let mut cmdline = [0u8; 512];
    let cb = cmdline_str.as_bytes();
    let copy_len = cb.len().min(511);
    cmdline[..copy_len].copy_from_slice(&cb[..copy_len]);

    let hdr = BootHeaderV2 {
        kernel_size: kernel.len() as u32,
        kernel_addr: st.kernel_addr,
        ramdisk_size: ramdisk.len() as u32,
        ramdisk_addr: st.ramdisk_addr,
        second_size: 0,
        second_addr: st.second_addr,
        tags_addr: st.tags_addr,
        page_size: st.page_size,
        header_version: 2,
        os_version: st.os_version,
        name: st.name,
        cmdline,
        id,
        extra_cmdline: [0u8; 1024],
        recovery_dtbo_size: 0,
        recovery_dtbo_offset: 0,
        header_size: HDR_V2_SIZE as u32,
        dtb_size: dtb.len() as u32,
        dtb_addr: st.dtb_addr,
    };

    let mut img = encode_header_v2(&hdr);
    pad_to_page(&mut img, page);
    img.extend_from_slice(kernel);
    pad_to_page(&mut img, page);
    img.extend_from_slice(ramdisk);
    pad_to_page(&mut img, page);
    img.extend_from_slice(&dtb);
    pad_to_page(&mut img, page);
    Ok(img)
}

pub fn inspect(path: &Path) -> Result<()> {
    let data = fs::read(path).with_context(|| format!("reading {}", path.display()))?;
    let (hdr, dtb) = parse_v2(&data)?;
    let p = hdr.page_size as usize;
    let k_off = p;
    let r_off = k_off + pages(hdr.kernel_size as usize, p) * p;
    let s_off = r_off + pages(hdr.ramdisk_size as usize, p) * p;
    let dtb_off = s_off
        + pages(hdr.second_size as usize, p) * p
        + pages(hdr.recovery_dtbo_size as usize, p) * p;
    let hash = Sha256::digest(&data);

    println!("file:           {} ({} bytes)", path.display(), data.len());
    println!(
        "header:         v{} (size {}, page {})",
        hdr.header_version, hdr.header_size, hdr.page_size
    );
    println!("os_version:     {:#010x}", hdr.os_version);
    println!("name:           \"{}\"", cstr(&hdr.name));
    println!("cmdline:        \"{}\"", cstr(&hdr.cmdline));
    println!(
        "kernel:         {} bytes @ off {:#x}, load {:#x}",
        hdr.kernel_size, k_off, hdr.kernel_addr
    );
    println!(
        "ramdisk:        {} bytes @ off {:#x}, load {:#x}",
        hdr.ramdisk_size, r_off, hdr.ramdisk_addr
    );
    println!("tags_addr:      {:#x}", hdr.tags_addr);
    println!(
        "dtb:            {} bytes @ off {:#x}, load {:#x} (magic {:02x?})",
        dtb.len(),
        dtb_off,
        hdr.dtb_addr,
        &dtb[..4]
    );
    println!("sha256:         {:x}", hash);
    Ok(())
}

pub fn pack(
    stock_path: &Path,
    kernel_path: &Path,
    ramdisk_path: Option<&Path>,
    out_path: &Path,
    cmdline: &str,
) -> Result<()> {
    let stock = fs::read(stock_path).with_context(|| format!("reading {}", stock_path.display()))?;
    let kernel =
        fs::read(kernel_path).with_context(|| format!("reading {}", kernel_path.display()))?;
    let ramdisk = match ramdisk_path {
        Some(p) => fs::read(p).with_context(|| format!("reading {}", p.display()))?,
        None => empty_cpio_gz()?,
    };
    let img = build_boot_v2(&stock, &kernel, &ramdisk, cmdline)?;
    fs::write(out_path, &img).with_context(|| format!("writing {}", out_path.display()))?;
    let hash = Sha256::digest(&img);
    println!(
        "wrote {}: {} bytes (kernel {}, ramdisk {}, cmdline \"{}\")",
        out_path.display(),
        img.len(),
        kernel.len(),
        ramdisk.len(),
        cmdline
    );
    println!("sha256 {}", format!("{:x}", hash));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fake_stock_boot() -> Vec<u8> {
        let page = 4096usize;
        let mut dtb = vec![0u8; 64];
        dtb[..4].copy_from_slice(&FDT_MAGIC);
        let hdr = BootHeaderV2 {
            kernel_size: 4096,
            kernel_addr: 0x8000,
            ramdisk_size: 0,
            ramdisk_addr: 0x1000000,
            second_size: 0,
            second_addr: 0,
            tags_addr: 0x100,
            page_size: page as u32,
            header_version: 2,
            os_version: 0x220001ab,
            name: [0u8; 16],
            cmdline: [0u8; 512],
            id: [0u8; 32],
            extra_cmdline: [0u8; 1024],
            recovery_dtbo_size: 0,
            recovery_dtbo_offset: 0,
            header_size: HDR_V2_SIZE as u32,
            dtb_size: dtb.len() as u32,
            dtb_addr: 0x1f00000,
        };
        let mut out = encode_header_v2(&hdr);
        pad_to_page(&mut out, page);
        out.resize(out.len() + page, 0xaa);
        out.extend_from_slice(&dtb);
        pad_to_page(&mut out, page);
        out
    }

    #[test]
    fn roundtrip_pack_and_parse() {
        let stock = fake_stock_boot();
        let mut kernel = vec![0u8; 128];
        kernel[56..60].copy_from_slice(ARM64_MAGIC);
        let ramdisk = empty_cpio_gz().unwrap();
        let packed = build_boot_v2(&stock, &kernel, &ramdisk, "console=null").unwrap();
        let (hdr, dtb) = parse_v2(&packed).unwrap();
        assert_eq!(hdr.kernel_size, 128);
        assert_eq!(hdr.kernel_addr, 0x8000);
        assert_eq!(hdr.ramdisk_addr, 0x1000000);
        assert_eq!(hdr.dtb_addr, 0x1f00000);
        assert_eq!(dtb.len(), 64);
        assert_eq!(cstr(&hdr.cmdline), "console=null");
    }
}
