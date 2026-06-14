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

interface IUniswapV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
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

/// @title DustExecutor
/// @notice Route-aware dust converter for ERC20 -> ETH sweeps.
/// @dev Intended flow:
///      1. Backend scans, quotes, checks tax/security, and simulates each route.
///      2. Frontend sends only sellable token instructions to this contract.
///      3. V2 fee-on-transfer tokens use Router02's supporting-fee function.
///      4. V3 tokens can use a direct V3 exactInputSingle router.
///      5. V4 and complex routes can use an allow-listed Universal Router with
///         backend-generated calldata.
///
///      This contract is not audited. Do not deploy with arbitrary routers
///      allow-listed. For Universal Router routes, backend calldata must send
///      proceeds to this contract so settlement and protocol fees are enforced.
contract DustExecutor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum RouteType {
        V2_FEE_ON_TRANSFER,
        V3_EXACT_INPUT_SINGLE,
        UNIVERSAL_ROUTER
    }

    struct Swap {
        address token;
        RouteType routeType;
        address router;
        uint256 amount;
        uint256 minEthOut;
        address[] v2Path;
        uint24 v3Fee;
        bytes universalRouterData;
    }

    address public immutable WETH;
    IPermit2 public immutable PERMIT2;

    address public feeCollector;
    uint256 public feeBps;
    uint256 public constant MAX_FEE_BPS = 300;

    mapping(address => bool) public allowedRouters;

    event DustConverted(
        address indexed user, address indexed token, RouteType indexed routeType, uint256 amountIn, uint256 ethOut
    );
    event SwapSkipped(address indexed user, address indexed token, RouteType indexed routeType, string reason);
    event FeePaid(address indexed collector, uint256 amount);
    event RouterSet(address indexed router, bool allowed);
    event FeeCollectorUpdated(address indexed newCollector);
    event FeeUpdated(uint256 newBps);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event EthRescued(address indexed to, uint256 amount);

    constructor(address _weth, address _permit2) Ownable(msg.sender) {
        require(_weth != address(0), "WETH zero");
        require(_permit2 != address(0), "Permit2 zero");
        WETH = _weth;
        PERMIT2 = IPermit2(_permit2);
        feeCollector = msg.sender;
        feeBps = 100;
    }

    /// @notice Execute swaps after the user has approved this contract directly.
    function convertDust(Swap[] calldata swaps, uint256 deadline) external nonReentrant {
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

        _settle(ethStart);
    }

    /// @notice Execute swaps using one Permit2 batch signature.
    /// @dev permit.permitted[i] must match swaps[i].token and swaps[i].amount.
    function convertDustPermit2(
        Swap[] calldata swaps,
        IPermit2.PermitBatchTransferFrom calldata permit,
        bytes calldata signature
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

        _settle(ethStart);
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
            ok = _swapV3ExactInputSingle(s, received, deadline);
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

    function _swapV3ExactInputSingle(Swap calldata s, uint256 received, uint256 deadline) internal returns (bool) {
        if (s.v3Fee == 0) return false;

        IERC20(s.token).forceApprove(s.router, received);
        IUniswapV3Router.ExactInputSingleParams memory params = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: s.token,
            tokenOut: WETH,
            fee: s.v3Fee,
            recipient: address(this),
            deadline: deadline,
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

    function _settle(uint256 ethStart) internal {
        uint256 grossEth = address(this).balance - ethStart;
        if (grossEth == 0) return;

        uint256 fee = (grossEth * feeBps) / 10_000;
        uint256 userAmount = grossEth - fee;

        if (userAmount > 0) {
            _sendETH(msg.sender, userAmount);
        }
        if (fee > 0) {
            _sendETH(feeCollector, fee);
            emit FeePaid(feeCollector, fee);
        }
    }

    function setRouter(address router, bool allowed) external onlyOwner {
        require(router != address(0), "router zero");
        allowedRouters[router] = allowed;
        emit RouterSet(router, allowed);
    }

    function setFeeCollector(address collector) external onlyOwner {
        require(collector != address(0), "collector zero");
        feeCollector = collector;
        emit FeeCollectorUpdated(collector);
    }

    function setFeeBps(uint256 bps) external onlyOwner {
        require(bps <= MAX_FEE_BPS, "fee too high");
        feeBps = bps;
        emit FeeUpdated(bps);
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
