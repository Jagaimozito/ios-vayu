# Working on ios-vayu

- Read `NOTES.md` before starting; it contains the project goal, `vayu` hardware facts,
  current blocker, local artifact locations and the next concrete action.
- The user switches agents frequently. Update the active handoff in `NOTES.md`
  after each milestone and before stopping. Record commits, CI run IDs, exact
  build/boot results and unfinished work. Distinguish observations from guesses.
- Commit completed changes. Use `gh` for GitHub Actions kernel builds and logs.
  Local single-file cross-compiles are useful before spending a CI run.
- **Critical Partition Safety Rule:** Device bring-up uses temporary `fastboot boot` images.
  The user authorized wiping/flashing non-critical partitions (`userdata`, `/dev/block/sda32`)
  for the iOS root (no GPT changes), while **strictly forbidding** deleting or modifying any
  critical partition (`xbl`, `xbl_config`, `abl`, `aop`, `modemst1`, `modemst2`, `fsg`, `persist`,
  `uefisecapp`, `uefivarstore`, `ddr`, `cdt`, `devinfo`, `recovery`). Keep stock `boot` (`sde49`)
  and `dtbo` (`sde45`) backed up in `dumps/` and confirm before any flash to `boot` or `userdata`.
- Keep device dumps (`dumps/`), firmware blobs (`fw-vayu/`), serial numbers, Wi-Fi keys,
  and downloaded Apple artifacts out of git.

## Languages

- Write new code in **Rust** (boot tools and loaders, UEFI apps with the `uefi` crate,
  host and flashing tools, daemons and services, driver logic behind a thin C/C++ shim).
- Use **C or C++** only where Rust cannot go: XNU itself, IOKit's C++ interfaces,
  patches to existing C/C++ code (such as `shim/`), and vendor ABIs.
- **No Python** in anything that ships or runs on the device; Python is fine for small dev scripts.
- Reuse existing MIT Rust tools/crates (`akshaynexus/iOSPlus10` `tools/op10tool` and
  `akshaynexus/OneiOS` `tools/oneios-tool`) before writing new ones, keeping their license
  and attribution, and add new tools as subcommands in the same style.

## iOSOnAnd tracker

- This port is tracked at https://hackios.appaiproxy.com/device/poco-x3-pro (repo: `t3ddycarecaexiste/ios-vayu`).
- Never commit `cli.mjs`, `.env*`, `TRACKER_QUEUE.md`, or `TRACKER_TOKEN` / API keys.
- Before updating any area, inspect current state with:
  `node cli.mjs status-get --device poco-x3-pro`
- Whenever a change makes an area work or breaks it, record it in the same session:
  `node cli.mjs status-set poco-x3-pro <area> works|in-progress|broken --detail "<what the build, log or test showed>" --source "<commit or log link>" --os ios --version "iOS 27.2"` (add `--photo <file>` for a screenshot or clip that proves it).
- Post milestone progress with `node cli.mjs update poco-x3-pro <files> --text "..."`.
- Record GPU acceleration stack/fps with `node cli.mjs gpu-set poco-x3-pro ...` and log GPU bugs with `node cli.mjs gpu-issue-add poco-x3-pro ...` / `gpu-issue-set`.
- Only claim what a build, log, photo, or video directly proves; anything unproven stays `unknown`.
