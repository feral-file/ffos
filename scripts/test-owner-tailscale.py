#!/usr/bin/env python3
"""Exercise enrollment and revocation without changing the host network."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'archiso-ff1/airootfs/usr/local/bin/feral-tailscale'


class OwnerAccess(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(self.path / 'key')], check=True)

    def run_helper(self, body, check=True):
        script = '''source "$1"
STATE_DIR="$2/state"
ROOT_MARKER="$2/root/owner-enabled"
mkdir -p "$2/root"
require_installed_root() { :; }
require_root() { :; }
systemctl() { printf 'systemctl %s\\n' "$*" >> "$2_UNUSED"; }
'''
        # Every external side effect has an observable stub. Source functions
        # use real files, validation, atomic writes and removal in the sandbox.
        script = script.replace('"$2_UNUSED"', '"' + str(self.path / 'calls') + '"')
        script += '''nft() { cat > "''' + str(self.path / 'rules') + '''"; }
tailscale() { printf 'tailscale %s\\n' "$*" >> "''' + str(self.path / 'calls') + '''"; }
timeout() { shift; "$@"; }
''' + body
        return subprocess.run(['bash', '-eu', '-c', script, 'test', str(HELPER), str(self.path)], text=True, capture_output=True, check=check)

    def test_invalid_peer_cannot_enroll(self):
        for peer in ['192.168.1.2', '100.63.1.1', '100.128.1.1', '100.64.256.1', '100.064.1.2', '100.64.1.2;accept', '']:
            with self.subTest(peer=peer):
                r = self.run_helper('enroll ' + "'" + peer + "'" + ' "$2/key.pub"', check=False)
                self.assertNotEqual(r.returncode, 0)
                self.assertFalse((self.path / 'state/enabled').exists())

    def test_enrollment_validates_key_before_writing(self):
        (self.path / 'bad.pub').write_text('ssh-ed25519 garbage\n')
        r = self.run_helper('enroll 100.100.1.2 "$2/bad.pub"', check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((self.path / 'state/enabled').exists())

    def test_enrollment_and_reboot_preserve_identity(self):
        self.run_helper('enroll 100.100.1.2 "$2/key.pub"; printf secret > "$STATE_DIR/tailscaled.state"; boot')
        self.assertEqual((self.path / 'state/tailscaled.state').read_text(), 'secret')
        self.assertEqual((self.path / 'state').stat().st_mode & 0o777, 0o700)
        calls = (self.path / 'calls').read_text()
        for flag in ['--accept-dns=false', '--accept-routes=false', '--ssh=false', '--advertise-exit-node=false', '--exit-node=']:
            self.assertIn(flag, calls)
        rules = (self.path / 'rules').read_text()
        self.assertIn('ip saddr 100.100.1.2 tcp dport { 1111, 2222 } accept', rules)
        self.assertIn('iifname "tailscale0" drop', rules)
        self.assertIn('tcp dport 2222 drop', rules)
        self.assertNotIn('flush ruleset', rules)

    def test_authorized_key_only_for_feralfile(self):
        result = self.run_helper('enroll 100.100.1.2 "$2/key.pub"; authorized_key feralfile')
        self.assertIn('from="100.100.1.2",restrict,pty ssh-ed25519 ', result.stdout)
        result = self.run_helper('authorized_key root')
        self.assertEqual(result.stdout, '')

    def test_revocation_survives_restored_root_marker(self):
        result = self.run_helper('enroll 100.100.1.2 "$2/key.pub"; reset_access; touch "$ROOT_MARKER"; boot; authorized_key feralfile')
        self.assertNotIn('ssh-ed25519', result.stdout)
        self.assertFalse((self.path / 'state/enabled').exists())
        self.assertNotIn('ip saddr', (self.path / 'rules').read_text())

    def test_factory_root_does_not_reuse_shared_identity(self):
        self.run_helper('enroll 100.100.1.2 "$2/key.pub"; printf secret > "$STATE_DIR/tailscaled.state"; rm "$ROOT_MARKER"; boot')
        self.assertFalse((self.path / 'state/tailscaled.state').exists())
        self.assertNotIn('ip saddr', (self.path / 'rules').read_text())

    def test_logout_failure_still_revokes(self):
        self.run_helper('enroll 100.100.1.2 "$2/key.pub"; tailscale() { return 1; }; reset_access')
        self.assertFalse((self.path / 'state').exists())
        self.assertFalse((self.path / 'root/owner-enabled').exists())

    def test_failed_stop_does_not_erase_live_daemon_state(self):
        r = self.run_helper('enroll 100.100.1.2 "$2/key.pub"; systemctl() { return 1; }; reset_access', check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((self.path / 'state/enabled').exists())
        self.assertTrue((self.path / 'state').exists())
        self.assertNotIn('ip saddr', (self.path / 'rules').read_text())

    def test_reenrollment_requires_disconnect(self):
        self.run_helper('enroll 100.100.1.2 "$2/key.pub"')
        r = self.run_helper('enroll 100.100.1.3 "$2/key.pub"', check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual((self.path / 'state/owner-ip').read_text().strip(), '100.100.1.2')


class ImageWiring(unittest.TestCase):
    def test_reset_paths_revoke_before_restoring_roots(self):
        reset = (ROOT / 'archiso-ff1/airootfs/root/scripts/factory_reset.sh').read_text()
        self.assertLess(reset.index('/usr/local/bin/feral-tailscale reset'), reset.index('btrfs subvolume snapshot'))
        hook = (ROOT / 'archiso-ff1/airootfs/etc/initcpio/hooks/btrfs-rollback').read_text()
        self.assertLess(hook.index('rm -rf /run/rollback/@snapshots/.tailscale'), hook.index('btrfs subvolume set-default'))

    def test_daemons_require_guard_and_optional_enrollment(self):
        units = ROOT / 'archiso-ff1/airootfs/etc/systemd/system'
        for path in [units / 'tailscaled.service.d/10-feral-owner.conf', units / 'feral-owner-ssh.service']:
            body = path.read_text()
            self.assertIn('Requires=feral-owner-guard.service', body)
            self.assertIn('After=feral-owner-guard.service', body)
            self.assertIn('ConditionPathExists=/.snapshots/.tailscale/enabled', body)
            self.assertIn('ExecStartPre=/usr/local/bin/feral-tailscale guard', body)

    def test_image_contains_no_identity(self):
        image = ROOT / 'archiso-ff1/airootfs'
        for path in ['.snapshots/.tailscale', 'var/lib/tailscale/tailscaled.state', 'home/feralfile/.state/tailscale-owner-enabled']:
            self.assertFalse((image / path).exists(), path)
        updater = (image / 'root/scripts/feral-system-update.sh').read_text()
        exclude = next(line for line in updater.splitlines() if '--exclude=' in line)
        self.assertIn('"/.snapshots/*"', exclude)
        self.assertIn('"/home/feralfile/.state"', exclude)


if __name__ == '__main__':
    unittest.main()
