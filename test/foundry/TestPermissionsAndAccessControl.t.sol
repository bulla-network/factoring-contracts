// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoringV2_1 } from 'contracts/BullaFactoring.sol';
import { BullaFactoringVault } from 'contracts/BullaFactoringVault.sol';
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
        bullaFactoring.approveInvoice(InvoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(userWithoutPermissions);
        bullaClaim.approve(address(bullaFactoring), InvoiceId);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedFactoring(address)", userWithoutPermissions));
        bullaFactoring.fundInvoice(InvoiceId, upfrontBps, address(0));
        vm.stopPrank();
    }

    function testAragonDaoInteractionHappyPath() public {
        daoMock.setHasPermissionReturnValueMock(true);
        
        BullaFactoringVault vaultAragon = new BullaFactoringVault(asset, permissionsWithAragon, permissionsWithAragon, poolTokenName, poolTokenSymbol, address(0));
        BullaFactoringV2_1 bullaFactoringAragon = new BullaFactoringV2_1(vaultAragon, invoiceAdapterBulla, bullaFrendLend, underwriter, permissionsWithAragon, bullaDao, protocolFeeBps, adminFeeBps, poolName, targetYield);
        vaultAragon.setAssociatedFund(address(bullaFactoringAragon), true);

        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        asset.approve(address(vaultAragon), 1000 ether);
        vaultAragon.deposit(initialDeposit, alice);
        vm.stopPrank();
    }

        function testAragonDaoInteractionUnHappyPath() public {
        daoMock.setHasPermissionReturnValueMock(false);
        
        BullaFactoringVault vaultAragon = new BullaFactoringVault(asset, permissionsWithAragon, permissionsWithAragon, poolTokenName, poolTokenSymbol, address(0));
        BullaFactoringV2_1 bullaFactoringAragon = new BullaFactoringV2_1(vaultAragon, invoiceAdapterBulla, bullaFrendLend, underwriter, permissionsWithAragon, bullaDao, protocolFeeBps, adminFeeBps, poolName, targetYield);
        vaultAragon.setAssociatedFund(address(bullaFactoringAragon), true);

        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        asset.approve(address(vaultAragon), 1000 ether);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedDeposit(address)", alice));
        vaultAragon.deposit(initialDeposit, alice);
        vm.stopPrank();
    }

    function testGnosisPermissionsHappyPath() public {
        daoMock.setHasPermissionReturnValueMock(true);
        
        BullaFactoringVault vaultSafe = new BullaFactoringVault(asset, permissionsWithSafe, permissionsWithSafe, poolTokenName, poolTokenSymbol, address(0));
        BullaFactoringV2_1 bullaFactoringSafe = new BullaFactoringV2_1(vaultSafe, invoiceAdapterBulla, bullaFrendLend, underwriter, permissionsWithSafe, bullaDao, protocolFeeBps, adminFeeBps, poolName, targetYield);
        vaultSafe.setAssociatedFund(address(bullaFactoringSafe), true);

        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        asset.approve(address(vaultSafe), 1000 ether);
        vaultSafe.deposit(initialDeposit, alice);
        vm.stopPrank();
    }

    function testGnosisPermissionsUnHappyPath() public {
        daoMock.setHasPermissionReturnValueMock(true);
        
        BullaFactoringVault vaultSafe = new BullaFactoringVault(asset, permissionsWithSafe, permissionsWithSafe, poolTokenName, poolTokenSymbol, address(0));
        BullaFactoringV2_1 bullaFactoringSafe = new BullaFactoringV2_1(vaultSafe, invoiceAdapterBulla, bullaFrendLend, underwriter, permissionsWithSafe, bullaDao, protocolFeeBps, adminFeeBps, poolName, targetYield);
        vaultSafe.setAssociatedFund(address(bullaFactoringSafe), true);

        uint256 initialDeposit = 200000;
        vm.startPrank(bob);
        asset.approve(address(vaultSafe), 1000 ether);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedDeposit(address)", bob));
        vaultSafe.deposit(initialDeposit, bob);
        vm.stopPrank();
    }

    function testApproveDoesNotOverrideStorage() public {
        dueBy = block.timestamp + 30 days;
        uint256 invoiceAmount = 100000000000;
        interestApr = 1000; // 10% APR
        upfrontBps = 10000; // 100% upfront

        uint256 initialDeposit = 100000000000;
        vm.startPrank(alice);
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Creditor creates the invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Underwriter approves the invoice again
        vm.startPrank(underwriter);
        vm.expectRevert(abi.encodeWithSignature("InvoiceAlreadyFunded()"));
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
    }
}
