// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

// `onRelease` reasons.
// The backer lowered its line with `setBacker`: `amount` is the decrease.
uint8 constant RELEASE_LOWERED = 1;
// The backing ended with `removeBacker`: `amount` is the whole remaining line.
uint8 constant RELEASE_REMOVED = 2;
// The owner named another backer with `setBacker`: `amount` is the whole remaining line of the backer replaced.
uint8 constant RELEASE_REPLACED = 3;

/// @title Agent Credit Backers (draft ERC): the backer
/// @notice A contract that stands behind a lender's line to an agent identity and absorbs its loss. The lender asks it
///         before each draw (`canBorrow`) and tells it of each draw (`onBorrow`), default (`onDefault`) and release
///         (`onRelease`). A backer also implements ERC-165.
/// @dev The ERC-165 identifier is `type(ICreditBacker).interfaceId`.
interface ICreditBacker {
    /// @notice Whether the backer stands behind this draw at `lender`: `caller` draws `amount` for `agentId` over
    ///         `term` seconds at `fee`, `owner` is the identity's owner now and `to` receives the money. The answer
    ///         does not depend on who asks.
    function canBorrow(
        address lender,
        uint256 agentId,
        uint256 amount,
        uint64 term,
        uint256 fee,
        address caller,
        address owner,
        address to
    ) external view returns (bool);

    /// @notice `lender` recorded `loanId` for `agentId` under this backer and sent the money.
    function onBorrow(address lender, uint256 agentId, uint256 loanId) external;

    /// @notice `loanId` defaulted. `principal` is the loss charged to this backer; `lender` already took `paid` of it.
    function onDefault(address lender, uint256 agentId, uint256 loanId, uint256 principal, uint256 paid) external;

    /// @notice `amount` of the line this backer stood behind for `agentId` at `lender` is no longer backed by it, for
    ///         `reason` (one of the RELEASE_ constants).
    function onRelease(address lender, uint256 agentId, uint256 amount, uint8 reason) external;
}
