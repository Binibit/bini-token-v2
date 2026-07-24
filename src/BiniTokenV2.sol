// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {
    ERC20PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {
    ERC20CappedUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20CappedUpgradeable.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";

interface IUniswapV2FactoryLike {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV3FactoryLike {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/**
 * @title BiniTokenV2
 * @notice Ethereum-canonical BINI. Ordinary ERC-20 transfers are free from genesis. Before the
 *         irreversible market opening, transfers into known DEX infrastructure are blocked.
 * @dev This policy cannot identify every present or future AMM. It covers explicitly registered
 *      infrastructure and deployed V2/V3-style pools whose factory governance has registered.
 *      Unknown AMMs and pre-funded undeployed CREATE2 addresses are outside the provable boundary.
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
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether;

    enum MarketState {
        PRE_MARKET,
        OPEN_MARKET
    }

    enum FactoryKind {
        NONE,
        UNISWAP_V2,
        UNISWAP_V3
    }

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 public constant MARKET_MANAGER_ROLE = keccak256("MARKET_MANAGER_ROLE");

    bytes4 private constant FACTORY_SELECTOR = bytes4(keccak256("factory()"));
    bytes4 private constant TOKEN0_SELECTOR = bytes4(keccak256("token0()"));
    bytes4 private constant TOKEN1_SELECTOR = bytes4(keccak256("token1()"));
    bytes4 private constant FEE_SELECTOR = bytes4(keccak256("fee()"));
    uint256 private constant PROBE_GAS = 30_000;

    /// @custom:storage-location erc7201:binibit.storage.BiniTokenV2
    struct BiniTokenV2Storage {
        MarketState marketState;
        mapping(address factory => FactoryKind kind) factoryKind;
        mapping(address account => bool blocked) marketInfrastructure;
    }

    // keccak256(abi.encode(uint256(keccak256("binibit.storage.BiniTokenV2")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION = 0xb919b0c0062827d20ad4293e3018837a27a74d3431061c198bdaffa48b665b00;

    error ZeroAddress();
    error NotContract(address account);
    error MarketAlreadyOpen();
    error DexMarketClosed(address destination);

    event MarketOpened(address indexed executor, uint256 indexed blockNumber);
    event DexFactorySet(address indexed factory, FactoryKind kind);
    event MarketInfrastructureSet(address indexed account, bool blocked);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param adminTimelock Holds DEFAULT_ADMIN, UPGRADER, MARKET_MANAGER and UNPAUSER.
     * @param emergencyPauserSafe Holds PAUSER for the independent global circuit breaker.
     * @param genesisDistributionSafe Receives the complete fixed supply in the initial mint.
     * @param adminTransferDelay Delay for the two-step default-admin transfer.
     */
    function initialize(
        address adminTimelock,
        address emergencyPauserSafe,
        address genesisDistributionSafe,
        uint48 adminTransferDelay
    ) external initializer {
        if (adminTimelock == address(0) || emergencyPauserSafe == address(0) || genesisDistributionSafe == address(0)) revert ZeroAddress();

        __ERC20_init("Binibit", "BINI");
        __ERC20Permit_init("Binibit");
        __ERC20Pausable_init();
        __ERC20Capped_init(MAX_SUPPLY);
        __AccessControlDefaultAdminRules_init(adminTransferDelay, adminTimelock);

        _grantRole(UPGRADER_ROLE, adminTimelock);
        _grantRole(MARKET_MANAGER_ROLE, adminTimelock);
        _grantRole(UNPAUSER_ROLE, adminTimelock);
        _grantRole(PAUSER_ROLE, emergencyPauserSafe);

        _mint(genesisDistributionSafe, MAX_SUPPLY);
    }

    modifier onlyPreMarket() {
        _requirePreMarket();
        _;
    }

    /**
     * @notice Permanently removes all DEX-destination checks.
     * @dev The global emergency pause remains independent and may still stop all transfers.
     */
    function openMarket() external onlyRole(MARKET_MANAGER_ROLE) onlyPreMarket {
        _s().marketState = MarketState.OPEN_MARKET;
        emit MarketOpened(msg.sender, block.number);
    }

    function marketState() external view returns (MarketState) {
        return _s().marketState;
    }

    function marketOpen() public view returns (bool) {
        return _s().marketState == MarketState.OPEN_MARKET;
    }

    /**
     * @notice Registers a trusted V2/V3-compatible factory for automatic deployed-pool detection.
     * @dev `NONE` removes a factory. Governance must verify chain, runtime code and implementation.
     */
    function setDexFactory(address factory, FactoryKind kind) external onlyRole(MARKET_MANAGER_ROLE) onlyPreMarket {
        if (factory == address(0)) revert ZeroAddress();
        if (kind != FactoryKind.NONE && factory.code.length == 0) revert NotContract(factory);
        _s().factoryKind[factory] = kind;
        emit DexFactorySet(factory, kind);
    }

    /**
     * @notice Marks concrete DEX recipients such as V4 PoolManager, routers, liquidity managers,
     *         and gateways.
     * @dev This is infrastructure policy, not a participant allowlist. Entries are ignored forever
     *      after `openMarket()`.
     */
    function setMarketInfrastructure(address[] calldata accounts, bool blocked)
        external
        onlyRole(MARKET_MANAGER_ROLE)
        onlyPreMarket
    {
        BiniTokenV2Storage storage $ = _s();
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            if (account == address(0)) revert ZeroAddress();
            if (blocked && account.code.length == 0) revert NotContract(account);
            $.marketInfrastructure[account] = blocked;
            emit MarketInfrastructureSet(account, blocked);
        }
    }

    function dexFactoryKind(address factory) external view returns (FactoryKind) {
        return _s().factoryKind[factory];
    }

    function isMarketInfrastructure(address account) external view returns (bool) {
        return _s().marketInfrastructure[account];
    }

    /**
     * @notice Returns whether an address is presently blocked as a DEX destination.
     * @dev Returns false after OPEN_MARKET even though historical registry entries remain in storage.
     */
    function isBlockedDexDestination(address account) public view returns (bool) {
        if (marketOpen()) return false;
        return _s().marketInfrastructure[account] || isRecognizedDexPool(account);
    }

    /**
     * @notice Detects a deployed V2/V3-style pool belonging to a registered factory.
     * @dev Contract-wallet lookalikes are not blocked unless the registered factory confirms them.
     */
    function isRecognizedDexPool(address account) public view returns (bool) {
        if (account.code.length == 0) return false;

        (bool factoryOk, address factory) = _readAddress(account, FACTORY_SELECTOR);
        FactoryKind kind = factoryOk ? _s().factoryKind[factory] : FactoryKind.NONE;
        if (kind == FactoryKind.NONE) return false;

        (bool token0Ok, address token0) = _readAddress(account, TOKEN0_SELECTOR);
        (bool token1Ok, address token1) = _readAddress(account, TOKEN1_SELECTOR);
        if (!token0Ok || !token1Ok || (token0 != address(this) && token1 != address(this))) return false;

        if (kind == FactoryKind.UNISWAP_V2) {
            return
                _readFactoryAddress(factory, abi.encodeCall(IUniswapV2FactoryLike.getPair, (token0, token1))) == account;
        }

        (bool feeOk, uint24 fee) = _readUint24(account, FEE_SELECTOR);
        return feeOk
            && _readFactoryAddress(factory, abi.encodeCall(IUniswapV3FactoryLike.getPool, (token0, token1, fee)))
                == account;
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(UNPAUSER_ROLE) {
        _unpause();
    }

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20PausableUpgradeable, ERC20CappedUpgradeable)
    {
        _requireNotPaused();
        if (from != address(0) && to != address(0) && isBlockedDexDestination(to)) {
            revert DexMarketClosed(to);
        }
        super._update(from, to, value);
    }

    function _readAddress(address target, bytes4 selector) private view returns (bool ok, address value) {
        bytes32 word;
        (ok, word) = _readWord(target, selector);
        value = address(uint160(uint256(word)));
    }

    function _readUint24(address target, bytes4 selector) private view returns (bool ok, uint24 value) {
        bytes32 word;
        (ok, word) = _readWord(target, selector);
        value = uint24(uint256(word));
    }

    function _readWord(address target, bytes4 selector) private view returns (bool ok, bytes32 word) {
        uint256 shiftedSelector = uint256(uint32(selector)) << 224;
        uint256 probeGas = PROBE_GAS;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, shiftedSelector)
            ok := staticcall(probeGas, target, ptr, 4, ptr, 32)
            if lt(returndatasize(), 32) { ok := 0 }
            word := mload(ptr)
        }
    }

    function _readFactoryAddress(address factory, bytes memory callData) private view returns (address result) {
        (bool ok, bytes memory data) = factory.staticcall{gas: PROBE_GAS}(callData);
        if (ok && data.length >= 32) result = abi.decode(data, (address));
    }

    function _requirePreMarket() private view {
        if (_s().marketState == MarketState.OPEN_MARKET) revert MarketAlreadyOpen();
    }

    function _s() private pure returns (BiniTokenV2Storage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(UPGRADER_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();
    }
}
