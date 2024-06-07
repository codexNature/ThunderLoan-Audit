// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.20;

// e this is probably the interface to work with poolfactory.sol from from TSwap. 
// q why are we using TSwap?
// a we need it to get value of a token to calculate the feess
interface IPoolFactory {
    function getPool(address tokenAddress) external view returns (address);
}


// ✅