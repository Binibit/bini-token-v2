// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// P1-RC1 REFERENCE IMPLEMENTATION — locally compiled + tested, NOT an authorized release build.
// Gate A (business ratifications) unsigned; mainnet-fork V2/V3/V4, Sepolia rehearsal, and external
// audit are OWED. Reflects RC0.1 refinements: role-based launch guard (BOOTSTRAP_OPERATOR_ROLE, no
// per-address allowlist, no auto-expiry), single genesis recipient, one-way finalizeLaunch.

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ERC20PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {ERC20CappedUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20CappedUpgradeable.sol";
import {AccessControlDefaultAdminRulesUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";

/**
 * @title  BiniTokenV2
 * @notice Canonical BINI V2 — ERC-20, 18 decimals, fixed 1,000,000,000 supply minted ONCE to a
 *         single genesis distribution Safe. No runtime mint, no burn, no blacklist, no tax. UUPS.
 *         A temporary, role-gated launch guard restricts transfers to the BOOTSTRAP_OPERATOR until a
 *         one-way `finalizeLaunch()`; afterwards BINI is a plain, unrestricted ERC-20 forever.
 */
contract BiniTokenV2 is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    ERC20PausableUpgradeable,
    ERC20CappedUpgradeable,
    AccessControlDefaultAdminRulesUpgradeable,
    UUPSUpgradeable
{
    /// @notice Fixed maximum and initial supply.
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether; // 1e9 * 1e18

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 public constant LAUNCH_MANAGER_ROLE = keccak256("LAUNCH_MANAGER_ROLE");
    bytes32 public constant BOOTSTRAP_OPERATOR_ROLE = keccak256("BOOTSTRAP_OPERATOR_ROLE");

    /// @custom:storage-location erc7201:binibit.storage.BiniTokenV2
    struct BiniTokenV2Storage {
        bool launchFinalized;
    }

    // keccak256(abi.encode(uint256(keccak256("binibit.storage.BiniTokenV2")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION =
        0xb919b0c0062827d20ad4293e3018837a27a74d3431061c198bdaffa48b665b00;

    function _s() private pure returns (BiniTokenV2Storage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }

    error ZeroAddress();
    error LaunchNotFinalized();
    error LaunchAlreadyFinalized();

    event LaunchFinalized(address indexed executor, uint256 indexed blockNumber);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param adminTimelock          holds DEFAULT_ADMIN, UPGRADER and LAUNCH_MANAGER (the Ethereum Timelock).
     * @param emergencyPauserSafe     holds PAUSER (fast circuit-breaker).
     * @param governanceUnpauserSafe  holds UNPAUSER (distinct authority).
     * @param genesisDistributionSafe receives the full 1B supply and holds BOOTSTRAP_OPERATOR.
     * @param defaultAdminDelay       delay (seconds) for the 2-step default-admin handover. Accepts any
     *                                value (incl. 0) by design; the DEPLOYMENT SCRIPT MUST assert the
     *                                exact governance-approved value and record it in the manifest.
     */
    function initialize(
        address adminTimelock,
        address emergencyPauserSafe,
        address governanceUnpauserSafe,
        address genesisDistributionSafe,
        uint48 defaultAdminDelay
    ) external initializer {
        if (
            adminTimelock == address(0) || emergencyPauserSafe == address(0)
                || governanceUnpauserSafe == address(0) || genesisDistributionSafe == address(0)
        ) revert ZeroAddress();

        __ERC20_init("Binibit", "BINI");
        __ERC20Permit_init("Binibit");
        __ERC20Pausable_init();
        __ERC20Capped_init(MAX_SUPPLY);
        __AccessControlDefaultAdminRules_init(defaultAdminDelay, adminTimelock);
        // UUPSUpgradeable (canonical @openzeppelin/contracts, OZ 5.x) has no initializer — nothing to init.

        _grantRole(UPGRADER_ROLE, adminTimelock);
        _grantRole(LAUNCH_MANAGER_ROLE, adminTimelock);
        _grantRole(PAUSER_ROLE, emergencyPauserSafe);
        _grantRole(UNPAUSER_ROLE, governanceUnpauserSafe);
        _grantRole(BOOTSTRAP_OPERATOR_ROLE, genesisDistributionSafe);

        // Full supply minted once to the single genesis recipient. No other mint path exists.
        _mint(genesisDistributionSafe, MAX_SUPPLY);
    }

    // --- launch (one-way, role-gated; no per-address allowlist, no auto-expiry) ---

    /// @notice Irreversibly open transfers for everyone, forever. LAUNCH_MANAGER = the Timelock.
    /// @dev Deliberately NOT `whenNotPaused`: governance may finalize while paused (finish setup →
    ///      governed `unpause()` → market opens). The deployment/launch runbook MUST verify pause and
    ///      liquidity state before calling. There is no path back to the pre-launch restriction.
    function finalizeLaunch() external onlyRole(LAUNCH_MANAGER_ROLE) {
        if (_s().launchFinalized) revert LaunchAlreadyFinalized();
        _s().launchFinalized = true;
        emit LaunchFinalized(msg.sender, block.number);
    }

    function launchFinalized() external view returns (bool) {
        return _s().launchFinalized;
    }

    // --- pause (split authorities) ---
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(UNPAUSER_ROLE) {
        _unpause();
    }

    // --- transfer hook: pause > launch guard > cap, resolved once ---
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20PausableUpgradeable, ERC20CappedUpgradeable)
    {
        // Global pause takes PRECEDENCE over the launch restriction: a paused pre-launch transfer
        // reverts EnforcedPause, not LaunchNotFinalized (unambiguous operational semantics).
        _requireNotPaused();
        // Before launch, only the BOOTSTRAP_OPERATOR may SEND (mint from 0x0 is always exempt).
        if (!_s().launchFinalized && from != address(0)) {
            if (!hasRole(BOOTSTRAP_OPERATOR_ROLE, from)) revert LaunchNotFinalized();
        }
        super._update(from, to, value); // ERC20Pausable re-checks pause (benign), then ERC20Capped, then ERC20
    }

    // --- upgrade authorization (UPGRADER = Timelock) ---
    /// @dev RESIDUAL MASTER KEY: this implementation has no runtime mint, burn, blacklist, tax, or
    ///      confiscation. A future authorized UUPS upgrade CAN change token behavior; that power is
    ///      constrained OFF-CHAIN by the Timelock delay, an independent canceller, a release policy
    ///      that rejects upgrades adding mint/cap-change/blacklist/forced-transfer/tax/permanent-DEX,
    ///      independent review, and external audit — not by the EVM.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();
    }
}
