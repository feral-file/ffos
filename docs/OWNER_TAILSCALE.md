# Owner access over Tailscale (pilot)

Status: implementation for a development-image pilot. No production version or
hardware validation is claimed. Ship through a full FFOS image; installing a
component package alone cannot deliver these units, firewall rules or reset hooks.

## Behavior and boundaries

The owner's existing coding agent runs on their own Tailscale-connected computer.
That computer reaches the FF1's existing HTTP control API on port 1111 and an
independent OpenSSH owner listener on port 2222. The owner explicitly enrolls
one computer's Tailscale IPv4 address and SSH public key. Its grant lasts until
revocation or factory reset; it survives reboot and full-image OTA. Recovery
works independently of the player and controld when the OS and network work.

Port 1111 is an administrative interface, including reset and SSH authorization.
The authorized `feralfile` account already has sudo privileges. Enroll only the
owner's trusted computer. The device firewall rejects other Tailscale peers,
IPv6 access, other inbound tailnet ports, forwarding, and port 2222 on LAN/WAN.
The owner listener permits only `feralfile`, public-key authentication and the
registered source IPv4; forwarding and user SSH rc scripts are disabled.

Normal support SSH remains controlled by `ff-cli ssh enable --ttl …` on port 22.
It does not enroll or revoke owner access. Existing support expiry uses a global
`pkill -u feralfile sshd`; it may interrupt an open owner session, but cannot
remove its key or stop the owner listener. Reconnect on port 2222 if that occurs.
Do not describe `ff-cli ssh disable` as revoking the persistent owner grant.

Tailscale SSH is disabled. The FF1 accepts neither tailnet DNS nor subnet routes,
uses no exit node and advertises no routes. Playback, Wi-Fi setup and local
control do not depend on Tailscale. An agent running in the cloud needs its own
network path; the owner's phone running Tailscale does not supply that path.

## Enroll while local

Install the development image on an explicitly selected pilot FF1 first. On the
computer that runs the agent, inspect `tailscale ip -4` and use an existing SSH
key (or generate one without overwriting an existing key). Keep the private key
on that computer. Confirm the FF1's physical ID and LAN SSH host fingerprint.

Use the existing temporary support grant for bootstrap:

```sh
ff-cli ssh enable --pubkey ~/.ssh/id_ed25519.pub --ttl 30m -d "<device-name>"
scp ~/.ssh/id_ed25519.pub feralfile@<ff1-lan-address>:/tmp/owner-key.pub
ssh -t feralfile@<ff1-lan-address> \
  'sudo feral-tailscale enroll <computer-tailscale-ipv4> /tmp/owner-key.pub'
```

The owner completes the Tailscale login URL in their own browser and account.
If an update is running, enrollment exits before creating a grant; retry after
the update finishes and the FF1 returns. The updater lock covers only the durable
grant write, so waiting for browser authentication does not block updates.
No auth key or enrolled identity goes into an image, repository or shared log.
If login takes longer than five minutes, finish authentication and run
`sudo feral-tailscale connect` over LAN to retry. Inspect
`sudo feral-tailscale status` and `tailscale ip -4` on the FF1. Verify the SSH
host key for `[<ff1-tailscale-ipv4>]:2222` against the same installed FF1's host
key, already verified over LAN; do not disable host-key checking.

The tailnet policy must also permit the agent computer to reach this FF1 on
TCP 1111 and 2222. Review existing broad allow rules: adding a narrower grant
does not cancel them. A minimal grant has this shape (replace both addresses):

```json
{"grants":[{"src":["100.100.1.2"],"dst":["100.100.1.3"],"ip":["tcp:1111","tcp:2222"]}]}
```

Merge the relevant grant into the owner's policy; do not replace their whole
policy. The device allowlist is an additional restriction even on a permissive
tailnet. Test with an unauthorized peer before calling the pilot ready.

For unattended FF1 access, disable key expiry **for this FF1** in the owner's
Tailscale admin console after enrollment. Node credential expiry is separate
from the persistent SSH grant; an expired FF1 node key can require local
reauthentication. Do not change expiry for their other devices. See
[Tailscale's key-expiry instructions](https://tailscale.com/kb/1028/key-expiry).

## Use the existing agent and CLI

No remote Bonjour discovery is expected. Save the original configured host,
keep the same physical ID and friendly name, then update that row explicitly:

```sh
ff-cli device add --host http://<ff1-tailscale-ipv4>:1111 \
  --name "<existing-device-name>" --id <physical-FF1-ID>
ff-cli config validate
curl --fail --max-time 10 http://<ff1-tailscale-ipv4>:1111/api/status
ssh -p 2222 -i ~/.ssh/id_ed25519 feralfile@<ff1-tailscale-ipv4> \
  'journalctl --user -u feral-controld -n 80 --no-pager'
```

`device add` replaces that device's configured host; it does not create automatic
LAN/Tailscale failover. Keep its physical ID so the relayer credential remains
associated with the same device. `ff-cli status` describes CLI configuration,
not live FF1 health. Use the status API and actual SSH command results as proof.

For an authorized controld repair:

```sh
ssh -p 2222 -i ~/.ssh/id_ed25519 feralfile@<ff1-tailscale-ipv4> \
  'systemctl --user restart feral-controld.service'
```

This can interrupt device control. Pairing approvals still belong to the owner;
remote shell access does not substitute for an approval.

## Revoke and transfer

```sh
sudo feral-tailscale disconnect
```

Disconnect runs in a detached system service, because it closes the very SSH
session that may request it. It removes the durable enable markers, applies a
deny-all tailnet input policy, attempts bounded logout, stops both owner network
services, and erases local Tailscale identity and the owner public key. Inspect
`journalctl -u feral-owner-disconnect.service` locally for the result. Logout
failure does not preserve local access; also remove the device from the Tailscale
admin console. Enrollment after disconnect requires local access again.

For a lost agent computer, revoke that computer in the Tailscale admin console
immediately. For transfer, factory-reset the FF1 and remove its old tailnet entry;
the recipient enrolls afresh. Reset revokes before staging a replacement root,
so a failed candidate boot cannot restore the old owner's access.

For an explicitly authorized factory reset from owner SSH, use
`sudo systemctl start --no-block set-factory-boot.service`. The reset continues
in its own service after revocation closes the SSH session. Direct invocation of
`sudo /root/scripts/factory_reset.sh` dispatches to the same service. Inspect
`journalctl -u set-factory-boot.service` locally if reset does not complete.

## Persistence and failure ordering

`/.snapshots/.tailscale/` is root-only state on the existing `@snapshots` mount,
outside all root snapshots. It contains daemon state, the owner address/public
key and an `enabled` file. Nothing lives in `/var/lib/tailscale`. A marker at
`/home/feralfile/.state/tailscale-owner-enabled` ties access to the installed root;
that directory is already preserved even by older full-image updater scripts.
An OTA snapshot copies the marker but never copies identity. Revoking shared
state defeats an old root marker. Booting a factory root without the marker
clears leftover shared identity before starting either daemon. Both the running
factory-reset script and the initramfs factory-rollback hook erase shared state,
including when the restored factory image predates this feature.

`feral-owner-guard.service` loads only `inet feral_owner`. It must succeed before
tailscaled or owner SSH starts. Each daemon start re-applies the guard. Captive
portal reload/stop touches only `ip feral_captive`; neither operation flushes
Tailscale or NetworkManager tables. Owner services are optional dependencies of
multi-user startup, never prerequisites for the kiosk or provisioning services.

## Verification and release proof

Run `make verify` for lifecycle tests, image wiring checks, syntax and ShellCheck.
Run `scripts/test-owner-firewall.sh` inside an isolated user/network namespace
for real nftables load/reload/stop and packet-acceptance tests. Neither command
proves hardware update, boot ordering or remote recovery.

Before merging for release, record a development-image pilot demonstrating:

- Enrolled agent on a different network: read diagnostics; perform one authorized
  maintenance action; stop controld, open a **new** owner SSH connection and
  restart controld. Test a wrong key, another tailnet peer and the LAN on 2222.
- Reboot and full-image update preserve identity/key and access; a failed OTA
  candidate's fallback cannot resurrect access revoked after its snapshot.
- Disconnect and both app-triggered and power-cycle factory reset remove access;
  repeat with a factory image predating Tailscale and with the network offline.
- Captive portal works through firewall/Tailscale restarts; playback, downloads
  and Wi-Fi provisioning work with tailscaled stopped or unable to authenticate.
- Verify SSH sessions close on disconnect, and inspect image contents to confirm
  there is no owner identity, enable marker or public key embedded in the image.

Development build and physical-device evidence are required before representing
this as a released or hardware-tested feature. Staging/production promotion and
production image publishing remain the human release operator's steps.
