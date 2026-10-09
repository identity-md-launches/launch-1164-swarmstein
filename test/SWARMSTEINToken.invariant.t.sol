// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SWARMSTEINToken} from "../src/SWARMSTEINToken.sol";

/// @notice Drives the token with random sequences of transfer, transferFrom and approve from a
/// bounded set of actors, plus the calls that must fail (over-balance, over-allowance, zero
/// address, admin selectors), and keeps ghost accounting the invariants are checked against.
contract SWARMSTEINHandler is Test {
    SWARMSTEINToken public token;
    address[] public actors;

    // Ghost accounting.
    mapping(address => uint256) public ghostSent;
    mapping(address => uint256) public ghostReceived;
    mapping(address => uint256) public ghostInitial;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    uint256 public calls;
    uint256 public successfulTransfers;
    uint256 public successfulTransferFroms;
    uint256 public rejectedCalls;

    constructor(SWARMSTEINToken token_, address deployer, uint256 extraActors) {
        token = token_;
        actors.push(deployer);
        ghostInitial[deployer] = token_.balanceOf(deployer);
        for (uint256 i; i < extraActors; ++i) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    // --------------------------------------------------------------------------------------
    // Successful paths
    // --------------------------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        calls++;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        bool ok = token.transfer(to, amount);
        assertTrue(ok, "transfer returned false");
        ghostSent[from] += amount;
        ghostReceived[to] += amount;
        successfulTransfers++;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        calls++;
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        // Mostly finite, sometimes infinite, so both allowance paths are exercised.
        if (amount % 7 == 0) amount = type(uint256).max;
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        ghostAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        calls++;
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(from, spender);
        uint256 cap = allowed < token.balanceOf(from) ? allowed : token.balanceOf(from);
        amount = bound(amount, 0, cap);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount), "transferFrom returned false");
        if (allowed != type(uint256).max) ghostAllowance[from][spender] = allowed - amount;
        ghostSent[from] += amount;
        ghostReceived[to] += amount;
        successfulTransferFroms++;
    }

    // --------------------------------------------------------------------------------------
    // Paths that must be rejected, interleaved with the successful ones
    // --------------------------------------------------------------------------------------

    function transferOverBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        calls++;
        address from = _actor(fromSeed);
        uint256 held = token.balanceOf(from);
        excess = bound(excess, 1, type(uint256).max - held);
        vm.prank(from);
        vm.expectRevert(
            abi.encodeWithSelector(SWARMSTEINToken.InsufficientBalance.selector, from, held, held + excess)
        );
        token.transfer(_actor(toSeed), held + excess);
        rejectedCalls++;
    }

    function transferFromOverAllowance(uint256 spenderSeed, uint256 fromSeed, uint256 excess) external {
        calls++;
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        uint256 allowed = token.allowance(from, spender);
        if (allowed == type(uint256).max) return;
        excess = bound(excess, 1, type(uint256).max - allowed);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(
                SWARMSTEINToken.InsufficientAllowance.selector, spender, allowed, allowed + excess
            )
        );
        token.transferFrom(from, spender, allowed + excess);
        rejectedCalls++;
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        calls++;
        address from = _actor(fromSeed);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(SWARMSTEINToken.InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
        rejectedCalls++;
    }

    function adminCall(uint256 callerSeed, uint256 which) external {
        calls++;
        string[8] memory signatures = [
            "mint(address,uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "blacklist(address)",
            "setFee(uint256)",
            "transferOwnership(address)",
            "upgradeTo(address)"
        ];
        address caller = _actor(callerSeed);
        bytes memory data =
            abi.encodeWithSignature(signatures[which % signatures.length], caller, uint256(1e27));
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, "an admin-shaped selector succeeded");
        rejectedCalls++;
    }
}

/// @notice Invariants over random call sequences: the supply is fixed, every balance equals its
/// ghost ledger, the sum of balances is the supply, allowances are exact, and the code never
/// changes.
contract SWARMSTEINTokenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;

    SWARMSTEINToken token;
    SWARMSTEINHandler handler;
    address deployer = makeAddr("deployer");
    bytes32 codeHashAtDeployment;

    function setUp() public {
        vm.prank(deployer);
        token = new SWARMSTEINToken();
        codeHashAtDeployment = address(token).codehash;
        handler = new SWARMSTEINHandler(token, deployer, 6);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_sumOfBalancesIsTheSupply() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, SUPPLY, "balances do not sum to the supply");
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
        assertEq(token.balanceOf(address(token)), 0, "the token holds itself");
        assertEq(token.balanceOf(address(handler)), 0, "the handler holds tokens");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_supplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_everyBalanceMatchesItsLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            uint256 expected =
                handler.ghostInitial(actor) + handler.ghostReceived(actor) - handler.ghostSent(actor);
            assertEq(token.balanceOf(actor), expected, "a balance drifted from what was sent and received");
            assertLe(token.balanceOf(actor), SUPPLY, "a balance exceeds the supply");
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_allowancesAreExact() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.ghostAllowance(owner, spender),
                    "allowance drifted"
                );
            }
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_codeIsImmutable() public view {
        assertEq(address(token).codehash, codeHashAtDeployment, "the token's code changed");
        assertEq(address(token).balance, 0, "the token acquired ETH");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_handlerExercisedBothPaths() public view {
        // A sanity check on the campaign itself: if nothing ever succeeded or nothing was ever
        // rejected, the other invariants proved less than they appear to.
        if (handler.calls() > 40) {
            assertGt(
                handler.successfulTransfers() + handler.successfulTransferFroms(), 0, "no transfer succeeded"
            );
            assertGt(handler.rejectedCalls(), 0, "no call was rejected");
        }
    }
}
