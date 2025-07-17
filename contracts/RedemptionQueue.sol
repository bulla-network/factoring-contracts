// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IRedemptionQueue.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title RedemptionQueue
/// @notice Manages a FIFO queue of redemption requests for the BullaFactoring contract
/// @dev Handles both share-based redemptions and asset-based withdrawals using a head pointer for efficiency
contract RedemptionQueue is IRedemptionQueue, Ownable {
    
    // Custom errors
    error OnlyFactoringContract();
    error InvalidOwner();
    error InvalidReceiver();
    error InvalidRedemptionType();
    error InvalidQueueIndex();
    error NotAuthorized();
    error RedemptionAlreadyCancelled();
    error QueueEmpty();
    error InvalidRedemption();
    error AmountExceedsQueuedShares();
    error AmountExceedsQueuedAssets();
    
    /// @notice Array storing all queued redemptions
    QueuedRedemption[] private queue;
    
    /// @notice Index of the first valid redemption in the queue (head pointer)
    uint256 private head;
    
    /// @notice The BullaFactoring contract address that can manage the queue
    address public factoringContract;
    
    modifier onlyFactoringContract() {
        if (msg.sender != factoringContract) revert OnlyFactoringContract();
        _;
    }
    
    constructor(address owner, address _factoringContract) Ownable(owner) {
        factoringContract = _factoringContract;
        head = 0;
    }
    
    /// @inheritdoc IRedemptionQueue
    function setFactoringContract(address _factoringContract) external onlyOwner {
        factoringContract = _factoringContract;
    }
    
    /// @inheritdoc IRedemptionQueue
    function queueRedemption(
        address owner,
        address receiver,
        uint256 shares,
        uint256 assets
    ) external onlyFactoringContract returns (uint256 queueIndex) {
        if (owner == address(0)) revert InvalidOwner();
        if (receiver == address(0)) revert InvalidReceiver();
        if ((shares > 0) == (assets > 0)) revert InvalidRedemptionType();
        
        QueuedRedemption memory redemption = QueuedRedemption({
            owner: owner,
            receiver: receiver,
            shares: shares,
            assets: assets
        });
        
        queueIndex = queue.length;
        queue.push(redemption);
        
        emit RedemptionQueued(owner, receiver, shares, assets, queueIndex);
        
        return queueIndex;
    }
    
    /// @inheritdoc IRedemptionQueue
    function cancelQueuedRedemption(uint256 queueIndex) external {
        if (queueIndex >= queue.length) revert InvalidQueueIndex();
        
        QueuedRedemption storage redemption = queue[queueIndex];
        if (redemption.owner != msg.sender && msg.sender != factoringContract) revert NotAuthorized();
        if (redemption.owner == address(0)) revert RedemptionAlreadyCancelled();
        
        address owner = redemption.owner;
        
        // Mark as cancelled by setting owner to zero
        redemption.owner = address(0);
        redemption.receiver = address(0);
        redemption.shares = 0;
        redemption.assets = 0;
        
        // If this is the head item, advance head to next valid item
        if (queueIndex == head) {
            _advanceHead();
        }
        
        emit RedemptionCancelled(owner, queueIndex);
    }
    
    /// @inheritdoc IRedemptionQueue
    function removeAmountFromFirstOwner(uint256 amount) external onlyFactoringContract returns (QueuedRedemption memory nextRedemption) {
        if (isQueueEmpty()) revert QueueEmpty();
        
        uint256 currentHead = head; // Store original head for event
        QueuedRedemption storage redemption = queue[head];
        if (redemption.owner == address(0)) revert InvalidRedemption();
        
        address owner = redemption.owner;
        address receiver = redemption.receiver;
        
        if (redemption.shares > 0) {
            // Share-based redemption
            if (amount > redemption.shares) revert AmountExceedsQueuedShares();
            
            if (amount == redemption.shares) {
                // Remove entire entry by marking as processed and advancing head
                redemption.owner = address(0);
                redemption.receiver = address(0);
                redemption.shares = 0;
                _advanceHead();
            } else {
                // Reduce the amount
                redemption.shares -= amount;
            }
            
            emit RedemptionProcessed(owner, receiver, amount, 0, currentHead);
        } else if (redemption.assets > 0) {
            // Asset-based withdrawal
            if (amount > redemption.assets) revert AmountExceedsQueuedAssets();
            
            if (amount == redemption.assets) {
                // Remove entire entry by marking as processed and advancing head
                redemption.owner = address(0);
                redemption.receiver = address(0);
                redemption.assets = 0;
                _advanceHead();
            } else {
                // Reduce the amount
                redemption.assets -= amount;
            }
            
            emit RedemptionProcessed(owner, receiver, 0, amount, currentHead);
        }
        
        // Return the next redemption in queue
        return getNextRedemption();
    }
    
    /// @inheritdoc IRedemptionQueue
    function clearQueue() external onlyOwner {
        delete queue;
        head = 0;
    }
    
    /// @inheritdoc IRedemptionQueue
    function isQueueEmpty() public view returns (bool isEmpty) {
        return head >= queue.length;
    }
    
    /// @inheritdoc IRedemptionQueue
    function getQueueLength() external view returns (uint256 queueLength) {
        if (head >= queue.length) return 0;
        
        // Count active (non-cancelled) items from head onwards
        uint256 activeCount = 0;
        for (uint256 i = head; i < queue.length; i++) {
            if (queue[i].owner != address(0)) {
                activeCount++;
            }
        }
        return activeCount;
    }
    
    /// @inheritdoc IRedemptionQueue
    function getQueuedRedemption(uint256 queueIndex) external view returns (QueuedRedemption memory redemption) {
        if (queueIndex >= queue.length) revert InvalidQueueIndex();
        return queue[queueIndex];
    }
    
    /// @inheritdoc IRedemptionQueue
    function getQueuedRedemptionsForOwner(address owner) external view returns (uint256[] memory queueIndexes) {
        uint256 validCount = 0;
        
        // Count valid positions for this owner from head onwards
        for (uint256 i = head; i < queue.length; i++) {
            if (queue[i].owner == owner) {
                validCount++;
            }
        }
        
        // Build result array
        queueIndexes = new uint256[](validCount);
        uint256 resultIndex = 0;
        
        for (uint256 i = head; i < queue.length; i++) {
            if (queue[i].owner == owner) {
                queueIndexes[resultIndex] = i;
                resultIndex++;
            }
        }
        
        return queueIndexes;
    }
    
    /// @inheritdoc IRedemptionQueue
    function getTotalQueuedForOwner(address owner) external view returns (uint256 totalShares, uint256 totalAssets) {
        for (uint256 i = head; i < queue.length; i++) {
            if (queue[i].owner == owner) {
                totalShares += queue[i].shares;
                totalAssets += queue[i].assets;
            }
        }
        
        return (totalShares, totalAssets);
    }
    
    /// @inheritdoc IRedemptionQueue
    function getNextRedemption() public view returns (QueuedRedemption memory redemption) {
        if (isQueueEmpty()) {
            return QueuedRedemption(address(0), address(0), 0, 0);
        }
        return queue[head];
    }

    /// @inheritdoc IRedemptionQueue
    function getQueueStats() external view returns (uint256 queueLength, uint256 totalShares, uint256 totalAssets) {
        queueLength = isQueueEmpty() ? 0 : queue.length - head;
        
        for (uint256 i = head; i < queue.length; i++) {
            totalShares += queue[i].shares;
            totalAssets += queue[i].assets;
        }
        
        return (queueLength, totalShares, totalAssets);
    }

    // Internal functions
    
    /// @notice Advances the head pointer to the next valid (non-cancelled) redemption
    /// @dev Called when the current head item is removed or cancelled
    function _advanceHead() private {
        // Move head forward until we find a valid redemption or reach the end
        while (head < queue.length && queue[head].owner == address(0)) {
            head++;
        }
    }
    
    /// @notice Compacts the queue by removing processed items before the head
    /// @dev Can be called to clean up memory and reduce gas costs for subsequent operations
    function compactQueue() external onlyOwner {
        if (head == 0) return; // Nothing to compact
        
        // Count active redemptions from head onwards
        uint256 activeCount = 0;
        for (uint256 i = head; i < queue.length; i++) {
            if (queue[i].owner != address(0)) {
                activeCount++;
            }
        }
        
        // Create new array with only active redemptions
        QueuedRedemption[] memory newQueue = new QueuedRedemption[](activeCount);
        uint256 newIndex = 0;
        
        for (uint256 i = head; i < queue.length; i++) {
            if (queue[i].owner != address(0)) {
                newQueue[newIndex] = queue[i];
                newIndex++;
            }
        }
        
        // Replace the queue and reset head
        queue = newQueue;
        head = 0;
    }
} 