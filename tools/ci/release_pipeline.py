#!/usr/bin/env python3
"""Maintainer tool: publish Belderchin to GitHub and run the release workflow.

Authentication uses GitHub's OAuth *device flow* (the same mechanism as
`gh auth login --web`, using GitHub CLI's public client id): the script prints
a one-time code, the maintainer enters it at https://github.com/login/device,
and the resulting token lives only in this process' memory. Nothing secret is
ever written to disk or printed.

Steps (each can be skipped with flags):
  1. full clone of upstream hiddify-app into a scratch dir, our commits fetched
     on top, `main` pushed to the target repository (no tags are pushed - tags
     would trigger release builds for every upstream version);
  2. Android signing secrets uploaded (libsodium sealed box) from a keystore
     file plus an env file with the passwords;
  3. `android-release.yml` dispatched with publish_release=true and watched
     until it finishes; release asset URLs are printed.

Afterwards the process stays alive for a while and accepts simple commands
from a command file (one per line): dispatch | push | runs | logs <run_id> |
release | quit. This lets a maintainer re-run steps without authenticating
again.
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

GH_CLI_CLIENT_ID = "178c6fc778ccc68e1d6a"  # GitHub CLI's public OAuth app id
API = "https://api.github.com"


def log(msg: str) -> None:
    print(time.strftime("%H:%M:%S"), msg, flush=True)


# --------------------------------------------------------------------------- http
def http(method: str, url: str, token: str | None = None, data=None, headers=None, raw=False):
    body = None
    hdrs = {"Accept": "application/vnd.github+json", "User-Agent": "belderchin-release-pipeline"}
    if headers:
        hdrs.update(headers)
    if token:
        hdrs["Authorization"] = f"Bearer {token}"
    if data is not None:
        if hdrs.get("Content-Type") == "application/x-www-form-urlencoded":
            body = urllib.parse.urlencode(data).encode()
        else:
            hdrs["Content-Type"] = "application/json"
            body = json.dumps(data).encode()
    req = urllib.request.Request(url, data=body, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            payload = resp.read()
            if raw:
                return resp.status, payload
            return resp.status, (json.loads(payload) if payload else {})
    except urllib.error.HTTPError as e:
        payload = e.read()
        try:
            parsed = json.loads(payload) if payload else {}
        except ValueError:
            parsed = {"raw": payload[:200].decode(errors="replace")}
        return e.code, parsed


# ------------------------------------------------------------------ device flow
FORM = {"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"}


def request_device_code(scope: str) -> dict:
    status, d = http(
        "POST",
        "https://github.com/login/device/code",
        data={"client_id": GH_CLI_CLIENT_ID, "scope": scope},
        headers=FORM,
    )
    if status != 200 or "device_code" not in d:
        raise SystemExit(f"device code request failed: {status} {d}")
    d["expires_at"] = time.time() + int(d.get("expires_in", 900))
    return d


def announce_code(d: dict) -> None:
    print("=" * 64, flush=True)
    print(f"USER_CODE: {d['user_code']}", flush=True)
    print(f"VERIFY_URL: {d['verification_uri']}", flush=True)
    print(f"EXPIRES_IN_SECONDS: {int(d['expires_at'] - time.time())}", flush=True)
    print("=" * 64, flush=True)


def poll_token(d: dict) -> str:
    """Exchange an authorized device code for a token (kept in memory only)."""
    interval = int(d.get("interval", 5))
    while time.time() < d["expires_at"]:
        status, t = http(
            "POST",
            "https://github.com/login/oauth/access_token",
            data={
                "client_id": GH_CLI_CLIENT_ID,
                "device_code": d["device_code"],
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            },
            headers=FORM,
        )
        if "access_token" in t:
            log("authorized (token kept in memory only)")
            return t["access_token"]
        err = t.get("error")
        if err == "slow_down":
            interval += 5
        elif err != "authorization_pending":
            raise SystemExit(f"device flow ended: {err or t}")
        time.sleep(interval)
    raise SystemExit("device code expired before it was entered")


def obtain_token(args, scope: str = "repo workflow") -> str:
    """Two-step mode (for environments that cannot keep a process alive while
    the maintainer authorizes): `--issue-code` stores the pending device code in
    `--device-code-file`; a later run picks it up and exchanges it."""
    path = args.device_code_file
    if args.issue_code:
        d = request_device_code(scope)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(d, fh)
        announce_code(d)
        raise SystemExit(0)
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
        os.remove(path)
        if time.time() > d["expires_at"]:
            raise SystemExit("stored device code has expired; run again with --issue-code")
        log("exchanging the stored device code")
        return poll_token(d)
    d = request_device_code(scope)
    announce_code(d)
    return poll_token(d)


# -------------------------------------------------------------------------- git
def run(cmd, env=None, cwd=None, check=True):
    log("$ " + " ".join(cmd))
    r = subprocess.run(cmd, cwd=cwd, env=env, text=True, capture_output=True)
    if r.stdout.strip():
        print(r.stdout.strip()[-4000:], flush=True)
    if r.stderr.strip():
        print(r.stderr.strip()[-4000:], flush=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"command failed ({r.returncode}): {' '.join(cmd)}")
    return r


def git_auth_env(token: str) -> dict:
    env = dict(os.environ)
    env.update(
        {
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "http.https://github.com/.extraheader",
            "GIT_CONFIG_VALUE_0": "AUTHORIZATION: basic "
            + base64.b64encode(f"x-access-token:{token}".encode()).decode(),
        }
    )
    return env


def prepare_scratch(args) -> str:
    scratch = os.path.join(args.work, "upstream.git")
    if not os.path.isdir(scratch):
        os.makedirs(args.work, exist_ok=True)
        run(["git", "clone", "--bare", "--single-branch", "--branch", args.upstream_branch, args.upstream, scratch])
        run(["git", "-C", scratch, "fetch", "--no-tags", "origin", f"refs/tags/{args.base_tag}:refs/tags/{args.base_tag}"])
    run(["git", "-C", scratch, "fetch", "--no-tags", args.source, f"+{args.branch}:refs/heads/belderchin-main"])
    run(["git", "-C", scratch, "merge-base", "--is-ancestor", args.base_tag, "belderchin-main"])
    run(["git", "-C", scratch, "log", "--oneline", f"{args.base_tag}..belderchin-main"])
    return scratch


def push_main(args, token: str, scratch: str) -> None:
    target = f"https://github.com/{args.repo}.git"
    run(
        ["git", "-C", scratch, "push", target, f"+refs/heads/belderchin-main:refs/heads/{args.branch}"],
        env=git_auth_env(token),
    )
    log(f"pushed {args.branch} to {target}")


# ---------------------------------------------------------------------- secrets
def upload_secrets(args, token: str) -> None:
    from nacl import encoding, public  # PyNaCl

    values = {}
    with open(args.secrets_env, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                values[k.strip()] = v.strip()
    with open(args.keystore, "rb") as fh:
        values["ANDROID_SIGNING_KEY"] = base64.b64encode(fh.read()).decode()
    required = {
        "ANDROID_SIGNING_KEY",
        "ANDROID_SIGNING_KEY_ALIAS",
        "ANDROID_SIGNING_STORE_PASSWORD",
        "ANDROID_SIGNING_KEY_PASSWORD",
    }
    missing = required - values.keys()
    if missing:
        raise SystemExit(f"secrets env file lacks {sorted(missing)}")

    status, pk = http("GET", f"{API}/repos/{args.repo}/actions/secrets/public-key", token)
    if status != 200:
        raise SystemExit(f"cannot read repo public key: {status} {pk}")
    box = public.SealedBox(public.PublicKey(pk["key"].encode(), encoding.Base64Encoder()))
    for name in sorted(required):
        sealed = base64.b64encode(box.encrypt(values[name].encode())).decode()
        status, resp = http(
            "PUT",
            f"{API}/repos/{args.repo}/actions/secrets/{name}",
            token,
            data={"encrypted_value": sealed, "key_id": pk["key_id"]},
        )
        if status not in (201, 204):
            raise SystemExit(f"secret {name}: {status} {resp}")
        log(f"secret {name}: {'created' if status == 201 else 'updated'}")


# ---------------------------------------------------------------------- actions
def dispatch(args, token: str) -> None:
    url = f"{API}/repos/{args.repo}/actions/workflows/{args.workflow}/dispatches"
    for attempt in range(12):
        status, resp = http("POST", url, token, data={"ref": args.branch, "inputs": {"publish_release": "true"}})
        if status == 204:
            log(f"dispatched {args.workflow} on {args.branch}")
            return
        log(f"dispatch attempt {attempt + 1}: {status} {resp.get('message', resp)}")
        time.sleep(10)
    raise SystemExit("workflow dispatch failed")


def latest_run(args, token: str, event: str = "workflow_dispatch"):
    status, d = http(
        "GET",
        f"{API}/repos/{args.repo}/actions/workflows/{args.workflow}/runs?event={event}&per_page=1",
        token,
    )
    runs = d.get("workflow_runs") or []
    return runs[0] if status == 200 and runs else None


def watch_run(args, token: str, timeout_s: int = 5400):
    deadline = time.time() + timeout_s
    run_info = None
    while time.time() < deadline and run_info is None:
        time.sleep(15)
        run_info = latest_run(args, token)
    if run_info is None:
        log("no run found")
        return None
    log(f"run #{run_info['run_number']} id={run_info['id']} url={run_info['html_url']}")
    last = None
    while time.time() < deadline:
        status, d = http("GET", f"{API}/repos/{args.repo}/actions/runs/{run_info['id']}", token)
        state = (d.get("status"), d.get("conclusion"))
        if state != last:
            log(f"run status={state[0]} conclusion={state[1]}")
            last = state
        if d.get("status") == "completed":
            return d
        time.sleep(30)
    log("timed out waiting for the run")
    return None


def print_release(args, token: str) -> None:
    status, rel = http("GET", f"{API}/repos/{args.repo}/releases?per_page=1", token)
    if status != 200 or not rel:
        log(f"no release yet ({status})")
        return
    r = rel[0]
    log(f"release {r['tag_name']} ({'prerelease' if r.get('prerelease') else 'release'}): {r['html_url']}")
    for a in r.get("assets", []):
        print(f"  {a['name']}  {a['size']} bytes  {a['browser_download_url']}", flush=True)


def fetch_logs(args, token: str, run_id: str) -> None:
    status, payload = http("GET", f"{API}/repos/{args.repo}/actions/runs/{run_id}/logs", token, raw=True)
    if status != 200:
        log(f"logs: {status}")
        return
    out = os.path.join(args.logs_dir, str(run_id))
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out, exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(payload)) as zf:
        zf.extractall(out)
    log(f"logs extracted to {out}")
    status, jobs = http("GET", f"{API}/repos/{args.repo}/actions/runs/{run_id}/jobs", token)
    for j in jobs.get("jobs", []):
        failed = [s["name"] for s in j.get("steps", []) if s.get("conclusion") == "failure"]
        log(f"job {j['name']}: {j.get('conclusion')} failed steps: {failed}")


# ----------------------------------------------------------------- command loop
def command_loop(args, token: str, scratch: str, hours: float) -> None:
    deadline = time.time() + hours * 3600
    log(f"command loop: write commands to {args.command_file} (dispatch|push|runs|logs <id>|release|quit)")
    while time.time() < deadline:
        time.sleep(5)
        if not os.path.exists(args.command_file):
            continue
        with open(args.command_file, encoding="utf-8") as fh:
            lines = [l.strip() for l in fh if l.strip()]
        os.remove(args.command_file)
        for line in lines:
            parts = line.split()
            try:
                if parts[0] == "quit":
                    log("bye")
                    return
                if parts[0] == "push":
                    scratch = prepare_scratch(args)
                    push_main(args, token, scratch)
                elif parts[0] == "secrets":
                    upload_secrets(args, token)
                elif parts[0] == "dispatch":
                    dispatch(args, token)
                    d = watch_run(args, token)
                    if d and d.get("conclusion") == "success":
                        print_release(args, token)
                elif parts[0] == "runs":
                    status, d = http("GET", f"{API}/repos/{args.repo}/actions/runs?per_page=5", token)
                    for r in d.get("workflow_runs", []):
                        log(f"{r['id']} {r['name']} {r['event']} {r['status']} {r['conclusion']} {r['html_url']}")
                elif parts[0] == "logs" and len(parts) > 1:
                    fetch_logs(args, token, parts[1])
                elif parts[0] == "release":
                    print_release(args, token)
                else:
                    log(f"unknown command: {line}")
            except Exception as e:  # keep the loop alive
                log(f"command '{line}' failed: {e}")
    log("command loop finished")


# ------------------------------------------------------------------------- main
def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default="kafinetnabovat-spec/belderchin")
    ap.add_argument("--source", default=os.getcwd(), help="local Belderchin checkout")
    ap.add_argument("--branch", default="main")
    ap.add_argument("--upstream", default="https://github.com/hiddify/hiddify-app.git")
    ap.add_argument("--upstream-branch", default="main")
    ap.add_argument("--base-tag", default="v4.1.2")
    ap.add_argument("--work", default="/var/tmp/belderchin-work", help="scratch dir for the full clone")
    ap.add_argument("--workflow", default="android-release.yml")
    ap.add_argument("--keystore", help="release keystore (.jks/.p12) to upload as ANDROID_SIGNING_KEY")
    ap.add_argument("--secrets-env", help="env file with ANDROID_SIGNING_KEY_ALIAS/STORE_PASSWORD/KEY_PASSWORD")
    ap.add_argument("--skip-push", action="store_true")
    ap.add_argument("--skip-dispatch", action="store_true")
    ap.add_argument("--command-file", default="/tmp/belderchin-cmd")
    ap.add_argument("--logs-dir", default="/tmp/belderchin-logs")
    ap.add_argument("--stay-alive-hours", type=float, default=6)
    ap.add_argument("--issue-code", action="store_true", help="only request a device code, store it, print it and exit")
    ap.add_argument("--device-code-file", default=os.path.expanduser("~/.belderchin-device-code.json"))
    args = ap.parse_args()

    if args.issue_code:
        obtain_token(args)
    scratch = None
    if not args.skip_push:
        scratch = prepare_scratch(args)  # network work that needs no token

    token = obtain_token(args)
    status, me = http("GET", f"{API}/user", token)
    log(f"authenticated as {me.get('login')} ({status})")
    status, repo = http("GET", f"{API}/repos/{args.repo}", token)
    if status != 200:
        raise SystemExit(f"repository {args.repo} not reachable: {status} {repo.get('message')}")
    perms = repo.get("permissions", {})
    log(f"repo ok: fork={repo.get('fork')} size={repo.get('size')} push={perms.get('push')} admin={perms.get('admin')}")

    if not args.skip_push:
        push_main(args, token, scratch)
    if args.keystore and args.secrets_env:
        upload_secrets(args, token)
    if not args.skip_dispatch:
        dispatch(args, token)
        d = watch_run(args, token)
        if d and d.get("conclusion") == "success":
            print_release(args, token)
        elif d:
            fetch_logs(args, token, str(d["id"]))
    command_loop(args, token, scratch or "", args.stay_alive_hours)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
