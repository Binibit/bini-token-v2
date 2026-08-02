// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BiniMigrationVault
 * @notice Locks known-holder BINI V1 and atomically releases the exact 1:1 token amount in BINI V2.
 * @dev V1 has 12 decimals and V2 has 18, so raw amounts scale by 1,000,000. There is no rescue path
 *      for locked V1. Entitlements are configured by the Timelock and then irreversibly sealed.
 */
contract BiniMigrationVault is AccessControl, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant V1_TO_V2_SCALE = 1_000_000;
    uint256 public constant MAX_ENTITLEMENTS_PER_CALL = 20;
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant RECIPIENT_AUTHORIZATION_TYPEHASH =
        keccak256("RecipientAuthorization(address holder,address recipient,uint256 v1RawAmount,uint256 deadline)");

    IERC20 public immutable v1Token;
    IERC20 public immutable v2Token;

    bool public entitlementsSealed;
    uint256 public totalEntitledV1;
    uint256 public totalEntitledV2;
    uint256 public totalLockedV1;
    uint256 public totalReleasedV2;

    mapping(address holder => uint256 v1RawAmount) public entitlementV1;
    mapping(address holder => uint256 v1RawAmount) public migratedV1;
    mapping(address holder => bytes32 actionId) public migrationActionId;
    mapping(bytes32 actionId => bool configured) public configuredActions;
    mapping(bytes32 actionId => bool completed) public completedActions;

    error ZeroAddress();
    error NotContract(address account);
    error InvalidDecimals(uint8 v1Decimals, uint8 v2Decimals);
    error InvalidArrayLength();
    error EntitlementBatchTooLarge(uint256 supplied, uint256 maximum);
    error InvalidEntitlement(address holder, uint256 amount);
    error EntitlementAlreadyConfigured(address holder);
    error DuplicateAction(bytes32 actionId);
    error EntitlementsAlreadySealed();
    error EntitlementsNotSealed();
    error InsufficientMigrationReserve(uint256 required, uint256 available);
    error MigrationAlreadyCompleted(address holder);
    error AmountDoesNotMatchEntitlement(uint256 expected, uint256 actual);
    error AuthorizationExpired(uint256 deadline);
    error InvalidRecipientAuthorization(address holder, address recipient);
    error InexactV1Lock(uint256 expected, uint256 received);
    error InexactV2Release(uint256 expected, uint256 received);

    event EntitlementConfigured(address indexed holder, uint256 v1RawAmount, uint256 v2RawAmount, bytes32 actionId);
    event EntitlementsSealed(uint256 totalV1Raw, uint256 totalV2Raw);
    event Migrated(
        bytes32 indexed actionId,
        address indexed holder,
        address indexed recipient,
        address operator,
        uint256 v1RawAmount,
        uint256 v2RawAmount
    );

    constructor(address v1Token_, address v2Token_, address adminTimelock) EIP712("BINI V1 to V2 Migration", "1") {
        if (v1Token_ == address(0) || v2Token_ == address(0) || adminTimelock == address(0)) revert ZeroAddress();
        if (v1Token_.code.length == 0) revert NotContract(v1Token_);
        if (v2Token_.code.length == 0) revert NotContract(v2Token_);
        if (adminTimelock.code.length == 0) revert NotContract(adminTimelock);

        uint8 v1Decimals = IERC20Metadata(v1Token_).decimals();
        uint8 v2Decimals = IERC20Metadata(v2Token_).decimals();
        if (v1Decimals != 12 || v2Decimals != 18) revert InvalidDecimals(v1Decimals, v2Decimals);

        v1Token = IERC20(v1Token_);
        v2Token = IERC20(v2Token_);
        _grantRole(DEFAULT_ADMIN_ROLE, adminTimelock);
        _grantRole(CONFIG_ROLE, adminTimelock);
    }

    function setEntitlements(address[] calldata holders, uint256[] calldata v1RawAmounts, bytes32[] calldata actionIds)
        external
        onlyRole(CONFIG_ROLE)
    {
        if (entitlementsSealed) revert EntitlementsAlreadySealed();
        if (holders.length == 0 || holders.length != v1RawAmounts.length || holders.length != actionIds.length) {
            revert InvalidArrayLength();
        }
        if (holders.length > MAX_ENTITLEMENTS_PER_CALL) {
            revert EntitlementBatchTooLarge(holders.length, MAX_ENTITLEMENTS_PER_CALL);
        }

        uint256 addedV1 = 0;
        uint256 addedV2 = 0;
        for (uint256 i; i < holders.length; ++i) {
            address holder = holders[i];
            uint256 v1RawAmount = v1RawAmounts[i];
            bytes32 actionId = actionIds[i];
            if (holder == address(0) || v1RawAmount == 0 || actionId == bytes32(0)) {
                revert InvalidEntitlement(holder, v1RawAmount);
            }
            if (entitlementV1[holder] != 0) revert EntitlementAlreadyConfigured(holder);
            if (migrationActionId[holder] != bytes32(0) || configuredActions[actionId]) {
                revert DuplicateAction(actionId);
            }

            uint256 v2RawAmount = toV2Raw(v1RawAmount);
            entitlementV1[holder] = v1RawAmount;
            migrationActionId[holder] = actionId;
            configuredActions[actionId] = true;
            addedV1 += v1RawAmount;
            addedV2 += v2RawAmount;
            emit EntitlementConfigured(holder, v1RawAmount, v2RawAmount, actionId);
        }
        totalEntitledV1 += addedV1;
        totalEntitledV2 += addedV2;
    }

    function sealEntitlements() external onlyRole(CONFIG_ROLE) {
        if (entitlementsSealed) revert EntitlementsAlreadySealed();
        uint256 available = v2Token.balanceOf(address(this));
        if (available < totalEntitledV2) revert InsufficientMigrationReserve(totalEntitledV2, available);
        entitlementsSealed = true;
        emit EntitlementsSealed(totalEntitledV1, totalEntitledV2);
    }

    function migrate(
        address holder,
        uint256 v1RawAmount,
        address recipient,
        uint256 deadline,
        bytes calldata recipientAuthorization
    ) external nonReentrant returns (uint256 v2RawAmount) {
        if (!entitlementsSealed) revert EntitlementsNotSealed();
        if (holder == address(0) || recipient == address(0)) revert ZeroAddress();
        if (migratedV1[holder] != 0) revert MigrationAlreadyCompleted(holder);

        uint256 expected = entitlementV1[holder];
        if (expected == 0 || v1RawAmount != expected) revert AmountDoesNotMatchEntitlement(expected, v1RawAmount);

        _validateRecipient(holder, recipient, v1RawAmount, deadline, recipientAuthorization);

        v2RawAmount = toV2Raw(v1RawAmount);
        if (v2Token.balanceOf(address(this)) < v2RawAmount) {
            revert InsufficientMigrationReserve(v2RawAmount, v2Token.balanceOf(address(this)));
        }

        bytes32 actionId = migrationActionId[holder];
        migratedV1[holder] = v1RawAmount;
        completedActions[actionId] = true;
        totalLockedV1 += v1RawAmount;
        totalReleasedV2 += v2RawAmount;

        _lockV1(holder, v1RawAmount);
        _releaseV2(recipient, v2RawAmount);

        emit Migrated(actionId, holder, recipient, msg.sender, v1RawAmount, v2RawAmount);
    }

    function _validateRecipient(
        address holder,
        address recipient,
        uint256 v1RawAmount,
        uint256 deadline,
        bytes calldata recipientAuthorization
    ) private view {
        if (recipient == holder) return;
        // slither-disable-next-line timestamp
        if (deadline < block.timestamp) revert AuthorizationExpired(deadline);
        bytes32 digest = recipientAuthorizationDigest(holder, recipient, v1RawAmount, deadline);
        if (!SignatureChecker.isValidSignatureNow(holder, digest, recipientAuthorization)) {
            revert InvalidRecipientAuthorization(holder, recipient);
        }
    }

    function _lockV1(address holder, uint256 v1RawAmount) private {
        uint256 v1Before = v1Token.balanceOf(address(this));
        // The entitlement fixes holder and amount; arbitrary-from is the intended lock operation.
        // slither-disable-next-line arbitrary-send-erc20
        v1Token.safeTransferFrom(holder, address(this), v1RawAmount);
        uint256 v1Received = v1Token.balanceOf(address(this)) - v1Before;
        if (v1Received != v1RawAmount) revert InexactV1Lock(v1RawAmount, v1Received);
    }

    function _releaseV2(address recipient, uint256 v2RawAmount) private {
        uint256 recipientBefore = v2Token.balanceOf(recipient);
        v2Token.safeTransfer(recipient, v2RawAmount);
        uint256 v2Received = v2Token.balanceOf(recipient) - recipientBefore;
        if (v2Received != v2RawAmount) revert InexactV2Release(v2RawAmount, v2Received);
    }

    function toV2Raw(uint256 v1RawAmount) public pure returns (uint256) {
        return v1RawAmount * V1_TO_V2_SCALE;
    }

    function recipientAuthorizationDigest(address holder, address recipient, uint256 v1RawAmount, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(abi.encode(RECIPIENT_AUTHORIZATION_TYPEHASH, holder, recipient, v1RawAmount, deadline))
        );
    }

    function remainingV2Liability() external view returns (uint256) {
        return totalEntitledV2 - totalReleasedV2;
    }
}
