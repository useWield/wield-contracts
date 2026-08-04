# Security Policy

Wield manages real user funds on Robinhood Chain mainnet (chain ID `4663`). We take
security reports seriously and will work with you in good faith.

## Reporting a vulnerability

**Do not open a public GitHub issue for security problems.**

Report privately through one of these channels:

- GitHub private vulnerability reporting: use the **Security** tab of this repository
  and click *Report a vulnerability*.
- Email: `security@usewield.io`
- X / Twitter DM: [@wield_](https://x.com/wield_)

Please include:

1. A description of the vulnerability and its impact.
2. Steps to reproduce, ideally a Foundry test or script.
3. The affected contract address or file path and commit hash.
4. Any suggested mitigation.

## Response targets

| Stage | Target |
|---|---|
| Acknowledgement | 48 hours |
| Initial assessment | 5 business days |
| Fix or mitigation plan | 14 days for critical, 30 days for others |

We will keep you informed throughout and credit you in the release notes unless you
prefer to stay anonymous.

## Scope

In scope:

- Solidity contracts in `wield-contracts` (`Vault.sol`, `BlendManager.sol`, `P2PDesk.sol`)
- Deployed contracts listed in the deployments documentation
- SDK and CLI code that constructs or signs transactions

Out of scope:

- Issues in third-party dependencies without a demonstrated exploit path in Wield
- Denial of service caused solely by public RPC rate limits
- Findings that require a compromised user private key or a malicious wallet extension
- Front-end styling and non-security UX bugs

## Known accepted risks

These are documented rather than hidden. They are tracked and may be addressed in
future releases:

- Basket vaults were deployed without an initial seed deposit. First-depositor share
  inflation is mitigated by OpenZeppelin v5 ERC-4626 virtual shares and decimals offset.
- `BlendManager` does not yet have the same reentrancy and lifecycle test coverage as
  `P2PDesk`.
- Vault rebalancing is executed by a permissioned keeper address. Users trust that
  keeper for rebalance timing, not for custody: withdrawals are always user-initiated.

## Safe harbour

We will not pursue legal action against researchers who:

- Make a good faith effort to avoid privacy violations, data destruction, and service
  interruption.
- Only interact with accounts they own or have explicit permission to test.
- Report promptly and give us reasonable time to remediate before public disclosure.
