# Contributing to Wield

Thanks for taking the time to contribute.

## Before you start

- For anything non-trivial, open an issue first so we can agree on the approach.
- For security problems, **do not** open an issue. Follow [SECURITY.md](./SECURITY.md).

## Development setup

Each repository documents its own setup in its `README.md`. In short:

| Repository | Toolchain | Test command |
|---|---|---|
| `wield-contracts` | Foundry | `forge test` |
| `wield-sdk` | Bun | `bun test` |
| `wield-cli` | Bun | `bun test` |
| `wield-landing` | Node 20+ / npm | `npm run build` |

## Pull request checklist

1. **Tests pass.** Run the repository's test command and paste the output in the PR
   description. PRs without evidence of a passing test run will be asked for it.
2. **No secrets.** Never commit a `.env`, private key, API key, RPC credential, or
   server address. Only `.env.example` files with placeholder values belong in git.
3. **Scope is minimal.** One logical change per PR. Do not mix a bug fix with a
   refactor or a formatting sweep.
4. **Match existing style.** Follow the conventions already present in the files you
   touch rather than introducing a new pattern.
5. **Contracts changes need tests.** Any change under `src/*.sol` must come with a
   Foundry test that fails before the change and passes after it.

## Commit messages

Use short, imperative subjects:

```
fix(vault): drop uiMultiplier from stock valuation
feat(sdk): add basket position helpers
docs: document blend exit flow
```

## Solidity conventions

- Solidity `0.8.24`, Foundry, OpenZeppelin v5, Solady.
- `forge fmt --check` must pass. CI enforces this.
- Follow checks-effects-interactions. State updates precede external calls.
- Guard every externally reachable value-moving function with `nonReentrant` unless
  you can justify in the PR why it is unnecessary.
- Prefer explicit reverts with custom errors over `require` strings.

## TypeScript conventions

- Strict TypeScript. No `any`, no `@ts-ignore`, no `@ts-expect-error`.
- `bun run typecheck` (or `tsc --noEmit`) must be clean.
- Prefer `viem` primitives over hand-rolled ABI encoding.

## Licence

By contributing you agree that your contributions are licensed under the MIT
Licence found in [LICENSE](./LICENSE).
