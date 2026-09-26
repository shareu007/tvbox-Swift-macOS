import importlib.util
import tempfile
import subprocess
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("bundle_audit", Path(__file__).parents[1] / "audit_macos_bundle.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class BundlePrivacyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.bundle = Path(self.temp.name) / "TVBox.app"
        self.resources = self.bundle / "Contents/Resources"
        self.resources.mkdir(parents=True)
        (self.resources / "TVBoxPresets.json").write_text("[]")
        self.binary = self.bundle / "Contents/MacOS/TVBox"
        self.binary.parent.mkdir()
        self.binary.write_bytes(b"clean binary")

    def check(self):
        return audit.audit_bundle(self.bundle, [Path("/synthetic/private-home")])

    def testBinaryDebugPathsAreRejectedWithoutLoggingMatchedValue(self):
        self.binary.write_bytes(b"prefix\0/synthetic/private-home/project/build/file.o\0")
        issues = self.check()
        self.assertEqual(issues, [("Contents/MacOS/TVBox", "local absolute path")])
        self.assertNotIn("private-home", str(issues))

    def testMetadataLocalPathsAreRejected(self):
        subprocess.run(["xattr", "-w", "test.audit-path", "/synthetic/private-home/file", str(self.binary)], check=True)
        self.assertEqual(self.check(), [("Contents/MacOS/TVBox", "local absolute path")])

    def testEncodedLocalPathsAreRejected(self):
        self.binary.write_bytes("/synthetic/private-home/cache".encode("utf-16-le"))
        self.assertTrue(self.check())

    def testNonemptyPresetAndRuntimeDatabaseAreRejected(self):
        (self.resources / "TVBoxPresets.json").write_text('[{"url":"https://example.com"}]')
        (self.resources / "history.sqlite").touch()
        self.assertEqual(len(self.check()), 2)

    def testParserConstantsAndEmbeddedBase64AreNotCredentials(self):
        self.binary.write_bytes((b"-----BEGIN " + b"PRIVATE KEY-----\0") + b"XAKIA" + b"A" * 16 + b"base64")
        self.assertEqual(self.check(), [])

    def testCompletePrivateKeyPayloadAndBoundedCredentialAreRejected(self):
        self.binary.write_bytes((b"-----BEGIN " + b"PRIVATE KEY-----\n") + b"A" * 40 + b"\0ghp_" + b"Z" * 30 + b"\0")
        self.assertEqual(len(self.check()), 2)

    def testExternalSymlinkIsRejectedButFrameworkAliasAllowed(self):
        (self.resources / "alias").symlink_to("TVBoxPresets.json")
        self.assertEqual(self.check(), [])
        (self.resources / "external").symlink_to(self.temp.name)
        self.assertEqual(len(self.check()), 1)


if __name__ == "__main__":
    unittest.main()
