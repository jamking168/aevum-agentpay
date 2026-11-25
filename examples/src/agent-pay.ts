/**
 * AgentPay demo: an AI agent spends inside a session the payer opened for it.
 *
 *   pnpm example agent-pay
 *
 * Env (examples/.env, both keys are TEST wallets - never fund them on mainnet):
 *   AGENT_PAY_ADDRESS   deployed AgentPay contract
 *   MERCHANT_ADDRESS    who gets paid
 *   PAYER_KEY           opens the session, approves the budget, can revoke
 *   AGENT_KEY           pays the invoices; it never holds the money
 *
 * What it shows, in order:
 *   1. the payer opens a session for the agent (budget 10 tUSD8, 3 per payment, 1 hour)
 *   2. the agent pays two invoices (2 and 3 tUSD8) - both land on chain
 *   3. the agent tries a 4 tUSD8 invoice - refused by the per-payment cap
 *   4. the agent retries invoice #1 - refused as already paid
 *   5. the payer revokes the session; the next payment is refused
 * Every refusal is a revert from the contract, not a rule the agent chose to follow.
 */
import { createWalletClient, http, keccak256, parseAbi, parseUnits, toHex, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { TUSD8_ADDRESS, erc20Abi, txUrl } from "@aevum-kit/aevum";
import { connect, requiredAddress, requiredKey } from "./env";

const agentPayAbi = parseAbi([
  "function openSession(bytes32 sessionId, address agent, uint256 budget, uint256 perPaymentCap, uint64 expiry)",
  "function pay(bytes32 sessionId, bytes32 orderId, address merchant, uint256 amount)",
  "function revoke(bytes32 sessionId)",
  "function remaining(bytes32 sessionId) view returns (uint256)",
  "function isOrderPaid(bytes32 sessionId, bytes32 orderId) view returns (bool)",
  "event Paid(bytes32 indexed sessionId, bytes32 indexed orderId, address indexed agent, address payer, address merchant, uint256 amount, uint256 spentAfter)",
]);

const { client, chain, rpcUrl } = await connect();
const agentPay = requiredAddress("AGENT_PAY_ADDRESS");
const merchant = requiredAddress("MERCHANT_ADDRESS");
const payer = privateKeyToAccount(requiredKey("PAYER_KEY"));
const agent = privateKeyToAccount(requiredKey("AGENT_KEY"));

const payerWallet = createWalletClient({ account: payer, chain, transport: http(rpcUrl) });
const agentWallet = createWalletClient({ account: agent, chain, transport: http(rpcUrl) });

const budget = parseUnits("10", 6);
const perPayment = parseUnits("3", 6);
const sessionId = keccak256(toHex(`demo-session-${Date.now()}`)) as Hex;
const expiry = BigInt(Math.floor(Date.now() / 1000) + 3600);

console.log("chain    ", chain.id);
console.log("AgentPay ", agentPay);
console.log("payer    ", payer.address);
console.log("agent    ", agent.address);
console.log("session  ", sessionId);

console.log("\n1) payer opens the session and approves the budget");
let hash = await payerWallet.writeContract({
  address: TUSD8_ADDRESS,
  abi: erc20Abi,
  functionName: "approve",
  args: [agentPay, budget],
});
await client.waitForTransactionReceipt({ hash });
console.log("   approve    ", txUrl(hash));

hash = await payerWallet.writeContract({
  address: agentPay,
  abi: agentPayAbi,
  functionName: "openSession",
  args: [sessionId, agent.address, budget, perPayment, expiry],
});
await client.waitForTransactionReceipt({ hash });
console.log("   openSession", txUrl(hash));

const invoices = [
  { orderId: keccak256(toHex("invoice-1")) as Hex, amount: parseUnits("2", 6), note: "2 tUSD8 - inside the cap" },
  { orderId: keccak256(toHex("invoice-2")) as Hex, amount: parseUnits("3", 6), note: "3 tUSD8 - inside the cap" },
  { orderId: keccak256(toHex("invoice-3")) as Hex, amount: parseUnits("4", 6), note: "4 tUSD8 - above the per-payment cap" },
  { orderId: keccak256(toHex("invoice-1")) as Hex, amount: parseUnits("2", 6), note: "invoice-1 again - replay" },
];

console.log("\n2) the agent works through the invoices");
for (const inv of invoices) {
  try {
    const h = await agentWallet.writeContract({
      address: agentPay,
      abi: agentPayAbi,
      functionName: "pay",
      args: [sessionId, inv.orderId, merchant, inv.amount],
    });
    await client.waitForTransactionReceipt({ hash: h });
    console.log(`   PAID     ${inv.note}`);
    console.log(`            ${txUrl(h)}`);
  } catch (e) {
    console.log(`   REFUSED  ${inv.note} -> ${shortReason(e)}`);
  }
}

console.log("\n3) payer revokes the session");
hash = await payerWallet.writeContract({
  address: agentPay,
  abi: agentPayAbi,
  functionName: "revoke",
  args: [sessionId],
});
await client.waitForTransactionReceipt({ hash });
console.log("   revoke     ", txUrl(hash));

try {
  const h = await agentWallet.writeContract({
    address: agentPay,
    abi: agentPayAbi,
    functionName: "pay",
    args: [sessionId, keccak256(toHex("invoice-4")) as Hex, merchant, parseUnits("1", 6)],
  });
  await client.waitForTransactionReceipt({ hash: h });
  console.log("   PAID     after revoke - this must not happen");
} catch (e) {
  console.log(`   REFUSED  after revoke -> ${shortReason(e)}`);
}

const left = (await client.readContract({
  address: agentPay,
  abi: agentPayAbi,
  functionName: "remaining",
  args: [sessionId],
})) as bigint;

console.log("\nsummary");
console.log("   session remaining", Number(left) / 1e6, "tUSD8");
console.log("   every refusal above came from the contract, not from this script");

function shortReason(e: unknown): string {
  const s = e instanceof Error ? e.message : String(e);
  const m = s.match(
    /(BudgetExceeded|PerPaymentCapExceeded|OrderAlreadyPaid|SessionIsRevoked|SessionExpired|MerchantNotAllowed|NotAgent)/,
  );
  return m ? m[1] : s.split("\n")[0].slice(0, 120);
}
