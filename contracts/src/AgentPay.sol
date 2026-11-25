// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal EIP-3009 subset: tUSD8 on Aevum implements `receiveWithAuthorization`.
interface IERC3009Receive {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

/// @title AgentPay
/// @notice Spending sessions for AI agents paying in a stablecoin (tUSD8 on Aevum).
///
///         A payer opens a session for one agent with four hard limits that live in the
///         contract, not in the agent's prompt:
///           - a total budget,
///           - a per-payment cap,
///           - an expiry timestamp,
///           - an optional merchant allowlist,
///         plus per-order idempotency so a retried or replayed payment cannot charge twice.
///         The contract never holds funds: money moves payer -> merchant in the same call.
///
/// @dev Two payment paths:
///       1. `pay` — the agent calls it directly and pays gas; the payer has approved this
///          contract for the budget.
///       2. `payWithAuthorization` — the payer signs an EIP-3009 `ReceiveWithAuthorization`
///          bound to (sessionId, orderId); anyone, including a relayer, can submit it, so the
///          agent needs no native gas at all.
///
///      Both paths check the same gates in `_precheck`/`_record`, so an agent cannot escape a
///      limit by switching paths. Nothing here is Cancun-only: Aevum runs Shanghai.
contract AgentPay {
    using SafeERC20 for IERC20;

    struct Session {
        address payer;
        address agent;
        uint64 expiry;
        uint256 budget;
        uint256 spent;
        uint256 perPaymentCap;
        bool revoked;
        bool exists;
    }

    IERC20 public immutable token;

    /// @notice EIP-3009 signature parts, grouped so the gasless entrypoint stays readable.
    struct Authorization {
        uint256 validAfter;
        uint256 validBefore;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    mapping(bytes32 sessionId => Session) private _sessions;
    mapping(bytes32 sessionId => mapping(address merchant => bool)) private _allowed;
    mapping(bytes32 sessionId => uint256) private _allowlistCount;
    mapping(bytes32 paymentKey => bool) private _used;

    event SessionOpened(
        bytes32 indexed sessionId,
        address indexed payer,
        address indexed agent,
        uint256 budget,
        uint256 perPaymentCap,
        uint64 expiry
    );
    event MerchantAllowed(bytes32 indexed sessionId, address indexed merchant, bool allowed);
    event Paid(
        bytes32 indexed sessionId,
        bytes32 indexed orderId,
        address indexed agent,
        address payer,
        address merchant,
        uint256 amount,
        uint256 spentAfter
    );
    event SessionRevoked(bytes32 indexed sessionId, address indexed payer);

    error ZeroAddress();
    error ZeroAmount();
    error SessionExists(bytes32 sessionId);
    error SessionUnknown(bytes32 sessionId);
    error NotPayer();
    error NotAgent();
    error SessionExpired(uint64 expiry);
    error SessionIsRevoked();
    error BudgetExceeded(uint256 budget, uint256 spent, uint256 amount);
    error PerPaymentCapExceeded(uint256 cap, uint256 amount);
    error MerchantNotAllowed(address merchant);
    error OrderAlreadyPaid(bytes32 sessionId, bytes32 orderId);

    constructor(IERC20 token_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
    }

    // ---------------------------------------------------------------- payer side

    /// @notice Open a spending session for `agent`.
    /// @dev The payer must approve this contract for at least `budget` of `token`.
    ///      Sessions are immutable once opened except for the allowlist and `revoke`.
    function openSession(
        bytes32 sessionId,
        address agent,
        uint256 budget,
        uint256 perPaymentCap,
        uint64 expiry
    ) external {
        if (agent == address(0)) revert ZeroAddress();
        if (_sessions[sessionId].exists) revert SessionExists(sessionId);
        if (budget == 0) revert ZeroAmount();
        if (perPaymentCap == 0) revert ZeroAmount();
        if (expiry <= block.timestamp) revert SessionExpired(expiry);

        _sessions[sessionId] = Session({
            payer: msg.sender,
            agent: agent,
            expiry: expiry,
            budget: budget,
            spent: 0,
            perPaymentCap: perPaymentCap,
            revoked: false,
            exists: true
        });

        emit SessionOpened(sessionId, msg.sender, agent, budget, perPaymentCap, expiry);
    }

    /// @notice Allow or block one merchant for a session. With at least one allowed merchant,
    ///         only allowed merchants can be paid (the allowlist is opt-in, not default-deny).
    function allowMerchant(bytes32 sessionId, address merchant, bool allowed) external {
        Session storage s = _sessions[sessionId];
        if (!s.exists) revert SessionUnknown(sessionId);
        if (s.payer != msg.sender) revert NotPayer();
        if (merchant == address(0)) revert ZeroAddress();
        bool was = _allowed[sessionId][merchant];
        if (allowed && !was) _allowlistCount[sessionId] += 1;
        if (!allowed && was) _allowlistCount[sessionId] -= 1;
        _allowed[sessionId][merchant] = allowed;
        emit MerchantAllowed(sessionId, merchant, allowed);
    }

    /// @notice Kill the session at once. The payer's tokens were never escrowed, so there is
    ///         nothing to withdraw: revoking only stops future payments.
    function revoke(bytes32 sessionId) external {
        Session storage s = _sessions[sessionId];
        if (!s.exists) revert SessionUnknown(sessionId);
        if (s.payer != msg.sender) revert NotPayer();
        s.revoked = true;
        emit SessionRevoked(sessionId, msg.sender);
    }

    // ---------------------------------------------------------------- agent side

    /// @notice Pay `merchant` for `orderId` from the payer's balance, within the session limits.
    ///         The agent (or the payer) pays the gas.
    function pay(bytes32 sessionId, bytes32 orderId, address merchant, uint256 amount) external {
        Session storage s = _sessions[sessionId];
        if (!s.exists) revert SessionUnknown(sessionId);
        if (msg.sender != s.agent && msg.sender != s.payer) revert NotAgent();
        _precheck(s, sessionId, orderId, merchant, amount);
        _record(s, sessionId, orderId, msg.sender, merchant, amount);
        token.safeTransferFrom(s.payer, merchant, amount);
    }

    /// @notice Gasless path: submit the payer's EIP-3009 signature for one order.
    /// @dev The signed nonce must equal `paymentNonce(sessionId, orderId)`, so a signature can
    ///      only ever settle that one order in that one session. `to` must be this contract;
    ///      `receiveWithAuthorization` (not `transferWithAuthorization`) keeps a watcher from
    ///      front-running the signature into a plain transfer.
    function payWithAuthorization(
        bytes32 sessionId,
        bytes32 orderId,
        address merchant,
        uint256 amount,
        Authorization calldata auth
    ) external {
        Session storage session = _sessions[sessionId];
        if (!session.exists) revert SessionUnknown(sessionId);
        _precheck(session, sessionId, orderId, merchant, amount);

        address payer = session.payer;
        address agent = msg.sender;
        _record(session, sessionId, orderId, agent, merchant, amount);

        IERC3009Receive(address(token)).receiveWithAuthorization(
            payer,
            address(this),
            amount,
            auth.validAfter,
            auth.validBefore,
            paymentNonce(sessionId, orderId),
            auth.v,
            auth.r,
            auth.s
        );
        token.safeTransfer(merchant, amount);
    }

    // ---------------------------------------------------------------- views

    function sessionOf(bytes32 sessionId) external view returns (Session memory) {
        return _sessions[sessionId];
    }

    function remaining(bytes32 sessionId) external view returns (uint256) {
        Session storage s = _sessions[sessionId];
        if (!s.exists) return 0;
        return s.budget - s.spent;
    }

    function isOrderPaid(bytes32 sessionId, bytes32 orderId) external view returns (bool) {
        return _used[_paymentKey(sessionId, orderId)];
    }

    function isMerchantAllowed(bytes32 sessionId, address merchant) external view returns (bool) {
        return _allowed[sessionId][merchant];
    }

    /// @notice Nonce the payer must sign for `receiveWithAuthorization` on this order.
    function paymentNonce(bytes32 sessionId, bytes32 orderId) public pure returns (bytes32) {
        return keccak256(abi.encodePacked("AgentPay:payment", sessionId, orderId));
    }

    // ---------------------------------------------------------------- internals

    function _precheck(
        Session storage s,
        bytes32 sessionId,
        bytes32 orderId,
        address merchant,
        uint256 amount
    ) private view {
        if (s.revoked) revert SessionIsRevoked();
        if (block.timestamp >= s.expiry) revert SessionExpired(s.expiry);
        if (amount == 0) revert ZeroAmount();
        if (amount > s.perPaymentCap) revert PerPaymentCapExceeded(s.perPaymentCap, amount);
        if (s.spent + amount > s.budget) revert BudgetExceeded(s.budget, s.spent, amount);
        if (merchant == address(0)) revert ZeroAddress();
        if (_hasAllowlist(sessionId) && !_allowed[sessionId][merchant]) {
            revert MerchantNotAllowed(merchant);
        }
        if (_used[_paymentKey(sessionId, orderId)]) revert OrderAlreadyPaid(sessionId, orderId);
    }

    function _record(
        Session storage s,
        bytes32 sessionId,
        bytes32 orderId,
        address agent,
        address merchant,
        uint256 amount
    ) private {
        _used[_paymentKey(sessionId, orderId)] = true;
        s.spent += amount;
        emit Paid(sessionId, orderId, agent, s.payer, merchant, amount, s.spent);
    }

    /// @dev The allowlist is opt-in: a session with no allowed merchant may pay anyone. Once the
    ///      payer allows one merchant, only allowed merchants can be paid. Callers read
    ///      `isMerchantAllowed` off-chain; on-chain we track it with a counter-free rule:
    ///      a session "has an allowlist" when its payer has allowed at least one merchant.
    function _hasAllowlist(bytes32 sessionId) private view returns (bool) {
        return _allowlistCount[sessionId] > 0;
    }

    function _paymentKey(bytes32 sessionId, bytes32 orderId) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(sessionId, orderId));
    }
}
