// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoringV2_1 } from 'contracts/BullaFactoring.sol';
import { CommonSetup } from './CommonSetup.t.sol';
import "contracts/interfaces/IBullaFactoring.sol";
import {CreateClaimApprovalType} from '@bulla/contracts-v2/src/types/Types.sol';
import {EIP712Helper} from './utils/EIP712Helper.sol';
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title TestInsufficientFundsWithDeployedCapital
 * @notice Tests the scenario where the pool has enough total capital but insufficient liquid assets (totalAssets) 
 *         due to deployed capital and withheld fees when trying to accept a loan offer.
 * @dev This tests the specific error case mentioned in line 245 of BullaFactoring.sol where totalAssets() < principalAmount
 *      The contract has capital tied up in active invoices with withheld fees, so totalAssets (liquid assets) 
 *      is insufficient even though the overall pool balance might be adequate.
 */
contract TestInsufficientFundsWithDeployedCapital is CommonSetup {

    EIP712Helper public sigHelper;

    event InvoiceFunded(
        uint256 indexed invoiceId,
        uint256 fundedAmount,
        address indexed originalCreditor,
        uint256 invoiceDueDate,
        uint16 upfrontBps,
        uint256 protocolFee,
        address fundsReceiver
    );

    function setUp() public override {
        super.setUp();
        sigHelper = new EIP712Helper(address(bullaClaim));
        
        // Add factoring pool to feeExemption whitelist
        feeExemptionWhitelist.allow(address(bullaFactoring));

        // Set up approval for mock controller to create many claims for bob
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: bob,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: type(uint64).max,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: bobPK,
                user: bob,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: type(uint64).max,
                isBindingAllowed: true
            })
        });

        // Set up approval for charlie to accept loans
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: charlie,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: type(uint64).max,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: charliePK,
                user: charlie,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: type(uint64).max,
                isBindingAllowed: true
            })
        });
    }

    /**
     * @notice Test the specific scenario described in the code comment on line 242-244:
     *         "if the pool has 0 assets... it means the pool has enough assets to cover 
     *         the principal amount, but might be taking from withheld fees or admin/protocol 
     *         balances where it should not be taking from."
     * 
     * This tests when totalAssets() <= 0 due to all liquid assets being deployed as capital
     * with withheld fees, but the contract still has sufficient balance for the transfer.
     */
    function testInsufficientFundsWhenTotalAssetsIsZeroButBalanceExists() public {
        // Step 1: Deploy multiple invoices to gradually consume all available assets
        uint256 initialDeposit = 2000 * 1e6; // 2000 USDC
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Factor multiple invoices to consume available assets
        uint256 invoice1Amount = 800 * 1e6;
        uint256 invoice2Amount = 800 * 1e6;
        
        // First invoice
        vm.startPrank(bob);
        uint256 invoiceId1 = createClaim(bob, alice, invoice1Amount, dueBy);
        bullaClaim.approve(address(bullaFactoring), invoiceId1);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId1, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaFactoring.fundInvoice(invoiceId1, upfrontBps, address(0));
        vm.stopPrank();

        // Second invoice with higher fees to consume remaining assets
        // Give charlie factoring permissions
        factoringPermissions.allow(charlie);
        
        vm.startPrank(charlie);
        uint256 invoiceId2 = createClaim(charlie, alice, invoice2Amount, dueBy);
        bullaClaim.approve(address(bullaFactoring), invoiceId2);
        vm.stopPrank();

        uint16 highSpread = 1500; // 15%
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId2, interestApr, highSpread, upfrontBps, 0);
        vm.stopPrank();

        vm.startPrank(charlie);
        bullaFactoring.fundInvoice(invoiceId2, upfrontBps, address(0));
        vm.stopPrank();

        // Check if we achieved totalAssets <= 0
        uint256 totalAssetsAfterFactoring = bullaFactoring.totalAssets();
        
        uint256 remainingAmount = totalAssetsAfterFactoring + 1;
        
        vm.startPrank(bob);
        uint256 invoiceId3 = createClaim(bob, alice, remainingAmount, dueBy);
        bullaClaim.approve(address(bullaFactoring), invoiceId3);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId3, interestApr, 0, 10000, 0); // High fees
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(BullaFactoringV2_1.InsufficientFunds.selector, totalAssetsAfterFactoring, remainingAmount));
        bullaFactoring.fundInvoice(invoiceId3, 10000, address(0));
        vm.stopPrank();

        // Step 2: Create a loan offer for the remaining amount
        uint256 loanAmount = remainingAmount; 
        
        vm.startPrank(underwriter);
        uint256 loanOfferId = bullaFactoring.offerLoan(
            charlie,
            1000,
            0,
            loanAmount,
            30 days,
            365,
            "Test totalAssets <= 0"
        );
        vm.stopPrank();

        vm.prank(charlie);
        // BullaFrendLend wraps callback failures in CallbackFailed error
        // Calculate the CallbackFailed error selector manually: bytes4(keccak256("CallbackFailed(bytes)"))
        bytes4 callbackFailedSelector = bytes4(keccak256("CallbackFailed(bytes)"));
        bytes memory expectedCallbackData = abi.encodeWithSelector(
            BullaFactoringV2_1.InsufficientFunds.selector,
            totalAssetsAfterFactoring,
            loanAmount
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                callbackFailedSelector,
                expectedCallbackData
            )
        );
        bullaFrendLend.acceptLoan(loanOfferId);
    }


}
