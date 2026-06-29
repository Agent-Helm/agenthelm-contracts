# AgentHelm Contracts

Smart contracts for [AgentHelm](https://github.com/Agent-Helm) — a route-aware
"dust" converter that sweeps low-value ERC-20 balances into ETH (or HELM) on Base.

## DustExecutor

`src/DustExecutor.sol` settles a batch of token swaps in a single call. The
off-chain backend scans balances, checks token tax/security, quotes routes, and
simulates each swap; the contract only executes routes it has been told are
sellable and pays out the net proceeds (minus a capped protocol fee) to the user.

### Routes

- **V2 fee-on-transfer** — `swapExactTokensForETHSupportingFeeOnTransferTokens`
- **V3 exact-input-single** — direct `exactInputSingle`
- **V4 exact-input-single** — native Uniswap V4 route for Clanker tokens, whose
  calldata is built on-chain from the pool params (fee, tickSpacing, hooks) so
  slippage is enforced authoritatively
- **Universal Router** — allow-listed router with backend-generated calldata

### Output modes

Each `convertDust` call takes an `OutputMode`:

- **`ETH`** — user receives ETH. Fee is `ethFeeBps` (default **10%**), of which
  `ethBurnBps` (default **3%**) is accrued for HELM buyback-and-burn and the rest
  goes to `ownerWallet` in ETH.
- **`HELM`** — user receives HELM. Fee is `helmFeeBps` (default **5%**, paid to
  `ownerWallet` in ETH); the remaining proceeds are swapped ETH → HELM through the
  configured Uniswap V4 (Clanker) route and delivered to the user.

### Entry points

- `convertDust(swaps, deadline, mode, minHelmOut)` — user approved the contract directly
- `convertDustPermit2(swaps, deadline, mode, minHelmOut, permit, signature)` — a single Permit2 batch signature

### Safety properties

- `Ownable` + `ReentrancyGuard`
- Only allow-listed routers can be called (`setRouter`)
- Protocol fees are capped at `MAX_FEE_BPS` (**10%**), and `ethBurnBps` can never
  exceed `ethFeeBps` (enforced in `setFees`)
- Approvals are cleared and leftover token deltas returned after every swap
- `rescueToken` / `rescueETH` for stuck funds

### Owner configuration

- `setOwnerWallet(wallet)` — fee recipient (fees are always paid in ETH)
- `setFees(ethFeeBps, ethBurnBps, helmFeeBps)` — fee schedule
- `setRouter(router, allowed)` — allow-list a swap router
- `setHelmConfig(token, router, fee, tickSpacing, hooks)` — the ETH → HELM V4 buy
  route; set once HELM is live on Clanker

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
addresses, then allow-lists the Uniswap SwapRouter02 and Universal Router. The
ETH → HELM buy route is configured separately via `setHelmConfig` once HELM is
live on Clanker.

### Base canonical addresses

| Contract         | Address                                      |
| ---------------- | -------------------------------------------- |
| WETH             | `0x4200000000000000000000000000000000000006` |
| Permit2          | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| SwapRouter02     | `0x2626664c2603336E57B271c5C0b26F421741e481` |
| Universal Router | `0x6fF5693b99212Da76ad316178A184AB56D299b43` |
