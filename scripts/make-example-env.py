#!/usr/bin/env python3
"""Build examples/.env for the local Aevum fork without putting keys on a command line.

Reads the two throwaway wallets that .secrets/ already holds (created with `cast wallet new`)
and writes them into examples/.env (mode 600, git-ignored). Nothing here is printed except the
two public addresses, so private key material never reaches a shell argument, chat or log.
"""
from __future__ import annotations

import os
import re
import sys

ROOT = "/home/jam/projects/money-coo/aevum-challenge"
SECRETS = os.path.join(ROOT, ".secrets")
ENV_PATH = os.path.join(ROOT, "examples", ".env")


def read_wallet(name: str) -> tuple[str, str]:
    path = os.path.join(SECRETS, f"{name}.txt")
    text = open(path, encoding="utf-8").read()
    addr = re.search(r"Address:\s*(0x[0-9a-fA-F]{40})", text)
    key = re.search(r"Private [Kk]ey:\s*(0x[0-9a-fA-F]{64})", text)
    if not addr or not key:
        sys.exit(f"{path} is not a `cast wallet new` dump")
    return addr.group(1), key.group(1)


def main() -> None:
    agent_pay = sys.argv[1]
    payer_addr, payer_key = read_wallet("payer")
    agent_addr, agent_key = read_wallet("agent")
    merchant_addr, _ = read_wallet("test-wallet")

    lines = [
        "# Local Aevum fork (chain 440050). Throwaway wallets, no real money anywhere.",
        "RPC_URL=http://127.0.0.1:8555",
        f"AGENT_PAY_ADDRESS={agent_pay}",
        f"MERCHANT_ADDRESS={merchant_addr}",
        f"PAYER_KEY={payer_key}",
        f"AGENT_KEY={agent_key}",
        "",
    ]
    fd = os.open(ENV_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    os.chmod(ENV_PATH, 0o600)

    print(f"wrote {ENV_PATH} (600)")
    print(f"  payer    {payer_addr}")
    print(f"  agent    {agent_addr}")
    print(f"  merchant {merchant_addr}")
    print(f"  agentpay {agent_pay}")


if __name__ == "__main__":
    main()
