// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Swarmstein (SWARMSTEIN)
/// @notice A plain, fixed-supply ERC-20 for the Swarmstein launch on Robinhood Chain.
/// @dev Design, all of it deliberate:
///  - The whole supply (1,000,000,000 * 1e18 units) is minted once, to `msg.sender`, in the
///    constructor. At launch `msg.sender` is the ProjectFactory, which distributes the supply
///    (swarm share, pool seed, remainder). Nothing here reserves, sends or subtracts any of it.
///  - There is no mint function, no owner, no admin, no pause, no blacklist, no fee, no tax and
///    no transfer limit. Every parameter is a compile-time constant.
///  - No proxy, no upgradeability, no `delegatecall`, no `selfdestruct`.
///  - Self-contained: no imports, so every byte of the deployed code is in this file.
///  - Standard ERC-20 (EIP-20) with the EIP-20 `Transfer` and `Approval` events, the usual
///    zero-address rejections, and an infinite allowance (`type(uint256).max`) that is not
///    decremented on `transferFrom`.
contract SWARMSTEINToken {
    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    string private constant NAME = "Swarmstein";
    string private constant SYMBOL = "SWARMSTEIN";
    uint8 private constant DECIMALS = 18;

    /// @notice The fixed total supply in minor units: 1,000,000,000 tokens with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    // ---------------------------------------------------------------------------------------------
    // Events (EIP-20)
    // ---------------------------------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error InsufficientBalance(address from, uint256 balance, uint256 needed);
    error InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error InvalidReceiver(address receiver);
    error InvalidSender(address sender);
    error InvalidApprover(address approver);
    error InvalidSpender(address spender);

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    mapping(address account => uint256) private _balances;
    mapping(address owner => mapping(address spender => uint256)) private _allowances;

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @notice Mints the entire fixed supply to the deployer (the launch factory) exactly once.
    /// @dev Takes no arguments and calls no other contract, so it deploys on an empty chain.
    constructor() {
        _balances[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-20 metadata
    // ---------------------------------------------------------------------------------------------

    function name() external pure returns (string memory) {
        return NAME;
    }

    function symbol() external pure returns (string memory) {
        return SYMBOL;
    }

    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-20 views
    // ---------------------------------------------------------------------------------------------

    /// @notice Always the fixed supply: nothing mints or burns after the constructor.
    function totalSupply() external pure returns (uint256) {
        return TOTAL_SUPPLY;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-20 mutators
    // ---------------------------------------------------------------------------------------------

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0)) revert InvalidSender(address(0));
        if (to == address(0)) revert InvalidReceiver(address(0));

        uint256 fromBalance = _balances[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);
        unchecked {
            // fromBalance >= amount, checked above.
            _balances[from] = fromBalance - amount;
            // The sum of all balances is TOTAL_SUPPLY < 2**256, so this cannot overflow.
            _balances[to] += amount;
        }

        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        if (owner == address(0)) revert InvalidApprover(address(0));
        if (spender == address(0)) revert InvalidSpender(address(0));
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) private {
        uint256 current = _allowances[owner][spender];
        if (current == type(uint256).max) return;
        if (current < amount) revert InsufficientAllowance(spender, current, amount);
        unchecked {
            _allowances[owner][spender] = current - amount;
        }
        // Note: no Approval event on allowance spend, matching OpenZeppelin v5 behaviour.
    }
}
