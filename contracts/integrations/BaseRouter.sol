pragma solidity ^0.8.0;

import {IBaseRouter} from './interfaces/IBaseRouter.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

abstract contract BaseRouter is IBaseRouter {
    modifier onlyContract() {
        require(msg.sender.code.length > 0);
        _;
    }

    function _query(address tokenA, address tokenB, uint256 amountIn) internal view virtual returns (uint256);

    function _swap(address tokenA, address tokenB, address to, uint256 amountIn, uint256 amountOut) internal virtual;

    function query(address tokenA, address tokenB, uint256 amountIn) public view returns (uint256 amountOut) {
        amountOut = _query(tokenA, tokenB, amountIn);
    }

    function swap(
        address tokenA,
        address tokenB,
        address to,
        uint256 amountIn,
        uint256 amountOut
    ) external onlyContract {
        uint256 balanceBefore = IERC20(tokenB).balanceOf(to);
        _swap(tokenA, tokenA, to, amountIn, amountOut);
        uint256 balanceAfter = IERC20(tokenB).balanceOf(to);
        uint256 amountReceived = balanceAfter - balanceBefore;

        if (amountReceived < amountOut) revert InsufficientAmountOut(amountOut, amountReceived);

        emit Swap(tokenA, tokenB, amountIn, amountReceived);
    }

    function routerId() public view virtual returns (bytes32);
}
