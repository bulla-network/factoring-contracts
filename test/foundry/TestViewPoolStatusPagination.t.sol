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
            bullaFactoring.approveInvoice(invoiceIds[i], interestApr, spreadBps, upfrontBps, 0);
            vm.stopPrank();
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceIds[i]);
            bullaFactoring.fundInvoice(invoiceIds[i], upfrontBps, address(0));
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
            bullaFactoring.approveInvoice(invoiceIds[i], interestApr, spreadBps, upfrontBps, 0);
            vm.stopPrank();
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceIds[i]);
            bullaFactoring.fundInvoice(invoiceIds[i], upfrontBps, address(0));
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
            bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
            vm.stopPrank();
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceId);
            bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
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
            bullaFactoring.approveInvoice(invoiceIds[i], interestApr, spreadBps, upfrontBps, 0);
            vm.stopPrank();
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceIds[i]);
            bullaFactoring.fundInvoice(invoiceIds[i], upfrontBps, address(0));
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
}

