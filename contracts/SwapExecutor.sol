pragma solidity ^0.8.0;

import './integrations/interfaces/IBaseRouter.sol';
import './interfaces/IWETH.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

contract SwapExecutor is Ownable {
    using SafeERC20 for IERC20;

    struct QueryResult {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        IBaseRouter router;
    }

    IBaseRouter[] public routers;
    uint24 public swapFeePercentage;
    IWETH public weth;

    address public constant ETHER = address(0x000);

    mapping(address => bool) public isActiveRouter;

    error NoActiveRouters();
    error InvalidContract(address addr);

    constructor(
        address newOwner,
        IBaseRouter[] memory _routers,
        uint24 _swapFeePercentage,
        IWETH _weth
    ) Ownable(newOwner) {
        addRouters(_routers);
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
        bool exactAmountOut
    ) private {
        uint256 amountOut = 0; // Start with zero
        if (exactAmountOut) {
            amountOut = router.query(tokenA, tokenB, amountIn);
        }
        // Approve spend
        _approveTokenSpend(router, IERC20(tokenA), amountIn);
        // Swap to self
        router.swap(tokenA, tokenB, address(this), amountIn, amountOut);
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

    function switchRouterActiveStatus(IBaseRouter router) external onlyOwner {
        require(_checkIfIsRouter(router), 'Unknown router');
        isActiveRouter[address(router)] = !isActiveRouter[address(router)];
    }

    function execute(address tokenA, address tokenB, uint256 amountIn) external payable {
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

        IBaseRouter[] memory activeRouters = _filterActiveRouters();
        if (activeRouters.length == 0) revert NoActiveRouters(); // We need routers to execute the swap
        QueryResult[] memory results; // Store query results for each router
        for (uint i = 0; i < activeRouters.length; i++) {}
    }
}
