// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ISeloraPool {
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
}
