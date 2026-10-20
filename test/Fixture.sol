// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BackedCreditLine} from "../src/BackedCreditLine.sol";
import {MockRegistry, MockToken, BackerBase} from "./mocks/Mocks.sol";

/// @notice What every test starts from: one identity with an owner key, a lender of 1% per 30 days with a 3-day grace
///         period and 1,000 units of cash, and helpers that sign consents the way the draft describes them.
abstract contract Fixture is Test {
    // The EIP-712 domain and type, written out from the draft's text rather than read from the lender.
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant CONSENT_TYPEHASH = keccak256(
        "BackerConsent(address lender,uint256 agentId,address backer,uint256 line,uint256 nonce,uint256 deadline)"
    );

    uint256 internal constant AGENT = 6197;
    uint16 internal constant FEE_BPS = 100; // 1% per 30 days
    uint64 internal constant GRACE = 3 days;
    uint64 internal constant MAX_TERM = 30 days;

    MockRegistry internal registry;
    MockToken internal usd;
    BackedCreditLine internal lender;
    address internal owner;
    uint256 internal ownerKey;
    address internal wallet = makeAddr("wallet");
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual {
        registry = new MockRegistry();
        usd = new MockToken();
        lender = new BackedCreditLine(address(registry), address(usd), FEE_BPS, GRACE, MAX_TERM);
        (owner, ownerKey) = makeAddrAndKey("owner");
        registry.mint(owner, AGENT);
        usd.mint(address(lender), 1_000e6);
    }

    function _digest(address lender_, uint256 agentId, address backer, uint256 line, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 domain = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256(bytes("Agent Credit Backers")), keccak256(bytes("1")), block.chainid, lender_
            )
        );
        bytes32 consent = keccak256(abi.encode(CONSENT_TYPEHASH, lender_, agentId, backer, line, nonce, deadline));
        return keccak256(abi.encodePacked(hex"1901", domain, consent));
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev The owner's consent for `backer` behind a line of `line` for AGENT at `lender`, at the current nonce.
    function _consent(address backer, uint256 line) internal view returns (bytes memory) {
        return _sign(ownerKey, _digest(address(lender), AGENT, backer, line, lender.consentNonce(AGENT), _deadline()));
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 1 hours;
    }

    /// @dev `backer` puts itself behind a line of `line` for AGENT, with the owner's consent.
    function _back(BackerBase backer, uint256 line) internal {
        backer.setBackerAt(lender, AGENT, line, _deadline(), _consent(address(backer), line));
    }

    function _borrow(uint256 amount, uint64 term) internal returns (uint256) {
        vm.prank(owner);
        return lender.borrow(AGENT, amount, term, wallet, type(uint256).max);
    }

    function _repay(uint256 loanId) internal {
        address payer = makeAddr("payer");
        uint256 due = lender.amountDue(loanId);
        usd.mint(payer, due);
        vm.startPrank(payer);
        usd.approve(address(lender), due);
        lender.repay(loanId, due);
        vm.stopPrank();
    }

    function _default(uint256 loanId) internal {
        vm.warp(lender.loanInfo(loanId).defaultableAt);
        lender.markDefault(loanId);
    }
}
