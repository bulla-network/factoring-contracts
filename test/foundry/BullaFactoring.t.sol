// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoring } from 'contracts/BullaFactoring.sol';
import { BullaClaimInvoiceProviderAdapter } from 'contracts/BullaClaimInvoiceProviderAdapter.sol';
import { MockUSDC } from 'contracts/mocks/MockUSDC.sol';
import "@bulla-network/contracts/interfaces/IBullaClaim.sol";
import "../../contracts/interfaces/IInvoiceProviderAdapter.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract TestBullaFactoring is Test {
    BullaFactoring public bullaFactoring;
    BullaClaimInvoiceProviderAdapter public invoiceAdapterBulla;
    MockUSDC public asset;
    IBullaClaim bullaClaim = IBullaClaim(0x3702D060cbB102b6AebF40B40880F77BeF3d7225); // contract address on SEPOLIA
    IERC721 bullaClaimERC721 = IERC721(0x3702D060cbB102b6AebF40B40880F77BeF3d7225); // required to use approve & transferFrom functions

    address alice = address(0xA11c3);
    address bob = address(0xb0b);
    address underwriter = address(0x1222);

    function setUp() public {
        asset = new MockUSDC();
        invoiceAdapterBulla = new BullaClaimInvoiceProviderAdapter(bullaClaim);
        bullaFactoring = new BullaFactoring(asset, invoiceAdapterBulla, underwriter);

        asset.mint(alice, 1000 ether);
        asset.mint(bob, 1000 ether);

        vm.startPrank(alice);
        asset.approve(address(bullaFactoring), 1000 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(bullaFactoring), 1000 ether);
        vm.stopPrank();
    }


    function createClaim(
        address creditor, 
        address debtor, 
        uint256 claimAmount, 
        uint256 dueBy
    ) internal returns (uint256) {
        string memory description = "";
        address claimToken = address(asset);
        Multihash memory attachment = Multihash({
            hash: 0x0,
            hashFunction: 0x12, 
            size: 32 
        });

        return bullaClaim.createClaim(
            creditor,
            debtor,
            description,
            claimAmount,
            dueBy,
            claimToken,
            attachment
        );
    }

    function calculateFundedAmount(uint256 invoiceId) public view returns (uint256) {
        IInvoiceProviderAdapter.Invoice memory invoice = invoiceAdapterBulla.getInvoiceDetails(invoiceId);
        return Math.mulDiv(invoice.faceValue, bullaFactoring.fundingPercentage(), 10000);
    }

    function calculatePricePerShare(uint256 capitalAccount, uint256 sharesOutstanding, uint SCALING_FACTOR) public pure returns (uint256) {
        if (sharesOutstanding == 0) return 0;
        return (capitalAccount * SCALING_FACTOR) / sharesOutstanding;
    }

    function testPriceUpdateInvoicesRedeemed() public {
        uint256 dueBy = block.timestamp + 30 days;

        uint256 initialDeposit = 900;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint initialFactorerBalance = asset.balanceOf(bob);

        vm.startPrank(bob);
        uint invoiceId01Amount = 100;
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId02Amount = 900;
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId02Amount, dueBy);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId02);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaFactoring.fundInvoice(invoiceId02);
        vm.stopPrank();

        uint factorerBalanceAfterFactoring = asset.balanceOf(bob);

        assertEq(factorerBalanceAfterFactoring, initialFactorerBalance + calculateFundedAmount(invoiceId01) + calculateFundedAmount(invoiceId02));

        // alice pays both invoices
        vm.startPrank(alice);
        // bullaClaim is the contract executing the transferFrom method when paying, so it needs to be approved
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        bullaClaim.payClaim(invoiceId02, invoiceId02Amount);
        vm.stopPrank();

        // automation will signal that we have some paid invoices
        (uint256[] memory paidInvoices, ) = bullaFactoring.viewPoolStatus();
        assertEq(paidInvoices.length, 2);

        uint pricePerShareBeforeReconciliation = bullaFactoring.pricePerShare();
        // owner will reconcile paid invoices to account for any realized gains or losses
        bullaFactoring.reconcileActivePaidInvoices();

        uint pricePerShareAfterReconciliation = bullaFactoring.pricePerShare();
        uint capitalAccount = bullaFactoring.calculateCapitalAccount();
        uint sharePriceCheck = calculatePricePerShare(capitalAccount, bullaFactoring.totalSupply(), bullaFactoring.SCALING_FACTOR());
        assertEq(pricePerShareAfterReconciliation, sharePriceCheck);
        assertTrue(pricePerShareBeforeReconciliation < pricePerShareAfterReconciliation, "Price per share should increased due to redeemed invoices");
    }

    function testPriceUpdateInvoicesImpaired() public {
        uint256 dueBy = block.timestamp + 30 days;

        uint256 initialDeposit = 2000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId01Amount = 100;
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId02Amount = 900;
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId02Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId02);
        bullaFactoring.fundInvoice(invoiceId02);
        vm.stopPrank();

        // alice pays both invoices
        vm.startPrank(alice);
        // bullaClaim is the contract executing the transferFrom method when paying, so it needs to be approved
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        bullaClaim.payClaim(invoiceId02, invoiceId02Amount);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId03Amount = 10;
        uint256 invoiceId03 = createClaim(bob, alice, invoiceId03Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId03);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId03);
        bullaFactoring.fundInvoice(invoiceId03);
        vm.stopPrank();

        // we reconcile redeemed invoice to adjust the price
        bullaFactoring.reconcileActivePaidInvoices();
        uint pricePerShareBeforeImpairment = bullaFactoring.pricePerShare();

        // Fast forward time by 100 days to simulate the invoice becoming impaired
        vm.warp(block.timestamp + 100 days);

        (, uint256[] memory impairedInvoices) = bullaFactoring.viewPoolStatus();
        assertEq(impairedInvoices.length, 1);

        // Check the impact on the price per share due to the impaired invoice
        bullaFactoring.reconcileActivePaidInvoices();
        uint pricePerShareAfterImpairment = bullaFactoring.pricePerShare();
        assertTrue(pricePerShareAfterImpairment < pricePerShareBeforeImpairment, "Price per share should decrease due to impaired invoice");
    }

    function testDeductionsExceedGains() public {
        uint256 dueBy = block.timestamp + 30 days;

        uint256 initialDeposit = 2000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Bob creates and funds an invoice
        vm.startPrank(bob);
        uint invoiceIdAmount = 300; // Amount of the invoice
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId);
        vm.stopPrank();

        // Fast forward time by 100 days to simulate the invoice becoming impaired
        vm.warp(block.timestamp + 100 days);

        // automation will signal that we have an impaired invoice
        (, uint256[] memory impairedInvoices) = bullaFactoring.viewPoolStatus();
        assertEq(impairedInvoices.length, 1);


        bullaFactoring.reconcileActivePaidInvoices(); 

        vm.expectRevert(abi.encodeWithSignature("DeductionsExceedsRealisedGains()"));
        bullaFactoring.pricePerShare();
    }

    function testUnknownInvoiceId() public {
        uint256 dueBy = block.timestamp + 30 days;
        uint invoiceId01Amount = 100;
        createClaim(bob, alice, invoiceId01Amount, dueBy);
        // picking a random number as incorrect invoice id
        uint256 incorrectInvoiceId = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao))) % 10000000000;
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(incorrectInvoiceId);
        vm.stopPrank();
        vm.expectRevert("ERC721: owner query for nonexistent token");
        bullaClaimERC721.approve(address(bullaFactoring), incorrectInvoiceId);
        vm.expectRevert("ERC721: operator query for nonexistent token");
        bullaFactoring.fundInvoice(incorrectInvoiceId);
    }

    function testFundInvoiceWithoutUnderwriterApproval() public {
        uint256 dueBy = block.timestamp + 30 days;

        uint256 initialDeposit = 900;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId01Amount = 100;
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        vm.expectRevert(abi.encodeWithSignature("InvoiceNotApproved()"));
        bullaFactoring.fundInvoice(invoiceId01);
        vm.stopPrank();
    }

    function testFundInvoiceExpiredApproval() public {
        uint256 dueBy = block.timestamp + 30 days;

        uint256 initialDeposit = 900;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceIdAmount = 100;
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 hours);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("ApprovalExpired()"));
        bullaFactoring.fundInvoice(invoiceId);
        vm.stopPrank();
    }

    function testInvoiceCancelled() public {
        uint256 dueBy = block.timestamp + 30 days;

        uint256 initialDeposit = 900;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceIdAmount = 100;
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.rescindClaim(invoiceId);
        vm.expectRevert(abi.encodeWithSignature("InvoiceCanceled()"));
        bullaFactoring.fundInvoice(invoiceId);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 invoiceId02 = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId02);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02);
        vm.stopPrank();

        vm.startPrank(alice);
        bullaClaim.rejectClaim(invoiceId02);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("InvoiceCanceled()"));
        bullaFactoring.fundInvoice(invoiceId02);
        vm.stopPrank();
    }

    function testInvoicePaid() public {
        uint256 dueBy = block.timestamp + 30 days;

        uint256 initialDeposit = 900;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceIdAmount = 100;
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId);
        vm.stopPrank();

        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId, invoiceIdAmount);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("InvoicePaymentChanged()"));
        bullaFactoring.fundInvoice(invoiceId);
        vm.stopPrank();
    }

    function testFundBalanceGoesToZero() public {
        uint256 initialBalanceAlice = asset.balanceOf(alice);
        uint256 initialDepositAlice = 10 ether;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDepositAlice, alice);
        vm.stopPrank();

        // Alice redeems all her funds
        vm.startPrank(alice);
        bullaFactoring.redeem(bullaFactoring.balanceOf(alice), alice, alice);
        vm.stopPrank();

        uint256 aliceBalanceAfterRedemption = asset.balanceOf(alice);
        assertEq(aliceBalanceAfterRedemption, initialBalanceAlice, "Alice's balance should be equal to her initial deposit after redemption");

        // New depositor Bob comes in
        uint256 initialDepositBob = 20 ether;
        vm.startPrank(bob);
        bullaFactoring.deposit(initialDepositBob, bob);
        vm.stopPrank();

        uint256 pricePerShareAfterNewDeposit = bullaFactoring.pricePerShare();
        assertEq(pricePerShareAfterNewDeposit, bullaFactoring.SCALING_FACTOR(), "Price should go back to the scaling factor for new depositor in empty asset vault");
    }

}