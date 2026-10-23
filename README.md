<p align="center">
  <img src="docs/assets/icon.png" width="128" alt="TetherKit icon">
</p>

# TetherKit

**English** | [简体中文](README.zh-CN.md)

**A kext-free HoRNDIS alternative that brings Android USB tethering on macOS back to life.**

TetherKit is a **user-space RNDIS driver for macOS**: it turns an RNDIS device (Android USB
tethering, Windows Phone, embedded Linux gadgets, …) into a network interface that macOS can
see and use — with **no kernel extension, no DriverKit, no SIP changes and no developer
account**. Works the same on Apple Silicon and Intel. Ships with a GUI — pick a device,
connect, configure IP in three clicks — plus a command-line tool, `tetherkit-cli`.

![TetherKit main window](docs/assets/screenshot-main-en.jpg)

- **USB side**: asynchronous bulk transfers via [libusb](https://libusb.info/), with a complete
  host-side RNDIS state machine.
- **Interface side**: macOS `feth` (`if_fake`) virtual interface pairs + BPF, reading and
  writing raw Ethernet frames directly.
- **No kernel code**: pure user-space C++23. No kext, no DriverKit, no need to disable SIP.

> ⚠️ **Status**: all modules are implemented; 210 test cases (10,408 assertions) pass
> under both a normal build and a ThreadSanitizer build. End-to-end throughput,
> measured against a real Android phone: **~326 Mbps RX / ~240–300 Mbps TX, zero
> retransmits in both directions** (USB 2.0 high-speed; theoretical ceiling 426 Mbps).
> Methodology and full results: [docs/BENCHMARKS.md](docs/BENCHMARKS.md); the
> verification checklist lives in [AGENTS.md](AGENTS.md) §6 (Chinese).

---

## Coming from HoRNDIS?

If you landed here because **HoRNDIS stopped working after a macOS upgrade**, or because it
shows up as blocked/"Disabled Software" with no *Allow* button on your Apple Silicon Mac —
that is what TetherKit is for.

[HoRNDIS](https://github.com/jwise/HoRNDIS) was the answer for years, and it is good software.
But it is a **kernel extension**, and that is the part macOS keeps tightening:

| | HoRNDIS | TetherKit |
|---|---|---|
| Kind of software | Kernel extension (kext) | Plain user-space program |
| Apple Silicon | Needs *Reduced Security* set in Recovery + a reboot before a third-party kext can load at all | Nothing to change — it is not a driver as far as the OS is concerned |
| SIP | Commonly needs to be weakened | Untouched |
| After a macOS upgrade | Kext may stop loading; re-approval or a rebuild is often needed | Just an app; nothing to re-approve |
| Worst case failure | Kernel panic | The process exits |
| Upstream status | Latest release 9.2 (Aug 2024); ["MacOS Sonoma not supported"](https://github.com/jwise/HoRNDIS/issues/169) still open | Actively developed |

TetherKit reaches the same goal from the other side: instead of teaching the kernel to speak
RNDIS, it speaks RNDIS **in user space** over libusb, and hands the resulting Ethernet frames
to macOS through a `feth` virtual interface pair. The kernel never loads any of our code.

**What you give up:** the interface is created by an app you have to start (the connection
itself survives quitting the UI — it lives in a small privileged background component), and
throughput is bounded by user-space copies rather than the USB link. In practice that has not
been the limit: see the measured numbers above.

---

## Why this exists

The macOS kernel has **no** RNDIS driver. Plug in an Android phone with USB tethering enabled
and no new interface shows up. Existing approaches either ship a kext (requires weakening SIP
or Apple Silicon's security policy, a high signing bar, and breaks easily on system updates)
or go through a Network Extension (requires a developer account plus system-extension
approval). TetherKit takes a third route: **act as both the USB host and the network driver,
entirely in user space**.

---

## Installation

**Compatibility**: macOS 14 Sonoma, 15 Sequoia and 26 Tahoe, on Apple Silicon (M1–M4) and
Intel. The command-line tool goes back to macOS 13.3 Ventura. Nothing needs to be disabled —
SIP stays on, the Apple Silicon security policy stays at *Full Security*.

```bash
# The GUI, TetherKit.app (macOS 14+)
brew install XiaoMiku01/tap/tetherkit

# The command-line tool, tetherkit-cli (macOS 13.3+)
brew install XiaoMiku01/tap/tetherkit-cli
```

Both formulae build from source and pull in `libusb` automatically. The tap
lives at [XiaoMiku01/homebrew-tap](https://github.com/XiaoMiku01/homebrew-tap).

Launch the GUI like this (on first launch the app drops a Finder alias into
/Applications, so Spotlight can find and launch TetherKit from then on):

```bash
open "$(brew --prefix)/opt/tetherkit/TetherKit.app"
```

On first run the app walks you through installing the privileged helper —
one click, one admin password prompt.

To upgrade:

```bash
brew upgrade tetherkit tetherkit-cli
```

> **Note for existing users**: as of v0.1.2 the formula name `tetherkit` belongs
> to the GUI; the CLI was renamed `tetherkit-cli` (binary included). If you had
> the CLI installed, run `brew uninstall tetherkit && brew install tetherkit-cli`.

You can also grab prebuilt artifacts straight from
[Releases](https://github.com/XiaoMiku01/TetherKit/releases) (arm64 only). They are
**unsigned**, so a browser download gets quarantined by Gatekeeper and you have to
clear the attribute yourself:

```bash
xattr -d com.apple.quarantine tetherkit-cli     # CLI
xattr -dr com.apple.quarantine TetherKit.app    # GUI (recursive)
```

If that bothers you, use Homebrew above, or build it yourself as described in
[Building from source](#building-from-source) — locally built artifacts carry no
quarantine attribute.

---

## Graphical interface

TetherKit.app (SwiftUI) reduces the whole flow to three clicks — pick a device,
connect, configure IP — and shows live throughput and logs.

It comes in two pieces: `TetherKit.app` runs as a **normal user**, and anything
that needs root is handed to `tetherkit-helper`, a privileged component launched
on demand by launchd. Every privileged call carries an authorization credential
the user has just confirmed. The app itself needs no entitlements.

The helper's installation payload is embedded in the .app
(`Contents/Library/HelperTools/`); on first run the app walks you through
installing it (see Installation above). If you prefer the terminal, this is
exactly equivalent:

```bash
sudo ./gui/Scripts/install-helper.sh
```

Uninstall: the dashboard has an "Uninstall privileged component…" button at the
bottom (terminal equivalent: `sudo ./gui/Scripts/uninstall-helper.sh`).

The app lets you choose how the virtual interface gets its address:

| Mode | Notes |
|---|---|
| Automatic (DHCP) | Handled by the system's IPConfiguration — lease, DNS and routes are all set up for you. Most phones ship a DHCP server, so this is the recommended choice |
| Static IP | Enter address, netmask, gateway and DNS yourself. Validated as you type, including netmask contiguity |

There is also a "route all traffic through this interface" switch. With it off,
only traffic explicitly bound to the interface uses it. You usually do not need
it — when no other network is available, macOS picks this interface as the
primary service on its own.

**Background mode**: closing the main window keeps the app in the menu bar
(the Dock icon is hidden) with live up/down rates on the status item; click it
for a compact panel with shortcuts back to the main window. The connection
itself lives in the privileged helper, so quitting the UI never drops it.

While connected, the status item shows upload above download in two right-aligned
lines with a fixed width, so changing values do not move neighboring icons. Rates
use bytes per second (`B/s`, `K/s`, `M/s`; each step is 1024); the main dashboard
continues to show bits per second. When idle, only the status icon is shown.

**Update check**: "TetherKit → Check for Updates…" checks on demand; the app also
checks once a day on its own (it only hits GitHub's public Releases API and
reports nothing), lighting up a notice at the bottom of the dashboard when a new
version is out. The update itself still goes through `brew upgrade` or a source
rebuild — with certificate-free distribution, auto-replacing the .app would be
blocked by Gatekeeper, so the app deliberately only checks, never swaps. To
disable the automatic check:
`defaults write com.tetherkit.app updateCheckDisabled -bool YES`.

**Interface language**: "TetherKit → Language" offers Follow system / 中文 /
English, and the menu bar panel carries the same switch. Changes take effect
**immediately** — no restart — and the log lines coming out of the library
follow along (the language is pushed to the privileged helper too). The default
is to follow the system language.

**Requires** macOS 14+ (the CLI still supports 13.3+). Design notes and
trade-offs are in [docs/GUI-ARCHITECTURE.md](docs/GUI-ARCHITECTURE.md).

---

## Command-line tool

Besides the GUI there is a command-line tool, `tetherkit-cli` (installation above):

```bash
# First check whether the device is recognized (**no root needed**)
tetherkit-cli --list

# Start the driver
sudo tetherkit-cli

# In another terminal, configure the new interface (RNDIS devices usually run a DHCP server)
sudo ipconfig set feth0 DHCP
ipconfig getifaddr feth0
```

> The commands above assume an installed `tetherkit-cli` (on your `PATH`). If you
> built from source, substitute `./build/bin/tetherkit-cli`.

On a successful start the program prints the interface it created along with the follow-up
commands. `Ctrl-C` shuts down gracefully (the device is taken out of RNDIS first, then the
interface is destroyed).

Common options (see `--help` for the full list):

| Option | Description |
|---|---|
| `--list` | List detected RNDIS devices and exit; no root required |
| `--vid` / `--pid` | Select a device (hex), for multi-device setups |
| `--stats 1000` | Print a throughput/drop statistics line every second |
| `--log debug` | Enable detailed protocol interaction logging |
| `--max-transfer-kb` | The main throughput tuning knob — see [docs/PERFORMANCE.md](docs/PERFORMANCE.md) |
| `--lang zh\|en\|auto` | Interface language, default `auto` (see below) |

**Language**: by default the tool checks `TETHERKIT_LANG`, `LC_ALL`,
`LC_MESSAGES` and `LANG` in that order and takes the first non-empty value.
Anything starting with `zh` means Chinese; everything else means English.

```bash
tetherkit-cli --lang zh --help     # pick explicitly
TETHERKIT_LANG=zh tetherkit-cli --list
```

> ⚠️ Whether `sudo` passes `LANG` through depends on your sudoers `env_keep`, so
> `sudo tetherkit-cli` does not necessarily follow your terminal's language —
> pass `--lang` explicitly in that case.

### Why root is needed

| Operation | Root? | Reason |
|---|---|---|
| Create / destroy `feth` | ✔ | The kernel enforces `proc_suser` on `SIOCIFCREATE2` / `SIOCSDRVSPEC` |
| Open `/dev/bpf*` | ✔ | The nodes are `0600 root:wheel`, and macOS has **no** equivalent of FreeBSD's `access_bpf` group |
| libusb claiming the RNDIS interface | ✘ | The macOS kernel has **no** RNDIS driver, so nothing else holds the interface. A non-sandboxed command line program needs neither root nor an entitlement |

In other words, root is a requirement of the interface side, not the USB side — which is why
`--list` works without it.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `--list` finds no device | ① Try a different **data** cable (many are power-only); ② enable "USB tethering" on the device; ③ unlock the phone and trust this computer. Use `system_profiler SPUSBDataType` to check whether the system sees the device at all |
| `claiming the RNDIS data interface failed [libusb: LIBUSB_ERROR_ACCESS]` | Something else owns the interface. Check for a third-party kext such as HoRNDIS, or another user-space program using the device |
| `creating the feth virtual interface requires root` | Run it with `sudo` |
| `sysctl net.link.fake.hwcsum is 1, expected 0` | These switches are **snapshotted when the feth is created**; changing them afterwards has no effect. Do `sudo sysctl -w net.link.fake.hwcsum=0` first, then start |
| `ipconfig set feth0 DHCP` gets no address | Make sure tethering is actually on at the device side; use `--stats 1000` to see whether TX frames go out and RX frames come back |
| Interface is configured but there is no connectivity | The default route still points at the old interface. `sudo route -n change default $(ipconfig getoption feth0 router)` — note this displaces the existing default route |
| Throughput far below expectations | Check the "device aggregation limit N packets" and "link batch write" lines in the startup log, then work through the checklist in [docs/PERFORMANCE.md](docs/PERFORMANCE.md) |
| The interface is gone after a reboot | `ipconfig set` creates a **temporary** service that only lives until the next network configuration change, and never appears in System Settings. That is a macOS limitation, not a bug |

### Questions people usually arrive with

**Does Android USB tethering work on macOS at all?**
Not out of the box — macOS ships no RNDIS driver, so an Android phone in USB tethering mode
simply produces no network interface. That is what TetherKit adds.

**Do I have to disable SIP, or lower the security policy on Apple Silicon?**
No. Those are requirements of *kernel extensions*. TetherKit is an ordinary program; the
kernel never loads any of its code. The privileged part is a small background component that
needs an admin password once, at install time.

**HoRNDIS shows as "Disabled Software" / has no *Allow* button. Can I fix it?**
That is macOS refusing to load a third-party kext, not something the kext can fix from its
side. On Apple Silicon, loading one at all requires booting into Recovery and lowering the
security policy. TetherKit avoids the whole category of problem.

**Does it work on M1 / M2 / M3 / M4?**
Yes — Apple Silicon and Intel take the same code path. There is nothing architecture-specific
about it beyond ordinary compilation.

**Is my device supported?**
Anything that presents an RNDIS interface: most Android phones with USB tethering enabled,
Windows Phone, and Linux `g_ether`/`u_ether` USB gadgets (Raspberry Pi Zero, BeagleBone …).
Run `tetherkit-cli --list` to check — it needs no root.

**Does iPhone tethering need this?**
No. macOS supports iPhone USB tethering natively; TetherKit is for the devices it does not
cover.

---

## Architecture

```
        ┌──────────────────────────────── macOS kernel ────────────────────────────────┐
        │                                                                              │
        │   IP stack / routing / DHCP client                                           │
        │        │                                                                     │
        │        ▼                                                                     │
        │   ┌─────────┐    if_fake peer pair    ┌─────────┐                            │
        │   │  feth0  │ ◄─────────────────────► │  feth1  │                            │
        │   │(system) │                         │(driver) │                            │
        │   └─────────┘                         └────┬────┘                            │
        │    IP + routes                             │ BPF                             │
        └────────────────────────────────────────────┼─────────────────────────────────┘
                                                     │ read() / write() raw Ethernet frames
        ┌────────────────────────────────────────────┼─────────────────────────────────┐
        │   TetherKit (user space)                   │                                 │
        │                                            ▼                                 │
        │   ┌───────────────────────── data path bridge ─────────────────────────┐     │
        │   │ TX: BPF batch read → coalesce frames → RNDIS_PACKET_MSG → bulk OUT │     │
        │   │ RX: bulk IN → split RNDIS_PACKET_MSG → SPSC queue → BPF write      │     │
        │   └──────────────────────────────────┬─────────────────────────────────┘     │
        │                                      │                                       │
        │   ┌───────── RNDIS state machine ──────────┐                                 │
        │   │ INITIALIZE / QUERY / SET / KEEPALIVE / │                                 │
        │   │ RESET / INDICATE_STATUS / HALT         │                                 │
        │   └────────────────────┬───────────────────┘                                 │
        │                        │                                                     │
        │   ┌───────────────────── libusb ─────────────────────┐                       │
        │   │ control:      SEND_ENCAPSULATED_COMMAND /        │                       │
        │   │               GET_ENCAPSULATED_RESPONSE          │                       │
        │   │ notification: interrupt IN (RESPONSE_AVAILABLE)  │                       │
        │   │ data:         bulk IN / bulk OUT (async, pooled) │                       │
        │   └─────────────────────────┬────────────────────────┘                       │
        └─────────────────────────────┼────────────────────────────────────────────────┘
                                      │ USB
                                ┌─────┴──────┐
                                │RNDIS device│
                                └────────────┘
```

---

## Building from source

Requirements: macOS 13.3+, Xcode command line tools (Apple clang with C++23 support),
CMake ≥ 3.24, libusb 1.0.

```bash
brew install libusb cmake
```

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build -j
```

Output: `build/bin/tetherkit-cli`.

### Building the GUI

Requires the full Xcode toolchain. On top of the build directory above:

```bash
cmake --build build --target gui        # same as ./gui/Scripts/build-gui.sh
open dist/TetherKit.app
```

### Build options

| Option | Default | Description |
|---|---|---|
| `TETHERKIT_BUILD_TESTS` | `ON` | Build unit tests |
| `TETHERKIT_BUILD_BENCHMARKS` | `ON` | Build benchmarks |
| `TETHERKIT_WARNINGS_AS_ERRORS` | `OFF` | Treat warnings as errors |
| `TETHERKIT_NATIVE_ARCH` | `OFF` | `-mcpu=native`; the binary is no longer portable |
| `TETHERKIT_ENABLE_LTO` | `OFF` | Link-time optimization |
| `TETHERKIT_ENABLE_ASAN` | `OFF` | AddressSanitizer |
| `TETHERKIT_ENABLE_UBSAN` | `OFF` | UndefinedBehaviorSanitizer |
| `TETHERKIT_ENABLE_TSAN` | `OFF` | ThreadSanitizer (**required to validate the lock-free structures**) |

### Tests

```bash
ctest --test-dir build --output-on-failure
```

The lock-free queue and the multi-threaded data path are validated separately under
ThreadSanitizer:

```bash
cmake -S . -B build-tsan -DTETHERKIT_ENABLE_TSAN=ON
cmake --build build-tsan -j
ctest --test-dir build-tsan --output-on-failure
```

### Benchmarks

```bash
cmake -S . -B build-rel -DCMAKE_BUILD_TYPE=Release
cmake --build build-rel -j
./build-rel/bin/tetherkit_bench
```

Aggregated results: [docs/BENCHMARKS.md](docs/BENCHMARKS.md).

---

## Documentation

The documents below are written in Chinese.

| Document | Contents |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | **Overall design**: why feth+BPF, module breakdown, concurrency model, teardown ordering, risk assessment of the private ABI |
| [docs/RNDIS-PROTOCOL.md](docs/RNDIS-PROTOCOL.md) | **Protocol reference**: field offsets, status codes, OIDs, state machine, device quirks. Includes the three rules that are easiest to get wrong |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | **Tuning guide**: the knobs, how to identify the bottleneck, known limits |
| [docs/BENCHMARKS.md](docs/BENCHMARKS.md) | **Benchmark results** (auto-generated) + methodology and known limitations |
| [docs/GUI-ARCHITECTURE.md](docs/GUI-ARCHITECTURE.md) | **Graphical interface**: process and trust model, data flow, implementation constraints, what is and is not implemented |
| [docs/GUI-SPIKE.md](docs/GUI-SPIKE.md) | **Feasibility spike**: why privilege escalation is done this way, and the three routes that were ruled out |
| [AGENTS.md](AGENTS.md) | Implementation notes: verified facts about the environment, progress, **pitfalls hit along the way**, and the to-be-verified checklist |

---

## License

See [LICENSE](LICENSE).
