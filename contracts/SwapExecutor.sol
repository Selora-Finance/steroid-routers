pragma solidity ^0.8.0;

import './integrations/interfaces/IBaseRouter.sol';
import './interfaces/IWETH.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

contract SwapExecutor is Ownable {
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
        IBaseRouter router;
    }

    IBaseRouter[] public routers;
    uint64 public swapFeePercentage;
    IWETH public weth;

    address public constant ETHER = address(0x000);
    address[] public trustedTokens;
    uint64 public constant MAX_FEE_PERCENTAGE = 5000; // 5%
    uint64 public constant MAX_PERCENTAGE = 100000; // 100%

    mapping(address => bool) public isActiveRouter;

    error NoActiveRouters();
    error InvalidContract(address addr);
    error NoSwapRoute(address tokenA, address tokenB);
    error FeePercentageTooHigh();
    error InsufficientAmountOut();

    constructor(
        address newOwner,
        IBaseRouter[] memory _routers,
        uint64 _swapFeePercentage,
        IWETH _weth,
        address[] memory _trustedTokens
    ) Ownable(newOwner) {
        addRouters(_routers);
        setTrustedTokens(_trustedTokens);

        if (_swapFeePercentage > MAX_FEE_PERCENTAGE) revert FeePercentageTooHigh();

        swapFeePercentage = _swapFeePercentage;
        weth = _weth;
    }

    function _approveTokenSpend(IBaseRouter router, IERC20 token, uint256 amount) private {
        token.approve(address(router), amount);
    }

    function _executeSwapOnRouter(
        IBaseRouter router,
        address tokenA,
        address tokenB,
        uint256 amountIn,
        uint256 amountOut,
        bool exactAmountOut,
        uint256 deadline
    ) private {
        if (!exactAmountOut) amountOut = 0;
        // Approve spend
        _approveTokenSpend(router, IERC20(tokenA), amountIn);
        // Swap to self
        router.swap(tokenA, tokenB, address(this), amountIn, amountOut, deadline);
    }

    function _unwrapAndSendEther(uint256 amount, address to) private returns (bool sent) {
        weth.withdraw(amount);
        (sent, ) = to.call{value: amount}('');
    }

    function _checkIfIsRouter(IBaseRouter router) private view returns (bool) {
        for (uint i = 0; i < routers.length; i++) {
            if (routers[i] == router) return true;
        }
        return false;
    }

    function _addRouter(IBaseRouter router) private {
        if (!_checkIfIsRouter(router)) {
            routers.push(router);
            isActiveRouter[address(router)] = true;
        }
    }

    function _filterActiveRouters() private view returns (IBaseRouter[] memory _routers) {
        for (uint i = 0; i < routers.length; i++) {
            if (isActiveRouter[address(routers[i])]) {
                _routers[_routers.length] = routers[i];
            }
        }
    }

    function _query(
        IBaseRouter router,
        address tokenA,
        address tokenB,
        uint256 amountIn
    ) private view returns (QueryResult memory result) {
        // Query directly
        uint256 amountOut = router.query(tokenA, tokenB, amountIn);
        result = QueryResult(tokenA, tokenB, amountIn, amountOut, router);
    }

    function addRouters(IBaseRouter[] memory _routers) public onlyOwner {
        for (uint i = 0; i < _routers.length; i++) {
            _addRouter(_routers[i]);
        }
    }

    function setTrustedTokens(address[] memory _trustedTokens) public onlyOwner {
        trustedTokens = _trustedTokens;
    }

    function switchRouterActiveStatus(IBaseRouter router) external onlyOwner {
        require(_checkIfIsRouter(router), 'Unknown router');
        isActiveRouter[address(router)] = !isActiveRouter[address(router)];
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
        IBaseRouter[] memory activeRouters = _filterActiveRouters();
        if (activeRouters.length == 0) revert NoActiveRouters(); // We need routers to execute query
        for (uint i = 0; i < activeRouters.length; i++) {
            IBaseRouter router = activeRouters[i];
            QueryResult memory qr = _query(router, tokenA, tokenB, amountIn);
            if (qr.amountOut > bestResult.amountOut) bestResult = qr;
        }
    }

    function _emptyQueryResults() private pure returns (QueryResult[] memory) {
        QueryResult[] memory emptyResult;
        return emptyResult;
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
            if (finalResults.length == 0) finalResults[0] = firstQR;
            else finalResults[finalResults.length] = firstQR;
            return finalResults; // Return earlier
        }

        // Only check if we don't want to skip trusted tokens
        if (!skipTrustedTokens) {
            for (uint i = 0; i < trustedTokens.length; i++) {
                if (trustedTokens[i] == tokenA) continue;
                QueryResult memory bestResult = query(tokenA, trustedTokens[i], amountIn);
                if (bestResult.amountOut == 0) continue;
                if (finalResults.length == 0) finalResults[0] = bestResult;
                else finalResults[finalResults.length] = bestResult;

                finalResults = _findBestRoute(
                    trustedTokens[i],
                    tokenB,
                    bestResult.amountOut,
                    finalResults,
                    trustedTokens[i] == trustedTokens[trustedTokens.length - 1]
                ); // Recursion
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
                route.router,
                route.tokenIn,
                route.tokenOut,
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
