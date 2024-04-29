
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
import "@bulla-network/contracts/interfaces/IBullaClaim.sol";
import "../../contracts/interfaces/IInvoiceProviderAdapter.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "contracts/interfaces/IBullaFactoring.sol";

contract CommonSetup is Test {
    BullaFactoring public bullaFactoring;
    BullaClaimInvoiceProviderAdapter public invoiceAdapterBulla;
    MockUSDC public asset;
    MockPermissions public depositPermissions;
    MockPermissions public factoringPermissions;
    PermissionsWithAragon public permissionsWithAragon;
    DAOMock public daoMock;
    PermissionsWithSafe public permissionsWithSafe;
    TestSafe public testSafe;
    IBullaClaim bullaClaim = IBullaClaim(0x3702D060cbB102b6AebF40B40880F77BeF3d7225); // contract address on SEPOLIA
    IERC721 bullaClaimERC721 = IERC721(0x3702D060cbB102b6AebF40B40880F77BeF3d7225); // required to use approve & transferFrom functions

    address alice = address(0xA11c3);
    address bob = address(0xb0b);
    address underwriter = address(0x1222);
    address userWithoutPermissions = address(0x743123);

    uint16 interestApr = 1000;
    uint16 upfrontBps = 8000;
    uint256 dueBy = block.timestamp + 30 days;
    uint16 minDays = 30;

    address bullaDao = address(this);
    uint16 protocolFeeBps = 25;
    uint16 adminFeeBps = 50;
    uint16 taxBps = 10;
    uint16 targetYield = 730;

    string poolName = 'Test Pool';
    string poolTokenName = 'Test Bulla Factoring Pool Token';
    string poolTokenSymbol = 'BFT-Test';

    function setUp() public {
        asset = new MockUSDC();
        invoiceAdapterBulla = new BullaClaimInvoiceProviderAdapter(bullaClaim);
        depositPermissions = new MockPermissions();
        factoringPermissions = new MockPermissions();
        daoMock = new DAOMock();
        address[] memory safeOwners = new address[](2);
        safeOwners[0] = alice;
        safeOwners[1] = address(this);
        testSafe = new TestSafe(safeOwners, uint8(2));
        bytes32 ALLOW_PERMISSION_ID = keccak256("ALLOW_PERMISSION");
        permissionsWithAragon = new PermissionsWithAragon(address(daoMock), ALLOW_PERMISSION_ID);
        permissionsWithSafe = new PermissionsWithSafe(address(testSafe));

        // Allow alice and bob for deposits, and bob for factoring
        depositPermissions.allow(alice);
        depositPermissions.allow(bob);
        factoringPermissions.allow(bob);
        factoringPermissions.allow(address(this));

        bullaFactoring = new BullaFactoring(asset, invoiceAdapterBulla, underwriter, depositPermissions, factoringPermissions, bullaDao ,protocolFeeBps, adminFeeBps, poolName, taxBps, targetYield, poolTokenName, poolTokenSymbol);

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

    function calculateKickbackAmount(uint256 invoiceId, uint fundedTimestamp, uint16 apr, uint fundedAmount) public view returns (uint256) {
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

}