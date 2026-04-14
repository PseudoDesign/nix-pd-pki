from __future__ import annotations

import argparse
import datetime
import sys
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from ykman.device import list_all_devices
from ykman.piv import parse_rfc4514_string, sign_certificate_builder
from yubikit.core import NotSupportedError, _timeout
from yubikit.core.smartcard import SW, ApduError, SmartCardConnection
from yubikit.piv import KEY_TYPE, PivSession, SLOT, TOUCH_POLICY


def hash_algorithm(name: str):
    normalized = name.strip().lower()
    if normalized == "sha256":
        return hashes.SHA256
    if normalized == "sha384":
        return hashes.SHA384
    if normalized == "sha512":
        return hashes.SHA512
    raise ValueError(f"Unsupported hash algorithm: {name}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate and store a self-signed root CA certificate on a YubiKey PIV slot."
    )
    parser.add_argument("--yubikey-serial", required=True, type=int)
    parser.add_argument("--slot", required=True)
    parser.add_argument("--public-key", required=True)
    parser.add_argument("--subject", required=True)
    parser.add_argument("--valid-days", required=True, type=int)
    parser.add_argument("--hash-algorithm", required=True)
    parser.add_argument("--pin", required=True)
    parser.add_argument("--management-key-hex", required=True)
    parser.add_argument("--out-cert", required=True)
    return parser.parse_args()


def prompt_for_touch(prompt: str = "Touch your YubiKey...") -> None:
    print(prompt, file=sys.stderr)


def sign_certificate_with_touch_retry(
    session: PivSession,
    slot: SLOT,
    key_type: KEY_TYPE,
    builder: x509.CertificateBuilder,
    digest,
    timeout: float,
    max_attempts: int = 5,
):
    for attempt in range(1, max_attempts + 1):
        prompt = "Touch your YubiKey..."
        if attempt > 1:
            prompt = f"Touch not detected. Touch your YubiKey... ({attempt}/{max_attempts})"

        try:
            with _timeout(lambda: prompt_for_touch(prompt), timeout):
                return sign_certificate_builder(session, slot, key_type, builder, digest)
        except ApduError as error:
            if error.sw != SW.SECURITY_CONDITION_NOT_SATISFIED or attempt == max_attempts:
                raise

    raise RuntimeError("unreachable")


def main() -> int:
    args = parse_args()

    public_key_path = Path(args.public_key)
    output_path = Path(args.out_cert)
    public_key = serialization.load_pem_public_key(public_key_path.read_bytes())
    slot = SLOT(int(args.slot, 16))
    key_type = KEY_TYPE.from_public_key(public_key)
    subject = parse_rfc4514_string(args.subject)
    digest = hash_algorithm(args.hash_algorithm)
    now = datetime.datetime.now(datetime.timezone.utc)
    valid_to = now + datetime.timedelta(days=args.valid_days)

    subject_key_identifier = x509.SubjectKeyIdentifier.from_public_key(public_key)
    builder = (
        x509.CertificateBuilder()
        .public_key(public_key)
        .subject_name(subject)
        .issuer_name(subject)
        .serial_number(x509.random_serial_number())
        .not_valid_before(now)
        .not_valid_after(valid_to)
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=False,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=True,
                crl_sign=True,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(subject_key_identifier, critical=False)
        .add_extension(
            x509.AuthorityKeyIdentifier.from_issuer_public_key(public_key),
            critical=False,
        )
    )

    for device, info in list_all_devices([SmartCardConnection]):
        if info.serial != args.yubikey_serial:
            continue

        with device.open_connection(SmartCardConnection) as connection:
            session = PivSession(connection)
            session.authenticate(bytes.fromhex(args.management_key_hex))
            session.verify_pin(args.pin)

            try:
                metadata = session.get_slot_metadata(slot)
                if metadata.touch_policy in (TOUCH_POLICY.ALWAYS, TOUCH_POLICY.CACHED):
                    timeout = 0.0
                else:
                    timeout = 30.0
            except ApduError as error:
                if error.sw == SW.REFERENCE_DATA_NOT_FOUND:
                    print(f"No private key in slot {slot.name}.", file=sys.stderr)
                    return 1
                raise
            except NotSupportedError:
                timeout = 1.0

            certificate = sign_certificate_with_touch_retry(
                session, slot, key_type, builder, digest, timeout
            )
            session.put_certificate(slot, certificate)
            output_path.write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
            return 0

    print(
        f"Failed to connect to a YubiKey with serial: {args.yubikey_serial}",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
