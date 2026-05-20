// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { CommonSetup } from './CommonSetup.t.sol';

contract TestViewPoolStatusPagination is CommonSetup {

    function testViewPoolStatusPaginationWithNoInvoices() public {
        // Call with pagination when there are no invoices
        (uint256[] memory impairedInvoiceIds, bool hasMore) = bullaFactoring.viewPoolStatus(0, 10);
        
        assertEq(impairedInvoiceIds.length, 0, "Should return empty array");
        assertFalse(hasMore, "Should not have more invoices");
    }

    function testViewPoolStatusPaginationFirstPage() public {
        // Alice deposits into the fund
        uint256 initialDeposit = 100000;
        vm.startPrank(alice);
        asset.approve(address(bullaFactoring), initialDeposit);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create 5 invoices, 3 will be impaired, 2 will not
        uint256[] memory invoiceIds = new uint256[](5);
        
        for (uint i = 0; i < 5; i++) {
            vm.prank(bob);
            invoiceIds[i] = createClaim(bob, alice, 100, dueBy);
            vm.startPrank(underwriter);
            _approveInvoice(invoiceIds[i], interestApr, spreadBps, upfrontBps, 0);
            vm.stopPrank();
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceIds[i]);
            _fundInvoice(invoiceIds[i], upfrontBps, address(0));
            vm.stopPrank();
        }

        // Fast forward to make all invoices impaired
        vm.warp(block.timestamp + 91 days);

        // Get first page with limit of 3
        (uint256[] memory impairedInvoiceIds, bool hasMore) = bullaFactoring.viewPoolStatus(0, 3);
        
        assertEq(impairedInvoiceIds.length, 3, "Should return 3 impaired invoices");
        assertTrue(hasMore, "Should have more invoices to check");
    }

    function testViewPoolStatusPaginationMultiplePages() public {
        // Alice deposits into the fund
        uint256 initialDeposit = 100000;
        vm.startPrank(alice);
        asset.approve(address(bullaFactoring), initialDeposit);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create 10 invoices
        uint256[] memory invoiceIds = new uint256[](10);
        
        for (uint i = 0; i < 10; i++) {
            vm.prank(bob);
            invoiceIds[i] = createClaim(bob, alice, 100, dueBy);
            vm.startPrank(underwriter);
            _approveInvoice(invoiceIds[i], interestApr, spreadBps, upfrontBps, 0);
            vm.stopPrank();
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceIds[i]);
            _fundInvoice(invoiceIds[i], upfrontBps, address(0));
            vm.stopPrank();
        }

        // Fast forward to make all invoices impaired
        vm.warp(block.timestamp + 91 days);

        // Get first page with limit of 4
        (uint256[] memory page1, bool hasMore1) = bullaFactoring.viewPoolStatus(0, 4);
        assertEq(page1.length, 4, "First page should have 4 impaired invoices");
        assertTrue(hasMore1, "Should have more invoices after first page");

        // Get second page with limit of 4
        (uint256[] memory page2, bool hasMore2) = bullaFactoring.viewPoolStatus(4, 4);
        assertEq(page2.length, 4, "Second page should have 4 impaired invoices");
        assertTrue(hasMore2, "Should have more invoices after second page");

        // Get third page with limit of 4 (only 2 remaining)
        (uint256[] memory page3, bool hasMore3) = bullaFactoring.viewPoolStatus(8, 4);
        assertEq(page3.length, 2, "Third page should have 2 impaired invoices");
        assertFalse(hasMore3, "Should not have more invoices after third page");

        // Verify no duplicates across pages
        for (uint i = 0; i < page1.length; i++) {
            for (uint j = 0; j < page2.length; j++) {
                assertTrue(page1[i] != page2[j], "Pages should not have duplicate invoices");
            }
        }
    }

    function testViewPoolStatusPaginationCapAt25000() public {
        // Test that limit is capped at 25000
        (uint256[] memory impairedInvoiceIds, bool hasMore) = bullaFactoring.viewPoolStatus(0, 50000);
        
        // Should not revert and should work (capped at 25000)
        assertEq(impairedInvoiceIds.length, 0, "Should return empty array");
        assertFalse(hasMore, "Should not have more invoices");
    }

    function testViewPoolStatusWithLargeLimit() public {
        // Alice deposits into the fund
        uint256 initialDeposit = 10000;
        vm.startPrank(alice);
        asset.approve(address(bullaFactoring), initialDeposit);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create 3 invoices
        for (uint i = 0; i < 3; i++) {
            vm.prank(bob);
            uint256 invoiceId = createClaim(bob, alice, 100, dueBy);
            vm.startPrank(underwriter);
            _approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
            vm.stopPrank();
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceId);
            _fundInvoice(invoiceId, upfrontBps, address(0));
            vm.stopPrank();
        }

        // Fast forward to make invoices impaired
        vm.warp(block.timestamp + 91 days);

        // Call with offset 0 and large limit
        (uint256[] memory allImpaired, bool hasMore) = bullaFactoring.viewPoolStatus(0, 25000);
        
        assertEq(allImpaired.length, 3, "Should return all 3 impaired invoices");
        assertFalse(hasMore, "Should not have more invoices");
    }

    function testViewPoolStatusPaginationMixedImpairedAndActive() public {
        // Alice deposits into the fund
        uint256 initialDeposit = 100000;
        vm.startPrank(alice);
        asset.approve(address(bullaFactoring), initialDeposit);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create 6 invoices
        uint256[] memory invoiceIds = new uint256[](6);
        
        for (uint i = 0; i < 6; i++) {
            vm.prank(bob);
            invoiceIds[i] = createClaim(bob, alice, 100, dueBy);
            vm.startPrank(underwriter);
            _approveInvoice(invoiceIds[i], interestApr, spreadBps, upfrontBps, 0);
            vm.stopPrank();
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceIds[i]);
            _fundInvoice(invoiceIds[i], upfrontBps, address(0));
            vm.stopPrank();
        }

        // Fast forward to make all impaired
        vm.warp(block.timestamp + 91 days);
        
        // Pay off 2 invoices to make them non-impaired (they'll be removed from active)
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceIds[0], 100);
        bullaClaim.payClaim(invoiceIds[1], 100);
        vm.stopPrank();

        // Get all with pagination - should only return the 4 still-active impaired invoices
        (uint256[] memory page1, bool hasMore) = bullaFactoring.viewPoolStatus(0, 25000);
        
        assertEq(page1.length, 4, "Should return 4 impaired invoices (2 were paid off)");
        assertFalse(hasMore, "Should not have more invoices");
    }

    function testActiveInvoicesVersionBumpsOnEveryMutation() public {
        address insurerAddr = address(0x1999);

        uint256 v0 = bullaFactoring.activeInvoicesVersion();

        // Fund Alice's deposit pool
        vm.prank(alice);
        bullaFactoring.deposit(1_000_000, alice);

        // ---- add (fund) ----
        vm.prank(bob);
        uint256 invoiceA = createClaim(bob, alice, 100_000, dueBy);
        vm.prank(underwriter);
        _approveInvoice(invoiceA, interestApr, spreadBps, upfrontBps, 0);
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceA);
        _fundInvoice(invoiceA, upfrontBps, address(0));
        vm.stopPrank();

        uint256 v1 = bullaFactoring.activeInvoicesVersion();
        assertEq(v1, v0 + 1, "version must bump on fund (add)");

        // ---- remove (unfactor) ----
        vm.prank(bob);
        asset.approve(address(bullaFactoring), type(uint256).max);
        vm.prank(bob);
        bullaFactoring.unfactorInvoice(invoiceA);

        uint256 v2 = bullaFactoring.activeInvoicesVersion();
        assertEq(v2, v1 + 1, "version must bump on unfactor (remove)");

        // Fund a fresh invoice we'll use to test impair- and reconcile-driven removes
        vm.prank(bob);
        uint256 invoiceB = createClaim(bob, alice, 100_000, dueBy);
        vm.prank(underwriter);
        _approveInvoice(invoiceB, interestApr, spreadBps, upfrontBps, 0);
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceB);
        _fundInvoice(invoiceB, upfrontBps, address(0));
        vm.stopPrank();
        uint256 v3 = bullaFactoring.activeInvoicesVersion();
        assertEq(v3, v2 + 1, "version must bump on second fund (add)");

        // ---- remove (impair) ----
        vm.warp(block.timestamp + 91 days);
        // Cover any out-of-pocket cost for the insurer (premium < grossGain on a single invoice).
        asset.mint(insurerAddr, 100_000);
        vm.prank(insurerAddr);
        asset.approve(address(bullaFactoring), type(uint256).max);
        vm.prank(insurerAddr);
        bullaFactoring.impairInvoice(invoiceB);

        uint256 v4 = bullaFactoring.activeInvoicesVersion();
        assertEq(v4, v3 + 1, "version must bump on impair (remove)");

        // ---- remove (reconcile after payment) ----
        vm.prank(bob);
        uint256 invoiceC = createClaim(bob, alice, 100_000, block.timestamp + 30 days);
        vm.prank(underwriter);
        _approveInvoice(invoiceC, interestApr, spreadBps, upfrontBps, 0);
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceC);
        _fundInvoice(invoiceC, upfrontBps, address(0));
        vm.stopPrank();
        uint256 v5 = bullaFactoring.activeInvoicesVersion();
        assertEq(v5, v4 + 1, "version must bump on third fund (add)");

        // payClaim triggers reconcileSingleInvoice via the set-paid callback registered at funding,
        // which removes the invoice from _activeInvoices and bumps the version.
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 100_000);
        bullaClaim.payClaim(invoiceC, 100_000);
        vm.stopPrank();

        uint256 v6 = bullaFactoring.activeInvoicesVersion();
        assertEq(v6, v5 + 1, "version must bump on reconcile (remove)");
    }
}

