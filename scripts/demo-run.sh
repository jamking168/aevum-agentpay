#!/usr/bin/env bash
# Rebuild the whole AgentPay demo from scratch on a local fork of the Aevum testnet and
# record what actually happened into demo/transcript.txt.
#
# The fork is a real copy of Aevum testnet state (chain 440050 wraps chain 44005), so the
# token the demo moves is the real tUSD8 contract, not a mock. Nothing here touches the
# live chain: anvil impersonates tUSD8's minter locally to fund the throwaway wallets
# that .secrets/ holds.
set -uo pipefail

export PATH="$HOME/.foundry/bin:$PATH"
ROOT=/home/jam/projects/money-coo/aevum-challenge
FORK_RPC=http://127.0.0.1:8555
LOG="$ROOT/demo/transcript.txt"
mkdir -p "$ROOT/demo"
: > "$LOG"

cd "$ROOT" || exit 1

say() { printf '%s\n' "$*" | tee -a "$LOG"; }

# 1. fork -------------------------------------------------------------------
if cast chain-id --rpc-url "$FORK_RPC" >/dev/null 2>&1; then
  say "fork already running on $FORK_RPC"
else
  say "starting anvil fork of https://rpc-test.qday.info (chain 440050)"
  nohup anvil --fork-url https://rpc-test.qday.info --hardfork shanghai \
    --chain-id 440050 --port 8555 >"$ROOT/demo/anvil.log" 2>&1 &
  for _ in $(seq 1 90); do
    cast chain-id --rpc-url "$FORK_RPC" >/dev/null 2>&1 && break
    sleep 1
  done
fi

CHAIN=$(cast chain-id --rpc-url "$FORK_RPC" 2>/dev/null)
BLOCK=$(cast block-number --rpc-url "$FORK_RPC" 2>/dev/null)
say "fork ready: chainId=$CHAIN block=$BLOCK"
if [ "$CHAIN" != "440050" ]; then
  say "ABORT: fork is not up (chainId '$CHAIN')"
  exit 1
fi

# 2. deploy -----------------------------------------------------------------
say ""
say "deploying AgentPay with the real tUSD8 0x456569838f1d43009A91ebA4263147Afd7233483"
DEPLOY_OUT=$(make -s deploy-agentpay-fork 2>&1)
ADDR=$(printf '%s\n' "$DEPLOY_OUT" | awk '/^ *AgentPay /{print $NF}' | tail -1)
if [ -z "$ADDR" ]; then
  say "ABORT: could not read the deployed address"
  printf '%s\n' "$DEPLOY_OUT" | tee -a "$LOG"
  exit 1
fi
say "AgentPay deployed at $ADDR"

# 3. fund the two throwaway wallets -----------------------------------------
ENVOUT=$(python3 scripts/make-example-env.py "$ADDR" 2>&1)
PAYER_ADDR=$(printf '%s\n' "$ENVOUT" | awk '/^  payer/{print $2}')
MERCHANT_ADDR=$(printf '%s\n' "$ENVOUT" | awk '/^  merchant/{print $2}')
AGENT_ADDR=$(printf '%s\n' "$ENVOUT" | awk '$1=="agent"{print $2}')

say ""
say "funding the demo wallets from tUSD8's minter (local impersonation only)"
make -s deal TO="$PAYER_ADDR" AMOUNT=10 2>&1 | tee -a "$LOG"
# The agent is the one sending pay() and therefore the one paying gas; give it native
# tQDAY too, otherwise every payment fails on insufficient funds instead of on the
# contract's own gates, which is what this demo is supposed to show.
cast rpc anvil_setBalance "$AGENT_ADDR" 0x8ac7230489e80000 --rpc-url "$FORK_RPC" >/dev/null
say "agent $AGENT_ADDR funded with 10 tQDAY for gas"

say ""
say "running the end-to-end flow (payer opens a session, agent pays, three attempts get refused)"
cd "$ROOT/examples" || exit 1
npx tsx --env-file-if-exists=.env src/agent-pay.ts 2>&1 | tee -a "$LOG"
RC=${PIPESTATUS[0]}
cd "$ROOT" || exit 1

say ""
say "exit code: $RC"
say "fork block after the run: $(cast block-number --rpc-url "$FORK_RPC" 2>/dev/null)"