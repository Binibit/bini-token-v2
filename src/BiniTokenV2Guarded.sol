// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// MODEL C reference (ECON-2 hardened). Permanently guarded BINI: BOOTSTRAP -> GUARDED, no OPEN.
// DISCLOSURE: no confiscation / forced-transfer / admin-burn / balance-rewrite. BUT it HAS governed
// transfer-eligibility and an emergency address FREEZE (emergencyRevoke -> class NONE): a frozen address
// keeps its balance but cannot send or receive until a governed manager re-approves it. This must be
// disclosed to holders, CEX, custody, MMs, auditors, and legal.

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ERC20PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {ERC20CappedUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20CappedUpgradeable.sol";
import {AccessControlDefaultAdminRulesUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";

contract BiniTokenV2Guarded is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    ERC20PausableUpgradeable,
    ERC20CappedUpgradeable,
    AccessControlDefaultAdminRulesUpgradeable,
    UUPSUpgradeable
{
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether;

    enum TransferMode { BOOTSTRAP, GUARDED }
    enum AccountClass { NONE, PARTICIPANT, SYSTEM, CUSTODY, MARKET_ENDPOINT }

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 public constant POLICY_MANAGER_ROLE = keccak256("POLICY_MANAGER_ROLE");
    // Per-class managers — each may ONLY approve/revoke its own class (boundary-enforced). Sensitive
    // classes (SYSTEM/CUSTODY/MARKET_ENDPOINT/OPERATOR) belong to the Timelock; PARTICIPANT to Ops.
    bytes32 public constant PARTICIPANT_MANAGER_ROLE = keccak256("PARTICIPANT_MANAGER_ROLE");
    bytes32 public constant SYSTEM_MANAGER_ROLE = keccak256("SYSTEM_MANAGER_ROLE");
    bytes32 public constant CUSTODY_MANAGER_ROLE = keccak256("CUSTODY_MANAGER_ROLE");
    bytes32 public constant ENDPOINT_MANAGER_ROLE = keccak256("ENDPOINT_MANAGER_ROLE");
    bytes32 public constant OPERATOR_MANAGER_ROLE = keccak256("OPERATOR_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_REVOKER_ROLE = keccak256("EMERGENCY_REVOKER_ROLE");
    bytes32 public constant BOOTSTRAP_OPERATOR_ROLE = keccak256("BOOTSTRAP_OPERATOR_ROLE");

    /// @custom:storage-location erc7201:binibit.storage.BiniTokenV2Guarded
    struct GuardedStorage {
        TransferMode mode;
        mapping(address => AccountClass) accountClass;
        mapping(address => bool) approvedOperator;
    }

    bytes32 private constant STORAGE_LOCATION =
        0x8f8334c80b8b39b92d35e01e80c0222e020c97fe2254163fdb7f364477b6f000;

    function _s() private pure returns (GuardedStorage storage $) {
        assembly { $.slot := STORAGE_LOCATION }
    }

    error ZeroAddress();
    error AlreadyGuarded();
    error TransferNotAllowed(address from, address to, address operator);
    error ClassBoundaryViolation(address account, AccountClass current, AccountClass target);
    error BootstrapRecipientNotApproved(address to);

    event GuardedModeActivated(address indexed executor, uint256 indexed blockNumber);
    event AccountClassSet(address indexed account, AccountClass class);
    event OperatorSet(address indexed operator, bool approved);
    event AddressFrozen(address indexed account);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    /**
     * @param adminTimelock          DEFAULT_ADMIN + UPGRADER + POLICY + SYSTEM/CUSTODY/ENDPOINT/OPERATOR managers.
     * @param operationsSafe         PARTICIPANT_MANAGER only (retail onboarding).
     * @param securitySafe           PAUSER + EMERGENCY_REVOKER.
     * @param governanceUnpauserSafe UNPAUSER.
     * @param genesisDistributionSafe receives 1B, BOOTSTRAP_OPERATOR only. Emptied + role revoked at go-live.
     * @param adminTransferDelay     2-step admin handover delay; deploy script MUST assert the approved value.
     */
    function initialize(
        address adminTimelock,
        address operationsSafe,
        address securitySafe,
        address governanceUnpauserSafe,
        address genesisDistributionSafe,
        uint48 adminTransferDelay
    ) external initializer {
        if (
            adminTimelock == address(0) || operationsSafe == address(0) || securitySafe == address(0)
                || governanceUnpauserSafe == address(0) || genesisDistributionSafe == address(0)
        ) revert ZeroAddress();

        __ERC20_init("Binibit", "BINI");
        __ERC20Permit_init("Binibit");
        __ERC20Pausable_init();
        __ERC20Capped_init(MAX_SUPPLY);
        __AccessControlDefaultAdminRules_init(adminTransferDelay, adminTimelock);

        // Sensitive authorities -> Timelock.
        _grantRole(UPGRADER_ROLE, adminTimelock);
        _grantRole(POLICY_MANAGER_ROLE, adminTimelock);
        _grantRole(SYSTEM_MANAGER_ROLE, adminTimelock);
        _grantRole(CUSTODY_MANAGER_ROLE, adminTimelock);
        _grantRole(ENDPOINT_MANAGER_ROLE, adminTimelock);
        _grantRole(OPERATOR_MANAGER_ROLE, adminTimelock);
        // Operational / emergency.
        _grantRole(PARTICIPANT_MANAGER_ROLE, operationsSafe);
        _grantRole(PAUSER_ROLE, securitySafe);
        _grantRole(EMERGENCY_REVOKER_ROLE, securitySafe);
        _grantRole(UNPAUSER_ROLE, governanceUnpauserSafe);
        _grantRole(BOOTSTRAP_OPERATOR_ROLE, genesisDistributionSafe);

        _s().mode = TransferMode.BOOTSTRAP;
        _mint(genesisDistributionSafe, MAX_SUPPLY);
    }

    // --- mode (one-way; NO OPEN) ---
    function activateGuardedMode() external onlyRole(POLICY_MANAGER_ROLE) {
        if (_s().mode == TransferMode.GUARDED) revert AlreadyGuarded();
        _s().mode = TransferMode.GUARDED;
        emit GuardedModeActivated(msg.sender, block.number);
    }

    function transferMode() external view returns (TransferMode) { return _s().mode; }
    function accountClassOf(address a) external view returns (AccountClass) { return _s().accountClass[a]; }
    function isApprovedOperator(address a) external view returns (bool) { return _s().approvedOperator[a]; }
    function isApproved(address a) external view returns (bool) { return _s().accountClass[a] != AccountClass.NONE; }

    // --- per-class perimeter management (boundary-enforced) ---
    /// @dev A manager may only move an address between NONE and its OWN `managed` class; it can NEVER
    ///      reclassify or revoke an address currently held in a different class. Closes the P0.1 bypass
    ///      where PARTICIPANT_MANAGER could approve a pool as SYSTEM/CUSTODY.
    function _manageClass(address[] calldata accts, AccountClass managed, bool approved) internal {
        GuardedStorage storage $ = _s();
        for (uint256 i; i < accts.length; ++i) {
            if (accts[i] == address(0)) revert ZeroAddress();
            AccountClass cur = $.accountClass[accts[i]];
            if (cur != AccountClass.NONE && cur != managed) revert ClassBoundaryViolation(accts[i], cur, managed);
            AccountClass next = approved ? managed : AccountClass.NONE;
            $.accountClass[accts[i]] = next;
            emit AccountClassSet(accts[i], next);
        }
    }

    function setParticipants(address[] calldata a, bool ok) external onlyRole(PARTICIPANT_MANAGER_ROLE) {
        _manageClass(a, AccountClass.PARTICIPANT, ok);
    }
    function setSystemAccounts(address[] calldata a, bool ok) external onlyRole(SYSTEM_MANAGER_ROLE) {
        _manageClass(a, AccountClass.SYSTEM, ok);
    }
    function setCustodyAccounts(address[] calldata a, bool ok) external onlyRole(CUSTODY_MANAGER_ROLE) {
        _manageClass(a, AccountClass.CUSTODY, ok);
    }
    function setMarketEndpoints(address[] calldata a, bool ok) external onlyRole(ENDPOINT_MANAGER_ROLE) {
        _manageClass(a, AccountClass.MARKET_ENDPOINT, ok);
    }
    function setOperators(address[] calldata a, bool ok) external onlyRole(OPERATOR_MANAGER_ROLE) {
        for (uint256 i; i < a.length; ++i) {
            if (a[i] == address(0)) revert ZeroAddress();
            _s().approvedOperator[a[i]] = ok;
            emit OperatorSet(a[i], ok);
        }
    }

    /// @notice Emergency FREEZE (revoke-fast, Security Safe): sets class NONE + removes operator from ANY
    ///         class. Balance is UNCHANGED. Restore is via the appropriate normal manager. This is a
    ///         governed transfer freeze — disclosed, not a confiscation.
    function emergencyRevoke(address[] calldata a) external onlyRole(EMERGENCY_REVOKER_ROLE) {
        GuardedStorage storage $ = _s();
        for (uint256 i; i < a.length; ++i) {
            $.accountClass[a[i]] = AccountClass.NONE;
            $.approvedOperator[a[i]] = false;
            emit AddressFrozen(a[i]);
        }
    }

    // --- pause (split) ---
    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(UNPAUSER_ROLE) { _unpause(); }

    // --- transfer policy: pause > guard > cap ---
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20PausableUpgradeable, ERC20CappedUpgradeable)
    {
        _requireNotPaused();
        if (from != address(0)) {
            GuardedStorage storage $ = _s();
            if ($.mode == TransferMode.BOOTSTRAP) {
                // Onboarding-before-distribution: bootstrap operator may only send to ALREADY-approved
                // recipients (prevents trapped balances after GUARDED). Mint (from==0) is exempt above.
                if (!hasRole(BOOTSTRAP_OPERATOR_ROLE, from)) revert TransferNotAllowed(from, to, msg.sender);
                if ($.accountClass[to] == AccountClass.NONE) revert BootstrapRecipientNotApproved(to);
            } else {
                bool bothApproved =
                    $.accountClass[from] != AccountClass.NONE && $.accountClass[to] != AccountClass.NONE;
                // Feeding a MARKET_ENDPOINT (pool / V4 PoolManager) requires an approved OPERATOR (the V4
                // lever: blocks direct user->PoolManager, closing the ERC-6909 claims entry).
                bool senderOk = ($.accountClass[to] == AccountClass.MARKET_ENDPOINT)
                    ? $.approvedOperator[msg.sender]
                    : (msg.sender == from || $.approvedOperator[msg.sender]);
                if (!(bothApproved && senderOk)) revert TransferNotAllowed(from, to, msg.sender);
            }
        }
        super._update(from, to, value);
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(UPGRADER_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();
    }
}
