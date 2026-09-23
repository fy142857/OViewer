"""One-time local signing setup. Requires keytool and PyNaCl; never run in CI.

Secrets stay in a private directory outside the checkout. Re-running uses the
same key. Back up the whole directory independently before relying on it.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess

from scripts.versioning.github import GitHub, json_text
from scripts.versioning.rules import VersionError


def setup(directory: Path, repository: str):
    directory = directory.expanduser().resolve()
    root = Path(__file__).resolve().parents[1]
    if directory == root or root in directory.parents:
        raise VersionError("Signing material must be stored outside the repository")
    keytool = shutil.which("keytool")
    if not keytool:
        raise VersionError("keytool is required")
    from nacl.public import PublicKey, SealedBox

    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if os.name == "nt":
        identity = subprocess.run(["whoami"], check=True, capture_output=True, text=True).stdout.strip()
        subprocess.run(["icacls", str(directory), "/inheritance:r", "/grant:r", f"{identity}:(OI)(CI)F", "SYSTEM:(OI)(CI)F"], check=True, capture_output=True)
    credentials = directory / "credentials.json"
    keystore = directory / "oviewer-release.jks"
    if not credentials.exists():
        if keystore.exists():
            raise VersionError("Keystore exists without credentials; refusing to replace it")
        values = {"store_password": secrets.token_urlsafe(40), "key_password": secrets.token_urlsafe(40), "alias": "oviewer"}
        descriptor = os.open(credentials, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(json_text(values))
    values = json.loads(credentials.read_text(encoding="utf-8"))
    env = {**os.environ, "OVIEWER_STORE_PASSWORD": values["store_password"], "OVIEWER_KEY_PASSWORD": values["key_password"]}
    if not keystore.exists():
        subprocess.run([keytool, "-genkeypair", "-noprompt", "-keystore", str(keystore), "-storetype", "JKS",
                        "-storepass:env", "OVIEWER_STORE_PASSWORD", "-keypass:env", "OVIEWER_KEY_PASSWORD",
                        "-alias", values["alias"], "-keyalg", "RSA", "-keysize", "3072", "-sigalg", "SHA256withRSA",
                        "-validity", "36500", "-dname", "CN=OViewer, O=OViewer, C=CN"], env=env, capture_output=True, check=True)
    certificate = subprocess.run([keytool, "-exportcert", "-keystore", str(keystore), "-storepass:env", "OVIEWER_STORE_PASSWORD",
                                  "-alias", values["alias"]], env=env, capture_output=True, check=True).stdout
    fingerprint = hashlib.sha256(certificate).hexdigest()
    (directory / "certificate.der").write_bytes(certificate)
    (directory / "SHA256.txt").write_text(fingerprint + "\n", encoding="utf-8")
    result = subprocess.run(["git", "credential", "fill"], input="protocol=https\nhost=github.com\n\n", capture_output=True, text=True,
                            check=True, env={**os.environ, "GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "Never"})
    credential = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    api = GitHub(repository, credential["password"])
    variable = "ANDROID_SIGNING_CERT_SHA256"
    existing = api.optional(f"/actions/variables/{variable}")
    if existing and existing["value"].lower() != fingerprint:
        raise VersionError("Existing signing fingerprint differs; refusing to replace any configuration")
    receipt = directory / "github-provisioning.json"
    intended = {"repository": repository, "certificate_sha256": fingerprint}
    if receipt.exists() and json.loads(receipt.read_text(encoding="utf-8")) != intended:
        raise VersionError("This key directory was provisioned for a different repository")
    remote_names = {item["name"] for item in api.pages("/actions/secrets", "secrets")}
    signing_names = {"ANDROID_KEYSTORE_BASE64", "ANDROID_KEYSTORE_PASSWORD", "ANDROID_KEY_ALIAS", "ANDROID_KEY_PASSWORD"}
    if remote_names & signing_names and not existing and not receipt.exists():
        raise VersionError("Unmanaged signing secrets already exist; refusing to replace them")
    receipt.write_text(json_text(intended), encoding="utf-8")
    public = api.request("/actions/secrets/public-key")
    box = SealedBox(PublicKey(base64.b64decode(public["key"])))
    values = {"ANDROID_KEYSTORE_BASE64": base64.b64encode(keystore.read_bytes()).decode(), "ANDROID_KEYSTORE_PASSWORD": values["store_password"],
              "ANDROID_KEY_ALIAS": values["alias"], "ANDROID_KEY_PASSWORD": values["key_password"]}
    # Encrypted using GitHub's repository public key before leaving this process.
    for name, value in values.items():
        encrypted = base64.b64encode(box.encrypt(value.encode())).decode()
        api.request(f"/actions/secrets/{name}", {"key_id": public["key_id"], "encrypted_value": encrypted}, "PUT")
    if not existing:
        api.request("/actions/variables", {"name": variable, "value": fingerprint})
    print(f"Signing directory: {directory}\nCertificate SHA-256: {fingerprint}\nFour encrypted Actions secrets configured. Keep an independent backup of this directory.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--repository", required=True)
    args = parser.parse_args()
    setup(args.directory, args.repository)
