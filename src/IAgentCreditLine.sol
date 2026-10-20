// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

// From ERC-8450 Agent Credit Lines (github.com/priors-agents/ERC-8450), copied unchanged. The Agent Credit Backers
// draft extends it.

/// @title Agent Credit Lines (draft ERC)
/// @notice Revolving credit extended by a lender to identities of an ERC-721 identity registry (an ERC-8004 Identity
///         Registry): quote, borrow, repay, amount due and default, with one fixed set of events.
/// @dev The ERC-165 identifier is `type(IAgentCreditLine).interfaceId`.
interface IAgentCreditLine {
    enum LoanStatus {
        None,
        Active,
        Repaid,
        Defaulted
    }

    struct LoanInfo {
        uint256 agentId;
        address owner; // the registry owner of agentId when the loan was drawn
        uint256 principal;
        uint256 fee;
        uint64 issuedAt;
        uint64 dueAt;
        uint64 defaultableAt;
        LoanStatus status;
    }

    /// @notice A loan was drawn. `to` received `principal`; `fee` is owed on top of it by `dueAt`.
    event Borrowed(
        uint256 indexed loanId,
        uint256 indexed agentId,
        address indexed to,
        uint256 principal,
        uint256 fee,
        uint64 dueAt
    );

    /// @notice A loan was repaid in full by `payer`.
    event Repaid(
        uint256 indexed loanId, uint256 indexed agentId, address indexed payer, uint256 principal, uint256 fee
    );

    /// @notice A loan was marked defaulted. `owner` is the registry owner recorded when it was drawn.
    event Defaulted(uint256 indexed loanId, uint256 indexed agentId, address indexed owner, uint256 principal);

    /// @notice The ERC-721 contract whose token ids are the agent ids this lender serves.
    function identityRegistry() external view returns (address);

    /// @notice The ERC-20 token lent and repaid.
    function asset() external view returns (address);

    /// @notice Whether `account` may borrow for `agentId`: its registry owner, or a delegate the lender accepts.
    function isController(uint256 agentId, address account) external view returns (bool);

    /// @notice The most `borrow` would lend to `agentId` now, in base units of `asset()`.
    function availableCredit(uint256 agentId) external view returns (uint256);

    /// @notice The fee `borrow` would charge for `amount` over `term` seconds now.
    function quote(uint256 agentId, uint256 amount, uint64 term) external view returns (uint256 fee);

    /// @notice Draws `amount` for `agentId`, sends it to `to`, and returns the new loan's id (never 0).
    function borrow(uint256 agentId, uint256 amount, uint64 term, address to, uint256 maxFee)
        external
        returns (uint256 loanId);

    /// @notice What `repay` would take to close `loanId` now; 0 unless the loan is active.
    function amountDue(uint256 loanId) external view returns (uint256);

    /// @notice Closes `loanId` with the caller's funds, taking at most `maxDue`. Anyone may repay.
    function repay(uint256 loanId, uint256 maxDue) external returns (uint256 paid);

    /// @notice Marks `loanId` defaulted once `block.timestamp` has reached its `defaultableAt`. Anyone may call it.
    function markDefault(uint256 loanId) external;

    /// @notice Everything recorded about `loanId`.
    function loanInfo(uint256 loanId) external view returns (LoanInfo memory);
}
