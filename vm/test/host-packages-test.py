#!/usr/bin/python3
"""Offline host preflight regression tests: /usr/bin/python3 -B vm/test/host-packages-test.py"""
import contextlib
import importlib.util
import io
import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace as Record
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "preflight", Path(__file__).resolve().parents[1] / "host" / "check-packages.py"
)
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)
preflight.apt_pkg.init_system()

ZABBLY = Record(trusted=True, site="pkgs.zabbly.com", origin="pkgs.zabbly.com",
                label="incus-stable", archive="noble")
UBUNTU = Record(trusted=True, site="mirror.example", origin="Ubuntu", label="Ubuntu", archive="noble")
STATUS = Record(trusted=False, site="", origin="", label="", archive="now")


def version(number, *origins):
    return Record(version=number, origins=list(origins))


def package(current, candidate=None, newer=None):
    return Record(is_installed=True, installed=current, name="incus", fullname="incus:amd64",
                  candidate=candidate or current, versions=[newer or current, current],
                  is_now_broken=False)


class PackageTests(unittest.TestCase):
    def check(self, pkg, state="installed ok"):
        with patch.object(preflight.subprocess, "check_output", return_value=state):
            return preflight.check_package({"incus": pkg}, "incus", minimum="7.5.1")

    def test_unconfigured_package(self):
        with self.assertRaisesRegex(ValueError, "incomplete dpkg installation"):
            self.check(package(version("7.6", ZABBLY)), state="unpacked ok")

    def test_current_distro_and_zabbly_sources(self):
        for source in [UBUNTU, ZABBLY]:
            with self.subTest(site=source.site):
                self.assertIn(source.site, self.check(package(version("1:7.5.1-1", STATUS, source))))

    def test_old_epoch_version(self):
        with self.assertRaisesRegex(ValueError, "need >= 7.5.1"):
            self.check(package(version("2:6.0.0-4", UBUNTU)))

    def test_new_candidate(self):
        with self.assertRaisesRegex(ValueError, "candidate 7.6"):
            self.check(package(version("7.5.1", ZABBLY), candidate=version("7.6", ZABBLY)))

    def test_pinned_old_version(self):
        with self.assertRaisesRegex(ValueError, "repository offers 7.6"):
            self.check(package(version("7.5.1", ZABBLY), newer=version("7.6", ZABBLY)))

    def test_local_or_ambiguous_version(self):
        for origins in [(STATUS,), (ZABBLY, Record(**{**vars(ZABBLY), "label": "incus-daily"})),
                        (Record(**{**vars(ZABBLY), "site": "unrelated.example"}),),
                        (Record(**{**vars(UBUNTU), "trusted": False}),)]:
            with self.subTest(origins=origins), self.assertRaisesRegex(ValueError, "supported repository"):
                self.check(package(version("7.6", *origins)))

    def test_missing_server(self):
        with self.assertRaisesRegex(ValueError, "not installed"):
            preflight.check_package({"incus-client": package(version("7.6", ZABBLY))}, "incus")

    def test_full_dnsmasq(self):
        with patch.object(preflight.apt, "Cache", return_value={"dnsmasq": Record(is_installed=True)}), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(preflight.main(), 1)
            self.assertIn("FAIL dnsmasq: full service installed", out.getvalue())

    def test_unowned_or_modified_command_not_executed(self):
        pkg = Record(name="incus-client", fullname="incus-client:amd64")
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            binary = root / "incus"
            marker = root / "called"
            binary.write_text(f"#!/bin/sh\n: > {marker}\n")
            binary.chmod(0o755)
            for recorded, reason in [("opt/incus/bin/incus", "not the binary"),
                                     (str(binary).lstrip("/"), "differs")]:
                sums = Record(stdout=f"{'0' * 32}  {recorded}\n")
                with self.subTest(recorded=recorded), patch.dict(os.environ, PATH=temp), \
                        patch.object(preflight.subprocess, "run", return_value=sums), \
                        self.assertRaisesRegex(ValueError, reason):
                    preflight.check_binary(pkg, "incus")
            self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
