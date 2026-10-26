// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IAgentCreditLine} from "../src/IAgentCreditLine.sol";
import {IBackedCreditLine} from "../src/IBackedCreditLine.sol";
import {ICreditBacker} from "../src/ICreditBacker.sol";
import {BackedCreditLine} from "../src/BackedCreditLine.sol";
import {Fixture} from "./Fixture.sol";
import {
    RecordingBacker,
    MisbehavingBacker,
    NotABacker,
    MockERC1271Wallet,
    MockToken,
    HostileBacker
} from "./mocks/Mocks.sol";

contract BackedCreditLineTest is Fixture {
    event BackerSet(uint256 indexed agentId, address indexed backer, uint256 line);
    event BackerCharged(
        uint256 indexed loanId, uint256 indexed agentId, address indexed backer, uint256 principal, uint256 paid
    );
    event BackerHookFailed(uint256 indexed agentId, address indexed backer, bytes4 selector);
    event Defaulted(uint256 indexed loanId, uint256 indexed agentId, address indexed owner, uint256 principal);
    event LossPaid(uint256 indexed loanId, address indexed backer, address indexed payer, uint256 amount);
    event Recovered(
        uint256 indexed loanId, address indexed backer, address indexed payer, uint256 amount, uint256 toBacker
    );
    event BackerPaid(address indexed backer, uint256 amount);
    event ConsentsRevoked(uint256 indexed agentId, address indexed owner, uint256 nonce);

    uint256 constant FEE_10_FOR_7_DAYS = 23_334; // 10 units at 1% per 30 days for 7 days, rounded up
    uint256 constant DUE_10_FOR_7_DAYS = 10e6 + FEE_10_FOR_7_DAYS;

    RecordingBacker backer;

    function setUp() public override {
        super.setUp();
        backer = new RecordingBacker();
        usd.mint(address(backer), 100e6);
        backer.approve(usd, address(lender), 50e6);
    }

    function _misbehaving(MisbehavingBacker.Mode mode) internal returns (MisbehavingBacker m) {
        m = new MisbehavingBacker();
        usd.mint(address(m), 100e6);
        m.approve(usd, address(lender), 50e6);
        _back(m, 50e6);
        m.setMode(mode);
    }

    // ------------------------------------------------------------- interfaces

    function test_supportsInterface() public view {
        assertTrue(lender.supportsInterface(type(IBackedCreditLine).interfaceId));
        assertTrue(lender.supportsInterface(type(IAgentCreditLine).interfaceId));
        assertTrue(lender.supportsInterface(0x01ffc9a7)); // ERC-165
        assertFalse(lender.supportsInterface(0xffffffff));
    }

    // ------------------------------------------------------------- consent

    function test_setBacker_validConsent_setsBackerAndEmits() public {
        uint256 deadline = _deadline();
        bytes32 digest = _digest(address(lender), AGENT, address(backer), 50e6, 0, deadline);
        assertEq(lender.consentDigest(AGENT, address(backer), 50e6, 0, deadline), digest);
        assertEq(lender.consentNonce(AGENT), 0);

        vm.expectEmit(true, true, true, true);
        emit BackerSet(AGENT, address(backer), 50e6);
        backer.setBackerAt(lender, AGENT, 50e6, deadline, _sign(ownerKey, digest));

        assertEq(lender.backerOf(AGENT), address(backer));
        (uint256 line, uint256 outstanding) = lender.backedLine(AGENT);
        assertEq(line, 50e6);
        assertEq(outstanding, 0);
        assertEq(lender.consentNonce(AGENT), 1);
        assertEq(lender.availableCredit(AGENT), 50e6);
    }

    function test_setBacker_wrongSigner_reverts() public {
        (, uint256 strangerKey) = makeAddrAndKey("strangerKey");
        uint256 deadline = _deadline();
        bytes memory sig = _sign(strangerKey, _digest(address(lender), AGENT, address(backer), 50e6, 0, deadline));
        vm.expectRevert(BackedCreditLine.BadConsent.selector);
        backer.setBackerAt(lender, AGENT, 50e6, deadline, sig);
    }

    function test_setBacker_consentForOtherTerms_reverts() public {
        uint256 deadline = _deadline();
        bytes memory forFifty = _sign(ownerKey, _digest(address(lender), AGENT, address(backer), 50e6, 0, deadline));
        // a larger line than the owner signed for
        vm.expectRevert(BackedCreditLine.BadConsent.selector);
        backer.setBackerAt(lender, AGENT, 60e6, deadline, forFifty);
        // another backer than the one named
        RecordingBacker other = new RecordingBacker();
        vm.expectRevert(BackedCreditLine.BadConsent.selector);
        other.setBackerAt(lender, AGENT, 50e6, deadline, forFifty);
        // another lender than the one named
        BackedCreditLine lender2 = new BackedCreditLine(address(registry), address(usd), FEE_BPS, GRACE, MAX_TERM);
        vm.expectRevert(BackedCreditLine.BadConsent.selector);
        backer.setBackerAt(lender2, AGENT, 50e6, deadline, forFifty);
        // another deadline than the one signed
        vm.expectRevert(BackedCreditLine.BadConsent.selector);
        backer.setBackerAt(lender, AGENT, 50e6, deadline + 1, forFifty);
    }

    function test_setBacker_expiredConsent_reverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerKey, _digest(address(lender), AGENT, address(backer), 50e6, 0, deadline));
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(BackedCreditLine.ConsentExpired.selector, deadline));
        backer.setBackerAt(lender, AGENT, 50e6, deadline, sig);
        vm.warp(deadline); // the deadline itself is still in time
        backer.setBackerAt(lender, AGENT, 50e6, deadline, sig);
        assertEq(lender.backerOf(AGENT), address(backer));
    }

    function test_setBacker_replayedConsent_reverts() public {
        uint256 deadline = _deadline();
        bytes memory sig = _sign(ownerKey, _digest(address(lender), AGENT, address(backer), 50e6, 0, deadline));
        backer.setBackerAt(lender, AGENT, 50e6, deadline, sig);
        backer.removeAt(lender, AGENT);
        vm.expectRevert(BackedCreditLine.BadConsent.selector);
        backer.setBackerAt(lender, AGENT, 50e6, deadline, sig);
        assertEq(lender.backerOf(AGENT), address(0));
    }

    function test_setBacker_highSSignature_reverts() public {
        uint256 deadline = _deadline();
        bytes32 digest = _digest(address(lender), AGENT, address(backer), 50e6, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        // The same signature's twin, (r, n - s, the other v), also recovers the owner; the draft refuses it.
        uint256 n = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        bytes32 highS = bytes32(n - uint256(s));
        uint8 otherV = v == 27 ? 28 : 27;
        assertEq(ecrecover(digest, otherV, r, highS), owner);
        vm.expectRevert(BackedCreditLine.BadConsent.selector);
        backer.setBackerAt(lender, AGENT, 50e6, deadline, abi.encodePacked(r, highS, otherV));
    }

    function test_setBacker_contractOwner_consentsThroughERC1271() public {
        (address key, uint256 keyKey) = makeAddrAndKey("walletKey");
        MockERC1271Wallet smartOwner = new MockERC1271Wallet(key);
        uint256 agent2 = AGENT + 1;
        registry.mint(address(smartOwner), agent2);
        uint256 deadline = _deadline();
        bytes32 digest = _digest(address(lender), agent2, address(backer), 50e6, 0, deadline);

        vm.expectRevert(BackedCreditLine.BadConsent.selector);
        backer.setBackerAt(lender, agent2, 50e6, deadline, _sign(ownerKey, digest)); // not the wallet's key

        backer.setBackerAt(lender, agent2, 50e6, deadline, _sign(keyKey, digest));
        assertEq(lender.backerOf(agent2), address(backer));
        assertEq(lender.consentNonce(agent2), 1);
    }

    function test_setBacker_notCalledByTheBacker_reverts() public {
        uint256 deadline = _deadline();
        bytes memory sig = _sign(ownerKey, _digest(address(lender), AGENT, address(backer), 50e6, 0, deadline));
        vm.prank(stranger);
        vm.expectRevert(BackedCreditLine.NotBacker.selector);
        lender.setBacker(AGENT, address(backer), 50e6, deadline, sig);
        vm.prank(owner); // not even the owner can put a backer behind its identity without the backer
        vm.expectRevert(BackedCreditLine.NotBacker.selector);
        lender.setBacker(AGENT, address(backer), 50e6, deadline, sig);
    }

    function test_setBacker_backerWithoutTheInterface_reverts() public {
        NotABacker plain = new NotABacker();
        uint256 deadline = _deadline();
        bytes memory sig = _sign(ownerKey, _digest(address(lender), AGENT, address(plain), 50e6, 0, deadline));
        vm.expectRevert(BackedCreditLine.NotACreditBacker.selector);
        plain.setBackerAt(lender, AGENT, 50e6, deadline, sig);
        // an account with no code cannot be a backer either
        sig = _sign(ownerKey, _digest(address(lender), AGENT, stranger, 50e6, 0, deadline));
        vm.prank(stranger);
        vm.expectRevert(BackedCreditLine.NotACreditBacker.selector);
        lender.setBacker(AGENT, stranger, 50e6, deadline, sig);
    }

    function test_setBacker_zeroLine_reverts() public {
        uint256 deadline = _deadline();
        bytes memory sig = _sign(ownerKey, _digest(address(lender), AGENT, address(backer), 0, 0, deadline));
        vm.expectRevert(BackedCreditLine.ZeroLine.selector);
        backer.setBackerAt(lender, AGENT, 0, deadline, sig);
    }

    // ------------------------------------------------------------- changing and replacing

    function test_setBacker_lowerLine_releasesTheDifference_raiseReleasesNothing() public {
        _back(backer, 50e6);
        vm.expectCall(address(backer), abi.encodeCall(ICreditBacker.onRelease, (address(lender), AGENT, 20e6, 1)));
        _back(backer, 30e6);
        assertEq(backer.releases(), 1);
        assertEq(backer.released(), 20e6);
        assertEq(backer.lastReason(), 1);
        (uint256 line,) = lender.backedLine(AGENT);
        assertEq(line, 30e6);

        _back(backer, 80e6); // a raise is not a release
        assertEq(backer.releases(), 1);
        (line,) = lender.backedLine(AGENT);
        assertEq(line, 80e6);
    }

    function test_setBacker_lineBelowOutstanding_reverts() public {
        _back(backer, 50e6);
        _borrow(20e6, 7 days);
        bytes memory sig = _consent(address(backer), 10e6);
        uint256 deadline = _deadline();
        vm.expectRevert(abi.encodeWithSelector(BackedCreditLine.LineBelowOutstanding.selector, 20e6));
        backer.setBackerAt(lender, AGENT, 10e6, deadline, sig);
        _back(backer, 20e6); // down to what is drawn is fine
        assertEq(backer.released(), 30e6);
        assertEq(lender.availableCredit(AGENT), 0);
    }

    function test_setBacker_replace_releasesTheOldLine() public {
        _back(backer, 50e6);
        RecordingBacker next = new RecordingBacker();
        vm.expectCall(address(backer), abi.encodeCall(ICreditBacker.onRelease, (address(lender), AGENT, 50e6, 3)));
        vm.expectEmit(true, true, true, true);
        emit BackerSet(AGENT, address(next), 40e6);
        _back(next, 40e6);
        assertEq(lender.backerOf(AGENT), address(next));
        assertEq(backer.released(), 50e6);
        assertEq(backer.lastReason(), 3);
        assertEq(next.releases(), 0);
    }

    function test_setBacker_replaceWhileLoanActive_reverts() public {
        _back(backer, 50e6);
        uint256 loanId = _borrow(10e6, 7 days);
        RecordingBacker next = new RecordingBacker();
        bytes memory sig = _consent(address(next), 40e6);
        uint256 deadline = _deadline();
        vm.expectRevert(abi.encodeWithSelector(BackedCreditLine.LoansOutstanding.selector, 10e6));
        next.setBackerAt(lender, AGENT, 40e6, deadline, sig);
        _repay(loanId);
        next.setBackerAt(lender, AGENT, 40e6, deadline, sig);
        assertEq(lender.backerOf(AGENT), address(next));
    }

    // ------------------------------------------------------------- removing

    function test_removeBacker_byBacker_releasesTheLine() public {
        _back(backer, 50e6);
        vm.expectEmit(true, true, true, true);
        emit BackerSet(AGENT, address(0), 0);
        vm.expectCall(address(backer), abi.encodeCall(ICreditBacker.onRelease, (address(lender), AGENT, 50e6, 2)));
        backer.removeAt(lender, AGENT);
        assertEq(lender.backerOf(AGENT), address(0));
        (uint256 line, uint256 outstanding) = lender.backedLine(AGENT);
        assertEq(line, 0);
        assertEq(outstanding, 0);
        assertEq(backer.lastReason(), 2);
        assertEq(lender.availableCredit(AGENT), 0);
    }

    function test_removeBacker_byOwner_releasesTheLine() public {
        _back(backer, 50e6);
        vm.expectCall(address(backer), abi.encodeCall(ICreditBacker.onRelease, (address(lender), AGENT, 50e6, 2)));
        vm.prank(owner);
        lender.removeBacker(AGENT);
        assertEq(lender.backerOf(AGENT), address(0));
        assertEq(backer.released(), 50e6);
    }

    function test_removeBacker_byStranger_reverts() public {
        _back(backer, 50e6);
        vm.prank(stranger);
        vm.expectRevert(BackedCreditLine.NotBackerOrOwner.selector);
        lender.removeBacker(AGENT);
    }

    function test_removeBacker_whileLoanActive_reverts() public {
        _back(backer, 50e6);
        uint256 loanId = _borrow(10e6, 7 days);
        vm.expectRevert(abi.encodeWithSelector(BackedCreditLine.LoansOutstanding.selector, 10e6));
        backer.removeAt(lender, AGENT);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BackedCreditLine.LoansOutstanding.selector, 10e6));
        lender.removeBacker(AGENT);
        _repay(loanId);
        backer.removeAt(lender, AGENT);
        assertEq(lender.backerOf(AGENT), address(0));
    }

    function test_removeBacker_withoutBacker_reverts() public {
        vm.prank(owner);
        vm.expectRevert(BackedCreditLine.NoBacker.selector);
        lender.removeBacker(AGENT);
    }

    /// @dev The owner signs a raise of the line, then removes the backer before the raise is used: the signature
    ///      cannot bring the backer back. The same when the backer removes itself.
    function test_removeBacker_voidsAConsentNotYetUsed() public {
        _back(backer, 50e6);
        uint256 deadline = _deadline();
        bytes memory raise = _consent(address(backer), 80e6); // signed, not submitted
        uint256 nonce = lender.consentNonce(AGENT);
        vm.prank(owner);
        lender.removeBacker(AGENT);
        vm.expectRevert(BackedCreditLine.BadConsent.selector);
        backer.setBackerAt(lender, AGENT, 80e6, deadline, raise);
        assertEq(lender.backerOf(AGENT), address(0));
        assertEq(lender.consentNonce(AGENT), nonce + 1);

        _back(backer, 50e6);
        raise = _consent(address(backer), 80e6);
        backer.removeAt(lender, AGENT);
        vm.expectRevert(BackedCreditLine.BadConsent.selector);
        backer.setBackerAt(lender, AGENT, 80e6, deadline, raise);
        assertEq(lender.backerOf(AGENT), address(0));
    }

    /// @dev A consent signed while the identity has no backer, voided by its owner before it is used.
    function test_revokeConsents_byTheOwnerOnly_voidsConsentsNotYetUsed() public {
        uint256 deadline = _deadline();
        bytes memory sig = _consent(address(backer), 50e6); // nonce 0, no backer yet
        address key = makeAddr("key");
        vm.prank(owner);
        lender.setDelegate(AGENT, key);
        address[3] memory others = [stranger, address(backer), key];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(BackedCreditLine.NotOwner.selector);
            lender.revokeConsents(AGENT);
        }

        vm.expectEmit(true, true, true, true);
        emit ConsentsRevoked(AGENT, owner, 1);
        vm.prank(owner);
        lender.revokeConsents(AGENT);
        assertEq(lender.consentNonce(AGENT), 1);
        vm.expectRevert(BackedCreditLine.BadConsent.selector);
        backer.setBackerAt(lender, AGENT, 50e6, deadline, sig);
        _back(backer, 50e6); // a consent signed at the new nonce works
        assertEq(lender.backerOf(AGENT), address(backer));
    }

    // ------------------------------------------------------------- drawing

    function test_borrow_asksCanBorrowWithTheDrawsArguments() public {
        _back(backer, 50e6);
        address key = makeAddr("key");
        vm.prank(owner);
        lender.setDelegate(AGENT, key); // so that the caller and the owner differ
        assertEq(lender.quote(AGENT, 10e6, 7 days), FEE_10_FOR_7_DAYS);

        vm.expectCall(
            address(backer),
            abi.encodeCall(
                ICreditBacker.canBorrow,
                (address(lender), AGENT, 10e6, uint64(7 days), FEE_10_FOR_7_DAYS, key, owner, wallet)
            )
        );
        vm.prank(key);
        lender.borrow(AGENT, 10e6, 7 days, wallet, type(uint256).max);
        assertEq(usd.balanceOf(wallet), 10e6);
    }

    function test_borrow_canBorrowFalse_reverts() public {
        _back(backer, 50e6);
        backer.setAnswer(RecordingBacker.Answer.No);
        vm.prank(owner);
        vm.expectRevert(BackedCreditLine.BackerRefused.selector);
        lender.borrow(AGENT, 10e6, 7 days, wallet, type(uint256).max);
        assertEq(usd.balanceOf(wallet), 0);
        assertEq(lender.loanCount(), 0);
    }

    function test_borrow_canBorrowReverts_reverts() public {
        _back(backer, 50e6);
        backer.setAnswer(RecordingBacker.Answer.Revert);
        vm.prank(owner);
        vm.expectRevert(bytes("no answer"));
        lender.borrow(AGENT, 10e6, 7 days, wallet, type(uint256).max);
        assertEq(usd.balanceOf(wallet), 0);
    }

    function test_borrow_tellsOnBorrow_afterRecordingTheLoan() public {
        _back(backer, 50e6);
        vm.expectCall(address(backer), abi.encodeCall(ICreditBacker.onBorrow, (address(lender), AGENT, 1)));
        uint256 loanId = _borrow(10e6, 7 days);
        assertEq(loanId, 1);
        assertEq(backer.borrows(), 1);
        assertEq(uint8(lender.loanInfo(loanId).status), uint8(IAgentCreditLine.LoanStatus.Active));
    }

    function test_borrow_onBorrowReverts_revertsTheDraw() public {
        _back(backer, 50e6);
        backer.setRefuseOnBorrow(true);
        vm.prank(owner);
        vm.expectRevert(bytes("not this draw"));
        lender.borrow(AGENT, 10e6, 7 days, wallet, type(uint256).max);
        assertEq(usd.balanceOf(wallet), 0);
        assertEq(lender.loanCount(), 0);
    }

    function test_borrow_aboveTheBackedLine_reverts() public {
        _back(backer, 50e6);
        _borrow(30e6, 7 days);
        assertEq(lender.availableCredit(AGENT), 20e6); // the line less what is drawn, though cash is 970 units
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BackedCreditLine.OverCredit.selector, 20e6));
        lender.borrow(AGENT, 20e6 + 1, 7 days, wallet, type(uint256).max);
    }

    function test_borrow_recordsTheBackerAndOutstanding() public {
        _back(backer, 50e6);
        uint256 loanId = _borrow(10e6, 7 days);
        assertEq(lender.backerOfLoan(loanId), address(backer));
        (uint256 line, uint256 outstanding) = lender.backedLine(AGENT);
        assertEq(line, 50e6);
        assertEq(outstanding, 10e6);
    }

    function test_borrow_withoutABacker_hasNoCredit() public {
        assertEq(lender.availableCredit(AGENT), 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BackedCreditLine.OverCredit.selector, 0));
        lender.borrow(AGENT, 1e6, 7 days, wallet, type(uint256).max);
    }

    function test_backerOfLoan_staysWithTheLoan() public {
        _back(backer, 50e6);
        uint256 first = _borrow(10e6, 7 days);
        _repay(first);
        RecordingBacker next = new RecordingBacker();
        _back(next, 50e6);
        uint256 second = _borrow(10e6, 7 days);
        assertEq(lender.backerOfLoan(first), address(backer));
        assertEq(lender.backerOfLoan(second), address(next));
        assertEq(lender.backerOfLoan(99), address(0));
    }

    // ------------------------------------------------------------- repaying

    function test_repay_neverCallsTheBacker() public {
        _back(backer, 50e6);
        uint256 loanId = _borrow(10e6, 7 days);
        vm.etch(address(backer), hex"60006000fd"); // from now on every call to the backer reverts
        vm.expectCall(address(backer), bytes(""), 0);
        _repay(loanId);
        assertEq(uint8(lender.loanInfo(loanId).status), uint8(IAgentCreditLine.LoanStatus.Repaid));
    }

    function test_repay_freesTheBackedRoom() public {
        _back(backer, 50e6);
        uint256 loanId = _borrow(30e6, 7 days);
        _repay(loanId);
        (uint256 line, uint256 outstanding) = lender.backedLine(AGENT);
        assertEq(line, 50e6);
        assertEq(outstanding, 0);
        assertEq(lender.availableCredit(AGENT), 50e6);
    }

    // ------------------------------------------------------------- defaults and loss

    function test_markDefault_chargesThePrincipal() public {
        _back(backer, 50e6);
        uint256 loanId = _borrow(10e6, 7 days);
        uint256 cashBefore = usd.balanceOf(address(lender));
        vm.warp(lender.loanInfo(loanId).defaultableAt);

        vm.expectEmit(true, true, true, true);
        emit Defaulted(loanId, AGENT, owner, 10e6);
        vm.expectEmit(true, true, true, true);
        emit BackerCharged(loanId, AGENT, address(backer), 10e6, 10e6);
        vm.expectCall(
            address(backer), abi.encodeCall(ICreditBacker.onDefault, (address(lender), AGENT, loanId, 10e6, 10e6))
        );
        lender.markDefault(loanId);

        // the principal, not the fee, came out of the backer's balance and into the lender's
        assertEq(usd.balanceOf(address(backer)), 90e6);
        assertEq(usd.balanceOf(address(lender)), cashBefore + 10e6);
        (uint256 line, uint256 outstanding) = lender.backedLine(AGENT);
        assertEq(line, 40e6);
        assertEq(outstanding, 0);
        assertEq(backer.charged(), 10e6);
        assertEq(backer.paidTotal(), 10e6);
        assertEq(lender.unpaidLoss(address(backer)), 0);
        assertEq(uint8(lender.loanInfo(loanId).status), uint8(IAgentCreditLine.LoanStatus.Defaulted));
    }

    function test_markDefault_backerShortOfFunds_paysWhatItHas() public {
        RecordingBacker poor = new RecordingBacker();
        usd.mint(address(poor), 4e6);
        poor.approve(usd, address(lender), 50e6);
        _back(poor, 50e6);
        uint256 loanId = _borrow(10e6, 7 days);
        vm.warp(lender.loanInfo(loanId).defaultableAt);
        vm.expectEmit(true, true, true, true);
        emit BackerCharged(loanId, AGENT, address(poor), 10e6, 4e6);
        lender.markDefault(loanId);

        assertEq(usd.balanceOf(address(poor)), 0);
        assertEq(poor.paidTotal(), 4e6);
        assertEq(lender.unpaidLoss(address(poor)), 6e6);
        // no new credit under a backer that left a loss unpaid
        assertEq(lender.availableCredit(AGENT), 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BackedCreditLine.OverCredit.selector, 0));
        lender.borrow(AGENT, 1e6, 7 days, wallet, type(uint256).max);
    }

    function test_markDefault_allowanceCapsWhatIsTaken() public {
        _back(backer, 50e6);
        uint256 first = _borrow(10e6, 7 days);
        uint256 second = _borrow(10e6, 7 days);
        backer.approve(usd, address(lender), 3e6);
        vm.warp(lender.loanInfo(first).defaultableAt);
        vm.expectEmit(true, true, true, true);
        emit BackerCharged(first, AGENT, address(backer), 10e6, 3e6);
        lender.markDefault(first);
        assertEq(usd.balanceOf(address(backer)), 97e6);

        backer.approve(usd, address(lender), 0); // nothing approved: nothing taken, the default still stands
        vm.expectEmit(true, true, true, true);
        emit BackerCharged(second, AGENT, address(backer), 10e6, 0);
        lender.markDefault(second);
        assertEq(usd.balanceOf(address(backer)), 97e6);
        assertEq(uint8(lender.loanInfo(second).status), uint8(IAgentCreditLine.LoanStatus.Defaulted));
        assertEq(lender.unpaidLoss(address(backer)), 17e6);
    }

    function test_markDefault_transferReverts_stillDefaults() public {
        _back(backer, 50e6);
        uint256 loanId = _borrow(10e6, 7 days);
        usd.setTrap(address(backer), MockToken.Trap.Revert); // the token refuses to move the backer's funds
        vm.warp(lender.loanInfo(loanId).defaultableAt);
        vm.expectEmit(true, true, true, true);
        emit BackerCharged(loanId, AGENT, address(backer), 10e6, 0);
        lender.markDefault(loanId);
        assertEq(uint8(lender.loanInfo(loanId).status), uint8(IAgentCreditLine.LoanStatus.Defaulted));
        assertEq(backer.paidTotal(), 0);
    }

    // ------------------------------------------------------------- an asset call cannot block

    /// @dev A 10-unit default while the token misbehaves for the backer's funds: the default completes with a keeper's
    ///      ordinary gas, nothing is paid, the whole principal is unpaid, and the backer is still told.
    function _defaultWhileTheTokenMisbehaves(MockToken.Trap trap) internal {
        _back(backer, 50e6);
        uint256 loanId = _borrow(10e6, 7 days);
        usd.setTrap(address(backer), trap);
        vm.warp(lender.loanInfo(loanId).defaultableAt);
        vm.expectEmit(true, true, true, true);
        emit BackerCharged(loanId, AGENT, address(backer), 10e6, 0);
        lender.markDefault{gas: 1_000_000}(loanId);
        assertEq(uint8(lender.loanInfo(loanId).status), uint8(IAgentCreditLine.LoanStatus.Defaulted));
        assertEq(lender.unpaidLoss(address(backer)), 10e6);
        assertEq(backer.paidTotal(), 0);
        assertEq(backer.defaults(), 1);
    }

    function test_markDefault_tokenReturnsFalse_paysNothing() public {
        _defaultWhileTheTokenMisbehaves(MockToken.Trap.ReturnFalse);
    }

    function test_markDefault_tokenBurnsAllItsGas_stillDefaults() public {
        _defaultWhileTheTokenMisbehaves(MockToken.Trap.BurnGas);
    }

    function test_markDefault_tokenRevertsWithHugeData_stillDefaults() public {
        _defaultWhileTheTokenMisbehaves(MockToken.Trap.RevertBomb);
    }

    function test_markDefault_tokenReturnsHugeData_stillDefaults() public {
        _defaultWhileTheTokenMisbehaves(MockToken.Trap.ReturnBomb);
    }

    function test_markDefault_tokenBurnsGasReadingTheBalance_stillDefaults() public {
        _defaultWhileTheTokenMisbehaves(MockToken.Trap.BurnOnRead);
    }

    /// @dev Another identity with its own owner key and backer, a 10-unit loan drawn, and the token set to misbehave
    ///      with that backer's funds.
    function _trappedLoan(uint256 agentId, string memory name, MockToken.Trap trap) internal returns (uint256 loanId) {
        (address o, uint256 key) = makeAddrAndKey(name);
        registry.mint(o, agentId);
        RecordingBacker b = new RecordingBacker();
        usd.mint(address(b), 100e6);
        b.approve(usd, address(lender), 50e6);
        _backAs(b, agentId, key);
        vm.prank(o);
        loanId = lender.borrow(agentId, 10e6, 7 days, wallet, type(uint256).max);
        usd.setTrap(address(b), trap);
    }

    function _backAs(RecordingBacker b, uint256 agentId, uint256 ownerKey_) internal {
        uint256 deadline = _deadline();
        bytes32 digest = _digest(address(lender), agentId, address(b), 50e6, 0, deadline);
        b.setBackerAt(lender, agentId, 50e6, deadline, _sign(ownerKey_, digest));
    }

    function _gasOfDefault(uint256 loanId) internal returns (uint256) {
        uint256 g = gasleft();
        lender.markDefault(loanId);
        return g - gasleft();
    }

    function test_markDefault_tokenDataBombs_costNoMoreThanTheirBudget() public {
        uint256 quietLoan = _trappedLoan(AGENT + 1, "owner1", MockToken.Trap.ReturnFalse);
        uint256 revertingLoan = _trappedLoan(AGENT + 2, "owner2", MockToken.Trap.RevertBomb);
        uint256 returningLoan = _trappedLoan(AGENT + 3, "owner3", MockToken.Trap.ReturnBomb);
        vm.warp(lender.loanInfo(returningLoan).defaultableAt);

        // A bomb may spend its own budget; copying it back would cost about as much again.
        uint256 limit = _gasOfDefault(quietLoan) + lender.ASSET_GAS() * 3 / 2;
        assertLt(_gasOfDefault(revertingLoan), limit);
        assertLt(_gasOfDefault(returningLoan), limit);
        assertEq(lender.unpaidLoss(lender.backerOfLoan(revertingLoan)), 10e6);
        assertEq(lender.unpaidLoss(lender.backerOfLoan(returningLoan)), 10e6);
    }

    // ------------------------------------------------------------- a backer cannot block

    function test_markDefault_revertingBacker_cannotBlock() public {
        MisbehavingBacker bad = _misbehaving(MisbehavingBacker.Mode.Revert);
        uint256 loanId = _borrow(10e6, 7 days);
        vm.warp(lender.loanInfo(loanId).defaultableAt);
        vm.expectEmit(true, true, true, true);
        emit BackerHookFailed(AGENT, address(bad), ICreditBacker.onDefault.selector);
        lender.markDefault(loanId);
        assertEq(uint8(lender.loanInfo(loanId).status), uint8(IAgentCreditLine.LoanStatus.Defaulted));
        assertEq(usd.balanceOf(address(bad)), 90e6); // the loss was taken before the backer was called
    }

    function test_markDefault_gasBurningBacker_cannotBlock() public {
        MisbehavingBacker bad = _misbehaving(MisbehavingBacker.Mode.BurnGas);
        uint256 loanId = _borrow(10e6, 7 days);
        vm.warp(lender.loanInfo(loanId).defaultableAt);
        vm.expectEmit(true, true, true, true);
        emit BackerHookFailed(AGENT, address(bad), ICreditBacker.onDefault.selector);
        uint256 g = gasleft();
        lender.markDefault(loanId);
        assertLt(g - gasleft(), 250_000); // the backer burnt its budget, not the caller's gas
        assertEq(uint8(lender.loanInfo(loanId).status), uint8(IAgentCreditLine.LoanStatus.Defaulted));
    }

    function test_markDefault_returnBombBacker_cannotBlock() public {
        // Two identical identities, one behind a backer that returns nothing, one behind a backer that returns about
        // 160 KB. Copying that into the lender's memory would cost it more than the whole hook budget.
        _misbehaving(MisbehavingBacker.Mode.Behave);
        uint256 quietLoan = _borrow(10e6, 7 days);

        uint256 agent2 = AGENT + 1;
        (address owner2, uint256 owner2Key) = makeAddrAndKey("owner2");
        registry.mint(owner2, agent2);
        MisbehavingBacker loud = new MisbehavingBacker();
        usd.mint(address(loud), 100e6);
        loud.approve(usd, address(lender), 50e6);
        uint256 deadline = _deadline();
        loud.setBackerAt(
            lender,
            agent2,
            50e6,
            deadline,
            _sign(owner2Key, _digest(address(lender), agent2, address(loud), 50e6, 0, deadline))
        );
        loud.setMode(MisbehavingBacker.Mode.ReturnBomb);
        vm.prank(owner2);
        uint256 loudLoan = lender.borrow(agent2, 10e6, 7 days, wallet, type(uint256).max);

        vm.warp(lender.loanInfo(loudLoan).defaultableAt);
        uint256 g = gasleft();
        lender.markDefault(quietLoan);
        uint256 quietGas = g - gasleft();
        g = gasleft();
        lender.markDefault(loudLoan);
        uint256 loudGas = g - gasleft();

        assertEq(uint8(lender.loanInfo(loudLoan).status), uint8(IAgentCreditLine.LoanStatus.Defaulted));
        assertLt(loudGas, quietGas + lender.HOOK_GAS()); // only the backer's own budget, nothing copied back
    }

    function _misbehaviours() internal pure returns (MisbehavingBacker.Mode[3] memory) {
        return [MisbehavingBacker.Mode.Revert, MisbehavingBacker.Mode.BurnGas, MisbehavingBacker.Mode.ReturnBomb];
    }

    function test_removeBacker_byOwner_misbehavingBackerCannotBlock() public {
        MisbehavingBacker.Mode[3] memory modes = _misbehaviours();
        for (uint256 i; i < modes.length; ++i) {
            MisbehavingBacker bad = _misbehaving(modes[i]);
            if (modes[i] != MisbehavingBacker.Mode.ReturnBomb) {
                // a return, however large, is a success; the other two fail and are logged
                vm.expectEmit(true, true, true, true);
                emit BackerHookFailed(AGENT, address(bad), ICreditBacker.onRelease.selector);
            }
            vm.prank(owner);
            lender.removeBacker(AGENT);
            assertEq(lender.backerOf(AGENT), address(0));
        }
    }

    function test_setBacker_replace_misbehavingOldBackerCannotBlock() public {
        MisbehavingBacker.Mode[3] memory modes = _misbehaviours();
        for (uint256 i; i < modes.length; ++i) {
            MisbehavingBacker bad = _misbehaving(modes[i]);
            if (modes[i] != MisbehavingBacker.Mode.ReturnBomb) {
                vm.expectEmit(true, true, true, true);
                emit BackerHookFailed(AGENT, address(bad), ICreditBacker.onRelease.selector);
            }
            RecordingBacker next = new RecordingBacker();
            _back(next, 40e6);
            assertEq(lender.backerOf(AGENT), address(next));
            next.removeAt(lender, AGENT);
        }
    }

    // ------------------------------------------------------------- the notification budget

    function test_notifications_getTheGasBudget() public {
        _back(backer, 50e6);
        uint256 loanId = _borrow(10e6, 7 days);
        _default(loanId);
        uint256 seen = backer.gasAtLastNotification();
        assertGe(lender.HOOK_GAS(), 100_000);
        assertGt(seen, 99_000); // the budget, less what dispatch costs the backer
        assertLe(seen, lender.HOOK_GAS()); // and no more: the caller's gas is not the backer's

        backer.removeAt(lender, AGENT);
        seen = backer.gasAtLastNotification();
        assertGt(seen, 99_000);
        assertLe(seen, lender.HOOK_GAS());
    }

    /// @dev Every gas amount from too little upwards, one unit of 1,000 at a time: each call either reverts and changes
    ///      nothing, or charges the backer in full and tells it. No amount makes the default go through with the
    ///      transfer or the notification starved; both the asset-call and the hook check are seen refusing.
    function test_markDefault_withAnyGas_revertsOrChargesAndTellsInFull() public {
        _back(backer, 50e6);
        uint256 loanId = _borrow(10e6, 7 days);
        vm.warp(lender.loanInfo(loanId).defaultableAt);
        bytes memory hookStarved = abi.encodeWithSelector(BackedCreditLine.HookStarved.selector);
        bytes memory assetStarved = abi.encodeWithSelector(BackedCreditLine.AssetCallStarved.selector);
        bool sawHookStarved;
        bool sawAssetStarved;
        for (uint256 g = 40_000;; g += 1_000) {
            assertLt(g, 500_000);
            (bool ok, bytes memory ret) = address(lender).call{gas: g}(abi.encodeCall(lender.markDefault, (loanId)));
            if (ok) break;
            assertEq(uint8(lender.loanInfo(loanId).status), uint8(IAgentCreditLine.LoanStatus.Active));
            if (keccak256(ret) == keccak256(hookStarved)) sawHookStarved = true;
            else if (keccak256(ret) == keccak256(assetStarved)) sawAssetStarved = true;
            else assertEq(ret.length, 0); // out of gas before the first check
        }
        assertEq(usd.balanceOf(address(backer)), 90e6);
        assertEq(lender.unpaidLoss(address(backer)), 0);
        assertEq(backer.paidTotal(), 10e6);
        assertEq(backer.defaults(), 1);
        assertTrue(sawAssetStarved);
        assertTrue(sawHookStarved);
    }

    function test_removeBacker_starvedHook_reverts() public {
        _back(backer, 50e6);
        vm.prank(owner);
        (bool ok, bytes memory ret) = address(lender).call{gas: 60_000}(abi.encodeCall(lender.removeBacker, (AGENT)));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(BackedCreditLine.HookStarved.selector));
        assertEq(lender.backerOf(AGENT), address(backer));
    }

    // ------------------------------------------------------------- re-entry

    function _hostile() internal returns (HostileBacker h) {
        h = new HostileBacker(lender, AGENT);
        usd.mint(address(h), 100e6);
        h.approve(usd, address(lender), type(uint256).max);
        _back(h, 50e6);
    }

    function _targets() internal pure returns (HostileBacker.Target[5] memory) {
        return [
            HostileBacker.Target.Borrow,
            HostileBacker.Target.Repay,
            HostileBacker.Target.MarkDefault,
            HostileBacker.Target.SetBacker,
            HostileBacker.Target.RemoveBacker
        ];
    }

    function test_reentry_fromOnBorrow_failsAndTheDrawReverts() public {
        HostileBacker.Target[5] memory targets = _targets();
        HostileBacker h = _hostile();
        for (uint256 i; i < targets.length; ++i) {
            h.arm(targets[i], true); // revert with what the lender answered
            vm.prank(owner);
            vm.expectRevert(BackedCreditLine.Reentrant.selector);
            lender.borrow(AGENT, 1e6, 7 days, wallet, type(uint256).max);
        }
        assertEq(lender.loanCount(), 0);
        assertFalse(h.reentered());
    }

    function test_reentry_fromOnDefault_failsAndTheDefaultCompletes() public {
        HostileBacker.Target[5] memory targets = _targets();
        bytes memory reentrant = abi.encodeWithSelector(BackedCreditLine.Reentrant.selector);
        for (uint256 i; i < targets.length; ++i) {
            for (uint256 j; j < 2; ++j) {
                bool bubble = j == 1;
                HostileBacker h = _hostile();
                uint256 loanId = _borrow(1e6, 7 days);
                h.arm(targets[i], bubble);
                vm.warp(lender.loanInfo(loanId).defaultableAt);
                if (bubble) {
                    vm.expectEmit(true, true, true, true);
                    emit BackerHookFailed(AGENT, address(h), ICreditBacker.onDefault.selector);
                }
                lender.markDefault(loanId);
                assertEq(uint8(lender.loanInfo(loanId).status), uint8(IAgentCreditLine.LoanStatus.Defaulted));
                assertFalse(h.reentered());
                if (!bubble) assertEq(h.lastError(), reentrant);
                vm.prank(owner);
                lender.removeBacker(AGENT); // its onRelease tries again, and is caught again
            }
        }
    }

    function test_reentry_fromOnRelease_failsAndTheRemovalCompletes() public {
        HostileBacker.Target[5] memory targets = _targets();
        bytes memory reentrant = abi.encodeWithSelector(BackedCreditLine.Reentrant.selector);
        for (uint256 i; i < targets.length; ++i) {
            for (uint256 j; j < 2; ++j) {
                bool bubble = j == 1;
                HostileBacker h = _hostile();
                h.arm(targets[i], bubble);
                if (bubble) {
                    vm.expectEmit(true, true, true, true);
                    emit BackerHookFailed(AGENT, address(h), ICreditBacker.onRelease.selector);
                }
                vm.prank(owner);
                lender.removeBacker(AGENT);
                assertEq(lender.backerOf(AGENT), address(0));
                assertFalse(h.reentered());
                if (!bubble) assertEq(h.lastError(), reentrant);
            }
        }
    }

    // ------------------------------------------------------------- consent across chains

    function test_setBacker_consentFromAnotherChain_reverts() public {
        uint256 deadline = _deadline();
        bytes memory signedHere = _sign(ownerKey, _digest(address(lender), AGENT, address(backer), 50e6, 0, deadline));
        vm.chainId(block.chainid + 1); // the same lender address on another chain, or after a fork
        vm.expectRevert(BackedCreditLine.BadConsent.selector);
        backer.setBackerAt(lender, AGENT, 50e6, deadline, signedHere);

        bytes memory signedThere = _sign(ownerKey, _digest(address(lender), AGENT, address(backer), 50e6, 0, deadline));
        backer.setBackerAt(lender, AGENT, 50e6, deadline, signedThere);
        assertEq(lender.backerOf(AGENT), address(backer));
    }

    // ------------------------------------------------------------- every decrease told once

    /// @dev Any sequence of line changes, draws, repayments, defaults and removals: the principals the backer was
    ///      charged plus the amounts released to it plus the line it still holds equal every line and raise it was
    ///      given, and every release carries one of the three reasons.
    function testFuzz_everyLineDecreaseIsToldOnce(uint8[16] calldata ops, uint32[16] calldata sizes) public {
        usd.mint(address(backer), 10_000e6);
        backer.approve(usd, address(lender), type(uint256).max);
        uint256 given;
        uint256[16] memory open;
        uint256 head;
        uint256 tail;

        for (uint256 i; i < 16; ++i) {
            uint256 size = bound(sizes[i], 1, 100) * 1e6;
            (uint256 line, uint256 outstanding) = lender.backedLine(AGENT);
            bool backed = lender.backerOf(AGENT) != address(0);
            uint8 op = ops[i] % 5;
            if (op == 0) {
                if (size < outstanding) continue;
                _back(backer, size);
                if (!backed) given += size;
                else if (size > line) given += size - line;
            } else if (op == 1) {
                uint256 room = lender.availableCredit(AGENT);
                if (room == 0) continue;
                open[tail++] = _borrow(size < room ? size : room, 7 days);
            } else if (op == 2) {
                if (head == tail) continue;
                _repay(open[head++]);
            } else if (op == 3) {
                if (head == tail) continue;
                _default(open[head++]);
            } else {
                if (!backed || outstanding != 0) continue;
                backer.removeAt(lender, AGENT);
            }
        }

        (uint256 finalLine,) = lender.backedLine(AGENT);
        assertEq(backer.charged() + backer.released() + finalLine, given);
        assertEq(backer.paidTotal(), backer.charged());
        assertFalse(backer.badReason());
    }

    // ------------------------------------------------------------- after a default

    /// @dev A backer holding 4 units behind a line of 50, and a 10-unit loan of 7 days that defaulted under it: 4 paid,
    ///      6 left unpaid.
    function _partlyPaidDefault() internal returns (RecordingBacker poor, uint256 loanId) {
        poor = new RecordingBacker();
        usd.mint(address(poor), 4e6);
        poor.approve(usd, address(lender), 50e6);
        _back(poor, 50e6);
        loanId = _borrow(10e6, 7 days);
        _default(loanId);
    }

    function _funded(string memory name, uint256 amount) internal returns (address who) {
        who = makeAddr(name);
        usd.mint(who, amount);
        vm.prank(who);
        usd.approve(address(lender), amount);
    }

    function _assertLoss(uint256 loanId, uint256 paid, uint256 unpaid, uint256 recovered, uint256 returned)
        internal
        view
    {
        (uint256 p, uint256 u, uint256 r, uint256 t) = lender.lossInfo(loanId);
        assertEq(p, paid, "paid");
        assertEq(u, unpaid, "unpaid");
        assertEq(r, recovered, "recovered");
        assertEq(t, returned, "returned");
    }

    /// @dev A 10-unit default collects 4 units and `onDefault` reverts: the line still shrinks by 10, and what the
    ///      backer paid for that loan stays readable by a contract, without the `BackerCharged` log.
    function test_lossInfo_partialCollectionWithAFailedOnDefault() public {
        MisbehavingBacker bad = new MisbehavingBacker();
        usd.mint(address(bad), 4e6);
        bad.approve(usd, address(lender), 50e6);
        _back(bad, 50e6);
        bad.setMode(MisbehavingBacker.Mode.Revert);
        uint256 loanId = _borrow(10e6, 7 days);
        vm.warp(lender.loanInfo(loanId).defaultableAt);
        vm.expectEmit(true, true, true, true);
        emit BackerCharged(loanId, AGENT, address(bad), 10e6, 4e6);
        vm.expectEmit(true, true, true, true);
        emit BackerHookFailed(AGENT, address(bad), ICreditBacker.onDefault.selector);
        lender.markDefault(loanId);

        (uint256 line, uint256 outstanding) = lender.backedLine(AGENT);
        assertEq(line, 40e6);
        assertEq(outstanding, 0);
        _assertLoss(loanId, 4e6, 6e6, 0, 0);
        assertEq(lender.unpaidLoss(address(bad)), 6e6);
    }

    function test_lossInfo_zerosUnlessDefaulted() public {
        _back(backer, 50e6);
        uint256 active = _borrow(10e6, 7 days);
        uint256 repaid = _borrow(10e6, 7 days);
        _repay(repaid);
        _assertLoss(active, 0, 0, 0, 0);
        _assertLoss(repaid, 0, 0, 0, 0);
        _assertLoss(99, 0, 0, 0, 0);
        _default(active);
        _assertLoss(active, 10e6, 0, 0, 0);
    }

    function test_payLossAndRecover_revertUnlessDefaulted() public {
        _back(backer, 50e6);
        uint256 active = _borrow(10e6, 7 days);
        uint256 repaid = _borrow(10e6, 7 days);
        _repay(repaid);
        address payer = _funded("payer2", 100e6);
        uint256[3] memory ids = [active, repaid, uint256(99)];
        for (uint256 i; i < ids.length; ++i) {
            vm.prank(payer);
            vm.expectRevert(BackedCreditLine.NotDefaulted.selector);
            lender.payLoss(ids[i], 1e6);
            vm.prank(payer);
            vm.expectRevert(BackedCreditLine.NotDefaulted.selector);
            lender.recover(ids[i], 1e6);
        }
    }

    function test_payLoss_paysTheUnpaidPart_andCreditComesBack() public {
        (RecordingBacker poor, uint256 loanId) = _partlyPaidDefault();
        assertEq(lender.availableCredit(AGENT), 0);
        address manager = _funded("manager", 100e6);
        uint256 cash = usd.balanceOf(address(lender));

        vm.expectEmit(true, true, true, true);
        emit LossPaid(loanId, address(poor), manager, 6e6);
        vm.prank(manager);
        assertEq(lender.payLoss(loanId, 100e6), 6e6); // no more than is unpaid

        assertEq(usd.balanceOf(address(lender)), cash + 6e6);
        _assertLoss(loanId, 10e6, 0, 0, 0);
        assertEq(lender.unpaidLoss(address(poor)), 0);
        assertEq(lender.availableCredit(AGENT), 40e6); // the line less the cover the default spent, open again
        vm.prank(manager);
        vm.expectRevert(BackedCreditLine.NothingUnpaid.selector);
        lender.payLoss(loanId, 1);
    }

    /// @dev 4 of 10 paid by the backer at the default. What the agent brings back pays the 6 left unpaid first, then
    ///      the backer's 4, then the fee, and no more than the principal and the fee in all.
    function test_recover_unpaidPartThenBackerThenFee() public {
        (RecordingBacker poor, uint256 loanId) = _partlyPaidDefault();
        address agentWallet = _funded("agentWallet", 100e6);
        uint256 cash = usd.balanceOf(address(lender));

        vm.expectEmit(true, true, true, true);
        emit Recovered(loanId, address(poor), agentWallet, 5e6, 0);
        vm.prank(agentWallet);
        lender.recover(loanId, 5e6); // all of it to the unpaid part
        _assertLoss(loanId, 4e6, 1e6, 5e6, 0);
        assertEq(lender.unpaidLoss(address(poor)), 1e6);

        vm.expectEmit(true, true, true, true);
        emit Recovered(loanId, address(poor), agentWallet, 3e6, 2e6);
        vm.prank(agentWallet);
        lender.recover(loanId, 3e6); // the last unit unpaid, then 2 back to the backer
        _assertLoss(loanId, 4e6, 0, 8e6, 2e6);
        assertEq(lender.dueToBacker(address(poor)), 2e6);

        vm.prank(agentWallet);
        assertEq(lender.recover(loanId, 100e6), 2e6 + FEE_10_FOR_7_DAYS); // the backer's last 2, then the fee
        _assertLoss(loanId, 4e6, 0, DUE_10_FOR_7_DAYS, 4e6);
        assertEq(lender.dueToBacker(address(poor)), 4e6);
        assertEq(usd.balanceOf(address(poor)), 0); // credited, not sent
        lender.payBacker(address(poor));
        assertEq(usd.balanceOf(address(poor)), 4e6); // what it paid, back
        assertEq(usd.balanceOf(address(lender)), cash + 6e6 + FEE_10_FOR_7_DAYS);
        assertEq(lender.unpaidLoss(address(poor)), 0);
        assertEq(lender.availableCredit(AGENT), 40e6);

        vm.prank(agentWallet);
        vm.expectRevert(BackedCreditLine.NothingToRecover.selector);
        lender.recover(loanId, 1);
    }

    function test_recover_backerThatPaidInFull_getsItBackBeforeTheFee() public {
        _back(backer, 50e6);
        uint256 loanId = _borrow(10e6, 7 days);
        _default(loanId);
        assertEq(usd.balanceOf(address(backer)), 90e6);
        address agentWallet = _funded("agentWallet", 100e6);

        vm.expectEmit(true, true, true, true);
        emit Recovered(loanId, address(backer), agentWallet, 10e6, 10e6);
        vm.prank(agentWallet);
        lender.recover(loanId, 10e6);
        lender.payBacker(address(backer));
        assertEq(usd.balanceOf(address(backer)), 100e6);
        _assertLoss(loanId, 10e6, 0, 10e6, 10e6);
    }

    /// @dev On a token with a freeze list (USDC keeps one), the backer's address is frozen after it paid at the default.
    ///      A recovery that reaches the backer's part still goes through, and reaches the fee behind it; the backer's
    ///      part waits at the lender until the backer can receive it, and anyone can then pay it, to the backer only.
    function test_recover_frozenBacker_blocksNeitherTheRecoveryNorTheFee() public {
        _back(backer, 50e6);
        uint256 loanId = _borrow(10e6, 7 days);
        _default(loanId); // the backer paid all 10 units
        usd.setFrozen(address(backer), true);
        address agentWallet = _funded("agentWallet", 100e6);
        uint256 cash = usd.balanceOf(address(lender));

        vm.expectEmit(true, true, true, true);
        emit Recovered(loanId, address(backer), agentWallet, DUE_10_FOR_7_DAYS, 10e6);
        vm.prank(agentWallet);
        assertEq(lender.recover(loanId, 100e6), DUE_10_FOR_7_DAYS); // the backer's 10, then the fee
        _assertLoss(loanId, 10e6, 0, DUE_10_FOR_7_DAYS, 10e6);
        assertEq(usd.balanceOf(address(lender)), cash + DUE_10_FOR_7_DAYS);
        assertEq(lender.dueToBacker(address(backer)), 10e6);

        vm.expectRevert(bytes("frozen")); // the freeze holds up the backer's own payment, nothing else
        lender.payBacker(address(backer));
        usd.setFrozen(address(backer), false);
        vm.expectEmit(true, true, true, true);
        emit BackerPaid(address(backer), 10e6);
        vm.prank(stranger);
        assertEq(lender.payBacker(address(backer)), 10e6);
        assertEq(usd.balanceOf(address(backer)), 100e6);
        assertEq(usd.balanceOf(address(lender)), cash + FEE_10_FOR_7_DAYS);
        assertEq(lender.dueToBacker(address(backer)), 0);
        vm.expectRevert(BackedCreditLine.NothingDue.selector);
        lender.payBacker(address(backer));
    }

    /// @dev What a recovery credits to a backer is the backer's: the lender holds it but does not lend it.
    function test_dueToBacker_isNotLent() public {
        _back(backer, 50e6);
        uint256 loanId = _borrow(10e6, 7 days);
        _default(loanId);
        address agentWallet = _funded("agentWallet", 10e6);
        vm.prank(agentWallet);
        lender.recover(loanId, 10e6); // all of it due to the backer
        uint256 cash = usd.balanceOf(address(lender));
        vm.prank(address(lender));
        usd.transfer(makeAddr("elsewhere"), cash - 15e6); // 15 units left, 10 of them the backer's

        assertEq(lender.availableCredit(AGENT), 5e6);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BackedCreditLine.OverCredit.selector, 5e6));
        lender.borrow(AGENT, 5e6 + 1, 7 days, wallet, type(uint256).max);
        lender.payBacker(address(backer));
        assertEq(lender.availableCredit(AGENT), 5e6);
    }

    /// @dev A backer that pays its shortfall late is repaid from a later recovery as if it had paid at the default.
    function test_payLoss_thenRecover_returnsWhatTheBackerPaidLate() public {
        (RecordingBacker poor, uint256 loanId) = _partlyPaidDefault();
        address manager = _funded("manager", 6e6);
        vm.prank(manager);
        lender.payLoss(loanId, 6e6);
        address agentWallet = _funded("agentWallet", 100e6);
        vm.prank(agentWallet);
        assertEq(lender.recover(loanId, 100e6), DUE_10_FOR_7_DAYS);
        lender.payBacker(address(poor));
        assertEq(usd.balanceOf(address(poor)), 10e6);
        _assertLoss(loanId, 10e6, 0, DUE_10_FOR_7_DAYS, 10e6);
    }

    function test_payLossAndRecover_neverCallTheBacker() public {
        (RecordingBacker poor, uint256 loanId) = _partlyPaidDefault();
        vm.etch(address(poor), hex"60006000fd"); // from now on every call to the backer reverts
        address payer = _funded("payer2", 100e6);
        vm.expectCall(address(poor), bytes(""), 0);
        vm.startPrank(payer);
        lender.payLoss(loanId, 1e6);
        lender.recover(loanId, 100e6);
        lender.payBacker(address(poor));
        vm.stopPrank();
        _assertLoss(loanId, 5e6, 0, DUE_10_FOR_7_DAYS, 5e6);
        assertEq(usd.balanceOf(address(poor)), 5e6);
    }

    /// @dev Any sequence of late payments and recoveries after a default that collected any part of the principal:
    ///      the record matches the money, the backer never gets back more than it paid, nothing is taken beyond the
    ///      principal and the fee, and the fee is reached only once the unpaid part and the backer are covered.
    function testFuzz_afterADefault_everyUnitIsAccountedFor(
        uint8 collected,
        bool[8] calldata late,
        uint32[8] calldata sizes
    ) public {
        uint256 atDefault = bound(collected, 0, 10) * 1e6;
        RecordingBacker b = new RecordingBacker();
        usd.mint(address(b), atDefault);
        b.approve(usd, address(lender), 50e6);
        _back(b, 50e6);
        uint256 loanId = _borrow(10e6, 7 days);
        _default(loanId);
        assertEq(usd.balanceOf(address(b)), 0);
        uint256 cash = usd.balanceOf(address(lender));
        address payer = _funded("payer2", 1_000e6);

        uint256 paidLate;
        uint256 recovered;
        for (uint256 i; i < 8; ++i) {
            uint256 size = bound(sizes[i], 1, 12e6);
            vm.prank(payer);
            if (late[i]) {
                try lender.payLoss(loanId, size) returns (uint256 got) {
                    paidLate += got;
                } catch {}
            } else {
                try lender.recover(loanId, size) returns (uint256 got) {
                    recovered += got;
                } catch {}
            }
        }

        (uint256 p, uint256 u, uint256 r, uint256 t) = lender.lossInfo(loanId);
        assertEq(p, atDefault + paidLate);
        assertEq(r, recovered);
        assertLe(r, DUE_10_FOR_7_DAYS);
        assertLe(t, p);
        assertEq(lender.dueToBacker(address(b)), t); // credited, then paid out
        if (t != 0) lender.payBacker(address(b));
        assertEq(usd.balanceOf(address(b)), t);
        assertEq(usd.balanceOf(address(lender)), cash + paidLate + r - t);
        assertEq(lender.unpaidLoss(address(b)), u);
        // The principal is paid by the backer, still unpaid, or covered by what recoveries kept for the lender.
        uint256 towardUnpaid = 10e6 - p - u;
        assertLe(towardUnpaid + t, r);
        uint256 towardFee = r - t - towardUnpaid;
        assertLe(towardFee, FEE_10_FOR_7_DAYS);
        if (t != 0) assertEq(u, 0); // the backer is paid back only once nothing is unpaid
        if (towardFee != 0) assertEq(t, p); // and the fee only once the backer has all it paid
    }
}
