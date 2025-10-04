pragma solidity ^0.8.0;

import '../BaseRouter.sol';
import '../interfaces/ISeloraV3Router.sol';
import '../interfaces/ISeloraV3Factory.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

contract SeloraV3Router is BaseRouter {
    using SafeERC20 for IERC20;

    ISeloraV3Router public immutable baseSwapRouter;
    ISeloraV3Factory public immutable baseFactory;

    constructor(ISeloraV3Router _baseSwapRouter, ISeloraV3Factory _baseFactory) BaseRouter() {
        baseSwapRouter = _baseSwapRouter;
        baseFactory = _baseFactory;
    }

    function _getBalance(address token, address _acc) private view returns (uint256 _balance) {
        (, bytes memory data) = token.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, _acc));
        _balance = abi.decode(data, (uint256));
    }

    function _getDecimals(address token) private view returns (uint8 _decimals) {
        (, bytes memory data) = token.staticcall(abi.encodeWithSelector(bytes4(keccak256(bytes('decimals()')))));
        _decimals = abi.decode(data, (uint8));
    }

    function _getBestRoute(
        address tokenA,
        address tokenB,
        uint256 amountIn
    ) private view returns (int24 tickSpacing, uint256 amountOut) {
        int24[] memory tickSpacings = baseFactory.tickSpacings();
        for (uint i = 0; i < tickSpacings.length; i++) {
            address pool = baseFactory.getPool(tokenA, tokenB, tickSpacings[i]);
            uint256 balanceA = _getBalance(tokenA, pool);
            uint256 balanceB = _getBalance(tokenB, pool);
            // Calculate price of token A in terms of B
            uint8 decimalsA = _getDecimals(tokenA);
            uint256 priceA = (balanceB * 10 ** decimalsA) / balanceA;
            uint256 aOut = (amountIn * priceA) / (10 ** decimalsA);
            if (aOut > amountOut) {
                amountOut = aOut;
                tickSpacing = tickSpacings[i];
            }
        }
    }

    function _query(
        address tokenA,
        address tokenB,
        uint256 amountIn
    ) internal view virtual override returns (uint256 amountOut) {
        (, amountOut) = _getBestRoute(tokenA, tokenB, amountIn);
    }

    function _swap(
        address tokenA,
        address tokenB,
        address to,
        uint256 amountIn,
        uint256 amountOut,
        uint256 deadline
    ) internal virtual override {
        (int24 tickSpacing, ) = _getBestRoute(tokenA, tokenB, amountIn);
        bytes4 selector;
        bytes memory callBytes0;
        if (amountOut == 0) {
            selector = ISeloraV3Router.exactInputSingle.selector;
            ISeloraV3Router.ExactInputSingleParams memory params = ISeloraV3Router.ExactInputSingleParams(
                tokenA,
                tokenB,
                tickSpacing,
                to,
                deadline,
                amountIn,
                amountOut,
                0
            );
            callBytes0 = abi.encodeWithSelector(selector, params);
        } else {
            selector = ISeloraV3Router.exactOutputSingle.selector;
            ISeloraV3Router.ExactOutputSingleParams memory params = ISeloraV3Router.ExactOutputSingleParams(
                tokenA,
                tokenB,
                tickSpacing,
                to,
                deadline,
                amountOut,
                amountIn,
                0
            );
            callBytes0 = abi.encodeWithSelector(selector, params);
        }

        bytes4 sweepSelector = bytes4(keccak256(bytes('sweepToken(address,uint256,address)')));
        bytes memory callBytes1 = abi.encodeWithSelector(sweepSelector, tokenB, amountOut, to);
        // Use multicall
        bytes4 multicallSelector = bytes4(keccak256(bytes('multicall(bytes[])')));
        bytes[2] memory allCallBytes;
        allCallBytes[0] = callBytes0;
        allCallBytes[1] = callBytes1;

        // Allow base router to spend amount
        IERC20(tokenA).approve(address(baseSwapRouter), amountIn);

        (bool success, ) = address(baseSwapRouter).call(abi.encodeWithSelector(multicallSelector, allCallBytes));
        require(success, 'Swap failed');
    }
}
