// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SIMDTESTLaunch} from "../src/SIMDTESTLaunch.sol";

/// @notice Read-only salt search; does not broadcast or access environment variables.
contract MineHook {
    error SaltNotFound();

    function run(SIMDTESTLaunch launch, uint256 start, uint256 attempts)
        external
        view
        returns (bytes32 salt, address predicted)
    {
        bytes32 initHash = launch.hookInitCodeHash();
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(launch), salt, initHash))))
            );
            if (uint160(predicted) & 0x3fff == 0x20cc && predicted.code.length == 0) {
                return (salt, predicted);
            }
        }
        revert SaltNotFound();
    }
}
