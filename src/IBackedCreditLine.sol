// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IAgentCreditLine} from "./IAgentCreditLine.sol";

/// @title Agent Credit Backers (draft ERC): the lender
/// @notice A lender of the Agent Credit Lines draft that lets a backer, with the identity owner's signed consent, stand
///         behind an identity's line and absorb its loss.
/// @dev The ERC-165 identifier is `type(IBackedCreditLine).interfaceId`; it covers only the functions declared here.
///      The owner's consent is an EIP-712 signature over
///      `BackerConsent(address lender,uint256 agentId,address backer,uint256 line,uint256 nonce,uint256 deadline)` in
///      the domain `EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)` with name
///      "Agent Credit Backers", version "1", the chain id and the lender's address.
interface IBackedCreditLine is IAgentCreditLine {
    /// @notice `backer` now stands behind a line of `line` for `agentId`. Both are zero when a backer was removed.
    event BackerSet(uint256 indexed agentId, address indexed backer, uint256 line);

    /// @notice `loanId` defaulted: `backer` was charged its `principal` and the lender took `paid` of it.
    event BackerCharged(
        uint256 indexed loanId, uint256 indexed agentId, address indexed backer, uint256 principal, uint256 paid
    );

    /// @notice A call to `backer` with `selector` (`onDefault` or `onRelease`) failed; the lender went on without it.
    event BackerHookFailed(uint256 indexed agentId, address indexed backer, bytes4 selector);

    /// @notice `payer` paid `amount` of the part of `backer`'s charge for `loanId` that it had left unpaid. It counts
    ///         as paid by `backer`.
    event LossPaid(uint256 indexed loanId, address indexed backer, address indexed payer, uint256 amount);

    /// @notice `payer` paid `amount` toward `loanId` after its default, and `toBacker` of it went to `backer`.
    event Recovered(
        uint256 indexed loanId, address indexed backer, address indexed payer, uint256 amount, uint256 toBacker
    );

    /// @notice The backer standing behind `agentId`'s line, or the zero address.
    function backerOf(uint256 agentId) external view returns (address);

    /// @notice The line the backer stands behind for `agentId`, and the principal of active loans drawn under it.
    function backedLine(uint256 agentId) external view returns (uint256 line, uint256 outstanding);

    /// @notice The backer `loanId` was drawn under, or the zero address.
    function backerOfLoan(uint256 loanId) external view returns (address);

    /// @notice The nonce the owner's next consent for `agentId` must carry.
    function consentNonce(uint256 agentId) external view returns (uint256);

    /// @notice For a defaulted `loanId` drawn under a backer: what the backer has paid of its charge (at the default
    ///         and through `payLoss`), the part still unpaid, all that `recover` took, and the part of that which went
    ///         to the backer. Zeros for any other loan.
    function lossInfo(uint256 loanId)
        external
        view
        returns (uint256 paid, uint256 unpaid, uint256 recovered, uint256 returned);

    /// @notice Anyone. Pays up to `amount` of the part of the backer's charge for `loanId` it left unpaid, as the
    ///         backer's payment. Returns what it took.
    function payLoss(uint256 loanId, uint256 amount) external returns (uint256 taken);

    /// @notice Anyone. Pays up to `amount` toward `loanId` after its default: first the part of the backer's charge
    ///         left unpaid, then back to the backer up to what it paid, then the fee. Returns what it took.
    function recover(uint256 loanId, uint256 amount) external returns (uint256 taken);

    /// @notice Puts `backer` (the caller) behind a line of `line` for `agentId`, or changes its line, with the owner's
    ///         signed consent valid until `deadline`.
    function setBacker(uint256 agentId, address backer, uint256 line, uint256 deadline, bytes calldata ownerConsent)
        external;

    /// @notice Ends the backing of `agentId`. Its backer or its owner, once no loan drawn under it is active.
    function removeBacker(uint256 agentId) external;
}
