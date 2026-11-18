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

    def assertAdvisory(self, result, status):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"{status}  host VS Code Remote-SSH settings (advisory", result.stdout)
        self.assertNotIn("FAIL", result.stdout + result.stderr)

    def test_skips_without_vscode(self):
        self.assertAdvisory(self.doctor(), "SKIP")

    def test_default_profile_with_jsonc(self):
        self.write("settings.json", REQUIRED)
        result = self.doctor()
        self.assertAdvisory(result, "INFO")
        self.assertIn("profile 'Default' sets all required values", result.stdout)
        self.assertIn("cannot tell which profile a connection uses", result.stdout)

    def test_unconfigured_vscode_does_not_fail_doctor(self):
        self.write("settings.json", '{"remote.autoForwardPorts": false, "git.terminalAuthentication": true}')
        result = self.doctor()
        self.assertAdvisory(result, "WARN")
        for key in ("git.terminalAuthentication", "github.gitAuthentication", "git.useIntegratedAskPass"):
            self.assertIn(f'"{key}": false', result.stdout)
        self.assertNotIn('"remote.autoForwardPorts": false', result.stdout)

    def test_dedicated_profile_by_name(self):
        self.write("settings.json", "{}")
        self.write("profiles/-1a2b/settings.json", REQUIRED)
        self.write("globalStorage/storage.json",
                   json.dumps({"userDataProfiles": [{"location": "-1a2b", "name": "devvm"}]}))
        result = self.doctor()
        self.assertAdvisory(result, "INFO")
        self.assertIn("profile 'devvm' sets all required values", result.stdout)
        self.assertIn("profile 'Default' needs:", result.stdout)

    def test_separate_user_data_dir(self):
        self.user = self.config / "devvm-vscode" / "User"
        self.write("settings.json", REQUIRED)
        result = self.doctor()
        self.assertAdvisory(result, "INFO")
        self.assertIn("devvm-vscode profile 'Default' sets all required values", result.stdout)

    def test_unparseable_settings_warn(self):
        self.write("settings.json", '{"remote.autoForwardPorts": false')
        result = self.doctor()
        self.assertAdvisory(result, "WARN")
        self.assertIn("cannot parse", result.stdout)


if __name__ == "__main__":
    unittest.main()
