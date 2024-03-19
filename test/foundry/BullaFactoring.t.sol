// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoring } from 'contracts/BullaFactoring.sol';
import { BullaClaimInvoiceProviderAdapter } from 'contracts/BullaClaimInvoiceProviderAdapter.sol';
import { MockUSDC } from 'contracts/mocks/MockUSDC.sol';
import { MockPermissions } from 'contracts/mocks/MockPermissions.sol';
import "@bulla-network/contracts/interfaces/IBullaClaim.sol";
import "../../contracts/interfaces/IInvoiceProviderAdapter.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract TestBullaFactoring is Test {
    BullaFactoring public bullaFactoring;
    BullaClaimInvoiceProviderAdapter public invoiceAdapterBulla;
    MockUSDC public asset;
    MockPermissions public depositPermissions;
    MockPermissions public factoringPermissions;
    IBullaClaim bullaClaim = IBullaClaim(0x3702D060cbB102b6AebF40B40880F77BeF3d7225); // contract address on SEPOLIA
    IERC721 bullaClaimERC721 = IERC721(0x3702D060cbB102b6AebF40B40880F77BeF3d7225); // required to use approve & transferFrom functions

    address alice = address(0xA11c3);
    address bob = address(0xb0b);
    address underwriter = address(0x1222);
    address userWithoutPermissions = address(0x743123);

    uint16 interestApr = 1000;
    uint16 upfrontBps = 8000;
    uint256 dueBy = block.timestamp + 30 days;

    address bullaDao = address(this);
    uint16 protocolFeeBps = 25;
    uint16 adminFeeBps = 50;

    function setUp() public {
        asset = new MockUSDC();
        invoiceAdapterBulla = new BullaClaimInvoiceProviderAdapter(bullaClaim);
        depositPermissions = new MockPermissions();
        factoringPermissions = new MockPermissions();

        // Allow alice and bob for deposits, and bob for factoring
        depositPermissions.allow(alice);
        depositPermissions.allow(bob);
        factoringPermissions.allow(bob);
        factoringPermissions.allow(address(this));

        bullaFactoring = new BullaFactoring(asset, invoiceAdapterBulla, underwriter, depositPermissions, factoringPermissions, bullaDao,protocolFeeBps, adminFeeBps) ;

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
        uint256 _dueBy
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
            _dueBy,
            claimToken,
            attachment
        );
    }

    function calculateKickbackAmount(uint256 invoiceId, uint fundedTimestamp, uint16 apr, uint fundedAmount) private view returns (uint256) {
        IInvoiceProviderAdapter.Invoice memory invoice = invoiceAdapterBulla.getInvoiceDetails(invoiceId);
        uint256 daysSinceFunded = (block.timestamp > fundedTimestamp) ? (block.timestamp - fundedTimestamp) / 60 / 60 / 24 : 0;
        daysSinceFunded = daysSinceFunded +1;
        uint256 trueDiscountRateBps = Math.mulDiv(apr, daysSinceFunded, 365);
        uint256 haircutCap = invoice.faceValue - fundedAmount;
        uint256 trueHaircut = Math.min(Math.mulDiv(invoice.faceValue, trueDiscountRateBps, 10000), haircutCap);        
        uint256 totalDueToCreditor = invoice.faceValue - trueHaircut;
        uint256 kickbackAmount = totalDueToCreditor - fundedAmount;

        return kickbackAmount;
    }

    function calculatePricePerShare(uint256 capitalAccount, uint256 sharesOutstanding, uint SCALING_FACTOR) public pure returns (uint256) {
        if (sharesOutstanding == 0) return 0;
        return (capitalAccount * SCALING_FACTOR) / sharesOutstanding;
    }


    function testInvoicePaymentAndKickbackCalculation() public {
        dueBy = block.timestamp + 60 days; // Invoice due in 60 days
        uint256 invoiceAmount = 100000; // Invoice amount is $100000
        interestApr = 1000; // 10% APR
        upfrontBps = 8000; // 80% upfront

        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Creditor creates the invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();


        // Simulate debtor paying in 30 days instead of 60
        uint256 actualDaysUntilPayment = 30;
        vm.warp(block.timestamp + actualDaysUntilPayment * 1 days);

        // Debtor pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        uint pricePerShareBeforeReconciliation = bullaFactoring.pricePerShare();

        bullaFactoring.reconcileActivePaidInvoices();

        uint pricePerShareAfterReconciliation = bullaFactoring.pricePerShare();
    
        assertTrue(pricePerShareBeforeReconciliation < pricePerShareAfterReconciliation, "Price per share should increased due to redeemed invoices");

    }

    function testImmediateRepaymentStillChangesPrice() public {
        dueBy = block.timestamp + 60 days; // Invoice due in 60 days
        uint256 invoiceAmount = 100000; // Invoice amount is $100000
        interestApr = 1000; // 10% APR
        upfrontBps = 8000; // 80% upfront

        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Creditor creates the invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();

        // Debtor pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        uint pricePerShareBeforeReconciliation = bullaFactoring.pricePerShare();

        bullaFactoring.reconcileActivePaidInvoices();

        uint pricePerShareAfterReconciliation = bullaFactoring.pricePerShare();
    
        assertTrue(pricePerShareBeforeReconciliation < pricePerShareAfterReconciliation, "Price per share should change even if invoice repaid immediately");
    }

    function testPriceUpdateInvoicesRedeemed() public {
        interestApr = 1000;
        upfrontBps = 8000;

        uint256 initialDeposit = 9000000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint initialFactorerBalance = asset.balanceOf(bob);

        vm.startPrank(bob);
        uint invoiceId01Amount = 100000;
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, interestApr, upfrontBps);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId02Amount = 900000;
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId02Amount, dueBy);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId02);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, upfrontBps);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps);
        vm.stopPrank();

        uint factorerBalanceAfterFactoring = asset.balanceOf(bob);

        assertEq(factorerBalanceAfterFactoring, initialFactorerBalance + bullaFactoring.getFundedAmount(invoiceId01) + bullaFactoring.getFundedAmount(invoiceId02));

        // Simulate debtor paying in 30 days
        vm.warp(block.timestamp + 30 days);

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

    function testAprCapWhenPastDueDate() public {
        interestApr = 2000;
        upfrontBps = 8000;

        uint256 initialDeposit = 2000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId01Amount = 100;
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, interestApr, upfrontBps);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps);
        vm.stopPrank();

        // Simulate debtor paying in 30 days
        vm.warp(block.timestamp + 30 days);

        // alice pays the first invoice
        vm.startPrank(alice);
        // bullaClaim is the contract executing the transferFrom method when paying, so it needs to be approved
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();

        uint256 dueByNew = block.timestamp + 30 days;

        vm.startPrank(bob);
        uint invoiceId03Amount = 100;
        uint256 invoiceId03 = createClaim(bob, alice, invoiceId03Amount, dueByNew);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId03, interestApr, upfrontBps);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId03);
        bullaFactoring.fundInvoice(invoiceId03, upfrontBps);
        vm.stopPrank();

        // Fast forward time by 900 days to simulate interest rate cap
        vm.warp(block.timestamp + 900 days);

        uint balanceBefore = asset.balanceOf(bob);
        // alice pays the second invoice
        vm.startPrank(alice);
        // bullaClaim is the contract executing the transferFrom method when paying, so it needs to be approved
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId03, invoiceId03Amount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();
        uint balanceAfter = asset.balanceOf(bob);

        assertTrue(balanceBefore == balanceAfter, "No kickback as interest rate cap has been reached");
    }


    function testPriceUpdateInvoicesImpaired() public {
        uint256 initialDeposit = 2000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId01Amount = 100;
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, interestApr, upfrontBps);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId02Amount = 900;
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId02Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, upfrontBps);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId02);
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps);
        vm.stopPrank();

        // Simulate debtor paying in 30 days
        vm.warp(block.timestamp + 30 days);

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
        bullaFactoring.approveInvoice(invoiceId03, interestApr, upfrontBps);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId03);
        bullaFactoring.fundInvoice(invoiceId03, upfrontBps);
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
        uint256 initialDeposit = 2000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Bob creates and funds an invoice
        vm.startPrank(bob);
        uint invoiceIdAmount = 300; // Amount of the invoice
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
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
        uint invoiceId01Amount = 100;
        createClaim(bob, alice, invoiceId01Amount, dueBy);
        // picking a random number as incorrect invoice id
        uint256 incorrectInvoiceId = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao))) % 10000000000;
        vm.startPrank(underwriter);
        vm.expectRevert(abi.encodeWithSignature("InexistentInvoice()"));
        bullaFactoring.approveInvoice(incorrectInvoiceId, interestApr, upfrontBps);
        vm.stopPrank();
    }

    function testFundInvoiceWithoutUnderwriterApproval() public {
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
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps);
        vm.stopPrank();
    }

    function testFundInvoiceExpiredApproval() public {
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
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 hours);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("ApprovalExpired()"));
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();
    }

    function testInvoiceCancelled() public {
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
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.rescindClaim(invoiceId);
        vm.expectRevert(abi.encodeWithSignature("InvoiceCanceled()"));
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 invoiceId02 = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId02);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, upfrontBps);
        vm.stopPrank();

        vm.startPrank(alice);
        bullaClaim.rejectClaim(invoiceId02);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("InvoiceCanceled()"));
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps);
        vm.stopPrank();
    }

    function testInvoicePaid() public {
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
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps);
        vm.stopPrank();

        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId, invoiceIdAmount);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("InvoicePaidAmountChanged()"));
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
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

    function testWhitelistFactoring() public {
        uint invoiceId01Amount = 100;
        vm.startPrank(userWithoutPermissions);
        uint256 InvoiceId = createClaim(userWithoutPermissions, alice, invoiceId01Amount, dueBy);
        vm.stopPrank();
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(InvoiceId, interestApr, upfrontBps);
        vm.stopPrank();
        vm.startPrank(userWithoutPermissions);
        bullaClaimERC721.approve(address(bullaFactoring), InvoiceId);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedFactoring(address)", userWithoutPermissions));
        bullaFactoring.fundInvoice(InvoiceId, upfrontBps);
        vm.stopPrank();
    }

    function testWhitelistDeposit() public {
        vm.startPrank(userWithoutPermissions);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedDeposit(address)", userWithoutPermissions));
        bullaFactoring.deposit(1 ether, alice);
        vm.stopPrank();
    }

    function testDisperseKickbackAmount() public {
        uint256 initialDeposit = 900;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint initialFactorerBalance = asset.balanceOf(bob);

        vm.startPrank(bob);
        uint invoiceId01Amount = 100;
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);

        bullaFactoring.approveInvoice(invoiceId01, interestApr, upfrontBps);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps);
        uint256 fundedTimestamp = block.timestamp;
        vm.stopPrank();

        // Simulate debtor paying in 30 days
        uint256 actualDaysUntilPayment = 30;
        vm.warp(block.timestamp + actualDaysUntilPayment * 1 days);

        // alice pays both invoices
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        vm.stopPrank();

        // automation will signal that we have some paid invoices
        (uint256[] memory paidInvoices, ) = bullaFactoring.viewPoolStatus();
        assertEq(paidInvoices.length, 1);

        // owner will reconcile paid invoices to account for any realized gains or losses
        bullaFactoring.reconcileActivePaidInvoices();

        // Check if the kickback and funded amount were correctly transferred
        uint256 fundedAmount = bullaFactoring.getFundedAmount(invoiceId01);
        uint256 kickbackAmount = calculateKickbackAmount(invoiceId01, fundedTimestamp, interestApr, fundedAmount);

        uint256 finalBalanceOwner = asset.balanceOf(address(bob));

        assertEq(finalBalanceOwner, initialFactorerBalance + kickbackAmount + fundedAmount, "Kickback amount was not dispersed correctly");
    }

    function testCannotRedeemKickbackAmount() public {
        // Alice deposits into the fund
        uint256 initialDepositAlice = 100;
        vm.startPrank(alice);
        asset.approve(address(bullaFactoring), initialDepositAlice);
        bullaFactoring.deposit(initialDepositAlice, alice);
        vm.stopPrank();

        // Bob funds an invoice
        uint invoiceIdAmount = 100; // Amount of the invoice
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        uint256 fundedTimestamp = block.timestamp;
        vm.stopPrank();

        uint256 actualDaysUntilPayment = 30;
        vm.warp(block.timestamp + actualDaysUntilPayment * 1 days);

        // Alice pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceIdAmount);
        bullaClaim.payClaim(invoiceId, invoiceIdAmount);
        vm.stopPrank();

        uint256 fundedAmount = bullaFactoring.getFundedAmount(invoiceId);
        uint256 kickbackAmount = calculateKickbackAmount(invoiceId, fundedTimestamp, interestApr, fundedAmount);
        uint256 sharesToRedeemIncludingKickback = bullaFactoring.convertToShares(initialDepositAlice + kickbackAmount);
        uint maxRedeem = bullaFactoring.maxRedeem();

        assertTrue(sharesToRedeemIncludingKickback > maxRedeem);

        uint pricePerShare = bullaFactoring.pricePerShare();
        uint maxRedeemAmount = maxRedeem * pricePerShare / bullaFactoring.SCALING_FACTOR();

        // if Alice tries to redeem more shares than she owns, she'll be capped by max redeem amount
        vm.startPrank(alice);
        uint balanceBefore = asset.balanceOf(alice);
        bullaFactoring.redeem(sharesToRedeemIncludingKickback, alice, alice);
        uint balanceAfter = asset.balanceOf(alice);
        vm.stopPrank();

        uint actualAssetsRedeems = balanceAfter - balanceBefore;

        assertEq(actualAssetsRedeems, maxRedeemAmount, "Redeem amount should be capped to max redeem amount");
    }
    
    function testAvailableAssetsLessThanTotal() public {
        // Alice deposits into the fund
        uint256 initialDepositAlice = 2000;
        vm.startPrank(alice);
        asset.approve(address(bullaFactoring), initialDepositAlice);
        bullaFactoring.deposit(initialDepositAlice, alice);
        vm.stopPrank();

        // Bob funds an invoice
        uint invoiceIdAmount = 100; // Amount of the invoice
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();
    
        assertTrue(bullaFactoring.totalAssets() > bullaFactoring.availableAssets());

        uint fundedAmount = bullaFactoring.getFundedAmount(invoiceId);

        assertEq(bullaFactoring.totalAssets() - fundedAmount, bullaFactoring.availableAssets(), "Available Assets should be the differenct of total assets and what has been funded");
    }

    function testUnfactorInvoice() public {
        // Alice deposits into the fund
        uint256 initialDeposit = 1000;
        vm.startPrank(alice);
        asset.approve(address(bullaFactoring), initialDeposit);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Bob creates and funds an invoice
        uint invoiceIdAmount = 100;
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();

        // Bob unfactors the invoice
        vm.startPrank(bob);
        bullaFactoring.unfactorInvoice(invoiceId);
        vm.stopPrank();

        // Assert the invoice NFT is transferred back to Bob and that fund has received the funded amount back
        assertEq(bullaClaimERC721.ownerOf(invoiceId), bob, "Invoice NFT should be returned to Bob");
        assertEq(asset.balanceOf(address(bullaFactoring)), initialDeposit, "Funded amount should be refunded to BullaFactoring");
    }

     function testUnfactorImpairedInvoiceAffectsSharePrice() public {
        interestApr = 2000;
        upfrontBps = 8000;

        uint256 initialDeposit = 2000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId01Amount = 100;
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, interestApr, upfrontBps);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId02Amount = 900;
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId02Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, upfrontBps);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId02);
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps);
        vm.stopPrank();

        // alice pays both invoices
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        bullaClaim.payClaim(invoiceId02, invoiceId02Amount);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId03Amount = 50;
        uint256 invoiceId03 = createClaim(bob, alice, invoiceId03Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId03, interestApr, upfrontBps);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId03);
        bullaFactoring.fundInvoice(invoiceId03, upfrontBps);
        vm.stopPrank();

        // Fast forward time by 100 days to simulate the invoice becoming impaired
        vm.warp(block.timestamp + 100 days);

        // reconcile redeemed invoice to adjust the price
        bullaFactoring.reconcileActivePaidInvoices();
        uint sharePriceBeforeUnfactoring = bullaFactoring.pricePerShare();

        // Bob unfactors the invoice
        vm.startPrank(bob);
        bullaFactoring.unfactorInvoice(invoiceId03);
        vm.stopPrank();
  
        bullaFactoring.reconcileActivePaidInvoices();

        uint256 sharePriceAfterUnfactoring = bullaFactoring.pricePerShare();

        assertTrue(sharePriceAfterUnfactoring > sharePriceBeforeUnfactoring, "Price per share should increase due to unfactored impaired invoice");
    }


    function testInterestAccruedOnUnfactoredInvoice() public {
        interestApr = 2000;
        upfrontBps = 8000;
        uint invoiceAmount = 100;

        uint256 initialDeposit = 2000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 invoiceId01 = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, interestApr, upfrontBps);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps);
        vm.stopPrank();

        uint balanceBeforeUnfactoring = asset.balanceOf(bob);

        // Bob unfactors the first invoice
        vm.startPrank(bob);
        bullaFactoring.unfactorInvoice(invoiceId01);
        vm.stopPrank();

        uint balanceAfterUnfactoring = asset.balanceOf(bob);
        uint refundedAmount = balanceBeforeUnfactoring - balanceAfterUnfactoring;

        vm.startPrank(bob);
        uint256 invoiceId03 = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId03, interestApr, upfrontBps);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId03);
        bullaFactoring.fundInvoice(invoiceId03, upfrontBps);
        vm.stopPrank();

        // Fast forward time by 90 days 
        vm.warp(block.timestamp + 90 days);

        uint balanceBeforeDelayedUnfactoring = asset.balanceOf(bob);

        // Bob unfactors the second invoice
        vm.startPrank(bob);
        bullaFactoring.unfactorInvoice(invoiceId03);
        vm.stopPrank();
  
        uint balanceAfterDelayedUnfactoring = asset.balanceOf(bob);
        uint refundeDelayedUnfactoring = balanceBeforeDelayedUnfactoring - balanceAfterDelayedUnfactoring;

        assertTrue(refundedAmount > refundeDelayedUnfactoring, "Interest should accrue when unfactoring invoices");
    } 

    function testWithdrawFees() public {
        uint256 initialDeposit = 1 ether;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Simulate funding an invoice to generate fees
        vm.startPrank(bob);
        uint256 invoiceAmount = 0.01 ether;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();

        // Check initial balances
        uint256 initialBullaDaoBalance = asset.balanceOf(bullaDao);
        uint256 initialOwnerBalance = asset.balanceOf(address(this));

        // Withdraw admin fees
        vm.startPrank(address(this)); 
        bullaFactoring.withdrawAdminFees();
        vm.stopPrank();

        // alice pays invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();

        // Withdraw protocol fees
        vm.startPrank(bullaDao);
        bullaFactoring.withdrawProtocolFees();
        vm.stopPrank();

        // Check final balances
        uint256 finalBullaDaoBalance = asset.balanceOf(bullaDao);
        uint256 finalOwnerBalance = asset.balanceOf(address(this));

        // Check that the Bulla DAO and the owner's balances have increased by the expected fee amounts
        assertTrue(finalBullaDaoBalance > initialBullaDaoBalance, "Bulla DAO should receive protocol fees");
        assertTrue(finalOwnerBalance > initialOwnerBalance, "Owner should receive admin fees");
    }

    function testFeesDeductionFromCapitalAccount() public {
        interestApr = 1000;
        upfrontBps = 8000;

        uint256 initialDeposit = 9000000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId01Amount = 100000;
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, interestApr, upfrontBps);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId02Amount = 90000;
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId02Amount, dueBy);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId02);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, upfrontBps);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps);
        vm.stopPrank();

        // Simulate debtor paying in 30 days
        vm.warp(block.timestamp + 30 days);

        // alice pays both invoices
        vm.startPrank(alice);
        // bullaClaim is the contract executing the transferFrom method when paying, so it needs to be approved
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        bullaClaim.payClaim(invoiceId02, invoiceId02Amount);
        vm.stopPrank();

        // owner will reconcile paid invoices to account for any realized gains or losses, and fees
        bullaFactoring.reconcileActivePaidInvoices();

        uint capitalAccountBefore = bullaFactoring.calculateCapitalAccount();

        // Withdraw admin fees
        vm.startPrank(address(this)); 
        bullaFactoring.withdrawAdminFees();
        vm.stopPrank();

        // Withdraw protocol fees
        vm.startPrank(bullaDao);
        bullaFactoring.withdrawProtocolFees();
        vm.stopPrank();

        uint capitalAccountAfter = bullaFactoring.calculateCapitalAccount();

        assertEq(capitalAccountAfter , capitalAccountBefore, "Capital Account should remain unchanged");
    }

    function testFactorerUsesLowerUpfrontBps() public {
        uint256 invoiceAmount = 100000; 
        uint16 approvedUpfrontBps = 8000; 
        uint16 factorerUpfrontBps = 7000;

        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Creditor creates the 2 invoices
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        uint256 invoiceId2 = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice with approvedUpfrontBps
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, approvedUpfrontBps);
        bullaFactoring.approveInvoice(invoiceId2, interestApr, approvedUpfrontBps);
        vm.stopPrank();

        // Factorer funds one invoice at a lower UpfrontBps
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, approvedUpfrontBps);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId2);
        bullaFactoring.fundInvoice(invoiceId2, factorerUpfrontBps);
        vm.stopPrank();

        uint256 actualFundedAmount = bullaFactoring.getFundedAmount(invoiceId);
        uint256 actualFundedAmountLowerUpfrontBps = bullaFactoring.getFundedAmount(invoiceId2);

        assertTrue(actualFundedAmount > actualFundedAmountLowerUpfrontBps, "Funded amounts should reflect the actual upfront bps chosen by the factorer" );
    }
}