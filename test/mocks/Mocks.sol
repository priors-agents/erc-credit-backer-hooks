// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IAgentCreditLine} from "../../src/IAgentCreditLine.sol";
import {ICreditBacker} from "../../src/ICreditBacker.sol";
import {IBackedCreditLine} from "../../src/IBackedCreditLine.sol";

/// @notice An ERC-721-shaped identity registry reduced to what the tests need: mint, transfer, burn, ownerOf.
contract MockRegistry {
    mapping(uint256 => address) private _owners;

    function mint(address to, uint256 id) external {
        _owners[id] = to;
    }

    function transfer(uint256 id, address to) external {
        require(_owners[id] == msg.sender, "not owner");
        _owners[id] = to;
    }

    function burn(uint256 id) external {
        require(_owners[id] == msg.sender, "not owner");
        delete _owners[id];
    }

    function ownerOf(uint256 id) external view returns (address o) {
        o = _owners[id];
        require(o != address(0), "no token");
    }
}

/// @notice A plain ERC-20 with a public mint, and traps that make it misbehave when it moves an address's funds (or,
///         for `BurnOnRead`, when it reads that address's balance), standing in for a token that calls the holder's
///         own code during a transfer, as an ERC-777 token calls its `tokensToSend` hook.
contract MockToken {
    enum Trap {
        None,
        Revert, // reverts with a short reason
        ReturnFalse, // returns false and moves nothing
        BurnGas, // uses all the gas it is given
        RevertBomb, // reverts with as much data as its gas can pay for
        ReturnBomb, // returns as much data as its gas can pay for, the first word reading `true`, and moves nothing
        BurnOnRead // `balanceOf` uses all the gas it is given
    }

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => Trap) public trap;
    /// @notice A freeze list, as USDC and USDT keep: no transfer from or to a frozen address.
    mapping(address => bool) public frozen;

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
    }

    function setTrap(address account, Trap t) external {
        trap[account] = t;
    }

    function setFrozen(address account, bool isFrozen) external {
        frozen[account] = isFrozen;
    }

    function balanceOf(address account) external view returns (uint256) {
        if (trap[account] == Trap.BurnOnRead) _burn();
        return _balances[account];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(trap[msg.sender] != Trap.Revert, "frozen");
        require(!frozen[msg.sender] && !frozen[to], "frozen");
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(!frozen[from] && !frozen[to], "frozen");
        Trap t = trap[from];
        if (t == Trap.Revert) revert("frozen");
        if (t == Trap.ReturnFalse) return false;
        if (t == Trap.BurnGas) _burn();
        if (t == Trap.RevertBomb) _bomb(false);
        if (t == Trap.ReturnBomb) _bomb(true);
        allowance[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }

    function _burn() private pure {
        while (true) {}
    }

    /// @dev Ends the call with about as much data as the gas left can pay for, so that copying it would cost the
    ///      caller about as much again.
    function _bomb(bool asReturn) private view {
        uint256 words = _sqrt(gasleft() * 512 * 7 / 10); // memory costs about words^2 / 512 gas
        uint256 size = words * 32;
        assembly {
            mstore(0, 1)
            switch asReturn
            case 0 { revert(0, size) }
            default { return(0, size) }
        }
    }

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}

/// @notice The parts every test backer shares: ERC-165, and calls to a lender made as the backer itself.
abstract contract BackerBase is ICreditBacker {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ICreditBacker).interfaceId || interfaceId == 0x01ffc9a7;
    }

    function setBackerAt(IBackedCreditLine lender, uint256 agentId, uint256 line, uint256 deadline, bytes calldata sig)
        external
    {
        lender.setBacker(agentId, address(this), line, deadline, sig);
    }

    function removeAt(IBackedCreditLine lender, uint256 agentId) external {
        lender.removeBacker(agentId);
    }

    function approve(MockToken token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }
}

/// @notice A backer that answers `canBorrow` as told and keeps a tally of every notification it receives.
contract RecordingBacker is BackerBase {
    enum Answer {
        Yes,
        No,
        Revert
    }

    Answer public answer;
    bool public refuseOnBorrow;
    uint256 public borrows;
    uint256 public defaults;
    uint256 public charged; // sum of the principals passed to onDefault
    uint256 public paidTotal; // sum of the `paid` passed to onDefault
    uint256 public releases;
    uint256 public released; // sum of the amounts passed to onRelease
    uint8 public lastReason;
    bool public badReason; // set if a reason outside 1..3 ever arrives
    uint256 public gasAtLastNotification;

    function setAnswer(Answer a) external {
        answer = a;
    }

    function setRefuseOnBorrow(bool on) external {
        refuseOnBorrow = on;
    }

    function canBorrow(address, uint256, uint256, uint64, uint256, address, address, address)
        external
        view
        returns (bool)
    {
        if (answer == Answer.Revert) revert("no answer");
        return answer == Answer.Yes;
    }

    function onBorrow(address, uint256, uint256) external {
        require(!refuseOnBorrow, "not this draw");
        borrows += 1;
    }

    function onDefault(address, uint256, uint256, uint256 principal, uint256 paid) external {
        gasAtLastNotification = gasleft();
        defaults += 1;
        charged += principal;
        paidTotal += paid;
    }

    function onRelease(address, uint256, uint256 amount, uint8 reason) external {
        gasAtLastNotification = gasleft();
        releases += 1;
        released += amount;
        lastReason = reason;
        if (reason == 0 || reason > 3) badReason = true;
    }
}

/// @notice A backer that lets every draw through and then misbehaves in `onDefault` and `onRelease`.
contract MisbehavingBacker is BackerBase {
    enum Mode {
        Behave,
        Revert,
        BurnGas,
        ReturnBomb
    }

    Mode public mode;

    function setMode(Mode m) external {
        mode = m;
    }

    function canBorrow(address, uint256, uint256, uint64, uint256, address, address, address)
        external
        pure
        returns (bool)
    {
        return true;
    }

    function onBorrow(address, uint256, uint256) external {}

    function onDefault(address, uint256, uint256, uint256, uint256) external view {
        _misbehave();
    }

    function onRelease(address, uint256, uint256, uint8) external view {
        _misbehave();
    }

    function _misbehave() private view {
        Mode m = mode;
        if (m == Mode.Revert) revert("down");
        if (m == Mode.BurnGas) {
            while (true) {}
        }
        if (m == Mode.ReturnBomb) {
            // About 160 KB of return data, as much as the gas budget allows: copying it would cost the caller dearly.
            assembly {
                return(0, 160000)
            }
        }
    }
}

/// @notice A contract that tries to become a backer without implementing ICreditBacker.
contract NotABacker {
    function setBackerAt(IBackedCreditLine lender, uint256 agentId, uint256 line, uint256 deadline, bytes calldata sig)
        external
    {
        lender.setBacker(agentId, address(this), line, deadline, sig);
    }
}

/// @notice A smart-account owner: it approves a signature (ERC-1271) when its signer key made it.
contract MockERC1271Wallet {
    address public immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        if (sig.length != 65) return 0xffffffff;
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        return ecrecover(hash, v, r, s) == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @notice A backer whose hooks call back into the lender while the lender is still in the middle of an action. It
///         either keeps the lender's error and returns, or reverts with it.
contract HostileBacker is BackerBase {
    enum Target {
        Borrow,
        Repay,
        MarkDefault,
        SetBacker,
        RemoveBacker
    }

    IBackedCreditLine public immutable lender;
    uint256 public immutable agentId;
    bool public armed;
    Target public target;
    bool public bubble;
    bytes public lastError;
    bool public reentered; // set if a call back into the lender ever went through

    constructor(IBackedCreditLine lender_, uint256 agentId_) {
        lender = lender_;
        agentId = agentId_;
    }

    function arm(Target t, bool bubble_) external {
        armed = true;
        target = t;
        bubble = bubble_;
    }

    function canBorrow(address, uint256, uint256, uint64, uint256, address, address, address)
        external
        pure
        returns (bool)
    {
        return true;
    }

    function onBorrow(address, uint256, uint256) external {
        _reenter();
    }

    function onDefault(address, uint256, uint256, uint256, uint256) external {
        _reenter();
    }

    function onRelease(address, uint256, uint256, uint8) external {
        _reenter();
    }

    function _reenter() private {
        if (!armed) return;
        (bool ok, bytes memory err) = address(lender).call(_callData());
        if (ok) {
            reentered = true;
            return;
        }
        if (bubble) {
            assembly {
                revert(add(err, 32), mload(err))
            }
        }
        lastError = err;
    }

    function _callData() private view returns (bytes memory) {
        Target t = target;
        if (t == Target.Borrow) {
            return abi.encodeCall(IAgentCreditLine.borrow, (agentId, 1, 1 days, address(this), type(uint256).max));
        }
        if (t == Target.Repay) return abi.encodeCall(IAgentCreditLine.repay, (1, type(uint256).max));
        if (t == Target.MarkDefault) return abi.encodeCall(IAgentCreditLine.markDefault, (1));
        if (t == Target.SetBacker) {
            return abi.encodeCall(IBackedCreditLine.setBacker, (agentId, address(this), 1, type(uint256).max, ""));
        }
        return abi.encodeCall(IBackedCreditLine.removeBacker, (agentId));
    }
}
