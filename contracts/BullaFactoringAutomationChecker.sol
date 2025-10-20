// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;
import './BullaFactoring.sol';

contract BullaFactoringAutomationCheckerV2 {
    function checker(address poolAddress)
        external
        view
        returns (bool canExec, bytes memory execPayload)
    {
        (uint256[] memory paidInvoices, , uint256[] memory impairedInvoices, ) = BullaFactoringV2_1(poolAddress).viewPoolStatus();

        canExec = paidInvoices.length + impairedInvoices.length > 0;

        execPayload = abi.encodeCall(BullaFactoringV2_1.reconcileActivePaidInvoices, ());
    }
}