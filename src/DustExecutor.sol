// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transfer, (to, value)));
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transferFrom, (from, to, value)));
    }

    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        bytes memory approvalCall = abi.encodeCall(token.approve, (spender, value));
        if (!_callOptionalReturnBool(token, approvalCall)) {
            _callOptionalReturn(token, abi.encodeCall(token.approve, (spender, 0)));
            _callOptionalReturn(token, approvalCall);
        }
    }

    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        (bool success, bytes memory returndata) = address(token).call(data);
        require(success, "SafeERC20: call failed");
        if (returndata.length > 0) {
            require(abi.decode(returndata, (bool)), "SafeERC20: operation failed");
        }
    }

    function _callOptionalReturnBool(IERC20 token, bytes memory data) private returns (bool) {
        (bool success, bytes memory returndata) = address(token).call(data);
        return success && (returndata.length == 0 || abi.decode(returndata, (bool)));
    }
}

abstract contract ReentrancyGuard {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private _status;

    constructor() {
        _status = NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != ENTERED, "ReentrancyGuard: reentrant call");
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }
}

abstract contract Ownable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address initialOwner) {
        require(initialOwner != address(0), "Ownable: owner zero");
        _transferOwnership(initialOwner);
    }

    modifier onlyOwner() {
        require(owner() == msg.sender, "Ownable: caller is not owner");
        _;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Ownable: new owner zero");
        _transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV2Router02 {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

// Uniswap V3 SwapRouter02 (e.g. Base 0x2626664c2603336E57B271c5C0b26F421741e481).
// SwapRouter02's exactInputSingle has NO `deadline` field (selector 0x04e45aaf),
// unlike the legacy SwapRouter (0x414bf389). The executor enforces its own
// deadline in convertDust, so router-level deadline is not needed.
interface IUniswapV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IPermit2 {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitBatchTransferFrom {
        TokenPermissions[] permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitBatchTransferFrom calldata permit,
        SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice Uniswap V4 entrypoint. HELM launches on clanker.world (Clanker v4),
///         whose pools live on Uniswap V4 behind a fee hook, so the ETH->HELM
///         buy must route through the Universal Router -> PoolManager.
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @dev Uniswap V4 pool identifier. Clanker v4 pools pair against WETH (not
///      native ETH), so currency0/currency1 are the sorted (WETH, HELM) pair and
///      the contract wraps ETH->WETH before swapping. `hooks` MUST be the Clanker
///      fee hook address or the swap reverts, and `fee` must be the dynamic-fee
///      flag (0x800000) for Clanker dynamic-fee pools.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @dev Mirrors v4-periphery IV4Router.ExactInputSingleParams for abi.encode.
struct V4ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

/// @title DustExecutor
/// @notice Route-aware dust converter for ERC20 -> ETH sweeps.
/// @dev Intended flow:
///      1. Backend scans, quotes, checks tax/security, and simulates each route.
///      2. Frontend sends only sellable token instructions to this contract.
///      3. V2 fee-on-transfer tokens use Router02's supporting-fee function.
///      4. V3 tokens can use a direct V3 exactInputSingle router.
///      5. V4 / Clanker tokens use a native V4 exactInputSingle route whose
///         calldata is built on-chain from the pool params (fee, tickSpacing,
///         hooks), so slippage is enforced authoritatively.
///      6. Other complex routes can still use an allow-listed Universal Router
///         with backend-generated calldata.
///
///      This contract is not audited. Do not deploy with arbitrary routers
///      allow-listed. For Universal Router routes, backend calldata must send
///      proceeds to this contract so settlement and protocol fees are enforced.
contract DustExecutor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum RouteType {
        V2_FEE_ON_TRANSFER,
        V3_EXACT_INPUT_SINGLE,
        UNIVERSAL_ROUTER,
        V4_EXACT_INPUT_SINGLE
    }

    /// @notice What the user receives for their dust.
    /// ETH  -> 10% fee (7% to owner in ETH, 3% accrued for HELM buyback+burn).
    /// HELM -> 5% fee (all to owner in ETH); remaining 95% bought as HELM.
    enum OutputMode {
        ETH,
        HELM
    }

    struct Swap {
        address token;
        RouteType routeType;
        address router;
        uint256 amount;
        uint256 minEthOut;
        address[] v2Path;
        // Pool fee for V3 and V4 routes. For a Clanker v4 dynamic-fee pool this
        // MUST be the dynamic-fee flag 0x800000 (8388608), not a percentage.
        uint24 v3Fee;
        // V4 pool key extras (V4_EXACT_INPUT_SINGLE only; zero for other routes).
        int24 v4TickSpacing;
        address v4Hooks;
        bytes universalRouterData;
    }

    address public immutable WETH;
    IPermit2 public immutable PERMIT2;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant MAX_FEE_BPS = 1000;

    /// @notice Wallet that receives the protocol fee (always paid in ETH).
    address public ownerWallet;

    // Fee schedule (basis points). ethBurnBps is a subset of ethFeeBps.
    uint256 public ethFeeBps = 1000; // 10% total when the user takes ETH
    uint256 public ethBurnBps = 300; // 3% of that earmarked for buyback+burn
    uint256 public helmFeeBps = 500; // 5% total when the user takes HELM

    // ETH/HELM buy route (Uniswap V4 via Universal Router).
    address public helmToken;
    address public helmRouter;
    uint24 public helmPoolFee;
    int24 public helmTickSpacing;
    address public helmHooks;

    /// @notice ETH set aside from ETH-mode swaps, spent in batches by buyback+burn.
    uint256 public accumulatedBurnEth;

    mapping(address => bool) public allowedRouters;

    event DustConverted(
        address indexed user, address indexed token, RouteType indexed routeType, uint256 amountIn, uint256 ethOut
    );
    event SwapSkipped(address indexed user, address indexed token, RouteType indexed routeType, string reason);
    event FeePaid(address indexed collector, uint256 amount);
    event HelmDelivered(address indexed user, uint256 ethIn, uint256 helmOut);
    event HelmBuyFailed(address indexed user, uint256 ethRefunded);
    event BurnAccrued(uint256 amount, uint256 totalAccrued);
    event BuybackBurned(uint256 ethIn, uint256 helmBurned);
    event RouterSet(address indexed router, bool allowed);
    event OwnerWalletUpdated(address indexed newWallet);
    event FeesUpdated(uint256 ethFeeBps, uint256 ethBurnBps, uint256 helmFeeBps);
    event HelmConfigUpdated(address token, address router, uint24 fee, int24 tickSpacing, address hooks);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event EthRescued(address indexed to, uint256 amount);

    constructor(address _weth, address _permit2) Ownable(msg.sender) {
        require(_weth != address(0), "WETH zero");
        require(_permit2 != address(0), "Permit2 zero");
        WETH = _weth;
        PERMIT2 = IPermit2(_permit2);
        ownerWallet = msg.sender;
    }

    /// @notice Execute swaps after the user has approved this contract directly.
    /// @param mode Whether the user receives ETH or HELM for the net proceeds.
    /// @param minHelmOut Minimum HELM out for the buy (HELM mode only; pass 0 for ETH mode).
    function convertDust(Swap[] calldata swaps, uint256 deadline, OutputMode mode, uint256 minHelmOut)
        external
        nonReentrant
    {
        require(deadline >= block.timestamp, "Deadline expired");
        require(swaps.length > 0, "No swaps");

        uint256 ethStart = address(this).balance;

        for (uint256 i = 0; i < swaps.length; ++i) {
            Swap calldata s = swaps[i];
            if (s.amount == 0) {
                emit SwapSkipped(msg.sender, s.token, s.routeType, "zero amount");
                continue;
            }

            uint256 tokenStart = IERC20(s.token).balanceOf(address(this));
            uint256 userBalance = IERC20(s.token).balanceOf(msg.sender);
            uint256 userAllowance = IERC20(s.token).allowance(msg.sender, address(this));
            if (userBalance < s.amount || userAllowance < s.amount) {
                emit SwapSkipped(msg.sender, s.token, s.routeType, "insufficient allowance/balance");
                continue;
            }

            IERC20(s.token).safeTransferFrom(msg.sender, address(this), s.amount);
            uint256 received = IERC20(s.token).balanceOf(address(this)) - tokenStart;
            _executeSwap(msg.sender, s, received, deadline, tokenStart);
        }

        _settle(ethStart, mode, minHelmOut);
    }

    /// @notice Execute swaps using one Permit2 batch signature.
    /// @dev permit.permitted[i] must match swaps[i].token and swaps[i].amount.
    function convertDustPermit2(
        Swap[] calldata swaps,
        IPermit2.PermitBatchTransferFrom calldata permit,
        bytes calldata signature,
        OutputMode mode,
        uint256 minHelmOut
    ) external nonReentrant {
        require(permit.deadline >= block.timestamp, "Deadline expired");
        uint256 n = swaps.length;
        require(n > 0, "No swaps");
        require(n == permit.permitted.length, "Length mismatch");

        uint256[] memory tokenStarts = new uint256[](n);
        IPermit2.SignatureTransferDetails[] memory details = new IPermit2.SignatureTransferDetails[](n);

        for (uint256 i = 0; i < n; ++i) {
            require(swaps[i].token == permit.permitted[i].token, "Token mismatch");
            require(swaps[i].amount == permit.permitted[i].amount, "Amount mismatch");
            tokenStarts[i] = IERC20(swaps[i].token).balanceOf(address(this));
            details[i] =
                IPermit2.SignatureTransferDetails({to: address(this), requestedAmount: permit.permitted[i].amount});
        }

        uint256 ethStart = address(this).balance;
        PERMIT2.permitTransferFrom(permit, details, msg.sender, signature);

        for (uint256 i = 0; i < n; ++i) {
            uint256 received = IERC20(swaps[i].token).balanceOf(address(this)) - tokenStarts[i];
            _executeSwap(msg.sender, swaps[i], received, permit.deadline, tokenStarts[i]);
        }

        _settle(ethStart, mode, minHelmOut);
    }

    function _executeSwap(address user, Swap calldata s, uint256 received, uint256 deadline, uint256 tokenStart)
        internal
    {
        if (received == 0) {
            emit SwapSkipped(user, s.token, s.routeType, "nothing received");
            return;
        }
        if (!allowedRouters[s.router]) {
            _returnTokenDelta(s.token, user, tokenStart);
            emit SwapSkipped(user, s.token, s.routeType, "router not allowed");
            return;
        }

        uint256 ethBefore = address(this).balance;
        uint256 wethBefore = IWETH(WETH).balanceOf(address(this));

        bool ok;
        if (s.routeType == RouteType.V2_FEE_ON_TRANSFER) {
            ok = _swapV2FeeOnTransfer(s, received, deadline);
        } else if (s.routeType == RouteType.V3_EXACT_INPUT_SINGLE) {
            ok = _swapV3ExactInputSingle(s, received);
        } else if (s.routeType == RouteType.V4_EXACT_INPUT_SINGLE) {
            ok = _swapV4ExactInputSingle(s, received, deadline);
        } else if (s.routeType == RouteType.UNIVERSAL_ROUTER) {
            ok = _swapUniversalRouter(s, received, deadline);
        }

        if (!ok) {
            _clearApprovals(s.token, s.router);
            _returnTokenDelta(s.token, user, tokenStart);
            emit SwapSkipped(user, s.token, s.routeType, "swap failed");
            return;
        }

        uint256 wethAfter = IWETH(WETH).balanceOf(address(this));
        if (wethAfter > wethBefore) {
            IWETH(WETH).withdraw(wethAfter - wethBefore);
        }

        _clearApprovals(s.token, s.router);
        _returnTokenDelta(s.token, user, tokenStart);

        uint256 ethOut = address(this).balance - ethBefore;
        // V2/V3 routers enforce minEthOut inside their swap calls. Universal
        // Router calldata must also encode its own minimum output checks; once
        // a raw router call succeeds, this contract cannot undo only that route.
        emit DustConverted(user, s.token, s.routeType, received, ethOut);
    }

    function _swapV2FeeOnTransfer(Swap calldata s, uint256 received, uint256 deadline) internal returns (bool) {
        if (s.v2Path.length < 2) return false;
        if (s.v2Path[0] != s.token) return false;
        if (s.v2Path[s.v2Path.length - 1] != WETH) return false;

        IERC20(s.token).forceApprove(s.router, received);
        try IUniswapV2Router02(s.router).swapExactTokensForETHSupportingFeeOnTransferTokens(
            received, s.minEthOut, s.v2Path, address(this), deadline
        ) {
            return true;
        } catch {
            return false;
        }
    }

    function _swapV3ExactInputSingle(Swap calldata s, uint256 received) internal returns (bool) {
        if (s.v3Fee == 0) return false;

        IERC20(s.token).forceApprove(s.router, received);
        IUniswapV3Router.ExactInputSingleParams memory params = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: s.token,
            tokenOut: WETH,
            fee: s.v3Fee,
            recipient: address(this),
            amountIn: received,
            amountOutMinimum: s.minEthOut,
            sqrtPriceLimitX96: 0
        });

        try IUniswapV3Router(s.router).exactInputSingle(params) returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice Sell an ERC20 dust token for WETH through a Uniswap V4 pool.
    /// @dev First-class V4 route for Clanker / hooked pools. The V4 calldata is
    ///      built on-chain from the pool params in the Swap struct so the runtime
    ///      amount and `minEthOut` are authoritative (unlike the opaque
    ///      UNIVERSAL_ROUTER route, which cannot enforce slippage here). The
    ///      router pays out WETH to this contract; the caller unwraps it to ETH.
    ///      For a Clanker dynamic-fee pool, `v3Fee` MUST be 0x800000 and `v4Hooks`
    ///      MUST be the pool's fee hook, or the swap reverts (and is caught).
    function _swapV4ExactInputSingle(Swap calldata s, uint256 received, uint256 deadline) internal returns (bool) {
        // uint128 bounds keep the V4 amount fields and the uint160 Permit2 cast safe.
        if (received > type(uint128).max || s.minEthOut > type(uint128).max) return false;
        if (deadline > type(uint48).max) return false;

        // Approve the router to pull the token via Permit2 (V4 settles via Permit2).
        IERC20(s.token).forceApprove(address(PERMIT2), received);
        PERMIT2.approve(s.token, s.router, uint160(received), uint48(deadline));

        (address c0, address c1) = s.token < WETH ? (s.token, WETH) : (WETH, s.token);
        bool zeroForOne = c0 == s.token; // selling the token for WETH

        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: s.v3Fee,
            tickSpacing: s.v4TickSpacing,
            hooks: s.v4Hooks
        });

        // V4_SWAP command (0x10), action sequence: SWAP_EXACT_IN_SINGLE (0x06),
        // SETTLE_ALL (0x0c), TAKE_ALL (0x0f).
        bytes memory commands = abi.encodePacked(uint8(0x10));
        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            V4ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: uint128(received),
                amountOutMinimum: uint128(s.minEthOut),
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(s.token, received); // SETTLE_ALL: pay the token input
        params[2] = abi.encode(WETH, s.minEthOut); // TAKE_ALL: receive WETH output

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        try IUniversalRouter(s.router).execute(commands, inputs, deadline) {
            return true;
        } catch {
            return false;
        }
    }

    function _swapUniversalRouter(Swap calldata s, uint256 received, uint256 deadline) internal returns (bool) {
        if (s.universalRouterData.length == 0) return false;
        if (received > type(uint160).max) return false;
        if (deadline > type(uint48).max) return false;

        IERC20(s.token).forceApprove(address(PERMIT2), received);
        PERMIT2.approve(s.token, s.router, uint160(received), uint48(deadline));

        (bool success,) = s.router.call(s.universalRouterData);
        return success;
    }

    function _clearApprovals(address token, address router) internal {
        IERC20(token).forceApprove(router, 0);
        IERC20(token).forceApprove(address(PERMIT2), 0);
        PERMIT2.approve(token, router, 0, 0);
    }

    function _returnTokenDelta(address token, address to, uint256 tokenStart) internal {
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        if (tokenBalance > tokenStart) {
            IERC20(token).safeTransfer(to, tokenBalance - tokenStart);
        }
    }

    function _settle(uint256 ethStart, OutputMode mode, uint256 minHelmOut) internal {
        uint256 grossEth = address(this).balance - ethStart;
        if (grossEth == 0) return;

        if (mode == OutputMode.HELM) {
            // 5% to owner in ETH; remaining 95% bought as HELM for the user.
            uint256 ownerCut = (grossEth * helmFeeBps) / 10_000;
            uint256 buyCut = grossEth - ownerCut;

            if (ownerCut > 0) {
                _sendETH(ownerWallet, ownerCut);
                emit FeePaid(ownerWallet, ownerCut);
            }
            if (buyCut > 0) {
                (bool ok, uint256 helmOut) = _buyHelm(buyCut, minHelmOut, msg.sender);
                if (ok) {
                    emit HelmDelivered(msg.sender, buyCut, helmOut);
                } else {
                    // Pool unavailable / slippage: refund the user in ETH instead.
                    _sendETH(msg.sender, buyCut);
                    emit HelmBuyFailed(msg.sender, buyCut);
                }
            }
        } else {
            // 10% total: 7% to owner in ETH, 3% accrued for batched buyback+burn.
            uint256 ownerCut = (grossEth * (ethFeeBps - ethBurnBps)) / 10_000;
            uint256 burnCut = (grossEth * ethBurnBps) / 10_000;
            uint256 userCut = grossEth - ownerCut - burnCut;

            if (userCut > 0) {
                _sendETH(msg.sender, userCut);
            }
            if (ownerCut > 0) {
                _sendETH(ownerWallet, ownerCut);
                emit FeePaid(ownerWallet, ownerCut);
            }
            if (burnCut > 0) {
                accumulatedBurnEth += burnCut;
                emit BurnAccrued(burnCut, accumulatedBurnEth);
            }
        }
    }

    /// @notice Spend accrued ETH-mode fees buying HELM and sending it to the
    ///         burn address. Batched to limit gas and sandwich exposure on a
    ///         thin pool. `minOut` should come from a fresh off-chain quote.
    function executeBuybackBurn(uint256 minOut) external onlyOwner nonReentrant {
        uint256 amount = accumulatedBurnEth;
        require(amount > 0, "nothing to burn");
        accumulatedBurnEth = 0;

        (bool ok, uint256 burned) = _buyHelm(amount, minOut, DEAD);
        if (!ok) {
            accumulatedBurnEth = amount; // restore on failure
            revert("buyback failed");
        }
        emit BuybackBurned(amount, burned);
    }

    /// @notice Buy HELM through the Uniswap V4 Universal Router and forward it.
    /// @dev Clanker v4 pools pair against WETH, so we wrap ETH->WETH, sort the
    ///      (WETH, HELM) currencies for the PoolKey, and let the router pull WETH
    ///      via Permit2. The V4 calldata is built on-chain from the stored pool
    ///      config so the runtime amount and `minOut` are authoritative. On any
    ///      failure the wrap is undone so the caller can refund native ETH.
    function _buyHelm(uint256 ethIn, uint256 minOut, address recipient)
        internal
        returns (bool ok, uint256 received)
    {
        if (helmRouter == address(0) || helmToken == address(0)) return (false, 0);
        // uint128 bound also keeps the uint160 Permit2 cast safe.
        if (ethIn == 0 || ethIn > type(uint128).max || minOut > type(uint128).max) return (false, 0);

        // Wrap to WETH (Clanker pools are WETH-paired, not native-ETH).
        IWETH(WETH).deposit{value: ethIn}();

        (address c0, address c1) = WETH < helmToken ? (WETH, helmToken) : (helmToken, WETH);
        bool wethIsCurrency0 = c0 == WETH;

        uint256 balBefore = IERC20(helmToken).balanceOf(address(this));

        // Approve the router to pull WETH via Permit2 (same pattern as V4 dust routes).
        IERC20(WETH).forceApprove(address(PERMIT2), ethIn);
        PERMIT2.approve(WETH, helmRouter, uint160(ethIn), type(uint48).max);

        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: helmPoolFee,
            tickSpacing: helmTickSpacing,
            hooks: helmHooks
        });

        // V4_SWAP command (0x10), action sequence: SWAP_EXACT_IN_SINGLE (0x06),
        // SETTLE_ALL (0x0c), TAKE_ALL (0x0f).
        bytes memory commands = abi.encodePacked(uint8(0x10));
        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            V4ExactInputSingleParams({
                poolKey: key,
                zeroForOne: wethIsCurrency0, // selling WETH for HELM
                amountIn: uint128(ethIn),
                amountOutMinimum: uint128(minOut),
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(WETH, ethIn); // SETTLE_ALL: pay WETH input
        params[2] = abi.encode(helmToken, minOut); // TAKE_ALL: receive HELM output

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        // No msg.value: the input is WETH (ERC20), pulled via Permit2.
        try IUniversalRouter(helmRouter).execute(commands, inputs, block.timestamp) {
            received = IERC20(helmToken).balanceOf(address(this)) - balBefore;
            _clearApprovals(WETH, helmRouter);
            if (recipient != address(this) && received > 0) {
                IERC20(helmToken).safeTransfer(recipient, received);
            }
            return (true, received);
        } catch {
            // Undo the wrap so the caller still holds native ETH to refund.
            _clearApprovals(WETH, helmRouter);
            IWETH(WETH).withdraw(ethIn);
            return (false, 0);
        }
    }

    function setRouter(address router, bool allowed) external onlyOwner {
        require(router != address(0), "router zero");
        allowedRouters[router] = allowed;
        emit RouterSet(router, allowed);
    }

    function setOwnerWallet(address wallet) external onlyOwner {
        require(wallet != address(0), "wallet zero");
        ownerWallet = wallet;
        emit OwnerWalletUpdated(wallet);
    }

    function setFees(uint256 _ethFeeBps, uint256 _ethBurnBps, uint256 _helmFeeBps) external onlyOwner {
        require(_ethFeeBps <= MAX_FEE_BPS && _helmFeeBps <= MAX_FEE_BPS, "fee too high");
        require(_ethBurnBps <= _ethFeeBps, "burn exceeds fee");
        ethFeeBps = _ethFeeBps;
        ethBurnBps = _ethBurnBps;
        helmFeeBps = _helmFeeBps;
        emit FeesUpdated(_ethFeeBps, _ethBurnBps, _helmFeeBps);
    }

    /// @notice Configure the WETH->HELM V4 buy route once HELM is live on Clanker.
    /// @param token HELM token address.
    /// @param router Uniswap V4 Universal Router address (must support Permit2 input).
    /// @param fee Pool fee field. For a Clanker dynamic-fee pool this MUST be the
    ///        dynamic-fee flag 0x800000 (8388608), not a percentage.
    /// @param tickSpacing Pool tick spacing for the HELM pool (e.g. 200).
    /// @param hooks Clanker fee hook for the HELM pool (must match exactly).
    function setHelmConfig(address token, address router, uint24 fee, int24 tickSpacing, address hooks)
        external
        onlyOwner
    {
        require(token != address(0) && router != address(0), "zero addr");
        helmToken = token;
        helmRouter = router;
        helmPoolFee = fee;
        helmTickSpacing = tickSpacing;
        helmHooks = hooks;
        emit HelmConfigUpdated(token, router, fee, tickSpacing, hooks);
    }

    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "to zero");
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    function rescueETH(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "to zero");
        _sendETH(to, amount);
        emit EthRescued(to, amount);
    }

    function _sendETH(address to, uint256 amount) internal {
        (bool success,) = payable(to).call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    receive() external payable {}
}
