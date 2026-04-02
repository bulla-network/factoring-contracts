// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoringV2_2 } from 'contracts/BullaFactoring.sol';
import { PermissionsWithAragon } from 'contracts/PermissionsWithAragon.sol';
import { PermissionsWithSafe } from 'contracts/PermissionsWithSafe.sol';
import { BullaClaimV2InvoiceProviderAdapterV2 } from 'contracts/BullaClaimV2InvoiceProviderAdapterV2.sol';
import { MockUSDC } from 'contracts/mocks/MockUSDC.sol';
import { MockPermissions } from 'contracts/mocks/MockPermissions.sol';
import { DAOMock } from 'contracts/mocks/DAOMock.sol';
import { TestSafe } from 'contracts/mocks/gnosisSafe.sol';
import "@bulla-network/contracts/contracts/interfaces/IBullaClaim.sol";
import "../../contracts/interfaces/IInvoiceProviderAdapter.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "contracts/interfaces/IBullaFactoring.sol";

import { CommonSetup } from './CommonSetup.t.sol';


contract TestPermissionsAndAccessControl is CommonSetup {
    function testWhitelistFactoring() public {
        uint invoiceId01Amount = 100;
        vm.startPrank(userWithoutPermissions);
        uint256 InvoiceId = createClaim(userWithoutPermissions, alice, invoiceId01Amount, dueBy);
        vm.stopPrank();
        vm.startPrank(underwriter);
        _approveInvoice(InvoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(userWithoutPermissions);
        bullaClaim.approve(address(bullaFactoring), InvoiceId);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedFactoring(address)", userWithoutPermissions));
        _fundInvoiceExpectRevert(InvoiceId, upfrontBps, address(0));
        vm.stopPrank();
    }

    function testAragonDaoInteractionHappyPath() public {
        daoMock.setHasPermissionReturnValueMock(true);
        
        BullaFactoringV2_2 bullaFactoringAragon = new BullaFactoringV2_2(asset, invoiceAdapterBulla, bullaFrendLend, underwriter, permissionsWithAragon, permissionsWithAragon, permissionsWithAragon, bullaDao ,protocolFeeBps, adminFeeBps, poolName, targetYield, poolTokenName, poolTokenSymbol, address(0x1999), uint16(100), uint16(500), uint16(5000));

        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        asset.approve(address(bullaFactoringAragon), 1000 ether);
        bullaFactoringAragon.deposit(initialDeposit, alice);
        vm.stopPrank();
    }

        function testAragonDaoInteractionUnHappyPath() public {
        daoMock.setHasPermissionReturnValueMock(false);
        
        BullaFactoringV2_2 bullaFactoringAragon = new BullaFactoringV2_2(asset, invoiceAdapterBulla, bullaFrendLend, underwriter, permissionsWithAragon, permissionsWithAragon, permissionsWithAragon, bullaDao ,protocolFeeBps, adminFeeBps, poolName, targetYield, poolTokenName, poolTokenSymbol, address(0x1999), uint16(100), uint16(500), uint16(5000));

        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        asset.approve(address(bullaFactoringAragon), 1000 ether);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedDeposit(address)", alice));
        bullaFactoringAragon.deposit(initialDeposit, alice);
        vm.stopPrank();
    }

    function testGnosisPermissionsHappyPath() public {
        daoMock.setHasPermissionReturnValueMock(true);
        
        BullaFactoringV2_2 bullaFactoringSafe = new BullaFactoringV2_2(asset, invoiceAdapterBulla, bullaFrendLend, underwriter, permissionsWithSafe, permissionsWithSafe, permissionsWithSafe, bullaDao ,protocolFeeBps, adminFeeBps, poolName, targetYield, poolTokenName, poolTokenSymbol, address(0x1999), uint16(100), uint16(500), uint16(5000));

        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        asset.approve(address(bullaFactoringSafe), 1000 ether);
        bullaFactoringSafe.deposit(initialDeposit, alice);
        vm.stopPrank();
    }

    function testGnosisPermissionsUnHappyPath() public {
        daoMock.setHasPermissionReturnValueMock(true);
        
        BullaFactoringV2_2 bullaFactoringSafe = new BullaFactoringV2_2(asset, invoiceAdapterBulla, bullaFrendLend, underwriter, permissionsWithSafe, permissionsWithSafe, permissionsWithSafe, bullaDao ,protocolFeeBps, adminFeeBps, poolName, targetYield, poolTokenName, poolTokenSymbol, address(0x1999), uint16(100), uint16(500), uint16(5000));

        uint256 initialDeposit = 200000;
        vm.startPrank(bob);
        asset.approve(address(bullaFactoringSafe), 1000 ether);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedDeposit(address)", bob));
        bullaFactoringSafe.deposit(initialDeposit, bob);
        vm.stopPrank();
    }

    function testReceiverAddressNotInFactoringPermissionsReverts() public {
        // Setup: deposit liquidity
        uint256 initialDeposit = 100000000000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // bob creates an invoice (bob is allowed in factoringPermissions)
        dueBy = block.timestamp + 30 days;
        uint256 invoiceAmount = 1000000;
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice
        vm.startPrank(underwriter);
        _approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        // bob tries to fund invoice with charlie as receiver (charlie is NOT in factoringPermissions)
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedReceiverAddress(address)", charlie));
        _fundInvoiceExpectRevert(invoiceId, upfrontBps, charlie);
        vm.stopPrank();
    }

    function testReceiverAddressInFactoringPermissionsSucceeds() public {
        // Setup: deposit liquidity
        uint256 initialDeposit = 100000000000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Allow alice in factoring permissions so she can be a receiver
        factoringPermissions.allow(alice);

        // bob creates an invoice (bob is allowed in factoringPermissions)
        dueBy = block.timestamp + 30 days;
        uint256 invoiceAmount = 1000000;
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice
        vm.startPrank(underwriter);
        _approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        // bob funds invoice with alice as receiver (alice IS in factoringPermissions)
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        uint256 fundedAmount = _fundInvoice(invoiceId, upfrontBps, alice);
        vm.stopPrank();

        assertGt(fundedAmount, 0, "Funded amount should be greater than 0");
    }

    function testReceiverAddressZeroSucceeds() public {
        // Setup: deposit liquidity
        uint256 initialDeposit = 100000000000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // bob creates an invoice (bob is allowed in factoringPermissions)
        dueBy = block.timestamp + 30 days;
        uint256 invoiceAmount = 1000000;
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice
        vm.startPrank(underwriter);
        _approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        // bob funds invoice with address(0) as receiver (should default to msg.sender = bob, skip permission check)
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        uint256 fundedAmount = _fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        assertGt(fundedAmount, 0, "Funded amount should be greater than 0");
    }

    function testApproveDoesNotOverrideStorage() public {
        dueBy = block.timestamp + 30 days;
        uint256 invoiceAmount = 100000000000;
        interestApr = 1000; // 10% APR
        upfrontBps = 10000; // 100% upfront

        uint256 initialDeposit = 100000000000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Creditor creates the invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice
        vm.startPrank(underwriter);
        _approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        _fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Underwriter approves the invoice again
        vm.startPrank(underwriter);
        vm.expectRevert(abi.encodeWithSignature("InvoiceAlreadyFunded()"));
        _approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
    }
}
