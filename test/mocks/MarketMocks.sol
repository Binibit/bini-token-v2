// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

contract ActorContract {}

contract MockV2Pool {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;

    constructor(address tokenA, address tokenB) {
        factory = msg.sender;
        token0 = tokenA;
        token1 = tokenB;
    }
}

contract MockV2Factory {
    mapping(address => mapping(address => address)) public getPair;

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        pair = address(new MockV2Pool(tokenA, tokenB));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}

contract MockV3Pool {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;

    constructor(address tokenA, address tokenB, uint24 poolFee) {
        factory = msg.sender;
        token0 = tokenA;
        token1 = tokenB;
        fee = poolFee;
    }
}

contract MockV3Factory {
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;

    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool) {
        pool = address(new MockV3Pool(tokenA, tokenB, fee));
        getPool[tokenA][tokenB][fee] = pool;
        getPool[tokenB][tokenA][fee] = pool;
    }
}

contract ReturnBombV2Factory {
    address public pair;

    function setPair(address pair_) external {
        pair = pair_;
    }

    function getPair(address, address) external view returns (address) {
        address pair_ = pair;
        assembly {
            mstore(0, pair_)
            return(0, 0x4000)
        }
    }
}

contract ReturnBombV2Pool {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;

    constructor(address factory_, address tokenA, address tokenB) {
        factory = factory_;
        token0 = tokenA;
        token1 = tokenB;
    }
}

contract ShortReturnV2Factory {
    function getPair(address, address) external pure returns (address) {
        assembly {
            mstore(0, 0)
            return(31, 1)
        }
    }
}

contract RevertingProbeWallet {
    fallback() external {
        revert();
    }
}
