# ERC-8467: Agent Credit Backers (draft)

A standard way for a third party (a staker, a collateral vault, an insurer) to stand behind a lender's credit line to
an agent identity and absorb its loss. With the identity owner's signed consent, the backer puts itself behind a line
of a given size. The lender asks it before each draw (`canBorrow`), tells it of each draw (`onBorrow`), takes the
principal of each defaulted loan from its balance and tells it (`onDefault`), and tells it when part of the line is no
longer its concern (`onRelease`). A backer can refuse a draw; it cannot stop a repayment, a default or the end of its
backing. After a default, a part of the loss the backer left unpaid can be paid in later (`payLoss`), money paid toward
the defaulted loan (`recover`) goes to that part, then back to the backer (credited to it, and paid out by `payBacker`,
which anyone may call), then to the fee, and `lossInfo` keeps the figures per loan.

It extends the Agent Credit Lines draft. Identities are token ids of an ERC-721 identity registry, such as the Identity
Registry of ERC-8004 (Trustless Agents).

**Status: draft, submitted as [ethereum/ERCs#2111](https://github.com/ethereum/ERCs/pull/2111).** The text is in
[`ERCS/erc-8467.md`](ERCS/erc-8467.md). The editors assigned it ERC-8467 on 2026-10-27. ERC-8210 (Agent Assurance, an open pull request:
https://github.com/ethereum/ERCs/pull/1632) leaves third-party "Backers" and a `depositFor` call to "a separate ERC" in
its "Delegated Funding (Reserved)" section. This proposal was raised on ERC-8210's discussion thread first ([post
50](https://ethereum-magicians.org/t/erc-8210-agent-assurance/28097/50)), so that the agent ERC family ends up with one
backer ERC, not two, and is discussed on its own thread since 2026-10-23:
https://ethereum-magicians.org/t/erc-8467-agent-credit-backers/30062. If ERC-8210's authors would rather fold it into
their reserved section, it can be.

## Why

Lenders to ERC-8004 agents already let third parties stand behind lines. Priors has several kinds of backer behind one
pool (seat vaults where stakers back lines, a collateral vault, a treasury that backs first lines), all through one
hook of its own; on Nenrin, backers stake, offer lines and lose principal when a loan is marked defaulted. Each hook
belongs to one lender, so a backer cannot stand behind the same agent at another lender, and a lender cannot accept a
backer written for someone else. This fixes the four calls, how the loss is taken from the backer, and how the owner
consents, and it makes sure a backer can never block a repayment or a default.

## What is here

| Path | What |
|---|---|
| `ERCS/erc-8467.md` | The ERC text, in the ethereum/ERCs template |
| `src/ICreditBacker.sol` | The backer interface, and the release reasons |
| `src/IBackedCreditLine.sol` | The lender interface |
| `src/IAgentCreditLine.sol` | The Agent Credit Lines interface it extends, copied unchanged |
| `src/BackedCreditLine.sol` | A reference lender that lends only behind a backer, derived from the Agent Credit Lines reference lender (not audited) |
| `src/StakeBacker.sol` | A reference backer that pays a defaulted principal from its stake (not audited) |
| `test/BackedCreditLine.t.sol` | Foundry tests of the lender: consent, draws, repayments, defaults, late payments of a loss and recoveries after a default, releases, every gas amount for a default, backers that revert, burn their gas, return huge payloads or call back into the lender, and tokens that misbehave the same ways while a loss is taken |
| `test/StakeBacker.t.sol` | Foundry tests of the reference backer |
| `test/Fixture.sol`, `test/mocks/Mocks.sol` | Shared setup, an identity registry, a token and test backers |
| `scripts/lint-erc.sh` | Lints the ERC text with eipw the way the ethereum/ERCs CI does |
| `eipw.toml` | The ethereum/ERCs repository's eipw configuration, copied as is |

## Checks

```bash
forge build
forge test
scripts/lint-erc.sh   # needs eipw: cargo install eipw --version 0.11.0 --locked
```

CI runs all three on every push (`.github/workflows/ci.yml`).

## Related drafts

- Agent Credit Lines: one interface to borrow, repay and default against any lender to agent identities
  (github.com/priors-agents/erc-agent-credit-lines). This proposal extends its interface.
- Agent Default Registry: lender-reported defaults any contract can check
  (github.com/priors-agents/erc-agent-default-registry). A default charged to a backer here is the same default a lender
  records there.
- Credit history for ERC-8004 agents: a profile of the ERC-8004 Reputation Registry for loan outcomes
  (`docs/ERC-8004-CREDIT.md` in github.com/priors-agents/priors). Its loan class (`unsecured`, `secured:<kind>`) is the
  lender's own claim today; with a backer on record (`backerOfLoan`), a reader can check it.

## Licence

CC0 1.0 ([LICENSE.md](LICENSE.md)), as the ERC process requires.
