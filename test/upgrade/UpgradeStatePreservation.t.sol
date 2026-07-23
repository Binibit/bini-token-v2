// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2Guarded as G} from "../../src/BiniTokenV2Guarded.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/*//////////////////////////////////////////////////////////////////////////
                        UPGRADE CANDIDATE IMPLEMENTATIONS
//////////////////////////////////////////////////////////////////////////*/

/// @dev Legit append-only upgrade: same storage layout, adds one pure view. Storage-compatible & benign.
contract GoodV2 is G {
    function version() external pure returns (uint256) { return 2; }
}

/// @dev NOT a UUPS implementation — it has NO `proxiableUUID()`. The ERC1967/UUPS proxy MUST reject it
///      STRUCTURALLY (try IERC1822Proxiable(newImpl).proxiableUUID() fails -> ERC1967InvalidImplementation).
contract NotUUPS {
    uint256 public foo;
    function setFoo(uint256 v) external { foo = v; }
}

/// @dev A structurally-valid-looking impl whose `proxiableUUID()` returns the WRONG slot. The UUPS rollback
///      check (`_upgradeToAndCallUUPS`) compares it against the ERC1967 impl slot and reverts
///      UUPSUnsupportedProxiableUUID. STRUCTURAL reject. (Standalone: G's `proxiableUUID` is non-virtual and
///      cannot be overridden, which is itself the mechanism that makes this check reliable.)
contract WrongUUID {
    function proxiableUUID() external pure returns (bytes32) { return keccak256("wrong"); }
}

/// @dev POLICY-PROHIBITED (technically possible) impl. It IS `BiniTokenV2Guarded` (so it is guaranteed
///      storage-layout-compatible and keeps every ERC20/AccessControl view) plus one extra function.
///
///      IMPORTANT on-chain nuance: `_update` in the base is a NON-VIRTUAL override, so a naive `evilMint`
///      that called `_mint` would still route through the capped hook and revert ERC20ExceededCap (supply is
///      already == cap at genesis). That non-virtual hook is a genuine speed-bump — BUT it is not enforced by
///      the proxy. An upgrade author simply does not route through it: `evilMint` writes the ERC-7201 ERC20
///      ledger (`_balances`, `_totalSupply`) DIRECTLY, minting past the cap. The proxy cannot stop this.
contract EvilMintImpl is G {
    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC20")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC20_STORAGE =
        0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;

    function version() external pure returns (uint256) { return 666; }

    function evilMint(address to, uint256 amt) external {
        // _balances is field 0 (slot = keccak256(key, base)); _totalSupply is field 2 (slot = base + 2).
        assembly {
            mstore(0x00, and(to, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(0x20, ERC20_STORAGE)
            let bslot := keccak256(0x00, 0x40)
            sstore(bslot, add(sload(bslot), amt))
            let tsslot := add(ERC20_STORAGE, 2)
            sstore(tsslot, add(sload(tsslot), amt))
        }
    }
}

/// @dev Second POLICY-PROHIBITED impl: forced transfer / confiscation — the exact thing the token's own
///      disclosure header swears it can never do. Storage-compatible (IS G); `evilSeize` rewrites the ERC20
///      balances ledger directly, sidestepping the non-virtual guard hook.
contract EvilSeizeImpl is G {
    bytes32 private constant ERC20_STORAGE =
        0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;

    function evilSeize(address from, address to, uint256 amt) external {
        assembly {
            mstore(0x00, and(from, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(0x20, ERC20_STORAGE)
            let fslot := keccak256(0x00, 0x40)
            sstore(fslot, sub(sload(fslot), amt))
            mstore(0x00, and(to, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(0x20, ERC20_STORAGE)
            let tslot := keccak256(0x00, 0x40)
            sstore(tslot, add(sload(tslot), amt))
        }
    }
}

/*//////////////////////////////////////////////////////////////////////////
                                   TESTS
//////////////////////////////////////////////////////////////////////////*/

contract UpgradeStatePreservationTest is Test {
    // Packed snapshot to keep the state-preservation test off the "stack too deep" cliff.
    struct Snap {
        uint8 mode;
        uint8 classGenesis;
        uint8 classP1;
        uint8 classEndpoint;
        bool op1;
        address genesisSafe;
        uint256 balGenesis;
        uint256 balP1;
        uint256 allowance;
        uint256 nonceP1;
        bool roleUpgrader;
        uint256 totalSupply;
        uint256 cap;
        bool paused;
    }

    G internal t;

    address internal timelock = address(0x700); // UPGRADER + POLICY/SYSTEM/CUSTODY/ENDPOINT/OPERATOR/UNPAUSER
    address internal ops = address(0x704); // PARTICIPANT_MANAGER only
    address internal security = address(0x701); // PAUSER + EMERGENCY_REVOKER
    address internal genesis = address(0x703); // supply + BOOTSTRAP_OPERATOR (approved SYSTEM here)
    address internal endpoint = address(0xE9D); // MARKET_ENDPOINT
    address internal op1 = address(0x0B1); // approved operator
    address internal spender = address(0x5EED); // ERC20 allowance grantee
    address internal attacker = address(0xBAD);

    uint256 internal constant P1_PK = 0xA11CE;
    address internal p1; // PARTICIPANT + permit signer

    function setUp() public {
        p1 = vm.addr(P1_PK);
        G impl = new G();
        t = G(address(new ERC1967Proxy(address(impl), abi.encodeCall(
            G.initialize, (timelock, ops, security, genesis, uint48(3 days))
        ))));
    }

    function _a(address x) internal pure returns (address[] memory r) { r = new address[](1); r[0] = x; }

    /// @dev Sign a real EIP-2612 permit so the ERC20Permit nonce genuinely advances 0 -> 1.
    function _permit(uint256 pk, address owner, address spndr, uint256 value, uint256 deadline) internal {
        bytes32 typehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(typehash, owner, spndr, value, t.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", t.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        t.permit(owner, spndr, value, deadline, v, r, s);
    }

    // ------------------------------------------------------------------
    // 1. STATE PRESERVATION across a legit UUPS upgrade to GoodV2.
    // ------------------------------------------------------------------
    function test_StatePreservation_AcrossGoodUpgrade() public {
        // ---- build rich state on the proxy BEFORE upgrade ----
        // Timelock-owned classes.
        vm.startPrank(timelock);
        t.setSystemAccounts(_a(genesis), true); // genesis -> SYSTEM (also satisfies activation gate)
        t.setMarketEndpoints(_a(endpoint), true); // endpoint -> MARKET_ENDPOINT
        t.setOperators(_a(op1), true); // op1 -> approved operator
        vm.stopPrank();
        // Ops-owned class.
        vm.prank(ops);
        t.setParticipants(_a(p1), true); // p1 -> PARTICIPANT

        // Move BINI genesis -> p1 while BOOTSTRAP (genesis is BOOTSTRAP_OPERATOR, p1 approved recipient).
        vm.prank(genesis);
        t.transfer(p1, 5_000 ether);

        // Lock the perimeter (one-way BOOTSTRAP -> GUARDED). Genesis approved SYSTEM => gate passes.
        vm.prank(timelock);
        t.activateGuardedMode();

        // Real permit: sets allowance(p1, spender) AND advances nonce(p1) 0 -> 1.
        _permit(P1_PK, p1, spender, 777 ether, block.timestamp + 1 days);

        // Freeze the token (pause). Pause does not gate upgradeToAndCall.
        vm.prank(security);
        t.pause();

        // ---- snapshot EVERY observable field ----
        Snap memory s = Snap({
            mode: uint8(t.transferMode()),
            classGenesis: uint8(t.accountClassOf(genesis)),
            classP1: uint8(t.accountClassOf(p1)),
            classEndpoint: uint8(t.accountClassOf(endpoint)),
            op1: t.isApprovedOperator(op1),
            genesisSafe: t.genesisSafe(),
            balGenesis: t.balanceOf(genesis),
            balP1: t.balanceOf(p1),
            allowance: t.allowance(p1, spender),
            nonceP1: t.nonces(p1),
            roleUpgrader: t.hasRole(t.UPGRADER_ROLE(), timelock),
            totalSupply: t.totalSupply(),
            cap: t.cap(),
            paused: t.paused()
        });

        // sanity that state is actually non-trivial before the upgrade
        assertEq(s.mode, uint8(G.TransferMode.GUARDED), "pre: mode GUARDED");
        assertEq(s.classGenesis, uint8(G.AccountClass.SYSTEM), "pre: genesis SYSTEM");
        assertEq(s.classP1, uint8(G.AccountClass.PARTICIPANT), "pre: p1 PARTICIPANT");
        assertEq(s.classEndpoint, uint8(G.AccountClass.MARKET_ENDPOINT), "pre: endpoint ENDPOINT");
        assertTrue(s.op1, "pre: op1 operator");
        assertEq(s.allowance, 777 ether, "pre: allowance");
        assertEq(s.nonceP1, 1, "pre: nonce advanced");
        assertTrue(s.paused, "pre: paused");
        assertEq(s.balP1, 5_000 ether, "pre: p1 balance");

        // ---- UUPS upgrade to GoodV2 by the UPGRADER (timelock) ----
        GoodV2 goodV2 = new GoodV2(); // deploy BEFORE prank (CREATE would consume the prank)
        vm.prank(timelock);
        t.upgradeToAndCall(address(goodV2), "");

        // new logic reachable
        assertEq(GoodV2(address(t)).version(), 2, "GoodV2 version");

        // ---- assert EVERY field is byte-identical after the upgrade ----
        assertEq(uint8(t.transferMode()), s.mode, "post: mode");
        assertEq(uint8(t.accountClassOf(genesis)), s.classGenesis, "post: genesis class");
        assertEq(uint8(t.accountClassOf(p1)), s.classP1, "post: p1 class");
        assertEq(uint8(t.accountClassOf(endpoint)), s.classEndpoint, "post: endpoint class");
        assertEq(t.isApprovedOperator(op1), s.op1, "post: op1 operator");
        assertEq(t.genesisSafe(), s.genesisSafe, "post: genesisSafe");
        assertEq(t.balanceOf(genesis), s.balGenesis, "post: genesis balance");
        assertEq(t.balanceOf(p1), s.balP1, "post: p1 balance");
        assertEq(t.allowance(p1, spender), s.allowance, "post: allowance");
        assertEq(t.nonces(p1), s.nonceP1, "post: nonce");
        assertEq(t.hasRole(t.UPGRADER_ROLE(), timelock), s.roleUpgrader, "post: upgrader role");
        assertEq(t.totalSupply(), s.totalSupply, "post: totalSupply");
        assertEq(t.cap(), s.cap, "post: cap");
        assertEq(t.paused(), s.paused, "post: paused");
    }

    // ------------------------------------------------------------------
    // 2. STRUCTURAL REJECT — non-UUPS implementation (no proxiableUUID).
    //    The ERC1967 proxy itself reverts; nothing policy-level involved.
    // ------------------------------------------------------------------
    function test_StructuralReject_NonUUPSImpl() public {
        NotUUPS bad = new NotUUPS();
        // proxiableUUID() call fails -> the proxy itself reverts ERC1967InvalidImplementation(newImpl).
        vm.expectRevert(abi.encodeWithSelector(
            ERC1967Utils.ERC1967InvalidImplementation.selector, address(bad)
        ));
        vm.prank(timelock);
        t.upgradeToAndCall(address(bad), "");
    }

    // ------------------------------------------------------------------
    // 3. STRUCTURAL REJECT — wrong proxiableUUID value.
    // ------------------------------------------------------------------
    function test_StructuralReject_WrongProxiableUUID() public {
        WrongUUID bad = new WrongUUID();
        vm.expectRevert(abi.encodeWithSelector(
            UUPSUpgradeable.UUPSUnsupportedProxiableUUID.selector, keccak256("wrong")
        ));
        vm.prank(timelock);
        t.upgradeToAndCall(address(bad), "");
    }

    // ------------------------------------------------------------------
    // 4. AUTH — a non-UPGRADER cannot upgrade (AccessControlUnauthorizedAccount).
    // ------------------------------------------------------------------
    function test_Auth_NonUpgraderCannotUpgrade() public {
        GoodV2 good = new GoodV2();
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, ops, t.UPGRADER_ROLE()
        ));
        vm.prank(ops);
        t.upgradeToAndCall(address(good), "");
    }

    // ------------------------------------------------------------------
    // 5. POLICY-PROHIBITED (technically possible): a storage-compatible EVIL impl upgrades cleanly and then
    //    mints beyond the cap. The proxy does NOT stop it.
    //
    //    CLASSIFICATION: policy-prohibited, NOT tool-rejected — mitigated by UPGRADER=Timelock delay +
    //    external audit + OZ storage-layout validation in CI (absent in this repo). On-chain, once UPGRADER
    //    approves a storage-compatible impl, ALL of its logic (cap, guard, pause) is whatever the impl says.
    //    The non-virtual capped `_update` blocks a naive `_mint`, but the evil impl just writes the ledger
    //    directly — the proxy has no say.
    // ------------------------------------------------------------------
    function test_PolicyProhibited_EvilMintUpgradeSucceeds() public {
        uint256 supplyBefore = t.totalSupply();
        assertEq(supplyBefore, t.cap(), "genesis supply already at cap");

        // Storage-compatible malicious upgrade — proxy accepts it (structurally valid UUPS impl).
        EvilMintImpl evil = new EvilMintImpl(); // deploy BEFORE prank
        vm.prank(timelock);
        t.upgradeToAndCall(address(evil), "");

        // The evil runtime mint SUCCEEDS, pushing supply beyond the (formerly hard) cap.
        uint256 minted = 1e24;
        EvilMintImpl(address(t)).evilMint(attacker, minted);

        assertEq(t.balanceOf(attacker), minted, "evil mint credited attacker");
        assertEq(t.totalSupply(), supplyBefore + minted, "totalSupply inflated past original");
        assertGt(t.totalSupply(), t.cap(), "supply now exceeds the cap the proxy could not enforce");
    }

    // ------------------------------------------------------------------
    // 5b. POLICY-PROHIBITED companion: forced transfer / confiscation — the exact thing the token's
    //     disclosure header promises it can never do — is trivially possible via a storage-compatible impl.
    //     Same classification: governance/audit/CI are the only defenses, not the proxy.
    // ------------------------------------------------------------------
    function test_PolicyProhibited_EvilSeizeUpgradeSucceeds() public {
        // give p1 a balance to be seized (BOOTSTRAP path)
        vm.prank(ops);
        t.setParticipants(_a(p1), true);
        vm.prank(genesis);
        t.transfer(p1, 1_000 ether);

        EvilSeizeImpl evil = new EvilSeizeImpl(); // deploy BEFORE prank
        vm.prank(timelock);
        t.upgradeToAndCall(address(evil), "");

        EvilSeizeImpl(address(t)).evilSeize(p1, attacker, 1_000 ether);
        assertEq(t.balanceOf(p1), 0, "victim drained");
        assertEq(t.balanceOf(attacker), 1_000 ether, "confiscated to attacker");
    }
}
