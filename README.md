# AgentHelm Contracts

Smart contracts for [AgentHelm](https://github.com/Agent-Helm) — a route-aware
"dust" converter that sweeps low-value ERC-20 balances into ETH on Base.

## DustExecutor

`src/DustExecutor.sol` settles a batch of token → ETH swaps in a single call.
The off-chain backend scans balances, checks token tax/security, quotes routes,
and simulates each swap; the contract only executes routes it has been told are
sellable and pays out the net ETH (minus a capped protocol fee) to the user.

Supported routes:

- **V2 fee-on-transfer** — `swapExactTokensForETHSupportingFeeOnTransferTokens`
- **V3 exact-input-single** — direct `exactInputSingle`
- **Universal Router** — allow-listed router with backend-generated calldata

Two entry points:

- `convertDust(...)` — user has approved the contract directly
- `convertDustPermit2(...)` — a single Permit2 batch signature

Safety properties:

- `Ownable` + `ReentrancyGuard`
- Only allow-listed routers can be called (`setRouter`)
- Protocol fee is capped at `MAX_FEE_BPS` (3%)
- Approvals are cleared and leftover token deltas returned after every swap
- `rescueToken` / `rescueETH` for stuck funds

> ⚠️ This contract is **not audited**. Do not allow-list arbitrary routers.

## Layout

```
src/DustExecutor.sol                  core contract
script/DeployDustExecutor.s.sol       Base deployment + router allow-listing
test/DustExecutor.t.sol               unit tests
foundry.toml                          Foundry config (Base / Base Sepolia)
```

## Setup

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
forge install
forge build
forge test
```

## Deploy to Base

```bash
cp .env.example .env   # fill in PRIVATE_KEY, BASE_RPC_URL, BASESCAN_API_KEY

forge script script/DeployDustExecutor.s.sol:DeployDustExecutor \
  --rpc-url base \
  --broadcast \
  --verify
```

The script deploys `DustExecutor` with the Base canonical WETH and Permit2
addresses, then allow-lists the Uniswap SwapRouter02 and Universal Router.

### Base canonical addresses

| Contract        | Address                                      |
| --------------- | -------------------------------------------- |
| WETH            | `0x4200000000000000000000000000000000000006` |
| Permit2         | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| SwapRouter02    | `0x2626664c2603336E57B271c5C0b26F421741e481` |
| Universal Router| `0x6fF5693b99212Da76ad316178A184AB56D299b43` |
