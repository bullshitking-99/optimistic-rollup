// SPDX-License-Identifier: MIT
pragma solidity >=0.6.6;

import "openzeppelin-solidity/contracts/access/Ownable.sol";

// 既然有以太，为什么还需要内置token
// 核心点：以太的交易需在主链确认，故侧链为了low latency & gas fee 需要自己的token在内部快速共识
contract TokenRegistry is Ownable {
    // token有自己的index和address
    mapping(address => uint256) public tokenAddressToTokenIndex;
    mapping(uint256 => address) public tokenIndexToTokenAddress;
    uint256 numTokens = 0;

    event TokenRegistered(
        address indexed tokenAddress,
        uint256 indexed tokenIndex
    );

    function registerToken(address _tokenAddress) external onlyOwner {
        // Register token with an index if it isn't already
        // address有效且不存在于当前状态
        if (
            _tokenAddress != address(0) &&
            tokenAddressToTokenIndex[_tokenAddress] == 0
        ) {
            tokenAddressToTokenIndex[_tokenAddress] = numTokens;
            tokenIndexToTokenAddress[numTokens] = _tokenAddress;
            emit TokenRegistered(_tokenAddress, numTokens);
            numTokens++;
        }
    }
}
