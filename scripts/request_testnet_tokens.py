#!/usr/bin/env python3
"""Ask QDay for testnet tokens by email — the one support channel an agent can use alone.

The faucet requires the recipient to hold ETH/USDT/USDC on Ethereum mainnet (verified:
`/gasapi/eligibility?address=0xEb04…` returns {"eligible":false}), and every claim route
needs a captcha token (`/claim` → 403 captcha verification failed). Discord verification
fails for our account too, so this email is the remaining route.

Credentials come from the profile .env (GMAIL_ADDRESS / GMAIL_APP_PASSWORD) and are never
printed. Run with --dry to render the message without sending.
"""
from __future__ import annotations

import os
import smtplib
import ssl
import sys
from email.message import EmailMessage

ENV = "/home/jam/.hermes/profiles/money-coo/.env"
DEPLOYER = "0xEb04B55B2AD7A4f4dAd9412389a04c024f45f462"
REPO = "https://github.com/jamking168/aevum-agentpay"
VIDEO = ("https://github.com/jamking168/aevum-agentpay/releases/download/demo-v1/"
         "agentpay-demo-subtitled.mp4")

SUBJECT = "Aevum Builder Challenge #1 — testnet tokens for our deployer (faucet not reachable)"
BODY = f"""Hello QDay team,

We are building for Aevum Builder Challenge #1 on DoraHacks (track: Native AI Assistants):
AgentPay, a payment contract that gives an AI agent a session-scoped budget with an
on-chain per-payment cap, expiry, instant revoke and one payment per order, plus an
EIP-3009 path where the payer signs and a relayer pays the gas.

Public repository (MIT): {REPO}
86-second demo video: {VIDEO}

We are blocked on the faucet. From the faucet backend:

  GET https://faucet.qday.info/gasapi/eligibility?address={DEPLOYER}
  -> {{"eligible":false,"via":null}}

The eligibility check wants the recipient to hold ETH, USDT or USDC on Ethereum mainnet.
Our only holdings are TRC20, so we cannot satisfy it, and every claim route also requires
a captcha token (POST /gasapi/claim returns 403 "captcha verification failed"). Discord
verification did not go through for our account either.

Could you send the tokens straight to our deployer address?

  Address: {DEPLOYER}
  Needed:  1 tQDAY for gas (a deployment estimates 1,003,220 gas at 1 gwei = 0.001 tQDAY)
           plus 5 tUSD8 for the payment demo transactions

The deployment script is contracts/script/DeployAgentPay.s.sol and the demo driver is
examples/src/agent-pay.ts, so as soon as the tokens land we can deploy and send you the
transaction hashes on Aevum testnet (chain 44005) the same day.

Thank you,
Jam
"""


def load_env(path: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def main() -> int:
    env = load_env(ENV)
    sender = env.get("GMAIL_ADDRESS")
    password = env.get("GMAIL_APP_PASSWORD")
    if not sender or not password:
        sys.exit("GMAIL_ADDRESS / GMAIL_APP_PASSWORD missing from the profile .env")

    msg = EmailMessage()
    msg["From"] = sender
    msg["To"] = "support@qday.io"
    msg["Cc"] = "morris@pqalabs.xyz"
    msg["Subject"] = SUBJECT
    msg.set_content(BODY)

    if "--dry" in sys.argv:
        print(f"From: {sender}\nTo: support@qday.io\nCc: morris@pqalabs.xyz\nSubject: {SUBJECT}\n")
        print(BODY)
        return 0

    ctx = ssl.create_default_context()
    with smtplib.SMTP_SSL("smtp.gmail.com", 465, context=ctx, timeout=60) as s:
        s.login(sender, password)
        s.send_message(msg)
    print(f"sent from {sender} to support@qday.io (cc morris@pqalabs.xyz)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
