// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IRedemptionQueue
/// @notice Interface for a redemption queue that manages pending redemptions when pool liquidity is insufficient
/// @dev Handles both share-based redemptions and asset-based withdrawals in FIFO order
interface IRedemptionQueue {
    /// @notice Represents a queued redemption request
    struct QueuedRedemption {
        address owner;
        address receiver;
        uint256 shares;  // For share-based redemptions (> 0 for redemption, 0 for withdrawal)
        uint256 assets;  // For asset-based withdrawals (> 0 for withdrawal, 0 for redemption)
    }

    // Events
    event RedemptionQueued(
        address indexed owner,
        address indexed receiver,
        uint256 shares,
        uint256 assets,
        uint256 queueIndex
    );
    
    event RedemptionProcessed(
        address indexed owner,
        address indexed receiver,
        uint256 shares,
        uint256 assets,
        uint256 queueIndex
    );
    
    event RedemptionCancelled(
        address indexed owner,
        uint256 queueIndex
    );

    // Queue management functions
    
    /// @notice Queue a redemption request when insufficient liquidity is available
    /// @param owner The owner of the shares/assets being redeemed
    /// @param receiver The address to receive the redeemed assets
    /// @param shares Amount of shares to redeem (0 for asset-based withdrawals)
    /// @param assets Amount of assets to withdraw (0 for share-based redemptions)
    /// @return queueIndex The position in the queue
    function queueRedemption(
        address owner,
        address receiver,
        uint256 shares,
        uint256 assets
    ) external returns (uint256 queueIndex);

    /// @notice Allow a user to cancel their queued redemption request
    /// @param queueIndex The index of the redemption to cancel
    function cancelQueuedRedemption(uint256 queueIndex) external;

    /// @notice Remove a specific amount from the first queued redemption
    /// @dev If amount equals the total queued amount, removes the entire entry
    /// @dev If amount is less than total, reduces the queued amount  
    /// @param amount The amount to remove (shares or assets depending on redemption type)
    /// @return nextRedemption The next redemption in line to be processed
    function removeAmountFromFirstOwner(uint256 amount) external returns (QueuedRedemption memory nextRedemption);

    /// @notice Set the factoring contract address that can manage the queue
    /// @param _factoringContract The new factoring contract address
    function setFactoringContract(address _factoringContract) external;

    /// @notice Emergency function to clear the entire queue (owner only)
    function clearQueue() external;

    // View functions
    
    /// @notice Check if the redemption queue is empty
    /// @return isEmpty True if the queue is empty
    function isQueueEmpty() external view returns (bool isEmpty);

    /// @notice Get the total length of the redemption queue
    /// @return queueLength Number of queued redemptions
    function getQueueLength() external view returns (uint256 queueLength);

    /// @notice Get a specific queued redemption by index
    /// @param queueIndex The index of the redemption to retrieve
    /// @return redemption The queued redemption at the specified index
    function getQueuedRedemption(uint256 queueIndex) external view returns (QueuedRedemption memory redemption);

    /// @notice Get all queue indexes for a specific owner
    /// @param owner The owner to search for
    /// @return queueIndexes Array of queue indexes where the owner has queued redemptions
    function getQueuedRedemptionsForOwner(address owner) external view returns (uint256[] memory queueIndexes);

    /// @notice Get the total queued shares and assets for a specific owner
    /// @param owner The owner to check
    /// @return totalShares Total shares queued for redemption
    /// @return totalAssets Total assets queued for withdrawal
    function getTotalQueuedForOwner(address owner) external view returns (uint256 totalShares, uint256 totalAssets);

    /// @notice Get the next redemption in line to be processed
    /// @return redemption The next queued redemption, or empty struct if queue is empty
    function getNextRedemption() external view returns (QueuedRedemption memory redemption);

    /// @notice Compacts the queue by removing processed items before the head
    /// @dev Can be called to clean up memory and reduce gas costs for subsequent operations
    function compactQueue() external;

    /// @notice Gets the total queue statistics including length and totals
    /// @return queueLength The number of active redemptions in the queue
    /// @return totalShares The total shares queued for redemption  
    /// @return totalAssets The total assets queued for withdrawal
    function getQueueStats() external view returns (uint256 queueLength, uint256 totalShares, uint256 totalAssets);
} 