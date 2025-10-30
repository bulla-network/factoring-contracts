// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;
import './BullaFactoring.sol';
import './interfaces/IRedemptionQueue.sol';

contract BullaFactoringAutomationCheckerV2_1 {
    mapping(address => uint256) public lastReconcileBlock;
    mapping(address => uint256) public lastQueueProcessBlock;

    error ReconcileAlreadyProcessed();
    error RedemptionQueueAlreadyProcessed();

    function checkerReconcile(address poolAddress)
        external
        view
        returns (bool canExec, bytes memory execPayload)
    {
        BullaFactoringV2_1 factoring = BullaFactoringV2_1(poolAddress);
        (uint256[] memory paidInvoices, , uint256[] memory impairedInvoices, ) = factoring.viewPoolStatus();

        if (paidInvoices.length + impairedInvoices.length == 0) {
            return (false, bytes(''));
        }

        execPayload = abi.encodeCall(BullaFactoringAutomationCheckerV2_1.executeReconcile, (poolAddress));
        canExec = true;
    }

    function executeReconcile(address poolAddress) external {
        BullaFactoringV2_1 factoring = BullaFactoringV2_1(poolAddress);

        if (lastReconcileBlock[poolAddress] == block.number) {
            revert ReconcileAlreadyProcessed();
        }

        lastReconcileBlock[poolAddress] = block.number;

        factoring.reconcileActivePaidInvoices();
    }

    function checkerProcessRedemptionQueue(address poolAddress)
        external
        view
        returns (bool canExec, bytes memory execPayload)
    {
        BullaFactoringV2_1 factoring = BullaFactoringV2_1(poolAddress);
        (uint256[] memory paidInvoices, , , ) = factoring.viewPoolStatus();

        if (paidInvoices.length > 0) {
            return (false, bytes(''));
        }

        IRedemptionQueue queue = factoring.getRedemptionQueue();
        IRedemptionQueue.QueuedRedemption memory nextRedemption = queue.getNextRedemption();

        if (nextRedemption.owner == address(0)) {
            return (false, bytes(''));
        }

        uint256 totalAssets = factoring.totalAssets();
        if (totalAssets == 0) {
            return (false, bytes(''));
        }

        if (nextRedemption.shares > 0) {
            uint256 ownerBalance = factoring.balanceOf(nextRedemption.owner);
            if (ownerBalance < nextRedemption.shares) {
                return (false, bytes(''));
            }

            uint256 maxShares = factoring.maxRedeem(nextRedemption.owner);
            if (maxShares < nextRedemption.shares) {
                return (false, bytes(''));
            }

            uint256 assetsNeeded = factoring.previewRedeem(nextRedemption.shares);
            if (assetsNeeded == 0 || assetsNeeded > totalAssets) {
                return (false, bytes(''));
            }
        } else if (nextRedemption.assets > 0) {
            uint256 maxAssets = factoring.maxWithdraw(nextRedemption.owner);
            if (maxAssets < nextRedemption.assets) {
                return (false, bytes(''));
            }

            if (nextRedemption.assets > totalAssets) {
                return (false, bytes(''));
            }
        } else {
            return (false, bytes(''));
        }
        
        execPayload = abi.encodeCall(BullaFactoringAutomationCheckerV2_1.executeProcessRedemptionQueue, (poolAddress));
        canExec = true;
    }

    function executeProcessRedemptionQueue(address poolAddress) external {
        BullaFactoringV2_1 factoring = BullaFactoringV2_1(poolAddress);

        if (lastQueueProcessBlock[poolAddress] == block.number) {
            revert RedemptionQueueAlreadyProcessed();
        }

        lastQueueProcessBlock[poolAddress] = block.number;

        factoring.processRedemptionQueue();
    }
}