# Wield Contracts

Solidity contracts for **Wield** — an agent-managed vault protocol for tokenized real-world assets and tokenized equities on **Robinhood Chain**.

USDG in, `WIELD` shares out. An off-chain agent proposes allocations; the vault enforces caps, slippage, and oracle freshness on-chain.

- Website: https://usewield.io
- dApp: https://app.usewield.io
- Explorer: https://robinhoodchain.blockscout.com

## Network

| Field | Value |
|---|---|
| Chain | Robinhood Chain Mainnet |
| Chain ID | `4663` |
| RPC | `https://rpc.mainnet.chain.robinhood.com` |
| Explorer | https://robinhoodchain.blockscout.com |
| Settlement asset | USDG (Paxos) `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |

## Deployed addresses

### Flagship vault

| Contract | Address |
|---|---|
| Wield RWA Vault (ERC-4626) | `0x7769526f55cd6B0B8a9E0Bf9e124618A0fe084de` |

### Baskets

| Contract | Address | Composition |
|---|---|---|
| BlendManager | `0x4bc86AC09EeC8dd21557944b21891e08F1295b42` | — |
| Big Tech basket | `0xfcb4B482C89839e8c19696E3e78223B8985ED923` | AAPL 60% / GOOGL 40% |
| Frontier basket | `0xb345dafdED457A2544B6ECcF462A41Ea77168eF3` | SPCX 50% / USO 50% |
| Core 4 basket | `0x66bc68ed37f0dC1b53bb1838beb204b3B42D55B9` | AAPL / GOOGL / SPCX / USO 25% each |

### Tokenized equities and price feeds

| Symbol | Token | Chainlink feed (8 decimals) |
|---|---|---|
| AAPL | `0xaf3d76f1834a1d425780943c99ea8a608f8a93f9` | `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0` |
| GOOGL | `0x2e0847e8910a9732eb3fb1bb4b70a580adad4fe3` | `0xF6f373a037c30F0e5010d854385cA89185AE638b` |
| USO | `0xa30fa36db767ad9ed3f7a60fc79526fb4d56d344` | `0x75a9c76Ef439e2C7c2E5a34Ab105EcFe3766431c` |
| SPCX | `0x4a0e65a3eccec6dbe60ae065f2e7bb85fae35eea` | `0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb` |
| HOOD | `0x79D2234Ed4Ee24880835F261DF9A98FcEfC7600e` | no published feed |

> **Multiplier caution.** Robinhood tokenized-equity feeds already return `underlying market price × multiplier`. Integrators must **not** apply the multiplier again. See the [Chainlink docs](https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood).

DEX router (Uniswap V3 SwapRouter02): `0xCaf681a66D020601342297493863E78C959E5cb2`, pool fee `3000`.

## Contracts

| File | Purpose |
|---|---|
| `src/Vault.sol` | ERC-4626 vault. Holds USDG plus yield-bearing (ERC-4626) and stock (ERC-20 + Chainlink feed) underlyings. Agent-signed rebalance intents, concentration caps, slippage cap, oracle staleness guard, pause, emergency withdraw. |
| `src/BlendManager.sol` | Lets a user split one USDG deposit across up to 4 basket vaults and receive a single ERC-721 position NFT. Buy-and-hold; `exit()` redeems every leg back to USDG. |
| `src/P2PDesk.sol` | EIP-712 off-chain order book for peer-to-peer swaps of supported assets. |
| `src/MockUSDG.sol` | 6-decimal mock settlement token for local tests only. |

### Vault safety model

- **Agent authority is bounded.** The agent signs an `Intent` (nonce, deadline, allocations) hashed with chain ID and vault address. The vault verifies the signature against the registered agent identity — it never lets the agent move funds to arbitrary destinations.
- **Concentration caps** are enforced on-chain at rebalance time.
- **Oracle freshness**: `oracleStaleAfter` (deployed at 172800 s / 48 h, because tokenized-equity feeds update on price movement during market hours only).
- **Slippage**: `maxSlippageBps` (deployed at 100 = 1%).
- **Pause** blocks new deposits; withdrawals always work.

## Quickstart

Requires [Foundry](https://book.getfoundry.sh).

```bash
git clone https://github.com/useWield/wield-contracts
cd wield-contracts
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts Vectorized/solady
forge build
forge test -vvv
```

`lib/` is not committed. `forge install` fetches `forge-std`, `openzeppelin-contracts`, and `solady`.

## Deploy

```bash
cp .env.example .env    # fill DEPLOYER_PRIVATE_KEY, KEEPER_ADDRESS, addresses
set -a; . ./.env; set +a

# simulate first
forge script script/DeployBaskets.s.sol:DeployBaskets \
  --rpc-url "$RPC_URL" --legacy

# broadcast
forge script script/DeployBaskets.s.sol:DeployBaskets \
  --rpc-url "$RPC_URL" --broadcast --legacy \
  --with-gas-price 2000000000 --slow
```

| Script | Deploys |
|---|---|
| `script/Deploy.s.sol` | A single `Vault` |
| `script/DeployAll.s.sol` | Vault plus mock underlyings (local / test) |
| `script/DeployBaskets.s.sol` | 3 basket vaults plus `BlendManager` |
| `script/DeployP2P.s.sol` | `P2PDesk` |

`DeployBaskets.s.sol` refuses to run unless `block.chainid == EXPECTED_CHAIN_ID` (default `4663`) and every required address is non-zero.

> Robinhood Chain expects legacy-style pricing. Use `--legacy --with-gas-price 2000000000`.

## Tests

```bash
forge test -vvv        # full suite
forge fmt --check      # formatting gate used in CI
forge build --sizes    # contract size report
```

CI (`.github/workflows/test.yml`) runs `forge fmt --check`, `forge build --sizes`, and `forge test -vvv` on every push and PR.

## Audit status

**Not formally audited.** These contracts are live on mainnet and used in production by Wield, but no third-party audit has been completed. Read [SECURITY.md](SECURITY.md) for the known accepted risks before integrating or forking.

## License

MIT — see [LICENSE](LICENSE).
