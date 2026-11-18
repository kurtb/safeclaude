#!/usr/bin/env python3
"""Offline tests of the host VS Code settings check run by devvm doctor."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

VM = Path(__file__).resolve().parents[1]
REQUIRED = """{
  // devvm: no Git credential handoff or port forwarding
  "remote.autoForwardPorts": false,
  "git.terminalAuthentication": false, /* block */
  "github.gitAuthentication": false,
  "git.useIntegratedAskPass": false,
  "url": "https://example.invalid/a//b,}",
}
"""


class VSCodeSettingsTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.config = Path(tmp.name) / "config"
        self.user = self.config / "Code" / "User"

    def write(self, rel, text):
        path = self.user / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def doctor(self):
        script = 'source "$1/lib/doctor.sh"; failed=0; VMDIR="$1"; check_vscode_settings; exit "$failed"'
        return subprocess.run(["bash", "-c", script, "_", str(VM)], text=True, capture_output=True,
                              env={"PATH": "/usr/bin:/bin", "HOME": "/nonexistent",
                                   "XDG_CONFIG_HOME": str(self.config)}, timeout=10)

    def test_skips_without_vscode(self):
        result = self.doctor()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SKIP  host VS Code settings", result.stdout)

    def test_default_profile_with_jsonc(self):
        self.write("settings.json", REQUIRED)
        result = self.doctor()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("OK    a host VS Code profile", result.stdout)
        self.assertIn("profile 'Default' sets all required values", result.stdout)

    def test_missing_and_true_values_fail(self):
        self.write("settings.json", '{"remote.autoForwardPorts": false, "git.terminalAuthentication": true}')
        result = self.doctor()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("FAIL  a host VS Code profile", result.stderr)
        for key in ("git.terminalAuthentication", "github.gitAuthentication", "git.useIntegratedAskPass"):
            self.assertIn(f'"{key}": false', result.stderr)
        self.assertNotIn('"remote.autoForwardPorts": false', result.stderr)

    def test_dedicated_profile_by_name(self):
        self.write("settings.json", "{}")
        self.write("profiles/-1a2b/settings.json", REQUIRED)
        self.write("globalStorage/storage.json",
                   json.dumps({"userDataProfiles": [{"location": "-1a2b", "name": "devvm"}]}))
        result = self.doctor()
        self.assertIn("OK    a host VS Code profile", result.stdout)
        self.assertIn("profile 'devvm' sets all required values", result.stdout)
        self.assertIn("profile 'Default' needs:", result.stderr)

    def test_unparseable_settings_fail(self):
        self.write("settings.json", '{"remote.autoForwardPorts": false')
        result = self.doctor()
        self.assertIn("cannot parse", result.stderr)
        self.assertIn("FAIL  a host VS Code profile", result.stderr)



if __name__ == "__main__":
    unittest.main()
