"""Exercise persistent sleep-setting recovery without changing this Mac's settings."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "keep_awake.sh"
FAKE_TOOL = r'''
import json, os, re, sys
from pathlib import Path

state_file = Path(os.environ["AWAKE_TEST_STATE"])
state = json.loads(state_file.read_text())
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
state["calls"].append([tool, *args])
code = 0
if tool == "pmset":
    if args == ["-g"]:
        print("System-wide power settings:\n SleepDisabled", state["sleep_disabled"])
    elif args == ["-g", "batt"]:
        print("Now drawing from 'Battery Power'")
    else:
        raise RuntimeError("Unexpected pmset call")
elif tool == "launchctl":
    target = args[-1] if args else ""
    key = "guard" if ".battery" in target else "agent"
    if args[0] == "print":
        if state.get(key, False):
            print(" state = running")
        else:
            code = 1
    elif args[0] in ("bootstrap", "kickstart"):
        state[key] = True
    elif args[0] == "bootout":
        state[key] = False
    elif args[0] != "enable":
        raise RuntimeError("Unexpected launchctl call")
elif tool == "osascript":
    if state["deny_admin"]:
        code = 1
    elif "sudoers.d" in args[-1]:
        state["passwordless"] = "mktemp" in args[-1]
        state["installation"] = args[-1]
    else:
        match = re.search(r"disablesleep ([01])", args[-1])
        if not match:
            raise RuntimeError("Unexpected privileged command")
        state["sleep_disabled"] = int(match.group(1))
elif tool == "sudo":
    if not state.get("passwordless"):
        code = 1
    elif args == ["-n", "-l"]:
        pmset = state_file.parent / "pmset"
        print(f"(root) NOPASSWD: {pmset} -a disablesleep 0, {pmset} -a disablesleep 1")
    elif len(args) == 5 and args[0] == "-n" and args[2:4] == ["-a", "disablesleep"]:
        state["sleep_disabled"] = int(args[4])
    else:
        raise RuntimeError("Unexpected sudo call")
else:
    raise RuntimeError("Unexpected tool")
state_file.write_text(json.dumps(state))
sys.exit(code)
'''


class KeepAwakeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="amster-awake-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state_file = self.root / "fake-system.json"
        self.state_file.write_text(json.dumps({
            "sleep_disabled": 0, "agent": False, "deny_admin": False, "calls": []
        }))
        source = SCRIPT.read_text()
        for absolute in ("/usr/bin/pmset", "/bin/launchctl", "/usr/bin/osascript", "/usr/bin/sudo"):
            fake = self.root / Path(absolute).name
            fake.write_text(f"#!{sys.executable}\n" + FAKE_TOOL)
            fake.chmod(0o700)
            source = source.replace(absolute, str(fake))
        self.script = self.root / "keep_awake.sh"
        self.script.write_text(source)
        worker = self.root / "BatteryGuard"
        worker.write_text("#!/bin/sh\nexit 0\n")
        worker.chmod(0o700)
        self.env = dict(os.environ, HOME=str(self.root), AWAKE_TEST_STATE=str(self.state_file))
        self.saved = self.root / "Library/Application Support/AmsterApart/keep-awake/original-sleep-disabled"
        self.plist = self.root / "Library/LaunchAgents/local.amster-apart.keep-awake.plist"
        self.guard_plist = self.plist.with_name("local.amster-apart.keep-awake.battery.plist")
        self.eco_limit = self.saved.with_name("eco-limit")

    def state(self):
        return json.loads(self.state_file.read_text())

    def update_state(self, **changes):
        state = self.state()
        state.update(changes)
        self.state_file.write_text(json.dumps(state))

    def run_script(self, *args, success=True):
        result = subprocess.run(
            ["/bin/bash", str(self.script), *args], env=self.env,
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def test_start_stop_restores_original_and_removes_autostart(self):
        self.run_script("start")
        self.assertEqual(self.saved.read_text(), "0\n")
        self.assertEqual(self.state()["sleep_disabled"], 1)
        self.assertTrue(self.state()["agent"])
        self.run_script("stop")
        self.assertEqual(self.state()["sleep_disabled"], 0)
        self.assertFalse(self.state()["agent"])
        self.assertFalse(self.saved.exists())
        self.assertFalse(self.plist.exists())

    def test_repeated_start_preserves_original_and_single_agent(self):
        self.run_script("start")
        self.run_script("start")
        self.assertEqual(self.saved.read_text(), "0\n")
        bootstraps = [call for call in self.state()["calls"] if call[:2] == ["launchctl", "bootstrap"]]
        self.assertEqual(len(bootstraps), 1)
        self.run_script("stop")
        self.assertEqual(self.state()["sleep_disabled"], 0)

    def test_preexisting_disabled_sleep_remains_disabled(self):
        self.update_state(sleep_disabled=1)
        self.run_script("start")
        self.run_script("stop")
        self.assertEqual(self.state()["sleep_disabled"], 1)
        self.assertFalse(any(call[0] == "osascript" for call in self.state()["calls"]))

    def test_idle_mode_never_changes_sleep_setting(self):
        self.run_script("start", "--idle")
        self.assertTrue(self.state()["agent"])
        self.assertEqual(self.state()["sleep_disabled"], 0)
        self.assertFalse(self.saved.exists())
        self.run_script("stop")
        self.assertFalse(any(call[0] == "osascript" for call in self.state()["calls"]))

    def test_cancelled_admin_keeps_recovery_and_idle_protection(self):
        self.update_state(deny_admin=True)
        self.run_script("start", success=False)
        self.assertEqual(self.state()["sleep_disabled"], 0)
        self.assertTrue(self.state()["agent"])
        self.assertEqual(self.saved.read_text(), "0\n")
        self.update_state(deny_admin=False)
        self.run_script("start")
        self.run_script("stop")
        self.assertEqual(self.state()["sleep_disabled"], 0)

    def test_failed_restore_keeps_recovery_and_can_retry(self):
        self.run_script("start")
        self.update_state(deny_admin=True)
        self.run_script("stop", success=False)
        self.assertTrue(self.saved.exists())
        self.assertTrue(self.state()["agent"])
        self.update_state(deny_admin=False)
        self.run_script("stop")
        self.assertEqual(self.state()["sleep_disabled"], 0)

    def test_invalid_saved_value_never_reaches_privileged_command(self):
        self.run_script("start")
        self.saved.write_text("untrusted\n")
        self.update_state(calls=[])
        self.run_script("stop", success=False)
        self.assertFalse(any(call[0] == "osascript" for call in self.state()["calls"]))
        self.assertTrue(self.saved.exists())

    def test_unknown_system_value_never_changes_sleep(self):
        self.update_state(sleep_disabled="unknown")
        self.run_script("start", success=False)
        self.assertFalse(self.saved.exists())
        self.assertFalse(any(call[0] == "osascript" for call in self.state()["calls"]))

    def test_status_reports_actual_state(self):
        result = self.run_script("status")
        self.assertIn("не работает", result.stdout)
        self.assertIn("SleepDisabled=0", result.stdout)
        self.run_script("start")
        result = self.run_script("status")
        self.assertIn("работает (caffeinate)", result.stdout)
        self.assertIn("SleepDisabled=1", result.stdout)

    def test_old_disk_assertion_is_migrated_without_losing_recovery(self):
        self.run_script("start")
        self.plist.write_text(self.plist.read_text().replace("<string>-i</string>", "<string>-ims</string>"))
        self.run_script("start")
        self.assertIn("<string>-i</string>", self.plist.read_text())
        self.assertNotIn("-ims", self.plist.read_text())
        self.assertEqual(self.saved.read_text(), "0\n")

    def test_eco_cutoff_restores_sleep_and_removes_both_agents(self):
        self.run_script("setup")
        self.run_script("eco", "20")
        self.assertEqual(self.eco_limit.read_text(), "20\n")
        self.assertTrue(self.state()["guard"])
        self.run_script("stop", "--automatic")
        self.assertEqual(self.state()["sleep_disabled"], 0)
        self.assertFalse(self.state()["agent"])
        self.assertFalse(self.state()["guard"])
        self.assertFalse(self.guard_plist.exists())
        self.assertFalse(self.eco_limit.exists())
        self.assertFalse(self.saved.with_name("lock").exists())

    def test_ac_only_mode_and_return_to_unlimited(self):
        self.run_script("setup")
        self.run_script("eco", "--ac-only")
        self.assertEqual(self.eco_limit.read_text(), "100\n")
        self.assertIn("EcoLimit=100", self.run_script("status").stdout)
        self.assertIn("BatteryGuard=1", self.run_script("status").stdout)
        self.run_script("start")
        self.assertFalse(self.eco_limit.exists())
        self.assertFalse(self.state()["guard"])
        self.assertTrue(self.state()["agent"])
        self.assertEqual(self.state()["sleep_disabled"], 1)

    def test_automatic_cutoff_never_prompts_and_retains_recovery_on_failure(self):
        self.run_script("setup")
        self.run_script("eco")
        self.update_state(passwordless=False, calls=[])
        self.run_script("stop", "--automatic", success=False)
        self.assertTrue(self.saved.exists())
        self.assertTrue(self.state()["guard"])
        self.assertFalse(any(call[0] == "osascript" for call in self.state()["calls"]))
        self.update_state(passwordless=True)
        self.run_script("stop", "--automatic")
        self.assertEqual(self.state()["sleep_disabled"], 0)

    def test_eco_requires_recoverable_settings_and_worker_before_mutation(self):
        self.run_script("eco", success=False)
        self.assertFalse(self.state()["agent"])
        self.run_script("setup")
        self.update_state(sleep_disabled=1)
        self.run_script("eco", success=False)
        self.assertFalse(self.state()["agent"])
        self.update_state(sleep_disabled=0)
        (self.root / "BatteryGuard").unlink()
        self.run_script("eco", success=False)
        self.assertFalse(self.state()["agent"])

    def test_idle_transition_releases_previous_closed_lid_protection(self):
        self.run_script("setup")
        self.run_script("eco")
        self.run_script("start", "--idle")
        self.assertEqual(self.state()["sleep_disabled"], 0)
        self.assertFalse(self.state()["guard"])
        self.assertTrue(self.state()["agent"])
        self.assertFalse(self.saved.exists())

    def test_setup_once_allows_switching_without_further_prompts(self):
        self.run_script("setup")
        self.assertEqual(self.state()["sleep_disabled"], 0)
        self.assertTrue(self.state()["passwordless"])
        self.run_script("setup")
        self.run_script("start")
        self.run_script("stop")
        self.run_script("start")
        prompts = [call for call in self.state()["calls"] if call[0] == "osascript"]
        self.assertEqual(len(prompts), 1)
        self.assertEqual(self.state()["sleep_disabled"], 1)

    def test_setup_grants_only_two_exact_commands(self):
        self.run_script("setup")
        installation = self.state()["installation"]
        self.assertIn("-a disablesleep 0,", installation)
        self.assertIn("-a disablesleep 1'", installation)
        self.assertNotIn("NOPASSWD: ALL", installation)
        self.assertIn("visudo -c -f", installation)
        self.assertIn("-o root -g wheel -m 0440", installation)

    def test_cancelled_setup_leaves_power_settings_unchanged(self):
        self.update_state(sleep_disabled=1, deny_admin=True)
        self.run_script("setup", success=False)
        self.assertEqual(self.state()["sleep_disabled"], 1)
        self.assertFalse(self.state().get("passwordless", False))

    def test_access_can_be_removed_without_changing_sleep(self):
        self.run_script("setup")
        self.run_script("start")
        self.run_script("remove-access")
        self.assertFalse(self.state()["passwordless"])
        self.assertEqual(self.state()["sleep_disabled"], 1)


if __name__ == "__main__":
    unittest.main()
