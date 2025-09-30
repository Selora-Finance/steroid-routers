pragma solidity ^0.8.0;

interface IBaseRouter {
    function query(address tokenA, address tokenB, uint256 amountIn) external view returns (uint256);

    function swap(address tokenA, address tokenB, address to, uint256 amountIn, uint256 amountOut) external;

    function routerId() external view returns (bytes32);

    error InsufficientAmountOut(uint256 expected, uint256 received);

    event Swap(address indexed tokenA, address indexed tokenB, uint256 indexed amountIn, uint256 amountOut);
}
