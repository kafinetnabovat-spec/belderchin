#!/usr/bin/env python3
"""Belderchin source-list signing tool (Ed25519).

The app only ships the *public* key. The private key lives with the maintainer,
outside of any git repository. Never commit it, never paste it into CI logs.

    pip install cryptography

Commands
--------
  gen-key  --out DIR [--key-id ID]
      Generates a new Ed25519 key pair. Writes DIR/<key-id>.private.hex (mode 600)
      and DIR/<key-id>.public.hex, and prints the Dart snippet to embed in
      lib/features/sources/data/trusted_keys.dart.

  sign     --key FILE --key-id ID --in sources.json --out sources.signed.json
           [--version N] [--issue-now] [--valid-days D]
      Validates sources.json, optionally bumps version / issued_at / expires_at,
      and writes the signed envelope consumed by the app.

  verify   --pub HEX_OR_FILE --in sources.signed.json
      Verifies the envelope exactly like the app does and prints a summary.

  show     --in sources.signed.json
      Prints the decoded payload without verifying (for inspection only).

Envelope format (JSON):
  {
    "format": "belderchin-sources/1",
    "key_id": "<id>",
    "payload": "<base64 of UTF-8 JSON bytes>",
    "signature": "<base64 of 64-byte Ed25519 signature>"
  }
The signature covers  SIGNING_PREFIX + payload_bytes  (domain separation).
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import ipaddress
import json
import os
import pathlib
import re
import sys

try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
    from cryptography.exceptions import InvalidSignature
except ImportError:  # pragma: no cover
    sys.exit("missing dependency: pip install cryptography")

FORMAT = "belderchin-sources/1"
SIGNING_PREFIX = b"belderchin-sources-v1:"
KEY_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{1,31}$")
URL_RE = re.compile(r"^https://[^\s]+$")


# ----------------------------------------------------------------------------- helpers
def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def _iso(ts: dt.datetime) -> str:
    return ts.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso(value: str, field: str) -> dt.datetime:
    try:
        return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except (TypeError, ValueError):
        raise SystemExit(f"{field}: expected UTC timestamp like 2026-01-31T12:00:00Z, got {value!r}")


def _load_key_bytes(value: str) -> bytes:
    path = pathlib.Path(value)
    text = path.read_text().strip() if path.exists() else value.strip()
    try:
        raw = bytes.fromhex(text)
    except ValueError:
        raise SystemExit("key must be 32 bytes hex (or a file containing it)")
    if len(raw) != 32:
        raise SystemExit(f"key must be 32 bytes, got {len(raw)}")
    return raw


def canonical_payload(obj: dict) -> bytes:
    """Compact, sorted-keys JSON. The app verifies the bytes it receives, so any
    stable serialisation works; canonical form keeps diffs/reviews readable."""
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")


# ----------------------------------------------------------------------------- schema
def validate_sources(obj: dict) -> list[str]:
    """Returns a list of human readable problems (empty == OK).
    Mirrors the checks in lib/features/sources/model/source_list.dart."""
    problems: list[str] = []

    def req(key, typ, where=obj, prefix=""):
        if key not in where:
            problems.append(f"{prefix}{key}: missing")
            return None
        if not isinstance(where[key], typ):
            problems.append(f"{prefix}{key}: expected {typ.__name__}")
            return None
        return where[key]

    version = req("version", int)
    if version is not None and version < 1:
        problems.append("version: must be >= 1")
    issued = req("issued_at", str)
    expires = req("expires_at", str)
    if issued and expires:
        i, e = _parse_iso(issued, "issued_at"), _parse_iso(expires, "expires_at")
        if e <= i:
            problems.append("expires_at must be after issued_at")
    mav = obj.get("min_app_version")
    if mav is not None and not re.match(r"^\d+\.\d+\.\d+$", str(mav)):
        problems.append("min_app_version: expected X.Y.Z")

    mirrors = obj.get("mirrors", [])
    if not isinstance(mirrors, list) or any(not (isinstance(m, str) and URL_RE.match(m)) for m in mirrors):
        problems.append("mirrors: must be a list of https URLs")

    hc = obj.get("health_check")
    if hc is not None:
        if not isinstance(hc, dict):
            problems.append("health_check: expected object")
        else:
            urls = hc.get("urls", [])
            if not isinstance(urls, list) or not urls or any(not isinstance(u, str) or not u.startswith("http") for u in urls):
                problems.append("health_check.urls: non-empty list of http(s) URLs")
            ms = hc.get("min_success", 1)
            if not isinstance(ms, int) or ms < 1 or (isinstance(urls, list) and ms > len(urls)):
                problems.append("health_check.min_success: 1..len(urls)")

    warp = obj.get("warp")
    if warp is not None:
        if not isinstance(warp, dict):
            problems.append("warp: expected object")
        else:
            if not isinstance(warp.get("enabled", True), bool):
                problems.append("warp.enabled: expected bool")
            for cidr in warp.get("endpoints", []):
                try:
                    ipaddress.ip_network(cidr, strict=False)
                except ValueError:
                    problems.append(f"warp.endpoints: invalid CIDR {cidr!r}")
            for port in warp.get("ports", []):
                if not isinstance(port, int) or not (1 <= port <= 65535):
                    problems.append(f"warp.ports: invalid port {port!r}")

    seen_ids: set[str] = set()
    for layer in ("workers", "backup"):
        entries = obj.get(layer, [])
        if not isinstance(entries, list):
            problems.append(f"{layer}: expected list")
            continue
        for idx, entry in enumerate(entries):
            where = f"{layer}[{idx}]."
            if not isinstance(entry, dict):
                problems.append(f"{layer}[{idx}]: expected object")
                continue
            sid = req("id", str, entry, where)
            if sid:
                if sid in seen_ids:
                    problems.append(f"{where}id: duplicate {sid!r}")
                seen_ids.add(sid)
            req("name", str, entry, where)
            has_url = isinstance(entry.get("url"), str) and URL_RE.match(entry["url"])
            has_content = isinstance(entry.get("content"), str) and entry["content"].strip()
            if not has_url and not has_content:
                problems.append(f"{where}: needs 'url' (https) or 'content'")
            weight = entry.get("weight", 1)
            if not isinstance(weight, int) or weight < 0:
                problems.append(f"{where}weight: non-negative int")
    return problems


# ----------------------------------------------------------------------------- commands
def cmd_gen_key(args: argparse.Namespace) -> int:
    key_id = args.key_id or f"bld-{_now():%Y%m}"
    if not KEY_ID_RE.match(key_id):
        raise SystemExit("key id: lowercase letters, digits, dashes, 2-32 chars")
    out = pathlib.Path(args.out).expanduser().resolve()
    out.mkdir(parents=True, exist_ok=True)
    private = Ed25519PrivateKey.generate()
    priv_hex = private.private_bytes_raw().hex()
    pub_hex = private.public_key().public_bytes_raw().hex()
    priv_path = out / f"{key_id}.private.hex"
    pub_path = out / f"{key_id}.public.hex"
    if priv_path.exists():
        raise SystemExit(f"refusing to overwrite {priv_path}")
    fd = os.open(priv_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(priv_hex + "\n")
    pub_path.write_text(pub_hex + "\n")
    print(f"private key : {priv_path}  (keep offline, never commit)")
    print(f"public key  : {pub_path}")
    print("\nEmbed in lib/features/sources/data/trusted_keys.dart:\n")
    print(f"  TrustedKey(id: '{key_id}', publicKeyHex: '{pub_hex}'),")
    return 0


def _read_json(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def cmd_sign(args: argparse.Namespace) -> int:
    if not KEY_ID_RE.match(args.key_id):
        raise SystemExit("key id: lowercase letters, digits, dashes, 2-32 chars")
    private = Ed25519PrivateKey.from_private_bytes(_load_key_bytes(args.key))
    obj = _read_json(args.inp)
    if args.version is not None:
        obj["version"] = args.version
    if args.issue_now:
        obj["issued_at"] = _iso(_now())
    if args.valid_days is not None:
        base = _parse_iso(obj.get("issued_at", _iso(_now())), "issued_at")
        obj["expires_at"] = _iso(base + dt.timedelta(days=args.valid_days))
    problems = validate_sources(obj)
    if problems:
        print("sources.json is invalid:", file=sys.stderr)
        for p in problems:
            print("  -", p, file=sys.stderr)
        return 2
    payload = canonical_payload(obj)
    signature = private.sign(SIGNING_PREFIX + payload)
    envelope = {
        "format": FORMAT,
        "key_id": args.key_id,
        "payload": base64.b64encode(payload).decode("ascii"),
        "signature": base64.b64encode(signature).decode("ascii"),
    }
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(envelope, fh, indent=2)
        fh.write("\n")
    if args.rewrite_input:
        with open(args.inp, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
    print(f"signed version {obj['version']} (issued {obj['issued_at']}, expires {obj['expires_at']}) -> {args.out}")
    return 0


def verify_envelope(envelope: dict, public_key: bytes) -> dict:
    if envelope.get("format") != FORMAT:
        raise ValueError(f"unsupported format {envelope.get('format')!r}")
    payload = base64.b64decode(envelope["payload"], validate=True)
    signature = base64.b64decode(envelope["signature"], validate=True)
    Ed25519PublicKey.from_public_bytes(public_key).verify(signature, SIGNING_PREFIX + payload)
    obj = json.loads(payload.decode("utf-8"))
    problems = validate_sources(obj)
    if problems:
        raise ValueError("payload schema problems: " + "; ".join(problems))
    return obj


def cmd_verify(args: argparse.Namespace) -> int:
    envelope = _read_json(args.inp)
    try:
        obj = verify_envelope(envelope, _load_key_bytes(args.pub))
    except InvalidSignature:
        print("SIGNATURE INVALID", file=sys.stderr)
        return 1
    except (ValueError, KeyError) as exc:
        print(f"INVALID: {exc}", file=sys.stderr)
        return 1
    _print_summary(obj, envelope.get("key_id"))
    print("signature OK")
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    envelope = _read_json(args.inp)
    obj = json.loads(base64.b64decode(envelope["payload"]).decode("utf-8"))
    print(json.dumps(obj, ensure_ascii=False, indent=2))
    return 0


def _print_summary(obj: dict, key_id: str | None) -> None:
    now = _now()
    expires = _parse_iso(obj["expires_at"], "expires_at")
    print(f"key id      : {key_id}")
    print(f"version     : {obj['version']}")
    print(f"issued_at   : {obj['issued_at']}")
    print(f"expires_at  : {obj['expires_at']}  ({'EXPIRED' if expires <= now else f'{(expires - now).days} days left'})")
    print(f"mirrors     : {len(obj.get('mirrors', []))}")
    print(f"warp        : {'enabled' if obj.get('warp', {}).get('enabled', False) else 'disabled'}")
    print(f"workers     : {len(obj.get('workers', []))}")
    print(f"backup      : {len(obj.get('backup', []))}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("gen-key")
    p.add_argument("--out", required=True)
    p.add_argument("--key-id")
    p.set_defaults(func=cmd_gen_key)

    p = sub.add_parser("sign")
    p.add_argument("--key", required=True, help="private key hex or file")
    p.add_argument("--key-id", required=True)
    p.add_argument("--in", dest="inp", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--version", type=int)
    p.add_argument("--issue-now", action="store_true")
    p.add_argument("--valid-days", type=int)
    p.add_argument("--rewrite-input", action="store_true", help="write the bumped fields back into --in")
    p.set_defaults(func=cmd_sign)

    p = sub.add_parser("verify")
    p.add_argument("--pub", required=True, help="public key hex or file")
    p.add_argument("--in", dest="inp", required=True)
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser("show")
    p.add_argument("--in", dest="inp", required=True)
    p.set_defaults(func=cmd_show)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
