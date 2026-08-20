# FF1 Device life cycle

## App flows

### App startup

```mermaid
flowchart TD
    FF1Start[FF1 Start] --> Provision(feral-controld: provisioning)
    Provision --> HasInternet{Has Internet}

    HasInternet --> |No| HasLink{Has link:<br/>ethernet or<br/>Wi-Fi association}
    HasLink --> |Yes, claimed| LinkSuppress(Keep retrying;<br/>AP suppressed)
    LinkSuppress --> |Recheck| HasInternet
    HasLink --> |Yes, unclaimed,<br/>Wi-Fi, no wire| Episode(Setup-incomplete episode:<br/>5-min window, then bounded AP<br/>sessions + 5/10/20-min station ladder)
    Episode --> |WAN returns, or<br/>claimed over LAN| HasInternet
    Episode --> |4 AP cycles,<br/>no progress| Settled(Settled in station mode;<br/>LAN pairing still works)
    Settled --> |Link lost| OfflineWindow
    HasLink --> |No,<br/>unprovisioned| SoftAP(Raise SoftAP + captive portal)
    HasLink --> |No,<br/>provisioned| OfflineWindow(Arm 5-min<br/>sustained-offline window)
    OfflineWindow --> |Still offline + no link<br/>at expiry| SoftAP
    OfflineWindow --> |Back online| HasInternet
    HasInternet --> |Yes| UpToDate1{Up to date}

    UpToDate1 --> |No| Update(Update to latest version)
    UpToDate1 --> |Yes| Paired{Has been claimed}
    Update --> |Restart| FF1Start
    Paired --> |No| ClaimQR(Display claim QR)
    Paired --> |Yes| Artwork(Artwork Playback)
    ClaimQR --> |Phone binds topic via cloud| Artwork

    App[App command:<br/>startWifiSetup] --> |30-min bounded session| SoftAP
    SoftAP --> |Phone joins AP,<br/>submits Wi-Fi in portal| Join(Join network, tear down AP)
    SoftAP --> |Every 30 min on<br/>sustained-offline raises| Recheck(Station blink: forced<br/>reactivation of saved profiles)
    Recheck --> |Reassociated| HasInternet
    Recheck --> |Still gone| SoftAP
    Join --> |Success| HasInternet
    Join --> |Failure| SoftAP
```

### AP session policy and network escape cadence

Since the network-recovery work (canonical rules in ffos-user
`docs/setup-flow.md`; API surface in its `docs/api-design.md`), a raised
setup AP carries a session policy latched from its raise reason, and
"link alive but useless" states have their own escape:

| Raise reason | Session |
| :- | :- |
| `unprovisioned` (out-of-box) | Unbounded, no recheck — nothing saved to reactivate. |
| `sustained-offline` / `relocated` | Unbounded cycles: AP up 30 min, then a brief station "recheck blink" that force-reactivates saved in-range profiles; a recovered network is noticed within one cycle. |
| `setup-incomplete` (unclaimed, live Wi-Fi link, no internet, no ethernet) | Bounded episode: 5-min window, 5-min AP sessions, escalating 5/10/20-min station phases; after 4 cycles the device settles in station mode where LAN pairing/`startWifiSetup` still work. Claimed devices never auto-raise on a live link. |
| `user-requested` (app `startWifiSetup`) | 30 min, then teardown and normal state handling — the abandonment net. Wired devices reject the command with `wired_link_active` instead of raising. |

Session teardowns defer while the captive portal saw a human action within
2 min (+15-min ceiling); bounded sessions additionally carry a 2-hour
absolute cap across portal rescan re-arms. Wired devices never auto-raise,
and a wired-link sighting lowers any raised AP except the out-of-box
`unprovisioned` session (nothing is saved to fall back to, and claiming
works over the cable with the AP still up). The app-visible mirror of all
this is the additive `network` health object on `getDeviceStatus` and the
LAN hub status routes.

### App update

```mermaid
flowchart TD
    Current[Current Version] --> Trouble{Having<br/>trouble}

    Trouble --> |Yes| Reset[Factory Reset]
    Trouble --> |No| Update[Update at 3am]

    Update --> |Restart| Latest

    Reset --> FactoryVersion(Factory Version)
    FactoryVersion --> |Force Update| Latest
```

There is **no last-version rollback**: OTA promotion deletes the previous
root subvolume in early boot, before any userspace health signal exists
(issue #122, accepted trade-off). The only recovery from a bad-but-bootable
version is a factory reset — via the app command when `feral-controld` is
reachable, or via the keyboard-free power-cycle gesture below when it is not.

### Power-cycle factory reset (keyboard-free recovery)

The device ships without a keyboard and the boot menu is hidden
(`timeout 0`, `editor no`), so the `btrfs-rollback` initramfs hook implements
a recovery gesture that needs only the power cord:

1. **Trigger**: cut power (unplug) when the boot screen appears, then plug
   back in. Repeat until **5 consecutive unclean cuts** have accumulated, with
   each boot-to-boot gap at most **120 seconds**.
2. On the next boot the hook arms a one-shot boot of `factory_reset.conf`
   plus a one-shot menu timeout and reboots: systemd-boot shows the menu with
   **FF1 - Factory Reset** selected and a **60-second countdown** on screen.
3. **Waiting out the countdown** runs the factory reset (the existing
   `rollback=factory` initramfs path). **Pulling power during the countdown
   cancels**: systemd-boot consumes both one-shot EFI variables the moment
   the menu is shown, so the next boot is a completely normal boot.

Counting rules (all state lives in `@snapshots/.recovery/` on the btrfs
top level, which survives every subvolume rotation):

- Only **unclean** cuts count. `clean-shutdown-marker.service` writes a flag
  on every orderly shutdown, so app- or watchdog-initiated
  `systemctl reboot`s and normal poweroffs break the chain.
- A boot-to-boot gap over 120 seconds breaks the chain, so isolated real
  power outages never accumulate.
- The gesture is disabled when the RTC is obviously wrong (clock before
  2025): a dead CMOS battery would otherwise make outages weeks apart look
  seconds apart.

Accepted residual risks (decided in issue #122):

- **Unattended trigger**: an extreme power event matching the exact pattern
  (5 cuts, each boot living just long enough to stamp, tight cadence) resets
  an unattended device after the uncancelled countdown. Judged rare after
  excluding clean reboots and utility-recloser timing.
- **No claim protection**: after any factory reset the device can be claimed
  by anyone. A server-side protection can be added later without a firmware
  change.
- **Recovery is a wipe**: setup, claim, and the offline artwork cache are
  lost and must be rebuilt.
- A broken kernel or initramfs takes the gesture down with it; that failure
  class has no self-service recovery (unchanged from before).

### Command Processing Flow

```mermaid
flowchart TD
    %% Command Flow from Mobile
    Mobile[Mobile Controller] --> |Send Command| Relayer[Relayer Service]
    Relayer --> |WebSocket Message| Controld[Controld Service]
    
    %% Command Processing
    Controld --> Mediator[Mediator]
    Mediator --> |Parse Message| Parse{Message Type}
    
    Parse --> |System Message| System[Handle System Message<br/>Save Topic ID]
    Parse --> |Command Message| CmdType{Command Type}
    
    CmdType --> |Device Command| DeviceCmd[Command Handler<br/>Execute Device Commands]
    CmdType --> |Web Command| WebCmd[Chrome DevTools Protocol]
    
    DeviceCmd --> |Available Commands| Commands[Device Commands:<br/>• connect<br/>• showPairingQRCode<br/>• deviceMetrics<br/>• sendKeyboardEvent<br/>• dragGesture<br/>• tapGesture<br/>• rotate<br/>• shutdown<br/>• getDeviceStatus<br/>• updateToLatestVersion<br/>• startWifiSetup]
    
    WebCmd --> |Forward to Browser| Browser[Chromium Browser]
    Browser --> |Execute JavaScript| WebApp[Web Application]
    
    %% Response Flow
    Commands --> |Return Result| Response[Send Response]
    WebApp --> |Return Result| Response
    
    Response --> |RPC Response| Relayer
    Relayer --> |WebSocket Response| Mobile
    
    %% Error Handling
    DeviceCmd --> |Error| Error[Error Response]
    WebCmd --> |Error| Error
    Error --> Response
    
    class Controld,Relayer service
    class Mediator,Commands,Browser,WebApp component
    class Parse,CmdType decision
    class Mobile external
```

## Telemetry (Heartbeat)

All the events should only consider network connected scenario otherwise it can't be sent over heartbeat.

### Device status
| Field | Type | Description |
| :--- | :--- | :--- |
| `Timestamp` | DateTime | The ISO 8601 timestamp (UTC) when the heartbeat was generated. |
| `MAC Address` | String | The unique, immutable MAC address of the network interface. |
| `Build` | String | The current firmware build version (e.g., "develop-0.0.1"). |
| `Screen Info` | String | String detailing screen status (e.g., "1920x1080@60"). |
| `CPU Temp` | Number | The core CPU temperature in Celsius (°C). **Alerts if > 55.** |
| `CPU Usage` | Percent | The current CPU utilization (0.00 to 1.00). **Alerts if > 0.80.** |
| `GPU Usage` | Percent | The current GPU utilization (0.00 to 1.00). **Alerts if > 0.80.** |
| `Memory Usage`| Percent | The percentage of total RAM currently in use (0.00 to 1.00). **Alerts if > 0.80.** |
| `Disk Usage` | Percent | The percentage of total disk storage currently in use (0.00 to 1.00). **Alerts if > 0.80.** |
| `Uptime` | String | The duration the device has been running since last boot, in "D H:M:S" format. |
| `Status` | String | **(Calculated)** "✅ Online" or "❌ Offline". Derived in the spreadsheet, not sent by device. |
| `Public Key` | String | The device's public key for signature verification. |
| `Signature` | String | The payload's cryptographic signature for data integrity. |
| `Page` | String | The on-screen setup state. Owned by `feral-controld` since the setupd merge (the `setupui` narration state; the coarse provisioning state is also exposed as `setup_state` on the LAN hub's `GET /api/status`). |
| `Page Uptime` | String | The duration the device has stayed in the current setup state, in "D H:M:S" format. |

### Setup states

Since the setupd merge, the on-screen setup state is owned by `feral-controld`. These states replace the former setupd page names:

| State | Notes |
| :- | :- |
| `softap_qr` | SoftAP provisioning QR: join `FF1-<device_id>` and open the captive portal (offline unprovisioned, escape-policy raises, or app-triggered `startWifiSetup`). |
| `joining` / `join_failed` | Joining the chosen Wi-Fi network / join failed, AP re-raised for retry. |
| `connecting` | Neutral provisioned-device connectivity narration (boot hedge, offline retry, recheck blink). Extension state: controld downgrades it for players that predate it. |
| `setup_error` | Persistent provisioning failure (setup AP repeatedly failing to start or release); retries continue underneath. Extension state with the same downgrade behavior. |
| `updating` | Firmware update in progress (replaces `SystemUpgrade`). |
| `claim_qr` | Pairing/claim QR shown; network connected and up to date (replaces the pairing `QRCode`). |
| `ready` / `hidden` | Claimed; artwork playback (replaces `WebApp`). |
| `factory_reset` | Device initiated rollback to factory version (replaces `FactoryReset`). |

## Version control

We deploy the firmware versions through 2 main channels:
- Dev channel: https://ffosdev.feralfile.com/
- Prod channel: https://ffos.feralfile.com/

Our versioning follow Semantic Versioning format.

Each channel has API to specific min_version and latest_version. If the current version on the device is older than min_version, it's forced to update. Otherwise, it will update to the latest version silently at 3am.