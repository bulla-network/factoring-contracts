// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoringFactoryV2_1 } from 'contracts/BullaFactoringFactoryV2_1.sol';
import { BullaFactoringV2_1 } from 'contracts/BullaFactoring.sol';
import { DepositPermissions } from 'contracts/DepositPermissions.sol';
import { FactoringPermissions } from 'contracts/FactoringPermissions.sol';
import { Permissions } from 'contracts/Permissions.sol';
import { BullaClaimV2InvoiceProviderAdapterV2 } from 'contracts/BullaClaimV2InvoiceProviderAdapterV2.sol';
import { MockUSDC } from 'contracts/mocks/MockUSDC.sol';
import { MockPermissions } from 'contracts/mocks/MockPermissions.sol';
import { IInvoiceProviderAdapterV2 } from 'contracts/interfaces/IInvoiceProviderAdapter.sol';
import { IBullaFrendLendV2 } from 'bulla-contracts-v2/src/interfaces/IBullaFrendLendV2.sol';
import { BullaFrendLendV2 } from 'bulla-contracts-v2/src/BullaFrendLendV2.sol';
import { BullaControllerRegistry } from 'bulla-contracts-v2/src/BullaControllerRegistry.sol';
import { BullaClaimV2 } from 'bulla-contracts-v2/src/BullaClaimV2.sol';
import { BullaApprovalRegistry } from 'bulla-contracts-v2/src/BullaApprovalRegistry.sol';
import { BullaInvoice } from 'bulla-contracts-v2/src/BullaInvoice.sol';
import { IBullaClaimV2, LockState } from 'bulla-contracts-v2/src/interfaces/IBullaClaimV2.sol';
import '@openzeppelin/contracts/access/Ownable.sol';

contract TestBullaFactoringFactoryV2_1 is Test {
    BullaFactoringFactoryV2_1 public factory;
    BullaClaimV2InvoiceProviderAdapterV2 public invoiceAdapter;
    MockUSDC public usdc;
    MockUSDC public usdt;
    MockPermissions public feeExemptionWhitelist;
    
    BullaControllerRegistry public bullaControllerRegistry;
    BullaApprovalRegistry public bullaApprovalRegistry;
    IBullaFrendLendV2 public bullaFrendLend;
    IBullaClaimV2 public bullaClaim;
    BullaInvoice public bullaInvoice;

    address bullaDao = address(0xDA0);
    address poolCreator = address(0x1111);
    address underwriter = address(0x2222);
    address depositor1 = address(0x3333);
    address depositor2 = address(0x4444);
    address factorer1 = address(0x5555);
    address randomUser = address(0x6666);

    uint16 protocolFeeBps = 20;

    event PoolCreated(
        address indexed pool,
        address indexed owner,
        address indexed asset,
        string poolName,
        string tokenName,
        string tokenSymbol,
        address depositPermissions,
        address redeemPermissions,
        address factoringPermissions
    );

    event InvoiceProviderAdapterChanged(address indexed oldAdapter, address indexed newAdapter);
    event BullaFrendLendChanged(address indexed oldAddress, address indexed newAddress);
    event ProtocolFeeBpsChanged(uint16 oldProtocolFeeBps, uint16 newProtocolFeeBps);
    event AssetWhitelistChanged(address indexed asset, bool allowed);
    event PoolCreationFeeChanged(uint256 oldFee, uint256 newFee);
    event FeesWithdrawn(address indexed to, uint256 amount);

    function setUp() public {
        // Deploy mock tokens
        usdc = new MockUSDC();
        usdt = new MockUSDC();

        // Deploy Bulla infrastructure
        feeExemptionWhitelist = new MockPermissions();
        bullaControllerRegistry = new BullaControllerRegistry();
        bullaApprovalRegistry = new BullaApprovalRegistry(address(bullaControllerRegistry));
        bullaClaim = new BullaClaimV2(address(bullaApprovalRegistry), LockState.Unlocked, 0, address(feeExemptionWhitelist));
        bullaFrendLend = new BullaFrendLendV2(address(bullaClaim), address(this), 50, 0);
        bullaInvoice = new BullaInvoice(address(bullaClaim), address(this), 50);
        invoiceAdapter = new BullaClaimV2InvoiceProviderAdapterV2(address(bullaClaim), address(bullaFrendLend), address(bullaInvoice));
        bullaApprovalRegistry.setAuthorizedContract(address(bullaClaim), true);

        // Deploy factory with bullaDao as owner
        factory = new BullaFactoringFactoryV2_1(
            IInvoiceProviderAdapterV2(address(invoiceAdapter)),
            bullaFrendLend,
            bullaDao,
            protocolFeeBps
        );

        // Whitelist USDC as allowed asset
        vm.prank(bullaDao);
        factory.allowAsset(address(usdc));

        // Fund accounts
        vm.deal(poolCreator, 10 ether);
        vm.deal(randomUser, 10 ether);
    }

    // ============ Constructor Tests ============

    function test_constructor_setsCorrectValues() public view {
        assertEq(address(factory.invoiceProviderAdapter()), address(invoiceAdapter));
        assertEq(address(factory.bullaFrendLend()), address(bullaFrendLend));
        assertEq(factory.protocolFeeBps(), protocolFeeBps);
        assertEq(factory.owner(), bullaDao);
    }

    function test_constructor_revertsOnZeroAdapter() public {
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidAddress.selector);
        new BullaFactoringFactoryV2_1(
            IInvoiceProviderAdapterV2(address(0)),
            bullaFrendLend,
            bullaDao,
            protocolFeeBps
        );
    }

    function test_constructor_revertsOnZeroOwner() public {
        // OpenZeppelin's Ownable reverts first with OwnableInvalidOwner
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new BullaFactoringFactoryV2_1(
            IInvoiceProviderAdapterV2(address(invoiceAdapter)),
            bullaFrendLend,
            address(0),
            protocolFeeBps
        );
    }

    function test_constructor_revertsOnInvalidProtocolFee() public {
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidPercentage.selector);
        new BullaFactoringFactoryV2_1(
            IInvoiceProviderAdapterV2(address(invoiceAdapter)),
            bullaFrendLend,
            bullaDao,
            10001 // > 100%
        );
    }

    // ============ createPool Tests ============

    function test_createPool_deploysPoolWithCorrectProperties() public {
        address[] memory depositors = new address[](0);
        address[] memory factorers = new address[](0);

        vm.prank(poolCreator);
        (address pool, address depositPerms, address factoringPerms) = factory.createPool(
            usdc,
            underwriter,
            50, // adminFeeBps
            "Test Pool",
            800, // targetYieldBps
            "Test Pool Token",
            "TPT",
            depositors,
            factorers
        );

        // Verify pool properties
        BullaFactoringV2_1 poolContract = BullaFactoringV2_1(pool);
        assertEq(address(poolContract.assetAddress()), address(usdc));
        assertEq(poolContract.underwriter(), underwriter);
        assertEq(poolContract.adminFeeBps(), 50);
        assertEq(poolContract.poolName(), "Test Pool");
        assertEq(poolContract.targetYieldBps(), 800);
        assertEq(poolContract.name(), "Test Pool Token");
        assertEq(poolContract.symbol(), "TPT");
        assertEq(poolContract.protocolFeeBps(), protocolFeeBps);
        assertEq(poolContract.bullaDao(), bullaDao); // owner() is used as bullaDao for pools

        // Verify ownership transferred to caller
        assertEq(poolContract.owner(), poolCreator);

        // Verify permissions contracts exist
        assertTrue(depositPerms != address(0));
        assertTrue(factoringPerms != address(0));

        // Verify pool added to factory
        assertEq(factory.getPoolCount(), 1);
        assertEq(factory.pools(0), pool);
    }

    function test_createPool_emitsPoolCreatedEvent() public {
        address[] memory depositors = new address[](0);
        address[] memory factorers = new address[](0);

        vm.prank(poolCreator);
        vm.expectEmit(false, true, true, false); // Don't check pool address (unknown before creation)
        emit PoolCreated(
            address(0), // Will be replaced
            poolCreator,
            address(usdc),
            "Test Pool",
            "Test Pool Token",
            "TPT",
            address(0), // Will be replaced
            address(0), // Will be replaced
            address(0)  // Will be replaced
        );
        
        factory.createPool(
            usdc,
            underwriter,
            50,
            "Test Pool",
            800,
            "Test Pool Token",
            "TPT",
            depositors,
            factorers
        );
    }

    function test_createPool_whitelistsDepositors() public {
        address[] memory depositors = new address[](2);
        depositors[0] = depositor1;
        depositors[1] = depositor2;
        address[] memory factorers = new address[](0);

        vm.prank(poolCreator);
        (, address depositPerms,) = factory.createPool(
            usdc,
            underwriter,
            50,
            "Test Pool",
            800,
            "Test Pool Token",
            "TPT",
            depositors,
            factorers
        );

        // Verify depositors are whitelisted
        DepositPermissions perms = DepositPermissions(depositPerms);
        assertTrue(perms.isAllowed(depositor1));
        assertTrue(perms.isAllowed(depositor2));
        assertFalse(perms.isAllowed(randomUser));
    }

    function test_createPool_whitelistsFactorers() public {
        address[] memory depositors = new address[](0);
        address[] memory factorers = new address[](1);
        factorers[0] = factorer1;

        vm.prank(poolCreator);
        (,, address factoringPerms) = factory.createPool(
            usdc,
            underwriter,
            50,
            "Test Pool",
            800,
            "Test Pool Token",
            "TPT",
            depositors,
            factorers
        );

        // Verify factorers are whitelisted
        FactoringPermissions perms = FactoringPermissions(factoringPerms);
        assertTrue(perms.isAllowed(factorer1));
        assertFalse(perms.isAllowed(randomUser));
    }

    function test_createPool_transfersPermissionsOwnershipToCaller() public {
        address[] memory depositors = new address[](0);
        address[] memory factorers = new address[](0);

        vm.prank(poolCreator);
        (, address depositPerms, address factoringPerms) = factory.createPool(
            usdc,
            underwriter,
            50,
            "Test Pool",
            800,
            "Test Pool Token",
            "TPT",
            depositors,
            factorers
        );

        // Verify ownership transferred to caller
        assertEq(DepositPermissions(depositPerms).owner(), poolCreator);
        assertEq(FactoringPermissions(factoringPerms).owner(), poolCreator);
    }

    function test_createPool_depositPermissionsEqualsRedeemPermissions() public {
        address[] memory depositors = new address[](0);
        address[] memory factorers = new address[](0);

        vm.prank(poolCreator);
        (address pool, address depositPerms,) = factory.createPool(
            usdc,
            underwriter,
            50,
            "Test Pool",
            800,
            "Test Pool Token",
            "TPT",
            depositors,
            factorers
        );

        // Verify depositPermissions == redeemPermissions
        BullaFactoringV2_1 poolContract = BullaFactoringV2_1(pool);
        assertEq(address(poolContract.depositPermissions()), depositPerms);
        assertEq(address(poolContract.redeemPermissions()), depositPerms);
    }

    function test_createPool_revertsOnDisallowedAsset() public {
        address[] memory depositors = new address[](0);
        address[] memory factorers = new address[](0);

        vm.prank(poolCreator);
        vm.expectRevert(abi.encodeWithSelector(BullaFactoringFactoryV2_1.AssetNotAllowed.selector, address(usdt)));
        factory.createPool(
            usdt, // Not whitelisted
            underwriter,
            50,
            "Test Pool",
            800,
            "Test Pool Token",
            "TPT",
            depositors,
            factorers
        );
    }

    function test_createPool_revertsOnZeroAsset() public {
        address[] memory depositors = new address[](0);
        address[] memory factorers = new address[](0);

        vm.prank(poolCreator);
        vm.expectRevert(abi.encodeWithSelector(BullaFactoringFactoryV2_1.AssetNotAllowed.selector, address(0)));
        factory.createPool(
            MockUSDC(address(0)),
            underwriter,
            50,
            "Test Pool",
            800,
            "Test Pool Token",
            "TPT",
            depositors,
            factorers
        );
    }

    function test_createPool_revertsOnZeroUnderwriter() public {
        address[] memory depositors = new address[](0);
        address[] memory factorers = new address[](0);

        vm.prank(poolCreator);
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidAddress.selector);
        factory.createPool(
            usdc,
            address(0),
            50,
            "Test Pool",
            800,
            "Test Pool Token",
            "TPT",
            depositors,
            factorers
        );
    }

    // ============ createPoolWithPermissions Tests ============

    function test_createPoolWithPermissions_deploysWithCustomPermissions() public {
        MockPermissions customDeposit = new MockPermissions();
        MockPermissions customRedeem = new MockPermissions();
        MockPermissions customFactoring = new MockPermissions();

        customDeposit.allow(depositor1);
        customRedeem.allow(depositor2);
        customFactoring.allow(factorer1);

        vm.prank(poolCreator);
        address pool = factory.createPoolWithPermissions(
            usdc,
            underwriter,
            50,
            "Test Pool",
            800,
            "Test Pool Token",
            "TPT",
            Permissions(address(customDeposit)),
            Permissions(address(customRedeem)),
            Permissions(address(customFactoring))
        );

        // Verify permissions are set correctly
        BullaFactoringV2_1 poolContract = BullaFactoringV2_1(pool);
        assertEq(address(poolContract.depositPermissions()), address(customDeposit));
        assertEq(address(poolContract.redeemPermissions()), address(customRedeem));
        assertEq(address(poolContract.factoringPermissions()), address(customFactoring));

        // Verify ownership transferred
        assertEq(poolContract.owner(), poolCreator);
    }

    function test_createPoolWithPermissions_allowsDifferentDepositAndRedeemPermissions() public {
        MockPermissions customDeposit = new MockPermissions();
        MockPermissions customRedeem = new MockPermissions();
        MockPermissions customFactoring = new MockPermissions();

        vm.prank(poolCreator);
        address pool = factory.createPoolWithPermissions(
            usdc,
            underwriter,
            50,
            "Test Pool",
            800,
            "Test Pool Token",
            "TPT",
            Permissions(address(customDeposit)),
            Permissions(address(customRedeem)),
            Permissions(address(customFactoring))
        );

        BullaFactoringV2_1 poolContract = BullaFactoringV2_1(pool);
        assertTrue(address(poolContract.depositPermissions()) != address(poolContract.redeemPermissions()));
    }

    function test_createPoolWithPermissions_revertsOnZeroPermissions() public {
        MockPermissions validPerms = new MockPermissions();

        vm.startPrank(poolCreator);

        // Zero deposit permissions
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidAddress.selector);
        factory.createPoolWithPermissions(
            usdc, underwriter, 50, "Test", 800, "Test", "T",
            Permissions(address(0)),
            Permissions(address(validPerms)),
            Permissions(address(validPerms))
        );

        // Zero redeem permissions
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidAddress.selector);
        factory.createPoolWithPermissions(
            usdc, underwriter, 50, "Test", 800, "Test", "T",
            Permissions(address(validPerms)),
            Permissions(address(0)),
            Permissions(address(validPerms))
        );

        // Zero factoring permissions
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidAddress.selector);
        factory.createPoolWithPermissions(
            usdc, underwriter, 50, "Test", 800, "Test", "T",
            Permissions(address(validPerms)),
            Permissions(address(validPerms)),
            Permissions(address(0))
        );

        vm.stopPrank();
    }

    // ============ Pool Creation Fee Tests ============

    function test_poolCreationFee_defaultsToZero() public view {
        assertEq(factory.poolCreationFee(), 0);
    }

    function test_poolCreationFee_canBeSetByOwner() public {
        vm.prank(bullaDao);
        vm.expectEmit(true, true, true, true);
        emit PoolCreationFeeChanged(0, 0.1 ether);
        factory.setPoolCreationFee(0.1 ether);

        assertEq(factory.poolCreationFee(), 0.1 ether);
    }

    function test_poolCreationFee_revertsWhenNonOwnerSets() public {
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomUser));
        factory.setPoolCreationFee(0.1 ether);
    }

    function test_createPool_requiresExactFee() public {
        // Set fee
        vm.prank(bullaDao);
        factory.setPoolCreationFee(0.1 ether);

        address[] memory depositors = new address[](0);
        address[] memory factorers = new address[](0);

        // Try to create without fee
        vm.prank(poolCreator);
        vm.expectRevert(abi.encodeWithSelector(BullaFactoringFactoryV2_1.IncorrectFee.selector, 0.1 ether, 0));
        factory.createPool(
            usdc, underwriter, 50, "Test", 800, "Test", "T",
            depositors, factorers
        );

        // Try with insufficient fee
        vm.prank(poolCreator);
        vm.expectRevert(abi.encodeWithSelector(BullaFactoringFactoryV2_1.IncorrectFee.selector, 0.1 ether, 0.05 ether));
        factory.createPool{value: 0.05 ether}(
            usdc, underwriter, 50, "Test", 800, "Test", "T",
            depositors, factorers
        );

        // Try with excess fee
        vm.prank(poolCreator);
        vm.expectRevert(abi.encodeWithSelector(BullaFactoringFactoryV2_1.IncorrectFee.selector, 0.1 ether, 0.5 ether));
        factory.createPool{value: 0.5 ether}(
            usdc, underwriter, 50, "Test", 800, "Test", "T",
            depositors, factorers
        );

        // Success with exact fee
        vm.prank(poolCreator);
        (address pool,,) = factory.createPool{value: 0.1 ether}(
            usdc, underwriter, 50, "Test", 800, "Test", "T",
            depositors, factorers
        );
        assertTrue(pool != address(0));
        assertEq(address(factory).balance, 0.1 ether);
    }

    function test_createPoolWithPermissions_requiresExactFee() public {
        vm.prank(bullaDao);
        factory.setPoolCreationFee(0.1 ether);

        MockPermissions perms = new MockPermissions();

        // No fee
        vm.prank(poolCreator);
        vm.expectRevert(abi.encodeWithSelector(BullaFactoringFactoryV2_1.IncorrectFee.selector, 0.1 ether, 0));
        factory.createPoolWithPermissions(
            usdc, underwriter, 50, "Test", 800, "Test", "T",
            Permissions(address(perms)),
            Permissions(address(perms)),
            Permissions(address(perms))
        );

        // Excess fee
        vm.prank(poolCreator);
        vm.expectRevert(abi.encodeWithSelector(BullaFactoringFactoryV2_1.IncorrectFee.selector, 0.1 ether, 0.2 ether));
        factory.createPoolWithPermissions{value: 0.2 ether}(
            usdc, underwriter, 50, "Test", 800, "Test", "T",
            Permissions(address(perms)),
            Permissions(address(perms)),
            Permissions(address(perms))
        );

        // Success with exact fee
        vm.prank(poolCreator);
        address pool = factory.createPoolWithPermissions{value: 0.1 ether}(
            usdc, underwriter, 50, "Test", 800, "Test", "T",
            Permissions(address(perms)),
            Permissions(address(perms)),
            Permissions(address(perms))
        );
        assertTrue(pool != address(0));
    }

    function test_collectedFees_tracksBalance() public {
        vm.prank(bullaDao);
        factory.setPoolCreationFee(0.1 ether);

        assertEq(factory.collectedFees(), 0);

        address[] memory depositors = new address[](0);
        address[] memory factorers = new address[](0);

        // Create first pool
        vm.prank(poolCreator);
        factory.createPool{value: 0.1 ether}(
            usdc, underwriter, 50, "Test1", 800, "Test1", "T1",
            depositors, factorers
        );
        assertEq(factory.collectedFees(), 0.1 ether);

        // Create second pool
        vm.prank(poolCreator);
        factory.createPool{value: 0.1 ether}(
            usdc, underwriter, 50, "Test2", 800, "Test2", "T2",
            depositors, factorers
        );
        assertEq(factory.collectedFees(), 0.2 ether);
    }

    function test_withdrawFees_transfersToOwner() public {
        vm.prank(bullaDao);
        factory.setPoolCreationFee(0.1 ether);

        address[] memory depositors = new address[](0);
        address[] memory factorers = new address[](0);

        // Create pool with fee
        vm.prank(poolCreator);
        factory.createPool{value: 0.1 ether}(
            usdc, underwriter, 50, "Test", 800, "Test", "T",
            depositors, factorers
        );

        uint256 daoBalanceBefore = bullaDao.balance;

        // Withdraw fees
        vm.prank(bullaDao);
        vm.expectEmit(true, true, true, true);
        emit FeesWithdrawn(bullaDao, 0.1 ether);
        factory.withdrawFees();

        assertEq(bullaDao.balance, daoBalanceBefore + 0.1 ether);
        assertEq(factory.collectedFees(), 0);
    }

    function test_withdrawFees_revertsWhenNoFees() public {
        vm.prank(bullaDao);
        vm.expectRevert(BullaFactoringFactoryV2_1.TransferFailed.selector);
        factory.withdrawFees();
    }

    function test_withdrawFees_revertsWhenNonOwner() public {
        vm.prank(bullaDao);
        factory.setPoolCreationFee(0.1 ether);

        address[] memory depositors = new address[](0);
        address[] memory factorers = new address[](0);

        vm.prank(poolCreator);
        factory.createPool{value: 0.1 ether}(
            usdc, underwriter, 50, "Test", 800, "Test", "T",
            depositors, factorers
        );

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomUser));
        factory.withdrawFees();
    }

    // ============ Asset Whitelist Tests ============

    function test_allowAsset_addsToWhitelist() public {
        assertFalse(factory.isAssetAllowed(address(usdt)));

        vm.prank(bullaDao);
        vm.expectEmit(true, true, true, true);
        emit AssetWhitelistChanged(address(usdt), true);
        factory.allowAsset(address(usdt));

        assertTrue(factory.isAssetAllowed(address(usdt)));
    }

    function test_disallowAsset_removesFromWhitelist() public {
        assertTrue(factory.isAssetAllowed(address(usdc)));

        vm.prank(bullaDao);
        vm.expectEmit(true, true, true, true);
        emit AssetWhitelistChanged(address(usdc), false);
        factory.disallowAsset(address(usdc));

        assertFalse(factory.isAssetAllowed(address(usdc)));
    }

    function test_allowAsset_revertsOnZeroAddress() public {
        vm.prank(bullaDao);
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidAddress.selector);
        factory.allowAsset(address(0));
    }

    function test_assetWhitelist_onlyOwner() public {
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomUser));
        factory.allowAsset(address(usdt));

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomUser));
        factory.disallowAsset(address(usdc));
    }

    // ============ Setter Tests ============

    function test_setInvoiceProviderAdapter_updatesAdapter() public {
        BullaClaimV2InvoiceProviderAdapterV2 newAdapter = new BullaClaimV2InvoiceProviderAdapterV2(
            address(bullaClaim), address(bullaFrendLend), address(bullaInvoice)
        );

        vm.prank(bullaDao);
        vm.expectEmit(true, true, true, true);
        emit InvoiceProviderAdapterChanged(address(invoiceAdapter), address(newAdapter));
        factory.setInvoiceProviderAdapter(IInvoiceProviderAdapterV2(address(newAdapter)));

        assertEq(address(factory.invoiceProviderAdapter()), address(newAdapter));
    }

    function test_setInvoiceProviderAdapter_revertsOnZero() public {
        vm.prank(bullaDao);
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidAddress.selector);
        factory.setInvoiceProviderAdapter(IInvoiceProviderAdapterV2(address(0)));
    }

    function test_setBullaFrendLend_updatesAddress() public {
        BullaFrendLendV2 newFrendLend = new BullaFrendLendV2(address(bullaClaim), address(this), 50, 0);

        vm.prank(bullaDao);
        vm.expectEmit(true, true, true, true);
        emit BullaFrendLendChanged(address(bullaFrendLend), address(newFrendLend));
        factory.setBullaFrendLend(IBullaFrendLendV2(address(newFrendLend)));

        assertEq(address(factory.bullaFrendLend()), address(newFrendLend));
    }

    function test_setProtocolFeeBps_updatesFee() public {
        vm.prank(bullaDao);
        vm.expectEmit(true, true, true, true);
        emit ProtocolFeeBpsChanged(protocolFeeBps, 50);
        factory.setProtocolFeeBps(50);

        assertEq(factory.protocolFeeBps(), 50);
    }

    function test_setProtocolFeeBps_revertsOnInvalidPercentage() public {
        vm.prank(bullaDao);
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidPercentage.selector);
        factory.setProtocolFeeBps(10001);
    }

    function test_setters_revertWhenNonOwner() public {
        vm.startPrank(randomUser);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomUser));
        factory.setInvoiceProviderAdapter(IInvoiceProviderAdapterV2(address(invoiceAdapter)));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomUser));
        factory.setBullaFrendLend(bullaFrendLend);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomUser));
        factory.setProtocolFeeBps(100);

        vm.stopPrank();
    }

    // ============ Pool Tracking Tests ============

    function test_getPoolCount_tracksCreatedPools() public {
        assertEq(factory.getPoolCount(), 0);

        address[] memory depositors = new address[](0);
        address[] memory factorers = new address[](0);

        vm.startPrank(poolCreator);
        
        factory.createPool(usdc, underwriter, 50, "Pool1", 800, "P1", "P1", depositors, factorers);
        assertEq(factory.getPoolCount(), 1);

        factory.createPool(usdc, underwriter, 50, "Pool2", 800, "P2", "P2", depositors, factorers);
        assertEq(factory.getPoolCount(), 2);

        MockPermissions perms = new MockPermissions();
        factory.createPoolWithPermissions(usdc, underwriter, 50, "Pool3", 800, "P3", "P3",
            Permissions(address(perms)), Permissions(address(perms)), Permissions(address(perms)));
        assertEq(factory.getPoolCount(), 3);

        vm.stopPrank();
    }

    function test_getAllPools_returnsAllPools() public {
        address[] memory depositors = new address[](0);
        address[] memory factorers = new address[](0);

        vm.startPrank(poolCreator);
        
        (address pool1,,) = factory.createPool(usdc, underwriter, 50, "Pool1", 800, "P1", "P1", depositors, factorers);
        (address pool2,,) = factory.createPool(usdc, underwriter, 50, "Pool2", 800, "P2", "P2", depositors, factorers);

        vm.stopPrank();

        address[] memory pools = factory.getAllPools();
        assertEq(pools.length, 2);
        assertEq(pools[0], pool1);
        assertEq(pools[1], pool2);
    }

    // ============ Multiple Pools Test ============

    function test_multiplePoolsHaveIndependentConfigurations() public {
        address[] memory depositors = new address[](0);
        address[] memory factorers = new address[](0);

        vm.startPrank(poolCreator);
        
        (address pool1,,) = factory.createPool(
            usdc, underwriter, 25, "Pool One", 500, "Pool One Token", "P1T",
            depositors, factorers
        );
        
        (address pool2,,) = factory.createPool(
            usdc, address(0x9999), 75, "Pool Two", 1200, "Pool Two Token", "P2T",
            depositors, factorers
        );

        vm.stopPrank();

        BullaFactoringV2_1 p1 = BullaFactoringV2_1(pool1);
        BullaFactoringV2_1 p2 = BullaFactoringV2_1(pool2);

        // Verify independent configurations
        assertEq(p1.adminFeeBps(), 25);
        assertEq(p2.adminFeeBps(), 75);

        assertEq(p1.underwriter(), underwriter);
        assertEq(p2.underwriter(), address(0x9999));

        assertEq(p1.targetYieldBps(), 500);
        assertEq(p2.targetYieldBps(), 1200);

        // Both share protocol config (owner() is used as bullaDao)
        assertEq(p1.protocolFeeBps(), protocolFeeBps);
        assertEq(p2.protocolFeeBps(), protocolFeeBps);
        assertEq(p1.bullaDao(), factory.owner());
        assertEq(p2.bullaDao(), factory.owner());
    }

    // ============ Ownership Transfer Affects Future Pools ============

    function test_ownershipTransfer_affectsFuturePools() public {
        address[] memory depositors = new address[](0);
        address[] memory factorers = new address[](0);

        // Create first pool with original owner
        vm.prank(poolCreator);
        (address pool1,,) = factory.createPool(
            usdc, underwriter, 50, "Pool1", 800, "P1", "P1",
            depositors, factorers
        );

        // Transfer factory ownership
        address newOwner = address(0x7777);
        vm.prank(bullaDao);
        factory.transferOwnership(newOwner);

        // Create second pool with new owner
        vm.prank(poolCreator);
        (address pool2,,) = factory.createPool(
            usdc, underwriter, 50, "Pool2", 800, "P2", "P2",
            depositors, factorers
        );

        // First pool has original bullaDao
        assertEq(BullaFactoringV2_1(pool1).bullaDao(), bullaDao);
        
        // Second pool has new owner as bullaDao
        assertEq(BullaFactoringV2_1(pool2).bullaDao(), newOwner);
    }

    // ============ Additional Validation Tests ============

    function test_createPool_revertsOnInvalidAdminFeeBps() public {
        address[] memory depositors = new address[](0);
        address[] memory factorers = new address[](0);

        vm.prank(poolCreator);
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidPercentage.selector);
        factory.createPool(
            usdc,
            underwriter,
            10001, // > 100%
            "Test Pool",
            800,
            "Test Pool Token",
            "TPT",
            depositors,
            factorers
        );
    }

    function test_createPool_revertsOnInvalidTargetYieldBps() public {
        address[] memory depositors = new address[](0);
        address[] memory factorers = new address[](0);

        vm.prank(poolCreator);
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidPercentage.selector);
        factory.createPool(
            usdc,
            underwriter,
            50,
            "Test Pool",
            10001, // > 100%
            "Test Pool Token",
            "TPT",
            depositors,
            factorers
        );
    }

    function test_createPool_succeedsWithMaxValidBps() public {
        address[] memory depositors = new address[](0);
        address[] memory factorers = new address[](0);

        vm.prank(poolCreator);
        (address pool,,) = factory.createPool(
            usdc,
            underwriter,
            10000, // 100% - valid edge
            "Test Pool",
            10000, // 100% - valid edge
            "Test Pool Token",
            "TPT",
            depositors,
            factorers
        );

        BullaFactoringV2_1 poolContract = BullaFactoringV2_1(pool);
        assertEq(poolContract.adminFeeBps(), 10000);
        assertEq(poolContract.targetYieldBps(), 10000);
    }

    // ============ createPoolWithPermissions Validation Tests ============

    function test_createPoolWithPermissions_revertsOnZeroAsset() public {
        MockPermissions perms = new MockPermissions();

        vm.prank(poolCreator);
        vm.expectRevert(abi.encodeWithSelector(BullaFactoringFactoryV2_1.AssetNotAllowed.selector, address(0)));
        factory.createPoolWithPermissions(
            MockUSDC(address(0)),
            underwriter,
            50,
            "Test Pool",
            800,
            "Test Pool Token",
            "TPT",
            Permissions(address(perms)),
            Permissions(address(perms)),
            Permissions(address(perms))
        );
    }

    function test_createPoolWithPermissions_revertsOnZeroUnderwriter() public {
        MockPermissions perms = new MockPermissions();

        vm.prank(poolCreator);
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidAddress.selector);
        factory.createPoolWithPermissions(
            usdc,
            address(0),
            50,
            "Test Pool",
            800,
            "Test Pool Token",
            "TPT",
            Permissions(address(perms)),
            Permissions(address(perms)),
            Permissions(address(perms))
        );
    }

    function test_createPoolWithPermissions_revertsOnDisallowedAsset() public {
        MockPermissions perms = new MockPermissions();

        vm.prank(poolCreator);
        vm.expectRevert(abi.encodeWithSelector(BullaFactoringFactoryV2_1.AssetNotAllowed.selector, address(usdt)));
        factory.createPoolWithPermissions(
            usdt, // Not whitelisted
            underwriter,
            50,
            "Test Pool",
            800,
            "Test Pool Token",
            "TPT",
            Permissions(address(perms)),
            Permissions(address(perms)),
            Permissions(address(perms))
        );
    }

    function test_createPoolWithPermissions_revertsOnInvalidAdminFeeBps() public {
        MockPermissions perms = new MockPermissions();

        vm.prank(poolCreator);
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidPercentage.selector);
        factory.createPoolWithPermissions(
            usdc,
            underwriter,
            10001, // > 100%
            "Test Pool",
            800,
            "Test Pool Token",
            "TPT",
            Permissions(address(perms)),
            Permissions(address(perms)),
            Permissions(address(perms))
        );
    }

    function test_createPoolWithPermissions_revertsOnInvalidTargetYieldBps() public {
        MockPermissions perms = new MockPermissions();

        vm.prank(poolCreator);
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidPercentage.selector);
        factory.createPoolWithPermissions(
            usdc,
            underwriter,
            50,
            "Test Pool",
            10001, // > 100%
            "Test Pool Token",
            "TPT",
            Permissions(address(perms)),
            Permissions(address(perms)),
            Permissions(address(perms))
        );
    }

    function test_createPoolWithPermissions_emitsPoolCreatedEvent() public {
        MockPermissions depositPerms = new MockPermissions();
        MockPermissions redeemPerms = new MockPermissions();
        MockPermissions factoringPerms = new MockPermissions();

        vm.prank(poolCreator);
        vm.expectEmit(false, true, true, false);
        emit PoolCreated(
            address(0), // Will be replaced
            poolCreator,
            address(usdc),
            "Test Pool",
            "Test Pool Token",
            "TPT",
            address(depositPerms),
            address(redeemPerms),
            address(factoringPerms)
        );
        
        factory.createPoolWithPermissions(
            usdc,
            underwriter,
            50,
            "Test Pool",
            800,
            "Test Pool Token",
            "TPT",
            Permissions(address(depositPerms)),
            Permissions(address(redeemPerms)),
            Permissions(address(factoringPerms))
        );
    }

    // ============ Setter Validation Tests ============

    function test_setBullaFrendLend_revertsOnZero() public {
        vm.prank(bullaDao);
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidAddress.selector);
        factory.setBullaFrendLend(IBullaFrendLendV2(address(0)));
    }

    function test_setProtocolFeeBps_succeedsWithMaxValid() public {
        vm.prank(bullaDao);
        factory.setProtocolFeeBps(10000); // 100% - valid edge

        assertEq(factory.protocolFeeBps(), 10000);
    }

    // ============ Asset Whitelist Validation Tests ============

    function test_disallowAsset_revertsOnZeroAddress() public {
        vm.prank(bullaDao);
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidAddress.selector);
        factory.disallowAsset(address(0));
    }

    // ============ Fee Exact Match Tests ============

    function test_createPool_revertsOnExcessFeeWhenZeroRequired() public {
        // Fee is 0 by default
        assertEq(factory.poolCreationFee(), 0);

        address[] memory depositors = new address[](0);
        address[] memory factorers = new address[](0);

        // Try to send ETH when no fee required
        vm.prank(poolCreator);
        vm.expectRevert(abi.encodeWithSelector(BullaFactoringFactoryV2_1.IncorrectFee.selector, 0, 0.1 ether));
        factory.createPool{value: 0.1 ether}(
            usdc, underwriter, 50, "Test", 800, "Test", "T",
            depositors, factorers
        );
    }

    function test_createPoolWithPermissions_revertsOnExcessFeeWhenZeroRequired() public {
        // Fee is 0 by default
        assertEq(factory.poolCreationFee(), 0);

        MockPermissions perms = new MockPermissions();

        vm.prank(poolCreator);
        vm.expectRevert(abi.encodeWithSelector(BullaFactoringFactoryV2_1.IncorrectFee.selector, 0, 0.1 ether));
        factory.createPoolWithPermissions{value: 0.1 ether}(
            usdc, underwriter, 50, "Test", 800, "Test", "T",
            Permissions(address(perms)),
            Permissions(address(perms)),
            Permissions(address(perms))
        );
    }

    // ============ Public Array Accessor Test ============

    function test_pools_accessByIndex() public {
        address[] memory depositors = new address[](0);
        address[] memory factorers = new address[](0);

        vm.startPrank(poolCreator);
        
        (address pool1,,) = factory.createPool(usdc, underwriter, 50, "Pool1", 800, "P1", "P1", depositors, factorers);
        (address pool2,,) = factory.createPool(usdc, underwriter, 50, "Pool2", 800, "P2", "P2", depositors, factorers);
        (address pool3,,) = factory.createPool(usdc, underwriter, 50, "Pool3", 800, "P3", "P3", depositors, factorers);

        vm.stopPrank();

        // Access by index
        assertEq(factory.pools(0), pool1);
        assertEq(factory.pools(1), pool2);
        assertEq(factory.pools(2), pool3);
    }

    function test_pools_revertsOnOutOfBoundsIndex() public {
        // No pools created yet
        vm.expectRevert();
        factory.pools(0);
    }
}
