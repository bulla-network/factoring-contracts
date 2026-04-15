// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "contracts/ComplianceDepositPermissions.sol";
import "contracts/BullaKycGate.sol";
import "contracts/AgreementSignatureRepo.sol";
import "contracts/interfaces/ISanctionsList.sol";
import "contracts/interfaces/IBullaKycGate.sol";
import "contracts/interfaces/IAgreementSignatureRepo.sol";
import "contracts/interfaces/IBullaKycIssuer.sol";

// ============ Mocks ============

contract MockSanctionsList is ISanctionsList {
    mapping(address => bool) public sanctioned;

    function setSanctioned(address addr, bool status) external {
        sanctioned[addr] = status;
    }

    function isSanctioned(address addr) external view override returns (bool) {
        return sanctioned[addr];
    }
}

contract MockKycIssuer is IBullaKycIssuer {
    mapping(address => bool) public kyced;

    function setKyced(address addr, bool status) external {
        kyced[addr] = status;
    }

    function isKyced(address _address) external view override returns (bool) {
        return kyced[_address];
    }
}

// ============ Tests ============

contract TestComplianceDepositPermissions is Test {
    ComplianceDepositPermissions public permissions;
    MockSanctionsList public sanctionsList;
    BullaKycGate public kycGate;
    AgreementSignatureRepo public agreementRepo;
    MockKycIssuer public kycIssuer;

    address owner = address(this);
    address depositor = address(0x1234);
    address pool = address(0xBEEF);
    address signatureApprover = address(0xABCD);

    function setUp() public {
        // Deploy sanctions list mock
        sanctionsList = new MockSanctionsList();

        // Deploy KYC gate with a mock issuer
        kycGate = new BullaKycGate();
        kycIssuer = new MockKycIssuer();
        kycGate.addIssuer(kycIssuer);

        // Deploy agreement signature repo
        agreementRepo = new AgreementSignatureRepo(signatureApprover);

        // Deploy compliance deposit permissions
        permissions = new ComplianceDepositPermissions(
            ISanctionsList(address(sanctionsList)),
            IBullaKycGate(address(kycGate)),
            IAgreementSignatureRepo(address(agreementRepo))
        );
    }

    // ============ Happy Path ============

    function test_allChecksPassed() public {
        // KYC the depositor
        kycIssuer.setKyced(depositor, true);

        // Set doc version for pool and sign
        permissions.setPoolDocumentVersion(pool, 1);
        vm.prank(signatureApprover);
        agreementRepo.recordSignature(pool, 1, depositor);

        // Call isAllowed as pool (msg.sender = pool)
        vm.prank(pool);
        assertTrue(permissions.isAllowed(depositor));
    }

    // ============ Sanction Check ============

    function test_sanctionedDepositorRejected() public {
        kycIssuer.setKyced(depositor, true);
        sanctionsList.setSanctioned(depositor, true);

        vm.prank(pool);
        assertFalse(permissions.isAllowed(depositor));
    }

    function test_sanctionsListZeroSkipsCheck() public {
        // Deploy permissions with no sanctions list but no agreement repo either
        ComplianceDepositPermissions noSanctions = new ComplianceDepositPermissions(
            ISanctionsList(address(0)),
            IBullaKycGate(address(kycGate)),
            IAgreementSignatureRepo(address(0))
        );

        kycIssuer.setKyced(depositor, true);

        vm.prank(pool);
        assertTrue(noSanctions.isAllowed(depositor));
    }

    // ============ KYC Check ============

    function test_nonKycedDepositorRejected() public {
        // depositor is NOT KYC'd
        vm.prank(pool);
        assertFalse(permissions.isAllowed(depositor));
    }

    function test_kycGateZeroSkipsCheck() public {
        // Deploy permissions with no KYC gate
        ComplianceDepositPermissions noKyc = new ComplianceDepositPermissions(
            ISanctionsList(address(sanctionsList)),
            IBullaKycGate(address(0)),
            IAgreementSignatureRepo(address(0))
        );

        // depositor is NOT KYC'd but KYC gate is address(0) → skipped
        vm.prank(pool);
        assertTrue(noKyc.isAllowed(depositor));
    }

    // ============ Agreement Check ============

    function test_unsignedAgreementRejected() public {
        kycIssuer.setKyced(depositor, true);
        permissions.setPoolDocumentVersion(pool, 1);
        // depositor has NOT signed

        vm.prank(pool);
        assertFalse(permissions.isAllowed(depositor));
    }

    function test_docVersionZeroIsValid() public {
        kycIssuer.setKyced(depositor, true);
        // poolDocumentVersion defaults to 0 — version 0 is valid, requires signature

        vm.prank(pool);
        assertFalse(permissions.isAllowed(depositor));

        // Sign for version 0
        vm.prank(signatureApprover);
        agreementRepo.recordSignature(pool, 0, depositor);

        vm.prank(pool);
        assertTrue(permissions.isAllowed(depositor));
    }

    function test_agreementRepoZeroSkipsCheck() public {
        // Deploy permissions with no agreement repo
        ComplianceDepositPermissions noAgreement = new ComplianceDepositPermissions(
            ISanctionsList(address(sanctionsList)),
            IBullaKycGate(address(kycGate)),
            IAgreementSignatureRepo(address(0))
        );

        kycIssuer.setKyced(depositor, true);

        vm.prank(pool);
        assertTrue(noAgreement.isAllowed(depositor));
    }

    function test_allDepsZeroAllowsEveryone() public {
        ComplianceDepositPermissions allZero = new ComplianceDepositPermissions(
            ISanctionsList(address(0)),
            IBullaKycGate(address(0)),
            IAgreementSignatureRepo(address(0))
        );

        vm.prank(pool);
        assertTrue(allZero.isAllowed(depositor));
    }

    // ============ Admin: setPoolDocumentVersion ============

    function test_setPoolDocumentVersion() public {
        vm.expectEmit(true, false, false, true);
        emit ComplianceDepositPermissions.PoolDocumentVersionSet(pool, 3);
        permissions.setPoolDocumentVersion(pool, 3);

        assertEq(permissions.poolDocumentVersion(pool), 3);
    }

    function test_setPoolDocumentVersion_nonOwnerReverts() public {
        vm.prank(depositor);
        vm.expectRevert();
        permissions.setPoolDocumentVersion(pool, 1);
    }

    // ============ Admin: setSanctionsList ============

    function test_setSanctionsList() public {
        MockSanctionsList newList = new MockSanctionsList();

        vm.expectEmit(true, true, false, false);
        emit ComplianceDepositPermissions.SanctionsListUpdated(address(sanctionsList), address(newList));
        permissions.setSanctionsList(ISanctionsList(address(newList)));

        assertEq(address(permissions.sanctionsList()), address(newList));
    }

    function test_setSanctionsList_nonOwnerReverts() public {
        vm.prank(depositor);
        vm.expectRevert();
        permissions.setSanctionsList(ISanctionsList(address(0)));
    }

    // ============ Admin: setKycGate ============

    function test_setKycGate() public {
        BullaKycGate newGate = new BullaKycGate();

        vm.expectEmit(true, true, false, false);
        emit ComplianceDepositPermissions.KycGateUpdated(address(kycGate), address(newGate));
        permissions.setKycGate(IBullaKycGate(address(newGate)));

        assertEq(address(permissions.kycGate()), address(newGate));
    }

    function test_setKycGate_zeroAddressAllowed() public {
        permissions.setKycGate(IBullaKycGate(address(0)));
        assertEq(address(permissions.kycGate()), address(0));
    }

    function test_setKycGate_nonOwnerReverts() public {
        vm.prank(depositor);
        vm.expectRevert();
        permissions.setKycGate(IBullaKycGate(address(kycGate)));
    }

    // ============ Admin: setAgreementSignatureRepo ============

    function test_setAgreementSignatureRepo() public {
        AgreementSignatureRepo newRepo = new AgreementSignatureRepo(signatureApprover);

        vm.expectEmit(true, true, false, false);
        emit ComplianceDepositPermissions.AgreementSignatureRepoUpdated(address(agreementRepo), address(newRepo));
        permissions.setAgreementSignatureRepo(IAgreementSignatureRepo(address(newRepo)));

        assertEq(address(permissions.agreementSignatureRepo()), address(newRepo));
    }

    function test_setAgreementSignatureRepo_nonOwnerReverts() public {
        vm.prank(depositor);
        vm.expectRevert();
        permissions.setAgreementSignatureRepo(IAgreementSignatureRepo(address(0)));
    }

    // ============ Constructor ============

    function test_constructor_zeroKycGateAllowed() public {
        // All deps can be address(0)
        ComplianceDepositPermissions allZero = new ComplianceDepositPermissions(
            ISanctionsList(address(0)),
            IBullaKycGate(address(0)),
            IAgreementSignatureRepo(address(0))
        );
        assertEq(address(allZero.sanctionsList()), address(0));
        assertEq(address(allZero.kycGate()), address(0));
        assertEq(address(allZero.agreementSignatureRepo()), address(0));
    }

    function test_constructor_emitsEvents() public {
        vm.expectEmit(true, true, false, false);
        emit ComplianceDepositPermissions.SanctionsListUpdated(address(0), address(sanctionsList));
        vm.expectEmit(true, true, false, false);
        emit ComplianceDepositPermissions.KycGateUpdated(address(0), address(kycGate));
        vm.expectEmit(true, true, false, false);
        emit ComplianceDepositPermissions.AgreementSignatureRepoUpdated(address(0), address(agreementRepo));

        new ComplianceDepositPermissions(
            ISanctionsList(address(sanctionsList)),
            IBullaKycGate(address(kycGate)),
            IAgreementSignatureRepo(address(agreementRepo))
        );
    }

    // ============ Integration: msg.sender = pool ============

    function test_poolMsgSenderLookup() public {
        // Set up two pools with different doc versions
        address pool2 = address(0xCAFE);

        kycIssuer.setKyced(depositor, true);

        permissions.setPoolDocumentVersion(pool, 1);
        permissions.setPoolDocumentVersion(pool2, 2);

        // Sign for pool1/version1 only
        vm.prank(signatureApprover);
        agreementRepo.recordSignature(pool, 1, depositor);

        // pool1 calling → uses version 1, depositor signed → allowed
        vm.prank(pool);
        assertTrue(permissions.isAllowed(depositor));

        // pool2 calling → uses version 2, depositor NOT signed → rejected
        vm.prank(pool2);
        assertFalse(permissions.isAllowed(depositor));
    }
}
