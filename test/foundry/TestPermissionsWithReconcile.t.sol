// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoring } from 'contracts/BullaFactoring.sol';
import { IBullaFactoring } from 'contracts/interfaces/IBullaFactoring.sol';
import { PermissionsWithReconcile } from 'contracts/PermissionsWithReconcile.sol';
import { BullaClaimInvoiceProviderAdapter } from 'contracts/BullaClaimInvoiceProviderAdapter.sol';
import { MockUSDC } from 'contracts/mocks/MockUSDC.sol';
import { MockPermissions } from 'contracts/mocks/MockPermissions.sol';
import "@bulla-network/contracts/contracts/interfaces/IBullaClaim.sol";
import "../../contracts/interfaces/IInvoiceProviderAdapter.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
// IBullaFactoring imported above

import { CommonSetup } from './CommonSetup.t.sol';

contract TestPermissionsWithReconcile is CommonSetup {
    PermissionsWithReconcile public factoringPermissionsWithReconcile;
    PermissionsWithReconcile public depositPermissionsWithReconcile;
    BullaFactoring public bullaFactoringWithReconcilePermissions;

    function setUp() public override {
        super.setUp();
        
        // Deploy the new permission contracts first (before the BullaFactoring contract)
        factoringPermissionsWithReconcile = new PermissionsWithReconcile();
        depositPermissionsWithReconcile = new PermissionsWithReconcile();
        
        // Deploy BullaFactoring with the new permission contracts
        bullaFactoringWithReconcilePermissions = new BullaFactoring(
            asset,
            invoiceAdapterBulla,
            underwriter,
            depositPermissionsWithReconcile,
            factoringPermissionsWithReconcile,
            bullaDao,
            protocolFeeBps,
            adminFeeBps,
            poolName,
            taxBps,
            targetYield,
            poolTokenName,
            poolTokenSymbol
        );
        
        // Create new permission contracts with the correct BullaFactoring reference
        PermissionsWithReconcile newFactoringPermissions = new PermissionsWithReconcile();
        PermissionsWithReconcile newDepositPermissions = new PermissionsWithReconcile();
        
        // Set the BullaFactoring pool reference
        newFactoringPermissions.setBullaFactoringPool(address(bullaFactoringWithReconcilePermissions));
        newDepositPermissions.setBullaFactoringPool(address(bullaFactoringWithReconcilePermissions));
        
        // Update the BullaFactoring contract to use the new permission contracts
        bullaFactoringWithReconcilePermissions.setFactoringPermissions(address(newFactoringPermissions));
        bullaFactoringWithReconcilePermissions.setDepositPermissions(address(newDepositPermissions));
        
        // Update our references
        factoringPermissionsWithReconcile = newFactoringPermissions;
        depositPermissionsWithReconcile = newDepositPermissions;
        
        // Allow alice and bob for testing
        factoringPermissionsWithReconcile.allow(alice);
        factoringPermissionsWithReconcile.allow(bob);
        depositPermissionsWithReconcile.allow(alice);
        depositPermissionsWithReconcile.allow(bob);
    }

    function testPermissionsWithReconcileDeployment() public {
        assertEq(address(factoringPermissionsWithReconcile.bullaFactoringPool()), address(bullaFactoringWithReconcilePermissions));
        assertEq(factoringPermissionsWithReconcile.owner(), address(this));
        
        assertEq(address(depositPermissionsWithReconcile.bullaFactoringPool()), address(bullaFactoringWithReconcilePermissions));
        assertEq(depositPermissionsWithReconcile.owner(), address(this));
    }

    function testFactoringPermissionsAllowsWhenNoPaidInvoices() public {
        // Alice should be allowed when there are no paid invoices
        assertTrue(factoringPermissionsWithReconcile.isAllowed(alice));
        
        // Bob should be allowed when there are no paid invoices
        assertTrue(factoringPermissionsWithReconcile.isAllowed(bob));
        
        // User without permissions should not be allowed
        assertFalse(factoringPermissionsWithReconcile.isAllowed(userWithoutPermissions));
    }

    function testDepositPermissionsAllowsWhenNoPaidInvoices() public {
        // Alice should be allowed when there are no paid invoices
        assertTrue(depositPermissionsWithReconcile.isAllowed(alice));
        
        // Bob should be allowed when there are no paid invoices
        assertTrue(depositPermissionsWithReconcile.isAllowed(bob));
        
        // User without permissions should not be allowed
        assertFalse(depositPermissionsWithReconcile.isAllowed(userWithoutPermissions));
    }

    function testPermissionsRestoreAfterReconciliation() public {
        // Create and fund an invoice
        uint256 invoiceAmount = 1000;
        uint256 depositAmount = 2000;
        
        // Alice deposits funds
        vm.startPrank(alice);
        asset.mint(alice, depositAmount);
        asset.approve(address(bullaFactoringWithReconcilePermissions), depositAmount);
        bullaFactoringWithReconcilePermissions.deposit(depositAmount, alice);
        vm.stopPrank();

        // Create an invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice
        vm.startPrank(underwriter);
        bullaFactoringWithReconcilePermissions.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();

        // Bob funds the invoice
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoringWithReconcilePermissions), invoiceId);
        bullaFactoringWithReconcilePermissions.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();

        // Alice pays the invoice
        vm.startPrank(alice);
        uint256 paymentAmount = invoiceAmount;
        asset.mint(alice, paymentAmount);
        asset.approve(address(bullaClaim), paymentAmount);
        bullaClaim.payClaim(invoiceId, paymentAmount);
        vm.stopPrank();

        // Verify permissions are denied
        assertFalse(factoringPermissionsWithReconcile.isAllowed(alice), "Should deny before reconciliation");
        assertFalse(depositPermissionsWithReconcile.isAllowed(alice), "Should deny before reconciliation");

        // Reconcile the paid invoices
        bullaFactoringWithReconcilePermissions.reconcileActivePaidInvoices();

        // Check that there are no more paid invoices
        (uint256[] memory paidInvoices,) = bullaFactoringWithReconcilePermissions.viewPoolStatus();
        assertEq(paidInvoices.length, 0, "Should have no paid invoices after reconciliation");

        // Permissions should be restored
        assertTrue(factoringPermissionsWithReconcile.isAllowed(alice), "Should allow after reconciliation");
        assertTrue(depositPermissionsWithReconcile.isAllowed(alice), "Should allow after reconciliation");
    }

    function testOnlyOwnerCanAllowAndDisallow() public {
        // Test factoring permissions
        vm.startPrank(alice);
        vm.expectRevert();
        factoringPermissionsWithReconcile.allow(userWithoutPermissions);
        vm.expectRevert();
        factoringPermissionsWithReconcile.disallow(alice);
        vm.stopPrank();

        // Test deposit permissions
        vm.startPrank(alice);
        vm.expectRevert();
        depositPermissionsWithReconcile.allow(userWithoutPermissions);
        vm.expectRevert();
        depositPermissionsWithReconcile.disallow(alice);
        vm.stopPrank();

        // Owner should be able to allow/disallow
        factoringPermissionsWithReconcile.allow(userWithoutPermissions);
        assertTrue(factoringPermissionsWithReconcile.allowedAddresses(userWithoutPermissions));
        factoringPermissionsWithReconcile.disallow(userWithoutPermissions);
        assertFalse(factoringPermissionsWithReconcile.allowedAddresses(userWithoutPermissions));

        depositPermissionsWithReconcile.allow(userWithoutPermissions);
        assertTrue(depositPermissionsWithReconcile.allowedAddresses(userWithoutPermissions));
        depositPermissionsWithReconcile.disallow(userWithoutPermissions);
        assertFalse(depositPermissionsWithReconcile.allowedAddresses(userWithoutPermissions));
    }

    function testPermissionsWithMultiplePaidInvoices() public {
        uint256 invoiceAmount = 1000;
        uint256 depositAmount = 5000;
        
        // Alice deposits funds
        vm.startPrank(alice);
        asset.mint(alice, depositAmount);
        asset.approve(address(bullaFactoringWithReconcilePermissions), depositAmount);
        bullaFactoringWithReconcilePermissions.deposit(depositAmount, alice);
        vm.stopPrank();

        // Create and fund all invoices first (before any payments)
        uint256[] memory invoiceIds = new uint256[](3);
        
        for (uint i = 0; i < 3; i++) {
            // Create invoice
            vm.startPrank(bob);
            invoiceIds[i] = createClaim(bob, alice, invoiceAmount, dueBy);
            vm.stopPrank();

            // Underwriter approves
            vm.startPrank(underwriter);
            bullaFactoringWithReconcilePermissions.approveInvoice(invoiceIds[i], interestApr, upfrontBps, minDays);
            vm.stopPrank();

            // Bob funds the invoice
            vm.startPrank(bob);
            bullaClaimERC721.approve(address(bullaFactoringWithReconcilePermissions), invoiceIds[i]);
            bullaFactoringWithReconcilePermissions.fundInvoice(invoiceIds[i], upfrontBps);
            vm.stopPrank();
        }

        // Now pay all invoices
        for (uint i = 0; i < 3; i++) {
            vm.startPrank(alice);
            asset.mint(alice, invoiceAmount);
            asset.approve(address(bullaClaim), invoiceAmount);
            bullaClaim.payClaim(invoiceIds[i], invoiceAmount);
            vm.stopPrank();
        }

        // Check that there are multiple paid invoices
        (uint256[] memory paidInvoices,) = bullaFactoringWithReconcilePermissions.viewPoolStatus();
        assertEq(paidInvoices.length, 3, "Should have 3 paid invoices");

        // Permissions should be denied
        assertFalse(factoringPermissionsWithReconcile.isAllowed(alice));
        assertFalse(depositPermissionsWithReconcile.isAllowed(alice));

        // Reconcile all paid invoices
        bullaFactoringWithReconcilePermissions.reconcileActivePaidInvoices();

        // Permissions should be restored
        assertTrue(factoringPermissionsWithReconcile.isAllowed(alice));
        assertTrue(depositPermissionsWithReconcile.isAllowed(alice));
    }
} 