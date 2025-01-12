// SPDX-License-Identifier: MIT
pragma solidity >=0.6.6;
pragma experimental ABIEncoderV2;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";

/* Internal Imports */
import {DataTypes as dt} from "./DataTypes.sol";
import {MerkleUtils} from "./MerkleUtils.sol";
import {TransitionEvaluator} from "./TransitionEvaluator.sol";
import {TokenRegistry} from "./TokenRegistry.sol";
import {ValidatorRegistry} from "./ValidatorRegistry.sol";

contract RollupChain {
    using SafeMath for uint256;

    /* Fields */
    // The state transition evaluator
    TransitionEvaluator transitionEvaluator;
    // The Merkle Tree library (currently a contract for ease of testing)
    MerkleUtils merkleUtils;
    // The token registry
    TokenRegistry tokenRegistry;
    // The validator registry
    ValidatorRegistry validatorRegistry;
    // All the blocks!
    dt.Block[] public blocks;
    bytes32 public constant ZERO_BYTES32 =
        0x0000000000000000000000000000000000000000000000000000000000000000;
    // State tree height
    uint256 constant STATE_TREE_HEIGHT = 32;
    // TODO: Set a reasonable wait period
    uint256 constant WITHDRAW_WAIT_PERIOD = 0;

    address public committerAddress;

    /* Events */
    event RollupBlockCommitted(uint256 blockNumber, bytes[] transitions);
    event Transition(bytes data);
    event DecodedTransition(bool success, bytes returnData);

    /***************
     * Constructor *
     **************/
    constructor(
        address _transitionEvaluatorAddress,
        address _merkleUtilsAddress,
        address _tokenRegistryAddress,
        address _validatorRegistryAddress,
        address _committerAddress
    ) public {
        transitionEvaluator = TransitionEvaluator(_transitionEvaluatorAddress);
        merkleUtils = MerkleUtils(_merkleUtilsAddress);
        tokenRegistry = TokenRegistry(_tokenRegistryAddress);
        validatorRegistry = ValidatorRegistry(_validatorRegistryAddress);
        committerAddress = _committerAddress;
    }

    modifier onlyValidatorRegistry() {
        require(
            msg.sender == address(validatorRegistry),
            "Only validator registry may perform action"
        );
        _;
    }

    /* Methods */

    // 欺诈证明生效后，剪掉无效块后面的块
    function pruneBlocksAfter(uint256 _blockNumber) internal {
        for (uint256 i = _blockNumber; i < blocks.length; i++) {
            delete blocks[i];
        }
    }

    function getCurrentBlockNumber() public view returns (uint256) {
        return blocks.length - 1;
    }

    // 验证者注册中心切换当前提交者
    function setCommitterAddress(
        address _committerAddress
    ) external onlyValidatorRegistry {
        committerAddress = _committerAddress;
    }

    /**
     * Commits a new block which is then rolled up.
     */
    function commitBlock(
        uint256 _blockNumber,
        bytes[] calldata _transitions,
        bytes[] calldata _signatures
    ) external returns (bytes32) {
        require(
            msg.sender == committerAddress,
            "Only the committer may submit blocks"
        );
        require(_blockNumber == blocks.length, "Wrong block number");
        // 验证来自链下节点提交的区块签名，包含了其它验证者的签名，且需达到一定数量
        require(
            validatorRegistry.checkSignatures(
                _blockNumber,
                _transitions,
                _signatures
            ),
            "Failed signature check"
        );

        // Emit transition, for debugging
        for (uint256 i = 0; i < _transitions.length; i++) {
            emit Transition(_transitions[i]);
        }
        // 一堆bytes作为叶子节点，求hash root
        bytes32 root = merkleUtils.getMerkleRoot(_transitions);
        dt.Block memory rollupBlock = dt.Block({
            rootHash: root,
            blockSize: _transitions.length
        });
        // 因为乐观，所以直接push
        blocks.push(rollupBlock);
        // NOTE: Toggle the event if you'd like easier historical block queries
        emit RollupBlockCommitted(_blockNumber, _transitions);

        validatorRegistry.pickNextCommitter();
        return root;
    }

    /**********************
     * Proving Invalidity *
     *********************/

    /**
     * Verify inclusion of the claimed includedStorageSlot & store their results.
     * Note the complexity here is we need to store an empty storage slot as being 32 bytes of zeros
     * to be what the sparse merkle tree expects.
     */
    function verifyAndStoreStorageSlotInclusionProof(
        dt.IncludedStorageSlot memory _includedStorageSlot
    ) private {
        bytes memory accountInfoBytes = getAccountInfoBytes(
            _includedStorageSlot.storageSlot.value
        );
        merkleUtils.verifyAndStore(
            accountInfoBytes,
            uint256(_includedStorageSlot.storageSlot.slotIndex),
            _includedStorageSlot.siblings
        );
    }

    function getStateRootAndStorageSlots(
        bytes memory _transition
    ) public returns (bool, bytes32, uint256[] memory) {
        bool success;
        bytes memory returnData;
        bytes32 stateRoot;
        uint256[] memory storageSlots;
        (success, returnData) = address(transitionEvaluator).call(
            abi.encodeWithSelector(
                transitionEvaluator
                    .getTransitionStateRootAndAccessList
                    .selector,
                _transition
            )
        );
        // Emit the output as an event, for debugging
        emit DecodedTransition(success, returnData);
        // If the call was successful let's decode!
        if (success) {
            (stateRoot, storageSlots) = abi.decode(
                (returnData),
                (bytes32, uint256[])
            );
        }
        return (success, stateRoot, storageSlots);
    }

    function getStateRootsAndStorageSlots(
        bytes memory _preStateTransition,
        bytes memory _invalidTransition
    ) public returns (bool, bytes32, bytes32, uint256[] memory) {
        bool success;
        bytes memory returnData;
        bytes32 preStateRoot;
        bytes32 postStateRoot;
        uint256[] memory preStateStorageSlots;
        uint256[] memory storageSlots;
        // First decode the prestate root
        (success, returnData) = address(transitionEvaluator).call(
            abi.encodeWithSelector(
                transitionEvaluator
                    .getTransitionStateRootAndAccessList
                    .selector,
                _preStateTransition
            )
        );
        // Emit the output as an event, for debugging
        emit DecodedTransition(success, returnData);
        // Make sure the call was successful
        require(
            success,
            "If the preStateRoot is invalid, then prove that invalid instead!"
        );
        (preStateRoot, preStateStorageSlots) = abi.decode(
            (returnData),
            (bytes32, uint256[])
        );
        // Now that we have the prestateRoot, let's decode the postState
        (success, returnData) = address(transitionEvaluator).call(
            abi.encodeWithSelector(
                transitionEvaluator
                    .getTransitionStateRootAndAccessList
                    .selector,
                _invalidTransition
            )
        );
        // Emit the output as an event, for debugging
        emit DecodedTransition(success, returnData);
        // If the call was successful let's decode!
        if (success) {
            (postStateRoot, storageSlots) = abi.decode(
                (returnData),
                (bytes32, uint256[])
            );
        }
        return (success, preStateRoot, postStateRoot, storageSlots);
    }

    function verifyWithdrawTransition(
        address _account,
        dt.IncludedTransition memory _includedTransition
    ) public view returns (bool) {
        require(
            checkTransitionInclusion(_includedTransition),
            "Withdraw transition must be included"
        );
        require(
            transitionEvaluator.verifyWithdrawTransition(
                _account,
                _includedTransition.transition
            ),
            "Withdraw signature is invalid"
        );

        require(
            getCurrentBlockNumber() -
                _includedTransition.inclusionProof.blockNumber >=
                WITHDRAW_WAIT_PERIOD,
            "Withdraw wait period not passed"
        );
        return true;
    }

    /**
     * Checks if a transition is invalid and if it is prunes that block and it's children from the chain.
     */
    function proveTransitionInvalid(
        dt.IncludedTransition memory _preStateIncludedTransition,
        dt.IncludedTransition memory _invalidIncludedTransition,
        dt.IncludedStorageSlot[] memory _transitionStorageSlots
    ) public {
        // For convenience store the transitions
        bytes memory preStateTransition = _preStateIncludedTransition
            .transition;
        bytes memory invalidTransition = _invalidIncludedTransition.transition;

        /********* #1: CHECK_SEQUENTIAL_TRANSITIONS *********/
        // First verify that the transitions are sequential
        verifySequentialTransitions(
            _preStateIncludedTransition,
            _invalidIncludedTransition
        );

        /********* #2: DECODE_TRANSITIONS *********/
        // Decode our transitions and determine which storage slots we'll need in order to validate the transition
        (
            bool success,
            bytes32 preStateRoot,
            bytes32 postStateRoot,
            uint256[] memory storageSlotIndexes
        ) = getStateRootsAndStorageSlots(preStateTransition, invalidTransition);
        // If not success something went wrong with the decoding...
        if (!success) {
            // Prune the block if it has an incorrectly encoded transition!
            pruneBlocksAfter(
                _invalidIncludedTransition.inclusionProof.blockNumber
            );
            return;
        }

        /********* #3: VERIFY_TRANSITION_STORAGE_SLOTS *********/
        // Make sure the storage slots we were given are correct
        for (uint256 i = 0; i < _transitionStorageSlots.length; i++) {
            require(
                _transitionStorageSlots[i].storageSlot.slotIndex ==
                    storageSlotIndexes[i],
                "Supplied storage slot index is incorrect!"
            );
        }

        /********* #4: STORE_STORAGE_INCLUSION_PROOFS *********/
        // Now verify and store the storage inclusion proofs
        merkleUtils.setMerkleRootAndHeight(preStateRoot, STATE_TREE_HEIGHT);
        for (uint256 i = 0; i < _transitionStorageSlots.length; i++) {
            verifyAndStoreStorageSlotInclusionProof(_transitionStorageSlots[i]);
        }

        /********* #5: EVALUATE_TRANSITION *********/
        // Now that we've verified and stored our storage in the state tree, lets apply the transaction
        // To do this first let's pull out the storage slots we care about
        dt.StorageSlot[] memory storageSlots = new dt.StorageSlot[](
            _transitionStorageSlots.length
        );
        for (uint256 i = 0; i < _transitionStorageSlots.length; i++) {
            storageSlots[i] = _transitionStorageSlots[i].storageSlot;
        }

        bytes memory returnData;
        // Make the external call
        (success, returnData) = address(transitionEvaluator).call(
            abi.encodeWithSelector(
                transitionEvaluator.evaluateTransition.selector,
                invalidTransition,
                storageSlots
            )
        );

        // Check if it was successful. If not, we've got to prune.
        if (!success) {
            pruneBlocksAfter(
                _invalidIncludedTransition.inclusionProof.blockNumber
            );
            return;
        }
        // It was successful so let's decode the outputs to get the new leaf nodes we'll have to insert
        bytes32[] memory outputs = abi.decode((returnData), (bytes32[]));

        /********* #6: UPDATE_STATE_ROOT *********/
        // Now we need to check if the state root is incorrect, to do this we first insert the new leaf values
        for (uint256 i = 0; i < _transitionStorageSlots.length; i++) {
            merkleUtils.updateLeaf(
                outputs[i],
                _transitionStorageSlots[i].storageSlot.slotIndex
            );
        }

        /********* #7: COMPARE_STATE_ROOTS *********/
        // Check if the calculated state root equals what we expect
        if (postStateRoot != merkleUtils.getRoot()) {
            // Prune the block because we found an invalid post state root! Cryptoeconomic validity ftw!
            pruneBlocksAfter(
                _invalidIncludedTransition.inclusionProof.blockNumber
            );
            return;
        }

        // Woah! Looks like there's no fraud!
        revert("No fraud detected!");
    }

    /**
     * Verifies that two transitions were included one after another.
     * This is used to make sure we are comparing the correct
     * prestate & poststate.
     */
    function verifySequentialTransitions(
        dt.IncludedTransition memory _transition0,
        dt.IncludedTransition memory _transition1
    ) public view returns (bool) {
        // Verify inclusion
        require(
            checkTransitionInclusion(_transition0),
            "The first transition must be included!"
        );
        require(
            checkTransitionInclusion(_transition1),
            "The second transition must be included!"
        );

        // Verify that the two transitions are one after another

        // Start by checking if they are in the same block
        if (
            _transition0.inclusionProof.blockNumber ==
            _transition1.inclusionProof.blockNumber
        ) {
            // If the blocknumber is the same, simply check that transition0 preceeds transition1
            require(
                _transition0.inclusionProof.transitionIndex ==
                    _transition1.inclusionProof.transitionIndex - 1,
                "Transitions must be sequential!"
            );
            // Hurray! The transition is valid!
            return true;
        }

        // If not in the same block, we check that:
        // 0) the blocks are one after another
        require(
            _transition0.inclusionProof.blockNumber ==
                _transition1.inclusionProof.blockNumber - 1,
            "Blocks must be one after another or equal."
        );
        // 1) the transitionIndex of transition0 is the last in the block; and
        require(
            _transition0.inclusionProof.transitionIndex ==
                blocks[_transition0.inclusionProof.blockNumber].blockSize - 1,
            "_transition0 must be last in its block."
        );
        // 2) the transitionIndex of transition1 is the first in the block
        require(
            _transition1.inclusionProof.transitionIndex == 0,
            "_transition0 must be first in its block."
        );

        // Success!
        return true;
    }

    /**
     * Check to see if a transition was indeed included.
     */
    function checkTransitionInclusion(
        dt.IncludedTransition memory _includedTransition
    ) public view returns (bool) {
        bytes32 rootHash = blocks[
            _includedTransition.inclusionProof.blockNumber
        ].rootHash;
        bool isIncluded = merkleUtils.verify(
            rootHash,
            _includedTransition.transition,
            _includedTransition.inclusionProof.transitionIndex,
            _includedTransition.inclusionProof.siblings
        );
        return isIncluded;
    }

    /**
     * Get the hash of the transition.
     */
    function getTransitionHash(
        bytes memory _transition
    ) public pure returns (bytes32) {
        return keccak256(_transition);
    }

    /**
     * Get the bytes value for this storage.
     */
    function getAccountInfoBytes(
        dt.AccountInfo memory _accountInfo
    ) public pure returns (bytes memory) {
        // If it's an empty storage slot, return 32 bytes of zeros (empty value)
        if (
            _accountInfo.account ==
            0x0000000000000000000000000000000000000000 &&
            _accountInfo.balances.length == 0 &&
            _accountInfo.transferNonces.length == 0 &&
            _accountInfo.withdrawNonces.length == 0
        ) {
            return abi.encodePacked(uint256(0));
        }
        // Here we don't use `abi.encode([struct])` because it's not clear
        // how to generate that encoding client-side.
        return
            abi.encode(
                _accountInfo.account,
                _accountInfo.balances,
                _accountInfo.transferNonces,
                _accountInfo.withdrawNonces
            );
    }
}
