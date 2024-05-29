// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoring } from 'contracts/BullaFactoring.sol';
import { PermissionsWithAragon } from 'contracts/PermissionsWithAragon.sol';
import { PermissionsWithSafe } from 'contracts/PermissionsWithSafe.sol';
import { BullaClaimInvoiceProviderAdapter } from 'contracts/BullaClaimInvoiceProviderAdapter.sol';
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
        bullaFactoring.approveInvoice(InvoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(userWithoutPermissions);
        bullaClaimERC721.approve(address(bullaFactoring), InvoiceId);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedFactoring(address)", userWithoutPermissions));
        bullaFactoring.fundInvoice(InvoiceId, upfrontBps);
        vm.stopPrank();
    }

    function testAragonDaoInteractionHappyPath() public {
        daoMock.setHasPermissionReturnValueMock(true);
        
        BullaFactoring bullaFactoringAragon = new BullaFactoring(asset, invoiceAdapterBulla, underwriter, permissionsWithAragon, permissionsWithAragon, bullaDao ,protocolFeeBps, adminFeeBps, poolName, taxBps, targetYield, poolTokenName, poolTokenSymbol) ;

        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        asset.approve(address(bullaFactoringAragon), 1000 ether);
        bullaFactoringAragon.deposit(initialDeposit, alice);
        vm.stopPrank();
    }

        function testAragonDaoInteractionUnHappyPath() public {
        daoMock.setHasPermissionReturnValueMock(false);
        
        BullaFactoring bullaFactoringAragon = new BullaFactoring(asset, invoiceAdapterBulla, underwriter, permissionsWithAragon, permissionsWithAragon, bullaDao ,protocolFeeBps, adminFeeBps, poolName, taxBps, targetYield, poolTokenName, poolTokenSymbol) ;

        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        asset.approve(address(bullaFactoringAragon), 1000 ether);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedDeposit(address)", alice));
        bullaFactoringAragon.deposit(initialDeposit, alice);
        vm.stopPrank();
    }

    function testGnosisPermissionsHappyPath() public {
        daoMock.setHasPermissionReturnValueMock(true);
        
        BullaFactoring bullaFactoringSafe = new BullaFactoring(asset, invoiceAdapterBulla, underwriter, permissionsWithSafe, permissionsWithSafe, bullaDao ,protocolFeeBps, adminFeeBps, poolName, taxBps, targetYield, poolTokenName, poolTokenSymbol) ;

        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        asset.approve(address(bullaFactoringSafe), 1000 ether);
        bullaFactoringSafe.deposit(initialDeposit, alice);
        vm.stopPrank();
    }

    function testGnosisPermissionsUnHappyPath() public {
        daoMock.setHasPermissionReturnValueMock(true);
        
        BullaFactoring bullaFactoringSafe = new BullaFactoring(asset, invoiceAdapterBulla, underwriter, permissionsWithSafe, permissionsWithSafe, bullaDao ,protocolFeeBps, adminFeeBps, poolName, taxBps, targetYield, poolTokenName, poolTokenSymbol) ;

        uint256 initialDeposit = 200000;
        vm.startPrank(bob);
        asset.approve(address(bullaFactoringSafe), 1000 ether);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedDeposit(address)", bob));
        bullaFactoringSafe.deposit(initialDeposit, bob);
        vm.stopPrank();
    }
}