#!/usr/bin/env python3
"""Tests for vps-secrets-render. Run: python3 ansible/roles/deploy-user/files/test_vps_secrets_render.py

By default a stand-in for sops is used, which "decrypts" a file by dropping its
first line (and fails if the file contains FAIL). If real `sops` and
`age-keygen` are on PATH, a round-trip test with real encryption runs as well;
CI installs the pinned release for that.
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import os
import pwd
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "vps-secrets-render")
ME = pwd.getpwuid(os.getuid()).pw_name

loader = importlib.machinery.SourceFileLoader("vps_secrets_render", SCRIPT)
spec = importlib.util.spec_from_loader("vps_secrets_render", loader)
render = importlib.util.module_from_spec(spec)
loader.exec_module(render)

STUB = textwrap.dedent("""\
    #!/usr/bin/env python3
    import sys
    path = sys.argv[-1]
    data = open(path, "rb").read()
    if b"FAIL" in data:
        sys.stderr.write("Error: stub refused " + path + "\\n")
        sys.exit(1)
    sys.stdout.buffer.write(data.split(b"\\n", 1)[1])
    """)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.repo = os.path.join(self.tmp, "repo")
        os.makedirs(os.path.join(self.repo, "apps", "planka"))
        os.makedirs(os.path.join(self.repo, "backup", "services"))
        self.key = os.path.join(self.tmp, "key.txt")
        with open(self.key, "w") as f:
            f.write("AGE-SECRET-KEY-1TEST\n")
        self.sops = os.path.join(self.tmp, "sops")
        with open(self.sops, "w") as f:
            f.write(STUB)
        os.chmod(self.sops, 0o755)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def secret(self, rel, body):
        path = os.path.join(self.repo, "secrets", rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write("ENCRYPTED\n" + body)
        return path

    def run_render(self, *extra):
        argv = ["--repo", self.repo, "--sops", self.sops, "--key", self.key, "--owner", ME, *extra]
        return render.main(argv)

    def read(self, rel):
        with open(os.path.join(self.repo, rel)) as f:
            return f.read()

    def exists(self, rel):
        return os.path.lexists(os.path.join(self.repo, rel))


class RenderTests(Base):
    def test_no_secrets_dir_is_a_no_op(self):
        self.assertEqual(self.run_render(), 0)
        self.assertFalse(self.exists(".env"))

    def test_renders_the_mirrored_paths_with_mode_600(self):
        self.secret(".env.sops", "DOMAIN=example.org\n")
        self.secret("apps/planka/.env.sops", "SECRET_KEY=abc\n")
        self.secret("backup/services/planka.env.sops", "RESTIC_PASSWORD=x\n")
        self.assertEqual(self.run_render(), 0)
        self.assertEqual(self.read(".env"), "DOMAIN=example.org\n")
        self.assertEqual(self.read("apps/planka/.env"), "SECRET_KEY=abc\n")
        self.assertEqual(self.read("backup/services/planka.env"), "RESTIC_PASSWORD=x\n")
        mode = stat.S_IMODE(os.stat(os.path.join(self.repo, "apps/planka/.env")).st_mode)
        self.assertEqual(mode, 0o600)
        leftovers = [n for n in os.listdir(os.path.join(self.repo, "apps/planka")) if "vps-secrets" in n]
        self.assertEqual(leftovers, [])

    def test_an_unchanged_file_is_not_rewritten(self):
        self.secret("apps/planka/.env.sops", "A=1\n")
        self.run_render()
        path = os.path.join(self.repo, "apps/planka/.env")
        before = os.stat(path)
        self.assertEqual(self.run_render(), 0)
        after = os.stat(path)
        self.assertEqual((before.st_ino, before.st_ctime_ns), (after.st_ino, after.st_ctime_ns))

    def test_a_changed_file_is_replaced(self):
        self.secret("apps/planka/.env.sops", "A=1\n")
        self.run_render()
        self.secret("apps/planka/.env.sops", "A=2\n")
        self.run_render()
        self.assertEqual(self.read("apps/planka/.env"), "A=2\n")

    def test_one_failed_decrypt_writes_nothing(self):
        self.secret(".env.sops", "DOMAIN=example.org\n")
        self.secret("apps/planka/.env.sops", "FAIL\n")
        self.assertEqual(self.run_render(), 1)
        self.assertFalse(self.exists(".env"))
        self.assertFalse(self.exists("apps/planka/.env"))

    def test_a_target_outside_the_env_set_is_refused(self):
        self.secret(".env.sops", "A=1\n")
        self.secret("apps/planka/docker-compose.yml.sops", "x\n")
        self.assertEqual(self.run_render(), 1)
        self.assertFalse(self.exists(".env"))

    def test_traversal_names_are_refused(self):
        for rel in ("apps/../.env.sops", "apps/.hidden/.env.sops"):
            with self.subTest(rel=rel):
                with self.assertRaises(render.RenderError):
                    render.target_for(rel)

    def test_a_file_without_the_suffix_is_refused(self):
        self.secret("apps/planka/.env", "A=1\n")
        self.assertEqual(self.run_render(), 1)

    def test_a_symlink_inside_secrets_is_refused(self):
        os.makedirs(os.path.join(self.repo, "secrets"))
        os.symlink("/etc/hostname", os.path.join(self.repo, "secrets", "x.env.sops"))
        self.assertEqual(self.run_render(), 1)

    def test_a_planted_link_at_the_target_is_replaced_not_followed(self):
        victim = os.path.join(self.tmp, "victim")
        with open(victim, "w") as f:
            f.write("untouched\n")
        os.symlink(victim, os.path.join(self.repo, "apps/planka/.env"))
        self.secret("apps/planka/.env.sops", "A=1\n")
        self.assertEqual(self.run_render(), 0)
        with open(victim) as f:
            self.assertEqual(f.read(), "untouched\n")
        path = os.path.join(self.repo, "apps/planka/.env")
        self.assertFalse(os.path.islink(path))
        self.assertEqual(self.read("apps/planka/.env"), "A=1\n")

    def test_a_linked_app_directory_is_refused_and_nothing_is_written(self):
        elsewhere = os.path.join(self.tmp, "elsewhere")
        os.makedirs(elsewhere)
        os.symlink(elsewhere, os.path.join(self.repo, "apps", "linked"))
        self.secret(".env.sops", "A=1\n")
        self.secret("apps/linked/.env.sops", "B=2\n")
        self.assertEqual(self.run_render(), 1)
        self.assertEqual(os.listdir(elsewhere), [])
        self.assertFalse(self.exists(".env"))

    def test_a_missing_app_directory_writes_nothing(self):
        self.secret(".env.sops", "A=1\n")
        self.secret("apps/gone/.env.sops", "B=2\n")
        self.assertEqual(self.run_render(), 1)
        self.assertFalse(self.exists(".env"))

    def test_compose_variables_are_refused(self):
        self.secret(".env.sops", "COMPOSE_FILE=/tmp/evil.yml\n")
        self.assertEqual(self.run_render(), 1)
        self.secret(".env.sops", "export COMPOSE_PROJECT_NAME=x\n")
        self.assertEqual(self.run_render(), 1)
        self.assertFalse(self.exists(".env"))

    def test_recovery_file_is_never_rendered(self):
        self.secret("recovery.sops", "FAIL because the server cannot decrypt it\n")
        self.secret(".env.sops", "A=1\n")
        self.assertEqual(self.run_render(), 0)
        self.assertEqual(self.read(".env"), "A=1\n")

    def test_check_mode_writes_nothing(self):
        self.secret(".env.sops", "A=1\n")
        self.assertEqual(self.run_render("--check"), 0)
        self.assertFalse(self.exists(".env"))

    def test_secrets_without_a_server_key_stop_the_deploy(self):
        self.secret(".env.sops", "A=1\n")
        os.unlink(self.key)
        self.assertEqual(self.run_render(), 1)
        self.assertFalse(self.exists(".env"))


@unittest.skipUnless(shutil.which("sops") and shutil.which("age-keygen"), "real sops/age not installed")
class RealSopsTests(Base):
    def test_round_trip_with_real_encryption(self):
        os.unlink(self.key)  # replace the stand-in key with a real one
        subprocess.run(["age-keygen", "-o", self.key], check=True, capture_output=True)
        pub = subprocess.run(["age-keygen", "-y", self.key], check=True, capture_output=True, text=True).stdout.strip()
        plain = os.path.join(self.tmp, "plain.env")
        with open(plain, "w") as f:
            f.write("SECRET_KEY=s3cret\nDB_PASSWORD=p4ss\n")
        enc = subprocess.run(
            ["sops", "--encrypt", "--age", pub, "--input-type", "dotenv", "--output-type", "dotenv", plain],
            check=True, capture_output=True,
        ).stdout
        self.assertNotIn(b"s3cret", enc)
        path = os.path.join(self.repo, "secrets", "apps", "planka", ".env.sops")
        os.makedirs(os.path.dirname(path))
        with open(path, "wb") as f:
            f.write(enc)
        argv = ["--repo", self.repo, "--sops", shutil.which("sops"), "--key", self.key, "--owner", ME]
        self.assertEqual(render.main(argv), 0)
        self.assertEqual(self.read("apps/planka/.env"), "SECRET_KEY=s3cret\nDB_PASSWORD=p4ss\n")

    def test_a_file_encrypted_to_another_key_fails_cleanly(self):
        other = os.path.join(self.tmp, "other.txt")
        subprocess.run(["age-keygen", "-o", other], check=True, capture_output=True)
        subprocess.run(["age-keygen", "-o", self.key + ".real"], check=True, capture_output=True)
        os.replace(self.key + ".real", self.key)
        pub = subprocess.run(["age-keygen", "-y", other], check=True, capture_output=True, text=True).stdout.strip()
        plain = os.path.join(self.tmp, "plain.env")
        with open(plain, "w") as f:
            f.write("A=1\n")
        enc = subprocess.run(
            ["sops", "--encrypt", "--age", pub, "--input-type", "dotenv", "--output-type", "dotenv", plain],
            check=True, capture_output=True,
        ).stdout
        path = os.path.join(self.repo, "secrets", ".env.sops")
        os.makedirs(os.path.dirname(path))
        with open(path, "wb") as f:
            f.write(enc)
        argv = ["--repo", self.repo, "--sops", shutil.which("sops"), "--key", self.key, "--owner", ME]
        self.assertEqual(render.main(argv), 1)
        self.assertFalse(self.exists(".env"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
