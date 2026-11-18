#!/usr/bin/env python3
"""Stock Shelly Smart Plug controller (Gen2/3/4 RPC + Gen1 HTTP fallback).

Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
SPDX-License-Identifier: MIT
"""

import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

sys.dont_write_bytecode = True


def _digest_header(method, uri, realm, nonce, qop, user, password, algo="MD5"):
    hfn = hashlib.sha256 if "256" in algo.upper() else hashlib.md5

    def hx(text):
        return hfn(text.encode("utf-8")).hexdigest()

    ha1 = hx(f"{user}:{realm}:{password}")
    ha2 = hx(f"{method}:{uri}")
    nc = "00000001"
    cnonce = os.urandom(8).hex()
    if qop:
        resp = hx(f"{ha1}:{nonce}:{nc}:{cnonce}:auth:{ha2}")
        qop_part = f', qop=auth, nc={nc}, cnonce="{cnonce}"'
    else:
        resp = hx(f"{ha1}:{nonce}:{ha2}")
        qop_part = ""
    return (
        f'Digest username="{user}", realm="{realm}", '
        f'nonce="{nonce}", uri="{uri}", algorithm={algo}, '
        f'response="{resp}"{qop_part}'
    )


def _parse_digest_challenge(hdr):
    fields = {}
    for m in re.finditer(r'([a-zA-Z0-9_-]+)=("([^"]*)"|([^,\s]+))', hdr):
        fields[m.group(1).lower()] = (
            m.group(3) if m.group(3) is not None else m.group(4)
        )
    return fields


class ShellyPlug:
    """Controls a stock Shelly smart plug over local HTTP."""

    def __init__(
        self,
        host,
        switch_id=0,
        port=80,
        username="admin",
        password="",
        timeout=10.0,
    ):
        self.host = host
        self.switch_id = int(switch_id)
        self.port = int(port)
        self.username = username
        self.password = password
        self.timeout = float(timeout)

    def _base(self):
        return f"http://{self.host}:{self.port}"

    def _http(self, method, path, body=None):
        url = self._base() + path
        data = None if body is None else json.dumps(body).encode("utf-8")
        headers = {}
        if data is not None:
            headers["Content-Type"] = "application/json"

        req = urllib.request.Request(
            url, data=data, method=method, headers=headers
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.status, json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code == 401 and self.password:
                ch = e.headers.get("WWW-Authenticate", "")
                if ch.lower().startswith("digest"):
                    f = _parse_digest_challenge(ch)
                    headers["Authorization"] = _digest_header(
                        method,
                        path,
                        f.get("realm", ""),
                        f.get("nonce", ""),
                        f.get("qop", ""),
                        self.username,
                        self.password,
                        f.get("algorithm", "SHA-256"),
                    )
                    req2 = urllib.request.Request(
                        url, data=data, method=method, headers=headers
                    )
                    with urllib.request.urlopen(
                        req2, timeout=self.timeout
                    ) as resp2:
                        return resp2.status, json.loads(
                            resp2.read().decode("utf-8")
                        )
            raise

    def device_info(self):
        try:
            _, obj = self._http("GET", "/rpc/Shelly.GetDeviceInfo")
            obj["gen"] = obj.get("gen", 2)
            return obj
        except urllib.error.HTTPError as e:
            if e.code not in (404, 405, 501):
                raise
        _, obj = self._http("GET", "/shelly")
        obj["gen"] = obj.get("gen", 1)
        return obj

    def get_status(self):
        try:
            _, obj = self._http(
                "GET", f"/rpc/Switch.GetStatus?id={self.switch_id}"
            )
            return {
                "output": bool(obj.get("output", False)),
                "apower": float(obj.get("apower", 0.0)),
                "gen": 2,
            }
        except urllib.error.HTTPError as e:
            if e.code not in (404, 405, 501):
                raise
        _, obj = self._http("GET", f"/relay/{self.switch_id}")
        return {
            "output": bool(obj.get("ison", False)),
            "apower": float(obj.get("power", 0.0)),
            "gen": 1,
        }

    def set_power(self, on):
        state = bool(on)
        try:
            _, obj = self._http(
                "POST",
                "/rpc/Switch.Set",
                {"id": self.switch_id, "on": state},
            )
            was_on = bool(obj.get("was_on", False))
            return {"on": state, "was_on": was_on, "gen": 2}
        except urllib.error.HTTPError as e:
            if e.code not in (404, 405, 501):
                raise
        turn = "on" if state else "off"
        _, obj = self._http("GET", f"/relay/{self.switch_id}?turn={turn}")
        return {"on": bool(obj.get("ison", state)), "gen": 1}

    def power_cycle(self, off_sec=2.0):
        self.set_power(False)
        time.sleep(float(off_sec))
        return self.set_power(True)


def main():
    parser = argparse.ArgumentParser(description="Control a stock Shelly plug")
    parser.add_argument("--host", required=True, help="Shelly plug IP/host")
    parser.add_argument("--port", type=int, default=80)
    parser.add_argument("--switch-id", type=int, default=0)
    parser.add_argument("--user", default="admin")
    parser.add_argument("--password", default="")
    parser.add_argument(
        "--action",
        choices=("status", "info", "on", "off", "cycle"),
        default="status",
    )
    parser.add_argument("--off-sec", type=float, default=2.0)
    args = parser.parse_args()

    plug = ShellyPlug(
        args.host,
        switch_id=args.switch_id,
        port=args.port,
        username=args.user,
        password=args.password,
    )
    if args.action == "info":
        res = plug.device_info()
    elif args.action == "status":
        res = plug.get_status()
    elif args.action == "on":
        res = plug.set_power(True)
    elif args.action == "off":
        res = plug.set_power(False)
    else:
        res = plug.power_cycle(args.off_sec)
    print(json.dumps(res))


if __name__ == "__main__":
    main()
