// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import "./Permissions.sol";

contract PermissionsWithAragon is Permissions {
    IDAO public aragonDao;
    bytes32 private permissionId;

    constructor(address _daoAddress, bytes32 _permissionsId) {
        require(_daoAddress != address(0), "Invalid DAO address");
        aragonDao = IDAO(_daoAddress);
        permissionId = _permissionsId;
    }

    function isAllowed(address _address) override external view returns (bool) {
        return aragonDao.hasPermission(address(this), _address, permissionId, "");
    }
}