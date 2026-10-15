import importlib.util
import os
import sys
import unittest
import tempfile
import pathlib
import subprocess
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "rewrite"))
import rewrite
import codex_models


class RewriteTests(unittest.TestCase):
    def test_old_settings_keep_claude(self):
        self.assertEqual(rewrite.provider({}), "claude")
        self.assertEqual(rewrite.model_arguments({}), ["--model", "claude-haiku-5-5"])

    def test_provider_specific_effort(self):
        self.assertEqual(rewrite.model_arguments({"rewriteProvider": "codex", "rewriteEffort": "ultra"}),
                         ["-c", 'model_reasoning_effort="ultra"'])
        self.assertEqual(rewrite.model_arguments({"rewriteEffort": "ultra"}), ["--model", "claude-haiku-5-5"])
        self.assertEqual(rewrite.model_arguments({"rewriteProvider": "codex", "rewriteModel": "claude-haiku-5-5"}), [])
        for invalid in [[], {}, True, "bogus"]:
            self.assertEqual(rewrite.model_arguments({"rewriteProvider": "codex", "rewriteEffort": invalid}), [])

    def test_discovery_parses_efforts_and_default(self):
        models = codex_models.parse_models([
            {"model": "other", "supportedReasoningEfforts": None},
            {"model": "chosen", "displayName": "Chosen", "isDefault": True,
             "supportedReasoningEfforts": [{"reasoningEffort": "ultra"}, {"reasoningEffort": []}],
             "defaultReasoningEffort": "ultra"},
            {"model": "hidden", "hidden": True}, {}, None])
        self.assertEqual([m["slug"] for m in models], ["chosen", "other"])
        self.assertEqual(models[0]["efforts"], ["ultra"])
        self.assertEqual(models[0]["defaultEffort"], "ultra")

    def test_codex_command_isolated_and_final_text_only(self):
        process = mock.Mock()
        process.pid = 123456789
        process.returncode = 0
        process.communicate.return_value = ('{"type":"item.completed","item":null}\n'
            '{"type":"item.completed","item":{"type":"reasoning","text":"private"}}\n'
            '{"type":"item.completed","item":{"type":"agent_message","text":"Corrected."}}\n', None)
        with mock.patch.object(rewrite, "settings", return_value={"rewriteProvider": "codex"}), \
             mock.patch.object(rewrite, "front_app", return_value=""), \
             mock.patch.object(rewrite, "cli_path", return_value="/codex"), \
             mock.patch.object(rewrite.subprocess, "Popen", return_value=process) as spawn, \
             mock.patch.object(rewrite, "stop"):
            self.assertEqual(rewrite.rewrite("corrected"), "Corrected.")
        args, kwargs = spawn.call_args
        self.assertIn("--ignore-user-config", args[0])
        self.assertIn("--ignore-rules", args[0])
        self.assertIn("--ephemeral", args[0])
        self.assertIn("features.shell_tool=false", args[0])
        self.assertIn("skills.include_instructions=false", args[0])
        self.assertNotEqual(kwargs["env"]["HOME"], os.path.expanduser("~"))
        self.assertTrue(os.path.isabs(kwargs["env"]["CODEX_HOME"]))
        self.assertEqual(kwargs["cwd"], kwargs["env"]["HOME"])

    def test_isolated_python_launcher_with_minimal_path(self):
        with tempfile.TemporaryDirectory() as home:
            support = pathlib.Path(home) / "Library/Application Support/VoxtypeOSD"
            support.mkdir(parents=True)
            (support / "rewrite-enabled").touch()
            (support / "settings.json").write_text('{"rewriteProvider":"codex"}')
            binary = pathlib.Path(home) / ".local/bin/codex"
            binary.parent.mkdir(parents=True)
            binary.write_text('#!/bin/sh\ncat >/dev/null\necho \'{"type":"item.completed","item":{"type":"agent_message","text":"Corrected."}}\'\n')
            binary.chmod(0o700)
            result = subprocess.run([os.path.join(ROOT, "rewrite/voxtype-rewrite")], input="original",
                                    text=True, capture_output=True, timeout=5,
                                    env={"HOME": home, "PATH": "/usr/bin:/bin"})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "Corrected.")

    def test_failure_passthrough_is_logged(self):
        import io
        with mock.patch.object(sys, "stdin", io.StringIO("Original.")), \
             mock.patch.object(sys, "stdout", new_callable=io.StringIO) as output, \
             mock.patch.object(rewrite, "rewrite", side_effect=ValueError("bad JSON")), \
             mock.patch("builtins.open", mock.mock_open()) as log:
            rewrite.main()
            self.assertEqual(output.getvalue(), "Original.")
            self.assertIn('"ok": false', log().write.call_args[0][0])


if __name__ == "__main__":
    unittest.main()
