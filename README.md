# tailscale-awg for Asuswrt-Merlin

Tailscale with **AmneziaWG** support, packaged for **Asuswrt-Merlin 3006 or newer on aarch64**, installed through Entware on a USB drive. Verified on the **ASUS RT-BE92U**; the same binary covers the rest of the modern aarch64 HND line (RT-BE88U, RT-BE98, GT-AX11000 Pro, RT-AX86U, …).

AmneziaWG makes the WireGuard handshake harder to fingerprint, which is the point of this fork over stock Tailscale. The obfuscation lives in the Go source ([LiuTangLei/tailscale](https://github.com/LiuTangLei/tailscale)); this repository cross-compiles it and handles everything ASUSWRT-specific.

> **Stock ASUS firmware is not supported.** Without Merlin there is no `/jffs/scripts` hook execution, so nothing would survive a reboot or a firewall rebuild. The installer refuses to run.

## Requirements

| | |
|---|---|
| Firmware | Asuswrt-Merlin **3006+** (`Administration → Firmware Upgrade` shows the build number) |
| CPU | aarch64 (`uname -m`) |
| Storage | a USB drive, ext4, permanently attached, ≥ 1 GB free |
| Entware | installed on that drive — from the router shell run `amtm`, then pick `ep` |
| JFFS | `Administration → System → Enable JFFS custom scripts and configs` = **Yes**, then reboot |
| Access | SSH enabled (`Administration → System → Enable SSH`) |

Roughly 60 MB of free space on `/opt` and ~60 MB of RAM at runtime.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/leros1337/asuswrt-tailscale-awg/main/install.sh -o /tmp/ts-install.sh
sh /tmp/ts-install.sh install
```

The installer checks the firmware, architecture, JFFS scripts, `/dev/net/tun` and the Entware mount before touching anything, then adds an opkg feed, installs the package, wires up the Merlin hooks, starts the daemon and prints a login URL.

Useful variants:

```sh
sh install.sh install --authkey tskey-auth-...            # unattended
sh install.sh install --advertise-routes 192.168.50.0/24  # subnet router
sh install.sh install --exit-node                         # advertise as exit node
sh install.sh install --direct                            # skip the feed, use GitHub Releases
sh install.sh install --direct --no-upx                   # uncompressed binary (see Troubleshooting)
```

Other commands: `update`, `status`, `logs`, `repair`, `uninstall`.

`uninstall` leaves the node logged out, the hooks stripped from `/jffs/scripts` (byte-for-byte as they were), the firewall rules and `ip rule`s cleaned up, and the package removed — but it **keeps** `/opt/var/lib/tailscale`, so reinstalling does not mean a new machine in your tailnet. Add `--purge` to delete that too. `--yes` skips the prompts but deliberately will not purge; destroying the node identity needs its own flag. `status` is the first thing to run when something looks wrong — it reports every gate, the hook state, the live netfilter rules and `tailscale status` in one page.

Once installed, `tailscale` and `tailscaled` are on `PATH` at `/opt/sbin`.

### Manual install via opkg

```sh
echo 'src/gz tailscale-awg https://leros1337.github.io/asuswrt-tailscale-awg/aarch64-3.10' >> /opt/etc/opkg.conf
opkg update && opkg install tailscale
/opt/etc/tailscale/merlin-hooks.sh install
/opt/etc/init.d/S60tailscaled start
```

The feed is **not signed**: Entware's opkg has no usign support and does not set `check_signature`. Integrity comes from HTTPS plus the per-package `SHA256sum` field in `Packages`, which opkg does verify. Do not add `opkg-key add` steps — they cannot work here.

## What gets installed where

```
/opt/sbin/tailscaled                       the daemon (CLI folded in via ts_include_cli)
/opt/sbin/tailscale -> tailscaled
/opt/etc/init.d/S60tailscaled              service, started by Entware's rc.unslung
/opt/etc/tailscale/tailscaled.conf         your settings (an opkg conffile — survives upgrades)
/opt/etc/tailscale/{merlin-hooks.sh,firewall.sh}
/opt/var/lib/tailscale/tailscaled.state    node identity — on USB, so it survives reboots
/opt/var/log/tailscaled.log                rotated at 2 MB
```

Six Merlin user scripts get a marker-fenced block appended. Existing content is never touched, installing twice never duplicates a block, and `uninstall` restores each file byte-for-byte:

| `/jffs/scripts/…` | why |
|---|---|
| `post-mount` | start the daemon on hand-rolled Entware installs (`rc.unslung` handles the normal case) |
| `services-start` | late safety net if the daemon did not come up |
| `services-stop` | stop cleanly on reboot/shutdown |
| `unmount` | stop before the USB drive holding `/opt` disappears, so state is not truncated |
| `firewall-start` | re-apply rules after Merlin rebuilds the filter table |
| `nat-start` | re-apply rules after Merlin rebuilds the nat table |

Inspect exactly what was added with `grep -A5 'BEGIN tailscale-awg' /jffs/scripts/*`.

## Why `--netfilter-mode=off`

Tailscaled normally installs its own `ts-input` / `ts-forward` / `ts-postrouting` chains. Merlin's `start_firewall` runs `iptables -F; iptables -X` on every WAN event, VPN-client start and firewall setting change, and tailscaled only reconciles on *link* changes — so those chains silently vanish and connectivity degrades in ways that are hard to diagnose.

So the node's `netfilter-mode` preference is set to `off` and [`files/firewall.sh`](files/firewall.sh) owns the rules instead, re-applied from `firewall-start` and `nat-start` (both of which run *after* Merlin finishes rebuilding). Each rule is inserted only when `iptables -C` says it is absent, so repeated calls never stack up.

Measured on an RT-BE92U, before and after a single `service restart_firewall`:

| | before | after |
|---|---|---|
| tailscaled's own `ts-*` rules | 9 | **0** |
| `firewall.sh` rules (filter + nat) | 5 | **5** |

Tailnet connectivity was unaffected (`tailscale ping` still 2–3 ms). That is the whole argument for this design in one table.

Note that `netfilter-mode` is a **`tailscale up` preference, not a `tailscaled` flag** — passing it to the daemon makes it exit with `flag provided but not defined`. The installer reads `NETFILTER_MODE` from `tailscaled.conf` and applies it during `tailscale up`, after which it persists in `tailscaled.state`.

Policy routing (table 52, priorities 5210–5270) is still tailscaled's job — Merlin's firewall rebuild does not touch `ip rule`. Note that Merlin's **VPN Director** uses tables 111–115; there is no numeric collision, but a broadly-matching VPN Director rule can preempt Tailscale routing for a client.

## Subnet router and exit node

```sh
tailscale up --advertise-routes=192.168.50.0/24 --accept-dns=false
```

Then approve the route in the [admin console](https://login.tailscale.com/admin/machines). For an exit node add `--advertise-exit-node` and approve it the same way. `net.ipv4.ip_forward`, `net.ipv6.conf.all.forwarding` and `net.ipv4.conf.all.rp_filter=2` (loose — required for subnet-route return traffic) are re-asserted on every start and every firewall re-apply, because Merlin resets them on WAN up.

Record what you advertised in `/opt/etc/tailscale/tailscaled.conf` (`ADVERTISE_ROUTES`, `EXIT_NODE`) so `install.sh status` can show it.

If forwarding works in one direction only, Broadcom's flow accelerator is probably bypassing netfilter for LAN↔WAN flows. `nvram set ctf_disable=1 && nvram commit && reboot` fixes it at a real throughput cost — decide for yourself; the installer will never do this to you.

## AmneziaWG config sync

`tailscale awg sync` (and `set`/`reset`) applies the obfuscation parameters, then tries to bounce the daemon via `systemctl`, `service tailscaled restart` and `/etc/init.d/tailscale` — none of which exist on Merlin, so it ends with *"Please restart tailscaled manually"*. The config **was** applied; only the restart failed. Finish with:

```sh
/opt/etc/init.d/S60tailscaled restart
```

This package deliberately does not shadow `/etc/init.d` to satisfy that lookup: on ASUSWRT it is a read-only symlink to `/rom/etc/init.d`, which holds the firmware's wlan-driver, nvram and mount-fs boot scripts. Masking that directory to save one command is not a trade worth making.

## Reaching the router's web UI over Tailscale

`https://<tailnet-ip>:8443` does **not** work, and no firewall rule will fix it. ASUSWRT's `httpd` binds to specific addresses only — `127.0.0.1` and the LAN IP — never `0.0.0.0`, so nothing is listening on the Tailscale address:

```
tcp  0  0 127.0.0.1:8443    LISTEN
tcp  0  0 192.168.1.1:8443  LISTEN     <- LAN only
```

Use `tailscale serve` to proxy it from inside tailscaled:

```sh
tailscale serve --bg --http=80 https+insecure://192.168.1.1:8443
```

Then open `http://<hostname>/` from any tailnet device. Plain HTTP is fine here — the traffic is inside the WireGuard tunnel. `https+insecure://` is required because the router's own certificate is self-signed.

For `https://` with a real certificate, enable **HTTPS Certificates** at *login.tailscale.com/admin/dns* first, then:

```sh
tailscale serve --bg --https=443 https+insecure://192.168.1.1:8443
```

Without that setting the daemon logs `your Tailscale account does not support getting TLS certs` and the TLS handshake fails. Two client-side gotchas: `serve` routes on the Host header, so requesting the bare IP returns `404` — use the MagicDNS name; and the client needs `--accept-dns=true` to resolve that name. The serve config lives in `tailscaled.state`, so it survives reboots.

## DNS / MagicDNS

MagicDNS is **off by default** (`--accept-dns=false`). `/etc/resolv.conf` on Merlin is a tmpfs file that dnsmasq rewrites on every WAN event, so letting tailscaled manage it produces a fight that dnsmasq wins.

To get `*.ts.net` resolution the supported Merlin way:

```sh
echo 'server=/ts.net/100.100.100.100' >> /jffs/configs/dnsmasq.conf.add
service restart_dnsmasq
```

## Upgrades and firmware flashes

- `sh install.sh update` — reinstalls the package, re-applies the hooks, restarts the daemon. Node identity is kept; no re-login.
- A **firmware upgrade** leaves `/jffs` and the USB drive intact. Run `install.sh status` afterwards anyway.
- A **factory reset** clears `/jffs` and `jffs2_scripts`. Re-enable JFFS scripts, then `sh install.sh repair` — the package and node identity on USB are still there.

## Troubleshooting

| Symptom | Check |
|---|---|
| anything at all | `sh install.sh status`, then `sh install.sh logs` |
| daemon exits at once | `/opt/var/log/tailscaled.log`; confirm `/dev/net/tun` and free space on `/opt` |
| `Illegal instruction` / dies silently | the UPX-compressed binary may not run on your kernel. `sh install.sh install --direct --no-upx` |
| works until the WAN reconnects | `iptables -S \| grep tailscale0` — if empty, the `firewall-start` hook is missing (`install.sh repair`) |
| nothing after a reboot | `nvram get jffs2_scripts` must be `1`; the USB drive must be attached at boot |
| TLS / certificate errors | `opkg install ca-certificates` |
| `opkg` refuses the package | compare `opkg print-architecture` with `ENTWARE_ARCH` in `.config/tailscale-version` |
| router UI unreachable on the tailnet IP | expected — `httpd` binds to the LAN IP only. See *Reaching the router's web UI over Tailscale* |

## Building

Everything is a plain static Go cross-build — no OpenWrt SDK, no Docker.

```sh
git clone https://github.com/LiuTangLei/tailscale src   # at the tag in .config/tailscale-version
./build/build.sh          # -> out/tailscaled (UPX), out/tailscaled.raw
./build/mkipk.sh          # -> out/tailscale_<ver>-1_aarch64-3.10.ipk
./build/mkindex.sh out    # -> out/Packages, out/Packages.gz
sh tests/hooks_test.sh    # hook idempotency tests
```

The version pin lives in [`.config/tailscale-version`](.config/tailscale-version) and is bumped automatically by `check-version.yml`, which then dispatches `build-asuswrt.yml`.

## Credits and licence

BSD 3-Clause. Lineage: [GuNanOvO/openwrt-tailscale](https://github.com/GuNanOvO/openwrt-tailscale) → [LiuTangLei/openwrt-tailscale-awg](https://github.com/LiuTangLei/openwrt-tailscale-awg) → this repository, which replaces the OpenWrt delivery layer with an Asuswrt-Merlin one. AmneziaWG integration is LiuTangLei's work in [LiuTangLei/tailscale](https://github.com/LiuTangLei/tailscale). Tailscale itself is © Tailscale Inc. — see [`LICENSE.tailscale`](LICENSE.tailscale) and [`NOTICE`](NOTICE). Not affiliated with or endorsed by Tailscale Inc. or ASUSTeK.
