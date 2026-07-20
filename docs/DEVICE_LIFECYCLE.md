# FF1 Device life cycle

## App flows

### App startup

```mermaid
flowchart TD
    FF1Start[FF1 Start] --> Provision(feral-controld: provisioning)
    Provision --> HasInternet{Has Internet}

    HasInternet --> |No, wired link active| WiredSuppress(Keep retrying;<br/>AP suppressed)
    WiredSuppress --> |Recheck| HasInternet
    HasInternet --> |No, no wired link,<br/>unprovisioned| SoftAP(Raise SoftAP + captive portal)
    HasInternet --> |No, no wired link,<br/>provisioned| OfflineWindow(Arm 5-min<br/>sustained-offline window)
    OfflineWindow --> |Still offline<br/>at expiry| SoftAP
    OfflineWindow --> |Back online| HasInternet
    HasInternet --> |Yes| UpToDate1{Up to date}

    UpToDate1 --> |No| Update(Update to latest version)
    UpToDate1 --> |Yes| Paired{Has been claimed}
    Update --> |Restart| FF1Start
    Paired --> |No| ClaimQR(Display claim QR)
    Paired --> |Yes| Artwork(Artwork Playback)
    ClaimQR --> |Phone binds topic via cloud| Artwork

    SoftAP --> |Phone joins AP,<br/>submits Wi-Fi in portal| Join(Join network, tear down AP)
    Join --> |Success| HasInternet
    Join --> |Failure| SoftAP
```

### App update

```mermaid
flowchart TD
    Current[Current Version] --> Trouble{Having<br/>trouble}

    Trouble --> |Yes| Rollback{Choose version<br/>to rollback}
    Trouble --> |No| Update[Update at 3am]

    Update --> |Restart| Latest

    Rollback --> |Fresh| FactoryVersion(Factory Version)
    Rollback --> LastVersion(Last Version)

    FactoryVersion --> |Force Update| Latest
    LastVersion --> |Force Update| Latest
```

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
    
    DeviceCmd --> |Available Commands| Commands[Device Commands:<br/>• connect<br/>• showPairingQRCode<br/>• deviceMetrics<br/>• sendKeyboardEvent<br/>• dragGesture<br/>• tapGesture<br/>• rotate<br/>• shutdown<br/>• getDeviceStatus<br/>• updateToLatestVersion]
    
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
| `softap_qr` | SoftAP provisioning QR: join `FF1-<device_id>` and open the captive portal (offline, unprovisioned). |
| `joining` / `join_failed` | Joining the chosen Wi-Fi network / join failed, AP re-raised for retry. |
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