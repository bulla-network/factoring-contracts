// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/access/Ownable.sol';
import "./Permissions.sol";
import "./interfaces/ISanctionsList.sol";
import "./interfaces/IBullaKycGate.sol";
import "./interfaces/IAgreementSignatureRepo.sol";

contract ComplianceDepositPermissions is Permissions, Ownable {
    ISanctionsList public sanctionsList;
    IBullaKycGate public kycGate;
    IAgreementSignatureRepo public agreementSignatureRepo;
    mapping(address pool => uint256 documentVersion) public poolDocumentVersion;

    event SanctionsListUpdated(address indexed oldList, address indexed newList);
    event KycGateUpdated(address indexed oldGate, address indexed newGate);
    event AgreementSignatureRepoUpdated(address indexed oldRepo, address indexed newRepo);
    event PoolDocumentVersionSet(address indexed pool, uint256 documentVersion);

    constructor(
        ISanctionsList _sanctionsList,
        IBullaKycGate _kycGate,
        IAgreementSignatureRepo _agreementSignatureRepo
    ) Ownable(_msgSender()) {
        sanctionsList = _sanctionsList;
        kycGate = _kycGate;
        agreementSignatureRepo = _agreementSignatureRepo;
        emit SanctionsListUpdated(address(0), address(_sanctionsList));
        emit KycGateUpdated(address(0), address(_kycGate));
        emit AgreementSignatureRepoUpdated(address(0), address(_agreementSignatureRepo));
    }

    function isAllowed(address _address) external view override returns (bool) {
        // 1. Sanction check (optional — skip if address(0))
        if (address(sanctionsList) != address(0) && sanctionsList.isSanctioned(_address))
            return false;
        // 2. KYC check (optional — skip if address(0))
        if (address(kycGate) != address(0) && !kycGate.isAllowed(_address))
            return false;
        // 3. Agreement signature check (skip if agreementSignatureRepo not set)
        if (address(agreementSignatureRepo) != address(0)) {
            uint256 docVersion = poolDocumentVersion[msg.sender];
            if (!agreementSignatureRepo.hasSigned(msg.sender, docVersion, _address))
                return false;
        }
        return true;
    }

    function setPoolDocumentVersion(address pool, uint256 version) external onlyOwner {
        poolDocumentVersion[pool] = version;
        emit PoolDocumentVersionSet(pool, version);
    }

    function setSanctionsList(ISanctionsList _sanctionsList) external onlyOwner {
        address old = address(sanctionsList);
        sanctionsList = _sanctionsList;
        emit SanctionsListUpdated(old, address(_sanctionsList));
    }

    function setKycGate(IBullaKycGate _kycGate) external onlyOwner {
        address old = address(kycGate);
        kycGate = _kycGate;
        emit KycGateUpdated(old, address(_kycGate));
    }

    function setAgreementSignatureRepo(IAgreementSignatureRepo _agreementSignatureRepo) external onlyOwner {
        address old = address(agreementSignatureRepo);
        agreementSignatureRepo = _agreementSignatureRepo;
        emit AgreementSignatureRepoUpdated(old, address(_agreementSignatureRepo));
    }
}
