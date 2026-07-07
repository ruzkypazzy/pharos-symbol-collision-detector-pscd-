// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../assets/contracts/SymbolRegistry.sol";

contract SymbolRegistryTest is Test {
    SymbolRegistry internal reg;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal ownerEOA = makeAddr("ownerEOA");
    address internal owner;

    /// Allow this test contract to receive ETH (when it is the owner) so that
    /// emergencyWithdrawal can pay out to it.
    receive() external payable {}

    event SymbolRegistered(
        bytes32 indexed symbolHash,
        string symbol,
        address indexed claimer,
        uint256 deposit,
        uint64 timestamp,
        uint64 blockNumber,
        string projectURI
    );

    event SymbolReleased(
        bytes32 indexed symbolHash,
        string symbol,
        address indexed claimer,
        uint256 refund
    );

    function setUp() public {
        vm.prank(ownerEOA);
        reg = new SymbolRegistry();
        owner = reg.owner();
        assertEq(owner, ownerEOA, "owner should be deployer");
        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.label(owner, "owner");
    }

    // ------------------------------------------------------------------
    // register
    // ------------------------------------------------------------------

    function test_register_happyPath() public {
        vm.deal(alice, 1 ether);
        bytes32 expected = keccak256(bytes("SKP"));

        vm.expectEmit(true, true, false, true);
        emit SymbolRegistered(
            expected,
            "SKP",
            alice,
            0.001 ether,
            uint64(block.timestamp),
            uint64(block.number),
            "https://skp.example"
        );

        vm.prank(alice);
        reg.register{value: 0.001 ether}("SKP", "https://skp.example");

        assertTrue(reg.isClaimed("SKP"));
        assertTrue(reg.isClaimed("skp")); // case-insensitive
        assertTrue(reg.isClaimed(" SKP ")); // whitespace-insensitive
        assertEq(reg.activeClaimCount(), 1);
        assertEq(reg.totalHeld(), 0.001 ether);
    }

    function test_register_revertsBelowMinDeposit() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(SymbolRegistry.BelowMinimumDeposit.selector);
        reg.register{value: 0.0001 ether}("SKP", "");
    }

    function test_register_revertsAlreadyClaimed() public {
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);

        vm.prank(alice);
        reg.register{value: 0.001 ether}("USDC", "");

        vm.prank(bob);
        vm.expectRevert(SymbolRegistry.AlreadyClaimed.selector);
        reg.register{value: 0.001 ether}("USDC", "");
    }

    function test_register_acceptsHigherDeposit() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        reg.register{value: 0.5 ether}("MOON", "");
        assertEq(reg.totalHeld(), 0.5 ether);
        SymbolRegistry.Claim memory c = reg.getClaim("MOON");
        assertEq(c.deposit, 0.5 ether);
    }

    // ------------------------------------------------------------------
    // release
    // ------------------------------------------------------------------

    function test_release_refundsAndDeactivates() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        reg.register{value: 0.001 ether}("SKP", "");
        assertEq(reg.activeClaimCount(), 1);

        uint256 balBefore = alice.balance;

        vm.prank(alice);
        reg.release("SKP");

        assertFalse(reg.isClaimed("SKP"));
        assertEq(reg.activeClaimCount(), 0);
        assertEq(reg.totalHeld(), 0);
        assertEq(alice.balance - balBefore, 0.001 ether);
    }

    function test_release_revertsNotClaimed() public {
        vm.prank(alice);
        vm.expectRevert(SymbolRegistry.NotClaimed.selector);
        reg.release("NOPE");
    }

    function test_release_revertsNotClaimer() public {
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);

        vm.prank(alice);
        reg.register{value: 0.001 ether}("SKP", "");

        vm.prank(bob);
        vm.expectRevert(SymbolRegistry.NotClaimer.selector);
        reg.release("SKP");
    }

    function test_release_thenReregister() public {
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);

        vm.prank(alice);
        reg.register{value: 0.001 ether}("SKP", "");
        vm.prank(alice);
        reg.release("SKP");

        vm.prank(bob);
        reg.register{value: 0.001 ether}("SKP", "");
        SymbolRegistry.Claim memory c = reg.getClaim("SKP");
        assertEq(c.claimer, bob);
        assertTrue(c.active);
    }

    // ------------------------------------------------------------------
    // pause / emergency
    // ------------------------------------------------------------------

    function test_pause_blocksRegisterAndRelease() public {
        vm.deal(alice, 1 ether);
        vm.prank(owner);
        reg.pause();

        vm.prank(alice);
        vm.expectRevert(SymbolRegistry.PausedState.selector);
        reg.register{value: 0.001 ether}("SKP", "");

        // unpause + register, then pause again, then release reverts
        vm.prank(owner);
        reg.unpause();
        vm.prank(alice);
        reg.register{value: 0.001 ether}("SKP", "");

        vm.prank(owner);
        reg.pause();
        vm.prank(alice);
        vm.expectRevert(SymbolRegistry.PausedState.selector);
        reg.release("SKP");
    }

    function test_pause_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(SymbolRegistry.NotOwner.selector);
        reg.pause();
    }

    function test_emergencyWithdrawal_onlyOwner() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        reg.register{value: 0.5 ether}("SKP", "");

        vm.prank(alice);
        vm.expectRevert(SymbolRegistry.NotOwner.selector);
        reg.emergencyWithdrawal();

        // Owner withdraws to itself. The test contract (this) IS the owner,
        // so the contract must be able to receive ETH — give it one via deal.
        vm.deal(owner, 0);
        uint256 balBefore = owner.balance;
        vm.prank(owner);
        reg.emergencyWithdrawal();
        assertEq(owner.balance - balBefore, 0.5 ether);
        assertEq(reg.totalHeld(), 0);
    }

    // ------------------------------------------------------------------
    // views
    // ------------------------------------------------------------------

    function test_activeClaimCountOf() public {
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);

        vm.startPrank(alice);
        reg.register{value: 0.001 ether}("AAA", "");
        reg.register{value: 0.001 ether}("BBB", "");
        reg.register{value: 0.001 ether}("CCC", "");
        vm.stopPrank();

        vm.prank(bob);
        reg.register{value: 0.001 ether}("DDD", "");

        assertEq(reg.activeClaimCountOf(alice), 3);
        assertEq(reg.activeClaimCountOf(bob), 1);
        assertEq(reg.activeClaimCountOf(makeAddr("nobody")), 0);

        // release one and recount
        vm.prank(alice);
        reg.release("BBB");
        assertEq(reg.activeClaimCountOf(alice), 2);
    }

    function test_normalizationEdgeCases() public {
        vm.deal(alice, 1 ether);

        // different casings + whitespace resolve to same hash
        vm.prank(alice);
        reg.register{value: 0.001 ether}("  usdC  ", "uri");
        assertTrue(reg.isClaimed("USDC"));
        assertTrue(reg.isClaimed("usdc"));
        assertTrue(reg.isClaimed("UsDc"));
        assertFalse(reg.isClaimed("USDC.e"));
    }

    function test_minDepositConstant() public view {
        assertEq(reg.MIN_DEPOSIT(), 0.001 ether);
    }
}