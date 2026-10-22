#!/usr/bin/env python3
"""Seed S4 with a Hugging Face snapshot (C4). Public models; no token required.

Tries S4 POST /api/objects/huggingface-import first. If that fails, downloads
with huggingface_hub and uploads with boto3 to the same prefix.
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request

S4_API = os.environ.get("S4_API", "http://s4.s4.svc.cluster.local:5000").rstrip("/")
S4_S3 = os.environ.get("S4_S3", "http://s4.s4.svc.cluster.local:7480").rstrip("/")
BUCKET = os.environ.get("S4_BUCKET", "models")
REPO = os.environ.get("HF_REPO_ID", "Qwen/Qwen2.5-7B-Instruct")
PREFIX = os.environ.get("S3_PREFIX", "qwen2.5-7b-instruct").strip("/")
USER = os.environ["S4_UI_USER"]
PASSWORD = os.environ["S4_UI_PASSWORD"]
ACCESS = os.environ["AWS_ACCESS_KEY_ID"]
SECRET = os.environ["AWS_SECRET_ACCESS_KEY"]
POLL_SEC = int(os.environ.get("SEED_POLL_SEC", "20"))
TIMEOUT_SEC = int(os.environ.get("SEED_TIMEOUT_SEC", "3600"))


def req(method: str, url: str, data=None, headers=None, timeout=60):
    body = None
    hdrs = dict(headers or {})
    if data is not None:
        body = json.dumps(data).encode()
        hdrs.setdefault("Content-Type", "application/json")
    r = urllib.request.Request(url, data=body, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            raw = resp.read()
            return resp.status, json.loads(raw.decode()) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            parsed = json.loads(raw.decode()) if raw else {}
        except Exception:
            parsed = {"message": raw.decode("utf-8", "replace")[:400]}
        return e.code, parsed


def login() -> str:
    code, body = req(
        "POST",
        f"{S4_API}/api/auth/login",
        {"username": USER, "password": PASSWORD},
    )
    if code != 200 or not body.get("token"):
        raise SystemExit(f"S4 login failed HTTP {code}: {body}")
    return body["token"]


def auth_headers(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def ensure_bucket(token: str) -> None:
    code, body = req("POST", f"{S4_API}/api/buckets", {"bucketName": BUCKET}, auth_headers(token))
    if code in (200, 201):
        print(f"  created bucket {BUCKET}", flush=True)
        return
    err = str(body.get("error") or "") + str(body.get("message") or "")
    if code in (409, 400) or "exist" in err.lower() or "Already" in err:
        print(f"  bucket {BUCKET} already present", flush=True)
        return
    # list as a second check
    c2, listed = req("GET", f"{S4_API}/api/buckets", headers=auth_headers(token))
    names = [b.get("Name") for b in (listed.get("buckets") or [])]
    if BUCKET in names:
        print(f"  bucket {BUCKET} already present", flush=True)
        return
    raise SystemExit(f"create bucket failed HTTP {code}: {body}")


def list_prefix(token: str) -> list:
    import base64

    enc = base64.urlsafe_b64encode(f"{PREFIX}/".encode()).decode().rstrip("=")
    code, body = req(
        "GET",
        f"{S4_API}/api/objects/{BUCKET}/{enc}?maxKeys=200",
        headers=auth_headers(token),
        timeout=120,
    )
    if code != 200:
        return []
    return body.get("objects") or []


def prefix_ready(objs: list) -> bool:
    """True only when config AND actual weight shards are present.

    Small files (config.json, tokenizer.json) land first. Treating those as
    success left C4 pointing at an incomplete snapshot.
    """
    keys = [o.get("Key") or "" for o in objs]
    sizes = {o.get("Key") or "": int(o.get("Size") or 0) for o in objs}
    has_config = any(k.endswith("config.json") and "generation" not in k.split("/")[-1] for k in keys)
    weight_keys = [k for k in keys if k.endswith(".safetensors") and not k.endswith(".index.json")]
    weight_bytes = sum(sizes.get(k, 0) for k in weight_keys)
    # Qwen 7B shards are ~3–4 GiB each; require at least one real shard.
    return has_config and weight_bytes >= 1_000_000_000


def start_s4_import(token: str) -> str | None:
    code, body = req(
        "POST",
        f"{S4_API}/api/objects/huggingface-import",
        {"bucketName": BUCKET, "hfRepoId": REPO, "s3Prefix": PREFIX},
        auth_headers(token),
        timeout=120,
    )
    print(f"  huggingface-import HTTP {code}: {body}", flush=True)
    if code in (200, 201, 202):
        return body.get("jobId")
    return None


def s3_client():
    import boto3
    from botocore.config import Config

    return boto3.client(
        "s3",
        endpoint_url=S4_S3,
        aws_access_key_id=ACCESS,
        aws_secret_access_key=SECRET,
        region_name="us-east-1",
        use_ssl=False,
        config=Config(s3={"addressing_style": "path"}),
    )


def is_hf_junk_key(key: str) -> bool:
    parts = key.split("/")
    return ".cache" in parts or ".huggingface" in parts


def purge_hf_junk(client) -> int:
    """KServe downloads every object under the prefix. HF .cache metadata
    is not part of the model and has crashed S4 RGW with EMFILE/HTTP 500."""
    deleted = 0
    paginator = client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET, Prefix=f"{PREFIX}/"):
        for obj in page.get("Contents") or []:
            key = obj.get("Key") or ""
            if not is_hf_junk_key(key):
                continue
            client.delete_object(Bucket=BUCKET, Key=key)
            deleted += 1
            print(f"  deleted junk {key}", flush=True)
    return deleted


def boto_upload() -> None:
    from huggingface_hub import snapshot_download
    from pathlib import Path

    dest = Path("/tmp/hf-model")
    print(f"  snapshot_download {REPO} -> {dest}", flush=True)
    snapshot_download(repo_id=REPO, local_dir=str(dest))
    client = s3_client()
    files = [
        p
        for p in dest.rglob("*")
        if p.is_file() and ".cache" not in p.parts and ".huggingface" not in p.parts
    ]
    print(f"  uploading {len(files)} files to s3://{BUCKET}/{PREFIX}/", flush=True)
    for i, path in enumerate(files, 1):
        rel = path.relative_to(dest).as_posix()
        key = f"{PREFIX}/{rel}"
        extra = {}
        if path.suffix == ".json":
            extra["ContentType"] = "application/json"
        elif path.suffix in (".txt", ".md"):
            extra["ContentType"] = "text/plain"
        kwargs = {"ExtraArgs": extra} if extra else {}
        client.upload_file(str(path), BUCKET, key, **kwargs)
        if i % 5 == 0 or i == len(files):
            print(f"    {i}/{len(files)} {key}", flush=True)


def main() -> int:
    print(f"Seeding s3://{BUCKET}/{PREFIX}/ from {REPO}", flush=True)
    token = login()
    ensure_bucket(token)
    n = purge_hf_junk(s3_client())
    print(f"  purged {n} Hugging Face cache keys from prefix", flush=True)
    if os.environ.get("SEED_PURGE_ONLY", "0") == "1":
        return 0
    objs = list_prefix(token)
    if prefix_ready(objs):
        print(f"  already populated ({len(objs)} objects listed)", flush=True)
        return 0
    job = start_s4_import(token)
    deadline = time.time() + TIMEOUT_SEC
    if job:
        print(f"  waiting for S4 import job {job}", flush=True)
        started = time.time()
        while time.time() < deadline:
            objs = list_prefix(token)
            if prefix_ready(objs):
                n = purge_hf_junk(s3_client())
                print(f"  import complete ({len(objs)} objects listed, purged {n} cache keys)", flush=True)
                return 0
            weight = sum(
                int(o.get("Size") or 0)
                for o in objs
                if (o.get("Key") or "").endswith(".safetensors")
                and not (o.get("Key") or "").endswith(".index.json")
            )
            print(f"  polling… {len(objs)} objects, {weight} bytes of shards", flush=True)
            if time.time() - started >= 120 and weight < 1_000_000_000:
                print("  S4 import produced no weight shards; falling back to huggingface_hub", flush=True)
                break
            time.sleep(POLL_SEC)
        else:
            print("  S4 import did not finish in time; falling back to huggingface_hub", flush=True)
    else:
        print("  S4 import API unavailable; falling back to huggingface_hub", flush=True)
    boto_upload()
    n = purge_hf_junk(s3_client())
    objs = list_prefix(token)
    if prefix_ready(objs):
        print(f"  upload complete ({len(objs)} objects listed, purged {n} cache keys)", flush=True)
        return 0
    print("  WARNING: prefix still looks empty after upload", flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
