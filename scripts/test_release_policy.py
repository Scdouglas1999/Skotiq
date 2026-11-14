import os
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("release_policy.py")
SIGNING_NAMES = (
    "ANDROID_KEYSTORE_BASE64",
    "ANDROID_KEYSTORE_PASSWORD",
    "ANDROID_KEY_ALIAS",
    "ANDROID_KEY_PASSWORD",
    "UPDATE_PRIVATE_KEY",
    "UPDATE_PUBLIC_KEY",
)


def workflow_step(name):
    workflow = (SCRIPT.parent.parent / ".github/workflows/release.yml").read_text()
    block = re.search(
        rf"(?m)^      - name: {re.escape(name)}\n[\s\S]*?^        run: \|\n((?:^          [^\n]*\n|^\n)+)",
        workflow,
    )
    if block is None:
        raise AssertionError(f"Missing executable workflow step: {name}")
    return textwrap.dedent(block.group(1))


class ReleasePolicyTest(unittest.TestCase):
    def run_policy(self, channel, distribution=False, configured=SIGNING_NAMES):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            version = root / "version.yaml"
            version.write_text(f'version: "9.0.0"\nchannel: {channel}\n')
            output = root / "outputs"
            env = {f"{name}_CONFIGURED": "true" for name in configured}
            command = [
                sys.executable, str(SCRIPT), "--version-file", str(version),
                "--output", str(output),
            ]
            if distribution:
                command.append("--distribute")
            result = subprocess.run(command, env=env, text=True, capture_output=True)
            values = dict(line.split("=", 1) for line in output.read_text().splitlines()) if output.exists() else {}
            return result, values

    def test_stable_distribution_requires_every_android_and_update_credential(self):
        for name in SIGNING_NAMES:
            with self.subTest(name=name):
                result, values = self.run_policy('"stable" # release', True, set(SIGNING_NAMES) - {name})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name, result.stderr)
                self.assertEqual(values, {})

    def test_stable_distribution_is_signed_normal_latest_release(self):
        result, values = self.run_policy('"stable"', True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values, {
            "release_channel": "stable", "require_signing": "true",
            "prerelease": "false", "make_latest": "true",
        })

    def test_stable_build_only_preserves_unsigned_validation_path(self):
        result, values = self.run_policy("stable", configured=())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values["require_signing"], "false")
        self.assertIn("validation", result.stdout.lower())

    def test_prerelease_channels_do_not_become_latest_stable(self):
        for channel in ("beta", "alpha"):
            with self.subTest(channel=channel):
                result, values = self.run_policy(channel, True, ())
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(values["prerelease"], "true")
                self.assertEqual(values["make_latest"], "false")
                self.assertEqual(values["require_signing"], "false")

    def test_unknown_or_missing_channel_cannot_publish(self):
        for channel in ("", "production", '"stable', "stable\nchannel: beta"):
            with self.subTest(channel=channel):
                result, values = self.run_policy(channel, True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(values, {})


class AndroidSignatureTest(unittest.TestCase):
    def verify(self, certificate="CN=Release, O=Example", *, required=True,
               supplied=False, verifier_exit=0, include_apk=True):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            verifier = root / "apksigner"
            verifier.write_text(
                '#!/bin/sh\n'
                'printf "Signer #1 certificate DN: %s\\n" "$TEST_CERTIFICATE"\n'
                'exit "$TEST_VERIFIER_EXIT"\n'
            )
            verifier.chmod(0o700)
            apk = root / "fixture.apk"
            apk.touch()
            env = {
                "PATH": os.environ["PATH"], "APKSIGNER": str(verifier),
                "SKOTIQ_REQUIRE_RELEASE_SIGNING": str(required).lower(),
                "TEST_CERTIFICATE": certificate,
                "TEST_VERIFIER_EXIT": str(verifier_exit),
            }
            if supplied:
                env["KEYSTORE_FILE"] = "/configured/release.jks"
            command = ["bash", str(SCRIPT.with_name("verify_android_release_signatures.sh"))]
            if include_apk:
                command.append(str(apk))
            return subprocess.run(command, env=env, text=True, capture_output=True)

    def test_stable_refuses_a_debug_signed_apk(self):
        result = self.verify("CN=Android Debug, O=Android, C=US")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Android Debug certificate", result.stderr)

    def test_configured_identity_is_checked_in_build_only_mode_too(self):
        result = self.verify("CN=Android Debug, O=Android, C=US", required=False, supplied=True)
        self.assertNotEqual(result.returncode, 0)

    def test_valid_release_signature_passes(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_developer_validation_may_use_debug_certificate(self):
        result = self.verify("CN=Android Debug, O=Android, C=US", required=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unsigned_or_invalid_apk_is_rejected_by_verifier(self):
        result = self.verify(verifier_exit=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Verified APK signature", result.stdout)

    def test_missing_apk_is_not_a_success(self):
        self.assertNotEqual(self.verify(include_apk=False).returncode, 0)


class WorkflowVersionTest(unittest.TestCase):
    def resolve(self, event, ref_type="tag", requested=""):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for platform in ("desktop", "mobile"):
                app = root / "apps" / platform
                app.mkdir(parents=True)
                (app / "pubspec.yaml").write_text("version: 9.0.0+37\n")
            (root / "version.yaml").write_text('version: "9.0.0"\nchannel: stable\n')
            output = root / "outputs"
            result = subprocess.run(
                ["bash", "-c", workflow_step("Resolve + validate version")], cwd=root,
                env={
                    "PATH": os.environ["PATH"], "GITHUB_EVENT_NAME": event,
                    "GITHUB_REF_TYPE": ref_type, "GITHUB_REF_NAME": "v9.0.0",
                    "REQUESTED_RELEASE_TAG": requested, "GITHUB_OUTPUT": str(output),
                }, text=True, capture_output=True,
            )
            values = dict(line.split("=", 1) for line in output.read_text().splitlines()) if output.exists() else {}
            return result, values

    def test_manual_build_on_a_tag_does_not_become_publication(self):
        result, values = self.resolve("workflow_dispatch")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values["release_tag"], "")

    def test_tag_push_resolves_a_distribution(self):
        result, values = self.resolve("push")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values["release_tag"], "v9.0.0")

    def test_explicit_draft_attachment_resolves_a_distribution(self):
        result, values = self.resolve("workflow_dispatch", "branch", "v9.0.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values["release_tag"], "v9.0.0")

    def test_draft_attachment_cannot_name_another_release(self):
        result, values = self.resolve("workflow_dispatch", "branch", "v8.2.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(values, {})


class DraftAttachmentTest(unittest.TestCase):
    def attach(self, is_draft):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            gh = root / "gh"
            gh.write_text(
                '#!/bin/sh\n'
                'if [ "$2" = view ]; then printf "%s\\n" "$TEST_IS_DRAFT"; '
                'else touch "$TEST_UPLOAD_MARKER"; fi\n'
            )
            gh.chmod(0o700)
            marker = root / "uploaded"
            result = subprocess.run(
                ["bash", "-c", workflow_step("Attach artifacts to existing draft release")],
                cwd=root, env={
                    "PATH": str(root) + os.pathsep + os.environ["PATH"],
                    "RELEASE_TAG": "v9.0.0", "TEST_IS_DRAFT": is_draft,
                    "TEST_UPLOAD_MARKER": str(marker),
                }, text=True, capture_output=True,
            )
            return result, marker.exists()

    def test_existing_draft_receives_review_artifacts(self):
        result, uploaded = self.attach("true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(uploaded)

    def test_published_release_is_not_overwritten(self):
        result, uploaded = self.attach("false")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(uploaded)


if __name__ == "__main__":
    unittest.main()
