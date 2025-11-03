pragma solidity ^0.8.0;

import './interfaces/IWETH.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import './integrations/interfaces/ISeloraV2Router.sol';
import './integrations/interfaces/ISeloraV2Factory.sol';
import './integrations/interfaces/ISeloraPool.sol';

contract V2SwapExecutor is Ownable {
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
        ISeloraPool pool;
    }

    ISeloraV2Router public immutable baseRouter;
    ISeloraV2Factory public immutable baseFactory;
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
        ISeloraV2Router _baseRouter,
        uint64 _swapFeePercentage,
        IWETH _weth,
        address[] memory _trustedTokens
    ) Ownable(newOwner) {
        baseRouter = _baseRouter;
        baseFactory = ISeloraV2Factory(_baseRouter.defaultFactory());
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
        bool stable,
        uint256 amountIn,
        uint256 amountOut,
        bool exactAmountOut,
        uint256 deadline
    ) private {
        if (!exactAmountOut) amountOut = 0;
        // Approve spend
        _approveTokenSpend(IERC20(tokenA), amountIn);
        // Prepare routes
        ISeloraV2Router.Route[] memory routes = new ISeloraV2Router.Route[](1);
        routes[0] = ISeloraV2Router.Route({
            from: tokenA,
            to: tokenB,
            stable: stable,
            factory: baseRouter.defaultFactory()
        });
        // Swap to self
        baseRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn,
            amountOut,
            routes,
            address(this),
            deadline
        );
    }

    function _unwrapAndSendEther(uint256 amount, address to) private returns (bool sent) {
        weth.withdraw(amount);
        (sent, ) = to.call{value: amount}('');
    }

    function _query(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountIn
    ) private view returns (QueryResult memory result) {
        if (tokenA != tokenB && amountIn != 0) {
            address pool = baseFactory.getPool(tokenA, tokenB, stable);
            uint256 aOut;

            if (pool != address(0)) aOut = ISeloraPool(pool).getAmountOut(amountIn, tokenA);

            result = QueryResult({
                tokenIn: tokenA,
                tokenOut: tokenB,
                amountIn: amountIn,
                amountOut: aOut,
                pool: ISeloraPool(pool)
            });
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
        QueryResult memory stableResult = _query(tokenA, tokenB, true, amountIn);
        QueryResult memory volatileResult = _query(tokenA, tokenB, false, amountIn);
        if (stableResult.amountOut > volatileResult.amountOut) bestResult = stableResult;
        else bestResult = volatileResult;
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

    function _tokenIsWithinPath(QueryResult[] memory results, address token) private pure returns (bool isWithinPath) {
        for (uint i = 0; i < results.length; i++) {
            address tokenIn = results[i].tokenIn;
            address tokenOut = results[i].tokenOut;
            if (tokenIn == token || tokenOut == token) {
                isWithinPath = true;
                break;
            }
        }
    }

    function _findBestRoute(
        address tokenA,
        address tokenB,
        uint256 amountIn,
        QueryResult[] memory previousResults,
        bool skipTrustedTokens
    ) private view returns (QueryResult[] memory) {
        QueryResult memory firstQR = query(tokenA, tokenB, amountIn);
        QueryResult[] memory finalResults = previousResults;

        if (firstQR.amountOut != 0) {
            finalResults = _appendQueryResult(finalResults, firstQR);
            return finalResults; // Return earlier
        }

        // Only check if we don't want to skip trusted tokens
        if (!skipTrustedTokens) {
            for (uint i = 0; i < trustedTokens.length; i++) {
                if (
                    trustedTokens[i] == tokenA ||
                    trustedTokens[i] == tokenB ||
                    _tokenIsWithinPath(finalResults, trustedTokens[i])
                ) continue;
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
                route.pool.stable(),
                route.amountIn,
                route.tokenOut == tokenB ? amountOut : route.amountOut,
                route.tokenOut == tokenB ? swapType == SwapType.EXACT_OUT : false,
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
        if (msg.sender != address(weth)) {
            weth.deposit{value: msg.value}();
        }
    }
}
