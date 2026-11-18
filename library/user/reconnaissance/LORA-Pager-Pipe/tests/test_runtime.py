"""Startup checks must not touch hardware or install unrequested packages."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from lpp_test_paths import PAYLOAD_ROOT, PROJECT_ROOT
spec = importlib.util.spec_from_file_location("runtime_cli", PAYLOAD_ROOT / "lpp.py")
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)


class DependencyTests(unittest.TestCase):
    def probe(self, backend="glytch", mode="meshtastic", modules=(), libusb=True):
        output = io.StringIO()
        settings = {"backend": backend, "mode": mode}
        with patch.object(cli, "_module_available", side_effect=lambda name: name in modules), \
                patch.object(cli, "_libusb_available", return_value=libusb) as usb, \
                patch.object(cli, "_usb_present", side_effect=AssertionError("Hardware probe")), \
                patch.object(cli, "_meshtastic_running", side_effect=AssertionError("Process probe")), \
                patch.object(cli, "_crypto_checks", side_effect=AssertionError("Crypto self-test")), \
                patch.object(cli.socket, "create_connection", side_effect=AssertionError("Network probe")), \
                contextlib.redirect_stdout(output):
            self.assertEqual(cli.dependencies(settings), 0)
        return output.getvalue().splitlines(), usb.call_count

    def test_glytch_missing_libusb_has_fixed_required_package(self):
        report, calls = self.probe(modules={"usb.core", "cryptography"}, libusb=False)
        self.assertEqual(report, ["required libusb-1.0-0"])
        self.assertEqual(calls, 1)

    def test_missing_bundled_usb_requires_reinstall_not_package(self):
        report, calls = self.probe(modules={"cryptography"})
        self.assertEqual(report, ["reinstall pyusb"])
        self.assertEqual(calls, 0)

    def test_serial_only_checks_selected_backend(self):
        report, calls = self.probe(backend="lorapipe", modules={"cryptography"})
        self.assertEqual(report, ["required python3-pyserial"])
        self.assertEqual(calls, 0)

    def test_optional_crypto_respects_existing_provider_combinations(self):
        report, _ = self.probe(backend="lorapipe", mode="both", modules={"serial", "Crypto"})
        self.assertEqual(report, ["optional python3-cryptography"])
        report, _ = self.probe(backend="lorapipe", mode="both", modules={"serial", "Crypto", "nacl"})
        self.assertEqual(report, ["ready"])
        report, _ = self.probe(backend="lorapipe", modules={"serial", "Crypto"})
        self.assertEqual(report, ["ready"])

    def test_dependency_cli_does_not_require_a_region_or_print_credentials(self):
        settings = {"backend": "lorapipe", "mode": "meshtastic", "region": "",
                    "uploads": {"wigle": {"api_token": "TEST_PRIVATE_VALUE"}}}
        output = io.StringIO()
        with patch.object(cli.config, "load", return_value=settings), \
                patch.object(cli, "_module_available", return_value=True), \
                contextlib.redirect_stdout(output):
            self.assertEqual(cli.main(["dependencies"]), 0)
        self.assertEqual(output.getvalue(), "ready\n")


class StartupUITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bash = shutil.which("bash")
        if os.name == "nt":
            git_bash = Path("C:/Program Files/Git/bin/bash.exe")
            cls.bash = str(git_bash) if git_bash.exists() else None
        if not cls.bash:
            raise unittest.SkipTest("Bash is unavailable")

    def run_case(self, scenario):
        with tempfile.TemporaryDirectory(prefix="lpp-runtime-test-") as temporary:
            root = Path(temporary)
            source = (PAYLOAD_ROOT / "payload.sh").read_text(encoding="utf8")
            self.assertTrue(source.rstrip().endswith('main "$@"'))
            definitions = root / "payload-functions.sh"
            definitions.write_text(source[:source.rfind('main "$@"')], encoding="utf8", newline="\n")
            result = subprocess.run([self.bash, str(PROJECT_ROOT / "tests/runtime_harness.sh"),
                str(definitions), str(root), str(PAYLOAD_ROOT / "lpp.py"), scenario],
                text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn("TEST_PRIVATE_PACKAGE_DETAIL", result.stdout + result.stderr)
            return result.stdout

    def test_ready_launch_does_not_prompt_or_install(self):
        self.run_case("ready")

    def test_missing_python_is_installed_before_dependency_probe(self):
        self.run_case("python_missing")

    def test_required_dependency_decline_exits_without_installing(self):
        self.run_case("decline")

    def test_required_install_failure_exits(self):
        self.run_case("install_failure")

    def test_refresh_failure_never_attempts_install(self):
        self.run_case("refresh_failure")

    def test_successful_required_install_rechecks_runtime(self):
        self.run_case("install")

    def test_success_without_usable_dependency_is_rejected(self):
        self.run_case("still_missing")

    def test_already_installed_package_is_not_replaced(self):
        self.run_case("installed_broken")

    def test_optional_decline_preserves_raw_capture(self):
        self.run_case("optional_decline")

    def test_optional_install_failure_preserves_raw_capture(self):
        self.run_case("optional_failure")

    def test_optional_install_rechecks_and_finishes(self):
        self.run_case("optional_install")

    def test_serial_installs_only_its_required_package(self):
        self.run_case("serial")

    def test_missing_bundled_source_does_not_download_package(self):
        self.run_case("reinstall")

    def test_unrecognized_package_token_is_rejected(self):
        self.run_case("unrecognized")


if __name__ == "__main__":
    unittest.main()
