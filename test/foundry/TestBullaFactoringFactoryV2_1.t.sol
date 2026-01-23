// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoringFactoryV2_1 } from 'contracts/BullaFactoringFactoryV2_1.sol';
import { BullaFactoringV2_1 } from 'contracts/BullaFactoring.sol';
import { Permissions } from 'contracts/Permissions.sol';
import { PermissionsFactory } from 'contracts/PermissionsFactory.sol';
import { FactoringPermissions } from 'contracts/FactoringPermissions.sol';
import { BullaClaimV2InvoiceProviderAdapterV2 } from 'contracts/BullaClaimV2InvoiceProviderAdapterV2.sol';
import { MockUSDC } from 'contracts/mocks/MockUSDC.sol';
import { MockPermissions } from 'contracts/mocks/MockPermissions.sol';
import { MockZodiacRoles } from 'contracts/mocks/MockZodiacRoles.sol';
import { IZodiacRoles } from 'contracts/interfaces/IZodiacRoles.sol';
import { IInvoiceProviderAdapterV2 } from 'contracts/interfaces/IInvoiceProviderAdapter.sol';
import { IBullaFrendLendV2 } from 'bulla-contracts-v2/src/interfaces/IBullaFrendLendV2.sol';
import { BullaFrendLendV2 } from 'bulla-contracts-v2/src/BullaFrendLendV2.sol';
import { BullaControllerRegistry } from 'bulla-contracts-v2/src/BullaControllerRegistry.sol';
import { BullaClaimV2 } from 'bulla-contracts-v2/src/BullaClaimV2.sol';
import { BullaApprovalRegistry } from 'bulla-contracts-v2/src/BullaApprovalRegistry.sol';
import { BullaInvoice } from 'bulla-contracts-v2/src/BullaInvoice.sol';
import { IBullaClaimV2, LockState } from 'bulla-contracts-v2/src/interfaces/IBullaClaimV2.sol';
import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';

contract TestBullaFactoringFactoryV2_1 is Test {
    BullaFactoringFactoryV2_1 public factory;
    PermissionsFactory public permissionsFactory;
    MockZodiacRoles public mockZodiacRoles;

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
    event PermissionsCreated(address indexed permissions, address indexed owner);

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
            address(invoiceAdapter),
            address(bullaFrendLend),
            address(bullaClaim),
            bullaDao,
            protocolFeeBps
        );

        // Deploy permissions factory
        permissionsFactory = new PermissionsFactory();

        // Deploy and configure mock Zodiac Roles
        mockZodiacRoles = new MockZodiacRoles();
        bytes32 testRoleKey = keccak256("CALLBACK_WHITELISTER");
        vm.prank(bullaDao);
        factory.setZodiacRolesConfig(IZodiacRoles(address(mockZodiacRoles)), testRoleKey);

        // Whitelist USDC as allowed asset
        vm.prank(bullaDao);
        factory.allowAsset(address(usdc));

        // Fund accounts
        vm.deal(poolCreator, 10 ether);
        vm.deal(randomUser, 10 ether);
    }

    /// @notice Helper to build creation bytecode for BullaFactoringV2_1
    function _buildCreationBytecode(
        IERC20 asset,
        address _underwriter,
        address depositPerms,
        address redeemPerms,
        address factoringPerms,
        uint16 adminFeeBps,
        string memory poolName,
        uint16 targetYieldBps,
        string memory tokenName,
        string memory tokenSymbol
    ) internal view returns (bytes memory) {
        return abi.encodePacked(
            type(BullaFactoringV2_1).creationCode,
            abi.encode(
                asset,
                invoiceAdapter,
                bullaFrendLend,
                _underwriter,
                Permissions(depositPerms),
                Permissions(redeemPerms),
                Permissions(factoringPerms),
                bullaDao,
                protocolFeeBps,
                adminFeeBps,
                poolName,
                targetYieldBps,
                tokenName,
                tokenSymbol
            )
        );
    }

    // ============ Constructor Tests ============

    function test_constructor_setsCorrectValues() public view {
        assertEq(factory.owner(), bullaDao);
        assertEq(address(factory.invoiceProviderAdapter()), address(invoiceAdapter));
        assertEq(address(factory.bullaFrendLend()), address(bullaFrendLend));
        assertEq(factory.bullaClaimV2(), address(bullaClaim));
        assertEq(factory.protocolFeeBps(), protocolFeeBps);
        assertEq(factory.poolNonce(), 0);
        assertEq(factory.poolCreationFee(), 0);
        // Zodiac Roles configured in setUp
        assertEq(address(factory.rolesModifier()), address(mockZodiacRoles));
    }

    function test_constructor_revertsOnZeroAdapter() public {
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidAddress.selector);
        new BullaFactoringFactoryV2_1(
            address(0),
            address(bullaFrendLend),
            address(bullaClaim),
            bullaDao,
            protocolFeeBps
        );
    }

    function test_constructor_revertsOnZeroBullaFrendLend() public {
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidAddress.selector);
        new BullaFactoringFactoryV2_1(
            address(invoiceAdapter),
            address(0),
            address(bullaClaim),
            bullaDao,
            protocolFeeBps
        );
    }

    function test_constructor_revertsOnZeroBullaClaimV2() public {
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidAddress.selector);
        new BullaFactoringFactoryV2_1(
            address(invoiceAdapter),
            address(bullaFrendLend),
            address(0),
            bullaDao,
            protocolFeeBps
        );
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new BullaFactoringFactoryV2_1(
            address(invoiceAdapter),
            address(bullaFrendLend),
            address(bullaClaim),
            address(0),
            protocolFeeBps
        );
    }

    function test_constructor_revertsOnInvalidProtocolFee() public {
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidPercentage.selector);
        new BullaFactoringFactoryV2_1(
            address(invoiceAdapter),
            address(bullaFrendLend),
            address(bullaClaim),
            bullaDao,
            10001 // > 100%
        );
    }

    // ============ createPool Tests ============

    function test_createPool_deploysPoolWithCorrectProperties() public {
        address[] memory emptyAddresses = new address[](0);

        vm.startPrank(poolCreator);
        
        // Create permissions first
        address depositRedeemPerms = permissionsFactory.createPermissions(emptyAddresses);
        address factoringPerms = permissionsFactory.createPermissions(emptyAddresses);
        
        // Build creation bytecode
        bytes memory creationBytecode = _buildCreationBytecode(
            IERC20(address(usdc)),
            underwriter,
            depositRedeemPerms,
            depositRedeemPerms,
            factoringPerms,
            50,
            "Test Pool",
            800,
            "Test Pool Token",
            "TPT"
        );
        
        // Create pool
        address pool = factory.createPool(
            creationBytecode,
            address(usdc),
            "Test Pool",
            "Test Pool Token",
            "TPT",
            depositRedeemPerms,
            depositRedeemPerms,
            factoringPerms
        );
        vm.stopPrank();

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
        assertEq(poolContract.bullaDao(), bullaDao);

        // Verify ownership transferred to caller
        assertEq(poolContract.owner(), poolCreator);

        // Verify nonce incremented
        assertEq(factory.poolNonce(), 1);
    }

    function test_createPool_emitsPoolCreatedEvent() public {
        address[] memory emptyAddresses = new address[](0);

        vm.startPrank(poolCreator);
        address depositRedeemPerms = permissionsFactory.createPermissions(emptyAddresses);
        address factoringPerms = permissionsFactory.createPermissions(emptyAddresses);
        
        bytes memory creationBytecode = _buildCreationBytecode(
            IERC20(address(usdc)),
            underwriter,
            depositRedeemPerms,
            depositRedeemPerms,
            factoringPerms,
            50,
            "Test Pool",
            800,
            "Test Pool Token",
            "TPT"
        );

        vm.expectEmit(false, true, true, false);
        emit PoolCreated(
            address(0), // Will be replaced
            poolCreator,
            address(usdc),
            "Test Pool",
            "Test Pool Token",
            "TPT",
            depositRedeemPerms,
            depositRedeemPerms,
            factoringPerms
        );
        
        factory.createPool(
            creationBytecode,
            address(usdc),
            "Test Pool",
            "Test Pool Token",
            "TPT",
            depositRedeemPerms,
            depositRedeemPerms,
            factoringPerms
        );
        vm.stopPrank();
    }

    function test_createPool_revertsOnInvalidBullaDao() public {
        MockPermissions perms = new MockPermissions();
        
        // Build bytecode with wrong bullaDao
        bytes memory badBytecode = abi.encodePacked(
            type(BullaFactoringV2_1).creationCode,
            abi.encode(
                IERC20(address(usdc)),
                invoiceAdapter,
                bullaFrendLend,
                underwriter,
                Permissions(address(perms)),
                Permissions(address(perms)),
                Permissions(address(perms)),
                address(0x9999), // Wrong bullaDao
                protocolFeeBps,
                50,
                "Test",
                800,
                "Test",
                "T"
            )
        );

        vm.prank(poolCreator);
        vm.expectRevert(abi.encodeWithSelector(
            BullaFactoringFactoryV2_1.InvalidBullaDao.selector,
            bullaDao,
            address(0x9999)
        ));
        factory.createPool(
            badBytecode,
            address(usdc),
            "Test",
            "Test",
            "T",
            address(perms),
            address(perms),
            address(perms)
        );
    }

    function test_createPool_revertsOnInvalidProtocolFee() public {
        MockPermissions perms = new MockPermissions();
        
        // Build bytecode with wrong protocolFee
        bytes memory badBytecode = abi.encodePacked(
            type(BullaFactoringV2_1).creationCode,
            abi.encode(
                IERC20(address(usdc)),
                invoiceAdapter,
                bullaFrendLend,
                underwriter,
                Permissions(address(perms)),
                Permissions(address(perms)),
                Permissions(address(perms)),
                bullaDao,
                uint16(999), // Wrong protocolFee
                50,
                "Test",
                800,
                "Test",
                "T"
            )
        );

        vm.prank(poolCreator);
        vm.expectRevert(abi.encodeWithSelector(
            BullaFactoringFactoryV2_1.InvalidProtocolFee.selector,
            protocolFeeBps,
            uint16(999)
        ));
        factory.createPool(
            badBytecode,
            address(usdc),
            "Test",
            "Test",
            "T",
            address(perms),
            address(perms),
            address(perms)
        );
    }

    function test_createPool_revertsOnInvalidInvoiceAdapter() public {
        MockPermissions perms = new MockPermissions();
        
        // Create a different adapter
        BullaClaimV2InvoiceProviderAdapterV2 wrongAdapter = new BullaClaimV2InvoiceProviderAdapterV2(
            address(bullaClaim), address(bullaFrendLend), address(bullaInvoice)
        );
        
        // Build bytecode with wrong adapter
        bytes memory badBytecode = abi.encodePacked(
            type(BullaFactoringV2_1).creationCode,
            abi.encode(
                IERC20(address(usdc)),
                wrongAdapter, // Wrong adapter
                bullaFrendLend,
                underwriter,
                Permissions(address(perms)),
                Permissions(address(perms)),
                Permissions(address(perms)),
                bullaDao,
                protocolFeeBps,
                50,
                "Test",
                800,
                "Test",
                "T"
            )
        );

        vm.prank(poolCreator);
        vm.expectRevert(abi.encodeWithSelector(
            BullaFactoringFactoryV2_1.InvalidInvoiceAdapter.selector,
            address(invoiceAdapter),
            address(wrongAdapter)
        ));
        factory.createPool(
            badBytecode,
            address(usdc),
            "Test",
            "Test",
            "T",
            address(perms),
            address(perms),
            address(perms)
        );
    }

    function test_createPool_revertsOnDisallowedAsset() public {
        MockPermissions perms = new MockPermissions();
        bytes memory creationBytecode = _buildCreationBytecode(
            IERC20(address(usdt)),
            underwriter,
            address(perms),
            address(perms),
            address(perms),
            50,
            "Test",
            800,
            "Test",
            "T"
        );

        vm.prank(poolCreator);
        vm.expectRevert(abi.encodeWithSelector(BullaFactoringFactoryV2_1.AssetNotAllowed.selector, address(usdt)));
        factory.createPool(
            creationBytecode,
            address(usdt),
            "Test",
            "Test",
            "T",
            address(perms),
            address(perms),
            address(perms)
        );
    }

    function test_createPool_revertsOnZeroPermissions() public {
        MockPermissions validPerms = new MockPermissions();
        bytes memory creationBytecode = _buildCreationBytecode(
            IERC20(address(usdc)),
            underwriter,
            address(validPerms),
            address(validPerms),
            address(validPerms),
            50,
            "Test",
            800,
            "Test",
            "T"
        );

        vm.startPrank(poolCreator);

        // Zero deposit permissions
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidAddress.selector);
        factory.createPool(
            creationBytecode,
            address(usdc),
            "Test",
            "Test",
            "T",
            address(0),
            address(validPerms),
            address(validPerms)
        );

        // Zero redeem permissions
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidAddress.selector);
        factory.createPool(
            creationBytecode,
            address(usdc),
            "Test",
            "Test",
            "T",
            address(validPerms),
            address(0),
            address(validPerms)
        );

        // Zero factoring permissions
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidAddress.selector);
        factory.createPool(
            creationBytecode,
            address(usdc),
            "Test",
            "Test",
            "T",
            address(validPerms),
            address(validPerms),
            address(0)
        );

        vm.stopPrank();
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

    function test_setBullaFrendLend_revertsOnZero() public {
        vm.prank(bullaDao);
        vm.expectRevert(BullaFactoringFactoryV2_1.InvalidAddress.selector);
        factory.setBullaFrendLend(IBullaFrendLendV2(address(0)));
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

        MockPermissions perms = new MockPermissions();
        bytes memory creationBytecode = _buildCreationBytecode(
            IERC20(address(usdc)),
            underwriter,
            address(perms),
            address(perms),
            address(perms),
            50,
            "Test",
            800,
            "Test",
            "T"
        );

        // Try to create without fee
        vm.prank(poolCreator);
        vm.expectRevert(abi.encodeWithSelector(BullaFactoringFactoryV2_1.IncorrectFee.selector, 0.1 ether, 0));
        factory.createPool(
            creationBytecode,
            address(usdc),
            "Test",
            "Test",
            "T",
            address(perms),
            address(perms),
            address(perms)
        );

        // Try with insufficient fee
        vm.prank(poolCreator);
        vm.expectRevert(abi.encodeWithSelector(BullaFactoringFactoryV2_1.IncorrectFee.selector, 0.1 ether, 0.05 ether));
        factory.createPool{value: 0.05 ether}(
            creationBytecode,
            address(usdc),
            "Test",
            "Test",
            "T",
            address(perms),
            address(perms),
            address(perms)
        );

        // Success with exact fee
        vm.prank(poolCreator);
        address pool = factory.createPool{value: 0.1 ether}(
            creationBytecode,
            address(usdc),
            "Test",
            "Test",
            "T",
            address(perms),
            address(perms),
            address(perms)
        );
        assertTrue(pool != address(0));
        assertEq(address(factory).balance, 0.1 ether);
    }

    function test_withdrawFees_transfersToOwner() public {
        vm.prank(bullaDao);
        factory.setPoolCreationFee(0.1 ether);

        MockPermissions perms = new MockPermissions();
        bytes memory bytecode = _buildCreationBytecode(
            IERC20(address(usdc)),
            underwriter,
            address(perms),
            address(perms),
            address(perms),
            50,
            "Test",
            800,
            "Test",
            "T"
        );

        // Create pool with fee
        vm.prank(poolCreator);
        factory.createPool{value: 0.1 ether}(
            bytecode,
            address(usdc),
            "Test",
            "Test",
            "T",
            address(perms),
            address(perms),
            address(perms)
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

    // ============ computeAddress Tests ============

    function test_computeAddress_predictsDeterministicAddress() public {
        MockPermissions perms = new MockPermissions();
        bytes memory bytecode = _buildCreationBytecode(
            IERC20(address(usdc)),
            underwriter,
            address(perms),
            address(perms),
            address(perms),
            50,
            "Test",
            800,
            "Test",
            "T"
        );

        // Predict address before creation
        uint256 currentNonce = factory.poolNonce();
        address predicted = factory.computeAddress(bytecode, poolCreator, currentNonce);

        // Create pool
        vm.prank(poolCreator);
        address actual = factory.createPool(
            bytecode,
            address(usdc),
            "Test",
            "Test",
            "T",
            address(perms),
            address(perms),
            address(perms)
        );

        assertEq(predicted, actual);
    }

    // ============ Multiple Pools Test ============

    function test_multiplePoolsHaveIndependentConfigurations() public {
        vm.startPrank(poolCreator);
        
        MockPermissions perms1 = new MockPermissions();
        bytes memory bytecode1 = _buildCreationBytecode(
            IERC20(address(usdc)),
            underwriter,
            address(perms1),
            address(perms1),
            address(perms1),
            25,
            "Pool One",
            500,
            "Pool One Token",
            "P1T"
        );
        address pool1 = factory.createPool(
            bytecode1,
            address(usdc),
            "Pool One",
            "Pool One Token",
            "P1T",
            address(perms1),
            address(perms1),
            address(perms1)
        );
        
        MockPermissions perms2 = new MockPermissions();
        bytes memory bytecode2 = _buildCreationBytecode(
            IERC20(address(usdc)),
            address(0x9999),
            address(perms2),
            address(perms2),
            address(perms2),
            75,
            "Pool Two",
            1200,
            "Pool Two Token",
            "P2T"
        );
        address pool2 = factory.createPool(
            bytecode2,
            address(usdc),
            "Pool Two",
            "Pool Two Token",
            "P2T",
            address(perms2),
            address(perms2),
            address(perms2)
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

        // Both have same protocol-controlled params
        assertEq(p1.bullaDao(), bullaDao);
        assertEq(p2.bullaDao(), bullaDao);
        assertEq(p1.protocolFeeBps(), protocolFeeBps);
        assertEq(p2.protocolFeeBps(), protocolFeeBps);
    }

    // ============ PermissionsFactory Tests ============

    function test_permissionsFactory_whitelistsAddresses() public {
        address[] memory allowedAddresses = new address[](2);
        allowedAddresses[0] = depositor1;
        allowedAddresses[1] = depositor2;

        vm.prank(poolCreator);
        address permsAddr = permissionsFactory.createPermissions(allowedAddresses);

        // Verify addresses are whitelisted
        FactoringPermissions perms = FactoringPermissions(permsAddr);
        assertTrue(perms.isAllowed(depositor1));
        assertTrue(perms.isAllowed(depositor2));
        assertFalse(perms.isAllowed(randomUser));
    }

    function test_permissionsFactory_transfersOwnershipToCaller() public {
        address[] memory emptyAddresses = new address[](0);

        vm.prank(poolCreator);
        address permsAddr = permissionsFactory.createPermissions(emptyAddresses);

        // Verify ownership transferred to caller
        assertEq(FactoringPermissions(permsAddr).owner(), poolCreator);
    }

    function test_permissionsFactory_createPermissions_emitsEvent() public {
        address[] memory emptyAddresses = new address[](0);

        vm.prank(poolCreator);
        vm.expectEmit(false, true, false, false);
        emit PermissionsCreated(address(0), poolCreator);
        permissionsFactory.createPermissions(emptyAddresses);
    }
}
