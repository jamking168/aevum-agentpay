# AgentPay — spending sessions for AI agents, on Aevum testnet

An agent that pays for things needs a limit it cannot talk its way out of. AgentPay puts the
limit in a contract: a payer opens a **session** for one agent with a total budget, a
per-payment cap, an expiry and an optional merchant allowlist, then the agent pays invoices
inside it. Every attempt outside those limits reverts on chain. The contract never holds a
cent — money moves payer → merchant in the same call — and each order can be paid exactly once.

Built for **Aevum Builder Challenge #1** (QDay testnet, chain `44005`, tUSD8).

```
payer ──openSession(budget, cap, expiry, agent)──▶ AgentPay
  │                                                  │
  │ approve(budget)                                  │  agent pays:
  │                                                  │  pay(session, order, merchant, amount)
  └────────────────── tUSD8 ──payer → merchant───────┘  payWithAuthorization(...EIP-3009 sig...)
```

## Why this exists

Agent frameworks are good at deciding to spend and bad at being trusted with a balance. The
usual fix is a prompt ("never spend more than $20") or a server-side check the agent's own code
performs. Both fail the moment the agent is compromised, loops, or just hallucinates an argument.

AgentPay moves the four rules into the contract, so the agent's own code cannot widen them:

| Rule | Enforced where | Test |
| --- | --- | --- |
| total budget | `_precheck` → `BudgetExceeded` | `test_pay_rejectsAboveBudgetAfterSeveralPayments` |
| per-payment cap | `_precheck` → `PerPaymentCapExceeded` | `test_pay_rejectsAbovePerPaymentCap` |
| expiry | `_precheck` → `SessionExpired` | `test_pay_rejectsAfterExpiry` |
| revocable by the payer | `revoke` → `SessionIsRevoked` | `test_pay_rejectsAfterRevoke`, `test_revoke_onlyPayer` |
| one payment per order | `_used` map → `OrderAlreadyPaid` | `test_pay_rejectsReplayedOrder` |
| merchant allowlist (opt-in) | `_precheck` → `MerchantNotAllowed` | `test_allowlistBlocksUnlistedMerchantOnceUsed` |

## Two payment paths

- **`pay`** — the agent calls it directly and pays gas. The payer has approved AgentPay for the
  budget, so the tokens come from the payer's balance, never the agent's.
- **`payWithAuthorization`** — the payer signs an EIP-3009 `ReceiveWithAuthorization` bound to
  `paymentNonce(sessionId, orderId)`; anyone (a relayer, the merchant, the agent) can submit it.
  The agent needs **no native gas at all**, and a signature can only ever settle that one order.

Both paths run the same gates, so switching paths cannot escape a limit.

## Layout

```
contracts/src/AgentPay.sol            the contract
contracts/test/AgentPay.t.sol         21 unit tests (every limit, both paths)
contracts/test/fork/AgentPayFork.t.sol 2 tests against the REAL tUSD8 on a local Aevum fork
contracts/script/DeployAgentPay.s.sol deploy (real tUSD8 on Aevum, MockUSD8 on plain anvil)
examples/src/agent-pay.ts             an agent spending inside a session, refusals included
```

## Run it

Needs Node 22+, pnpm, Foundry (`foundryup`).

```bash
make install
make check          # build + Shanghai opcode check + 32 unit tests + 5 fork tests + typecheck
```

The fork tests use the real tUSD8 at `0x456569838f1d43009A91ebA4263147Afd7233483` through
`rpc-test.qday.info`; `deal` writes balances into the fork, so no funds are needed.

### Deploy to Aevum testnet (chain 44005)

```bash
cast wallet import aevum-deployer --interactive     # a TEST wallet only
cast wallet address --account aevum-deployer        # fund this from the QDay faucet
make deploy-agentpay-aevum ACCOUNT=aevum-deployer
```

Gas is tQDAY, about 1 gwei; the deploy costs well under 0.01 tQDAY. Aevum runs **Shanghai**, so
`evm_version = "shanghai"` in `contracts/foundry.toml` and `make build` runs
`tools/check-shanghai.mjs` over every bytecode blob.

### Demo an agent session

Against Aevum testnet:

```bash
cp examples/.env.example examples/.env    # AGENT_PAY_ADDRESS, MERCHANT_ADDRESS, PAYER_KEY, AGENT_KEY
pnpm example agent-pay
```

Or entirely offline against the local fork, which is how this was first run (no faucet, no funds):

```bash
make fork &                                          # Aevum state on 127.0.0.1:8555, chain 440050
make deploy-agentpay-fork                            # prints the AgentPay address
cast wallet new > .secrets/payer.txt                 # throwaway wallets
cast wallet new > .secrets/agent.txt
make deal TO=<payer address> AMOUNT=50               # fork-only: tUSD8 + tQDAY for gas
make deal TO=<agent address> AMOUNT=1
python3 scripts/make-example-env.py <AgentPay address>   # writes examples/.env (600), keys never on a command line
pnpm example agent-pay
```

Real output from that run:

```
1) payer opens the session and approves the budget
   approve     0x9a41…7a24
   openSession 0xce15…7a35
2) the agent works through the invoices
   PAID     2 tUSD8 - inside the cap
   PAID     3 tUSD8 - inside the cap
   REFUSED  4 tUSD8 - above the per-payment cap -> PerPaymentCapExceeded
   REFUSED  invoice-1 again - replay -> OrderAlreadyPaid
3) payer revokes the session
   revoke      0x1a92…bac9
   REFUSED  after revoke -> SessionIsRevoked
summary
   session remaining 5 tUSD8
```

Three real reverts, each with its selector checked against the contract
(`PerPaymentCapExceeded 0xf636018b`, `OrderAlreadyPaid 0x4e64befa`, `SessionIsRevoked 0x524d38ba`).

## Deployed addresses

| What | Where |
| --- | --- |
| AgentPay | _filled in after the testnet deploy_ |
| tUSD8 (given) | `0x456569838f1d43009A91ebA4263147Afd7233483` |

## Assumptions and limits (read before reusing)

- **The price is not on chain.** AgentPay moves the amount it is told to move. A merchant-facing
  app must price the order in its own backend and verify the amount, the way
  `web/src/lib/order.ts` does in the starter kit. Do not ship on "is this order paid?" alone.
- **Payer must pre-approve.** The direct path needs an ERC-20 approval of the budget. The
  gasless path does not need an approval, only the signature per order.
- **No custody, no withdrawal.** Funds never sit in the contract, so `revoke` stops future
  payments and nothing else.
- **Sessions are immutable** apart from the allowlist and `revoke`: raising a budget means
  opening a new session (a deliberate choice — an agent that can ask for more is a weaker gate).
- **One session id, one agent.** A payer running several agents should open several sessions.
- **The allowlist is opt-in.** A session with no allowed merchant may pay anyone; the first
  `allowMerchant` switches it to allowlist-only. That is documented so integrators are not
  surprised, and the counter is incremented per merchant, not per call.
- **Not audited.** This is challenge code. Treat it as a worked example, not as something to
  hold real money without a review.

## Build window note

The challenge requires the core work to be written during the build window (16 Nov – 11 Dec
2026). This repository starts from the official Aevum Starter Kit (MIT, PQA Labs) — its
`Checkout.sol`, web app and examples are kept for reference and credited below — and adds
`AgentPay.sol`, its tests, the deploy script and the agent example.

## Licenses and credit

- Based on **Aevum Starter Kit** (MIT, © 2026 PQA Labs): `contracts/`, `web/`, `examples/`,
  `packages/aevum/` and `tools/` come from it, with our additions on top. Its `LICENSE` and
  `NOTICE.md` are kept as-is.
- OpenZeppelin Contracts for `IERC20` / `SafeERC20` (MIT), forge-std (MIT), viem (MIT).
- This repository adds code under the MIT license as well; see `LICENSE`.