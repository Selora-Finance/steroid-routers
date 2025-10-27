pragma solidity ^0.8.0;

import './interfaces/IWETH.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import './integrations/interfaces/ISeloraV3Router.sol';
import './integrations/interfaces/ISeloraV3Factory.sol';

contract V3SwapExecutor is Ownable {
    using SafeERC20 for IERC20;

    enum SwapType {
        ALLOW_ZEROS,
        EXACT_OUT
    }

    struct QueryResult {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        int24 tickSpacing;
    }

    ISeloraV3Router public immutable baseRouter;
    ISeloraV3Factory public immutable baseFactory;
    uint64 public swapFeePercentage;
    IWETH public weth;

    address public constant ETHER = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    address[] public trustedTokens;
    uint64 public constant MAX_FEE_PERCENTAGE = 5000; // 5%
    uint64 public constant MAX_PERCENTAGE = 100000; // 100%

    error InvalidContract(address addr);
    error NoSwapRoute(address tokenA, address tokenB);
    error FeePercentageTooHigh();
    error InsufficientAmountOut();

    constructor(
        address newOwner,
        ISeloraV3Router _baseRouter,
        ISeloraV3Factory _baseFactory,
        uint64 _swapFeePercentage,
        IWETH _weth,
        address[] memory _trustedTokens
    ) Ownable(newOwner) {
        baseRouter = _baseRouter;
        baseFactory = _baseFactory;
        setTrustedTokens(_trustedTokens);

        if (_swapFeePercentage > MAX_FEE_PERCENTAGE) revert FeePercentageTooHigh();

        swapFeePercentage = _swapFeePercentage;
        weth = _weth;
    }

    function _approveTokenSpend(IERC20 token, uint256 amount) private {
        token.approve(address(baseRouter), amount);
    }

    function _executeSwapOnRouter(
        address tokenA,
        address tokenB,
        int24 tickSpacing,
        uint256 amountIn,
        uint256 amountOut,
        bool exactAmountOut,
        uint256 deadline
    ) private {
        if (!exactAmountOut) amountOut = 0;
        // Approve spend
        _approveTokenSpend(IERC20(tokenA), amountIn);
        // Prepare routes
        ISeloraV3Router.ExactInputSingleParams memory params = ISeloraV3Router.ExactInputSingleParams(
            tokenA,
            tokenB,
            tickSpacing,
            address(this),
            deadline,
            amountIn,
            amountOut,
            0
        );
        // Swap to self
        baseRouter.exactInputSingle(params);
    }

    function _unwrapAndSendEther(uint256 amount, address to) private returns (bool sent) {
        weth.withdraw(amount);
        (sent, ) = to.call{value: amount}('');
    }

    function _getBalance(address token, address _acc) private view returns (uint256 _balance) {
        (, bytes memory data) = token.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, _acc));
        _balance = abi.decode(data, (uint256));
    }

    function _getDecimals(address token) private view returns (uint8 _decimals) {
        (, bytes memory data) = token.staticcall(abi.encodeWithSelector(bytes4(keccak256(bytes('decimals()')))));
        _decimals = abi.decode(data, (uint8));
    }

    function _query(address tokenA, address tokenB, uint256 amountIn) private view returns (QueryResult memory result) {
        if (tokenA != tokenB && amountIn != 0) {
            int24[] memory tickSpacings = baseFactory.tickSpacings();
            for (uint i = 0; i < tickSpacings.length; i++) {
                address pool = baseFactory.getPool(tokenA, tokenB, tickSpacings[i]);
                if (pool == address(0)) continue;
                uint256 balanceA = _getBalance(tokenA, pool);
                uint256 balanceB = _getBalance(tokenB, pool);
                if (balanceA == 0 || balanceB == 0) continue;
                // Calculate price of token A in terms of B
                uint8 decimalsA = _getDecimals(tokenA);
                uint256 priceA = (balanceB * 10 ** decimalsA) / balanceA;
                uint256 aOut = (amountIn * priceA) / (10 ** decimalsA);
                if (aOut > result.amountOut) {
                    result.amountOut = aOut;
                    result.tickSpacing = tickSpacings[i];
                    result.tokenIn = tokenA;
                    result.tokenOut = tokenB;
                    result.amountIn = amountIn;
                }
            }
        }
    }

    function setTrustedTokens(address[] memory _trustedTokens) public onlyOwner {
        trustedTokens = _trustedTokens;
    }

    function setSwapFeePercentage(uint64 _swapFeePercentage) external onlyOwner {
        if (_swapFeePercentage > MAX_FEE_PERCENTAGE) revert FeePercentageTooHigh();
        swapFeePercentage = _swapFeePercentage;
    }

    function query(
        address tokenA,
        address tokenB,
        uint256 amountIn
    ) public view returns (QueryResult memory bestResult) {
        bestResult = _query(tokenA, tokenB, amountIn);
    }

    function _emptyQueryResults() private pure returns (QueryResult[] memory) {
        QueryResult[] memory emptyResult = new QueryResult[](0);
        return emptyResult;
    }

    function _appendQueryResult(
        QueryResult[] memory previousResults,
        QueryResult memory result
    ) private pure returns (QueryResult[] memory) {
        QueryResult[] memory finalResults = new QueryResult[](previousResults.length + 1);

        // Copy previous results
        for (uint i = 0; i < previousResults.length; i++) finalResults[i] = previousResults[i];

        finalResults[previousResults.length] = result;
        return finalResults;
    }

    function _findBestRoute(
        address tokenA,
        address tokenB,
        uint256 amountIn,
        QueryResult[] memory previousResults,
        bool skipTrustedTokens
    ) private view returns (QueryResult[] memory) {
        QueryResult memory firstQR = query(tokenA, tokenB, amountIn);
        QueryResult[] memory finalResults = _appendQueryResult(previousResults, firstQR);

        if (firstQR.amountOut != 0) return finalResults; // Return earlier

        // Only check if we don't want to skip trusted tokens
        if (!skipTrustedTokens) {
            for (uint i = 0; i < trustedTokens.length; i++) {
                if (trustedTokens[i] == tokenA) continue;
                QueryResult memory bestResult = query(tokenA, trustedTokens[i], amountIn);
                if (bestResult.amountOut == 0) continue;

                finalResults = _appendQueryResult(finalResults, bestResult);

                bool isLast = (i + 1) == trustedTokens.length;

                finalResults = _findBestRoute(trustedTokens[i], tokenB, bestResult.amountOut, finalResults, isLast); // Recursion
                QueryResult memory newQR = finalResults[finalResults.length - 1];
                address tokenOut = newQR.tokenOut;
                uint256 amountOut = newQR.amountOut;

                if (tokenOut == tokenB && amountOut != 0) return finalResults;
            }
        }

        return _emptyQueryResults();
    }

    function _calculateEcosystemCommission(uint256 amount) private view returns (uint256) {
        if (swapFeePercentage == 0) return 0;
        uint256 commission = (swapFeePercentage * amount) / MAX_PERCENTAGE;
        return commission;
    }

    function findBestRoute(
        address tokenA,
        address tokenB,
        uint256 amountIn
    ) public view returns (QueryResult[] memory results) {
        results = _findBestRoute(tokenA, tokenB, amountIn, _emptyQueryResults(), false);
    }

    function execute(
        address tokenA,
        address tokenB,
        address to,
        uint256 amountIn,
        uint256 amountOut,
        SwapType swapType,
        uint256 deadline
    ) external payable {
        // Wrap if first token is Ether or zero address
        if (tokenA == ETHER || tokenA == address(0)) {
            require(msg.value > 0, 'No zero value');
            amountIn = msg.value;
            weth.deposit{value: amountIn}();
            tokenA = address(weth);
        } else {
            if (tokenA.code.length == 0) revert InvalidContract(tokenA);
            IERC20(tokenA).transferFrom(msg.sender, address(this), amountIn); // Transfer token from sender
        }

        if (tokenB == ETHER || tokenB == address(0)) tokenB = address(weth);
        if (tokenB.code.length == 0) revert InvalidContract(tokenB); // Token B must be contract

        // Record balance before swap. This is to check and prevent overspending
        uint256 balanceBBefore = IERC20(tokenB).balanceOf(address(this));

        QueryResult[] memory bestRoute = findBestRoute(tokenA, tokenB, amountIn);
        if (bestRoute.length == 0) revert NoSwapRoute(tokenA, tokenB);

        // Execute swaps sequentially
        for (uint i = 0; i < bestRoute.length; i++) {
            QueryResult memory route = bestRoute[i];
            _executeSwapOnRouter(
                route.tokenIn,
                route.tokenOut,
                route.tickSpacing,
                route.amountIn,
                route.amountOut,
                swapType == SwapType.EXACT_OUT,
                deadline
            );
        }

        // Balance after
        uint256 balanceBAfter = IERC20(tokenB).balanceOf(address(this));
        uint256 sendableAmount = balanceBAfter - balanceBBefore;
        uint256 commission = _calculateEcosystemCommission(sendableAmount);
        uint256 dueToRecipient = sendableAmount - commission;
        uint256 fees = commission + balanceBBefore;

        if (sendableAmount < amountOut) revert InsufficientAmountOut();

        if (tokenB == address(weth)) {
            // Send to recipient
            _unwrapAndSendEther(dueToRecipient, to);
            if (fees > 0) _unwrapAndSendEther(fees, owner());
        } else {
            // Send to recipient
            IERC20(tokenB).transfer(to, dueToRecipient);
            if (fees > 0) IERC20(tokenB).transfer(owner(), fees);
        }
    }

    function sendOutERC20(IERC20 token, address to, uint256 amount) external onlyOwner returns (bool) {
        return token.transfer(to, amount);
    }

    receive() external payable {
        weth.deposit{value: msg.value}();
    }
}
