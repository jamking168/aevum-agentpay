# Aevum BUIDL — 表单填写内容（照抄）

## Title

```
AgentPay — session-scoped spending controls for AI agents on Aevum
```

## Tagline / short description

```
An AI agent gets a spending session: on-chain budget, per-payment cap, expiry, instant revoke and one payment per order. Payer and merchant settle in tUSD8 directly; the contract never holds funds.
```

## Track (single select)

```
Native AI Assistants
```

## GitHub repository link (required)

```
https://github.com/jamking168/aevum-agentpay
```

## Demo video link (required)

```
https://github.com/jamking168/aevum-agentpay/releases/download/demo-v1/agentpay-demo-subtitled.mp4
```

<sub>公开可下载，无需登录：已用匿名 HEAD 校验 200 / 2,147,189 bytes。</sub>

## Description (markdown，整段粘进 description 框)

```markdown
## The problem

Giving an AI agent a wallet is the easy part. Letting it spend unattended without handing over the whole balance is the hard part. Every team that tries it ends up writing the same ad-hoc checks off-chain, where they are advisory rather than enforced: a client-side cap is one prompt injection or one bug away from being bypassed.

## What AgentPay does

AgentPay moves those checks on-chain and makes them a spending session:

- **Budget** — the most the agent may ever spend in this session.
- **Per-payment cap** — the largest single invoice the agent may settle.
- **Expiry** — the session dies on its own; no cleanup job required.
- **Revoke** — the payer can stop the agent instantly, mid-session.
- **Idempotency** — one payment per order id, so a retry cannot double-charge.
- **Optional merchant allowlist** — the agent can be limited to known payees.

Money never sits in the contract. The payer approves tUSD8 once, and every payment moves tokens from the payer to the merchant directly. The agent signs and sends the payments itself but holds no funds — only the right to spend inside the limits above.

## Two payment paths

1. **Agent pays** (`pay`) — the agent sends the transaction and pays the gas.
2. **Relayer pays** (`payWithAuthorization`) — the payer signs an EIP-3009 authorization bound to the session and order id, and any third party can submit it. This is what makes an agent with zero native gas possible: the agent computes, the payer authorises, the relayer spends the gas.

## Evidence

Deployed and run against the live tUSD8 token `0x456569838f1d43009A91ebA4263147Afd7233483` on a fork of Aevum testnet (chain 440050), i.e. real testnet state, not a mock token:

- `approve` — `0x0b6b8f01884ac66487a54847d06067a3fa829815d4c80e2a9f1934135b06f3d7`
- `openSession` — `0x48e7f08dac0124a2627ca5df4351d16f596d09e48a9047b4d738991b3da02dc7`
- agent pays 2 tUSD8 — `0xdcd40e75a9d062443d2a7f0866e4af02291853b7616e72da4a05972d49cd04b5`
- agent pays 3 tUSD8 — `0x21744af52a68ba8fff13ecfbdbcdcd2a525f71c964e86a4800374cc11aab2b54`
- `revoke` — `0xff00bb89e57617299070d2d9c5328ad3c833a221aba3ea4b9d72ec8d1553ea49`

Three further attempts were refused by the contract itself: `PerPaymentCapExceeded` (4 tUSD8 above the cap), `OrderAlreadyPaid` (replayed order id), `SessionIsRevoked` (after the payer revoked).

Test suite: **32 unit tests**, **5 fork tests** that run against the live tUSD8 contract, and 6/6 bytecode checks for Shanghai compatibility — `make check` runs all of it.

## Honest status

- The demo above ran on a local fork of Aevum testnet because the faucet requires an Ethereum-mainnet-funded address and the deployer wallet is new; the on-chain deployment on the live testnet is the next step, and the same script performs it (`make deploy-agentpay-aevum`).
- No UI yet: the demo driver is a TypeScript script. A minimal merchant/payer screen is the next milestone.
- Session accounting is per-session; there is no global per-agent daily limit across sessions yet.

## Attribution

Built on the Aevum Starter Kit (MIT, PQA Labs); the LICENSE is retained and the kit's Checkout example is untouched. AgentPay ships under MIT.
```

## Tech stack（若表单要求）

```
Solidity 0.8.28 · Foundry (forge/anvil) · TypeScript + viem · EIP-3009 (transferWithAuthorization) · Aevum testnet chain 44005
```
