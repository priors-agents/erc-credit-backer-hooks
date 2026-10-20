// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IAgentCreditLine} from "../src/IAgentCreditLine.sol";
import {IBackedCreditLine} from "../src/IBackedCreditLine.sol";
import {ICreditBacker} from "../src/ICreditBacker.sol";
import {BackedCreditLine} from "../src/BackedCreditLine.sol";
import {StakeBacker} from "../src/StakeBacker.sol";
import {Fixture} from "./Fixture.sol";
import {MockToken, RecordingBacker} from "./mocks/Mocks.sol";

contract StakeBackerTest is Fixture {
    event Charged(
        address indexed lender, uint256 indexed agentId, uint256 indexed loanId, uint256 principal, uint256 paid
    );
    event BackerHookFailed(uint256 indexed agentId, address indexed backer, bytes4 selector);

    address manager = makeAddr("manager");
    StakeBacker stake;

    function setUp() public override {
        super.setUp();
        stake = new StakeBacker(address(usd), manager);
        usd.mint(address(stake), 100e6); // the manager's stake
    }

    function _stakeBehind(uint256 line) internal {
        bytes memory sig = _consent(address(stake), line);
        uint256 deadline = _deadline();
        vm.prank(manager);
        stake.back(lender, AGENT, line, deadline, sig);
    }

    function _canBorrow(address asker, address who) internal returns (bool) {
        vm.prank(asker);
        return stake.canBorrow(address(lender), AGENT, 10e6, 7 days, 23_334, owner, who, wallet);
    }

    // ------------------------------------------------------------- interface

    function test_supportsInterface() public view {
        assertTrue(stake.supportsInterface(type(ICreditBacker).interfaceId));
        assertTrue(stake.supportsInterface(0x01ffc9a7)); // ERC-165
        assertFalse(stake.supportsInterface(0xffffffff));
    }

    // ------------------------------------------------------------- backing and losses

    function test_back_standsBehindTheLineWithStake() public {
        _stakeBehind(50e6);
        assertEq(lender.backerOf(AGENT), address(stake));
        assertEq(stake.committed(), 50e6);
        assertEq(stake.linesAt(address(lender)), 50e6);
        assertEq(usd.allowance(address(stake), address(lender)), 50e6);
        assertEq(stake.freeStake(), 50e6);
        assertEq(lender.availableCredit(AGENT), 50e6);
    }

    function test_back_paysTheDefaultedPrincipalFromStake() public {
        _stakeBehind(50e6);
        uint256 loanId = _borrow(20e6, 7 days);
        uint256 cashBefore = usd.balanceOf(address(lender));
        vm.warp(lender.loanInfo(loanId).defaultableAt);
        vm.expectEmit(true, true, true, true);
        emit Charged(address(lender), AGENT, loanId, 20e6, 20e6);
        lender.markDefault(loanId);

        assertEq(usd.balanceOf(address(lender)), cashBefore + 20e6);
        assertEq(usd.balanceOf(address(stake)), 80e6);
        assertEq(stake.committed(), 30e6);
        assertEq(stake.linesAt(address(lender)), 30e6);
        assertEq(usd.allowance(address(stake), address(lender)), 30e6);
        assertEq(stake.freeStake(), 50e6); // the loss came out of the line's stake, not the free stake
        (uint256 line,) = lender.backedLine(AGENT);
        assertEq(line, 30e6);
    }

    function test_refusesEveryDrawAfterADefault() public {
        _stakeBehind(50e6);
        _default(_borrow(20e6, 7 days));
        assertFalse(_canBorrow(stranger, owner));
        vm.prank(owner);
        vm.expectRevert(BackedCreditLine.BackerRefused.selector);
        lender.borrow(AGENT, 1e6, 7 days, wallet, type(uint256).max);

        // nor will it stand behind the identity at that lender again
        vm.prank(manager);
        stake.leave(lender, AGENT);
        bytes memory sig = _consent(address(stake), 10e6);
        uint256 deadline = _deadline();
        vm.prank(manager);
        vm.expectRevert(StakeBacker.DefaultedHere.selector);
        stake.back(lender, AGENT, 10e6, deadline, sig);
    }

    function test_refusesDrawsOnceTheIdentityChangesHands() public {
        _stakeBehind(50e6);
        address buyer = makeAddr("buyer");
        vm.prank(owner);
        registry.transfer(AGENT, buyer);
        vm.prank(buyer);
        vm.expectRevert(BackedCreditLine.BackerRefused.selector);
        lender.borrow(AGENT, 1e6, 7 days, wallet, type(uint256).max);
    }

    function test_back_needsFreeStake() public {
        bytes memory sig = _consent(address(stake), 150e6);
        uint256 deadline = _deadline();
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(StakeBacker.NotEnoughStake.selector, 100e6));
        stake.back(lender, AGENT, 150e6, deadline, sig);
    }

    function test_back_lenderOfAnotherAsset_reverts() public {
        MockToken other = new MockToken();
        BackedCreditLine otherLender = new BackedCreditLine(address(registry), address(other), FEE_BPS, GRACE, MAX_TERM);
        vm.prank(manager);
        vm.expectRevert(StakeBacker.WrongAsset.selector);
        stake.back(otherLender, AGENT, 10e6, _deadline(), "");
    }

    function test_withdraw_onlyFreeStake() public {
        _stakeBehind(50e6);
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(StakeBacker.NotEnoughStake.selector, 50e6));
        stake.withdraw(manager, 50e6 + 1);
        stake.withdraw(manager, 50e6);
        vm.stopPrank();
        assertEq(usd.balanceOf(manager), 50e6);
        assertEq(stake.freeStake(), 0);
    }

    function test_onlyTheManagerActs() public {
        vm.startPrank(stranger);
        vm.expectRevert(StakeBacker.NotManager.selector);
        stake.back(lender, AGENT, 10e6, 0, "");
        vm.expectRevert(StakeBacker.NotManager.selector);
        stake.leave(lender, AGENT);
        vm.expectRevert(StakeBacker.NotManager.selector);
        stake.withdraw(stranger, 1);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- releases

    function test_leave_releasesTheLine() public {
        _stakeBehind(50e6);
        vm.prank(manager);
        stake.leave(lender, AGENT);
        assertEq(lender.backerOf(AGENT), address(0));
        assertEq(stake.committed(), 0);
        assertEq(usd.allowance(address(stake), address(lender)), 0);
        assertEq(stake.freeStake(), 100e6);
        assertFalse(_canBorrow(stranger, owner));
    }

    function test_replacedByAnotherBacker_releasesTheLine() public {
        _stakeBehind(50e6);
        RecordingBacker next = new RecordingBacker();
        _back(next, 20e6);
        assertEq(stake.committed(), 0);
        assertEq(stake.freeStake(), 100e6);
        (,,, bool defaulted) = stake.backings(address(lender), AGENT);
        assertFalse(defaulted);
        assertFalse(_canBorrow(stranger, owner));
    }

    // ------------------------------------------------------------- the backer's rules

    function test_canBorrow_sameAnswerWhoeverAsks() public {
        _stakeBehind(50e6);
        assertTrue(_canBorrow(address(lender), owner));
        assertTrue(_canBorrow(stranger, owner));
        assertTrue(_canBorrow(address(this), owner));
        address someoneElse = makeAddr("someoneElse");
        assertFalse(_canBorrow(address(lender), someoneElse));
        assertFalse(_canBorrow(stranger, someoneElse));
    }

    function test_hooks_onlyFromTheLender() public {
        _stakeBehind(50e6);
        vm.startPrank(stranger);
        vm.expectRevert(StakeBacker.NotLender.selector);
        stake.onBorrow(address(lender), AGENT, 1);
        vm.expectRevert(StakeBacker.NotLender.selector);
        stake.onDefault(address(lender), AGENT, 1, 50e6, 0);
        vm.expectRevert(StakeBacker.NotLender.selector);
        stake.onRelease(address(lender), AGENT, 50e6, 2);
        vm.stopPrank();
        // a caller that names itself as the lender is not one this backer stands behind
        vm.prank(stranger);
        vm.expectRevert(StakeBacker.NotBacking.selector);
        stake.onRelease(stranger, AGENT, 50e6, 2);
        assertEq(stake.committed(), 50e6);
    }

    // ------------------------------------------------------------- recovering from a missed notification

    function test_sync_recoversAMissedDefault() public {
        _stakeBehind(50e6);
        uint256 loanId = _borrow(20e6, 7 days);
        vm.mockCallRevert(address(stake), abi.encodeWithSelector(ICreditBacker.onDefault.selector), "down");
        vm.warp(lender.loanInfo(loanId).defaultableAt);
        vm.expectEmit(true, true, true, true);
        emit BackerHookFailed(AGENT, address(stake), ICreditBacker.onDefault.selector);
        lender.markDefault(loanId);
        vm.clearMockedCalls();
        assertEq(stake.committed(), 50e6); // stale: the notification never arrived
        assertTrue(_canBorrow(stranger, owner));

        stake.sync(lender, AGENT);
        assertEq(stake.committed(), 30e6);
        assertEq(usd.allowance(address(stake), address(lender)), 30e6);
        assertFalse(_canBorrow(stranger, owner));
    }

    function test_sync_recoversAMissedRemoval() public {
        _stakeBehind(50e6);
        vm.mockCallRevert(address(stake), abi.encodeWithSelector(ICreditBacker.onRelease.selector), "down");
        vm.prank(owner);
        lender.removeBacker(AGENT);
        vm.clearMockedCalls();
        assertEq(stake.committed(), 50e6);

        stake.sync(lender, AGENT);
        assertEq(stake.committed(), 0);
        assertEq(stake.freeStake(), 100e6);
        assertFalse(_canBorrow(stranger, owner));
        stake.sync(lender, AGENT); // nothing left to do
        assertEq(stake.committed(), 0);
    }

    function test_endToEnd_drawRepayDraw() public {
        _stakeBehind(50e6);
        uint256 first = _borrow(50e6, 7 days);
        _repay(first);
        uint256 second = _borrow(50e6, 14 days);
        assertEq(uint8(lender.loanInfo(second).status), uint8(IAgentCreditLine.LoanStatus.Active));
        assertEq(lender.backerOfLoan(second), address(stake));
        assertEq(stake.committed(), 50e6);
        assertEq(IBackedCreditLine(address(lender)).backerOf(AGENT), address(stake));
    }
}
