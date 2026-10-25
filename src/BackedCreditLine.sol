// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IAgentCreditLine} from "./IAgentCreditLine.sol";
import {IBackedCreditLine} from "./IBackedCreditLine.sol";
import {ICreditBacker, RELEASE_LOWERED, RELEASE_REMOVED, RELEASE_REPLACED} from "./ICreditBacker.sol";

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IERC721OwnerOf {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

/// @title BackedCreditLine
/// @notice Reference lender of the Agent Credit Backers draft. It lends only behind a backer: an identity's credit is
///         the line its backer stands behind, less the principal drawn under it, capped by the contract's own balance
///         of the asset. Fees are `feeBps` per 30 days of term, rounded up. On a default it takes the principal from
///         the backer's balance, up to the backer's allowance, before it tells the backer; a backer that leaves part
///         of a loss unpaid gets no new credit here until that part is paid in (`payLoss`, or a recovery). Payments
///         toward a defaulted loan (`recover`) go to that unpaid part first, then back to the backer up to what it
///         paid, then to the fee. The calls to the asset during a default, and `onDefault` and
///         `onRelease`, each get a fixed gas budget and cannot stop the lender. A delegate is bound to the owner who named it. Derived from `SimpleCreditLine`, the reference
///         lender of the Agent Credit Lines draft (CC0).
/// @dev Not audited. A reference for the interface.
contract BackedCreditLine is IBackedCreditLine, IERC165 {
    uint256 private constant BPS = 10_000;
    uint256 private constant FEE_PERIOD = 30 days;
    /// @notice Gas given to each `onDefault` and `onRelease` call: the draft's minimum.
    uint256 public constant HOOK_GAS = 100_000;
    /// @notice Gas given to each call to the asset while a default is charged: the backer's balance and allowance,
    ///         and the transfer. With a token that runs the holder's code during a transfer (as ERC-777 tokens do),
    ///         that code is the backer's, and it gets no more than this.
    uint256 public constant ASSET_GAS = 100_000;
    /// @dev Kept on top of what the 63/64 rule needs, for the call itself (a cold account, the arguments).
    uint256 private constant CALL_OVERHEAD = 5_000;
    /// @dev Half the secp256k1 order: a signature with a higher `s` is the malleable twin of a lower one.
    uint256 private constant HALF_ORDER = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant CONSENT_TYPEHASH = keccak256(
        "BackerConsent(address lender,uint256 agentId,address backer,uint256 line,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant NAME_HASH = keccak256("Agent Credit Backers");
    bytes32 private constant VERSION_HASH = keccak256("1");

    struct Backing {
        address backer;
        uint256 line;
        uint256 outstanding; // principal of the active loans drawn under this backing
    }

    struct Delegation {
        address delegate;
        address namedBy;
    }

    /// @dev A defaulted loan's charge to its backer, and what came in for it after the default.
    struct Loss {
        uint256 paid; // what the backer paid of its charge: at the default, and through payLoss
        uint256 unpaid; // the part of the charge still unpaid
        uint256 recovered; // all that recover took for the loan
        uint256 returned; // the part of `recovered` that went to the backer
    }

    IERC721OwnerOf private immutable _registry;
    IERC20Minimal private immutable _asset;
    uint16 public immutable feeBps;
    uint64 public immutable grace;
    uint64 public immutable maxTerm;

    mapping(uint256 => Backing) private _backings;
    mapping(uint256 => uint256) private _nonces;
    mapping(uint256 => Delegation) private _delegations;
    mapping(uint256 => LoanInfo) private _loans;
    mapping(uint256 => address) private _loanBackers;
    mapping(uint256 => Loss) private _losses;
    /// @notice Principal of defaulted loans a backer was charged and that is still unpaid: the sum of `unpaid` in
    ///         `lossInfo` over its loans. Any amount bars it here.
    mapping(address => uint256) public unpaidLoss;
    uint256 public loanCount;
    bool private _locked;

    event DelegateSet(uint256 indexed agentId, address indexed owner, address delegate);

    error NotOwner();
    error NotController();
    error ZeroAmount();
    error BadTerm();
    error OverCredit(uint256 available);
    error FeeAboveMax(uint256 fee);
    error DueAboveMax(uint256 due);
    error NotActive();
    error NotDefaulted();
    error NothingUnpaid();
    error NothingToRecover();
    error NotDefaultable(uint64 defaultableAt);
    error TransferFailed();
    error BackerRefused();
    error NotBacker();
    error NotACreditBacker();
    error ZeroLine();
    error ConsentExpired(uint256 deadline);
    error BadConsent();
    error LoansOutstanding(uint256 outstanding);
    error LineBelowOutstanding(uint256 outstanding);
    error NoBacker();
    error NotBackerOrOwner();
    error HookStarved();
    error AssetCallStarved();
    error Reentrant();

    modifier lock() {
        if (_locked) revert Reentrant();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(address registry_, address asset_, uint16 feeBps_, uint64 grace_, uint64 maxTerm_) {
        _registry = IERC721OwnerOf(registry_);
        _asset = IERC20Minimal(asset_);
        feeBps = feeBps_;
        grace = grace_;
        maxTerm = maxTerm_;
    }

    // ---------------------------------------------------------------- owner

    /// @notice The agent's owner names a key that may borrow for it. The key lapses while another address holds the
    ///         agent.
    function setDelegate(uint256 agentId, address delegate) external {
        address owner = _registry.ownerOf(agentId);
        if (owner != msg.sender) revert NotOwner();
        _delegations[agentId] = Delegation(delegate, owner);
        emit DelegateSet(agentId, owner, delegate);
    }

    // ---------------------------------------------------------------- views

    function identityRegistry() external view returns (address) {
        return address(_registry);
    }

    function asset() external view returns (address) {
        return address(_asset);
    }

    function isController(uint256 agentId, address account) public view returns (bool) {
        if (account == address(0)) return false;
        address owner = _ownerOf(agentId);
        if (owner == address(0)) return false;
        if (account == owner) return true;
        Delegation memory d = _delegations[agentId];
        return d.delegate == account && d.namedBy == owner;
    }

    /// @notice The backed line's room, capped by the cash on hand; zero without a backer, or under a backer that left
    ///         a loss unpaid. The backer is not asked: a client previews a draw with its `canBorrow`.
    function availableCredit(uint256 agentId) public view returns (uint256) {
        Backing storage b = _backings[agentId];
        if (b.backer == address(0) || unpaidLoss[b.backer] != 0) return 0;
        uint256 room = b.line > b.outstanding ? b.line - b.outstanding : 0;
        uint256 cash = _asset.balanceOf(address(this));
        return room < cash ? room : cash;
    }

    function quote(uint256, uint256 amount, uint64 term) public view returns (uint256) {
        uint256 num = amount * feeBps * term;
        uint256 den = BPS * FEE_PERIOD;
        return (num + den - 1) / den;
    }

    function amountDue(uint256 loanId) external view returns (uint256) {
        LoanInfo storage loan = _loans[loanId];
        if (loan.status != LoanStatus.Active) return 0;
        return loan.principal + loan.fee;
    }

    function loanInfo(uint256 loanId) external view returns (LoanInfo memory) {
        return _loans[loanId];
    }

    function backerOf(uint256 agentId) external view returns (address) {
        return _backings[agentId].backer;
    }

    function backedLine(uint256 agentId) external view returns (uint256 line, uint256 outstanding) {
        Backing storage b = _backings[agentId];
        return (b.line, b.outstanding);
    }

    function backerOfLoan(uint256 loanId) external view returns (address) {
        return _loanBackers[loanId];
    }

    function consentNonce(uint256 agentId) external view returns (uint256) {
        return _nonces[agentId];
    }

    function lossInfo(uint256 loanId)
        external
        view
        returns (uint256 paid, uint256 unpaid, uint256 recovered, uint256 returned)
    {
        Loss storage l = _losses[loanId];
        return (l.paid, l.unpaid, l.recovered, l.returned);
    }

    /// @notice The EIP-712 digest the owner signs to let `backer` stand behind a line of `line` for `agentId`.
    function consentDigest(uint256 agentId, address backer, uint256 line, uint256 nonce, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        bytes32 domain = keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
        bytes32 consent = keccak256(abi.encode(CONSENT_TYPEHASH, address(this), agentId, backer, line, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", domain, consent));
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IBackedCreditLine).interfaceId || interfaceId == type(IAgentCreditLine).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // ---------------------------------------------------------------- backers

    function setBacker(uint256 agentId, address backer, uint256 line, uint256 deadline, bytes calldata ownerConsent)
        external
        lock
    {
        if (msg.sender != backer) revert NotBacker();
        if (!_isCreditBacker(backer)) revert NotACreditBacker();
        if (line == 0) revert ZeroLine();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert ConsentExpired(deadline);
        uint256 nonce = _nonces[agentId];
        bytes32 digest = consentDigest(agentId, backer, line, nonce, deadline);
        if (!_isValidSignature(_registry.ownerOf(agentId), digest, ownerConsent)) revert BadConsent();
        _nonces[agentId] = nonce + 1;

        Backing storage b = _backings[agentId];
        address previous = b.backer;
        uint256 previousLine = b.line;
        // Each loan's loss belongs to the backer that agreed to it, so a backer changes only when nothing is drawn.
        if (previous != backer && b.outstanding != 0) revert LoansOutstanding(b.outstanding);
        if (line < b.outstanding) revert LineBelowOutstanding(b.outstanding);
        b.backer = backer;
        b.line = line;
        emit BackerSet(agentId, backer, line);

        if (previous == backer) {
            if (line < previousLine) _release(agentId, backer, previousLine - line, RELEASE_LOWERED);
        } else if (previous != address(0)) {
            _release(agentId, previous, previousLine, RELEASE_REPLACED);
        }
    }

    function removeBacker(uint256 agentId) external lock {
        Backing memory b = _backings[agentId];
        if (b.backer == address(0)) revert NoBacker();
        if (msg.sender != b.backer && msg.sender != _ownerOf(agentId)) revert NotBackerOrOwner();
        if (b.outstanding != 0) revert LoansOutstanding(b.outstanding);
        delete _backings[agentId];
        emit BackerSet(agentId, address(0), 0);
        _release(agentId, b.backer, b.line, RELEASE_REMOVED);
    }

    // ---------------------------------------------------------------- loans

    function borrow(uint256 agentId, uint256 amount, uint64 term, address to, uint256 maxFee)
        external
        lock
        returns (uint256 loanId)
    {
        if (!isController(agentId, msg.sender)) revert NotController();
        if (amount == 0) revert ZeroAmount();
        if (term == 0 || term > maxTerm) revert BadTerm();
        uint256 available = availableCredit(agentId);
        if (amount > available) revert OverCredit(available);
        uint256 fee = quote(agentId, amount, term);
        if (fee > maxFee) revert FeeAboveMax(fee);

        address backer = _backings[agentId].backer; // set: without a backer there is no credit
        address owner = _registry.ownerOf(agentId);
        _askBacker(backer, agentId, amount, term, fee, owner, to);
        loanId = _open(agentId, backer, owner, amount, fee, term, to);
        if (!_asset.transfer(to, amount)) revert TransferFailed();
        // A backer can stop money leaving: if it does not take note of the draw, there is no draw.
        ICreditBacker(backer).onBorrow(address(this), agentId, loanId);
    }

    /// @notice Anyone. The backer is not called: it cannot stop a repayment.
    function repay(uint256 loanId, uint256 maxDue) external lock returns (uint256 paid) {
        LoanInfo storage loan = _loans[loanId];
        if (loan.status != LoanStatus.Active) revert NotActive();
        paid = loan.principal + loan.fee;
        if (paid > maxDue) revert DueAboveMax(paid);

        loan.status = LoanStatus.Repaid;
        _backings[loan.agentId].outstanding -= loan.principal;

        emit Repaid(loanId, loan.agentId, msg.sender, loan.principal, loan.fee);
        if (!_asset.transferFrom(msg.sender, address(this), paid)) revert TransferFailed();
    }

    /// @notice Anyone, once the loan's `defaultableAt` has passed. The backer is charged the principal, which is taken
    ///         from its balance up to its allowance before it is told; nothing it does can stop the default.
    function markDefault(uint256 loanId) external lock {
        LoanInfo storage loan = _loans[loanId];
        if (loan.status != LoanStatus.Active) revert NotActive();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < loan.defaultableAt) revert NotDefaultable(loan.defaultableAt);

        loan.status = LoanStatus.Defaulted;
        uint256 agentId = loan.agentId;
        uint256 principal = loan.principal;
        emit Defaulted(loanId, agentId, loan.owner, principal);

        // Every loan here is drawn under a backer, and that backer is still the identity's: it cannot change while
        // the loan is active.
        address backer = _loanBackers[loanId];
        Backing storage b = _backings[agentId];
        b.outstanding -= principal;
        b.line -= principal; // the cover this loan used is spent
        uint256 paid = _take(backer, principal);
        _losses[loanId] = Loss({paid: paid, unpaid: principal - paid, recovered: 0, returned: 0});
        if (paid < principal) unpaidLoss[backer] += principal - paid;
        emit BackerCharged(loanId, agentId, backer, principal, paid);
        _notify(
            agentId,
            backer,
            ICreditBacker.onDefault.selector,
            abi.encodeCall(ICreditBacker.onDefault, (address(this), agentId, loanId, principal, paid))
        );
    }

    // ---------------------------------------------------------------- after a default

    /// @notice Anyone: the backer, or anyone for it. Pays up to `amount` of the part of the backer's charge for a
    ///         defaulted loan that it left unpaid, as the backer's own payment, so a later recovery can return it to
    ///         the backer. The backer is not called.
    function payLoss(uint256 loanId, uint256 amount) external lock returns (uint256 taken) {
        if (_loans[loanId].status != LoanStatus.Defaulted) revert NotDefaulted();
        Loss storage l = _losses[loanId];
        taken = amount < l.unpaid ? amount : l.unpaid;
        if (taken == 0) revert NothingUnpaid();
        address backer = _loanBackers[loanId];
        l.paid += taken;
        l.unpaid -= taken;
        unpaidLoss[backer] -= taken;
        emit LossPaid(loanId, backer, msg.sender, taken);
        if (!_asset.transferFrom(msg.sender, address(this), taken)) revert TransferFailed();
    }

    /// @notice Anyone: the agent, its owner, a collector. Pays up to `amount` toward a defaulted loan, up to its
    ///         principal and fee in all. It goes first to the part of the backer's charge left unpaid, which the
    ///         lender keeps; then to the backer, up to what the backer paid and has not had back; then to the fee,
    ///         which the lender keeps. The backer is not called; its part is transferred to it.
    function recover(uint256 loanId, uint256 amount) external lock returns (uint256 taken) {
        LoanInfo storage loan = _loans[loanId];
        if (loan.status != LoanStatus.Defaulted) revert NotDefaulted();
        Loss storage l = _losses[loanId];
        uint256 left = loan.principal + loan.fee - l.recovered;
        taken = amount < left ? amount : left;
        if (taken == 0) revert NothingToRecover();

        address backer = _loanBackers[loanId];
        uint256 toUnpaid = taken < l.unpaid ? taken : l.unpaid;
        uint256 rest = taken - toUnpaid;
        uint256 owedToBacker = l.paid - l.returned;
        uint256 toBacker = rest < owedToBacker ? rest : owedToBacker;
        // What is left of `rest` is the fee's: `left` caps `taken` at the unpaid part, the backer's due and the fee
        // not yet recovered.
        l.unpaid -= toUnpaid;
        unpaidLoss[backer] -= toUnpaid;
        l.recovered += taken;
        l.returned += toBacker;
        emit Recovered(loanId, backer, msg.sender, taken, toBacker);
        if (!_asset.transferFrom(msg.sender, address(this), taken)) revert TransferFailed();
        if (toBacker != 0 && !_asset.transfer(backer, toBacker)) revert TransferFailed();
    }

    // ---------------------------------------------------------------- internals

    /// @dev A `false`, a revert or a malformed answer all revert the draw.
    function _askBacker(
        address backer,
        uint256 agentId,
        uint256 amount,
        uint64 term,
        uint256 fee,
        address owner,
        address to
    ) private view {
        if (!ICreditBacker(backer).canBorrow(address(this), agentId, amount, term, fee, msg.sender, owner, to)) {
            revert BackerRefused();
        }
    }

    function _open(uint256 agentId, address backer, address owner, uint256 amount, uint256 fee, uint64 term, address to)
        private
        returns (uint256 loanId)
    {
        loanId = ++loanCount;
        uint64 dueAt = uint64(block.timestamp) + term;
        _loans[loanId] = LoanInfo({
            agentId: agentId,
            owner: owner,
            principal: amount,
            fee: fee,
            issuedAt: uint64(block.timestamp),
            dueAt: dueAt,
            defaultableAt: dueAt + grace,
            status: LoanStatus.Active
        });
        _loanBackers[loanId] = backer;
        _backings[agentId].outstanding += amount;
        emit Borrowed(loanId, agentId, to, amount, fee, dueAt);
    }

    /// @dev Takes up to `principal` of the asset from `backer`: the least of the principal, its balance and its
    ///      allowance. Returns what was taken, zero when the transfer fails. Whatever the asset does in these calls,
    ///      this never reverts, except when the caller left too little gas to give a call its full budget.
    function _take(address backer, uint256 principal) private returns (uint256 amount) {
        amount = principal;
        uint256 balance = _readAsset(abi.encodeCall(IERC20Minimal.balanceOf, (backer)));
        if (balance < amount) amount = balance;
        uint256 allowed = _readAsset(abi.encodeCall(IERC20Minimal.allowance, (backer, address(this))));
        if (allowed < amount) amount = allowed;
        if (amount == 0) return 0;
        (bool ok, uint256 size, uint256 word) =
            _callAsset(abi.encodeCall(IERC20Minimal.transferFrom, (backer, address(this), amount)), false);
        // Paid only on a clean `true`, or on no data at all for tokens that return nothing.
        if (!ok || !(size == 0 || (size == 32 && word == 1))) return 0;
    }

    /// @dev A read that fails, or does not return exactly one word, counts as zero.
    function _readAsset(bytes memory data) private returns (uint256) {
        (bool ok, uint256 size, uint256 word) = _callAsset(data, true);
        return ok && size == 32 ? word : 0;
    }

    /// @dev Calls the asset with exactly ASSET_GAS and copies back at most the first 32 bytes of what it returns,
    ///      so neither the gas it burns nor the size of what it returns can reach the rest of the default.
    function _callAsset(bytes memory data, bool readOnly) private returns (bool ok, uint256 size, uint256 word) {
        if (gasleft() < ASSET_GAS * 64 / 63 + CALL_OVERHEAD) revert AssetCallStarved();
        address token = address(_asset);
        uint256 budget = ASSET_GAS;
        assembly ("memory-safe") {
            switch readOnly
            case 0 { ok := call(budget, token, 0, add(data, 0x20), mload(data), 0, 0x20) }
            default { ok := staticcall(budget, token, add(data, 0x20), mload(data), 0, 0x20) }
            size := returndatasize()
            word := mload(0) // scratch space; meaningful only when size is 32
        }
    }

    function _release(uint256 agentId, address backer, uint256 amount, uint8 reason) private {
        _notify(
            agentId,
            backer,
            ICreditBacker.onRelease.selector,
            abi.encodeCall(ICreditBacker.onRelease, (address(this), agentId, amount, reason))
        );
    }

    /// @dev A notification: the backer gets exactly HOOK_GAS, its return data is never copied, and its failure is
    ///      logged, never propagated. A caller that leaves too little gas for the budget makes the whole call revert,
    ///      so it cannot make the notification fail on purpose while the action goes through.
    function _notify(uint256 agentId, address backer, bytes4 selector, bytes memory data) private {
        if (gasleft() < HOOK_GAS * 64 / 63 + CALL_OVERHEAD) revert HookStarved();
        bool ok;
        uint256 budget = HOOK_GAS;
        assembly ("memory-safe") {
            ok := call(budget, backer, 0, add(data, 0x20), mload(data), 0, 0)
        }
        if (!ok) emit BackerHookFailed(agentId, backer, selector);
    }

    function _isCreditBacker(address backer) private view returns (bool) {
        if (backer.code.length == 0) return false;
        try IERC165(backer).supportsInterface(type(ICreditBacker).interfaceId) returns (bool yes) {
            return yes;
        } catch {
            return false;
        }
    }

    /// @dev An ECDSA signature by `signer` with a low `s`, or, for a contract, its ERC-1271 approval.
    function _isValidSignature(address signer, bytes32 digest, bytes calldata signature) private view returns (bool) {
        if (signature.length == 65) {
            bytes32 r = bytes32(signature[0:32]);
            bytes32 s = bytes32(signature[32:64]);
            uint8 v = uint8(signature[64]);
            if (uint256(s) <= HALF_ORDER && (v == 27 || v == 28)) {
                address recovered = ecrecover(digest, v, r, s);
                if (recovered != address(0) && recovered == signer) return true;
            }
        }
        if (signer.code.length == 0) return false;
        (bool ok, bytes memory ret) = signer.staticcall(abi.encodeCall(IERC1271.isValidSignature, (digest, signature)));
        return ok && ret.length >= 32 && abi.decode(ret, (bytes32)) == bytes32(IERC1271.isValidSignature.selector);
    }

    function _ownerOf(uint256 agentId) private view returns (address) {
        try _registry.ownerOf(agentId) returns (address o) {
            return o;
        } catch {
            return address(0);
        }
    }
}
