// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./helpers/TestBase.sol";
import {SIMDTEST} from "../src/SIMDTEST.sol";

/// @dev Random transfers, approvals and allowance-based transfers among a fixed set of holders.
/// Reverting attempts (zero address, overspending, overdrawn allowance) are recorded, never propagated.
contract TokenHandler is TestBase {
    SIMDTEST public immutable token;
    address[5] public holders;

    uint256 public transfers;
    uint256 public transferFroms;
    uint256 public approvals;
    uint256 public expectedReverts;
    uint256 public unexpectedReverts;
    uint256 public deadInflow;
    bool public taxObserved;
    bool public allowanceMisapplied;

    constructor(SIMDTEST token_, address[5] memory holders_) {
        token = token_;
        holders = holders_;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = holders[fromSeed % 5];
        address to = _destination(toSeed);
        uint256 balance = token.balanceOf(from);
        uint256 amount = amountSeed % (balance + 2); // may exceed the balance by one
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            if (!ok) unexpectedReverts++;
            if (amount > balance || to == address(0)) unexpectedReverts++;
            _checkMoved(from, to, amount, balance, toBefore);
            ++transfers;
        } catch {
            if (amount > balance || to == address(0)) ++expectedReverts;
            else ++unexpectedReverts;
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = holders[ownerSeed % 5];
        address spender = _destination(spenderSeed);
        uint256 amount = amountSeed % 3 == 0 ? type(uint256).max : amountSeed % (900_000_001 ether);
        vm.prank(owner);
        try token.approve(spender, amount) {
            if (spender == address(0)) ++unexpectedReverts;
            if (token.allowance(owner, spender) != amount) allowanceMisapplied = true;
            ++approvals;
        } catch {
            if (spender == address(0)) ++expectedReverts;
            else ++unexpectedReverts;
        }
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amountSeed)
        external
    {
        address spender = holders[spenderSeed % 5];
        address from = holders[fromSeed % 5];
        address to = _destination(toSeed);
        uint256 balance = token.balanceOf(from);
        uint256 allowed = token.allowance(from, spender);
        uint256 amount = amountSeed % (balance + 2);
        bool shouldFail = amount > balance || amount > allowed || to == address(0);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(spender);
        try token.transferFrom(from, to, amount) {
            if (shouldFail) ++unexpectedReverts;
            _checkMoved(from, to, amount, balance, toBefore);
            uint256 expectedAllowance = allowed == type(uint256).max ? allowed : allowed - amount;
            if (token.allowance(from, spender) != expectedAllowance) allowanceMisapplied = true;
            ++transferFroms;
        } catch {
            if (shouldFail) ++expectedReverts;
            else ++unexpectedReverts;
        }
    }

    function _checkMoved(address from, address to, uint256 amount, uint256 fromBefore, uint256 toBefore)
        private
    {
        if (from == to) {
            if (token.balanceOf(from) != fromBefore) taxObserved = true;
            return;
        }
        if (token.balanceOf(from) != fromBefore - amount) taxObserved = true;
        if (token.balanceOf(to) != toBefore + amount) taxObserved = true;
        if (to == token.DEAD()) deadInflow += amount;
    }

    function _destination(uint256 seed) private view returns (address) {
        uint256 pick = seed % 8;
        if (pick < 5) return holders[pick];
        if (pick == 5) return token.DEAD();
        if (pick == 6) return address(0);
        return address(uint160(seed)); // an arbitrary fresh address
    }
}

contract SIMDTESTInvariantTest is TestBase {
    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    SIMDTEST private token;
    TokenHandler private handler;
    address[5] private holders;

    function setUp() public {
        token = new SIMDTEST();
        holders = [address(this), address(0xA11CE), address(0xB0B), address(0xCA201), address(0xDA7E)];
        for (uint256 i = 1; i < 5; ++i) {
            token.transfer(holders[i], 100_000_000 ether);
        }
        handler = new TokenHandler(token, holders);
    }

    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function targetSelectors() public view returns (FuzzSelector[] memory selectors) {
        bytes4[] memory s = new bytes4[](3);
        s[0] = TokenHandler.transfer.selector;
        s[1] = TokenHandler.approve.selector;
        s[2] = TokenHandler.transferFrom.selector;
        selectors = new FuzzSelector[](1);
        selectors[0] = FuzzSelector(address(handler), s);
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_SupplyFixedAndFullyAccounted() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        uint256 held = token.balanceOf(token.DEAD());
        for (uint256 i; i < 5; ++i) {
            held += token.balanceOf(holders[i]);
        }
        // Transfers to arbitrary fresh addresses leave the holder set; nothing is ever created.
        assertLe(held, 1_000_000_000 ether);
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_DeadAllocationOnlyGrows() public view {
        assertEq(token.balanceOf(token.DEAD()), 100_000_000 ether + handler.deadInflow());
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_TransfersAreTaxFreeAndAllowancesExact() public view {
        assertTrue(!handler.taxObserved());
        assertTrue(!handler.allowanceMisapplied());
        assertEq(handler.unexpectedReverts(), 0);
    }

    function test_HandlerActionsExecute() public {
        handler.transfer(1, 2, 5 ether);
        handler.transfer(1, 6, 5 ether); // zero address: expected revert
        handler.approve(1, 2, 7 ether);
        handler.transferFrom(2, 1, 3, 7 ether);
        handler.transferFrom(2, 1, 3, 1); // allowance exhausted: expected revert
        handler.transfer(3, 5, 1 ether); // to dead
        assertEq(handler.transfers(), 2);
        assertEq(handler.approvals(), 1);
        assertEq(handler.transferFroms(), 1);
        assertEq(handler.expectedReverts(), 2);
        assertEq(handler.unexpectedReverts(), 0);
        assertEq(handler.deadInflow(), 1 ether);
        assertTrue(!handler.taxObserved() && !handler.allowanceMisapplied());
    }
}
