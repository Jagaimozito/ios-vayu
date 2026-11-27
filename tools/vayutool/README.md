# vayutool

Rust host CLI for the POCO X3 Pro (`vayu`) iOS 27.2 port, structured after
[`akshaynexus/iOSPlus10`](https://github.com/akshaynexus/iOSPlus10) (`tools/op10tool`, MIT) and
[`akshaynexus/OneiOS`](https://github.com/akshaynexus/OneiOS) (`tools/oneios-tool`, MIT).

## Subcommands

- `inspect-boot <IMAGE>` — parse Android `boot.img` v2 header fields, section offsets, DTB magic, and SHA-256.
- `pack-boot --stock <STOCK_BOOT> --kernel <IMAGE> [--ramdisk <RAMDISK>] --out <OUT> [--cmdline ...]` — pack an ARM64 shim/kernel `Image` + optional ramdisk into a `vayu` Android v2 `boot.img` reusing the stock boot image's DTB and load addresses.

## Build & Test

```sh
cd tools/vayutool
cargo test
cargo build --release
```
