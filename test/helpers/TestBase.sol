// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }
    function etch(address target, bytes calldata code) external;
    function prank(address sender) external;
    function startPrank(address sender) external;
    function stopPrank() external;
    function roll(uint256 blockNumber) external;
    function expectRevert() external;
    function expectRevert(bytes4 selector) external;
    function expectRevert(bytes calldata reason) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
    function snapshotState() external returns (uint256);
    function revertToState(uint256 snapshot) external returns (bool);
}

abstract contract TestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertTrue(bool value) internal pure {
        require(value, "assertTrue");
    }

    function assertEq(uint256 a, uint256 b) internal pure {
        require(a == b, "assertEq uint");
    }

    function assertEq(int256 a, int256 b) internal pure {
        require(a == b, "assertEq int");
    }

    function assertEq(address a, address b) internal pure {
        require(a == b, "assertEq address");
    }

    function assertEq(bytes32 a, bytes32 b) internal pure {
        require(a == b, "assertEq bytes32");
    }

    function assertLe(uint256 a, uint256 b) internal pure {
        require(a <= b, "assertLe");
    }
}
