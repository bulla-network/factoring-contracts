// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@bulla-network/contracts/contracts/interfaces/IBullaClaim.sol";

contract MockBullaClaim is ERC721, IBullaClaim {
    using SafeERC20 for IERC20;

    uint256 private _tokenIdCounter = 1;
    mapping(uint256 => Claim) private _claims;

    constructor() ERC721("MockBullaClaim", "MBC") {}

    function createClaim(
        address creditor,
        address debtor,
        string memory description,
        uint256 claimAmount,
        uint256 dueBy,
        address claimToken,
        Multihash calldata attachment
    ) external returns (uint256 newTokenId) {
        newTokenId = _tokenIdCounter++;
        
        _claims[newTokenId] = Claim({
            claimAmount: claimAmount,
            paidAmount: 0,
            status: Status.Pending,
            dueBy: dueBy,
            debtor: debtor,
            claimToken: claimToken,
            attachment: attachment
        });

        _mint(creditor, newTokenId);

        emit ClaimCreated(
            address(0), // bullaManager
            newTokenId,
            address(0), // parent
            creditor,
            debtor,
            msg.sender, // origin
            description,
            _claims[newTokenId],
            block.timestamp
        );

        return newTokenId;
    }

    function createClaimWithURI(
        address creditor,
        address debtor,
        string memory description,
        uint256 claimAmount,
        uint256 dueBy,
        address claimToken,
        Multihash calldata attachment,
        string calldata _tokenUri
    ) external returns (uint256 newTokenId) {
        newTokenId = this.createClaim(creditor, debtor, description, claimAmount, dueBy, claimToken, attachment);
        // Note: In a full implementation, you'd set the token URI here
        return newTokenId;
    }

    function payClaim(uint256 tokenId, uint256 paymentAmount) external {
        Claim storage claim = _claims[tokenId];
        require(claim.claimToken != address(0), "Claim does not exist");
        require(claim.status == Status.Pending || claim.status == Status.Repaying, "Cannot pay this claim");
        require(paymentAmount > 0, "Payment amount must be greater than 0");

        IERC20(claim.claimToken).safeTransferFrom(msg.sender, ownerOf(tokenId), paymentAmount);
        
        claim.paidAmount += paymentAmount;
        
        if (claim.paidAmount >= claim.claimAmount) {
            claim.status = Status.Paid;
        } else {
            claim.status = Status.Repaying;
        }

        emit ClaimPayment(
            address(0), // bullaManager
            tokenId,
            claim.debtor,
            msg.sender, // paidBy
            msg.sender, // paidByOrigin
            paymentAmount,
            block.timestamp
        );
    }

    function rejectClaim(uint256 tokenId) external {
        Claim storage claim = _claims[tokenId];
        require(claim.claimToken != address(0), "Claim does not exist");
        require(msg.sender == claim.debtor, "Only debtor can reject claim");
        require(claim.status == Status.Pending, "Can only reject pending claims");

        claim.status = Status.Rejected;

        emit ClaimRejected(
            address(0), // bullaManager
            tokenId,
            block.timestamp
        );
    }

    function rescindClaim(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "Only creditor can rescind claim");
        Claim storage claim = _claims[tokenId];
        require(claim.status == Status.Pending, "Can only rescind pending claims");

        claim.status = Status.Rescinded;

        emit ClaimRescinded(
            address(0), // bullaManager
            tokenId,
            block.timestamp
        );
    }

    function getClaim(uint256 tokenId) external view returns (Claim memory) {
        require(_claims[tokenId].claimToken != address(0), "Claim does not exist");
        return _claims[tokenId];
    }

    function bullaManager() external view returns (address) {
        return address(0); // Mock implementation
    }
} 