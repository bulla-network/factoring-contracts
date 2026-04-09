// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/access/Ownable.sol';
import "./interfaces/IAgreementSignatureRepo.sol";

contract AgreementSignatureRepo is IAgreementSignatureRepo, Ownable {
    mapping(address pool => mapping(uint256 documentVersion => mapping(address participant => bool))) public signatures;
    address public signatureApprover;

    event SignatureRecorded(address indexed pool, uint256 indexed documentVersion, address indexed participant);
    event SignatureRevoked(address indexed pool, uint256 indexed documentVersion, address indexed participant);
    event SignatureApproverChanged(address indexed oldApprover, address indexed newApprover);

    error UnauthorizedSignatureApprover(address caller);

    modifier onlySignatureApprover() {
        if (msg.sender != signatureApprover) revert UnauthorizedSignatureApprover(msg.sender);
        _;
    }

    constructor(address initialSignatureApprover) Ownable(_msgSender()) {
        signatureApprover = initialSignatureApprover;
        emit SignatureApproverChanged(address(0), initialSignatureApprover);
    }

    function setSignatureApprover(address _newApprover) external onlyOwner {
        address oldApprover = signatureApprover;
        signatureApprover = _newApprover;
        emit SignatureApproverChanged(oldApprover, _newApprover);
    }

    function recordSignature(address pool, uint256 documentVersion, address participant) external onlySignatureApprover {
        signatures[pool][documentVersion][participant] = true;
        emit SignatureRecorded(pool, documentVersion, participant);
    }

    function revokeSignature(address pool, uint256 documentVersion, address participant) external onlySignatureApprover {
        signatures[pool][documentVersion][participant] = false;
        emit SignatureRevoked(pool, documentVersion, participant);
    }

    function hasSigned(address pool, uint256 documentVersion, address participant) external view override returns (bool) {
        return signatures[pool][documentVersion][participant];
    }
}
