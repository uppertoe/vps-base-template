#!/usr/bin/env python3
"""Tests for vps-secrets-render. Run: python3 ansible/roles/deploy-user/files/test_vps_secrets_render.py

By default a stand-in for sops is used, which "decrypts" stdin by dropping its
first line and its sops_ metadata lines (and fails, quoting the input on
stderr as real sops does for a malformed file, if the input contains FAIL). If real `sops` and
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
    import base64, json, sys
    assert sys.argv[-1] == "/dev/stdin", sys.argv
    data = sys.stdin.buffer.read()
    if b"FAIL" in data:
        sys.stderr.write("invalid dotenv input line: " + data.decode() + "\\n")
        sys.exit(1)
    if "binary" in sys.argv:
        # The stand-in for a binary-type file keeps the plaintext base64 in
        # the data field, where real sops keeps the ciphertext.
        enc = json.loads(data)["data"]
        sys.stdout.buffer.write(base64.b64decode(enc.split("data:", 1)[1].split(",", 1)[0]))
        sys.exit(0)
    body = data.split(b"\\n", 1)[1]
    sys.stdout.buffer.write(b"".join(l for l in body.splitlines(True) if not l.startswith(b"sops_")))
    """)
META = "sops_mac=ENC[AES256_GCM,data:x,iv:y,tag:z,type:str]\nsops_version=3.13.3\n"
FILE_META = {
    "mac": "ENC[AES256_GCM,data:x,iv:y,tag:z,type:str]",
    "version": "3.13.3",
    "lastmodified": "2026-11-04T00:00:00Z",
    "age": [{"recipient": "age1test", "enc": "-----BEGIN AGE ENCRYPTED FILE-----\nx\n-----END AGE ENCRYPTED FILE-----\n"}],
}


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
            f.write("ENCRYPTED\n" + body + META)
        return path

    def whole(self, rel, content: bytes, meta=None, fail=False):
        """A stand-in binary-type sops document for a whole file."""
        import base64, json
        path = os.path.join(self.repo, "secrets", rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        iv = "FAIL" if fail else "y"
        doc = {"data": f"ENC[AES256_GCM,data:{base64.b64encode(content).decode()},iv:{iv},tag:z,type:str]",
               "sops": FILE_META if meta is None else meta}
        with open(path, "w") as f:
            json.dump(doc, f)
        return path

    def run_render(self, *extra):
        argv = ["--repo", self.repo, "--sops", self.sops, "--key", self.key, "--owner", ME,
                "--state-dir", os.path.join(self.tmp, "state"), *extra]
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
        # compose's dotenv grammar also accepts ':' and a space before '='
        self.secret(".env.sops", "COMPOSE_FILE: /tmp/evil.yml\n")
        self.assertEqual(self.run_render(), 1)
        self.secret(".env.sops", "COMPOSE_FILE =/tmp/evil.yml\n")
        self.assertEqual(self.run_render(), 1)
        self.secret(".env.sops", "DOCKER_HOST=tcp://evil:2375\n")
        self.assertEqual(self.run_render(), 1)
        self.assertFalse(self.exists(".env"))
        # an ordinary value with a colon is fine
        self.secret(".env.sops", "BASE_URL=https://example.org:8443\n")
        self.assertEqual(self.run_render(), 0)

    def test_recovery_file_is_never_rendered(self):
        self.secret("recovery.sops", "FAIL because the server cannot decrypt it\n")
        self.secret(".env.sops", "A=1\n")
        self.assertEqual(self.run_render(), 0)
        self.assertEqual(self.read(".env"), "A=1\n")

    def test_sops_error_output_is_never_shown(self):
        import contextlib, io
        self.secret(".env.sops", "FAIL SECRET_VALUE_XYZ\n")
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            self.assertEqual(self.run_render(), 1)
        self.assertNotIn("SECRET_VALUE_XYZ", buf.getvalue())
        self.assertIn("withheld", buf.getvalue())

    def test_a_fifo_in_secrets_is_refused_without_hanging(self):
        os.makedirs(os.path.join(self.repo, "secrets"))
        os.mkfifo(os.path.join(self.repo, "secrets", ".env.sops"))
        self.assertEqual(self.run_render(), 1)

    def test_a_fifo_at_the_target_is_replaced_without_hanging(self):
        os.mkfifo(os.path.join(self.repo, "apps/planka/.env"))
        self.secret("apps/planka/.env.sops", "A=1\n")
        self.assertEqual(self.run_render(), 0)
        self.assertEqual(self.read("apps/planka/.env"), "A=1\n")

    def test_non_age_key_sources_are_refused(self):
        for meta in ("sops_kms__list_0__map_arn=arn:aws:kms:x\n", "sops_hc_vault__list_0__map_vault_address=https://x\n",
                     "sops_pgp__list_0__map_fp=ABC\n"):
            with self.subTest(meta=meta):
                self.secret(".env.sops", "A=1\n" + meta)
                self.assertEqual(self.run_render(), 1)
                self.assertFalse(self.exists(".env"))

    def test_a_file_without_sops_metadata_is_refused(self):
        path = os.path.join(self.repo, "secrets", ".env.sops")
        os.makedirs(os.path.dirname(path))
        with open(path, "w") as f:
            f.write("ENCRYPTED\nA=1\n")
        self.assertEqual(self.run_render(), 1)

    def test_a_carriage_return_is_refused(self):
        self.secret(".env.sops", "A=1\rCOMPOSE_FILE=/tmp/x\n")
        self.assertEqual(self.run_render(), 1)
        self.assertFalse(self.exists(".env"))

    def test_stale_temporary_files_are_removed(self):
        stale = os.path.join(self.repo, "apps/planka/.env.vps-secrets-tmp-123-0")
        with open(stale, "w") as f:
            f.write("PLAINTEXT=old\n")
        self.secret("apps/planka/.env.sops", "A=1\n")
        self.assertEqual(self.run_render(), 0)
        self.assertFalse(os.path.exists(stale))

    def test_an_oversized_file_is_refused(self):
        self.secret(".env.sops", "A=" + "x" * (render.MAX_BYTES + 10) + "\n")
        self.assertEqual(self.run_render(), 1)

    def test_check_mode_writes_nothing(self):
        self.secret(".env.sops", "A=1\n")
        self.assertEqual(self.run_render("--check"), 0)
        self.assertFalse(self.exists(".env"))

    def test_secrets_without_a_server_key_stop_the_deploy(self):
        self.secret(".env.sops", "A=1\n")
        os.unlink(self.key)
        self.assertEqual(self.run_render(), 1)
        self.assertFalse(self.exists(".env"))


class WholeFileTests(Base):
    """Whole files: a secrets file whose name does not end in .env.sops is a
    binary-type sops document, written back byte for byte below a
    subdirectory of its app."""

    def setUp(self):
        super().setUp()
        os.makedirs(os.path.join(self.repo, "apps", "authelia", "config"))

    def read_bytes(self, rel):
        with open(os.path.join(self.repo, rel), "rb") as f:
            return f.read()

    def test_a_whole_file_is_rendered_byte_for_byte_with_mode_600(self):
        content = b"-----BEGIN PRIVATE KEY-----\n\x00\xff\r\nno trailing newline"
        self.whole("apps/authelia/config/oidc.pem.sops", content)
        self.secret("apps/planka/.env.sops", "A=1\n")
        self.assertEqual(self.run_render(), 0)
        self.assertEqual(self.read_bytes("apps/authelia/config/oidc.pem"), content)
        st = os.stat(os.path.join(self.repo, "apps/authelia/config/oidc.pem"))
        self.assertEqual(stat.S_IMODE(st.st_mode), 0o600)
        self.assertEqual(self.read("apps/planka/.env"), "A=1\n")
        leftovers = [n for n in os.listdir(os.path.join(self.repo, "apps/authelia/config")) if "vps-secrets" in n]
        self.assertEqual(leftovers, [])

    def test_the_dotenv_guards_do_not_apply_to_a_whole_file(self):
        # A user list may well contain text that the dotenv guard refuses.
        content = b"users:\n  a:\n    note: COMPOSE_FILE=x\r\n"
        self.whole("apps/authelia/config/users_database.yml.sops", content)
        self.assertEqual(self.run_render(), 0)
        self.assertEqual(self.read_bytes("apps/authelia/config/users_database.yml"), content)

    def test_an_unchanged_whole_file_is_not_rewritten(self):
        self.whole("apps/authelia/config/oidc.pem.sops", b"key")
        self.run_render()
        path = os.path.join(self.repo, "apps/authelia/config/oidc.pem")
        before = os.stat(path)
        self.assertEqual(self.run_render(), 0)
        after = os.stat(path)
        self.assertEqual((before.st_ino, before.st_ctime_ns), (after.st_ino, after.st_ctime_ns))

    def test_a_whole_file_at_an_app_top_level_or_outside_apps_is_refused(self):
        for rel in ("apps/authelia/oidc.pem.sops", "apps/authelia/deploy.sh.sops",
                    "apps/authelia/docker-compose.yml.sops", "backup/restic.key.sops",
                    "oidc.pem.sops", "apps/authelia/config/.hidden.sops",
                    "apps/authelia/../x/oidc.pem.sops"):
            with self.subTest(rel=rel):
                with self.assertRaises(render.RenderError):
                    render.target_for(rel)
        self.whole("apps/authelia/deploy.sh.sops", b"#!/bin/sh\n")
        self.secret(".env.sops", "A=1\n")
        self.assertEqual(self.run_render(), 1)
        self.assertFalse(self.exists("apps/authelia/deploy.sh"))
        self.assertFalse(self.exists(".env"))

    def test_a_whole_file_that_is_not_a_sops_document_is_refused(self):
        path = os.path.join(self.repo, "secrets", "apps", "authelia", "config", "oidc.pem.sops")
        os.makedirs(os.path.dirname(path))
        for raw in (b"-----BEGIN PRIVATE KEY-----\nplain\n", b'{"data": "plain", "sops": {"mac": "x"}}',
                    b'{"data": "ENC[AES256_GCM,data:eA==,iv:y,tag:z,type:str]"}',
                    b'{"data": "ENC[AES256_GCM,data:eA==,iv:y,tag:z,type:str]", "sops": {"version": "3.13.3"}}',
                    b'["ENC[AES256_GCM,data:eA==,iv:y,tag:z,type:str]"]', b"\xff\xfe"):
            with self.subTest(raw=raw[:20]):
                with open(path, "wb") as f:
                    f.write(raw)
                self.assertEqual(self.run_render(), 1)
                self.assertFalse(self.exists("apps/authelia/config/oidc.pem"))

    def test_a_whole_file_naming_another_key_source_is_refused(self):
        for extra in ("kms", "gcp_kms", "azure_kv", "hc_vault", "pgp"):
            with self.subTest(extra=extra):
                meta = dict(FILE_META, **{extra: [{"arn": "x"}]})
                self.whole("apps/authelia/config/oidc.pem.sops", b"key", meta=meta)
                self.assertEqual(self.run_render(), 1)
                self.assertFalse(self.exists("apps/authelia/config/oidc.pem"))

    def test_an_empty_whole_file_is_refused(self):
        self.whole("apps/authelia/config/oidc.pem.sops", b"")
        self.secret(".env.sops", "A=1\n")
        self.assertEqual(self.run_render(), 1)
        self.assertFalse(self.exists(".env"))

    def test_one_failed_whole_file_writes_nothing(self):
        self.whole("apps/authelia/config/oidc.pem.sops", b"key", fail=True)
        self.secret(".env.sops", "A=1\n")
        self.assertEqual(self.run_render(), 1)
        self.assertFalse(self.exists(".env"))
        self.assertFalse(self.exists("apps/authelia/config/oidc.pem"))

    def test_a_planted_link_at_a_whole_file_target_is_replaced_not_followed(self):
        victim = os.path.join(self.tmp, "victim")
        with open(victim, "w") as f:
            f.write("untouched\n")
        os.symlink(victim, os.path.join(self.repo, "apps/authelia/config/oidc.pem"))
        self.whole("apps/authelia/config/oidc.pem.sops", b"key")
        self.assertEqual(self.run_render(), 0)
        with open(victim) as f:
            self.assertEqual(f.read(), "untouched\n")
        path = os.path.join(self.repo, "apps/authelia/config/oidc.pem")
        self.assertFalse(os.path.islink(path))
        self.assertEqual(self.read_bytes("apps/authelia/config/oidc.pem"), b"key")

    def test_a_linked_subdirectory_is_refused_and_nothing_is_written(self):
        elsewhere = os.path.join(self.tmp, "elsewhere")
        os.makedirs(elsewhere)
        os.symlink(elsewhere, os.path.join(self.repo, "apps", "authelia", "linked"))
        self.whole("apps/authelia/linked/oidc.pem.sops", b"key")
        self.secret(".env.sops", "A=1\n")
        self.assertEqual(self.run_render(), 1)
        self.assertEqual(os.listdir(elsewhere), [])
        self.assertFalse(self.exists(".env"))

    def test_a_whole_file_is_removed_when_its_secrets_file_is_deleted(self):
        self.whole("apps/authelia/config/oidc.pem.sops", b"key")
        self.whole("apps/authelia/config/users_database.yml.sops", b"users: {}\n")
        self.secret("apps/planka/.env.sops", "A=1\n")
        self.assertEqual(self.run_render(), 0)
        os.unlink(os.path.join(self.repo, "secrets/apps/authelia/config/users_database.yml.sops"))
        self.assertEqual(self.run_render(), 0)
        self.assertFalse(self.exists("apps/authelia/config/users_database.yml"))
        self.assertTrue(self.exists("apps/authelia/config/oidc.pem"))
        self.assertTrue(self.exists("apps/planka/.env"))
        # A second run finds nothing more to remove.
        self.assertEqual(self.run_render(), 0)

    def test_a_dotenv_file_is_not_removed_when_its_secrets_file_is_deleted(self):
        self.secret("apps/planka/.env.sops", "A=1\n")
        self.whole("apps/authelia/config/oidc.pem.sops", b"key")
        self.assertEqual(self.run_render(), 0)
        os.unlink(os.path.join(self.repo, "secrets/apps/planka/.env.sops"))
        self.assertEqual(self.run_render(), 0)
        self.assertTrue(self.exists("apps/planka/.env"))

    def test_removal_covers_an_emptied_secrets_directory(self):
        self.whole("apps/authelia/config/oidc.pem.sops", b"key")
        self.assertEqual(self.run_render(), 0)
        shutil.rmtree(os.path.join(self.repo, "secrets"))
        self.assertEqual(self.run_render(), 0)
        self.assertFalse(self.exists("apps/authelia/config/oidc.pem"))

    def test_removal_leaves_a_link_or_someone_elses_file_alone(self):
        self.whole("apps/authelia/config/oidc.pem.sops", b"key")
        self.assertEqual(self.run_render(), 0)
        os.unlink(os.path.join(self.repo, "secrets/apps/authelia/config/oidc.pem.sops"))
        victim = os.path.join(self.tmp, "victim")
        with open(victim, "w") as f:
            f.write("untouched\n")
        path = os.path.join(self.repo, "apps/authelia/config/oidc.pem")
        os.unlink(path)
        os.symlink(victim, path)
        self.assertEqual(self.run_render(), 0)
        self.assertTrue(os.path.islink(path))
        self.assertTrue(os.path.exists(victim))

    def test_check_mode_writes_no_whole_file_and_records_nothing(self):
        self.whole("apps/authelia/config/oidc.pem.sops", b"key")
        self.assertEqual(self.run_render("--check"), 0)
        self.assertFalse(self.exists("apps/authelia/config/oidc.pem"))
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "state")))

    def test_the_record_is_root_only_and_drops_vanished_repositories(self):
        self.whole("apps/authelia/config/oidc.pem.sops", b"key")
        self.assertEqual(self.run_render(), 0)
        state_dir = os.path.join(self.tmp, "state")
        self.assertEqual(stat.S_IMODE(os.stat(state_dir).st_mode), 0o700)
        record = os.path.join(state_dir, render.STATE_FILE)
        self.assertEqual(stat.S_IMODE(os.stat(record).st_mode), 0o600)
        with open(record, "a") as f:
            f.write(f"{self.tmp}/gone-release\tapps/x/y/z\n")
        self.assertEqual(self.run_render(), 0)
        with open(record) as f:
            lines = f.read().splitlines()
        self.assertEqual(lines, [f"{os.path.realpath(self.repo)}\tapps/authelia/config/oidc.pem"])


@unittest.skipUnless(shutil.which("sops") and shutil.which("age-keygen"), "real sops/age not installed")
class ResticInstallTests(Base):
    """--restic-dir: the rendered backup set is installed for restic and a
    service the repo no longer carries is removed."""

    def setUp(self):
        super().setUp()
        self.restic = os.path.join(self.tmp, "restic")

    def rpath(self, rel):
        return os.path.join(self.restic, rel)

    def test_without_the_flag_the_restic_directory_is_untouched(self):
        self.secret("backup/config.env.sops", "RESTIC_PASSWORD=a\n")
        self.assertEqual(self.run_render(), 0)
        self.assertFalse(os.path.exists(self.restic))

    def test_the_backup_set_is_installed_mode_600_in_a_700_directory(self):
        self.secret("backup/config.env.sops", "RESTIC_PASSWORD=a\n")
        self.secret("backup/services/planka.env.sops", "SERVICE=planka\n")
        self.assertEqual(self.run_render("--restic-dir", self.restic), 0)
        with open(self.rpath("config.env")) as f:
            self.assertEqual(f.read(), "RESTIC_PASSWORD=a\n")
        with open(self.rpath("services/planka.env")) as f:
            self.assertEqual(f.read(), "SERVICE=planka\n")
        for rel in ("config.env", "services/planka.env"):
            self.assertEqual(stat.S_IMODE(os.stat(self.rpath(rel)).st_mode), 0o600)
        for rel in ("", "services"):
            self.assertEqual(stat.S_IMODE(os.stat(self.rpath(rel)).st_mode), 0o700)
        # The checkout copies are still rendered as before.
        self.assertEqual(self.read("backup/config.env"), "RESTIC_PASSWORD=a\n")

    def test_a_service_the_repo_no_longer_carries_is_removed(self):
        os.makedirs(self.rpath("services"))
        with open(self.rpath("services/retired.env"), "w") as f:
            f.write("SERVICE=retired\n")
        with open(self.rpath("services/notes.txt"), "w") as f:
            f.write("kept: not an env file\n")
        self.secret("backup/config.env.sops", "RESTIC_PASSWORD=a\n")
        self.secret("backup/services/planka.env.sops", "SERVICE=planka\n")
        self.assertEqual(self.run_render("--restic-dir", self.restic), 0)
        self.assertFalse(os.path.exists(self.rpath("services/retired.env")))
        self.assertTrue(os.path.exists(self.rpath("services/notes.txt")))
        self.assertTrue(os.path.exists(self.rpath("services/planka.env")))

    def test_an_unchanged_restic_file_is_not_rewritten(self):
        self.secret("backup/config.env.sops", "RESTIC_PASSWORD=a\n")
        self.assertEqual(self.run_render("--restic-dir", self.restic), 0)
        before = os.stat(self.rpath("config.env")).st_ino
        self.assertEqual(self.run_render("--restic-dir", self.restic), 0)
        self.assertEqual(os.stat(self.rpath("config.env")).st_ino, before)

    def test_a_repo_without_a_backup_set_leaves_the_directory_alone(self):
        os.makedirs(self.rpath("services"))
        with open(self.rpath("services/hand.env"), "w") as f:
            f.write("SERVICE=hand-managed\n")
        self.secret("apps/planka/.env.sops", "A=1\n")
        self.assertEqual(self.run_render("--restic-dir", self.restic), 0)
        self.assertTrue(os.path.exists(self.rpath("services/hand.env")))

    def test_services_without_a_config_are_refused_and_nothing_is_installed(self):
        self.secret("backup/services/planka.env.sops", "SERVICE=planka\n")
        self.assertEqual(self.run_render("--restic-dir", self.restic), 1)
        self.assertFalse(os.path.exists(self.rpath("services/planka.env")))

    def test_check_mode_installs_nothing(self):
        self.secret("backup/config.env.sops", "RESTIC_PASSWORD=a\n")
        self.assertEqual(self.run_render("--check", "--restic-dir", self.restic), 0)
        self.assertFalse(os.path.exists(self.restic))


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

    def test_a_whole_file_round_trips_with_real_encryption(self):
        os.unlink(self.key)
        subprocess.run(["age-keygen", "-o", self.key], check=True, capture_output=True)
        pub = subprocess.run(["age-keygen", "-y", self.key], check=True, capture_output=True, text=True).stdout.strip()
        content = os.urandom(1704) + b"\n-----END-----"  # a key-sized blob, no trailing newline
        plain = os.path.join(self.tmp, "oidc.pem")
        with open(plain, "wb") as f:
            f.write(content)
        enc = subprocess.run(
            ["sops", "--encrypt", "--age", pub, "--input-type", "binary", "--output-type", "binary", plain],
            check=True, capture_output=True,
        ).stdout
        self.assertNotIn(content[:16], enc)
        path = os.path.join(self.repo, "secrets", "apps", "authelia", "config", "oidc.pem.sops")
        os.makedirs(os.path.dirname(path))
        os.makedirs(os.path.join(self.repo, "apps", "authelia", "config"))
        with open(path, "wb") as f:
            f.write(enc)
        argv = ["--repo", self.repo, "--sops", shutil.which("sops"), "--key", self.key, "--owner", ME,
                "--state-dir", os.path.join(self.tmp, "state")]
        self.assertEqual(render.main(argv), 0)
        with open(os.path.join(self.repo, "apps/authelia/config/oidc.pem"), "rb") as f:
            self.assertEqual(f.read(), content)
        # The same document is refused as a dotenv file and a dotenv document
        # as a whole file: the name decides the mode, and sops holds it to it.
        os.rename(path, os.path.join(self.repo, "secrets", "apps", "authelia", "config", "wrong.env.sops"))
        self.assertEqual(render.main(argv), 1)

    def test_a_tampered_whole_file_fails_cleanly(self):
        import json
        os.unlink(self.key)
        subprocess.run(["age-keygen", "-o", self.key], check=True, capture_output=True)
        pub = subprocess.run(["age-keygen", "-y", self.key], check=True, capture_output=True, text=True).stdout.strip()
        plain = os.path.join(self.tmp, "u.yml")
        with open(plain, "w") as f:
            f.write("users: {}\n")
        enc = json.loads(subprocess.run(
            ["sops", "--encrypt", "--age", pub, "--input-type", "binary", "--output-type", "binary", plain],
            check=True, capture_output=True,
        ).stdout)
        enc["data"] = enc["data"][:-6] + "AAAA" + enc["data"][-6:]
        path = os.path.join(self.repo, "secrets", "apps", "authelia", "config", "users_database.yml.sops")
        os.makedirs(os.path.dirname(path))
        os.makedirs(os.path.join(self.repo, "apps", "authelia", "config"))
        with open(path, "w") as f:
            json.dump(enc, f)
        argv = ["--repo", self.repo, "--sops", shutil.which("sops"), "--key", self.key, "--owner", ME,
                "--state-dir", os.path.join(self.tmp, "state")]
        self.assertEqual(render.main(argv), 1)
        self.assertFalse(self.exists("apps/authelia/config/users_database.yml"))

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
