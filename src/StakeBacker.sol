// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {ICreditBacker, RELEASE_LOWERED} from "./ICreditBacker.sol";
import {IBackedCreditLine} from "./IBackedCreditLine.sol";

interface IERC20Approve {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IERC721OwnerOf {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/// @title StakeBacker
/// @notice Reference backer of the Agent Credit Backers draft. Its manager stakes the asset and puts the contract behind
///         lines to agent identities at lenders of that asset. Stake covers every line in full: the manager can only
///         withdraw what no line holds, and the contract approves each lender for exactly the sum of its lines there,
///         which is where a lender takes a defaulted principal from. It backs the owner that consented, so it refuses
///         draws once the identity has changed hands, and it refuses every draw after a default under it.
/// @dev Not audited. A reference for the interface.
contract StakeBacker is ICreditBacker, IERC165 {
    struct Backing {
        uint256 line;
        address owner; // the identity's owner when the backing began
        bool active;
        bool defaulted;
    }

    IERC20Approve public immutable asset;
    address public immutable manager;
    /// @notice The sum of every line this backer stands behind: the stake that cannot be withdrawn.
    uint256 public committed;
    /// @notice lender => the sum of this backer's lines there, which is also the lender's allowance.
    mapping(address => uint256) public linesAt;
    /// @notice lender => agentId => what this backer stands behind there.
    mapping(address => mapping(uint256 => Backing)) public backings;

    event Backed(address indexed lender, uint256 indexed agentId, uint256 line, address owner);
    event Drawn(address indexed lender, uint256 indexed agentId, uint256 indexed loanId);
    event Charged(
        address indexed lender, uint256 indexed agentId, uint256 indexed loanId, uint256 principal, uint256 paid
    );
    event Released(address indexed lender, uint256 indexed agentId, uint256 amount, uint8 reason);

    error NotManager();
    error NotLender();
    error NotBacking();
    error AlreadyBacking();
    error DefaultedHere();
    error WrongAsset();
    error NotEnoughStake(uint256 free);
    error TransferFailed();

    modifier onlyManager() {
        if (msg.sender != manager) revert NotManager();
        _;
    }

    constructor(address asset_, address manager_) {
        asset = IERC20Approve(asset_);
        manager = manager_;
    }

    // ---------------------------------------------------------------- manager

    /// @notice Stands behind a line of `line` for `agentId` at `lender`, with the owner's signed consent. The stake
    ///         not yet committed must cover the line.
    function back(
        IBackedCreditLine lender,
        uint256 agentId,
        uint256 line,
        uint256 deadline,
        bytes calldata ownerConsent
    ) external onlyManager {
        if (lender.asset() != address(asset)) revert WrongAsset();
        Backing storage k = backings[address(lender)][agentId];
        if (k.active) revert AlreadyBacking();
        if (k.defaulted) revert DefaultedHere();
        uint256 free = freeStake();
        if (line > free) revert NotEnoughStake(free);

        committed += line;
        linesAt[address(lender)] += line;
        k.line = line;
        k.owner = IERC721OwnerOf(lender.identityRegistry()).ownerOf(agentId);
        k.active = true;
        _approve(address(lender));
        emit Backed(address(lender), agentId, line, k.owner);
        lender.setBacker(agentId, address(this), line, deadline, ownerConsent);
    }

    /// @notice Stops backing `agentId` at `lender` once nothing is drawn under it. The lender's `onRelease` frees the
    ///         line.
    function leave(IBackedCreditLine lender, uint256 agentId) external onlyManager {
        lender.removeBacker(agentId);
    }

    /// @notice Withdraws stake that no line holds.
    function withdraw(address to, uint256 amount) external onlyManager {
        uint256 free = freeStake();
        if (amount > free) revert NotEnoughStake(free);
        if (!asset.transfer(to, amount)) revert TransferFailed();
    }

    // ---------------------------------------------------------------- views

    /// @notice Stake that no line holds.
    function freeStake() public view returns (uint256) {
        uint256 balance = asset.balanceOf(address(this));
        return balance > committed ? balance - committed : 0;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ICreditBacker).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ---------------------------------------------------------------- ICreditBacker

    /// @notice Reads only its arguments and this contract's records, so anyone can ask it about a draw at `lender`.
    function canBorrow(address lender, uint256 agentId, uint256, uint64, uint256, address, address owner, address)
        external
        view
        returns (bool)
    {
        Backing storage k = backings[lender][agentId];
        return k.active && !k.defaulted && owner == k.owner;
    }

    function onBorrow(address lender, uint256 agentId, uint256 loanId) external {
        _backingOfCaller(lender, agentId);
        emit Drawn(lender, agentId, loanId);
    }

    /// @dev The lender has already taken `paid` from this contract's balance; the line it spent is no longer held.
    function onDefault(address lender, uint256 agentId, uint256 loanId, uint256 principal, uint256 paid) external {
        Backing storage k = _backingOfCaller(lender, agentId);
        k.defaulted = true;
        _shrink(lender, k, principal);
        emit Charged(lender, agentId, loanId, principal, paid);
    }

    function onRelease(address lender, uint256 agentId, uint256 amount, uint8 reason) external {
        Backing storage k = _backingOfCaller(lender, agentId);
        _shrink(lender, k, amount);
        if (reason != RELEASE_LOWERED) k.active = false; // removed or replaced: the backing is over
        emit Released(lender, agentId, amount, reason);
    }

    // ---------------------------------------------------------------- recovery

    /// @notice Anyone. Brings this backer's record of a backing in line with the lender's after a notification that
    ///         failed, so a missed `onDefault` or `onRelease` cannot hold stake forever.
    function sync(IBackedCreditLine lender, uint256 agentId) external {
        Backing storage k = backings[address(lender)][agentId];
        if (!k.active) return;
        bool stillBacking = lender.backerOf(agentId) == address(this);
        uint256 actual;
        if (stillBacking) (actual,) = lender.backedLine(agentId);
        if (actual >= k.line) return;
        _shrink(address(lender), k, k.line - actual);
        // This backer never lowers a line itself, so a line it still holds shrinks only through a default.
        if (stillBacking) k.defaulted = true;
        else k.active = false;
    }

    // ---------------------------------------------------------------- internals

    function _backingOfCaller(address lender, uint256 agentId) private view returns (Backing storage k) {
        if (msg.sender != lender) revert NotLender();
        k = backings[lender][agentId];
        if (!k.active) revert NotBacking();
    }

    function _shrink(address lender, Backing storage k, uint256 amount) private {
        k.line -= amount;
        committed -= amount;
        linesAt[lender] -= amount;
        _approve(lender);
    }

    function _approve(address lender) private {
        if (!asset.approve(lender, linesAt[lender])) revert TransferFailed();
    }
}
