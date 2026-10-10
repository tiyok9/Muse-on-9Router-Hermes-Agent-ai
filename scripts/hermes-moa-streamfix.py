#!/usr/bin/env python
"""Patch idempotent: kirim `stream: false` eksplisit di jalur non-streaming Hermes.

Latar: sebagian upstream OpenAI-compatible (mis. node custom 9Router) membalas
`text/event-stream` bila field `stream` DIHILANGKAN, sehingga parser Hermes gagal
dengan "Invalid SSE response for non-streaming request" (MoA E2E menggantung).

Patch ini menyuntik `stream=False` eksplisit pada dua titik:
  1. agent/auxiliary_client.py::call_llm  (jalur non-streaming umum)
  2. agent/moa_loop.py                    (stream_kwargs aggregator MoA)

Idempotent & re-runnable: dijalankan berkali-kali aman; file yang sudah dipatch
dilewati. Backup otomatis dibuat sebelum tulis.
"""
import os
import shutil
import sys
import time

HERMES = os.environ.get("HERMES_AGENT_DIR") or os.path.join(
    os.environ.get("LOCALAPPDATA", ""), "hermes", "hermes-agent"
)

TARGETS = [
    (
        os.path.join("agent", "auxiliary_client.py"),
        '''    if stream:
        kwargs["stream"] = True
        if stream_options:
            kwargs["stream_options"] = stream_options
        return client.chat.completions.create(**kwargs)
''',
        '''    if stream:
        kwargs["stream"] = True
        if stream_options:
            kwargs["stream_options"] = stream_options
        return client.chat.completions.create(**kwargs)
    # Non-streaming path: send an EXPLICIT stream=false. The OpenAI spec
    # defaults it to false, but some OpenAI-compatible upstreams (notably
    # 9Router custom nodes) reply text/event-stream when the key is ABSENT,
    # which makes the response parser fail with
    # "Invalid SSE response for non-streaming request".
    kwargs["stream"] = False
''',
    ),
    (
        os.path.join("agent", "moa_loop.py"),
        '''            if api_kwargs.get("timeout") is not None:
                stream_kwargs["timeout"] = api_kwargs["timeout"]
        agg_runtime = _slot_runtime(aggregator)''',
        '''            if api_kwargs.get("timeout") is not None:
                stream_kwargs["timeout"] = api_kwargs["timeout"]
        else:
            # Some OpenAI-compatible upstreams (9Router custom nodes) return
            # text/event-stream when `stream` is OMITTED; send an explicit
            # false so the non-streaming aggregator call gets a JSON body.
            stream_kwargs["stream"] = False
        agg_runtime = _slot_runtime(aggregator)''',
    ),
]


def main() -> int:
    if not os.path.isdir(HERMES):
        print("FATAL: HERMES_AGENT_DIR tidak ada: %s" % HERMES)
        return 2
    ts = time.strftime("%Y%m%dT%H%M%S")
    rc = 0
    for rel, old, new in TARGETS:
        path = os.path.join(HERMES, rel)
        if not os.path.isfile(path):
            print("SKIP  %s (tidak ada)" % rel)
            rc = 1
            continue
        with open(path, "rb") as fh:
            raw = fh.read()
        crlf = b"\r\n" in raw
        src = raw.decode("utf-8")
        # Cocokkan dengan line-ending file apa pun (LF atau CRLF).
        def _fit(text: str) -> str:
            return text.replace("\n", "\r\n") if crlf else text
        old_f, new_f = _fit(old), _fit(new)
        if new_f in src:
            print("OK    %s (sudah dipatch)" % rel)
            continue
        if old_f not in src:
            print("FAIL  %s (anchor tidak ditemukan — versi Hermes berubah?)" % rel)
            rc = 1
            continue
        shutil.copy2(path, "%s.bak.streamfix.%s" % (path, ts))
        with open(path, "wb") as fh:
            fh.write(src.replace(old_f, new_f, 1).encode("utf-8"))
        print("PATCH %s (backup: %s.bak.streamfix.%s)" % (rel, os.path.basename(path), ts))
    return rc


if __name__ == "__main__":
    sys.exit(main())
