// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {SWARMSTEINToken} from "../src/SWARMSTEINToken.sol";

/// @notice Property and edge-case tests for the Swarmstein token, read adversarially: zero, one,
/// the whole supply, the maximum, the same call twice, callers the code did not expect, and the
/// selectors that must not exist. The smoke tests in SWARMSTEINToken.t.sol cover the happy path;
/// this file concentrates on what must fail and on what must hold for any input.
contract SWARMSTEINTokenFuzzTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;

    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    SWARMSTEINToken token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(deployer);
        token = new SWARMSTEINToken();
    }

    // ------------------------------------------------------------------------------------------
    // Supply: fixed at 1e27, minted to whoever deploys, never anything else
    // ------------------------------------------------------------------------------------------

    function testFuzz_wholeSupplyGoesToAnyDeployer(address who) public {
        vm.assume(who != address(0) && who.code.length == 0);
        vm.prank(who);
        SWARMSTEINToken fresh = new SWARMSTEINToken();
        assertEq(fresh.totalSupply(), 1e27, "supply is not 1e27");
        assertEq(fresh.balanceOf(who), 1e27, "the deployer does not hold the whole supply");
        assertEq(fresh.balanceOf(deployer), 0, "another instance leaked balance");
    }

    function test_supplyIsExactlyOneBillionWithEighteenDecimals() public view {
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** uint256(token.decimals()));
        assertEq(token.totalSupply(), 1000000000000000000000000000);
    }

    /// @dev The deployer, the most trusted address a token could have, cannot grow the supply
    /// either: every mint-shaped selector is absent, and the supply constant is unreachable.
    function test_noMintShapedSelectorFromDeployerOrStranger() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "mintTo(address,uint256)",
            "issue(uint256)",
            "_mint(address,uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "setMinter(address)",
            "initialize(address)",
            "upgradeTo(address)",
            "renounceOwnership()"
        ];
        address[2] memory callers = [deployer, makeAddr("stranger")];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < signatures.length; ++i) {
                bytes memory data = abi.encodeWithSignature(signatures[i], callers[c], type(uint128).max);
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, signatures[i]);
            }
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(callers[1]), 0);
    }

    /// @dev There is no fallback or receive: any selector outside EIP-20 reverts, with or without
    /// calldata, so nothing hidden can be reached.
    function testFuzz_unknownSelectorReverts(bytes4 selector, bytes memory tail) public {
        vm.assume(!_isKnownSelector(selector));
        vm.prank(deployer);
        (bool ok,) = address(token).call(abi.encodePacked(selector, tail));
        assertFalse(ok, "an unknown selector did not revert");
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    /// @dev Nothing is payable: a known selector with ETH attached reverts and the ETH stays put.
    function testFuzz_valueOnAnyFunctionReverts(uint96 value) public {
        vm.assume(value > 0);
        vm.deal(deployer, value);
        bytes[4] memory calls = [
            abi.encodeCall(token.transfer, (alice, 1)),
            abi.encodeCall(token.approve, (alice, 1)),
            abi.encodeCall(token.transferFrom, (deployer, alice, 0)),
            abi.encodeCall(token.balanceOf, (alice))
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call{value: value}(calls[i]);
            assertFalse(ok, "a payable path exists");
        }
        assertEq(address(token).balance, 0);
        assertEq(deployer.balance, value);
    }

    // ------------------------------------------------------------------------------------------
    // Transfers: exact, conserving, no fee, no limit
    // ------------------------------------------------------------------------------------------

    function testFuzz_transferMovesExactlyTheAmount(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, SUPPLY);

        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(deployer, to, amount);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));

        if (to == deployer) {
            assertEq(token.balanceOf(deployer), SUPPLY, "self-transfer changed the balance");
        } else {
            assertEq(token.balanceOf(to), amount, "receiver got a different amount: fee or tax");
            assertEq(token.balanceOf(deployer), SUPPLY - amount, "sender lost a different amount");
            assertEq(token.balanceOf(to) + token.balanceOf(deployer), SUPPLY, "supply not conserved");
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Two hops of arbitrary size deliver exactly what was sent at every hop: no rounding,
    /// no per-transfer deduction, no per-wallet or per-transaction cap.
    function testFuzz_chainedTransfersAreLossless(uint256 a, uint256 b) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, a);
        vm.prank(deployer);
        token.transfer(alice, a);
        vm.prank(alice);
        token.transfer(bob, b);
        vm.prank(bob);
        token.transfer(carol, b);
        assertEq(token.balanceOf(carol), b);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(alice), a - b);
        assertEq(token.balanceOf(deployer), SUPPLY - a);
    }

    function testFuzz_transferRevertsOneWeiAboveBalance(uint256 held, uint256 excess) public {
        held = bound(held, 0, SUPPLY);
        excess = bound(excess, 1, type(uint256).max - held);
        uint256 amount = held + excess;

        vm.prank(deployer);
        token.transfer(alice, held);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(SWARMSTEINToken.InsufficientBalance.selector, alice, held, amount)
        );
        token.transfer(bob, amount);

        assertEq(token.balanceOf(alice), held, "a failed transfer changed the sender");
        assertEq(token.balanceOf(bob), 0, "a failed transfer changed the receiver");
    }

    /// @dev The same transfer twice: the second succeeds only if the balance still covers it, and
    /// never delivers more than the balance.
    function testFuzz_sameTransferTwice(uint256 held, uint256 amount) public {
        held = bound(held, 1, SUPPLY);
        amount = bound(amount, 1, held);
        vm.prank(deployer);
        token.transfer(alice, held);

        vm.startPrank(alice);
        token.transfer(bob, amount);
        if (amount * 2 <= held) {
            token.transfer(bob, amount);
            assertEq(token.balanceOf(bob), amount * 2);
            assertEq(token.balanceOf(alice), held - amount * 2);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    SWARMSTEINToken.InsufficientBalance.selector, alice, held - amount, amount
                )
            );
            token.transfer(bob, amount);
            assertEq(token.balanceOf(bob), amount);
            assertEq(token.balanceOf(alice), held - amount);
        }
        vm.stopPrank();
    }

    function testFuzz_transferToZeroAddressRevertsForAnyAmount(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(SWARMSTEINToken.InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function testFuzz_transferToSelfIsANoOp(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), held, "self-transfer minted or burned");
    }

    function testFuzz_transferToSelfAboveBalanceStillReverts(uint256 held, uint256 excess) public {
        held = bound(held, 0, SUPPLY);
        excess = bound(excess, 1, type(uint256).max - held);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(SWARMSTEINToken.InsufficientBalance.selector, alice, held, held + excess)
        );
        token.transfer(alice, held + excess);
    }

    /// @dev A contract holder is not treated differently from an EOA: no hooks, no callbacks, no
    /// code-size checks. The token contract itself can even hold tokens and they are simply stuck,
    /// as with any plain ERC-20.
    function testFuzz_contractsAreOrdinaryHolders(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        address holder = address(new Holder());
        vm.prank(deployer);
        token.transfer(holder, amount);
        assertEq(token.balanceOf(holder), amount);
        Holder(holder).send(token, bob, amount);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(holder), 0);
    }

    // ------------------------------------------------------------------------------------------
    // Allowances: exact accounting, overwrite semantics, infinite only at the maximum
    // ------------------------------------------------------------------------------------------

    function testFuzz_transferFromSpendsExactlyTheAmount(uint256 allowance_, uint256 amount) public {
        allowance_ = bound(allowance_, 0, SUPPLY);
        amount = bound(amount, 0, allowance_);

        vm.prank(deployer);
        token.approve(alice, allowance_);
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(deployer, bob, amount);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, amount));

        assertEq(
            token.allowance(deployer, alice), allowance_ - amount, "allowance not reduced by exactly amount"
        );
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.balanceOf(alice), 0, "the spender received something");
    }

    function testFuzz_transferFromRevertsOneWeiAboveAllowance(uint256 allowance_, uint256 excess) public {
        allowance_ = bound(allowance_, 0, SUPPLY - 1);
        excess = bound(excess, 1, SUPPLY - allowance_);
        uint256 amount = allowance_ + excess;

        vm.prank(deployer);
        token.approve(alice, allowance_);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(SWARMSTEINToken.InsufficientAllowance.selector, alice, allowance_, amount)
        );
        token.transferFrom(deployer, bob, amount);

        assertEq(token.allowance(deployer, alice), allowance_, "a failed transferFrom consumed allowance");
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev Allowance is checked before balance, and a transferFrom that fails on balance leaves
    /// the allowance untouched.
    function testFuzz_transferFromRevertsOnBalanceAfterAllowance(uint256 held, uint256 excess) public {
        held = bound(held, 0, SUPPLY);
        excess = bound(excess, 1, type(uint256).max - held);
        uint256 amount = held + excess;
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(bob, amount);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(SWARMSTEINToken.InsufficientBalance.selector, alice, held, amount)
        );
        token.transferFrom(alice, carol, amount);
        assertEq(token.allowance(alice, bob), amount);
        assertEq(token.balanceOf(alice), held);
    }

    function testFuzz_noAllowanceMeansNoTransferFromEvenForTheDeployer(address from, uint256 amount) public {
        vm.assume(from != address(0));
        amount = bound(amount, 1, SUPPLY);
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(SWARMSTEINToken.InsufficientAllowance.selector, deployer, 0, amount)
        );
        token.transferFrom(from, deployer, amount);
    }

    function testFuzz_infiniteAllowanceIsNeverDecremented(uint256 first, uint256 second) public {
        first = bound(first, 0, SUPPLY);
        second = bound(second, 0, SUPPLY - first);
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.startPrank(alice);
        token.transferFrom(deployer, bob, first);
        token.transferFrom(deployer, carol, second);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), type(uint256).max);
        assertEq(token.balanceOf(bob), first);
        assertEq(token.balanceOf(carol), second);
    }

    /// @dev Only exactly type(uint256).max is infinite. One less is an ordinary finite allowance.
    function testFuzz_maxMinusOneAllowanceIsFinite(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        uint256 nearlyInfinite = type(uint256).max - 1;
        vm.prank(deployer);
        token.approve(alice, nearlyInfinite);
        vm.prank(alice);
        token.transferFrom(deployer, bob, amount);
        assertEq(token.allowance(deployer, alice), nearlyInfinite - amount, "max-1 was treated as infinite");
    }

    /// @dev An infinite allowance does not create balance: the transfer still fails on balance.
    function testFuzz_infiniteAllowanceCannotExceedBalance(uint256 held, uint256 excess) public {
        held = bound(held, 0, SUPPLY);
        excess = bound(excess, 1, type(uint256).max - held);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(SWARMSTEINToken.InsufficientBalance.selector, alice, held, held + excess)
        );
        token.transferFrom(alice, carol, held + excess);
    }

    function testFuzz_approveOverwritesInsteadOfAccumulating(uint256 first, uint256 second) public {
        vm.startPrank(deployer);
        vm.expectEmit(true, true, true, true, address(token));
        emit Approval(deployer, alice, first);
        token.approve(alice, first);
        vm.expectEmit(true, true, true, true, address(token));
        emit Approval(deployer, alice, second);
        token.approve(alice, second);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), second, "approve accumulated");
    }

    function testFuzz_approveZeroRevokes(uint256 allowance_, uint256 amount) public {
        allowance_ = bound(allowance_, 1, SUPPLY);
        amount = bound(amount, 1, allowance_);
        vm.startPrank(deployer);
        token.approve(alice, allowance_);
        token.approve(alice, 0);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(SWARMSTEINToken.InsufficientAllowance.selector, alice, 0, amount)
        );
        token.transferFrom(deployer, bob, amount);
    }

    function testFuzz_allowancesAreIndependentPerPair(uint256 a, uint256 b) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(alice, a);
        vm.prank(bob);
        token.approve(alice, b);
        assertEq(token.allowance(deployer, alice), a);
        assertEq(token.allowance(bob, alice), b);
        assertEq(token.allowance(alice, deployer), 0, "allowance is not symmetric");
        assertEq(token.allowance(deployer, bob), 0);
    }

    function testFuzz_approveZeroSpenderReverts(uint256 amount) public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(SWARMSTEINToken.InvalidSpender.selector, address(0)));
        token.approve(address(0), amount);
    }

    /// @dev Nobody can spend from the zero address, so tokens can never be conjured from it.
    function testFuzz_transferFromZeroAddressReverts(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(alice);
        if (amount == 0) {
            vm.expectRevert(abi.encodeWithSelector(SWARMSTEINToken.InvalidSender.selector, address(0)));
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(SWARMSTEINToken.InsufficientAllowance.selector, alice, 0, amount)
            );
        }
        token.transferFrom(address(0), alice, amount);
    }

    function testFuzz_transferFromToZeroAddressReverts(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SWARMSTEINToken.InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), amount);
    }

    /// @dev Spending an allowance emits only Transfer (OpenZeppelin v5 semantics), and the
    /// Approval event is emitted only by approve.
    function test_transferFromEmitsNoApproval() public {
        vm.prank(deployer);
        token.approve(alice, 10);
        vm.recordLogs();
        vm.prank(alice);
        token.transferFrom(deployer, bob, 4);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
    }

    // ------------------------------------------------------------------------------------------
    // Bytecode: self-contained, no delegatecall, no selfdestruct, no external calls
    // ------------------------------------------------------------------------------------------

    /// @dev Both the creation code (the constructor) and the runtime contain none of the opcodes
    /// that would let the contract be replaced, redirected or destroyed, and no call opcode at
    /// all: the token talks to no other contract.
    function test_noCallCreateDelegatecallOrSelfdestructAnywhere() public view {
        _assertNoDangerousOpcodes(address(token).code, "runtime");
        _assertNoDangerousOpcodes(type(SWARMSTEINToken).creationCode, "creation");
        assertEq(
            address(token).code, type(SWARMSTEINToken).runtimeCode, "deployed runtime differs from compiled"
        );
    }

    function _assertNoDangerousOpcodes(bytes memory code, string memory label) private pure {
        assertGt(code.length, 0, label);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF0, string.concat(label, ": CREATE"));
            assertTrue(op != 0xF1, string.concat(label, ": CALL"));
            assertTrue(op != 0xF2, string.concat(label, ": CALLCODE"));
            assertTrue(op != 0xF4, string.concat(label, ": DELEGATECALL"));
            assertTrue(op != 0xF5, string.concat(label, ": CREATE2"));
            assertTrue(op != 0xFA, string.concat(label, ": STATICCALL"));
            assertTrue(op != 0xFF, string.concat(label, ": SELFDESTRUCT"));
        }
    }

    function _isKnownSelector(bytes4 selector) private view returns (bool) {
        return selector == token.name.selector || selector == token.symbol.selector
            || selector == token.decimals.selector || selector == token.totalSupply.selector
            || selector == token.balanceOf.selector || selector == token.allowance.selector
            || selector == token.transfer.selector || selector == token.approve.selector
            || selector == token.transferFrom.selector || selector == token.TOTAL_SUPPLY.selector;
    }
}

/// @notice A contract wallet, to show contracts are ordinary holders.
contract Holder {
    function send(SWARMSTEINToken token, address to, uint256 amount) external {
        require(token.transfer(to, amount), "transfer returned false");
    }
}
