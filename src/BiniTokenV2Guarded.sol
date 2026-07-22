// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// MODEL C REFERENCE — permanently guarded BINI (BOOTSTRAP -> GUARDED, no OPEN).
// Locally compiled + tested + V2-fork-proven; NOT an authorized release (Gate A unsigned; V3/V4/audit owed).
// Real BINI can move only inside a governed on-chain perimeter (approved accounts + operators). This does
// NOT ban fake tokens, empty pools, OTC, or CEX-internal markets — only unauthorized on-chain movement of
// REAL BINI. See docs/bini-v2/market-protection/mc1/.

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
    bytes32 public constant POLICY_MANAGER_ROLE = keccak256("POLICY_MANAGER_ROLE");       // mode transition
    bytes32 public constant ENDPOINT_MANAGER_ROLE = keccak256("ENDPOINT_MANAGER_ROLE");   // approve market endpoints (Timelock)
    bytes32 public constant PARTICIPANT_MANAGER_ROLE = keccak256("PARTICIPANT_MANAGER_ROLE"); // onboarding (Ops Safe)
    bytes32 public constant EMERGENCY_REVOKER_ROLE = keccak256("EMERGENCY_REVOKER_ROLE"); // Security Safe
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

    event GuardedModeActivated(address indexed executor, uint256 indexed blockNumber);
    event AccountClassSet(address indexed account, AccountClass class);
    event OperatorSet(address indexed operator, bool approved);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        address adminTimelock,
        address emergencyPauserSafe,
        address governanceUnpauserSafe,
        address genesisDistributionSafe,
        uint48 adminTransferDelay
    ) external initializer {
        if (
            adminTimelock == address(0) || emergencyPauserSafe == address(0)
                || governanceUnpauserSafe == address(0) || genesisDistributionSafe == address(0)
        ) revert ZeroAddress();

        __ERC20_init("Binibit", "BINI");
        __ERC20Permit_init("Binibit");
        __ERC20Pausable_init();
        __ERC20Capped_init(MAX_SUPPLY);
        __AccessControlDefaultAdminRules_init(adminTransferDelay, adminTimelock);

        _grantRole(UPGRADER_ROLE, adminTimelock);
        _grantRole(POLICY_MANAGER_ROLE, adminTimelock);
        _grantRole(ENDPOINT_MANAGER_ROLE, adminTimelock);
        _grantRole(PAUSER_ROLE, emergencyPauserSafe);
        _grantRole(UNPAUSER_ROLE, governanceUnpauserSafe);
        _grantRole(EMERGENCY_REVOKER_ROLE, emergencyPauserSafe);
        _grantRole(PARTICIPANT_MANAGER_ROLE, genesisDistributionSafe); // Ops onboarding; re-pointed at go-live
        _grantRole(BOOTSTRAP_OPERATOR_ROLE, genesisDistributionSafe);

        _s().mode = TransferMode.BOOTSTRAP;
        _mint(genesisDistributionSafe, MAX_SUPPLY);
    }

    // --- mode (one-way BOOTSTRAP -> GUARDED; NO OPEN) ---
    function activateGuardedMode() external onlyRole(POLICY_MANAGER_ROLE) {
        if (_s().mode == TransferMode.GUARDED) revert AlreadyGuarded();
        _s().mode = TransferMode.GUARDED;
        emit GuardedModeActivated(msg.sender, block.number);
    }

    function transferMode() external view returns (TransferMode) { return _s().mode; }
    function accountClassOf(address a) external view returns (AccountClass) { return _s().accountClass[a]; }
    function isApprovedOperator(address a) external view returns (bool) { return _s().approvedOperator[a]; }
    function isApproved(address a) external view returns (bool) { return _s().accountClass[a] != AccountClass.NONE; }

    // --- perimeter management ---
    function _setClass(address[] calldata accts, AccountClass class) internal {
        for (uint256 i; i < accts.length; ++i) {
            if (accts[i] == address(0)) revert ZeroAddress();
            _s().accountClass[accts[i]] = class;
            emit AccountClassSet(accts[i], class);
        }
    }

    function setParticipants(address[] calldata a, bool approved) external onlyRole(PARTICIPANT_MANAGER_ROLE) {
        _setClass(a, approved ? AccountClass.PARTICIPANT : AccountClass.NONE);
    }
    function setSystemAccounts(address[] calldata a, bool approved) external onlyRole(PARTICIPANT_MANAGER_ROLE) {
        _setClass(a, approved ? AccountClass.SYSTEM : AccountClass.NONE);
    }
    function setCustodyAccounts(address[] calldata a, bool approved) external onlyRole(PARTICIPANT_MANAGER_ROLE) {
        _setClass(a, approved ? AccountClass.CUSTODY : AccountClass.NONE);
    }
    /// @dev Approving a MARKET_ENDPOINT (a pool/pair/gateway) is the highest-sensitivity action → Timelock.
    function setMarketEndpoints(address[] calldata a, bool approved) external onlyRole(ENDPOINT_MANAGER_ROLE) {
        _setClass(a, approved ? AccountClass.MARKET_ENDPOINT : AccountClass.NONE);
    }
    function setOperators(address[] calldata a, bool approved) external onlyRole(PARTICIPANT_MANAGER_ROLE) {
        for (uint256 i; i < a.length; ++i) {
            if (a[i] == address(0)) revert ZeroAddress();
            _s().approvedOperator[a[i]] = approved;
            emit OperatorSet(a[i], approved);
        }
    }
    /// @notice Fast, Security-Safe-held revocation (revoke-fast); sets class NONE + removes operator.
    function emergencyRevoke(address[] calldata a) external onlyRole(EMERGENCY_REVOKER_ROLE) {
        for (uint256 i; i < a.length; ++i) {
            _s().accountClass[a[i]] = AccountClass.NONE;
            _s().approvedOperator[a[i]] = false;
            emit AccountClassSet(a[i], AccountClass.NONE);
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
        // Mint (from==0) is exempt (only in initialize). Everything else obeys the mode policy.
        if (from != address(0)) {
            GuardedStorage storage $ = _s();
            if ($.mode == TransferMode.BOOTSTRAP) {
                if (!hasRole(BOOTSTRAP_OPERATOR_ROLE, from)) revert TransferNotAllowed(from, to, msg.sender);
            } else {
                // GUARDED (permanent): both endpoints must be approved, AND:
                //  - feeding a MARKET_ENDPOINT (a pool / the V4 PoolManager / a gateway target) requires an
                //    approved OPERATOR (router/gateway) as msg.sender — a plain participant CANNOT send
                //    real BINI directly into a pool or the PoolManager. This is the V4 lever: it blocks
                //    direct user->PoolManager settlement, so a user can never create a BINI balance inside
                //    PoolManager and thus can never mint a BINI ERC-6909 claim to shuttle between PoolIds.
                //  - any other transfer: direct (msg.sender==from) or via an approved operator.
                bool bothApproved =
                    $.accountClass[from] != AccountClass.NONE && $.accountClass[to] != AccountClass.NONE;
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
