#!/usr/bin/env python3
"""Guest helper regression tests. Run as a non-root user; no network or PAT needed."""
import os
import pty
import select
import subprocess
import tempfile
import unittest
from pathlib import Path

VM = Path(__file__).resolve().parents[1]


class GuestTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)
        self.bin = self.home / "bin"
        self.bin.mkdir()
        self.env = dict(HOME=tmp.name, PATH=f"{self.bin}:/usr/bin:/bin",
                        GIT_CONFIG_NOSYSTEM="1", GIT_ALLOW_PROTOCOL="file")

    def script(self, path, body):
        path.write_text("#!/bin/sh\nset -eu\n" + body)
        path.chmod(0o755)

    def cmd(self, *args, stdin="", check=True, **env):
        return subprocess.run(args, env=self.env | env, cwd=self.home, text=True,
                              input=stdin, capture_output=True, check=check, timeout=10)

    def fixture(self, name, files):
        src = self.home / f"src-{name}"
        self.cmd("git", "init", "-b", "main", src)
        for filename, body in files.items():
            path = src / filename
            path.parent.mkdir(parents=True, exist_ok=True)
            self.script(path, body)
        self.cmd("git", "-C", src, "add", ".")
        self.cmd("git", "-C", src, "-c", "user.name=test", "-c", "user.email=test@example.invalid",
                 "commit", "-m", "fixture")
        url = f"https://example.invalid/{name}"
        self.cmd("git", "config", "--global", f"url.{src.as_uri()}.insteadOf", url)
        return src, {f"{name.upper()}_REPO": url}

    def test_dotfiles_and_skill_ref(self):
        self.script(self.bin / "zsh", "exit 0\n")
        self.script(self.bin / "nvim", "exit 0\n")
        env = {}
        (self.home / ".zshrc").write_text("existing\n")
        for group in ("dotzsh", "dotvim", "dotclaude"):
            repo, override = self.fixture(group, {"install.sh": f"""
test "$KEEP_ZSHRC" = yes
test "$PWD" = "$HOME/dev/{group}"
touch "$HOME/{group}-installed"
"""})
            self.cmd("git", "-C", repo, "tag", "stable")
            env.update(override, **{f"{group.upper()}_REF": "stable"})
        for _ in range(2):
            self.cmd(VM / "guest-personal.sh", "dotzsh", "dotvim", "dotclaude", **env)
        self.assertTrue(all((self.home / f"{g}-installed").exists() for g in ("dotzsh", "dotvim", "dotclaude")))
        self.assertEqual((self.home / ".zshrc").read_text(), "existing\n")
        for change in (dict(DOTVIM_REF="missing"), dict(DOTVIM_REPO="https://example.invalid/else")):
            result = self.cmd(VM / "guest-personal.sh", "dotvim", check=False, **(env | change))
            self.assertNotEqual(result.returncode, 0)

    def test_gstack_requires_working_browser(self):
        for name in ("bun", "sudo"):
            self.script(self.bin / name, "exit 1\n")
        self.script(self.bin / "node", 'echo "$*" >> "$HOME/steps"\n')
        _, env = self.fixture("gstack", {
            "setup": 'echo "$*" >> "$HOME/steps"\n',
            "browse/dist/browse": 'echo "$*" >> "$HOME/steps"; test -f "$HOME/browse-ok"\n',
            "bin/gstack-browser-ensure": 'echo "$*" >> "$HOME/steps"; test -f "$HOME/render-ok"\n',
        })
        r = self.cmd(VM / "guest-personal.sh", "gstack", check=False, **env)
        self.assertNotEqual(r.returncode, 0)
        (self.home / "render-ok").touch()
        r = self.cmd(VM / "guest-personal.sh", "gstack", check=False, **env)
        self.assertNotEqual(r.returncode, 0)
        (self.home / "browse-ok").touch()
        self.cmd(VM / "guest-personal.sh", "gstack", **env)
        steps = ["--host claude --no-browser", "node_modules/playwright/cli.js install-deps chromium",
                 "node_modules/playwright/cli.js install chromium", "--check"]
        self.assertEqual((self.home / "steps").read_text().splitlines(),
                         steps + (steps + ["goto about:blank"]) * 2)

    def fake_gh(self):
        self.script(self.bin / "gh", """
test -z "${GH_TOKEN+x}${GITHUB_TOKEN+x}"
echo "$2" >> "$HOME/calls"
case "$*" in
  "auth token --hostname github.com") test -f "$HOME/stored" ;;
  "auth login --hostname github.com --git-protocol https --with-token")
    [ "$(cat)" = dummy-test-input ] && touch "$HOME/stored" ;;
  "auth setup-git --hostname github.com") test ! -f "$HOME/fail-setup" ;;
  *) exit 9 ;;
esac
""")

    def test_auth_inputs_and_errors(self):
        self.fake_gh()
        helper = VM / "gh-auth-setup"
        self.assertIn("Skipped", self.cmd(helper).stderr)
        self.assertFalse((self.home / "stored").exists())
        self.assertNotEqual(self.cmd(helper, stdin="wrong", check=False).returncode, 0)
        for stdin, env in [
            ("dummy-test-input\n", dict(GH_TOKEN="unused")),
            ("", dict(GH_TOKEN="dummy-test-input", GITHUB_TOKEN="unused")),
            ("", dict(GITHUB_TOKEN="dummy-test-input")),
        ]:
            r = self.cmd(helper, stdin=stdin, **env)
            self.assertNotIn("dummy-test-input", r.stdout + r.stderr)
            self.assertTrue((self.home / "stored").exists())
            (self.home / "stored").unlink()
        (self.home / "fail-setup").touch()
        self.assertNotEqual(self.cmd(helper, stdin="dummy-test-input", check=False).returncode, 0)
        (self.home / "fail-setup").unlink()
        self.cmd(helper)
        self.assertEqual((self.home / "calls").read_text().splitlines()[-2:], ["token", "setup-git"])

    def test_auth_prompt_does_not_echo(self):
        self.fake_gh()
        master, slave = pty.openpty()
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)
        proc = subprocess.Popen([VM / "gh-auth-setup"], env=self.env, cwd=self.home,
                                stdin=slave, stdout=slave, stderr=slave)
        try:
            self.assertTrue(select.select([master], [], [], 5)[0])
            prompt = os.read(master, 1024)
            self.assertIn(b"PAT", prompt)
            os.write(master, b"dummy-test-input\n")
            self.assertEqual(proc.wait(timeout=5), 0)
            self.assertNotIn(b"dummy-test-input", os.read(master, 1024))
        finally:
            proc.kill()
            proc.wait()


if __name__ == "__main__":
    if os.geteuid() == 0:
        raise SystemExit("Run as a non-root user, like the guest commands.")
    unittest.main()
