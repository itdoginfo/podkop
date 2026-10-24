"""Offline regressions for source ruleset registration. Requires busybox and jq.

Run: python3 -m unittest discover -s tests -v
Only function definitions are extracted from the entrypoint; no OpenWrt services,
UCI configuration, network requests or installed files are touched. JSON helpers
and ruleset file operations are the real implementation, running in BusyBox ash.
"""

import json
import os
import re
import selectors
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "podkop/files/usr/lib"
ENTRY = ROOT / "podkop/files/usr/bin/podkop"
FUNCTIONS = (
    "prepare_source_ruleset",
    "configure_user_domain_list",
    "configure_user_subnet_list",
    "configure_remote_domain_or_subnet_list_handler",
)
BASE_CONFIG = {
    "route": {
        "rule_set": [],
        "rules": [
            {"__service_tag": "main-route", "outbound": "main-out"},
            {"__service_tag": "second-route", "outbound": "second-out"},
        ],
    },
    "dns": {"rules": [{"__service_tag": "fakeip-dns-rule-tag", "server": "fakeip"}]},
}


def function_definition(name):
    match = re.search(
        rf"^{name}\(\) \{{\n.*?^\}}", ENTRY.read_text(), re.MULTILINE | re.DOTALL,
    )
    if match is None:
        raise AssertionError(f"Cannot locate production function {name}")
    return match.group()


class SourceRulesetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for command in ("busybox", "jq"):
            if shutil.which(command) is None:
                raise RuntimeError(f"Required test dependency missing: {command}")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.rules = self.work / "rules"
        self.rules.mkdir()
        self.env = dict(os.environ, TMPDIR=str(self.work))
        # Relocate only jq's absolute module search path in a temporary copy.
        # Keep the real JSON helpers without installing anything system-wide.
        manager = self.work / "sing_box_config_manager.sh"
        manager.write_text((LIB / manager.name).read_text().replace(
            '"search": "/usr/lib/podkop"', '"search": ' + json.dumps(str(LIB)),
        ))
        self.prelude = f"""
PODKOP_LIB={shlex.quote(str(LIB))}
TMP_RULESET_FOLDER={shlex.quote(str(self.rules))}
. "$PODKOP_LIB/helpers.sh"
. "$PODKOP_LIB/rulesets.sh"
. {shlex.quote(str(manager))}
SB_FAKEIP_DNS_RULE_TAG=fakeip-dns-rule-tag
log() {{ :; }}
# Platform boundaries only: provide two user lists and avoid nft changes.
config_get() {{
    case "$3" in
        user_domain_list_type|user_subnet_list_type) value=text ;;
        user_domains_text) value=example.test ;;
        user_subnets_text) value=192.0.2.0/24 ;;
        *) return 1 ;;
    esac
    export "$1=$value"
}}
nft_add_set_elements() {{ :; }}
# Input validation is outside registration: host libc regex support differs
# from OpenWrt. Accept only this known-valid documentation subnet fixture.
is_ipv4_cidr() {{ [ "$1" = "192.0.2.0/24" ]; }}
config={shlex.quote(json.dumps(BASE_CONFIG))}
""" + "\n".join(function_definition(name) for name in FUNCTIONS)

    def run_shell(self, body, expect_stderr=False):
        result = subprocess.run(
            ["busybox", "ash", "-c", self.prelude + "\n" + body],
            env=self.env, capture_output=True, text=True, timeout=15, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        if not expect_stderr:
            self.assertEqual(result.stderr, "")
        return json.loads(result.stdout)

    def assert_registered(self, config, name="user", section="main"):
        tags = [f"{section}-{name}-{kind}-ruleset" for kind in ("domains", "subnets")]
        declarations = config["route"]["rule_set"]
        self.assertEqual([item["tag"] for item in declarations], tags)
        for item, tag in zip(declarations, tags):
            self.assertEqual(item, {
                "type": "local", "format": "source", "tag": tag,
                "path": str(self.rules / f"{tag}.json"),
            })
        route = next(r for r in config["route"]["rules"]
                     if r["__service_tag"] == f"{section}-route")
        self.assertEqual(route["rule_set"], tags)
        self.assertEqual(config["dns"]["rules"][0]["rule_set"], tags[0])
        other = next(r for r in config["route"]["rules"]
                     if r["__service_tag"] != f"{section}-route")
        self.assertNotIn("rule_set", other)

    @staticmethod
    def prepare_pair(name="user", section="main"):
        return (
            f"prepare_source_ruleset {section} {name} domains {section}-route\n"
            f"prepare_source_ruleset {section} {name} subnets {section}-route\n"
        )

    def test_fresh_and_existing_files_register_without_overwriting_contents(self):
        for name in ("user", "local", "remote"):
            for section in ("main", "second"):
                with self.subTest(name=name, section=section):
                    first = self.run_shell(self.prepare_pair(name, section) + 'echo "$config"')
                    self.assert_registered(first, name, section)
                    before = {}
                    for kind, key, value in (
                        ("domains", "domain_suffix", "example.test"),
                        ("subnets", "ip_cidr", "192.0.2.0/24"),
                    ):
                        path = self.rules / f"{section}-{name}-{kind}-ruleset.json"
                        path.write_text(json.dumps({"version": 3, "rules": [{key: [value]}]}))
                        before[path] = path.read_bytes()
                    rebuilt = self.run_shell(self.prepare_pair(name, section) + 'echo "$config"')
                    self.assert_registered(rebuilt, name, section)
                    for path, content in before.items():
                        self.assertEqual(path.read_bytes(), content)

    def test_repeated_calls_in_one_config_do_not_duplicate_registration(self):
        config = self.run_shell(self.prepare_pair() * 2 + 'echo "$config"')
        self.assert_registered(config)

    def test_multiple_remote_text_lists_share_one_registration(self):
        calls = "\n".join(
            f"configure_remote_domain_or_subnet_list_handler "
            f"https://example.test/{n}.txt {kind} main main-route"
            for kind in ("domains", "subnets") for n in (1, 2)
        )
        self.assert_registered(self.run_shell(calls + '\necho "$config"'), "remote")
        # A new config must also register the files left by the previous pass.
        self.assert_registered(self.run_shell(calls + '\necho "$config"'), "remote")

    def test_user_list_callers_keep_data_and_references_on_rebuild(self):
        calls = """
configure_user_domain_list main main-route
configure_user_subnet_list main main-route
echo "$config"
"""
        for _ in range(2):
            config = self.run_shell(calls)
            self.assert_registered(config)
            for kind, key, value in (
                ("domains", "domain_suffix", "example.test"),
                ("subnets", "ip_cidr", "192.0.2.0/24"),
            ):
                content = json.loads((self.rules / f"main-user-{kind}-ruleset.json").read_text())
                self.assertEqual(content, {"version": 3, "rules": [{key: [value]}]})

    def test_later_finishing_generation_preserves_rules_after_other_generation(self):
        # A has initialized its config but pauses before preparing lists.
        # B finishes first and creates the shared files; A then finishes last.
        script = self.prelude + '\nprintf "READY\\n"\nread -r resume\n'
        script += self.prepare_pair() + 'echo "$config"\n'
        with subprocess.Popen(
            ["busybox", "ash", "-c", script], env=self.env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True,
        ) as process:
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    self.assertTrue(selector.select(5), "Generation A did not reach barrier")
                self.assertEqual(process.stdout.readline().strip(), "READY")
                config_b = self.run_shell(self.prepare_pair() + 'echo "$config"')
                self.assert_registered(config_b)
                stdout, stderr = process.communicate("resume\n", timeout=15)
                self.assertEqual(process.returncode, 0, stderr)
                self.assert_registered(json.loads(stdout))
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

    def test_failed_file_creation_does_not_register_nonexistent_ruleset(self):
        config = self.run_shell('''
TMP_RULESET_FOLDER="$TMP_RULESET_FOLDER/missing/parent"
prepare_source_ruleset main user domains main-route
echo "$config"
''', expect_stderr=True)
        self.assertEqual(config, BASE_CONFIG)


if __name__ == "__main__":
    unittest.main()
