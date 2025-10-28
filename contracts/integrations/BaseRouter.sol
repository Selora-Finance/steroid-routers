pragma solidity ^0.8.0;

import {IBaseRouter} from './interfaces/IBaseRouter.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

abstract contract BaseRouter is IBaseRouter, Ownable {
    using SafeERC20 for IERC20;

    modifier onlyContract() {
        require(msg.sender.code.length > 0);
        _;
    }

    constructor() Ownable(msg.sender) {}

    function _query(address tokenA, address tokenB, uint256 amountIn) internal view virtual returns (uint256);

    function _swap(
        address tokenA,
        address tokenB,
        address to,
        uint256 amountIn,
        uint256 amountOut,
        uint256 deadline
    ) internal virtual;

    function query(address tokenA, address tokenB, uint256 amountIn) public view returns (uint256 amountOut) {
        amountOut = _query(tokenA, tokenB, amountIn);
    }

    function swap(
        address tokenA,
        address tokenB,
        address to,
        uint256 amountIn,
        uint256 amountOut,
        uint256 deadline
    ) external onlyContract {
        // Transfer token A from caller to the router
        IERC20(tokenA).transferFrom(msg.sender, address(this), amountIn);
        uint256 balanceBefore = IERC20(tokenB).balanceOf(to);
        _swap(tokenA, tokenB, to, amountIn, amountOut, deadline);
        uint256 balanceAfter = IERC20(tokenB).balanceOf(to);
        uint256 amountReceived = balanceAfter - balanceBefore;

        if (amountReceived < amountOut) revert InsufficientAmountOut(amountOut, amountReceived);

        emit Swap(tokenA, tokenB, amountIn, amountReceived);
    }

    function sendOutERC20(IERC20 token, address to, uint256 amount) external onlyOwner returns (bool) {
        return token.transfer(to, amount);
    }
}
