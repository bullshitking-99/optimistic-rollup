pragma solidity ^0.6.6;

// OpenZeppelin/Contracts 是一个用于安全智能合约开发的库。
// 它提供了ERC20、 ERC721、ERC777、ERC1155 等标准的实现
// 还提供Solidity 组件来构建自定义合同和更复杂的分散系统。

// 访问控制 ownable 只有合约管理员才能调用
import "openzeppelin-solidity/contracts/access/Ownable.sol";
// 椭圆曲线算法签名
import "openzeppelin-solidity/contracts/cryptography/ECDSA.sol";

// 继承了"Ownable"合约
contract AccountRegistry is Ownable {
    // 存储已注册账户的地址
    mapping(address => bool) public registeredAccounts;

    // 在账户注册时进行触发
    event AccountRegistered(address account);

    // 外部函数，用于注册账户。
    // 该函数接收两个参数："_account"和"_signature"。
    // "_account"参数是需要注册的账户地址，"_signature"参数是用于签名验证的字节数组
    function registerAccount(
        address _account,
        bytes calldata _signature
    ) external {
        require(!registeredAccounts[_account], "Account already registered");
        // 签名验证
        // 计算一个消息哈希，该哈希是通过使用当前合约地址和字符串"registerAccount"进行编码
        bytes32 messageHash = keccak256(
            abi.encodePacked(address(this), "registerAccount")
        );
        // 将该哈希进行签名
        bytes32 prefixedHash = ECDSA.toEthSignedMessageHash(messageHash);
        // 将签名结果与传入的"_signature"进行比较，以验证签名的有效性
        require(
            ECDSA.recover(prefixedHash, _signature) == _account,
            "Register signature is invalid!"
        );
        registeredAccounts[_account] = true;
        emit AccountRegistered(_account);
    }
}
