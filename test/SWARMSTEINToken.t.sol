// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SWARMSTEINToken} from "../src/SWARMSTEINToken.sol";

/// @notice Smoke tests for the Swarmstein token: deployment, supply, metadata, transfers,
/// approvals, and the absence of any admin surface. A fuller suite (fuzz, invariants) is written
/// separately; this file deliberately stays small and fast.
contract SWARMSTEINTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;

    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    SWARMSTEINToken token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(deployer);
        token = new SWARMSTEINToken();
    }

    // ------------------------------------------------------------------------------------------
    // Deployment and supply
    // ------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Swarmstein");
        assertEq(token.symbol(), "SWARMSTEIN");
        assertEq(token.decimals(), 18);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_constructorEmitsMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), deployer, SUPPLY);
        vm.prank(deployer);
        new SWARMSTEINToken();
    }

    function test_supplyIsIndependentOfDeployer() public {
        vm.prank(alice);
        SWARMSTEINToken other = new SWARMSTEINToken();
        assertEq(other.totalSupply(), SUPPLY);
        assertEq(other.balanceOf(alice), SUPPLY);
        assertEq(other.balanceOf(deployer), 0);
    }

    // ------------------------------------------------------------------------------------------
    // Transfers
    // ------------------------------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        uint256 amount = 123_456 * 1e18;
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, alice, amount);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, amount));

        assertEq(token.balanceOf(alice), amount, "no fee or tax on receive");
        assertEq(token.balanceOf(deployer), SUPPLY - amount, "no fee or tax on send");
        assertEq(token.totalSupply(), SUPPLY, "supply unchanged");
    }

    function test_transferWholeBalanceAndZero() public {
        vm.startPrank(deployer);
        assertTrue(token.transfer(alice, SUPPLY), "no transfer limit");
        assertTrue(token.transfer(bob, 0), "zero transfer allowed");
        vm.stopPrank();
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        token.transfer(deployer, 1e18);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SWARMSTEINToken.InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(SWARMSTEINToken.InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    // ------------------------------------------------------------------------------------------
    // Approvals and transferFrom
    // ------------------------------------------------------------------------------------------

    function test_approveAndTransferFrom() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, alice, 500);
        vm.prank(deployer);
        assertTrue(token.approve(alice, 500));
        assertEq(token.allowance(deployer, alice), 500);

        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 300));
        assertEq(token.balanceOf(bob), 300);
        assertEq(token.balanceOf(deployer), SUPPLY - 300);
        assertEq(token.allowance(deployer, alice), 200, "allowance decremented");
    }

    function test_transferFromRevertsBeyondAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 100);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(SWARMSTEINToken.InsufficientAllowance.selector, alice, 100, 101)
        );
        token.transferFrom(deployer, bob, 101);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SWARMSTEINToken.InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1e18);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
        assertEq(token.balanceOf(bob), 1e18);
    }

    function test_approveRevertsForZeroSpender() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(SWARMSTEINToken.InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ------------------------------------------------------------------------------------------
    // No admin surface
    // ------------------------------------------------------------------------------------------

    function test_noMintOwnerOrPauseSelectors() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "blacklist(address)",
            "setFee(uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], deployer, uint256(1));
            vm.prank(deployer);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    function test_noEtherAccepted() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "token has no receive/fallback");
    }
}
