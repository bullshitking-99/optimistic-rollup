// SPDX-License-Identifier: MIT
pragma solidity >=0.6.6;
pragma experimental ABIEncoderV2;

import "openzeppelin-solidity/contracts/access/Ownable.sol";
import "openzeppelin-solidity/contracts/cryptography/ECDSA.sol";
import {RollupChain} from "./RollupChain.sol";

/// @title 链上区块验证者注册中心
/// @notice 验证transition后的交易正确
/// @dev 似乎
contract ValidatorRegistry is Ownable {
    address[] public validators;
    address public currentCommitter;
    uint256 private currentCommitterIndex;
    RollupChain rollupChain;

    event CommitterChanged(address newCommitter);

    // 仅被链上合约调用
    modifier onlyRollupChain() {
        require(
            msg.sender == address(rollupChain),
            "Only RollupChain may perform action"
        );
        _;
    }

    constructor(address[] memory _validators) public {
        validators = _validators;
    }

    function setRollupChainAddress(
        address _rollupChainAddress
    ) external onlyOwner {
        rollupChain = RollupChain(_rollupChainAddress);
        // 更换主合约后重置验证轮
        resetValidators(validators);
    }

    function setValidators(address[] calldata _validators) external onlyOwner {
        resetValidators(_validators);
    }

    // 重置验证轮
    function resetValidators(address[] memory _validators) internal {
        require(_validators.length > 0, "Empty validator set");
        require(address(rollupChain) != address(0), "RollupChain not set");

        validators = _validators;
        currentCommitterIndex = 0;
        currentCommitter = validators[0];
        emit CommitterChanged(currentCommitter);
        rollupChain.setCommitterAddress(currentCommitter);
    }

    // committer 提交区块时验证签名
    function checkSignatures(
        uint256 _blockNumber,
        bytes[] calldata _transitions,
        bytes[] calldata _signatures
    ) external view onlyRollupChain returns (bool) {
        uint256 numValidators = validators.length;
        uint256 numSignatures;
        for (uint256 i = 0; i < numValidators; i++) {
            bytes32 blockHash = keccak256(
                abi.encode(_blockNumber, _transitions)
            );
            bytes32 prefixedHash = ECDSA.toEthSignedMessageHash(blockHash);
            require(
                ECDSA.recover(prefixedHash, _signatures[i]) == validators[i],
                "Signature is invalid!"
            );
            numSignatures++;
        }

        // TODO 修复这个错误逻辑 所谓小于4 没道理 三目运算符也没必要
        // Require signatures from all the validators if less than 4, or 2/3 of
        // the validators if at least 4.
        bool hasEnoughSignatures = numValidators < 4
            ? numSignatures == numValidators
            : numSignatures * 3 > numValidators * 2;
        require(hasEnoughSignatures, "Not enough signatures");
        return true;
    }

    // round-robin 轮换交易提交者
    function pickNextCommitter() external onlyRollupChain {
        currentCommitterIndex = (currentCommitterIndex + 1) % validators.length;
        currentCommitter = validators[currentCommitterIndex];
        emit CommitterChanged(currentCommitter);
        rollupChain.setCommitterAddress(currentCommitter);
    }
}
