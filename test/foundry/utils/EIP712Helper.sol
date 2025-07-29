// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "@bulla/contracts-v2/src/types/Types.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import {BullaClaimPermitLib} from "@bulla/contracts-v2/src/libraries/BullaClaimPermitLib.sol";
import {IBullaApprovalRegistry} from "@bulla/contracts-v2/src/interfaces/IBullaApprovalRegistry.sol";
import {IBullaControllerRegistry} from "@bulla/contracts-v2/src/interfaces/IBullaControllerRegistry.sol";
import {BullaClaimV2} from "@bulla/contracts-v2/src/BullaClaimV2.sol";

address constant HEVM_ADDRESS = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;

function privateKeyValidity(uint256 pk) pure returns (bool) {
    return pk != 0 && pk < 115792089237316195423570985008687907852837564279074904382605163141518161494337;
}

function splitSig(bytes memory sig) pure returns (uint8 v, bytes32 r, bytes32 s) {
    assembly {
        r := mload(add(sig, 0x20))
        s := mload(add(sig, 0x40))
        v := byte(0, mload(add(sig, 0x60)))
    }
}

contract EIP712Helper {
    using Strings for *;

    Vm constant vm = Vm(HEVM_ADDRESS);

    IBullaApprovalRegistry public approvalRegistry;
    IBullaControllerRegistry public controllerRegistry;

    string public EIP712_NAME;
    bytes32 public DOMAIN_SEPARATOR;
    bytes32 public CREATE_CLAIM_TYPEHASH;

    constructor(address _bullaClaim) {
        BullaClaimV2 bullaClaim = BullaClaimV2(_bullaClaim);
        approvalRegistry = IBullaApprovalRegistry(bullaClaim.approvalRegistry());
        controllerRegistry = IBullaControllerRegistry(approvalRegistry.controllerRegistry());

        DOMAIN_SEPARATOR = approvalRegistry.DOMAIN_SEPARATOR();
        CREATE_CLAIM_TYPEHASH = BullaClaimPermitLib.CREATE_CLAIM_TYPEHASH;
    }

    function _hashPermitCreateClaim(
        address user,
        address controller,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed
    ) internal view returns (bytes32) {
        CreateClaimApproval memory approvals = approvalRegistry.getApprovals(user, controller);

        return keccak256(
            abi.encode(
                CREATE_CLAIM_TYPEHASH,
                user,
                controller,
                keccak256(
                    bytes(
                        BullaClaimPermitLib.getPermitCreateClaimMessage(
                            controllerRegistry, controller, approvalType, approvalCount, isBindingAllowed
                        )
                    )
                ),
                approvalType,
                approvalCount,
                isBindingAllowed,
                approvals.nonce
            )
        );
    }

    // computes the hash of the fully encoded EIP-712 message for the domain, which can be used to recover the signer
    function getPermitCreateClaimDigest(
        address user,
        address controller,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed
    ) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                _hashPermitCreateClaim(user, controller, approvalType, approvalCount, isBindingAllowed)
            )
        );
    }

    function signCreateClaimPermit(
        uint256 pk,
        address user,
        address controller,
        CreateClaimApprovalType approvalType,
        uint64 approvalCount,
        bool isBindingAllowed
    ) public view returns (bytes memory) {
        bytes32 digest = getPermitCreateClaimDigest(user, controller, approvalType, approvalCount, isBindingAllowed);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /*///////////////////// ERC20 PERMIT FUNCTIONALITY /////////////////////*/

    /// @notice Creates an ERC20 permit digest for signing
    /// @param token The ERC20 token contract address
    /// @param owner The token owner
    /// @param spender The approved spender
    /// @param value The approval amount
    /// @param deadline The permit deadline
    /// @return The digest to be signed
    function getERC20PermitDigest(address token, address owner, address spender, uint256 value, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        // ERC20 Permit typehash as defined in EIP-2612
        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

        // Get the token's nonce for this owner
        uint256 nonce;
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSignature("nonces(address)", owner));
        if (success && data.length >= 32) {
            nonce = abi.decode(data, (uint256));
        }

        // Get the token's domain separator
        bytes32 domainSeparator;
        (success, data) = token.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        if (success && data.length >= 32) {
            domainSeparator = abi.decode(data, (bytes32));
        }

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));

        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    /// @notice Signs an ERC20 permit
    /// @param pk The private key to sign with
    /// @param token The ERC20 token contract address
    /// @param owner The token owner
    /// @param spender The approved spender
    /// @param value The approval amount
    /// @param deadline The permit deadline
    /// @return The signature bytes (r, s, v format)
    function signERC20Permit(uint256 pk, address token, address owner, address spender, uint256 value, uint256 deadline)
        public view
        returns (bytes memory)
    {
        bytes32 digest = getERC20PermitDigest(token, owner, spender, value, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Signs an ERC20 permit and returns v, r, s components separately
    /// @param pk The private key to sign with
    /// @param token The ERC20 token contract address
    /// @param owner The token owner
    /// @param spender The approved spender
    /// @param value The approval amount
    /// @param deadline The permit deadline
    /// @return v The recovery parameter
    /// @return r The first 32 bytes of the signature
    /// @return s The second 32 bytes of the signature
    function signERC20PermitComponents(
        uint256 pk,
        address token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline
    ) public view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 digest = getERC20PermitDigest(token, owner, spender, value, deadline);
        return vm.sign(pk, digest);
    }
}
