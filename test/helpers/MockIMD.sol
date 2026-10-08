// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Test double only. Installed at the pinned IMD address in an isolated local EVM.
contract MockIMD {
    string public constant symbol = "IMD";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public failTransfers;
    bool public taxTransfers;
    address public reenterTarget;
    bytes public reenterData;
    bool public reentered;
    bool public reentrySucceeded;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setFail(bool fail) external {
        failTransfers = fail;
    }

    function setTax(bool tax) external {
        taxTransfers = tax;
    }

    function setReentry(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) private returns (bool) {
        if (failTransfers) return false;
        balanceOf[from] -= amount;
        balanceOf[to] += taxTransfers ? amount - amount / 100 : amount;
        if (reenterTarget != address(0) && !reentered) {
            reentered = true;
            (reentrySucceeded,) = reenterTarget.call(reenterData);
        }
        return true;
    }
}
