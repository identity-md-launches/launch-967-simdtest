// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./helpers/TestBase.sol";
import {SIMDTEST} from "../src/SIMDTEST.sol";

contract SIMDTESTTest is TestBase {
    SIMDTEST private token;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    function setUp() public {
        token = new SIMDTEST();
    }

    function test_InitialSupplyMetadataAndDeadAllocation() public view {
        assertEq(keccak256(bytes(token.name())), keccak256("SIMDTEST"));
        assertEq(keccak256(bytes(token.symbol())), keccak256("SIMDTEST"));
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), 900_000_000 ether);
        assertEq(token.balanceOf(token.DEAD()), 100_000_000 ether);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function testFuzz_TransfersHaveNoTax(uint96 seed) public {
        uint256 amount = uint256(seed) % (900_000_000 ether + 1);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), 900_000_000 ether - amount);
        assertEq(token.balanceOf(token.DEAD()), 100_000_000 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_TransferFromExactAllowanceAndNoTax() public {
        token.approve(ALICE, 123 ether);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 123 ether);
        assertEq(token.balanceOf(BOB), 123 ether);
        assertEq(token.allowance(address(this), ALICE), 0);
        vm.prank(ALICE);
        vm.expectRevert(SIMDTEST.InsufficientAllowance.selector);
        token.transferFrom(address(this), BOB, 1);
    }

    function test_InfiniteApprovalAndSelfTransfer() public {
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(address(this), address(this), 123 ether);
        assertEq(token.allowance(address(this), ALICE), type(uint256).max);
        assertEq(token.balanceOf(address(this)), 900_000_000 ether);
        token.transfer(BOB, 0);
    }

    function test_InvalidTransfersAndBalanceRollback() public {
        vm.expectRevert(SIMDTEST.ZeroAddress.selector);
        token.transfer(address(0), 1);
        vm.expectRevert(SIMDTEST.ZeroAddress.selector);
        token.approve(address(0), 1);
        vm.expectRevert(SIMDTEST.InsufficientBalance.selector);
        token.transfer(BOB, 900_000_000 ether + 1);
        token.approve(ALICE, 1_000_000_000 ether);
        vm.prank(ALICE);
        vm.expectRevert(SIMDTEST.InsufficientBalance.selector);
        token.transferFrom(address(this), BOB, 1_000_000_000 ether);
        assertEq(token.allowance(address(this), ALICE), 1_000_000_000 ether);
    }

    function test_DeadBalanceHasNoApprovalAndNoRecoveryOrMintEntryPoints() public {
        address dead = token.DEAD();
        vm.expectRevert(SIMDTEST.InsufficientAllowance.selector);
        token.transferFrom(dead, address(this), 1);
        (bool mintOk,) =
            address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        (bool burnOk,) = address(token).call(abi.encodeWithSignature("burn(uint256)", 1));
        (bool ownerOk,) = address(token).call(abi.encodeWithSignature("owner()"));
        (bool pauseOk,) = address(token).call(abi.encodeWithSignature("pause()"));
        assertTrue(!mintOk && !burnOk && !ownerOk && !pauseOk);
        assertEq(token.balanceOf(dead), 100_000_000 ether);
    }
}
